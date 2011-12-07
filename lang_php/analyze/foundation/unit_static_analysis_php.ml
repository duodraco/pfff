
open Common

open OUnit

open Env_interpreter_php
module Env = Env_interpreter_php

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)

(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)

let heap_of_program_at_checkpoint content =
  let tmp_file = Parse_php.tmp_php_file_from_string content in

  let ast = 
    Parse_php.parse_program tmp_file +> Ast_php_simple_build.program in
  let db = Env_interpreter_php.code_database_of_juju_db  
    (Env_interpreter_php.juju_db_of_files [tmp_file]) in

  let env = Env_interpreter_php.empty_env db tmp_file in
  let heap = Env_interpreter_php.empty_heap in

  Abstract_interpreter_php.extract_paths := false;
  let _heap = Abstract_interpreter_php.program env heap ast in
  match !Abstract_interpreter_php._checkpoint_heap with
  | None -> failwith "use checkpoint() in your unit test"
  | Some x -> x

let rec chain_ptrs heap v =
  match v with
  | Vptr n ->
      Vptr n::(chain_ptrs heap (IMap.find n heap.ptrs))
  | Vref aset ->
      let n = ISet.choose aset in
      Vref aset::(chain_ptrs heap (Vptr n))
  | x -> [x]

let value_of_var s vars heap =
  let v = SMap.find s vars in
  match v with
  | Vptr n ->
      chain_ptrs heap v
  | _ -> assert_failure "variable is not a Vptr"

let info heap v = Env.string_of_value heap (List.hd v)

let callgraph_generation content =
  let tmp_file = Parse_php.tmp_php_file_from_string content in
  let ast = 
    Parse_php.parse_program tmp_file +> Ast_php_simple_build.program in
  let db = Env_interpreter_php.code_database_of_juju_db
    (Env_interpreter_php.juju_db_of_files [tmp_file]) in

  let env = Env_interpreter_php.empty_env db tmp_file in
  let heap = Env_interpreter_php.empty_heap in

  Abstract_interpreter_php.extract_paths := true;
  let _heap = Abstract_interpreter_php.program env heap ast in
  let graph = !(Abstract_interpreter_php.graph) in
  graph
  

