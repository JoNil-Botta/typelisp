;; generate.tl - Deterministic exact-source embedded stdlib payload generator.
(import stdlib.array)
(import stdlib.byte_buf_core)
(import stdlib.io)
(import stdlib.str_cat)
(import stdlib.string)
(import stdlib.text_buf)

(defstruct EmbeddedStdlibLzssMatch
  (offset i64)
  (len i64))

(define embedded-stdlib-lzss-window : i64
  4096)
(define embedded-stdlib-lzss-max-len : i64
  18)
(define embedded-stdlib-lzss-hash-count : i64
  65536)
(define embedded-stdlib-payload-chunk-len : i64
  4096)

(define (embedded-stdlib-source-byte [source : (& source str)] [index : i64]) : u8
  (cast (string.string-ref source index) : u8))

(define (embedded-stdlib-source-byte-i64
  [source : (& source str)]
  [index : i64]) : i64
  (cast (embedded-stdlib-source-byte source index) : i64))

(define (embedded-stdlib-lzss-hash [source : (& source str)] [index : i64]) : i64
  (%
    (+
      (* (embedded-stdlib-source-byte-i64 source index) 251)
      (* (embedded-stdlib-source-byte-i64 source (+ index 1)) 31)
      (embedded-stdlib-source-byte-i64 source (+ index 2)))
    embedded-stdlib-lzss-hash-count))

(define (embedded-stdlib-array-fill!
  [items : (&mut items (Array i64))]
  [value : i64]) : unit
  (let
    [index : i64 0]
    (begin
      (while (< index (array-length items))
        (begin
          (array-set! items index value)
          (set! index (+ index 1))))
      unit)))

(define (embedded-stdlib-lzss-insert!
  [source : (& source str)]
  [head : (&mut head (Array i64))]
  [previous : (&mut previous (Array i64))]
  [index : i64]) : unit
  (if (> (+ index 2) (- (string.string-length source) 1))
    unit
    (let
      [hash : i64 (embedded-stdlib-lzss-hash source index)]
      (begin
        (array-set! previous index (array-ref head hash))
        (array-set! head hash index)))))

(define (embedded-stdlib-lzss-insert-range!
  [source : (& source str)]
  [head : (&mut head (Array i64))]
  [previous : (&mut previous (Array i64))]
  [start : i64]
  [count : i64]) : unit
  (let
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (embedded-stdlib-lzss-insert! source head previous (+ start index))
          (set! index (+ index 1))))
      unit)))

(define (embedded-stdlib-lzss-match-len
  [source : (& source str)]
  [candidate : i64]
  [index : i64]) : i64
  (let
    [length : i64 0]
    [source-len : i64 (string.string-length source)]
    (begin
      (while (and
        (< length embedded-stdlib-lzss-max-len)
        (< (+ index length) source-len)
        (=
          (embedded-stdlib-source-byte source (+ candidate length))
          (embedded-stdlib-source-byte source (+ index length))))
        (set! length (+ length 1)))
      length)))

(define (embedded-stdlib-lzss-find-match
  [source : (& source str)]
  [head : (& head (Array i64))]
  [previous : (& previous (Array i64))]
  [index : i64]) : EmbeddedStdlibLzssMatch
  (if (> (+ index 2) (- (string.string-length source) 1))
    (EmbeddedStdlibLzssMatch 0 0)
    (let
      [hash : i64 (embedded-stdlib-lzss-hash source index)]
      [candidate : i64 (array-ref head hash)]
      [best-offset : i64 0]
      [best-len : i64 0]
      (begin
        (while (and
          (>= candidate 0)
          (<= (- index candidate) embedded-stdlib-lzss-window)
          (< best-len embedded-stdlib-lzss-max-len))
          (let
            [length : i64
              (embedded-stdlib-lzss-match-len source candidate index)]
            (begin
              (when
                (> length best-len)
                (begin
                  (set! best-len length)
                  (set! best-offset (- index candidate))))
              (set! candidate (array-ref previous candidate)))))
        (EmbeddedStdlibLzssMatch best-offset best-len)))))

