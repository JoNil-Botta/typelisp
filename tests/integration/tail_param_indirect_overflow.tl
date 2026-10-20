;; A closure environment, GP/FP cycles and stack overflow share one call.
(define (finish
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]
  [g : i64]
  [h : i64]
  [x : f64]
  [y : f64]) : i64
  (if (> a 0)
    (+
      (* 2 a)
      (+
        (* 3 b)
        (+
          (* 5 c)
          (+
            (* 7 d)
            (+
              (* 11 e)
              (+
                (* 13 f)
                (+
                  (* 17 g)
                  (+ (* 19 h) (+ (* 3 (cast x : i64)) (cast y : i64))))))))))
    (+ b c)))

(define (step
  [callback : (-> i64 i64 i64 i64 i64 i64 i64 i64 f64 f64 i64)]
  [a : i64]
  [n : i64]
  [limit : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]
  [g : i64]
  [h : i64]
  [x : f64]
  [y : f64]) : i64
  (if (>= n limit)
    (callback b c d e a f g h y x)
    (step callback a (+ n 1) limit b c d e f g h x y)))

(define (main) : i64
  (- (step finish 5 0 3 1 2 3 4 6 7 8 9.0 11.0) 455))