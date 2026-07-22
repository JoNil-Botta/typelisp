;; compile_profile_macro_detach_unchanged.tl - Imported no-change macro walk.
(import "compile_profile_macro_detach_unchanged_dep.tl")

(define (main) : i64
  (macro-detach-unchanged-value))