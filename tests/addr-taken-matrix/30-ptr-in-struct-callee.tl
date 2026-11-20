;; a callee reads the pointer out of a struct field and stores through it.
;; Expected exit 6 at --opt-level 0, 1 and 2.
(defstruct Holder
  (p (MutPtr i64)))

(define (store5h [h : Holder])
  (unsafe
    (ptr-write! h.p 5)))

(define (main) : i64
  (let
    [v : i64 41]
    [pv : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [h : Holder (Holder pv)]
    (store5h h)
    (+ 1 v)))