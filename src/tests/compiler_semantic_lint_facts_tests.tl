(import stdlib.arena)
(import stdlib.test)
(import stdlib.string)
(import stdlib.str_cat)
(import stdlib.vector)
(import stdlib.profile)
(import (vector.vector String) as roots)
(import compiler_check_core as check)
(import compiler_semantic_lint_facts as facts)
(import compiler_typecheck_core as tc)
(import compiler_typecheck_api as tc_api)
(import compiler_load as load)
(import compiler_load_tests as load_tests)
(import compiler_driver_core as driver)
(import compiler_owned_view as owned_view)

(define semantic-facts-test-calls : i64
  0)
(define semantic-facts-test-expression-count : i64
  0)
(define semantic-facts-test-binding-count : i64
  0)
(define semantic-facts-test-function-count : i64
  0)
(define semantic-facts-test-local-uses : i64
  0)
(define semantic-facts-test-unreliable : i64
  0)
(define semantic-facts-test-poisoned : i64
  0)
(define semantic-facts-test-unresolved : i64
  0)
(define semantic-facts-test-dependent : i64
  0)
(define semantic-facts-test-imported : i64
  0)
(define semantic-facts-test-owned-type : String
  "")
(define semantic-facts-test-field-uses : i64
  0)
(define semantic-facts-test-nominal-uses : i64
  0)
(define semantic-facts-test-variant-uses : i64
  0)
(define semantic-facts-test-core-uses : i64
  0)
(define semantic-facts-test-forbidden : i64
  0)
(define semantic-facts-test-compatible-try : i64
  0)
(define semantic-facts-test-macro-arguments : i64
  0)
(define semantic-facts-test-synthetic : i64
  0)
(define semantic-facts-test-missing-binding-spans : i64
  0)
(define semantic-facts-test-function-uses : i64
  0)
(define semantic-facts-test-generated : i64
  0)
(define semantic-facts-test-missing-nominal-spans : i64
  0)
(define semantic-facts-test-reliable-bools : i64
  0)
(define semantic-facts-test-captured-uses : i64
  0)
(define semantic-facts-test-allowed-lane-operands : i64
  0)
(define semantic-facts-test-forbidden-lane-operands : i64
  0)
(define semantic-facts-test-growth-line : i64
  -1)
(define semantic-facts-test-growth-uses : i64
  0)
(define semantic-facts-test-growth-mismatches : i64
  0)
(define semantic-facts-test-persistent-binding-count : i64
  0)

(define (semantic-facts-test-growth-identity
  [snapshot : (& snapshot facts.CompilerSemanticFacts)]
  [fact : (& fact facts.CompilerSemanticExpressionFact)]) : unit
  (when
    (and
      (> semantic-facts-test-growth-line 0)
      (string.eq (& fact.resolved-value.name) "growth-probe"))
    (let
      [previous : bool
        (match (facts.compiler-semantic-facts-function-at
          snapshot
          fact.function)
          [(facts.CompilerSemanticFunctionLookup.Found row)
            (string.eq (& row.identity.name) "previous")]
          [_ false])]
      [owner-matches : bool
        (match (facts.compiler-semantic-facts-function-at
          snapshot
          fact.resolved-value.function)
          [(facts.CompilerSemanticFunctionLookup.Found row)
            (string.eq
              (& row.identity.name)
              (if previous
                "previous"
                "value"))]
          [_ false])]
      (set!
        semantic-facts-test-growth-uses
        (+ semantic-facts-test-growth-uses 1))
      (unless
        (and
          owner-matches
          (match fact.resolved-value.kind
            [(facts.CompilerSemanticFactIdentityKind.Local) true]
            [_ false])
          (=
            fact.resolved-value.span.start-line
            (cast
              (if previous
                (cast 2 : i64)
                semantic-facts-test-growth-line)
              : i32)))
        (set!
          semantic-facts-test-growth-mismatches
          (+ semantic-facts-test-growth-mismatches 1))))))

