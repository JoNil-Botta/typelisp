;; Immediate raw helper calls compile only when the caller explicitly assumes
;; the live-cell address contract. This check-only fixture must never execute.
(import stdlib.byte_buf)
(import stdlib.format)
(import stdlib.text_buf)

(define (raw-writes) : i64
  (begin
    (unsafe
      (byte_buf.format-write-raw 1 "x"))
    (unsafe
      (text_buf.format-write-raw 1 "x"))
    (unsafe
      (format.arguments-string-write-raw 1 "x"))))

(define (raw-formatter-cell) : i64
  (begin
    (unsafe
      (format.formatter-write-string-at! 1 "x"))
    (unsafe
      (format.formatter-result-at 1))
    (unsafe
      (format.formatter-status-at 1))))

(define (raw-ranges [text : (& text str)]) : i64
  (let
    [source : (Ptr u8) (ptr-null : (Ptr u8))]
    [dst : (MutPtr u8) (ptr-null : (MutPtr u8))]
    [byte : u8
      (unsafe
        (format.format-debug-source-byte source 0 (cast 0 : u8) false))]
    [_length : i64
      (unsafe
        (format.format-debug-rendered-length source 1 byte false (cast 34 : u8)))]
    [_rendered : String
      (unsafe
        (format.format-debug-bytes-core source 1 byte false (cast 34 : u8)))]
    (unsafe
      (format.format-debug-write-code! dst 0 byte))
    (unsafe
      (format.format-write-fill! dst 0 1 'x'))
    (unsafe
      (format.format-copy-rendered-range! text 0 dst 0 1))
    (+
      (unsafe
        (format.format-debug-write-byte! dst 0 byte 0))
      (unsafe
        (format.arguments-renderer-call-at 0 0 0)))))

(define (main) : i64
  0)