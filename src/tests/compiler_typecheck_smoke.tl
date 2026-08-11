;; compiler_typecheck_smoke.tl - Runnable smoke for compiler_typecheck.tl.
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import compiler_typecheck)
(cfg
  test
  (import tests.compiler_typecheck_proof_reuse_unit as proof_reuse_unit))
(import compiler_typecheck_api as tc_api)
(import compiler_diagnostic as diagnostic)
(import compiler_typecheck_core as tc_core)
(import compiler_ast_types as ast)
(import compiler_load as load)
(import compiler_ctfe as ctfe)
(import compiler_parse_core as parser)
(import compiler_symbols)
(import compiler_builtin_ids as cbi)
(import compiler_intern as ci)
(import stdlib.string)
(import sym_i64_env)

(define (compiler-typecheck-smoke-write-text
  [path : String]
  [contents : String]) : unit
  (io.write-file path (byte_buf.str-as-bytes (& contents))))

(define (compiler-typecheck-reference-nested-local-source) : String
  "(define (main [x : i64]) : unit
  (let
    [x : i64 (+ x 1)]
    (let [r : (& x i64) (& x)] unit)))")

(define (compiler-typecheck-reference-inner-let-escape-source) : String
  "(define (main) : unit
  (let
    [r : (& x i64) (let [x : i64 1] (& x))]
    unit))")

(define (compiler-typecheck-reference-outer-assignment-escape-source) : String
  "(define (main [x : i64]) : unit
  (let
    [slot : (& x i64) (& x)]
    (let [x : i64 1] (set! slot (& x)))))")

(define (compiler-typecheck-reference-container-escape-source) : String
  "(define (main [x : i64] [items : (__tl_dyn-array (& x i64))]) : unit
  (let [x : i64 1] (set! (array-ref items 0) (& x))))")

(define (compiler-typecheck-reference-array-push-ok-source) : String
  "(define (main [x : i64] [items : (__tl_dyn-array (& x i64))]) : unit
  (array-push! items (& x)))")

(define (compiler-typecheck-reference-array-push-escape-source) : String
  "(define (main [x : i64] [items : (__tl_dyn-array (& x i64))]) : unit
  (let [x : i64 1] (array-push! items (& x))))")

(define (compiler-typecheck-reference-arena-store-escape-source) : String
  (compiler_typecheck.compiler-typecheck-with-alloc-string-helper-source
    "(define (main [items : (__tl_dyn-array (& r str))]) : unit
  (with-arena r
    (let [s : String (string.int->string 1)]
      (set! (array-ref items 0) (& s)))))"))

(define (compiler-typecheck-reference-lambda-capture-source) : String
  "(define (main [x : i64]) : (-> unit)
  (let
    [r : (& x i64) (& x)]
    (lambda () : unit (let [copy : (& x i64) r] unit))))")

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

(define (compiler-typecheck-lambda-large-global-env-source) : String
  (compiler-typecheck-lambda-large-global-env-source-from 0 192 ""))

(define (compiler-typecheck-reference-lambda-immediate-ok-source) : String
  "(define (read [r : (& n i64)]) : i64 42)
(define (main [n : i64]) : i64
  (let [r : (& n i64) (& n)]
    ((lambda () : i64 (read r)))))")

(define (compiler-typecheck-reference-lambda-local-ok-source) : String
  "(define (read [r : (& n i64)]) : i64 42)
(define (main [n : i64]) : i64
  (let [r : (& n i64) (& n)]
    (let [f : (-> i64) (lambda () : i64 (read r))]
      (f))))")

(define (compiler-typecheck-reference-lambda-while-ok-source) : String
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

(define (compiler-typecheck-reference-lambda-nested-ok-source) : String
  "(define (read [r : (& n i64)]) : i64 42)
(define (main [n : i64]) : i64
  (let [r : (& n i64) (& n)]
    ((lambda () : i64
      (let [f : (-> i64) (lambda () : i64 (read r))]
        (f))))))")

(define (compiler-typecheck-reference-lambda-inner-arena-ok-source) : String
  "(define (read [r : (& n i64)]) : i64 42)
(define (main [n : i64]) : i64
  (let [r : (& n i64) (& n)]
    (with-arena scratch
      (let [f : (-> i64) (lambda () : i64 (read r))]
        (f)))))")

(define (compiler-typecheck-reference-lambda-local-return-source) : String
  "(define (read [r : (& n i64)]) : i64 42)
(define (main [n : i64]) : (-> i64)
  (let [r : (& n i64) (& n)]
    (let [f : (-> i64) (lambda () : i64 (read r))]
      f)))")

(define (compiler-typecheck-reference-lambda-store-source) : String
  "(define (read [r : (& n i64)]) : i64 42)
(define (main [n : i64]) : (Tuple (-> i64))
  (let [r : (& n i64) (& n)]
    (let [f : (-> i64) (lambda () : i64 (read r))]
      (tuple f))))")

(define (compiler-typecheck-reference-lambda-pass-unknown-source) : String
  "(define (read [r : (& n i64)]) : i64 42)
(define (call-now [f : (-> i64)]) : i64 (f))
(define (main [n : i64]) : i64
  (let [r : (& n i64) (& n)]
    (let [f : (-> i64) (lambda () : i64 (read r))]
      (call-now f))))")

(define (compiler-typecheck-reference-lambda-assign-source) : String
  "(define (read [r : (& n i64)]) : i64 42)
(define (main [n : i64]) : i64
  (let [r : (& n i64) (& n)]
    (let
      [f : (-> i64) (lambda () : i64 (read r))]
      [g : (-> i64) (lambda () : i64 0)]
      (begin
        (set! g f)
        (g)))))")

(define (compiler-typecheck-closure-copy-aggregate-source) : String
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

(define (compiler-typecheck-closure-copy-reference-source) : String
  "(define (read [r : (& n i64)]) : i64 1)
(define (main [x : i64]) : i64
  (let
    [r : (& x i64) (& x)]
    [f : (-> i64) (lambda () : i64 (read r))]
    [copy : (-> i64) f]
    (+ (f) (copy))))")

(define (compiler-typecheck-closure-copy-reference-escape-source) : String
  "(define (read [r : (& n i64)]) : i64 1)
(define (main [x : i64]) : (-> i64)
  (let
    [r : (& x i64) (& x)]
    [f : (-> i64) (lambda () : i64 (read r))]
    [copy : (-> i64) f]
    copy))")

(define (compiler-typecheck-closure-move-owner-alias-source) : String
  "(import stdlib.string)
(define (main) : i64
  (let
    [owned : String \"captured\"]
    [f : (-> i64) (lambda () : i64 (string.string-length owned))]
    [moved : (-> i64) f]
    (+ (moved) (f))))")

(define (compiler-typecheck-closure-move-nested-alias-source) : String
  "(import stdlib.string)
(define (main) : i64
  (let
    [owned : String \"captured\"]
    [inner : (-> i64) (lambda () : i64 (string.string-length owned))]
    [outer : (-> i64) (lambda () : i64 (inner))]
    [moved : (-> i64) outer]
    (+ (moved) (outer))))")

(define (compiler-typecheck-reference-lambda-inner-arena-return-source) : String
  "(define (read [r : (& n i64)]) : i64 42)
(define (main) : (-> i64)
  (with-arena scratch
    (let [n : i64 1]
      (let [r : (& n i64) (& n)]
        (let [f : (-> i64) (lambda () : i64 (read r))]
          f)))))")

(define (compiler-typecheck-reference-lambda-mutable-immediate-source) : String
  "(define (read [r : (&mut items i64)]) : i64 42)
(define (main [items : (__tl_dyn-array i64)]) : i64
  (let [r : (&mut items i64) (&mut (array-ref items 0))]
    ((lambda () : i64 (read r)))))")

(define (compiler-typecheck-reference-lambda-mutable-local-repeat-source) : String
  "(define (write [r : (&mut items i64)]) : unit unit)
(define (main [items : (__tl_dyn-array i64)]) : i64
  (let
    [r : (&mut items i64) (&mut (array-ref items 0))]
    [f : (-> unit) (lambda () : unit (write r))]
    (begin (f) (f) (array-ref items 0))))")

(define (compiler-typecheck-reference-lambda-mutable-alias-source) : String
  "(define (write [r : (&mut items i64)]) : unit unit)
(define (main [items : (__tl_dyn-array i64)]) : unit
  (let
    [r : (&mut items i64) (&mut (array-ref items 0))]
    [f : (-> unit) (lambda () : unit (write r))]
    [alias : (-> unit) f]
    (alias)))")

(define (compiler-typecheck-closure-fnonce-once-source) : String
  "(define (main) : String
  (let
    [owned : String \"once\"]
    [take : (-> String) (lambda () : String owned)]
    (take)))")

(define (compiler-typecheck-closure-fnonce-second-call-source) : String
  "(define (main) : String
  (let
    [owned : String \"once\"]
    [take : (-> String) (lambda () : String owned)]
    [first : String (take)]
    (take)))")

(define (compiler-typecheck-closure-fnonce-escape-source) : String
  "(define (make) : (-> String)
  (let
    [owned : String \"once\"]
    [take : (-> String) (lambda () : String owned)]
    take))")

(define (compiler-typecheck-closure-owner-read-repeat-source) : String
  "(define (read [value : String]) : i64 42)
(define (main) : i64
  (let
    [owned : String \"repeat\"]
    [f : (-> i64) (lambda () : i64 (read owned))]
    (begin (f) (f))))")

(define (compiler-typecheck-reference-tuple-return-ok-source) : String
  "(define (main [n : i64]) : (Tuple (& n i64) i64)
  (tuple (& n) 1))")

(define (compiler-typecheck-reference-fixed-return-ok-source) : String
  "(define (main [n : i64]) : (Array (& n i64) 1)
  (array (& n)))")

(define (compiler-typecheck-reference-tuple-local-escape-source) : String
  "(define (main [n : i64]) : (Tuple (& n i64) i64)
  (let [n : i64 1] (tuple (& n) 1)))")

(define (compiler-typecheck-reference-fixed-local-escape-source) : String
  "(define (main [n : i64]) : (Array (& n i64) 1)
  (let [n : i64 1] (array (& n))))")

(define (compiler-typecheck-reference-tuple-arena-escape-source) : String
  (compiler_typecheck.compiler-typecheck-with-alloc-string-helper-source
    "(define (main [seed : (& phase str)]) : (Tuple (& phase str) i64)
  (with-arena phase
    (let [s : String (string.int->string 1)] (tuple (& phase s) 1))))"))

(define (compiler-typecheck-reference-fixed-arena-escape-source) : String
  (compiler_typecheck.compiler-typecheck-with-alloc-string-helper-source
    "(define (main [seed : (& phase str)]) : (Array (& phase str) 1)
  (with-arena phase
    (let [s : String (string.int->string 1)] (array (& phase s)))))"))

(define (compiler-typecheck-reference-dyn-array-init-ok-source) : String
  "(define (main [n : i64]) : unit
  (let [items : (__tl_dyn-array (& n i64)) (init : (__tl_dyn-array (& n i64)))] unit))")

(define (compiler-typecheck-reference-dyn-array-make-reject-source) : String
  "(define (main [n : i64]) : unit
  (let [items : (__tl_dyn-array (& n i64)) (make-array (& n i64) 0)] unit))")

(define (compiler-typecheck-reference-dyn-array-push-read-ok-source) : String
  "(define (main [n : i64]) : unit
  (let
    [items : (__tl_dyn-array (& n i64)) (init : (__tl_dyn-array (& n i64)))]
    (begin
      (array-push! items (& n))
      (let [r : (& n i64) (array-ref items 0)] unit))))")

(define (compiler-typecheck-reference-dyn-array-push-escape-source) : String
  "(define (main [n : i64]) : unit
  (let
    [items : (__tl_dyn-array (& n i64)) (init : (__tl_dyn-array (& n i64)))]
    (let [n : i64 1] (array-push! items (& n)))))")

(define (compiler-typecheck-reference-dyn-array-hidden-source) : String
  "(define (main) : unit
  (let [items : (__tl_dyn-array (& n i64)) (make-array (& n i64) 0)] unit))")

(define (compiler-typecheck-signature-lifetime-alias-positive-source) : String
  "(defstruct SignatureAliasRec
  (value i64))
(defstruct SignatureAliasStored
  (field i64)
  (pair (Tuple i64 i64))
  (fixed (Array i64 1)))
(define (signature-alias-touch!
  [items : (&mut source (Array SignatureAliasRec))]
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
    (signature-alias-value-lookup (& value) 42)))")

(define (compiler-typecheck-signature-lifetime-alias-unknown-source) : String
  "(define (bad [value : (& source i64)]) : unit
  (let [copy : (& missing i64) value] unit))")

(define (compiler-typecheck-signature-lifetime-alias-local-return-source) : String
  "(define (bad [value : (& source i64)]) : (& source i64)
  (let [local : i64 1] (& source local)))")

(define (compiler-typecheck-bytes-borrowed-source) : String
  "(defstruct ByteViews
  (:lifetimes data)
  (ro (& data bytes))
  (rw (&mut data bytes)))
(define (take [ro : (& data bytes)] [rw : (&mut data bytes)]) : unit unit)
(define (main [ro : (& data bytes)] [rw : (&mut data bytes)]) : unit
  (take ro rw))")

(define (compiler-typecheck-bytes-bare-param-source) : String
  "(define (main [raw : bytes]) : unit unit)")

(define (compiler-typecheck-bytes-bare-local-source) : String
  "(define (main) : unit
  (let [raw : bytes (init : bytes)] unit))")

(define (compiler-typecheck-bytes-bare-struct-source) : String
  "(defstruct BadBytes (payload bytes))
(define (main) : unit unit)")

(define (compiler-typecheck-bytes-bare-array-source) : String
  "(define (main [items : (__tl_dyn-array bytes)]) : unit unit)")

(define (compiler-typecheck-bytes-policy-message) : String
  "typecheck: bytes is a borrowed byte-slice referent; use (& lifetime bytes) or (&mut lifetime bytes)")

(define (compiler-typecheck-zero-make-array-recursive-source) : String
  "(defenum Loop (LoopBox (Box Loop)))
(define (main) : unit
  (let [items : (__tl_dyn-array Loop) (make-array Loop 0)] unit))")

(define (compiler-typecheck-auto-borrow-ok-source) : String
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

(define (compiler-typecheck-auto-borrow-temporary-source) : String
  "(define (take [n : (& n i64)]) : i64 1)
(define (main [n : i64]) : i64
  (take (+ n 1)))")

(define (compiler-typecheck-auto-borrow-shared-lifetime-source) : String
  "(define (same-owner [left : (& same str)] [right : (& same str)]) : i64 1)
(define (main [left : String] [right : String]) : i64
  (same-owner left right))")

(define (compiler-typecheck-auto-borrow-mutable-param-source) : String
  "(define (take-mut [n : (&mut n i64)]) : i64 1)
(define (main [n : i64]) : i64
  (take-mut n))")

(define (compiler-typecheck-mut-to-immut-reborrow-source) : String
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

(define (compiler-typecheck-mut-to-immut-reborrow-live-source) : String
  "(defstruct ReborrowItem (value i64))
(define (view [item : (& source ReborrowItem)]) : (& source ReborrowItem) item)
(define (main [item : (&mut item ReborrowItem)]) : i64
  (let [shared : (& item ReborrowItem) (view item)]
    (begin
      (set! item.value 42)
      shared.value)))")

(define (compiler-typecheck-mut-to-immut-reborrow-mismatch-source) : String
  "(define (read [value : (& shared i64)]) : i64 1)
(define (main [value : (&mut value bool)]) : i64 (read value))")

(define (compiler-typecheck-immut-to-mut-no-strengthen-source) : String
  "(define (write [value : (&mut value i64)]) : unit unit)
(define (main [value : (& value i64)]) : unit (write value))")

(define (compiler-typecheck-auto-borrow-string-aggregate-place-source) : String
  "(defstruct Named (name String))
(define (len [text : (& text str)]) : i64 1)
(define (same [left : (& left str)] [right : (& right str)]) : bool true)
(define (main [named : Named] [items : (Array String 1)]) : i64
  (if (same named.name (array-ref items 0))
    (+ (len named.name) (len (array-ref items 0)))
    0))")

(define (compiler-typecheck-auto-borrow-assignment-after-last-use-source) : String
  "(define (take [n : (& n i64)]) : i64 1)
(define (main [n : i64]) : i64
  (begin
    (take n)
    (set! n 2)
    n))")

(define (compiler-typecheck-auto-borrow-move-after-last-use-source) : String
  "(define (len [text : (& text str)]) : i64 1)
(define (main) : i64
  (let [text : String \"move\"]
    (begin
      (len text)
      (let [moved : String text] 1))))")

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

(define (compiler-typecheck-call-argument-diagnostic-source) : String
  "(define (takes-two [count : i64] [enabled : bool]) : i64 count)
(define (main) : i64 (takes-two true false))")

(define (compiler-typecheck-lambda-argument-diagnostic-source) : String
  "(define (main) : i64
  ((lambda ([item : i64]) : i64 item) false))")

(define (compiler-typecheck-constructor-argument-diagnostic-source) : String
  "(defstruct Pair
  (left i64)
  (right bool))
(define (main) : i64
  (let [pair : Pair (Pair false true)] pair.left))")

(define (compiler-typecheck-lifetime-argument-diagnostic-source) : String
  "(define (take-same
  [left : (& same i64)]
  [right : (& same i64)]) : unit
  unit)
(define (main
  [left-value : (& left-life i64)]
  [right-value : (& right-life i64)]) : unit
  (take-same left-value right-value))")

(define (compiler-typecheck-call-arity-diagnostic-source) : String
  "(define (takes-two [count : i64] [enabled : bool]) : i64 count)
(define (main) : i64 (takes-two 1))")

(define (compiler-typecheck-call-diagnostic-tests-ok?) : bool
  (and
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-call-argument-diagnostic-source)
      "typecheck: call `takes-two` argument 1 (parameter `count`) type mismatch: expected i64, found bool")
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-lambda-argument-diagnostic-source)
      "typecheck: call `lambda` argument 1 (parameter `item`) type mismatch: expected i64, found bool")
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-constructor-argument-diagnostic-source)
      "typecheck: call `Pair` argument 1 (parameter `left`) type mismatch: expected i64, found bool")
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-lifetime-argument-diagnostic-source)
      "typecheck: call `take-same` argument 2 (parameter `right`) type mismatch: expected (& left-life i64), found (& right-life i64); source lifetime `right-life` does not outlive required lifetime `left-life`")
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-call-arity-diagnostic-source)
      "typecheck: call arity mismatch: takes-two expected 2 arguments, got 1 argument")))

(define (compiler-typecheck-auto-borrow-tests-ok?) : bool
  (and
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-auto-borrow-ok-source))
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-auto-borrow-temporary-source)
      "typecheck: borrow requires a local, parameter, or aggregate place")
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-auto-borrow-shared-lifetime-source))
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-auto-borrow-mutable-param-source)
      "typecheck: call `take-mut` argument 1 (parameter `n`) type mismatch: expected (&mut n i64), found i64")
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-mut-to-immut-reborrow-source))
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-mut-to-immut-reborrow-live-source)
      "typecheck: cannot assign to borrowed place `item.value`")
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-mut-to-immut-reborrow-mismatch-source)
      "typecheck: call `read` argument 1 (parameter `value`) type mismatch: expected (& shared i64), found (& value bool)")
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-immut-to-mut-no-strengthen-source)
      "typecheck: call `write` argument 1 (parameter `value`) type mismatch: expected (&mut value i64), found (& value i64)")
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-auto-borrow-string-aggregate-place-source))
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-auto-borrow-assignment-after-last-use-source))
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-auto-borrow-move-after-last-use-source))
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-auto-borrow-assignment-before-last-use-source)
      "typecheck: cannot assign to borrowed place `n`")
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-auto-borrow-move-before-last-use-source)
      "typecheck: cannot move borrowed place `text`")))

(define (compiler-typecheck-borrow-projection-assign-source) : String
  "(defstruct Pair (left i64) (right i64))
(define (read-i64-ref [r : (& pair i64)]) : i64 1)
(define (main [pair : Pair]) : i64
  (let
    [borrowed : (& pair i64) (& pair.left)]
    (begin
      (set! pair.left 3)
      (read-i64-ref borrowed))))")

(define (compiler-typecheck-borrow-mut-after-immut-source) : String
  "(define (read-i64-ref [r : (& items i64)]) : unit unit)
(define (main [items : (__tl_dyn-array i64)]) : unit
  (let
    [borrowed : (& items i64) (& (array-ref items 0))]
    (begin
      (let
        [exclusive : (&mut items i64) (&mut (array-ref items 0))]
        unit)
      (read-i64-ref borrowed))))")

(define (compiler-typecheck-borrow-immut-after-mut-source) : String
  "(define (write-i64-ref [r : (&mut items i64)]) : unit unit)
(define (main [items : (__tl_dyn-array i64)]) : unit
  (let
    [exclusive : (&mut items i64) (&mut (array-ref items 0))]
    (begin
      (let
        [borrowed : (& items i64) (& (array-ref items 0))]
        unit)
      (write-i64-ref exclusive))))")

(define (compiler-typecheck-borrow-returned-call-source) : String
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
        (len borrowed)))))")

(define (compiler-typecheck-borrow-returned-call-after-last-use-source) : String
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

(define (compiler-typecheck-borrow-non-returning-call-source) : String
  "(define (len [text : (& text str)]) : i64 1)
(define (main) : i64
  (let
    [text : String \"borrowed\"]
    (begin
      (let [n : i64 (len (& text))] n)
      (let [moved : String text] 1))))")

(define (compiler-typecheck-borrow-narrow-lexical-ok-source) : String
  "(define (take [n : (& n i64)]) : i64
  1)
(define (main [n : i64]) : i64
  (begin
    (let [tmp : i64 (take n)] tmp)
    (set! n 2)
    n))")

(define (compiler-typecheck-mut-borrow-disjoint-fields-source) : String
  "(defstruct Bags
  (left (__tl_dyn-array i64))
  (right (__tl_dyn-array i64)))
(define (main) : unit
  (let
    [left-items : (__tl_dyn-array i64) (make-array i64 1)]
    [right-items : (__tl_dyn-array i64) (make-array i64 1)]
    [bags : Bags (Bags left-items right-items)]
    (let
      [left : (&mut bags (__tl_dyn-array i64)) (&mut bags.left)]
      [right : (&mut bags (__tl_dyn-array i64)) (&mut bags.right)]
      unit)))")

(define (compiler-typecheck-mut-borrow-same-field-source) : String
  "(defstruct Bags
  (left (__tl_dyn-array i64))
  (right (__tl_dyn-array i64)))
(define (write-array-ref [items : (&mut bags (__tl_dyn-array i64))]) : unit unit)
(define (main) : unit
  (let
    [left-items : (__tl_dyn-array i64) (make-array i64 1)]
    [right-items : (__tl_dyn-array i64) (make-array i64 1)]
    [bags : Bags (Bags left-items right-items)]
    (let
      [first : (&mut bags (__tl_dyn-array i64)) (&mut bags.left)]
      [second : (&mut bags (__tl_dyn-array i64)) (&mut bags.left)]
      (write-array-ref first))))")

(define (compiler-typecheck-mut-borrow-ancestor-descendant-source) : String
  "(defstruct Bags
  (left (__tl_dyn-array i64))
  (right (__tl_dyn-array i64)))
(define (main) : unit
  (let
    [left-items : (__tl_dyn-array i64) (make-array i64 1)]
    [right-items : (__tl_dyn-array i64) (make-array i64 1)]
    [bags : Bags (Bags left-items right-items)]
    (let
      [whole-left : (&mut bags (__tl_dyn-array i64)) (&mut bags.left)]
      [first-item : (&mut bags i64) (&mut (array-ref bags.left 0))]
      (set! (array-ref whole-left 0) 1))))")

(define (compiler-typecheck-mut-reborrow-bound-subscope-source) : String
  "(define (touch [slot : (&mut items i64)]) : unit unit)
(define (use [items : (&mut items (__tl_dyn-array i64))]) : unit
  (begin
    (let
      [slot : (&mut items i64) (&mut (array-ref items 0))]
      (touch slot))
    (set! (array-ref items 0) 7)))
(define (main [items : (__tl_dyn-array i64)]) : unit
  (use (&mut items)))")

(define (compiler-typecheck-mut-reborrow-same-scope-use-source) : String
  "(define (touch [slot : (&mut items i64)]) : unit unit)
(define (bad [items : (&mut items (__tl_dyn-array i64))]) : unit
  (let
    [slot : (&mut items i64) (&mut (array-ref items 0))]
    (begin
      (set! (array-ref items 0) 7)
      (touch slot))))
(define (main [items : (__tl_dyn-array i64)]) : unit
  (bad (&mut items)))")

(define (compiler-typecheck-mut-borrow-read-array-length-source) : String
  "(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (make-array i64 1)]
    [borrowed : (&mut items (__tl_dyn-array i64)) (&mut items)]
    [n : i64 (array-length items)]
    (begin
      (set! (array-ref borrowed 0) 41)
      (+ n 1))))")

(define (compiler-typecheck-mut-borrow-read-array-ref-source) : String
  "(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (make-array i64 1)]
    [borrowed : (&mut items (__tl_dyn-array i64)) (&mut items)]
    [n : i64 (array-ref items 0)]
    (begin
      (set! (array-ref borrowed 0) 41)
      n)))")

(define (compiler-typecheck-mut-borrow-read-struct-get-source) : String
  "(defstruct Bag
  (left (__tl_dyn-array i64))
  (right i64))
(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (make-array i64 1)]
    [bag : Bag (Bag items 42)]
    [borrowed : (&mut bag (__tl_dyn-array i64)) (&mut bag.left)]
    [copy : (__tl_dyn-array i64) bag.left]
    (begin
      (set! (array-ref borrowed 0) 41)
      (array-length copy))))")

(define (compiler-typecheck-mut-borrow-read-disjoint-source) : String
  "(defstruct Bag
  (left (__tl_dyn-array i64))
  (right i64))
(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (make-array i64 1)]
    [bag : Bag (Bag items 42)]
    [borrowed : (&mut bag (__tl_dyn-array i64)) (&mut bag.left)]
    [right : i64 bag.right]
    (begin
      (set! (array-ref borrowed 0) 41)
      right)))")

(define (compiler-typecheck-mut-borrow-read-through-ref-source) : String
  "(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (make-array i64 1)]
    [borrowed : (&mut items (__tl_dyn-array i64)) (&mut items)]
    [n : i64 (array-length borrowed)]
    (begin
      (set! (array-ref borrowed 0) 41)
      n)))")

(define (compiler-typecheck-mut-borrow-owner-read-after-last-use-source) : String
  "(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (make-array i64 1)]
    [borrowed : (&mut items (__tl_dyn-array i64)) (&mut items)]
    (begin
      (set! (array-ref borrowed 0) 41)
      (array-length items))))")

(define (compiler-typecheck-two-phase-mut-call-shared-read-source) : String
  "(define (read-len [items : (& items (__tl_dyn-array i64))]) : i64
  (array-length items))
(define (push-with-len [items : (&mut items (__tl_dyn-array i64))] [value : i64]) : unit
  (array-push! items value))
(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (make-array i64 1)]
    (begin
      (push-with-len (&mut items) (read-len (& items)))
      (array-length items))))")

(define (compiler-typecheck-two-phase-mut-call-direct-read-source) : String
  "(define (push-with-len [items : (&mut items (__tl_dyn-array i64))] [value : i64]) : unit
  (array-push! items value))
(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (make-array i64 1)]
    (begin
      (push-with-len (&mut items) (array-length items))
      (array-length items))))")

