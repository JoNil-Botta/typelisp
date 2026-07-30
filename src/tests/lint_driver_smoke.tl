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

(define (lint-driver-smoke-bare-self-named-import-macro-source) : String
  "(import pkg.vector)
(vector i64)")

(define (lint-driver-smoke-bare-self-named-import-macro-unused-test) : i64
  (let
    [findings : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_smoke_test.tl"
        (lint-driver-smoke-bare-self-named-import-macro-source)
        (lint_svec.new))]
    (if (selfhost-lint-unused-import-finding-ok? findings)
      42
      39)))

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

(define (lint-driver-smoke-unsafe-builtin-source [name : String]) : String
  (string.append
    "(define (main) : i64
  (unsafe ("
    (string.append name " 0)))")))

(define (lint-driver-smoke-program-unsafe-source [name : String]) : String
  (string.append
    "(define (main) : (Ptr (Ptr u8))
  (unsafe ("
    (string.append name ")))")))

(define (lint-driver-smoke-safe-program-argc-source) : String
  "(define (main) : i64
  (unsafe (program-argc)))")

(define (lint-driver-smoke-safe-tls-current-arena-source) : String
  "(define (main) : i64
  (unsafe (tls-current-arena)))")

(define (lint-driver-smoke-unsafe-parameter-shadow-source) : String
  "(define (main [atomic-load : (-> i64 i64)]) : i64
  (unsafe (atomic-load 1)))")

(define (lint-driver-smoke-unsafe-local-shadow-source) : String
  "(define (identity [value : i64]) : i64 value)
(define (main) : i64
  ((lambda ([atomic-add! : (-> i64 i64)]) : i64
    (unsafe (atomic-add! 1)))
    identity))")

(define (lint-driver-smoke-unsafe-let-shadow-source) : String
  "(define (identity [value : i64]) : i64 value)
(define (main) : i64
  (let
    [atomic-store! : (-> i64 i64) identity]
    (unsafe (atomic-store! 1))))")

(define (lint-driver-smoke-unsafe-top-level-shadow-source) : String
  "(define (volatile-load [value : i64]) : i64 value)
(define (main) : i64
  (unsafe (volatile-load 1)))")

(define (lint-driver-smoke-unsafe-tls-shadow-source) : String
  "(define (tls-current-arena-set! [value : i64]) : i64 value)
(define (main) : i64
  (unsafe (tls-current-arena-set! 1)))")

(define (lint-driver-smoke-unsafe-ambiguous-import-source) : String
  "(import \"legacy.tl\")
(define (main) : i64
  (unsafe (atomic-load 0)))")

(define (lint-driver-smoke-source-has-unused-unsafe-candidate?
  [path : String]
  [source : String]) : bool
  (match (parse-ast-source-diagnostic path source)
    [(ResultAstProgramDiagnostic.Ok program)
      (lint-program-has-unused-unsafe-candidate? program)]
    [(ResultAstProgramDiagnostic.Err _) true]))

(define (lint-driver-smoke-suppressed-unused-unsafe-source) : String
  "(define (main) : i64
  ;; lint-allow: unused-unsafe
  (unsafe (+ 1 2)))")

(define (lint-driver-smoke-unsafe-surface-dep-source) : String
  "(module lint.smoke.unsafe.surface.dep)
(unsafe
  (define (danger [value : i64]) : i64 value))
(define (safe [value : i64]) : i64 value)")

(define (lint-driver-smoke-unsafe-surface-required-source) : String
  "(import \"dep.tl\" module lint.smoke.unsafe.surface.dep as dep)
(define (main) : i64
  (unsafe (dep.danger 42)))")

(define (lint-driver-smoke-unsafe-surface-required-slash-source) : String
  "(import \"dep.tl\" module lint.smoke.unsafe.surface.dep as dep)
(define (main) : i64
  (unsafe (dep/danger 42)))")

(define (lint-driver-smoke-unsafe-surface-safe-source) : String
  "(import \"dep.tl\" module lint.smoke.unsafe.surface.dep as dep)
(define (main) : i64
  (unsafe (dep.safe 42)))")

(define (lint-driver-smoke-unsafe-surface-shadow-source) : String
  "(import \"dep.tl\" module lint.smoke.unsafe.surface.dep as dep)
(defstruct Holder
  (danger i64))
(define (read [dep : Holder]) : i64
  (unsafe dep.danger))
(define (main) : i64
  (read (Holder 42)))")

(define (lint-driver-smoke-unsafe-surface-macro-source) : String
  "(defmacro (identity [value : Expr]) : Expr value)
(define (main) : i64
  (unsafe (identity 42)))")

(define (lint-driver-smoke-unsafe-surface-local-value-source) : String
  "(define (main [value : i64]) : i64
  (unsafe (+ value 1)))")

(define (lint-driver-smoke-unsafe-surface-callable-value-source) : String
  "(define (main) : i64
  (let
    [callable (lambda ([value : i64]) : i64 value)]
    (unsafe (callable 42))))")

(define (lint-driver-smoke-unsafe-surface-legacy-dep-source) : String
  "(unsafe
  (define (legacy-danger [value : i64]) : i64 value))")

(define (lint-driver-smoke-unsafe-surface-legacy-source) : String
  "(import \"legacy_dep.tl\")
(define (main) : i64
  (unsafe (legacy-danger 42)))")

(define (lint-driver-smoke-unsafe-surface-type-error-source) : String
  "(defmacro (identity [value : Expr]) : Expr value)
(define (main) : i64
  (unsafe (identity missing-value)))")

(define (lint-driver-smoke-unsafe-surface-parse-error-source) : String
  "(define (main) : i64
  (unsafe (+ 1 2))")

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
(define (main [items : (__tl_dyn-array Point)]) : i64
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

(define (lint-driver-smoke-name-case-source) : String
  "(define badGlobal : i64 1)
(defstruct bad-type (field i64))
(defenum bad_enum (Value))
(define (BadFunction [BadParam : i64] [_BadUnused : i64]) : i64
  (let
    [BadLocal : i64 BadParam]
    ((lambda ([BadLambda : i64]) : i64 BadLambda) BadLocal)))
(defmacro (BadMacro [BadMacroParam : Expr] [T : type]) : Expr BadMacroParam)
(defdispatch BadDispatch
  (scalar BadFunction)
  (avx2 BadFunction)
  (avx512 BadFunction))
(unsafe (define (BadUnsafe) : i64 0))
(define bad-comptime : i64 1)")

(define (lint-driver-smoke-name-case-binders-source) : String
  "(defenum Choice (Some i64) (None))
(define (cleanup [value : i64]) : unit unit)
(define (binder-cases [n : i64]) : i64
  (begin
    (match (Some 1)
      [(Some BadPattern) BadPattern]
      [(Some Choice.None) 0]
      [None 0])
    (foreach ([BadIndex : i64 0 n]) unit)
    (spmd-reduce sum ([BadReduce : i64 0 n]) 0 BadReduce)
    (spmd-scan sum
      ([BadScanIndex : i64 0 n] [BadPrefix : i64 0])
      BadScanIndex
      BadPrefix)
    (with ([BadResource 1 cleanup]) BadResource)
    0))")

(define (lint-driver-smoke-name-case-module-source) : String
  "(module nested
  ;; (define badGlobal : i64 0)
  (define badGlobal : i64 1)
  (define (BadFunction [BadParam : i64] [unused-name : i64]) : i64
    BadParam))")

(define (lint-driver-smoke-name-case-suppressed-source) : String
  ";; lint-allow: global-name-case
(define BadGlobal : i64 1)
;; lint-allow: type-name-case
(defstruct bad-type (field i64))
;; lint-allow: function-name-case
(define (BadFunction) : i64 1)
(define (good-function
  ;; lint-allow: local-name-case
  [BadParam : i64]) : i64 BadParam)")

(define (lint-driver-smoke-name-case-out-of-scope-source) : String
  (string.append
    "(defstruct GoodType (bad_Field i64))
(defenum GoodEnum (bad-variant))
(extern BadExtern : i64)
(import pkg.data as BadAlias)
("
    "test BadTest unit)
(defmacro (builder [T : type]) : Module
  `(begin
    (module generated.Bad)
    (define BadGenerated : i64 1)))"))

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

(define (lint-driver-smoke-source-findings-with-name-case [source : String]) : LintFindings
  (selfhost-lint-source-with-roots-and-all-options
    "lint_driver_smoke_test.tl"
    source
    (lint_svec.new)
    false
    false
    false
    true))

(define (lint-driver-smoke-source-rule-count-with-name-case
  [source : String]
  [rule : String]) : i64
  (selfhost-lint-findings-rule-count
    (lint-driver-smoke-source-findings-with-name-case source)
    rule))

(define (lint-driver-smoke-name-case-rule-count [findings : LintFindings]) : i64
  (+
    (selfhost-lint-findings-rule-count findings (lint-rule-global-name-case-id))
    (+
      (selfhost-lint-findings-rule-count
        findings
        (lint-rule-function-name-case-id))
      (+
        (selfhost-lint-findings-rule-count
          findings
          (lint-rule-local-name-case-id))
        (selfhost-lint-findings-rule-count
          findings
          (lint-rule-type-name-case-id))))))

(define (lint-driver-smoke-name-case-spans-positive-from
  [findings : LintFindings]
  [index : i64]) : bool
  (if (>= index (lint-findings-count findings))
    true
    (let
      [finding : LintFinding (lint-findings-ref findings index)]
      [rule : String (struct-get finding rule-id)]
      [is-name-case : bool
        (or
          (string.eq rule (lint-rule-global-name-case-id))
          (string.eq rule (lint-rule-function-name-case-id))
          (string.eq rule (lint-rule-local-name-case-id))
          (string.eq rule (lint-rule-type-name-case-id)))]
      [span : AstSourceSpan (struct-get finding span)]
      (and
        (if is-name-case
          (and
            (> (ast-source-span-start-line span) 0)
            (> (ast-source-span-start-col span) 0))
          true)
        (lint-driver-smoke-name-case-spans-positive-from findings (+ index 1))))))

(define (lint-driver-smoke-name-case-spans-positive? [findings : LintFindings]) : bool
  (lint-driver-smoke-name-case-spans-positive-from findings 0))

(define (lint-driver-smoke-name-case-rule-at-line?
  [findings : LintFindings]
  [rule-id : String]
  [line : i64]
  [index : i64]) : bool
  (if (>= index (lint-findings-count findings))
    false
    (let
      [finding : LintFinding (lint-findings-ref findings index)]
      (if (string.eq (struct-get finding rule-id) rule-id)
        (= (ast-source-span-start-line (struct-get finding span)) line)
        (lint-driver-smoke-name-case-rule-at-line?
          findings
          rule-id
          line
          (+ index 1))))))

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
    [parameter-shadow : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_unsafe_parameter_shadow.tl"
        (lint-driver-smoke-unsafe-parameter-shadow-source)
        (lint_svec.new)
        false)]
    [local-shadow : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_unsafe_local_shadow.tl"
        (lint-driver-smoke-unsafe-local-shadow-source)
        (lint_svec.new)
        false)]
    [let-shadow : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_unsafe_let_shadow.tl"
        (lint-driver-smoke-unsafe-let-shadow-source)
        (lint_svec.new)
        false)]
    [top-level-shadow : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_unsafe_top_level_shadow.tl"
        (lint-driver-smoke-unsafe-top-level-shadow-source)
        (lint_svec.new)
        false)]
    [tls-shadow : LintFindings
      (selfhost-lint-source-with-roots-and-options
        "lint_driver_unsafe_tls_shadow.tl"
        (lint-driver-smoke-unsafe-tls-shadow-source)
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
      [(lint-driver-smoke-source-has-unused-unsafe-candidate?
          "lint_driver_atomic_load.tl"
          (lint-driver-smoke-unsafe-builtin-source "atomic-load"))
        160]
      [(lint-driver-smoke-source-has-unused-unsafe-candidate?
          "lint_driver_atomic_store.tl"
          (lint-driver-smoke-unsafe-builtin-source "atomic-store!"))
        161]
      [(lint-driver-smoke-source-has-unused-unsafe-candidate?
          "lint_driver_atomic_add.tl"
          (lint-driver-smoke-unsafe-builtin-source "atomic-add!"))
        162]
      [(lint-driver-smoke-source-has-unused-unsafe-candidate?
          "lint_driver_atomic_fetch_add.tl"
          (lint-driver-smoke-unsafe-builtin-source "atomic-fetch-add!"))
        163]
      [(lint-driver-smoke-source-has-unused-unsafe-candidate?
          "lint_driver_atomic_cas.tl"
          (lint-driver-smoke-unsafe-builtin-source "atomic-cas!"))
        164]
      [(lint-driver-smoke-source-has-unused-unsafe-candidate?
          "lint_driver_volatile_load.tl"
          (lint-driver-smoke-unsafe-builtin-source "volatile-load"))
        165]
      [(lint-driver-smoke-source-has-unused-unsafe-candidate?
          "lint_driver_volatile_store.tl"
          (lint-driver-smoke-unsafe-builtin-source "volatile-store!"))
        166]
      [(lint-driver-smoke-source-has-unused-unsafe-candidate?
          "lint_driver_tls_set.tl"
          (lint-driver-smoke-unsafe-builtin-source "tls-current-arena-set!"))
        167]
      [(lint-driver-smoke-source-has-unused-unsafe-candidate?
          "lint_driver_program_argv.tl"
          (lint-driver-smoke-program-unsafe-source "program-argv"))
        168]
      [(lint-driver-smoke-source-has-unused-unsafe-candidate?
          "lint_driver_program_envp.tl"
          (lint-driver-smoke-program-unsafe-source "program-envp"))
        169]
      [(not
          (lint-driver-smoke-source-has-unused-unsafe-candidate?
            "lint_driver_program_argc.tl"
            (lint-driver-smoke-safe-program-argc-source)))
        170]
      [(not
          (lint-driver-smoke-source-has-unused-unsafe-candidate?
            "lint_driver_tls_current.tl"
            (lint-driver-smoke-safe-tls-current-arena-source)))
        171]
      [(not (= (lint-findings-count parameter-shadow) 1)) 172]
      [(not (= (lint-findings-count local-shadow) 1)) 173]
      [(not (= (lint-findings-count let-shadow) 1)) 174]
      [(not (= (lint-findings-count top-level-shadow) 1)) 175]
      [(not (= (lint-findings-count tls-shadow) 1)) 176]
      [(not
          (lint-driver-smoke-source-has-unused-unsafe-candidate?
            "lint_driver_unsafe_ambiguous_import.tl"
            (lint-driver-smoke-unsafe-ambiguous-import-source)))
        177]
      [else 42])))

(define (lint-driver-smoke-unsafe-surface-paths) : lint_svec.Vec
  (let
    [paths : lint_svec.Vec (lint_svec.new)]
    (begin
      (lint_svec.push (&mut paths) "target/lint_unsafe_surface/required_a.tl")
      (lint_svec.push (&mut paths) "target/lint_unsafe_surface/required_b.tl")
      paths)))

(define (lint-driver-smoke-unsafe-surface-error-paths) : lint_svec.Vec
  (let
    [paths : lint_svec.Vec (lint_svec.new)]
    (begin
      (lint_svec.push (&mut paths) "target/lint_unsafe_surface/type_error.tl")
      (lint_svec.push (&mut paths) "target/lint_unsafe_surface/required_a.tl")
      paths)))

(define (lint-driver-smoke-unsafe-surface-macro-paths) : lint_svec.Vec
  (let
    [paths : lint_svec.Vec (lint_svec.new)]
    (begin
      (lint_svec.push (&mut paths) "target/lint_unsafe_surface/macro.tl")
      paths)))

(define (lint-driver-smoke-unsafe-surface-request-count
  [source : String]
  [stdlib-roots : lint_svec.Vec]) : i64
  (with-arena
    request
    (let
      [findings : LintFindings
        (selfhost-lint-source-with-roots-and-options
          "target/lint_unsafe_surface/direct_safe.tl"
          source
          stdlib-roots
          false)]
      (struct-get findings len))))

(define (lint-driver-smoke-unsafe-surface-self-test) : i64
  (begin
    (compiler-load-test-mkdir "target/lint_unsafe_surface")
    (io.write-file
      "target/lint_unsafe_surface/dep.tl"
      (lint-driver-smoke-unsafe-surface-dep-source))
    (io.write-file
      "target/lint_unsafe_surface/legacy_dep.tl"
      (lint-driver-smoke-unsafe-surface-legacy-dep-source))
    (io.write-file
      "target/lint_unsafe_surface/required_a.tl"
      (lint-driver-smoke-unsafe-surface-required-source))
    (io.write-file
      "target/lint_unsafe_surface/required_b.tl"
      (lint-driver-smoke-unsafe-surface-required-slash-source))
    (io.write-file
      "target/lint_unsafe_surface/safe.tl"
      (lint-driver-smoke-unsafe-surface-safe-source))
    (io.write-file
      "target/lint_unsafe_surface/shadow.tl"
      (lint-driver-smoke-unsafe-surface-shadow-source))
    (io.write-file
      "target/lint_unsafe_surface/macro.tl"
      (lint-driver-smoke-unsafe-surface-macro-source))
    (io.write-file
      "target/lint_unsafe_surface/local_value.tl"
      (lint-driver-smoke-unsafe-surface-local-value-source))
    (io.write-file
      "target/lint_unsafe_surface/callable_value.tl"
      (lint-driver-smoke-unsafe-surface-callable-value-source))
    (io.write-file
      "target/lint_unsafe_surface/legacy.tl"
      (lint-driver-smoke-unsafe-surface-legacy-source))
    (io.write-file
      "target/lint_unsafe_surface/type_error.tl"
      (lint-driver-smoke-unsafe-surface-type-error-source))
    (let
      [_reset-direct : unit (selfhost-lint-unsafe-surface-cache-reset!)]
      [direct-count : i64
        (lint-driver-smoke-unsafe-surface-request-count
          (lint-driver-smoke-unsafe-surface-safe-source)
          (lint_svec.new))]
      [direct-fallbacks : i64 (selfhost-lint-unused-unsafe-fallback-count)]
      [second-direct-count : i64
        (lint-driver-smoke-unsafe-surface-request-count
          (lint-driver-smoke-unsafe-surface-safe-source)
          (lint_svec.new))]
      [second-direct-fallbacks : i64
        (selfhost-lint-unused-unsafe-fallback-count)]
      [_reset-safe : unit (selfhost-lint-unsafe-surface-cache-reset!)]
      [safe-status : i64
        (selfhost-lint-run-file-in-scratch
          "target/lint_unsafe_surface/safe.tl"
          (lint_svec.new)
          true
          false
          false
          false
          false)]
      [safe-parses : i64 (selfhost-lint-unsafe-surface-cache-parse-count)]
      [safe-fallbacks : i64 (selfhost-lint-unused-unsafe-fallback-count)]
      [_reset-shadow : unit (selfhost-lint-unsafe-surface-cache-reset!)]
      [_shadow-status : i64
        (selfhost-lint-run-file-in-scratch
          "target/lint_unsafe_surface/shadow.tl"
          (lint_svec.new)
          false
          false
          false
          false
          false)]
      [shadow-fallbacks : i64 (selfhost-lint-unused-unsafe-fallback-count)]
      [_reset-macro : unit (selfhost-lint-unsafe-surface-cache-reset!)]
      [macro-status : i64
        (selfhost-lint-run-file-in-scratch
          "target/lint_unsafe_surface/macro.tl"
          (lint_svec.new)
          true
          false
          false
          false
          false)]
      [macro-fallbacks : i64 (selfhost-lint-unused-unsafe-fallback-count)]
      [_reset-local-value : unit (selfhost-lint-unsafe-surface-cache-reset!)]
      [local-value-status : i64
        (selfhost-lint-run-file-in-scratch
          "target/lint_unsafe_surface/local_value.tl"
          (lint_svec.new)
          true
          false
          false
          false
          false)]
      [local-value-fallbacks : i64 (selfhost-lint-unused-unsafe-fallback-count)]
      [_reset-callable-value : unit (selfhost-lint-unsafe-surface-cache-reset!)]
      [_callable-value-status : i64
        (selfhost-lint-run-file-in-scratch
          "target/lint_unsafe_surface/callable_value.tl"
          (lint_svec.new)
          false
          false
          false
          false
          false)]
      [callable-value-fallbacks : i64
        (selfhost-lint-unused-unsafe-fallback-count)]
      [_reset-legacy : unit (selfhost-lint-unsafe-surface-cache-reset!)]
      [_legacy-status : i64
        (selfhost-lint-run-file-in-scratch
          "target/lint_unsafe_surface/legacy.tl"
          (lint_svec.new)
          false
          false
          false
          false
          false)]
      [legacy-fallbacks : i64 (selfhost-lint-unused-unsafe-fallback-count)]
      [_direct-error-findings : LintFindings
        (selfhost-lint-typed-unused-unsafe-findings
          "target/lint_unsafe_surface/direct_type_error.tl"
          (lint-driver-smoke-unsafe-surface-type-error-source)
          (lint_svec.new)
          (selfhost-lint-language-cfgs))]
      [direct-error : String selfhost-lint-typed-unused-unsafe-error]
      [_direct-parse-error-findings : LintFindings
        (selfhost-lint-typed-unused-unsafe-findings
          "target/lint_unsafe_surface/direct_parse_error.tl"
          (lint-driver-smoke-unsafe-surface-parse-error-source)
          (lint_svec.new)
          (selfhost-lint-language-cfgs))]
      [direct-parse-error : String selfhost-lint-typed-unused-unsafe-error]
      [file-error-status : i64
        (selfhost-lint-run-file-in-scratch
          "target/lint_unsafe_surface/type_error.tl"
          (lint_svec.new)
          false
          false
          false
          false
          false)]
      [batch-macro-status : i64
        (selfhost-lint-files
          (lint-driver-smoke-unsafe-surface-macro-paths)
          (lint_svec.new)
          true
          false
          false
          false
          false
          false
          0)]
      [package-macro-status : i64
        (selfhost-lint-package-files
          (lint-driver-smoke-unsafe-surface-macro-paths)
          (lint_svec.new)
          true
          false
          false
          false
          false
          (selfhost-lint-dead-decls-with-capacity 0)
          false
          0)]
      [batch-error-status : i64
        (selfhost-lint-files
          (lint-driver-smoke-unsafe-surface-error-paths)
          (lint_svec.new)
          false
          false
          false
          false
          false
          false
          0)]
      [package-error-status : i64
        (selfhost-lint-package-files
          (lint-driver-smoke-unsafe-surface-error-paths)
          (lint_svec.new)
          false
          false
          false
          false
          false
          (selfhost-lint-dead-decls-with-capacity 0)
          false
          0)]
      [batch-status : i64
        (selfhost-lint-files
          (lint-driver-smoke-unsafe-surface-paths)
          (lint_svec.new)
          false
          false
          false
          false
          false
          false
          0)]
      (cond
        [(not (= direct-count 1)) 115]
        [(not (= direct-fallbacks 1)) 116]
        [(not (= second-direct-count 1)) 117]
        [(not (= second-direct-fallbacks 1)) 118]
        [(not (= safe-status 1)) 100]
        [(not (= safe-parses 1)) 101]
        [(not (= safe-fallbacks 0)) 102]
        [(not (= shadow-fallbacks 1)) 103]
        [(not (= macro-status 1)) 178]
        [(not (= macro-fallbacks 1)) 104]
        [(not (= legacy-fallbacks 1)) 105]
        [(not (= batch-status 0)) 106]
        [(not (= (selfhost-lint-unsafe-surface-cache-parse-count) 1)) 107]
        [(not (= (selfhost-lint-unsafe-surface-cache-hit-count) 1)) 108]
        [(not (= (selfhost-lint-unused-unsafe-fallback-count) 0)) 109]
        [(not (= (selfhost-lint-unused-unsafe-surface-required-total) 2)) 110]
        [(not (= (selfhost-lint-unused-unsafe-surface-classified-total) 2)) 114]
        [(not (= local-value-status 1)) 111]
        [(not (= local-value-fallbacks 0)) 112]
        [(not (= callable-value-fallbacks 1)) 113]
        [(not
            (and
              (string.contains
                (& direct-error)
                "target/lint_unsafe_surface/direct_type_error.tl")
              (string.contains (& direct-error) "typecheck:")))
          179]
        [(not
            (and
              (string.contains
                (& direct-parse-error)
                "target/lint_unsafe_surface/direct_parse_error.tl")
              (string.contains (& direct-parse-error) "reader:")))
          180]
        [(not (= file-error-status 1)) 181]
        [(not (= batch-error-status 1)) 182]
        [(not (= package-error-status 1)) 183]
        [(not (= batch-macro-status 1)) 184]
        [(not (= package-macro-status 1)) 185]
        [else 42]))))

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

(define (lint-driver-smoke-name-case-self-test) : i64
  (let
    [findings : LintFindings
      (lint-driver-smoke-source-findings-with-name-case
        (lint-driver-smoke-name-case-source))]
    [binder-findings : LintFindings
      (lint-driver-smoke-source-findings-with-name-case
        (lint-driver-smoke-name-case-binders-source))]
    [module-findings : LintFindings
      (lint-driver-smoke-source-findings-with-name-case
        (lint-driver-smoke-name-case-module-source))]
    [default-findings : LintFindings
      (selfhost-lint-source-with-roots
        "lint_driver_smoke_test.tl"
        (lint-driver-smoke-name-case-source)
        (lint_svec.new))]
    (cond
      [(not
          (and
            (lint-name-case-kebab? "good-name")
            (lint-name-case-kebab? "ready?")
            (lint-name-case-kebab? "mutate!")
            (lint-name-case-kebab? "int->string")
            (lint-name-case-kebab? "sha-256")
            (lint-name-case-kebab? "u16-7")
            (lint-name-case-kebab? "+")
            (lint-name-case-kebab? "name2")
            (not (lint-name-case-kebab? "Bad"))
            (not (lint-name-case-kebab? "bad_name"))
            (not (lint-name-case-kebab? "-bad"))
            (not (lint-name-case-kebab? "bad-"))
            (not (lint-name-case-kebab? "bad--name"))
            (not (lint-name-case-kebab? "bad->"))
            (not (lint-name-case-kebab? "bad->->name"))
            (not (lint-name-case-kebab? "2bad"))))
        81]
      [(not
          (and
            (lint-name-case-local-kebab? "_unused")
            (lint-name-case-local-kebab? "_")
            (not (lint-name-case-local-kebab? "__unused"))
            (not (lint-name-case-local-kebab? "_Bad"))))
        82]
      [(not
          (and
            (lint-name-case-type-operand? "T")
            (lint-name-case-type-operand? "value-type")
            (lint-name-case-type-operand? "_T")
            (not (lint-name-case-type-operand? "ValueType"))
            (not (lint-name-case-type-operand? "__T"))))
        83]
      [(not
          (and
            (lint-name-case-upper-camel? "ByteBuf")
            (lint-name-case-upper-camel? "TlciHostABI")
            (lint-name-case-upper-camel? "A2")
            (not (lint-name-case-upper-camel? "byteBuf"))
            (not (lint-name-case-upper-camel? "Bad-Type"))
            (not (lint-name-case-upper-camel? "Bad_Type"))
            (not (lint-name-case-upper-camel? "2Bad"))))
        84]
      [(not
          (and
            (string.eq
              (lint-name-case-kebab-suggestion "BadFunction" false)
              "bad-function")
            (string.eq
              (lint-name-case-kebab-suggestion "BadGlobal" false)
              "bad-global")
            (string.eq
              (lint-name-case-upper-camel-suggestion "bad-type")
              "BadType")))
        85]
      [(not
          (=
            (selfhost-lint-findings-rule-count
              findings
              (lint-rule-global-name-case-id))
            1))
        86]
      [(not
          (=
            (selfhost-lint-findings-rule-count
              findings
              (lint-rule-function-name-case-id))
            4))
        87]
      [(not
          (=
            (selfhost-lint-findings-rule-count
              findings
              (lint-rule-type-name-case-id))
            2))
        88]
      [(not
          (=
            (selfhost-lint-findings-rule-count
              findings
              (lint-rule-local-name-case-id))
            5))
        89]
      [(not
          (=
            (selfhost-lint-findings-rule-count
              binder-findings
              (lint-rule-local-name-case-id))
            6))
        90]
      [(not
          (and
            (lint-driver-smoke-name-case-spans-positive? findings)
            (lint-driver-smoke-name-case-spans-positive? binder-findings)))
        91]
      [(not
          (=
            (lint-driver-smoke-name-case-rule-count
              (lint-driver-smoke-source-findings-with-name-case
                (lint-driver-smoke-name-case-suppressed-source)))
            0))
        92]
      [(not
          (=
            (lint-driver-smoke-name-case-rule-count
              (lint-driver-smoke-source-findings-with-name-case
                (lint-driver-smoke-name-case-out-of-scope-source)))
            0))
        93]
      [(not (= (lint-driver-smoke-name-case-rule-count default-findings) 0)) 94]
      [(not
          (and
            (not
              (string.eq (lint-rule-message (lint-rule-global-name-case-id)) ""))
            (not
              (string.eq
                (lint-rule-suggestion (lint-rule-function-name-case-id))
                ""))
            (not
              (string.eq (lint-rule-message (lint-rule-local-name-case-id)) ""))
            (not
              (string.eq
                (lint-rule-suggestion (lint-rule-type-name-case-id))
                ""))))
        95]
      [(not (= (lint-driver-smoke-name-case-rule-count module-findings) 3)) 96]
      [(not
          (=
            (selfhost-lint-findings-rule-count
              module-findings
              (lint-rule-unused-variable-id))
            0))
        97]
      [(not
          (lint-driver-smoke-name-case-rule-at-line?
            module-findings
            (lint-rule-global-name-case-id)
            3
            0))
        98]
      [else 42])))

(define (lint-driver-smoke-legacy-path-import-source) : String
  (string.append
    "(im"
    (string.append
      "port \"../compiler_backend.tl\" as backend)
(im"
      "port \"dep.tl\" module package.dep as dep)
(import stdlib.string)")))

(define (lint-driver-smoke-findings-contain-message?
  [findings : LintFindings]
  [needle : String]
  [index : i64]) : bool
  (if (>= index (lint-findings-count findings))
    false
    (let
      [finding : LintFinding (lint-findings-ref findings index)]
      [message : String (struct-get finding message)]
      (or
        (string.contains (& message) (& needle))
        (lint-driver-smoke-findings-contain-message?
          findings
          needle
          (+ index 1))))))

(define (lint-driver-smoke-legacy-path-import-self-test) : i64
  (match (parse-ast-source-diagnostic
    "lint_driver_legacy_path_import_smoke.tl"
    (lint-driver-smoke-legacy-path-import-source))
    [(ResultAstProgramDiagnostic.Err _) 186]
    [(ResultAstProgramDiagnostic.Ok program)
      (let
        [findings : LintFindings
          (lint-legacy-path-imports-in-program program (lint-findings-empty))]
        (cond
          [(not (= (lint-findings-count findings) 2)) 187]
          [(not
              (lint-driver-smoke-findings-contain-message?
                findings
                "(import compiler_backend as backend)"
                0))
            188]
          [(not
              (lint-driver-smoke-findings-contain-message?
                findings
                "(import package.dep as dep)"
                0))
            189]
          [(not
              (string.eq
                (lint-rule-suggestion (lint-rule-legacy-path-import-id))
                (lint-rule-legacy-path-import-suggestion)))
            190]
          [else 42]))]))

(define (main) : i64
  (begin
    ;; The imported driver core defines printing helpers; keep the print-string
    ;; runtime linked even when this smoke only exercises the pure source path.
    (io.print-string "")
    (let
      [core-result : i64 (compiler-lint-driver-self-test)]
      [unused-import-result : i64 (selfhost-lint-unused-imports-self-test)]
      [bare-import-result : i64
        (lint-driver-smoke-bare-self-named-import-macro-unused-test)]
      [redundant-import-result : i64
        (lint-driver-smoke-redundant-import-alias-self-test)]
      [redundant-name-result : i64
        (lint-driver-smoke-redundant-function-name-self-test)]
      [dead-code-result : i64 (selfhost-lint-package-dead-code-self-test)]
      [unused-assignment-result : i64
        (selfhost-lint-unused-assignment-self-test)]
      [single-cell-result : i64
        (selfhost-lint-single-element-array-cell-self-test)]
      [dynamic-array-literal-result : i64
        (selfhost-lint-dynamic-array-literal-self-test)]
      [concat-result : i64
        (lint-driver-smoke-deprecated-string-concat-self-test)]
      [no-effect-result : i64 (lint-driver-smoke-no-effect-self-test)]
      [unreachable-result : i64 (lint-driver-smoke-unreachable-self-test)]
      [divergence-result : i64 (lint-driver-smoke-divergence-padding-self-test)]
      [unused-variable-result : i64
        (lint-driver-smoke-unused-variable-self-test)]
      [unused-unsafe-result : i64 (lint-driver-smoke-unused-unsafe-self-test)]
      [unsafe-surface-result : i64 (lint-driver-smoke-unsafe-surface-self-test)]
      [copy-result : i64 (lint-driver-smoke-copy-on-update-struct-self-test)]
      [dotted-result : i64 (lint-driver-smoke-prefer-dotted-field-self-test)]
      [name-case-result : i64 (lint-driver-smoke-name-case-self-test)]
      [legacy-path-import-result : i64
        (lint-driver-smoke-legacy-path-import-self-test)]
      (cond
        [(not (= core-result 42)) core-result]
        [(not (= unused-import-result 42)) unused-import-result]
        [(not (= bare-import-result 42)) bare-import-result]
        [(not (= redundant-import-result 42)) redundant-import-result]
        [(not (= redundant-name-result 42)) redundant-name-result]
        [(not (= dead-code-result 42)) dead-code-result]
        [(not (= unused-assignment-result 42)) unused-assignment-result]
        [(not (= single-cell-result 42)) single-cell-result]
        [(not (= dynamic-array-literal-result 42)) dynamic-array-literal-result]
        [(not (= concat-result 42)) concat-result]
        [(not (= no-effect-result 42)) no-effect-result]
        [(not (= unreachable-result 42)) unreachable-result]
        [(not (= divergence-result 42)) divergence-result]
        [(not (= unused-variable-result 42)) unused-variable-result]
        [(not (= unused-unsafe-result 42)) unused-unsafe-result]
        [(not (= unsafe-surface-result 42)) unsafe-surface-result]
        [(not (= copy-result 42)) copy-result]
        [(not (= dotted-result 42)) dotted-result]
        [(not (= name-case-result 42)) name-case-result]
        [else legacy-path-import-result]))))