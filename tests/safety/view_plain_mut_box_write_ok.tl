;; A plain-annotated mutable Box field view writes the caller's storage (p15b).
(defstruct Holder
  (b (Box i64)))

(define (write [r : (&mut r Holder)]) : unit
  (let
    [b : (Box i64) r.b]
    (set! (deref b) 42)))

(define (main) : i64
  (let
    [holder : Holder (Holder (box 40))]
    (write (&mut holder))
    (deref holder.b)))