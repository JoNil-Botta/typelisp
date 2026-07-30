;; The seed-built stage has no same-commit image yet. Stage1 builds the image
;; that is embedded in stage2, preserving the ordinary bootstrap handoff.
(define embedded-stdlib-tlci-bytes : (__tl_dyn-array u8)
  (make-array u8 0))
(define embedded-stdlib-tlci-source-hash : String
  "")