;; The imported side of entry_names_like_imported_variants.tl: its own bare
;; variant names must keep resolving to its own enum.
(defenum Outcome
  (Fail i64)
  (Ok i64))

(define (wrap [x : i64]) : Outcome
  (Ok x))

(define (unwrap [outcome : Outcome]) : i64
  (match outcome
    [(Ok v) v]
    [(Fail _) 0]))