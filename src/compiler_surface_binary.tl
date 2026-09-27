;; compiler_surface_binary.tl - string helpers shared by the portable
;; compiler surface codecs. Integers use stdlib.byte_le.
(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (import stdlib.byte_buf_core))
(import stdlib.string)

(define (surface-binary-string-length [text : (& text str)]) : i64
  (string.string-length text))

(define (surface-binary-string-ref [text : (& text str)] [index : i64]) : char
  (string.string-ref text index))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
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
        unit))))

(define (surface-binary-bytes->string
  [bytes : (& bytes (__tl_dyn-array u8))]
  [offset : i64]
  [length : i64]) : String
  (let
    [out : (__tl_dyn-array u8) (__tl_make-array u8 length)]
    [index : i64 0]
    (begin
      (while (< index length)
        (begin
          (set! (array-ref out index) (array-ref bytes (+ offset index)))
          (set! index (+ index 1))))
      (unsafe
        (string-from-bytes (ptr-cast (__tl_array-data out) : (Ptr u8)) length)))))

(cfg
  compiler-surface-producer
  (define (surface-binary-copy [bytes : (& bytes (__tl_dyn-array u8))]) : (__tl_dyn-array
      u8)
    (let
      [out : (__tl_dyn-array u8) (__tl_make-array u8 (array-length bytes))]
      [index : i64 0]
      (begin
        (while (< index (array-length bytes))
          (begin
            (set! (array-ref out index) (array-ref bytes index))
            (set! index (+ index 1))))
        out))))