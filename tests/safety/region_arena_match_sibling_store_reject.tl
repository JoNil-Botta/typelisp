;; Rejected at entry: the arena is named like the caller lifetime `r`, so the
;; form fails with the collision diagnostic and the arena must be renamed
;; (#9593, D-C121). It was the review witness for a sibling match arm's arena
;; escape.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defenum Pick
  (Take i64)
  (Skip))

(define (store [b : (&mut r (RefBox r))] [v : Pick]) : unit
  (with-arena
    r
    (match v
      [(Take r) unit]
      [(Skip)
        (let
          [x : (Box i64) (box 2)]
          (set! b.value (& r (deref x))))])))

(define (main) : i64
  0)