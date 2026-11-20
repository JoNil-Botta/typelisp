;; #8514: `fold` load-CSE forwarded `(ptr-read p)` across `set!` of the local `p`
;; addresses. Expected exit 42 (opt1 and opt2 exited 38).
(define (load-after-set) : i64
  (let
    [value : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of value))]
    [a : i64
      (unsafe
        (ptr-read p))]
    (begin
      (set! value 5)
      (+
        a
        (unsafe
          (ptr-read p))))))

(define (main) : i64
  (+ 36 (load-after-set)))