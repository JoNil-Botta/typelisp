(import stdlib.byte_buf)
(import stdlib.io)

(define (main) : unit
  (let
    [contents : String "alpha"]
    (io.write-file
      "tests/integration/missing-parent-zzz/output.txt"
      (byte_buf.str-as-bytes (& contents)))))