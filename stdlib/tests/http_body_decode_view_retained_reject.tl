(import stdlib.byte_buf)
(import stdlib.net.http_body_decode as body)
(import stdlib.net.http_types)

(defstruct Holder
  (:lifetimes held)
  (view (& held bytes)))

; Must fail: `holder` outlives `wire`, so it cannot retain a body view of it.
(define (main) : i64
  (let
    [fallback : String "x"]
    [holder : (Holder fallback) (Holder (byte_buf.str-as-bytes (& fallback)))]
    (begin
      (let
        [wire : byte_buf.ByteBuf (byte_buf.from-string "hello")]
        (match (body.body-decoder-new
          (http_types.HttpResponsePlanFixed 5)
          (body.HttpBodyPlainTransport)
          (body.default-body-decode-limits))
          [(body.HttpBodyDecoderNewOk decoder)
            (match (body.body-decoder-feed decoder (byte_buf.as-bytes (& wire))).step
              [(body.HttpBodyData view _) (set! holder (Holder view))]
              [_ unit])]
          [(body.HttpBodyDecoderNewErr _) unit]))
      (byte_buf.bytes-length holder.view))))