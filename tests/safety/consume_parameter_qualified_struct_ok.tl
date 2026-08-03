;; An imported scalar-only struct is structurally Copyable, so a qualified
;; consuming call leaves the local source usable.
(import consume.parameters.helper)

(define (main) : i64
  (let
    [payload : helper.HelperPayload (helper.HelperPayload 1)]
    (begin
      (helper.consume-payload payload)
      (struct-get payload value))))