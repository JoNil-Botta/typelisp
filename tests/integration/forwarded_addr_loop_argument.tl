;; An explicit source snapshot isolates address materialization from lowering.
(define (first [a : i64] [_b : i64]) : i64
  a)

(define (write-99! [p : (MutPtr i64)]) : i64
  (unsafe
    (ptr-write! p 99))
  0)

(define (main) : i64
  (let
    [x : i64 1]
    [y : i64 0]
    [q : (MutPtr i64)
      (unsafe
        (ptr-addr-of y))]
    [arg : i64 0]
    [i : i64 0]
    (while (< i 2)
      (when
        (= i 1)
        (let
          [snapshot : i64 x]
          (set! arg (first snapshot (write-99! q)))))
      (set!
        q
        (unsafe
          (ptr-addr-of x)))
      (+= i 1))
    arg))