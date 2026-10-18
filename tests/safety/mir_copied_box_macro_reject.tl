;; A shared field cannot supply an owned Box or exclusive access (#8927).
(defstruct Holder
  (b (Box i64)))

(defmacro (mutate-copy [value : Expr]) : Expr
  `(let
    [b : (Box i64) ,value]
    (set! (deref b) 42)))

(define (mutate [r : (& r Holder)]) : unit
  (mutate-copy r.b))

(define (main) : i64
  0)