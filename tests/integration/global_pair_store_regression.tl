(defstruct Cell
  (value i64))

(defstruct Pair
  (left i64)
  (right i64))

(define sink : Pair
  (Pair 7 8))

(define (replace-pair [cell : (& Cell)] [old : Pair]) : i64
  (set! sink (Pair 98 99))
  (+ cell.value (+ old.left old.right)))

(define (main) : i64
  (let
    [cell : Cell (Cell 10)]
    (replace-pair (& cell) sink)))