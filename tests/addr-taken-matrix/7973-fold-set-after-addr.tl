;; #7973: `fold` forwarded the address-taken local's value across `set!` and a call.
;; Expected exit 42 (opt1 and opt2 exited 40).
(define (write-seven [p : (MutPtr i64)] [depth : i64]) : i32
  (if (> depth 0)
    (write-seven p (- depth 1))
    (begin
      (unsafe
        (ptr-write! p 7))
      (cast 1 : i32))))

(define (p-set-after-addr [depth : i64]) : i64
  (let
    [value : i64 0]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of value))]
    (begin
      (set! value 5)
      (write-seven p depth)
      value)))

(define (main) : i64
  (+ 35 (p-set-after-addr 3)))