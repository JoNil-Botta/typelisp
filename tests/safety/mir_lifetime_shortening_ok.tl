;; A value read at a shorter lifetime (covariance) is the same value to the
;; ownership graph; typing checks the variance.
(defstruct View
  (:lifetimes source)
  (cell (& source i64)))

(define (read [view : (View outer)]) : i64
  (let
    [local : i64 0]
    [short : (View local) view]
    (deref short.cell)))

(define (main) : i64
  (let
    [value : i64 42]
    (read (View (& value)))))