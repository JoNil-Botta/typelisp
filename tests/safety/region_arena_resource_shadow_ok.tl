;; A resource spelled like a colliding with-arena region shadows the arena in
;; the with body: an explicit borrow of the resource names it (#9593).
(defstruct Pt
  (x i64))

(define (drop-pt [p : Pt]) : unit
  unit)

(define (probe [p : (& r i64)]) : i64
  (with-arena
    r
    (with
      ([r (Pt 40) drop-pt])
      (let
        [y : (& r i64) (& r r.x)]
        (+ (deref y) 2)))))

(define (main) : i64
  (let
    [s : i64 1]
    (probe (& s))))