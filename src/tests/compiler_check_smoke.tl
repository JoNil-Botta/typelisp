;; compiler_check_smoke.tl - Runnable smoke for virtual-source check helpers.
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import compiler_load)
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
      (cdiag.compiler-diagnostic-text-edit-span
        (cdiag.compiler-diagnostic-place-shared-view edit))]
    [start : i64
      (compiler-check-fix-test-position-index
        (tc_core.tc-global-shared-view source)
        (cdiag.compiler-diagnostic-span-start-line span)
        (cdiag.compiler-diagnostic-span-start-col span))]
    [end : i64
      (compiler-check-fix-test-position-index
        (tc_core.tc-global-shared-view source)
        (cdiag.compiler-diagnostic-span-end-line span)
        (cdiag.compiler-diagnostic-span-end-col span))]
    [source-len : i64 (string.string-length source)]
    (if (or (< start 0) (< end start))
      cdiag.CompilerDiagnosticNoString
      (cdiag.CompilerDiagnosticSomeString
        (str_cat.str-cat
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
    (match (compiler_check_core.compiler-check-source
      (tc_core.tc-global-shared-view path)
      (tc_core.tc-global-shared-view source))
      [(compiler_check_core.ResultCompilerCheck.Ok _) false]
      [(compiler_check_core.ResultCompilerCheck.Err diag-box)
        (let
          [diag : cdiag.CompilerDiagnostic
            (cdiag.compiler-diagnostic-list-first
              (cdiag.compiler-diagnostic-list-box-shared-view diag-box))]
          [fixes : cdiag.CompilerDiagnosticFixSeq
            (cdiag.compiler-diagnostic-fixes diag)]
          (and
            (= fixes.len 1)
            (let
              [fix : cdiag.CompilerDiagnosticFix
                (tc_core.tc-global-array-element-shared-view fixes.slots 0)]
              [edits : cdiag.CompilerDiagnosticTextEditSeq
                (cdiag.compiler-diagnostic-fix-edits
                  (cdiag.compiler-diagnostic-place-shared-view fix))]
              (and
                (string.eq
                  (cdiag.compiler-diagnostic-fix-title
                    (cdiag.compiler-diagnostic-place-shared-view fix))
                  "Replace misspelled name")
                (match (cdiag.compiler-diagnostic-fix-applicability
                  (cdiag.compiler-diagnostic-place-shared-view fix))
                  [cdiag.CompilerDiagnosticMachineApplicable true]
                  [_ false])
                (= edits.len 1)
                (let
                  [edit : cdiag.CompilerDiagnosticTextEdit
                    (tc_core.tc-global-array-element-shared-view edits.slots 0)]
                  [span : cdiag.CompilerDiagnosticSpan
                    (cdiag.compiler-diagnostic-text-edit-span
                      (cdiag.compiler-diagnostic-place-shared-view edit))]
                  (and
                    (string.eq (cdiag.compiler-diagnostic-span-path span) path)
                    (= (cdiag.compiler-diagnostic-span-start-line span) 5)
                    (= (cdiag.compiler-diagnostic-span-start-col span) 4)
                    (= (cdiag.compiler-diagnostic-span-end-line span) 5)
                    (= (cdiag.compiler-diagnostic-span-end-col span) 16)
                    (string.eq
                      (cdiag.compiler-diagnostic-text-edit-replacement
                        (cdiag.compiler-diagnostic-place-shared-view edit))
                      "render-value")
                    (match (compiler-check-fix-test-apply
                      source
                      (cdiag.compiler-diagnostic-place-shared-view edit))
                      [(cdiag.CompilerDiagnosticSomeString updated)
                        (and
                          (string.eq
                            updated
                            (compiler-check-near-miss-fixed-source))
                          (compiler_check_core.compiler-check-source-ok?
                            path
                            updated))]
                      [cdiag.CompilerDiagnosticNoString false])))))))])))

(define (compiler-check-stdlib-import-help-not-machine-fix-ok?) : bool
  (match (compiler_check_core.compiler-check-source
    "tests/import_help_only.tl"
    "(define (main) : i64 (begin (println \"value\") 0))")
    [(compiler_check_core.ResultCompilerCheck.Ok _) false]
    [(compiler_check_core.ResultCompilerCheck.Err diag)
      (let
        [first : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-first
            (cdiag.compiler-diagnostic-list-box-shared-view diag))]
        (=
          (__tl-project-field
            (cdiag.compiler-diagnostic-fixes
              first)
            len)
          0))]))

