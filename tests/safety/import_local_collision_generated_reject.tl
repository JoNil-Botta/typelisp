;; A declaration a module-scope generator emits is a local declaration once
;; expansion completes, so it collides with the unqualified import of the
;; same name.
(import import_local_collision_dep.answer)

(defmacro (emit-answer) : Decls
  `(define answer : i64
    1))

(emit-answer)

(define (main) : i64
  answer)