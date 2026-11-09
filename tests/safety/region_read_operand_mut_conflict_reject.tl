;; A body with a plain variable beside a region-read operand still reports a
;; real borrow error in it (#9737); `bump`'s own two arguments conflict here.
(define (read-i64 [p : (& p i64)]) : (in p i64)
  (deref p))

(define (bump [m : (&mut m i64)] [r : (& r i64)]) : i64
  1)

(define (bad [x : i64]) : i64
  (let
    [z : i64 3]
    ; Must fail: `z` is borrowed shared by the same call.
    (if (> (+ (read-i64 (& z)) x) (bump (&mut z) (& z)))
      42
      7)))

(define (main) : i64
  (bad 2))