(define (semantic-facts-test-consumer
  [_context : i64]
  [snapshot : (& snapshot facts.CompilerSemanticFacts)]) : unit
  (let
    [i : i64 0]
    (set! semantic-facts-test-calls (+ semantic-facts-test-calls 1))
    (set!
      semantic-facts-test-expression-count
      (facts.compiler-semantic-facts-expression-count snapshot))
    (set!
      semantic-facts-test-binding-count
      (facts.compiler-semantic-facts-binding-count snapshot))
    (set!
      semantic-facts-test-function-count
      (facts.compiler-semantic-facts-function-count snapshot))
    (set! semantic-facts-test-local-uses 0)
    (set! semantic-facts-test-growth-uses 0)
    (set! semantic-facts-test-growth-mismatches 0)
    (when
      (> semantic-facts-test-growth-line 0)
      (set!
        semantic-facts-test-persistent-binding-count
        (facts.compiler-semantic-fact-recorder-data
          (facts.CompilerSemanticFactRecorder snapshot.address)).persistent-bindings.len))
    (set! semantic-facts-test-unreliable 0)
    (set! semantic-facts-test-poisoned 0)
    (set! semantic-facts-test-unresolved 0)
    (set! semantic-facts-test-dependent 0)
    (set! semantic-facts-test-imported 0)
    (set! semantic-facts-test-field-uses 0)
    (set! semantic-facts-test-nominal-uses 0)
    (set! semantic-facts-test-variant-uses 0)
    (set! semantic-facts-test-core-uses 0)
    (set! semantic-facts-test-forbidden 0)
    (set! semantic-facts-test-compatible-try 0)
    (set! semantic-facts-test-macro-arguments 0)
    (set! semantic-facts-test-synthetic 0)
    (set! semantic-facts-test-missing-binding-spans 0)
    (set! semantic-facts-test-function-uses 0)
    (set! semantic-facts-test-generated 0)
    (set! semantic-facts-test-missing-nominal-spans 0)
    (set! semantic-facts-test-reliable-bools 0)
    (set! semantic-facts-test-captured-uses 0)
    (set! semantic-facts-test-allowed-lane-operands 0)
    (set! semantic-facts-test-forbidden-lane-operands 0)
    (while (< i (facts.compiler-semantic-facts-expression-count snapshot))
      (let
        [fact : facts.CompilerSemanticExpressionFact
          (match (facts.compiler-semantic-facts-expression-at snapshot i)
            [(facts.CompilerSemanticFactLookup.Found row) row]
            [_
              (test.assert-true false "in-range expression")
              (return unit)])]
        (semantic-facts-test-growth-identity snapshot (& fact))
        (match fact.reliability
          [(facts.CompilerSemanticFactReliability.Unresolved)
            (set!
              semantic-facts-test-unresolved
              (+ semantic-facts-test-unresolved 1))]
          [(facts.CompilerSemanticFactReliability.Poisoned)
            (set!
              semantic-facts-test-poisoned
              (+ semantic-facts-test-poisoned 1))]
          [(facts.CompilerSemanticFactReliability.Dependent)
            (set!
              semantic-facts-test-dependent
              (+ semantic-facts-test-dependent 1))]
          [_ unit])
        (when
          (string.contains (& fact.resolved-value.name) "shared-value")
          (begin
            (test.assert-true
              (> fact.resolved-value.declaration -1)
              "import retains the actual declaration")
            (test.assert-true
              (> fact.resolved-value.span.start-line 0)
              "import retains its declaring token")
            (test.assert-true
              (string.contains (& fact.resolved-value.module) "helper")
              "import retains its owning module")
            (test.assert-true
              (string.contains (& fact.resolved-value.path) "/helper.tl")
              "import retains its declaring file")
            (set!
              semantic-facts-test-imported
              (+ semantic-facts-test-imported 1))))
        (when
          (string.eq (& fact.resolved-value.name) "lane-probe")
          (if fact.early-exit-allowed
            (set!
              semantic-facts-test-allowed-lane-operands
              (+ semantic-facts-test-allowed-lane-operands 1))
            (set!
              semantic-facts-test-forbidden-lane-operands
              (+ semantic-facts-test-forbidden-lane-operands 1))))
        (match fact.resolved-value.kind
          [(facts.CompilerSemanticFactIdentityKind.Local)
            (when
              (and
                (>= fact.resolved-value.function 0)
                (!= fact.function fact.resolved-value.function))
              (set!
                semantic-facts-test-captured-uses
                (+ semantic-facts-test-captured-uses 1)))
            (set!
              semantic-facts-test-local-uses
              (+ semantic-facts-test-local-uses 1))]
          [(facts.CompilerSemanticFactIdentityKind.Parameter)
            (set!
              semantic-facts-test-local-uses
              (+ semantic-facts-test-local-uses 1))]
          [(facts.CompilerSemanticFactIdentityKind.Field)
            (set!
              semantic-facts-test-field-uses
              (+ semantic-facts-test-field-uses 1))]
          [(facts.CompilerSemanticFactIdentityKind.Variant)
            (set!
              semantic-facts-test-variant-uses
              (+ semantic-facts-test-variant-uses 1))]
          [(facts.CompilerSemanticFactIdentityKind.CoreOperation)
            (set!
              semantic-facts-test-core-uses
              (+ semantic-facts-test-core-uses 1))]
          [(facts.CompilerSemanticFactIdentityKind.Function)
            (test.assert-true
              (> fact.resolved-value.declaration -1)
              "resolved function declaration")
            (set!
              semantic-facts-test-function-uses
              (+ semantic-facts-test-function-uses 1))]
          [_ unit])
        (when
          (>= fact.resolved-type.nominal.declaration 0)
          (begin
            (set!
              semantic-facts-test-nominal-uses
              (+ semantic-facts-test-nominal-uses 1))
            (test.assert-true
              (> (string.string-length fact.resolved-type.nominal.name) 0)
              "direct nominal identity owns its spelling")
            (when
              (= fact.resolved-type.nominal.span.start-line 0)
              (set!
                semantic-facts-test-missing-nominal-spans
                (+ semantic-facts-test-missing-nominal-spans 1)))))
        (when
          (and (>= fact.function 0) (not fact.early-exit-allowed))
          (set!
            semantic-facts-test-forbidden
            (+ semantic-facts-test-forbidden 1)))
        (match fact.try-fact
          [(facts.CompilerSemanticTryFact.Compatible)
            (set!
              semantic-facts-test-compatible-try
              (+ semantic-facts-test-compatible-try 1))]
          [_ unit])
        (match fact.provenance
          [(facts.CompilerSemanticFactProvenance.MacroArgument)
            (set!
              semantic-facts-test-macro-arguments
              (+ semantic-facts-test-macro-arguments 1))]
          [(facts.CompilerSemanticFactProvenance.Synthetic)
            (set!
              semantic-facts-test-synthetic
              (+ semantic-facts-test-synthetic 1))]
          [(facts.CompilerSemanticFactProvenance.CheckedGenerated)
            (set!
              semantic-facts-test-generated
              (+ semantic-facts-test-generated 1))]
          [_ unit])
        (match fact.reliability
          [(facts.CompilerSemanticFactReliability.Reliable)
            (when
              (string.eq (& fact.resolved-type.text) "bool")
              (set!
                semantic-facts-test-reliable-bools
                (+ semantic-facts-test-reliable-bools 1)))
            (set!
              semantic-facts-test-owned-type
              (string.copy (& fact.resolved-type.text)))]
          [_
            (set!
              semantic-facts-test-unreliable
              (+ semantic-facts-test-unreliable 1))])
        (match (facts.compiler-semantic-facts-lookup snapshot fact.expression)
          [(facts.CompilerSemanticFactLookup.Found same)
            (test.assert-i64-eq
              same.expression
              fact.expression
              "source ID round trip")]
          [_ (test.assert-true false "every enumerated expression is indexed")])
        (set! i (+ i 1))))
    (set! i 0)
    (while (< i (facts.compiler-semantic-facts-binding-count snapshot))
      (when
        (match (facts.compiler-semantic-facts-binding-at snapshot i)
          [(facts.CompilerSemanticBindingLookup.Found row)
            (test.assert-true
              (and
                (>= row.function 0)
                (<
                  row.function
                  (facts.compiler-semantic-facts-function-count snapshot)))
              "binding retains its function owner")
            (= row.span.start-line 0)]
          [_ true])
        (set!
          semantic-facts-test-missing-binding-spans
          (+ semantic-facts-test-missing-binding-spans 1)))
      (set! i (+ i 1)))
    (set! i 0)
    (while (< i (facts.compiler-semantic-facts-function-count snapshot))
      (match (facts.compiler-semantic-facts-function-at snapshot i)
        [(facts.CompilerSemanticFunctionLookup.Found row)
          (test.assert-true
            (> (string.string-length row.identity.path) 0)
            "function owns its lexical source path")
          (test.assert-true
            (> (string.string-length row.return-type.text) 0)
            "enclosing function has its resolved return type")]
        [_ (test.assert-true false "in-range function")])
      (set! i (+ i 1)))
    (match (facts.compiler-semantic-facts-lookup snapshot -1)
      [(facts.CompilerSemanticFactLookup.Missing) unit]
      [_ (test.assert-true false "missing AST id must stay missing")])
    (match (facts.compiler-semantic-facts-expression-at
      snapshot
      (facts.compiler-semantic-facts-expression-count snapshot))
      [(facts.CompilerSemanticFactLookup.Missing) unit]
      [_ (test.assert-true false "past-end expression index")])
    (match (facts.compiler-semantic-facts-binding-at snapshot -1)
      [(facts.CompilerSemanticBindingLookup.Missing) unit]
      [_ (test.assert-true false "negative binding index")])
    (match (facts.compiler-semantic-facts-function-at
      snapshot
      (facts.compiler-semantic-facts-function-count snapshot))
      [(facts.CompilerSemanticFunctionLookup.Missing) unit]
      [_ (test.assert-true false "past-end function index")])
    ;; Mutating a selected owned row cannot mutate the sealed snapshot.
    (when
      (> (facts.compiler-semantic-facts-binding-count snapshot) 0)
      (match (facts.compiler-semantic-facts-binding-at snapshot 0)
        [(facts.CompilerSemanticBindingLookup.Found row)
          (let
            [original : String (string.copy (& row.name))]
            (unsafe
              (ptr-write!
                (ptr-cast (string-data (& row.name)) : (MutPtr u8))
                (cast 88 : u8)))
            (match (facts.compiler-semantic-facts-binding-at snapshot 0)
              [(facts.CompilerSemanticBindingLookup.Found again)
                (test.assert-string-eq
                  (& again.name)
                  (& original)
                  "query strings are deep owned copies")]
              [_ (test.assert-true false "retained binding")]))]
        [_ (test.assert-true false "first binding")]))))

