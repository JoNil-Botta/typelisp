;; The defining module's dotted descendant constructs, projects and matches
;; its opaque types (#6999).
(import opaque_dep.inner)

(define (main) : i64
  (inner.make-and-read 44))