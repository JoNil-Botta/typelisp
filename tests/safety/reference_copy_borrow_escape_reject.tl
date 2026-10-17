(defstruct Wide
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(define (escape) : (& program Wide)
  (let
    [source : Wide (Wide 1 2 3 4)]
    [view : (& source Wide) (& source)]
    (& (deref view))))

(define (main) : i64
  0)