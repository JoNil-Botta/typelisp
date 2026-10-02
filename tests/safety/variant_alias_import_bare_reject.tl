;; An aliased import does not bring the provider's variants into the
;; unqualified namespace; only an expected enum type resolves them.
(import variant_resolution_provider as provider)

(define (main) : i64
  (let
    [outcome (Pass 42)]
    0))