(define (compiler-typecheck-two-phase-mut-call-second-mut-source) : String
  "(define (take-two
  [left : (&mut left (__tl_dyn-array i64))]
  [right : (&mut right (__tl_dyn-array i64))]) : unit
  unit)
(define (main) : unit
  (let
    [items : (__tl_dyn-array i64) (make-array i64 1)]
    (take-two (&mut items) (&mut items))))")

(define (compiler-typecheck-two-phase-mut-call-escaping-shared-source) : String
  "(define (borrow-items [items : (& items (__tl_dyn-array i64))]) : (& items (__tl_dyn-array i64))
  items)
(define (take-mut-and-view
  [items : (&mut items (__tl_dyn-array i64))]
  [view : (& items (__tl_dyn-array i64))]) : unit
  unit)
(define (main) : unit
  (let
    [items : (__tl_dyn-array i64) (make-array i64 1)]
    (take-mut-and-view (&mut items) (borrow-items (& items)))))")

(define (compiler-typecheck-two-phase-mut-call-mutate-owner-source) : String
  "(define (take-mut-and-value
  [items : (&mut items (__tl_dyn-array i64))]
  [value : i64]) : unit
  unit)
(define (main) : unit
  (let
    [items : (__tl_dyn-array i64) (make-array i64 1)]
    (take-mut-and-value (&mut items) (begin (array-push! items 1) 0))))")

