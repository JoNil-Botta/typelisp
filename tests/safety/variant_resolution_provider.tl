;; Provider enum for the variant_* resolution fixtures.
(defenum Outcome
  (Fail i64)
  (Pass i64))

(define (outcome-value [outcome : Outcome]) : i64
  (match outcome
    [(Pass value) value]
    [(Fail value) (- 0 value)]))