;; (deref p).field reads across a set! of the field.
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
    [a : i64
      (unsafe
        (deref p).a)]
    (set! s.a 5)
    (let
      [b : i64
        (unsafe
          (deref p).a)]
      (+ a b))))