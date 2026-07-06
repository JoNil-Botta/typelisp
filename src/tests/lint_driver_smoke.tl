;; lint_driver_smoke.tl - Runnable smoke for lint_driver_core.tl: drives
;; the full load -> lint -> render path on an embedded source and returns 42.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as lint_svec)
(import "../lint_driver_core.tl")

(define (lint-driver-smoke-string-concat-source) : String
  "(define (main) : i64
  (string.string-length (string.append \"a\" \"b\")))")

(define (lint-driver-smoke-loop-string-concat-source) : String
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

(define (lint-driver-smoke-nested-string-concat-source) : String
  "(define (main) : i64
  (string.string-length (string.append \"a\" (string.append \"b\" \"c\"))))")

(define (lint-driver-smoke-suppressed-string-concat-source) : String
  "(define (main) : i64
  ;; lint-allow: deprecated-string-concat
  (string.string-length (string.append \"a\" \"b\")))")

(define (lint-driver-smoke-redundant-import-alias-source) : String
  (string.append
    "(import pkg.data "
    "as data)
(define (main) : i64 (data.value))"))

(define (lint-driver-smoke-redundant-import-colon-alias-source) : String
  (string.append
    "(import pkg.data "
    ":as data)
(define (main) : i64 (data.value))"))

(define (lint-driver-smoke-clean-default-import-alias-source) : String
  "(import pkg.data)
(define (main) : i64 (data.value))")

(define (lint-driver-smoke-renamed-import-alias-source) : String
  "(import pkg.data as d)
(define (main) : i64 (d.value))")

(define (lint-driver-smoke-suppressed-redundant-import-alias-source) : String
  (string.append
    ";; lint-allow: redundant-import-alias
(import pkg.data "
    "as data)
(define (main) : i64 (data.value))"))

(define (lint-driver-smoke-redundant-function-name-source) : String
  "(module sample.vector)
(define (vector-push [x : i64]) : i64 x)
(define (push [x : i64]) : i64 x)")

(define (lint-driver-smoke-redundant-generated-function-name-source) : String
  "(module sample.vector)
(defmacro (build [module-name : Expr]) : Module
  `(begin
    (module ,module-name)
    (define (vector-push [x : i64]) : i64 x)))")

(define (lint-driver-smoke-clean-function-name-source) : String
  "(module sample.vector)
(define (push [x : i64]) : i64 x)
(defmacro (build [module-name : Expr]) : Module
  `(begin
    (module ,module-name)
    (define (push [x : i64]) : i64 x)))")

(define (lint-driver-smoke-suppressed-redundant-function-name-source) : String
  "(module sample.vector)
;; lint-allow: redundant-function-name
(define (vector-push [x : i64]) : i64 x)")

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
      (io.panic \"stop\")
      (set! arena 3))
    (with-arena r
      (io.error \"stop\")
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

(define (lint-driver-smoke-divergence-padding-source) : String
  "(define (main [flag : bool]) : i64
  (begin
    (begin
      (io.panic \"stop\")
      ;; lint-allow: unreachable-code
      0)
    (unsafe
      (io.error \"stop\")
      ;; lint-allow: unreachable-code
      1)
    (with-arena scratch
      (io.panic \"stop\")
      ;; lint-allow: unreachable-code
      2)
    (if flag
      (begin
        (io.panic \"stop\")
        ;; lint-allow: unreachable-code
        3)
      4)))")

(define (lint-driver-smoke-clean-divergence-source) : String
  "(define (main [flag : bool]) : i64
  (if flag
    (io.panic \"stop\")
    4))")

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

(define (lint-driver-smoke-required-unsafe-call-source) : String
  "(unsafe (define (danger [value : i64]) : i64
  value))
(define (main) : i64
  (unsafe (danger 9)))")

(define (lint-driver-smoke-nested-unsafe-source) : String
  "(define (main [p : (Ptr i64)]) : i64
  (unsafe
    (unsafe (ptr-read p))))")

(define (lint-driver-smoke-suppressed-unused-unsafe-source) : String
  "(define (main) : i64
  ;; lint-allow: unused-unsafe
  (unsafe (+ 1 2)))")

(define (lint-driver-smoke-copy-on-update-struct-source) : String
  "(defstruct Point
  (x i64)
  (y i64))
(define (main [p : Point] [y : i64]) : i64
  (begin
    (set! p (Point (struct-get p x) y))
    (struct-get p y)))")

(define (lint-driver-smoke-dot-copy-on-update-struct-source) : String
  "(defstruct Point
  (x i64)
  (y i64))
(define (main [p : Point] [y : i64]) : i64
  (begin
    (set! p (Point p.x y))
    p.y))")

(define (lint-driver-smoke-suppressed-copy-on-update-struct-source) : String
  "(defstruct Point
  (x i64)
  (y i64))
(define (main [p : Point] [y : i64]) : i64
  (begin
    ;; lint-allow: copy-on-update-struct
    (set! p (Point (struct-get p x) y))
    (struct-get p y)))")

(define (lint-driver-smoke-multiple-field-copy-on-update-source) : String
  "(defstruct Point
  (x i64)
  (y i64))
(define (main [p : Point] [x : i64] [y : i64]) : i64
  (begin
    (set! p (Point (+ (struct-get p x) x) y))
    (struct-get p y)))")

(define (lint-driver-smoke-other-value-copy-on-update-source) : String
  "(defstruct Point
  (x i64)
  (y i64))
(define (main [p : Point] [q : Point] [y : i64]) : i64
  (begin
    (set! p (Point (struct-get q x) y))
    (struct-get p y)))")

(define (lint-driver-smoke-enum-copy-on-update-source) : String
  "(defenum State
  (A i64 i64)
  (B i64 i64))
(define (main [s : State] [x : i64]) : i64
  (begin
    (set! s (B x 2))
    x))")

(define (lint-driver-smoke-prefer-dotted-field-source) : String
  "(defstruct Point
  (x i64)
  (y i64))
(define (main [p : Point]) : i64
  (struct-get p x))")

(define (lint-driver-smoke-prefer-dotted-field-set-source) : String
  "(defstruct Point
  (x i64)
  (y i64))
(define (main [p : Point] [y : i64]) : i64
  (begin
    (set! (struct-get p x) y)
    y))")

(define (lint-driver-smoke-suppressed-prefer-dotted-field-source) : String
  "(defstruct Point
  (x i64)
  (y i64))
(define (main [p : Point]) : i64
  ;; lint-allow: prefer-dotted-field
  (struct-get p x))")

(define (lint-driver-smoke-complex-prefer-dotted-field-source) : String
  "(defstruct Point
  (x i64)
  (y i64))
(define (main [items : (Array Point)]) : i64
  (struct-get (array-ref items 0) x))")

(define (lint-driver-smoke-nested-prefer-dotted-field-source) : String
  "(defstruct Point
  (x i64)
  (y i64))
(defstruct Outer
  (inner Point))
(define (main [p : Outer]) : i64
  (struct-get (struct-get p inner) x))")

(define (lint-driver-smoke-quoted-prefer-dotted-field-source) : String
  "(defmacro (build [p : Expr]) : Expr
  `(struct-get ,p x))")

(define (lint-driver-smoke-unquoted-prefer-dotted-field-source) : String
  "(defstruct Point
  (x i64)
  (y i64))
(defmacro (build [p : Point]) : Expr
  `(field ,(struct-get p x)))")

(define (lint-driver-smoke-source-finding-count-with-deprecated-string-concat
  [source : String]) : i64
  (lint-findings-count
    (selfhost-lint-source-with-roots-and-options
      "lint_driver_smoke_test.tl"
      source
      (lint_svec.new)
      true)))

(define (lint-driver-smoke-source-findings-with-redundant-function-name
  [source : String]) : LintFindings
  (selfhost-lint-source-with-roots-and-staged-options
    "lint_driver_smoke_test.tl"
    source
    (lint_svec.new)
    false
    true
    false))

(define (lint-driver-smoke-source-findings-with-prefer-dotted-field
  [source : String]) : LintFindings
  (selfhost-lint-source-with-roots-and-staged-options
    "lint_driver_smoke_test.tl"
    source
    (lint_svec.new)
    false
    false
    true))

(define (lint-driver-smoke-source-rule-count-with-redundant-function-name
  [source : String]
  [rule : String]) : i64
  (selfhost-lint-findings-rule-count
    (lint-driver-smoke-source-findings-with-redundant-function-name source)
    rule))

(define (lint-driver-smoke-source-rule-count-with-prefer-dotted-field
  [source : String]
  [rule : String]) : i64
  (selfhost-lint-findings-rule-count
    (lint-driver-smoke-source-findings-with-prefer-dotted-field source)
    rule))

(define (lint-driver-smoke-string-concat-finding-ok?
  [findings : LintFindings]
  [index : i64]
  [depth : i64]) : bool
  (match (lint-findings-get findings index)
    [(LintMaybeFinding.Some finding)
      (let
        [fspan : AstSourceSpan (struct-get finding span)]
        (and
          (= (struct-get finding depth) depth)
          (> (ast-source-span-start-line fspan) 0)
          (string.eq
            (struct-get finding rule-id)
            (lint-rule-deprecated-string-concat-id))))]
    [(LintMaybeFinding.No) false]))

(define (lint-driver-smoke-finding-rule-ok?
  [findings : LintFindings]
  [index : i64]
  [rule-id : String]) : bool
  (match (lint-findings-get findings index)
    [(LintMaybeFinding.Some finding)
      (let
        [fspan : AstSourceSpan (struct-get finding span)]
        (and
          (> (ast-source-span-start-line fspan) 0)
          (string.eq (struct-get finding rule-id) rule-id)))]
    [(LintMaybeFinding.No) false]))

(define (lint-driver-smoke-finding-rule-line-ok?
  [findings : LintFindings]
  [index : i64]
  [rule-id : String]
  [line : i64]) : bool
  (match (lint-findings-get findings index)
    [(LintMaybeFinding.Some finding)
      (let
        [fspan : AstSourceSpan (struct-get finding span)]
        (and
          (= (ast-source-span-start-line fspan) line)
          (string.eq (struct-get finding rule-id) rule-id)))]
    [(LintMaybeFinding.No) false]))

(define (lint-driver-smoke-finding-rule-depth-line-ok?
  [findings : LintFindings]
  [index : i64]
  [rule-id : String]
  [depth : i64]
  [line : i64]) : bool
  (match (lint-findings-get findings index)
    [(LintMaybeFinding.Some finding)
      (let
        [fspan : AstSourceSpan (struct-get finding span)]
        (and
          (= (struct-get finding depth) depth)
          (= (ast-source-span-start-line fspan) line)
          (string.eq (struct-get finding rule-id) rule-id)))]
    [(LintMaybeFinding.No) false]))

(define (lint-driver-smoke-deprecated-string-concat-self-test) : i64
  (let
    [string-concat-reported : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_smoke_test.tl"
        (lint-driver-smoke-string-concat-source)
        (lint_svec.new)
        true)]
    [loop-string-concat-reported : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_smoke_test.tl"
        (lint-driver-smoke-loop-string-concat-source)
        (lint_svec.new)
        true)]
    [nested-string-concat-reported : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_smoke_test.tl"
        (lint-driver-smoke-nested-string-concat-source)
        (lint_svec.new)
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
        (lint_svec.new)
        true)]
    [clean : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_no_effect_clean.tl"
        (lint-driver-smoke-clean-no-effect-source)
        (lint_svec.new)
        true)]
    [suppressed : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_no_effect_suppressed.tl"
        (lint-driver-smoke-suppressed-no-effect-source)
        (lint_svec.new)
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
        (lint_svec.new)
        true)]
    [clean : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_unreachable_clean.tl"
        (lint-driver-smoke-clean-unreachable-source)
        (lint_svec.new)
        true)]
    [suppressed : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_unreachable_suppressed.tl"
        (lint-driver-smoke-suppressed-unreachable-source)
        (lint_svec.new)
        true)]
    (cond
      [(not (= (lint-findings-count reported) 7)) 40]
      [(not
          (=
            (selfhost-lint-findings-rule-count
              reported
              (lint-rule-unreachable-code-id))
            5))
        41]
      [(not
          (=
            (selfhost-lint-findings-rule-count
              reported
              (lint-rule-redundant-divergence-padding-id))
            2))
        43]
      [(not (= (lint-findings-count clean) 0)) 44]
      [(not (= (lint-findings-count suppressed) 0)) 45]
      [else 42])))

(define (lint-driver-smoke-divergence-padding-self-test) : i64
  (let
    [reported : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_divergence_padding.tl"
        (lint-driver-smoke-divergence-padding-source)
        (lint_svec.new)
        true)]
    [clean : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_divergence_padding_clean.tl"
        (lint-driver-smoke-clean-divergence-source)
        (lint_svec.new)
        true)]
    (cond
      [(not (= (lint-findings-count reported) 4)) 46]
      [(not
          (=
            (selfhost-lint-findings-rule-count
              reported
              (lint-rule-redundant-divergence-padding-id))
            4))
        47]
      [(not
          (lint-driver-smoke-finding-rule-line-ok?
            reported
            0
            (lint-rule-redundant-divergence-padding-id)
            4))
        48]
      [(not (= (lint-findings-count clean) 0)) 49]
      [else 42])))

(define (lint-driver-smoke-unused-variable-self-test) : i64
  (let
    [reported : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_unused_variable.tl"
        (lint-driver-smoke-unused-variable-source)
        (lint_svec.new)
        false)]
    [clean : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_unused_variable_clean.tl"
        (lint-driver-smoke-clean-unused-variable-source)
        (lint_svec.new)
        false)]
    [shadow : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_unused_variable_shadow.tl"
        (lint-driver-smoke-shadow-unused-variable-source)
        (lint_svec.new)
        false)]
    [suppressed : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_unused_variable_suppressed.tl"
        (lint-driver-smoke-suppressed-unused-variable-source)
        (lint_svec.new)
        false)]
    [prefix : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_unused_variable_prefix.tl"
        (lint-driver-smoke-prefix-unused-variable-source)
        (lint_svec.new)
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
        (lint_svec.new)
        false)]
    [required : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_required_unsafe.tl"
        (lint-driver-smoke-required-unsafe-source)
        (lint_svec.new)
        false)]
    [safe-call : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_unused_unsafe_call.tl"
        (lint-driver-smoke-unused-unsafe-call-source)
        (lint_svec.new)
        false)]
    [required-call : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_required_unsafe_call.tl"
        (lint-driver-smoke-required-unsafe-call-source)
        (lint_svec.new)
        false)]
    [nested : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_nested_unsafe.tl"
        (lint-driver-smoke-nested-unsafe-source)
        (lint_svec.new)
        false)]
    [suppressed : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_suppressed_unused_unsafe.tl"
        (lint-driver-smoke-suppressed-unused-unsafe-source)
        (lint_svec.new)
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
      [(not (= (lint-findings-count required-call) 0)) 65]
      [(not (= (lint-findings-count nested) 1)) 66]
      [(not
          (lint-driver-smoke-finding-rule-line-ok?
            nested
            0
            (lint-rule-unused-unsafe-id)
            2))
        67]
      [(not (= (lint-findings-count suppressed) 0)) 68]
      [else 42])))

(define (lint-driver-smoke-copy-on-update-struct-self-test) : i64
  (let
    [rule : String (lint-rule-copy-on-update-struct-id)]
    [reported : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_copy_on_update_struct.tl"
        (lint-driver-smoke-copy-on-update-struct-source)
        (lint_svec.new)
        false)]
    (cond
      [(not (= (selfhost-lint-findings-rule-count reported rule) 1)) 81]
      [(not (lint-driver-smoke-finding-rule-line-ok? reported 0 rule 6)) 82]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (lint-driver-smoke-suppressed-copy-on-update-struct-source)
              rule)
            0))
        83]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (lint-driver-smoke-multiple-field-copy-on-update-source)
              rule)
            0))
        84]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (lint-driver-smoke-other-value-copy-on-update-source)
              rule)
            0))
        85]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (lint-driver-smoke-enum-copy-on-update-source)
              rule)
            0))
        86]
      [(not
          (string.eq
            (lint-rule-message rule)
            (lint-rule-copy-on-update-struct-message)))
        87]
      [(not
          (string.eq
            (lint-rule-suggestion rule)
            (lint-rule-copy-on-update-struct-suggestion)))
        88]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (lint-driver-smoke-dot-copy-on-update-struct-source)
              rule)
            1))
        89]
      [else 42])))

