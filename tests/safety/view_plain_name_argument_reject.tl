;; The field/name bindings are legal; passing the alias as an owned Box is not.
(defstruct Holder
  (b (Box i64)))

(define (consume [b : (Box i64)]) : i64
  (deref b))

(define (take [r : (& r Holder)]) : i64
  (let
    [b : (Box i64) r.b]
    [alias : (Box i64) b]
    (consume alias)))

(define (main) : i64
  (let
    [holder : Holder (Holder (box 42))]
    (take (& holder))))