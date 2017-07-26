(**
 * Copyright (c) 2013-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "flow" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)


module LocMap = Map.Make (Loc)
open Flow_ast_visitor
open Hoister

class with_or_eval_visitor = object(this)
  inherit [bool] visitor ~init:false as super

  method! expression (expr: Ast.Expression.t) =
    let open Ast.Expression in
    if this#acc = true then expr else match expr with
    | (_, Call { Call.callee = (_, Identifier (_, "eval")); _}) ->
      this#set_acc true;
      expr
    | _ -> super#expression expr

  method! statement (stmt: Ast.Statement.t) =
    if this#acc = true then stmt else super#statement stmt

  method! with_ (stuff: Ast.Statement.With.t) =
    this#set_acc true;
    stuff
end

(* Visitor class that prepares use-def info, hoisting bindings one scope at a
   time. This info can be used for various purposes, e.g. variable renaming.

   We do not generate the scope tree for the entire program, because it is not
   clear where to hang scopes for function expressions, catch clauses,
   etc. One possibility is to augment the AST with scope identifiers.

   As we move into a nested scope, we generate bindings for the new scope, map
   the bindings to names generated by a factory, and augment the existing
   environment with this map before visiting the nested scope.

   Because globals can appear deep in the program, we cannot actually perform
   any renaming until we have walked the entire program. Instead, we compute (1)
   a map from identifier locations to name ids corresponding to binding sites
   and (2) a map from name ids to globals they conflict with. Later, we generate
   names (avoiding conflicts with globals) and rename those locations.

   We try to create the smallest number of name ids possible.
*)
module Def = struct
  type t = {
    loc: Loc.t;
    scope: int;
    name: int;
  }
end
type info = {
  (* map from identifier locations to defs *)
  locals: Def.t LocMap.t;
  (* map from name ids to globals they conflict with *)
  globals: SSet.t IMap.t;
  (* number of distinct name ids *)
  max_distinct: int;
  (* map of child scopes to parent scopes *)
  scopes: int IMap.t;
}
module Acc = struct
  type t = info
  let init = {
    max_distinct = 0;
    globals = IMap.empty;
    locals = LocMap.empty;
    scopes = IMap.empty;
  }
