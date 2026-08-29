;; A scalar-only struct may be passed by value twice because
;; each by-value use copies the structurally Copyable source.
(defstruct Payload
  (value i64))

(define (consume [payload : Payload]) : i64
  payload.value)

(define (main) : i64
  (let
    [payload : Payload (Payload 1)]
    (begin
      (consume payload)
      (consume payload))))