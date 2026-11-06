;; A plain-annotated name-to-name view keeps the shared field origin (p13).
(defstruct Holder
  (b (Box i64)))

(define (write [r : (& r Holder)]) : unit
  (let
    [b : (Box i64) r.b]
    [alias : (Box i64) b]
    (set! (deref alias) 42)))

(define (main) : i64
  (let
    [holder : Holder (Holder (box 40))]
    (write (& holder))
    (deref holder.b)))