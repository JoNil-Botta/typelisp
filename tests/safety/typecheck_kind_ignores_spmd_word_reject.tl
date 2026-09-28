;; A binding named `foreach-total` must not turn a type mismatch into an SPMD
;; restriction (#7139).
(define (main) : i64
  (let
    [foreach-total : i64 true]
    foreach-total))