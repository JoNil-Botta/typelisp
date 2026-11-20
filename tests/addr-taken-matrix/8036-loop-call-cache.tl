;; #8036: the loop call cache reused a read-only call across a loop `set!` of an
;; address-taken local. Expected exit 132 (prints 1156; 1156 & 0xff); opt2 was 1128.
(define (read-ptr0 [p : (MutPtr i64)]) : i64
  (let
    [i : i64 0]
    [total : i64 0]
    (while (< i 8)
      (set! total (+ total (* i i)))
      (set! i (+ i 1)))
    (+
      total
      (unsafe
        (ptr-read p)))))

(define (main) : i64
  (let
    [x : i64 0]
    [total : i64 0]
    [i : i64 0]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of x))]
    (while (< i 8)
      (set! x (+ x 1))
      (set! total (+ total (read-ptr0 p)))
      (set! i (+ i 1)))
    total))