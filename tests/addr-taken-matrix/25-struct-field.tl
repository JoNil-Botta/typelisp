;; a struct field whose address is taken, rewritten through that pointer.
;; Expected exit 12 at --opt-level 0, 1 and 2.
(defstruct Pair
  (a i64)
  (b i64))

(define (main) : i64
  (let
    [s : Pair (Pair 41 7)]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of s.a))]
    (unsafe
      (ptr-write! p 5))
    (+ s.a s.b)))