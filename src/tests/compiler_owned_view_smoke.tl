(import compiler_owned_view as views)
(import stdlib.test)

(defstruct Payload
  (number i64)
  (items (__tl_dyn-array i64)))

(define (make-items [first : i64] [second : i64]) : (__tl_dyn-array i64)
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    (set! (array-ref items 0) first)
    (set! (array-ref items 1) second)
    items))

(define (run-checks) : i64
  (let
    [boxed : (Box Payload) (box (Payload 42 (make-items 7 9)))]
    [plain : Payload (Payload 42 (make-items 11 13))]
    [whole : Payload (views.compiler-owned-box-shared-view boxed)]
    [typed-whole : Payload
      (views.compiler-owned-typed-box-shared-view boxed Payload)]
    [boxed-items : (__tl_dyn-array i64)
      (views.compiler-owned-box-shared-view boxed items)]
    [typed-items : (__tl_dyn-array i64)
      (views.compiler-owned-typed-box-shared-view boxed Payload items)]
    [plain-ref (& plain)]
    [plain-items : (__tl_dyn-array i64)
      (views.compiler-owned-box-shared-view plain-ref items)]
    [borrowed-items : (__tl_dyn-array i64)
      (views.compiler-owned-box-shared-view (& plain) items)]
    [boxed-ref (& (deref boxed))]
    [calls : i64 0]
    [once : i64
      (views.compiler-owned-box-shared-view
        (begin
          (set! calls (+ calls 1))
          (Payload 42 (make-items 17 19)))
        number)]
    (if (and
      (= whole.number 42)
      (= typed-whole.number 42)
      (= (views.compiler-owned-box-shared-view boxed number) 42)
      (= (views.compiler-owned-box-shared-view (& plain) number) 42)
      (= (array-ref boxed-items 1) 9)
      (= (array-ref typed-items 0) 7)
      (= (array-ref plain-items 1) 13)
      (= (array-ref borrowed-items 0) 11)
      (= (array-length plain.items) 2)
      (= (array-length boxed-ref.items) 2)
      (= once 42)
      (= calls 1))
      42
      1)))

(define (main) : i64
  (run-checks))

(test
  box-view-optional-field-projection
  (test.assert-i64-eq
    (run-checks)
    42
    "whole and selected payload views preserve other fields and evaluate once"))