;: After a reference binding is reassigned, it holds only its new loan: the
;: place it first borrowed may be written while the new value is still used
;: (#8449, location-sensitive origins).
(defstruct P
  (l i64)
  (r i64))

(define (read [view : (& v i64)]) : i64
  (deref view))

(define (keep [view : (& p i64)]) : (& p i64)
  view)

(define (main) : i64
  (let
    [p : P (P 1 40)]
    [view : (& p i64) (& p.l)]
    [first : i64 (read view)]
    (set! view (keep (& p.r)))
    (set! p.l 2)
    (+ (read view) p.l first -1)))