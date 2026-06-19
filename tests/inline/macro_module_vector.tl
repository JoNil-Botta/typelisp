;; macro_module_vector.tl - end-to-end coverage for module-emitting macros
;; that generate runnable functions with private helper calls (#3302).
;;
;; A `: Module` macro emits a growable i64 vector family, then this file imports
;; it with an alias. The generated module exports only the public API; `new`
;; calls the private `with-capacity` helper, and `push` calls the private
;; `grow` helper. Lowering must therefore keep and resolve generated module
;; bodies, including private unqualified helper calls inside the generated
;; module, rather than pruning those bodies after typecheck succeeds.
(import "stdlib/test.tl")

(defmacro (int-vector-module) : Module
  `(begin
    (module generated.intvec)
    (defstruct IntVec
      (slots (Array i64))
      (len i64)
      (cap i64))
    (define (int-vec-with-capacity [cap : i64]) : IntVec
      (let
        [c : i64
          (if (< cap 1)
            1
            cap)]
        (IntVec (make-array i64 c) 0 c)))
    (define (int-vec-new) : IntVec
      (int-vec-with-capacity 4))
    (define (int-vec-len [v : IntVec]) : i64
      (struct-get v len))
    (define (int-vec-capacity [v : IntVec]) : i64
      (struct-get v cap))
    (define (int-vec-get [v : IntVec] [index : i64]) : i64
      (array-ref (struct-get v slots) index))
    (define (int-vec-set [v : IntVec] [index : i64] [value : i64]) : IntVec
      (begin
        (array-set! (struct-get v slots) index value)
        v))
    (define (int-vec-grow [v : IntVec]) : IntVec
      (let
        [old-cap : i64 (struct-get v cap)]
        [new-cap : i64 (* old-cap 2)]
        [bigger : (Array i64) (make-array i64 new-cap)]
        [n : i64 (struct-get v len)]
        [i : i64 0]
        (begin
          (while (< i n)
            (begin
              (array-set! bigger i (array-ref (struct-get v slots) i))
              (set! i (+ i 1))))
          (IntVec bigger n new-cap))))
    (define (int-vec-push [v : IntVec] [value : i64]) : IntVec
      (if (< (struct-get v len) (struct-get v cap))
        (let
          [slots : (Array i64) (struct-get v slots)]
          (begin
            (array-set! slots (struct-get v len) value)
            (IntVec slots (+ (struct-get v len) 1) (struct-get v cap))))
        (int-vec-push (int-vec-grow v) value)))
    (define (int-vec-fixed-array-probe) : i64
      (let
        [items : (Array i64 3) (array 2 4 6)]
        (array-ref items 2)))
    (define (int-vec-scalar-probe-score [value : i64]) : i64
      (match value
        [0 10]
        [1 20]
        [_ 30]))
    (export (type IntVec))
    (export (constructor IntVec))
    (export (value int-vec-new))
    (export (value int-vec-len))
    (export (value int-vec-capacity))
    (export (value int-vec-get))
    (export (value int-vec-set))
    (export (value int-vec-push))
    (export (value int-vec-fixed-array-probe))
    (export (value int-vec-scalar-probe-score))))

(import (int-vector-module) as iv)

(define (int-vec-fill [n : i64]) : iv.IntVec
  (let
    [v : iv.IntVec (iv.int-vec-new)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! v (iv.int-vec-push v (* i i)))
          (set! i (+ i 1))))
      v)))

(test
  generated-module-vector-new-is-empty
  (let
    [v : iv.IntVec (iv.int-vec-new)]
    (begin
      (assert-i64-eq (iv.int-vec-len v) 0 "fresh generated vector is empty")
      (assert-i64-eq
        (iv.int-vec-capacity v)
        4
        "fresh generated vector reserves 4"))))

(test
  generated-module-vector-push-grows-past-capacity
  (let
    [v : iv.IntVec (int-vec-fill 10)]
    (begin
      (assert-i64-eq
        (iv.int-vec-len v)
        10
        "push tracks length past initial capacity")
      (assert-true
        (> (iv.int-vec-capacity v) 4)
        "capacity doubles when pushing past the initial reservation")
      (assert-i64-eq (iv.int-vec-get v 0) 0 "element 0 survives growth")
      (assert-i64-eq (iv.int-vec-get v 7) 49 "element 7 survives growth")
      (assert-i64-eq (iv.int-vec-get v 9) 81 "last element survives growth"))))

(test
  generated-module-vector-set-overwrites
  (let
    [v : iv.IntVec (iv.int-vec-set (int-vec-fill 5) 2 999)]
    (begin
      (assert-i64-eq (iv.int-vec-get v 2) 999 "set overwrites the indexed slot")
      (assert-i64-eq (iv.int-vec-get v 1) 1 "set leaves neighbours intact")
      (assert-i64-eq (iv.int-vec-len v) 5 "set preserves length"))))

(test
  generated-module-vector-extra-body-forms-round-trip
  (begin
    (assert-i64-eq
      (iv.int-vec-fixed-array-probe)
      6
      "generated typed fixed array binding round-trips")
    (assert-i64-eq
      (iv.int-vec-scalar-probe-score 0)
      10
      "generated scalar match handles literal pattern")
    (assert-i64-eq
      (iv.int-vec-scalar-probe-score 2)
      30
      "generated scalar match handles wildcard pattern")))