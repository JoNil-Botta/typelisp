;; an array element whose address is taken, rewritten through that pointer.
;; Expected exit 6 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [items : (Array i64 4) (array 41 1 1 1)]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of (array-ref items 0)))]
    (unsafe
      (ptr-write! p 5))
    (+ (array-ref items 0) (array-ref items 1))))