;; Unannotated top-level defines using an (:opaque) type in its defining module
;; must receive the declaration's provider during top-env and local-env builds (#8733).
(module opaque_provider_unannotated_define_dep)

(defstruct Handle
  (:opaque)
  (id i64))

(define h
  (Handle 7))
(define sz
  (comptime (size-of (type Handle))))