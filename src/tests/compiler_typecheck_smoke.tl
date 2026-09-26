;; compiler_typecheck_smoke.tl - Runnable smoke for the typechecker self-tests.
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import compiler_typecheck_tests as tc_tests)
(import compiler_typecheck_api as tc_api)
(import compiler_diagnostic as diagnostic)
(import compiler_typecheck_core as tc_core)
(import compiler_typecheck_core_tests as core_tests)
(import compiler_ast_types as ast)
(import compiler_load as load)
(import compiler_ctfe as ctfe)
(import compiler_parse_core as parser)
(import read as reader)
(import compiler_symbols)
(import compiler_builtin_ids as cbi)
(import compiler_intern as ci)
(import compiler_intern_state as cis)
(import stdlib.string)
(import sym_i64_env)

(define (compiler-typecheck-smoke-write-text
  [path : String]
  [contents : String]) : unit
  (io.write-file path (byte_buf.str-as-bytes (& contents))))

(define (compiler-typecheck-lambda-large-global-env-source-from
  [index : i64]
  [limit : i64]
  [out : String]) : String
  (if (>= index limit)
    (str_cat.str-cat
      out
      "(define (main) : unit
  (let
    [f : (-> unit) (lambda () : unit unit)]
    unit))
")
    (compiler-typecheck-lambda-large-global-env-source-from
      (+ index 1)
      limit
      (str_cat.str-cat
        out
        "(define (lambda-global-"
        (string.int->string index)
        ") : i64 "
        (string.int->string index)
        ")\n"))))

(define (compiler-typecheck-bytes-policy-message) : String
  "typecheck: bytes is a borrowed byte-slice referent; use (& lifetime bytes) or (&mut lifetime bytes)")

(define (compiler-typecheck-auto-borrow-assignment-before-last-use-source) : String
  "(define (take [n : (& n i64)]) : i64 1)
(define (main [n : i64]) : i64
  (let
    [borrowed : (& n i64) (& n)]
    (begin
      (set! n 2)
      (take borrowed))))")

(define (compiler-typecheck-auto-borrow-move-before-last-use-source) : String
  "(define (len [text : (& text str)]) : i64 1)
(define (main) : i64
  (let
    [text : String \"move\"]
    (let
      [borrowed : (& text str) (& text)]
      (begin
        (let [moved : String text] 1)
        (len borrowed)))))")

(define (compiler-typecheck-call-diagnostic-tests-ok?) : bool
  (and
    (tc_tests.compiler-typecheck-error-ok?
      "(define (takes-two [count : i64] [enabled : bool]) : i64 count)
(define (main) : i64 (takes-two true false))"
      "typecheck: call `takes-two` argument 1 (parameter `count`) type mismatch: expected i64, found bool")
    (tc_tests.compiler-typecheck-error-ok?
      "(define (main) : i64
  ((lambda ([item : i64]) : i64 item) false))"
      "typecheck: call `lambda` argument 1 (parameter `item`) type mismatch: expected i64, found bool")
    (tc_tests.compiler-typecheck-error-ok?
      "(defstruct Pair
  (left i64)
  (right bool))
(define (main) : i64
  (let [pair : Pair (Pair false true)] pair.left))"
      "typecheck: call `Pair` argument 1 (parameter `left`) type mismatch: expected i64, found bool")
    (tc_tests.compiler-typecheck-error-ok?
      "(define (take-same
  [left : (& same i64)]
  [right : (& same i64)]) : unit
  unit)
(define (main
  [left-value : (& left-life i64)]
  [right-value : (& right-life i64)]) : unit
  (take-same left-value right-value))"
      "typecheck: call `take-same` argument 2 (parameter `right`) type mismatch: expected (& left-life i64), found (& right-life i64); source lifetime `right-life` does not outlive required lifetime `left-life`")
    (tc_tests.compiler-typecheck-error-ok?
      "(define (takes-two [count : i64] [enabled : bool]) : i64 count)
(define (main) : i64 (takes-two 1))"
      "typecheck: call arity mismatch: takes-two expected 2 arguments, got 1 argument")))

