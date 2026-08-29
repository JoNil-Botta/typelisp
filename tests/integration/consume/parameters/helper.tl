;; lint-allow: unused-import
(import stdlib.string)

(defstruct HelperPayload
  (value i64))

(define (consume-length [text : String]) : i64
  (string-length text))

(define (consume-payload [payload : HelperPayload]) : i64
  payload.value)