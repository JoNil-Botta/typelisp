(define resource-with-order-trace : i64
  0)

(define (resource-with-order-init [digit : i64]) : i64
  (begin
    (set! resource-with-order-trace (+ (* resource-with-order-trace 10) digit))
    digit))

(define (resource-with-order-cleanup [digit : i64]) : unit
  (set! resource-with-order-trace (+ (* resource-with-order-trace 10) digit)))

(define (main) : i64
  (begin
    (with
      ([first (resource-with-order-init 1) resource-with-order-cleanup]
        [second (resource-with-order-init 2) resource-with-order-cleanup])
      unit)
    (if (= resource-with-order-trace 1221)
      42
      1)))