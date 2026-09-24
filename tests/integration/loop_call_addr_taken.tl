;; A read-only callee inside a loop must not be cached across a redefinition
;; of a local whose address the loop's pointer argument holds: before SSA the
;; `set!` is a plain move, but it writes the slot `ptr-read` reads.
(import stdlib.io)

(define (read-ptr [p : (MutPtr i64)] [k : i64]) : i64
  (let
    [i : i64 0]
    [total : i64 0]
    (begin
      (while (< i 8)
        (begin
          (set! total (+ total (* i k)))
          (set! i (+ i 1))))
      (+
        total
        (unsafe
          (ptr-read p))))))

(define (read-ptr0 [p : (MutPtr i64)]) : i64
  (let
    [i : i64 0]
    [total : i64 0]
    (begin
      (while (< i 8)
        (begin
          (set! total (+ total (* i i)))
          (set! i (+ i 1))))
      (+
        total
        (unsafe
          (ptr-read p))))))

(define (with-literal) : i64
  (let
    [x : i64 0]
    [total : i64 0]
    [i : i64 0]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of x))]
    (begin
      (while (< i 3)
        (begin
          (set! x (+ x 1))
          (set! total (+ total (read-ptr p 7)))
          (set! i (+ i 1))))
      total)))

(define (without-literal) : i64
  (let
    [x : i64 0]
    [total : i64 0]
    [i : i64 0]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of x))]
    (begin
      (while (< i 8)
        (begin
          (set! x (+ x 1))
          (set! total (+ total (read-ptr0 p)))
          (set! i (+ i 1))))
      total)))

(define (main) : i64
  (begin
    (io.println "{}" (with-literal))
    (io.println "{}" (without-literal))
    0))