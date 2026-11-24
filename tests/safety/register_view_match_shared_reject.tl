(defstruct Token
  (:cleanup cleanup-token)
  (id i64))

(defstruct Holder
  (:cleanup cleanup-holder)
  (token Token (:owned))
  (other i64))

(define (try-write [view : (& Holder)]) : unit
  (match view.token
    [token (set! token.id 10)]))

(define (main) : i64
  42)