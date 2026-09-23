(import stdlib.byte_buf)
(import stdlib.net.http_body_decode as body)
(import stdlib.net.http_types)

; Must fail: the body view borrows `wire`, a local, so it cannot be returned as
; a view of the caller's `outer` input.
(define (first-view [outer : (& outer bytes)]) : (& outer bytes)
  (let
    [wire : byte_buf.ByteBuf (byte_buf.from-string "hello")]
    (match (body.body-decoder-new
      (http_types.HttpResponsePlanFixed 5)
      (body.HttpBodyPlainTransport)
      (body.default-body-decode-limits))
      [(body.HttpBodyDecoderNewOk decoder)
        (match (body.body-decoder-feed decoder (byte_buf.as-bytes (& wire))).step
          [(body.HttpBodyData view _) view]
          [_ outer])]
      [(body.HttpBodyDecoderNewErr _) outer])))

(define (main) : i64
  (let
    [text : String "abc"]
    (byte_buf.bytes-length (first-view (byte_buf.str-as-bytes (& text))))))