(define (compiler-check-first-diagnostic-exact?
  [path : String]
  [source : String]
  [message : String]
  [line : i64]
  [col : i64]
  [end-line : i64]
  [end-col : i64]) : bool
  (match (check_core.compiler-check-source
    (tc_core.tc-global-shared-view path)
    source)
    [(check_core.ResultCompilerCheck.Ok _) false]
    [(check_core.ResultCompilerCheck.Err diagnostics-box)
      (let
        [diagnostics : cdiag.CompilerDiagnosticList
          (cdiag.compiler-diagnostic-list-box-shared-view diagnostics-box)]
        [diagnostic : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-first
            (cdiag.compiler-diagnostic-place-shared-view diagnostics))]
        (and
          (=
            (cdiag.compiler-diagnostic-list-count
              (cdiag.compiler-diagnostic-place-shared-view diagnostics))
            1)
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
(define (emit [text : String]) : unit unit)
(module main)
(import data as io)
(define (main) : i64
  (begin
    (io.emti \"hello\")
    0))")
    [(tc_core.ResultCompilerTypecheck.Ok _) false]
    [(tc_core.ResultCompilerTypecheck.Err diagnostics-box)
      (let
        [diagnostics : cdiag.CompilerDiagnosticList
          (cdiag.compiler-diagnostic-list-box-shared-view diagnostics-box)]
        [diagnostic : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-first
            (cdiag.compiler-diagnostic-place-shared-view diagnostics))]
        [fixes : cdiag.CompilerDiagnosticFixSeq
          (cdiag.compiler-diagnostic-fixes diagnostic)]
        (and
          (=
            (cdiag.compiler-diagnostic-list-count
              (cdiag.compiler-diagnostic-place-shared-view diagnostics))
            1)
          (string.eq
            (cdiag.compiler-diagnostic-message diagnostic)
            "typecheck: unbound name io.emti")
          (= fixes.len 1)
          (let
            [fix : cdiag.CompilerDiagnosticFix
              (tc_core.tc-global-array-element-shared-view fixes.slots 0)]
            [edits : cdiag.CompilerDiagnosticTextEditSeq
              (cdiag.compiler-diagnostic-fix-edits
                (cdiag.compiler-diagnostic-place-shared-view fix))]
            (and
              (string.eq
                (cdiag.compiler-diagnostic-fix-title
                  (cdiag.compiler-diagnostic-place-shared-view fix))
                "Replace misspelled name")
              (= edits.len 1)
              (string.eq
                (cdiag.compiler-diagnostic-text-edit-replacement
                  (array-ref edits.slots 0))
                "io.emit")))))]))

(define (compiler-check-qualified-unbound-display-ok?) : bool
  (match (tc_api.typecheck-compiler-source
    "(module data)
(define (emit [text : String]) : unit unit)
(module main)
(import data as io)
(define (main) : i64
  (begin
    (io.missing \"hello\")
    0))")
    [(tc_core.ResultCompilerTypecheck.Ok _) false]
    [(tc_core.ResultCompilerTypecheck.Err diagnostics-box)
      (let
        [diagnostics : cdiag.CompilerDiagnosticList
          (cdiag.compiler-diagnostic-list-box-shared-view diagnostics-box)]
        [diagnostic : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-first
            (cdiag.compiler-diagnostic-place-shared-view diagnostics))]
        (and
          (=
            (cdiag.compiler-diagnostic-list-count
              (cdiag.compiler-diagnostic-place-shared-view diagnostics))
            1)
          (string.eq
            (cdiag.compiler-diagnostic-message diagnostic)
            "typecheck: unbound name io.missing")
          (=
            (__tl-project-field
              (cdiag.compiler-diagnostic-fixes diagnostic)
              len)
            0)))]))

(define (compiler-check-duplicate-type-location-ok?) : bool
  (match (compiler_check_core.compiler-check-source
    "tests/duplicate_type_location.tl"
      "(defstruct Point (x i64))
(defstruct Point (y i64))
(define (main) : i64 0)")
    [(compiler_check_core.ResultCompilerCheck.Ok _) false]
    [(compiler_check_core.ResultCompilerCheck.Err diag-box)
      (let
        [diag : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-first
            (cdiag.compiler-diagnostic-list-box-shared-view diag-box))]
        [message : String (cdiag.compiler-diagnostic-message diag)]
        [diag-path : String (cdiag.compiler-diagnostic-path diag)]
        (and
          (string.eq
            message
            "symbols: duplicate type declaration Point")
          (string.eq diag-path "tests/duplicate_type_location.tl")
          (= (cdiag.compiler-diagnostic-line diag) 2)
          (= (cdiag.compiler-diagnostic-col diag) 1)))]))

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
        [diagnostics : cdiag.CompilerDiagnosticList
          (cdiag.compiler-diagnostic-list-box-shared-view diagnostics-box)]
        [first : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-get
            (cdiag.compiler-diagnostic-place-shared-view diagnostics)
            0)]
        [second : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-get
            (cdiag.compiler-diagnostic-place-shared-view diagnostics)
            1)]
        [third : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-get
            (cdiag.compiler-diagnostic-place-shared-view diagnostics)
            2)]
        (and
          (=
            (cdiag.compiler-diagnostic-list-count
              (cdiag.compiler-diagnostic-place-shared-view diagnostics))
            3)
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
          (= (cdiag.compiler-diagnostic-line third) 3)))]))

