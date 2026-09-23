(import stdlib.byte_buf)
(import stdlib.net.http_body_decode as body)
(import stdlib.net.http_types)

; Must fail: advancing (here clearing) the owning buffer while the returned
; body view of it is still live.
(define (main) : i64
  (let
    [wire : byte_buf.ByteBuf (byte_buf.from-string "helloNEXT")]
    (match (body.body-decoder-new
      (http_types.HttpResponsePlanFixed 5)
      (body.HttpBodyPlainTransport)
      (body.default-body-decode-limits))
      [(body.HttpBodyDecoderNewOk decoder)
        (let
          [fed : (body.HttpBodyFeed wire)
            (body.body-decoder-feed decoder (byte_buf.as-bytes (& wire)))]
          (match fed.step
            [(body.HttpBodyData view _)
              (begin
                (set! wire (byte_buf.clear wire))
                (byte_buf.bytes-length view))]
            [_ 0]))]
      [(body.HttpBodyDecoderNewErr _) 0])))