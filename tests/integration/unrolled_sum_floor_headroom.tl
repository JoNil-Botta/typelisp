;; A descending reduction whose literal floor sits 20 below i64 MAX: the
;; unroll guard's `floor + K` does not wrap for the sixteen-copy group but does
;; for the thirty-two-copy group private sum chains emit, so the guard must
;; keep its wrap check. Every trip count stops at the floor.
(import stdlib.io)
(import stdlib.string)

(define (down-sum [n : i64] [k : i64]) : i64
  (let
    [i : i64 (+ 9223372036854775787 n)]
    [s : i64 0]
    (begin
      (while (>= i 9223372036854775787)
        (begin
          (set! s (+ s (bit-and (bit-xor i k) 1)))
          (set! i (- i 1))))
      s)))

(define (main) : i64
  (let
    [limit : i64 (string.>int (io.arg 1))]
    [m : i64 0]
    (begin
      (while (<= m limit)
        (begin
          (io.println "{}" (down-sum m 3))
          (set! m (+ m 1))))
      42)))