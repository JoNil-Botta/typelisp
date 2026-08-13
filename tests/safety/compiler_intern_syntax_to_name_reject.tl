;; Structural syntax identity can cross the mixed reader/macro boundary, but it
;; cannot enter a renderable-only API without explicit source-name reduction.
(import compiler_intern)

(define (main) : i64
  (let
    [syntax : compiler_intern.InternSyntaxId
      (compiler_intern.intern-syntax-id-from-raw 999999999999999)]
    (begin
      (compiler_intern.intern-id-str syntax)
      0)))