;; module_macro_generated_global_init.tl - generated module top-level values
;; run their hidden runtime initializers before imported code reads them.
(import stdlib.test)

(defmacro (global-module) : Module
  `(begin
    (module generated.global_init_user)
    (define answer : i64
      (+ 40 2))
    (define (read-answer) : i64
      answer)))

(import (global-module) as generated)

(test
  generated-module-global-initializer-runs
  (test.assert-i64-eq
    generated.answer
    42
    "generated module global initialized through alias"))

(test
  generated-module-global-initializer-visible-to-generated-function
  (test.assert-i64-eq
    (generated.read-answer)
    42
    "generated module function reads initialized global"))