;; Build the deterministic freestanding deployment envelope around an ordinary
;; embedded stdlib `.tlci` image.
(import compiler_embedded_stdlib_tlci_encoder as encoder)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)

(define (main) : i64
  (if (!= (io.arg-count) 3)
    (begin
      (io.print-error "usage: encode-envelope <input.tlci> <output.tlch>\n")
      2)
    (let
      [input : String (io.arg 1)]
      [output : String (io.arg 2)]
      [source : String (byte_buf.to-string (io.read-file input))]
      [raw-len : i64 (string.string-length source)]
      (match (encoder.compiler-embedded-stdlib-tlci-encoder-encode source)
        [(encoder.ResultCompilerEmbeddedStdlibTlciEncoderBytes.Err message)
          (begin
            (io.print-error (str_cat.str-cat message "\n"))
            1)]
        [(encoder.ResultCompilerEmbeddedStdlibTlciEncoderBytes.Ok bytes)
          (let
            [compressed-len : i64 (array-length bytes)]
            [contents : byte_buf.ByteBuf (byte_buf.from-array bytes)]
            (begin
              (io.write-file output (byte_buf.as-bytes (& contents)))
              (io.print-format
                "{}"
                (str_cat.str-cat
                  "embedded stdlib tlci envelope: "
                  (string.int->string raw-len)
                  " -> "
                  (string.int->string compressed-len)
                  " bytes\n"))
              0))]))))