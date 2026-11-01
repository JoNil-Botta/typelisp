;; A resource binding spelled like a caller lifetime owns its storage, also
;; when only its fields are borrowed.
(defstruct RefBox
  (:lifetimes h)
  (value (& h i64)))

(defstruct Pt
  (x i64))

(define (drop-pt [p : Pt]) : unit
  unit)

(define (store [b : (&mut h (RefBox h))]) : unit
  (with
    ([h (Pt 3) drop-pt])
    ; Must fail: `(& h.x)` borrows the resource.
    (set! b.value (& h.x))))

(define (main) : i64
  0)