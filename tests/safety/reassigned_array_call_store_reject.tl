;: `views` is reassigned whole, then a call may store `&p.z` into it through
;: `(&mut views)`. A borrowed binding is never split into its definitions, so
;: its later read sees that loan and writing `p.z` before the read conflicts,
;: as in Rust (#8449).
(defstruct P
  (l i64)
  (r i64)
  (z i64))

(define (store [b : (&mut (Array (& a i64) 1))] [v : (& a i64)]) : unit
  (set! (array-ref (deref b) 0) v))

(define (read0 [vs : (Array (& a i64) 1)]) : i64
  (deref (array-ref vs 0)))

(define (main) : i64
  (let
    [p : P (P 1 2 3)]
    [views : (Array (& p i64) 1) (array (& p.l))]
    (set! views (array (& p.r)))
    (store (&mut views) (& p.z))
    (set! p.z 9)
    (read0 views)))