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

(define (lint-driver-smoke-unreachable-source) : String
  "(define (cleanup [x : i64]) : unit unit)
(define (main [arena : i64]) : i64
  (begin
    (begin
      (return 1)
      (set! arena 2))
    (unsafe
      (panic \"stop\")
      (set! arena 3))
    (with-arena r
      (error \"stop\")
      (set! arena 4))
    (in-arena arena
      (return 2)
      (set! arena 5))
    (with ([handle 1 cleanup])
      (return 3)
      (set! arena 6))
    arena))")

(define (lint-driver-smoke-clean-unreachable-source) : String
  "(define (main [ok : bool]) : i64
  (begin
    (if ok (return 1) (return 2))
    3))")

(define (lint-driver-smoke-suppressed-unreachable-source) : String
  "(define (main) : i64
  (begin
    (return 1)
    ;; lint-allow: unreachable-code
    2))")

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
    (cond
      [(not (= (lint-findings-count string-concat-reported) 1))
        20]
      [(not
        (lint-driver-smoke-string-concat-finding-ok? string-concat-reported 0 0))
        21]
      [(not (= (lint-findings-count loop-string-concat-reported) 1))
        22]
      [(not
        (lint-driver-smoke-string-concat-finding-ok?
          loop-string-concat-reported
          0
          2))
        23]
      [(not (= (lint-findings-count nested-string-concat-reported) 2))
        24]
      [(not
        (lint-driver-smoke-string-concat-finding-ok?
          nested-string-concat-reported
          1
          1))
        25]
      [(not
        (=
          (lint-driver-smoke-source-finding-count-with-deprecated-string-concat
            (lint-driver-smoke-suppressed-string-concat-source))
          0))
        26]
      [else 42])))

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
    (cond
      [(not (= (lint-findings-count reported) 4))
        30]
      [(not
        (lint-driver-smoke-finding-rule-ok? reported 0 (lint-rule-no-effect-id)))
        31]
      [(not (= (lint-findings-count clean) 0))
        32]
      [(not (= (lint-findings-count suppressed) 0))
        33]
      [else 42])))

(define (lint-driver-smoke-unreachable-self-test) : i64
  (let
    [reported : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_unreachable.tl"
        (lint-driver-smoke-unreachable-source)
        (string-vec-new)
        true)]
    [clean : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_unreachable_clean.tl"
        (lint-driver-smoke-clean-unreachable-source)
        (string-vec-new)
        true)]
    [suppressed : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_unreachable_suppressed.tl"
        (lint-driver-smoke-suppressed-unreachable-source)
        (string-vec-new)
        true)]
    (cond
      [(not (= (lint-findings-count reported) 5))
        40]
      [(not
        (lint-driver-smoke-finding-rule-ok?
          reported
          0
          (lint-rule-unreachable-code-id)))
        41]
      [(not (= (lint-findings-count clean) 0))
        44]
      [(not (= (lint-findings-count suppressed) 0))
        45]
      [else 42])))

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
              [dead-code-result : i64
                (selfhost-lint-package-dead-code-self-test)]
              (if (= dead-code-result 42)
                (let
                  [unused-assignment-result : i64
                    (selfhost-lint-unused-assignment-self-test)]
                  (if (= unused-assignment-result 42)
                    (let
                      [concat-result : i64
                        (lint-driver-smoke-deprecated-string-concat-self-test)]
                      (if (= concat-result 42)
                        (let
                          [no-effect-result : i64
                            (lint-driver-smoke-no-effect-self-test)]
                          (if (= no-effect-result 42)
                            (lint-driver-smoke-unreachable-self-test)
                            no-effect-result))
                        concat-result))
                    unused-assignment-result))
                dead-code-result))
            unused-import-result))
        core-result))))