(define (compiler-typecheck-auto-borrow-tests-ok?) : bool
  (and
    (tc_tests.compiler-typecheck-ok?
      "(defstruct RefBox (:lifetimes owner) (value (& owner i64)))
(define (take [n : (& n i64)]) : i64 1)
(define (len [text : (& text str)]) : i64 1)
(define (main [n : i64] [text : String]) : i64
  (let
    [direct : i64 (take n)]
    [box : (RefBox n) (RefBox n)]
    [from-box : i64 (take box.value)]
    [f : (-> (& n i64) i64) (lambda ([r : (& n i64)]) : i64 (take r))]
    [via-f : i64 (f n)]
    [text-len : i64 (len text)]
    [after-scope : i64 (let [inner : i64 (len text)] 1)]
    (+ direct (+ from-box (+ via-f (+ text-len after-scope))))))")
    (tc_tests.compiler-typecheck-ok?
      "(define (same-owner [left : (& same str)] [right : (& same str)]) : i64 1)
(define (main [left : String] [right : String]) : i64
  (same-owner left right))")
    (tc_tests.compiler-typecheck-ok?
      "(defstruct ReborrowItem (value i64))
(defstruct ReborrowView (:lifetimes source) (item (& source ReborrowItem)))
(define (read [item : (& seen ReborrowItem)]) : i64 item.value)
(define (view [item : (& source ReborrowItem)]) : (& source ReborrowItem) item)
(define (use [item : (&mut item ReborrowItem)]) : i64
  (let
    [direct : i64 (read item)]
    [f : (-> (& item ReborrowItem) i64)
      (lambda ([x : (& item ReborrowItem)]) : i64 x.value)]
    [via-fn : i64 (f item)]
    [via-lambda : i64
      ((lambda ([x : (& item ReborrowItem)]) : i64 x.value) item)]
    [returned : (& item ReborrowItem) (view item)]
    [returned-value : i64 returned.value]
    [stored : (ReborrowView item) (ReborrowView item)]
    [stored-value : i64 stored.item.value]
    (+ direct (+ via-fn (+ via-lambda (+ returned-value stored-value))))))
(define (main [item : ReborrowItem]) : i64 (use (&mut item)))")
    (tc_tests.compiler-typecheck-error-ok?
      "(defstruct ReborrowItem (value i64))
(define (view [item : (& source ReborrowItem)]) : (& source ReborrowItem) item)
(define (main [item : (&mut item ReborrowItem)]) : i64
  (let [shared : (& item ReborrowItem) (view item)]
    (begin
      (set! item.value 42)
      shared.value)))"
      "typecheck: cannot assign to borrowed place `item.value`")
    (tc_tests.compiler-typecheck-error-ok?
      "(define (read [value : (& shared i64)]) : i64 1)
(define (main [value : (&mut value bool)]) : i64 (read value))"
      "typecheck: call `read` argument 1 (parameter `value`) type mismatch: expected (& shared i64), found (& value bool)")
    (tc_tests.compiler-typecheck-error-ok?
      "(define (write [value : (&mut value i64)]) : unit unit)
(define (main [value : (& value i64)]) : unit (write value))"
      "typecheck: call `write` argument 1 (parameter `value`) type mismatch: expected (&mut value i64), found (& value i64)")
    (tc_tests.compiler-typecheck-ok?
      "(defstruct Named (name String))
(define (len [text : (& text str)]) : i64 1)
(define (same [left : (& left str)] [right : (& right str)]) : bool true)
(define (main [named : Named] [items : (Array String 1)]) : i64
  (if (same named.name (array-ref items 0))
    (+ (len named.name) (len (array-ref items 0)))
    0))")
    (tc_tests.compiler-typecheck-ok?
      "(define (len [text : (& text str)]) : i64 1)
(define (main) : i64
  (let [text : String \"move\"]
    (begin
      (len text)
      (let [moved : String text] 1))))")
    (tc_tests.compiler-typecheck-error-ok?
      (compiler-typecheck-auto-borrow-assignment-before-last-use-source)
      "typecheck: cannot assign to borrowed place `n`")
    (tc_tests.compiler-typecheck-error-ok?
      (compiler-typecheck-auto-borrow-move-before-last-use-source)
      "typecheck: cannot move borrowed place `text`")))

(define (compiler-typecheck-secondary-label-contains?
  [labels : diagnostic.CompilerDiagnosticLabelList]
  [needle : String]) : bool
  (let
    [count : i64 (diagnostic.compiler-diagnostic-label-list-count labels)]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (let
          [entry : diagnostic.CompilerDiagnosticLabel
            (diagnostic.compiler-diagnostic-label-list-get labels index)]
          (begin
            (match entry.label
              [(CompilerDiagnosticSomeString text)
                (if (string.contains (& text) (& needle))
                  (set! found true)
                  unit)]
              [CompilerDiagnosticNoString unit])
            (set! index (+ index 1)))))
      found)))

(define (compiler-typecheck-help-contains?
  [diag : (& diag diagnostic.CompilerDiagnostic)]
  [needle : String]) : bool
  (match (diagnostic.compiler-diagnostic-help diag)
    [(CompilerDiagnosticSomeString text) (string.contains (& text) (& needle))]
    [CompilerDiagnosticNoString false]))

(define (compiler-typecheck-labeled-borrow-error-ok?
  [src : String]
  [want-message-fragment : String]) : bool
  (match (tc_api.typecheck-compiler-source src)
    [(tc_core.ResultCompilerTypecheck.Err diag)
      (let
        [first : diagnostic.CompilerDiagnostic
          (diagnostic.compiler-diagnostic-list-first
            (diagnostic.compiler-diagnostic-list-box-shared-view diag))]
        [message : String (diagnostic.compiler-diagnostic-message first)]
        (and
          (string.contains (& message) (& want-message-fragment))
          (compiler-typecheck-help-contains? first "narrower lexical scope")
          (=
            (tc_tests.compiler-typecheck-secondary-count
              (diagnostic.compiler-diagnostic-secondary-spans first))
            1)
          (compiler-typecheck-secondary-label-contains?
            (diagnostic.compiler-diagnostic-secondary-spans first)
            "remains live")))]
    [(tc_core.ResultCompilerTypecheck.Ok _) false]))

(define (compiler-typecheck-borrow-diagnostic-tests-ok?) : bool
  (and
    (compiler-typecheck-labeled-borrow-error-ok?
      (compiler-typecheck-auto-borrow-assignment-before-last-use-source)
      "typecheck: cannot assign to borrowed place `n`")
    (compiler-typecheck-labeled-borrow-error-ok?
      (compiler-typecheck-auto-borrow-move-before-last-use-source)
      "typecheck: cannot move borrowed place `text`")
    (compiler-typecheck-labeled-borrow-error-ok?
      "(defstruct Pair (left i64) (right i64))
(define (read-i64-ref [r : (& pair i64)]) : i64 1)
(define (main [pair : Pair]) : i64
  (let
    [borrowed : (& pair i64) (& pair.left)]
    (begin
      (set! pair.left 3)
      (read-i64-ref borrowed))))"
      "typecheck: cannot assign to borrowed place `pair.left`")
    (compiler-typecheck-labeled-borrow-error-ok?
      "(define (read-i64-ref [r : (& items i64)]) : unit unit)
(define (main [items : (__tl_dyn-array i64)]) : unit
  (let
    [borrowed : (& items i64) (& (array-ref items 0))]
    (begin
      (let
        [exclusive : (&mut items i64) (&mut (array-ref items 0))]
        unit)
      (read-i64-ref borrowed))))"
      "typecheck: cannot mutably borrow borrowed place")
    (compiler-typecheck-labeled-borrow-error-ok?
      "(define (write-i64-ref [r : (&mut items i64)]) : unit unit)
(define (main [items : (__tl_dyn-array i64)]) : unit
  (let
    [exclusive : (&mut items i64) (&mut (array-ref items 0))]
    (begin
      (let
        [borrowed : (& items i64) (& (array-ref items 0))]
        unit)
      (write-i64-ref exclusive))))"
      "typecheck: cannot read mutably borrowed place `items[0]`")
    (compiler-typecheck-labeled-borrow-error-ok?
      "(define (borrow-text [source : (& source str)]) : (& source str)
  source)
(define (len [text : (& text str)]) : i64 1)
(define (main) : i64
  (let
    [text : String \"borrowed\"]
    (let
      [borrowed : (& text str) (borrow-text (& text))]
      (begin
        (let [moved : String text] 1)
        (len borrowed)))))"
      "typecheck: cannot move borrowed place `text`")
    (tc_tests.compiler-typecheck-ok?
      "(define (borrow-text [source : (& source str)]) : (& source str)
  source)
(define (len [text : (& text str)]) : i64 1)
(define (main) : i64
  (let
    [text : String \"borrowed\"]
    (let
      [borrowed : (& text str) (borrow-text (& text))]
      (begin
        (len borrowed)
        (let [moved : String text] 1)))))")
    (tc_tests.compiler-typecheck-ok?
      "(define (len [text : (& text str)]) : i64 1)
(define (main) : i64
  (let
    [text : String \"borrowed\"]
    (begin
      (let [n : i64 (len (& text))] n)
      (let [moved : String text] 1))))")
    (tc_tests.compiler-typecheck-ok?
      "(define (take [n : (& n i64)]) : i64
  1)
(define (main [n : i64]) : i64
  (begin
    (let [tmp : i64 (take n)] tmp)
    (set! n 2)
    n))")
    (tc_tests.compiler-typecheck-ok?
      "(defstruct Bags
  (left (__tl_dyn-array i64))
  (right (__tl_dyn-array i64)))
(define (main) : unit
  (let
    [left-items : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [right-items : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [bags : Bags (Bags left-items right-items)]
    (let
      [left : (&mut bags (__tl_dyn-array i64)) (&mut bags.left)]
      [right : (&mut bags (__tl_dyn-array i64)) (&mut bags.right)]
      unit)))")
    (compiler-typecheck-labeled-borrow-error-ok?
      "(defstruct Bags
  (left (__tl_dyn-array i64))
  (right (__tl_dyn-array i64)))
(define (write-array-ref [items : (&mut bags (__tl_dyn-array i64))]) : unit unit)
(define (main) : unit
  (let
    [left-items : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [right-items : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [bags : Bags (Bags left-items right-items)]
    (let
      [first : (&mut bags (__tl_dyn-array i64)) (&mut bags.left)]
      [second : (&mut bags (__tl_dyn-array i64)) (&mut bags.left)]
      (write-array-ref first))))"
      "typecheck: cannot read mutably borrowed place `bags.left`")
    (compiler-typecheck-labeled-borrow-error-ok?
      "(defstruct Bags
  (left (__tl_dyn-array i64))
  (right (__tl_dyn-array i64)))
(define (main) : unit
  (let
    [left-items : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [right-items : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [bags : Bags (Bags left-items right-items)]
    (let
      [whole-left : (&mut bags (__tl_dyn-array i64)) (&mut bags.left)]
      [first-item : (&mut bags i64) (&mut (array-ref bags.left 0))]
      (set! (array-ref whole-left 0) 1))))"
      "typecheck: cannot read mutably borrowed place `bags.left[0]`")
    (compiler-typecheck-labeled-borrow-error-ok?
      "(define (touch [slot : (&mut items i64)]) : unit unit)
(define (bad [items : (&mut items (__tl_dyn-array i64))]) : unit
  (let
    [slot : (&mut items i64) (&mut (array-ref items 0))]
    (begin
      (set! (array-ref items 0) 7)
      (touch slot))))
(define (main [items : (__tl_dyn-array i64)]) : unit
  (bad (&mut items)))"
      "typecheck: cannot assign to borrowed place `items[0]`")
    (compiler-typecheck-labeled-borrow-error-ok?
      "(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [borrowed : (&mut items (__tl_dyn-array i64)) (&mut items)]
    [n : i64 (array-length items)]
    (begin
      (set! (array-ref borrowed 0) 41)
      (+ n 1))))"
      "typecheck: cannot read mutably borrowed place `items`")
    (compiler-typecheck-labeled-borrow-error-ok?
      "(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [borrowed : (&mut items (__tl_dyn-array i64)) (&mut items)]
    [n : i64 (array-ref items 0)]
    (begin
      (set! (array-ref borrowed 0) 41)
      n)))"
      "typecheck: cannot read mutably borrowed place `items[0]`")
    (compiler-typecheck-labeled-borrow-error-ok?
      "(defstruct Bag
  (left (__tl_dyn-array i64))
  (right i64))
(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [bag : Bag (Bag items 42)]
    [borrowed : (&mut bag (__tl_dyn-array i64)) (&mut bag.left)]
    [copy : (__tl_dyn-array i64) bag.left]
    (begin
      (set! (array-ref borrowed 0) 41)
      (array-length copy))))"
      "typecheck: cannot read mutably borrowed place `bag.left`")
    (tc_tests.compiler-typecheck-ok?
      "(define (read-len [items : (& items (__tl_dyn-array i64))]) : i64
  (array-length items))
(define (push-with-len [items : (&mut items (__tl_dyn-array i64))] [value : i64]) : unit
  (__tl_array-push! items value))
(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    (begin
      (push-with-len (&mut items) (read-len (& items)))
      (array-length items))))")
    (tc_tests.compiler-typecheck-ok?
      "(define (push-with-len [items : (&mut items (__tl_dyn-array i64))] [value : i64]) : unit
  (__tl_array-push! items value))
(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    (begin
      (push-with-len (&mut items) (array-length items))
      (array-length items))))")
    (compiler-typecheck-labeled-borrow-error-ok?
      "(define (take [n : (& n i64)]) : i64 1)
(define (main [n : i64] [flag : bool]) : i64
  (let
    [borrowed : (& n i64) (& n)]
    (begin
      (if flag (set! n 2) unit)
      (take borrowed))))"
      "typecheck: cannot assign to borrowed place `n`")
    (compiler-typecheck-labeled-borrow-error-ok?
      "(define (take [n : (& n i64)]) : i64 1)
(define (main [n : i64] [flag : bool]) : i64
  (let
    [borrowed : (& n i64)
      (if flag
        (& n)
        (& n))]
    (begin
      (set! n 2)
      (take borrowed))))"
      "typecheck: cannot assign to borrowed place `n`")
    (tc_tests.compiler-typecheck-ok?
      "(define (take [n : (& n i64)]) : i64 1)
(define (main [n : i64] [flag : bool]) : i64
  (let
    [borrowed : (& n i64)
      (if flag
        (& n)
        (& n))]
    (begin
      (take borrowed)
      (set! n 2)
      n)))")
    (compiler-typecheck-labeled-borrow-error-ok?
      "(define (take [n : (& n i64)]) : i64 1)
(defenum Flag (On) (Off))
(define (main [n : i64] [flag : Flag]) : i64
  (let
    [borrowed : (& n i64)
      (match flag
        [On (& n)]
        [Off (& n)])]
    (begin
      (set! n 2)
      (take borrowed))))"
      "typecheck: cannot assign to borrowed place `n`")
    (tc_tests.compiler-typecheck-ok?
      "(define (take [n : (& n i64)]) : i64 1)
(defenum Flag (On) (Off))
(define (main [n : i64] [flag : Flag]) : i64
  (let
    [borrowed : (& n i64)
      (match flag
        [On (& n)]
        [Off (& n)])]
    (begin
      (take borrowed)
      (set! n 2)
      n)))")
    (compiler-typecheck-labeled-borrow-error-ok?
      "(defstruct RefBox (:lifetimes owner) (value (& owner i64)))
(define (read-box [box : (RefBox owner)]) : i64 1)
(define (main [n : i64] [flag : bool]) : i64
  (let
    [box : (RefBox n)
      (if flag
        (RefBox n)
        (RefBox n))]
    (begin
      (set! n 2)
      (read-box box))))"
      "typecheck: cannot assign to borrowed place `n`")
    (tc_tests.compiler-typecheck-ok?
      "(defstruct RefBox (:lifetimes owner) (value (& owner i64)))
(define (read-box [box : (RefBox owner)]) : i64 1)
(define (main [n : i64] [flag : bool]) : i64
  (let
    [box : (RefBox n)
      (if flag
        (RefBox n)
        (RefBox n))]
    (begin
      (read-box box)
      (set! n 2)
      n)))")
    (compiler-typecheck-labeled-borrow-error-ok?
      "(define (take [n : (& n i64)]) : i64 1)
(define (main [n : i64]) : i64
  (let
    [borrowed : (& n i64) (& n)]
    (begin
      (while (< n 3) (set! n 2))
      (take borrowed))))"
      "typecheck: cannot assign to borrowed place `n`")))

(define (compiler-typecheck-labeled-move-error-ok?
  [src : String]
  [want-message : String]
  [want-label-fragment : String]) : bool
  (match (tc_api.typecheck-compiler-source src)
    [(tc_core.ResultCompilerTypecheck.Err diag)
      (let
        [first : diagnostic.CompilerDiagnostic
          (diagnostic.compiler-diagnostic-list-first
            (diagnostic.compiler-diagnostic-list-box-shared-view diag))]
        (and
          (string.eq
            (diagnostic.compiler-diagnostic-message first)
            want-message)
          (compiler-typecheck-help-contains? first "clone the owner")
          (=
            (tc_tests.compiler-typecheck-secondary-count
              (diagnostic.compiler-diagnostic-secondary-spans first))
            1)
          (compiler-typecheck-secondary-label-contains?
            (diagnostic.compiler-diagnostic-secondary-spans first)
            want-label-fragment)))]
    [(tc_core.ResultCompilerTypecheck.Ok _) false]))

(define (compiler-typecheck-labeled-cleanup-move-error-ok?
  [src : String]
  [want-message : String]
  [want-move-label-fragment : String]
  [want-owner-label-fragment : String]) : bool
  (match (tc_api.typecheck-compiler-source src)
    [(tc_core.ResultCompilerTypecheck.Err diag)
      (let
        [first : diagnostic.CompilerDiagnostic
          (diagnostic.compiler-diagnostic-list-first
            (diagnostic.compiler-diagnostic-list-box-shared-view diag))]
        (and
          (string.eq
            (diagnostic.compiler-diagnostic-message first)
            want-message)
          (compiler-typecheck-help-contains? first "clone the owner")
          (=
            (tc_tests.compiler-typecheck-secondary-count
              (diagnostic.compiler-diagnostic-secondary-spans first))
            2)
          (compiler-typecheck-secondary-label-contains?
            (diagnostic.compiler-diagnostic-secondary-spans first)
            want-move-label-fragment)
          (compiler-typecheck-secondary-label-contains?
            (diagnostic.compiler-diagnostic-secondary-spans first)
            want-owner-label-fragment)))]
    [(tc_core.ResultCompilerTypecheck.Ok _) false]))

(define (compiler-typecheck-move-diagnostic-tests-ok?) : bool
  (and
    (compiler-typecheck-labeled-move-error-ok?
      (tc_tests.compiler-typecheck-move-use-after-move-source)
      "typecheck: use of moved value `s`"
      "move of `s` happened here")
    (compiler-typecheck-labeled-move-error-ok?
      (tc_tests.compiler-typecheck-move-owner-projection-nested-repeat-source)
      "typecheck: use of moved value `p.inner.handle`"
      "move of `p.inner.handle` happened here")
    (compiler-typecheck-labeled-move-error-ok?
      (tc_tests.compiler-typecheck-move-owner-projection-deep-mixed-repeat-source)
      "typecheck: use of moved value `p.mixed.0[1].0`"
      "move of `p.mixed.0[1].0` happened here")
    (compiler-typecheck-labeled-move-error-ok?
      (tc_tests.compiler-typecheck-move-owner-projection-nested-parent-after-child-source)
      "typecheck: use of moved value `p.inner`"
      "move of `p.inner.handle` happened here")
    (compiler-typecheck-labeled-move-error-ok?
      (tc_tests.compiler-typecheck-move-owner-projection-nested-child-after-parent-source)
      "typecheck: use of moved value `p.inner`"
      "move of `p.inner` happened here")
    (compiler-typecheck-labeled-move-error-ok?
      (tc_tests.compiler-typecheck-move-while-loop-carried-param-source)
      "typecheck: cannot move loop-carried owner value `s`"
      "loop-carried")
    (compiler-typecheck-labeled-cleanup-move-error-ok?
      (tc_tests.compiler-typecheck-move-with-cleanup-owner-whole-source)
      "typecheck: cleanup owner `h` moved before with scope exit"
      "move of `h` happened here"
      "cleanup owner `h` is bound")
    (compiler-typecheck-labeled-cleanup-move-error-ok?
      (tc_tests.compiler-typecheck-move-with-cleanup-owner-field-source)
      "typecheck: cleanup owner `h` moved before with scope exit"
      "move of `h.handle` happened here"
      "cleanup owner `h` is bound")))

(define (compiler-typecheck-reference-return-container-tests-ok?) : bool
  (and
    (tc_tests.compiler-typecheck-ok?
      "(define (main [n : i64]) : (Tuple (& n i64) i64)
  (tuple (& n) 1))")
    (tc_tests.compiler-typecheck-ok?
      "(define (main [n : i64]) : (Array (& n i64) 1)
  (array (& n)))")
    (tc_tests.compiler-typecheck-error-ok?
      "(define (main [n : i64]) : (Tuple (& n i64) i64)
  (let [n : i64 1] (tuple (& n) 1)))"
      "typecheck: reference value would escape lexical scope")
    (tc_tests.compiler-typecheck-error-ok?
      "(define (main [n : i64]) : (Array (& n i64) 1)
  (let [n : i64 1] (array (& n))))"
      "typecheck: reference value would escape lexical scope")
    (tc_tests.compiler-typecheck-error-ok?
      (tc_tests.compiler-typecheck-with-alloc-string-helper-source
        "(define (main [seed : (& phase str)]) : (Tuple (& phase str) i64)
  (with-arena phase
    (let [s : String (string.int->string 1)] (tuple (& phase s) 1))))")
      "typecheck: region-tagged value cannot escape with-arena 'phase'")
    (tc_tests.compiler-typecheck-error-ok?
      (tc_tests.compiler-typecheck-with-alloc-string-helper-source
        "(define (main [seed : (& phase str)]) : (Array (& phase str) 1)
  (with-arena phase
    (let [s : String (string.int->string 1)] (array (& phase s)))))")
      "typecheck: region-tagged value cannot escape with-arena 'phase'")))

(define (compiler-typecheck-reference-dyn-array-tests-ok?) : bool
  (and
    (tc_tests.compiler-typecheck-ok?
      "(define (main [n : i64]) : unit
  (let [items : (__tl_dyn-array (& n i64)) (init : (__tl_dyn-array (& n i64)))] unit))")
    (tc_tests.compiler-typecheck-ok?
      "(define (main [n : i64]) : unit
  (let
    [items : (__tl_dyn-array (& n i64)) (init : (__tl_dyn-array (& n i64)))]
    (begin
      (__tl_array-push! items (& n))
      (let [r : (& n i64) (array-ref items 0)] unit))))")
    (tc_tests.compiler-typecheck-ok?
      "(defenum Loop (LoopBox (Box Loop)))
(define (main) : unit
  (let [items : (__tl_dyn-array Loop) (__tl_make-array Loop 0)] unit))")
    (tc_tests.compiler-typecheck-error-ok?
      "(define (main [n : i64]) : unit
  (let
    [items : (__tl_dyn-array (& n i64)) (init : (__tl_dyn-array (& n i64)))]
    (let [n : i64 1] (__tl_array-push! items (& n)))))"
      "typecheck: cannot store reference into longer-lived array; reference value would escape lexical scope")
    (tc_tests.compiler-typecheck-error-ok?
      "(define (main [n : i64]) : unit
  (let [items : (__tl_dyn-array (& n i64)) (__tl_make-array (& n i64) 0)] unit))"
      "typecheck: init unsupported type (& n i64)")
    (tc_tests.compiler-typecheck-error-ok?
      "(define (main) : unit
  (let [items : (__tl_dyn-array (& n i64)) (__tl_make-array (& n i64) 0)] unit))"
      "typecheck: __tl_make-array element type is not supported")))

(define (compiler-typecheck-signature-lifetime-alias-tests-ok?) : bool
  (tc_tests.compiler-typecheck-ok?
    "(defstruct SignatureAliasRec
  (value i64))
(defstruct SignatureAliasStored
  (field i64)
  (pair (Tuple i64 i64))
  (fixed (Array i64 1)))
(define (signature-alias-touch!
  [items : (&mut source (__tl_dyn-array SignatureAliasRec))]
  [index : i64]) : unit
  (let
    [item : (&mut source SignatureAliasRec)
      (&mut (array-ref items index))]
    (begin
      (set! item.value (+ item.value 1))
      unit)))
(define (signature-alias-read-copy [value : (& source i64)]) : unit
  (let [copy : (& source i64) value] unit))
(define (signature-alias-project
  [stored : (& source SignatureAliasStored)]) : unit
  (let
    [field : (& source i64) (& stored.field)]
    [tuple-item : (& source i64)
      (& (tuple-ref stored.pair 0))]
    [array-item : (& source i64)
      (& (array-ref stored.fixed 0))]
    unit))
(define (signature-alias-same-input
  [left : (& same i64)]
  [right : (& same i64)]) : unit
  (let
    [left-copy : (& same i64) left]
    [right-copy : (& same i64) right]
    unit))
(define (signature-alias-value-lookup
  [item : (& source i64)]
  [source : i64]) : i64
  (let [copy : (& source i64) item] source))
(define (main [value : i64]) : i64
  (begin
    (signature-alias-same-input (& value) (& value))
    (signature-alias-value-lookup (& value) 42)))"))

(define (compiler-typecheck-bytes-referent-tests-ok?) : bool
  (and
    (tc_tests.compiler-typecheck-ok?
      "(defstruct ByteViews
  (:lifetimes data)
  (ro (& data bytes))
  (rw (&mut data bytes)))
(define (take [ro : (& data bytes)] [rw : (&mut data bytes)]) : unit unit)
(define (main [ro : (& data bytes)] [rw : (&mut data bytes)]) : unit
  (take ro rw))")
    (tc_tests.compiler-typecheck-error-ok?
      "(define (main [raw : bytes]) : unit unit)"
      (compiler-typecheck-bytes-policy-message))
    (tc_tests.compiler-typecheck-error-ok?
      "(define (main) : unit
  (let [raw : bytes (init : bytes)] unit))"
      (compiler-typecheck-bytes-policy-message))
    (tc_tests.compiler-typecheck-error-ok?
      "(defstruct BadBytes (payload bytes))
(define (main) : unit unit)"
      (compiler-typecheck-bytes-policy-message))
    (tc_tests.compiler-typecheck-error-ok?
      "(define (main [items : (__tl_dyn-array bytes)]) : unit unit)"
      (compiler-typecheck-bytes-policy-message))))

(define (compiler-typecheck-reference-lambda-capture-tests-ok?) : bool
  (and
    (tc_tests.compiler-typecheck-ok?
      "(define (read [r : (& n i64)]) : i64 42)
(define (main [n : i64]) : i64
  (let [r : (& n i64) (& n)]
    ((lambda () : i64 (read r)))))")
    (tc_tests.compiler-typecheck-ok?
      "(define (read [r : (& n i64)]) : i64 42)
(define (main [n : i64]) : i64
  (let [r : (& n i64) (& n)]
    (let [f : (-> i64) (lambda () : i64 (read r))]
      (f))))")
    (tc_tests.compiler-typecheck-ok?
      "(define (read [r : (& n i64)]) : i64 42)
(define (main [n : i64]) : i64
  (let [r : (& n i64) (& n)]
    (let [i : i64 0]
      (let [f : (-> i64) (lambda () : i64 (read r))]
        (begin
          (while (< i 1)
            (begin
              (set! i (+ i 1))
              (let [v : i64 (f)] unit)))
          (f))))))")
    (tc_tests.compiler-typecheck-ok?
      (compiler-typecheck-lambda-large-global-env-source-from 0 192 ""))
    (tc_tests.compiler-typecheck-ok?
      "(define (read [r : (& n i64)]) : i64 42)
(define (main [n : i64]) : i64
  (let [r : (& n i64) (& n)]
    ((lambda () : i64
      (let [f : (-> i64) (lambda () : i64 (read r))]
        (f))))))")
    (tc_tests.compiler-typecheck-ok?
      "(define (read [r : (& n i64)]) : i64 42)
(define (main [n : i64]) : i64
  (let [r : (& n i64) (& n)]
    (with-arena scratch
      (let [f : (-> i64) (lambda () : i64 (read r))]
        (f)))))")
    (tc_tests.compiler-typecheck-error-ok?
      "(define (read [r : (& n i64)]) : i64 42)
(define (main [n : i64]) : (-> i64)
  (let [r : (& n i64) (& n)]
    (let [f : (-> i64) (lambda () : i64 (read r))]
      f)))"
      "typecheck: reference-capturing closure value would escape lexical scope")
    (tc_tests.compiler-typecheck-error-ok?
      "(define (read [r : (& n i64)]) : i64 42)
(define (main [n : i64]) : (Tuple (-> i64))
  (let [r : (& n i64) (& n)]
    (let [f : (-> i64) (lambda () : i64 (read r))]
      (tuple f))))"
      "typecheck: reference-capturing closure value would escape lexical scope")
    (tc_tests.compiler-typecheck-error-ok?
      "(define (read [r : (& n i64)]) : i64 42)
(define (call-now [f : (-> i64)]) : i64 (f))
(define (main [n : i64]) : i64
  (let [r : (& n i64) (& n)]
    (let [f : (-> i64) (lambda () : i64 (read r))]
      (call-now f))))"
      "typecheck: reference-capturing closure value would escape lexical scope")
    (tc_tests.compiler-typecheck-error-ok?
      "(define (read [r : (& n i64)]) : i64 42)
(define (main [n : i64]) : i64
  (let [r : (& n i64) (& n)]
    (let
      [f : (-> i64) (lambda () : i64 (read r))]
      [g : (-> i64) (lambda () : i64 0)]
      (begin
        (set! g f)
        (g)))))"
      "typecheck: reference-capturing closure value would escape lexical scope")
    (tc_tests.compiler-typecheck-error-ok?
      "(define (read [r : (& n i64)]) : i64 42)
(define (main) : (-> i64)
  (with-arena scratch
    (let [n : i64 1]
      (let [r : (& n i64) (& n)]
        (let [f : (-> i64) (lambda () : i64 (read r))]
          f)))))"
      "typecheck: reference-capturing closure value would escape lexical scope")
    (tc_tests.compiler-typecheck-ok?
      "(define (read [r : (&mut items i64)]) : i64 42)
(define (main [items : (__tl_dyn-array i64)]) : i64
  (let [r : (&mut items i64) (&mut (array-ref items 0))]
    ((lambda () : i64 (read r)))))")
    (tc_tests.compiler-typecheck-ok?
      "(define (write [r : (&mut items i64)]) : unit unit)
(define (main [items : (__tl_dyn-array i64)]) : i64
  (let
    [r : (&mut items i64) (&mut (array-ref items 0))]
    [f : (-> unit) (lambda () : unit (write r))]
    (begin (f) (f) (array-ref items 0))))")
    (tc_tests.compiler-typecheck-error-ok?
      "(define (write [r : (&mut items i64)]) : unit unit)
(define (main [items : (__tl_dyn-array i64)]) : unit
  (let
    [r : (&mut items i64) (&mut (array-ref items 0))]
    [f : (-> unit) (lambda () : unit (write r))]
    [alias : (-> unit) f]
    (alias)))"
      "typecheck: reference-capturing closure value would escape lexical scope")
    (tc_tests.compiler-typecheck-ok?
      "(define (main) : String
  (let
    [owned : String \"once\"]
    [take : (-> String) (lambda () : String owned)]
    (take)))")
    (tc_tests.compiler-typecheck-ok?
      "(define (read [value : (& value str)]) : i64 42)
(define (main) : i64
  (let
    [owned : String \"repeat\"]
    [f : (-> i64) (lambda () : i64 (read (& owned)))]
    (begin (f) (f))))")))

(define (compiler-typecheck-closure-copy-tests-ok?) : bool
  (and
    (tc_tests.compiler-typecheck-ok?
      "(defstruct Pair
  (left i64)
  (right i64))
(define (named) : i64 1)
(define (main [x : i64]) : i64
  (let
    [pair : Pair (Pair 40 2)]
    [fn-value : (-> i64) named]
    [f : (-> i64)
      (lambda () : i64
        (+ x (+ pair.left (fn-value))))]
    [copy : (-> i64) f]
    (+ (f) (copy))))")
    (tc_tests.compiler-typecheck-ok?
      "(define (read [r : (& n i64)]) : i64 1)
(define (main [x : i64]) : i64
  (let
    [r : (& x i64) (& x)]
    [f : (-> i64) (lambda () : i64 (read r))]
    [copy : (-> i64) f]
    (+ (f) (copy))))")
    (tc_tests.compiler-typecheck-error-ok?
      "(define (read [r : (& n i64)]) : i64 1)
(define (main [x : i64]) : (-> i64)
  (let
    [r : (& x i64) (& x)]
    [f : (-> i64) (lambda () : i64 (read r))]
    [copy : (-> i64) f]
    copy))"
      "typecheck: reference-capturing closure value would escape lexical scope")
    (tc_tests.compiler-typecheck-error-ok?
      "(import stdlib.string)
(define (main) : i64
  (let
    [owned : String \"captured\"]
    [inner : (-> i64) (lambda () : i64 (string.string-length owned))]
    [outer : (-> i64) (lambda () : i64 (inner))]
    [moved : (-> i64) outer]
    (+ (moved) (outer))))"
      "typecheck: use of moved value `outer`")))

(define (compiler-typecheck-reference-escape-tests-ok?) : bool
  (and
    (tc_tests.compiler-typecheck-ok?
      "(define (main [x : i64]) : unit
  (let
    [x : i64 (+ x 1)]
    (let [r : (& x i64) (& x)] unit)))")
    (tc_tests.compiler-typecheck-error-ok?
      "(define (main) : unit
  (let
    [r : (& x i64) (let [x : i64 1] (& x))]
    unit))"
      "typecheck: reference value would escape lexical scope")
    (tc_tests.compiler-typecheck-error-ok?
      "(define (main [x : i64]) : unit
  (let
    [slot : (& x i64) (& x)]
    (let [x : i64 1] (set! slot (& x)))))"
      "typecheck: cannot store reference into longer-lived binding; reference value would escape lexical scope")
    (tc_tests.compiler-typecheck-error-ok?
      "(define (main [x : i64] [items : (__tl_dyn-array (& x i64))]) : unit
  (let [x : i64 1] (set! (array-ref items 0) (& x))))"
      "typecheck: cannot store reference into longer-lived array; reference value would escape lexical scope")
    (tc_tests.compiler-typecheck-ok?
      "(define (main [x : i64] [items : (__tl_dyn-array (& x i64))]) : unit
  (__tl_array-push! items (& x)))")
    (tc_tests.compiler-typecheck-error-ok?
      "(define (main [x : i64] [items : (__tl_dyn-array (& x i64))]) : unit
  (let [x : i64 1] (__tl_array-push! items (& x))))"
      "typecheck: cannot store reference into longer-lived array; reference value would escape lexical scope")
    (tc_tests.compiler-typecheck-error-ok?
      (tc_tests.compiler-typecheck-with-alloc-string-helper-source
        "(define (main [items : (__tl_dyn-array (& r str))]) : unit
  (with-arena r
    (let [s : String (string.int->string 1)]
      (set! (array-ref items 0) (& s)))))")
      "typecheck: cannot store reference into longer-lived array; reference value would escape lexical scope")
    (tc_tests.compiler-typecheck-error-ok?
      "(define (main [x : i64]) : (-> unit)
  (let
    [r : (& x i64) (& x)]
    (lambda () : unit (let [copy : (& x i64) r] unit))))"
      "typecheck: lambda cannot capture immutable reference; reference value would escape lexical scope")
    (compiler-typecheck-reference-lambda-capture-tests-ok?)
    (compiler-typecheck-closure-copy-tests-ok?)
    (compiler-typecheck-reference-return-container-tests-ok?)
    (compiler-typecheck-reference-dyn-array-tests-ok?)
    (compiler-typecheck-signature-lifetime-alias-tests-ok?)
    (compiler-typecheck-bytes-referent-tests-ok?)))

(define (compiler-typecheck-macro-alias-cache-collision-ok?) : bool
  (let
    [macro-state : tc_core.TcMacroState
      (tc_core.tc-job-state-macro-state (tc_core.tc-serial-job-state))]
    (begin
      (tc_core.macro-alias-derived-cache-reset-for-state! macro-state)
      (tc_core.macro-alias-cache-ensure! macro-state)
      (tc_core.macro-alias-cache-put! macro-state 1 (ci.intern-capacity) 11)
      (tc_core.macro-alias-cache-put! macro-state 2 0 22)
      (tc_core.macro-alias-cache-put! macro-state 3 1 -1)
      (tc_core.macro-alias-cache-put! macro-state 3 1 33)
      (tc_core.macro-alias-cache-put! macro-state 4 2 2)
      (tc_core.macro-alias-cache-put! macro-state 4 2 44)
      (tc_core.macro-alias-cache-put! macro-state 5 3 3)
      (tc_core.macro-alias-cache-put! macro-state 5 3 -3)
      (tc_core.macro-alias-cache-put! macro-state 6 4 4)
      (tc_core.macro-alias-cache-put! macro-state 6 4 -3)
      (tc_core.macro-alias-cache-put! macro-state 6 4 66)
      (and
        (=
          (tc_core.macro-alias-cache-get macro-state 1 (ci.intern-capacity))
          11)
        (= (tc_core.macro-alias-cache-get macro-state 2 0) 22)
        (= (tc_core.macro-alias-cache-get macro-state 3 1) 33)
        (= (tc_core.macro-alias-cache-get macro-state 4 2) 44)
        (= (tc_core.macro-alias-cache-get macro-state 5 3) -3)
        (= (tc_core.macro-alias-cache-get macro-state 6 4) 66)))))

(define (compiler-typecheck-smoke-module-macro-import-evaluated-key-source) : String
  "(defmacro (gen [key : String]) : Module
  `(begin
    (module generated.module)
    (define (answer) : i64 42)))
(import (gen \"same\"))
(import (gen (if true \"same\" \"other\")))
(define (main) : i64 (answer))")

(define (compiler-typecheck-smoke-comptime-error-tests-ok?) : bool
  (and
    (tc_tests.compiler-typecheck-error-ok?
      "(import stdlib.comptime)
(defmacro (badexpr [x : Expr]) : i64
  (comptime.error \"custom expression macro failure\"))
(define (main) : i64
  (badexpr 42))"
      "custom expression macro failure")
    (tc_tests.compiler-typecheck-error-ok?
      "(import stdlib.comptime)
(defmacro (badmod [key : String]) : Module
  (comptime.error \"custom module macro failure\"))
(import (badmod \"x\") as bad)
(define (main) : i64 0)"
      "custom module macro failure")
    (tc_tests.compiler-typecheck-error-ok?
      "(import stdlib.comptime)
(defmacro (baddecls) : Decls
  (comptime.error \"custom decl macro failure\"))
(baddecls)
(define (main) : i64 0)"
      "custom decl macro failure")))

(define (compiler-typecheck-smoke-regalloc-heapsort-macro-source
  [invocation : String]
  [tail : String]) : String
  (str_cat.str-cat
    (byte_buf.to-string (io.read-file "src/compiler_regalloc_interval_sort.tl"))
    "\n(import stdlib.comptime)\n
(defstruct Interval (var i64) (start i64) (end i64))\n
(defmacro (shared [place : Expr]) : Expr\n
  `(unsafe (ptr-read (ptr-addr-of ,place))))\n"
    invocation
    tail))

(define (compiler-typecheck-smoke-regalloc-heapsort-macro-error-source
  [invocation : String]) : String
  (compiler-typecheck-smoke-regalloc-heapsort-macro-source
    invocation
    "(define (main) : i64 42)"))

(define (compiler-typecheck-smoke-regalloc-heapsort-macro-tests-ok?) : bool
  (and
    (tc_tests.compiler-typecheck-ok?
      (compiler-typecheck-smoke-regalloc-heapsort-macro-source
        "(compiler-reg-interval-heapsort\n
  Interval candidate-before candidate-copy shared candidate-sift candidate-sort\n
  full-array candidate-start-end-var)\n
(compiler-reg-interval-heapsort\n
  Interval range-before range-copy shared range-sift range-sort\n
  range color-start-var)\n"
        "(define (main) : i64\n
  (let [items : (__tl_dyn-array Interval) (__tl_make-array Interval 2)]\n
    (begin\n
      (candidate-sort (shared items) 2)\n
      (range-sort items 0 2)\n
      42)))"))
    (tc_tests.compiler-typecheck-error-ok?
      (compiler-typecheck-smoke-regalloc-heapsort-macro-error-source
        "(compiler-reg-interval-heapsort\n
  Interval (bad-comparator) copy shared sift sort full-array candidate-start-end-var)\n")
      "compiler-reg-interval-heapsort: comparator must be a bare name")
    (tc_tests.compiler-typecheck-error-ok?
      (compiler-typecheck-smoke-regalloc-heapsort-macro-error-source
        "(compiler-reg-interval-heapsort\n
  Interval before 42 shared sift sort full-array candidate-start-end-var)\n")
      "compiler-reg-interval-heapsort: copy declaration must be a bare name")
    (tc_tests.compiler-typecheck-error-ok?
      (compiler-typecheck-smoke-regalloc-heapsort-macro-error-source
        "(compiler-reg-interval-heapsort\n
  Interval before copy shared sift sort unknown-shape candidate-start-end-var)\n")
      "compiler-reg-interval-heapsort: shape must be `full-array` or `range`")
    (tc_tests.compiler-typecheck-error-ok?
      (compiler-typecheck-smoke-regalloc-heapsort-macro-error-source
        "(compiler-reg-interval-heapsort\n
  Interval before copy shared sift sort full-array unknown-order)\n")
      "compiler-reg-interval-heapsort: ordering must be `candidate-start-end-var` or `color-start-var`")))

(define (compiler-typecheck-smoke-require [ok : bool] [name : String]) : bool
  (if ok
    true
    (io.panic name)))

(define (compiler-typecheck-smoke-module-macro-identity-tests-ok?) : bool
  (and
    (compiler-typecheck-smoke-require
      (tc_tests.compiler-typecheck-ok?
        (compiler-typecheck-smoke-module-macro-import-evaluated-key-source))
      "typecheck: module macro identity import evaluated key failed")
    (compiler-typecheck-smoke-require
      (tc_tests.compiler-typecheck-error-ok?
        "(import stdlib.comptime)
(defmacro (gen [key : Expr]) : Module
  (match key
    [(Expr.Call _ _)
      `(begin
      (module generated.module)
      (define (answer) : i64 99))]
    [_
      `(begin
      (module generated.module)
      (define (answer) : i64 42))]))
(defmacro (later) : Decls
  `(import (gen (type-key (type i64)))))
(import (gen \"i64\"))
(later)
(define (main) : i64 (answer))"
        "typecheck: Module macro output for generated identity :gen(string_3_105_54_52) has incompatible payload")
      "typecheck: module macro identity import incompatible key failed")
    (compiler-typecheck-smoke-require
      (tc_tests.compiler-typecheck-error-ok?
        "(defmacro (gen-a [key : String]) : Module
  `(begin
    (module generated.a)
    (define (answer) : i64 42)))
(defmacro (gen-b [key : String]) : Module
  `(begin
    (module generated.b)
    (define (answer) : i64 99)))
(import (gen-a \"a\"))
(import (gen-b \"b\"))
(define (main) : i64 (answer))"
        "typecheck: ambiguous unqualified import for value answer between modules generated.a and generated.b; use an explicit alias or qualified access")
      "typecheck: module macro identity generated collision failed")
    (compiler-typecheck-smoke-require
      (tc_tests.compiler-typecheck-ok?
        "(defmacro (gen-a [key : String]) : Module
  `(begin
    (module generated.a)
    (define (answer) : i64 42)))
(defmacro (gen-b [key : String]) : Module
  `(begin
    (module generated.b)
    (define (answer) : i64 99)))
(import (gen-a \"a\"))
(import (gen-b \"b\"))
(define (answer) : i64 7)
(define (main) : i64 (answer))")
      "typecheck: module macro identity generated local shadow failed")
    (compiler-typecheck-smoke-require
      (tc_tests.compiler-typecheck-ok?
        "(defmacro (gen [key : String]) : Module
  `(begin
    (module generated.module)
    (define (answer) : i64 42)))
(define (answer) : i64 0)
(import (gen \"x\"))
(define (main) : i64 (answer))")
      "typecheck: module macro identity local collision failed")
    (compiler-typecheck-smoke-require
      (tc_tests.compiler-typecheck-ok?
        "(import stdlib.comptime)
(defstruct Pair (value i64))
(defstruct Other (value i64))
(defmacro (boxmod [T : type]) : Module
  (let
    [mod-name : Expr (expr-var (type-key T))]
    `(begin
      (module ,mod-name)
      (defstruct Boxed (value ,T))
      (define (make [value : ,T]) : Boxed (Boxed value))
      (define (read [box : Boxed]) : ,T box.value))))
(import (boxmod i64) as bi)
(import (boxmod i64) as bi2)
(import (boxmod String) as bs)
(import (boxmod (-> i64 i64)) as bf)
(import (boxmod Pair) as bp)
(import (boxmod Pair) as bp2)
(import (boxmod Other) as bo)
(define (main) : i64
  (let
    [first : Pair (bp.read (bp.make (Pair 7)))]
    [second : Pair (bp2.read (bp2.make (Pair 8)))]
    [other : Other (bo.read (bo.make (Other 9)))]
    (+ (bi.read (bi.make 20))
      (+ (bi2.read (bi2.make 1))
        (+ (__tl_string_length (bs.read (bs.make \"typed\")))
          (+ first.value (+ second.value other.value)))))))")
      "typecheck: module macro identity type key failed")
    (compiler-typecheck-smoke-require
      (tc_tests.compiler-typecheck-ok?
        "(defmacro (vector [T : type]) : Module
  `(begin
    (module generated.vector)
    (define (id [value : ,T]) : ,T value)))
(defmacro (uses-vector) : Module
  `(begin
    (module generated.usesvec)
    (import (vector i64) as v)
    (define (answer) : i64
      (v.id 42))))
(import (uses-vector) as uv)
(define (main) : i64 (uv.answer))")
      "typecheck: module macro identity nested vector import failed")
    (compiler-typecheck-smoke-require
      (tc_tests.compiler-typecheck-ok?
        "(import stdlib.vector)
(defmacro (vector-user) : Module
  `(begin
    (module generated.local_type_vector_user)
    (defstruct T
      (value i64))
    (import (stdlib.vector.vector T) as vec)
    (define (make [value : i64]) : T
      (T value))
    (define (score [value : T]) : i64
      (let
        [items : vec.Vec (vec.new)]
        (begin
          (vec.push-ref! (&mut items) value)
          (let [item : T (vec.get (& items) 0 (T 0))] item.value))))))
(import (vector-user) as user)
(define (main) : i64
  (user.score (user.make 42)))")
      "typecheck: module macro identity local type stdlib vector failed")
    (compiler-typecheck-smoke-require
      (tc_tests.compiler-typecheck-ok?
        "(import stdlib.vector)
(defmacro (type-provider) : Module
  `(begin
    (module generated.qualified_type_vector_provider)
    (defstruct T
      (value i64))))
(defmacro (vector-user) : Module
  `(begin
    (module generated.qualified_type_vector_user)
    (import (type-provider) as provider)
    (import (stdlib.vector.vector provider.T) as vec)
    (define (make [value : i64]) : provider.T
      (provider.T value))
    (define (score [value : provider.T]) : i64
      (let
        [items : vec.Vec (vec.new)]
        (begin
          (vec.push-ref! (&mut items) value)
          (let
            [item : provider.T (vec.get (& items) 0 (provider.T 0))]
            item.value))))))
(import (vector-user) as user)
(define (main) : i64
  (user.score (user.make 42)))")
      "typecheck: module macro identity qualified type stdlib vector failed")
    (compiler-typecheck-smoke-require
      (tc_tests.compiler-typecheck-ok?
        "(import stdlib.vector)
(defstruct Pair
  (value i64))
(defmacro (vector-user [T : type]) : Module
  `(begin
    (module generated.param_type_vector_user)
    (import (stdlib.vector.vector ,T) as vec)
    (define (score [value : ,T]) : i64
      (let
        [items : vec.Vec (vec.new)]
        (begin
          (vec.push-ref! (&mut items) value)
          (vec.len (& items)))))))
(import (vector-user Pair) as user)
(define (main) : i64
  (user.score (Pair 42)))")
      "typecheck: module macro identity param type stdlib vector failed")
    (compiler-typecheck-smoke-require
      (tc_tests.compiler-typecheck-ok?
        "(defstruct Pair
  (value i64))
(defmacro (vector-user [T : type]) : Module
  `(begin
    (module generated.local_import_param_vector_user)
    (import stdlib.vector)
(import (vector.vector String) as svec)
    (import (vector.vector ,T) as vec)
    (define (score [value : ,T]) : i64
      (let
        [items : vec.Vec (vec.new)]
        (begin
          (vec.push-ref! (&mut items) value)
          (vec.len (& items)))))))
(import (vector-user Pair) as user)
(define (main) : i64
  (user.score (Pair 42)))")
      "typecheck: module macro identity local import param vector failed")
    (compiler-typecheck-smoke-require
      (tc_tests.compiler-typecheck-ok?
        "(import stdlib.json)
(import stdlib.vector)
(defmacro (json-vector-user) : Module
  `(begin
    (module generated.json_vector_user)
    (import (vector.vector json.Json core) as jvec)
    (define (score) : i64
      (let
        [items : jvec.Vec (jvec.new)]
        (jvec.len (& items))))))
(import (json-vector-user) as user)
(define (main) : i64
  (user.score))")
      "typecheck: module macro identity imported aggregate stdlib vector failed")
    (compiler-typecheck-smoke-require
      (tc_tests.compiler-typecheck-ok?
        "(import stdlib.json)
(defmacro (json-user) : Module
  `(begin
    (module generated.json_nested_payload_user)
    (import stdlib.json as json)
    (define (score [value : json.Json]) : i64
      (match (json.object-get-owned value \"zip\")
        [(json.JsonFound __json_value)
          (match __json_value
            [(json.JsonNumber text) (__tl_string_length text)]
            [_ 0])]
        [(json.JsonMissing) 0]))))
(import (json-user) as user)
(define (main) : i64
  (user.score
    (json.JsonObject
      (box
        (json.member-cons
          \"zip\"
          (json.JsonNumber \"42\")
          (json.member-list-empty))))))")
      "typecheck: module macro identity generated import nested enum payload failed")
    (compiler-typecheck-smoke-require
      (tc_tests.compiler-typecheck-ok?
        "(defstruct InitAddress
  (zip i64)
  (city String))
(defstruct InitPerson
  (home InitAddress))
(defmacro (init-user [T : type]) : Module
  `(begin
    (module generated.init_nested_root)
    (define (make) : ,T
      (init : ,T))))
(import (init-user InitPerson) as init_user)
(define (main) : i64
  (let [person : InitPerson (init_user.make)] person.home.zip))")
      "typecheck: module macro identity generated init nested root failed")
    (compiler-typecheck-smoke-require
      (tc_tests.compiler-typecheck-ok?
        "(defstruct ReplayAddress
  (zip i64))
(defstruct ReplayPerson
  (home ReplayAddress))
(defmacro (replay-leaf [T : type]) : Module
  `(begin
    (module generated.replay_leaf)
    (defenum Result
      (Ok ,T)
      (Err String))
    (define (make) : ,T
      (init : ,T))))
(defmacro (replay-nested [T : type] [index-expr : Expr]) : Decls
  (match index-expr
    [(Expr.Int index)
      (if (>= index (struct-field-count T))
        `(begin)
        (let
          [field-type : Expr (struct-field-type T index)]
          [field-kind : String (type-kind field-type)]
          [next-index : Expr (expr-int (+ index 1))]
          (match field-kind
            [\"struct\"
              `(begin
                (replay-nested ,T ,next-index)
                (import (replay-leaf ,field-type) as nested))]
            [_ `(replay-nested ,T ,next-index)])))]
    [_ `(begin)]))
(defmacro (replay-user [T : type]) : Module
  `(begin
    (module generated.replay_user)
    (replay-nested ,T 0)
    (define (answer) : i64 42)))
(import (replay-leaf ReplayAddress) as address_leaf)
(import (replay-user ReplayPerson) as replay_user)
(define (main) : i64
  (replay_user.answer))")
      "typecheck: module macro identity generated replay normalized failed")
    (compiler-typecheck-smoke-require
      (tc_tests.compiler-typecheck-ok?
        "(module toy.format)
(defmacro (emit-i64 [value : i64]) : i64
  `(+ ,value 1))
(module app)
(import toy.format as fmt)
(defmacro (make [format : Module]) : Module
  (let
    [emit : Expr (module-hook format \"emit-i64\")]
    `(begin
      (module generated.strategy_alias)
      (define (answer) : i64 (,emit 41)))))
(import (make fmt) as gen)
(define (main) : i64 (gen.answer))")
      "typecheck: module macro identity strategy alias failed")
    (compiler-typecheck-smoke-require
      (tc_tests.compiler-typecheck-ok?
        "(module toy.format)
(defmacro (emit-i64 [value : i64]) : i64
  `(+ ,value 1))
(module app)
(import toy.format)
(import toy.format as fmt)
(defmacro (make [format : Module]) : Module
  (let
    [emit : Expr (module-hook format \"emit-i64\")]
    `(begin
      (module generated.strategy_dedup)
      (define (answer) : i64 (,emit 41)))))
(import (make fmt) as a)
(import (make toy.format) as b)
(define (main) : i64 (+ (a.answer) (b.answer)))")
      "typecheck: module macro identity strategy dedup failed")
    (compiler-typecheck-smoke-require
      (tc_tests.compiler-typecheck-error-ok?
        "(module toy.empty)
(define (marker) : i64 0)
(module app)
(import toy.empty as fmt)
(defmacro (make [format : Module]) : Module
  (let
    [emit : Expr (module-hook format \"emit-i64\")]
    `(begin
      (module generated.strategy_missing_hook)
      (define (answer) : i64 (,emit 41)))))
(import (make fmt) as gen)
(define (main) : i64 (gen.answer))"
        "typecheck: strategy module toy.empty does not export hook emit-i64")
      "typecheck: module macro identity strategy missing hook failed")
    (compiler-typecheck-smoke-require
      (tc_tests.compiler-typecheck-error-ok?
        "(defmacro (make [format : Module]) : Module
  `(begin
    (module generated.strategy_unresolved)
    (define (answer) : i64 0)))
(import (make missing) as gen)
(define (main) : i64 (gen.answer))"
        "typecheck: unknown module strategy missing; import the module or use a visible dotted module alias")
      "typecheck: module macro identity strategy unresolved failed")
    (compiler-typecheck-smoke-require
      (tc_tests.compiler-typecheck-ok?
        "(module generated.strategy_vector_hook_app)
(import stdlib.comptime)
(import stdlib.vector)
(defmacro (make [factory : Module]) : Module
  (let
    [vector-macro : Expr (module-hook factory \"vector\")]
    `(begin
      (module generated.strategy_vector_hook)
      (defstruct T
        (value i64))
      (import (,vector-macro T) as vec)
      (define (make [value : i64]) : T
        (T value))
      (define (score [value : T]) : i64
        (let
          [items : vec.Vec (vec.new)]
          (begin
            (vec.push-ref! (&mut items) value)
            (let [item : T (vec.get (& items) 0 (T 0))] item.value)))))))
(import (make vector) as gen)
(define (main) : i64
  (gen.score (gen.make 42)))")
      "typecheck: module macro identity strategy vector hook failed")
    (compiler-typecheck-smoke-require
      (tc_tests.compiler-typecheck-ok?
        "(defmacro (base [key : String]) : Module
  `(begin
    (module generated.shared)
    (define (answer) : i64 40)))
(defmacro (extra [key : String]) : Module
  `(begin
    (module generated.shared)
    (define (bonus) : i64 1)))
(import (base \"same\") as base)
(import (extra \"same\") as extra)
(import (extra \"same\") as extra2)
(define (main) : i64
  (+ (base.answer) (+ (extra.bonus) (extra2.bonus))))")
      "typecheck: module macro identity extension failed")
    (compiler-typecheck-smoke-require
      (tc_tests.compiler-typecheck-error-ok?
        "(import stdlib.comptime)
(defmacro (base [key : String]) : Module
  `(begin
    (module generated.shared)
    (define (answer) : i64 40)))
(defmacro (extra [key : Expr]) : Module
  (match key
    [(Expr.Call _ _)
      `(begin
        (module generated.shared)
        (define (bonus) : i64 2))]
    [_
      `(begin
        (module generated.shared)
        (define (bonus) : i64 1))]))
(import (base \"i64\") as base)
(import (extra \"i64\") as extra)
(import (extra (type-key (type i64))) as extra2)
(define (main) : i64
  (+ (base.answer) (+ (extra.bonus) (extra2.bonus))))"
        "typecheck: Module macro output for generated identity :extra(string_3_105_54_52) has incompatible payload")
      "typecheck: module macro identity extension incompatible failed")))

;; Declaration-emitting macros must be able to emit functions with non-trivial
;; bodies. The macro-output serializer round-trips arithmetic,
;; dotted fields, __tl_make-array, array-ref/set!, let, while,
;; and set! back to
;; declarations; before that surface existed these fixtures failed with
;; "module macro output contains syntax that cannot be parsed as a declaration".
(define (compiler-typecheck-smoke-decls-macro-body-source) : String
  "
(defmacro (int-stack) : Decls
  `(begin
    (defstruct Stack
      (slots (__tl_dyn-array i64))
      (len i64)
      (cap i64))
    (define (stack-new) : Stack
      (Stack (__tl_make-array i64 4) 0 4))
    (define (stack-grow [s : Stack]) : Stack
      (let
        [new-cap : i64 (* s.cap 2)]
        [bigger : (__tl_dyn-array i64) (__tl_make-array i64 new-cap)]
        [i : i64 0]
        (begin
          (while (< i s.len)
            (begin
              (set! (array-ref bigger i) (array-ref s.slots i))
              (set! i (+ i 1))))
          (Stack bigger s.len new-cap))))
    (define (stack-push [s : Stack] [value : i64]) : Stack
      (if (< s.len s.cap)
        (begin
          (set! (array-ref s.slots s.len) value)
          (Stack s.slots (+ s.len 1) s.cap))
        (stack-push (stack-grow s) value)))
    (define (stack-top [s : Stack]) : i64
      (array-ref s.slots (- s.len 1)))
    (define (stack-fixed-array-probe) : i64
      (let
        [items : (Array i64 3) (array 11 22 33)]
        (array-ref items 1)))
    (define (stack-never-probe [x : i64]) : i64
      (ann (return x) : never))))
(int-stack)
(define (main) : i64 (stack-top (stack-push (stack-push (stack-new) 7) 42)))")

(define (compiler-typecheck-smoke-type-macro-param-tests-ok?) : bool
  (tc_tests.compiler-typecheck-ok?
    "
(defstruct Pair (value i64))
(defmacro (emit-pair [T : type]) : Decls
  `(begin
    (define (typed-id [v : ,T]) : ,T
      (let [x : ,T v] (ann x : ,T)))
    (define (typed-init) : ,T (init : ,T))
    (define (typed-array [v : ,T]) : (__tl_dyn-array ,T)
      (let [items : (__tl_dyn-array ,T) (__tl_make-array ,T 1)]
        (begin
          (set! (array-ref items 0) v)
          items)))))
(defmacro (emit-cast [T : type]) : Decls
  `(define (typed-cast [v : i64]) : ,T (cast v : ,T)))
(emit-pair Pair)
(emit-cast i64)
(define (main) : i64
  (let [pair : Pair (typed-id (Pair 41))]
    (+ (typed-cast 1) pair.value)))"))

(define (compiler-typecheck-smoke-decls-macro-generated-incompatible-diag-ok?) : bool
  (match (tc_api.typecheck-compiler-source
    "(import stdlib.comptime)
(defmacro (bundle [key : Expr]) : Decls
  (match key
    [(Expr.Call _ _)
      `(defstruct BundleBox (value i64))]
    [_
      `(defstruct BundleBox (value String))]))
(bundle \"i64\")
(bundle (type-key (type i64)))
(define (main) : i64 0)")
    [(tc_core.ResultCompilerTypecheck.Ok _) false]
    [(tc_core.ResultCompilerTypecheck.Err diag)
      (let
        [value : diagnostic.CompilerDiagnostic
          (diagnostic.compiler-diagnostic-list-first
            (diagnostic.compiler-diagnostic-list-box-shared-view diag))]
        [notes : diagnostic.CompilerDiagnosticNoteList
          (diagnostic.compiler-diagnostic-notes value)]
        (and
          (string.eq
            (diagnostic.compiler-diagnostic-message value)
            "generated-decl: duplicate generated key for BundleBox has incompatible payload")
          (= (diagnostic.compiler-diagnostic-line value) 9)
          (= (diagnostic.compiler-diagnostic-col value) 1)
          (= (diagnostic.compiler-diagnostic-note-list-count notes) 2)
          (tc_core.tc-string-prefix?
            (diagnostic.compiler-diagnostic-note-list-get notes 0)
            "generated identity: decls:")
          (string.eq
            (diagnostic.compiler-diagnostic-note-list-get notes 1)
            "conflicting generated item: BundleBox")))]))

(define (compiler-typecheck-smoke-decls-macro-generated-tests-ok?) : bool
  (and
    (tc_tests.compiler-typecheck-ok?
      "(defmacro (bundle [T : type] [version : String]) : Decls
  `(begin
    (defstruct BundleBox (value ,T))
    (defenum BundleMaybe (BundleNone) (BundleSome ,T))
    (define (bundle-score [value : BundleMaybe]) : i64 1)))
(bundle String \"v1\")
(bundle String \"v1\")
(define (main) : i64 (bundle-score (BundleSome \"x\")))")
    (compiler-typecheck-smoke-decls-macro-generated-incompatible-diag-ok?)
    (tc_tests.compiler-typecheck-ok?
      "(module bundle.family)
(defmacro (bundle [version : String]) : Decls
  `(begin
    (defstruct BundleBox (value String))
    (defenum BundleMaybe (BundleNone) (BundleSome String))))
(bundle \"v1\")
(module app)
(module bundle.family)
(bundle \"v1\")")
    (tc_tests.compiler-typecheck-ok?
      "(defmacro (box-family [T : type] [box-name : Expr] [ctor-name : Expr]) : Decls
  `(begin
    (defstruct ,box-name (value ,T))
    (define (,ctor-name [value : ,T]) : ,box-name
      (,box-name value))))
(box-family i64 IntBox int-box)
(box-family i64 IntBox int-box)
(define (main) : i64
  (let [boxed : IntBox (int-box 42)] boxed.value))")
    (tc_tests.compiler-typecheck-ok?
      "(module bundle.left)
(defmacro (bundle [version : String]) : Decls
  `(defstruct BundleBox (value String)))
(bundle \"v1\")
(module bundle.right)
(defmacro (bundle [version : String]) : Decls
  `(defstruct BundleBox (value String)))
(bundle \"v1\")")))

(define (compiler-typecheck-smoke-decl-macro-body-tests-ok?) : bool
  (and
    (tc_tests.compiler-typecheck-ok?
      (compiler-typecheck-smoke-decls-macro-body-source))
    (tc_tests.compiler-typecheck-ok?
      "(defmacro (int-box) : Module
  `(begin
    (module generated.intbox)
    (defstruct Box1 (value i64))
    (define (make [value : i64]) : Box1
      (Box1 value))
    (define (bumped [b : Box1]) : i64
      (let [doubled : i64 (* b.value 2)] (+ doubled 1)))))
(import (int-box) as ib)
(define (main) : i64 (ib.bumped (ib.make 20)))")
    (tc_tests.compiler-typecheck-ok?
      "(import stdlib.comptime)
(defstruct Pair (value i64))
(defmacro (vector [T : type]) : Module
  (let
    [module-name : Expr
      (expr-var
        (if (__tl_string_eq (type-key T) \"i64\")
          \"generated.vector.i64\"
          \"generated.vector.Pair\"))]
    `(begin
      (module ,module-name)
      (defstruct Vec (len i64))
      (define (new) : Vec
        (Vec 1))
      (define (len [v : (& v Vec)]) : i64
        v.len))))
(defmacro (sliceish [T : type]) : Module
  (let
    [module-name : Expr
      (expr-var
        (if (__tl_string_eq (type-key T) \"i64\")
          \"generated.sliceish.i64\"
          \"generated.sliceish.Pair\"))]
    `(begin
      (module ,module-name)
      (import (vector ,T) as vec)
      (define (len-of [v : vec.Vec]) : i64
        (vec.len (& v))))))
(import (vector i64) as vec)
(import (sliceish i64) as sliceish)
(import (vector Pair) as pvec)
(import (sliceish Pair) as psliceish)
(define (main) : i64
  (let
    [v : vec.Vec (vec.new)]
    [pv : pvec.Vec (pvec.new)]
    (+ (sliceish.len-of v) (psliceish.len-of pv))))")))

(define (compiler-typecheck-smoke-prefix-cache-cfg-source) : String
  "(cfg feature (define (shared-helper [x : i64]) : i64 (+ x 2)))
(cfg (not feature) (define (shared-helper [x : i64]) : i64 (+ x 1)))
(define (main) : i64 (shared-helper 2))")

(define (compiler-typecheck-smoke-prefix-cache-root-paths
  [root : String]
  [entry-path : String]) : ast.AstDeclPathList
  (ast.ast-decl-root-path-cons
    (load.compiler-load-join-root-path root "tc_prefix_shared.tl")
    (ast.ast-decl-root-path-cons entry-path (ast.ast-decl-path-list-new))))

(define (compiler-typecheck-smoke-prefix-cache-roots [root : String]) : svec.Vec
  (let
    [roots : svec.Vec (svec.new)]
    (begin
      (svec.push-ref! (&mut roots) root)
      roots)))

(define (compiler-typecheck-smoke-prefix-cache-state-isolation-ok?) : bool
  (let
    [state-a : tc_core.TcPrefixSnapshotCacheState
      (tc_core.tc-prefix-snapshot-cache-state-new)]
    [state-b : tc_core.TcPrefixSnapshotCacheState
      (tc_core.tc-prefix-snapshot-cache-state-new)]
    [owner-a : tc_core.TcPrefixSnapshotCacheProvenance
      (tc_core.TcPrefixSnapshotCacheProvenance 101 11 13 17 19 23)]
    [owner-a-reset : tc_core.TcPrefixSnapshotCacheProvenance
      (tc_core.TcPrefixSnapshotCacheProvenance 101 29 31 17 37 41)]
    [owner-b : tc_core.TcPrefixSnapshotCacheProvenance
      (tc_core.TcPrefixSnapshotCacheProvenance 103 43 47 53 59 61)]
    (begin
      (tc_core.tc-prefix-snapshot-cache-prepare-for-job! state-a owner-a)
      (tc_core.tc-prefix-snapshot-cache-prepare-for-job! state-b owner-b)
      (tc_core.tc-prefix-snapshot-cache-enable-for-state! state-a)
      (tc_core.tc-prefix-snapshot-cache-enable-for-state! state-b)
      (tc_core.tc-prefix-snapshot-cache-store-persistent-for-state
        state-a
        "shared-key"
        7
        "state-a"
        71
        (tc_core.CompilerTypecheckSummary 1 2 3))
      (tc_core.tc-prefix-snapshot-cache-store-persistent-for-state
        state-b
        "shared-key"
        11
        "state-b"
        73
        (tc_core.CompilerTypecheckSummary 4 5 6))
      (tc_core.tc-prefix-snapshot-cache-note-hit-for-state! state-a)
      (tc_core.tc-prefix-snapshot-cache-note-miss-for-state! state-a)
      (tc_core.tc-prefix-snapshot-cache-note-hit-for-state! state-b)
      (let
        [b-arena : i64
          (tc_core.tc-prefix-snapshot-cache-arena-value-for-state state-b)]
        [b-hits : i64
          (tc_core.tc-prefix-snapshot-cache-hit-count-for-state state-b)]
        [b-stores : i64
          (tc_core.tc-prefix-snapshot-cache-store-count-for-state state-b)]
        (begin
          ;; Simulate a pool/intern generation reset and retained-arena
          ;; rollover for A. B must retain both its snapshot and metrics.
          (tc_core.tc-prefix-snapshot-cache-prepare-for-job!
            state-a
            owner-a-reset)
          (let
            [rollover-ok : bool
              (and
                (=
                  (tc_core.tc-prefix-snapshot-cache-hit-count-for-state state-a)
                  0)
                (=
                  (tc_core.tc-prefix-snapshot-cache-miss-count-for-state
                    state-a)
                  0)
                (=
                  (tc_core.tc-prefix-snapshot-cache-store-count-for-state
                    state-a)
                  0)
                (=
                  (tc_core.tc-prefix-snapshot-cache-arena-value-for-state
                    state-a)
                  0)
                (match (tc_core.tc-prefix-snapshot-cache-lookup-for-state
                  state-a
                  "shared-key")
                  [(tc_core.TcPrefixSnapshotLookup.Miss) true]
                  [_ false]))]
            (begin
              ;; Teardown of A owns and destroys only A's retained arena.
              (tc_core.tc-prefix-snapshot-cache-invalidate-for-state! state-a)
              (let
                [isolated : bool
                  (and
                    rollover-ok
                    (=
                      (tc_core.tc-prefix-snapshot-cache-arena-value-for-state
                        state-b)
                      b-arena)
                    (=
                      (tc_core.tc-prefix-snapshot-cache-hit-count-for-state
                        state-b)
                      b-hits)
                    (=
                      (tc_core.tc-prefix-snapshot-cache-store-count-for-state
                        state-b)
                      b-stores)
                    (match (tc_core.tc-prefix-snapshot-cache-lookup-for-state
                      state-b
                      "shared-key")
                      [(tc_core.TcPrefixSnapshotLookup.Hit
                          count
                          module
                          module-id
                          summary)
                        (and
                          (= count 11)
                          (string.eq module "state-b")
                          (= module-id 73)
                          (=
                            (tc_api.compiler-typecheck-summary-score summary)
                            654))]
                      [_ false]))]
                (begin
                  (tc_core.tc-prefix-snapshot-cache-invalidate-for-state!
                    state-b)
                  isolated)))))))))

(define (compiler-typecheck-smoke-paths-contain?
  [paths : ast.AstDeclPathList]
  [needle : String]) : bool
  (match (ast.ast-decl-path-list-step paths)
    [(ast.AstDeclPathListStep.Nil) false]
    [(ast.AstDeclPathListStep.Cons path rest)
      (or
        (load.compiler-load-string-contains?
          (load.compiler-load-normalize-path path)
          needle)
        (compiler-typecheck-smoke-paths-contain? rest needle))]))

(define (compiler-typecheck-smoke-prefix-cache-check-cfg
  [src : String]
  [entry-path : String]
  [paths : ast.AstDeclPathList]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : bool
  (match (parser.parse-ast-source-diagnostic-with-cfg entry-path src cfgs)
    [(parser.ResultAstProgramDiagnostic.Ok program)
      (match (tc_api.typecheck-compiler-program-with-paths-cache
        program
        paths
        (tc_core.tc-global-shared-view stdlib-roots)
        cfgs
        (tc_api.compiler-typecheck-prefix-cache-scope
          "typecheck-prefix-smoke"
          stdlib-roots
          cfgs))
        [(tc_core.ResultCompilerTypecheck.Ok _) true]
        [(tc_core.ResultCompilerTypecheck.Err _) false])]
    [(parser.ResultAstProgramDiagnostic.Err _) false]))

(define (compiler-typecheck-smoke-prefix-cache-root-isolation-ok?) : bool
  (let
    [root-a : String "target/tc_prefix_root_a"]
    [root-b : String "target/tc_prefix_root_b"]
    [entry-a : String "target/tc_prefix_root_entry_a.tl"]
    [entry-b : String "target/tc_prefix_root_entry_b.tl"]
    [roots-a : svec.Vec
      (compiler-typecheck-smoke-prefix-cache-roots
        (tc_core.tc-global-shared-view root-a))]
    [roots-b : svec.Vec
      (compiler-typecheck-smoke-prefix-cache-roots
        (tc_core.tc-global-shared-view root-b))]
    [ok : bool true]
    (begin
      (load.compiler-load-session-cache-enable!)
      (tc_core.tc-prefix-snapshot-cache-clear!)
      (if (compiler-typecheck-smoke-prefix-cache-check-cfg
        (tc_tests.compiler-typecheck-prefix-cache-source-a)
        (tc_core.tc-global-shared-view entry-a)
        (compiler-typecheck-smoke-prefix-cache-root-paths root-a entry-a)
        roots-a
        (parser.compiler-cfg-empty))
        unit
        (set! ok false))
      (tc_core.compiler-typecheck-reset-file-state!)
      (if (compiler-typecheck-smoke-prefix-cache-check-cfg
        (tc_tests.compiler-typecheck-prefix-cache-source-b)
        (tc_core.tc-global-shared-view entry-b)
        (compiler-typecheck-smoke-prefix-cache-root-paths
          (tc_core.tc-global-shared-view root-b)
          entry-b)
        (tc_core.tc-global-shared-view roots-b)
        (parser.compiler-cfg-empty))
        unit
        (set! ok false))
      (if (= (tc_core.tc-prefix-snapshot-cache-hit-count-value) 0)
        unit
        (set! ok false))
      (if (>= (tc_core.tc-prefix-snapshot-cache-store-count-value) 2)
        unit
        (set! ok false))
      (tc_core.compiler-typecheck-reset-file-state!)
      (if (compiler-typecheck-smoke-prefix-cache-check-cfg
        (tc_tests.compiler-typecheck-prefix-cache-source-b)
        "target/tc_prefix_root_entry_c.tl"
        (compiler-typecheck-smoke-prefix-cache-root-paths
          root-b
          "target/tc_prefix_root_entry_c.tl")
        roots-b
        (parser.compiler-cfg-empty))
        unit
        (set! ok false))
      (if (> (tc_core.tc-prefix-snapshot-cache-hit-count-value) 0)
        unit
        (set! ok false))
      (load.compiler-load-session-cache-disable-for-test!)
      (tc_core.tc-prefix-snapshot-cache-clear!)
      (tc_api.compiler-typecheck-reset-load-session!)
      ok)))

(define (compiler-typecheck-smoke-prefix-cache-cfg-isolation-ok?) : bool
  (let
    [root : String "target/tc_prefix_cfg_root"]
    [entry-empty : String "target/tc_prefix_cfg_entry_empty.tl"]
    [entry-feature : String "target/tc_prefix_cfg_entry_feature.tl"]
    [roots : svec.Vec
      (compiler-typecheck-smoke-prefix-cache-roots
        (tc_core.tc-global-shared-view root))]
    [ok : bool true]
    (begin
      (load.compiler-load-session-cache-enable!)
      (tc_core.tc-prefix-snapshot-cache-clear!)
      (if (compiler-typecheck-smoke-prefix-cache-check-cfg
        (compiler-typecheck-smoke-prefix-cache-cfg-source)
        (tc_core.tc-global-shared-view entry-empty)
        (compiler-typecheck-smoke-prefix-cache-root-paths
          (tc_core.tc-global-shared-view root)
          entry-empty)
        (tc_core.tc-global-shared-view roots)
        (parser.compiler-cfg-empty))
        unit
        (set! ok false))
      (tc_core.compiler-typecheck-reset-file-state!)
      (if (compiler-typecheck-smoke-prefix-cache-check-cfg
        (compiler-typecheck-smoke-prefix-cache-cfg-source)
        (tc_core.tc-global-shared-view entry-feature)
        (compiler-typecheck-smoke-prefix-cache-root-paths
          (tc_core.tc-global-shared-view root)
          entry-feature)
        (tc_core.tc-global-shared-view roots)
        (parser.compiler-cfg-enable (parser.compiler-cfg-empty) "feature"))
        unit
        (set! ok false))
      (if (= (tc_core.tc-prefix-snapshot-cache-hit-count-value) 0)
        unit
        (set! ok false))
      (if (>= (tc_core.tc-prefix-snapshot-cache-store-count-value) 2)
        unit
        (set! ok false))
      (tc_core.compiler-typecheck-reset-file-state!)
      (if (compiler-typecheck-smoke-prefix-cache-check-cfg
        (compiler-typecheck-smoke-prefix-cache-cfg-source)
        "target/tc_prefix_cfg_entry_feature_b.tl"
        (compiler-typecheck-smoke-prefix-cache-root-paths
          root
          "target/tc_prefix_cfg_entry_feature_b.tl")
        roots
        (parser.compiler-cfg-enable (parser.compiler-cfg-empty) "feature"))
        unit
        (set! ok false))
      (if (> (tc_core.tc-prefix-snapshot-cache-hit-count-value) 0)
        unit
        (set! ok false))
      (load.compiler-load-session-cache-disable-for-test!)
      (tc_core.tc-prefix-snapshot-cache-clear!)
      (tc_api.compiler-typecheck-reset-load-session!)
      ok)))

(define (compiler-typecheck-smoke-prefix-cache-loaded-check
  [loaded : load.ResultCompilerLoadWithPaths]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : bool
  (match loaded
    [(load.ResultCompilerLoadWithPaths.Ok decls paths _ _)
      (match (tc_api.typecheck-compiler-program-with-paths-cache
        (ast.ast-program decls)
        paths
        (tc_core.tc-global-shared-view stdlib-roots)
        cfgs
        (tc_api.compiler-typecheck-prefix-cache-scope
          "typecheck-prefix-smoke"
          stdlib-roots
          cfgs))
        [(tc_core.ResultCompilerTypecheck.Ok _) true]
        [(tc_core.ResultCompilerTypecheck.Err _) false])]
    [(load.ResultCompilerLoadWithPaths.Err _) false]))

(define (compiler-typecheck-smoke-prefix-cache-file-check
  [entry-path : String]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : bool
  (compiler-typecheck-smoke-prefix-cache-loaded-check
    (load.compiler-load-file-with-paths-and-roots-cfg
      entry-path
      (sym_i64_env.sym-i64-empty)
      (tc_core.tc-global-shared-view stdlib-roots)
      cfgs)
    stdlib-roots
    cfgs))

(define (compiler-typecheck-smoke-qualified-macro-kind-list-ok?) : bool
  (let
    [provider : String "target/tc_macro_kind_provider.tl"]
    [entry : String "target/tc_macro_kind_entry.tl"]
    [roots : svec.Vec (svec.new)]
    [cfgs : sym_i64_env.SymI64Env (parser.compiler-cfg-empty)]
    (begin
      (compiler-typecheck-smoke-write-text
        provider
        "(module tc_macro_kind_provider)
(defmacro (emit [T : type (:kind i64 u8 struct)]) : Decls
  `(define (made) : i64 1))
(defmacro (family [T : type (:kind i64 u8 struct)]) : Module
  `(begin
    (module generated.macro_kind.family)
    (define (answer) : i64 41)))")
      (compiler-typecheck-smoke-write-text
        (tc_core.tc-global-shared-view entry)
        "(defstruct Ball (x i64))
(import tc_macro_kind_provider as provider)
(provider.emit Ball)
(import (provider.family Ball) as family)
(define (main) : i64 (+ (made) (family.answer)))")
      (tc_api.compiler-typecheck-reset-load-session!)
      (let
        [ok : bool
          (compiler-typecheck-smoke-prefix-cache-file-check entry roots cfgs)]
        (begin
          (tc_api.compiler-typecheck-reset-load-session!)
          ok)))))

(define (compiler-typecheck-smoke-prefix-cache-local-module-hit-ok?) : bool
  (let
    [dep : String "target/tc_prefix_local_dep.tl"]
    [entry-a : String "target/tc_prefix_local_entry_a.tl"]
    [entry-b : String "target/tc_prefix_local_entry_b.tl"]
    [roots : svec.Vec (svec.new)]
    [cfgs : sym_i64_env.SymI64Env (parser.compiler-cfg-empty)]
    [ok : bool true]
    (begin
      (compiler-typecheck-smoke-write-text
        dep
        "(module tc_prefix_local_dep)
(define (value [x : i64]) : i64 (+ x 1))")
      (compiler-typecheck-smoke-write-text
        (tc_core.tc-global-shared-view entry-a)
        "(import tc_prefix_local_dep as dep)
(define (main) : i64 (dep.value 1))")
      (compiler-typecheck-smoke-write-text
        (tc_core.tc-global-shared-view entry-b)
        "(import tc_prefix_local_dep as dep)
(define (main) : i64 (dep.value 2))")
      (load.compiler-load-session-cache-enable!)
      (tc_core.tc-prefix-snapshot-cache-clear!)
      ;; Load both programs before typechecking so the cache owner floors are
      ;; stable across the store/hit pair. Loading a new persistent program can
      ;; legitimately advance those floors and establish new provenance.
      (let
        [loaded-a : load.ResultCompilerLoadWithPaths
          (load.compiler-load-file-with-paths-and-roots-cfg
            entry-a
            (sym_i64_env.sym-i64-empty)
            (tc_core.tc-global-shared-view roots)
            cfgs)]
        [loaded-b : load.ResultCompilerLoadWithPaths
          (load.compiler-load-file-with-paths-and-roots-cfg
            entry-b
            (sym_i64_env.sym-i64-empty)
            (tc_core.tc-global-shared-view roots)
            cfgs)]
        (begin
          (if (compiler-typecheck-smoke-prefix-cache-loaded-check
            loaded-a
            (tc_core.tc-global-shared-view roots)
            cfgs)
            unit
            (set! ok false))
          (tc_core.compiler-typecheck-reset-file-state!)
          (if (compiler-typecheck-smoke-prefix-cache-loaded-check
            loaded-b
            roots
            cfgs)
            unit
            (set! ok false))
          (if (> (tc_core.tc-prefix-snapshot-cache-hit-count-value) 0)
            unit
            (set! ok false))
          (if (> (tc_core.tc-prefix-snapshot-cache-store-count-value) 0)
            unit
            (set! ok false))))
      (load.compiler-load-session-cache-disable-for-test!)
      (tc_core.tc-prefix-snapshot-cache-clear!)
      (tc_api.compiler-typecheck-reset-load-session!)
      ok)))

(define (compiler-typecheck-smoke-prefix-cache-moduleless-local-ok?) : bool
  (let
    [dep : String "target/tc_prefix_flat_dep.tl"]
    [entry-a : String "target/tc_prefix_flat_entry_a.tl"]
    [entry-b : String "target/tc_prefix_flat_entry_b.tl"]
    [roots : svec.Vec (svec.new)]
    [cfgs : sym_i64_env.SymI64Env (parser.compiler-cfg-empty)]
    [ok : bool true]
    (begin
      (compiler-typecheck-smoke-write-text
        dep
        "(define (flat-helper [x : i64]) : i64 (+ x 1))")
      (compiler-typecheck-smoke-write-text
        (tc_core.tc-global-shared-view entry-a)
        "(import tc_prefix_flat_dep)
(define (main) : i64 (tc_prefix_flat_dep.flat-helper 1))")
      (compiler-typecheck-smoke-write-text
        (tc_core.tc-global-shared-view entry-b)
        "(import tc_prefix_flat_dep)
(define (main) : i64 (tc_prefix_flat_dep.flat-helper 2))")
      (load.compiler-load-session-cache-enable!)
      (tc_core.tc-prefix-snapshot-cache-clear!)
      (let
        [loaded-a : load.ResultCompilerLoadWithPaths
          (load.compiler-load-file-with-paths-and-roots-cfg
            entry-a
            (sym_i64_env.sym-i64-empty)
            (tc_core.tc-global-shared-view roots)
            cfgs)]
        [loaded-b : load.ResultCompilerLoadWithPaths
          (load.compiler-load-file-with-paths-and-roots-cfg
            entry-b
            (sym_i64_env.sym-i64-empty)
            (tc_core.tc-global-shared-view roots)
            cfgs)]
        (begin
          (if (compiler-typecheck-smoke-prefix-cache-loaded-check
            loaded-a
            (tc_core.tc-global-shared-view roots)
            cfgs)
            unit
            (set! ok false))
          (tc_core.compiler-typecheck-reset-file-state!)
          (if (compiler-typecheck-smoke-prefix-cache-loaded-check
            loaded-b
            roots
            cfgs)
            unit
            (set! ok false))))
      (load.compiler-load-session-cache-disable-for-test!)
      (tc_core.tc-prefix-snapshot-cache-clear!)
      (tc_api.compiler-typecheck-reset-load-session!)
      ok)))

(define (compiler-typecheck-smoke-generated-moduleless-import-order-ok?) : bool
  (let
    [root-provider : String "target/tc_4004_root_provider.tl"]
    [named-provider : String "target/tc_4004_named_provider.tl"]
    [root-then-named : String "target/tc_4004_root_then_named.tl"]
    [named-then-root : String "target/tc_4004_named_then_root.tl"]
    [roots : svec.Vec (svec.new)]
    [cfgs : sym_i64_env.SymI64Env (parser.compiler-cfg-empty)]
    [ok : bool true]
    (begin
      (compiler-typecheck-smoke-write-text
        root-provider
        "(import stdlib.option)
(import (stdlib.option.option i64) as option_i64)

(define (root-score) : i64
  (option_i64.value-or (option_i64.some 1) 0))")
      (compiler-typecheck-smoke-write-text
        named-provider
        "(module tc_4004_named_provider)
(import stdlib.option)
(import (stdlib.option.option i64) as option_i64)

(define (named-score) : i64
  (option_i64.value-or (option_i64.some 2) 0))")
      (compiler-typecheck-smoke-write-text
        (tc_core.tc-global-shared-view root-then-named)
        "(import tc_4004_root_provider)
(import tc_4004_named_provider)

(define (main) : i64
  (+ (tc_4004_root_provider.root-score) (tc_4004_named_provider.named-score)))")
      (compiler-typecheck-smoke-write-text
        (tc_core.tc-global-shared-view named-then-root)
        "(import tc_4004_named_provider)
(import tc_4004_root_provider)

(define (main) : i64
  (+ (tc_4004_root_provider.root-score) (tc_4004_named_provider.named-score)))")
      (tc_api.compiler-typecheck-reset-load-session!)
      (if (compiler-typecheck-smoke-prefix-cache-file-check
        root-then-named
        (tc_core.tc-global-shared-view roots)
        cfgs)
        unit
        (set! ok false))
      (tc_api.compiler-typecheck-reset-load-session!)
      (if (compiler-typecheck-smoke-prefix-cache-file-check
        named-then-root
        roots
        cfgs)
        unit
        (set! ok false))
      ok)))

(defstruct CompilerTypecheckGeneratedImportStateSnapshot
  (diagnostic String)
  (cache-hits i64)
  (cache-misses i64)
  (cache-stores i64)
  (seen-nonempty bool)
  (surface-summary-present bool))

(define (compiler-typecheck-smoke-generated-type-param-pool-isolation-ok?) : bool
  (let
    [active-before : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    [source-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 4 4)]
    [installed-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 4 4)]
    [name-id : i64 (ci.intern "generated-type-param-pool-isolation")]
    [env : ctfe.CtfeEnv
      (ctfe.ctfe-env-extend-id
        (ctfe.ctfe-env-empty-with-pools
          (ast.ast-node-pool-context-shared-view (& source-pools)))
        name-id
        (ctfe.CompilerCtfeValue.Type (ast.AstType.I64)))]
    [installed-type-id : i64
      (ast.ast-node-pool-context-type-push
        (ast.ast-node-pool-context-shared-view (& installed-pools))
        (ast.AstType.Bool))]
    [installed-expr-id : i64
      (ast.ast-node-pool-context-expr-push
        (ast.ast-node-pool-context-shared-view (& installed-pools))
        (ast.AstExpr.Literal (ast.AstLiteral.Bool false)))]
    (begin
      (ast.ast-node-pool-context-install!
        (ast.ast-node-pool-context-shared-view (& installed-pools)))
      (let
        [result-id : i64
          (tc_core.macro-generated-type-param-expr
            (ast.ast-node-pool-context-shared-view (& source-pools))
            env
            (ast.AstExpr.Var name-id))]
        [installed-expr-bases : i64
          (ast.ast-node-pool-context-expr-segment-bases (& installed-pools))]
        [installed-type-bases : i64
          (ast.ast-node-pool-context-type-segment-bases (& installed-pools))]
        [active-after : ast.AstNodePoolContext
          (ast.ast-node-pool-context-capture-active)]
        [ok : bool
          (and
            (= result-id installed-expr-id)
            (=
              (ast.ast-node-pool-context-expr-len
                (ast.ast-node-pool-context-shared-view (& source-pools)))
              1)
            (=
              (ast.ast-node-pool-context-type-len
                (ast.ast-node-pool-context-shared-view (& source-pools)))
              1)
            (=
              (ast.ast-node-pool-context-expr-len
                (ast.ast-node-pool-context-shared-view (& installed-pools)))
              1)
            (=
              (ast.ast-node-pool-context-type-len
                (ast.ast-node-pool-context-shared-view (& installed-pools)))
              1)
            (match (ast.ast-node-pool-context-expr-get
              (& source-pools)
              result-id)
              [(ast.AstExpr.TypeLiteral source-type-id)
                (and
                  (= source-type-id installed-type-id)
                  (match (ast.ast-node-pool-context-type-get
                    (& source-pools)
                    source-type-id)
                    [(ast.AstType.I64) true]
                    [_ false]))]
              [_ false])
            (match (ast.ast-node-pool-context-expr-get
              (& installed-pools)
              installed-expr-id)
              [(ast.AstExpr.Literal (ast.AstLiteral.Bool value)) (not value)]
              [_ false])
            (match (ast.ast-node-pool-context-type-get
              (& installed-pools)
              installed-type-id)
              [(ast.AstType.Bool) true]
              [_ false])
            (=
              (ast.ast-node-pool-active-expr-segment-bases)
              installed-expr-bases)
            (=
              (ast.ast-node-pool-context-type-segment-bases (& active-after))
              installed-type-bases))]
        (begin
          (ast.ast-node-pool-context-install! active-before)
          ok)))))

(define (compiler-typecheck-smoke-type-resolution-pool-isolation-ok?) : bool
  (let
    [active-before : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    [installed-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 4 4)]
    [owned-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 4 4)]
    [installed-child : i64
      (ast.ast-node-pool-context-type-push
        (ast.ast-node-pool-context-shared-view (& installed-pools))
        (ast.AstType.I64))]
    [installed-parent : i64
      (ast.ast-node-pool-context-type-push
        (ast.ast-node-pool-context-shared-view (& installed-pools))
        (ast.AstType.Array installed-child 3))]
    [name-id : i64 (ci.intern "Expr")]
    [owned-child : i64
      (ast.ast-node-pool-context-type-push
        (ast.ast-node-pool-context-shared-view (& owned-pools))
        (ast.AstType.Var name-id))]
    [owned-parent : i64
      (ast.ast-node-pool-context-type-push
        (ast.ast-node-pool-context-shared-view (& owned-pools))
        (ast.AstType.Array owned-child 3))]
    [ctx : tc_core.TcContext
      (tc_core.tc-context-new
        (ast.ast-program (ast.ast-decl-list-new))
        (compiler_symbols.compiler-symbols-empty)
        (compiler_symbols.compiler-registries-empty)
        ""
        cbi.compiler-builtin-id-fix-empty
        (ast.ast-node-pool-context-shared-view (& owned-pools)))]
    [installed-ctx : tc_core.TcContext
      (tc_core.tc-context-new
        (ast.ast-program (ast.ast-decl-list-new))
        (compiler_symbols.compiler-symbols-empty)
        (compiler_symbols.compiler-registries-empty)
        ""
        cbi.compiler-builtin-id-fix-empty
        (ast.ast-node-pool-context-shared-view (& installed-pools)))]
    (begin
      (ast.ast-node-pool-context-install!
        (ast.ast-node-pool-context-shared-view (& installed-pools)))
      ;; The same numeric parent id deliberately means "already concrete" in
      ;; the installed pool and "contains Var" in the context-owned pool.
      (let
        [installed-memo-answer : bool
          (core_tests.tc-type-needs-resolution-id? installed-parent)]
        [installed-generation-after-prime : i64
          (ast.ty-node-pool-generation-value)]
        [owned-explicit-answer : bool
          (core_tests.tc-type-needs-resolution-id-with-bases?
            (ast.ast-node-pool-context-type-segment-bases (& owned-pools))
            owned-parent)]
        [resolved : ast.AstType
          (core_tests.tc-resolve-type-with-pools
            ctx
            (ast.ast-node-pool-context-shared-view (& owned-pools))
            (ast.ast-node-pool-context-type-get (& owned-pools) owned-parent))]
        [foreign-installed-count : i64
          (ast.ast-node-pool-context-type-len
            (ast.ast-node-pool-context-shared-view (& installed-pools)))]
        [installed-var : i64
          (ast.ast-node-pool-context-type-push
            (ast.ast-node-pool-context-shared-view (& installed-pools))
            (ast.AstType.Var name-id))]
        [installed-var-parent : i64
          (ast.ast-node-pool-context-type-push
            (ast.ast-node-pool-context-shared-view (& installed-pools))
            (ast.AstType.Array installed-var 5))]
        [installed-resolved : ast.AstType
          (tc_core.tc-resolve-type
            installed-ctx
            (ast.ast-node-pool-context-type-get
              (& installed-pools)
              installed-var-parent))]
        [installed-bases : i64
          (ast.ast-node-pool-context-type-segment-bases (& installed-pools))]
        [installed-active : ast.AstNodePoolContext
          (ast.ast-node-pool-context-capture-active)]
        [ok : bool
          (and
            (= installed-child owned-child)
            (= installed-parent owned-parent)
            (not installed-memo-answer)
            owned-explicit-answer
            (ast.ast-node-pool-context-type-installed? (& installed-pools))
            (=
              (ast.ty-node-pool-generation-value)
              installed-generation-after-prime)
            (= foreign-installed-count 2)
            (=
              (ast.ast-node-pool-context-type-len
                (ast.ast-node-pool-context-shared-view (& installed-pools)))
              5)
            (= (ast.ty-node-pool-len) 5)
            (=
              (ast.ast-node-pool-context-type-len
                (ast.ast-node-pool-context-shared-view (& owned-pools)))
              3)
            (match resolved
              [(ast.AstType.Array resolved-child count)
                (and
                  (= count 3)
                  (match (ast.ast-node-pool-context-type-get
                    (& owned-pools)
                    resolved-child)
                    [(ast.AstType.Expr) true]
                    [_ false]))]
              [_ false])
            (match (ast.ast-node-pool-context-type-get
              (& installed-pools)
              installed-child)
              [(ast.AstType.I64) true]
              [_ false])
            (match installed-resolved
              [(ast.AstType.Array resolved-child count)
                (and
                  (= count 5)
                  (match (ast.ty-node-get resolved-child)
                    [(ast.AstType.Expr) true]
                    [_ false]))]
              [_ false])
            (=
              (ast.ast-node-pool-context-type-segment-bases installed-active)
              installed-bases))]
        (begin
          (ast.ast-node-pool-context-install! active-before)
          ok)))))

(define (compiler-typecheck-smoke-generated-import-decl
  [source : String]
  [key : String]) : ast.AstDecl
  (match (parser.parse-ast-source-diagnostic "target/tc_state_entry.tl" source)
    [(parser.ResultAstProgramDiagnostic.Ok (ast.AstProgram.Program decls-box))
      (match (ast.ast-decl-list-step
        (ast.ast-decl-list-box-shared-view decls-box))
        [(ast.AstDeclListStep.Cons decl _)
          (ast.ast-decl-comptime-decl-with-meta
            (tc_core.macro-generated-meta "state-isolation" "import" key)
            decl)]
        [(ast.AstDeclListStep.Nil)
          (io.panic "typecheck: generated import fixture parsed no declaration")])]
    [(parser.ResultAstProgramDiagnostic.Err diag)
      (io.panic
        (diagnostic.compiler-diagnostic-render
          (diagnostic.compiler-diagnostic-box-shared-view diag)))]))

;; A load failure keeps its dependency primary and one actionable import site.
(define (compiler-typecheck-smoke-generated-import-location-ok?
  [diag : diagnostic.CompilerDiagnostic]
  [dependency-path : String]
  [request-path : String]
  [request-line : i64]
  [request-col : i64]) : bool
  (let
    [primary : diagnostic.CompilerDiagnosticSpan
      (diagnostic.compiler-diagnostic-primary-span diag)]
    [labels : diagnostic.CompilerDiagnosticLabelList
      (diagnostic.compiler-diagnostic-secondary-spans diag)]
    (and
      (string.eq primary.path dependency-path)
      (= (diagnostic.compiler-diagnostic-label-list-count labels) 1)
      (let
        [label : diagnostic.CompilerDiagnosticLabel
          (diagnostic.compiler-diagnostic-label-list-get labels 0)]
        [span : diagnostic.CompilerDiagnosticSpan label.span]
        (and
          (string.eq span.path request-path)
          (= span.start-line request-line)
          (= span.start-col request-col)
          (match label.label
            [(CompilerDiagnosticSomeString text)
              (string.eq text "generated import requested here")]
            [CompilerDiagnosticNoString false]))))))

;; The provider quote and caller deliberately have different line numbers.
;; Exercise the real loader so a provider span cannot be paired with the caller
;; path by the expansion's declaration-path lane.
(define (compiler-typecheck-smoke-generated-import-call-site-ok? [mode : i64]) : bool
  (let
    [entry : String "target/tc_generated_import_caller.tl"]
    [roots : svec.Vec (svec.new)]
    [cfgs : sym_i64_env.SymI64Env (parser.compiler-cfg-empty)]
    (begin
      (compiler-typecheck-smoke-write-text
        "target/tc_generated_import_left.tl"
        "(define answer : i64 14)")
      (compiler-typecheck-smoke-write-text
        "target/tc_generated_import_right.tl"
        "(define answer : i64 15)")
      (compiler-typecheck-smoke-write-text
        "target/tc_generated_import_provider.tl"
        (if (= mode 1)
          "(module tc_generated_import_provider)
(defmacro (emit-imports) : Decls
  `(begin
    (import tc_generated_import_left as dep)
    (import tc_generated_import_right as dep)))"
          (if (= mode 0)
            "(module tc_generated_import_provider)
(defmacro (emit-imports) : Decls
  `(import tc_generated_import_missing_dependency))"
            "(module tc_generated_import_provider)
(defmacro (emit-imports) : Decls
  `(import tc_generated_import_left.missing as unused))")))
      (compiler-typecheck-smoke-write-text
        (tc_core.tc-global-shared-view entry)
        (if (= mode 3)
          "(import tc_generated_import_provider as provider)

(import tc_generated_import_left as existing)

;; The selected module was already loaded before this request.
(provider.emit-imports)

(define (main) : i64 42)"
          "(import tc_generated_import_provider as provider)

(define prior : i64 1)

;; The generated import is requested on the next line.
(provider.emit-imports)

(define (main) : i64 42)"))
      (tc_api.compiler-typecheck-reset-load-session!)
      (match (load.compiler-load-file-with-paths-and-roots-cfg
        (tc_core.tc-global-shared-view entry)
        (sym_i64_env.sym-i64-empty)
        (tc_core.tc-global-shared-view roots)
        cfgs)
        [(load.ResultCompilerLoadWithPaths.Ok decls paths _ _)
          (match (tc_api.typecheck-compiler-program-with-paths-cache
            (ast.ast-program decls)
            paths
            (tc_core.tc-global-shared-view roots)
            cfgs
            (tc_api.compiler-typecheck-prefix-cache-scope
              "typecheck-generated-import-call-site"
              roots
              cfgs))
            [(tc_core.ResultCompilerTypecheck.Err diagnostics)
              (let
                [first : diagnostic.CompilerDiagnostic
                  (diagnostic.compiler-diagnostic-list-first
                    (diagnostic.compiler-diagnostic-list-box-shared-view
                      diagnostics))]
                (if (not (= mode 0))
                  (let
                    [span : diagnostic.CompilerDiagnosticSpan
                      (diagnostic.compiler-diagnostic-primary-span first)]
                    (and
                      (string.eq span.path entry)
                      (= span.start-line 6)
                      (= span.start-col 1)
                      (string.eq
                        (diagnostic.compiler-diagnostic-message first)
                        (if (= mode 1)
                          "compiler-load: ambiguous import alias 'dep' between 'tc_generated_import_left' and 'tc_generated_import_right'; use distinct aliases or qualified access"
                          "compiler-load: module 'tc_generated_import_left' has no selected item 'missing'"))))
                  (compiler-typecheck-smoke-generated-import-location-ok?
                    first
                    "target/tc_generated_import_missing_dependency.tl"
                    entry
                    6
                    1)))]
            [(tc_core.ResultCompilerTypecheck.Ok _) false])]
        [(load.ResultCompilerLoadWithPaths.Err _) false]))))

(define (compiler-typecheck-smoke-generated-provided-module-ok?) : bool
  (match (tc_api.typecheck-compiler-source
    "(module generated.provided)
(define (answer) : i64 42)
(module main)
(defmacro (emit) : Decls `(import generated.provided as p))
(emit)
(define (main) : i64 (p.answer))")
    [(tc_core.ResultCompilerTypecheck.Ok _) true]
    [(tc_core.ResultCompilerTypecheck.Err _) false]))

(define (compiler-typecheck-smoke-generated-import-state-run
  [state : load.CompilerLoadSessionState]
  [generated-import : ast.AstDecl]
  [missing-import : ast.AstDecl]
  [pools : ast.AstNodePoolContext]) : CompilerTypecheckGeneratedImportStateSnapshot
  (let
    [entry : String "target/tc_state_entry.tl"]
    [owner-id : i64 (load.compiler-load-source-path-id entry)]
    [roots : svec.Vec (svec.new)]
    [cfgs : sym_i64_env.SymI64Env
      (tc_api.typecheck-compiler-source-language-cfgs)]
    [empty-seen : sym_i64_env.SymI64Env (sym_i64_env.sym-i64-empty)]
    (match (core_tests.macro-materialize-generated-import
      (tc_core.tc-global-shared-view state)
      (tc_core.tc-global-shared-view generated-import)
      (tc_core.tc-global-shared-view entry)
      owner-id
      ""
      cbi.compiler-builtin-id-fix-empty
      empty-seen
      (tc_core.tc-global-shared-view roots)
      cfgs
      pools)
      [(tc_core.ResultMacroMaterializeImport.Ok _ _ first-seen)
        ;; A second traversal from an independent seen set must reuse A's
        ;; program/surface caches. The selected compatibility session is
        ;; intentionally irrelevant to both traversals.
        (match (core_tests.macro-materialize-generated-import
          (tc_core.tc-global-shared-view state)
          (tc_core.tc-global-shared-view generated-import)
          (tc_core.tc-global-shared-view entry)
          owner-id
          ""
          cbi.compiler-builtin-id-fix-empty
          empty-seen
          (tc_core.tc-global-shared-view roots)
          cfgs
          pools)
          [(tc_core.ResultMacroMaterializeImport.Ok _ _ _)
            (match (core_tests.macro-materialize-generated-import
              (tc_core.tc-global-shared-view state)
              generated-import
              (tc_core.tc-global-shared-view entry)
              owner-id
              ""
              cbi.compiler-builtin-id-fix-empty
              empty-seen
              (tc_core.tc-global-shared-view roots)
              cfgs
              pools)
              [(tc_core.ResultMacroMaterializeImport.Ok _ _ _)
                (match (core_tests.macro-materialize-generated-import
                  (tc_core.tc-global-shared-view state)
                  missing-import
                  entry
                  owner-id
                  ""
                  cbi.compiler-builtin-id-fix-empty
                  first-seen
                  roots
                  cfgs
                  pools)
                  [(tc_core.ResultMacroMaterializeImport.Err diag)
                    (begin
                      (if (compiler-typecheck-smoke-generated-import-location-ok?
                        (diagnostic.compiler-diagnostic-box-shared-view
                          (tc_core.tc-global-shared-view diag))
                        "target/tc_state_missing.tl"
                        "target/tc_state_entry.tl"
                        1
                        1)
                        unit
                        (io.panic
                          "typecheck: generated import lost dependency or import-site location"))
                      (CompilerTypecheckGeneratedImportStateSnapshot
                        (diagnostic.compiler-diagnostic-message
                          (__tl-box-place diag))
                        (load.compiler-load-session-state-program-cache-hit-count-value
                          state)
                        (load.compiler-load-session-state-program-cache-miss-count-value
                          state)
                        (load.compiler-load-session-state-program-cache-store-count-value
                          state)
                        (match (sym_i64_env.sym-i64-view first-seen)
                          [(sym_i64_env.SymI64ViewNil) false]
                          [(sym_i64_env.SymI64ViewBind _ _ _) true])
                        (match (load.compiler-load-session-state-surface-summary-find-module
                          state
                          (ci.intern "tc_state_dep"))
                          [(CompilerLoadSomeSurfaceSummary _) true]
                          [(CompilerLoadNoSurfaceSummary) false])))]
                  [(tc_core.ResultMacroMaterializeImport.Ok _ _ _)
                    (io.panic
                      "typecheck: generated missing import unexpectedly loaded")])]
              [(tc_core.ResultMacroMaterializeImport.Err diag)
                (io.panic
                  (diagnostic.compiler-diagnostic-render
                    (diagnostic.compiler-diagnostic-box-shared-view diag)))])]
          [(tc_core.ResultMacroMaterializeImport.Err diag)
            (io.panic
              (diagnostic.compiler-diagnostic-render
                (diagnostic.compiler-diagnostic-box-shared-view diag)))])]
      [(tc_core.ResultMacroMaterializeImport.Err diag)
        (io.panic
          (diagnostic.compiler-diagnostic-render
            (diagnostic.compiler-diagnostic-box-shared-view diag)))])))

(define (compiler-typecheck-smoke-generated-import-state-isolation-ok?) : bool
  (let
    [previous-state : load.CompilerLoadSessionState
      (load.compiler-load-serial-test-session-state)]
    [baseline-state : load.CompilerLoadSessionState
      (load.compiler-load-session-state-new)]
    [state-a : load.CompilerLoadSessionState
      (load.compiler-load-session-state-new)]
    [state-b : load.CompilerLoadSessionState
      (load.compiler-load-session-state-new)]
    [_enable-baseline : unit
      (load.compiler-load-session-state-cache-enable!
        (tc_core.tc-global-shared-view baseline-state))]
    [_enable-a : unit
      (load.compiler-load-session-state-cache-enable!
        (tc_core.tc-global-shared-view state-a))]
    [_seed-b : unit (set! (array-ref state-b.program-cache-hit-count 0) 17)]
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [_fixtures : unit
      (begin
        (compiler-typecheck-smoke-write-text
          "target/tc_state_nested.tl"
          "(module tc_state_nested)
(define nested-value : i64 7)")
        (compiler-typecheck-smoke-write-text
          "target/tc_state_dep.tl"
          "(module tc_state_dep)
(import tc_state_nested as nested)
(define dep-value : i64 nested.nested-value)"))]
    [generated-import : ast.AstDecl
      (compiler-typecheck-smoke-generated-import-decl
        "(import tc_state_dep as dep)"
        "state-import")]
    [missing-import : ast.AstDecl
      (compiler-typecheck-smoke-generated-import-decl
        "(import tc_state_missing as missing)"
        "state-missing")]
    [_select-baseline : unit
      (load.compiler-load-session-state-use!
        (tc_core.tc-global-shared-view baseline-state))]
    [baseline : CompilerTypecheckGeneratedImportStateSnapshot
      (compiler-typecheck-smoke-generated-import-state-run
        baseline-state
        (tc_core.tc-global-shared-view generated-import)
        (tc_core.tc-global-shared-view missing-import)
        (tc_core.tc-global-shared-view pools))]
    [_select-b : unit
      (load.compiler-load-session-state-use!
        (tc_core.tc-global-shared-view state-b))]
    [interleaved : CompilerTypecheckGeneratedImportStateSnapshot
      (compiler-typecheck-smoke-generated-import-state-run
        state-a
        generated-import
        missing-import
        pools)]
    (begin
      (load.compiler-load-session-state-use! previous-state)
      (cond
        [(not (string.eq baseline.diagnostic interleaved.diagnostic))
          (io.panic "typecheck: generated import state diagnostic mismatch")]
        [(not (= baseline.cache-hits interleaved.cache-hits))
          (io.panic "typecheck: generated import state cache-hit mismatch")]
        [(not (= baseline.cache-misses interleaved.cache-misses))
          (io.panic "typecheck: generated import state cache-miss mismatch")]
        [(not (= baseline.cache-stores interleaved.cache-stores))
          (io.panic "typecheck: generated import state cache-store mismatch")]
        [(not (= baseline.seen-nonempty interleaved.seen-nonempty))
          (io.panic "typecheck: generated import state seen mismatch")]
        [(not
            (=
              baseline.surface-summary-present
              interleaved.surface-summary-present))
          (io.panic "typecheck: generated import state surface mismatch")]
        [(not (> interleaved.cache-hits 0))
          (io.panic "typecheck: generated import state missed cache reuse")]
        [(not (> interleaved.cache-misses 0))
          (io.panic "typecheck: generated import state recorded no cache miss")]
        [(not (> interleaved.cache-stores 0))
          (io.panic "typecheck: generated import state recorded no cache store")]
        [(not interleaved.seen-nonempty)
          (io.panic "typecheck: generated import state lost seen set")]
        [(not interleaved.surface-summary-present)
          (io.panic "typecheck: generated import state lost surface summary")]
        [(not
            (load.compiler-load-string-contains?
              interleaved.diagnostic
              "tc_state_missing.tl"))
          (io.panic "typecheck: generated import state diagnostic uncontrolled")]
        [(not
            (=
              (load.compiler-load-session-state-program-cache-hit-count-value
                state-b)
              17))
          (io.panic "typecheck: generated import state mutated peer hit count")]
        [(not
            (=
              (load.compiler-load-session-state-program-cache-miss-count-value
                state-b)
              0))
          (io.panic "typecheck: generated import state mutated peer miss count")]
        [(not
            (=
              (load.compiler-load-session-state-program-cache-store-count-value
                state-b)
              0))
          (io.panic
            "typecheck: generated import state mutated peer store count")]
        [(match (load.compiler-load-session-state-surface-summary-find-module
            state-b
            (ci.intern "tc_state_dep"))
            [(CompilerLoadNoSurfaceSummary) false]
            [(CompilerLoadSomeSurfaceSummary _) true])
          (io.panic "typecheck: generated import state mutated peer surface")]
        [else true]))))

(define (compiler-typecheck-smoke-generated-import-state-threading-ok?) : bool
  (let
    [previous-state : load.CompilerLoadSessionState
      (load.compiler-load-serial-test-session-state)]
    [state-a : load.CompilerLoadSessionState
      (load.compiler-load-session-state-new)]
    [state-b : load.CompilerLoadSessionState
      (load.compiler-load-session-state-new)]
    [prefix-cache-a : tc_core.TcPrefixSnapshotCacheState
      (tc_core.tc-prefix-snapshot-cache-state-new)]
    [prefix-cache-b : tc_core.TcPrefixSnapshotCacheState
      (tc_core.tc-prefix-snapshot-cache-state-new)]
    [job-state-a : tc_core.TcJobState (tc_core.tc-job-state-new)]
    [_enable-a : unit
      (load.compiler-load-session-state-cache-enable!
        (tc_core.tc-global-shared-view state-a))]
    [_seed-b : unit
      (begin
        (set! (array-ref state-b.program-cache-hit-count 0) 23)
        (tc_core.tc-prefix-snapshot-cache-note-hit-for-state! prefix-cache-b))]
    [entry : String "target/tc_state_macro_entry.tl"]
    [source : String
      "(defmacro (state-module) : Module
  `(begin
    (module generated.state_session)
    (import tc_state_dep as dep)
    (define (value) : i64 dep.dep-value)))
(import (state-module) as generated_state)
(define (main) : i64 (generated_state.value))"]
    [roots : svec.Vec (svec.new)]
    [cfgs : sym_i64_env.SymI64Env
      (tc_api.typecheck-compiler-source-language-cfgs)]
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [_reset-typecheck : unit (tc_core.compiler-typecheck-reset-file-state!)]
    [_select-b : unit
      (load.compiler-load-session-state-use!
        (tc_core.tc-global-shared-view state-b))]
    [result : tc_core.ResultCompilerTypecheck
      (match (load.compiler-load-source-with-paths-and-roots-expect-cfg-with-pools
        (tc_core.tc-global-shared-view state-a)
        entry
        source
        (sym_i64_env.sym-i64-empty)
        (tc_core.tc-global-shared-view roots)
        ast.AstMaybeModuleName.No
        cfgs
        pools)
        [(load.ResultCompilerLoadWithPaths.Ok decls paths modules _)
          (tc_api.typecheck-compiler-program-with-paths-cache-and-load-state-and-prefix-cache-state-and-pools
            (tc_core.tc-global-shared-view state-a)
            (tc_core.tc-global-shared-view prefix-cache-a)
            job-state-a
            (ast.ast-program decls)
            (ast.ast-decl-path-list-with-modules paths modules)
            (tc_core.tc-global-shared-view roots)
            cfgs
            "typecheck-generated-import-state-threading"
            pools)]
        [(load.ResultCompilerLoadWithPaths.Err diag)
          (tc_core.ResultCompilerTypecheck.Err
            (diagnostic.compiler-diagnostic-list-box-single diag))])]
    [_reset-before-controlled-failure : unit
      (tc_core.compiler-typecheck-reset-file-state!)]
    [controlled-failure : tc_core.ResultCompilerTypecheck
      (match (parser.parse-ast-source-diagnostic
        "target/tc_state_controlled_failure.tl"
        "(define broken : i64 true)")
        [(parser.ResultAstProgramDiagnostic.Ok bad-program)
          (tc_api.typecheck-compiler-program-with-paths-cache-and-load-state-and-prefix-cache-state-and-pools
            (tc_core.tc-global-shared-view state-a)
            (tc_core.tc-global-shared-view prefix-cache-a)
            job-state-a
            bad-program
            (ast.ast-decl-root-path-cons
              "target/tc_state_controlled_failure.tl"
              (ast.ast-decl-path-list-new))
            roots
            cfgs
            "typecheck-controlled-failure-state-threading"
            pools)]
        [(parser.ResultAstProgramDiagnostic.Err diag)
          (tc_core.ResultCompilerTypecheck.Err
            (diagnostic.compiler-diagnostic-list-box-single diag))])]
    [ok : bool
      (and
        (match result
          [(tc_core.ResultCompilerTypecheck.Ok _) true]
          [(tc_core.ResultCompilerTypecheck.Err diag)
            (io.panic
              (diagnostic.compiler-diagnostic-render
                (diagnostic.compiler-diagnostic-list-first
                  (diagnostic.compiler-diagnostic-list-box-shared-view diag))))])
        (match controlled-failure
          [(tc_core.ResultCompilerTypecheck.Err _) true]
          [(tc_core.ResultCompilerTypecheck.Ok _) false])
        (match (load.compiler-load-session-state-surface-summary-find-module
          state-a
          (ci.intern "tc_state_dep"))
          [(CompilerLoadSomeSurfaceSummary _) true]
          [(CompilerLoadNoSurfaceSummary) false])
        (=
          (load.compiler-load-session-state-program-cache-hit-count-value
            state-b)
          23)
        (=
          (load.compiler-load-session-state-program-cache-miss-count-value
            state-b)
          0)
        (=
          (load.compiler-load-session-state-program-cache-store-count-value
            state-b)
          0)
        (=
          (tc_core.tc-prefix-snapshot-cache-hit-count-for-state prefix-cache-b)
          1)
        (=
          (tc_core.tc-prefix-snapshot-cache-miss-count-for-state prefix-cache-b)
          0)
        (=
          (tc_core.tc-prefix-snapshot-cache-store-count-for-state
            prefix-cache-b)
          0)
        (match (load.compiler-load-session-state-surface-summary-find-module
          state-b
          (ci.intern "tc_state_dep"))
          [(CompilerLoadNoSurfaceSummary) true]
          [(CompilerLoadSomeSurfaceSummary _) false]))]
    (begin
      (tc_core.tc-prefix-snapshot-cache-invalidate-for-state! prefix-cache-a)
      (tc_core.tc-prefix-snapshot-cache-invalidate-for-state! prefix-cache-b)
      (load.compiler-load-session-state-use! previous-state)
      ok)))

(define (compiler-typecheck-smoke-moduleless-stdlib-dotted-import-ok?) : bool
  (let
    [base : String "target/tc_moduleless_stdlib"]
    [stdlib-root : String
      (load.compiler-load-join-root-path
        (tc_core.tc-global-shared-view base)
        "stdlib")]
    [dep : String
      (load.compiler-load-join-root-path
        (tc_core.tc-global-shared-view stdlib-root)
        "some_name.tl")]
    [entry : String
      (load.compiler-load-join-root-path
        (tc_core.tc-global-shared-view base)
        "entry.tl")]
    [roots : svec.Vec
      (let
        [items : svec.Vec (svec.new)]
        (begin
          (svec.push-ref!
            (&mut items)
            (tc_core.tc-global-shared-view stdlib-root))
          items))]
    [cfgs : sym_i64_env.SymI64Env (parser.compiler-cfg-empty)]
    (begin
      (load.compiler-load-test-mkdir base)
      (load.compiler-load-test-mkdir stdlib-root)
      (compiler-typecheck-smoke-write-text dep "(define value : i64 42)")
      (compiler-typecheck-smoke-write-text
        (tc_core.tc-global-shared-view entry)
        "(import stdlib.some_name)
(define (main) : i64 some_name.value)")
      (tc_api.compiler-typecheck-reset-load-session!)
      (compiler-typecheck-smoke-prefix-cache-file-check entry roots cfgs))))

(define (compiler-typecheck-smoke-specialized-import-path-ok?) : bool
  (let
    [dir : String "target/tc_specialized_import_path"]
    [dep : String
      (load.compiler-load-join-root-path
        (tc_core.tc-global-shared-view dir)
        "dep.tl")]
    [entry : String
      (load.compiler-load-join-root-path
        (tc_core.tc-global-shared-view dir)
        "entry.tl")]
    [roots : svec.Vec (svec.new)]
    [cfgs : sym_i64_env.SymI64Env (parser.compiler-cfg-empty)]
    (begin
      (load.compiler-load-test-mkdir dir)
      (compiler-typecheck-smoke-write-text
        (tc_core.tc-global-shared-view dep)
        "(define imported : i64 true)")
      (compiler-typecheck-smoke-write-text
        (tc_core.tc-global-shared-view entry)
        "(define (id [comptime T : type] [value : T]) : T value)
(import dep)
(define (main) : i64 0)")
      (match (load.compiler-load-file-with-paths-and-roots-cfg
        entry
        (sym_i64_env.sym-i64-empty)
        (tc_core.tc-global-shared-view roots)
        cfgs)
        [(load.ResultCompilerLoadWithPaths.Ok decls paths _ _)
          (match (tc_api.typecheck-compiler-program-with-paths-cache
            (ast.ast-program decls)
            paths
            (tc_core.tc-global-shared-view roots)
            cfgs
            (tc_api.compiler-typecheck-prefix-cache-scope
              "typecheck-specialized-import-path-smoke"
              roots
              cfgs))
            [(tc_core.ResultCompilerTypecheck.Err diag)
              (let
                [first : diagnostic.CompilerDiagnostic
                  (diagnostic.compiler-diagnostic-list-first
                    (diagnostic.compiler-diagnostic-list-box-shared-view diag))]
                (and
                  (string.eq (diagnostic.compiler-diagnostic-path first) dep)
                  (string.eq
                    (diagnostic.compiler-diagnostic-message first)
                    "typecheck: value definition type mismatch: expected i64, found bool")))]
            [(tc_core.ResultCompilerTypecheck.Ok _) false])]
        [(load.ResultCompilerLoadWithPaths.Err _) false]))))

(define (compiler-typecheck-smoke-macro-dependency-state-check
  [entry : String]
  [roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : bool
  (let
    [load-state : load.CompilerLoadSessionState
      (load.compiler-load-session-state-new)]
    [prefix-cache : tc_core.TcPrefixSnapshotCacheState
      (tc_core.tc-prefix-snapshot-cache-state-new)]
    [job-state : tc_core.TcJobState (tc_core.tc-job-state-new)]
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [result : tc_core.ResultCompilerTypecheck
      (match (load.compiler-load-file-with-paths-and-roots-cfg-with-pools
        (load.compiler-load-session-state-shared-view (& load-state))
        entry
        (sym_i64_env.sym-i64-empty)
        (tc_core.tc-global-shared-view roots)
        cfgs
        (ast.ast-node-pool-context-shared-view (& pools)))
        [(load.ResultCompilerLoadWithPaths.Ok decls paths modules _)
          (tc_api.typecheck-compiler-program-with-paths-cache-and-load-state-and-prefix-cache-state-and-pools
            load-state
            (tc_core.tc-global-shared-view prefix-cache)
            job-state
            (ast.ast-program decls)
            (ast.ast-decl-path-list-with-modules paths modules)
            roots
            cfgs
            "typecheck-macro-transitive-dependency-state"
            pools)]
        [(load.ResultCompilerLoadWithPaths.Err diag)
          (tc_core.ResultCompilerTypecheck.Err
            (diagnostic.compiler-diagnostic-list-box-single diag))])]
    [ok : bool
      (match result
        [(tc_core.ResultCompilerTypecheck.Ok _) true]
        [(tc_core.ResultCompilerTypecheck.Err _) false])]
    (begin
      (tc_core.tc-prefix-snapshot-cache-invalidate-for-state! prefix-cache)
      ok)))

(define (compiler-typecheck-smoke-macro-dependency-missing-ok?) : bool
  (let
    [provider : String "target/tc_macro_missing_provider.tl"]
    [entry : String "target/tc_macro_missing_entry.tl"]
    [missing : String "target/tc_macro_missing_helper.tl"]
    [roots : svec.Vec (svec.new)]
    [cfgs : sym_i64_env.SymI64Env (parser.compiler-cfg-empty)]
    (begin
      (compiler-typecheck-smoke-write-text
        provider
        "(module tc_macro_missing_provider)
(import tc_macro_missing_helper as helper)
(defmacro (bumped [value : Expr]) : Expr `(helper.bump ,value))")
      (compiler-typecheck-smoke-write-text
        (tc_core.tc-global-shared-view entry)
        "(import tc_macro_missing_provider as provider)
(define (main) : i64 (provider.bumped 41))")
      (tc_api.compiler-typecheck-reset-load-session!)
      (match (load.compiler-load-file-with-paths-and-roots-cfg
        entry
        (sym_i64_env.sym-i64-empty)
        roots
        cfgs)
        [(load.ResultCompilerLoadWithPaths.Err diag)
          (and
            (string.eq
              (diagnostic.compiler-diagnostic-path (__tl-box-place diag))
              missing)
            (string.eq
              (diagnostic.compiler-diagnostic-message (__tl-box-place diag))
              (str_cat.str-cat "compiler-load: cannot read import " missing)))]
        [(load.ResultCompilerLoadWithPaths.Ok _ _ _ _) false]))))

(define (compiler-typecheck-smoke-macro-dependency-context-ok?) : bool
  (let
    [helper : String "target/tc_macro_context_helper.tl"]
    [provider : String "target/tc_macro_context_provider.tl"]
    [entry : String "target/tc_macro_context_entry.tl"]
    [roots : svec.Vec (svec.new)]
    [cfgs : sym_i64_env.SymI64Env (parser.compiler-cfg-empty)]
    (begin
      (compiler-typecheck-smoke-write-text
        helper
        "(module tc_macro_context_helper)
(defmacro (bump [T : type] [value : Expr]) : Expr
  (match (type-kind T)
    [\"i64\" `(+ ,value 1)]
    [_ `0]))")
      (compiler-typecheck-smoke-write-text
        provider
        "(module tc_macro_context_provider)
(import tc_macro_context_helper as helper)
(defmacro (bumped [value : Expr]) : Expr
  `(helper.bump i64 ,value))")
      (compiler-typecheck-smoke-write-text
        (tc_core.tc-global-shared-view entry)
        "(import tc_macro_context_provider as provider)
(define (main) : i64 (provider.bumped 41))")
      (tc_api.compiler-typecheck-reset-load-session!)
      (let
        [serial-ok : bool
          (compiler-typecheck-smoke-prefix-cache-file-check
            (tc_core.tc-global-shared-view entry)
            (tc_core.tc-global-shared-view roots)
            cfgs)]
        [_reset : unit (tc_api.compiler-typecheck-reset-load-session!)]
        [state-ok : bool
          (compiler-typecheck-smoke-macro-dependency-state-check
            entry
            roots
            cfgs)]
        (and
          serial-ok
          state-ok
          (compiler-typecheck-smoke-macro-dependency-missing-ok?))))))

(define (compiler-typecheck-smoke-surface-macro-summary-ok?) : bool
  (let
    [provider : String "target/tc_surface_macro_provider.tl"]
    [entry : String "target/tc_surface_macro_entry.tl"]
    [roots : svec.Vec (svec.new)]
    [cfgs : sym_i64_env.SymI64Env (parser.compiler-cfg-empty)]
    [macro-state : tc_core.TcMacroState
      (tc_core.tc-job-state-macro-state (tc_core.tc-serial-job-state))]
    [ctfe-state : ctfe.CompilerCtfeMacroState
      (tc_core.tc-macro-ctfe-state macro-state)]
    (begin
      (compiler-typecheck-smoke-write-text
        provider
        "(module tc_surface_macro_provider)
(defmacro (first) : Expr `0)
(define value : i64 1)
(define (wide [p0 : i64] [p1 : i64] [p2 : i64] [p3 : i64] [p4 : i64] [p5 : i64] [p6 : i64] [p7 : i64] [p8 : i64] [p9 : i64] [p10 : i64] [p11 : i64] [p12 : i64] [p13 : i64] [p14 : i64] [p15 : i64]) : i64 p0)
(defmacro (hook [value : i64]) : i64 `(+ ,value 1))
(defmacro (last) : Expr `42)")
      (compiler-typecheck-smoke-write-text
        (tc_core.tc-global-shared-view entry)
        "(import tc_surface_macro_provider as provider)
(define (main) : i64 0)")
      (tc_api.compiler-typecheck-reset-load-session!)
      (match (load.compiler-load-file-with-paths-and-roots-cfg
        entry
        (sym_i64_env.sym-i64-empty)
        roots
        cfgs)
        [(load.ResultCompilerLoadWithPaths.Ok _ _ _ _)
          (begin
            (tc_core.tc-macro-state-bind-source-names!
              macro-state
              (ci.intern-source-name-session-capture-active-handle))
            (ctfe.ctfe-module-macro-export-reset-for-state! ctfe-state)
            (let
              [names : tc_core.TcNameIdList
                (tc_core.macro-collect-surface-summary-macro-names
                  macro-state
                  (load.compiler-load-surface-summaries)
                  (tc_core.TcNameIdList.Nil))]
              ;; The provider stays a lazy surface summary (aliased dotted
              ;; import of a module-declared target), so its decls are not in
              ;; the loaded program; the summary keys are the session-interned
              ;; name ids directly.
              [provider-id : i64 (ci.intern "tc_surface_macro_provider")]
              [hook-id : i64 (ci.intern "hook")]
              [non-macro-id : i64 (ci.intern "value")]
              [missing-id : i64 (ci.intern "missing")]
              [generated-provider-id : i64
                (ci.intern-generated-name "tc_surface_macro_provider")]
              [generated-hook-id : i64 (ci.intern-generated-name "hook")]
              [retained : tc_core.MacroMaybeDecl
                (tc_core.macro-surface-call-decl-in-module
                  macro-state
                  provider-id
                  hook-id)]
              [before-reset : bool
                (and
                  (tc_core.tc-name-id-list-contains names hook-id)
                  (tc_core.macro-surface-macro-in-module? provider-id hook-id)
                  (tc_core.macro-surface-macro-in-module?
                    provider-id
                    (ci.intern "first"))
                  (tc_core.macro-surface-macro-in-module?
                    provider-id
                    (ci.intern "last"))
                  (not
                    (tc_core.macro-surface-macro-in-module?
                      provider-id
                      missing-id))
                  (tc_core.macro-surface-module-has-macro? provider-id)
                  (not
                    (tc_core.macro-surface-macro-in-module?
                      provider-id
                      (ci.intern "wide")))
                  (match (tc_core.macro-surface-call-decl-in-module
                    macro-state
                    provider-id
                    (ci.intern "wide"))
                    [(tc_core.MacroMaybeDecl.No) true]
                    [_ false])
                  (string.eq
                    (ci.intern-str generated-provider-id)
                    (ci.intern-str provider-id))
                  (string.eq
                    (ci.intern-str generated-hook-id)
                    (ci.intern-str hook-id))
                  (not (= generated-provider-id provider-id))
                  (not (= generated-hook-id hook-id))
                  (not
                    (tc_core.macro-surface-macro-in-module?
                      generated-provider-id
                      hook-id))
                  (not
                    (tc_core.macro-surface-macro-in-module?
                      provider-id
                      generated-hook-id))
                  (not
                    (tc_core.macro-surface-module-has-macro?
                      generated-provider-id))
                  (match (tc_core.macro-surface-call-decl-in-module
                    macro-state
                    provider-id
                    hook-id)
                    [(tc_core.MacroMaybeDecl.Some _ _ _ _ _ _) true]
                    [(tc_core.MacroMaybeDecl.No) false])
                  (match (tc_core.macro-surface-call-decl-in-module
                    macro-state
                    generated-provider-id
                    generated-hook-id)
                    [(tc_core.MacroMaybeDecl.Some _ _ _ _ _ _) false]
                    [(tc_core.MacroMaybeDecl.No) true])
                  (ctfe.ctfe-module-macro-export-id-for-state?
                    ctfe-state
                    provider-id
                    hook-id)
                  (not
                    (ctfe.ctfe-module-macro-export-id-for-state?
                      ctfe-state
                      provider-id
                      non-macro-id)))]
              (begin
                (load.compiler-load-surface-summaries-reset!)
                (tc_core.macro-surface-call-decl-cache-reset! macro-state)
                (and
                  before-reset
                  ;; The selected signature owns its parameter payload even after
                  ;; the loader destroys the summary arena used by the scan.
                  (match retained
                    [(tc_core.MacroMaybeDecl.Some name module _ params ret _)
                      (and
                        (= name hook-id)
                        (= module provider-id)
                        (= (ast.ast-macro-param-list-len (& params)) 1)
                        (match (ast.ast-macro-param-list-get
                          (& params)
                          0
                          (ast.ast-macro-param-fallback))
                          [(ast.AstMacroParam.Param
                              parameter
                              (ast.AstType.I64)
                              false
                              _)
                            (= parameter (ci.intern "value"))]
                          [_ false])
                        (match ret
                          [(ast.AstType.I64) true]
                          [_ false]))]
                    [(tc_core.MacroMaybeDecl.No) false])
                  (not
                    (tc_core.macro-surface-macro-in-module? provider-id hook-id))
                  (not (tc_core.macro-surface-module-has-macro? provider-id))
                  (match (tc_core.macro-surface-call-decl-in-module
                    macro-state
                    provider-id
                    hook-id)
                    [(tc_core.MacroMaybeDecl.Some _ _ _ _ _ _) false]
                    [(tc_core.MacroMaybeDecl.No) true])))))]
        [(load.ResultCompilerLoadWithPaths.Err _) false]))))

(define (compiler-typecheck-smoke-record-surface-summary?
  [path : String]
  [source : String]) : bool
  (let
    [path-id : i64 (load.compiler-load-parse-context-name-id path)]
    [fallback-id : i64
      (load.compiler-load-parse-context-name-id
        (load.compiler-load-canonical-module-id-from-path path))]
    (match (parser.parse-ast-source-diagnostic
      (tc_core.tc-global-shared-view path)
      source)
      [(parser.ResultAstProgramDiagnostic.Ok program)
        (match (load.compiler-load-surface-summary-build
          (tc_core.tc-global-shared-view path)
          path-id
          (load.compiler-load-dirname path)
          program
          fallback-id
          false)
          [(load.ResultCompilerLoadSurfaceSummary.Ok summary)
            (begin
              (load.compiler-load-record-surface-summary! summary)
              true)]
          [(load.ResultCompilerLoadSurfaceSummary.Err _) false])]
      [(parser.ResultAstProgramDiagnostic.Err _) false])))

(define (compiler-typecheck-smoke-lazy-summary-macro-provider-source) : String
  "(module tc.lazy.summary.macro.provider)
(defmacro (hook [value : i64]) : i64 `(+ ,value 1))
(define value : i64 1)")

(define (compiler-typecheck-smoke-lazy-summary-macro-check
  [provider-source : String]
  [entry-source : String]
  [expected-forces : i64]) : bool
  (let
    [provider-path : String "target/tc_lazy_summary_macro_provider.tl"]
    [ok : bool false]
    (begin
      (tc_core.compiler-typecheck-reset-file-state!)
      (load.compiler-load-surface-summaries-reset!)
      (if (compiler-typecheck-smoke-record-surface-summary?
        provider-path
        provider-source)
        (match (parser.parse-ast-source-diagnostic "" entry-source)
          [(parser.ResultAstProgramDiagnostic.Ok entry-program)
            (match (tc_api.typecheck-compiler-program-with-paths-checked
              entry-program
              (ast.ast-decl-path-list-new))
              [(tc_core.ResultCompilerTypecheckChecked.Ok _ _ _ _)
                (set!
                  ok
                  (and
                    (> (core_tests.tc-lazy-import-summary-backed-stub-count) 0)
                    (if (= expected-forces 0)
                      (=
                        (core_tests.tc-lazy-import-summary-macro-force-count)
                        0)
                      (>
                        (core_tests.tc-lazy-import-summary-macro-force-count)
                        0))))]
              [(tc_core.ResultCompilerTypecheckChecked.Partial _ _ _ _)
                (set! ok false)]
              [(tc_core.ResultCompilerTypecheckChecked.Err _) (set! ok false)])]
          [(parser.ResultAstProgramDiagnostic.Err _) (set! ok false)])
        (set! ok false))
      (tc_core.compiler-typecheck-reset-file-state!)
      (load.compiler-load-surface-summaries-reset!)
      ok)))

(define (compiler-typecheck-smoke-lazy-summary-macro-unused-ok?) : bool
  (compiler-typecheck-smoke-lazy-summary-macro-check
    (compiler-typecheck-smoke-lazy-summary-macro-provider-source)
    "(module tc.lazy.summary.macro.provider)
(define summary-stub : i64 0)
(module tc.lazy.summary.macro.entry)
(import tc.lazy.summary.macro.provider as provider)
(define (main) : i64 0)"
    0))

(define (compiler-typecheck-smoke-lazy-summary-macro-call-ok?) : bool
  (compiler-typecheck-smoke-lazy-summary-macro-check
    (compiler-typecheck-smoke-lazy-summary-macro-provider-source)
    "(module tc.lazy.summary.macro.provider)
(define summary-stub : i64 0)
(module tc.lazy.summary.macro.entry)
(import tc.lazy.summary.macro.provider as provider)
(define (main) : i64 (provider.hook 41))"
    1))

(define (compiler-typecheck-smoke-lazy-summary-macro-hook-ok?) : bool
  (compiler-typecheck-smoke-lazy-summary-macro-check
    (compiler-typecheck-smoke-lazy-summary-macro-provider-source)
    "(module tc.lazy.summary.macro.provider)
(define summary-stub : i64 0)
(module tc.lazy.summary.macro.entry)
(import tc.lazy.summary.macro.provider as provider)
(defmacro (make [factory : Module]) : Module
  (let
    [emit : Expr (module-hook factory \"hook\")]
    `(begin
      (module generated.lazy_summary_macro_hook)
      (define (answer) : i64 (,emit 41)))))
(import (make provider) as gen)
(define (main) : i64 (gen.answer))"
    1))

(define (compiler-typecheck-smoke-lazy-summary-macro-comptime-ok?) : bool
  (compiler-typecheck-smoke-lazy-summary-macro-check
    "(module tc.lazy.summary.macro.comptime_provider)
(import stdlib.comptime)
(defmacro (capture [value : comptime.Expr]) : comptime.Expr `(+ ,value 1))
(define value : i64 1)"
    "(module tc.lazy.summary.macro.comptime_provider)
(define summary-stub : i64 0)
(module tc.lazy.summary.macro.entry)
(import tc.lazy.summary.macro.comptime_provider as provider)
(define (main) : i64 (provider.capture 41))"
    1))

(define (compiler-typecheck-smoke-lazy-summary-macro-context-ok?) : bool
  (compiler-typecheck-smoke-lazy-summary-macro-check
    "(module tc.lazy.summary.macro.context_provider)
(import tc.lazy.summary.macro.helper as helper)
(defmacro (hook [value : i64]) : i64 `(helper.bump ,value))"
    "(module tc.lazy.summary.macro.helper)
(define (bump [value : i64]) : i64 (+ value 1))
(module tc.lazy.summary.macro.context_provider)
(define summary-stub : i64 0)
(module tc.lazy.summary.macro.entry)
(import tc.lazy.summary.macro.context_provider as provider)
(define (main) : i64 (provider.hook 41))"
    1))

(define (compiler-typecheck-smoke-nested-dotted-nominal-ok?) : bool
  (tc_tests.compiler-typecheck-ok?
    "(module shared.types)
(defstruct Item (value i64))
(module bridge.api)
(import shared.types as shared)
(define (round-trip [item : shared.Item]) : shared.Item item)
(module app.main)
(import shared.types as item)
(import bridge.api as bridge)
(define (main) : i64
  (let
    [value : item.Item (bridge.round-trip (item.Item 42))]
    value.value))"))

(define (compiler-typecheck-smoke-qualified-array-ok?) : bool
  (tc_tests.compiler-typecheck-ok?
    "
(define (take-array-ref [r : (& items i64)]) : i64 1)
(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [fixed : (Array i64 2) (array 3 4)]
    (begin
      (set! (array-ref items 0) (array-ref fixed 1))
      (let
        [borrow-score : i64
          (let
            [borrowed : (& items i64) (& (array-ref items 0))]
            (take-array-ref borrowed))]
        (begin
          (__tl_array-push! items 9)
          (+ borrow-score (+ (array-length items) (array-ref items 0))))))))"))

(define (compiler-typecheck-smoke-expr-list-parsed-id
  [exprs : (& exprs ast.AstExprList)]
  [name : (& name str)]) : i64
  (let
    [index : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (< index exprs.len))
        (begin
          (set!
            found
            (compiler-typecheck-smoke-expr-parsed-id
              (ast.ast-expr-list-get exprs index 0)
              name))
          (set! index (+ index 1))))
      found)))

(define (compiler-typecheck-smoke-expr-parsed-id
  [expr-id : i64]
  [name : (& name str)]) : i64
  (match (ast.ast-node-get expr-id)
    [(ast.AstExpr.Spanned inner _)
      (compiler-typecheck-smoke-expr-parsed-id inner name)]
    [(ast.AstExpr.Var name-id)
      (let
        [leading-id : i64 (ci.intern-leading-dot-id name-id)]
        (cond
          [(string.eq (tc_core.tc-env-key-name-text name-id) name) name-id]
          [(and
              (>= leading-id 0)
              (string.eq (tc_core.tc-env-key-name-text leading-id) name))
            leading-id]
          [else -1]))]
    [(ast.AstExpr.Binary _ left right)
      (let
        [found : i64 (compiler-typecheck-smoke-expr-parsed-id left name)]
        (if (>= found 0)
          found
          (compiler-typecheck-smoke-expr-parsed-id right name)))]
    [(ast.AstExpr.Unary _ value)
      (compiler-typecheck-smoke-expr-parsed-id value name)]
    [(ast.AstExpr.Call func args)
      (let
        [found : i64 (compiler-typecheck-smoke-expr-parsed-id func name)]
        (if (>= found 0)
          found
          (compiler-typecheck-smoke-expr-list-parsed-id (& args) name)))]
    [(ast.AstExpr.If cond then else-expr)
      (let
        [found : i64 (compiler-typecheck-smoke-expr-parsed-id cond name)]
        (if (>= found 0)
          found
          (let
            [found : i64 (compiler-typecheck-smoke-expr-parsed-id then name)]
            (if (>= found 0)
              found
              (compiler-typecheck-smoke-expr-parsed-id else-expr name)))))]
    [(ast.AstExpr.Tuple items)
      (compiler-typecheck-smoke-expr-list-parsed-id (& items) name)]
    [(ast.AstExpr.Array items)
      (compiler-typecheck-smoke-expr-list-parsed-id (& items) name)]
    [(ast.AstExpr.DynArray items)
      (compiler-typecheck-smoke-expr-list-parsed-id (& items) name)]
    [(ast.AstExpr.Begin items)
      (compiler-typecheck-smoke-expr-list-parsed-id (& items) name)]
    [(ast.AstExpr.Unsafe items)
      (compiler-typecheck-smoke-expr-list-parsed-id (& items) name)]
    [(ast.AstExpr.Match match-box)
      (match (__tl-box-place match-box)
        [(ast.AstMatch.Match scrutinee _)
          (compiler-typecheck-smoke-expr-parsed-id scrutinee name)])]
    [(ast.AstExpr.StructGet base _)
      (compiler-typecheck-smoke-expr-parsed-id base name)]
    [(ast.AstExpr.Ann value _)
      (compiler-typecheck-smoke-expr-parsed-id value name)]
    [(ast.AstExpr.Cast value _)
      (compiler-typecheck-smoke-expr-parsed-id value name)]
    [_ -1]))

(define (compiler-typecheck-smoke-program-parsed-id
  [program : ast.AstProgram]
  [name : String]) : i64
  (match program
    [(ast.AstProgram.Program decls-box)
      (let
        [decls : ast.AstDeclList (ast.ast-decl-list-box-shared-view decls-box)]
        [index : i64 0]
        [found : i64 -1]
        (begin
          (while (and (< found 0) (< index decls.len))
            (let
              [decl : ast.AstDecl
                (ast.ast-decl-list-get (& decls) index (ast.ast-decl-fallback))]
              (begin
                (set!
                  found
                  (match decl
                    [(ast.AstDecl.Module name-id)
                      (if (string.eq
                        (tc_core.tc-env-key-name-text name-id)
                        name)
                        name-id
                        -1)]
                    [(ast.AstDecl.Def decl-meta name-id _ value)
                      (if (string.eq
                        (tc_core.tc-env-key-name-text name-id)
                        name)
                        name-id
                        (compiler-typecheck-smoke-expr-parsed-id value (& name)))]
                    [(ast.AstDecl.DefFn decl-meta name-id _ _ body _)
                      (if (string.eq
                        (tc_core.tc-env-key-name-text name-id)
                        name)
                        name-id
                        (compiler-typecheck-smoke-expr-parsed-id body (& name)))]
                    [(ast.AstDecl.DefMacro decl-meta name-id _ _ body)
                      (if (string.eq
                        (tc_core.tc-env-key-name-text name-id)
                        name)
                        name-id
                        (compiler-typecheck-smoke-expr-parsed-id body (& name)))]
                    [(ast.AstDecl.DefStruct decl-meta name-id _ _ _)
                      (if (string.eq
                        (tc_core.tc-env-key-name-text name-id)
                        name)
                        name-id
                        -1)]
                    [(ast.AstDecl.DefEnum decl-meta name-id _ _)
                      (if (string.eq
                        (tc_core.tc-env-key-name-text name-id)
                        name)
                        name-id
                        -1)]
                    [_ -1]))
                (set! index (+ index 1)))))
          found))]))

(define (compiler-typecheck-smoke-required-parsed-id
  [ctx : tc_core.TcContext]
  [context : String]
  [name : String]) : i64
  (let
    [name-id : i64
      (compiler-typecheck-smoke-program-parsed-id
        (tc_core.tc-context-program ctx)
        (tc_core.tc-global-shared-view name))]
    (if (>= name-id 0)
      name-id
      (io.panic (str_cat.str-cat context name)))))

(define (compiler-typecheck-smoke-module-key-id
  [ctx : tc_core.TcContext]
  [module : String]
  [name : String]) : i64
  (compiler_symbols.compiler-symbol-module-key-id-by-id
    (compiler-typecheck-smoke-required-parsed-id
      ctx
      "typecheck smoke: missing module id: "
      module)
    (compiler-typecheck-smoke-required-parsed-id
      ctx
      "typecheck smoke: missing name id: "
      name)))

(define (compiler-typecheck-smoke-qualified-cache-id?
  [ctx : tc_core.TcContext]
  [id : i64]
  [module : String]
  [name : String]) : bool
  (= id (compiler-typecheck-smoke-module-key-id ctx module name)))

(define (compiler-typecheck-smoke-lazy-import-explicit-alias-cache-ok?
  [entry-ctx : tc_core.TcContext]
  [env : tc_core.TcTypeEnv]) : bool
  (begin
    (tc_core.tc-source-dotted-alias-key-cache-reset!)
    (match (tc_core.tc-source-name-lookup-key-with-field-check
      entry-ctx
      env
      "helper.value"
      (compiler-typecheck-smoke-required-parsed-id
        entry-ctx
        "typecheck smoke: missing dotted lookup id: "
        "helper.value")
      true)
      [(tc_core.ResultTcString.Ok key)
        (let
          [module-id : i64
            (compiler-typecheck-smoke-required-parsed-id
              entry-ctx
              "typecheck smoke: missing entry module id: "
              "entry.module")]
          [name-id : i64
            (compiler-typecheck-smoke-required-parsed-id
              entry-ctx
              "typecheck smoke: missing dotted lookup id: "
              "helper.value")]
          (and
            (string.eq key "helper.module/value")
            (compiler-typecheck-smoke-qualified-cache-id?
              entry-ctx
              (core_tests.tc-source-dotted-alias-key-cache-get
                module-id
                name-id)
              "helper.module"
              "value")
            (match (tc_core.tc-source-name-lookup-key-with-field-check
              entry-ctx
              env
              "helper.value"
              name-id
              true)
              [(tc_core.ResultTcString.Ok cached-key)
                (string.eq cached-key key)]
              [(tc_core.ResultTcString.Err _) false])))]
      [(tc_core.ResultTcString.Err _) false])))

(define (compiler-typecheck-smoke-lazy-import-full-path-cache-checked?
  [full-ctx : tc_core.TcContext]
  [env : tc_core.TcTypeEnv]) : bool
  (begin
    (tc_core.tc-source-dotted-full-path-key-cache-reset!)
    (match (tc_core.tc-source-name-lookup-key-with-field-check
      full-ctx
      env
      "helper.module.value"
      (compiler-typecheck-smoke-required-parsed-id
        full-ctx
        "typecheck smoke: missing full dotted lookup id: "
        "helper.module.value")
      true)
      [(tc_core.ResultTcString.Ok key)
        (let
          [module-id : i64
            (compiler-typecheck-smoke-required-parsed-id
              full-ctx
              "typecheck smoke: missing full entry module id: "
              "full.entry")]
          [name-id : i64
            (compiler-typecheck-smoke-required-parsed-id
              full-ctx
              "typecheck smoke: missing full dotted lookup id: "
              "helper.module.value")]
          (and
            (string.eq key "helper.module/value")
            (compiler-typecheck-smoke-qualified-cache-id?
              full-ctx
              (core_tests.tc-source-dotted-full-path-key-cache-get
                module-id
                name-id)
              "helper.module"
              "value")
            (match (tc_core.tc-source-name-lookup-key-with-field-check
              full-ctx
              env
              "helper.module.value"
              name-id
              true)
              [(tc_core.ResultTcString.Ok cached-key)
                (string.eq cached-key key)]
              [(tc_core.ResultTcString.Err _) false])))]
      [(tc_core.ResultTcString.Err _) false])))

(define (compiler-typecheck-smoke-lazy-import-full-path-cache-ok?) : bool
  (let
    [ok : bool
      (match (parser.parse-ast-source-diagnostic
        ""
        "(module helper.module)
(define value : i64 41)
(module full.entry)
(import helper.module)
(define (full-score) : i64 helper.module.value)")
        [(parser.ResultAstProgramDiagnostic.Ok program)
          (match (tc_api.typecheck-compiler-program-with-paths-checked
            program
            (ast.ast-decl-path-list-new))
            [(tc_core.ResultCompilerTypecheckChecked.Ok _ ctx env _)
              (compiler-typecheck-smoke-lazy-import-full-path-cache-checked?
                (tc_core.tc-context-with-module-id
                  ctx
                  "full.entry"
                  (compiler-typecheck-smoke-required-parsed-id
                    ctx
                    "typecheck smoke: missing full.entry id: "
                    "full.entry"))
                env)]
            [(tc_core.ResultCompilerTypecheckChecked.Partial _ _ _ _) false]
            [(tc_core.ResultCompilerTypecheckChecked.Err _) false])]
        [(parser.ResultAstProgramDiagnostic.Err _) false])]
    (begin
      (tc_core.compiler-typecheck-reset-file-state!)
      ok)))

(define (compiler-typecheck-smoke-full-path-cache-derived-reset-ok?) : bool
  (let
    [module-id : i64 (ci.intern "reset.entry")]
    [name-id : i64 (ci.intern "stdlib.json.stringify")]
    [lookup-id : i64 (ci.intern "stdlib.json/stringify")]
    (begin
      (tc_core.tc-source-dotted-full-path-key-cache-reset!)
      (core_tests.tc-source-dotted-full-path-key-cache-put!
        module-id
        name-id
        lookup-id)
      (let
        [before : i64
          (core_tests.tc-source-dotted-full-path-key-cache-get
            module-id
            name-id)]
        (begin
          (tc_core.macro-alias-derived-cache-reset!)
          (and
            (= before lookup-id)
            (=
              (core_tests.tc-source-dotted-full-path-key-cache-get
                module-id
                name-id)
              -2)))))))

(define (compiler-typecheck-smoke-source-name-caches-intern-reset-ok?) : bool
  (begin
    (tc_core.tc-source-dotted-alias-key-cache-reset!)
    (tc_core.tc-source-dotted-full-path-key-cache-reset!)
    (tc_core.tc-source-qualified-variant-key-cache-reset!)
    (let
      [macro-state : tc_core.TcMacroState
        (tc_core.tc-job-state-macro-state (tc_core.tc-serial-job-state))]
      [registries : compiler_symbols.CompilerRegistries
        (compiler_symbols.compiler-registries-empty)]
      [registry-id : i64
        (compiler_symbols.compiler-registries-identity registries)]
      [old-module-id : i64 (ci.intern "generation.entry")]
      [old-alias-name-id : i64 (ci.intern "alias.value")]
      [old-full-name-id : i64 (ci.intern "full.path.value")]
      [old-variant-name-id : i64 (ci.intern "Choice.Full")]
      [old-alias-value-id : i64 (ci.intern "old.alias/value")]
      [old-full-value-id : i64 (ci.intern "old.full/value")]
      [old-variant-value-id : i64 (ci.intern "old.choice/Full")]
      [old-table-id : i64 (ci.intern-active-table-id)]
      [old-generation : i64 (ci.intern-generation)]
      [old-result-module-id : i64 (ci.intern "stdlib.result")]
      [old-result-name-id : i64 (ci.intern "result")]
      [_bind-source-names : unit
        (tc_core.tc-macro-state-bind-source-names!
          macro-state
          (ci.intern-source-name-session-capture-active-handle))]
      [_old-result-identity : unit
        (tc_core.macro-stdlib-result-identity-ensure! macro-state)]
      [old-result-identity : tc_core.TcMacroResultIdentityStateData
        (tc_core.tc-macro-result-identity-state-data macro-state)]
      [old-result-ids-current : bool
        (and
          (= old-result-identity.table-id old-table-id)
          (= old-result-identity.reset-generation old-generation)
          (= old-result-identity.module-id old-result-module-id)
          (= old-result-identity.macro-id old-result-name-id))]
      (begin
        (core_tests.tc-source-dotted-alias-key-cache-put!
          old-module-id
          old-alias-name-id
          old-alias-value-id)
        (core_tests.tc-source-dotted-full-path-key-cache-put!
          old-module-id
          old-full-name-id
          old-full-value-id)
        (core_tests.tc-source-qualified-variant-key-cache-put!
          registry-id
          old-module-id
          old-variant-name-id
          old-variant-value-id
          0)
        (ci.intern-reset!)
        (cbi.compiler-builtin-initialize-for-parse!)
        (tc_core.compiler-typecheck-reset-intern-owned-state!)
        (let
          [module-id : i64 (ci.intern "generation.entry")]
          [alias-name-id : i64 (ci.intern "alias.value")]
          [full-name-id : i64 (ci.intern "full.path.value")]
          [variant-name-id : i64 (ci.intern "Choice.Full")]
          [result-module-id : i64 (ci.intern "stdlib.result")]
          [result-name-id : i64 (ci.intern "result")]
          [_bind-result-source-names : unit
            (tc_core.tc-macro-state-bind-source-names!
              macro-state
              (ci.intern-source-name-session-capture-active-handle))]
          [_result-identity : unit
            (tc_core.macro-stdlib-result-identity-ensure! macro-state)]
          [result-identity : tc_core.TcMacroResultIdentityStateData
            (tc_core.tc-macro-result-identity-state-data macro-state)]
          [alias-miss : i64
            (core_tests.tc-source-dotted-alias-key-cache-get
              module-id
              alias-name-id)]
          [full-miss : i64
            (core_tests.tc-source-dotted-full-path-key-cache-get
              module-id
              full-name-id)]
          [variant-miss : i64
            (core_tests.tc-source-qualified-variant-key-cache-get
              registry-id
              module-id
              variant-name-id)]
          (begin
            (tc_core.compiler-typecheck-reset-file-state!)
            (and
              old-result-ids-current
              (= (ci.intern-active-table-id) old-table-id)
              (> (ci.intern-generation) old-generation)
              (= result-identity.table-id old-table-id)
              (= result-identity.reset-generation (ci.intern-generation))
              (= result-identity.module-id result-module-id)
              (= result-identity.macro-id result-name-id)
              (= alias-miss -2)
              (= full-miss -2)
              (= variant-miss -2))))))))

(define (compiler-typecheck-smoke-source-key-cache-state-isolation-ok?) : bool
  (let
    [job-a : tc_core.TcJobState (tc_core.tc-job-state-new)]
    [job-b : tc_core.TcJobState (tc_core.tc-job-state-new)]
    [state-a : tc_core.TcSourceKeyCacheState
      (tc_core.tc-job-state-source-key-cache job-a)]
    [state-b : tc_core.TcSourceKeyCacheState
      (tc_core.tc-job-state-source-key-cache job-b)]
    [table-a : i64 1001]
    [table-b : i64 2002]
    [generation-a : i64 7]
    [generation-b : i64 11]
    [registry-b : i64 3003]
    [module-id : i64 17]
    [name-id : i64 23]
    (begin
      (tc_core.tc-source-dotted-alias-key-cache-put-for-state!
        (tc_core.tc-global-shared-view state-a)
        table-a
        generation-a
        module-id
        name-id
        41)
      (tc_core.tc-source-dotted-alias-key-cache-put-for-state!
        (tc_core.tc-global-shared-view state-b)
        table-b
        generation-b
        module-id
        name-id
        42)
      (tc_core.tc-source-dotted-full-path-key-cache-put-for-state!
        (tc_core.tc-global-shared-view state-b)
        table-b
        generation-b
        module-id
        name-id
        43)
      (tc_core.tc-source-qualified-variant-key-cache-put-for-state!
        (tc_core.tc-global-shared-view state-b)
        table-b
        generation-b
        registry-b
        module-id
        name-id
        44
        45)
      (let
        [before-reset : bool
          (and
            (=
              (tc_core.tc-source-dotted-alias-key-cache-get-for-state
                (tc_core.tc-global-shared-view state-a)
                table-a
                generation-a
                module-id
                name-id)
              41)
            (=
              (tc_core.tc-source-dotted-alias-key-cache-get-for-state
                (tc_core.tc-global-shared-view state-b)
                table-b
                generation-b
                module-id
                name-id)
              42))]
        (begin
          (tc_core.tc-job-state-reset-file-state! job-a)
          (let
            [isolated-reset : bool
              (and
                (=
                  (tc_core.tc-source-dotted-alias-key-cache-get-for-state
                    state-a
                    table-a
                    generation-a
                    module-id
                    name-id)
                  -2)
                (=
                  (tc_core.tc-source-dotted-alias-key-cache-get-for-state
                    (tc_core.tc-global-shared-view state-b)
                    table-b
                    generation-b
                    module-id
                    name-id)
                  42)
                (=
                  (tc_core.tc-source-dotted-full-path-key-cache-get-for-state
                    (tc_core.tc-global-shared-view state-b)
                    table-b
                    generation-b
                    module-id
                    name-id)
                  43)
                (=
                  (tc_core.tc-source-qualified-variant-key-cache-get-for-state
                    (tc_core.tc-global-shared-view state-b)
                    table-b
                    generation-b
                    registry-b
                    module-id
                    name-id)
                  44)
                (=
                  (tc_core.tc-source-qualified-variant-handle-cache-get-for-state
                    (tc_core.tc-global-shared-view state-b)
                    table-b
                    generation-b
                    registry-b
                    module-id
                    name-id)
                  45))]
            [wrong-owner-miss : bool
              (=
                (tc_core.tc-source-dotted-alias-key-cache-get-for-state
                  (tc_core.tc-global-shared-view state-b)
                  table-a
                  generation-b
                  module-id
                  name-id)
                -2)]
            (begin
              (tc_core.tc-source-dotted-full-path-key-cache-put-for-state!
                (tc_core.tc-global-shared-view state-b)
                table-b
                generation-b
                module-id
                name-id
                46)
              (let
                [stale-generation-miss : bool
                  (=
                    (tc_core.tc-source-dotted-full-path-key-cache-get-for-state
                      state-b
                      table-b
                      (+ generation-b 1)
                      module-id
                      name-id)
                    -2)]
                (and
                  before-reset
                  isolated-reset
                  wrong-owner-miss
                  stale-generation-miss)))))))))

(define (compiler-typecheck-smoke-qualified-enum-variant-precedence-ok?) : bool
  (tc_tests.compiler-typecheck-ok?
    "(module provider.enums)
(defenum Choice (Empty) (Full i64))
(module entry.enums)
(import provider.enums as provider)
(defenum Choice (Empty) (Full i64))
(define (local-score [c : Choice]) : i64
  (match c
    [(Choice.Full n) n]
    [(Choice.Empty) 0]))
(define (provider-score [c : provider.Choice]) : i64
  (match c
    [(provider.Choice.Full n) n]
    [(provider.Choice.Empty) 0]))
(define (main) : i64
  (+ (local-score (Choice.Full 5))
     (provider-score (provider.Choice.Full 7))))"))

;; Dotted variants and bare module-local constructors share the same direct
;; cache storage but are distinct key domains. A dotted name misclassified as
;; bare can cache a false constructor miss that poisons later variant lookup.
;; In #6324, two unrelated helper declarations changed collision order and
;; surfaced that poisoned miss as a bogus CompilerCtfeValue.I64 lookup failure.
(define (compiler-typecheck-smoke-dotted-constructor-cache-domain-ok?) : bool
  (let
    [intern-state : ci.InternCompatState (ci.intern-compat-state-new)]
    [session : cis.InternStructuralSessionHandle
      (cis.intern-structural-session-handle-from-source-names
        (ci.intern-source-name-session-handle-from-state intern-state))]
    [bare-id : i64 (ci.intern "Full")]
    [dotted-id : i64 (ci.intern "Choice.Full")]
    [qualified-id : i64 (ci.intern "provider/Full")]
    (and
      (tc_core.tc-constructor-non-root-bare-name-id? session "entry" bare-id)
      (not
        (tc_core.tc-constructor-non-root-bare-name-id?
          session
          "entry"
          dotted-id))
      (not
        (tc_core.tc-constructor-non-root-bare-name-id?
          session
          "entry"
          qualified-id))
      (not (tc_core.tc-constructor-non-root-bare-name-id? session "" bare-id)))))

;; A user-defined Module macro exercises the same catalog path as stdlib.result.
;; `Choice` is a nominal/type/pattern-only surface; `make` and `score` are
;; independent helpers so the expanded body shows whether demand closure stays
;; narrow and grows when a later alias needs another member.
(define (compiler-typecheck-smoke-generic-catalog-type-only-source) : String
  "(defmacro (catalog) : Module
  `(begin
    (module generated.generic_catalog)
    (defenum Choice
      (Empty)
      (Full i64))
    (define (make [value : i64]) : Choice
      (Full value))
    (define (score [value : Choice]) : i64
      (match value
        [(Full inner) inner]
        [(Empty) 0]))))
(import (catalog) as api)
(define (read [value : api.Choice]) : i64
  (match value
    [(api.Full inner) inner]
    [(api.Empty) 0]))
(define (main) : i64 (read (api.Full 42)))")

(define (compiler-typecheck-smoke-generic-catalog-later-helper-source) : String
  "(defmacro (catalog) : Module
  `(begin
    (module generated.generic_catalog)
    (defenum Choice
      (Empty)
      (Full i64))
    (define (make [value : i64]) : Choice
      (Full value))
    (define (score [value : Choice]) : i64
      (match value
        [(Full inner) inner]
        [(Empty) 0]))))
(import (catalog) as type-api)
(import (catalog) as value-api)
(import (catalog) as unused-api)
(define (read [value : type-api.Choice]) : i64
  (match value
    [(type-api.Full inner) inner]
    [(type-api.Empty) 0]))
(define (main) : i64
  (+ (read (type-api.Full 1)) (read (value-api.make 41))))")

(define (compiler-typecheck-smoke-generic-catalog-closure-source) : String
  "(defmacro (catalog) : Module
  `(begin
    (module generated.generic_catalog_closure)
    (define (score [value : i64]) : i64
      (+ value (bonus)))
    (define (bonus) : i64 1)
    (define (unused) : i64 0)))
(import (catalog) as api)
(define (main) : i64 (api.score 41))")

(define (compiler-typecheck-smoke-generic-catalog-cycle-source) : String
  "(defmacro (catalog) : Module
  `(begin
    (module generated.generic_catalog_cycle)
    (define (even [value : i64]) : bool
      (if (= value 0) true (odd (- value 1))))
    (define (odd [value : i64]) : bool
      (if (= value 0) false (even (- value 1))))
    (define (unused) : i64 0)))
(import (catalog) as api)
(define (main) : i64 (if (api.even 42) 42 0))")

;; The canonical target spelling is observable after a first alias has caused
;; the catalog to exist. Its member demand must union with alias demand without
;; re-evaluating the Module macro.
(define (compiler-typecheck-smoke-generic-catalog-canonical-source) : String
  "(defmacro (catalog) : Module
  `(begin
    (module generated.generic_catalog_canonical)
    (defenum Choice
      (Empty)
      (Full i64))
    (define (make [value : i64]) : Choice
      (Full value))
    (define (score [value : Choice]) : i64
      (match value
        [(Full inner) inner]
        [(Empty) 0]))))
(import (catalog) as api)
(define (read [value : api.Choice]) : i64
  (match value
    [(api.Full inner) inner]
    [(api.Empty) 0]))
(define (main) : i64
  (+ (read (api.Full 1))
    (read (generated.generic_catalog_canonical.make 41))))")

(define (compiler-typecheck-smoke-generic-catalog-unused-source) : String
  "(defmacro (catalog) : Module
  `(begin
    (module generated.generic_catalog)
    (defenum Choice
      (Empty)
      (Full i64))
    (define (make [value : i64]) : Choice
      (Full value))))
(import (catalog) as unused-api)
(define (main) : i64 42)")

;; A lexical binding with the same spelling as an import alias is not a direct
;; catalog use. The demand observer keeps just these root bindings while it
;; avoids allocating environments for every unrelated local.
(define (compiler-typecheck-smoke-generic-catalog-shadowed-alias-source) : String
  "(defmacro (catalog) : Module
  `(begin
    (module generated.generic_catalog_shadow)
    (define (helper) : i64 42)))
(import (catalog) as api)
(define (shadow [api : i64]) : i64 api)
(define (main) : i64 (shadow 42))")

(define (compiler-typecheck-smoke-generic-catalog-full-source) : String
  "(defmacro (catalog) : Module
  `(begin
    (module generated.generic_catalog)
    (defenum Choice
      (Empty)
      (Full i64))
    (define (make [value : i64]) : Choice
      (Full value))
    (define (score [value : Choice]) : i64
      (match value
        [(Full inner) inner]
        [(Empty) 0]))))
(import (catalog) as api)
(define (main) : i64 (api.score (api.make 42)))")

(define (compiler-typecheck-smoke-generic-catalog-unqualified-source) : String
  "(defmacro (catalog) : Module
  `(begin
    (module generated.generic_catalog)
    (defenum Choice
      (Empty)
      (Full i64))
    (define (make [value : i64]) : Choice
      (Full value))
    (define (score [value : Choice]) : i64
      (match value
        [(Full inner) inner]
        [(Empty) 0]))))
(import (catalog))
(define (main) : i64 (score (make 42)))")

;; This spelling used to select the compiler-owned Result materializer, which
;; skipped transformer evaluation and accepted the malformed unused helper.
(define (compiler-typecheck-smoke-result-catalog-invalid-source) : String
  "(module stdlib.result)
(defmacro (result [T : type] [E : type]) : Module
  `(begin
    (module stdlib.result.generated.invalid)
    (defenum Result (Ok ,T) (Err ,E))
    (define broken : i64 true)))
(import (result.result i64 String) as unused-result)
(define (main) : i64 0)")

(define (compiler-typecheck-smoke-generated-catalog-body-has-name?
  [body : ast.AstDeclList]
  [name : String]) : bool
  (match (ast.ast-decl-list-step body)
    [(ast.AstDeclListStep.Nil) false]
    [(ast.AstDeclListStep.Cons decl rest)
      (or
        (match (tc_core.macro-generated-visible-name decl)
          [(SpecMaybeString.Some candidate) (string.eq candidate name)]
          [(SpecMaybeString.None) false])
        (compiler-typecheck-smoke-generated-catalog-body-has-name? rest name))]))

(define (compiler-typecheck-smoke-generic-catalog-expanded-name?
  [source : String]
  [module-name : String]
  [name : String]) : bool
  (let
    [ok : bool
      (match (parser.parse-ast-source-diagnostic "" source)
        [(parser.ResultAstProgramDiagnostic.Ok program)
          (match (tc_core.macro-expand-program program)
            [(tc_core.ResultMacroExpand.Ok expanded _)
              (match expanded
                [(ast.AstProgram.Program decls-box)
                  (let
                    [decls : ast.AstDeclList
                      (ast.ast-decl-list-box-shared-view decls-box)]
                    (if (tc_core.macro-module-exists?
                      (tc_core.tc-global-shared-view decls)
                      (tc_core.tc-global-shared-view module-name))
                      (compiler-typecheck-smoke-generated-catalog-body-has-name?
                        (tc_core.macro-collect-module-body-decls
                          decls
                          module-name
                          "")
                        name)
                      false))])]
            [(tc_core.ResultMacroExpand.Err _) false])]
        [(parser.ResultAstProgramDiagnostic.Err _) false])]
    (begin
      (tc_core.compiler-typecheck-reset-file-state!)
      ok)))

(define (compiler-typecheck-smoke-generic-catalog-expanded-module?
  [source : String]
  [module-name : String]) : bool
  (let
    [ok : bool
      (match (parser.parse-ast-source-diagnostic "" source)
        [(parser.ResultAstProgramDiagnostic.Ok program)
          (match (tc_core.macro-expand-program program)
            [(tc_core.ResultMacroExpand.Ok expanded _)
              (match expanded
                [(ast.AstProgram.Program decls-box)
                  (tc_core.macro-module-exists?
                    (ast.ast-decl-list-box-shared-view decls-box)
                    module-name)])]
            [(tc_core.ResultMacroExpand.Err _) false])]
        [(parser.ResultAstProgramDiagnostic.Err _) false])]
    (begin
      (tc_core.compiler-typecheck-reset-file-state!)
      ok)))

(define (compiler-typecheck-smoke-generic-catalog-ok?) : bool
  (begin
    (compiler-typecheck-smoke-require
      (tc_tests.compiler-typecheck-ok?
        (compiler-typecheck-smoke-generic-catalog-type-only-source))
      "generic catalog type-only typecheck")
    (compiler-typecheck-smoke-require
      (compiler-typecheck-smoke-generic-catalog-expanded-name?
        (compiler-typecheck-smoke-generic-catalog-type-only-source)
        "generated.generic_catalog"
        "Choice")
      "generic catalog type-only missing Choice")
    (compiler-typecheck-smoke-require
      (not
        (compiler-typecheck-smoke-generic-catalog-expanded-name?
          (compiler-typecheck-smoke-generic-catalog-type-only-source)
          "generated.generic_catalog"
          "make"))
      "generic catalog type-only retained make")
    (compiler-typecheck-smoke-require
      (not
        (compiler-typecheck-smoke-generic-catalog-expanded-name?
          (compiler-typecheck-smoke-generic-catalog-type-only-source)
          "generated.generic_catalog"
          "score"))
      "generic catalog type-only retained score")
    (compiler-typecheck-smoke-require
      (tc_tests.compiler-typecheck-ok?
        (compiler-typecheck-smoke-generic-catalog-later-helper-source))
      "generic catalog later-helper typecheck")
    (compiler-typecheck-smoke-require
      (compiler-typecheck-smoke-generic-catalog-expanded-name?
        (compiler-typecheck-smoke-generic-catalog-later-helper-source)
        "generated.generic_catalog"
        "Choice")
      "generic catalog later-helper missing Choice")
    (compiler-typecheck-smoke-require
      (compiler-typecheck-smoke-generic-catalog-expanded-name?
        (compiler-typecheck-smoke-generic-catalog-later-helper-source)
        "generated.generic_catalog"
        "make")
      "generic catalog later-helper missing make")
    (compiler-typecheck-smoke-require
      (not
        (compiler-typecheck-smoke-generic-catalog-expanded-name?
          (compiler-typecheck-smoke-generic-catalog-later-helper-source)
          "generated.generic_catalog"
          "score"))
      "generic catalog later-helper retained score")
    (compiler-typecheck-smoke-require
      (tc_tests.compiler-typecheck-ok?
        (compiler-typecheck-smoke-generic-catalog-closure-source))
      "generic catalog closure typecheck")
    (compiler-typecheck-smoke-require
      (compiler-typecheck-smoke-generic-catalog-expanded-name?
        (compiler-typecheck-smoke-generic-catalog-closure-source)
        "generated.generic_catalog_closure"
        "score")
      "generic catalog closure missing score")
    (compiler-typecheck-smoke-require
      (compiler-typecheck-smoke-generic-catalog-expanded-name?
        (compiler-typecheck-smoke-generic-catalog-closure-source)
        "generated.generic_catalog_closure"
        "bonus")
      "generic catalog closure missing bonus")
    (compiler-typecheck-smoke-require
      (not
        (compiler-typecheck-smoke-generic-catalog-expanded-name?
          (compiler-typecheck-smoke-generic-catalog-closure-source)
          "generated.generic_catalog_closure"
          "unused"))
      "generic catalog closure retained unused")
    (compiler-typecheck-smoke-require
      (tc_tests.compiler-typecheck-ok?
        (compiler-typecheck-smoke-generic-catalog-cycle-source))
      "generic catalog cyclic closure typecheck")
    (compiler-typecheck-smoke-require
      (compiler-typecheck-smoke-generic-catalog-expanded-name?
        (compiler-typecheck-smoke-generic-catalog-cycle-source)
        "generated.generic_catalog_cycle"
        "even")
      "generic catalog cyclic closure missing even")
    (compiler-typecheck-smoke-require
      (compiler-typecheck-smoke-generic-catalog-expanded-name?
        (compiler-typecheck-smoke-generic-catalog-cycle-source)
        "generated.generic_catalog_cycle"
        "odd")
      "generic catalog cyclic closure missing odd")
    (compiler-typecheck-smoke-require
      (not
        (compiler-typecheck-smoke-generic-catalog-expanded-name?
          (compiler-typecheck-smoke-generic-catalog-cycle-source)
          "generated.generic_catalog_cycle"
          "unused"))
      "generic catalog cyclic closure retained unused")
    (compiler-typecheck-smoke-require
      (tc_tests.compiler-typecheck-ok?
        (compiler-typecheck-smoke-generic-catalog-canonical-source))
      "generic catalog canonical typecheck")
    (compiler-typecheck-smoke-require
      (compiler-typecheck-smoke-generic-catalog-expanded-name?
        (compiler-typecheck-smoke-generic-catalog-canonical-source)
        "generated.generic_catalog_canonical"
        "Choice")
      "generic catalog canonical missing Choice")
    (compiler-typecheck-smoke-require
      (compiler-typecheck-smoke-generic-catalog-expanded-name?
        (compiler-typecheck-smoke-generic-catalog-canonical-source)
        "generated.generic_catalog_canonical"
        "make")
      "generic catalog canonical missing make")
    (compiler-typecheck-smoke-require
      (not
        (compiler-typecheck-smoke-generic-catalog-expanded-name?
          (compiler-typecheck-smoke-generic-catalog-canonical-source)
          "generated.generic_catalog_canonical"
          "score"))
      "generic catalog canonical retained score")
    (compiler-typecheck-smoke-require
      (tc_tests.compiler-typecheck-ok?
        (compiler-typecheck-smoke-generic-catalog-unused-source))
      "generic catalog unused typecheck")
    (compiler-typecheck-smoke-require
      (not
        (compiler-typecheck-smoke-generic-catalog-expanded-module?
          (compiler-typecheck-smoke-generic-catalog-unused-source)
          "generated.generic_catalog"))
      "generic catalog unused materialized module")
    (compiler-typecheck-smoke-require
      (tc_tests.compiler-typecheck-ok?
        (compiler-typecheck-smoke-generic-catalog-shadowed-alias-source))
      "generic catalog shadowed alias typecheck")
    (compiler-typecheck-smoke-require
      (not
        (compiler-typecheck-smoke-generic-catalog-expanded-module?
          (compiler-typecheck-smoke-generic-catalog-shadowed-alias-source)
          "generated.generic_catalog_shadow"))
      "generic catalog shadowed alias materialized module")
    (compiler-typecheck-smoke-require
      (tc_tests.compiler-typecheck-ok?
        (compiler-typecheck-smoke-generic-catalog-full-source))
      "generic catalog full typecheck")
    (compiler-typecheck-smoke-require
      (compiler-typecheck-smoke-generic-catalog-expanded-name?
        (compiler-typecheck-smoke-generic-catalog-full-source)
        "generated.generic_catalog"
        "score")
      "generic catalog full missing score")
    (compiler-typecheck-smoke-require
      (tc_tests.compiler-typecheck-ok?
        (compiler-typecheck-smoke-generic-catalog-unqualified-source))
      "generic catalog unqualified typecheck")
    (compiler-typecheck-smoke-require
      (compiler-typecheck-smoke-generic-catalog-expanded-name?
        (compiler-typecheck-smoke-generic-catalog-unqualified-source)
        "generated.generic_catalog"
        "score")
      "generic catalog unqualified missing score")
    (compiler-typecheck-smoke-require
      (tc_tests.compiler-typecheck-ok?
        "(defmacro (catalog) : Module
  `(begin
    (module generated.generic_macro_catalog)
    (defmacro (one) : i64 `1)
    (define (helper) : i64 42)))
(import (catalog) as api)
(define (main) : i64 (api.one))")
      "generic catalog qualified macro typecheck")
    (compiler-typecheck-smoke-require
      (tc_tests.compiler-typecheck-ok?
        "(defmacro (catalog) : Module
  `(begin
    (module generated.generic_macro_catalog)
    (defmacro (one) : i64 `1)
    (define (helper) : i64 42)))
(import (catalog))
(define (main) : i64 (one))")
      "generic catalog direct macro typecheck")
    (compiler-typecheck-smoke-require
      (tc_tests.compiler-typecheck-error-ok?
        "(defmacro (invalid-catalog) : Module
  `(begin
    (module generated.invalid_catalog)
    (defenum Choice (Empty) (Full i64))
    (define broken : i64 true)))
(import (invalid-catalog) as unused-api)
(define (main) : i64 0)"
        "typecheck: value definition type mismatch: expected i64, found bool")
      "generic catalog invalid helper accepted or changed diagnostic")
    (compiler-typecheck-smoke-require
      (tc_tests.compiler-typecheck-error-ok?
        (compiler-typecheck-smoke-result-catalog-invalid-source)
        "typecheck: value definition type mismatch: expected i64, found bool")
      "Result-spelled catalog invalid helper accepted or changed diagnostic")
    true))

(define (compiler-typecheck-smoke-lazy-import-explicit-alias-no-fanout-ok?) : bool
  (let
    [ok : bool
      (match (parser.parse-ast-source-diagnostic
        ""
        "(module helper.module)
(define value : i64 41)
(define (get) : i64 value)
(defstruct Item (n i64))
(defenum Choice (Empty) (Full i64))
(extern (foreign [x : i64]) : i64)
(module entry.module)
(import helper.module as helper)
(defstruct LocalHelper (value bool))
(define (shadow [helper : LocalHelper]) : bool helper.value)
(define (score [item : helper.Item]) : i64
  (+
    (helper.get)
    (+
      helper.value
      (match (helper.Choice.Full item.n)
        [(helper.Choice.Full n) n]
        [(helper.Choice.Empty) 0]))))
(define (main) : i64 (score (helper.Item 1)))")
        [(parser.ResultAstProgramDiagnostic.Ok program)
          (match (tc_api.typecheck-compiler-program-with-paths-checked
            program
            (ast.ast-decl-path-list-new))
            [(tc_core.ResultCompilerTypecheckChecked.Ok _ ctx env _)
              (let
                [entry-ctx : tc_core.TcContext
                  (tc_core.tc-context-with-module-id
                    ctx
                    "entry.module"
                    (compiler-typecheck-smoke-required-parsed-id
                      ctx
                      "typecheck smoke: missing entry.module id: "
                      "entry.module"))]
                (and
                  (= (core_tests.tc-lazy-import-stub-count) 1)
                  (= (core_tests.tc-lazy-import-summary-backed-stub-count) 1)
                  (not
                    (tc_core.tc-name-bound-id?
                      env
                      (compiler-typecheck-smoke-module-key-id
                        entry-ctx
                        "helper"
                        "value")))
                  (tc_core.tc-name-bound-id?
                    env
                    (compiler-typecheck-smoke-module-key-id
                      entry-ctx
                      "helper.module"
                      "value"))
                  (match (core_tests.tc-lookup-dotted-source-visible
                    entry-ctx
                    env
                    "helper.value"
                    (compiler-typecheck-smoke-required-parsed-id
                      entry-ctx
                      "typecheck smoke: missing helper.value id: "
                      "helper.value"))
                    [(tc_core.ResultTcType.Ok _) true]
                    [(tc_core.ResultTcType.Err _) false])
                  (compiler-typecheck-smoke-lazy-import-explicit-alias-cache-ok?
                    entry-ctx
                    env)
                  (match (core_tests.tc-lookup-dotted-source-visible
                    entry-ctx
                    env
                    "helper.get"
                    (compiler-typecheck-smoke-required-parsed-id
                      entry-ctx
                      "typecheck smoke: missing helper.get id: "
                      "helper.get"))
                    [(tc_core.ResultTcType.Ok _) true]
                    [(tc_core.ResultTcType.Err _) false])
                  (match (core_tests.tc-lookup-dotted-source-visible
                    entry-ctx
                    env
                    "helper.Choice.Full"
                    (compiler-typecheck-smoke-required-parsed-id
                      entry-ctx
                      "typecheck smoke: missing helper.Choice.Full id: "
                      "helper.Choice.Full"))
                    [(tc_core.ResultTcType.Ok _) true]
                    [(tc_core.ResultTcType.Err _) false])
                  (match (tc_core.tc-dotted-type-name-lookup-key-from-id
                    entry-ctx
                    "helper.Item"
                    (compiler-typecheck-smoke-required-parsed-id
                      entry-ctx
                      "typecheck smoke: missing helper.Item id: "
                      "helper.Item"))
                    [(tc_core.ResultTcString.Ok key)
                      (string.eq key "helper.module/Item")]
                    [(tc_core.ResultTcString.Err _) false])
                  (match (tc_core.tc-module-local-env-id
                    entry-ctx
                    env
                    "entry.module"
                    (tc_core.tc-context-module-id entry-ctx))
                    [(tc_core.ResultTcEnv.Ok local-env)
                      (and
                        (not
                          (tc_core.tc-name-bound-id?
                            local-env
                            (compiler-typecheck-smoke-module-key-id
                              entry-ctx
                              "helper"
                              "value")))
                        (match (core_tests.tc-lookup-dotted-source-visible
                          entry-ctx
                          local-env
                          "helper.value"
                          (compiler-typecheck-smoke-required-parsed-id
                            entry-ctx
                            "typecheck smoke: missing helper.value id: "
                            "helper.value"))
                          [(tc_core.ResultTcType.Ok _) true]
                          [(tc_core.ResultTcType.Err _) false]))]
                    [(tc_core.ResultTcEnv.Err _) false])))]
            [(tc_core.ResultCompilerTypecheckChecked.Partial _ _ _ _) false]
            [(tc_core.ResultCompilerTypecheckChecked.Err _) false])]
        [(parser.ResultAstProgramDiagnostic.Err _) false])]
    (begin
      (tc_core.compiler-typecheck-reset-file-state!)
      ok)))

(define (compiler-typecheck-smoke-lazy-import-stdlib-summary-backed-ok?) : bool
  (let
    [ok : bool
      (match (tc_api.typecheck-compiler-source-load
        "(module main)
(import stdlib.vector as vec)
(define (main) : i64 0)")
        [(load.ResultCompilerLoadWithPaths.Ok decls paths _ _)
          (match (tc_api.typecheck-compiler-program-with-paths-checked
            (ast.ast-program decls)
            paths)
            [(tc_core.ResultCompilerTypecheckChecked.Ok _ _ env _)
              (and
                (> (core_tests.tc-lazy-import-summary-backed-stub-count) 0)
                (not
                  (tc_core.tc-name-bound-id?
                    env
                    (ci.intern
                      (compiler_symbols.compiler-symbol-module-key "vec" "Vec")))))]
            [(tc_core.ResultCompilerTypecheckChecked.Partial _ _ _ _) false]
            [(tc_core.ResultCompilerTypecheckChecked.Err _) false])]
        [(load.ResultCompilerLoadWithPaths.Err _) false])]
    (begin
      (tc_core.compiler-typecheck-reset-file-state!)
      (load.compiler-load-surface-summaries-reset!)
      ok)))

(define (compiler-typecheck-smoke-lazy-import-stdlib-result-macro-ok?) : bool
  (let
    [ok : bool
      (begin
        (load.compiler-load-test-mkdir "target/tc_lazy_stdlib_result")
        (compiler-typecheck-smoke-write-text
          "target/tc_lazy_stdlib_result/result.tl"
          "(module main)
(import stdlib.result)
(import (result.result i64 String) as result_i64_string)
(define (main) : i64 42)")
        (match (load.compiler-load-file-with-paths
          "target/tc_lazy_stdlib_result/result.tl"
          (sym_i64_env.sym-i64-empty))
          [(load.ResultCompilerLoadWithPaths.Ok decls paths _ _)
            (let
              [skip-count : i64 (load.compiler-load-lazy-import-skip-count)]
              [result-materialized : bool
                (compiler-typecheck-smoke-paths-contain?
                  (tc_core.tc-global-shared-view paths)
                  "stdlib/result.tl")]
              (match (tc_api.typecheck-compiler-program-with-paths-checked
                (ast.ast-program decls)
                paths)
                [(tc_core.ResultCompilerTypecheckChecked.Ok _ _ _ _)
                  (and (= skip-count 0) result-materialized)]
                [(tc_core.ResultCompilerTypecheckChecked.Partial _ _ _ _) false]
                [(tc_core.ResultCompilerTypecheckChecked.Err diag)
                  (let
                    [first : diagnostic.CompilerDiagnostic
                      (diagnostic.compiler-diagnostic-list-first
                        (diagnostic.compiler-diagnostic-list-box-shared-view
                          diag))]
                    [message : String
                      (diagnostic.compiler-diagnostic-message first)]
                    (begin
                      (io.stderr-write (byte_buf.str-as-bytes (& message)))
                      false))]))]
          [(load.ResultCompilerLoadWithPaths.Err _) false]))]
    (begin
      (tc_core.compiler-typecheck-reset-file-state!)
      (load.compiler-load-surface-summaries-reset!)
      ok)))

(define (compiler-typecheck-smoke-unused-result-import-local-type-ok?) : bool
  (let
    [ok : bool
      (begin
        (load.compiler-load-test-mkdir "target/tc_unused_result_local_type")
        (compiler-typecheck-smoke-write-text
          "target/tc_unused_result_local_type/main.tl"
          "(module main)
(import stdlib.result)

(defstruct LocalError
  (message String))

(import (result.result i64 LocalError) as local_result_unused)

(define (main) : i64 42)")
        (match (load.compiler-load-file-with-paths
          "target/tc_unused_result_local_type/main.tl"
          (sym_i64_env.sym-i64-empty))
          [(load.ResultCompilerLoadWithPaths.Ok decls paths _ _)
            (match (tc_api.typecheck-compiler-program-with-paths-checked
              (ast.ast-program decls)
              paths)
              [(tc_core.ResultCompilerTypecheckChecked.Ok _ _ _ _) true]
              [(tc_core.ResultCompilerTypecheckChecked.Partial _ _ _ _) false]
              [(tc_core.ResultCompilerTypecheckChecked.Err diag)
                (let
                  [first : diagnostic.CompilerDiagnostic
                    (diagnostic.compiler-diagnostic-list-first
                      (diagnostic.compiler-diagnostic-list-box-shared-view diag))]
                  [message : String
                    (diagnostic.compiler-diagnostic-message first)]
                  (begin
                    (io.stderr-write (byte_buf.str-as-bytes (& message)))
                    false))])]
          [(load.ResultCompilerLoadWithPaths.Err _) false]))]
    (begin
      (tc_core.compiler-typecheck-reset-file-state!)
      (load.compiler-load-surface-summaries-reset!)
      ok)))

(define (compiler-typecheck-smoke-result-enum-then-helper-ok?) : bool
  (let
    [ok : bool
      (begin
        (load.compiler-load-test-mkdir "target/tc_result_enum_then_helper")
        (compiler-typecheck-smoke-write-text
          "target/tc_result_enum_then_helper/main.tl"
          "(module main)
(import stdlib.result)
(import (result.result i64 String) as r_enum)
(import (result.result i64 String) as r_helper)

(define (score [value : r_enum.Result]) : i64
  (match value
    [(r_enum.Ok v) v]
    [(r_enum.Err _) 0]))

(define (main) : i64
  (+ (score (r_helper.ok 40)) (r_helper.value-or (r_helper.err \"bad\") 2)))")
        (match (load.compiler-load-file-with-paths
          "target/tc_result_enum_then_helper/main.tl"
          (sym_i64_env.sym-i64-empty))
          [(load.ResultCompilerLoadWithPaths.Ok decls paths _ _)
            (match (tc_api.typecheck-compiler-program-with-paths-checked
              (ast.ast-program decls)
              paths)
              [(tc_core.ResultCompilerTypecheckChecked.Ok _ _ _ _) true]
              [(tc_core.ResultCompilerTypecheckChecked.Partial _ _ _ _) false]
              [(tc_core.ResultCompilerTypecheckChecked.Err diag)
                (let
                  [first : diagnostic.CompilerDiagnostic
                    (diagnostic.compiler-diagnostic-list-first
                      (diagnostic.compiler-diagnostic-list-box-shared-view diag))]
                  [message : String
                    (diagnostic.compiler-diagnostic-message first)]
                  (begin
                    (io.stderr-write (byte_buf.str-as-bytes (& message)))
                    false))])]
          [(load.ResultCompilerLoadWithPaths.Err _) false]))]
    (begin
      (tc_core.compiler-typecheck-reset-file-state!)
      (load.compiler-load-surface-summaries-reset!)
      ok)))

(define (compiler-typecheck-smoke-lazy-import-str-cat-macro-ok?) : bool
  (let
    [ok : bool
      (match (tc_api.typecheck-compiler-source-load
        "(module main)
(import stdlib.str_cat)
(define (main) : String
  (str_cat.str-cat \"a\" \"b\" \"c\" \"d\" \"e\"))")
        [(load.ResultCompilerLoadWithPaths.Ok decls paths _ _)
          (match (tc_api.typecheck-compiler-program-with-paths-checked
            (ast.ast-program decls)
            paths)
            [(tc_core.ResultCompilerTypecheckChecked.Ok _ _ _ _) true]
            [(tc_core.ResultCompilerTypecheckChecked.Partial _ _ _ _) false]
            [(tc_core.ResultCompilerTypecheckChecked.Err _) false])]
        [(load.ResultCompilerLoadWithPaths.Err _) false])]
    (begin
      (tc_core.compiler-typecheck-reset-file-state!)
      (load.compiler-load-surface-summaries-reset!)
      ok)))

(define (compiler-typecheck-smoke-runtime-str-cat-two-nested-ok?) : bool
  (let
    [ok : bool
      (match (tc_api.typecheck-compiler-source-load
        "(module main)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.string)

(defstruct Span
  (line i64)
  (col i64))

(define (span-line [span : (& span Span)]) : i64
  span.line)

(define (span-col [span : (& span Span)]) : i64
  span.col)

(define (render [span : Span]) : String
  (str_cat.str-cat
    \"a\"
    \"b\"
    (string.int->string (span-line span))
    \"d\"
    (string.int->string (span-col span))
    \"f\"))

(define (main) : i64 0)")
        [(load.ResultCompilerLoadWithPaths.Ok decls paths _ _)
          (match (tc_api.typecheck-compiler-program-with-paths-checked
            (ast.ast-program decls)
            paths)
            [(tc_core.ResultCompilerTypecheckChecked.Ok _ _ _ _) true]
            [(tc_core.ResultCompilerTypecheckChecked.Partial _ _ _ _) false]
            [(tc_core.ResultCompilerTypecheckChecked.Err _) false])]
        [(load.ResultCompilerLoadWithPaths.Err _) false])]
    (begin
      (tc_core.compiler-typecheck-reset-file-state!)
      (load.compiler-load-surface-summaries-reset!)
      ok)))

(define (compiler-typecheck-smoke-registry-member-diagnostic-ok?
  [src : String]
  [path : String]
  [message : String]) : bool
  (match (parser.parse-ast-source src)
    [(parser.ResultAstProgram.Ok program)
      (match (tc_api.typecheck-compiler-program-with-paths
        program
        (ast.ast-decl-root-path-cons
          "support.tl"
          (ast.ast-decl-root-path-cons
            (tc_core.tc-global-shared-view path)
            (ast.ast-decl-path-list-new))))
        [(tc_core.ResultCompilerTypecheck.Err diag)
          (let
            [value : diagnostic.CompilerDiagnostic
              (diagnostic.compiler-diagnostic-list-first
                (diagnostic.compiler-diagnostic-list-box-shared-view diag))]
            (and
              (string.eq (diagnostic.compiler-diagnostic-message value) message)
              (string.eq (diagnostic.compiler-diagnostic-path value) path)
              (= (diagnostic.compiler-diagnostic-line value) 4)
              (= (diagnostic.compiler-diagnostic-col value) 3)))]
        [(tc_core.ResultCompilerTypecheck.Ok _) false])]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-typecheck-scoped-marker-queries-ok?) : bool
  (let
    [was-active : bool
      (tc_core.tc-type-env-scoped-runtime-active? (tc_core.tc-default-env))]
    [runtime-tail-id : i64 (ci.intern "runtime-tail")]
    [tail-resource-id : i64 (ci.intern "tail-resource")]
    [tail-arena-id : i64 (ci.intern "tail-arena")]
    [tail-atomic-id : i64 (ci.intern "tail-atomic")]
    [outer-id : i64 (ci.intern "outer")]
    [resource-id : i64 (ci.intern "resource")]
    [arena-id : i64 (ci.intern "arena")]
    [atomic-id : i64 (ci.intern "atomic")]
    [tail-value-env : tc_core.TcTypeEnv
      (tc_core.tc-bind-id
        (tc_core.tc-default-env)
        runtime-tail-id
        (ast.AstType.String))]
    [tail-cleanup-env : tc_core.TcTypeEnv
      (tc_core.tc-bind-id
        (core_tests.tc-bind-cleanup-owner tail-value-env tail-resource-id)
        tail-resource-id
        (ast.AstType.String))]
    [tail-arena-env : tc_core.TcTypeEnv
      (tc_core.tc-bind-id
        (tc_core.tc-bind-ordinary-arena-owner tail-cleanup-env tail-arena-id)
        tail-arena-id
        (ast.AstType.I64))]
    [tail-atomic-env : tc_core.TcTypeEnv
      (tc_core.tc-bind-id
        (tc_core.tc-bind-atomic-arena-owner tail-arena-env tail-atomic-id)
        tail-atomic-id
        (ast.AstType.I64))]
    [base-env : tc_core.TcTypeEnv
      (tc_core.tc-push-region
        (tc_core.tc-env-with-cache tail-atomic-env)
        outer-id)]
    [outer-save : tc_core.TcTypeEnvScopedRuntimeSave
      (tc_core.tc-type-env-scoped-runtime-enter!
        (tc_core.tc-type-env-scoped-carrier-from-env base-env))]
    [resource-env : tc_core.TcTypeEnv
      (tc_core.tc-bind-id
        (core_tests.tc-bind-cleanup-owner base-env resource-id)
        resource-id
        (ast.AstType.String))]
    [arena-env : tc_core.TcTypeEnv
      (tc_core.tc-bind-id
        (tc_core.tc-bind-ordinary-arena-owner resource-env arena-id)
        arena-id
        (ast.AstType.I64))]
    [runtime-env : tc_core.TcTypeEnv
      (tc_core.tc-bind-id
        (tc_core.tc-bind-atomic-arena-owner arena-env atomic-id)
        atomic-id
        (ast.AstType.I64))]
    [scope-save : tc_core.TcTypeEnvScopedRuntimeSave
      (tc_core.tc-type-env-scoped-runtime-save runtime-env)]
    [before-shadow : bool
      (and
        (tc_core.tc-cleanup-owner-active-id? runtime-env resource-id)
        (tc_core.tc-ordinary-arena-owner-active-id? runtime-env arena-id)
        (not (tc_core.tc-atomic-arena-owner-active-id? runtime-env arena-id))
        (tc_core.tc-atomic-arena-owner-active-id? runtime-env atomic-id)
        (not (tc_core.tc-ordinary-arena-owner-active-id? runtime-env atomic-id))
        (tc_core.tc-cleanup-owner-active-id? runtime-env tail-resource-id)
        (tc_core.tc-ordinary-arena-owner-active-id? runtime-env tail-arena-id)
        (not
          (tc_core.tc-atomic-arena-owner-active-id? runtime-env tail-arena-id))
        (tc_core.tc-atomic-arena-owner-active-id? runtime-env tail-atomic-id)
        (not
          (tc_core.tc-ordinary-arena-owner-active-id?
            runtime-env
            tail-atomic-id))
        (tc_core.tc-lifetime-visible-id? runtime-env outer-id)
        (tc_core.tc-lifetime-visible-id? runtime-env resource-id)
        (not (tc_core.tc-lifetime-visible-id? runtime-env runtime-tail-id))
        (tc_core.tc-lifetime-outlives-binding-id?
          runtime-env
          outer-id
          resource-id)
        (tc_core.tc-lifetime-outlives-binding-id?
          runtime-env
          resource-id
          arena-id)
        (not
          (tc_core.tc-lifetime-outlives-binding-id?
            runtime-env
            arena-id
            resource-id))
        (tc_core.tc-lifetime-outlives-lifetime-id?
          runtime-env
          outer-id
          resource-id)
        (tc_core.tc-lifetime-outlives-lifetime-id?
          runtime-env
          resource-id
          arena-id)
        (not
          (tc_core.tc-lifetime-outlives-lifetime-id?
            runtime-env
            arena-id
            resource-id)))]
    [shadow-env : tc_core.TcTypeEnv
      (tc_core.tc-bind-id runtime-env resource-id (ast.AstType.Bool))]
    [shadowed : bool
      (and
        (not (tc_core.tc-cleanup-owner-active-id? shadow-env resource-id))
        (tc_core.tc-lifetime-visible-id? shadow-env resource-id))]
    (begin
      (tc_core.tc-type-env-scoped-runtime-restore! scope-save)
      (let
        [restored : bool
          (and
            (tc_core.tc-cleanup-owner-active-id? runtime-env resource-id)
            (tc_core.tc-ordinary-arena-owner-active-id? runtime-env arena-id)
            (tc_core.tc-atomic-arena-owner-active-id? runtime-env atomic-id)
            (tc_core.tc-lifetime-outlives-binding-id?
              runtime-env
              outer-id
              resource-id))]
        (begin
          (tc_core.tc-type-env-scoped-runtime-restore! outer-save)
          (and
            (not was-active)
            (not (tc_core.tc-type-env-scoped-runtime-active? runtime-env))
            before-shadow
            shadowed
            restored))))))

(define (compiler-typecheck-scoped-marker-replaced-cache-ok?) : bool
  (let
    [cache-owner-id : i64 (ci.intern "cache-owner")]
    [outer-env : tc_core.TcTypeEnv
      (tc_core.tc-bind-id
        (tc_core.tc-default-env)
        cache-owner-id
        (ast.AstType.I64))]
    [inactive-save : tc_core.TcTypeEnvScopedRuntimeSave
      (tc_core.tc-type-env-scoped-runtime-enter!
        (tc_core.tc-type-env-scoped-carrier-from-env outer-env))]
    [outer-visible-before : bool
      (tc_core.tc-lifetime-visible-id? outer-env cache-owner-id)]
    [outer-save : tc_core.TcTypeEnvScopedRuntimeSave
      (tc_core.tc-type-env-scoped-runtime-enter!
        (tc_core.tc-type-env-scoped-carrier-from-env (tc_core.tc-default-env)))]
    [inner-hidden : bool
      (not
        (tc_core.tc-lifetime-visible-id?
          (tc_core.tc-default-env)
          cache-owner-id))]
    (begin
      (tc_core.tc-type-env-scoped-runtime-restore! outer-save)
      (let
        [outer-visible-after : bool
          (tc_core.tc-lifetime-visible-id? outer-env cache-owner-id)]
        (begin
          (tc_core.tc-type-env-scoped-runtime-restore! inactive-save)
          (and
            outer-visible-before
            inner-hidden
            outer-visible-after
            (not (tc_core.tc-type-env-scoped-runtime-active? outer-env))))))))

(define (compiler-typecheck-smoke-hygiene-structural-ids-ok?) : bool
  (let
    [intern-a : ci.InternCompatState (ci.intern-compat-state-new)]
    [intern-b : ci.InternCompatState (ci.intern-compat-state-new)]
    [session-a : cis.InternStructuralSessionHandle
      (cis.intern-structural-session-handle-from-source-names
        (ci.intern-source-name-session-handle-from-state intern-a))]
    [session-b : cis.InternStructuralSessionHandle
      (cis.intern-structural-session-handle-from-source-names
        (ci.intern-source-name-session-handle-from-state intern-b))]
    [source-id : i64 17]
    [module-id : i64 23]
    [declaration-id : i64 42]
    [root-module-id : i64 (compiler_symbols.compiler-symbol-root-module-id)]
    [legacy-id : i64
      (tc_core.macro-hygiene-global-id session-a module-id source-id true)]
    [context-id : i64
      (tc_core.macro-hygiene-global-id session-a module-id source-id false)]
    [root-context-id : i64
      (tc_core.macro-hygiene-global-id session-a root-module-id source-id false)]
    ;; The structural map starts with 512 slots. Adding 512 to one component
    ;; preserves its first bucket while still requiring a distinct record.
    [collision-context-id : i64
      (tc_core.macro-hygiene-global-id
        session-a
        module-id
        (+ source-id 512)
        false)]
    [definition-a : cis.InternMacroDefinitionIdentity
      (cis.intern-structural-session-macro-definition-identity
        session-a
        root-module-id
        source-id)]
    [definition-a-again : cis.InternMacroDefinitionIdentity
      (cis.intern-structural-session-macro-definition-identity
        session-a
        root-module-id
        source-id)]
    [direct-local-id : i64
      (tc_core.macro-hygiene-local-id
        session-a
        (tc_core.MacroHygieneContext
          source-id
          root-module-id
          declaration-id
          (compiler_symbols.compiler-symbols-empty))
        3
        source-id)]
    [surface-local-id : i64
      (tc_core.macro-hygiene-local-id
        session-a
        (tc_core.MacroHygieneContext
          source-id
          root-module-id
          -1
          (compiler_symbols.compiler-symbols-empty))
        3
        source-id)]
    [other-macro-local-id : i64
      (tc_core.macro-hygiene-local-id
        session-a
        (tc_core.MacroHygieneContext
          (+ source-id 1)
          root-module-id
          declaration-id
          (compiler_symbols.compiler-symbols-empty))
        3
        source-id)]
    [deep-local-id : i64
      (tc_core.macro-hygiene-local-id
        session-a
        (tc_core.MacroHygieneContext
          source-id
          root-module-id
          declaration-id
          (compiler_symbols.compiler-symbols-empty))
        1024
        source-id)]
    [deep-local-again : i64
      (tc_core.macro-hygiene-local-id
        session-a
        (tc_core.MacroHygieneContext
          source-id
          root-module-id
          -1
          (compiler_symbols.compiler-symbols-empty))
        1024
        source-id)]
    [collision-local-id : i64
      (tc_core.macro-hygiene-local-id
        session-a
        (tc_core.MacroHygieneContext
          source-id
          root-module-id
          declaration-id
          (compiler_symbols.compiler-symbols-empty))
        1536
        source-id)]
    [b-context-id : i64
      (tc_core.macro-hygiene-global-id session-b module-id source-id false)]
    [b-local-id : i64
      (tc_core.macro-hygiene-local-id
        session-b
        (tc_core.MacroHygieneContext
          source-id
          root-module-id
          declaration-id
          (compiler_symbols.compiler-symbols-empty))
        3
        source-id)]
    [before-reset : bool
      (and
        (tc_core.macro-hygiene-global-legacy-id? session-a legacy-id)
        (=
          (tc_core.macro-hygiene-global-module-id session-a legacy-id)
          module-id)
        (=
          (tc_core.macro-hygiene-global-module-id session-a context-id)
          module-id)
        (not
          (tc_core.macro-hygiene-global-legacy-id? session-a root-context-id))
        (=
          (tc_core.macro-hygiene-global-module-id session-a root-context-id)
          root-module-id)
        (=
          (tc_core.macro-hygiene-structural-source-name-id
            session-a
            root-context-id)
          source-id)
        (tc_core.macro-hygiene-local-id? session-a direct-local-id)
        (tc_core.macro-hygiene-local-id? session-a surface-local-id)
        ;; Dense declaration ids are deliberately absent from the structural
        ;; macro definition key, preserving generated-module replay stability.
        (= direct-local-id surface-local-id)
        (= deep-local-id deep-local-again)
        (not (= direct-local-id other-macro-local-id))
        (not (= context-id collision-context-id))
        (not (= deep-local-id collision-local-id))
        (=
          (cis.intern-macro-definition-identity-raw definition-a)
          (cis.intern-macro-definition-identity-raw definition-a-again))
        (not
          (= (cis.intern-macro-definition-identity-raw definition-a) context-id))
        (not (= context-id b-context-id))
        (not (= direct-local-id b-local-id))
        (not (tc_core.macro-hygiene-global-id? session-b context-id))
        (not (tc_core.macro-hygiene-local-id? session-b direct-local-id))
        (match (cis.intern-structural-session-macro-global-record-for-raw
          session-a
          context-id)
          [(cis.InternMaybeMacroGlobalRecord.Some record)
            (and
              (= record.definition-module-id module-id)
              (= record.source-name-id source-id)
              (match record.role
                [(cis.InternMacroGlobalRole.Context) true]
                [_ false]))]
          [_ false])
        (match (cis.intern-structural-session-macro-local-record-for-raw
          session-a
          deep-local-id)
          [(cis.InternMaybeMacroLocalRecord.Some record)
            (and
              (= record.lexical-depth 1024)
              (= record.source-name-id source-id)
              (match (cis.intern-structural-session-macro-definition-record
                session-a
                record.macro-definition)
                [(cis.InternMaybeMacroDefinitionRecord.Some definition)
                  (and
                    (= definition.definition-module-id root-module-id)
                    (= definition.macro-name-id source-id))]
                [_ false]))]
          [_ false])
        (=
          (cis.intern-structural-session-kind-count
            session-a
            (ci.intern-structural-kind-macro-definition))
          2)
        (=
          (cis.intern-structural-session-kind-count
            session-a
            (ci.intern-structural-kind-macro-global))
          4)
        (=
          (cis.intern-structural-session-kind-count
            session-a
            (ci.intern-structural-kind-macro-local))
          4)
        (= (ci.intern-compat-state-structural-count intern-a) 10)
        (= (ci.intern-structural-record-slot-bytes) 37))]
    (begin
      (ci.intern-compat-state-reset-to! (&mut intern-a) 0)
      (let
        [next-session-a : cis.InternStructuralSessionHandle
          (cis.intern-structural-session-handle-from-source-names
            (ci.intern-source-name-session-handle-from-state intern-a))]
        [reset-ok : bool
          (and
            before-reset
            (not (cis.intern-structural-session-valid? session-a))
            (cis.intern-structural-session-valid? next-session-a)
            (not (tc_core.macro-hygiene-global-id? next-session-a context-id))
            (not
              (tc_core.macro-hygiene-local-id? next-session-a direct-local-id))
            (tc_core.macro-hygiene-global-id? session-b b-context-id)
            (tc_core.macro-hygiene-local-id? session-b b-local-id))]
        (begin
          (ci.intern-compat-state-reset! (&mut intern-b))
          (and reset-ok (not (cis.intern-structural-session-valid? session-b))))))))

(define (compiler-typecheck-smoke-structural-name-rendering-ok?) : bool
  (let
    [source-name-id : i64 (ci.intern "generated.module")]
    [owner-module-id : i64 (ci.intern "macro.owner")]
    [item-name-id : i64 (ci.intern "Item")]
    [ctx : tc_core.TcContext
      (tc_core.tc-context-new
        (ast.ast-program (ast.ast-decl-list-new))
        (compiler_symbols.compiler-symbols-empty)
        (compiler_symbols.compiler-registries-empty)
        ""
        cbi.compiler-builtin-id-fix-empty
        (ast.ast-node-pool-context-capture-active))]
    [session : cis.InternStructuralSessionHandle
      (tc_core.tc-context-structural-session ctx)]
    [structural-module-id : i64
      (tc_core.macro-hygiene-global-id
        session
        owner-module-id
        source-name-id
        false)]
    [qualified-item-id : i64
      (cis.intern-structural-key-raw
        (cis.intern-structural-session-composite-pair-key
          session
          structural-module-id
          item-name-id))]
    (and
      (string.eq
        (tc_core.tc-env-key-name-text-for-session session structural-module-id)
        "generated.module")
      (string.eq
        (tc_core.tc-env-key-name-text-for-session session qualified-item-id)
        "generated.module/Item")
      (=
        (tc_core.tc-source-name-id-or ctx structural-module-id -1)
        source-name-id)
      (tc_core.tc-module-identity-id-eq?
        session
        structural-module-id
        source-name-id))))

(define (compiler-typecheck-smoke-macro-change-signal-source-ok?
  [source : String]
  [expected-change : bool]) : bool
  (let
    [ok : bool
      (match (parser.parse-ast-source-diagnostic "" source)
        [(parser.ResultAstProgramDiagnostic.Ok program)
          (match (tc_core.macro-expand-program program)
            [(tc_core.ResultMacroExpand.Ok _ _)
              (if expected-change
                (tc_core.macro-expand-program-structurally-changed?
                  (tc_core.tc-job-state-macro-state
                    (tc_core.tc-serial-job-state)))
                (not
                  (tc_core.macro-expand-program-structurally-changed?
                    (tc_core.tc-job-state-macro-state
                      (tc_core.tc-serial-job-state)))))]
            [(tc_core.ResultMacroExpand.Err _) false])]
        [(parser.ResultAstProgramDiagnostic.Err _) false])]
    (begin
      (tc_core.compiler-typecheck-reset-file-state!)
      ok)))

(define (compiler-typecheck-smoke-generated-decl-has-no-semantic-origin?
  [decls : ast.AstDeclList]) : bool
  (match (ast.ast-decl-list-step (ast.ast-place-shared-view decls))
    [(ast.AstDeclListStep.Nil) false]
    [(ast.AstDeclListStep.Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (match decl
          [(ast.AstDecl.DefStruct _ name _ _ _)
            (if (string.eq (ci.intern-str name) "Generated")
              (match (parser.compiler-parse-semantic-origin-run (& decls) 0)
                [(parser.CompilerParseMaybeSemanticOriginRun.Some _) false]
                [(parser.CompilerParseMaybeSemanticOriginRun.None) true])
              (compiler-typecheck-smoke-generated-decl-has-no-semantic-origin?
                rest))]
          [_
            (compiler-typecheck-smoke-generated-decl-has-no-semantic-origin?
              rest)]))]))

(define (compiler-typecheck-smoke-generated-semantic-origin-absent-ok?) : bool
  (let
    [mark : i64 (reader.sp-node-pool-len)]
    [ok : bool
      (match (parser.parse-ast-source-diagnostic
        ""
        "(defmacro (emit) : Decls
  `(begin (defstruct Generated (field Source.Type))))
(emit)")
        [(parser.ResultAstProgramDiagnostic.Ok program)
          (match (tc_core.macro-expand-program program)
            [(tc_core.ResultMacroExpand.Ok expanded _)
              (match expanded
                [(ast.AstProgram.Program decls-box)
                  (compiler-typecheck-smoke-generated-decl-has-no-semantic-origin?
                    (ast.ast-decl-list-box-shared-view decls-box))])]
            [(tc_core.ResultMacroExpand.Err _) false])]
        [(parser.ResultAstProgramDiagnostic.Err _) false])]
    (begin
      (tc_core.compiler-typecheck-reset-file-state!)
      (reader.sp-node-pool-truncate! mark)
      (parser.compiler-parse-decl-origin-cache-reset!)
      ok)))

(define (compiler-typecheck-smoke-macro-no-change-signal-ok?) : bool
  ;; An unused defmacro forces the full declaration walk while every output
  ;; declaration remains shared with the compact input program.
  (compiler-typecheck-smoke-macro-change-signal-source-ok?
    "(defmacro (one) : i64 `1)
(test ignored-test true)
(define (main) : i64 0)"
    false))

(define (compiler-typecheck-smoke-macro-expr-change-signal-ok?) : bool
  (compiler-typecheck-smoke-macro-change-signal-source-ok?
    "(defmacro (one) : i64 `1)
(define (main) : i64 (one))"
    true))

(define (compiler-typecheck-smoke-macro-decl-change-signal-ok?) : bool
  ;; Declaration splices must miss the retain-source fast path even if their
  ;; generated body contains no expression node that would serve as a proxy.
  (compiler-typecheck-smoke-macro-change-signal-source-ok?
    "(defmacro (items) : Decls
  `(begin (defstruct Marker (value i64))))
(items)
(define (main) : i64 0)"
    true))

(define (compiler-typecheck-smoke-macro-module-import-change-signal-ok?) : bool
  ;; Module macro imports replace the placeholder import and may materialize a
  ;; generated module, so they must always miss the retain-source fast path.
  (compiler-typecheck-smoke-macro-change-signal-source-ok?
    (compiler-typecheck-smoke-module-macro-import-evaluated-key-source)
    true))

(define (compiler-typecheck-core-macro-bodies-observed?) : bool
  (and
    (tc_tests.compiler-typecheck-error-ok?
      "(module stdlib.core_macros)
(defmacro (and [_args : bool ...]) : bool
  (expr-var \"core-and-body-observed\"))
(module main)
(define (main) : bool (and true))"
      "typecheck: unbound name core-and-body-observed")
    (tc_tests.compiler-typecheck-error-ok?
      "(module stdlib.core_macros)
(defmacro (or [_args : bool ...]) : bool
  (expr-var \"core-or-body-observed\"))
(module main)
(define (main) : bool (or false))"
      "typecheck: unbound name core-or-body-observed")
    (tc_tests.compiler-typecheck-error-ok?
      "(module stdlib.core_macros)
(defmacro (cond [_arms : ExprClause ...]) : Expr
  (expr-var \"core-cond-body-observed\"))
(module main)
(define (main) : i64 (cond [else 42]))"
      "typecheck: unbound name core-cond-body-observed")))

(test
  compiler-typecheck-macro-state-isolation
  (unless
    (core_tests.tc-macro-state-isolation-ok?)
    (io.panic "typecheck: macro/CTFE job state isolation smoke failed")))

(test
  compiler-typecheck-type-resolution-pool-isolation
  (unless
    (compiler-typecheck-smoke-type-resolution-pool-isolation-ok?)
    (io.panic "typecheck: type-resolution pool isolation smoke failed")))

(define (compiler-typecheck-structural-intern-session-isolation-ok?) : bool
  (let
    [installed : ci.InternCompatState (ci.intern-compat-state-capture-active)]
    [intern-a : ci.InternCompatState (ci.intern-compat-state-new)]
    [intern-b : ci.InternCompatState (ci.intern-compat-state-new)]
    [job-a : tc_core.TcJobState (tc_core.tc-job-state-new)]
    [job-b : tc_core.TcJobState (tc_core.tc-job-state-new)]
    [macro-a : tc_core.TcMacroState (tc_core.tc-job-state-macro-state job-a)]
    [macro-b : tc_core.TcMacroState (tc_core.tc-job-state-macro-state job-b)]
    [source-a : ci.InternSourceNameSessionHandle
      (ci.intern-source-name-session-handle-from-state intern-a)]
    [source-b : ci.InternSourceNameSessionHandle
      (ci.intern-source-name-session-handle-from-state intern-b)]
    [_bind-a : unit
      (tc_core.tc-macro-state-bind-source-names! macro-a source-a)]
    [_bind-b : unit
      (tc_core.tc-macro-state-bind-source-names! macro-b source-b)]
    [body-a : tc_core.TcBodyState
      (tc_core.tc-body-state-new-with-job-state-and-source-names
        job-a
        (tc_core.tc-macro-state-source-names macro-a))]
    [ctx-a : tc_core.TcContext
      (tc_core.tc-context-new-with-source-names-and-body-state
        (ast.ast-program (ast.ast-decl-list-new))
        (compiler_symbols.compiler-symbols-empty)
        (compiler_symbols.compiler-registries-empty)
        ""
        cbi.compiler-builtin-id-fix-empty
        (ast.ast-node-pool-context-capture-active)
        (tc_core.tc-macro-state-source-names macro-a)
        (tc_core.tc-global-shared-view body-a))]
    [hygiene-a : tc_core.MacroHygieneEnv
      (tc_core.macro-hygiene-env-empty macro-a (tc_core.tc-context-pools ctx-a))]
    [macro-a-handle : ci.InternSourceNameSessionHandle
      (tc_core.tc-macro-state-source-names macro-a)]
    [macro-b-handle : ci.InternSourceNameSessionHandle
      (tc_core.tc-macro-state-source-names macro-b)]
    [body-a-handle : ci.InternSourceNameSessionHandle
      (tc_core.tc-macro-state-source-names
        (tc_core.tc-job-state-macro-state body-a.job-state))]
    [ctx-a-handle : ci.InternSourceNameSessionHandle
      (tc_core.tc-context-source-names ctx-a)]
    [hygiene-a-handle : ci.InternSourceNameSessionHandle
      (tc_core.tc-macro-state-source-names hygiene-a.state)]
    [session-a : cis.InternStructuralSessionHandle
      (cis.intern-structural-session-handle-from-source-names macro-a-handle)]
    [session-b : cis.InternStructuralSessionHandle
      (cis.intern-structural-session-handle-from-source-names macro-b-handle)]
    [env-a : tc_core.TcTypeEnv (tc_core.tc-empty-env-with-job-state job-a)]
    [env-b : tc_core.TcTypeEnv (tc_core.tc-empty-env-with-job-state job-b)]
    [env-session-a : cis.InternStructuralSessionHandle
      (tc_core.tc-type-env-structural-session env-a)]
    [env-session-b : cis.InternStructuralSessionHandle
      (tc_core.tc-type-env-structural-session env-b)]
    [session-a-generation : i64
      (cis.intern-structural-session-current-reset-generation session-a)]
    [generation-b : i64 (ci.intern-compat-state-generation intern-b)]
    [stale-arena-raw : i64 -1]
    [ok : bool
      (and
        (= macro-a-handle.address body-a-handle.address)
        (= macro-a-handle.address ctx-a-handle.address)
        (= macro-a-handle.address hygiene-a-handle.address)
        (not (= macro-a-handle.address macro-b-handle.address))
        (= env-session-a.address session-a.address)
        (= env-session-b.address session-b.address)
        (not
          (=
            (cis.intern-structural-session-owner env-session-a)
            (cis.intern-structural-session-owner env-session-b))))]
    (begin
      ;; Keep B installed while macro expansion and ordinary typecheck views
      ;; owned by A canonicalize, grow, and decode A's structural records.
      (ci.intern-compat-state-install! (tc_core.tc-global-shared-view intern-b))
      (let
        [a-pair : cis.InternStructuralKey
          (cis.intern-structural-session-composite-pair-key session-a 71 81)]
        [a-pair-again : cis.InternStructuralKey
          (cis.intern-structural-session-composite-pair-key
            (cis.intern-structural-session-handle-from-source-names
              ctx-a-handle)
            71
            81)]
        [b-pair : cis.InternStructuralKey
          (cis.intern-structural-session-composite-pair-key session-b 71 81)]
        [a-triple : cis.InternStructuralKey
          (cis.intern-structural-session-composite-triple-key
            session-a
            91
            101
            111)]
        [large-owner : i64 (+ (ci.intern-capacity) 1000)]
        [large-token : i64 (+ (ci.intern-capacity) 2000)]
        [a-region : cis.InternArenaPhaseIdentity
          (cis.intern-structural-session-arena-phase-identity
            session-a
            (cis.InternArenaPhaseRecord.Region large-owner large-token))]
        [a-region-again : cis.InternArenaPhaseIdentity
          (cis.intern-structural-session-arena-phase-identity
            session-a
            (cis.InternArenaPhaseRecord.Region large-owner large-token))]
        ;; The initial map has 512 slots. Changing this component by 512
        ;; deliberately preserves the arena record's first bucket.
        [a-region-hash-collision : cis.InternArenaPhaseIdentity
          (cis.intern-structural-session-arena-phase-identity
            session-a
            (cis.InternArenaPhaseRecord.Region (+ large-owner 512) large-token))]
        [a-current-marker : cis.InternArenaPhaseIdentity
          (cis.intern-structural-session-arena-phase-identity
            session-a
            (cis.InternArenaPhaseRecord.CurrentRegionMarker large-owner))]
        [a-owner-marker : cis.InternArenaPhaseIdentity
          (cis.intern-structural-session-arena-phase-identity
            session-a
            (cis.InternArenaPhaseRecord.TokenOwnerMarker large-token))]
        [a-region-marker : cis.InternArenaPhaseIdentity
          (cis.intern-structural-session-arena-phase-identity
            session-a
            (cis.InternArenaPhaseRecord.TokenRegionMarker large-token))]
        [b-region : cis.InternArenaPhaseIdentity
          (cis.intern-structural-session-arena-phase-identity
            session-b
            (cis.InternArenaPhaseRecord.Region large-owner large-token))]
        (begin
          (set! stale-arena-raw (cis.intern-arena-phase-identity-raw a-region))
          (set!
            ok
            (and
              ok
              (=
                (cis.intern-structural-key-raw a-pair)
                (cis.intern-structural-key-raw a-pair-again))
              (not
                (=
                  (cis.intern-structural-key-raw a-pair)
                  (cis.intern-structural-key-raw b-pair)))
              (cis.intern-structural-session-key-owned? session-a a-pair)
              (not (cis.intern-structural-session-key-owned? session-b a-pair))
              (ci.intern-compat-state-composite-pair-id?
                intern-a
                (cis.intern-structural-key-raw a-pair))
              (=
                (ci.intern-compat-state-composite-left-id-unchecked
                  intern-a
                  (cis.intern-structural-key-raw a-pair))
                71)
              (=
                (ci.intern-compat-state-composite-right-id-unchecked
                  intern-a
                  (cis.intern-structural-key-raw a-pair))
                81)
              (ci.intern-compat-state-composite-triple-id?
                intern-a
                (cis.intern-structural-key-raw a-triple))
              (=
                (ci.intern-compat-state-composite-left-id-unchecked
                  intern-a
                  (cis.intern-structural-key-raw a-triple))
                91)
              (=
                (ci.intern-compat-state-composite-middle-id-unchecked
                  intern-a
                  (cis.intern-structural-key-raw a-triple))
                101)
              (=
                (ci.intern-compat-state-composite-right-id-unchecked
                  intern-a
                  (cis.intern-structural-key-raw a-triple))
                111)
              ;; B is both explicit and installed. The explicit constructor
              ;; must keep the transitional legacy fast path coherent for the
              ;; same owner while leaving unrelated installed owners alone.
              (ci.intern-composite-pair-id?
                (cis.intern-structural-key-raw b-pair))
              (=
                (cis.intern-arena-phase-identity-raw a-region)
                (cis.intern-arena-phase-identity-raw a-region-again))
              (not
                (=
                  (cis.intern-arena-phase-identity-raw a-region)
                  (cis.intern-arena-phase-identity-raw a-region-hash-collision)))
              (not
                (=
                  (cis.intern-arena-phase-identity-raw a-region)
                  (cis.intern-arena-phase-identity-raw a-current-marker)))
              (not
                (=
                  (cis.intern-arena-phase-identity-raw a-current-marker)
                  (cis.intern-arena-phase-identity-raw a-owner-marker)))
              (not
                (=
                  (cis.intern-arena-phase-identity-raw a-owner-marker)
                  (cis.intern-arena-phase-identity-raw a-region-marker)))
              (not
                (=
                  (cis.intern-arena-phase-identity-raw a-region)
                  (cis.intern-arena-phase-identity-raw b-region)))
              (not
                (ci.intern-renderable-id?
                  (cis.intern-arena-phase-identity-raw a-region)))
              (match (cis.intern-structural-session-arena-phase-record
                session-a
                a-region)
                [(cis.InternMaybeArenaPhaseRecord.Some
                    (cis.InternArenaPhaseRecord.Region owner token))
                  (and (= owner large-owner) (= token large-token))]
                [_ false])
              (match (cis.intern-structural-session-arena-phase-record
                session-a
                a-current-marker)
                [(cis.InternMaybeArenaPhaseRecord.Some
                    (cis.InternArenaPhaseRecord.CurrentRegionMarker owner))
                  (= owner large-owner)]
                [_ false])
              (match (cis.intern-structural-session-arena-phase-record
                session-a
                a-owner-marker)
                [(cis.InternMaybeArenaPhaseRecord.Some
                    (cis.InternArenaPhaseRecord.TokenOwnerMarker token))
                  (= token large-token)]
                [_ false])
              (match (cis.intern-structural-session-arena-phase-record
                session-a
                a-region-marker)
                [(cis.InternMaybeArenaPhaseRecord.Some
                    (cis.InternArenaPhaseRecord.TokenRegionMarker token))
                  (= token large-token)]
                [_ false])
              (match (cis.intern-structural-session-arena-phase-record
                session-b
                a-region)
                [(cis.InternMaybeArenaPhaseRecord.No) true]
                [_ false])
              (match (cis.intern-structural-session-arena-phase-record-for-raw
                session-a
                (cis.intern-structural-key-raw a-pair))
                [(cis.InternMaybeArenaPhaseRecord.No) true]
                [_ false])))
          (let
            [index : i64 0]
            (while (< index 700)
              (let
                [key : cis.InternStructuralKey
                  (cis.intern-structural-session-composite-triple-key
                    (cis.intern-structural-session-handle-from-source-names
                      ctx-a-handle)
                    (+ 1000 index)
                    (+ 2000 index)
                    (+ 3000 index))]
                [phase : cis.InternArenaPhaseIdentity
                  (cis.intern-structural-session-arena-phase-identity
                    session-a
                    (cis.InternArenaPhaseRecord.Region
                      (+ (ci.intern-capacity) 4000 index)
                      (+ (ci.intern-capacity) 5000 index)))]
                (begin
                  (unless
                    (=
                      (cis.intern-structural-session-key-middle session-a key)
                      (+ 2000 index))
                    (set! ok false))
                  (match (cis.intern-structural-session-arena-phase-record
                    session-a
                    phase)
                    [(cis.InternMaybeArenaPhaseRecord.Some
                        (cis.InternArenaPhaseRecord.Region owner token))
                      (unless
                        (and
                          (= owner (+ (ci.intern-capacity) 4000 index))
                          (= token (+ (ci.intern-capacity) 5000 index)))
                        (set! ok false))]
                    [_ (set! ok false)])
                  (set! index (+ index 1))))))
          (set!
            ok
            (and
              ok
              (= (ci.intern-compat-state-structural-count intern-a) 1407)
              (= (ci.intern-compat-state-structural-count intern-b) 2)
              (>=
                (array-length
                  (__tl-project-field
                    (array-ref intern-a.structural-table-cell 0)
                    kinds))
                2048)
              (= (ci.intern-structural-record-slot-bytes) 37)
              (=
                (array-length
                  (__tl-project-field
                    (array-ref intern-a.structural-table-cell 0)
                    structural-cache-raws))
                (ci.intern-structural-cache-capacity))
              (=
                (ci.intern-active-table-id)
                (ci.intern-compat-state-table-id intern-b))))))
      (ci.intern-compat-state-install! installed)
      (ci.intern-compat-state-reset-to! (&mut intern-a) 0)
      (let
        [stale-before-rebind : bool
          (not (cis.intern-structural-session-valid? session-a))]
        [next-source-a : ci.InternSourceNameSessionHandle
          (ci.intern-source-name-session-handle-from-state intern-a)]
        [_rebind-a : unit
          (tc_core.tc-macro-state-bind-source-names! macro-a next-source-a)]
        [next-session-a : cis.InternStructuralSessionHandle
          (cis.intern-structural-session-handle-from-source-names
            (tc_core.tc-macro-state-source-names macro-a))]
        [reset-to-ok : bool
          (and
            ok
            stale-before-rebind
            (not
              (=
                (cis.intern-structural-session-current-reset-generation
                  session-a)
                session-a-generation))
            (= (ci.intern-compat-state-structural-count intern-a) 0)
            (cis.intern-structural-session-valid? next-session-a)
            (match (cis.intern-structural-session-arena-phase-record-for-raw
              next-session-a
              stale-arena-raw)
              [(cis.InternMaybeArenaPhaseRecord.No) true]
              [_ false])
            (= session-a.address next-session-a.address))]
        (begin
          (ci.intern-compat-state-reset! (&mut intern-b))
          (and
            reset-to-ok
            (cis.intern-structural-session-valid? next-session-a)
            (not (cis.intern-structural-session-valid? session-b))
            (= (ci.intern-compat-state-structural-count intern-b) 0)
            (not (= (ci.intern-compat-state-generation intern-b) generation-b))
            (= (ci.intern-compat-state-pool-len intern-b) 0)))))))

(test
  compiler-typecheck-structural-intern-session-isolation
  (unless
    (compiler-typecheck-structural-intern-session-isolation-ok?)
    (io.panic "typecheck: structural-intern session isolation smoke failed")))

(define (compiler-typecheck-smoke-body-state-diagnostic-reuse-ok?) : bool
  (let
    [failed : tc_core.ResultCompilerTypecheck
      (tc_api.typecheck-compiler-source
        "(define (bad) : bool 1)
(define (checked-after-bad) : i64 42)")]
    [failed-once : bool
      (match failed
        [(tc_core.ResultCompilerTypecheck.Ok _) false]
        [(tc_core.ResultCompilerTypecheck.Err diagnostics)
          (=
            (diagnostic.compiler-diagnostic-list-count
              (diagnostic.compiler-diagnostic-list-box-shared-view diagnostics))
            1)])]
    [reused : tc_core.ResultCompilerTypecheck
      (tc_api.typecheck-compiler-source
        "(define (checked-after-reset) : i64 42)")]
    (and
      failed-once
      (match reused
        [(tc_core.ResultCompilerTypecheck.Ok _) true]
        [(tc_core.ResultCompilerTypecheck.Err _) false]))))

(cfg
  compile-profile
  (define (compiler-typecheck-smoke-macro-profile-entry-eq?
    [index : i64]
    [macro-id : i64]
    [macro-name : String]
    [arity : i64]
    [calls : i64]
    [total-ms : i64]) : bool
    (if (and (>= index 0) (< index (tc_core.compiler-tc-macro-profile-count)))
      (let
        [entry : tc_core.CompilerTcMacroProfileEntry
          (tc_core.compiler-tc-macro-profile-current-entry index)]
        (and
          (= entry.macro-id macro-id)
          (string.eq entry.macro-name macro-name)
          (= entry.arity arity)
          (= entry.calls calls)
          (= entry.total-ms total-ms)))
      false)))

(cfg
  compile-profile
  (define (compiler-typecheck-smoke-macro-profile-storage-ok?) : bool
    (let
      [module-a : i64 (ci.intern "profile-dense-module-a")]
      [module-b : i64 (ci.intern "profile-dense-module-b")]
      [name-id : i64 (ci.intern "profile-dense-macro")]
      [macro-a : i64 (ci.intern-composite-pair-id module-a name-id)]
      [macro-b : i64 (ci.intern-composite-pair-id module-b name-id)]
      [macro-state : tc_core.TcMacroState
        (tc_core.tc-job-state-macro-state (tc_core.tc-serial-job-state))]
      [growth-cursor : i64 0]
      [ok : bool true]
      (begin
        (tc_core.compiler-tc-macro-profile-reset)
        (tc_core.compiler-tc-macro-profile-record-entry!
          macro-state
          macro-a
          "profile-dense-module-a/profile-dense-macro"
          2
          3)
        (tc_core.compiler-tc-macro-profile-record-entry!
          macro-state
          macro-a
          "profile-dense-module-a/profile-dense-macro"
          2
          5)
        (tc_core.compiler-tc-macro-profile-record-entry!
          macro-state
          macro-a
          "profile-dense-module-a/profile-dense-macro"
          6
          7)
        (tc_core.compiler-tc-macro-profile-record-entry!
          macro-state
          macro-b
          "profile-dense-module-b/profile-dense-macro"
          2
          11)
        (set!
          ok
          (and
            (= (tc_core.compiler-tc-macro-profile-count) 3)
            (compiler-typecheck-smoke-macro-profile-entry-eq?
              (tc_core.compiler-tc-macro-profile-current-entry-index macro-a 2)
              macro-a
              "profile-dense-module-a/profile-dense-macro"
              2
              2
              8)
            (compiler-typecheck-smoke-macro-profile-entry-eq?
              (tc_core.compiler-tc-macro-profile-current-entry-index macro-a 6)
              macro-a
              "profile-dense-module-a/profile-dense-macro"
              6
              1
              7)
            (compiler-typecheck-smoke-macro-profile-entry-eq?
              (tc_core.compiler-tc-macro-profile-current-entry-index macro-b 2)
              macro-b
              "profile-dense-module-b/profile-dense-macro"
              2
              1
              11)))
        (while (< growth-cursor 32)
          (begin
            (tc_core.compiler-tc-macro-profile-record-entry!
              macro-state
              macro-b
              "profile-dense-module-b/profile-dense-macro"
              (+ growth-cursor 100)
              growth-cursor)
            (set! growth-cursor (+ growth-cursor 1))))
        (set!
          ok
          (and
            ok
            (= (tc_core.compiler-tc-macro-profile-count) 35)
            (compiler-typecheck-smoke-macro-profile-entry-eq?
              (tc_core.compiler-tc-macro-profile-current-entry-index
                macro-b
                131)
              macro-b
              "profile-dense-module-b/profile-dense-macro"
              131
              1
              31)))
        (tc_core.compiler-tc-macro-profile-reset)
        (set!
          ok
          (and
            ok
            (tc_core.compiler-tc-macro-profile-active?)
            (= (tc_core.compiler-tc-macro-profile-count) 0)
            (=
              (tc_core.compiler-tc-macro-profile-current-entry-index macro-a 2)
              -1)))
        (tc_core.compiler-tc-macro-profile-record-entry!
          macro-state
          macro-b
          "profile-dense-module-b/profile-dense-macro"
          2
          13)
        (set!
          ok
          (and
            ok
            (compiler-typecheck-smoke-macro-profile-entry-eq?
              0
              macro-b
              "profile-dense-module-b/profile-dense-macro"
              2
              1
              13)))
        (tc_core.compiler-tc-macro-profile-clear)
        (and
          ok
          (not (tc_core.compiler-tc-macro-profile-active?))
          (= (tc_core.compiler-tc-macro-profile-count) 0))))))

(define (main) : i64
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (cfg
      compile-profile
      (if (compiler-typecheck-smoke-macro-profile-storage-ok?)
        (return 0)
        (return 1)))
    (tc_tests.compiler-typecheck-self-test)
    (unless
      (compiler-typecheck-core-macro-bodies-observed?)
      (io.panic "typecheck: stdlib core macro body was bypassed"))
    (unless
      (compiler-typecheck-scoped-marker-queries-ok?)
      (io.panic "typecheck: scoped marker query smoke failed"))
    (unless
      (compiler-typecheck-scoped-marker-replaced-cache-ok?)
      (io.panic "typecheck: replaced scoped marker cache smoke failed"))
    ;; The macro-expansion self-test leaves multiple symbol generations behind.
    ;; A fresh stdlib Module macro compile must not observe a reclaimed handle.
    (unless
      (compiler-typecheck-smoke-lazy-import-stdlib-result-macro-ok?)
      (io.panic "typecheck: macro symbol generation reset smoke failed"))
    (unless
      (compiler-typecheck-smoke-body-state-diagnostic-reuse-ok?)
      (io.panic "typecheck: body state diagnostic reuse smoke failed"))
    (unless
      (core_tests.tc-scratch-arena-state-isolation-self-test)
      (io.panic "typecheck: scratch arena state isolation smoke failed"))
    (unless
      (core_tests.tc-unused-unsafe-state-isolation-self-test)
      (io.panic "typecheck: unused unsafe state isolation smoke failed"))
    (unless
      (core_tests.tc-spmd-traversal-state-isolation-self-test)
      (io.panic "typecheck: SPMD traversal state isolation smoke failed"))
    (unless
      (and
        (compiler-typecheck-smoke-registry-member-diagnostic-ok?
          "(define support : i64 0)
(defstruct Pair
  (x i64)
  (x i64))"
          "fields.tl"
          "symbols: duplicate field Pair.x")
        (compiler-typecheck-smoke-registry-member-diagnostic-ok?
          "(define support : i64 0)
(defenum Choice
  (Same)
  (Same))"
          "variants.tl"
          "symbols: duplicate enum variant Choice.Same"))
      (io.panic "typecheck: registry member diagnostic spans failed"))
    (unless
      (compiler-typecheck-reference-escape-tests-ok?)
      (io.panic "typecheck: reference escape tests failed"))
    (unless
      (compiler-typecheck-auto-borrow-tests-ok?)
      (io.panic "typecheck: auto-borrow tests failed"))
    (unless
      (compiler-typecheck-call-diagnostic-tests-ok?)
      (io.panic "typecheck: call diagnostic tests failed"))
    (unless
      (compiler-typecheck-borrow-diagnostic-tests-ok?)
      (io.panic "typecheck: borrow diagnostic tests failed"))
    (unless
      (compiler-typecheck-move-diagnostic-tests-ok?)
      (io.panic "typecheck: move diagnostic tests failed"))
    (unless
      (compiler-typecheck-macro-alias-cache-collision-ok?)
      (io.panic "typecheck: macro alias cache collision test failed"))
    (unless
      (compiler-typecheck-smoke-hygiene-structural-ids-ok?)
      (io.panic "typecheck: hygiene structural id smoke failed"))
    (unless
      (compiler-typecheck-smoke-structural-name-rendering-ok?)
      (io.panic "typecheck: structural name rendering smoke failed"))
    (unless
      (compiler-typecheck-smoke-macro-no-change-signal-ok?)
      (io.panic "typecheck: unchanged macro walk signal smoke failed"))
    (unless
      (compiler-typecheck-smoke-macro-expr-change-signal-ok?)
      (io.panic "typecheck: expression macro change signal smoke failed"))
    (unless
      (compiler-typecheck-smoke-macro-decl-change-signal-ok?)
      (io.panic "typecheck: declaration macro change signal smoke failed"))
    (unless
      (compiler-typecheck-smoke-generated-semantic-origin-absent-ok?)
      (io.panic "typecheck: generated declaration has editable semantic origin"))
    (unless
      (compiler-typecheck-smoke-macro-module-import-change-signal-ok?)
      (io.panic "typecheck: module import macro change signal smoke failed"))
    (unless
      (compiler-typecheck-smoke-module-macro-identity-tests-ok?)
      (io.panic "typecheck: module macro identity smoke failed"))
    (unless
      (compiler-typecheck-smoke-comptime-error-tests-ok?)
      (io.panic "typecheck: comptime-error smoke failed"))
    (unless
      (compiler-typecheck-smoke-regalloc-heapsort-macro-tests-ok?)
      (io.panic "typecheck: regalloc heapsort declaration macro smoke failed"))
    (unless
      (compiler-typecheck-smoke-decl-macro-body-tests-ok?)
      (io.panic "typecheck: declaration macro body smoke failed"))
    (unless
      (compiler-typecheck-smoke-decls-macro-generated-tests-ok?)
      (io.panic "typecheck: declaration macro generated identity smoke failed"))
    (unless
      (compiler-typecheck-smoke-type-macro-param-tests-ok?)
      (io.panic "typecheck: type macro param smoke failed"))
    (unless
      (compiler-typecheck-smoke-qualified-array-ok?)
      (io.panic "typecheck: qualified array smoke failed"))
    (unless
      (compiler-typecheck-smoke-nested-dotted-nominal-ok?)
      (io.panic "typecheck: nested dotted nominal smoke failed"))
    (unless
      (compiler-typecheck-smoke-lazy-import-explicit-alias-no-fanout-ok?)
      (io.panic "typecheck: lazy import alias fanout smoke failed"))
    (unless
      (compiler-typecheck-smoke-lazy-import-full-path-cache-ok?)
      (io.panic "typecheck: lazy import full path cache smoke failed"))
    (unless
      (compiler-typecheck-smoke-full-path-cache-derived-reset-ok?)
      (io.panic "typecheck: full path derived cache reset smoke failed"))
    (unless
      (compiler-typecheck-smoke-source-name-caches-intern-reset-ok?)
      (io.panic "typecheck: source name cache intern reset smoke failed"))
    (unless
      (compiler-typecheck-smoke-source-key-cache-state-isolation-ok?)
      (io.panic "typecheck: source key cache state isolation smoke failed"))
    (unless
      (compiler-typecheck-smoke-qualified-enum-variant-precedence-ok?)
      (io.panic "typecheck: qualified enum variant precedence smoke failed"))
    (unless
      (compiler-typecheck-smoke-dotted-constructor-cache-domain-ok?)
      (io.panic "typecheck: dotted constructor cache domain smoke failed"))
    (unless
      (compiler-typecheck-smoke-lazy-import-stdlib-summary-backed-ok?)
      (io.panic "typecheck: lazy import summary smoke failed"))
    (unless
      (compiler-typecheck-smoke-lazy-import-stdlib-result-macro-ok?)
      (io.panic "typecheck: lazy import stdlib.result macro smoke failed"))
    (unless
      (compiler-typecheck-smoke-unused-result-import-local-type-ok?)
      (io.panic "typecheck: unused result local type smoke failed"))
    (unless
      (compiler-typecheck-smoke-result-enum-then-helper-ok?)
      (io.panic "typecheck: result enum then helper smoke failed"))
    (unless
      (compiler-typecheck-smoke-lazy-import-str-cat-macro-ok?)
      (io.panic "typecheck: lazy import str-cat macro smoke failed"))
    (unless
      (compiler-typecheck-smoke-runtime-str-cat-two-nested-ok?)
      (io.panic "typecheck: runtime str-cat two nested smoke failed"))
    (unless
      (compiler-typecheck-smoke-lazy-summary-macro-unused-ok?)
      (io.panic "typecheck: lazy summary macro unused smoke failed"))
    (unless
      (compiler-typecheck-smoke-lazy-summary-macro-call-ok?)
      (io.panic "typecheck: lazy summary macro call smoke failed"))
    (unless
      (compiler-typecheck-smoke-lazy-summary-macro-hook-ok?)
      (io.panic "typecheck: lazy summary macro hook smoke failed"))
    (unless
      (compiler-typecheck-smoke-lazy-summary-macro-comptime-ok?)
      (io.panic "typecheck: lazy summary macro comptime param smoke failed"))
    (unless
      (compiler-typecheck-smoke-lazy-summary-macro-context-ok?)
      (io.panic "typecheck: lazy summary macro definition context smoke failed"))
    (unless
      (compiler-typecheck-smoke-prefix-cache-state-isolation-ok?)
      (io.panic "typecheck: prefix cache state isolation smoke failed"))
    (unless
      (compiler-typecheck-smoke-prefix-cache-root-isolation-ok?)
      (io.panic "typecheck: prefix cache root smoke failed"))
    (unless
      (compiler-typecheck-smoke-prefix-cache-cfg-isolation-ok?)
      (io.panic "typecheck: prefix cache cfg smoke failed"))
    (unless
      (compiler-typecheck-smoke-qualified-macro-kind-list-ok?)
      (io.panic "typecheck: qualified macro kind-list smoke failed"))
    (unless
      (compiler-typecheck-smoke-prefix-cache-local-module-hit-ok?)
      (io.panic "typecheck: prefix cache local module smoke failed"))
    (unless
      (compiler-typecheck-smoke-prefix-cache-moduleless-local-ok?)
      (io.panic "typecheck: prefix cache moduleless local smoke failed"))
    (unless
      (compiler-typecheck-smoke-generated-moduleless-import-order-ok?)
      (io.panic "typecheck: generated moduleless import order smoke failed"))
    (unless
      (compiler-typecheck-smoke-generated-type-param-pool-isolation-ok?)
      (io.panic "typecheck: generated type-param pool isolation smoke failed"))
    (unless
      (compiler-typecheck-smoke-generated-import-state-isolation-ok?)
      (io.panic "typecheck: generated import state isolation smoke failed"))
    (unless
      (compiler-typecheck-smoke-generated-import-call-site-ok? 0)
      (io.panic "typecheck: generated missing import call-site smoke failed"))
    (unless
      (compiler-typecheck-smoke-generated-import-call-site-ok? 1)
      (io.panic "typecheck: generated alias conflict call-site smoke failed"))
    (unless
      (compiler-typecheck-smoke-generated-import-call-site-ok? 2)
      (io.panic
        "typecheck: generated missing selected import call-site smoke failed"))
    (unless
      (compiler-typecheck-smoke-generated-import-call-site-ok? 3)
      (io.panic
        "typecheck: generated preloaded selected import call-site smoke failed"))
    (unless
      (compiler-typecheck-smoke-generated-provided-module-ok?)
      (io.panic
        "typecheck: generated provided dotted-module import smoke failed"))
    (unless
      (compiler-typecheck-smoke-generated-import-state-threading-ok?)
      (io.panic "typecheck: generated import state threading smoke failed"))
    (unless
      (compiler-typecheck-smoke-moduleless-stdlib-dotted-import-ok?)
      (io.panic "typecheck: moduleless stdlib dotted import smoke failed"))
    (unless
      (compiler-typecheck-smoke-specialized-import-path-ok?)
      (io.panic "typecheck: specialized import diagnostic path smoke failed"))
    (unless
      (compiler-typecheck-smoke-macro-dependency-context-ok?)
      (io.panic "typecheck: macro dependency context smoke failed"))
    (unless
      (compiler-typecheck-smoke-surface-macro-summary-ok?)
      (io.panic "typecheck: surface summary macro export smoke failed"))
    (tc_core.macro-alias-cache-reset!)
    42))