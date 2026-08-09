;; lint_smoke.tl - Runnable smoke for lint_core.tl.
(import stdlib.string)
(import compiler_builtin_ids as cbi)
(import lint_core)
(import lint_core_tests)
(import compiler_ast_types as ast)
(import stdlib.io)

(define (lint-smoke-string-append-source) : String
  "(define (main) : i64 (string.string-length (string.append \"a\" \"b\")))")

(define (lint-smoke-string-concat-source) : String
  "(define (main) : i64 (string.string-length (string.concat \"a\" \"b\")))")

(define (lint-smoke-string-concat5-source) : String
  "(define (main) : i64
  (string.string-length (string.concat5 \"a\" \"b\" \"c\" \"d\" \"e\")))")

(define (lint-smoke-nested-string-append-source) : String
  "(define (main) : i64
  (string.string-length (string.append \"a\" (string.append \"b\" \"c\"))))")

(define (lint-smoke-loop-string-append-source) : String
  "(define (main) : i64
  (let
    [i : i64 0]
    [out : String \"\"]
    (begin
      (while (< i 3)
        (begin
          (set! out (string.append out \"x\"))
          (set! i (+ i 1))))
      (string.string-length out))))")

(define (lint-smoke-deprecated-string-concat-self-test) : i64
  (begin
    (if (=
      (lint_core.lint-findings-count
        (lint_core.lint-deprecated-string-concat-scan
          (lint-smoke-string-append-source)
          (lint_core.lint-findings-empty)))
      1)
      unit
      (io.panic "lint: string-append call should be flagged"))
    (match (lint_core.lint-findings-get
      (lint_core.lint-deprecated-string-concat-scan
        (lint-smoke-string-concat-source)
        (lint_core.lint-findings-empty))
      0)
      [(lint_core.LintMaybeFinding.Some finding)
        (if (and
          (= (struct-get finding depth) 0)
          (string.eq
            (struct-get finding rule-id)
            (lint_core.lint-rule-deprecated-string-concat-id)))
          unit
          (io.panic "lint: string-concat finding should carry default metadata"))]
      [(lint_core.LintMaybeFinding.No)
        (io.panic "lint: string-concat call should produce a finding")])
    (if (=
      (lint_core.lint-findings-count
        (lint_core.lint-deprecated-string-concat-scan
          (lint-smoke-string-concat5-source)
          (lint_core.lint-findings-empty)))
      1)
      unit
      (io.panic "lint: string.concat5 call should be flagged"))
    (if (=
      (lint_core.lint-findings-count
        (lint_core.lint-deprecated-string-concat-scan
          (lint-smoke-nested-string-append-source)
          (lint_core.lint-findings-empty)))
      2)
      unit
      (io.panic "lint: nested string append should produce two findings"))
    (match (lint_core.lint-findings-get
      (lint_core.lint-deprecated-string-concat-scan
        (lint-smoke-nested-string-append-source)
        (lint_core.lint-findings-empty))
      1)
      [(lint_core.LintMaybeFinding.Some finding)
        (if (= (struct-get finding depth) 1)
          unit
          (io.panic "lint: nested string append should carry chain depth"))]
      [(lint_core.LintMaybeFinding.No)
        (io.panic "lint: nested string append should produce a chain finding")])
    (match (lint_core.lint-findings-get
      (lint_core.lint-deprecated-string-concat-scan
        (lint-smoke-loop-string-append-source)
        (lint_core.lint-findings-empty))
      0)
      [(lint_core.LintMaybeFinding.Some finding)
        (if (= (struct-get finding depth) 2)
          unit
          (io.panic "lint: loop string append should carry loop depth"))]
      [(lint_core.LintMaybeFinding.No)
        (io.panic "lint: loop string append should produce a finding")])
    42))

(define (lint-smoke-nested-str-cat-self-test) : i64
  (let
    [vx : i64 (lint_core_tests.lint-test-var "x")]
    [vy : i64 (lint_core_tests.lint-test-var "y")]
    [vz : i64 (lint_core_tests.lint-test-var "z")]
    [str-cat-callee : i64 (lint_core_tests.lint-test-var "str-cat")]
    [str-cat-yz : i64
      (ast.ast-expr-call
        str-cat-callee
        (lint_core_tests.lint-test-expr-list2 vy vz))]
    [nested-str-cat : i64
      (ast.ast-expr-call
        str-cat-callee
        (lint_core_tests.lint-test-expr-list2 vx str-cat-yz))]
    [flat-str-cat : i64
      (ast.ast-expr-call
        str-cat-callee
        (lint_core_tests.lint-test-expr-list3 vx vy vz))]
    [spanned-str-cat : i64
      (ast.ast-expr-spanned nested-str-cat (ast.ast-source-span 23 4 23 36))]
    (begin
      (if (=
        (lint_core.lint-findings-count
          (lint_core_tests.lint-test-walk
            nested-str-cat
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        1)
        unit
        (io.panic "lint: nested str-cat should be flagged once"))
      (match (lint_core.lint-findings-get
        (lint_core_tests.lint-test-walk
          spanned-str-cat
          (lint_core.lint-default-ladder-threshold)
          (lint_core.lint-findings-empty))
        0)
        [(lint_core.LintMaybeFinding.Some finding)
          (let
            [span : ast.AstSourceSpan (struct-get finding span)]
            (if (and
              (string.eq
                (struct-get finding rule-id)
                (lint_core.lint-rule-nested-str-cat-id))
              (string.eq
                (struct-get finding message)
                "nested str-cat: prefer one flat str-cat call")
              (= (ast.ast-source-span-start-line span) 23))
              unit
              (io.panic "lint: nested str-cat finding metadata mismatch")))]
        [(lint_core.LintMaybeFinding.No)
          (io.panic "lint: spanned nested str-cat should produce a finding")])
      (if (=
        (lint_core.lint-findings-count
          (lint_core_tests.lint-test-walk
            flat-str-cat
            (lint_core.lint-default-ladder-threshold)
            (lint_core.lint-findings-empty)))
        0)
        42
        (io.panic "lint: flat str-cat should not be flagged")))))

(define (main) : i64
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (let
      [core-result : i64 (lint_core_tests.compiler-lint-self-test)]
      (if (= core-result 42)
        (if (= (lint-smoke-deprecated-string-concat-self-test) 42)
          (lint-smoke-nested-str-cat-self-test)
          1)
        core-result))))