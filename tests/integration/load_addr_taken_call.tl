(define (read-hash [p : (MutPtr i64)]) : i64
  (let
    [x : i64
      (unsafe
        (ptr-read p))]
    (set! x (% (+ (* x 17) 23) 1000003))
    (set! x (% (+ (* x 17) 23) 1000003))
    x))

(define (main) : i64
  (let
    [value : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of value))]
    [before : i64 (read-hash p)]
    (set! value 5)
    (if (= (+ before (read-hash p)) 2562)
      42
      1)))