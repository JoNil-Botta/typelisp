;; Imported globals read by tests/integration/global_reference_initializers.tl
;; (#7804): one read by value, one mutated after initialization, one computed at
;; startup.
(define answer : i64
  14)
(define flag : bool
  true)
(define computed : i64
  (+ 20 1))

(define (set-answer! [value : i64]) : unit
  (set! answer value))