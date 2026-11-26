;; Unannotated top-level defines using an (:opaque) type in its defining module
;; and in a same-package dotted descendant both check cleanly (#8733).
(module opaque_provider_unannotated_define_dep.extra)

(import opaque_provider_unannotated_define_dep as owner)

(define h2
  (owner.Handle 9))
(define sz2
  (comptime (size-of (type owner.Handle))))

(define (main) : i64
  (let
    [h1 : owner.Handle owner.h]
    (+ (+ h1.id owner.sz) (+ h2.id sz2))))