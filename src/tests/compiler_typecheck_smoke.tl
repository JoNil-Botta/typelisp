;; compiler_typecheck_smoke.tl - Runnable smoke for compiler_typecheck.tl.
(import stdlib.io)
(import stdlib.vector)
(import (vector String) as svec)
(import "../compiler_typecheck.tl")
(import stdlib.string)
(import sym_i64_env)

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
  "(define (main [x : i64] [items : (Array (& x i64))]) : unit
  (let [x : i64 1] (array-set! items 0 (& x))))")

(define (compiler-typecheck-reference-array-push-ok-source) : String
  "(define (main [x : i64] [items : (Array (& x i64))]) : unit
  (array-push! items (& x)))")

(define (compiler-typecheck-reference-array-push-escape-source) : String
  "(define (main [x : i64] [items : (Array (& x i64))]) : unit
  (let [x : i64 1] (array-push! items (& x))))")

(define (compiler-typecheck-reference-arena-store-escape-source) : String
  (compiler-typecheck-with-alloc-string-helper-source
    "(define (main [items : (Array (& r str))]) : unit
  (with-arena r
    (let [s : String (string.int->string 1)]
      (array-set! items 0 (& s)))))"))

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
    (string.append
      out
      "(define (main) : unit
  (let
    [f : (-> unit) (lambda () : unit unit)]
    unit))
")
    (compiler-typecheck-lambda-large-global-env-source-from
      (+ index 1)
      limit
      (string.append
        out
        (string.append
          "(define (lambda-global-"
          (string.append
            (string.int->string index)
            (string.append
              ") : i64 "
              (string.append (string.int->string index) ")\n"))))))))

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

