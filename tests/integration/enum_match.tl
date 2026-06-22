(defenum Color
  (Red i64)
  (Green i64)
  (Blue i64)
  (Yellow i64)
  (Purple i64))

(define (final-arm-value [c : Color]) : i64
  (match c
    [(Red v) (+ v 1)]
    [(Green v) (+ v 10)]
    [(Blue v) (+ v 20)]
    [(Yellow v) (+ v 30)]
    [(Purple v) (+ v 34)]))

(define (wildcard-value [c : Color]) : i64
  (match c
    [(Red v) v]
    [(Green v) (+ v 2)]
    [(Blue v) (+ v 3)]
    [(Yellow v) (+ v 4)]
    [_ 6]))

(define (main) : i64
  (+ (final-arm-value (Purple 2)) (wildcard-value (Purple 99))))