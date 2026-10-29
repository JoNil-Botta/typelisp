;; Production compiler build input, generated before each self-host stage.
;;
;; TLCH v2 stores the prelude and independently loadable native entries behind
;; one authenticated index and shared Huffman model. The runtime decodes only
;; requested frames; inspection reconstructs the exact ordinary `.tlci` image.
(include-bin
  embedded-stdlib-tlci-bytes
  "../target/embedded-stdlib-tlci/stdlib.tlci.tlch")

(include-str embedded-stdlib-tlci-source-hash "../target/embedded-stdlib-tlci/source-hash.txt")

(define (embedded-stdlib-tlci-source-hash-shared-view) : String
  (unsafe
    (ptr-read (ptr-addr-of embedded-stdlib-tlci-source-hash))))