(defstruct Cell
  (value i64)
  (b i64)
  (c i64)
  (d i64))

(define g : Cell
  (Cell 7 0 0 0))

(define (touch! [local : (& r Cell)] [copied : Cell]) : i64
  (begin
    (set! g (Cell 9 0 0 0))
    (+ local.value copied.value)))

(define (main) : i64
  (let
    [local : Cell (Cell 10 0 0 0)]
    (touch! (& local) g)))