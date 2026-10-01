;; compile_profile_module_view_release.tl - lowering releases each module's
;; local view after the module's last declaration segment (#8372). The entry
;; and module A are each left for an imported module and revisited, A's first
;; segment holds no declarations, the entry's last segment ends the program,
;; `stdlib.comptime` is lowered through the runtime-skip path, and A reaches
;; module B's function `b` through an alias of the same name. Every name must
;; resolve through its own module's view.
(import stdlib.comptime as _comptime)
(import module_view_release_a as a)

(defmacro (twice [value : Expr]) : Expr
  `(* 2 ,value))

(define (six) : i64
  6)

(define (helper) : i64
  (twice (six)))

(define (main) : i64
  (if (and (= (a.helper) 31) (= (a.after) 5) (= (helper) 12))
    (- (+ (a.helper) (helper)) 1)
    1))