(define (compiler-typecheck-reference-lambda-inner-arena-return-source) : String
  "(define (read [r : (& n i64)]) : i64 42)
(define (main) : (-> i64)
  (with-arena scratch
    (let [n : i64 1]
      (let [r : (& n i64) (& n)]
        (let [f : (-> i64) (lambda () : i64 (read r))]
          f)))))")

(define (compiler-typecheck-reference-lambda-mutable-reject-source) : String
  "(define (read [r : (&mut items i64)]) : i64 42)
(define (main [items : (Array i64)]) : i64
  (let [r : (&mut items i64) (&mut (array-ref items 0))]
    ((lambda () : i64 (read r)))))")

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
  (compiler-typecheck-with-alloc-string-helper-source
    "(define (main [seed : (& phase str)]) : (Tuple (& phase str) i64)
  (with-arena phase
    (let [s : String (string.int->string 1)] (tuple (& phase s) 1))))"))

(define (compiler-typecheck-reference-fixed-arena-escape-source) : String
  (compiler-typecheck-with-alloc-string-helper-source
    "(define (main [seed : (& phase str)]) : (Array (& phase str) 1)
  (with-arena phase
    (let [s : String (string.int->string 1)] (array (& phase s)))))"))

(define (compiler-typecheck-reference-dyn-array-init-ok-source) : String
  "(define (main [n : i64]) : unit
  (let [items : (Array (& n i64)) (init : (Array (& n i64)))] unit))")

(define (compiler-typecheck-reference-dyn-array-make-reject-source) : String
  "(define (main [n : i64]) : unit
  (let [items : (Array (& n i64)) (make-array (& n i64) 0)] unit))")

(define (compiler-typecheck-reference-dyn-array-push-read-ok-source) : String
  "(define (main [n : i64]) : unit
  (let
    [items : (Array (& n i64)) (init : (Array (& n i64)))]
    (begin
      (array-push! items (& n))
      (let [r : (& n i64) (array-ref items 0)] unit))))")

(define (compiler-typecheck-reference-dyn-array-push-escape-source) : String
  "(define (main [n : i64]) : unit
  (let
    [items : (Array (& n i64)) (init : (Array (& n i64)))]
    (let [n : i64 1] (array-push! items (& n)))))")

(define (compiler-typecheck-reference-dyn-array-hidden-source) : String
  "(define (main) : unit
  (let [items : (Array (& n i64)) (make-array (& n i64) 0)] unit))")

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
  "(define (main [items : (Array bytes)]) : unit unit)")

(define (compiler-typecheck-bytes-policy-message) : String
  "typecheck: bytes is a borrowed byte-slice referent; use (& lifetime bytes) or (&mut lifetime bytes)")

(define (compiler-typecheck-zero-make-array-recursive-source) : String
  "(defenum Loop (LoopBox (Box Loop)))
(define (main) : unit
  (let [items : (Array Loop) (make-array Loop 0)] unit))")

(define (compiler-typecheck-auto-borrow-ok-source) : String
  "(defstruct RefBox (:lifetimes owner) (value (& owner i64)))
(define (take [n : (& n i64)]) : i64 1)
(define (len [text : (& text str)]) : i64 1)
(define (main [n : i64] [text : String]) : i64
  (let
    [direct : i64 (take n)]
    [box : (RefBox n) (RefBox n)]
    [from-box : i64 (take (struct-get box value))]
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

(define (compiler-typecheck-auto-borrow-string-aggregate-place-source) : String
  "(defstruct Named (name String))
(define (len [text : (& text str)]) : i64 1)
(define (same [left : (& left str)] [right : (& right str)]) : bool true)
(define (main [named : Named] [items : (Array String 1)]) : i64
  (if (same (struct-get named name) (array-ref items 0))
    (+ (len (struct-get named name)) (len (array-ref items 0)))
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

(define (compiler-typecheck-auto-borrow-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-auto-borrow-ok-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-auto-borrow-temporary-source)
      "typecheck: borrow requires a local, parameter, or aggregate place")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-auto-borrow-shared-lifetime-source)
      "typecheck: constructor lifetime mismatch")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-auto-borrow-mutable-param-source)
      "typecheck: argument type mismatch")
    (compiler-typecheck-ok?
      (compiler-typecheck-auto-borrow-string-aggregate-place-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-auto-borrow-assignment-after-last-use-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-auto-borrow-move-after-last-use-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-auto-borrow-assignment-before-last-use-source)
      "typecheck: cannot assign to borrowed place `n`")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-auto-borrow-move-before-last-use-source)
      "typecheck: cannot move borrowed place `text`")))

(define (compiler-typecheck-borrow-projection-assign-source) : String
  "(defstruct Pair (left i64) (right i64))
(define (read-i64-ref [r : (& pair i64)]) : i64 1)
(define (main [pair : Pair]) : i64
  (let
    [borrowed : (& pair i64) (& (struct-get pair left))]
    (begin
      (set! (struct-get pair left) 3)
      (read-i64-ref borrowed))))")

(define (compiler-typecheck-borrow-mut-after-immut-source) : String
  "(define (read-i64-ref [r : (& items i64)]) : unit unit)
(define (main [items : (Array i64)]) : unit
  (let
    [borrowed : (& items i64) (& (array-ref items 0))]
    (begin
      (let
        [exclusive : (&mut items i64) (&mut (array-ref items 0))]
        unit)
      (read-i64-ref borrowed))))")

(define (compiler-typecheck-borrow-immut-after-mut-source) : String
  "(define (write-i64-ref [r : (&mut items i64)]) : unit unit)
(define (main [items : (Array i64)]) : unit
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
  (left (Array i64))
  (right (Array i64)))
(define (main) : unit
  (let
    [left-items : (Array i64) (make-array i64 1)]
    [right-items : (Array i64) (make-array i64 1)]
    [bags : Bags (Bags left-items right-items)]
    (let
      [left : (&mut bags (Array i64)) (&mut (struct-get bags left))]
      [right : (&mut bags (Array i64)) (&mut (struct-get bags right))]
      unit)))")

(define (compiler-typecheck-mut-borrow-same-field-source) : String
  "(defstruct Bags
  (left (Array i64))
  (right (Array i64)))
(define (write-array-ref [items : (&mut bags (Array i64))]) : unit unit)
(define (main) : unit
  (let
    [left-items : (Array i64) (make-array i64 1)]
    [right-items : (Array i64) (make-array i64 1)]
    [bags : Bags (Bags left-items right-items)]
    (let
      [first : (&mut bags (Array i64)) (&mut (struct-get bags left))]
      [second : (&mut bags (Array i64)) (&mut (struct-get bags left))]
      (write-array-ref first))))")

(define (compiler-typecheck-mut-borrow-ancestor-descendant-source) : String
  "(defstruct Bags
  (left (Array i64))
  (right (Array i64)))
(define (main) : unit
  (let
    [left-items : (Array i64) (make-array i64 1)]
    [right-items : (Array i64) (make-array i64 1)]
    [bags : Bags (Bags left-items right-items)]
    (let
      [whole-left : (&mut bags (Array i64)) (&mut (struct-get bags left))]
      [first-item : (&mut bags i64) (&mut (array-ref (struct-get bags left) 0))]
      (array-set! whole-left 0 1))))")

(define (compiler-typecheck-mut-reborrow-bound-subscope-source) : String
  "(define (touch [slot : (&mut items i64)]) : unit unit)
(define (use [items : (&mut items (Array i64))]) : unit
  (begin
    (let
      [slot : (&mut items i64) (&mut (array-ref items 0))]
      (touch slot))
    (array-set! items 0 7)))
(define (main [items : (Array i64)]) : unit
  (use (&mut items)))")

(define (compiler-typecheck-mut-reborrow-same-scope-use-source) : String
  "(define (touch [slot : (&mut items i64)]) : unit unit)
(define (bad [items : (&mut items (Array i64))]) : unit
  (let
    [slot : (&mut items i64) (&mut (array-ref items 0))]
    (begin
      (array-set! items 0 7)
      (touch slot))))
(define (main [items : (Array i64)]) : unit
  (bad (&mut items)))")

(define (compiler-typecheck-mut-borrow-read-array-length-source) : String
  "(define (main) : i64
  (let
    [items : (Array i64) (make-array i64 1)]
    [borrowed : (&mut items (Array i64)) (&mut items)]
    [n : i64 (array-length items)]
    (begin
      (array-set! borrowed 0 41)
      (+ n 1))))")

(define (compiler-typecheck-mut-borrow-read-array-ref-source) : String
  "(define (main) : i64
  (let
    [items : (Array i64) (make-array i64 1)]
    [borrowed : (&mut items (Array i64)) (&mut items)]
    [n : i64 (array-ref items 0)]
    (begin
      (array-set! borrowed 0 41)
      n)))")

(define (compiler-typecheck-mut-borrow-read-struct-get-source) : String
  "(defstruct Bag
  (left (Array i64))
  (right i64))
(define (main) : i64
  (let
    [items : (Array i64) (make-array i64 1)]
    [bag : Bag (Bag items 42)]
    [borrowed : (&mut bag (Array i64)) (&mut (struct-get bag left))]
    [copy : (Array i64) (struct-get bag left)]
    (begin
      (array-set! borrowed 0 41)
      (array-length copy))))")

(define (compiler-typecheck-mut-borrow-read-disjoint-source) : String
  "(defstruct Bag
  (left (Array i64))
  (right i64))
(define (main) : i64
  (let
    [items : (Array i64) (make-array i64 1)]
    [bag : Bag (Bag items 42)]
    [borrowed : (&mut bag (Array i64)) (&mut (struct-get bag left))]
    [right : i64 (struct-get bag right)]
    (begin
      (array-set! borrowed 0 41)
      right)))")

(define (compiler-typecheck-mut-borrow-read-through-ref-source) : String
  "(define (main) : i64
  (let
    [items : (Array i64) (make-array i64 1)]
    [borrowed : (&mut items (Array i64)) (&mut items)]
    [n : i64 (array-length borrowed)]
    (begin
      (array-set! borrowed 0 41)
      n)))")

(define (compiler-typecheck-mut-borrow-owner-read-after-last-use-source) : String
  "(define (main) : i64
  (let
    [items : (Array i64) (make-array i64 1)]
    [borrowed : (&mut items (Array i64)) (&mut items)]
    (begin
      (array-set! borrowed 0 41)
      (array-length items))))")

(define (compiler-typecheck-two-phase-mut-call-shared-read-source) : String
  "(define (read-len [items : (& items (Array i64))]) : i64
  (array-length items))
(define (push-with-len [items : (&mut items (Array i64))] [value : i64]) : unit
  (array-push! items value))
(define (main) : i64
  (let
    [items : (Array i64) (make-array i64 1)]
    (begin
      (push-with-len (&mut items) (read-len (& items)))
      (array-length items))))")

(define (compiler-typecheck-two-phase-mut-call-direct-read-source) : String
  "(define (push-with-len [items : (&mut items (Array i64))] [value : i64]) : unit
  (array-push! items value))
(define (main) : i64
  (let
    [items : (Array i64) (make-array i64 1)]
    (begin
      (push-with-len (&mut items) (array-length items))
      (array-length items))))")

(define (compiler-typecheck-two-phase-mut-call-second-mut-source) : String
  "(define (take-two
  [left : (&mut left (Array i64))]
  [right : (&mut right (Array i64))]) : unit
  unit)
(define (main) : unit
  (let
    [items : (Array i64) (make-array i64 1)]
    (take-two (&mut items) (&mut items))))")

(define (compiler-typecheck-two-phase-mut-call-escaping-shared-source) : String
  "(define (borrow-items [items : (& items (Array i64))]) : (& items (Array i64))
  items)
(define (take-mut-and-view
  [items : (&mut items (Array i64))]
  [view : (& items (Array i64))]) : unit
  unit)
(define (main) : unit
  (let
    [items : (Array i64) (make-array i64 1)]
    (take-mut-and-view (&mut items) (borrow-items (& items)))))")

(define (compiler-typecheck-two-phase-mut-call-mutate-owner-source) : String
  "(define (take-mut-and-value
  [items : (&mut items (Array i64))]
  [value : i64]) : unit
  unit)
(define (main) : unit
  (let
    [items : (Array i64) (make-array i64 1)]
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
(define (main [n : i64] [out : (Array i64)] [limit : i64]) : unit
  (foreach ([i : i64 0 limit])
    (let [borrowed : (& n i64) (& n)]
      (begin
        (take borrowed)
        (array-set! out i n)))))")

(define (compiler-typecheck-secondary-label-contains?
  [labels : CompilerDiagnosticLabelList]
  [needle : String]) : bool
  (match labels
    [(CompilerDiagnosticLabelNil) false]
    [(CompilerDiagnosticLabelCons entry rest)
      (match (struct-get entry label)
        [(CompilerDiagnosticSomeString text)
          (if (string.contains (& text) (& needle))
            true
            (compiler-typecheck-secondary-label-contains? (box-get rest) needle))]
        [CompilerDiagnosticNoString
          (compiler-typecheck-secondary-label-contains? (box-get rest) needle)])]))

(define (compiler-typecheck-help-contains?
  [diag : CompilerDiagnostic]
  [needle : String]) : bool
  (match (compiler-diagnostic-help diag)
    [(CompilerDiagnosticSomeString text) (string.contains (& text) (& needle))]
    [CompilerDiagnosticNoString false]))

(define (compiler-typecheck-labeled-borrow-error-ok?
  [src : String]
  [want-message-fragment : String]) : bool
  (match (typecheck-compiler-source src)
    [(ResultCompilerTypecheck.Err diag)
      (let
        [message : String (compiler-diagnostic-message (box-get diag))]
        (and
          (string.contains (& message) (& want-message-fragment))
          (compiler-typecheck-help-contains?
            (box-get diag)
            "narrower lexical scope")
          (=
            (compiler-typecheck-secondary-count
              (compiler-diagnostic-secondary-spans (box-get diag)))
            1)
          (compiler-typecheck-secondary-label-contains?
            (compiler-diagnostic-secondary-spans (box-get diag))
            "remains live")))]
    [(ResultCompilerTypecheck.Ok _) false]))

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
      "typecheck: cannot read mutably borrowed place `items.#array.0`")
    (compiler-typecheck-labeled-borrow-error-ok?
      (compiler-typecheck-borrow-returned-call-source)
      "typecheck: cannot move borrowed place `text`")
    (compiler-typecheck-ok?
      (compiler-typecheck-borrow-returned-call-after-last-use-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-borrow-non-returning-call-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-borrow-narrow-lexical-ok-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-mut-borrow-disjoint-fields-source))
    (compiler-typecheck-labeled-borrow-error-ok?
      (compiler-typecheck-mut-borrow-same-field-source)
      "typecheck: cannot read mutably borrowed place `bags.left`")
    (compiler-typecheck-labeled-borrow-error-ok?
      (compiler-typecheck-mut-borrow-ancestor-descendant-source)
      "typecheck: cannot read mutably borrowed place `bags.left.#array.0`")
    (compiler-typecheck-ok?
      (compiler-typecheck-mut-reborrow-bound-subscope-source))
    (compiler-typecheck-labeled-borrow-error-ok?
      (compiler-typecheck-mut-reborrow-same-scope-use-source)
      "typecheck: cannot assign to borrowed place `items.#array.0`")
    (compiler-typecheck-labeled-borrow-error-ok?
      (compiler-typecheck-mut-borrow-read-array-length-source)
      "typecheck: cannot read mutably borrowed place `items`")
    (compiler-typecheck-labeled-borrow-error-ok?
      (compiler-typecheck-mut-borrow-read-array-ref-source)
      "typecheck: cannot read mutably borrowed place `items.#array.0`")
    (compiler-typecheck-labeled-borrow-error-ok?
      (compiler-typecheck-mut-borrow-read-struct-get-source)
      "typecheck: cannot read mutably borrowed place `bag.left`")
    (compiler-typecheck-ok?
      (compiler-typecheck-mut-borrow-read-disjoint-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-mut-borrow-read-through-ref-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-mut-borrow-owner-read-after-last-use-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-two-phase-mut-call-shared-read-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-two-phase-mut-call-direct-read-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-two-phase-mut-call-second-mut-source)
      "typecheck: cannot mutably borrow borrowed place `items`")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-two-phase-mut-call-escaping-shared-source)
      "typecheck: cannot mutably borrow borrowed place `items`")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-two-phase-mut-call-mutate-owner-source)
      "typecheck: cannot assign to borrowed place `items`")
    (compiler-typecheck-labeled-borrow-error-ok?
      (compiler-typecheck-borrow-if-conservative-source)
      "typecheck: cannot assign to borrowed place `n`")
    (compiler-typecheck-ok?
      (compiler-typecheck-borrow-if-branch-local-after-join-source))
    (compiler-typecheck-labeled-borrow-error-ok?
      (compiler-typecheck-borrow-if-result-before-last-use-source)
      "typecheck: cannot assign to borrowed place `n`")
    (compiler-typecheck-ok?
      (compiler-typecheck-borrow-if-result-after-last-use-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-borrow-match-branch-local-after-join-source))
    (compiler-typecheck-labeled-borrow-error-ok?
      (compiler-typecheck-borrow-match-result-before-last-use-source)
      "typecheck: cannot assign to borrowed place `n`")
    (compiler-typecheck-ok?
      (compiler-typecheck-borrow-match-result-after-last-use-source))
    (compiler-typecheck-labeled-borrow-error-ok?
      (compiler-typecheck-borrow-if-aggregate-result-before-last-use-source)
      "typecheck: cannot assign to borrowed place `n`")
    (compiler-typecheck-ok?
      (compiler-typecheck-borrow-if-aggregate-result-after-last-use-source))
    (compiler-typecheck-labeled-borrow-error-ok?
      (compiler-typecheck-borrow-while-conservative-source)
      "typecheck: cannot assign to borrowed place `n`")
    (compiler-typecheck-ok?
      (compiler-typecheck-borrow-while-body-after-last-use-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-borrow-foreach-body-after-last-use-source))))

