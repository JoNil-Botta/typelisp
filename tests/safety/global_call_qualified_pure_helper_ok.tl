(import stdlib.hash)

(defstruct Big
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(define g : Big
  (Big 1 2 3 4))

(define (write!) : unit
  (set! g (Big 9 9 9 9)))

(define (read [r : (& r Big)]) : i64
  (hash.combine r.a 0))

(define (main) : i64
  (let
    [f : (-> unit) write!]
    (read (& g))))