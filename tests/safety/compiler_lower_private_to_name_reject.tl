;; Lower-private structural identities are compiler-internal keys. They cannot
;; enter a renderable-name API without an explicit, role-specific reduction.
(import compiler_intern)
(import compiler_intern_state)

(define (main) : i64
  (let
    [private : compiler_intern_state.InternLowerPrivateIdentity
      (compiler_intern_state.InternLowerPrivateIdentity 1)]
    (begin
      (compiler_intern.intern-id-str private)
      0)))