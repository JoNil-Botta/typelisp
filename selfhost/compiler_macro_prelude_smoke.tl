;; compiler_macro_prelude_smoke.tl - Imported stdlib macro smoke for selfhost sources (#1882).
(import "../stdlib/core_macros.tl" module stdlib.core-macros as core)

(define (compiler-macro-prelude-selfhost-smoke) : i64
  (let
    [value : i64 0]
    (begin
      (core/when true (set! value 7))
      (core/when false (set! value 1000))
      (core/unless false (set! value (* value 6)))
      (core/unless true (set! value 1000))
      value)))

(define (main) : i64
  (compiler-macro-prelude-selfhost-smoke))