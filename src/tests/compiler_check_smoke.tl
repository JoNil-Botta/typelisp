;; compiler_check_smoke.tl - Runnable smoke for virtual-source check helpers.
(import stdlib.string)
(import compiler_check_core as check_core)
(import compiler_diagnostic as cdiag)
(import compiler_semantic_index as semantic_index)
(import compiler_builtin_ids as cbi)
(import compiler_typecheck_api as tc_api)
(import compiler_typecheck_core as tc_core)

(define (compiler-check-fix-test-position-index
  [source : String]
  [target-line : i64]
  [target-col : i64]) : i64
  (let
    [idx : i64 0]
    [source-len : i64 (string.string-length source)]
    [line : i64 1]
    [col : i64 1]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (< idx source-len))
        (if (and (= line target-line) (= col target-col))
          (set! found idx)
          (begin
            (if (= (string.string-ref source idx) '\n')
              (begin
                (set! line (+ line 1))
                (set! col 1))
              (set! col (+ col 1)))
            (set! idx (+ idx 1)))))
      (if (and (< found 0) (= line target-line) (= col target-col))
        source-len
        found))))

(define (compiler-check-fix-test-apply
  [source : String]
  [edit : cdiag.CompilerDiagnosticTextEdit]) : cdiag.CompilerDiagnosticMaybeString
  (let
    [span : cdiag.CompilerDiagnosticSpan
      (cdiag.compiler-diagnostic-text-edit-span edit)]
    [start : i64
      (compiler-check-fix-test-position-index
        source
        (cdiag.compiler-diagnostic-span-start-line span)
        (cdiag.compiler-diagnostic-span-start-col span))]
    [end : i64
      (compiler-check-fix-test-position-index
        source
        (cdiag.compiler-diagnostic-span-end-line span)
        (cdiag.compiler-diagnostic-span-end-col span))]
    [source-len : i64 (string.string-length source)]
    (if (or (< start 0) (< end start))
      cdiag.CompilerDiagnosticNoString
      (cdiag.CompilerDiagnosticSomeString
        (string.concat3
          (string.substring source 0 start)
          (cdiag.compiler-diagnostic-text-edit-replacement edit)
          (string.substring source end (- source-len end)))))))

(define (compiler-check-near-miss-fix-source) : String
  "(define (render-value [value : i64]) : i64
  value)

(define (main) : i64
  (render-vaule 42))")

(define (compiler-check-near-miss-fixed-source) : String
  "(define (render-value [value : i64]) : i64
  value)

(define (main) : i64
  (render-value 42))")

(define (compiler-check-near-miss-fix-ok?) : bool
  (let
    [path : String "tests/near_miss_fix.tl"]
    [source : String (compiler-check-near-miss-fix-source)]
    (match (compiler_check_core.compiler-check-source path source)
      [(compiler_check_core.ResultCompilerCheck.Ok _) false]
      [(compiler_check_core.ResultCompilerCheck.Err diag-box)
        (let
          [diag : cdiag.CompilerDiagnostic
            (cdiag.compiler-diagnostic-list-first (box-get diag-box))]
          [fixes : cdiag.CompilerDiagnosticFixSeq
            (cdiag.compiler-diagnostic-fixes diag)]
          (and
            (= (struct-get fixes len) 1)
            (let
              [fix : cdiag.CompilerDiagnosticFix
                (array-ref (struct-get fixes slots) 0)]
              [edits : cdiag.CompilerDiagnosticTextEditSeq
                (cdiag.compiler-diagnostic-fix-edits fix)]
              (and
                (string.eq
                  (cdiag.compiler-diagnostic-fix-title fix)
                  "Replace misspelled name")
                (match (cdiag.compiler-diagnostic-fix-applicability fix)
                  [cdiag.CompilerDiagnosticMachineApplicable true]
                  [_ false])
                (= (struct-get edits len) 1)
                (let
                  [edit : cdiag.CompilerDiagnosticTextEdit
                    (array-ref (struct-get edits slots) 0)]
                  [span : cdiag.CompilerDiagnosticSpan
                    (cdiag.compiler-diagnostic-text-edit-span edit)]
                  (and
                    (string.eq (cdiag.compiler-diagnostic-span-path span) path)
                    (= (cdiag.compiler-diagnostic-span-start-line span) 5)
                    (= (cdiag.compiler-diagnostic-span-start-col span) 4)
                    (= (cdiag.compiler-diagnostic-span-end-line span) 5)
                    (= (cdiag.compiler-diagnostic-span-end-col span) 16)
                    (string.eq
                      (cdiag.compiler-diagnostic-text-edit-replacement edit)
                      "render-value")
                    (match (compiler-check-fix-test-apply source edit)
                      [(cdiag.CompilerDiagnosticSomeString updated)
                        (and
                          (string.eq
                            updated
                            (compiler-check-near-miss-fixed-source))
                          (compiler_check_core.compiler-check-source-ok?
                            path
                            updated))]
                      [cdiag.CompilerDiagnosticNoString false])))))))])))