end
class scope_builder = object(this)
  inherit [Acc.t] visitor ~init:Acc.init as super

  val mutable env = SMap.empty
  val mutable scope = -1
  val mutable scope_counter = 0
  method private new_scope parent =
    let child = scope_counter in
    scope_counter <- scope_counter + 1;
    this#update_acc (fun acc -> { acc with
      scopes = IMap.add child parent acc.scopes
    });
    child

  val mutable counter = 0
  method private next =
    let result = counter in
    counter <- counter + 1;
    this#update_acc (fun acc -> { acc with
      max_distinct = max counter acc.max_distinct
    });
    result

  method private mk_env scope bindings =
    List.fold_left (fun map (loc, x) ->
      match SMap.get x map with
      | Some _ -> map
      | None ->
        let def = Def.{ loc; scope; name = this#next; } in
        SMap.add x def map
    ) SMap.empty bindings

  method private push bindings =
    let save_counter = counter in
    let old_env = env in
    let old_scope = scope in
    scope <- this#new_scope old_scope;
    env <- SMap.fold SMap.add (this#mk_env scope (Bindings.to_list bindings)) old_env;
    old_scope, old_env, save_counter

  method private pop (old_scope, old_env, save_counter) =
    scope <- old_scope;
    env <- old_env;
    counter <- save_counter

  method with_bindings: 'a. Bindings.t -> ('a -> 'a) -> 'a -> 'a = fun bindings visit node ->
    let saved_state = this#push bindings in
    let node' = visit node in
    this#pop saved_state;
    node'

  method private add_global x def =
    let { Def.name; _ } = def in
    this#update_acc (fun acc -> { acc with
      globals =
        let iglobals = try IMap.find_unsafe name acc.globals with _ -> SSet.empty in
        IMap.add name (SSet.add x iglobals) acc.globals
    })

  method private add_local loc def =
    this#update_acc (fun acc -> { acc with
      locals = LocMap.add loc def acc.locals
    })

  (* catch params for which their catch blocks introduce bindings, and those
     bindings conflict with the catch params *)
  val mutable bad_catch_params = []

  method! identifier (expr: Ast.Identifier.t) =
    let loc, x = expr in
    begin match SMap.get x env with
      | Some def -> this#add_local loc def
      | None -> SMap.iter (fun _ -> this#add_global x) env
    end;
    expr

  (* don't rename the `foo` in `x.foo` *)
  method! member_property_identifier (id: Ast.Identifier.t) = id

  (* don't rename the `foo` in `{ foo: ... }` *)
  method! object_key_identifier (id: Ast.Identifier.t) = id

  method! block (stmt: Ast.Statement.Block.t) =
    let lexical_hoist = new lexical_hoister in
    let lexical_bindings = lexical_hoist#eval lexical_hoist#block stmt in
    this#with_bindings lexical_bindings super#block stmt

  (* like block *)
  method! program (program: Ast.program) =
    let lexical_hoist = new lexical_hoister in
    let lexical_bindings = lexical_hoist#eval lexical_hoist#program program in
    this#with_bindings lexical_bindings super#program program

  method! for_in_statement (stmt: Ast.Statement.ForIn.t) =
    let open Ast.Statement.ForIn in
    let { left; right = _; body = _; each = _ } = stmt in

    let lexical_hoist = new lexical_hoister in
    let lexical_bindings = match left with
    | LeftDeclaration (_, decl) ->
      lexical_hoist#eval lexical_hoist#variable_declaration decl
    | _ -> Bindings.empty
    in
    this#with_bindings lexical_bindings super#for_in_statement stmt

  method! for_of_statement (stmt: Ast.Statement.ForOf.t) =
    let open Ast.Statement.ForOf in
    let { left; right = _; body = _; async = _ } = stmt in

    let lexical_hoist = new lexical_hoister in
    let lexical_bindings = match left with
    | LeftDeclaration (_, decl) ->
      lexical_hoist#eval lexical_hoist#variable_declaration decl
    | _ -> Bindings.empty
    in
    this#with_bindings lexical_bindings super#for_of_statement stmt

  method! for_statement (stmt: Ast.Statement.For.t) =
    let open Ast.Statement.For in
    let { init; test = _; update = _; body = _ } = stmt in

    let lexical_hoist = new lexical_hoister in
    let lexical_bindings = match init with
    | Some (InitDeclaration (_, decl)) ->
      lexical_hoist#eval lexical_hoist#variable_declaration decl
    | _ -> Bindings.empty
    in
    this#with_bindings lexical_bindings super#for_statement stmt

  method! catch_clause (clause: Ast.Statement.Try.CatchClause.t') =
    let open Ast.Statement.Try.CatchClause in
    let { param; body = _ } = clause in

    this#with_bindings (
      let open Ast.Pattern in
      let _, patt = param in
      match patt with
      | Identifier { Identifier.name; _ } ->
        let loc, _x = name in
        if List.mem loc bad_catch_params then Bindings.empty else
          Bindings.singleton name
      | _ -> (* TODO *)
        Bindings.empty
    ) super#catch_clause clause

  (* helper for function params and body *)
  method private lambda params body =
    let open Ast.Function in

    (* hoisting *)
    let hoist = new hoister in
    begin
      let param_list, _rest = params in
      run_list hoist#function_param_pattern param_list;
      match body with
        | BodyBlock (_loc, block) ->
          run hoist#block block
        | _ ->
          ()
    end;

    (* pushing *)
    let saved_bad_catch_params = bad_catch_params in
    bad_catch_params <- hoist#bad_catch_params;
    let saved_state = this#push hoist#acc in

    let (param_list, rest) = params in
    run_list this#function_param_pattern param_list;
    run_opt this#function_rest_element rest;

    begin match body with
      | BodyBlock (_, block) ->
        run this#block block
      | BodyExpression expr ->
        run this#expression expr
    end;

    (* popping *)
    this#pop saved_state;
    bad_catch_params <- saved_bad_catch_params

  method! function_declaration (expr: Ast.Function.t) =
    let contains_with_or_eval =
      let visit = new with_or_eval_visitor in
      visit#eval visit#function_declaration expr
    in

    if not contains_with_or_eval then begin
      let open Ast.Function in
      let {
        id; params; body; async = _; generator = _; expression = _;
        predicate = _; returnType = _; typeParameters = _;
      } = expr in

      run_opt this#identifier id;

      this#lambda params body;
    end;

    expr

  (* Almost the same as function_declaration, except that the name of the
     function expression is locally in scope. *)
  method! function_ (expr: Ast.Function.t) =
    let contains_with_or_eval =
      let visit = new with_or_eval_visitor in
      visit#eval visit#function_ expr
    in

    if not contains_with_or_eval then begin
      let open Ast.Function in
      let {
        id; params; body; async = _; generator = _; expression = _;
        predicate = _; returnType = _; typeParameters = _;
      } = expr in

      (* pushing *)
      let saved_state = this#push (match id with
        | Some name -> Bindings.singleton name
        | None -> Bindings.empty
      ) in
      run_opt this#identifier id;

      this#lambda params body;

      (* popping *)
      this#pop saved_state;
    end;

    expr
end

module Utils = struct
  type scope = int
  type use = Loc.t

  let all_uses { locals; _ } =
    LocMap.fold (fun use _ uses ->
      use::uses
    ) locals []

  let def_of_use { locals; _ } use =
    LocMap.find use locals

  let use_is_def info use =
    let def = def_of_use info use in
    def.Def.loc = use

  let uses_of_def { locals; _ } ?(exclude_def=false) def =
    LocMap.fold (fun use def' uses ->
      if exclude_def && def'.Def.loc = use then uses
      else if Def.(def.loc = def'.loc) then use::uses else uses
    ) locals []

  let uses_of_use info ?exclude_def use =
    let def = def_of_use info use in
    uses_of_def info ?exclude_def def

  let def_is_unused info def =
    uses_of_def info ~exclude_def:true def = []

  let all_defs { locals; _ } =
    LocMap.fold (fun use def defs ->
      if use = def.Def.loc then def::defs else defs
    ) locals []

  let defs_of_scope info scope =
    let defs = all_defs info in
    List.filter (fun def -> scope = def.Def.scope) defs

end

let program ?(ignore_toplevel=false) program =
  let walk = new scope_builder in
  if ignore_toplevel then walk#eval walk#program program
  else
    let hoist = new hoister in
    let bindings = hoist#eval hoist#program program in
    walk#eval (walk#with_bindings bindings walk#program) program
