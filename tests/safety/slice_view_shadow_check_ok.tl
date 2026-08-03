;; A source-defined value named slice-view must remain an ordinary call.
(define (slice-view [x : i64] [y : i64] [z : i64]) : i64
  (+ x (+ y z)))

(define (main) : i64
  (slice-view 1 2 3))