(define (compiler-typecheck-labeled-move-error-ok?
  [src : String]
  [want-message : String]
  [want-label-fragment : String]) : bool
  (match (typecheck-compiler-source src)
    [(ResultCompilerTypecheck.Err diag)
      (and
        (string.eq (compiler-diagnostic-message (box-get diag)) want-message)
        (compiler-typecheck-help-contains? (box-get diag) "clone the owner")
        (=
          (compiler-typecheck-secondary-count
            (compiler-diagnostic-secondary-spans (box-get diag)))
          1)
        (compiler-typecheck-secondary-label-contains?
          (compiler-diagnostic-secondary-spans (box-get diag))
          want-label-fragment))]
    [(ResultCompilerTypecheck.Ok _) false]))

(define (compiler-typecheck-labeled-cleanup-move-error-ok?
  [src : String]
  [want-message : String]
  [want-move-label-fragment : String]
  [want-owner-label-fragment : String]) : bool
  (match (typecheck-compiler-source src)
    [(ResultCompilerTypecheck.Err diag)
      (and
        (string.eq (compiler-diagnostic-message (box-get diag)) want-message)
        (compiler-typecheck-help-contains? (box-get diag) "clone the owner")
        (=
          (compiler-typecheck-secondary-count
            (compiler-diagnostic-secondary-spans (box-get diag)))
          2)
        (compiler-typecheck-secondary-label-contains?
          (compiler-diagnostic-secondary-spans (box-get diag))
          want-move-label-fragment)
        (compiler-typecheck-secondary-label-contains?
          (compiler-diagnostic-secondary-spans (box-get diag))
          want-owner-label-fragment))]
    [(ResultCompilerTypecheck.Ok _) false]))

(define (compiler-typecheck-move-diagnostic-tests-ok?) : bool
  (and
    (compiler-typecheck-labeled-move-error-ok?
      (compiler-typecheck-move-use-after-move-source)
      "typecheck: use of moved value `s`"
      "move of `s` happened here")
    (compiler-typecheck-labeled-move-error-ok?
      (compiler-typecheck-move-owner-projection-nested-repeat-source)
      "typecheck: use of moved value `p.inner.handle`"
      "move of `p.inner.handle` happened here")
    (compiler-typecheck-labeled-move-error-ok?
      (compiler-typecheck-move-owner-projection-nested-parent-after-child-source)
      "typecheck: use of moved value `p.inner`"
      "move of `p.inner.handle` happened here")
    (compiler-typecheck-labeled-move-error-ok?
      (compiler-typecheck-move-owner-projection-nested-child-after-parent-source)
      "typecheck: use of moved value `p.inner`"
      "move of `p.inner` happened here")
    (compiler-typecheck-labeled-move-error-ok?
      (compiler-typecheck-move-while-loop-carried-param-source)
      "typecheck: cannot move loop-carried owner value `s`"
      "loop-carried")
    (compiler-typecheck-labeled-cleanup-move-error-ok?
      (compiler-typecheck-move-with-cleanup-owner-whole-source)
      "typecheck: cleanup owner `h` moved before with scope exit"
      "move of `h` happened here"
      "cleanup owner `h` is bound")
    (compiler-typecheck-labeled-cleanup-move-error-ok?
      (compiler-typecheck-move-with-cleanup-owner-field-source)
      "typecheck: cleanup owner `h` moved before with scope exit"
      "move of `h.handle` happened here"
      "cleanup owner `h` is bound")))

(define (compiler-typecheck-reference-return-container-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      (compiler-typecheck-reference-tuple-return-ok-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-reference-fixed-return-ok-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-reference-tuple-local-escape-source)
      "typecheck: reference value would escape lexical scope")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-reference-fixed-local-escape-source)
      "typecheck: reference value would escape lexical scope")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-reference-tuple-arena-escape-source)
      "typecheck: region-tagged value cannot escape with-arena 'phase'")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-reference-fixed-arena-escape-source)
      "typecheck: region-tagged value cannot escape with-arena 'phase'")))

(define (compiler-typecheck-reference-dyn-array-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      (compiler-typecheck-reference-dyn-array-init-ok-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-reference-dyn-array-push-read-ok-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-zero-make-array-recursive-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-reference-dyn-array-push-escape-source)
      "typecheck: cannot store reference into longer-lived array; reference value would escape lexical scope")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-reference-dyn-array-make-reject-source)
      "typecheck: init unsupported type (& n i64)")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-reference-dyn-array-hidden-source)
      "typecheck: make-array element type is not supported")))

(define (compiler-typecheck-bytes-referent-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-bytes-borrowed-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-bytes-bare-param-source)
      (compiler-typecheck-bytes-policy-message))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-bytes-bare-local-source)
      (compiler-typecheck-bytes-policy-message))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-bytes-bare-struct-source)
      (compiler-typecheck-bytes-policy-message))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-bytes-bare-array-source)
      (compiler-typecheck-bytes-policy-message))))

(define (compiler-typecheck-reference-lambda-capture-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      (compiler-typecheck-reference-lambda-immediate-ok-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-reference-lambda-local-ok-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-reference-lambda-while-ok-source))
    (compiler-typecheck-ok? (compiler-typecheck-lambda-large-global-env-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-reference-lambda-nested-ok-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-reference-lambda-inner-arena-ok-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-reference-lambda-local-return-source)
      "typecheck: reference-capturing closure value would escape lexical scope")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-reference-lambda-store-source)
      "typecheck: reference-capturing closure value would escape lexical scope")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-reference-lambda-pass-unknown-source)
      "typecheck: reference-capturing closure value would escape lexical scope")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-reference-lambda-assign-source)
      "typecheck: reference-capturing closure value would escape lexical scope")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-reference-lambda-inner-arena-return-source)
      "typecheck: reference-capturing closure value would escape lexical scope")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-reference-lambda-mutable-reject-source)
      "typecheck: lambda cannot capture mutable reference; reference value would escape lexical scope")))

(define (compiler-typecheck-reference-escape-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-reference-nested-local-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-reference-inner-let-escape-source)
      "typecheck: reference value would escape lexical scope")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-reference-outer-assignment-escape-source)
      "typecheck: cannot store reference into longer-lived binding; reference value would escape lexical scope")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-reference-container-escape-source)
      "typecheck: cannot store reference into longer-lived array; reference value would escape lexical scope")
    (compiler-typecheck-ok? (compiler-typecheck-reference-array-push-ok-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-reference-array-push-escape-source)
      "typecheck: cannot store reference into longer-lived array; reference value would escape lexical scope")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-reference-arena-store-escape-source)
      "typecheck: cannot store reference into longer-lived array; reference value would escape lexical scope")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-reference-lambda-capture-source)
      "typecheck: lambda cannot capture immutable reference; reference value would escape lexical scope")
    (compiler-typecheck-reference-lambda-capture-tests-ok?)
    (compiler-typecheck-reference-return-container-tests-ok?)
    (compiler-typecheck-reference-dyn-array-tests-ok?)
    (compiler-typecheck-bytes-referent-tests-ok?)))

(define (compiler-typecheck-macro-alias-cache-collision-ok?) : bool
  (begin
    (macro-alias-cache-reset!)
    (macro-alias-cache-ensure!)
    (macro-alias-cache-put! 1 262144 11)
    (macro-alias-cache-put! 2 0 22)
    (and
      (= (macro-alias-cache-get 1 262144) 11)
      (= (macro-alias-cache-get 2 0) 22))))

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
    [(ExprCall _ _)
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
      (define (read [box : Boxed]) : ,T (struct-get box value)))))
(import (boxmod i64) as bi)
(import (boxmod i64) as bi2)
(import (boxmod String) as bs)
(import (boxmod (-> i64 i64)) as bf)
(import (boxmod Pair) as bp)
(import (boxmod Pair) as bp2)
(import (boxmod Other) as bo)
(define (main) : i64
  (+ (bi.read (bi.make 20))
    (+ (bi2.read (bi2.make 1))
      (+ (__tl_string_length (bs.read (bs.make \"typed\")))
          (+ (struct-get (bp.read (bp.make (Pair 7))) value)
            (+ (struct-get (bp2.read (bp2.make (Pair 8))) value)
              (struct-get (bo.read (bo.make (Other 9))) value)))))))")

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
  "(import \"stdlib/vector.tl\")
(defmacro (vector-user) : Module
  `(begin
    (module generated.local_type_vector_user)
    (defstruct T
      (value i64))
    (import (vector T) as vec)
    (define (make [value : i64]) : T
      (T value))
    (define (score [value : T]) : i64
      (let
        [items : vec.Vec (vec.new)]
        (begin
          (vec.push (&mut items) value)
          (struct-get (vec.get (& items) 0 (T 0)) value))))))
(import (vector-user) as user)
(define (main) : i64
  (user.score (user.make 42)))")

(define (compiler-typecheck-smoke-module-macro-qualified-type-stdlib-vector-source) : String
  "(import \"stdlib/vector.tl\")
(defmacro (type-provider) : Module
  `(begin
    (module generated.qualified_type_vector_provider)
    (defstruct T
      (value i64))))
(defmacro (vector-user) : Module
  `(begin
    (module generated.qualified_type_vector_user)
    (import (type-provider) as provider)
    (import (vector provider.T) as vec)
    (define (make [value : i64]) : provider.T
      (provider.T value))
    (define (score [value : provider.T]) : i64
      (let
        [items : vec.Vec (vec.new)]
        (begin
          (vec.push (&mut items) value)
          (struct-get (vec.get (& items) 0 (provider.T 0)) value))))))
(import (vector-user) as user)
(define (main) : i64
  (user.score (user.make 42)))")

(define (compiler-typecheck-smoke-module-macro-param-type-stdlib-vector-source) : String
  "(import \"stdlib/vector.tl\")
(defstruct Pair
  (value i64))
(defmacro (vector-user [T : type]) : Module
  `(begin
    (module generated.param_type_vector_user)
    (import (vector T) as vec)
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
    (import (vector T) as vec)
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
    (import (vector json.Json) as jvec)
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
        (json.JsonMemberListCons
          \"zip\"
          (json.JsonNumber \"42\")
          (box json.JsonMemberListNil))))))")

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
  (struct-get (struct-get (init_user.make) home) zip))")

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
    [(ExprInt index)
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
            (struct-get (vec.get (& items) 0 (T 0)) value)))))))
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
    [(ExprCall _ _)
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
    (compiler-typecheck-error-ok?
      (compiler-typecheck-smoke-comptime-error-expression-source)
      "custom expression macro failure")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-smoke-comptime-error-module-source)
      "custom module macro failure")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-smoke-comptime-error-decls-source)
      "custom decl macro failure")))

