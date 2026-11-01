;: As `mir_closure_result_loan_reject`, but `p.l` is written after the
;: result's last use (#8449).
(defstruct Pair
  (l i64)
  (r i64))

(define (main) : i64
  (let
    [p : Pair (Pair 1 2)]
    [r : (& p i64) (& p.l)]
    [pick
      (lambda ([n : i64]) : (& p i64)
        r)]
    [v : i64 (deref (pick 0))]
    (set! p.l 40)
    (+ v p.l 1)))