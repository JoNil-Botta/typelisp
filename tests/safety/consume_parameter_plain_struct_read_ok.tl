;; A scalar-only struct is structurally Copyable, so a by-value call does
;; not invalidate a later read of the source.
(defstruct Payload
  (value i64))

(define (consume [payload : Payload]) : i64
  payload.value)

(define (main) : i64
  (let
    [payload : Payload (Payload 1)]
    (begin
      (consume payload)
      payload.value)))