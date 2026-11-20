;; an array element read through a pointer, then written by set!.
;; Expected exit 32 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [items : (Array i64 4) (array 1 7 7 7)]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of (array-ref items 0)))]
    [a : i64
      (unsafe
        (ptr-read p))]
    (set! (array-ref items 0) 5)
    (+
      36
      (-
        a
        (unsafe
          (ptr-read p))))))