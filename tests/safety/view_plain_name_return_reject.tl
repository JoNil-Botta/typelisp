;; Returning the name-chain view as an owned Box consumes it at the result.
(defstruct Holder
  (b (Box i64)))

(define (take [r : (& r Holder)]) : (Box i64)
  (let
    [b : (Box i64) r.b]
    [alias : (Box i64) b]
    alias))

(define (main) : i64
  (let
    [holder : Holder (Holder (box 42))]
    [b : (Box i64) (take (& holder))]
    (deref b)))