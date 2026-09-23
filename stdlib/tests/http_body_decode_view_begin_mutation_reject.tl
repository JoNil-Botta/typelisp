(import stdlib.byte_buf)
(import stdlib.net.http_body_decode as body)
(import stdlib.net.http_types)

; Must fail: the feed buffer reaches the decoder through a `begin` (#7979),
; and the owning buffer is cleared while the returned body view is live.
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
            (body.body-decoder-feed
              decoder
              (begin
                (byte_buf.bytes-length (byte_buf.as-bytes (& wire)))
                (byte_buf.as-bytes (& wire))))]
          (match fed.step
            [(body.HttpBodyData view _)
              (begin
                (set! wire (byte_buf.clear wire))
                (byte_buf.bytes-length view))]
            [_ 0]))]
      [(body.HttpBodyDecoderNewErr _) 0])))