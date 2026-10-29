;; Base accepts these two bodies. Only the third, differently named variant in
;; caller_lifetime_call_inference_order_ok remains the inference limitation.
(defstruct RefBox
  (:lifetimes t)
  (value (& t i64)))

(define (put [value : (& t i64)] [cell : (&mut r (RefBox t))]) : unit
  (set! cell.value value))

(define (put-swapped [cell : (&mut r (RefBox t))] [value : (& t i64)]) : unit
  (set! cell.value value))

(define (value-first [xs : (& a (Array i64 2))]) : i64
  (let
    [a : i64 0]
    [cell (RefBox (& a))]
    (put (& (array-ref xs 0)) (&mut cell))
    (deref cell.value)))

(define (box-first [xs : (& a (Array i64 2))]) : i64
  (let
    [a : i64 0]
    [cell (RefBox (& a))]
    (put-swapped (&mut cell) (& (array-ref xs 0)))
    (deref cell.value)))

(define (main) : i64
  0)