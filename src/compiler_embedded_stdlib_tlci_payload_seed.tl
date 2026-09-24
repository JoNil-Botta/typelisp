;; Test builds carry no same-commit image; production builds embed the image
;; that the previous stage built (see compiler_embedded_stdlib_tlci_payload).
;;
;; An empty payload is the "no image" signal for the loader, which is why this
;; variant carries no compressed framing: `compiler_embedded_stdlib_tlci` reads
;; a zero-length payload as unavailable before it looks for a header.
(define embedded-stdlib-tlci-bytes : (__tl_dyn-array u8)
  (__tl_make-array u8 0))
(define embedded-stdlib-tlci-source-hash : String
  "")

(define (embedded-stdlib-tlci-source-hash-shared-view) : String
  (unsafe
    (ptr-read (ptr-addr-of embedded-stdlib-tlci-source-hash))))