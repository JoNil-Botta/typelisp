;; Prove that the deployment envelope expands to the exact ordinary TLCI bytes.
(import compiler_embedded_stdlib_tlci_codec as codec)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.str_cat_runtime as str_cat)

(define (embedded-stdlib-tlci-envelope-eq?
  [left : (& left (__tl_dyn-array u8))]
  [right : (& right (__tl_dyn-array u8))]) : bool
  (let
    [index : i64 0]
    [same : bool (= (array-length left) (array-length right))]
    (begin
      (while (and same (< index (array-length left)))
        (begin
          (if (!= (array-ref left index) (array-ref right index))
            (set! same false)
            unit)
          (set! index (+ index 1))))
      same)))

(define (main) : i64
  (if (!= (io.arg-count) 3)
    (begin
      (io.print-error "usage: verify-envelope <input.tlci> <input.tlch>\n")
      2)
    (let
      [raw : (__tl_dyn-array u8) (byte_buf.to-array (io.read-file (io.arg 1)))]
      [envelope : (__tl_dyn-array u8)
        (byte_buf.to-array (io.read-file (io.arg 2)))]
      (match (codec.compiler-embedded-stdlib-tlci-codec-decode
        (& envelope)
        268435456)
        [(codec.CompilerEmbeddedStdlibTlciCodecBytes.Err message)
          (begin
            (io.print-error (str_cat.str-cat message "\n"))
            1)]
        [(codec.CompilerEmbeddedStdlibTlciCodecBytes.Ok expanded)
          (if (embedded-stdlib-tlci-envelope-eq? (& raw) (& expanded))
            0
            (begin
              (io.print-error
                "embedded stdlib tlci envelope: expanded bytes differ\n")
              1))]))))