(define (lint-driver-smoke-prefer-dotted-field-self-test) : i64
  (let
    [rule : String (lint-rule-prefer-dotted-field-id)]
    [reported : LintFindings
      (lint-driver-smoke-source-findings-with-prefer-dotted-field
        (lint-driver-smoke-prefer-dotted-field-source))]
    [set-reported : LintFindings
      (lint-driver-smoke-source-findings-with-prefer-dotted-field
        (lint-driver-smoke-prefer-dotted-field-set-source))]
    (cond
      [(not (= (selfhost-lint-findings-rule-count reported rule) 1)) 90]
      [(not (lint-driver-smoke-finding-rule-depth-line-ok? reported 0 rule 0 5))
        91]
      [(not (= (selfhost-lint-findings-rule-count set-reported rule) 1)) 92]
      [(not
          (lint-driver-smoke-finding-rule-depth-line-ok?
            set-reported
            0
            rule
            1
            6))
        93]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (lint-driver-smoke-prefer-dotted-field-source)
              rule)
            0))
        94]
      [(not
          (=
            (lint-driver-smoke-source-rule-count-with-prefer-dotted-field
              (lint-driver-smoke-suppressed-prefer-dotted-field-source)
              rule)
            0))
        95]
      [(not
          (=
            (lint-driver-smoke-source-rule-count-with-prefer-dotted-field
              (lint-driver-smoke-complex-prefer-dotted-field-source)
              rule)
            0))
        96]
      [(not
          (=
            (lint-driver-smoke-source-rule-count-with-prefer-dotted-field
              (lint-driver-smoke-nested-prefer-dotted-field-source)
              rule)
            0))
        97]
      [(not
          (=
            (lint-driver-smoke-source-rule-count-with-prefer-dotted-field
              (lint-driver-smoke-quoted-prefer-dotted-field-source)
              rule)
            0))
        98]
      [(not
          (=
            (lint-driver-smoke-source-rule-count-with-prefer-dotted-field
              (lint-driver-smoke-unquoted-prefer-dotted-field-source)
              rule)
            1))
        101]
      [(not
          (string.eq
            (lint-rule-message rule)
            (lint-rule-prefer-dotted-field-message)))
        99]
      [(not
          (string.eq
            (lint-rule-suggestion rule)
            (lint-rule-prefer-dotted-field-suggestion)))
        100]
      [else 42])))

