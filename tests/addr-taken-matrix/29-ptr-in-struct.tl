;; the address-taken local's pointer is carried in a struct field.
;; Expected exit 6 at --opt-level 0, 1 and 2.
(defstruct Holder
  (p (MutPtr i64)))

(define (main) : i64
  (let
    [v : i64 41]
    [pv : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [h : Holder (Holder pv)]
    (unsafe
      (ptr-write! h.p 5))
    (+ 1 v)))