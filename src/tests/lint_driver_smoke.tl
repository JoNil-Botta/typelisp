;; lint_driver_smoke.tl - Runnable smoke for lint_driver_core.tl (#1163): drives
;; the full load -> lint -> render path on an embedded source and returns 42.
(import "../stdlib/io.tl")
(import "lint_driver_core.tl")

(define (lint-driver-smoke-string-concat-source) : String
  "(define (main) : i64
  (string-length (string-append \"a\" \"b\")))")

(define (lint-driver-smoke-loop-string-concat-source) : String
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

(define (lint-driver-smoke-nested-string-concat-source) : String
  "(define (main) : i64
  (string-length (string-append \"a\" (string-append \"b\" \"c\"))))")

(define (lint-driver-smoke-suppressed-string-concat-source) : String
  "(define (main) : i64
  ;; lint-allow: deprecated-string-concat
  (string-length (string-append \"a\" \"b\")))")

(define (lint-driver-smoke-no-effect-source) : String
  "(define (main) : i64
  (let
    [x : i64 1]
    (begin
      1
      x
      (+ x 2)
      (cast x : i64)
      x)))")

(define (lint-driver-smoke-clean-no-effect-source) : String
  "(define (touch [x : i64]) : i64 x)
(define (main) : i64
  (let
    [x : i64 0]
    (begin
      (touch x)
      (set! x 1)
      x)))")

(define (lint-driver-smoke-suppressed-no-effect-source) : String
  "(define (main) : i64
  (begin
    ;; lint-allow: no-effect
    1
    42))")

(define (lint-driver-smoke-source-finding-count-with-deprecated-string-concat
  [source : String]) : i64
  (lint-findings-count
    (selfhost-lint-source-with-roots-and-options
      "lint_driver_smoke_test.tl"
      source
      (string-vec-new)
      true)))

(define (lint-driver-smoke-string-concat-finding-ok?
  [findings : LintFindings]
  [index : i64]
  [depth : i64]) : bool
  (match (lint-findings-get findings index)
    [(LintSomeFinding finding)
      (let
        [fspan : AstSourceSpan (struct-get finding span)]
        (and
          (= (struct-get finding depth) depth)
          (> (struct-get fspan start-line) 0)
          (string-eq
            (struct-get finding rule-id)
            (lint-rule-deprecated-string-concat-id))))]
    [(LintNoFinding) false]))

(define (lint-driver-smoke-finding-rule-ok?
  [findings : LintFindings]
  [index : i64]
  [rule-id : String]) : bool
  (match (lint-findings-get findings index)
    [(LintSomeFinding finding)
      (let
        [fspan : AstSourceSpan (struct-get finding span)]
        (and
          (> (struct-get fspan start-line) 0)
          (string-eq (struct-get finding rule-id) rule-id)))]
    [(LintNoFinding) false]))

(define (lint-driver-smoke-deprecated-string-concat-self-test) : i64
  (let
    [string-concat-reported : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_smoke_test.tl"
        (lint-driver-smoke-string-concat-source)
        (string-vec-new)
        true)]
    [loop-string-concat-reported : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_smoke_test.tl"
        (lint-driver-smoke-loop-string-concat-source)
        (string-vec-new)
        true)]
    [nested-string-concat-reported : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_smoke_test.tl"
        (lint-driver-smoke-nested-string-concat-source)
        (string-vec-new)
        true)]
    (if (not (= (lint-findings-count string-concat-reported) 1))
      20
      (if (not
        (lint-driver-smoke-string-concat-finding-ok? string-concat-reported 0 0))
        21
        (if (not (= (lint-findings-count loop-string-concat-reported) 1))
          22
          (if (not
            (lint-driver-smoke-string-concat-finding-ok?
              loop-string-concat-reported
              0
              2))
            23
            (if (not (= (lint-findings-count nested-string-concat-reported) 2))
              24
              (if (not
                (lint-driver-smoke-string-concat-finding-ok?
                  nested-string-concat-reported
                  1
                  1))
                25
                (if (not
                  (=
                    (lint-driver-smoke-source-finding-count-with-deprecated-string-concat
                      (lint-driver-smoke-suppressed-string-concat-source))
                    0))
                  26
                  42)))))))))

(define (lint-driver-smoke-no-effect-self-test) : i64
  (let
    [reported : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_no_effect.tl"
        (lint-driver-smoke-no-effect-source)
        (string-vec-new)
        true)]
    [clean : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_no_effect_clean.tl"
        (lint-driver-smoke-clean-no-effect-source)
        (string-vec-new)
        true)]
    [suppressed : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_no_effect_suppressed.tl"
        (lint-driver-smoke-suppressed-no-effect-source)
        (string-vec-new)
        true)]
    (if (not (= (lint-findings-count reported) 4))
      30
      (if (not
        (lint-driver-smoke-finding-rule-ok? reported 0 (lint-rule-no-effect-id)))
        31
        (if (not (= (lint-findings-count clean) 0))
          32
          (if (not (= (lint-findings-count suppressed) 0))
            33
            42))))))

(define (main) : i64
  (begin
    ;; The imported driver core defines printing helpers; keep the print-string
    ;; runtime linked even when this smoke only exercises the pure source path.
    (print-string "")
    (let
      [core-result : i64 (compiler-lint-driver-self-test)]
      (if (= core-result 42)
        (let
          [unused-import-result : i64 (selfhost-lint-unused-imports-self-test)]
          (if (= unused-import-result 42)
            (let
              [concat-result : i64
                (lint-driver-smoke-deprecated-string-concat-self-test)]
              (if (= concat-result 42)
                (lint-driver-smoke-no-effect-self-test)
                concat-result))
            unused-import-result))
        core-result))))