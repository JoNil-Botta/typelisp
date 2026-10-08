;; Prelude `+=` and `-=` update variables, field paths and compound places,
;; evaluating a compound place's operands (here an array index) exactly once.
;; `main` returns 42 only when every update lands once.
(defstruct Stats
  (count i64)
  (items (__tl_dyn-array i64)))

(define index-evaluations : i64
  0)

(define (counted-index [value : i64]) : i64
  (begin
    (+= index-evaluations 1)
    value))

(define (bump-cell [cell : (&mut cell i64)]) : unit
  (+= (deref cell) 5))

(define (shrink-stats [stats : (&mut stats Stats)]) : unit
  (begin
    (-= stats.count 2)
    (-= (array-ref stats.items (counted-index 2)) 4)))

(define (main) : i64
  (let
    [total : i64 1]
    [ratio : f64 1.5]
    [stats : Stats (Stats 0 (__tl_make-array i64 4))]
    (begin
      (+= total 10)
      (-= total 1)
      (bump-cell (&mut total))
      (+= ratio 0.5)
      (+= stats.count 7)
      (+= (array-ref stats.items (counted-index 1)) 9)
      (-= (array-ref stats.items (counted-index 1)) 3)
      (shrink-stats (&mut stats))
      (cond
        [(not (= total 15)) 1]
        [(not (= ratio 2.0)) 2]
        [(not (= stats.count 5)) 3]
        [(not (= (array-ref stats.items 1) 6)) 4]
        [(not (= (array-ref stats.items 2) -4)) 5]
        [(not (= index-evaluations 3)) 6]
        [else 42]))))