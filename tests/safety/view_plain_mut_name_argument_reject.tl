;; A mutable-origin view may write exclusively, but an owned argument takes it.
(defstruct Holder
  (b (Box i64)))

(define (consume [b : (Box i64)]) : i64
  (deref b))

(define (take [r : (&mut r Holder)]) : i64
  (let
    [b : (Box i64) r.b]
    [alias : (Box i64) b]
    (consume alias)))

(define (main) : i64
  (let
    [holder : Holder (Holder (box 42))]
    (take (&mut holder))))