(module consume.parameters.helper)

;; lint-allow: unused-import
(import stdlib.string)

(defstruct HelperPayload
  (value i64))

(define (consume-length [text : String (:consume)]) : i64
  (string-length text))

(define (consume-payload [payload : HelperPayload (:consume)]) : i64
  (struct-get payload value))