(define (compiler-check-import-help-not-machine-fix-ok?) : bool
  (match (compiler_check_core.compiler-check-source
    "tests/import_help_only.tl"
    "(define (main) : i64 (begin (print 1) 0))")
    [(compiler_check_core.ResultCompilerCheck.Ok _) false]
    [(compiler_check_core.ResultCompilerCheck.Err diag)
      (=
        (struct-get
          (cdiag.compiler-diagnostic-fixes
            (cdiag.compiler-diagnostic-list-first (box-get diag)))
          len)
        0)]))

(define (compiler-check-first-diagnostic-exact?
  [path : String]
  [source : String]
  [message : String]
  [line : i64]
  [col : i64]
  [end-line : i64]
  [end-col : i64]) : bool
  (match (check_core.compiler-check-source path source)
    [(check_core.ResultCompilerCheck.Ok _) false]
    [(check_core.ResultCompilerCheck.Err diagnostics-box)
      (let
        [diagnostics : cdiag.CompilerDiagnosticList (box-get diagnostics-box)]
        [diagnostic : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-first diagnostics)]
        (and
          (= (cdiag.compiler-diagnostic-list-count diagnostics) 1)
          (string.eq (cdiag.compiler-diagnostic-message diagnostic) message)
          (string.eq (cdiag.compiler-diagnostic-path diagnostic) path)
          (= (cdiag.compiler-diagnostic-line diagnostic) line)
          (= (cdiag.compiler-diagnostic-col diagnostic) col)
          (= (cdiag.compiler-diagnostic-end-line diagnostic) end-line)
          (= (cdiag.compiler-diagnostic-end-col diagnostic) end-col)))]))

(define (compiler-check-subform-diagnostic-spans-ok?) : bool
  (and
    (compiler-check-first-diagnostic-exact?
      "tests/field_subform.tl"
      "(defstruct Point
  (x i64)
  (y i64))

(define (main) : i64
  (let
    [p : Point (Point 1 2)]
    (begin
      (set! p.z 5)
      0)))"
      "typecheck: unknown struct field Point.z; available fields: x, y"
      9
      13
      9
      13)
    (compiler-check-first-diagnostic-exact?
      "tests/binding_subform.tl"
      "(define (main) : i64
  (let
    [first : i64 1]
    [wrong : i64 true]
    [last : i64 3]
    (+ first (+ wrong last))))"
      "typecheck: let binding `wrong` type mismatch: expected i64, found bool"
      4
      18
      4
      18)
    (compiler-check-first-diagnostic-exact?
      "tests/pattern_subform.tl"
      "(defenum Choice
  (A i64)
  (B i64))

(define (main) : i64
  (match (A 1)
    [(A value) value]
    [(B) 2]))"
      "typecheck: pattern arity mismatch: expected 1, found 0"
      8
      6
      8
      8)
    (compiler-check-first-diagnostic-exact?
      "tests/operand_subform.tl"
      "(define (main) : i64
  (let
    [x : i64 1]
    [y : bool true]
    (+ x y)))"
      "typecheck: integer operator expects matching integer operands: expected i64, found bool"
      5
      10
      5
      10)))

