;; a pointer to the whole struct, read before and after a field set!.
;; Expected exit 6 at --opt-level 0, 1 and 2.
(defstruct Pair
  (a i64)
  (b i64))

(define (main) : i64
  (let
    [s : Pair (Pair 1 7)]
    [p : (MutPtr Pair)
      (unsafe
        (ptr-addr-of s))]
    [a : Pair
      (unsafe
        (ptr-read p))]
    (set! s.a 5)
    (let
      [b : Pair
        (unsafe
          (ptr-read p))]
      (+ a.a b.a))))