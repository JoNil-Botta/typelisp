;; A match binder that shadows a caller lifetime owns its storage.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defenum Choice
  (Some i64)
  (Empty))

(define (store [choice : Choice] [b : (&mut a (RefBox a))]) : unit
  (match choice
    ; Must fail: `(& a)` borrows the binder.
    [(Some a) (set! b.value (& a))]
    [(Empty) unit]))

(define (main) : i64
  0)