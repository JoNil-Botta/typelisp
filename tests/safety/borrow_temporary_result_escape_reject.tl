;: A call whose result can borrow a temporary argument is rejected: the
;: temporary is dropped when the call returns.
(defstruct Point
  (x i64)
  (y i64))

(define (keep [p : (& Point)]) : (& Point)
  p)

(define (main) : i64
  (let
    [kept (keep (& (Point 1 2)))]
    kept.x))