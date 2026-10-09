;; The defining module's dotted descendant matches its opaque types with
;; or-patterns and by-name struct patterns (#6999).
(import opaque_dep.patterns)

(define (main) : i64
  (patterns.weigh 41))