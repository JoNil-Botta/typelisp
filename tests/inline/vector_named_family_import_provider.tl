;; vector_named_family_import_provider.tl - Imported named vector-family generator fixture.
(import stdlib.vector as vf)

(defstruct ImportedVecFamilyPoint
  (x i64))

(vf.family
  ImportedVecFamilyPoint
  ImportedVecFamilyPointVec
  imported-vec-family-point-vec)

(defstruct ImportedVecFamilyDoc
  (uri String)
  (points ImportedVecFamilyPointVec))

(vf.family
  ImportedVecFamilyDoc
  ImportedVecFamilyDocVec
  imported-vec-family-doc-vec)