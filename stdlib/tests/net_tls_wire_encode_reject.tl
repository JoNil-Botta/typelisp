;; An encoder given a value the wire cannot carry traps instead of writing a
;; malformed message: here a ClientHello random of 33 bytes.
(import stdlib.byte_buf)
(import stdlib.net.tls_wire as tls)

(define (main) : i64
  (let
    [hello : tls.TlsClientHello
      (tls.TlsClientHello
        0x0303
        (byte_buf.from-string "012345678901234567890123456789012")
        (byte_buf.new)
        (__tl_make-array i64 0)
        (byte_buf.new)
        (__tl_make-array tls.TlsExtension 0))]
    [encoded : byte_buf.ByteBuf
      (tls.encode-client-hello (byte_buf.new) (& hello))]
    (byte_buf.len (& encoded))))