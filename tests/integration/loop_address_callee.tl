(define (inc [x : i64]) : i64
  (+ x 1))

(define (dec [x : i64]) : i64
  (- x 1))

(define (write-dec! [p : (MutPtr (-> i64 i64))]) : i64
  (unsafe
    (ptr-write! p dec))
  41)

(define (main) : i64
  (let
    [f inc]
    [g dec]
    [p : (MutPtr (-> i64 i64))
      (unsafe
        (ptr-addr-of g))]
    [callee : i64 0]
    [i : i64 0]
    (while (< i 2)
      (when (= i 1) (set! callee (f (write-dec! p))))
      (set!
        p
        (unsafe
          (ptr-addr-of f)))
      (+= i 1))
    callee))