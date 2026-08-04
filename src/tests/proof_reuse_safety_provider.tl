;; Installed generated-module fixtures for the proof-reuse negative safety
;; matrix.  Every macro is complete (the type parameter has an explicit kind
;; constraint) and gives each generated module a family-specific, identity-keyed
;; name so the real loader can keep the scenarios independent.
(import stdlib.comptime)
(import stdlib.string)

(defmacro (proof-reuse-hidden-invalid [T : type (:kind i64 u8)]) : Module
  (let
    [module-name : Expr
      (expr-var
        (comptime.string-append "proof_reuse.hidden_invalid." (type-key T)))]
    `(begin
      (module ,module-name)
      ;; This declaration is intentionally unreferenced by the entry fixture.
      (define (hidden-invalid-value) : ,T
        300))))

(defmacro (proof-reuse-literal-narrowing [T : type (:kind i64 u8)]) : Module
  (let
    [module-name : Expr
      (expr-var
        (comptime.string-append "proof_reuse.literal_narrowing." (type-key T)))]
    `(begin
      (module ,module-name)
      (define (big) : ,T
        300))))

(defmacro (proof-reuse-bool-arithmetic [T : type (:kind i64 bool)]) : Module
  (let
    [module-name : Expr
      (expr-var
        (comptime.string-append "proof_reuse.bool_arithmetic." (type-key T)))]
    `(begin
      (module ,module-name)
      (define (plus-one [x : ,T]) : ,T
        (+ x 1)))))

(defmacro (proof-reuse-uncloneable-clone [T : type (:kind i64 function)]) : Module
  (let
    [module-name : Expr
      (expr-var
        (comptime.string-append "proof_reuse.uncloneable_clone." (type-key T)))]
    `(begin
      (module ,module-name)
      (define (copy [x : ,T]) : ,T
        (clone x)))))

(defmacro (proof-reuse-equality-sensitive [T : type (:kind i64 u8)]) : Module
  (let
    [module-name : Expr
      (expr-var
        (comptime.string-append "proof_reuse.equality_sensitive." (type-key T)))]
    `(begin
      (module ,module-name)
      (define (same [a : ,T] [b : ,T]) : bool
        (= a b)))))

(defmacro (proof-reuse-cleanup-substitution [T : type (:kind i64 struct)]) : Module
  (let
    [module-name : Expr
      (expr-var
        (comptime.string-append
          "proof_reuse.cleanup_substitution."
          (type-key T)))]
    `(begin
      (module ,module-name)
      (defstruct GeneratedCleanupValue
        (value ,T)))))

(defmacro (proof-reuse-reflection-fixed-shape [T : type (:kind i64 bool)]) : Module
  (let
    [module-name : Expr
      (expr-var
        (comptime.string-append
          "proof_reuse.reflection_fixed_shape."
          (type-key T)))]
    (if (__tl_string_eq (type-kind T) "i64")
      `(begin
        (module ,module-name)
        (define fixed : (Array i64 2)
          (array 1 2)))
      `(begin
        (module ,module-name)
        (define fixed : (Array i64 2)
          (array 1 true))))))

(defmacro (proof-reuse-nested-inner [T : type (:kind i64 u8)]) : Module
  (let
    [module-name : Expr
      (expr-var
        (comptime.string-append "proof_reuse.nested_inner." (type-key T)))]
    `(begin
      (module ,module-name)
      ;; The outer fixture intentionally never demands this declaration.
      (define (hidden-inner-invalid) : ,T
        300))))

(defmacro (proof-reuse-nested-outer [T : type (:kind i64 u8)]) : Module
  (let
    [module-name : Expr
      (expr-var
        (comptime.string-append "proof_reuse.nested_outer." (type-key T)))]
    `(begin
      (module ,module-name)
      (import (proof-reuse-nested-inner ,T) as inner))))

;; The helper/callee below is deliberately fixed at i64.  The generated
;; caller's own T signature is structurally substitutable, but its unchanged
;; nonlocal callee must force the u8 identity through concrete checking.
(defmacro (proof-reuse-fixed-signature-call [T : type (:kind i64 u8)]) : Module
  (let
    [module-name : Expr
      (expr-var
        (comptime.string-append
          "proof_reuse.fixed_signature_call."
          (type-key T)))]
    `(begin
      (module ,module-name)
      (define (proof-reuse-fixed-signature-call-only-i64 [x : i64]) : i64
        x)
      (define (proof-reuse-fixed-signature-call [x : ,T]) : ,T
        (proof-reuse-fixed-signature-call-only-i64 x)))))

;; This value is likewise fixed at i64 while the generated declaration's
;; return type follows T.  A u8 identity must retain the return mismatch.
(defmacro (proof-reuse-fixed-value [T : type (:kind i64 u8)]) : Module
  (let
    [module-name : Expr
      (expr-var
        (comptime.string-append "proof_reuse.fixed_value." (type-key T)))]
    `(begin
      (module ,module-name)
      (define proof-reuse-fixed-value-i64 : i64
        42)
      (define (proof-reuse-fixed-value [x : ,T]) : ,T
        proof-reuse-fixed-value-i64))))

