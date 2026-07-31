;; compiler_check_smoke.tl - Runnable smoke for virtual-source check helpers.
(import "../compiler_check_core.tl")
(import "../compiler_semantic_index.tl")
(import compiler_builtin_ids as cbi)

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
  [edit : CompilerDiagnosticTextEdit]) : CompilerDiagnosticMaybeString
  (let
    [span : CompilerDiagnosticSpan (compiler-diagnostic-text-edit-span edit)]
    [start : i64
      (compiler-check-fix-test-position-index
        source
        (compiler-diagnostic-span-start-line span)
        (compiler-diagnostic-span-start-col span))]
    [end : i64
      (compiler-check-fix-test-position-index
        source
        (compiler-diagnostic-span-end-line span)
        (compiler-diagnostic-span-end-col span))]
    [source-len : i64 (string.string-length source)]
    (if (or (< start 0) (< end start))
      CompilerDiagnosticNoString
      (CompilerDiagnosticSomeString
        (string.concat3
          (string.substring source 0 start)
          (compiler-diagnostic-text-edit-replacement edit)
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
    (match (compiler-check-source path source)
      [(ResultCompilerCheck.Ok _) false]
      [(ResultCompilerCheck.Err diag-box)
        (let
          [diag : CompilerDiagnostic
            (compiler-diagnostic-list-first (box-get diag-box))]
          [fixes : CompilerDiagnosticFixSeq (compiler-diagnostic-fixes diag)]
          (and
            (= (struct-get fixes len) 1)
            (let
              [fix : CompilerDiagnosticFix
                (array-ref (struct-get fixes slots) 0)]
              [edits : CompilerDiagnosticTextEditSeq
                (compiler-diagnostic-fix-edits fix)]
              (and
                (string.eq
                  (compiler-diagnostic-fix-title fix)
                  "Replace misspelled name")
                (match (compiler-diagnostic-fix-applicability fix)
                  [CompilerDiagnosticMachineApplicable true]
                  [_ false])
                (= (struct-get edits len) 1)
                (let
                  [edit : CompilerDiagnosticTextEdit
                    (array-ref (struct-get edits slots) 0)]
                  [span : CompilerDiagnosticSpan
                    (compiler-diagnostic-text-edit-span edit)]
                  (and
                    (string.eq (compiler-diagnostic-span-path span) path)
                    (= (compiler-diagnostic-span-start-line span) 5)
                    (= (compiler-diagnostic-span-start-col span) 4)
                    (= (compiler-diagnostic-span-end-line span) 5)
                    (= (compiler-diagnostic-span-end-col span) 16)
                    (string.eq
                      (compiler-diagnostic-text-edit-replacement edit)
                      "render-value")
                    (match (compiler-check-fix-test-apply source edit)
                      [(CompilerDiagnosticSomeString updated)
                        (and
                          (string.eq
                            updated
                            (compiler-check-near-miss-fixed-source))
                          (compiler-check-source-ok? path updated))]
                      [CompilerDiagnosticNoString false])))))))])))

(define (compiler-check-import-help-not-machine-fix-ok?) : bool
  (match (compiler-check-source
    "tests/import_help_only.tl"
    "(define (main) : i64 (begin (print 1) 0))")
    [(ResultCompilerCheck.Ok _) false]
    [(ResultCompilerCheck.Err diag)
      (=
        (struct-get
          (compiler-diagnostic-fixes
            (compiler-diagnostic-list-first (box-get diag)))
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
  (match (compiler-check-source path source)
    [(ResultCompilerCheck.Ok _) false]
    [(ResultCompilerCheck.Err diagnostics-box)
      (let
        [diagnostics : CompilerDiagnosticList (box-get diagnostics-box)]
        [diagnostic : CompilerDiagnostic
          (compiler-diagnostic-list-first diagnostics)]
        (and
          (= (compiler-diagnostic-list-count diagnostics) 1)
          (string.eq (compiler-diagnostic-message diagnostic) message)
          (string.eq (compiler-diagnostic-path diagnostic) path)
          (= (compiler-diagnostic-line diagnostic) line)
          (= (compiler-diagnostic-col diagnostic) col)
          (= (compiler-diagnostic-end-line diagnostic) end-line)
          (= (compiler-diagnostic-end-col diagnostic) end-col)))]))

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
  (match (typecheck-compiler-source
    "(module data)
(define (print [text : String]) : unit unit)
(module main)
(import \"data.tl\" module data :as io)
(define (main) : i64
  (begin
    (io.prnit \"hello\")
    0))")
    [(ResultCompilerTypecheck.Ok _) false]
    [(ResultCompilerTypecheck.Err diagnostics-box)
      (let
        [diagnostics : CompilerDiagnosticList (box-get diagnostics-box)]
        [diagnostic : CompilerDiagnostic
          (compiler-diagnostic-list-first diagnostics)]
        [fixes : CompilerDiagnosticFixSeq
          (compiler-diagnostic-fixes diagnostic)]
        (and
          (= (compiler-diagnostic-list-count diagnostics) 1)
          (string.eq
            (compiler-diagnostic-message diagnostic)
            "typecheck: unbound name io.prnit")
          (= (struct-get fixes len) 1)
          (let
            [fix : CompilerDiagnosticFix (array-ref (struct-get fixes slots) 0)]
            [edits : CompilerDiagnosticTextEditSeq
              (compiler-diagnostic-fix-edits fix)]
            (and
              (string.eq
                (compiler-diagnostic-fix-title fix)
                "Replace misspelled name")
              (= (struct-get edits len) 1)
              (string.eq
                (compiler-diagnostic-text-edit-replacement
                  (array-ref (struct-get edits slots) 0))
                "io.print")))))]))

(define (compiler-check-qualified-unbound-display-ok?) : bool
  (match (typecheck-compiler-source
    "(module data)
(define (print [text : String]) : unit unit)
(module main)
(import \"data.tl\" module data :as io)
(define (main) : i64
  (begin
    (io.missing \"hello\")
    0))")
    [(ResultCompilerTypecheck.Ok _) false]
    [(ResultCompilerTypecheck.Err diagnostics-box)
      (let
        [diagnostics : CompilerDiagnosticList (box-get diagnostics-box)]
        [diagnostic : CompilerDiagnostic
          (compiler-diagnostic-list-first diagnostics)]
        (and
          (= (compiler-diagnostic-list-count diagnostics) 1)
          (string.eq
            (compiler-diagnostic-message diagnostic)
            "typecheck: unbound name io.missing")
          (= (struct-get (compiler-diagnostic-fixes diagnostic) len) 0)))]))

(define (compiler-check-duplicate-type-location-ok?) : bool
  (let
    [path : String "tests/duplicate_type_location.tl"]
    [source : String
      "(defstruct Point (x i64))
(defstruct Point (y i64))
(define (main) : i64 0)"]
    (match (compiler-check-source path source)
      [(ResultCompilerCheck.Ok _) false]
      [(ResultCompilerCheck.Err diag-box)
        (let
          [diag : CompilerDiagnostic
            (compiler-diagnostic-list-first (box-get diag-box))]
          (and
            (string.eq
              (compiler-diagnostic-message diag)
              "symbols: duplicate type declaration Point")
            (string.eq (compiler-diagnostic-path diag) path)
            (= (compiler-diagnostic-line diag) 2)
            (= (compiler-diagnostic-col diag) 1)))])))

(define (compiler-check-independent-diagnostics-ok?) : bool
  (match (compiler-check-source
    "tests/multiple_diagnostics.tl"
    "(define (a) : i64 (unknown-one 1))
(define (b) : i64 (unknown-two 2))
(define (c) : i64 (+ \"str\" 1))
(define (main) : i64 0)")
    [(ResultCompilerCheck.Ok _) false]
    [(ResultCompilerCheck.Err diagnostics-box)
      (let
        [diagnostics : CompilerDiagnosticList (box-get diagnostics-box)]
        (and
          (= (compiler-diagnostic-list-count diagnostics) 3)
          (match diagnostics
            [(CompilerDiagnosticList.Cons first first-rest)
              (match (box-get first-rest)
                [(CompilerDiagnosticList.Cons second second-rest)
                  (match (box-get second-rest)
                    [(CompilerDiagnosticList.Cons third third-rest)
                      (and
                        (string.eq
                          (compiler-diagnostic-message first)
                          "typecheck: unbound name unknown-one")
                        (= (compiler-diagnostic-line first) 1)
                        (string.eq
                          (compiler-diagnostic-message second)
                          "typecheck: unbound name unknown-two")
                        (= (compiler-diagnostic-line second) 2)
                        (string.eq
                          (compiler-diagnostic-message third)
                          "typecheck: integer operator expects matching integer operands")
                        (= (compiler-diagnostic-line third) 3)
                        (match (box-get third-rest)
                          [(CompilerDiagnosticList.Nil) true]
                          [_ false]))]
                    [_ false])]
                [_ false])]
            [_ false])))]))

(define (compiler-check-poison-suppresses-derived-diagnostics-ok?) : bool
  (match (compiler-check-source
    "tests/poison_diagnostics.tl"
    "(define (broken) : i64 (unknown-origin 1))
(define (derived-one) : i64 (broken))
(define (derived-two) : i64 (+ (derived-one) 1))
(define (derived-three) : i64 (derived-two))
(define (main) : i64 0)")
    [(ResultCompilerCheck.Ok _) false]
    [(ResultCompilerCheck.Err diagnostics-box)
      (let
        [diagnostics : CompilerDiagnosticList (box-get diagnostics-box)]
        (and
          (= (compiler-diagnostic-list-count diagnostics) 1)
          (string.eq
            (compiler-diagnostic-message
              (compiler-diagnostic-list-first diagnostics))
            "typecheck: unbound name unknown-origin")))]))

(define (main) : i64
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (cond
      [(and
          (= (compiler-check-self-test) 42)
          (compiler-check-near-miss-fix-ok?)
          (compiler-check-import-help-not-machine-fix-ok?)
          (compiler-check-duplicate-type-location-ok?)
          (compiler-check-independent-diagnostics-ok?)
          (compiler-check-poison-suppresses-derived-diagnostics-ok?)
          (compiler-check-semantic-index-ok?)
          (compiler-check-subform-diagnostic-spans-ok?)
          (compiler-check-qualified-near-miss-ok?)
          (compiler-check-qualified-unbound-display-ok?))
        42]
      [else 1])))