;; Code a macro expands into a module is checked as that module's code: the
;; defining module's macro cannot construct the type here (#6999).
(import opaque_dep)

(define (main) : i64
  (begin
    (opaque_dep.make-connection 3)
    0))