(define (semantic-facts-test-source [source : String]) : bool
  (let
    [owner : arena.Arena (arena.make)]
    [_next-job : unit (check.compiler-check-reset-interns!)]
    [before : i64 tc_api.compiler-typecheck-pipeline-runs]
    [result : check.ResultCompilerCheck
      (facts.compiler-check-semantic-request
        (facts.CompilerSemanticCheckRequest
          (check.CompilerSemanticCheckInput.Source
            "semantic_facts_test.tl"
            source)
          (roots.new)
          (check.compiler-check-language-cfgs)
          (tc.tc-serial-job-state)
          owner
          false
          0
          semantic-facts-test-consumer))]
    (arena.destroy-safe! owner)
    (tc.compiler-typecheck-reset-file-state!)
    (test.assert-i64-eq
      tc_api.compiler-typecheck-pipeline-runs
      (+ before 1)
      "exactly one checked-program pipeline")
    (test.assert-i64-eq
      (tc.tc-job-state-semantic-observer (tc.tc-serial-job-state)).address
      0
      "observer must be unpublished before retirement")
    (test.assert-i64-eq
      tc.tc-semantic-observed-jobs
      0
      "disabled hooks stay disabled after retirement")
    (match result
      [(check.ResultCompilerCheck.Ok _ _) true]
      [(check.ResultCompilerCheck.Err _ _) false])))

