;; Production compiler build input, generated before each self-host stage.
;;
;; The image is embedded compressed. `include-str-lzss` compresses the file's
;; exact bytes at the loader boundary -- it neither decodes nor validates them
;; as text -- so the comptime image round-trips byte for byte, and the
;; published compiler carries roughly 1.6 MB of `.data` instead of 5.0 MB.
;; `compiler_embedded_stdlib_tlci` expands the payload on demand.
(include-str-lzss
  embedded-stdlib-tlci-bytes
  "../target/embedded-stdlib-tlci/stdlib.tlci")

(include-str embedded-stdlib-tlci-source-hash "../target/embedded-stdlib-tlci/source-hash.txt")

(define (embedded-stdlib-tlci-source-hash-shared-view) : String
  (cfg
    stage0-seed-bootstrap
    embedded-stdlib-tlci-source-hash
    (unsafe
      (ptr-read (ptr-addr-of embedded-stdlib-tlci-source-hash)))))