(define (compiler-check-parser-recovery-result-ok?
  [result : compiler_check_core.ResultCompilerCheck]) : bool
  (match result
    [(compiler_check_core.ResultCompilerCheck.Ok _) false]
    [(compiler_check_core.ResultCompilerCheck.Err diagnostics-box)
      (let
        [diagnostics : cdiag.CompilerDiagnosticList
          (cdiag.compiler-diagnostic-list-box-shared-view diagnostics-box)]
        [first : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-get
            (cdiag.compiler-diagnostic-place-shared-view diagnostics)
            0)]
        [second : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-get
            (cdiag.compiler-diagnostic-place-shared-view diagnostics)
            1)]
        [third : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-get
            (cdiag.compiler-diagnostic-place-shared-view diagnostics)
            2)]
        (and
          (=
            (cdiag.compiler-diagnostic-list-count
              (cdiag.compiler-diagnostic-place-shared-view diagnostics))
            3)
          (string.eq
            (cdiag.compiler-diagnostic-message first)
            "parse: malformed define")
          (string.eq
            (cdiag.compiler-diagnostic-code-or-empty first)
            (cdiag.compiler-diagnostic-code-parse))
          (= (cdiag.compiler-diagnostic-line first) 1)
          (string.eq
            (cdiag.compiler-diagnostic-message second)
            "typecheck: unbound name missing-a")
          (= (cdiag.compiler-diagnostic-line second) 2)
          (string.eq
            (cdiag.compiler-diagnostic-message third)
            "typecheck: unbound name missing-b")
          (= (cdiag.compiler-diagnostic-line third) 3)))]))

(define (compiler-check-parser-recovery-diagnostics-ok?) : bool
  (let
    [path : String "tests/parser_recovery_diagnostics.tl"]
    [source : String
      "(define)
(define (later-a) : i64 missing-a)
(define (later-b) : i64 missing-b)
(define (main) : i64 0)"]
    (and
      (compiler-check-parser-recovery-result-ok?
        (compiler_check_core.compiler-check-source
          (tc_core.tc-global-shared-view path)
          (tc_core.tc-global-shared-view source)))
      (compiler-check-parser-recovery-result-ok?
        (compiler_check_core.compiler-check-package-source-with-roots-and-cfg
          (tc_core.tc-global-shared-view path)
          source
          (svec.new)
          "."
          (compiler_load.compiler-pkg-deps-empty)
          (compiler_check_core.compiler-check-language-cfgs))))))

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
        [diagnostics : cdiag.CompilerDiagnosticList
          (cdiag.compiler-diagnostic-list-box-shared-view diagnostics-box)]
        [first : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-first
            (cdiag.compiler-diagnostic-place-shared-view diagnostics))]
        (and
          (=
            (cdiag.compiler-diagnostic-list-count
              (cdiag.compiler-diagnostic-place-shared-view diagnostics))
            1)
          (string.eq
            (cdiag.compiler-diagnostic-message first)
            "typecheck: unbound name unknown-origin")))]))

(define (compiler-check-semantic-access-code
  [access : semantic_index.CompilerSemanticAccess]) : i64
  (match access
    [(semantic_index.CompilerSemanticAccess.None) 0]
    [(semantic_index.CompilerSemanticAccess.Read) 1]
    [(semantic_index.CompilerSemanticAccess.Write) 2]
    [(semantic_index.CompilerSemanticAccess.ReadWrite) 3]))