(*****************************************************************************)
(* Abstract interpreter *)
(*****************************************************************************)
let abstract_interpreter_unittest =
  "abstract interpreter" >::: [

  (*-------------------------------------------------------------------------*)
  (* Basic types and dataflow *)
  (*-------------------------------------------------------------------------*)
    "basic" >:: (fun () ->
      let file ="
$x = 42;
checkpoint(); // x:42
" in
      let (heap, vars) = heap_of_program_at_checkpoint file in
      match value_of_var "$x" vars heap with
      (* variables in PHP are pointers to a pointer to a value ... *)
      | [Vptr n1; Vptr n2; Vint 42] -> ()
      | v -> assert_failure ("wrong value for $x: " ^ info heap v)
    );

    "unsugaring" >:: (fun () ->
      let file ="
$x = <<<END
hello
END;
checkpoint(); // x:'hello'
" in
      let (heap, vars) = heap_of_program_at_checkpoint file in
      match value_of_var "$x" vars heap with
      (* todo? it should maybe be "hello" without the newline *)
      | [Vptr n1; Vptr n2; Vstring "hello\n"] -> ()
      | v -> assert_failure ("wrong value for $x: " ^ info heap v)
    );

    "aliasing" >:: (fun () ->
      let file ="
$x = 42;
$y =& $x;
checkpoint();
" in
      let (heap, vars) = heap_of_program_at_checkpoint file in
      let x = value_of_var "$x" vars heap in
      let y = value_of_var "$y" vars heap in
      match x, y with
      | [Vptr ix1; Vref _set; Vptr ix2; Vint 42],
        [Vptr iy1; Vref _set2; Vptr iy2; Vint 42]
        ->
          assert_equal
            ~msg:"it should share the second pointer"
            ix2 iy2;
          assert_bool 
            "variables should have different original pointers"
            (ix1 <> iy1)

      | _ -> assert_failure (spf "wrong value for $x: %s, $y = %s "
                               (info heap x) (info heap y))
    );

    "abstraction when if" >:: (fun () ->
      let file ="
$x = 1;
$y = true; // TODO? could statically detect it's always $x = 2;
if($y) { $x = 2;} else { $x = 3; }
checkpoint(); // x: int
" in
      let (heap, vars) = heap_of_program_at_checkpoint file in
      match value_of_var "$x" vars heap with
      | [Vptr n1; Vptr n2; Vabstr Tint] -> ()
      | v -> assert_failure ("wrong value for $x: " ^ info heap v)
    );

    "union types" >:: (fun () ->
      let file ="
$x = null;
$y = true;
if($y) { $x = 2;} else { $x = 3; }
checkpoint(); // x: null | int
" in
      let (heap, vars) = heap_of_program_at_checkpoint file in
      match value_of_var "$x" vars heap with
      | [Vptr n1; Vptr n2; Vsum [Vnull; Vabstr Tint]] -> ()
      | v -> assert_failure ("wrong value for $x: " ^ info heap v)
    );

    "simple dataflow" >:: (fun () ->
      let file ="
$x = 2;
$x = 3;
$y = $x;
checkpoint(); // y:int
" in
      let (heap, vars) = heap_of_program_at_checkpoint file in
      match value_of_var "$x" vars heap with
      | [Vptr n1; Vptr n2; Vabstr Tint] -> ()
      | v -> assert_failure ("wrong value for $y: " ^ info heap v)
    );

  (*-------------------------------------------------------------------------*)
  (* Interprocedural dataflow *)
  (*-------------------------------------------------------------------------*)

    "interprocedural dataflow" >:: (fun () ->
      let file ="
$x = 2;
function foo($a) { return $a + 1; }
$y = foo($x);
checkpoint(); // y: int
" in
      let (heap, vars) = heap_of_program_at_checkpoint file in
      match value_of_var "$y" vars heap with
      | [Vptr n1; Vptr n2; Vabstr Tint] -> ()
      | v -> assert_failure ("wrong value for $y: " ^ info heap v)
    );

  (*-------------------------------------------------------------------------*)
  (* Lookup semantic *)
  (*-------------------------------------------------------------------------*)

    "semantic lookup static method" >:: (fun () ->

      let file ="
$x = 2;
class A { static function foo($a) { return $a + 1; } }
class B extends A { }
$y = B::foo($x);
checkpoint(); // y::int
" in
      let (heap, vars) = heap_of_program_at_checkpoint file in
      match value_of_var "$y" vars heap with
      | [Vptr n1; Vptr n2; Vabstr Tint] -> ()
      | v -> assert_failure ("wrong value for $y: " ^ info heap v)
    );

    "semantic lookup self in parent" >:: (fun () ->

      let file ="
class A {
  static function foo() { return self::bar(); }
  static function bar() { return 1+1; }
}

class B extends A {
 static function bar() { return false || false; }
  }
$x = B::foo();
$y = B::bar();
checkpoint(); // x: int, y: bool
" in
      let (heap, vars) = heap_of_program_at_checkpoint file in
      (match value_of_var "$x" vars heap with
      | [Vptr n1; Vptr n2; Vabstr Tint] -> ()
      | v -> assert_failure ("wrong value for $x: " ^ info heap v)
      );
      (match value_of_var "$y" vars heap with
      | [Vptr n1; Vptr n2; Vabstr Tbool] -> ()
      | v -> assert_failure ("wrong value for $y: " ^ info heap v)
      );
    );

    "semantic lookup method" >:: (fun () ->

      let file ="
$x = 2;
class A { function foo($a) { return $a + 1; } }
class B extends A { }
$o = new B();
$y = $o->foo($x);
checkpoint(); // y: int
" in
      let (heap, vars) = heap_of_program_at_checkpoint file in
      match value_of_var "$y" vars heap with
      | [Vptr n1; Vptr n2; Vabstr Tint] -> ()
      | v -> assert_failure ("wrong value for $y: " ^ info heap v)
    );
  (*-------------------------------------------------------------------------*)
  (* Callgraph *)
  (*-------------------------------------------------------------------------*)

    "basic callgraph for direct functions" >:: (fun () ->
      let file = "
function foo() { }
function bar() { foo(); }
"
      in
      let g = callgraph_generation file in
      let xs = SMap.find "bar" g +> SSet.elements in
      assert_equal
        ~msg:"it should handle simple direct calls:"
        ["bar"]
        xs;
    );


(*
      (* Checking the semantic of static method calls. *)
      "simple static method call" >:: (fun () ->
        let file = "
          class A { static function a() { } }
          function b() { A::a(); }
        "
        in
        let db = db_from_string file in
        (* shortcuts *)
        let id s = id s db in
        let callers id = callers id db in let callees id = callees id db in
        assert_equal [id "A::a"] (callees (id "b"));
        assert_equal [id "b"] (callers (id "A::a"));
      );

      "static method call with self:: and parent::" >:: (fun () ->
        let file = "
          class A {
           static function a() { }
           static function a2() { self::a(); }
          }
          class B extends A {
           function b() { parent::a(); }
          }
        "
        in
        let db = db_from_string file in
        (* shortcuts *)
        let id s = id s db in
        let callers id = callers id db in let _callees id = callees id db in
        assert_equal
          (sort [id "A::a2"; id "B::b"; 
                 (* todo? we now consider the class as callers too *)
                 id "A::"; id "B::"])
          (sort (callers (id "A::a")));
      );

      (* In PHP it is ok to call B::foo() even if B does not define
       * a static method 'foo' provided that B inherits from a class
       * that defines such a foo.
       *)
      "static method call and inheritance" >:: (fun () ->
        let file = "
          class A { static function a() { } }
          class B extends A { }
          function c() { B::a(); }
        "
        in
        let db = db_from_string file in
        (* shortcuts *)
        let id s = id s db in
        let callers id = callers id db in let _callees id = callees id db in
        (* TODO: how this works?? I have code to solve this pb? where? *)                                  
        assert_equal
          (sort [id "c"])
          (sort (callers (id "A::a")));
      );

      (* Right now the analysis is very simple and does some gross over
       * approximation. With a call like $x->foo(), the analysis consider
       * any method foo in any class as a viable candidate. Doing a better
       * job would require some class and data-flow analysis.
       * Once the analysis gets more precise, fix those tests.
       *)
      "method call approximation" >:: (fun () ->
        let _file = "
          class A { function foo() { } }
          class B { function foo() { } }
          function c() { $a = new A(); $a->foo(); }
        "
        in
(* TODO
        let db = db_from_string file in
        Database_php_build2.index_db_method db;
        (* shortcuts *)
        let id s = id s db in
        let _callers id = callers id db in let callees id = callees id db in
        assert_equal
         (sort [id "A::foo"; id "B::foo"]) (* sad, should have only A::foo *)
         (sort (callees (id "c")));
*)
        ()
      );

      (* PHP is very permissive regarding static method calls as one can
       * do $this->foo() even if foo is a static method. PHP does not
       * impose the X::foo() syntax, which IMHO is just wrong.
       *)
      "static method call and $this" >:: (fun () ->
        let file = "
          class A {
           static function a() { }
           function a2() { $this->a(); }
        }
        "
        in
        let db = db_from_string file in
        (* shortcuts *)
        let _id s = id s db in
        let _callers id = callers id db in let _callees id = callees id db in
        (* This currently fails, and I am not sure I want to fix it. Our
         * code should not use the $this->foo() syntax for static method
         * calls
         *
         * assert_equal
         * (sort [id "A::a2"])
         * (sort (callers (id "A::a")));
         *)
         ()
      );

      (* Checking method calls. *)
      "simple method call" >:: (fun () ->
        let _file = "
          class A { function foo() { } }
          function c() { $a = new A(); $a->foo(); }
        "
        in
(* TODO
        let db = db_from_string file in
        Database_php_build2.index_db_method db;
        (* shortcuts *)
        let id s = id s db in
        let _callers id = callers id db in let callees id = callees id db in
        assert_equal
         (sort [id "A::foo"])
         (sort (callees (id "c")));
*)
        ()
      );


*)
  ]



(*****************************************************************************)
(* Tainting analysis *)
(*****************************************************************************)

(*****************************************************************************)
(* Type inference *)
(*****************************************************************************)

(*****************************************************************************)
(* Final suite *)
(*****************************************************************************)
let unittest =
  "static_analysis_php" >::: [
    abstract_interpreter_unittest;
  ]

(*****************************************************************************)
(* Main entry for args *)
(*****************************************************************************)