(define (compiler-typecheck-borrow-if-conservative-source) : String
  "(define (take [n : (& n i64)]) : i64 1)
(define (main [n : i64] [flag : bool]) : i64
  (let
    [borrowed : (& n i64) (& n)]
    (begin
      (if flag (set! n 2) unit)
      (take borrowed))))")

(define (compiler-typecheck-borrow-if-branch-local-after-join-source) : String
  "(define (take [n : (& n i64)]) : i64 1)
(define (main [n : i64] [flag : bool]) : i64
  (begin
    (if flag
      (let [borrowed : (& n i64) (& n)] (begin (take borrowed) unit))
      unit)
    (set! n 2)
    n))")

(define (compiler-typecheck-borrow-if-result-before-last-use-source) : String
  "(define (take [n : (& n i64)]) : i64 1)
(define (main [n : i64] [flag : bool]) : i64
  (let
    [borrowed : (& n i64)
      (if flag
        (& n)
        (& n))]
    (begin
      (set! n 2)
      (take borrowed))))")

(define (compiler-typecheck-borrow-if-result-after-last-use-source) : String
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

(define (compiler-typecheck-borrow-match-branch-local-after-join-source) : String
  "(define (take [n : (& n i64)]) : i64 1)
(defenum Flag (On) (Off))
(define (main [n : i64] [flag : Flag]) : i64
  (begin
    (match flag
      [On (let [borrowed : (& n i64) (& n)] (begin (take borrowed) unit))]
      [Off unit])
    (set! n 2)
    n))")

(define (compiler-typecheck-borrow-match-result-before-last-use-source) : String
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
      (take borrowed))))")

(define (compiler-typecheck-borrow-match-result-after-last-use-source) : String
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

(define (compiler-typecheck-borrow-if-aggregate-result-before-last-use-source) : String
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
      (read-box box))))")

(define (compiler-typecheck-borrow-if-aggregate-result-after-last-use-source) : String
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

(define (compiler-typecheck-borrow-while-conservative-source) : String
  "(define (take [n : (& n i64)]) : i64 1)
(define (main [n : i64]) : i64
  (let
    [borrowed : (& n i64) (& n)]
    (begin
      (while (< n 3) (set! n 2))
      (take borrowed))))")

(define (compiler-typecheck-borrow-while-body-after-last-use-source) : String
  "(define (take [n : (& n i64)]) : i64 1)
(define (main [n : i64] [limit : i64]) : i64
  (let [i : i64 0]
    (begin
      (while (< i limit)
        (let [borrowed : (& n i64) (& n)]
          (begin
            (take borrowed)
            (set! n (+ n 1))
            (set! i (+ i 1)))))
      n)))")

(define (compiler-typecheck-borrow-foreach-body-after-last-use-source) : String
  "(define (take [n : (& n i64)]) : i64 1)
(define (main [n : i64] [out : (__tl_dyn-array i64)] [limit : i64]) : unit
  (foreach ([i : i64 0 limit])
    (let [borrowed : (& n i64) (& n)]
      (begin
        (take borrowed)
        (set! (array-ref out i) n)))))")

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
  [diag : diagnostic.CompilerDiagnostic]
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
        [message : String
          (diagnostic.compiler-diagnostic-message
            (diagnostic.compiler-diagnostic-list-first (__tl-box-place diag)))]
        (and
          (string.contains (& message) (& want-message-fragment))
          (compiler-typecheck-help-contains?
            (diagnostic.compiler-diagnostic-list-first (__tl-box-place diag))
            "narrower lexical scope")
          (=
            (compiler_typecheck.compiler-typecheck-secondary-count
              (diagnostic.compiler-diagnostic-secondary-spans
                (diagnostic.compiler-diagnostic-list-first
                  (__tl-box-place diag))))
            1)
          (compiler-typecheck-secondary-label-contains?
            (diagnostic.compiler-diagnostic-secondary-spans
              (diagnostic.compiler-diagnostic-list-first (__tl-box-place diag)))
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
      (compiler-typecheck-borrow-projection-assign-source)
      "typecheck: cannot assign to borrowed place `pair.left`")
    (compiler-typecheck-labeled-borrow-error-ok?
      (compiler-typecheck-borrow-mut-after-immut-source)
      "typecheck: cannot mutably borrow borrowed place")
    (compiler-typecheck-labeled-borrow-error-ok?
      (compiler-typecheck-borrow-immut-after-mut-source)
      "typecheck: cannot read mutably borrowed place `items[0]`")
    (compiler-typecheck-labeled-borrow-error-ok?
      (compiler-typecheck-borrow-returned-call-source)
      "typecheck: cannot move borrowed place `text`")
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-borrow-returned-call-after-last-use-source))
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-borrow-non-returning-call-source))
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-borrow-narrow-lexical-ok-source))
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-mut-borrow-disjoint-fields-source))
    (compiler-typecheck-labeled-borrow-error-ok?
      (compiler-typecheck-mut-borrow-same-field-source)
      "typecheck: cannot read mutably borrowed place `bags.left`")
    (compiler-typecheck-labeled-borrow-error-ok?
      (compiler-typecheck-mut-borrow-ancestor-descendant-source)
      "typecheck: cannot read mutably borrowed place `bags.left[0]`")
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-mut-reborrow-bound-subscope-source))
    (compiler-typecheck-labeled-borrow-error-ok?
      (compiler-typecheck-mut-reborrow-same-scope-use-source)
      "typecheck: cannot assign to borrowed place `items[0]`")
    (compiler-typecheck-labeled-borrow-error-ok?
      (compiler-typecheck-mut-borrow-read-array-length-source)
      "typecheck: cannot read mutably borrowed place `items`")
    (compiler-typecheck-labeled-borrow-error-ok?
      (compiler-typecheck-mut-borrow-read-array-ref-source)
      "typecheck: cannot read mutably borrowed place `items[0]`")
    (compiler-typecheck-labeled-borrow-error-ok?
      (compiler-typecheck-mut-borrow-read-struct-get-source)
      "typecheck: cannot read mutably borrowed place `bag.left`")
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-mut-borrow-read-disjoint-source))
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-mut-borrow-read-through-ref-source))
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-mut-borrow-owner-read-after-last-use-source))
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-two-phase-mut-call-shared-read-source))
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-two-phase-mut-call-direct-read-source))
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-two-phase-mut-call-second-mut-source)
      "typecheck: cannot mutably borrow borrowed place `items`")
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-two-phase-mut-call-escaping-shared-source)
      "typecheck: cannot mutably borrow borrowed place `items`")
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-two-phase-mut-call-mutate-owner-source)
      "typecheck: cannot assign to borrowed place `items`")
    (compiler-typecheck-labeled-borrow-error-ok?
      (compiler-typecheck-borrow-if-conservative-source)
      "typecheck: cannot assign to borrowed place `n`")
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-borrow-if-branch-local-after-join-source))
    (compiler-typecheck-labeled-borrow-error-ok?
      (compiler-typecheck-borrow-if-result-before-last-use-source)
      "typecheck: cannot assign to borrowed place `n`")
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-borrow-if-result-after-last-use-source))
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-borrow-match-branch-local-after-join-source))
    (compiler-typecheck-labeled-borrow-error-ok?
      (compiler-typecheck-borrow-match-result-before-last-use-source)
      "typecheck: cannot assign to borrowed place `n`")
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-borrow-match-result-after-last-use-source))
    (compiler-typecheck-labeled-borrow-error-ok?
      (compiler-typecheck-borrow-if-aggregate-result-before-last-use-source)
      "typecheck: cannot assign to borrowed place `n`")
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-borrow-if-aggregate-result-after-last-use-source))
    (compiler-typecheck-labeled-borrow-error-ok?
      (compiler-typecheck-borrow-while-conservative-source)
      "typecheck: cannot assign to borrowed place `n`")
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-borrow-while-body-after-last-use-source))
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-borrow-foreach-body-after-last-use-source))))

(define (compiler-typecheck-labeled-move-error-ok?
  [src : String]
  [want-message : String]
  [want-label-fragment : String]) : bool
  (match (tc_api.typecheck-compiler-source src)
    [(tc_core.ResultCompilerTypecheck.Err diag)
      (and
        (string.eq
          (diagnostic.compiler-diagnostic-message
            (diagnostic.compiler-diagnostic-list-first (__tl-box-place diag)))
          want-message)
        (compiler-typecheck-help-contains?
          (diagnostic.compiler-diagnostic-list-first (__tl-box-place diag))
          "clone the owner")
        (=
          (compiler_typecheck.compiler-typecheck-secondary-count
            (diagnostic.compiler-diagnostic-secondary-spans
              (diagnostic.compiler-diagnostic-list-first (__tl-box-place diag))))
          1)
        (compiler-typecheck-secondary-label-contains?
          (diagnostic.compiler-diagnostic-secondary-spans
            (diagnostic.compiler-diagnostic-list-first (__tl-box-place diag)))
          want-label-fragment))]
    [(tc_core.ResultCompilerTypecheck.Ok _) false]))

(define (compiler-typecheck-labeled-cleanup-move-error-ok?
  [src : String]
  [want-message : String]
  [want-move-label-fragment : String]
  [want-owner-label-fragment : String]) : bool
  (match (tc_api.typecheck-compiler-source src)
    [(tc_core.ResultCompilerTypecheck.Err diag)
      (and
        (string.eq
          (diagnostic.compiler-diagnostic-message
            (diagnostic.compiler-diagnostic-list-first (__tl-box-place diag)))
          want-message)
        (compiler-typecheck-help-contains?
          (diagnostic.compiler-diagnostic-list-first (__tl-box-place diag))
          "clone the owner")
        (=
          (compiler_typecheck.compiler-typecheck-secondary-count
            (diagnostic.compiler-diagnostic-secondary-spans
              (diagnostic.compiler-diagnostic-list-first (__tl-box-place diag))))
          2)
        (compiler-typecheck-secondary-label-contains?
          (diagnostic.compiler-diagnostic-secondary-spans
            (diagnostic.compiler-diagnostic-list-first (__tl-box-place diag)))
          want-move-label-fragment)
        (compiler-typecheck-secondary-label-contains?
          (diagnostic.compiler-diagnostic-secondary-spans
            (diagnostic.compiler-diagnostic-list-first (__tl-box-place diag)))
          want-owner-label-fragment))]
    [(tc_core.ResultCompilerTypecheck.Ok _) false]))

(define (compiler-typecheck-move-diagnostic-tests-ok?) : bool
  (and
    (compiler-typecheck-labeled-move-error-ok?
      (compiler_typecheck.compiler-typecheck-move-use-after-move-source)
      "typecheck: use of moved value `s`"
      "move of `s` happened here")
    (compiler-typecheck-labeled-move-error-ok?
      (compiler_typecheck.compiler-typecheck-move-owner-projection-nested-repeat-source)
      "typecheck: use of moved value `p.inner.handle`"
      "move of `p.inner.handle` happened here")
    (compiler-typecheck-labeled-move-error-ok?
      (compiler_typecheck.compiler-typecheck-move-owner-projection-deep-mixed-repeat-source)
      "typecheck: use of moved value `p.mixed.0[1].0`"
      "move of `p.mixed.0[1].0` happened here")
    (compiler-typecheck-labeled-move-error-ok?
      (compiler_typecheck.compiler-typecheck-move-owner-projection-nested-parent-after-child-source)
      "typecheck: use of moved value `p.inner`"
      "move of `p.inner.handle` happened here")
    (compiler-typecheck-labeled-move-error-ok?
      (compiler_typecheck.compiler-typecheck-move-owner-projection-nested-child-after-parent-source)
      "typecheck: use of moved value `p.inner`"
      "move of `p.inner` happened here")
    (compiler-typecheck-labeled-move-error-ok?
      (compiler_typecheck.compiler-typecheck-move-while-loop-carried-param-source)
      "typecheck: cannot move loop-carried owner value `s`"
      "loop-carried")
    (compiler-typecheck-labeled-cleanup-move-error-ok?
      (compiler_typecheck.compiler-typecheck-move-with-cleanup-owner-whole-source)
      "typecheck: cleanup owner `h` moved before with scope exit"
      "move of `h` happened here"
      "cleanup owner `h` is bound")
    (compiler-typecheck-labeled-cleanup-move-error-ok?
      (compiler_typecheck.compiler-typecheck-move-with-cleanup-owner-field-source)
      "typecheck: cleanup owner `h` moved before with scope exit"
      "move of `h.handle` happened here"
      "cleanup owner `h` is bound")))

(define (compiler-typecheck-reference-return-container-tests-ok?) : bool
  (and
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-reference-tuple-return-ok-source))
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-reference-fixed-return-ok-source))
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-reference-tuple-local-escape-source)
      "typecheck: reference value would escape lexical scope")
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-reference-fixed-local-escape-source)
      "typecheck: reference value would escape lexical scope")
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-reference-tuple-arena-escape-source)
      "typecheck: region-tagged value cannot escape with-arena 'phase'")
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-reference-fixed-arena-escape-source)
      "typecheck: region-tagged value cannot escape with-arena 'phase'")))

(define (compiler-typecheck-reference-dyn-array-tests-ok?) : bool
  (and
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-reference-dyn-array-init-ok-source))
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-reference-dyn-array-push-read-ok-source))
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-zero-make-array-recursive-source))
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-reference-dyn-array-push-escape-source)
      "typecheck: cannot store reference into longer-lived array; reference value would escape lexical scope")
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-reference-dyn-array-make-reject-source)
      "typecheck: init unsupported type (& n i64)")
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-reference-dyn-array-hidden-source)
      "typecheck: make-array element type is not supported")))

(define (compiler-typecheck-signature-lifetime-alias-tests-ok?) : bool
  (and
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-signature-lifetime-alias-positive-source))
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-signature-lifetime-alias-unknown-source)
      "typecheck: let binding `copy` type mismatch: expected (& missing i64), found (& source i64); source lifetime `source` does not outlive required lifetime `missing`")
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-signature-lifetime-alias-local-return-source)
      "typecheck: borrow lifetime mismatch")))

(define (compiler-typecheck-bytes-referent-tests-ok?) : bool
  (and
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-bytes-borrowed-source))
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-bytes-bare-param-source)
      (compiler-typecheck-bytes-policy-message))
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-bytes-bare-local-source)
      (compiler-typecheck-bytes-policy-message))
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-bytes-bare-struct-source)
      (compiler-typecheck-bytes-policy-message))
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-bytes-bare-array-source)
      (compiler-typecheck-bytes-policy-message))))

(define (compiler-typecheck-reference-lambda-capture-tests-ok?) : bool
  (and
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-reference-lambda-immediate-ok-source))
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-reference-lambda-local-ok-source))
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-reference-lambda-while-ok-source))
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-lambda-large-global-env-source))
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-reference-lambda-nested-ok-source))
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-reference-lambda-inner-arena-ok-source))
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-reference-lambda-local-return-source)
      "typecheck: reference-capturing closure value would escape lexical scope")
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-reference-lambda-store-source)
      "typecheck: reference-capturing closure value would escape lexical scope")
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-reference-lambda-pass-unknown-source)
      "typecheck: reference-capturing closure value would escape lexical scope")
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-reference-lambda-assign-source)
      "typecheck: reference-capturing closure value would escape lexical scope")
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-reference-lambda-inner-arena-return-source)
      "typecheck: reference-capturing closure value would escape lexical scope")
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-reference-lambda-mutable-immediate-source))
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-reference-lambda-mutable-local-repeat-source))
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-reference-lambda-mutable-alias-source)
      "typecheck: reference-capturing closure value would escape lexical scope")
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-closure-fnonce-once-source))
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-closure-fnonce-second-call-source)
      "typecheck: use of moved value `take`")
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-closure-fnonce-escape-source)
      "typecheck: closure capability would be erased by escaping the direct local binding")
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-closure-owner-read-repeat-source))))

(define (compiler-typecheck-closure-copy-tests-ok?) : bool
  (and
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-closure-copy-aggregate-source))
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-closure-copy-reference-source))
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-closure-copy-reference-escape-source)
      "typecheck: reference-capturing closure value would escape lexical scope")
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-closure-move-owner-alias-source)
      "typecheck: use of moved value `f`")
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-closure-move-nested-alias-source)
      "typecheck: use of moved value `outer`")))

(define (compiler-typecheck-reference-escape-tests-ok?) : bool
  (and
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-reference-nested-local-source))
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-reference-inner-let-escape-source)
      "typecheck: reference value would escape lexical scope")
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-reference-outer-assignment-escape-source)
      "typecheck: cannot store reference into longer-lived binding; reference value would escape lexical scope")
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-reference-container-escape-source)
      "typecheck: cannot store reference into longer-lived array; reference value would escape lexical scope")
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-reference-array-push-ok-source))
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-reference-array-push-escape-source)
      "typecheck: cannot store reference into longer-lived array; reference value would escape lexical scope")
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-reference-arena-store-escape-source)
      "typecheck: cannot store reference into longer-lived array; reference value would escape lexical scope")
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-reference-lambda-capture-source)
      "typecheck: lambda cannot capture immutable reference; reference value would escape lexical scope")
    (compiler-typecheck-reference-lambda-capture-tests-ok?)
    (compiler-typecheck-closure-copy-tests-ok?)
    (compiler-typecheck-reference-return-container-tests-ok?)
    (compiler-typecheck-reference-dyn-array-tests-ok?)
    (compiler-typecheck-signature-lifetime-alias-tests-ok?)
    (compiler-typecheck-bytes-referent-tests-ok?)))

(define (compiler-typecheck-macro-alias-cache-collision-ok?) : bool
  (begin
    (tc_core.macro-alias-cache-reset!)
    (tc_core.macro-alias-cache-ensure!)
    (tc_core.macro-alias-cache-put! 1 (ci.intern-capacity) 11)
    (tc_core.macro-alias-cache-put! 2 0 22)
    (tc_core.macro-alias-cache-put! 3 1 -1)
    (tc_core.macro-alias-cache-put! 3 1 33)
    (tc_core.macro-alias-cache-put! 4 2 2)
    (tc_core.macro-alias-cache-put! 4 2 44)
    (tc_core.macro-alias-cache-put! 5 3 3)
    (tc_core.macro-alias-cache-put! 5 3 -3)
    (tc_core.macro-alias-cache-put! 6 4 4)
    (tc_core.macro-alias-cache-put! 6 4 -3)
    (tc_core.macro-alias-cache-put! 6 4 66)
    (and
      (= (tc_core.macro-alias-cache-get 1 (ci.intern-capacity)) 11)
      (= (tc_core.macro-alias-cache-get 2 0) 22)
      (= (tc_core.macro-alias-cache-get 3 1) 33)
      (= (tc_core.macro-alias-cache-get 4 2) 44)
      (= (tc_core.macro-alias-cache-get 5 3) -3)
      (= (tc_core.macro-alias-cache-get 6 4) 66))))

(define (compiler-typecheck-smoke-module-macro-import-evaluated-key-source) : String
  "(defmacro (gen [key : String]) : Module
  `(begin
    (module generated.module)
    (define (answer) : i64 42)))
(import (gen \"same\"))
(import (gen (if true \"same\" \"other\")))
(define (main) : i64 (answer))")

(define (compiler-typecheck-smoke-module-macro-import-incompatible-key-source) : String
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
(define (main) : i64 (answer))")

(define (compiler-typecheck-smoke-module-macro-generated-collision-source) : String
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
(define (main) : i64 (answer))")

(define (compiler-typecheck-smoke-module-macro-generated-local-shadow-source) : String
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

(define (compiler-typecheck-smoke-module-macro-local-collision-source) : String
  "(defmacro (gen [key : String]) : Module
  `(begin
    (module generated.module)
    (define (answer) : i64 42)))
(define (answer) : i64 0)
(import (gen \"x\"))
(define (main) : i64 (answer))")

(define (compiler-typecheck-smoke-module-macro-type-key-source) : String
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

(define (compiler-typecheck-smoke-module-macro-nested-vector-import-source) : String
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

(define (compiler-typecheck-smoke-module-macro-local-type-stdlib-vector-source) : String
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
          (vec.push (&mut items) value)
          (let [item : T (vec.get (& items) 0 (T 0))] item.value))))))
