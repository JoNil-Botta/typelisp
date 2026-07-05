;; compile_profile_generated_import.tl - Fixture for generated import follow-up
;; compile-profile rows.
(defmacro (profile-generated-import-module) : Module
  `(begin
    (module generated.profile_generated_import)
    (import stdlib.string)
    (define (answer) : i64
      (if (string.eq "ok" "ok")
        42
        1))))

(import (profile-generated-import-module) as generated_import)

(define (main) : i64
  (generated_import.answer))
