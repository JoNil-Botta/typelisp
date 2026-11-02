;; A scalar read result keeps no reference to the temporary call borrow (#8897).
(define (read [place : (&mut place i64)]) : i64
  (deref place))

(define (main) : i64
  (let
    [value : i64 41]
    [snapshot : i64 (read (&mut value))]
    (set! value (+ value 1))
    (if (and (= snapshot 41) (= value 42))
      42
      1)))