;; Production compiler build input, generated before each self-host stage.
(include-bin
  embedded-stdlib-tlci-bytes
  "../target/embedded-stdlib-tlci/stdlib.tlci")

(include-str embedded-stdlib-tlci-source-hash "../target/embedded-stdlib-tlci/source-hash.txt")