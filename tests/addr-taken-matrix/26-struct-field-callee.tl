;; a struct field rewritten by a callee handed &s.a.
;; Expected exit 12 at --opt-level 0, 1 and 2.
(defstruct Pair
  (a i64)
  (b i64))

(define (store5 [p : (MutPtr i64)])
  (unsafe
    (ptr-write! p 5)))

(define (main) : i64
  (let
    [s : Pair (Pair 41 7)]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of s.a))]
    (store5 p)
    (+ s.a s.b)))