(define (compiler-typecheck-smoke-require [ok : bool] [name : String]) : bool
  (if ok
    true
    (io.panic name)))

(define (compiler-typecheck-smoke-module-macro-identity-tests-ok?) : bool
  (and
    (compiler-typecheck-smoke-require
      (compiler-typecheck-ok?
        (compiler-typecheck-smoke-module-macro-import-evaluated-key-source))
      "typecheck: module macro identity import evaluated key failed")
    (compiler-typecheck-smoke-require
      (compiler-typecheck-error-ok?
        (compiler-typecheck-smoke-module-macro-import-incompatible-key-source)
        "typecheck: Module macro output for generated identity :gen(string_3_105_54_52) has incompatible payload")
      "typecheck: module macro identity import incompatible key failed")
    (compiler-typecheck-smoke-require
      (compiler-typecheck-error-ok?
        (compiler-typecheck-smoke-module-macro-generated-collision-source)
        "typecheck: ambiguous unqualified import for value answer between modules generated.a and generated.b; use an explicit alias or qualified access")
      "typecheck: module macro identity generated collision failed")
    (compiler-typecheck-smoke-require
      (compiler-typecheck-ok?
        (compiler-typecheck-smoke-module-macro-generated-local-shadow-source))
      "typecheck: module macro identity generated local shadow failed")
    (compiler-typecheck-smoke-require
      (compiler-typecheck-ok?
        (compiler-typecheck-smoke-module-macro-local-collision-source))
      "typecheck: module macro identity local collision failed")
    (compiler-typecheck-smoke-require
      (compiler-typecheck-ok?
        (compiler-typecheck-smoke-module-macro-type-key-source))
      "typecheck: module macro identity type key failed")
    (compiler-typecheck-smoke-require
      (compiler-typecheck-ok?
        (compiler-typecheck-smoke-module-macro-nested-vector-import-source))
      "typecheck: module macro identity nested vector import failed")
    (compiler-typecheck-smoke-require
      (compiler-typecheck-ok?
        (compiler-typecheck-smoke-module-macro-local-type-stdlib-vector-source))
      "typecheck: module macro identity local type stdlib vector failed")
    (compiler-typecheck-smoke-require
      (compiler-typecheck-ok?
        (compiler-typecheck-smoke-module-macro-qualified-type-stdlib-vector-source))
      "typecheck: module macro identity qualified type stdlib vector failed")
    (compiler-typecheck-smoke-require
      (compiler-typecheck-ok?
        (compiler-typecheck-smoke-module-macro-param-type-stdlib-vector-source))
      "typecheck: module macro identity param type stdlib vector failed")
    (compiler-typecheck-smoke-require
      (compiler-typecheck-ok?
        (compiler-typecheck-smoke-module-macro-local-import-param-vector-source))
      "typecheck: module macro identity local import param vector failed")
    (compiler-typecheck-smoke-require
      (compiler-typecheck-ok?
        (compiler-typecheck-smoke-module-macro-imported-aggregate-stdlib-vector-source))
      "typecheck: module macro identity imported aggregate stdlib vector failed")
    (compiler-typecheck-smoke-require
      (compiler-typecheck-ok?
        (compiler-typecheck-smoke-module-macro-generated-import-nested-enum-payload-source))
      "typecheck: module macro identity generated import nested enum payload failed")
    (compiler-typecheck-smoke-require
      (compiler-typecheck-ok?
        (compiler-typecheck-smoke-module-macro-generated-init-nested-root-source))
      "typecheck: module macro identity generated init nested root failed")
    (compiler-typecheck-smoke-require
      (compiler-typecheck-ok?
        (compiler-typecheck-smoke-module-macro-generated-replay-normalized-source))
      "typecheck: module macro identity generated replay normalized failed")
    (compiler-typecheck-smoke-require
      (compiler-typecheck-ok?
        (compiler-typecheck-smoke-module-macro-strategy-alias-source))
      "typecheck: module macro identity strategy alias failed")
    (compiler-typecheck-smoke-require
      (compiler-typecheck-ok?
        (compiler-typecheck-smoke-module-macro-strategy-dedup-source))
      "typecheck: module macro identity strategy dedup failed")
    (compiler-typecheck-smoke-require
      (compiler-typecheck-error-ok?
        (compiler-typecheck-smoke-module-macro-strategy-missing-hook-source)
        "typecheck: strategy module toy.empty does not export hook emit-i64")
      "typecheck: module macro identity strategy missing hook failed")
    (compiler-typecheck-smoke-require
      (compiler-typecheck-error-ok?
        (compiler-typecheck-smoke-module-macro-strategy-unresolved-source)
        "typecheck: unknown module strategy missing; import the module or use a visible dotted module alias")
      "typecheck: module macro identity strategy unresolved failed")
    (compiler-typecheck-smoke-require
      (compiler-typecheck-ok?
        (compiler-typecheck-smoke-module-macro-strategy-vector-hook-source))
      "typecheck: module macro identity strategy vector hook failed")
    (compiler-typecheck-smoke-require
      (compiler-typecheck-ok?
        (compiler-typecheck-smoke-module-macro-extension-source))
      "typecheck: module macro identity extension failed")
    (compiler-typecheck-smoke-require
      (compiler-typecheck-error-ok?
        (compiler-typecheck-smoke-module-macro-extension-incompatible-source)
        "typecheck: Module macro output for generated identity :extra(string_3_105_54_52) has incompatible payload")
      "typecheck: module macro identity extension incompatible failed")))

;; Declaration-emitting macros must be able to emit functions with non-trivial
;; bodies. The macro-output serializer round-trips arithmetic,
;; struct-get, array.make-array, array.ref/array-set!, let, while,
;; and set! back to
;; declarations; before that surface existed these fixtures failed with
;; "module macro output contains syntax that cannot be parsed as a declaration".
(define (compiler-typecheck-smoke-decls-macro-body-source) : String
  "(import stdlib.array)
(defmacro (int-stack) : Decls
  `(begin
    (defstruct Stack
      (slots (Array i64))
      (len i64)
      (cap i64))
    (define (stack-new) : Stack
      (Stack (array.make-array i64 4) 0 4))
    (define (stack-grow [s : Stack]) : Stack
      (let
        [new-cap : i64 (* (struct-get s cap) 2)]
        [bigger : (Array i64) (array.make-array i64 new-cap)]
        [i : i64 0]
        (begin
          (while (< i (struct-get s len))
            (begin
              (array-set! bigger i (array-ref (struct-get s slots) i))
              (set! i (+ i 1))))
          (Stack bigger (struct-get s len) new-cap))))
    (define (stack-push [s : Stack] [value : i64]) : Stack
      (if (< (struct-get s len) (struct-get s cap))
        (begin
          (array-set! (struct-get s slots) (struct-get s len) value)
          (Stack (struct-get s slots) (+ (struct-get s len) 1) (struct-get s cap)))
        (stack-push (stack-grow s) value)))
    (define (stack-top [s : Stack]) : i64
      (array-ref (struct-get s slots) (- (struct-get s len) 1)))
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
      (let [doubled : i64 (* (struct-get b value) 2)] (+ doubled 1)))))
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
        (struct-get v len)))))
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
    (define (typed-array [v : ,T]) : (Array ,T)
      (let [items : (Array ,T) (array.make-array ,T 1)]
        (begin
          (array-set! items 0 v)
          items)))))
(defmacro (emit-cast [T : type]) : Decls
  `(define (typed-cast [v : i64]) : ,T (cast v : ,T)))
(emit-pair Pair)
(emit-cast i64)
(define (main) : i64
  (+ (typed-cast 1)
    (struct-get (typed-id (Pair 41)) value)))")

(define (compiler-typecheck-smoke-type-macro-param-tests-ok?) : bool
  (compiler-typecheck-ok? (compiler-typecheck-smoke-type-macro-param-source)))

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
    [(ExprCall _ _)
      `(defstruct BundleBox (value i64))]
    [_
      `(defstruct BundleBox (value String))]))
(bundle \"i64\")
(bundle (type-key (type i64)))
(define (main) : i64 0)")

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
  (struct-get (int-box 42) value))")

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
    (compiler-typecheck-ok?
      (compiler-typecheck-smoke-decls-macro-generated-reuse-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-smoke-decls-macro-generated-incompatible-source)
      "generated-decl: duplicate generated key for BundleBox has incompatible payload")
    (compiler-typecheck-ok?
      (compiler-typecheck-smoke-decls-macro-cross-module-reuse-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-smoke-decls-macro-expr-name-key-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-smoke-decls-macro-cross-module-distinct-source))))

(define (compiler-typecheck-smoke-decl-macro-body-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-smoke-decls-macro-body-source))
    (compiler-typecheck-ok? (compiler-typecheck-smoke-module-macro-body-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-smoke-module-macro-generated-import-source))))

