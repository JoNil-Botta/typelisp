(defstruct Token
  (:cleanup cleanup-token)
  (id i64))

(defstruct Holder
  (:cleanup cleanup-holder)
  (token Token (:owned))
  (other i64))

(defstruct Outer
  (:cleanup cleanup-outer)
  (holder Holder (:owned))
  (extra i64))

(define (bump-id [token : (&mut Token)]) : unit
  (set! token.id (+ token.id 10)))

(define (write-token [view : (&mut Holder)]) : unit
  (match view.token
    [token (set! token.id 10)]))

(define (write-holder [view : (&mut Outer)]) : i64
  (let
    [value
      (match view.holder
        [(fields token)
          (bump-id (&mut token))
          token.id])]
    (+ value 2)))

(define (main) : i64
  (let
    [outer (Outer (Holder (Token 2) 0) 0)]
    [_write (write-token (&mut outer.holder))]
    [value (write-holder (&mut outer))]
    [stored : i64 outer.holder.token.id]
    (cleanup-outer outer)
    (+ value stored)))