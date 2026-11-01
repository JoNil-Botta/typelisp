;: Reads and writes through references and a local reference, and a comptime
;: value, are checked as places through the reference's loan.
(defstruct Pt
  (x i64)
  (y i64))

(define (read-through [value : (& value i64)]) : i64
  (+ (deref value) 1))

(define (write-through [value : (&mut value i64)]) : unit
  (set! (deref value) (+ (deref value) 1)))

(define (field-through [p : (& p Pt)]) : i64
  (deref p).x)

(define (local-ref) : i64
  (let
    [n : i64 20]
    [r : (& n i64) (& n)]
    (+ (deref r) (deref r))))

(define (size-const) : i64
  (comptime (+ 1 0)))

(define (main) : i64
  (let
    [n : i64 0]
    [p : Pt (Pt 0 0)]
    (begin
      (write-through (&mut n))
      (+ (read-through (& n)) (field-through (& p)) (local-ref) (size-const) 19))))