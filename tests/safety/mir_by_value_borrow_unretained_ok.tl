;; A by-value call scratch borrow beside another mutable argument that cannot
;; hold it still writes back after the call (#8897).
(define (move-into! [target : (&mut a i64)] [source : (&mut a i64)]) : unit
  (set! (deref target) (+ (deref target) (deref source)))
  (set! (deref source) 0))

(define (main) : i64
  (let
    [total : i64 40]
    [extra : i64 2]
    (move-into! (&mut total) (&mut extra))
    (+ total extra)))