(test
  semantic-facts-one-checked-walk-and-shadowed-locals
  (test.assert-true
    (semantic-facts-test-source
      "(define (value [x : i64]) : i64 (let [x : i64 (+ x 1)] (let [x : i64 (+ x 2)] x)))")
    "source check")
  (test.assert-true
    (> semantic-facts-test-expression-count 4)
    "typed expression records")
  (test.assert-i64-eq
    semantic-facts-test-binding-count
    3
    "parameter and both lexical bindings are distinct")
  (test.assert-true (>= semantic-facts-test-local-uses 3) "resolved local uses")
  (test.assert-i64-eq semantic-facts-test-function-count 1 "one function owner")
  (test.assert-i64-eq
    semantic-facts-test-missing-binding-spans
    0
    "declaring local tokens")
  (test.assert-true
    (> semantic-facts-test-core-uses 0)
    "resolved core operations")
  (test.assert-i64-eq
    semantic-facts-test-unreliable
    0
    "successful facts are reliable"))

(test
  semantic-facts-nested-initializer-shadow-token
  (test.assert-true
    (semantic-facts-test-source
      "(define (value) : i64 (let [x : i64 (let [x : i64 42] x)] x))")
    "nested initializer check")
  (test.assert-i64-eq
    semantic-facts-test-binding-count
    2
    "initializer binder and enclosing binder have distinct declarations")
  (test.assert-i64-eq
    semantic-facts-test-missing-binding-spans
    0
    "both declaring tokens survive nested initializer evaluation"))

(test
  semantic-facts-consecutive-jobs-own-their-payloads
  (test.assert-true
    (semantic-facts-test-source "(define (first) : i64 42)")
    "first job")
  (let
    [first : String (clone semantic-facts-test-owned-type)]
    (test.assert-true
      (semantic-facts-test-source "(define (second) : bool true)")
      "second job")
    (test.assert-string-eq
      first
      "i64"
      "owned payload survives source pools and facts retirement")
    (test.assert-string-eq
      semantic-facts-test-owned-type
      "bool"
      "second job owns distinct facts")
    (test.assert-i64-eq
      semantic-facts-test-function-count
      1
      "no retained prior function")))

(test
  semantic-facts-partial-check-marks-unresolved
  (test.assert-true
    (not
      (semantic-facts-test-source
        "(define (good) : i64 42) (define (bad) : i64 missing) (define (user) : i64 (begin (bad) 42)) (define (poison) : i64 (+ missing 1)) (define (later) : bool true)"))
    "partial result keeps the primary error")
  (test.assert-true
    (>= semantic-facts-test-unresolved 1)
    "unresolved expressions are explicit")
  (test.assert-true
    (> semantic-facts-test-poisoned 0)
    "poison values stay explicit")
  (test.assert-true
    (> semantic-facts-test-dependent 0)
    "checks depending on a failed declaration stay distinct")
  (test.assert-true
    (>= semantic-facts-test-function-count 2)
    "surviving declaration facts")
  (test.assert-true
    (> semantic-facts-test-reliable-bools 0)
    "an unrelated later body remains reliable"))

