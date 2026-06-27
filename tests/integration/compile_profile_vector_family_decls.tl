;; compile_profile_vector_family_decls.tl - Fixture for vector-family Decls profile rows.
(import stdlib.vector_family as vf)

(defstruct ProfileVecDecl
  (id i64))

(vf.vector-family ProfileVecDecl ProfileVecDeclList profile-vec-decl-list)

(defstruct ProfileVecDoc
  (uri String)
  (decls ProfileVecDeclList))

(vf.vector-family ProfileVecDoc ProfileVecDocList profile-vec-doc-list)

(define (profile-core-after-vector [n : i64]) : i64
  (cond [(and (> n 0) (< n 10)) 42] [else 0]))

(define (main) : i64
  (profile-core-after-vector 3))