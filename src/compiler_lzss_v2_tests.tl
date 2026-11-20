;; Coverage for the read-only v2 source-frame reader the seed's payloads need.
;;
;; The reader is built from the v2 canonical model, so a frame assembled here
;; with those very codes proves the whole path: marker, decimal header, symbol
;; stream, match copy and the padding checks. It is deleted together with the
;; reader once the published seed writes v3 frames.
(import stdlib.string)
(import stdlib.byte_buf_core as buf)
(import compiler_lzss as lzss)
(import compiler_lzss_v2 as v2)

(define (compiler-lzss-v2-test-write-bits!
  [out : (&mut out buf.ByteBufBuilder)]
  [pending : (&mut pending (__tl_dyn-array i64))]
  [used : (&mut used (__tl_dyn-array i64))]
  [value : i64]
  [count : i64]) : unit
  (let
    [total : i64 (+ (array-ref used 0) count)]
    (set!
      (array-ref pending 0)
      (bit-or
        (shl (array-ref pending 0) count)
        (bit-and value (- (shl 1 count) 1))))
    (while (>= total 8)
      (set! total (- total 8))
      (buf.byte-buf-builder-push
        (&mut out)
        (cast (bit-and (shr (array-ref pending 0) total) 255) : u8)))
    (set! (array-ref used 0) total)
    (set!
      (array-ref pending 0)
      (bit-and (array-ref pending 0) (- (shl 1 total) 1)))))

(define (compiler-lzss-v2-test-symbol!
  [out : (&mut out buf.ByteBufBuilder)]
  [pending : (&mut pending (__tl_dyn-array i64))]
  [used : (&mut used (__tl_dyn-array i64))]
  [code : (& code v2.CompilerLzssV2Canonical)]
  [symbol : i64]) : unit
  (compiler-lzss-v2-test-write-bits!
    out
    pending
    used
    (array-ref code.codes symbol)
    (array-ref code.lengths symbol)))

;; A frame whose token stream is: literal 'a', then a match at distance 1 with
;; length 4, so the decoded bytes are "aaaaa".
(define (compiler-lzss-v2-test-frame-body) : String
  (let
    [main : v2.CompilerLzssV2Canonical (v2.compiler-lzss-v2-main)]
    [distance : v2.CompilerLzssV2Canonical (v2.compiler-lzss-v2-distance)]
    [length-code : v2.CompilerLzssV2Canonical (v2.compiler-lzss-v2-length)]
    [out : buf.ByteBufBuilder (buf.byte-buf-builder-new)]
    [pending : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [used : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    (compiler-lzss-v2-test-symbol!
      (&mut out)
      (&mut pending)
      (&mut used)
      (& main)
      97)
    (compiler-lzss-v2-test-symbol!
      (&mut out)
      (&mut pending)
      (&mut used)
      (& main)
      256)
    (compiler-lzss-v2-test-symbol!
      (&mut out)
      (&mut pending)
      (&mut used)
      (& distance)
      0)
    (compiler-lzss-v2-test-symbol!
      (&mut out)
      (&mut pending)
      (&mut used)
      (& length-code)
      1)
    (when
      (> (array-ref used 0) 0)
      (compiler-lzss-v2-test-write-bits!
        (&mut out)
        (&mut pending)
        (&mut used)
        0
        (- 8 (array-ref used 0))))
    (buf.byte-buf-builder-to-string (& out))))

(define (compiler-lzss-v2-test-frame [raw-len : i64] [body : (& body str)]) : (__tl_dyn-array
    u8)
  (let
    [text : String (string.int->string raw-len)]
    [digits : i64 (string.string-length (& text))]
    [body-len : i64 (string.string-length body)]
    [out : (__tl_dyn-array u8) (__tl_make-array u8 (+ 36 digits 1 body-len))]
    [index : i64 0]
    (while (< index (array-length out))
      (set! (array-ref out index) (cast 0 : u8))
      (set! index (+ index 1)))
    (set! index 0)
    (while (< index 36)
      (set!
        (array-ref out index)
        (cast (string.string-ref (v2.compiler-lzss-v2-prefix) index) : u8))
      (set! index (+ index 1)))
    (set! index 0)
    (while (< index digits)
      (set!
        (array-ref out (+ 36 index))
        (cast (string.string-ref (& text) index) : u8))
      (set! index (+ index 1)))
    (set! (array-ref out (+ 36 digits)) (cast 10 : u8))
    (set! index 0)
    (while (< index body-len)
      (set!
        (array-ref out (+ 36 digits 1 index))
        (cast (string.string-ref body index) : u8))
      (set! index (+ index 1)))
    out))

(define (compiler-lzss-v2-test-status) : i64
  (let
    [body : String (compiler-lzss-v2-test-frame-body)]
    [frame : (__tl_dyn-array u8) (compiler-lzss-v2-test-frame 5 (& body))]
    ;; The v2 frame decodes through the v2 reader...
    (match (v2.compiler-lzss-decode (& frame) 64)
      [(Err _) (return 1)]
      [(Ok bytes)
        (when (!= (array-length bytes) 5) (return 2))
        (when (!= (array-ref bytes 0) (cast 97 : u8)) (return 3))
        (when (!= (array-ref bytes 4) (cast 97 : u8)) (return 4))])
    ;; ... and through the v3 entry point that keeps the v2 dispatch.
    (match (lzss.compiler-lzss-decode (& frame) 64)
      [(Err _) (return 5)]
      [(Ok bytes) (when (!= (array-length bytes) 5) (return 6))])
    ;; A claimed length that the tokens cannot fill, a consumer limit below it
    ;; and a truncated frame are all rejected.
    (let
      [bigger : (__tl_dyn-array u8) (compiler-lzss-v2-test-frame 9 (& body))]
      (match (v2.compiler-lzss-decode (& bigger) 64)
        [(Ok _) (return 7)]
        [(Err _) unit]))
    (match (v2.compiler-lzss-decode (& frame) 4)
      [(Ok _) (return 8)]
      [(Err _) unit])
    (let
      [cut : (__tl_dyn-array u8)
        (__tl_make-array u8 (- (array-length frame) 1))]
      [index : i64 0]
      (while (< index (array-length cut))
        (set! (array-ref cut index) (array-ref frame index))
        (set! index (+ index 1)))
      (match (v2.compiler-lzss-decode (& cut) 64)
        [(Ok _) (return 9)]
        [(Err _) unit]))
    0))

(test
  compiler-lzss-v2-source-frames
  (if (= (compiler-lzss-v2-test-status) 0)
    unit
    (string.tl_oob_abort)))