(define (lint-driver-smoke-redundant-import-alias-self-test) : i64
  (let
    [rule : String (lint-rule-redundant-import-alias-id)]
    (cond
      [(not
          (=
            (selfhost-lint-source-rule-count
              (lint-driver-smoke-redundant-import-alias-source)
              rule)
            1))
        69]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (lint-driver-smoke-redundant-import-colon-alias-source)
              rule)
            1))
        70]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (lint-driver-smoke-clean-default-import-alias-source))
            0))
        71]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (lint-driver-smoke-renamed-import-alias-source))
            0))
        72]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (lint-driver-smoke-suppressed-redundant-import-alias-source)
              rule)
            0))
        73]
      [(not
          (string.eq
            (lint-rule-message rule)
            (lint-rule-redundant-import-alias-message)))
        74]
      [else 42])))

(define (lint-driver-smoke-redundant-function-name-self-test) : i64
  (let
    [rule : String (lint-rule-redundant-function-name-id)]
    (cond
      [(not
          (=
            (lint-driver-smoke-source-rule-count-with-redundant-function-name
              (lint-driver-smoke-redundant-function-name-source)
              rule)
            1))
        75]
      [(not
          (=
            (lint-driver-smoke-source-rule-count-with-redundant-function-name
              (lint-driver-smoke-redundant-generated-function-name-source)
              rule)
            1))
        76]
      [(not
          (=
            (lint-findings-count
              (lint-driver-smoke-source-findings-with-redundant-function-name
                (lint-driver-smoke-clean-function-name-source)))
            0))
        77]
      [(not
          (=
            (lint-driver-smoke-source-rule-count-with-redundant-function-name
              (lint-driver-smoke-suppressed-redundant-function-name-source)
              rule)
            0))
        78]
      [(not
          (string.eq
            (lint-rule-message rule)
            (lint-rule-redundant-function-name-message)))
        79]
      [(not
          (string.eq
            (lint-rule-suggestion rule)
            (lint-rule-redundant-function-name-suggestion)))
        80]
      [else 42])))

