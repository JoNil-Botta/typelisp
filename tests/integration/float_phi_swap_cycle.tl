(import stdlib.io)

;; Cover float loop-backedge parallel moves. The iteration count is
;; runtime-derived so the optimizer cannot fold either loop.
(define (rotate-f32 [steps : i64]) : bool
  (let
    [a : f32 1.0]
    [b : f32 2.0]
    [c : f32 3.0]
    [i : i64 0]
    (begin
      (while (< i steps)
        (let
          [old-a : f32 a]
          (begin
            (set! a b)
            (set! b c)
            (set! c old-a)
            (set! i (+ i 1)))))
      (let
        [phase : i64 (% steps 3)]
        (if (= phase 0)
          (and (= a 1.0) (= b 2.0) (= c 3.0))
          (if (= phase 1)
            (and (= a 2.0) (= b 3.0) (= c 1.0))
            (and (= a 3.0) (= b 1.0) (= c 2.0))))))))

(define (swap-f64 [steps : i64]) : bool
  (let
    [a : f64 4.0]
    [b : f64 9.0]
    [i : i64 0]
    (begin
      (while (< i steps)
        (let
          [old-a : f64 a]
          (begin
            (set! a b)
            (set! b old-a)
            (set! i (+ i 1)))))
      (if (= (% steps 2) 0)
        (and (= a 4.0) (= b 9.0))
        (and (= a 9.0) (= b 4.0))))))

(define (main) : i64
  (let
    [steps : i64 (+ (io.arg-count) 1)]
    (if (and (rotate-f32 steps) (swap-f64 steps))
      42
      1)))