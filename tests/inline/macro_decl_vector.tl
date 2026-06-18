;; macro_decl_vector.tl - end-to-end coverage for declaration-emitting macros
;; that generate functions with non-trivial bodies (#3193 / #3074).
;;
;; A `: Decls` macro splices a growable i64 vector family - struct plus
;; new/push/len/get/set/capacity and the capacity-doubling growth loop - into
;; this module. The generated function bodies use arithmetic, struct-get,
;; make-array, array-ref/array-set!, let, while, and set!, all of which the
;; module-scope macro-output serializer must round-trip back to declarations.
;; These inline tests build and run the generated code on the host compiler.
(import "stdlib/test.tl")

(defmacro (int-vector-family) : Decls
  `(begin
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
        (int-vec-push (int-vec-grow v) value)))))

(int-vector-family)

(define (int-vec-fill [n : i64]) : IntVec
  (let
    [v : IntVec (int-vec-new)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! v (int-vec-push v (* i i)))
          (set! i (+ i 1))))
      v)))

(test
  generated-vector-new-is-empty
  (let
    [v : IntVec (int-vec-new)]
    (begin
      (assert-i64-eq (int-vec-len v) 0 "fresh generated vector is empty")
      (assert-i64-eq (int-vec-capacity v) 4 "fresh generated vector reserves 4"))))

(test
  generated-vector-push-grows-past-capacity
  (let
    [v : IntVec (int-vec-fill 10)]
    (begin
      (assert-i64-eq
        (int-vec-len v)
        10
        "push tracks length past initial capacity")
      (assert-true
        (> (int-vec-capacity v) 4)
        "capacity doubles when pushing past the initial reservation")
      (assert-i64-eq (int-vec-get v 0) 0 "element 0 survives growth")
      (assert-i64-eq (int-vec-get v 7) 49 "element 7 survives growth")
      (assert-i64-eq (int-vec-get v 9) 81 "last element survives growth"))))

(test
  generated-vector-set-overwrites
  (let
    [v : IntVec (int-vec-set (int-vec-fill 5) 2 999)]
    (begin
      (assert-i64-eq (int-vec-get v 2) 999 "set overwrites the indexed slot")
      (assert-i64-eq (int-vec-get v 1) 1 "set leaves neighbours intact")
      (assert-i64-eq (int-vec-len v) 5 "set preserves length"))))