(define (compiler-typecheck-smoke-prefix-cache-cfg-source) : String
  "(cfg feature (define (shared-helper [x : i64]) : i64 (+ x 2)))
(cfg (not feature) (define (shared-helper [x : i64]) : i64 (+ x 1)))
(define (main) : i64 (shared-helper 2))")

(define (compiler-typecheck-smoke-prefix-cache-root-paths
  [root : String]
  [entry-path : String]) : AstDeclPathList
  (ast-decl-path-cons
    (compiler-load-join-root-path root "tc_prefix_shared.tl")
    (ast-decl-path-cons entry-path (ast-decl-path-list-new))))

(define (compiler-typecheck-smoke-prefix-cache-roots [root : String]) : svec.Vec
  (let
    [roots : svec.Vec (svec.new)]
    (begin
      (svec.push (&mut roots) root)
      roots)))

(define (compiler-typecheck-smoke-paths-contain?
  [paths : AstDeclPathList]
  [needle : String]) : bool
  (match (ast-decl-path-list-step paths)
    [(AstDeclPathListStep.Nil) false]
    [(AstDeclPathListStep.Cons path rest)
      (or
        (compiler-load-string-contains?
          (compiler-load-normalize-path path)
          needle)
        (compiler-typecheck-smoke-paths-contain? rest needle))]))

(define (compiler-typecheck-smoke-prefix-cache-check-cfg
  [src : String]
  [entry-path : String]
  [paths : AstDeclPathList]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : bool
  (match (parse-ast-source-diagnostic-with-cfg entry-path src cfgs)
    [(ResultAstProgramDiagnostic.Ok program)
      (match (typecheck-compiler-program-with-paths-cache
        program
        paths
        stdlib-roots
        (compiler-typecheck-prefix-cache-scope
          "typecheck-prefix-smoke"
          stdlib-roots
          cfgs))
        [(ResultCompilerTypecheck.Ok _) true]
        [(ResultCompilerTypecheck.Err _) false])]
    [(ResultAstProgramDiagnostic.Err _) false]))

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
      (compiler-load-session-cache-enable!)
      (tc-prefix-snapshot-cache-clear!)
      (if (compiler-typecheck-smoke-prefix-cache-check-cfg
        (compiler-typecheck-prefix-cache-source-a)
        entry-a
        (compiler-typecheck-smoke-prefix-cache-root-paths root-a entry-a)
        roots-a
        (compiler-cfg-empty))
        unit
        (set! ok false))
      (compiler-typecheck-reset-load-session!)
      (if (compiler-typecheck-smoke-prefix-cache-check-cfg
        (compiler-typecheck-prefix-cache-source-b)
        entry-b
        (compiler-typecheck-smoke-prefix-cache-root-paths root-b entry-b)
        roots-b
        (compiler-cfg-empty))
        unit
        (set! ok false))
      (if (= tc-prefix-snapshot-cache-hit-count 0)
        unit
        (set! ok false))
      (if (>= tc-prefix-snapshot-cache-store-count 2)
        unit
        (set! ok false))
      (compiler-typecheck-reset-load-session!)
      (if (compiler-typecheck-smoke-prefix-cache-check-cfg
        (compiler-typecheck-prefix-cache-source-b)
        "target/tc_prefix_root_entry_c.tl"
        (compiler-typecheck-smoke-prefix-cache-root-paths
          root-b
          "target/tc_prefix_root_entry_c.tl")
        roots-b
        (compiler-cfg-empty))
        unit
        (set! ok false))
      (if (> tc-prefix-snapshot-cache-hit-count 0)
        unit
        (set! ok false))
      (compiler-load-session-cache-disable-for-test!)
      (tc-prefix-snapshot-cache-clear!)
      ok)))

(define (compiler-typecheck-smoke-prefix-cache-cfg-isolation-ok?) : bool
  (let
    [root : String "target/tc_prefix_cfg_root"]
    [entry-empty : String "target/tc_prefix_cfg_entry_empty.tl"]
    [entry-feature : String "target/tc_prefix_cfg_entry_feature.tl"]
    [roots : svec.Vec (compiler-typecheck-smoke-prefix-cache-roots root)]
    [ok : bool true]
    (begin
      (compiler-load-session-cache-enable!)
      (tc-prefix-snapshot-cache-clear!)
      (if (compiler-typecheck-smoke-prefix-cache-check-cfg
        (compiler-typecheck-smoke-prefix-cache-cfg-source)
        entry-empty
        (compiler-typecheck-smoke-prefix-cache-root-paths root entry-empty)
        roots
        (compiler-cfg-empty))
        unit
        (set! ok false))
      (compiler-typecheck-reset-load-session!)
      (if (compiler-typecheck-smoke-prefix-cache-check-cfg
        (compiler-typecheck-smoke-prefix-cache-cfg-source)
        entry-feature
        (compiler-typecheck-smoke-prefix-cache-root-paths root entry-feature)
        roots
        (compiler-cfg-enable (compiler-cfg-empty) "feature"))
        unit
        (set! ok false))
      (if (= tc-prefix-snapshot-cache-hit-count 0)
        unit
        (set! ok false))
      (if (>= tc-prefix-snapshot-cache-store-count 2)
        unit
        (set! ok false))
      (compiler-typecheck-reset-load-session!)
      (if (compiler-typecheck-smoke-prefix-cache-check-cfg
        (compiler-typecheck-smoke-prefix-cache-cfg-source)
        "target/tc_prefix_cfg_entry_feature_b.tl"
        (compiler-typecheck-smoke-prefix-cache-root-paths
          root
          "target/tc_prefix_cfg_entry_feature_b.tl")
        roots
        (compiler-cfg-enable (compiler-cfg-empty) "feature"))
        unit
        (set! ok false))
      (if (> tc-prefix-snapshot-cache-hit-count 0)
        unit
        (set! ok false))
      (compiler-load-session-cache-disable-for-test!)
      (tc-prefix-snapshot-cache-clear!)
      ok)))

