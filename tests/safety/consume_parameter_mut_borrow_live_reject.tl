(defstruct Payload
  (value i64))

(define (borrow-and-consume
  [_value : (&mut value i64)]
  [payload : Payload (:consume)]) : i64
  (struct-get payload value))

(define (main) : i64
  (let
    [payload : Payload (Payload 1)]
    (borrow-and-consume (&mut payload.value) payload)))