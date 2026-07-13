(import
  "../integration/consume_parameters_helper.tl"
  module consume.parameters.helper
  as helper)

(define (main) : i64
  (let
    [payload : helper.HelperPayload (helper.HelperPayload 1)]
    (begin
      (helper.consume-payload payload)
      (struct-get payload value))))
