;; A written mutable view excludes another live view of the same field (p15).
(defstruct Holder
  (b (Box i64)))

(define (write [r : (&mut r Holder)]) : i64
  (let
    [first : (Box i64) r.b]
    [second : (Box i64) r.b]
    (set! (deref first) 42)
    (deref second)))

(define (main) : i64
  (let
    [holder : Holder (Holder (box 40))]
    (write (&mut holder))))