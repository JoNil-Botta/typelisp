;; load-CSE: the pointer to v is carried in a struct field.
;; Expected exit 6 at --opt-level 0 (opt1 and opt2 exit 2 and 2 until the queued fix lands).
(defstruct Holder
  (p (MutPtr i64)))

(define (main) : i64
  (let
    [v : i64 1]
    [pv : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [h : Holder (Holder pv)]
    [a : i64
      (unsafe
        (ptr-read h.p))]
    (set! v 5)
    (let
      [b : i64
        (unsafe
          (ptr-read h.p))]
      (+ a b))))