;; compile_profile_vector_family_decls.tl - Fixture for vector-family Decls profile rows.
(import stdlib.vector_family as vf)

(defstruct ProfileVecDecl
  (id i64))

(vf.vector-family ProfileVecDecl ProfileVecDeclList profile-vec-decl-list)

(defstruct ProfileVecDoc
  (uri String)
  (decls ProfileVecDeclList))

(vf.vector-family ProfileVecDoc ProfileVecDocList profile-vec-doc-list)

(define (main) : i64
  42)