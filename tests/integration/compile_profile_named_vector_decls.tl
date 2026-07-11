;; compile_profile_named_vector_decls.tl - Fixture for named vector Decls macro profile rows.
(import stdlib.vector)

(defstruct ProfileVecDecl
  (id i64))

(vector.family ProfileVecDecl ProfileVecDeclList profile-vec-decl-list)

(defstruct ProfileVecDoc
  (uri String)
  (decls ProfileVecDeclList))

(vector.family ProfileVecDoc ProfileVecDocList profile-vec-doc-list)

(defstruct ProfileVecSpan
  (start i64)
  (end i64))

(vector.family ProfileVecSpan ProfileVecSpanList profile-vec-span-list)

(define (profile-core-after-vector [n : i64]) : i64
  (cond [(and (> n 0) (< n 10)) 42] [else 0]))

(define (main) : i64
  (profile-core-after-vector 3))