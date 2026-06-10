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

(define (main) : i64
  (let
    [core-result : i64 (compiler-lint-self-test)]
    (if (= core-result 42)
      (lint-smoke-deprecated-string-concat-self-test)
      core-result)))