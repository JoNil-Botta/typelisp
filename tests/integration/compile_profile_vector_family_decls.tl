;; compile_profile_vector_family_decls.tl - Fixture for vector-family Decls profile rows.
(import stdlib.vector_family as vf)

(defstruct ProfileVecPoint
  (x i64)
  (y i64))

(vf.vector-family ProfileVecPoint ProfileVecPointVec profile-vec-point-vec)

(defstruct ProfileVecSpan
  (points ProfileVecPointVec)
  (start i64)
  (len i64))

(vf.vector-family ProfileVecSpan ProfileVecSpanVec profile-vec-span-vec)

(define (main) : i64
  42)