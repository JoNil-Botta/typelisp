;; Positive control for #9288 and #9053: valid view-alias borrows and
;; non-cleanup clones (owned and through a reference) continue to pass.
(defstruct Payload
  (b (Box i64))
  (n i64))

(defstruct Holder
  (p Payload)
  (k i64))

(define (view-alias [h : (& h Holder)]) : (& h Payload)
  (let
    [v h.p]
    (& v)))

(define (clone-ref [p : (& p Payload)]) : Payload
  (clone (deref p)))

(define (main) : i64
  (let
    [h : Holder (Holder (Payload (box 20) 2) 10)]
    [v (view-alias (& h))]
    [c1 (clone-ref v)]
    [c2 (clone c1)]
    (+ (deref c1.b) (deref c2.b) c2.n)))