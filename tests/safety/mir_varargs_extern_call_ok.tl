;; A call to a C variadic extern is checked against its signature expanded to
;; the call's arity: each trailing argument is read at its own type (an open
;; tail) or the declared one (`...T`) (#8449 M5). Check-only: the extern is not
;; linked.
(extern (sumf [count : i64] ...) : i32 (:symbol "sumf"))

(define (total [a : f64] [b : f64]) : i64
  (+ (cast (sumf 2 a b) : i64) (cast (sumf 0) : i64)))

(define (main) : i64
  42)