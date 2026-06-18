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
  "(define (cleanup [_x : i64]) : unit unit)
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

(define (lint-driver-smoke-unused-variable-source) : String
  "(defmacro (emit [quoted-only : Expr] [used-macro : Expr]) : Expr
  `(quoted-only ,used-macro))
(define (lambda-case) : i64
  (let
    [f (lambda ([x : i64] [unused-lambda : i64]) : i64 x)]
    (f 1 2)))
(define (main [unused-param : i64] [used-param : i64]) : i64
  (let
    [used-local : i64 used-param]
    [unused-local : i64 9]
    used-local))")

(define (lint-driver-smoke-clean-unused-variable-source) : String
  "(defstruct Pair
  (x i64)
  (y i64))
(defstruct TaggedPair
  (:lifetimes owner)
  (x i64))
(define (id [comptime T : type] [value : T]) : T
  value)
(define (dot-clean) : i64
  (let
    [p : Pair (Pair 1 2)]
    p.x))
(define (tagged [owner : i64]) : (TaggedPair owner)
  (TaggedPair 1))
(define (main [_unused-param : i64] [used-param : i64]) : i64
  (let
    [_unused-local : i64 0]
    [used-local : i64 used-param]
    used-local))")

(define (lint-driver-smoke-shadow-unused-variable-source) : String
  "(define (main [x : i64]) : i64
  (let
    [x : i64 2]
    x))")

(define (lint-driver-smoke-suppressed-unused-variable-source) : String
  "(define (main
  ;; lint-allow: unused-variable
  [x : i64]
  [y : i64]) : i64
  y)")

(define (lint-driver-smoke-prefix-unused-variable-source) : String
  "(define (prefix-long [buf : i64]) : i64
  buf)
(define (prefix [buf : i64]) : i64
  0)")

(define (lint-driver-smoke-unused-unsafe-source) : String
  "(define (main) : i64
  (unsafe (+ 1 2)))")

(define (lint-driver-smoke-unused-unsafe-call-source) : String
  "(define (safe-helper) : i64
  7)
(define (main) : i64
  (unsafe (cast (safe-helper) : i64)))")

(define (lint-driver-smoke-required-unsafe-source) : String
  "(define (main [p : (Ptr i64)]) : i64
  (unsafe (ptr-read p)))")

(define (lint-driver-smoke-nested-unsafe-source) : String
  "(define (main [p : (Ptr i64)]) : i64
  (unsafe
    (unsafe (ptr-read p))))")

(define (lint-driver-smoke-suppressed-unused-unsafe-source) : String
  "(define (main) : i64
  ;; lint-allow: unused-unsafe
  (unsafe (+ 1 2)))")

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

(define (lint-driver-smoke-finding-rule-line-ok?
  [findings : LintFindings]
  [index : i64]
  [rule-id : String]
  [line : i64]) : bool
  (match (lint-findings-get findings index)
    [(LintSomeFinding finding)
      (let
        [fspan : AstSourceSpan (struct-get finding span)]
        (and
          (= (struct-get fspan start-line) line)
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
      [(not (= (lint-findings-count string-concat-reported) 1)) 20]
      [(not
          (lint-driver-smoke-string-concat-finding-ok?
            string-concat-reported
            0
            0))
        21]
      [(not (= (lint-findings-count loop-string-concat-reported) 1)) 22]
      [(not
          (lint-driver-smoke-string-concat-finding-ok?
            loop-string-concat-reported
            0
            2))
        23]
      [(not (= (lint-findings-count nested-string-concat-reported) 2)) 24]
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
      [(not (= (lint-findings-count reported) 4)) 30]
      [(not
          (lint-driver-smoke-finding-rule-ok?
            reported
            0
            (lint-rule-no-effect-id)))
        31]
      [(not (= (lint-findings-count clean) 0)) 32]
      [(not (= (lint-findings-count suppressed) 0)) 33]
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
      [(not (= (lint-findings-count reported) 5)) 40]
      [(not
          (lint-driver-smoke-finding-rule-ok?
            reported
            0
            (lint-rule-unreachable-code-id)))
        41]
      [(not (= (lint-findings-count clean) 0)) 44]
      [(not (= (lint-findings-count suppressed) 0)) 45]
      [else 42])))

(define (lint-driver-smoke-unused-variable-self-test) : i64
  (let
    [reported : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_unused_variable.tl"
        (lint-driver-smoke-unused-variable-source)
        (string-vec-new)
        false)]
    [clean : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_unused_variable_clean.tl"
        (lint-driver-smoke-clean-unused-variable-source)
        (string-vec-new)
        false)]
    [shadow : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_unused_variable_shadow.tl"
        (lint-driver-smoke-shadow-unused-variable-source)
        (string-vec-new)
        false)]
    [suppressed : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_unused_variable_suppressed.tl"
        (lint-driver-smoke-suppressed-unused-variable-source)
        (string-vec-new)
        false)]
    [prefix : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_unused_variable_prefix.tl"
        (lint-driver-smoke-prefix-unused-variable-source)
        (string-vec-new)
        false)]
    [status : i64 42]
    (begin
      (if (not (= (lint-findings-count reported) 4))
        (set! status 50)
        unit)
      (if (and
        (= status 42)
        (not
          (lint-driver-smoke-finding-rule-ok?
            reported
            0
            (lint-rule-unused-variable-id))))
        (set! status 51)
        unit)
      (if (and (= status 42) (not (= (lint-findings-count clean) 0)))
        (set! status 52)
        unit)
      (if (and (= status 42) (not (= (lint-findings-count shadow) 1)))
        (set! status 53)
        unit)
      (if (and
        (= status 42)
        (not
          (lint-driver-smoke-finding-rule-ok?
            shadow
            0
            (lint-rule-unused-variable-id))))
        (set! status 54)
        unit)
      (if (and (= status 42) (not (= (lint-findings-count suppressed) 0)))
        (set! status 55)
        unit)
      (if (and (= status 42) (not (= (lint-findings-count prefix) 1)))
        (set! status 56)
        unit)
      (if (and
        (= status 42)
        (not
          (lint-driver-smoke-finding-rule-line-ok?
            prefix
            0
            (lint-rule-unused-variable-id)
            3)))
        (set! status 57)
        unit)
      status)))

(define (lint-driver-smoke-unused-unsafe-self-test) : i64
  (let
    [reported : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_unused_unsafe.tl"
        (lint-driver-smoke-unused-unsafe-source)
        (string-vec-new)
        false)]
    [required : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_required_unsafe.tl"
        (lint-driver-smoke-required-unsafe-source)
        (string-vec-new)
        false)]
    [safe-call : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_unused_unsafe_call.tl"
        (lint-driver-smoke-unused-unsafe-call-source)
        (string-vec-new)
        false)]
    [nested : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_nested_unsafe.tl"
        (lint-driver-smoke-nested-unsafe-source)
        (string-vec-new)
        false)]
    [suppressed : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_suppressed_unused_unsafe.tl"
        (lint-driver-smoke-suppressed-unused-unsafe-source)
        (string-vec-new)
        false)]
    (cond
      [(not (= (lint-findings-count reported) 1)) 60]
      [(not
          (lint-driver-smoke-finding-rule-line-ok?
            reported
            0
            (lint-rule-unused-unsafe-id)
            2))
        61]
      [(not (= (lint-findings-count required) 0)) 62]
      [(not (= (lint-findings-count safe-call) 1)) 63]
      [(not
          (lint-driver-smoke-finding-rule-line-ok?
            safe-call
            0
            (lint-rule-unused-unsafe-id)
            4))
        64]
      [(not (= (lint-findings-count nested) 1)) 65]
      [(not
          (lint-driver-smoke-finding-rule-line-ok?
            nested
            0
            (lint-rule-unused-unsafe-id)
            2))
        66]
      [(not (= (lint-findings-count suppressed) 0)) 67]
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
                            (let
                              [unreachable-result : i64
                                (lint-driver-smoke-unreachable-self-test)]
                              (if (= unreachable-result 42)
                                (let
                                  [unused-variable-result : i64
                                    (lint-driver-smoke-unused-variable-self-test)]
                                  (if (= unused-variable-result 42)
                                    (lint-driver-smoke-unused-unsafe-self-test)
                                    unused-variable-result))
                                unreachable-result))
                            no-effect-result))
                        concat-result))
                    unused-assignment-result))
                dead-code-result))
            unused-import-result))
        core-result))))