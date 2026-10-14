;; A direct tail call of ten floats whose register arguments are a permutation
;; of the caller's (two swaps and a chain) and whose float overflow comes from
;; both a register argument and a stack argument of the caller. Every value is
;; distinct and every argument has its own weight, so any lost or swapped
;; argument changes the result.
;;
;; `fin` calls back into `step` (not in tail position), so neither is inlined,
;; and its parameters stay live across that call.
(define (fin
  [a : f64]
  [b : f64]
  [c : f64]
  [d : f64]
  [e : f64]
  [f : f64]
  [g : f64]
  [h : f64]
  [i : f64]
  [j : f64]
  [k : i64]) : i64
  (if (> k 0)
    (+
      (step a b c d e f g h i j (- k 1))
      (if (> (+ a (+ b (+ c (+ d (+ e (+ f (+ g (+ h (+ i j))))))))) 1000.0)
        1
        0))
    (let
      [sum : f64
        (+
          a
          (+
            (* 11.0 b)
            (+
              (* 121.0 c)
              (+
                (* 1331.0 d)
                (+
                  (* 14641.0 e)
                  (+
                    (* 161051.0 f)
                    (+
                      (* 1771561.0 g)
                      (+
                        (* 19487171.0 h)
                        (+ (* 214358881.0 i) (* 2357947691.0 j))))))))))]
      [want : f64
        (+
          2.0
          (+
            (* 11.0 1.0)
            (+
              (* 121.0 4.0)
              (+
                (* 1331.0 3.0)
                (+
                  (* 14641.0 10.0)
                  (+
                    (* 161051.0 5.0)
                    (+
                      (* 1771561.0 6.0)
                      (+
                        (* 19487171.0 7.0)
                        (+ (* 214358881.0 8.0) (* 2357947691.0 9.0))))))))))]
      (if (= sum want)
        42
        (+ 100 (% (cast sum : i64) 100))))))

(define (step
  [p0 : f64]
  [p1 : f64]
  [p2 : f64]
  [p3 : f64]
  [p4 : f64]
  [p5 : f64]
  [p6 : f64]
  [p7 : f64]
  [p8 : f64]
  [p9 : f64]
  [k : i64]) : i64
  (fin p1 p0 p3 p2 p9 p4 p5 p6 p7 p8 k))

;; fin sees a..j = 2 1 4 3 10 5 6 7 8 9.
(define (main) : i64
  (step 1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 9.0 10.0 0))