;; compiler_typecheck_smoke.tl - Runnable smoke for compiler_typecheck.tl (#426).
(import "../../stdlib/io.tl")
(import "../compiler_typecheck.tl")
(import "../../stdlib/string.tl")

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
    (let [s : String (int->string 1)]
      (array-set! items 0 (& s)))))"))

(define (compiler-typecheck-reference-lambda-capture-source) : String
  "(define (main [x : i64]) : (-> unit)
  (let
    [r : (& x i64) (& x)]
    (lambda () : unit (let [copy : (& x i64) r] unit))))")

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
    (let [s : String (int->string 1)] (tuple (& phase s) 1))))"))

(define (compiler-typecheck-reference-fixed-arena-escape-source) : String
  (compiler-typecheck-with-alloc-string-helper-source
    "(define (main [seed : (& phase str)]) : (Array (& phase str) 1)
  (with-arena phase
    (let [s : String (int->string 1)] (array (& phase s)))))"))

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
  "(define (borrow-text [text : (& text str)]) : (& text str)
  text)
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
  "(define (borrow-text [text : (& text str)]) : (& text str)
  text)
(define (len [text : (& text str)]) : i64 1)
(define (main) : i64
  (let
    [text : String \"borrowed\"]
    (let
      [borrowed : (& text str) (borrow-text (& text))]
      (begin
        (len borrowed)
        (let [moved : String text] 1)))))")

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
          (if (string-contains (& text) (& needle))
            true
            (compiler-typecheck-secondary-label-contains? (box-get rest) needle))]
        [CompilerDiagnosticNoString
          (compiler-typecheck-secondary-label-contains? (box-get rest) needle)])]))

(define (compiler-typecheck-help-contains?
  [diag : CompilerDiagnostic]
  [needle : String]) : bool
  (match (compiler-diagnostic-help diag)
    [(CompilerDiagnosticSomeString text) (string-contains (& text) (& needle))]
    [CompilerDiagnosticNoString false]))

(define (compiler-typecheck-labeled-borrow-error-ok?
  [src : String]
  [want-message-fragment : String]) : bool
  (match (typecheck-compiler-source src)
    [(ErrCompilerTypecheck diag)
      (let
        [message : String (compiler-diagnostic-message diag)]
        (and
          (string-contains (& message) (& want-message-fragment))
          (compiler-typecheck-help-contains? diag "narrower lexical scope")
          (=
            (compiler-typecheck-secondary-count
              (compiler-diagnostic-secondary-spans diag))
            1)
          (compiler-typecheck-secondary-label-contains?
            (compiler-diagnostic-secondary-spans diag)
            "remains live")))]
    [(OkCompilerTypecheck _) false]))

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
    [(ErrCompilerTypecheck diag)
      (and
        (string-eq (compiler-diagnostic-message diag) want-message)
        (compiler-typecheck-help-contains? diag "clone the owner")
        (=
          (compiler-typecheck-secondary-count
            (compiler-diagnostic-secondary-spans diag))
          1)
        (compiler-typecheck-secondary-label-contains?
          (compiler-diagnostic-secondary-spans diag)
          want-label-fragment))]
    [(OkCompilerTypecheck _) false]))

(define (compiler-typecheck-labeled-cleanup-move-error-ok?
  [src : String]
  [want-message : String]
  [want-move-label-fragment : String]
  [want-owner-label-fragment : String]) : bool
  (match (typecheck-compiler-source src)
    [(ErrCompilerTypecheck diag)
      (and
        (string-eq (compiler-diagnostic-message diag) want-message)
        (compiler-typecheck-help-contains? diag "clone the owner")
        (=
          (compiler-typecheck-secondary-count
            (compiler-diagnostic-secondary-spans diag))
          2)
        (compiler-typecheck-secondary-label-contains?
          (compiler-diagnostic-secondary-spans diag)
          want-move-label-fragment)
        (compiler-typecheck-secondary-label-contains?
          (compiler-diagnostic-secondary-spans diag)
          want-owner-label-fragment))]
    [(OkCompilerTypecheck _) false]))

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
    (define (answer) : i64 42)
    (export (value answer))))
