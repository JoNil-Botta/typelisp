;; A function value holds no loans, also as an array element: an array of
;; functions is an ordinary Copy value.
(define (double [x : i64]) : i64
  (* x 2))

(define (increment [x : i64]) : i64
  (+ x 1))

(define (main) : i64
  (let
    [steps : (Array (-> i64 i64) 2) (array double increment)]
    [copy : (Array (-> i64 i64) 2) steps]
    (+ ((array-ref steps 0) 20) ((array-ref copy 1) 1))))