(defmacro (generated-consumer-module) : Module
  `(begin
    (module generated.consume.safety)
    (defstruct Payload
      (value i64))
    (define (consume [payload : Payload (:consume)]) : i64
      (struct-get payload value))))

(import (generated-consumer-module) as generated)

(define (main) : i64
  (let
    [payload : generated.Payload (generated.Payload 1)]
    (begin
      (generated.consume payload)
      (struct-get payload value))))