(test
  semantic-facts-nested-lambda-owner
  (test.assert-true
    (semantic-facts-test-source
      "(define (value) : i64 (let [f : (-> i64 i64) (lambda ([n : i64]) : i64 n)] (f 42)))")
    "lambda check")
  (test.assert-i64-eq
    semantic-facts-test-function-count
    2
    "lambda has its own function owner"))

(test
  semantic-facts-lambda-capture-retains-the-original-binding
  (test.assert-true
    (semantic-facts-test-source
      "(define (value) : i64 (let [x : i64 42]
        (let [f : (-> i64) (lambda () : i64 x)] (f))))")
    "capture check")
  (test.assert-true
    (> semantic-facts-test-captured-uses 0)
    "capture refers to the outer declaring token and owner")
  (test.assert-i64-eq
    semantic-facts-test-missing-binding-spans
    0
    "captured aliases do not manufacture declarations"))

(test
  semantic-facts-file-and-package-consumer-handoff
  (load.compiler-load-test-mkdir "target/exp")
  (load.compiler-load-test-mkdir "target/exp/semantic-facts-test")
  (load_tests.compiler-load-write-file-text
    "target/exp/semantic-facts-test/main.tl"
    "(import helper as peer) (define (main) : i64 (peer.shared-value))")
  (load_tests.compiler-load-write-file-text
    "target/exp/semantic-facts-test/helper.tl"
    "(define (shared-value) : i64 42)")
  (let
    [owner : arena.Arena (arena.make)]
    [file : check.ResultCompilerCheck
      (facts.compiler-check-semantic-request
        (facts.CompilerSemanticCheckRequest
          (check.CompilerSemanticCheckInput.File
            "target/exp/semantic-facts-test/main.tl")
          (roots.new)
          (check.compiler-check-language-cfgs)
          (tc.tc-serial-job-state)
          owner
          false
          0
          semantic-facts-test-consumer))]
    [file-count : i64 semantic-facts-test-expression-count]
    [_retire : unit (arena.destroy-safe! owner)]
    [package-owner : arena.Arena (arena.make)]
    [package : check.ResultCompilerCheck
      (facts.compiler-check-semantic-request
        (facts.CompilerSemanticCheckRequest
          (check.CompilerSemanticCheckInput.PackageEntry
            "target/exp/semantic-facts-test/main.tl"
            "target/exp/semantic-facts-test"
            (load.compiler-pkg-deps-empty)
            false)
          (roots.new)
          (check.compiler-check-language-cfgs)
          (tc.tc-serial-job-state)
          package-owner
          false
          0
          semantic-facts-test-consumer))]
    (arena.destroy-safe! package-owner)
    (test.assert-true
      (match file
        [(check.ResultCompilerCheck.Ok _ _) true]
        [_ false])
      "file check")
    (test.assert-true
      (match package
        [(check.ResultCompilerCheck.Ok _ _) true]
        [_ false])
      "package check")
    (test.assert-true (> file-count 0) "file consumer")
    (test.assert-true
      (> semantic-facts-test-expression-count 0)
      "package consumer")
    (test.assert-true
      (> semantic-facts-test-imported 0)
      "package references retain cross-module declaration identities")))

