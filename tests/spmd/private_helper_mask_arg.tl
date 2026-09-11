;; A private helper receives the active mask and all five varying bool masks.
;; Their independently allocated homes can require a nontrivial entry move.
(define (heavy-store
  [out : (&mut out (__tl_dyn-array i64))]
  [i : i64]
  [take0 : bool]
  [take1 : bool]
  [take2 : bool]
  [take3 : bool]
  [take4 : bool]) : unit
  (if (and take0 take1 take2 take3 take4)
    (set! (array-ref out i) (+ (+ (+ (+ (+ (+ (+ i 1) 2) 3) 4) 5) 6) 7))
    (set! (array-ref out i) (- (- (- (- (- (- (- i 1) 2) 3) 4) 5) 6) 7))))

(define (fill [out : (&mut out (__tl_dyn-array i64))] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (heavy-store out i (< i 7) (= (% i 3) 0) (< i 12) (!= i 5) (>= i 0))))

(define (sum-array [xs : (& xs (__tl_dyn-array i64))] [n : i64]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! sum (+ sum (array-ref xs i)))
          (set! i (+ i 1))))
      sum)))

(define (main) : i64
  (let
    [n : i64 13]
    [out : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    (begin
      (fill (&mut out) n)
      (if (= (sum-array (& out) n) -118)
        42
        1))))