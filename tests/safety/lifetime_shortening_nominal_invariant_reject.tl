;: Structural variance makes a lifetime used in both a function parameter and
;: result invariant.
(defstruct InvariantView
  (:lifetimes source)
  (value (-> (& source i64) (& source i64))))

(define (main [view : (InvariantView outer)]) : i64
  (let
    [inner : i64 1]
    [changed : (InvariantView inner) view]
    0))