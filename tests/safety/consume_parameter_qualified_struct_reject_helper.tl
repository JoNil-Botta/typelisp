(defstruct HelperPayload
  (value i64))

(define (consume-payload [payload : HelperPayload (:consume)]) : i64
  (struct-get payload value))