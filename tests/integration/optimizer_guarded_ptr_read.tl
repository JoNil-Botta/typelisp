;; The packed handle's u64 word must be compared with i64 signedness. Folding
;; its non-positive guard the other way executes the invalid pointer read.
(import compiler_intern_state as cis)

(define (main) : i64
  (if (cis.intern-structural-session-valid?
    (cis.InternStructuralSessionHandle -1))
    7
    134))