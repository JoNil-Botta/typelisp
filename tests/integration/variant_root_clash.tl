;; The entry module declares a variant spelled like one a transitively imported
;; module builds bare in an argument position (variant_root_clash_lib.tl).
;; Lowering must type that module's bare `Cast` from its own enum, not from this
;; entry-module binding of the same spelling.
(import variant_root_clash_mid as mid)

(defenum Local
  (Cast)
  (Other))

(define (local-value [local : Local]) : i64
  (match local
    [Cast 0]
    [Other 2]))

(define (main) : i64
  (+ (mid.via 40) (local-value Cast)))