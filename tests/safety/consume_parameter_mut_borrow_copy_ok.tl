;; A scalar-only struct argument may be copied while a two-phase mutable
;; borrow is live; the copy does not invalidate the borrowed source.
(defstruct Payload
  (value i64))

(define (borrow-and-consume
  [_value : (&mut value i64)]
  [payload : Payload (:consume)]) : i64
  payload.value)

(define (main) : i64
  (let
    [payload : Payload (Payload 1)]
    (borrow-and-consume (&mut payload.value) payload)))