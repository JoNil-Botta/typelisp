;; Genuine caller data keeps its lifetime under a binder of the same name
;; (#9609). An inferred alias of the caller reference.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defstruct OwnBox
  (:lifetimes a)
  (value (in a (Box i64))))

(define (store [b : (&mut r (RefBox r))] [p : (& r i64)]) : unit
  (let
    [r : i64 1]
    [alias p]
    (set! b.value alias)))

(define (main) : i64
  0)