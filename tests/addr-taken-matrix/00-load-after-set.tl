;; Expected exit 42 at --opt-level 0 (opt1 and opt2 exit 38 and 38 until the queued fix lands).
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