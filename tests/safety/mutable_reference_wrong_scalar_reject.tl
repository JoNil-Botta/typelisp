;; A writeback slot may only be created for the formal's referent type.
(define (clear-flag! [flag : (&mut flag bool)]) : unit
  (set! (deref flag) false))

(define (main) : i64
  (let
    [counter : i64 0]
    (clear-flag! (&mut counter))
    counter))