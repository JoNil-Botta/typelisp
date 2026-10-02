;; The provider is loaded through the bridge but never imported here, so its
;; variants are not visible unqualified (SPEC 4.4.3).
(import variant_resolution_bridge as bridge)

(define (main) : i64
  (let
    [outcome (Pass 42)]
    0))