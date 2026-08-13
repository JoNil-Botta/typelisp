;; Mixed syntax identities are one-word nominal values. Raw compiler integers,
;; including missing sentinels, must use the checked compatibility constructor.
(import compiler_intern)

(define (main) : i64
  (let
    [raw : i64 17]
    [typed : compiler_intern.InternSyntaxId raw]
    (begin
      (compiler_intern.intern-syntax-id-value typed)
      0)))