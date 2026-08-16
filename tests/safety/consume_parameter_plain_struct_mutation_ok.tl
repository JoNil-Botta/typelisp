;; A scalar-only struct remains an owned, mutable place after a by-value call
;; because its structural Copy classification leaves the source initialized.
(defstruct Payload
  (value i64))

(define (consume [payload : Payload]) : i64
  payload.value)

(define (main) : i64
  (let
    [payload : Payload (Payload 1)]
    (begin
      (consume payload)
      (set! payload.value 2)
      0)))