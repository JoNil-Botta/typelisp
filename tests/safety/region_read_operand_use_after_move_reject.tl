;; A body with a plain variable beside a region-read operand still reports a
;; real ownership error in it (#9737).
(define (read-i64 [p : (& p i64)]) : (in p i64)
  (deref p))

(define (take [s : String]) : i64
  1)

; Must fail: `s` was moved by the first call.
(define (bad [p : (& p i64)] [x : i64] [s : String]) : i64
  (let
    [a : i64 (take s)]
    (if (> (+ (read-i64 p) x) (take s))
      a
      7)))

(define (main) : i64
  (let
    [z : i64 3]
    (bad (& z) 2 "ab")))