;; backend reload elision: the address-taken accumulator must be reloaded from
;; its slot after every call inside the loop.
;; Expected exit 42 at --opt-level 0, 1 and 2.
(define (bump [p : (MutPtr i64)])
  (unsafe
    (ptr-write!
      p
      (+
        (unsafe
          (ptr-read p))
        1))))

(define (main) : i64
  (let
    [acc : i64 0]
    [pa : (MutPtr i64)
      (unsafe
        (ptr-addr-of acc))]
    [i : i64 0]
    (while (< i 3)
      (bump pa)
      (set! i (+ i 1)))
    (+ acc 39)))