(define (compiler-check-semantic-record-access?
  [index : (& index semantic_index.CompilerSemanticSourceIndex)]
  [record-index : i64]
  [expected : i64]) : bool
  (and
    (>= record-index 0)
    (=
      (compiler-check-semantic-access-code
        (semantic_index.compiler-semantic-source-index-get index record-index).access)
      expected)))

(define (compiler-check-semantic-record-symbols-eq?
  [index : (& index semantic_index.CompilerSemanticSourceIndex)]
  [left-index : i64]
  [right-index : i64]) : bool
  (and
    (>= left-index 0)
    (>= right-index 0)
    (semantic_index.compiler-semantic-symbol-id-eq?
      (semantic_index.compiler-semantic-source-index-get index left-index).symbol
      (semantic_index.compiler-semantic-source-index-get index right-index).symbol)))

(define (compiler-check-semantic-access-ok?) : bool
  (let
    [path : String "src/tests/semantic_access_entry.tl"]
    [source : String
      "(module semantic.access)
(import semantic.index.import_dep as dep)
(defmacro (wrap [value : Expr]) : Expr value)
(defmacro (emit-one) : Decls
  `(define generated-from-macro : i64 (wrap 5)))
(emit-one)
(define top : i64 dep.imported-value)
(define (bump [slot : i64]) : i64
  (begin
    (set! slot (+ slot top))
    slot))
(define result : i64 (bump (wrap top)))
(define (shadow [shadowed : i64]) : i64
  (let
    [shadowed : i64 (+ shadowed 1)]
    (begin
      (set! shadowed (+ shadowed 1))
      shadowed)))"]
    (match (semantic_index.compiler-check-source-index-with-roots
      path
      source
      (svec.new))
      [(semantic_index.ResultCompilerCheckWithSemanticIndex.Ok _ index)
        (let
          [slot-definition : i64
            (semantic_index.compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "slot"
              semantic_index.CompilerSemanticRecordRole.Definition
              0)]
          [slot-write : i64
            (semantic_index.compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "slot"
              semantic_index.CompilerSemanticRecordRole.Use
              0)]
          [slot-write-record : semantic_index.CompilerSemanticRecord
            (semantic_index.compiler-semantic-source-index-get
              (& index)
              slot-write)]
          [slot-rhs-read : i64
            (semantic_index.compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "slot"
              semantic_index.CompilerSemanticRecordRole.Use
              1)]
          [slot-result-read : i64
            (semantic_index.compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "slot"
              semantic_index.CompilerSemanticRecordRole.Use
              2)]
          [shadow-param-definition : i64
            (semantic_index.compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "shadowed"
              semantic_index.CompilerSemanticRecordRole.Definition
              0)]
          [shadow-local-definition : i64
            (semantic_index.compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "shadowed"
              semantic_index.CompilerSemanticRecordRole.Definition
              1)]
          [shadow-param-read : i64
            (semantic_index.compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "shadowed"
              semantic_index.CompilerSemanticRecordRole.Use
              0)]
          [shadow-local-write : i64
            (semantic_index.compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "shadowed"
              semantic_index.CompilerSemanticRecordRole.Use
              1)]
          [shadow-local-read : i64
            (semantic_index.compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "shadowed"
              semantic_index.CompilerSemanticRecordRole.Use
              2)]
          [shadow-local-result-read : i64
            (semantic_index.compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "shadowed"
              semantic_index.CompilerSemanticRecordRole.Use
              3)]
          [bump-read : i64
            (semantic_index.compiler-semantic-source-index-find-record
              (& index)
              path
              "bump"
              semantic_index.CompilerSemanticRecordRole.Use
              -1)]
          [import-read : i64
            (semantic_index.compiler-semantic-source-index-find-record
              (& index)
              path
              "imported-value"
              semantic_index.CompilerSemanticRecordRole.Use
              -1)]
          [macro-read : i64
            (semantic_index.compiler-semantic-source-index-find-macro-use
              (& index)
              "wrap"
              true
              0)]
          [generated-macro : i64
            (semantic_index.compiler-semantic-source-index-find-macro-use
              (& index)
              "wrap"
              false
              0)]
          [generated-definition : i64
            (semantic_index.compiler-semantic-source-index-find-record
              (& index)
              ""
              "generated-from-macro"
              semantic_index.CompilerSemanticRecordRole.Definition
              -1)]
          [unknown-ok : bool
            (match (semantic_index.compiler-check-source-index-with-roots
              "src/tests/semantic_access_unknown.tl"
              "(module semantic.access.unknown)
(define (broken) : i64 unresolved-name)"
              (svec.new))
              [(semantic_index.ResultCompilerCheckWithSemanticIndex.Partial
                  _
                  partial)
                (let
                  [ok : bool
                    (<
                      (semantic_index.compiler-semantic-source-index-find-name-occurrence
                        (& partial)
                        "src/tests/semantic_access_unknown.tl"
                        "unresolved-name"
                        semantic_index.CompilerSemanticRecordRole.Use
                        0)
                      0)]
                  (begin
                    (semantic_index.compiler-semantic-source-index-release!
                      (&mut partial))
                    ok))]
              [(semantic_index.ResultCompilerCheckWithSemanticIndex.Ok
                  _
                  complete)
                (begin
                  (semantic_index.compiler-semantic-source-index-release!
                    (&mut complete))
                  false)]
              [(semantic_index.ResultCompilerCheckWithSemanticIndex.Err _)
                false])]
          [ok : bool
            (and
              (compiler-check-semantic-record-access?
                (& index)
                slot-definition
                0)
              (compiler-check-semantic-record-access? (& index) slot-write 2)
              (string.eq
                (string.substring
                  source
                  slot-write-record.span.start-byte
                  (-
                    slot-write-record.span.end-byte
                    slot-write-record.span.start-byte))
                "slot")
              (compiler-check-semantic-record-access? (& index) slot-rhs-read 1)
              (compiler-check-semantic-record-access?
                (& index)
                slot-result-read
                1)
              (compiler-check-semantic-record-symbols-eq?
                (& index)
                slot-definition
                slot-write)
              (compiler-check-semantic-record-symbols-eq?
                (& index)
                slot-write
                slot-rhs-read)
              (compiler-check-semantic-record-symbols-eq?
                (& index)
                slot-write
                slot-result-read)
              (compiler-check-semantic-record-access?
                (& index)
                shadow-param-definition
                0)
              (compiler-check-semantic-record-access?
                (& index)
                shadow-local-definition
                0)
              (compiler-check-semantic-record-access?
                (& index)
                shadow-param-read
                1)
              (compiler-check-semantic-record-access?
                (& index)
                shadow-local-write
                2)
              (compiler-check-semantic-record-access?
                (& index)
                shadow-local-read
                1)
              (compiler-check-semantic-record-access?
                (& index)
                shadow-local-result-read
                1)
              (compiler-check-semantic-record-symbols-eq?
                (& index)
                shadow-param-definition
                shadow-param-read)
              (compiler-check-semantic-record-symbols-eq?
                (& index)
                shadow-local-definition
                shadow-local-write)
              (compiler-check-semantic-record-symbols-eq?
                (& index)
                shadow-local-write
                shadow-local-read)
              (not
                (compiler-check-semantic-record-symbols-eq?
                  (& index)
                  shadow-param-definition
                  shadow-local-definition))
              (compiler-check-semantic-record-access? (& index) bump-read 1)
              (compiler-check-semantic-record-access? (& index) import-read 1)
              (compiler-check-semantic-record-access? (& index) macro-read 1)
              (compiler-check-semantic-record-access?
                (& index)
                generated-macro
                0)
              (compiler-check-semantic-record-access?
                (& index)
                generated-definition
                0)
              unknown-ok)]
          (begin
            (semantic_index.compiler-semantic-source-index-release!
              (&mut index))
            ok))]
      [(semantic_index.ResultCompilerCheckWithSemanticIndex.Partial _ partial)
        (begin
          (semantic_index.compiler-semantic-source-index-release!
            (&mut partial))
          false)]
      [(semantic_index.ResultCompilerCheckWithSemanticIndex.Err _) false])))

(define (main) : i64
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (unless
      (compiler-check-core-self-test-ok?)
      (return 1))
    (cond
      [(and
          (compiler-check-near-miss-fix-ok?)
          (compiler-check-stdlib-import-help-not-machine-fix-ok?)
          (compiler-check-duplicate-type-location-ok?)
          (compiler-check-independent-diagnostics-ok?)
          (compiler-check-parser-recovery-diagnostics-ok?)
          (compiler-check-poison-suppresses-derived-diagnostics-ok?)
          (semantic_index.compiler-check-semantic-index-ok?)
          (compiler-check-semantic-access-ok?)
          (compiler-check-subform-diagnostic-spans-ok?)
          (compiler-check-qualified-near-miss-ok?)
          (compiler-check-qualified-unbound-display-ok?))
        42]
      [else 1])))
