;; A module without generators has its final declarations at load time, so the
;; loader keeps rejecting a missing selected item immediately.
(import decls_generated_conflict_left.missing as unused)

(define (main) : i64
  0)