(define (compiler-typecheck-smoke-prefix-cache-file-check
  [entry-path : String]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : bool
  (match (compiler-load-file-with-paths-and-roots-cfg
    entry-path
    (sym_i64_env.sym-i64-empty)
    stdlib-roots
    cfgs)
    [(ResultCompilerLoadWithPaths.Ok decls paths _ _)
      (match (typecheck-compiler-program-with-paths-cache
        (ast-program decls)
        paths
        stdlib-roots
        (compiler-typecheck-prefix-cache-scope
          "typecheck-prefix-smoke"
          stdlib-roots
          cfgs))
        [(ResultCompilerTypecheck.Ok _) true]
        [(ResultCompilerTypecheck.Err _) false])]
    [(ResultCompilerLoadWithPaths.Err _) false]))

(define (compiler-typecheck-smoke-prefix-cache-local-module-hit-ok?) : bool
  (let
    [dep : String "target/tc_prefix_local_dep.tl"]
    [entry-a : String "target/tc_prefix_local_entry_a.tl"]
    [entry-b : String "target/tc_prefix_local_entry_b.tl"]
    [roots : svec.Vec (svec.new)]
    [cfgs : sym_i64_env.SymI64Env (compiler-cfg-empty)]
    [ok : bool true]
    (begin
      (io.write-file
        dep
        "(module tc.prefix.local.dep)
(define (value [x : i64]) : i64 (+ x 1))")
      (io.write-file
        entry-a
        "(import \"tc_prefix_local_dep.tl\" module tc.prefix.local.dep as dep)
(define (main) : i64 (dep.value 1))")
      (io.write-file
        entry-b
        "(import \"tc_prefix_local_dep.tl\" module tc.prefix.local.dep as dep)
(define (main) : i64 (dep.value 2))")
      (compiler-load-session-cache-enable!)
      (tc-prefix-snapshot-cache-clear!)
      (if (compiler-typecheck-smoke-prefix-cache-file-check entry-a roots cfgs)
        unit
        (set! ok false))
      (compiler-typecheck-reset-load-session!)
      (if (compiler-typecheck-smoke-prefix-cache-file-check entry-b roots cfgs)
        unit
        (set! ok false))
      (if (> tc-prefix-snapshot-cache-hit-count 0)
        unit
        (set! ok false))
      (if (> tc-prefix-snapshot-cache-store-count 0)
        unit
        (set! ok false))
      (compiler-load-session-cache-disable-for-test!)
      (tc-prefix-snapshot-cache-clear!)
      ok)))

(define (compiler-typecheck-smoke-prefix-cache-flat-local-no-hit-ok?) : bool
  (let
    [dep : String "target/tc_prefix_flat_dep.tl"]
    [entry-a : String "target/tc_prefix_flat_entry_a.tl"]
    [entry-b : String "target/tc_prefix_flat_entry_b.tl"]
    [roots : svec.Vec (svec.new)]
    [cfgs : sym_i64_env.SymI64Env (compiler-cfg-empty)]
    [ok : bool true]
    (begin
      (io.write-file dep "(define (flat-helper [x : i64]) : i64 (+ x 1))")
      (io.write-file
        entry-a
        "(import \"tc_prefix_flat_dep.tl\")
(define (main) : i64 (flat-helper 1))")
      (io.write-file
        entry-b
        "(import \"tc_prefix_flat_dep.tl\")
(define (main) : i64 (flat-helper 2))")
      (compiler-load-session-cache-enable!)
      (tc-prefix-snapshot-cache-clear!)
      (if (compiler-typecheck-smoke-prefix-cache-file-check entry-a roots cfgs)
        unit
        (set! ok false))
      (compiler-typecheck-reset-load-session!)
      (if (compiler-typecheck-smoke-prefix-cache-file-check entry-b roots cfgs)
        unit
        (set! ok false))
      (if (= tc-prefix-snapshot-cache-hit-count 0)
        unit
        (set! ok false))
      (if (= tc-prefix-snapshot-cache-store-count 0)
        unit
        (set! ok false))
      (compiler-load-session-cache-disable-for-test!)
      (tc-prefix-snapshot-cache-clear!)
      ok)))

(define (compiler-typecheck-smoke-generated-moduleless-import-order-ok?) : bool
  (let
    [root-provider : String "target/tc_4004_root_provider.tl"]
    [named-provider : String "target/tc_4004_named_provider.tl"]
    [root-then-named : String "target/tc_4004_root_then_named.tl"]
    [named-then-root : String "target/tc_4004_named_then_root.tl"]
    [roots : svec.Vec (svec.new)]
    [cfgs : sym_i64_env.SymI64Env (compiler-cfg-empty)]
    [ok : bool true]
    (begin
      (io.write-file
        root-provider
        "(import \"stdlib/option.tl\")
(import (option i64) as option_i64)

(define (root-score) : i64
  (option_i64.value-or (option_i64.some 1) 0))")
      (io.write-file
        named-provider
        "(module tc4004named)
(import \"stdlib/option.tl\")
(import (option i64) as option_i64)

(define (named-score) : i64
  (option_i64.value-or (option_i64.some 2) 0))")
      (io.write-file
        root-then-named
        "(import \"tc_4004_root_provider.tl\")
(import \"tc_4004_named_provider.tl\")

(define (main) : i64
  (+ (root-score) (tc4004named.named-score)))")
      (io.write-file
        named-then-root
        "(import \"tc_4004_named_provider.tl\")
(import \"tc_4004_root_provider.tl\")

(define (main) : i64
  (+ (root-score) (tc4004named.named-score)))")
      (compiler-typecheck-reset-load-session!)
      (if (compiler-typecheck-smoke-prefix-cache-file-check
        root-then-named
        roots
        cfgs)
        unit
        (set! ok false))
      (compiler-typecheck-reset-load-session!)
      (if (compiler-typecheck-smoke-prefix-cache-file-check
        named-then-root
        roots
        cfgs)
        unit
        (set! ok false))
      ok)))

(define (compiler-typecheck-smoke-moduleless-stdlib-dotted-import-ok?) : bool
  (let
    [base : String "target/tc_moduleless_stdlib"]
    [stdlib-root : String (compiler-load-join-root-path base "stdlib")]
    [dep : String (compiler-load-join-root-path stdlib-root "some_name.tl")]
    [entry : String (compiler-load-join-root-path base "entry.tl")]
    [roots : svec.Vec
      (let
        [items : svec.Vec (svec.new)]
        (begin
          (svec.push (&mut items) stdlib-root)
          items))]
    [cfgs : sym_i64_env.SymI64Env (compiler-cfg-empty)]
    (begin
      (compiler-load-test-mkdir base)
      (compiler-load-test-mkdir stdlib-root)
      (io.write-file dep "(define value : i64 42)")
      (io.write-file
        entry
        "(import stdlib.some_name)
(define (main) : i64 some_name.value)")
      (compiler-typecheck-reset-load-session!)
      (compiler-typecheck-smoke-prefix-cache-file-check entry roots cfgs))))

(define (compiler-typecheck-smoke-specialized-import-path-ok?) : bool
  (let
    [dir : String "target/tc_specialized_import_path"]
    [dep : String (compiler-load-join-root-path dir "dep.tl")]
    [entry : String (compiler-load-join-root-path dir "entry.tl")]
    [roots : svec.Vec (svec.new)]
    [cfgs : sym_i64_env.SymI64Env (compiler-cfg-empty)]
    (begin
      (compiler-load-test-mkdir dir)
      (io.write-file dep "(define imported : i64 true)")
      (io.write-file
        entry
        "(define (id [comptime T : type] [value : T]) : T value)
(import \"dep.tl\")
(define (main) : i64 0)")
      (match (compiler-load-file-with-paths-and-roots-cfg
        entry
        (sym_i64_env.sym-i64-empty)
        roots
        cfgs)
        [(ResultCompilerLoadWithPaths.Ok decls paths _ _)
          (match (typecheck-compiler-program-with-paths-cache
            (ast-program decls)
            paths
            roots
            (compiler-typecheck-prefix-cache-scope
              "typecheck-specialized-import-path-smoke"
              roots
              cfgs))
            [(ResultCompilerTypecheck.Err diag)
              (and
                (string.eq (compiler-diagnostic-path (box-get diag)) dep)
                (string.eq
                  (compiler-diagnostic-message (box-get diag))
                  "typecheck: value definition type mismatch"))]
            [(ResultCompilerTypecheck.Ok _) false])]
        [(ResultCompilerLoadWithPaths.Err _) false]))))

(define (compiler-typecheck-smoke-macro-dependency-helper-source) : String
  "(module tc.macro.context.helper)
(define (bump [value : i64]) : i64 (+ value 1))")

(define (compiler-typecheck-smoke-macro-dependency-provider-source) : String
  "(module tc.macro.context.provider)
(import \"tc_macro_context_helper.tl\" module tc.macro.context.helper as helper)
(defmacro (bumped [value : i64]) : i64
  `(helper.bump ,value))")

(define (compiler-typecheck-smoke-macro-dependency-entry-source) : String
  "(import \"tc_macro_context_provider.tl\" module tc.macro.context.provider as provider)
(define (main) : i64 (provider.bumped 41))")

(define (compiler-typecheck-smoke-macro-dependency-context-ok?) : bool
  (let
    [helper : String "target/tc_macro_context_helper.tl"]
    [provider : String "target/tc_macro_context_provider.tl"]
    [entry : String "target/tc_macro_context_entry.tl"]
    [roots : svec.Vec (svec.new)]
    [cfgs : sym_i64_env.SymI64Env (compiler-cfg-empty)]
    (begin
      (io.write-file
        helper
        (compiler-typecheck-smoke-macro-dependency-helper-source))
      (io.write-file
        provider
        (compiler-typecheck-smoke-macro-dependency-provider-source))
      (io.write-file
        entry
        (compiler-typecheck-smoke-macro-dependency-entry-source))
      (compiler-typecheck-reset-load-session!)
      (compiler-typecheck-smoke-prefix-cache-file-check entry roots cfgs))))

(define (compiler-typecheck-smoke-surface-macro-provider-source) : String
  "(module tc.surface.macro.provider)
(defmacro (hook) : Expr `42)
(define value : i64 1)")

(define (compiler-typecheck-smoke-surface-macro-entry-source) : String
  "(import \"tc_surface_macro_provider.tl\" module tc.surface.macro.provider as provider)
(define (main) : i64 0)")

(define (compiler-typecheck-smoke-surface-macro-summary-ok?) : bool
  (let
    [provider : String "target/tc_surface_macro_provider.tl"]
    [entry : String "target/tc_surface_macro_entry.tl"]
    [roots : svec.Vec (svec.new)]
    [cfgs : sym_i64_env.SymI64Env (compiler-cfg-empty)]
    (begin
      (io.write-file
        provider
        (compiler-typecheck-smoke-surface-macro-provider-source))
      (io.write-file
        entry
        (compiler-typecheck-smoke-surface-macro-entry-source))
      (compiler-typecheck-reset-load-session!)
      (match (compiler-load-file-with-paths-and-roots-cfg
        entry
        (sym_i64_env.sym-i64-empty)
        roots
        cfgs)
        [(ResultCompilerLoadWithPaths.Ok _ _ _ _)
          (begin
            (ctfe-module-macro-export-reset!)
            (let
              [names : TcStringList
                (macro-collect-surface-summary-macro-names
                  (compiler-load-surface-summaries)
                  TcStringList.Nil)]
              (and
                (tc-string-list-contains names "hook")
                (macro-surface-macro-in-module?
                  "tc.surface.macro.provider"
                  "hook")
                (not
                  (macro-surface-macro-in-module?
                    "tc.surface.macro.provider"
                    "missing"))
                (ctfe-module-macro-export? "tc.surface.macro.provider" "hook")
                (not
                  (ctfe-module-macro-export?
                    "tc.surface.macro.provider"
                    "missing")))))]
        [(ResultCompilerLoadWithPaths.Err _) false]))))

(define (compiler-typecheck-smoke-record-surface-summary?
  [path : String]
  [source : String]) : bool
  (match (parse-ast-source-diagnostic path source)
    [(ResultAstProgramDiagnostic.Ok program)
      (match (compiler-load-surface-summary-build
        path
        (compiler-load-dirname path)
        (compiler-cfg-empty)
        program)
        [(ResultCompilerLoadSurfaceSummary.Ok summary)
          (begin
            (compiler-load-record-surface-summary! summary)
            true)]
        [(ResultCompilerLoadSurfaceSummary.Err _) false])]
    [(ResultAstProgramDiagnostic.Err _) false]))

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
      (compiler-typecheck-reset-file-state!)
      (compiler-load-surface-summaries-reset!)
      (if (compiler-typecheck-smoke-record-surface-summary?
        provider-path
        provider-source)
        (match (parse-ast-source-diagnostic "" entry-source)
          [(ResultAstProgramDiagnostic.Ok entry-program)
            (match (typecheck-compiler-program-with-paths-checked
              entry-program
              (ast-decl-path-list-new))
              [(ResultCompilerTypecheckChecked.Ok _ _ _)
                (set!
                  ok
                  (and
                    (> (tc-lazy-import-summary-backed-stub-count) 0)
                    (if (= expected-forces 0)
                      (= (tc-lazy-import-summary-macro-force-count) 0)
                      (> (tc-lazy-import-summary-macro-force-count) 0))))]
              [(ResultCompilerTypecheckChecked.Err _) (set! ok false)])]
          [(ResultAstProgramDiagnostic.Err _) (set! ok false)])
        (set! ok false))
      (compiler-typecheck-reset-file-state!)
      (compiler-load-surface-summaries-reset!)
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

(define (compiler-typecheck-smoke-qualified-array-source) : String
  "(import stdlib.array)
(define (take-array-ref [r : (& items i64)]) : i64 1)
(define (main) : i64
  (let
    [items : (Array i64) (array.make-array i64 1)]
    [fixed : (Array i64 2) (array 3 4)]
    (begin
      (array-set! items 0 (array-ref fixed 1))
      (let
        [borrow-score : i64
          (let
            [borrowed : (& items i64) (& (array-ref items 0))]
            (take-array-ref borrowed))]
        (begin
          (array-push! items 9)
          (+ borrow-score (+ (array-length items) (array-ref items 0))))))))")

(define (compiler-typecheck-smoke-qualified-array-ok?) : bool
  (compiler-typecheck-ok? (compiler-typecheck-smoke-qualified-array-source)))

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
      (match (helper.Choice.Full (struct-get item n))
        [(helper.Choice.Full n) n]
        [(helper.Choice.Empty) 0]))))
(define (main) : i64 (score (helper.Item 1)))")

(define (compiler-typecheck-smoke-lazy-import-full-path-source) : String
  "(module helper.module)
(define value : i64 41)
(module full.entry)
(import helper.module)
(define (full-score) : i64 helper.module.value)")

(define (compiler-typecheck-smoke-lazy-import-explicit-alias-cache-ok?
  [entry-ctx : TcContext]
  [env : TcTypeEnv]) : bool
  (begin
    (tc-source-dotted-alias-key-cache-reset!)
    (match (tc-source-name-lookup-key entry-ctx env "helper.value")
      [(ResultTcString.Ok key)
        (let
          [module-id : i64 (intern "entry.module")]
          [name-id : i64 (intern "helper.value")]
          [lookup-id : i64 (intern "helper.module/value")]
          (and
            (string.eq key "helper.module/value")
            (=
              (tc-source-dotted-alias-key-cache-get module-id name-id)
              lookup-id)
            (match (tc-source-name-lookup-key entry-ctx env "helper.value")
              [(ResultTcString.Ok cached-key) (string.eq cached-key key)]
              [(ResultTcString.Err _) false])))]
      [(ResultTcString.Err _) false])))

(define (compiler-typecheck-smoke-lazy-import-full-path-cache-checked?
  [full-ctx : TcContext]
  [env : TcTypeEnv]) : bool
  (begin
    (tc-source-dotted-full-path-key-cache-reset!)
    (match (tc-source-name-lookup-key full-ctx env "helper.module.value")
      [(ResultTcString.Ok key)
        (let
          [module-id : i64 (intern "full.entry")]
          [name-id : i64 (intern "helper.module.value")]
          [lookup-id : i64 (intern "helper.module/value")]
          (and
            (string.eq key "helper.module/value")
            (=
              (tc-source-dotted-full-path-key-cache-get module-id name-id)
              lookup-id)
            (match (tc-source-name-lookup-key
              full-ctx
              env
              "helper.module.value")
              [(ResultTcString.Ok cached-key) (string.eq cached-key key)]
              [(ResultTcString.Err _) false])))]
      [(ResultTcString.Err _) false])))

(define (compiler-typecheck-smoke-lazy-import-full-path-cache-ok?) : bool
  (let
    [ok : bool
      (match (parse-ast-source-diagnostic
        ""
        (compiler-typecheck-smoke-lazy-import-full-path-source))
        [(ResultAstProgramDiagnostic.Ok program)
          (match (typecheck-compiler-program-with-paths-checked
            program
            (ast-decl-path-list-new))
            [(ResultCompilerTypecheckChecked.Ok _ ctx env)
              (compiler-typecheck-smoke-lazy-import-full-path-cache-checked?
                (tc-context-with-module ctx "full.entry")
                env)]
            [(ResultCompilerTypecheckChecked.Err _) false])]
        [(ResultAstProgramDiagnostic.Err _) false])]
    (begin
      (compiler-typecheck-reset-file-state!)
      ok)))

(define (compiler-typecheck-smoke-full-path-cache-derived-reset-ok?) : bool
  (let
    [module-id : i64 (intern "reset.entry")]
    [name-id : i64 (intern "stdlib.json.stringify")]
    [lookup-id : i64 (intern "stdlib.json/stringify")]
    (begin
      (tc-source-dotted-full-path-key-cache-reset!)
      (tc-source-dotted-full-path-key-cache-put! module-id name-id lookup-id)
      (let
        [before : i64
          (tc-source-dotted-full-path-key-cache-get module-id name-id)]
        (begin
          (macro-alias-derived-cache-reset!)
          (and
            (= before lookup-id)
            (= (tc-source-dotted-full-path-key-cache-get module-id name-id) -2)))))))

(define (compiler-typecheck-smoke-source-name-caches-intern-reset-ok?) : bool
  (begin
    (tc-source-dotted-alias-key-cache-reset!)
    (tc-source-dotted-full-path-key-cache-reset!)
    (tc-source-qualified-variant-key-cache-reset!)
    (let
      [old-module-id : i64 (intern "generation.entry")]
      [old-alias-name-id : i64 (intern "alias.value")]
      [old-full-name-id : i64 (intern "full.path.value")]
      [old-variant-name-id : i64 (intern "Choice.Full")]
      [old-alias-value-id : i64 (intern "old.alias/value")]
      [old-full-value-id : i64 (intern "old.full/value")]
      [old-variant-value-id : i64 (intern "old.choice/Full")]
      (begin
        (tc-source-dotted-alias-key-cache-put!
          old-module-id
          old-alias-name-id
          old-alias-value-id)
        (tc-source-dotted-full-path-key-cache-put!
          old-module-id
          old-full-name-id
          old-full-value-id)
        (tc-source-qualified-variant-key-cache-put!
          old-module-id
          old-variant-name-id
          old-variant-value-id)
        (intern-reset!)
        (compiler-typecheck-reset-intern-owned-state!)
        (let
          [module-id : i64 (intern "generation.entry")]
          [alias-name-id : i64 (intern "alias.value")]
          [full-name-id : i64 (intern "full.path.value")]
          [variant-name-id : i64 (intern "Choice.Full")]
          [alias-miss : i64
            (tc-source-dotted-alias-key-cache-get module-id alias-name-id)]
          [full-miss : i64
            (tc-source-dotted-full-path-key-cache-get module-id full-name-id)]
          [variant-miss : i64
            (tc-source-qualified-variant-key-cache-get
              module-id
              variant-name-id)]
          (begin
            (compiler-typecheck-reset-file-state!)
            (and (= alias-miss -2) (= full-miss -2) (= variant-miss -2))))))))

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
  (compiler-typecheck-ok?
    (compiler-typecheck-smoke-qualified-enum-variant-precedence-source)))

(test
  compiler-typecheck-qualified-enum-variant-precedence
  (if (compiler-typecheck-smoke-qualified-enum-variant-precedence-ok?)
    unit
    (io.panic "typecheck: qualified enum variant precedence smoke failed")))

(define (compiler-typecheck-smoke-lazy-import-stdlib-summary-source) : String
  "(module main)
(import stdlib.vector as vec)
(define (main) : i64 0)")

(define (compiler-typecheck-smoke-lazy-import-stdlib-array-source) : String
  "(module main)
(import stdlib.array)
(define (main) : i64
  (let
    [items : (Array i64) (stdlib.array.make-array i64 0)]
    (begin
      (stdlib.array.push! items 41)
      (+ (stdlib.array.ref items 0) (stdlib.array.length items)))))")

(define (compiler-typecheck-smoke-lazy-import-stdlib-array-alias-source) : String
  "(module main)
(import stdlib.array)
(define (main) : i64
  (let
    [items : (Array i64) (array.make-array i64 0)]
    (begin
      (array.push! items 41)
      (+ (array.ref items 0) (array.length items)))))")

(define (compiler-typecheck-smoke-lazy-import-stdlib-result-source) : String
  "(module main)
(import stdlib.result)
(import (result i64 String) as result_i64_string)
(define (main) : i64 42)")

(define (compiler-typecheck-smoke-unused-result-import-local-type-source) : String
  "(module main)
(import stdlib.result)

(defstruct LocalError
  (message String))

(import (result i64 LocalError) as local_result_unused)

(define (main) : i64 42)")

(define (compiler-typecheck-smoke-result-enum-then-helper-source) : String
  "(module main)
(import stdlib.result)
(import (result i64 String) as r_enum)
(import (result i64 String) as r_helper)

(define (score [value : r_enum.Result]) : i64
  (match value
    [(r_enum.Ok v) v]
    [(r_enum.Err _) 0]))

(define (main) : i64
  (+ (score (r_helper.ok 40)) (r_helper.value-or (r_helper.err \"bad\") 2)))")

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
  (struct-get span line))

(define (span-col [span : (& span Span)]) : i64
  (struct-get span col))

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
      (match (parse-ast-source-diagnostic
        ""
        (compiler-typecheck-smoke-lazy-import-explicit-alias-source))
        [(ResultAstProgramDiagnostic.Ok program)
          (match (typecheck-compiler-program-with-paths-checked
            program
            (ast-decl-path-list-new))
            [(ResultCompilerTypecheckChecked.Ok _ ctx env)
              (let
                [entry-ctx : TcContext
                  (tc-context-with-module ctx "entry.module")]
                (and
                  (= (tc-lazy-import-stub-count) 1)
                  (= (tc-lazy-import-summary-backed-stub-count) 1)
                  (not
                    (tc-name-bound?
                      env
                      (compiler-symbol-module-key "helper" "value")))
                  (tc-name-bound?
                    env
                    (compiler-symbol-module-key "helper.module" "value"))
                  (match (tc-lookup-dotted-source-visible
                    entry-ctx
                    env
                    "helper.value")
                    [(ResultTcType.Ok _) true]
                    [(ResultTcType.Err _) false])
                  (compiler-typecheck-smoke-lazy-import-explicit-alias-cache-ok?
                    entry-ctx
                    env)
                  (match (tc-lookup-dotted-source-visible
                    entry-ctx
                    env
                    "helper.get")
                    [(ResultTcType.Ok _) true]
                    [(ResultTcType.Err _) false])
                  (match (tc-lookup-dotted-source-visible
                    entry-ctx
                    env
                    "helper.Choice.Full")
                    [(ResultTcType.Ok _) true]
                    [(ResultTcType.Err _) false])
                  (match (tc-dotted-type-name-lookup-key
                    entry-ctx
                    "helper.Item")
                    [(ResultTcString.Ok key)
                      (string.eq key "helper.module/Item")]
                    [(ResultTcString.Err _) false])
                  (match (tc-module-local-env entry-ctx env "entry.module")
                    [(ResultTcEnv.Ok local-env)
                      (and
                        (not
                          (tc-name-bound?
                            local-env
                            (compiler-symbol-module-key "helper" "value")))
                        (match (tc-lookup-dotted-source-visible
                          entry-ctx
                          local-env
                          "helper.value")
                          [(ResultTcType.Ok _) true]
                          [(ResultTcType.Err _) false]))]
                    [(ResultTcEnv.Err _) false])))]
            [(ResultCompilerTypecheckChecked.Err _) false])]
        [(ResultAstProgramDiagnostic.Err _) false])]
    (begin
      (compiler-typecheck-reset-file-state!)
      ok)))

(define (compiler-typecheck-smoke-lazy-import-stdlib-summary-backed-ok?) : bool
  (let
    [ok : bool
      (match (typecheck-compiler-source-load
        (compiler-typecheck-smoke-lazy-import-stdlib-summary-source))
        [(ResultCompilerLoadWithPaths.Ok decls paths _ _)
          (match (typecheck-compiler-program-with-paths-checked
            (ast-program decls)
            paths)
            [(ResultCompilerTypecheckChecked.Ok _ _ env)
              (and
                (> (tc-lazy-import-summary-backed-stub-count) 0)
                (not
                  (tc-name-bound?
                    env
                    (compiler-symbol-module-key "vec" "I64Vec"))))]
            [(ResultCompilerTypecheckChecked.Err _) false])]
        [(ResultCompilerLoadWithPaths.Err _) false])]
    (begin
      (compiler-typecheck-reset-file-state!)
      (compiler-load-surface-summaries-reset!)
      ok)))

(define (compiler-typecheck-smoke-lazy-import-stdlib-array-macro-ok?) : bool
  (let
    [ok : bool
      (begin
        (compiler-load-test-mkdir "target/tc_lazy_stdlib_array")
        (io.write-file
          "target/tc_lazy_stdlib_array/canonical.tl"
          (compiler-typecheck-smoke-lazy-import-stdlib-array-source))
        (match (compiler-load-file-with-paths
          "target/tc_lazy_stdlib_array/canonical.tl"
          (sym_i64_env.sym-i64-empty))
          [(ResultCompilerLoadWithPaths.Ok decls paths _ _)
            (let
              [array-materialized : bool
                (compiler-typecheck-smoke-paths-contain?
                  paths
                  "stdlib/array.tl")]
              (match (typecheck-compiler-program-with-paths-checked
                (ast-program decls)
                paths)
                [(ResultCompilerTypecheckChecked.Ok _ _ _)
                  (if array-materialized
                    (io.panic
                      "typecheck: lazy import stdlib.array materialized")
                    true)]
                [(ResultCompilerTypecheckChecked.Err diag)
                  (let
                    [message : String
                      (compiler-diagnostic-message (box-get diag))]
                    (begin
                      (io.stderr-write (& message))
                      (io.panic
                        "typecheck: lazy import stdlib.array nested typecheck failed")))]))]
          [(ResultCompilerLoadWithPaths.Err _)
            (io.panic "typecheck: lazy import stdlib.array load failed")]))]
    (begin
      (compiler-typecheck-reset-file-state!)
      (compiler-load-surface-summaries-reset!)
      ok)))

(define (compiler-typecheck-smoke-lazy-import-stdlib-result-macro-ok?) : bool
  (let
    [ok : bool
      (begin
        (compiler-load-test-mkdir "target/tc_lazy_stdlib_result")
        (io.write-file
          "target/tc_lazy_stdlib_result/result.tl"
          (compiler-typecheck-smoke-lazy-import-stdlib-result-source))
        (match (compiler-load-file-with-paths
          "target/tc_lazy_stdlib_result/result.tl"
          (sym_i64_env.sym-i64-empty))
          [(ResultCompilerLoadWithPaths.Ok decls paths _ _)
            (let
              [skip-count : i64 (compiler-load-lazy-import-skip-count)]
              [result-materialized : bool
                (compiler-typecheck-smoke-paths-contain?
                  paths
                  "stdlib/result.tl")]
              (match (typecheck-compiler-program-with-paths-checked
                (ast-program decls)
                paths)
                [(ResultCompilerTypecheckChecked.Ok _ _ _)
                  (and (> skip-count 0) (not result-materialized))]
                [(ResultCompilerTypecheckChecked.Err diag)
                  (let
                    [message : String
                      (compiler-diagnostic-message (box-get diag))]
                    (begin
                      (io.stderr-write (& message))
                      false))]))]
          [(ResultCompilerLoadWithPaths.Err _) false]))]
    (begin
      (compiler-typecheck-reset-file-state!)
      (compiler-load-surface-summaries-reset!)
      ok)))

(define (compiler-typecheck-smoke-unused-result-import-local-type-ok?) : bool
  (let
    [ok : bool
      (begin
        (compiler-load-test-mkdir "target/tc_unused_result_local_type")
        (io.write-file
          "target/tc_unused_result_local_type/main.tl"
          (compiler-typecheck-smoke-unused-result-import-local-type-source))
        (match (compiler-load-file-with-paths
          "target/tc_unused_result_local_type/main.tl"
          (sym_i64_env.sym-i64-empty))
          [(ResultCompilerLoadWithPaths.Ok decls paths _ _)
            (match (typecheck-compiler-program-with-paths-checked
              (ast-program decls)
              paths)
              [(ResultCompilerTypecheckChecked.Ok _ _ _) true]
              [(ResultCompilerTypecheckChecked.Err diag)
                (let
                  [message : String
                    (compiler-diagnostic-message (box-get diag))]
                  (begin
                    (io.stderr-write (& message))
                    false))])]
          [(ResultCompilerLoadWithPaths.Err _) false]))]
    (begin
      (compiler-typecheck-reset-file-state!)
      (compiler-load-surface-summaries-reset!)
      ok)))

(define (compiler-typecheck-smoke-result-enum-then-helper-ok?) : bool
  (let
    [ok : bool
      (begin
        (compiler-load-test-mkdir "target/tc_result_enum_then_helper")
        (io.write-file
          "target/tc_result_enum_then_helper/main.tl"
          (compiler-typecheck-smoke-result-enum-then-helper-source))
        (match (compiler-load-file-with-paths
          "target/tc_result_enum_then_helper/main.tl"
          (sym_i64_env.sym-i64-empty))
          [(ResultCompilerLoadWithPaths.Ok decls paths _ _)
            (match (typecheck-compiler-program-with-paths-checked
              (ast-program decls)
              paths)
              [(ResultCompilerTypecheckChecked.Ok _ _ _) true]
              [(ResultCompilerTypecheckChecked.Err diag)
                (let
                  [message : String
                    (compiler-diagnostic-message (box-get diag))]
                  (begin
                    (io.stderr-write (& message))
                    false))])]
          [(ResultCompilerLoadWithPaths.Err _) false]))]
    (begin
      (compiler-typecheck-reset-file-state!)
      (compiler-load-surface-summaries-reset!)
      ok)))

(define (compiler-typecheck-smoke-lazy-import-stdlib-array-alias-ok?) : bool
  (let
    [ok : bool
      (begin
        (compiler-load-test-mkdir "target/tc_lazy_stdlib_array")
        (io.write-file
          "target/tc_lazy_stdlib_array/alias.tl"
          (compiler-typecheck-smoke-lazy-import-stdlib-array-alias-source))
        (match (compiler-load-file-with-paths
          "target/tc_lazy_stdlib_array/alias.tl"
          (sym_i64_env.sym-i64-empty))
          [(ResultCompilerLoadWithPaths.Ok decls paths _ _)
            (let
              [skip-count : i64 (compiler-load-lazy-import-skip-count)]
              (match (typecheck-compiler-program-with-paths-checked
                (ast-program decls)
                paths)
                [(ResultCompilerTypecheckChecked.Ok _ _ _) (= skip-count 0)]
                [(ResultCompilerTypecheckChecked.Err _) false]))]
          [(ResultCompilerLoadWithPaths.Err _) false]))]
    (begin
      (compiler-typecheck-reset-file-state!)
      (compiler-load-surface-summaries-reset!)
      ok)))

(define (compiler-typecheck-smoke-lazy-import-str-cat-macro-ok?) : bool
  (let
    [ok : bool
      (match (typecheck-compiler-source-load
        (compiler-typecheck-smoke-lazy-import-str-cat-source))
        [(ResultCompilerLoadWithPaths.Ok decls paths _ _)
          (match (typecheck-compiler-program-with-paths-checked
            (ast-program decls)
            paths)
            [(ResultCompilerTypecheckChecked.Ok _ _ _) true]
            [(ResultCompilerTypecheckChecked.Err _) false])]
        [(ResultCompilerLoadWithPaths.Err _) false])]
    (begin
      (compiler-typecheck-reset-file-state!)
      (compiler-load-surface-summaries-reset!)
      ok)))

(define (compiler-typecheck-smoke-runtime-str-cat-two-nested-ok?) : bool
  (let
    [ok : bool
      (match (typecheck-compiler-source-load
        (compiler-typecheck-smoke-runtime-str-cat-two-nested-source))
        [(ResultCompilerLoadWithPaths.Ok decls paths _ _)
          (match (typecheck-compiler-program-with-paths-checked
            (ast-program decls)
            paths)
            [(ResultCompilerTypecheckChecked.Ok _ _ _) true]
            [(ResultCompilerTypecheckChecked.Err _) false])]
        [(ResultCompilerLoadWithPaths.Err _) false])]
    (begin
      (compiler-typecheck-reset-file-state!)
      (compiler-load-surface-summaries-reset!)
      ok)))

(define (main) : i64
  (begin
    (compiler-typecheck-self-test)
    (unless
      (compiler-typecheck-reference-escape-tests-ok?)
      (io.panic "typecheck: reference escape tests failed"))
    (unless
      (compiler-typecheck-auto-borrow-tests-ok?)
      (io.panic "typecheck: auto-borrow tests failed"))
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
      (compiler-typecheck-smoke-qualified-enum-variant-precedence-ok?)
      (io.panic "typecheck: qualified enum variant precedence smoke failed"))
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
      (compiler-typecheck-smoke-prefix-cache-root-isolation-ok?)
      (io.panic "typecheck: prefix cache root smoke failed"))
    (unless
      (compiler-typecheck-smoke-prefix-cache-cfg-isolation-ok?)
      (io.panic "typecheck: prefix cache cfg smoke failed"))
    (unless
      (compiler-typecheck-smoke-prefix-cache-local-module-hit-ok?)
      (io.panic "typecheck: prefix cache local module smoke failed"))
    (unless
      (compiler-typecheck-smoke-prefix-cache-flat-local-no-hit-ok?)
      (io.panic "typecheck: prefix cache flat local smoke failed"))
    (unless
      (compiler-typecheck-smoke-generated-moduleless-import-order-ok?)
      (io.panic "typecheck: generated moduleless import order smoke failed"))
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
    (macro-alias-cache-reset!)
    42))