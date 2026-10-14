;; A macro call inside another macro's template is invoked from the file that
;; holds the template: the nested frame names the dependency module's line,
;; not a position in the file that expanded the outer call.
(import macro_nested_frame_dep as dep)

(define (main) : i64
  (let
    [x : i64 42]
    (dep.outer-pointer x)))