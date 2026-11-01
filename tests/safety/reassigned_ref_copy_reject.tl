;: A copy of a reference taken before the binding is reassigned keeps the
;: first loan (#8449).
(defstruct P
  (l i64)
  (r i64))

(define (read [view : (& v i64)]) : i64
  (deref view))

(define (main) : i64
  (let
    [p : P (P 1 2)]
    [view : (& p i64) (& p.l)]
    [kept : (& p i64) view]
    (set! view (& p.r))
    (set! p.l 5)
    (+ (read kept) (read view))))