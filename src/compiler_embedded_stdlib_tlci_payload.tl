;; Production compiler build input, generated before each self-host stage.
;;
;; The image is an ordinary `.tlci` until the build-time encoder wraps it in the
;; versioned compiler-owned TLCH deployment envelope. `include-bin` embeds that
;; envelope byte for byte; `compiler_embedded_stdlib_tlci` expands the exact
;; ordinary image on demand before the existing parser and mapper see it.
(include-bin
  embedded-stdlib-tlci-bytes
  "../target/embedded-stdlib-tlci/stdlib.tlci.tlch")

(include-str embedded-stdlib-tlci-source-hash "../target/embedded-stdlib-tlci/source-hash.txt")

(define (embedded-stdlib-tlci-source-hash-shared-view) : String
  (cfg
    stage0-seed-bootstrap
    embedded-stdlib-tlci-source-hash
    (unsafe
      (ptr-read (ptr-addr-of embedded-stdlib-tlci-source-hash)))))