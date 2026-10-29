(defstruct Cell
  (value i64))

(define (read [cell : (& keep Cell)]) : i64
  (let
    [get
      (lambda () : i64
        cell.value)]
    [alias get]
    (+ (get) (alias))))

(define (main) : i64
  (let
    [cell (Cell 21)]
    (read (& cell))))