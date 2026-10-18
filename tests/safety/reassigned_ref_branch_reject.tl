;: A reference reassigned on one branch only may still hold its first loan
;: after the join: writing that borrowed place while it is used is rejected
;: (#8449, location-sensitive origins).
(defstruct P
  (l i64)
  (r i64))

(define (read [view : (& v i64)]) : i64
  (deref view))

(define (pick [c : bool]) : i64
  (let
    [p : P (P 1 2)]
    [view : (& p i64) (& p.l)]
    (if c
      (set! view (& p.r))
      unit)
    (set! p.l 5)
    (read view)))

(define (main) : i64
  (pick true))