(import (vector-user) as user)
(define (main) : i64
  (user.score (user.make 42)))")

(define (compiler-typecheck-smoke-module-macro-qualified-type-stdlib-vector-source) : String
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
          (vec.push (&mut items) value)
          (let
            [item : provider.T (vec.get (& items) 0 (provider.T 0))]
            item.value))))))
(import (vector-user) as user)
(define (main) : i64
  (user.score (user.make 42)))")

(define (compiler-typecheck-smoke-module-macro-param-type-stdlib-vector-source) : String
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
          (vec.push (&mut items) value)
          (vec.len (& items)))))))
(import (vector-user Pair) as user)
(define (main) : i64
  (user.score (Pair 42)))")

(define (compiler-typecheck-smoke-module-macro-local-import-param-vector-source) : String
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
          (vec.push (&mut items) value)
          (vec.len (& items)))))))
(import (vector-user Pair) as user)
(define (main) : i64
  (user.score (Pair 42)))")

(define (compiler-typecheck-smoke-module-macro-imported-aggregate-stdlib-vector-source) : String
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

(define (compiler-typecheck-smoke-module-macro-generated-import-nested-enum-payload-source) : String
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

(define (compiler-typecheck-smoke-module-macro-generated-init-nested-root-source) : String
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

(define (compiler-typecheck-smoke-module-macro-generated-replay-normalized-source) : String
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

(define (compiler-typecheck-smoke-module-macro-strategy-alias-source) : String
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

(define (compiler-typecheck-smoke-module-macro-strategy-dedup-source) : String
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

(define (compiler-typecheck-smoke-module-macro-strategy-missing-hook-source) : String
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
(define (main) : i64 (gen.answer))")

(define (compiler-typecheck-smoke-module-macro-strategy-unresolved-source) : String
  "(defmacro (make [format : Module]) : Module
  `(begin
    (module generated.strategy_unresolved)
    (define (answer) : i64 0)))
(import (make missing) as gen)
(define (main) : i64 (gen.answer))")

(define (compiler-typecheck-smoke-module-macro-strategy-vector-hook-source) : String
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
            (vec.push (&mut items) value)
            (let [item : T (vec.get (& items) 0 (T 0))] item.value)))))))
(import (make vector) as gen)
(define (main) : i64
  (gen.score (gen.make 42)))")

(define (compiler-typecheck-smoke-module-macro-extension-source) : String
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

(define (compiler-typecheck-smoke-module-macro-extension-incompatible-source) : String
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
  (+ (base.answer) (+ (extra.bonus) (extra2.bonus))))")

(define (compiler-typecheck-smoke-comptime-error-expression-source) : String
  "(import stdlib.comptime)
(defmacro (badexpr [x : Expr]) : i64
  (comptime.error \"custom expression macro failure\"))
(define (main) : i64
  (badexpr 42))")

(define (compiler-typecheck-smoke-comptime-error-module-source) : String
  "(import stdlib.comptime)
(defmacro (badmod [key : String]) : Module
  (comptime.error \"custom module macro failure\"))
(import (badmod \"x\") as bad)
(define (main) : i64 0)")

(define (compiler-typecheck-smoke-comptime-error-decls-source) : String
  "(import stdlib.comptime)
(defmacro (baddecls) : Decls
  (comptime.error \"custom decl macro failure\"))
(baddecls)
(define (main) : i64 0)")

(define (compiler-typecheck-smoke-comptime-error-tests-ok?) : bool
  (and
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-smoke-comptime-error-expression-source)
      "custom expression macro failure")
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-smoke-comptime-error-module-source)
      "custom module macro failure")
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-smoke-comptime-error-decls-source)
      "custom decl macro failure")))

(define (compiler-typecheck-smoke-module-catalog-invalid-unused-source) : String
  "(defmacro (catalog [T : type]) : Module
  `(begin
    (module generated.catalog_invalid)
    (defstruct Item (value ,T))
    (define (answer) : i64 42)
    (define (invalid-unused-helper) : i64 true)))
(import (catalog i64) as catalog_i64)
(define (main) : i64 (catalog_i64.answer))")

(define (compiler-typecheck-smoke-require [ok : bool] [name : String]) : bool
  (if ok
    true
    (io.panic name)))

(define (compiler-typecheck-smoke-module-macro-identity-tests-ok?) : bool
  (and
    (compiler-typecheck-smoke-require
      (compiler_typecheck.compiler-typecheck-error-ok?
        (compiler-typecheck-smoke-module-catalog-invalid-unused-source)
        "typecheck: return type mismatch: expected i64, found bool")
      "typecheck: generated module catalog skipped invalid unused helper")
    (compiler-typecheck-smoke-require
      (compiler_typecheck.compiler-typecheck-ok?
        (compiler-typecheck-smoke-module-macro-import-evaluated-key-source))
      "typecheck: module macro identity import evaluated key failed")
    (compiler-typecheck-smoke-require
      (compiler_typecheck.compiler-typecheck-error-ok?
        (compiler-typecheck-smoke-module-macro-import-incompatible-key-source)
        "typecheck: Module macro output for generated identity :gen(string_3_105_54_52) has incompatible payload")
      "typecheck: module macro identity import incompatible key failed")
    (compiler-typecheck-smoke-require
      (compiler_typecheck.compiler-typecheck-error-ok?
        (compiler-typecheck-smoke-module-macro-generated-collision-source)
        "typecheck: ambiguous unqualified import for value answer between modules generated.a and generated.b; use an explicit alias or qualified access")
      "typecheck: module macro identity generated collision failed")
    (compiler-typecheck-smoke-require
      (compiler_typecheck.compiler-typecheck-ok?
        (compiler-typecheck-smoke-module-macro-generated-local-shadow-source))
      "typecheck: module macro identity generated local shadow failed")
    (compiler-typecheck-smoke-require
      (compiler_typecheck.compiler-typecheck-ok?
        (compiler-typecheck-smoke-module-macro-local-collision-source))
      "typecheck: module macro identity local collision failed")
    (compiler-typecheck-smoke-require
      (compiler_typecheck.compiler-typecheck-ok?
        (compiler-typecheck-smoke-module-macro-type-key-source))
      "typecheck: module macro identity type key failed")
    (compiler-typecheck-smoke-require
      (compiler_typecheck.compiler-typecheck-ok?
        (compiler-typecheck-smoke-module-macro-nested-vector-import-source))
      "typecheck: module macro identity nested vector import failed")
    (compiler-typecheck-smoke-require
      (compiler_typecheck.compiler-typecheck-ok?
        (compiler-typecheck-smoke-module-macro-local-type-stdlib-vector-source))
      "typecheck: module macro identity local type stdlib vector failed")
    (compiler-typecheck-smoke-require
      (compiler_typecheck.compiler-typecheck-ok?
        (compiler-typecheck-smoke-module-macro-qualified-type-stdlib-vector-source))
      "typecheck: module macro identity qualified type stdlib vector failed")
    (compiler-typecheck-smoke-require
      (compiler_typecheck.compiler-typecheck-ok?
        (compiler-typecheck-smoke-module-macro-param-type-stdlib-vector-source))
      "typecheck: module macro identity param type stdlib vector failed")
    (compiler-typecheck-smoke-require
      (compiler_typecheck.compiler-typecheck-ok?
        (compiler-typecheck-smoke-module-macro-local-import-param-vector-source))
      "typecheck: module macro identity local import param vector failed")
    (compiler-typecheck-smoke-require
      (compiler_typecheck.compiler-typecheck-ok?
        (compiler-typecheck-smoke-module-macro-imported-aggregate-stdlib-vector-source))
      "typecheck: module macro identity imported aggregate stdlib vector failed")
    (compiler-typecheck-smoke-require
      (compiler_typecheck.compiler-typecheck-ok?
        (compiler-typecheck-smoke-module-macro-generated-import-nested-enum-payload-source))
      "typecheck: module macro identity generated import nested enum payload failed")
    (compiler-typecheck-smoke-require
      (compiler_typecheck.compiler-typecheck-ok?
        (compiler-typecheck-smoke-module-macro-generated-init-nested-root-source))
      "typecheck: module macro identity generated init nested root failed")
    (compiler-typecheck-smoke-require
      (compiler_typecheck.compiler-typecheck-ok?
        (compiler-typecheck-smoke-module-macro-generated-replay-normalized-source))
      "typecheck: module macro identity generated replay normalized failed")
    (compiler-typecheck-smoke-require
      (compiler_typecheck.compiler-typecheck-ok?
        (compiler-typecheck-smoke-module-macro-strategy-alias-source))
      "typecheck: module macro identity strategy alias failed")
    (compiler-typecheck-smoke-require
      (compiler_typecheck.compiler-typecheck-ok?
        (compiler-typecheck-smoke-module-macro-strategy-dedup-source))
      "typecheck: module macro identity strategy dedup failed")
    (compiler-typecheck-smoke-require
      (compiler_typecheck.compiler-typecheck-error-ok?
        (compiler-typecheck-smoke-module-macro-strategy-missing-hook-source)
        "typecheck: strategy module toy.empty does not export hook emit-i64")
      "typecheck: module macro identity strategy missing hook failed")
    (compiler-typecheck-smoke-require
      (compiler_typecheck.compiler-typecheck-error-ok?
        (compiler-typecheck-smoke-module-macro-strategy-unresolved-source)
        "typecheck: unknown module strategy missing; import the module or use a visible dotted module alias")
      "typecheck: module macro identity strategy unresolved failed")
    (compiler-typecheck-smoke-require
      (compiler_typecheck.compiler-typecheck-ok?
        (compiler-typecheck-smoke-module-macro-strategy-vector-hook-source))
      "typecheck: module macro identity strategy vector hook failed")
    (compiler-typecheck-smoke-require
      (compiler_typecheck.compiler-typecheck-ok?
        (compiler-typecheck-smoke-module-macro-extension-source))
      "typecheck: module macro identity extension failed")
    (compiler-typecheck-smoke-require
      (compiler_typecheck.compiler-typecheck-error-ok?
        (compiler-typecheck-smoke-module-macro-extension-incompatible-source)
        "typecheck: Module macro output for generated identity :extra(string_3_105_54_52) has incompatible payload")
      "typecheck: module macro identity extension incompatible failed")))

;; Declaration-emitting macros must be able to emit functions with non-trivial
;; bodies. The macro-output serializer round-trips arithmetic,
;; dotted fields, array.make-array, array.ref/set!, let, while,
;; and set! back to
;; declarations; before that surface existed these fixtures failed with
;; "module macro output contains syntax that cannot be parsed as a declaration".
(define (compiler-typecheck-smoke-decls-macro-body-source) : String
  "(import stdlib.array)
(defmacro (int-stack) : Decls
  `(begin
    (defstruct Stack
      (slots (__tl_dyn-array i64))
      (len i64)
      (cap i64))
    (define (stack-new) : Stack
      (Stack (array.make-array i64 4) 0 4))
    (define (stack-grow [s : Stack]) : Stack
      (let
        [new-cap : i64 (* s.cap 2)]
        [bigger : (__tl_dyn-array i64) (array.make-array i64 new-cap)]
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

(define (compiler-typecheck-smoke-module-macro-body-source) : String
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

(define (compiler-typecheck-smoke-module-macro-generated-import-source) : String
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
    (+ (sliceish.len-of v) (psliceish.len-of pv))))")

(define (compiler-typecheck-smoke-type-macro-param-source) : String
  "(import stdlib.array)
(defstruct Pair (value i64))
(defmacro (emit-pair [T : type]) : Decls
  `(begin
    (define (typed-id [v : ,T]) : ,T
      (let [x : ,T v] (ann x : ,T)))
    (define (typed-init) : ,T (init : ,T))
    (define (typed-array [v : ,T]) : (__tl_dyn-array ,T)
      (let [items : (__tl_dyn-array ,T) (array.make-array ,T 1)]
        (begin
          (set! (array-ref items 0) v)
          items)))))
(defmacro (emit-cast [T : type]) : Decls
  `(define (typed-cast [v : i64]) : ,T (cast v : ,T)))
(emit-pair Pair)
(emit-cast i64)
(define (main) : i64
  (let [pair : Pair (typed-id (Pair 41))]
    (+ (typed-cast 1) pair.value)))")

(define (compiler-typecheck-smoke-type-macro-param-tests-ok?) : bool
  (compiler_typecheck.compiler-typecheck-ok?
    (compiler-typecheck-smoke-type-macro-param-source)))

(define (compiler-typecheck-smoke-decls-macro-generated-reuse-source) : String
  "(defmacro (bundle [T : type] [version : String]) : Decls
  `(begin
    (defstruct BundleBox (value ,T))
    (defenum BundleMaybe (BundleNone) (BundleSome ,T))
    (define (bundle-score [value : BundleMaybe]) : i64 1)))
(bundle String \"v1\")
(bundle String \"v1\")
(define (main) : i64 (bundle-score (BundleSome \"x\")))")

(define (compiler-typecheck-smoke-decls-macro-generated-incompatible-source) : String
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

(define (compiler-typecheck-smoke-decls-macro-generated-incompatible-diag-ok?) : bool
  (match (tc_api.typecheck-compiler-source
    (compiler-typecheck-smoke-decls-macro-generated-incompatible-source))
    [(tc_core.ResultCompilerTypecheck.Ok _) false]
    [(tc_core.ResultCompilerTypecheck.Err diag)
      (let
        [value : diagnostic.CompilerDiagnostic
          (diagnostic.compiler-diagnostic-list-first (__tl-box-place diag))]
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

(define (compiler-typecheck-smoke-decls-macro-cross-module-reuse-source) : String
  "(module bundle.family)
(defmacro (bundle [version : String]) : Decls
  `(begin
    (defstruct BundleBox (value String))
    (defenum BundleMaybe (BundleNone) (BundleSome String))))
(bundle \"v1\")
(module app)
(module bundle.family)
(bundle \"v1\")")

(define (compiler-typecheck-smoke-decls-macro-expr-name-key-source) : String
  "(defmacro (box-family [T : type] [box-name : Expr] [ctor-name : Expr]) : Decls
  `(begin
    (defstruct ,box-name (value ,T))
    (define (,ctor-name [value : ,T]) : ,box-name
      (,box-name value))))
(box-family i64 IntBox int-box)
(box-family i64 IntBox int-box)
(define (main) : i64
  (let [boxed : IntBox (int-box 42)] boxed.value))")

(define (compiler-typecheck-smoke-decls-macro-cross-module-distinct-source) : String
  "(module bundle.left)
(defmacro (bundle [version : String]) : Decls
  `(defstruct BundleBox (value String)))
(bundle \"v1\")
(module bundle.right)
(defmacro (bundle [version : String]) : Decls
  `(defstruct BundleBox (value String)))
(bundle \"v1\")")

(define (compiler-typecheck-smoke-decls-macro-generated-tests-ok?) : bool
  (and
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-smoke-decls-macro-generated-reuse-source))
    (compiler-typecheck-smoke-decls-macro-generated-incompatible-diag-ok?)
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-smoke-decls-macro-cross-module-reuse-source))
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-smoke-decls-macro-expr-name-key-source))
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-smoke-decls-macro-cross-module-distinct-source))))

(define (compiler-typecheck-smoke-decl-macro-body-tests-ok?) : bool
  (and
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-smoke-decls-macro-body-source))
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-smoke-module-macro-body-source))
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-smoke-module-macro-generated-import-source))))

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
      (svec.push (&mut roots) root)
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
        stdlib-roots
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
    [roots-a : svec.Vec (compiler-typecheck-smoke-prefix-cache-roots root-a)]
    [roots-b : svec.Vec (compiler-typecheck-smoke-prefix-cache-roots root-b)]
    [ok : bool true]
    (begin
      (load.compiler-load-session-cache-enable!)
      (tc_core.tc-prefix-snapshot-cache-clear!)
      (if (compiler-typecheck-smoke-prefix-cache-check-cfg
        (compiler_typecheck.compiler-typecheck-prefix-cache-source-a)
        entry-a
        (compiler-typecheck-smoke-prefix-cache-root-paths root-a entry-a)
        roots-a
        (parser.compiler-cfg-empty))
        unit
        (set! ok false))
      (tc_core.compiler-typecheck-reset-file-state!)
      (if (compiler-typecheck-smoke-prefix-cache-check-cfg
        (compiler_typecheck.compiler-typecheck-prefix-cache-source-b)
        entry-b
        (compiler-typecheck-smoke-prefix-cache-root-paths root-b entry-b)
        roots-b
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
        (compiler_typecheck.compiler-typecheck-prefix-cache-source-b)
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
    [roots : svec.Vec (compiler-typecheck-smoke-prefix-cache-roots root)]
    [ok : bool true]
    (begin
      (load.compiler-load-session-cache-enable!)
      (tc_core.tc-prefix-snapshot-cache-clear!)
      (if (compiler-typecheck-smoke-prefix-cache-check-cfg
        (compiler-typecheck-smoke-prefix-cache-cfg-source)
        entry-empty
        (compiler-typecheck-smoke-prefix-cache-root-paths root entry-empty)
        roots
        (parser.compiler-cfg-empty))
        unit
        (set! ok false))
      (tc_core.compiler-typecheck-reset-file-state!)
      (if (compiler-typecheck-smoke-prefix-cache-check-cfg
        (compiler-typecheck-smoke-prefix-cache-cfg-source)
        entry-feature
        (compiler-typecheck-smoke-prefix-cache-root-paths root entry-feature)
        roots
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
        stdlib-roots
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
      stdlib-roots
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
        entry
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
        entry-a
        "(import tc_prefix_local_dep as dep)
(define (main) : i64 (dep.value 1))")
      (compiler-typecheck-smoke-write-text
        entry-b
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
            roots
            cfgs)]
        [loaded-b : load.ResultCompilerLoadWithPaths
          (load.compiler-load-file-with-paths-and-roots-cfg
            entry-b
            (sym_i64_env.sym-i64-empty)
            roots
            cfgs)]
        (begin
          (if (compiler-typecheck-smoke-prefix-cache-loaded-check
            loaded-a
            roots
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
        entry-a
        "(import tc_prefix_flat_dep)
(define (main) : i64 (tc_prefix_flat_dep.flat-helper 1))")
      (compiler-typecheck-smoke-write-text
        entry-b
        "(import tc_prefix_flat_dep)
(define (main) : i64 (tc_prefix_flat_dep.flat-helper 2))")
      (load.compiler-load-session-cache-enable!)
      (tc_core.tc-prefix-snapshot-cache-clear!)
      (let
        [loaded-a : load.ResultCompilerLoadWithPaths
          (load.compiler-load-file-with-paths-and-roots-cfg
            entry-a
            (sym_i64_env.sym-i64-empty)
            roots
            cfgs)]
        [loaded-b : load.ResultCompilerLoadWithPaths
          (load.compiler-load-file-with-paths-and-roots-cfg
            entry-b
            (sym_i64_env.sym-i64-empty)
            roots
            cfgs)]
        (begin
          (if (compiler-typecheck-smoke-prefix-cache-loaded-check
            loaded-a
            roots
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
        root-then-named
        "(import tc_4004_root_provider)
(import tc_4004_named_provider)

(define (main) : i64
  (+ (tc_4004_root_provider.root-score) (tc_4004_named_provider.named-score)))")
      (compiler-typecheck-smoke-write-text
        named-then-root
        "(import tc_4004_named_provider)
(import tc_4004_root_provider)

(define (main) : i64
  (+ (tc_4004_root_provider.root-score) (tc_4004_named_provider.named-score)))")
      (tc_api.compiler-typecheck-reset-load-session!)
      (if (compiler-typecheck-smoke-prefix-cache-file-check
        root-then-named
        roots
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
        (ctfe.ctfe-env-empty-with-pools source-pools)
        name-id
        (ctfe.CompilerCtfeValue.Type (ast.AstType.I64)))]
    [installed-type-id : i64
      (ast.ast-node-pool-context-type-push installed-pools (ast.AstType.Bool))]
    [installed-expr-id : i64
      (ast.ast-node-pool-context-expr-push
        installed-pools
        (ast.AstExpr.Literal (ast.AstLiteral.Bool false)))]
    (begin
      (ast.ast-node-pool-context-install! installed-pools)
      (let
        [result-id : i64
          (tc_core.macro-generated-type-param-expr
            source-pools
            env
            (ast.AstExpr.Var name-id))]
        [installed-expr-bases : i64
          (ast.ast-node-pool-context-expr-segment-bases installed-pools)]
        [installed-type-bases : i64
          (ast.ast-node-pool-context-type-segment-bases installed-pools)]
        [ok : bool
          (and
            (= result-id installed-expr-id)
            (= (ast.ast-node-pool-context-expr-len source-pools) 1)
            (= (ast.ast-node-pool-context-type-len source-pools) 1)
            (= (ast.ast-node-pool-context-expr-len installed-pools) 1)
            (= (ast.ast-node-pool-context-type-len installed-pools) 1)
            (match (ast.ast-node-pool-context-expr-get source-pools result-id)
              [(ast.AstExpr.TypeLiteral source-type-id)
                (and
                  (= source-type-id installed-type-id)
                  (match (ast.ast-node-pool-context-type-get
                    source-pools
                    source-type-id)
                    [(ast.AstType.I64) true]
                    [_ false]))]
              [_ false])
            (match (ast.ast-node-pool-context-expr-get
              installed-pools
              installed-expr-id)
              [(ast.AstExpr.Literal (ast.AstLiteral.Bool value)) (not value)]
              [_ false])
            (match (ast.ast-node-pool-context-type-get
              installed-pools
              installed-type-id)
              [(ast.AstType.Bool) true]
              [_ false])
            (=
              (ast.ast-node-pool-active-expr-segment-bases)
              installed-expr-bases)
            (=
              (ast.ast-node-pool-context-type-segment-bases
                (ast.ast-node-pool-context-capture-active))
              installed-type-bases))]
        (begin
          (ast.ast-node-pool-context-install! active-before)
          ok)))))

(define (compiler-typecheck-smoke-generated-import-decl
  [source : String]
  [key : String]) : ast.AstDecl
  (match (parser.parse-ast-source-diagnostic "target/tc_state_entry.tl" source)
    [(parser.ResultAstProgramDiagnostic.Ok (ast.AstProgram.Program decls-box))
      (match (ast.ast-decl-list-step (__tl-box-place decls-box))
        [(ast.AstDeclListStep.Cons decl _)
          (ast.ast-decl-comptime-decl-with-meta
            (tc_core.macro-generated-meta "state-isolation" "import" key)
            decl)]
        [(ast.AstDeclListStep.Nil)
          (io.panic "typecheck: generated import fixture parsed no declaration")])]
    [(parser.ResultAstProgramDiagnostic.Err diag)
      (io.panic (diagnostic.compiler-diagnostic-render (__tl-box-place diag)))]))

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
    (match (tc_core.macro-materialize-generated-import
      state
      generated-import
      entry
      owner-id
      ""
      cbi.compiler-builtin-id-fix-empty
      empty-seen
      roots
      cfgs
      pools)
      [(tc_core.ResultMacroMaterializeImport.Ok _ _ first-seen)
        ;; A second traversal from an independent seen set must reuse A's
        ;; program/surface caches. The selected compatibility session is
        ;; intentionally irrelevant to both traversals.
        (match (tc_core.macro-materialize-generated-import
          state
          generated-import
          entry
          owner-id
          ""
          cbi.compiler-builtin-id-fix-empty
          empty-seen
          roots
          cfgs
          pools)
          [(tc_core.ResultMacroMaterializeImport.Ok _ _ _)
            (match (tc_core.macro-materialize-generated-import
              state
              generated-import
              entry
              owner-id
              ""
              cbi.compiler-builtin-id-fix-empty
              empty-seen
              roots
              cfgs
              pools)
              [(tc_core.ResultMacroMaterializeImport.Ok _ _ _)
                (match (tc_core.macro-materialize-generated-import
                  state
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
                    (CompilerTypecheckGeneratedImportStateSnapshot
                      (diagnostic.compiler-diagnostic-message
                        (__tl-box-place diag))
                      (load.compiler-load-session-state-program-cache-hit-count-value
                        state)
                      (load.compiler-load-session-state-program-cache-miss-count-value
                        state)
                      (load.compiler-load-session-state-program-cache-store-count-value
                        state)
                      (match first-seen
                        [(sym_i64_env.SymI64Nil) false]
                        [_ true])
                      (match (load.compiler-load-session-state-surface-summary-find-module
                        state
                        (ci.intern "tc_state_dep"))
                        [(CompilerLoadSomeSurfaceSummary _) true]
                        [(CompilerLoadNoSurfaceSummary) false]))]
                  [(tc_core.ResultMacroMaterializeImport.Ok _ _ _)
                    (io.panic
                      "typecheck: generated missing import unexpectedly loaded")])]
              [(tc_core.ResultMacroMaterializeImport.Err diag)
                (io.panic
                  (diagnostic.compiler-diagnostic-render (__tl-box-place diag)))])]
          [(tc_core.ResultMacroMaterializeImport.Err diag)
            (io.panic
              (diagnostic.compiler-diagnostic-render (__tl-box-place diag)))])]
      [(tc_core.ResultMacroMaterializeImport.Err diag)
        (io.panic (diagnostic.compiler-diagnostic-render (__tl-box-place diag)))])))

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
      (load.compiler-load-session-state-cache-enable! baseline-state)]
    [_enable-a : unit (load.compiler-load-session-state-cache-enable! state-a)]
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
      (load.compiler-load-session-state-use! baseline-state)]
    [baseline : CompilerTypecheckGeneratedImportStateSnapshot
      (compiler-typecheck-smoke-generated-import-state-run
        baseline-state
        generated-import
        missing-import
        pools)]
    [_select-b : unit (load.compiler-load-session-state-use! state-b)]
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
    [_enable-a : unit (load.compiler-load-session-state-cache-enable! state-a)]
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
    [_select-b : unit (load.compiler-load-session-state-use! state-b)]
    [result : tc_core.ResultCompilerTypecheck
      (match (load.compiler-load-source-with-paths-and-roots-expect-cfg-with-pools
        state-a
        entry
        source
        (sym_i64_env.sym-i64-empty)
        roots
        ast.AstMaybeModuleName.No
        cfgs
        pools)
        [(load.ResultCompilerLoadWithPaths.Ok decls paths modules _)
          (tc_api.typecheck-compiler-program-with-paths-cache-and-load-state-and-prefix-cache-state-and-pools
            state-a
            prefix-cache-a
            job-state-a
            (ast.ast-program decls)
            (ast.ast-decl-path-list-with-modules paths modules)
            roots
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
            state-a
            prefix-cache-a
            job-state-a
            bad-program
            (ast.ast-decl-root-path-cons
              "target/tc_state_controlled_failure.tl"
              (ast.ast-decl-path-list-new))
            roots
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
                  (__tl-box-place diag))))])
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
    [stdlib-root : String (load.compiler-load-join-root-path base "stdlib")]
    [dep : String
      (load.compiler-load-join-root-path stdlib-root "some_name.tl")]
    [entry : String (load.compiler-load-join-root-path base "entry.tl")]
    [roots : svec.Vec
      (let
        [items : svec.Vec (svec.new)]
        (begin
          (svec.push (&mut items) stdlib-root)
          items))]
    [cfgs : sym_i64_env.SymI64Env (parser.compiler-cfg-empty)]
    (begin
      (load.compiler-load-test-mkdir base)
      (load.compiler-load-test-mkdir stdlib-root)
      (compiler-typecheck-smoke-write-text dep "(define value : i64 42)")
      (compiler-typecheck-smoke-write-text
        entry
        "(import stdlib.some_name)
(define (main) : i64 some_name.value)")
      (tc_api.compiler-typecheck-reset-load-session!)
      (compiler-typecheck-smoke-prefix-cache-file-check entry roots cfgs))))

(define (compiler-typecheck-smoke-specialized-import-path-ok?) : bool
  (let
    [dir : String "target/tc_specialized_import_path"]
    [dep : String (load.compiler-load-join-root-path dir "dep.tl")]
    [entry : String (load.compiler-load-join-root-path dir "entry.tl")]
    [roots : svec.Vec (svec.new)]
    [cfgs : sym_i64_env.SymI64Env (parser.compiler-cfg-empty)]
    (begin
      (load.compiler-load-test-mkdir dir)
      (compiler-typecheck-smoke-write-text dep "(define imported : i64 true)")
      (compiler-typecheck-smoke-write-text
        entry
        "(define (id [comptime T : type] [value : T]) : T value)
(import dep)
(define (main) : i64 0)")
      (match (load.compiler-load-file-with-paths-and-roots-cfg
        entry
        (sym_i64_env.sym-i64-empty)
        roots
        cfgs)
        [(load.ResultCompilerLoadWithPaths.Ok decls paths _ _)
          (match (tc_api.typecheck-compiler-program-with-paths-cache
            (ast.ast-program decls)
            paths
            roots
            (tc_api.compiler-typecheck-prefix-cache-scope
              "typecheck-specialized-import-path-smoke"
              roots
              cfgs))
            [(tc_core.ResultCompilerTypecheck.Err diag)
              (and
                (string.eq
                  (diagnostic.compiler-diagnostic-path
                    (diagnostic.compiler-diagnostic-list-first
                      (__tl-box-place diag)))
                  dep)
                (string.eq
                  (diagnostic.compiler-diagnostic-message
                    (diagnostic.compiler-diagnostic-list-first
                      (__tl-box-place diag)))
                  "typecheck: value definition type mismatch: expected i64, found bool"))]
            [(tc_core.ResultCompilerTypecheck.Ok _) false])]
        [(load.ResultCompilerLoadWithPaths.Err _) false]))))

(define (compiler-typecheck-smoke-macro-dependency-helper-source) : String
  "(module tc_macro_context_helper)
(define (bump [value : i64]) : i64 (+ value 1))")

(define (compiler-typecheck-smoke-macro-dependency-provider-source) : String
  "(module tc_macro_context_provider)
(import tc_macro_context_helper as helper)
(defmacro (bumped [value : i64]) : i64
  `(helper.bump ,value))")

(define (compiler-typecheck-smoke-macro-dependency-entry-source) : String
  "(import tc_macro_context_provider as provider)
(define (main) : i64 (provider.bumped 41))")

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
        (compiler-typecheck-smoke-macro-dependency-helper-source))
      (compiler-typecheck-smoke-write-text
        provider
        (compiler-typecheck-smoke-macro-dependency-provider-source))
      (compiler-typecheck-smoke-write-text
        entry
        (compiler-typecheck-smoke-macro-dependency-entry-source))
      (tc_api.compiler-typecheck-reset-load-session!)
      (compiler-typecheck-smoke-prefix-cache-file-check entry roots cfgs))))

(define (compiler-typecheck-smoke-surface-macro-provider-source) : String
  "(module tc_surface_macro_provider)
(defmacro (hook) : Expr `42)
(define value : i64 1)")

(define (compiler-typecheck-smoke-surface-macro-entry-source) : String
  "(import tc_surface_macro_provider as provider)
(define (main) : i64 0)")

(define (compiler-typecheck-smoke-surface-macro-summary-ok?) : bool
  (let
    [provider : String "target/tc_surface_macro_provider.tl"]
    [entry : String "target/tc_surface_macro_entry.tl"]
    [roots : svec.Vec (svec.new)]
    [cfgs : sym_i64_env.SymI64Env (parser.compiler-cfg-empty)]
    (begin
      (compiler-typecheck-smoke-write-text
        provider
        (compiler-typecheck-smoke-surface-macro-provider-source))
      (compiler-typecheck-smoke-write-text
        entry
        (compiler-typecheck-smoke-surface-macro-entry-source))
      (tc_api.compiler-typecheck-reset-load-session!)
      (match (load.compiler-load-file-with-paths-and-roots-cfg
        entry
        (sym_i64_env.sym-i64-empty)
        roots
        cfgs)
        [(load.ResultCompilerLoadWithPaths.Ok _ _ _ _)
          (begin
            (ctfe.ctfe-module-macro-export-reset!)
            (let
              [names : tc_core.TcNameIdList
                (tc_core.macro-collect-surface-summary-macro-names
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
              [before-reset : bool
                (and
                  (tc_core.tc-name-id-list-contains names hook-id)
                  (tc_core.macro-surface-macro-in-module? provider-id hook-id)
                  (not
                    (tc_core.macro-surface-macro-in-module?
                      provider-id
                      missing-id))
                  (tc_core.macro-surface-module-has-macro? provider-id)
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
                    provider-id
                    hook-id)
                    [(tc_core.MacroMaybeDecl.Some _ _ _ _ _ _) true]
                    [(tc_core.MacroMaybeDecl.No) false])
                  (match (tc_core.macro-surface-call-decl-in-module
                    generated-provider-id
                    generated-hook-id)
                    [(tc_core.MacroMaybeDecl.Some _ _ _ _ _ _) false]
                    [(tc_core.MacroMaybeDecl.No) true])
                  (ctfe.ctfe-module-macro-export-id? provider-id hook-id)
                  (not
                    (ctfe.ctfe-module-macro-export-id? provider-id non-macro-id)))]
              (begin
                (load.compiler-load-surface-summaries-reset!)
                (tc_core.macro-surface-call-decl-cache-reset!)
                (and
                  before-reset
                  (not
                    (tc_core.macro-surface-macro-in-module? provider-id hook-id))
                  (not (tc_core.macro-surface-module-has-macro? provider-id))
                  (match (tc_core.macro-surface-call-decl-in-module
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
    (match (parser.parse-ast-source-diagnostic path source)
      [(parser.ResultAstProgramDiagnostic.Ok program)
        (match (load.compiler-load-surface-summary-build
          path
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

(define (compiler-typecheck-smoke-lazy-summary-macro-unused-source) : String
  "(module tc.lazy.summary.macro.provider)
(define summary-stub : i64 0)
(module tc.lazy.summary.macro.entry)
(import tc.lazy.summary.macro.provider as provider)
(define (main) : i64 0)")

(define (compiler-typecheck-smoke-lazy-summary-macro-call-source) : String
  "(module tc.lazy.summary.macro.provider)
(define summary-stub : i64 0)
(module tc.lazy.summary.macro.entry)
(import tc.lazy.summary.macro.provider as provider)
(define (main) : i64 (provider.hook 41))")

(define (compiler-typecheck-smoke-lazy-summary-macro-hook-source) : String
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
(define (main) : i64 (gen.answer))")

(define (compiler-typecheck-smoke-lazy-summary-macro-comptime-provider-source) : String
  "(module tc.lazy.summary.macro.comptime_provider)
(import stdlib.comptime)
(defmacro (capture [value : comptime.Expr]) : comptime.Expr `(+ ,value 1))
(define value : i64 1)")

(define (compiler-typecheck-smoke-lazy-summary-macro-comptime-source) : String
  "(module tc.lazy.summary.macro.comptime_provider)
(define summary-stub : i64 0)
(module tc.lazy.summary.macro.entry)
(import tc.lazy.summary.macro.comptime_provider as provider)
(define (main) : i64 (provider.capture 41))")

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
                    (> (tc_core.tc-lazy-import-summary-backed-stub-count) 0)
                    (if (= expected-forces 0)
                      (= (tc_core.tc-lazy-import-summary-macro-force-count) 0)
                      (> (tc_core.tc-lazy-import-summary-macro-force-count) 0))))]
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
    (compiler-typecheck-smoke-lazy-summary-macro-unused-source)
    0))

(define (compiler-typecheck-smoke-lazy-summary-macro-call-ok?) : bool
  (compiler-typecheck-smoke-lazy-summary-macro-check
    (compiler-typecheck-smoke-lazy-summary-macro-provider-source)
    (compiler-typecheck-smoke-lazy-summary-macro-call-source)
    1))

(define (compiler-typecheck-smoke-lazy-summary-macro-hook-ok?) : bool
  (compiler-typecheck-smoke-lazy-summary-macro-check
    (compiler-typecheck-smoke-lazy-summary-macro-provider-source)
    (compiler-typecheck-smoke-lazy-summary-macro-hook-source)
    1))

(define (compiler-typecheck-smoke-lazy-summary-macro-comptime-ok?) : bool
  (compiler-typecheck-smoke-lazy-summary-macro-check
    (compiler-typecheck-smoke-lazy-summary-macro-comptime-provider-source)
    (compiler-typecheck-smoke-lazy-summary-macro-comptime-source)
    1))

(define (compiler-typecheck-smoke-nested-dotted-nominal-source) : String
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
    value.value))")

(define (compiler-typecheck-smoke-nested-dotted-nominal-ok?) : bool
  (compiler_typecheck.compiler-typecheck-ok?
    (compiler-typecheck-smoke-nested-dotted-nominal-source)))

(define (compiler-typecheck-smoke-qualified-array-source) : String
  "(import stdlib.array)
(define (take-array-ref [r : (& items i64)]) : i64 1)
(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (array.make-array i64 1)]
    [fixed : (Array i64 2) (array 3 4)]
    (begin
      (set! (array-ref items 0) (array-ref fixed 1))
      (let
        [borrow-score : i64
          (let
            [borrowed : (& items i64) (& (array-ref items 0))]
            (take-array-ref borrowed))]
        (begin
          (array-push! items 9)
          (+ borrow-score (+ (array-length items) (array-ref items 0))))))))")

(define (compiler-typecheck-smoke-qualified-array-ok?) : bool
  (compiler_typecheck.compiler-typecheck-ok?
    (compiler-typecheck-smoke-qualified-array-source)))

(test
  compiler-typecheck-qualified-array-borrow
  (if (compiler-typecheck-smoke-qualified-array-ok?)
    unit
    (io.panic "typecheck: qualified array borrow smoke failed")))

(define (compiler-typecheck-smoke-lazy-import-explicit-alias-source) : String
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

(define (compiler-typecheck-smoke-lazy-import-full-path-source) : String
  "(module helper.module)
(define value : i64 41)
(module full.entry)
(import helper.module)
(define (full-score) : i64 helper.module.value)")

(define (compiler-typecheck-smoke-expr-list-parsed-id
  [exprs : (& exprs ast.AstExprList)]
  [name : String]) : i64
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
  [name : String]) : i64
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
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
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
                        (compiler-typecheck-smoke-expr-parsed-id value name))]
                    [(ast.AstDecl.DefFn decl-meta name-id _ _ body _)
                      (if (string.eq
                        (tc_core.tc-env-key-name-text name-id)
                        name)
                        name-id
                        (compiler-typecheck-smoke-expr-parsed-id body name))]
                    [(ast.AstDecl.DefMacro decl-meta name-id _ _ body)
                      (if (string.eq
                        (tc_core.tc-env-key-name-text name-id)
                        name)
                        name-id
                        (compiler-typecheck-smoke-expr-parsed-id body name))]
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
        name)]
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
              (tc_core.tc-source-dotted-alias-key-cache-get module-id name-id)
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
              (tc_core.tc-source-dotted-full-path-key-cache-get
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
        (compiler-typecheck-smoke-lazy-import-full-path-source))
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
      (tc_core.tc-source-dotted-full-path-key-cache-put!
        module-id
        name-id
        lookup-id)
      (let
        [before : i64
          (tc_core.tc-source-dotted-full-path-key-cache-get module-id name-id)]
        (begin
          (tc_core.macro-alias-derived-cache-reset!)
          (and
            (= before lookup-id)
            (=
              (tc_core.tc-source-dotted-full-path-key-cache-get
                module-id
                name-id)
              -2)))))))

(define (compiler-typecheck-smoke-source-name-caches-intern-reset-ok?) : bool
  (begin
    (tc_core.tc-source-dotted-alias-key-cache-reset!)
    (tc_core.tc-source-dotted-full-path-key-cache-reset!)
    (tc_core.tc-source-qualified-variant-key-cache-reset!)
    (let
      [registry-id : i64
        (compiler_symbols.compiler-registries-identity
          (compiler_symbols.compiler-registries-empty))]
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
      [_old-result-identity : unit
        (tc_core.macro-stdlib-result-identity-ensure!)]
      [old-result-ids-current : bool
        (and
          (= tc_core.macro-stdlib-result-identity-table-id old-table-id)
          (= tc_core.macro-stdlib-result-identity-generation old-generation)
          (= tc_core.macro-stdlib-result-module-id old-result-module-id)
          (= tc_core.macro-stdlib-result-macro-id old-result-name-id))]
      (begin
        (tc_core.tc-source-dotted-alias-key-cache-put!
          old-module-id
          old-alias-name-id
          old-alias-value-id)
        (tc_core.tc-source-dotted-full-path-key-cache-put!
          old-module-id
          old-full-name-id
          old-full-value-id)
        (tc_core.tc-source-qualified-variant-key-cache-put!
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
          [_result-identity : unit
            (tc_core.macro-stdlib-result-identity-ensure!)]
          [alias-miss : i64
            (tc_core.tc-source-dotted-alias-key-cache-get
              module-id
              alias-name-id)]
          [full-miss : i64
            (tc_core.tc-source-dotted-full-path-key-cache-get
              module-id
              full-name-id)]
          [variant-miss : i64
            (tc_core.tc-source-qualified-variant-key-cache-get
              registry-id
              module-id
              variant-name-id)]
          (begin
            (tc_core.compiler-typecheck-reset-file-state!)
            (and
              old-result-ids-current
              (= (ci.intern-active-table-id) old-table-id)
              (> (ci.intern-generation) old-generation)
              (= tc_core.macro-stdlib-result-identity-table-id old-table-id)
              (=
                tc_core.macro-stdlib-result-identity-generation
                (ci.intern-generation))
              (= tc_core.macro-stdlib-result-module-id result-module-id)
              (= tc_core.macro-stdlib-result-macro-id result-name-id)
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
        state-a
        table-a
        generation-a
        module-id
        name-id
        41)
      (tc_core.tc-source-dotted-alias-key-cache-put-for-state!
        state-b
        table-b
        generation-b
        module-id
        name-id
        42)
      (tc_core.tc-source-dotted-full-path-key-cache-put-for-state!
        state-b
        table-b
        generation-b
        module-id
        name-id
        43)
      (tc_core.tc-source-qualified-variant-key-cache-put-for-state!
        state-b
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
                state-a
                table-a
                generation-a
                module-id
                name-id)
              41)
            (=
              (tc_core.tc-source-dotted-alias-key-cache-get-for-state
                state-b
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
                    state-b
                    table-b
                    generation-b
                    module-id
                    name-id)
                  42)
                (=
                  (tc_core.tc-source-dotted-full-path-key-cache-get-for-state
                    state-b
                    table-b
                    generation-b
                    module-id
                    name-id)
                  43)
                (=
                  (tc_core.tc-source-qualified-variant-key-cache-get-for-state
                    state-b
                    table-b
                    generation-b
                    registry-b
                    module-id
                    name-id)
                  44)
                (=
                  (tc_core.tc-source-qualified-variant-handle-cache-get-for-state
                    state-b
                    table-b
                    generation-b
                    registry-b
                    module-id
                    name-id)
                  45))]
            [wrong-owner-miss : bool
              (=
                (tc_core.tc-source-dotted-alias-key-cache-get-for-state
                  state-b
                  table-a
                  generation-b
                  module-id
                  name-id)
                -2)]
            (begin
              (tc_core.tc-source-dotted-full-path-key-cache-put-for-state!
                state-b
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

(define (compiler-typecheck-smoke-qualified-enum-variant-precedence-source) : String
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
     (provider-score (provider.Choice.Full 7))))")

(define (compiler-typecheck-smoke-qualified-enum-variant-precedence-ok?) : bool
  (compiler_typecheck.compiler-typecheck-ok?
    (compiler-typecheck-smoke-qualified-enum-variant-precedence-source)))

(test
  compiler-typecheck-qualified-enum-variant-precedence
  (if (compiler-typecheck-smoke-qualified-enum-variant-precedence-ok?)
    unit
    (io.panic "typecheck: qualified enum variant precedence smoke failed")))

;; Dotted variants and bare module-local constructors share the same direct
;; cache storage but are distinct key domains. A dotted name misclassified as
;; bare can cache a false constructor miss that poisons later variant lookup.
(define (compiler-typecheck-smoke-dotted-constructor-cache-domain-ok?) : bool
  (let
    [bare-id : i64 (ci.intern "Full")]
    [dotted-id : i64 (ci.intern "Choice.Full")]
    [qualified-id : i64 (ci.intern "provider/Full")]
    (and
      (tc_core.tc-constructor-non-root-bare-name-id? "entry" bare-id)
      (not (tc_core.tc-constructor-non-root-bare-name-id? "entry" dotted-id))
      (not (tc_core.tc-constructor-non-root-bare-name-id? "entry" qualified-id))
      (not (tc_core.tc-constructor-non-root-bare-name-id? "" bare-id)))))

(test
  compiler-typecheck-dotted-constructor-cache-domain
  (if (compiler-typecheck-smoke-dotted-constructor-cache-domain-ok?)
    unit
    (io.panic "typecheck: dotted constructor cache domain smoke failed")))

(define (compiler-typecheck-smoke-lazy-import-stdlib-summary-source) : String
  "(module main)
(import stdlib.vector as vec)
(define (main) : i64 0)")

(define (compiler-typecheck-smoke-lazy-import-stdlib-array-source) : String
  "(module main)
(import stdlib.array)
(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (stdlib.array.make-array i64 0)]
    (begin
      (stdlib.array.push! items 41)
      (+ (stdlib.array.ref items 0) (stdlib.array.length items)))))")

(define (compiler-typecheck-smoke-lazy-import-stdlib-array-alias-source) : String
  "(module main)
(import stdlib.array)
(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (array.make-array i64 0)]
    (begin
      (array.push! items 41)
      (+ (array.ref items 0) (array.length items)))))")

(define (compiler-typecheck-smoke-lazy-import-stdlib-result-source) : String
  "(module main)
(import stdlib.result)
(import (result.result i64 String) as result_i64_string)
(define (main) : i64 42)")

(define (compiler-typecheck-smoke-unused-result-import-local-type-source) : String
  "(module main)
(import stdlib.result)

(defstruct LocalError
  (message String))

(import (result.result i64 LocalError) as local_result_unused)

(define (main) : i64 42)")

(define (compiler-typecheck-smoke-result-enum-then-helper-source) : String
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

(define (compiler-typecheck-smoke-generic-catalog-qualified-macro-source) : String
  "(defmacro (catalog) : Module
  `(begin
    (module generated.generic_macro_catalog)
    (defmacro (one) : i64 `1)
    (define (helper) : i64 42)))
(import (catalog) as api)
(define (main) : i64 (api.one))")

(define (compiler-typecheck-smoke-generic-catalog-direct-macro-source) : String
  "(defmacro (catalog) : Module
  `(begin
    (module generated.generic_macro_catalog)
    (defmacro (one) : i64 `1)
    (define (helper) : i64 42)))
(import (catalog))
(define (main) : i64 (one))")

(define (compiler-typecheck-smoke-generic-catalog-invalid-source) : String
  "(defmacro (invalid-catalog) : Module
  `(begin
    (module generated.invalid_catalog)
    (defenum Choice (Empty) (Full i64))
    (define broken : i64 true)))
(import (invalid-catalog) as unused-api)
(define (main) : i64 0)")

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
                  (match (tc_core.macro-find-module-body-decls
                    (__tl-box-place decls-box)
                    module-name)
                    [(tc_core.MacroMaybeDeclList.Some body)
                      (compiler-typecheck-smoke-generated-catalog-body-has-name?
                        body
                        name)]
                    [(tc_core.MacroMaybeDeclList.No) false])])]
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
                    (__tl-box-place decls-box)
                    module-name)])]
            [(tc_core.ResultMacroExpand.Err _) false])]
        [(parser.ResultAstProgramDiagnostic.Err _) false])]
    (begin
      (tc_core.compiler-typecheck-reset-file-state!)
      ok)))

(define (compiler-typecheck-smoke-generic-catalog-ok?) : bool
  (begin
    (compiler-typecheck-smoke-require
      (compiler_typecheck.compiler-typecheck-ok?
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
      (compiler_typecheck.compiler-typecheck-ok?
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
      (compiler_typecheck.compiler-typecheck-ok?
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
      (compiler_typecheck.compiler-typecheck-ok?
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
      (compiler_typecheck.compiler-typecheck-ok?
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
      (compiler_typecheck.compiler-typecheck-ok?
        (compiler-typecheck-smoke-generic-catalog-unused-source))
      "generic catalog unused typecheck")
    (compiler-typecheck-smoke-require
      (not
        (compiler-typecheck-smoke-generic-catalog-expanded-module?
          (compiler-typecheck-smoke-generic-catalog-unused-source)
          "generated.generic_catalog"))
      "generic catalog unused materialized module")
    (compiler-typecheck-smoke-require
      (compiler_typecheck.compiler-typecheck-ok?
        (compiler-typecheck-smoke-generic-catalog-shadowed-alias-source))
      "generic catalog shadowed alias typecheck")
    (compiler-typecheck-smoke-require
      (not
        (compiler-typecheck-smoke-generic-catalog-expanded-module?
          (compiler-typecheck-smoke-generic-catalog-shadowed-alias-source)
          "generated.generic_catalog_shadow"))
      "generic catalog shadowed alias materialized module")
    (compiler-typecheck-smoke-require
      (compiler_typecheck.compiler-typecheck-ok?
        (compiler-typecheck-smoke-generic-catalog-full-source))
      "generic catalog full typecheck")
    (compiler-typecheck-smoke-require
      (compiler-typecheck-smoke-generic-catalog-expanded-name?
        (compiler-typecheck-smoke-generic-catalog-full-source)
        "generated.generic_catalog"
        "score")
      "generic catalog full missing score")
    (compiler-typecheck-smoke-require
      (compiler_typecheck.compiler-typecheck-ok?
        (compiler-typecheck-smoke-generic-catalog-unqualified-source))
      "generic catalog unqualified typecheck")
    (compiler-typecheck-smoke-require
      (compiler-typecheck-smoke-generic-catalog-expanded-name?
        (compiler-typecheck-smoke-generic-catalog-unqualified-source)
        "generated.generic_catalog"
        "score")
      "generic catalog unqualified missing score")
    (compiler-typecheck-smoke-require
      (compiler_typecheck.compiler-typecheck-ok?
        (compiler-typecheck-smoke-generic-catalog-qualified-macro-source))
      "generic catalog qualified macro typecheck")
    (compiler-typecheck-smoke-require
      (compiler_typecheck.compiler-typecheck-ok?
        (compiler-typecheck-smoke-generic-catalog-direct-macro-source))
      "generic catalog direct macro typecheck")
    (compiler-typecheck-smoke-require
      (compiler_typecheck.compiler-typecheck-error-ok?
        (compiler-typecheck-smoke-generic-catalog-invalid-source)
        "typecheck: value definition type mismatch: expected i64, found bool")
      "generic catalog invalid helper accepted or changed diagnostic")
    (compiler-typecheck-smoke-require
      (compiler_typecheck.compiler-typecheck-error-ok?
        (compiler-typecheck-smoke-result-catalog-invalid-source)
        "typecheck: value definition type mismatch: expected i64, found bool")
      "Result-spelled catalog invalid helper accepted or changed diagnostic")
    true))

(define (compiler-typecheck-smoke-lazy-import-str-cat-source) : String
  "(module main)
(import stdlib.str_cat)
(define (main) : String
  (str_cat.str-cat \"a\" \"b\" \"c\" \"d\" \"e\"))")

(define (compiler-typecheck-smoke-runtime-str-cat-two-nested-source) : String
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

(define (compiler-typecheck-smoke-lazy-import-explicit-alias-no-fanout-ok?) : bool
  (let
    [ok : bool
      (match (parser.parse-ast-source-diagnostic
        ""
        (compiler-typecheck-smoke-lazy-import-explicit-alias-source))
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
                  (= (tc_core.tc-lazy-import-stub-count) 1)
                  (= (tc_core.tc-lazy-import-summary-backed-stub-count) 1)
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
                  (match (tc_core.tc-lookup-dotted-source-visible
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
                  (match (tc_core.tc-lookup-dotted-source-visible
                    entry-ctx
                    env
                    "helper.get"
                    (compiler-typecheck-smoke-required-parsed-id
                      entry-ctx
                      "typecheck smoke: missing helper.get id: "
                      "helper.get"))
                    [(tc_core.ResultTcType.Ok _) true]
                    [(tc_core.ResultTcType.Err _) false])
                  (match (tc_core.tc-lookup-dotted-source-visible
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
                        (match (tc_core.tc-lookup-dotted-source-visible
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
        (compiler-typecheck-smoke-lazy-import-stdlib-summary-source))
        [(load.ResultCompilerLoadWithPaths.Ok decls paths _ _)
          (match (tc_api.typecheck-compiler-program-with-paths-checked
            (ast.ast-program decls)
            paths)
            [(tc_core.ResultCompilerTypecheckChecked.Ok _ _ env _)
              (and
                (> (tc_core.tc-lazy-import-summary-backed-stub-count) 0)
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

(define (compiler-typecheck-smoke-lazy-import-stdlib-array-macro-ok?) : bool
  (let
    [ok : bool
      (begin
        (load.compiler-load-test-mkdir "target/tc_lazy_stdlib_array")
        (compiler-typecheck-smoke-write-text
          "target/tc_lazy_stdlib_array/canonical.tl"
          (compiler-typecheck-smoke-lazy-import-stdlib-array-source))
        (match (load.compiler-load-file-with-paths
          "target/tc_lazy_stdlib_array/canonical.tl"
          (sym_i64_env.sym-i64-empty))
          [(load.ResultCompilerLoadWithPaths.Ok decls paths _ _)
            (let
              [array-materialized : bool
                (compiler-typecheck-smoke-paths-contain?
                  paths
                  "stdlib/array.tl")]
              (match (tc_api.typecheck-compiler-program-with-paths-checked
                (ast.ast-program decls)
                paths)
                [(tc_core.ResultCompilerTypecheckChecked.Ok _ _ _ _)
                  (if array-materialized
                    (io.panic
                      "typecheck: lazy import stdlib.array materialized")
                    true)]
                [(tc_core.ResultCompilerTypecheckChecked.Partial _ _ _ _) false]
                [(tc_core.ResultCompilerTypecheckChecked.Err diag)
                  (let
                    [message : String
                      (diagnostic.compiler-diagnostic-message
                        (diagnostic.compiler-diagnostic-list-first
                          (__tl-box-place diag)))]
                    (begin
                      (io.stderr-write (byte_buf.str-as-bytes (& message)))
                      (io.panic
                        "typecheck: lazy import stdlib.array nested typecheck failed")))]))]
          [(load.ResultCompilerLoadWithPaths.Err _)
            (io.panic "typecheck: lazy import stdlib.array load failed")]))]
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
          (compiler-typecheck-smoke-lazy-import-stdlib-result-source))
        (match (load.compiler-load-file-with-paths
          "target/tc_lazy_stdlib_result/result.tl"
          (sym_i64_env.sym-i64-empty))
          [(load.ResultCompilerLoadWithPaths.Ok decls paths _ _)
            (let
              [skip-count : i64 (load.compiler-load-lazy-import-skip-count)]
              [result-materialized : bool
                (compiler-typecheck-smoke-paths-contain?
                  paths
                  "stdlib/result.tl")]
              (match (tc_api.typecheck-compiler-program-with-paths-checked
                (ast.ast-program decls)
                paths)
                [(tc_core.ResultCompilerTypecheckChecked.Ok _ _ _ _)
                  (and (= skip-count 0) result-materialized)]
                [(tc_core.ResultCompilerTypecheckChecked.Partial _ _ _ _) false]
                [(tc_core.ResultCompilerTypecheckChecked.Err diag)
                  (let
                    [message : String
                      (diagnostic.compiler-diagnostic-message
                        (diagnostic.compiler-diagnostic-list-first
                          (__tl-box-place diag)))]
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
          (compiler-typecheck-smoke-unused-result-import-local-type-source))
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
                  [message : String
                    (diagnostic.compiler-diagnostic-message
                      (diagnostic.compiler-diagnostic-list-first
                        (__tl-box-place diag)))]
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
          (compiler-typecheck-smoke-result-enum-then-helper-source))
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
                  [message : String
                    (diagnostic.compiler-diagnostic-message
                      (diagnostic.compiler-diagnostic-list-first
                        (__tl-box-place diag)))]
                  (begin
                    (io.stderr-write (byte_buf.str-as-bytes (& message)))
                    false))])]
          [(load.ResultCompilerLoadWithPaths.Err _) false]))]
    (begin
      (tc_core.compiler-typecheck-reset-file-state!)
      (load.compiler-load-surface-summaries-reset!)
      ok)))

(define (compiler-typecheck-smoke-lazy-import-stdlib-array-alias-ok?) : bool
  (let
    [ok : bool
      (begin
        (load.compiler-load-test-mkdir "target/tc_lazy_stdlib_array")
        (compiler-typecheck-smoke-write-text
          "target/tc_lazy_stdlib_array/alias.tl"
          (compiler-typecheck-smoke-lazy-import-stdlib-array-alias-source))
        (match (load.compiler-load-file-with-paths
          "target/tc_lazy_stdlib_array/alias.tl"
          (sym_i64_env.sym-i64-empty))
          [(load.ResultCompilerLoadWithPaths.Ok decls paths _ _)
            (let
              [skip-count : i64 (load.compiler-load-lazy-import-skip-count)]
              (match (tc_api.typecheck-compiler-program-with-paths-checked
                (ast.ast-program decls)
                paths)
                [(tc_core.ResultCompilerTypecheckChecked.Ok _ _ _ _)
                  (= skip-count 0)]
                [(tc_core.ResultCompilerTypecheckChecked.Partial _ _ _ _) false]
                [(tc_core.ResultCompilerTypecheckChecked.Err _) false]))]
          [(load.ResultCompilerLoadWithPaths.Err _) false]))]
    (begin
      (tc_core.compiler-typecheck-reset-file-state!)
      (load.compiler-load-surface-summaries-reset!)
      ok)))

(define (compiler-typecheck-smoke-lazy-import-str-cat-macro-ok?) : bool
  (let
    [ok : bool
      (match (tc_api.typecheck-compiler-source-load
        (compiler-typecheck-smoke-lazy-import-str-cat-source))
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
        (compiler-typecheck-smoke-runtime-str-cat-two-nested-source))
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
          (ast.ast-decl-root-path-cons path (ast.ast-decl-path-list-new))))
        [(tc_core.ResultCompilerTypecheck.Err diag)
          (let
            [value : diagnostic.CompilerDiagnostic
              (diagnostic.compiler-diagnostic-list-first (__tl-box-place diag))]
            (and
              (string.eq (diagnostic.compiler-diagnostic-message value) message)
              (string.eq (diagnostic.compiler-diagnostic-path value) path)
              (= (diagnostic.compiler-diagnostic-line value) 4)
              (= (diagnostic.compiler-diagnostic-col value) 3)))]
        [(tc_core.ResultCompilerTypecheck.Ok _) false])]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-typecheck-scoped-marker-queries-ok?) : bool
  (let
    [was-active : bool (tc_core.tc-type-env-scoped-runtime-active?)]
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
        (tc_core.tc-bind-cleanup-owner tail-value-env tail-resource-id)
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
        (tc_core.tc-bind-cleanup-owner base-env resource-id)
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
      (tc_core.tc-type-env-scoped-runtime-save)]
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
            (not (tc_core.tc-type-env-scoped-runtime-active?))
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
            (not (tc_core.tc-type-env-scoped-runtime-active?))))))))

(define (compiler-typecheck-smoke-hygiene-structural-ids-ok?) : bool
  (let
    [source-id : i64 17]
    [module-id : i64 23]
    [declaration-id : i64 42]
    [legacy-id : i64 (tc_core.macro-hygiene-global-id module-id source-id true)]
    [context-id : i64
      (tc_core.macro-hygiene-global-id module-id source-id false)]
    [root-context-id : i64
      (tc_core.macro-hygiene-global-id
        (compiler_symbols.compiler-symbol-root-module-id)
        source-id
        false)]
    [direct-local-id : i64
      (tc_core.macro-hygiene-local-id
        (tc_core.MacroHygieneContext
          source-id
          (compiler_symbols.compiler-symbol-root-module-id)
          declaration-id
          (compiler_symbols.compiler-symbols-empty))
        3
        source-id)]
    [surface-local-id : i64
      (tc_core.macro-hygiene-local-id
        (tc_core.MacroHygieneContext
          source-id
          (compiler_symbols.compiler-symbol-root-module-id)
          -1
          (compiler_symbols.compiler-symbols-empty))
        3
        source-id)]
    [other-macro-local-id : i64
      (tc_core.macro-hygiene-local-id
        (tc_core.MacroHygieneContext
          (+ source-id 1)
          (compiler_symbols.compiler-symbol-root-module-id)
          declaration-id
          (compiler_symbols.compiler-symbols-empty))
        3
        source-id)]
    (and
      (tc_core.macro-hygiene-global-legacy-id? legacy-id)
      (= (tc_core.macro-hygiene-global-module-id legacy-id) module-id)
      (= (tc_core.macro-hygiene-global-module-id context-id) module-id)
      (not (tc_core.macro-hygiene-global-legacy-id? root-context-id))
      (=
        (tc_core.macro-hygiene-global-module-id root-context-id)
        (compiler_symbols.compiler-symbol-root-module-id))
      (=
        (tc_core.macro-hygiene-structural-source-name-id root-context-id)
        source-id)
      (tc_core.macro-hygiene-local-id? direct-local-id)
      (tc_core.macro-hygiene-local-id? surface-local-id)
      ;; The hygienic-local namespace belongs to the macro, not to the route
      ;; that resolved it: a dense symbol declaration id and the surface
      ;; fallback must rename the same local to the same id. Two different
      ;; macros still get two namespaces.
      (= direct-local-id surface-local-id)
      (not (= direct-local-id other-macro-local-id)))))

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
                (tc_core.macro-expand-program-structurally-changed?)
                (not (tc_core.macro-expand-program-structurally-changed?)))]
            [(tc_core.ResultMacroExpand.Err _) false])]
        [(parser.ResultAstProgramDiagnostic.Err _) false])]
    (begin
      (tc_core.compiler-typecheck-reset-file-state!)
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

(define (compiler-typecheck-core-and-body-source) : String
  "(module stdlib.core_macros)
(defmacro (and [_args : bool ...]) : bool
  (expr-var \"core-and-body-observed\"))
(module main)
(define (main) : bool (and true))")

(define (compiler-typecheck-core-or-body-source) : String
  "(module stdlib.core_macros)
(defmacro (or [_args : bool ...]) : bool
  (expr-var \"core-or-body-observed\"))
(module main)
(define (main) : bool (or false))")

(define (compiler-typecheck-core-cond-body-source) : String
  "(module stdlib.core_macros)
(defmacro (cond [_arms : ExprClause ...]) : Expr
  (expr-var \"core-cond-body-observed\"))
(module main)
(define (main) : i64 (cond [else 42]))")

(define (compiler-typecheck-core-macro-bodies-observed?) : bool
  (and
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-core-and-body-source)
      "typecheck: unbound name core-and-body-observed")
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-core-or-body-source)
      "typecheck: unbound name core-or-body-observed")
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-core-cond-body-source)
      "typecheck: unbound name core-cond-body-observed")))

(test
  compiler-typecheck-core-macro-bodies
  (unless
    (compiler-typecheck-core-macro-bodies-observed?)
    (io.panic "typecheck: stdlib core macro body was bypassed")))

(test
  compiler-typecheck-call-diagnostics
  (unless
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-call-argument-diagnostic-source)
      "typecheck: call `takes-two` argument 1 (parameter `count`) type mismatch: expected i64, found bool")
    (io.panic "typecheck: named call diagnostic inline test failed"))
  (unless
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-lambda-argument-diagnostic-source)
      "typecheck: call `lambda` argument 1 (parameter `item`) type mismatch: expected i64, found bool")
    (io.panic "typecheck: lambda call diagnostic inline test failed"))
  (unless
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-constructor-argument-diagnostic-source)
      "typecheck: call `Pair` argument 1 (parameter `left`) type mismatch: expected i64, found bool")
    (io.panic "typecheck: constructor call diagnostic inline test failed"))
  (unless
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-lifetime-argument-diagnostic-source)
      "typecheck: call `take-same` argument 2 (parameter `right`) type mismatch: expected (& left-life i64), found (& right-life i64); source lifetime `right-life` does not outlive required lifetime `left-life`")
    (io.panic "typecheck: lifetime call diagnostic inline test failed"))
  (unless
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-call-arity-diagnostic-source)
      "typecheck: call arity mismatch: takes-two expected 2 arguments, got 1 argument")
    (io.panic "typecheck: arity call diagnostic inline test failed"))
  (unless
    (compiler-typecheck-auto-borrow-tests-ok?)
    (io.panic "typecheck: auto-borrow call diagnostic inline test failed")))

(test
  compiler-typecheck-closure-copy
  (unless
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-closure-copy-aggregate-source))
    (io.panic "typecheck: Copy aggregate closure alias failed"))
  (unless
    (compiler_typecheck.compiler-typecheck-ok?
      (compiler-typecheck-closure-copy-reference-source))
    (io.panic "typecheck: Copy reference closure alias failed"))
  (unless
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-closure-copy-reference-escape-source)
      "typecheck: reference-capturing closure value would escape lexical scope")
    (io.panic "typecheck: copied reference closure escaped"))
  (unless
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-closure-move-owner-alias-source)
      "typecheck: use of moved value `f`")
    (io.panic "typecheck: non-Copy closure source reuse passed"))
  (unless
    (compiler_typecheck.compiler-typecheck-error-ok?
      (compiler-typecheck-closure-move-nested-alias-source)
      "typecheck: use of moved value `outer`")
    (io.panic "typecheck: nested non-Copy closure source reuse passed")))

(test
  compiler-typecheck-proof-reuse-exact-walker
  (unless
    (proof_reuse_unit.compiler-typecheck-proof-reuse-unit-tests-ok?)
    (io.panic "typecheck: proof-reuse exact/walker unit tests failed")))

(test
  compiler-typecheck-unused-unsafe-state-isolation
  (unless
    (tc_core.tc-unused-unsafe-state-isolation-self-test)
    (io.panic "typecheck: unused unsafe state isolation smoke failed")))

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
              (__tl-box-place diagnostics))
            1)])]
    [reused : tc_core.ResultCompilerTypecheck
      (tc_api.typecheck-compiler-source
        "(define (checked-after-reset) : i64 42)")]
    (and
      failed-once
      (match reused
        [(tc_core.ResultCompilerTypecheck.Ok _) true]
        [(tc_core.ResultCompilerTypecheck.Err _) false]))))

;; Engage the proof-reuse lane through the real installed-module loader.  The
;; vector fixtures import stdlib.vector and instantiate the same generated
;; catalog under one versus five concrete identities; keep each run isolated
;; so the measured skip count cannot carry across programs.
(define (compiler-typecheck-smoke-installed-proof-reuse-roots) : svec.Vec
  (let
    [roots : svec.Vec (svec.new)]
    (begin
      (svec.push (&mut roots) "stdlib")
      (svec.push (&mut roots) "src")
      roots)))

;; The public source-load adapter always prepends the core-macro prelude.  The
;; path-aware installed fixture loader needs the same prelude explicitly so
;; entry expressions such as `and` retain their macro bindings.
(define (compiler-typecheck-smoke-installed-proof-load-file
  [path : String]
  [roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : load.ResultCompilerLoadWithPaths
  (match (load.compiler-load-core-macro-prelude-with-roots-cfg
    (sym_i64_env.sym-i64-empty)
    roots
    cfgs)
    [(load.ResultCompilerLoadWithPaths.Ok
        prelude-decls
        prelude-paths
        prelude-modules
        prelude-seen)
      (match (load.compiler-load-file-with-paths-and-roots-cfg
        path
        prelude-seen
        roots
        cfgs)
        [(load.ResultCompilerLoadWithPaths.Ok
            entry-decls
            entry-paths
            entry-modules
            seen)
          (load.ResultCompilerLoadWithPaths.Ok
            (load.compiler-load-decl-list-append prelude-decls entry-decls)
            (load.compiler-load-decl-path-list-append prelude-paths entry-paths)
            (load.compiler-load-decl-module-list-append
              prelude-modules
              entry-modules)
            seen)]
        [(load.ResultCompilerLoadWithPaths.Err diag)
          (load.ResultCompilerLoadWithPaths.Err diag)])]
    [(load.ResultCompilerLoadWithPaths.Err diag)
      (load.ResultCompilerLoadWithPaths.Err diag)]))

(define (compiler-typecheck-smoke-installed-vector-profile-file-ok?
  [path : String]
  ;; lint-allow: unused-variable -- used by test builds.
  [expected-skips : i64]) : bool
  (let
    [roots : svec.Vec (compiler-typecheck-smoke-installed-proof-reuse-roots)]
    [cfgs : sym_i64_env.SymI64Env (parser.compiler-cfg-empty)]
    [result : bool
      (begin
        (tc_api.compiler-typecheck-reset-load-session!)
        (tc_core.compiler-typecheck-reset-file-state!)
        (tc_core.tc-macro-abstract-proof-reset!)
        (load.compiler-load-surface-summaries-reset!)
        (tc_core.tc-prefix-snapshot-cache-clear!)
        (match (compiler-typecheck-smoke-installed-proof-load-file
          path
          roots
          cfgs)
          [(load.ResultCompilerLoadWithPaths.Ok decls paths _ _)
            (match (tc_api.typecheck-compiler-program-with-paths-checked-cache
              (ast.ast-program decls)
              paths
              roots
              (tc_api.compiler-typecheck-prefix-cache-scope
                "proof-reuse-smoke"
                roots
                cfgs))
              [(tc_core.ResultCompilerTypecheckChecked.Ok _ _ _ _)
                (cfg
                  test
                  (= (tc_core.tc-proof-reuse-skips-total-value) expected-skips)
                  true)]
              [(tc_core.ResultCompilerTypecheckChecked.Partial _ _ _ _) false]
              [(tc_core.ResultCompilerTypecheckChecked.Err diagnostics)
                (let
                  [message : String
                    (diagnostic.compiler-diagnostic-message
                      (diagnostic.compiler-diagnostic-list-first
                        (__tl-box-place diagnostics)))]
                  (begin
                    (io.stderr-write (byte_buf.str-as-bytes (& message)))
                    false))])]
          [(load.ResultCompilerLoadWithPaths.Err load-diagnostic)
            (let
              [message : String
                (diagnostic.compiler-diagnostic-message
                  (__tl-box-place load-diagnostic))]
              (begin
                (io.stderr-write (byte_buf.str-as-bytes (& message)))
                false))]))]
    (begin
      ;; Reset both loader/file state and proof/family counters after every
      ;; fixture, including a failing one, before returning to later smoke.
      (tc_core.compiler-typecheck-reset-file-state!)
      (tc_core.tc-macro-abstract-proof-reset!)
      (load.compiler-load-surface-summaries-reset!)
      (tc_core.tc-prefix-snapshot-cache-clear!)
      (tc_api.compiler-typecheck-reset-load-session!)
      result)))

(define (compiler-typecheck-smoke-installed-vector-proof-reuse-ok?) : bool
  (if (compiler-typecheck-smoke-installed-vector-profile-file-ok?
    "tests/integration/compile_profile_vector_one_core.tl"
    0)
    (compiler-typecheck-smoke-installed-vector-profile-file-ok?
      "tests/integration/compile_profile_vector_five_core.tl"
      16)
    false))

;; Run one installed-loader fixture that must fail, and require the concrete
;; checker diagnostic to contain the packet's stable substring.  Load and proof
;; state are reset both before and after every fixture so a failing identity
;; cannot contaminate a later family.
(define (compiler-typecheck-smoke-installed-proof-error-file-ok?
  [path : String]
  [expected-substring : String]) : bool
  (let
    [roots : svec.Vec (compiler-typecheck-smoke-installed-proof-reuse-roots)]
    [cfgs : sym_i64_env.SymI64Env (parser.compiler-cfg-empty)]
    [result : bool
      (begin
        (tc_api.compiler-typecheck-reset-load-session!)
        (tc_core.compiler-typecheck-reset-file-state!)
        (tc_core.tc-macro-abstract-proof-reset!)
        (load.compiler-load-surface-summaries-reset!)
        (tc_core.tc-prefix-snapshot-cache-clear!)
        (match (compiler-typecheck-smoke-installed-proof-load-file
          path
          roots
          cfgs)
          [(load.ResultCompilerLoadWithPaths.Ok decls paths _ _)
            (match (tc_api.typecheck-compiler-program-with-paths-checked-cache
              (ast.ast-program decls)
              paths
              roots
              (tc_api.compiler-typecheck-prefix-cache-scope
                "proof-reuse-smoke"
                roots
                cfgs))
              [(tc_core.ResultCompilerTypecheckChecked.Ok _ _ _ _) false]
              [(tc_core.ResultCompilerTypecheckChecked.Partial
                  diagnostics
                  _
                  _
                  _)
                (load.compiler-load-string-contains?
                  (diagnostic.compiler-diagnostic-message
                    (diagnostic.compiler-diagnostic-list-first
                      (deref diagnostics)))
                  expected-substring)]
              [(tc_core.ResultCompilerTypecheckChecked.Err diagnostics)
                (load.compiler-load-string-contains?
                  (diagnostic.compiler-diagnostic-message
                    (diagnostic.compiler-diagnostic-list-first
                      (__tl-box-place diagnostics)))
                  expected-substring)])]
          [(load.ResultCompilerLoadWithPaths.Err load-diagnostic)
            (load.compiler-load-string-contains?
              (diagnostic.compiler-diagnostic-message
                (__tl-box-place load-diagnostic))
              expected-substring)]))]
    (begin
      (tc_core.compiler-typecheck-reset-file-state!)
      (tc_core.tc-macro-abstract-proof-reset!)
      (load.compiler-load-surface-summaries-reset!)
      (tc_core.tc-prefix-snapshot-cache-clear!)
      (tc_api.compiler-typecheck-reset-load-session!)
      result)))

(define (compiler-typecheck-smoke-installed-proof-reuse-safety-ok?) : bool
  (let
    [hidden-invalid-ok : bool
      (compiler-typecheck-smoke-installed-proof-error-file-ok?
        "tests/integration/proof_reuse_hidden_invalid.tl"
        "typecheck: integer literal 300 does not fit expected type u8")]
    [literal-narrowing-ok : bool
      (compiler-typecheck-smoke-installed-proof-error-file-ok?
        "tests/integration/proof_reuse_literal_narrowing.tl"
        "typecheck: integer literal 300 does not fit expected type u8")]
    [bool-arithmetic-ok : bool
      (compiler-typecheck-smoke-installed-proof-error-file-ok?
        "tests/integration/proof_reuse_bool_arithmetic.tl"
        "typecheck: integer operator expects matching integer operands")]
    [uncloneable-clone-ok : bool
      (compiler-typecheck-smoke-installed-proof-error-file-ok?
        "tests/integration/proof_reuse_uncloneable_clone.tl"
        "typecheck: clone unsupported type (-> i64 i64)")]
    [equality-sensitive-ok : bool
      (compiler-typecheck-smoke-installed-vector-profile-file-ok?
        "tests/integration/proof_reuse_equality.tl"
        0)]
    [cleanup-substitution-ok : bool
      (compiler-typecheck-smoke-installed-proof-error-file-ok?
        "tests/integration/proof_reuse_cleanup_ownership.tl"
        "field value stores cleanup-owning type FileHandle without :owned")]
    [reflection-fixed-shape-ok : bool
      (compiler-typecheck-smoke-installed-proof-error-file-ok?
        "tests/integration/proof_reuse_reflection_fixed_shape.tl"
        "typecheck: array elements must have same type: expected i64, found bool")]
    [nested-generated-imports-ok : bool
      (compiler-typecheck-smoke-installed-proof-error-file-ok?
        "tests/integration/proof_reuse_nested_generated_imports.tl"
        "typecheck: integer literal 300 does not fit expected type u8")]
    [fixed-signature-call-ok : bool
      (compiler-typecheck-smoke-installed-proof-error-file-ok?
        "tests/integration/proof_reuse_fixed_signature_call.tl"
        "typecheck: call `proof-reuse-fixed-signature-call-only-i64` argument 1 (parameter `x`) type mismatch: expected i64, found u8")]
    [fixed-value-ok : bool
      (compiler-typecheck-smoke-installed-proof-error-file-ok?
        "tests/integration/proof_reuse_fixed_value.tl"
        "typecheck: return type mismatch: expected u8, found i64")]
    [fixed-local-annotation-ok : bool
      (compiler-typecheck-smoke-installed-proof-error-file-ok?
        "tests/integration/proof_reuse_fixed_local_annotation.tl"
        "typecheck: let binding `y` type mismatch: expected i64, found u8")]
    [fixed-return-ok : bool
      (compiler-typecheck-smoke-installed-proof-error-file-ok?
        "tests/integration/proof_reuse_fixed_return.tl"
        "typecheck: return type mismatch: expected i64, found u8")]
    [fixed-field-access-ok : bool
      (compiler-typecheck-smoke-installed-proof-error-file-ok?
        "tests/integration/proof_reuse_fixed_field_access.tl"
        "typecheck: return type mismatch: expected u8, found i64")]
    [substituted-condition-ok : bool
      (compiler-typecheck-smoke-installed-proof-error-file-ok?
        "tests/integration/proof_reuse_substituted_condition.tl"
        "typecheck: if condition must be bool: expected bool, found u8")]
    [fixed-constructor-argument-ok : bool
      (compiler-typecheck-smoke-installed-proof-error-file-ok?
        "tests/integration/proof_reuse_fixed_constructor_argument.tl"
        "typecheck: call `Box` argument 1 (parameter `fixed`) type mismatch: expected i64, found u8")]
    [partial-catalog-ok : bool
      (compiler-typecheck-smoke-installed-vector-profile-file-ok?
        "tests/integration/proof_reuse_partial_catalog.tl"
        2)]
    [sibling-value-dependency-ok : bool
      (compiler-typecheck-smoke-installed-proof-error-file-ok?
        "tests/integration/proof_reuse_sibling_value_dependency.tl"
        "typecheck: integer operator expects matching integer operands")]
    (and
      hidden-invalid-ok
      literal-narrowing-ok
      bool-arithmetic-ok
      uncloneable-clone-ok
      equality-sensitive-ok
      cleanup-substitution-ok
      reflection-fixed-shape-ok
      nested-generated-imports-ok
      fixed-signature-call-ok
      fixed-value-ok
      fixed-local-annotation-ok
      fixed-return-ok
      fixed-field-access-ok
      substituted-condition-ok
      fixed-constructor-argument-ok
      partial-catalog-ok
      sibling-value-dependency-ok)))

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
      [growth-cursor : i64 0]
      [ok : bool true]
      (begin
        (tc_core.compiler-tc-macro-profile-reset)
        (tc_core.compiler-tc-macro-profile-record-entry!
          macro-a
          "profile-dense-module-a/profile-dense-macro"
          2
          3)
        (tc_core.compiler-tc-macro-profile-record-entry!
          macro-a
          "profile-dense-module-a/profile-dense-macro"
          2
          5)
        (tc_core.compiler-tc-macro-profile-record-entry!
          macro-a
          "profile-dense-module-a/profile-dense-macro"
          6
          7)
        (tc_core.compiler-tc-macro-profile-record-entry!
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
    (compiler_typecheck.compiler-typecheck-self-test)
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
      (tc_core.tc-scratch-arena-state-isolation-self-test)
      (io.panic "typecheck: scratch arena state isolation smoke failed"))
    (unless
      (tc_core.tc-unused-unsafe-state-isolation-self-test)
      (io.panic "typecheck: unused unsafe state isolation smoke failed"))
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
      (compiler-typecheck-smoke-macro-no-change-signal-ok?)
      (io.panic "typecheck: unchanged macro walk signal smoke failed"))
    (unless
      (compiler-typecheck-smoke-macro-expr-change-signal-ok?)
      (io.panic "typecheck: expression macro change signal smoke failed"))
    (unless
      (compiler-typecheck-smoke-macro-decl-change-signal-ok?)
      (io.panic "typecheck: declaration macro change signal smoke failed"))
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
      (compiler-typecheck-smoke-lazy-import-stdlib-array-macro-ok?)
      (io.panic "typecheck: lazy import stdlib.array macro smoke failed"))
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
      (compiler-typecheck-smoke-lazy-import-stdlib-array-alias-ok?)
      (io.panic "typecheck: lazy import stdlib.array alias smoke failed"))
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
    (unless
      (compiler-typecheck-smoke-installed-vector-proof-reuse-ok?)
      (io.panic "typecheck: installed vector proof-reuse smoke failed"))
    (unless
      (compiler-typecheck-smoke-installed-proof-reuse-safety-ok?)
      (io.panic "typecheck: installed proof-reuse safety matrix smoke failed"))
    (tc_core.macro-alias-cache-reset!)
    42))