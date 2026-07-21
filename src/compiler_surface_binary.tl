;; compiler_surface_binary.tl - nominal-free binary primitives for portable
;; compiler surface sections. This intentionally does not import tlci_core:
;; surface codecs are also included by the TLCl loader, and pulling the full
;; container module through an alias would create a second nominal universe.
(import stdlib.byte_buf_core)
(import stdlib.string)

(define (surface-binary-string-length [text : String]) : i64
  (string.string-length text))

(define (surface-binary-string-ref [text : String] [index : i64]) : char
  (string.string-ref text index))

(define (surface-binary-push-u64!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (begin
    (byte_buf_core.byte-buf-builder-push out (cast (bit-and value 0xff) : u8))
    (byte_buf_core.byte-buf-builder-push
      out
      (cast (bit-and (shr value 8) 0xff) : u8))
    (byte_buf_core.byte-buf-builder-push
      out
      (cast (bit-and (shr value 16) 0xff) : u8))
    (byte_buf_core.byte-buf-builder-push
      out
      (cast (bit-and (shr value 24) 0xff) : u8))
    (byte_buf_core.byte-buf-builder-push
      out
      (cast (bit-and (shr value 32) 0xff) : u8))
    (byte_buf_core.byte-buf-builder-push
      out
      (cast (bit-and (shr value 40) 0xff) : u8))
    (byte_buf_core.byte-buf-builder-push
      out
      (cast (bit-and (shr value 48) 0xff) : u8))
    (byte_buf_core.byte-buf-builder-push
      out
      (cast (bit-and (shr value 56) 0xff) : u8))))

(define (surface-binary-push-string!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [text : String]) : unit
  (let
    [index : i64 0]
    [length : i64 (surface-binary-string-length text)]
    (begin
      (while (< index length)
        (begin
          (byte_buf_core.byte-buf-builder-push
            out
            (cast (surface-binary-string-ref text index) : u8))
          (set! index (+ index 1))))
      unit)))

(define (surface-binary-byte [bytes : (Array u8)] [offset : i64]) : i64
  (cast (array-ref bytes offset) : i64))

(define (surface-binary-read-u64 [bytes : (Array u8)] [offset : i64]) : i64
  (+
    (surface-binary-byte bytes offset)
    (+
      (shl (surface-binary-byte bytes (+ offset 1)) 8)
      (+
        (shl (surface-binary-byte bytes (+ offset 2)) 16)
        (+
          (shl (surface-binary-byte bytes (+ offset 3)) 24)
          (+
            (shl (surface-binary-byte bytes (+ offset 4)) 32)
            (+
              (shl (surface-binary-byte bytes (+ offset 5)) 40)
              (+
                (shl (surface-binary-byte bytes (+ offset 6)) 48)
                (shl (surface-binary-byte bytes (+ offset 7)) 56)))))))))

(define (surface-binary-bytes->string
  [bytes : (Array u8)]
  [offset : i64]
  [length : i64]) : String
  (let
    [out : (Array u8) (make-array u8 length)]
    [index : i64 0]
    (begin
      (while (< index length)
        (begin
          (array-set! out index (array-ref bytes (+ offset index)))
          (set! index (+ index 1))))
      (unsafe
        (string-from-bytes (ptr-cast (array-data out) : (Ptr u8)) length)))))

(define (surface-binary-copy [bytes : (Array u8)]) : (Array u8)
  (let
    [out : (Array u8) (make-array u8 (array-length bytes))]
    [index : i64 0]
    (begin
      (while (< index (array-length bytes))
        (begin
          (array-set! out index (array-ref bytes index))
          (set! index (+ index 1))))
      out)))