(test
  semantic-facts-direct-nominal-field-and-variant-identities
  (test.assert-true
    (semantic-facts-test-source
      "(defstruct Boxed (value i64)) (defenum Choice (None) (Some Boxed))
(define (value) : Choice (let [box : Boxed (Boxed 42)] (begin box.value (Choice.Some box))))")
    "nominal check")
  (test.assert-true
    (> semantic-facts-test-nominal-uses 0)
    "direct nominal identity")
  (test.assert-i64-eq
    semantic-facts-test-missing-nominal-spans
    0
    "ordinary nominal declaration tokens are owned")
  (test.assert-true
    (> semantic-facts-test-field-uses 0)
    "dotted field identity")
  (test.assert-true
    (> semantic-facts-test-variant-uses 0)
    "qualified variant identity"))

(test
  semantic-facts-try-and-foreach-context
  (test.assert-true
    (semantic-facts-test-source
      "(defenum Result (Ok i64) (Err i64))
(define (value [r : Result]) : Result (Result.Ok (try r)))")
    "try check")
  (test.assert-true
    (> semantic-facts-test-compatible-try 0)
    "canonical try query")
  (test.assert-true
    (semantic-facts-test-source
      "(define (value) : unit (foreach ([i : i64 0 4]) (begin (+ i 1) unit)))")
    "foreach check")
  (test.assert-true
    (> semantic-facts-test-forbidden 0)
    "foreach cannot return or propagate"))

(test
  semantic-facts-exact-macro-argument-and-synthetic-expansion
  (test.assert-true
    (semantic-facts-test-source
      "(defmacro (wrap [value : Expr]) : Expr `(+ ,value 1))
(define (value [n : i64]) : i64 (wrap n))")
    "macro check")
  (test.assert-true
    (> semantic-facts-test-macro-arguments 0)
    "exact caller argument")
  (test.assert-true
    (> semantic-facts-test-synthetic 0)
    "constructed expansion is synthetic"))

(test
  semantic-facts-pattern-bindings-and-lexical-scopes
  (test.assert-true
    (semantic-facts-test-source
      "(defenum Choice (A i64) (B i64))
(define (value [c : Choice]) : i64 (match c [(Choice.A n) n] [(Choice.B n) n]))")
    "pattern check")
  (test.assert-i64-eq
    semantic-facts-test-missing-binding-spans
    0
    "pattern binding tokens")
  (test.assert-true
    (>= semantic-facts-test-local-uses 3)
    "parameter and distinct arm bindings"))

(test
  semantic-facts-aliases-generated-families-and-annotations
  (test.assert-true
    (semantic-facts-test-source
      "(import stdlib.comptime)
(defmacro (boxes [T : type]) : Module
  `(begin (module boxes) (defstruct Item (value ,T))
    (define (make [n : ,T]) : Item (Item n))))
(import (boxes i64) as first)
(import (boxes i64) as second)
(define (value) : i64 (let [item : first.Item (second.make 42)] item.value))")
    "generated concrete family aliases")
  (test.assert-true
    (> semantic-facts-test-function-uses 0)
    "aliased function identity")
  (test.assert-true
    (> semantic-facts-test-nominal-uses 0)
    "annotated concrete nominal identity")
  (test.assert-true
    (> semantic-facts-test-field-uses 0)
    "concrete family's field identity"))

(test
  semantic-facts-macro-hygiene-preserves-definition-owner
  (test.assert-true
    (semantic-facts-test-source
      "(define (helper) : i64 42)
(defmacro (answer) : Expr `(helper))
(define (value) : i64 (let [helper : i64 7] (answer)))")
    "hygienic reference ignores caller shadow")
  (test.assert-true
    (> semantic-facts-test-function-uses 0)
    "definition-site function identity"))

(test
  semantic-facts-spmd-context-and-lambda-reset
  (test.assert-true
    (semantic-facts-test-source
      "(define (value) : i64 (spmd-reduce sum ([i : i64 0 4]) 0 i))")
    "SPMD reduction")
  (test.assert-true
    (> semantic-facts-test-forbidden 0)
    "SPMD value forbids early exit")
  (test.assert-true
    (semantic-facts-test-source
      "(define (value) : unit (foreach ([i : i64 0 4])
          (let [f : (-> i64) (lambda () : i64 (return 42))] unit)))")
    "lambda within foreach resets early-exit owner")
  (test.assert-i64-eq
    semantic-facts-test-function-count
    2
    "nested lambda owner")
  (test.assert-i64-eq
    semantic-facts-test-missing-binding-spans
    0
    "rechecked foreach bindings retain their source token"))

(test
  semantic-facts-scan-and-compact-context
  (test.assert-true
    (semantic-facts-test-source
      "(define (value) : unit (spmd-scan sum ([i : i64 0 4] [prefix : i64 0]) i unit))")
    "scan check")
  (test.assert-true
    (> semantic-facts-test-forbidden 0)
    "scan body forbids early exit")
  (test.assert-i64-eq
    semantic-facts-test-missing-binding-spans
    0
    "scan binder tokens")
  (test.assert-true
    (semantic-facts-test-source
      "(define (value) : i64 (spmd-compact ([i : i64 0 4] [slot : i64 0]) (= i 1) unit))")
    "compact check")
  (test.assert-true
    (> semantic-facts-test-forbidden 0)
    "compact body forbids early exit")
  (test.assert-i64-eq
    semantic-facts-test-missing-binding-spans
    0
    "compact binder tokens"))

(define (semantic-facts-test-consumer-in-owner
  [owner : i64]
  [snapshot : (& snapshot facts.CompilerSemanticFacts)]) : unit
  (in-arena (arena.Arena owner) (semantic-facts-test-consumer 0 snapshot)))

(define (semantic-facts-test-owned-job [source : String] [generated : bool]) : bool
  (let
    [home : arena.Arena (arena.current)]
    (with-scratch
      (let
        [scope : driver.CompilerDriverPackageRuntimeScope
          (driver.compiler-driver-package-runtime-scope-new home)]
        [owner : arena.Arena (arena.make)]
        [checked : bool
          (in-arena
            (arena.Arena (array-ref scope.frontend-arena 0))
            (match (facts.compiler-check-semantic-request
              (facts.CompilerSemanticCheckRequest
                (check.CompilerSemanticCheckInput.Source
                  "semantic_facts_test.tl"
                  source)
                (roots.new)
                (check.compiler-check-language-cfgs)
                (driver.compiler-driver-state-typecheck (& scope.state))
                owner
                generated
                home.handle
                semantic-facts-test-consumer-in-owner))
              [(check.ResultCompilerCheck.Ok _ _) true]
              [_ false]))]
        [_capture : unit
          (driver.compiler-driver-package-runtime-capture-frontend!
            (owned_view.compiler-owned-shared-view scope))]
        (arena.destroy-safe! owner)
        (driver.compiler-driver-package-runtime-scope-release!
          (owned_view.compiler-owned-shared-view scope))
        (driver.compiler-driver-package-runtime-scope-release! scope)
        checked))))

(test
  semantic-facts-batch-releases-owned-snapshots
  (let
    [index : i64 0]
    [warm-live : i64 0]
    (while (< index 12)
      (test.assert-true
        (semantic-facts-test-owned-job
          "(define (value [x : i64]) : i64 (+ x 1))"
          false)
        "batch entry")
      (set! index (+ index 1))
      (when (= index 4) (set! warm-live (profile.alloc-live))))
    (test.assert-true (> warm-live 0) "allocation accounting is active")
    (test.assert-true
      (< (- (profile.alloc-live) warm-live) 1048576)
      "retired snapshots and pools do not accumulate between entries")))

(test
  semantic-facts-checked-generated-source-provenance
  (test.assert-true
    (semantic-facts-test-owned-job "(define (value) : i64 42)" true)
    "physical generated source")
  (test.assert-true
    (> semantic-facts-test-generated 0)
    "checked-in generated source has its own provenance"))

(test
  semantic-facts-invalid-source-publishes-an-empty-snapshot
  (test.assert-true
    (not (semantic-facts-test-owned-job "(define (" false))
    "syntax error is preserved")
  (test.assert-i64-eq
    semantic-facts-test-expression-count
    0
    "no typed expressions")
  (test.assert-i64-eq semantic-facts-test-function-count 0 "no function owners"))

(test
  semantic-facts-synthetic-binding-does-not-borrow-a-source-token
  (test.assert-true
    (semantic-facts-test-source
      "(defmacro (wrapped) : Expr `(let [x : i64 42] x))
(define (value) : i64 (let [x : i64 (wrapped)] x))")
    "generated binding check")
  (test.assert-true
    (> semantic-facts-test-synthetic 0)
    "generated expression provenance")
  (test.assert-i64-eq
    semantic-facts-test-binding-count
    2
    "source and generated declarations")
  (test.assert-i64-eq
    semantic-facts-test-missing-binding-spans
    1
    "only the generated binder lacks a source token"))

(test
  semantic-facts-spmd-initializer-operands-forbid-early-exit
  (test.assert-true
    (semantic-facts-test-source
      "(define (value) : unit (foreach ([lane-probe : i64 0 4]) (let [x : i64 (+ lane-probe 1)] unit)))")
    "foreach initializer check")
  (test.assert-true
    (> semantic-facts-test-forbidden-lane-operands 0)
    "foreach operands were observed")
  (test.assert-i64-eq
    semantic-facts-test-allowed-lane-operands
    0
    "foreach operands forbid early exit")
  (test.assert-true
    (semantic-facts-test-source
      "(define (value) : i64 (spmd-reduce sum ([lane-probe : i64 0 4]) 0 (let [x : i64 (+ lane-probe 1)] x)))")
    "reduce initializer check")
  (test.assert-true
    (> semantic-facts-test-forbidden-lane-operands 0)
    "reduce operands were observed")
  (test.assert-i64-eq
    semantic-facts-test-allowed-lane-operands
    0
    "reduce operands forbid early exit")
  (test.assert-true
    (semantic-facts-test-source
      "(define (value) : unit (spmd-scan sum ([lane-probe : i64 0 4] [prefix : i64 0]) (let [x : i64 (+ lane-probe 1)] x) unit))")
    "scan initializer check")
  (test.assert-true
    (> semantic-facts-test-forbidden-lane-operands 0)
    "scan operands were observed")
  (test.assert-i64-eq
    semantic-facts-test-allowed-lane-operands
    0
    "scan operands forbid early exit")
  (test.assert-true
    (semantic-facts-test-source
      "(define (value) : i64 (spmd-compact ([lane-probe : i64 0 4] [slot : i64 0]) (= lane-probe 1) unit))")
    "compact initializer check")
  (test.assert-true
    (> semantic-facts-test-forbidden-lane-operands 0)
    "compact operands were observed")
  (test.assert-i64-eq
    semantic-facts-test-allowed-lane-operands
    0
    "compact operands forbid early exit")
  (test.assert-true
    (semantic-facts-test-source
      "(define (value) : unit (foreach ([lane-probe : i64 0 4]) (let [f : (-> i64) (lambda () : i64 (return lane-probe))] unit)))")
    "capturing lambda inside foreach")
  (test.assert-true
    (> semantic-facts-test-allowed-lane-operands 0)
    "lambda operands reset early-exit scope"))

(test
  semantic-facts-spmd-error-restores-the-next-function-scope
  (test.assert-true
    (not
      (semantic-facts-test-source
        "(define (bad) : unit (foreach ([lane-probe : i64 0 4]) (let [x : i64 (+ lane-probe 1)] (return unit)))) (define (after [lane-probe : i64]) : i64 (return lane-probe))"))
    "SPMD early return is rejected")
  (test.assert-true
    (> semantic-facts-test-forbidden-lane-operands 0)
    "failed SPMD operands retain their context")
  (test.assert-true
    (> semantic-facts-test-allowed-lane-operands 0)
    "later function restores the ordinary return scope"))

(test
  semantic-facts-foreach-active-lane-keeps-its-binding-and-policy
  (test.assert-true
    (semantic-facts-test-source
      "(define (value) : unit (foreach ([i : i64 0 4]) (let [v : i64 (+ i 1)] (foreach-active [lane-probe : i64] (let [x : i64 (+ lane-probe (lane-value v))] unit)))))")
    "foreach-active and lane-value check")
  (test.assert-true
    (> semantic-facts-test-forbidden-lane-operands 0)
    "lane references retain their resolved binder and forbidden early-exit policy")
  (test.assert-i64-eq
    semantic-facts-test-allowed-lane-operands
    0
    "active-lane operands forbid early exit")
  (test.assert-i64-eq
    semantic-facts-test-missing-binding-spans
    0
    "active-lane binder has its physical token"))

(test
  semantic-facts-binding-maps-grow-through-capture-and-spmd-imports
  (let
    [source : String
      "(define growth-probe : i64 99)\n(define (previous) : i64 (let [growth-probe : i64 7] growth-probe))\n(define (value) : i64 (let\n"]
    [i : i64 0]
    (while (< i 64)
      (set!
        source
        (str_cat.str-cat
          source
          "[pad-"
          (string.int->string i)
          " : i64 "
          (string.int->string i)
          "]\n"))
      (set! i (+ i 1)))
    (set! semantic-facts-test-growth-line 68)
    (set!
      source
      (str_cat.str-cat
        source
        "[growth-probe : i64 42]\n"
        "[f : (-> i64) (lambda () : i64 growth-probe)]\n"
        "(begin (foreach ([i : i64 0 4]) (let [sum : i64 (+ growth-probe i)] unit)) (+ (f) growth-probe))))"))
    (test.assert-true
      (semantic-facts-test-source source)
      "large environment checks")
    (test.assert-true
      (> semantic-facts-test-binding-count 64)
      "binding maps cross their initial capacity")
    (test.assert-true
      (> semantic-facts-test-persistent-binding-count 32)
      "materialized binding descriptors keep every entry and grow")
    (test.assert-true
      (>= semantic-facts-test-growth-uses 4)
      "references include the earlier function, capture and SPMD import")
    (test.assert-i64-eq
      semantic-facts-test-growth-mismatches
      0
      "every reference keeps its actual declaring token and function")
    (set! semantic-facts-test-growth-line -1)))

(test
  semantic-facts-nested-jobs-keep-the-disabled-guard-balanced
  (with-scratch
    (let
      [outer : tc.TcJobState (tc.tc-job-state-new)]
      [inner : tc.TcJobState (tc.tc-job-state-new)]
      [observer : tc.TcSemanticObserver
        (facts.compiler-semantic-fact-recorder-observer
          (facts.compiler-semantic-fact-recorder-new "nested.tl" false))]
      (tc.tc-job-state-set-semantic-observer! outer observer)
      (tc.tc-job-state-set-semantic-observer! inner (tc.TcSemanticObserver 0))
      (tc.tc-job-state-set-semantic-observer! outer observer)
      (test.assert-i64-eq
        tc.tc-semantic-observed-jobs
        1
        "ordinary nested jobs and repeated installation preserve the outer observer")
      (tc.tc-job-state-set-semantic-observer! inner observer)
      (test.assert-i64-eq tc.tc-semantic-observed-jobs 2 "two observed jobs")
      (tc.tc-job-state-set-semantic-observer! outer (tc.TcSemanticObserver 0))
      (test.assert-i64-eq
        tc.tc-semantic-observed-jobs
        1
        "retiring one job preserves the other")
      (tc.tc-job-state-set-semantic-observer! inner (tc.TcSemanticObserver 0))
      (test.assert-i64-eq
        tc.tc-semantic-observed-jobs
        0
        "all retired jobs restore the disabled path"))))