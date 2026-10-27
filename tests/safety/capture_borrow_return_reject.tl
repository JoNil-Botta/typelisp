;; A lambda returns a borrow of its by-value capture `x` under the enclosing
;; binding's lifetime. The capture is the lambda's own copy, which ends with
;; the call (#9297).
(define (scrub [r : (& i64)] [seed : i64]) : i64
  (let
    [a : (Array i64 32)
      (array 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)]
    [i : i64 0]
    (while (< i 32)
      (set! (array-ref a i) (+ seed i))
      (set! i (+ i 1)))
    (+ (deref r) (- (array-ref a (% seed 32)) (array-ref a (% seed 32))))))

(define (main) : i64
  (let
    [x : i64 42]
    ; Must fail: `(& x)` borrows the lambda's copy of `x`.
    [f
      (lambda () : (& x i64)
        (& x))]
    [r : (& x i64) (f)]
    (scrub r 100)))