(import (gen \"same\"))
(import (gen (if true \"same\" \"other\")))
(define (main) : i64 (answer))")

(define (compiler-typecheck-smoke-module-macro-import-incompatible-key-source) : String
  "(defmacro (gen [key : Expr]) : Module
  (match key
    [(ExprCall _ _)
      `(begin
      (module generated.module)
      (define (answer) : i64 99)
      (export (value answer)))]
    [_
      `(begin
      (module generated.module)
      (define (answer) : i64 42)
      (export (value answer)))]))
(defmacro (later) : Decls
  `(import (gen (string-append \"sa\" \"me\"))))
(import (gen \"same\"))
(later)
(define (main) : i64 (answer))")

(define (compiler-typecheck-smoke-module-macro-generated-collision-source) : String
  "(defmacro (gen-a [key : String]) : Module
  `(begin
    (module generated.a)
    (define (answer) : i64 42)
    (export (value answer))))
(defmacro (gen-b [key : String]) : Module
  `(begin
    (module generated.b)
    (define (answer) : i64 99)
    (export (value answer))))
(import (gen-a \"a\"))
(import (gen-b \"b\"))
(define (main) : i64 (answer))")

(define (compiler-typecheck-smoke-module-macro-local-collision-source) : String
  "(defmacro (gen [key : String]) : Module
  `(begin
    (module generated.module)
    (define (answer) : i64 42)
    (export (value answer))))
(define (answer) : i64 0)
(import (gen \"x\"))
(define (main) : i64 (answer))")

(define (compiler-typecheck-smoke-module-macro-type-key-source) : String
  "(defstruct Pair (value i64))
(defstruct Other (value i64))
(defmacro (boxmod [T : type]) : Module
  (let
    [mod-name : Expr (expr-var (string-append \"generated.box.\" (type-key T)))]
    `(begin
      (module ,mod-name)
      (defstruct Boxed (value ,T))
      (define (make [value : ,T]) : Boxed (Boxed value))
      (define (read [box : Boxed]) : ,T (struct-get box value))
      (export (type Boxed))
      (export (constructor Boxed))
      (export (value make))
      (export (value read)))))
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
    (define (id [value : ,T]) : ,T value)
    (export (value id))))
(defmacro (uses-vector) : Module
  `(begin
    (module generated.usesvec)
    (import (vector i64) as v)
    (define (answer) : i64
      (v.id 42))
    (export (value answer))))
(import (uses-vector) as uv)
(define (main) : i64 (uv.answer))")

(define (compiler-typecheck-smoke-module-macro-extension-source) : String
  "(defmacro (base [key : String]) : Module
  `(begin
    (module generated.shared)
    (define (answer) : i64 40)
    (export (value answer))))
(defmacro (extra [key : String]) : Module
  `(begin
    (module generated.shared)
    (define (bonus) : i64 1)
    (export (value bonus))))
(import (base \"same\") as base)
(import (extra \"same\") as extra)
(import (extra \"same\") as extra2)
(define (main) : i64
  (+ (base.answer) (+ (extra.bonus) (extra2.bonus))))")

(define (compiler-typecheck-smoke-module-macro-extension-incompatible-source) : String
  "(defmacro (base [key : String]) : Module
  `(begin
    (module generated.shared)
    (define (answer) : i64 40)
    (export (value answer))))
(defmacro (extra [key : Expr]) : Module
  (match key
    [(ExprCall _ _)
      `(begin
        (module generated.shared)
        (define (bonus) : i64 2)
        (export (value bonus)))]
    [_
      `(begin
        (module generated.shared)
        (define (bonus) : i64 1)
        (export (value bonus)))]))
(import (base \"same\") as base)
(import (extra \"same\") as extra)
(import (extra (string-append \"sa\" \"me\")) as extra2)
(define (main) : i64
  (+ (base.answer) (+ (extra.bonus) (extra2.bonus))))")

(define (compiler-typecheck-smoke-module-macro-identity-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      (compiler-typecheck-smoke-module-macro-import-evaluated-key-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-smoke-module-macro-import-incompatible-key-source)
      "typecheck: Module macro output for generated identity :gen(string_4_115_97_109_101) has incompatible payload")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-smoke-module-macro-generated-collision-source)
      "typecheck: generated import collision for value answer between generated identities :gen-a(string_1_97) and :gen-b(string_1_98); use an explicit alias or full generated-module access")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-smoke-module-macro-local-collision-source)
      "typecheck: generated import collision for value answer from generated identity :gen(string_1_120) with ordinary binding local declaration; use an explicit alias or full generated-module access")
    (compiler-typecheck-ok?
      (compiler-typecheck-smoke-module-macro-type-key-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-smoke-module-macro-nested-vector-import-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-smoke-module-macro-extension-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-smoke-module-macro-extension-incompatible-source)
      "typecheck: Module macro output for generated identity :extra(string_4_115_97_109_101) has incompatible payload")))

;; Declaration-emitting macros must be able to emit functions with non-trivial
;; bodies (#3193 / #3074). The macro-output serializer round-trips arithmetic,
;; struct-get, make-array, array-ref/array-set!, let, while, and set! back to
;; declarations; before that surface existed these fixtures failed with
;; "module macro output contains syntax that cannot be parsed as a declaration".
(define (compiler-typecheck-smoke-decls-macro-body-source) : String
  "(defmacro (int-stack) : Decls
  `(begin
    (defstruct Stack
      (slots (Array i64))
      (len i64)
      (cap i64))
    (define (stack-new) : Stack
      (Stack (make-array i64 4) 0 4))
    (define (stack-grow [s : Stack]) : Stack
      (let
        [new-cap : i64 (* (struct-get s cap) 2)]
        [bigger : (Array i64) (make-array i64 new-cap)]
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
      (let [doubled : i64 (* (struct-get b value) 2)] (+ doubled 1)))
    (export (type Box1))
    (export (constructor Box1))
    (export (value make))
    (export (value bumped))))
(import (int-box) as ib)
(define (main) : i64 (ib.bumped (ib.make 20)))")

(define (compiler-typecheck-smoke-type-macro-param-source) : String
  "(defstruct Pair (value i64))
(defmacro (emit-pair [T : type]) : Decls
  `(begin
    (define (typed-id [v : ,T]) : ,T
      (let [x : ,T v] (ann x : ,T)))
    (define (typed-init) : ,T (init : ,T))
    (define (typed-array [v : ,T]) : (Array ,T)
      (let [items : (Array ,T) (make-array ,T 1)]
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

(define (compiler-typecheck-smoke-decl-macro-body-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-smoke-decls-macro-body-source))
    (compiler-typecheck-ok? (compiler-typecheck-smoke-module-macro-body-source))))

(define (compiler-typecheck-smoke-prefix-cache-cfg-source) : String
  "(cfg feature (define (shared-helper [x : i64]) : i64 (+ x 2)))
(cfg (not feature) (define (shared-helper [x : i64]) : i64 (+ x 1)))
(define (main) : i64 (shared-helper 2))")

(define (compiler-typecheck-smoke-prefix-cache-root-paths
  [root : String]
  [entry-path : String]) : AstDeclPathList
  (ast-decl-path-cons
    (compiler-load-join-root-path root "tc_prefix_shared.tl")
    (ast-decl-path-cons entry-path AstDeclPathNil)))

(define (compiler-typecheck-smoke-prefix-cache-roots [root : String]) : StringVec
  (string-vec-push (string-vec-new) root))

(define (compiler-typecheck-smoke-prefix-cache-check-cfg
  [src : String]
  [entry-path : String]
  [paths : AstDeclPathList]
  [stdlib-roots : StringVec]
  [cfgs : SymI64Env]) : bool
  (match (parse-ast-source-diagnostic-with-cfg entry-path src cfgs)
    [(OkAstProgramDiagnostic program)
      (match (typecheck-compiler-program-with-paths-cache
        program
        paths
        stdlib-roots
        (compiler-typecheck-prefix-cache-scope
          "typecheck-prefix-smoke"
          stdlib-roots
          cfgs))
        [(OkCompilerTypecheck _) true]
        [(ErrCompilerTypecheck _) false])]
    [(ErrAstProgramDiagnostic _) false]))

(define (compiler-typecheck-smoke-prefix-cache-root-isolation-ok?) : bool
  (let
    [root-a : String "target/tc_prefix_root_a"]
    [root-b : String "target/tc_prefix_root_b"]
    [entry-a : String "target/tc_prefix_root_entry_a.tl"]
    [entry-b : String "target/tc_prefix_root_entry_b.tl"]
    [roots-a : StringVec (compiler-typecheck-smoke-prefix-cache-roots root-a)]
    [roots-b : StringVec (compiler-typecheck-smoke-prefix-cache-roots root-b)]
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
      (compiler-load-session-reset-pools!)
      (compiler-load-session-reset-interns!)
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
      (compiler-load-session-reset-pools!)
      (compiler-load-session-reset-interns!)
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
    [roots : StringVec (compiler-typecheck-smoke-prefix-cache-roots root)]
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
      (compiler-load-session-reset-pools!)
      (compiler-load-session-reset-interns!)
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
      (compiler-load-session-reset-pools!)
      (compiler-load-session-reset-interns!)
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
  [stdlib-roots : StringVec]
  [cfgs : SymI64Env]) : bool
  (match (compiler-load-file-with-paths-and-roots-cfg
    entry-path
    (sym-i64-empty)
    stdlib-roots
    cfgs)
    [(OkCompilerLoadWithPaths decls paths _ _)
      (match (typecheck-compiler-program-with-paths-cache
        (ast-program decls)
        paths
        stdlib-roots
        (compiler-typecheck-prefix-cache-scope
          "typecheck-prefix-smoke"
          stdlib-roots
          cfgs))
        [(OkCompilerTypecheck _) true]
        [(ErrCompilerTypecheck _) false])]
    [(ErrCompilerLoadWithPaths _) false]))

(define (compiler-typecheck-smoke-prefix-cache-local-module-hit-ok?) : bool
  (let
    [dep : String "target/tc_prefix_local_dep.tl"]
    [entry-a : String "target/tc_prefix_local_entry_a.tl"]
    [entry-b : String "target/tc_prefix_local_entry_b.tl"]
    [roots : StringVec (string-vec-new)]
    [cfgs : SymI64Env (compiler-cfg-empty)]
    [ok : bool true]
    (begin
      (write-file
        dep
        "(module tc.prefix.local.dep)
(define (value [x : i64]) : i64 (+ x 1))
(export (value value))")
      (write-file
        entry-a
        "(import \"tc_prefix_local_dep.tl\" module tc.prefix.local.dep as dep)
(define (main) : i64 (dep.value 1))")
      (write-file
        entry-b
        "(import \"tc_prefix_local_dep.tl\" module tc.prefix.local.dep as dep)
(define (main) : i64 (dep.value 2))")
      (compiler-load-session-cache-enable!)
      (tc-prefix-snapshot-cache-clear!)
      (if (compiler-typecheck-smoke-prefix-cache-file-check entry-a roots cfgs)
        unit
        (set! ok false))
      (compiler-load-session-reset-pools!)
      (compiler-load-session-reset-interns!)
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
    [roots : StringVec (string-vec-new)]
    [cfgs : SymI64Env (compiler-cfg-empty)]
    [ok : bool true]
    (begin
      (write-file dep "(define (flat-helper [x : i64]) : i64 (+ x 1))")
      (write-file
        entry-a
        "(import \"tc_prefix_flat_dep.tl\")
(define (main) : i64 (flat-helper 1))")
      (write-file
        entry-b
        "(import \"tc_prefix_flat_dep.tl\")
(define (main) : i64 (flat-helper 2))")
      (compiler-load-session-cache-enable!)
      (tc-prefix-snapshot-cache-clear!)
      (if (compiler-typecheck-smoke-prefix-cache-file-check entry-a roots cfgs)
        unit
        (set! ok false))
      (compiler-load-session-reset-pools!)
      (compiler-load-session-reset-interns!)
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

(define (main) : i64
  (begin
    (compiler-typecheck-self-test)
    (unless
      (compiler-typecheck-reference-escape-tests-ok?)
      (panic "typecheck: reference escape tests failed"))
    (unless
      (compiler-typecheck-auto-borrow-tests-ok?)
      (panic "typecheck: auto-borrow tests failed"))
    (unless
      (compiler-typecheck-borrow-diagnostic-tests-ok?)
      (panic "typecheck: borrow diagnostic tests failed"))
    (unless
      (compiler-typecheck-move-diagnostic-tests-ok?)
      (panic "typecheck: move diagnostic tests failed"))
    (unless
      (compiler-typecheck-macro-alias-cache-collision-ok?)
      (panic "typecheck: macro alias cache collision test failed"))
    (unless
      (compiler-typecheck-smoke-module-macro-identity-tests-ok?)
      (panic "typecheck: module macro identity smoke failed"))
    (unless
      (compiler-typecheck-smoke-decl-macro-body-tests-ok?)
      (panic "typecheck: declaration macro body smoke failed"))
    (unless
      (compiler-typecheck-smoke-type-macro-param-tests-ok?)
      (panic "typecheck: type macro param smoke failed"))
    (unless
      (compiler-typecheck-smoke-prefix-cache-root-isolation-ok?)
      (panic "typecheck: prefix cache root smoke failed"))
    (unless
      (compiler-typecheck-smoke-prefix-cache-cfg-isolation-ok?)
      (panic "typecheck: prefix cache cfg smoke failed"))
    (unless
      (compiler-typecheck-smoke-prefix-cache-local-module-hit-ok?)
      (panic "typecheck: prefix cache local module smoke failed"))
    (unless
      (compiler-typecheck-smoke-prefix-cache-flat-local-no-hit-ok?)
      (panic "typecheck: prefix cache flat local smoke failed"))
    (macro-alias-cache-reset!)
    42))