(define (main) : i64
  (begin
    ;; The imported driver core defines printing helpers; keep the print-string
    ;; runtime linked even when this smoke only exercises the pure source path.
    (io.print-string "")
    (let
      [core-result : i64 (compiler-lint-driver-self-test)]
      (if (= core-result 42)
        (let
          [unused-import-result : i64 (selfhost-lint-unused-imports-self-test)]
          (if (= unused-import-result 42)
            (let
              [redundant-import-result : i64
                (lint-driver-smoke-redundant-import-alias-self-test)]
              (if (= redundant-import-result 42)
                (let
                  [redundant-name-result : i64
                    (lint-driver-smoke-redundant-function-name-self-test)]
                  (if (= redundant-name-result 42)
                    (let
                      [dead-code-result : i64
                        (selfhost-lint-package-dead-code-self-test)]
                      (if (= dead-code-result 42)
                        (let
                          [unused-assignment-result : i64
                            (selfhost-lint-unused-assignment-self-test)]
                          (if (= unused-assignment-result 42)
                            (let
                              [single-cell-result : i64
                                (selfhost-lint-single-element-array-cell-self-test)]
                              (if (= single-cell-result 42)
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
                                              [divergence-result : i64
                                                (lint-driver-smoke-divergence-padding-self-test)]
                                              (if (= divergence-result 42)
                                                (let
                                                  [unused-variable-result : i64
                                                    (lint-driver-smoke-unused-variable-self-test)]
                                                  (if (=
                                                    unused-variable-result
                                                    42)
                                                    (let
                                                      [unused-unsafe-result : i64
                                                        (lint-driver-smoke-unused-unsafe-self-test)]
                                                      (if (=
                                                        unused-unsafe-result
                                                        42)
                                                        (let
                                                          [copy-result : i64
                                                            (lint-driver-smoke-copy-on-update-struct-self-test)]
                                                          (if (= copy-result 42)
                                                            (lint-driver-smoke-prefer-dotted-field-self-test)
                                                            copy-result))
                                                        unused-unsafe-result))
                                                    unused-variable-result))
                                                divergence-result))
                                            unreachable-result))
                                        no-effect-result))
                                    concat-result))
                                single-cell-result))
                            unused-assignment-result))
                        dead-code-result))
                    redundant-name-result))
                redundant-import-result))
            unused-import-result))
        core-result))))