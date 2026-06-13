;; #2805: two 16-byte register-group values swap across a loop back-edge.
;; The phi-copy cycle breaker must save and restore both words; saving only
;; word0 makes one `y` payload duplicate and changes the final checksum.
(defstruct Pair
  (x i64)
  (y i64))

(define (copy-pair [p : (& p Pair)]) : Pair
  (Pair (struct-get p x) (struct-get p y)))

(define (swap-sum [n : i64]) : i64
  (let
    [a : Pair (Pair 1 17)]
    [b : Pair (Pair 2 25)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (let
            [tmp : Pair (copy-pair (& a))]
            (begin
              (set! a (copy-pair (& b)))
              (set! b tmp)))
          (set! i (+ i 1))))
      (+ (struct-get a y) (struct-get b y)))))

(define (main) : i64
  (swap-sum 5))