(define (embedded-stdlib-lzss-compress [source : (& source str)]) : byte_buf_core.ByteBufBuilder
  (let
    [source-len : i64 (string.string-length source)]
    [head : (Array i64) (array.make-array i64 embedded-stdlib-lzss-hash-count)]
    [previous : (Array i64) (array.make-array i64 source-len)]
    [out : byte_buf_core.ByteBufBuilder
      (byte_buf_core.byte-buf-builder-with-capacity
        (+ source-len (+ (/ source-len 8) 1)))]
    [index : i64 0]
    (begin
      (embedded-stdlib-array-fill! (&mut head) -1)
      (embedded-stdlib-array-fill! (&mut previous) -1)
      (while (< index source-len)
        (let
          [flag-index : i64 (byte_buf_core.byte-buf-builder-len (& out))]
          [flags : i64 0]
          [bit : i64 0]
          (begin
            (byte_buf_core.byte-buf-builder-push (&mut out) (cast 0 : u8))
            (while (and (< bit 8) (< index source-len))
              (match (embedded-stdlib-lzss-find-match
                source
                (& head)
                (& previous)
                index)
                [(EmbeddedStdlibLzssMatch offset length)
                  (if (>= length 3)
                    (let
                      [packed : i64 (+ (shl (- offset 1) 4) (- length 3))]
                      (begin
                        (byte_buf_core.byte-buf-builder-push
                          (&mut out)
                          (cast (shr packed 8) : u8))
                        (byte_buf_core.byte-buf-builder-push
                          (&mut out)
                          (cast (bit-and packed 255) : u8))
                        (embedded-stdlib-lzss-insert-range!
                          source
                          (&mut head)
                          (&mut previous)
                          index
                          length)
                        (set! index (+ index length))))
                    (begin
                      (set! flags (bit-or flags (shl 1 bit)))
                      (byte_buf_core.byte-buf-builder-push
                        (&mut out)
                        (embedded-stdlib-source-byte source index))
                      (embedded-stdlib-lzss-insert!
                        source
                        (&mut head)
                        (&mut previous)
                        index)
                      (set! index (+ index 1))))])
              (set! bit (+ bit 1)))
            (array-set! (struct-get out slots) flag-index (cast flags : u8)))))
      out)))

