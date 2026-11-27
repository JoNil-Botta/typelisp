;; #7962: borrowing an outer `(in outer String)` inside `with-arena inner`
;; takes the address of `s`'s outer frame slot rather than allocating a
;; 16-byte descriptor in `inner`, so `r` remains valid after `inner` exits.
(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [outer (arena.make)]
    [s (in-arena outer (string.copy "world"))]
    [r : (& outer str) (with-arena inner (& s))]
    [_clobber : i64
      (with-arena
        junk
        (let
          [a (string.copy "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")]
          [b (string.copy "yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy")]
          (+ (string.string-length (& a)) (string.string-length (& b)))))]
    (if (and (= (string.string-length r) 5) (string.eq r "world"))
      42
      1)))