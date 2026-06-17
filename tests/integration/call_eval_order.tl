(define call-eval-order-trace : i64
  0)

(define (call-eval-order-mark [digit : i64]) : i64
  (begin
    (set! call-eval-order-trace (+ (* call-eval-order-trace 10) digit))
    digit))

(define (call-eval-order-sum8
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]
  [g : i64]
  [h : i64]) : i64
  (+ (+ (+ (+ (+ (+ (+ a b) c) d) e) f) g) h))

(define (call-eval-order-apply8 [fn : (-> i64 i64 i64 i64 i64 i64 i64 i64 i64)]) : i64
  (fn
    (call-eval-order-mark 1)
    (call-eval-order-mark 2)
    (call-eval-order-mark 3)
    (call-eval-order-mark 4)
    (call-eval-order-mark 5)
    (call-eval-order-mark 6)
    (call-eval-order-mark 7)
    (call-eval-order-mark 8)))

(define (call-eval-order-direct-ok?) : bool
  (begin
    (set! call-eval-order-trace 0)
    (and
      (=
        (call-eval-order-sum8
          (call-eval-order-mark 1)
          (call-eval-order-mark 2)
          (call-eval-order-mark 3)
          (call-eval-order-mark 4)
          (call-eval-order-mark 5)
          (call-eval-order-mark 6)
          (call-eval-order-mark 7)
          (call-eval-order-mark 8))
        36)
      (= call-eval-order-trace 12345678))))

(define (call-eval-order-indirect-ok?) : bool
  (begin
    (set! call-eval-order-trace 0)
    (and
      (= (call-eval-order-apply8 call-eval-order-sum8) 36)
      (= call-eval-order-trace 12345678))))

(define (main) : i64
  (if (and (call-eval-order-direct-ok?) (call-eval-order-indirect-ok?))
    42
    1))