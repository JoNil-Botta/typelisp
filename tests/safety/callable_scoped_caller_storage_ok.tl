;; Canonical incoming a retains base's same-name storage relations.
(defstruct RefBox
  (:lifetimes item)
  (value (& item i64)))

(define (assign [p : (& a i64)]) : i64
  (let
    [a : i64 1]
    [slot (& a)]
    (set! slot p)
    (deref slot)))

(define (array-both-orders [p : (& a i64)]) : i64
  (let
    [a : i64 1]
    [first (array p (& a))]
    [second (array (& a) p)]
    (+ (deref (array-ref first 0)) (deref (array-ref second 1)))))

(define (construct [p : (& a i64)]) : i64
  (let
    [a : i64 1]
    [cell (RefBox (& a))]
    (set! cell.value p)
    (deref cell.value)))

(define (main) : i64
  0)