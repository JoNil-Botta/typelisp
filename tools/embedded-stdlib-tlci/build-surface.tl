;; Build relocatable frontend-surface sections separately from native TLCl
;; production so compiler-internal nominal identities never cross the byte
;; boundary between the two translation units.
(import "../../src/compiler_prelude_surface_producer.tl")
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)

(define (main) : i64
  (if (not (= (io.arg-count) 6))
    (begin
      (io.print-error
        "usage: build-surface <stdlib-root> <output> <linux|windows> <build-hash> <source-hash>\n")
      2)
    (let
      [root : String (io.arg 1)]
      [output : String (io.arg 2)]
      [target : String (io.arg 3)]
      [build-hash : String (io.arg 4)]
      [source-hash : String (io.arg 5)]
      (if (or (string.eq target "linux") (string.eq target "windows"))
        (match (prelude-surface-build
          root
          source-hash
          build-hash
          (string.eq target "windows"))
          [(ResultPreludeSurface.Err message)
            (begin
              (io.print-error (str-cat "prelude surface: " message "\n"))
              1)]
          [(ResultPreludeSurface.Ok bytes)
            (let
              [contents : byte_buf.ByteBuf (byte_buf.from-array bytes)]
              (begin
                (io.write-file output (byte_buf.as-bytes (& contents)))
                0))])
        (begin
          (io.print-error (str-cat "invalid host target: " target "\n"))
          2)))))