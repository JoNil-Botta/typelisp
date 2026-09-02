;; The freestanding entries give `main` the same 1 GiB private stack on Linux
;; and Windows. Each non-tail-recursive frame keeps an 8 KiB fixed array live
;; across the child call. With the current self-hosted backend's spill slots,
;; depth 14,000 commits about 330 MiB: it clears the private stack but overflows
;; the former 256 MiB Windows PE entry stack.
(define (main-private-stack-depth [depth : i64]) : i64
  (let
    [page : (Array i64 1024) (make-array i64 1024)]
    [index : i64 (bit-and depth 1023)]
    (begin
      (set! (array-ref page index) depth)
      (if (= depth 0)
        (array-ref page index)
        (+ (main-private-stack-depth (- depth 1)) (array-ref page index))))))

(define (main) : i64
  (if (= (main-private-stack-depth 14000) 98007000)
    42
    1))