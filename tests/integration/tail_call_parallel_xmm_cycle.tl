;; Direct tail calls that swap two float parameters, from a loop (`s`) and
;; from a function in a call cycle (`u`, which `h` calls back into). Kept in
;; their XMM argument registers, the two parameters would form an XMM cycle,
;; which the parallel marshalling breaks through the cycle-temp slot.
(define (g [x : f64] [y : f64] [k : i64]) : i64
  (if (> k 0)
    (cast (+ (* 3.0 x) y) : i64)
    (cast y : i64)))

(define (s [x : f64] [y : f64] [n : i64] [m : i64]) : i64
  (if (>= n m)
    (g y x n)
    (s x y (+ n 1) m)))

(define (h [x : f64] [y : f64] [k : i64]) : i64
  (if (> k 0)
    (+ 1 (u x y (- k 1)))
    (cast (+ (* 3.0 x) y) : i64)))

(define (u [x : f64] [y : f64] [k : i64]) : i64
  (h y x k))

;; g(10.0, 12.0, 3) = 30 + 12 = 42.
;; u(12, 10, 2) -> h(10, 12, 2) -> 1 + u(10, 12, 1) -> h(12, 10, 1)
;;   -> 1 + u(12, 10, 0) -> h(10, 12, 0) = 42, so 44 in all.
(define (main) : i64
  (if (= (u 12.0 10.0 2) 44)
    (s 12.0 10.0 0 3)
    1))