(define embedded-stdlib-base64-alphabet : String
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

(define (embedded-stdlib-base64-byte [index : i64]) : u8
  (cast (string.string-ref embedded-stdlib-base64-alphabet index) : u8))

(define (embedded-stdlib-base64-push!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [index : i64]) : unit
  (byte_buf_core.byte-buf-builder-push out (embedded-stdlib-base64-byte index)))

(define (embedded-stdlib-base64-encode
  [input : (& input byte_buf_core.ByteBufBuilder)]) : String
  (let
    [length : i64 (byte_buf_core.byte-buf-builder-len input)]
    [out : byte_buf_core.ByteBufBuilder
      (byte_buf_core.byte-buf-builder-with-capacity (* (/ (+ length 2) 3) 4))]
    [index : i64 0]
    (begin
      (while (< index length)
        (let
          [remaining : i64 (- length index)]
          [a : i64 (cast (array-ref (struct-get input slots) index) : i64)]
          [b : i64
            (if (> remaining 1)
              (cast (array-ref (struct-get input slots) (+ index 1)) : i64)
              0)]
          [c : i64
            (if (> remaining 2)
              (cast (array-ref (struct-get input slots) (+ index 2)) : i64)
              0)]
          (begin
            (embedded-stdlib-base64-push! (&mut out) (shr a 2))
            (embedded-stdlib-base64-push!
              (&mut out)
              (bit-or (shl (bit-and a 3) 4) (shr b 4)))
            (if (> remaining 1)
              (embedded-stdlib-base64-push!
                (&mut out)
                (bit-or (shl (bit-and b 15) 2) (shr c 6)))
              (byte_buf_core.byte-buf-builder-push (&mut out) (cast 61 : u8)))
            (if (> remaining 2)
              (embedded-stdlib-base64-push! (&mut out) (bit-and c 63))
              (byte_buf_core.byte-buf-builder-push (&mut out) (cast 61 : u8)))
            (set! index (+ index 3)))))
      (byte_buf_core.byte-buf-builder-to-string (& out)))))

(define (embedded-stdlib-emit-payload-chunks
  [out : text_buf.TextBuf]
  [encoded : String]) : text_buf.TextBuf
  (let
    [result : text_buf.TextBuf out]
    [index : i64 0]
    [length : i64 (string.string-length encoded)]
    [chunk-count : i64 0]
    (begin
      (while (< index length)
        (let
          [chunk-len : i64
            (if (< (- length index) embedded-stdlib-payload-chunk-len)
              (- length index)
              embedded-stdlib-payload-chunk-len)]
          (begin
            (text_buf.append!
              result
              "        (CompilerEmbeddedStdlibPayloadChunkCons\n          \"")
            (text_buf.append! result (string.substring encoded index chunk-len))
            (text_buf.append! result "\"\n          (box\n")
            (set! index (+ index chunk-len))
            (set! chunk-count (+ chunk-count 1)))))
      (text_buf.append!
        result
        "            (CompilerEmbeddedStdlibPayloadChunkNil)")
      (while (> chunk-count 0)
        (begin
          (text_buf.append! result "))")
          (set! chunk-count (- chunk-count 1))))
      (text_buf.append! result "\n")
      result)))

(define (embedded-stdlib-emit-entry [out : text_buf.TextBuf] [suffix : String]) : text_buf.TextBuf
  (let
    [path : String (str_cat.str-cat "stdlib/" suffix)]
    [source : String (io.read-file path)]
    [compressed : byte_buf_core.ByteBufBuilder
      (embedded-stdlib-lzss-compress (& source))]
    [encoded : String (embedded-stdlib-base64-encode (& compressed))]
    [result : text_buf.TextBuf out]
    (begin
      (text_buf.append! result "    [(string.eq suffix \"")
      (text_buf.append! result suffix)
      (text_buf.append! result "\")\n")
      (text_buf.append! result "      (CompilerEmbeddedStdlibPayloadSome\n")
      (text_buf.append! result "        ")
      (text_buf.append-int! result (string.string-length source))
      (text_buf.append! result "\n        ")
      (text_buf.append-int!
        result
        (byte_buf_core.byte-buf-builder-len (& compressed)))
      (text_buf.append! result "\n")
      (set! result (embedded-stdlib-emit-payload-chunks result encoded))
      (text_buf.append! result "      )]\n")
      result)))

(define (embedded-stdlib-line-end [manifest : String] [start : i64]) : i64
  (let
    [index : i64 start]
    [length : i64 (string.string-length manifest)]
    (begin
      (while (and (< index length) (!= (string.string-ref manifest index) '\n'))
        (set! index (+ index 1)))
      index)))

(define (embedded-stdlib-line-trim-cr [line : String]) : String
  (let
    [length : i64 (string.string-length line)]
    (if (and (> length 0) (= (string.string-ref line (- length 1)) '\r'))
      (string.substring line 0 (- length 1))
      line)))

(define (embedded-stdlib-generate-lines
  [manifest : String]
  [start : i64]
  [out : text_buf.TextBuf]) : text_buf.TextBuf
  (if (>= start (string.string-length manifest))
    out
    (let
      [end : i64 (embedded-stdlib-line-end manifest start)]
      [line : String
        (embedded-stdlib-line-trim-cr
          (string.substring manifest start (- end start)))]
      [next : i64
        (if (< end (string.string-length manifest))
          (+ end 1)
          end)]
      [next-out : text_buf.TextBuf
        (if (= (string.string-length line) 0)
          out
          (embedded-stdlib-emit-entry out line))]
      (embedded-stdlib-generate-lines manifest next next-out))))

(define (embedded-stdlib-generate [output-path : String]) : i64
  (let
    [manifest : String
      (io.read-file "tools/embedded-stdlib-payload/modules.txt")]
    [header : text_buf.TextBuf (text_buf.empty)]
    (begin
      (text_buf.append!
        header
        ";; compiler_embedded_stdlib_payload.tl - GENERATED exact-source payload.\n;; Regenerate with scripts/generate-embedded-stdlib-payload.sh.\n(import stdlib.string)\n\n(defenum CompilerEmbeddedStdlibPayloadChunks\n  (CompilerEmbeddedStdlibPayloadChunkNil)\n  (CompilerEmbeddedStdlibPayloadChunkCons\n    String\n    (Box CompilerEmbeddedStdlibPayloadChunks)))\n\n(defenum CompilerEmbeddedStdlibPayload\n  (CompilerEmbeddedStdlibPayloadNone)\n  (CompilerEmbeddedStdlibPayloadSome\n    i64\n    i64\n    CompilerEmbeddedStdlibPayloadChunks))\n\n(define (compiler-embedded-stdlib-payload-lookup\n  [suffix : String]) : CompilerEmbeddedStdlibPayload\n  (cond\n")
      (let
        [out : text_buf.TextBuf
          (embedded-stdlib-generate-lines manifest 0 header)]
        (begin
          (text_buf.append!
            out
            "    [else (CompilerEmbeddedStdlibPayloadNone)]))\n")
          (io.write-file output-path (text_buf.render out))
          0)))))

(define (main) : i64
  (if (= (io.arg-count) 2)
    (embedded-stdlib-generate (io.arg 1))
    (begin
      (io.print-error
        "usage: generate.tl <output compiler_embedded_stdlib_payload.tl>")
      2)))