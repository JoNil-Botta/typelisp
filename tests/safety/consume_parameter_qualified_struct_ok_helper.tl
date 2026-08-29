(defstruct HelperPayload
  (value i64))

(define (consume-payload [payload : HelperPayload]) : i64
  payload.value)