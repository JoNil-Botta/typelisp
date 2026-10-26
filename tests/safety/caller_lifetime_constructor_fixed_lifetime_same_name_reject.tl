;; A constructor lifetime an argument fixes is that argument's: a borrow of a
;; parameter spelled like a caller lifetime does not reach caller storage
;; through it.
(defenum Either
  (:lifetimes a b)
  (Left (& a i64))
  (Right (& b i64)))

(defstruct Holder
  (:lifetimes a b)
  (e (Either a b)))

; Must fail: `(& a)` borrows the parameter, not the caller's `a`.
(define (leak [a : i64] [h : (&mut a (Holder a b))]) : unit
  (set! h.e (Either.Left (& a))))

(define (main) : i64
  0)