;; A `set!` of an address-taken local is a store to it, so a load through its
;; address after the `set!` reads the new value: fold's load-CSE forwarded the
;; first `(ptr-read p)` across it (#8514). Exits 42; opt1 and opt2 exited 38.
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