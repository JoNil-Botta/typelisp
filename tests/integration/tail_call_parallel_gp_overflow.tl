;; A direct tail call whose register arguments mix swap cycles with a chain,
;; and whose overflow argument is read out of a parameter register. On System V
;; `fin`'s fifth argument (%r8) comes from the caller's tenth parameter (a stack
;; slot) while the caller's fifth (%r8) moves on to `fin`'s sixth (%r9), and
;; `fin`'s seventh (a stack slot) is read from the caller's %r9. An overflow
;; argument read from a register has to be stored before that register is
;; overwritten. Every value is distinct and every argument has its own weight.
(define (fin
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]
  [g : i64]
  [h : i64]
  [i : i64]
  [j : i64]) : i64
  (if (> a 0)
    (+
      a
      (+
        (* 11 b)
        (+
          (* 121 c)
          (+
            (* 1331 d)
            (+
              (* 14641 e)
              (+
                (* 161051 f)
                (+
                  (* 1771561 g)
                  (+ (* 19487171 h) (+ (* 214358881 i) (* 2357947691 j))))))))))
    0))

(define (step
  [p0 : i64]
  [p1 : i64]
  [p2 : i64]
  [p3 : i64]
  [p4 : i64]
  [p5 : i64]
  [p6 : i64]
  [p7 : i64]
  [p8 : i64]
  [p9 : i64]
  [n : i64]
  [m : i64]) : i64
  (if (>= n m)
    (fin p1 p0 p3 p2 p9 p4 p5 p6 p7 p8)
    (step p0 p1 p2 p3 p4 p5 p6 p7 p8 p9 (+ n 1) m)))

;; fin sees a..j = 2 1 4 3 10 5 6 7 8 9, as base-11 digits.
(define (main) : i64
  (let
    [r : i64 (step 1 2 3 4 5 6 7 8 9 10 0 3)]
    [want : i64
      (+
        2
        (+
          (* 11 1)
          (+
            (* 121 4)
            (+
              (* 1331 3)
              (+
                (* 14641 10)
                (+
                  (* 161051 5)
                  (+
                    (* 1771561 6)
                    (+ (* 19487171 7) (+ (* 214358881 8) (* 2357947691 9))))))))))]
    (if (= r want)
      42
      (+ 100 (% r 100)))))