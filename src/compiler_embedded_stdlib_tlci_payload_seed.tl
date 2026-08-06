;; The seed-built stage has no same-commit image yet. Stage1 builds the image
;; that is embedded in stage2, preserving the ordinary bootstrap handoff.
;;
;; An empty payload is the "no image" signal for the loader, which is why this
;; variant carries no compressed framing: `compiler_embedded_stdlib_tlci` reads
;; a zero-length payload as unavailable before it looks for a header.
(define embedded-stdlib-tlci-bytes : (__tl_dyn-array u8)
  (make-array u8 0))
(define embedded-stdlib-tlci-source-hash : String
  "")

(define (embedded-stdlib-tlci-source-hash-shared-view) : String
  (unsafe
    (ptr-read (ptr-addr-of embedded-stdlib-tlci-source-hash))))