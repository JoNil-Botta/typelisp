(defstruct Payload
  (value i64))

(define (consume [payload : Payload (:consume)]) : i64
  (struct-get payload value))

(define (main) : i64
  (let
    [payload : Payload (Payload 1)]
    (begin
      (consume payload)
      (struct-get payload value))))