;; compile_profile_macro_detach_unchanged.tl - Imported no-change macro walk.
(import compile_profile_macro_detach_unchanged_dep as dep)

(define (main) : i64
  (dep.macro-detach-unchanged-value))