;; Exercise the embedded bytes through the production loader and registration
;; entry. The exact count is pinned by the current 42-module source manifest so
;; additions/removals require regenerating and reviewing the catalog together.
(import "../../src/compiler_embedded_stdlib_tlci.tl")
(import stdlib.io)
(import stdlib.str_cat)
(import stdlib.string)

(define (main) : i64
  (match (compiler-embedded-stdlib-tlci-validate)
    [(CompilerEmbeddedStdlibTlciValidation.Err message)
      (begin
        (io.print-error
          (str_cat.str-cat "embedded stdlib tlci validation failed: " message))
        1)]
    [(CompilerEmbeddedStdlibTlciValidation.Ok count)
      (if (= count 92)
        42
        (begin
          (io.print-error
            (str_cat.str-cat
              "embedded stdlib tlci macro count mismatch: expected 92, got "
              (string.int->string count)))
          2))]))