;; A fixed local annotation sits on the value-flow edge from x to y.  The
;; i64 seed is valid, but the later u8 identity must retain the concrete let
;; binding mismatch.
(defmacro (proof-reuse-fixed-local-annotation [T : type (:kind i64 u8)]) : Module
  (let
    [module-name : Expr
      (expr-var
        (comptime.string-append
          "proof_reuse.fixed_local_annotation."
          (type-key T)))]
    `(begin
      (module ,module-name)
      (define (proof-reuse-fixed-local-annotation [x : ,T]) : ,T
        (let
          [y : i64 x]
          y)))))

;; The parameter follows T, while the return type is deliberately fixed i64.
(defmacro (proof-reuse-fixed-return [T : type (:kind i64 u8)]) : Module
  (let
    [module-name : Expr
      (expr-var
        (comptime.string-append "proof_reuse.fixed_return." (type-key T)))]
    `(begin
      (module ,module-name)
      (define (proof-reuse-fixed-return [x : ,T]) : i64
        x))))

;; Field access reads a fixed Box field while the generated payload follows T;
;; the later u8 identity must retain the concrete return mismatch.
(defmacro (proof-reuse-fixed-field-access [T : type (:kind i64 u8)]) : Module
  (let
    [module-name : Expr
      (expr-var
        (comptime.string-append "proof_reuse.fixed_field_access." (type-key T)))]
    `(begin
      (module ,module-name)
      (defstruct Box
        (fixed i64)
        (payload ,T))
      (define (proof-reuse-fixed-field-access [value : Box]) : ,T
        (struct-get value fixed)))))

;; `if` supplies an implicit bool condition expectation not represented in the
;; expression's own type syntax, so the u8 identity must be checked concretely.
(defmacro (proof-reuse-substituted-condition [T : type (:kind bool u8)]) : Module
  (let
    [module-name : Expr
      (expr-var
        (comptime.string-append
          "proof_reuse.substituted_condition."
          (type-key T)))]
    `(begin
      (module ,module-name)
      (define (proof-reuse-substituted-condition [x : ,T]) : ,T
        (if x
          x
          x)))))

;; Constructor calls carry fixed field expectations that are not visible in
;; the call AST; changing T must not reuse the i64 constructor check.
(defmacro (proof-reuse-fixed-constructor-argument [T : type (:kind i64 u8)]) : Module
  (let
    [module-name : Expr
      (expr-var
        (comptime.string-append
          "proof_reuse.fixed_constructor_argument."
          (type-key T)))]
    `(begin
      (module ,module-name)
      (defstruct Box
        (fixed i64)
        (payload ,T))
      (define (proof-reuse-fixed-constructor-argument [x : ,T]) : Box
        (Box x x)))))

;; The two generated identities intentionally have different sibling catalogs:
;; the `extra=true` expansion carries one additional declaration while the
;; `extra=false` expansion does not.  Box and identity substitute T directly,
;; so those declarations remain independently safe to reuse.
(defmacro (proof-reuse-partial-catalog
  [T : type (:kind i64 i32)]
  [extra : String]) : Module
  (let
    [extra-text : String (comptime.expr-string-value extra)]
    [module-name : Expr
      (expr-var
        (comptime.string-append
          (comptime.string-append "proof_reuse.partial_catalog." (type-key T))
          (if (string.eq extra-text "extra")
            ".extra"
            ".base")))]
    (if (string.eq extra-text "extra")
      `(begin
        (module ,module-name)
        (defstruct Box
          (value ,T))
        (define (identity [x : ,T]) : ,T
          x)
        (define partial-catalog-extra : i64
          0))
      `(begin
        (module ,module-name)
        (defstruct Box
          (value ,T))
        (define (identity [x : ,T]) : ,T
          x)))))

;; The generated shared value references a sibling helper whose signature
;; changes with the String operand. The first identity is valid; the second
;; must be checked concretely so its bool helper is rejected by integer +.
(defmacro (proof-reuse-sibling-value-dependency
  [T : type (:kind i64 i32)]
  [flavor : String]) : Module
  (let
    [flavor-text : String (comptime.expr-string-value flavor)]
    [module-name : Expr
      (expr-var
        (comptime.string-append
          (comptime.string-append
            (comptime.string-append
              "proof_reuse.sibling_value_dependency."
              (type-key T))
            ".")
          flavor-text))]
    (if (string.eq flavor-text "integer")
      `(begin
        (module ,module-name)
        (define (helper) : i64
          1)
        (define shared
          (+ (helper) 1)))
      `(begin
        (module ,module-name)
        (define (helper) : bool
          true)
        (define shared
          (+ (helper) 1))))))