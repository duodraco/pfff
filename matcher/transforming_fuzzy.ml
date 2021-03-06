(* Yoann Padioleau
 *
 * Copyright (C) 2013 Facebook
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * version 2.1 as published by the Free Software Foundation, with the
 * special exception on linking described in file license.txt.
 * 
 * This library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the file
 * license.txt for more details.
 *)
open Common

module MV = Metavars_fuzzy
module A = Ast_fuzzy
module B = Ast_fuzzy
module PI = Parse_info

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)
(*
 * This module makes it possible to match and transform one tree 
 * against another tree providing a kind of patch but at a 
 * syntactical level.
 * 
 * To understand the logic behind this code it may help to first read
 * this: http://coccinelle.lip6.fr/papers/eurosys08.pdf
 *)

(*****************************************************************************)
(* The functor argument *)
(*****************************************************************************)

module XMATCH = struct
  (* ------------------------------------------------------------------------*)
  (* Combinators history *) 
  (* ------------------------------------------------------------------------*)
  (*
   * version0: 
   *   type ('a, 'b) matcher = 'a -> 'b -> bool
   * 
   *   This just lets you know if you matched something.
   * 
   * version1:
   *   type ('a, 'b) matcher = 'a -> 'b -> unit -> ('a, 'b) option
   * 
   *   The Maybe monad.
   * 
   * version2:
   *   type ('a, 'b) matcher = 'a -> 'b -> binding -> binding list
   * 
   *   Why not returning a binding option ? because I may need at some
   *   point to return multiple possible bindings for one matching code.
   *   For instance with the pattern do 'f(..., X, ...)', X could be binded
   *   to different parts of the code.
   *   Note that the empty list means a match failure.
   *)

  type tin = MV.fuzzy_binding
  type 'x tout = ('x * MV.fuzzy_binding) list
  type ('a, 'b) matcher = 'a -> 'b  -> tin -> ('a * 'b) tout

  let ((>>=):
          (tin -> ('a * 'b) tout)  -> 
          (('a * 'b) -> (tin -> ('c * 'd) tout)) -> 
          (tin -> ('c * 'd) tout)) = 
    fun m1 m2 ->
      fun tin ->
        (* old:
           match m1 tin with
           | None -> None
           | Some (a,b) ->
           m2 (a, b) tin
        *)
        (* let's get a list of possible environment match (could be 
         * the empty list when it didn't match, playing the role None
         * had before)
         *)
        let xs = m1 tin in
        (* try m2 on each possible returned bindings *)
        let xxs = xs +> List.map (fun ((a,b), binding) -> 
          m2 (a, b) binding
        ) in
        List.flatten xxs

  let (>||>) m1 m2 = fun tin ->
(* CHOICE
      let xs = m1 tin in
      if null xs
      then m2 tin
      else xs
*)
    (* opti? use set instead of list *)
    m1 tin ++ m2 tin

           
  let return (a,b) = fun tin ->
    (* old: Some (a,b) *)
    [(a,b), tin]
      
  let fail = fun tin ->
    (* old: None *)
    []

  (* ------------------------------------------------------------------------*)
  (* Environment *) 
  (* ------------------------------------------------------------------------*)

  let subst_metavars env x =
    (* TODO *)
    x

  (* when a transformation contains a '+' part, as in 
   * - 2
   * + bar(X)
   * 
   * then before applying the transformation we need first to
   * substitute all metavariables by their actual binded value
   * in the environment.
   *)
  let adjust_transfo_with_env env transfo = 
     match transfo with
     | PI.NoTransfo 
     | PI.Remove -> transfo

     | PI.AddBefore add ->
         PI.AddBefore (subst_metavars env add)
     | PI.AddAfter add ->
         PI.AddAfter (subst_metavars env add)
     | PI.Replace add ->
         PI.Replace (subst_metavars env add)

  (* propagate the transformation info *)
  let tokenf a b = fun tin ->
    
    let a1 = Parse_info.str_of_info a in
    let b1 = Parse_info.str_of_info b in
    if a1 =$= b1
    then begin
      let transfo = a.PI.transfo in
      b.PI.transfo <- adjust_transfo_with_env tin transfo;   
      return (a, b) tin
    end
    else fail tin

end

(*****************************************************************************)
(* Entry point  *) 
(*****************************************************************************)

module MATCH  = Fuzzy_vs_fuzzy.X_VS_X (XMATCH)

type ('a, 'b) transformer = 'a -> 'b ->
  Metavars_fuzzy.fuzzy_binding list

let transform_trees_trees pattern e   env = 
  ignore (MATCH.m_trees pattern e   env)
