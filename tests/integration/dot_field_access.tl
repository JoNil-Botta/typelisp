;; #2610: dotted field access is struct-get sugar when the leading segment is a
;; local binding. Reads, writes, nested fields, and borrows share the existing
;; struct-get/place machinery.
(defstruct Pair
  (x i64)
  (y i64))

(defstruct Outer
  (p Pair)
  (z i64))

(define (dot-read) : i64
  (let
    [p : Pair (Pair 10 20)]
    (+ p.x p.y)))

(define (dot-write) : i64
  (let
    [p : Pair (Pair 1 2)]
    (begin
      (set! p.x 17)
      (set! p.y 25)
      (+ p.x p.y))))

(define (dot-chain) : i64
  (let
    [o : Outer (Outer (Pair 5 6) 30)]
    (begin
      (set! o.p.y 12)
      (+ o.p.x (+ o.p.y o.z)))))

(define (take-field [_r : (& n i64)]) : i64
  5)

(define (dot-borrow) : i64
  (let
    [p : Pair (Pair 1 2)]
    (take-field (& p.x))))

(define (main) : i64
  (- (+ (dot-read) (+ (dot-write) (+ (dot-chain) (dot-borrow)))) 124))