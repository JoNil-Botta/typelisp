;; lint_smoke.tl - Runnable smoke for lint_core.tl (#1163).
(import "lint_core.tl")

(define (lint-smoke-string-append-source) : String
  "(define (main) : i64 (string-length (string-append \"a\" \"b\")))")

(define (lint-smoke-string-concat-source) : String
  "(define (main) : i64 (string-length (string-concat \"a\" \"b\")))")

(define (lint-smoke-string-concat5-source) : String
  "(define (main) : i64
  (string-length (string-concat5 \"a\" \"b\" \"c\" \"d\" \"e\")))")

(define (lint-smoke-nested-string-append-source) : String
  "(define (main) : i64
  (string-length (string-append \"a\" (string-append \"b\" \"c\"))))")

(define (lint-smoke-loop-string-append-source) : String
  "(define (main) : i64
  (let
    [i : i64 0]
    [out : String \"\"]
    (begin
      (while (< i 3)
        (begin
          (set! out (string-append out \"x\"))
          (set! i (+ i 1))))
      (string-length out))))")

(define (lint-smoke-deprecated-string-concat-self-test) : i64
  (begin
    (if (=
      (lint-findings-count
        (lint-deprecated-string-concat-scan
          (lint-smoke-string-append-source)
          (lint-findings-empty)))
      1)
      unit
      (panic "lint: string-append call should be flagged"))
    (match (lint-findings-get
      (lint-deprecated-string-concat-scan
        (lint-smoke-string-concat-source)
        (lint-findings-empty))
      0)
      [(LintSomeFinding finding)
        (if (and
          (= (struct-get finding depth) 0)
          (string-eq
            (struct-get finding rule-id)
            (lint-rule-deprecated-string-concat-id)))
          unit
          (panic "lint: string-concat finding should carry default metadata"))]
      [(LintNoFinding)
        (panic "lint: string-concat call should produce a finding")])
    (if (=
      (lint-findings-count
        (lint-deprecated-string-concat-scan
          (lint-smoke-string-concat5-source)
          (lint-findings-empty)))
      1)
      unit
      (panic "lint: string-concat5 call should be flagged"))
    (if (=
      (lint-findings-count
        (lint-deprecated-string-concat-scan
          (lint-smoke-nested-string-append-source)
          (lint-findings-empty)))
      2)
      unit
      (panic "lint: nested string append should produce two findings"))
    (match (lint-findings-get
      (lint-deprecated-string-concat-scan
        (lint-smoke-nested-string-append-source)
        (lint-findings-empty))
      1)
      [(LintSomeFinding finding)
        (if (= (struct-get finding depth) 1)
          unit
          (panic "lint: nested string append should carry chain depth"))]
      [(LintNoFinding)
        (panic "lint: nested string append should produce a chain finding")])
    (match (lint-findings-get
      (lint-deprecated-string-concat-scan
        (lint-smoke-loop-string-append-source)
        (lint-findings-empty))
      0)
      [(LintSomeFinding finding)
        (if (= (struct-get finding depth) 2)
          unit
          (panic "lint: loop string append should carry loop depth"))]
      [(LintNoFinding)
        (panic "lint: loop string append should produce a finding")])
    42))

(define (lint-smoke-nested-str-cat-self-test) : i64
  (let
    [vx : i64 (lint-test-var "x")]
    [vy : i64 (lint-test-var "y")]
    [vz : i64 (lint-test-var "z")]
    [str-cat-callee : i64 (lint-test-var "str-cat")]
    [str-cat-yz : i64
      (ast-expr-call str-cat-callee (lint-test-expr-list2 vy vz))]
    [nested-str-cat : i64
      (ast-expr-call str-cat-callee (lint-test-expr-list2 vx str-cat-yz))]
    [flat-str-cat : i64
      (ast-expr-call str-cat-callee (lint-test-expr-list3 vx vy vz))]
    [spanned-str-cat : i64
      (ast-expr-spanned nested-str-cat (AstSourceSpan 23 4 23 36))]
    (begin
      (if (=
        (lint-findings-count
          (lint-test-walk
            nested-str-cat
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        1)
        unit
        (panic "lint: nested str-cat should be flagged once"))
      (match (lint-findings-get
        (lint-test-walk
          spanned-str-cat
          (lint-default-ladder-threshold)
          (lint-findings-empty))
        0)
        [(LintSomeFinding finding)
          (let
            [span : AstSourceSpan (struct-get finding span)]
            (if (and
              (string-eq
                (struct-get finding rule-id)
                (lint-rule-nested-str-cat-id))
              (string-eq
                (struct-get finding message)
                "nested str-cat: prefer one flat str-cat call")
              (= (struct-get span start-line) 23))
              unit
              (panic "lint: nested str-cat finding metadata mismatch")))]
        [(LintNoFinding)
          (panic "lint: spanned nested str-cat should produce a finding")])
      (if (=
        (lint-findings-count
          (lint-test-walk
            flat-str-cat
            (lint-default-ladder-threshold)
            (lint-findings-empty)))
        0)
        42
        (panic "lint: flat str-cat should not be flagged")))))

(define (main) : i64
  (let
    [core-result : i64 (compiler-lint-self-test)]
    (if (= core-result 42)
      (if (= (lint-smoke-deprecated-string-concat-self-test) 42)
        (lint-smoke-nested-str-cat-self-test)
        1)
      core-result)))