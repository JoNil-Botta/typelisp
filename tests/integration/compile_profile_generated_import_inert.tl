;; compile_profile_generated_import_inert.tl - Fixture for inert generated
;; import follow-up compile-profile rows.
;; Retained for #2454 path-import compatibility: the generated module imports a
;; helper whose module name intentionally does not map to a dotted source path.
(defmacro (profile-generated-inert-import-module) : Module
  `(begin
    (module generated.profile_generated_import_inert)
    (import "compile_profile_generated_import_inert_dep.tl" module generated.profile_generated_import_inert_dep as dep)
    (define (answer) : i64
      (dep.answer))))

(import (profile-generated-inert-import-module) as generated_inert)

(define (main) : i64
  (generated_inert.answer))