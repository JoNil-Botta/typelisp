;; an array element rewritten by a callee handed &items[0].
;; Expected exit 6 at --opt-level 0, 1 and 2.
(define (store5 [p : (MutPtr i64)])
  (unsafe
    (ptr-write! p 5)))

(define (main) : i64
  (let
    [items : (Array i64 4) (array 41 1 1 1)]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of (array-ref items 0)))]
    (store5 p)
    (+ (array-ref items 0) (array-ref items 1))))