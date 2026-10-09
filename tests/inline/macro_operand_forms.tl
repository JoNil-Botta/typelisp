;; Expression macro expansion must recurse through every operand of
;; `__tl_array-push!`, `tuple-ref` and the SPMD forms, and expand an SPMD body
;; with the form's binders in scope (#8497).
(import stdlib.test)

(defmacro (operand [value : Expr]) : Expr
  value)

;; 1 when `place` has type i64, else 0. It asks for the operand's type, so it
;; only expands where every name in `place` is bound.
(defmacro (i64-code [place : Expr]) : i64
  (if (__tl_string_eq (type-kind (expr-type place)) "i64")
    (expr-int 1)
    (expr-int 0)))

(define (pair) : (Tuple i64 i64)
  (tuple 42 1))

(define (fill [xs : (&mut xs (__tl_dyn-array i64))] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (set! (array-ref xs i) (+ i 1))
      (set! i (+ i 1)))))

(test
  macro-expands-in-array-push-operands
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    (__tl_array-push! (operand items) (operand 42))
    (__tl_array-push! items (i64-code (array-ref items 0)))
    (test.assert-i64-eq (array-length items) 2 "both pushes ran")
    (test.assert-i64-eq (array-ref items 0) 42 "pushed value expands")
    (test.assert-i64-eq
      (array-ref items 1)
      1
      "a type-aware macro sees the buffer element")))

(test
  macro-expands-in-tuple-ref-operand
  (test.assert-i64-eq
    (tuple-ref (operand (pair)) 0)
    42
    "tuple-ref expands its tuple operand")
  (test.assert-i64-eq
    (tuple-ref (operand (operand (pair))) 1)
    1
    "nested macro calls expand"))

(test
  macro-expands-in-spmd-reduce
  (let
    [xs : (__tl_dyn-array i64) (__tl_make-array i64 8)]
    (fill (&mut xs) 8)
    (test.assert-i64-eq
      (spmd-reduce
        sum
        ([i : i64 (operand 0) (operand 8)])
        (operand 0)
        (+ (operand (array-ref xs i)) (i64-code i)))
      44
      "range, initial value and value expand; the index is in scope")))

(test
  macro-expands-in-spmd-scan
  (let
    [xs : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    [out : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    (fill (&mut xs) 4)
    (spmd-scan
      sum
      ([i : i64 (operand 0) (operand 4)] [prefix : i64 (operand 10)])
      (+ (operand (array-ref xs i)) (i64-code i))
      (set! (array-ref out i) (+ prefix (i64-code prefix))))
    ;; An inclusive scan of the values 2, 3, 4, 5 from 10.
    (test.assert-i64-eq (array-ref out 0) 13 "range and initial value expand")
    (test.assert-i64-eq
      (array-ref out 3)
      25
      "value and body expand; index and prefix are in scope")))

(test
  macro-expands-in-spmd-compact
  (let
    [out : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    (spmd-compact
      ([i : i64 (operand 0) (operand 4)] [slot : i64 (operand 0)])
      (operand (= (i64-code i) 1))
      (set! (array-ref out slot) (+ i (i64-code slot))))
    (test.assert-i64-eq (array-ref out 0) 1 "first selected lane")
    (test.assert-i64-eq
      (array-ref out 3)
      4
      "predicate and body expand; index and slot are in scope")))

(test
  macro-expands-in-spmd-broadcast-and-shuffle
  (let
    [xs : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    [broadcast : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    [shuffled : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    (fill (&mut xs) 4)
    (foreach
      ([i : i64 0 4])
      (begin
        (set!
          (array-ref broadcast i)
          (spmd-broadcast (operand (array-ref xs i)) (operand 0)))
        (set!
          (array-ref shuffled i)
          (spmd-shuffle (operand (array-ref xs i)) (operand (- i i))))))
    ;; Iteration 0 is lane 0 of its gang at every gang width.
    (test.assert-i64-eq (array-ref broadcast 0) 1 "broadcast expands")
    (test.assert-i64-eq (array-ref shuffled 0) 1 "shuffle expands")))