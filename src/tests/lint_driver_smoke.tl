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

(define (main) : i64
  (begin
    ;; The imported driver core defines printing helpers; keep the print-string
    ;; runtime linked even when this smoke only exercises the pure source path.
    (print-string "")
    (let
      [core-result : i64 (compiler-lint-driver-self-test)]
      (if (= core-result 42)
        (lint-driver-smoke-deprecated-string-concat-self-test)
        core-result))))