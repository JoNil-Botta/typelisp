;; a struct field read through a pointer, then written by set!, then read again.
;; Expected exit 32 at --opt-level 0, 1 and 2.
(defstruct Pair
  (a i64)
  (b i64))

(define (main) : i64
  (let
    [s : Pair (Pair 1 7)]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of s.a))]
    [a : i64
      (unsafe
        (ptr-read p))]
    (set! s.a 5)
    (+
      36
      (-
        a
        (unsafe
          (ptr-read p))))))