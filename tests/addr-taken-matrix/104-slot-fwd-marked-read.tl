;; The nested constructor returns a field through a result slot. The other
;; field captures the local between its two pointer stores. Expected exit 42.
(defstruct Pair
  (first i64)
  (second i64))

(defstruct Result
  (pair Pair)
  (captured i64))

(define (make-pair [n : i64]) : Pair
  (Pair n (+ n 1)))

(define (make-result [n : i64]) : Result
  (let
    [v : i64 0]
    [p
      (unsafe
        (ptr-addr-of v))]
    [pair (make-pair n)]
    (unsafe
      (ptr-write! (ptr-offset p 0) 1))
    (let
      [x (+ v 0)]
      (unsafe
        (ptr-write! (ptr-offset p 0) 2))
      (Result pair x))))

(define (main) : i64
  (let
    [result (make-result 40)]
    (+ result.pair.second result.captured)))