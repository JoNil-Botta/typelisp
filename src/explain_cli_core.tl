;; explain_cli_core.tl - Long-form diagnostic code explanations.
;;
;; Detailed entries are append-only alongside the diagnostic codes themselves:
;; once published, a code and its meaning are never renumbered or reused.
(import stdlib.io)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import compiler_diagnostic as cdiag)

(defenum DiagnosticExplainLookup
  (DiagnosticExplainUnknown)
  (DiagnosticExplainKnownWithoutProse)
  (DiagnosticExplainDetailed String))

(define (diagnostic-explain-help-text) : String
  "Usage:
    typelisp explain <code>

Summary:
    Explain a TypeLisp diagnostic code.
")

(define (diagnostic-explain-e0201) : String
  "E0201: unbound name

Description:
    A name was used where no visible definition, parameter, or import provides it.

Minimal failing example:
    (define (main) : i64
      missing-value)

Fix:
    Define the name before using it, correct its spelling, or import the module
    that provides it. For example:

    (define missing-value : i64 42)
    (define (main) : i64
      missing-value)
")

(define (diagnostic-explain-e0202) : String
  "E0202: arity mismatch

Description:
    A function, constructor, or pattern received the wrong number of arguments.

Minimal failing example:
    (define (add [left : i64] [right : i64]) : i64
      (+ left right))
    (define (main) : i64
      (add 1))

Fix:
    Supply exactly the parameters required by the declaration. Here, call
    `(add 1 2)`.
")

(define (diagnostic-explain-e0203) : String
  "E0203: non-exhaustive match

Description:
    A match expression does not cover every possible value of its scrutinee.

Minimal failing example:
    (defenum Choice (Yes) (No))
    (define (score [choice : Choice]) : i64
      (match choice
        [(Yes) 1]))

Fix:
    Add an arm for every missing variant, or use a wildcard arm when one
    fallback behavior is correct. Here, add `[(No) 0]`.
")

(define (diagnostic-explain-e0204) : String
  "E0204: unknown struct field

Description:
    A field access or update names a field that the struct does not declare.

Minimal failing example:
    (defstruct Point (x i64) (y i64))
    (define (main) : i64
      (let
        [point : Point (Point 1 2)]
        point.z))

Fix:
    Use one of the fields listed by the diagnostic, or add the intended field
    to the struct definition. Here, use `point.x` or `point.y`.
")

(define (diagnostic-explain-e0205) : String
  "E0205: region escape

Description:
    A value tied to an arena or lexical region would outlive the storage that
    owns it.

Minimal failing example:
    (import stdlib.string)
    (define (main) : String
      (with-arena phase (string.int->string 41)))

Fix:
    Consume the region-owned value before leaving its scope, or copy only data
    whose ownership can safely move outward. For example, compute and return an
    `i64` length inside the `with-arena` body instead of returning the String.
")

(define (diagnostic-explain-e0206) : String
  "E0206: type mismatch

Description:
    An expression's inferred type does not match the type required at that
    position.

Minimal failing example:
    (define (main) : i64
      true)

Fix:
    Change the expression to produce the required type, or change the declared
    type when that is the intended contract. Here, return an `i64` such as `0`.
")

(define (diagnostic-explain-lookup [code : String]) : DiagnosticExplainLookup
  (cond
    [(string.eq code (cdiag.compiler-diagnostic-code-typecheck-unbound-name))
      (DiagnosticExplainDetailed (diagnostic-explain-e0201))]
    [(string.eq code (cdiag.compiler-diagnostic-code-typecheck-arity-mismatch))
      (DiagnosticExplainDetailed (diagnostic-explain-e0202))]
    [(string.eq
        code
        (cdiag.compiler-diagnostic-code-typecheck-non-exhaustive-match))
      (DiagnosticExplainDetailed (diagnostic-explain-e0203))]
    [(string.eq
        code
        (cdiag.compiler-diagnostic-code-typecheck-unknown-struct-field))
      (DiagnosticExplainDetailed (diagnostic-explain-e0204))]
    [(string.eq code (cdiag.compiler-diagnostic-code-typecheck-region-escape))
      (DiagnosticExplainDetailed (diagnostic-explain-e0205))]
    [(string.eq code (cdiag.compiler-diagnostic-code-typecheck-type-mismatch))
      (DiagnosticExplainDetailed (diagnostic-explain-e0206))]
    [(or
        (string.eq code (cdiag.compiler-diagnostic-code-parse))
        (string.eq code (cdiag.compiler-diagnostic-code-typecheck)))
      DiagnosticExplainKnownWithoutProse]
    [else DiagnosticExplainUnknown]))

(define (diagnostic-explain-known-without-prose [code : String]) : String
  (str_cat.str-cat
    code
    ": this diagnostic code is recognized, but no long-form explanation is available yet.\n"))

(define (diagnostic-explain-run-from [idx : i64] [count : i64]) : i64
  (if (not (= count (+ idx 1)))
    (begin
      (io.print-error
        "explain: expected one diagnostic code (for example E0201)\n")
      1)
    (let
      [code : String (io.arg idx)]
      (match (diagnostic-explain-lookup code)
        [(DiagnosticExplainDetailed text)
          (begin
            (io.print-format "{}" text)
            0)]
        [DiagnosticExplainKnownWithoutProse
          (begin
            (io.print-format "{}" (diagnostic-explain-known-without-prose code))
            0)]
        [DiagnosticExplainUnknown
          (begin
            (io.print-error
              (str_cat.str-cat "explain: unknown diagnostic code `" code "`\n"))
            1)]))))

(cfg
  test
  (define (diagnostic-explain-detailed-entry-ok? [code : String]) : bool
    (match (diagnostic-explain-lookup code)
      [(DiagnosticExplainDetailed text)
        (and
          (string.contains (& text) "Description:")
          (string.contains (& text) "Minimal failing example:")
          (string.contains (& text) "Fix:"))]
      [_ false])))

(cfg
  test
  (test
    diagnostic-explain-registry
    (unless
      (and
        (diagnostic-explain-detailed-entry-ok?
          (cdiag.compiler-diagnostic-code-typecheck-unbound-name))
        (diagnostic-explain-detailed-entry-ok?
          (cdiag.compiler-diagnostic-code-typecheck-arity-mismatch))
        (diagnostic-explain-detailed-entry-ok?
          (cdiag.compiler-diagnostic-code-typecheck-non-exhaustive-match))
        (diagnostic-explain-detailed-entry-ok?
          (cdiag.compiler-diagnostic-code-typecheck-unknown-struct-field))
        (diagnostic-explain-detailed-entry-ok?
          (cdiag.compiler-diagnostic-code-typecheck-region-escape))
        (diagnostic-explain-detailed-entry-ok?
          (cdiag.compiler-diagnostic-code-typecheck-type-mismatch))
        (match (diagnostic-explain-lookup
          (cdiag.compiler-diagnostic-code-parse))
          [DiagnosticExplainKnownWithoutProse true]
          [_ false])
        (match (diagnostic-explain-lookup
          (cdiag.compiler-diagnostic-code-typecheck))
          [DiagnosticExplainKnownWithoutProse true]
          [_ false])
        (match (diagnostic-explain-lookup "E9999")
          [DiagnosticExplainUnknown true]
          [_ false]))
      (io.panic "explain: diagnostic registry test failed"))))