(import consume.parameters.helper)

(define (main) : i64
  (let
    [payload : helper.HelperPayload (helper.HelperPayload 1)]
    (begin
      (helper.consume-payload payload)
      (struct-get payload value))))