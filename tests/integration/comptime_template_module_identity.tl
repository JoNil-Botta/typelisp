;; Comptime templates are identified by module and name, and their instances
;; live in their template's module (#8597):
;; - this module's `pick` and the dependency's `pick` are different templates,
;;   so each module's calls run its own body;
;; - an instance of the dependency's `bump` calls the dependency's private
;;   `helper`;
;; - an instance created inside another instance (`twice` calling `pick`)
;;   resolves `pick` in the template's module, not the caller's;
;; - a binder at the call site does not shadow a template inside the
;;   instance's body.
(import comptime_template_module_identity_dep as dep)

(define (pick [comptime T : type] [x : T]) : T
  (+ x 100))

(define (wrap [comptime T : type] [x : T]) : T
  (pick (type T) x))

(define (shadowed [pick : i64]) : i64
  (+ pick (wrap (type i64) 2)))

(define (main) : i64
  (cond
    [(!= (pick (type i64) 5) 105) 1]
    [(!= (dep.dep-pick) 1) 2]
    [(!= (dep.dep-bump) 1001) 3]
    [(!= (dep.dep-twice) 6) 4]
    [(!= (shadowed 1) 103) 5]
    [else 42]))