(define (compiler-check-qualified-near-miss-ok?) : bool
  (match (tc_api.typecheck-compiler-source
    "(module data)
(define (print [text : String]) : unit unit)
(module main)
(import data as io)
(define (main) : i64
  (begin
    (io.prnit \"hello\")
    0))")
    [(tc_core.ResultCompilerTypecheck.Ok _) false]
    [(tc_core.ResultCompilerTypecheck.Err diagnostics-box)
      (let
        [diagnostics : cdiag.CompilerDiagnosticList (box-get diagnostics-box)]
        [diagnostic : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-first diagnostics)]
        [fixes : cdiag.CompilerDiagnosticFixSeq
          (cdiag.compiler-diagnostic-fixes diagnostic)]
        (and
          (= (cdiag.compiler-diagnostic-list-count diagnostics) 1)
          (string.eq
            (cdiag.compiler-diagnostic-message diagnostic)
            "typecheck: unbound name io.prnit")
          (= (struct-get fixes len) 1)
          (let
            [fix : cdiag.CompilerDiagnosticFix
              (array-ref (struct-get fixes slots) 0)]
            [edits : cdiag.CompilerDiagnosticTextEditSeq
              (cdiag.compiler-diagnostic-fix-edits fix)]
            (and
              (string.eq
                (cdiag.compiler-diagnostic-fix-title fix)
                "Replace misspelled name")
              (= (struct-get edits len) 1)
              (string.eq
                (cdiag.compiler-diagnostic-text-edit-replacement
                  (array-ref (struct-get edits slots) 0))
                "io.print")))))]))

(define (compiler-check-qualified-unbound-display-ok?) : bool
  (match (tc_api.typecheck-compiler-source
    "(module data)
(define (print [text : String]) : unit unit)
(module main)
(import data as io)
(define (main) : i64
  (begin
    (io.missing \"hello\")
    0))")
    [(tc_core.ResultCompilerTypecheck.Ok _) false]
    [(tc_core.ResultCompilerTypecheck.Err diagnostics-box)
      (let
        [diagnostics : cdiag.CompilerDiagnosticList (box-get diagnostics-box)]
        [diagnostic : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-first diagnostics)]
        (and
          (= (cdiag.compiler-diagnostic-list-count diagnostics) 1)
          (string.eq
            (cdiag.compiler-diagnostic-message diagnostic)
            "typecheck: unbound name io.missing")
          (= (struct-get (cdiag.compiler-diagnostic-fixes diagnostic) len) 0)))]))

(define (compiler-check-duplicate-type-location-ok?) : bool
  (let
    [path : String "tests/duplicate_type_location.tl"]
    [source : String
      "(defstruct Point (x i64))
(defstruct Point (y i64))
(define (main) : i64 0)"]
    (match (compiler_check_core.compiler-check-source path source)
      [(compiler_check_core.ResultCompilerCheck.Ok _) false]
      [(compiler_check_core.ResultCompilerCheck.Err diag-box)
        (let
          [diag : cdiag.CompilerDiagnostic
            (cdiag.compiler-diagnostic-list-first (box-get diag-box))]
          (and
            (string.eq
              (cdiag.compiler-diagnostic-message diag)
              "symbols: duplicate type declaration Point")
            (string.eq (cdiag.compiler-diagnostic-path diag) path)
            (= (cdiag.compiler-diagnostic-line diag) 2)
            (= (cdiag.compiler-diagnostic-col diag) 1)))])))

(define (compiler-check-independent-diagnostics-ok?) : bool
  (match (compiler_check_core.compiler-check-source
    "tests/multiple_diagnostics.tl"
    "(define (a) : i64 (unknown-one 1))
(define (b) : i64 (unknown-two 2))
(define (c) : i64 (+ \"str\" 1))
(define (main) : i64 0)")
    [(compiler_check_core.ResultCompilerCheck.Ok _) false]
    [(compiler_check_core.ResultCompilerCheck.Err diagnostics-box)
      (let
        [diagnostics : cdiag.CompilerDiagnosticList (box-get diagnostics-box)]
        (and
          (= (cdiag.compiler-diagnostic-list-count diagnostics) 3)
          (match diagnostics
            [(cdiag.CompilerDiagnosticList.Cons first first-rest)
              (match (box-get first-rest)
                [(cdiag.CompilerDiagnosticList.Cons second second-rest)
                  (match (box-get second-rest)
                    [(cdiag.CompilerDiagnosticList.Cons third third-rest)
                      (and
                        (string.eq
                          (cdiag.compiler-diagnostic-message first)
                          "typecheck: unbound name unknown-one")
                        (= (cdiag.compiler-diagnostic-line first) 1)
                        (string.eq
                          (cdiag.compiler-diagnostic-message second)
                          "typecheck: unbound name unknown-two")
                        (= (cdiag.compiler-diagnostic-line second) 2)
                        (string.eq
                          (cdiag.compiler-diagnostic-message third)
                          "typecheck: integer operator expects matching integer operands")
                        (= (cdiag.compiler-diagnostic-line third) 3)
                        (match (box-get third-rest)
                          [(cdiag.CompilerDiagnosticList.Nil) true]
                          [_ false]))]
                    [_ false])]
                [_ false])]
            [_ false])))]))

(define (compiler-check-poison-suppresses-derived-diagnostics-ok?) : bool
  (match (compiler_check_core.compiler-check-source
    "tests/poison_diagnostics.tl"
    "(define (broken) : i64 (unknown-origin 1))
(define (derived-one) : i64 (broken))
(define (derived-two) : i64 (+ (derived-one) 1))
(define (derived-three) : i64 (derived-two))
(define (main) : i64 0)")
    [(compiler_check_core.ResultCompilerCheck.Ok _) false]
    [(compiler_check_core.ResultCompilerCheck.Err diagnostics-box)
      (let
        [diagnostics : cdiag.CompilerDiagnosticList (box-get diagnostics-box)]
        (and
          (= (cdiag.compiler-diagnostic-list-count diagnostics) 1)
          (string.eq
            (cdiag.compiler-diagnostic-message
              (cdiag.compiler-diagnostic-list-first diagnostics))
            "typecheck: unbound name unknown-origin")))]))

(define (main) : i64
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (cond
      [(and
          (= (compiler_check_core.compiler-check-self-test) 42)
          (compiler-check-near-miss-fix-ok?)
          (compiler-check-import-help-not-machine-fix-ok?)
          (compiler-check-duplicate-type-location-ok?)
          (compiler-check-independent-diagnostics-ok?)
          (compiler-check-poison-suppresses-derived-diagnostics-ok?)
          (semantic_index.compiler-check-semantic-index-ok?)
          (compiler-check-subform-diagnostic-spans-ok?)
          (compiler-check-qualified-near-miss-ok?)
          (compiler-check-qualified-unbound-display-ok?))
        42]
      [else 1])))