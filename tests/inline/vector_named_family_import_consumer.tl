;; vector_named_family_import_consumer.tl - imported named vector-family generated names remain visible.
(import stdlib.test)
(import stdlib.io)

;; Retained for #2454 path-import compatibility: this fixture checks that a path
;; import still exposes generated family names in the importing module.
(import "vector_named_family_import_provider.tl")

(define (imported-vector-family-helper-ok?) : bool
  (let
    [points : ImportedVecFamilyPointVec (imported-vec-family-point-vec-new)]
    [docs : ImportedVecFamilyDocVec (imported-vec-family-doc-vec-new)]
    (begin
      (imported-vec-family-point-vec-push
        (&mut points)
        (ImportedVecFamilyPoint 5))
      (imported-vec-family-doc-vec-push
        (&mut docs)
        (ImportedVecFamilyDoc "doc" points))
      (and
        (= (imported-vec-family-point-vec-len (& points)) 1)
        (= (imported-vec-family-doc-vec-len (& docs)) 1)))))

(test
  imported-vector-family-generated-names
  (unless
    (imported-vector-family-helper-ok?)
    (io.panic "imported vector-family generated names failed")))