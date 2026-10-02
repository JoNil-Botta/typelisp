;; Provider enums for variant_expected_resolution.tl. The caller declares
;; enums with the same variant names in another order, so a bare name resolved
;; to the wrong enum would carry the wrong tag.
(defenum Outcome
  (Fail i64)
  (Pass i64))

(defenum Flag
  (Low)
  (High i64))

(define (outcome-value [outcome : Outcome]) : i64
  (match outcome
    [(Pass value) value]
    [(Fail value) (- 0 value)]))

(define (flag-value [flag : Flag]) : i64
  (match flag
    [Low 1]
    [(High value) value]))