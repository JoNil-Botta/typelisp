;; compiler_check_tests.tl - Shared tests for virtual-source check helpers.
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import compiler_load)
(import compiler_load_tests as load_tests)
(import compiler_check_core as check_core)
(import compiler_source_overlay_tests as overlay_tests)
(import compiler_diagnostic as cdiag)
(import compiler_diagnostic_tests as cdiag_tests)
(import compiler_semantic_index as semantic_index)
(import compiler_semantic_index_tests as sem_tests)
(import compiler_builtin_ids as cbi)
(import compiler_typecheck_api as tc_api)
(import compiler_typecheck_core as tc_core)
(import stdlib.io)
(import compiler_ast_types as ast)
(import compiler_owned_view as owned_view)
(import compiler_symbols as csym)
(import compiler_target_cfg_core as target_cfg)
(import compiler_parse_core as parser)
(import sym_i64_env)

(define (compiler-check-fix-test-position-index
  [source : (& source str)]
  [target-line : i64]
  [target-col : i64]) : i64
  (let
    [idx : i64 0]
    [source-len : i64 (string.string-length source)]
    [line : i64 1]
    [col : i64 1]
    [found : i64 -1]
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
      found)))

(define (compiler-check-fix-test-apply
  [source : (& source str)]
  [edit : cdiag.CompilerDiagnosticTextEdit]) : cdiag.CompilerDiagnosticMaybeString
  (let
    [span : cdiag.CompilerDiagnosticSpan
      (cdiag.compiler-diagnostic-text-edit-span
        (cdiag.compiler-diagnostic-place-shared-view edit))]
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
      CompilerDiagnosticNoString
      (CompilerDiagnosticSomeString
        (str_cat.str-cat
          (string.substring source 0 start)
          (cdiag.compiler-diagnostic-text-edit-replacement edit)
          (string.substring source end (- source-len end)))))))

(define (compiler-check-near-miss-fix-ok?) : bool
  (let
    [path : String "tests/near_miss_fix.tl"]
    [source : String
      "(define (render-value [value : i64]) : i64
  value)

(define (main) : i64
  (render-vaule 42))"]
    (match (check_core.compiler-check-source
      (tc_core.tc-global-shared-view path)
      (tc_core.tc-global-shared-view source))
      [(Ok _ _) false]
      [(Err diag-box _)
        (let
          [diag : cdiag.CompilerDiagnostic
            (cdiag.compiler-diagnostic-list-first (deref diag-box))]
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
                (match (cdiag.compiler-diagnostic-fix-applicability fix)
                  [CompilerDiagnosticMachineApplicable true]
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
                    (match (compiler-check-fix-test-apply source edit)
                      [(CompilerDiagnosticSomeString updated)
                        (and
                          (string.eq
                            updated
                            "(define (render-value [value : i64]) : i64
  value)

(define (main) : i64
  (render-value 42))")
                          (compiler-check-source-ok? path updated))]
                      [CompilerDiagnosticNoString false])))))))])))

(define (compiler-check-stdlib-import-help-not-machine-fix-ok?) : bool
  (match (check_core.compiler-check-source
    "tests/import_help_only.tl"
    "(define (main) : i64 (begin (println \"value\") 0))")
    [(Ok _ _) false]
    [(Err diag _)
      (let
        [first : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-first (deref diag))]
        (= (__tl-project-field (cdiag.compiler-diagnostic-fixes first) len) 0))]))

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
    [(Ok _ _) false]
    [(Err diagnostics-box _)
      (let
        [diagnostics : cdiag.CompilerDiagnosticList
          (cdiag.compiler-diagnostic-list-box-shared-view diagnostics-box)]
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
(define (emit [text : String]) : unit unit)
(module main)
(import data as io)
(define (main) : i64
  (begin
    (io.emti \"hello\")
    0))")
    [(Ok _) false]
    [(Err diagnostics-box)
      (let
        [diagnostics : cdiag.CompilerDiagnosticList
          (cdiag.compiler-diagnostic-list-box-shared-view diagnostics-box)]
        [diagnostic : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-first diagnostics)]
        [fixes : cdiag.CompilerDiagnosticFixSeq
          (cdiag.compiler-diagnostic-fixes diagnostic)]
        (and
          (= (cdiag.compiler-diagnostic-list-count diagnostics) 1)
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
                (cdiag.compiler-diagnostic-fix-title fix)
                "Replace misspelled name")
              (= edits.len 1)
              (string.eq
                (cdiag.compiler-diagnostic-text-edit-replacement
                  (tc_core.tc-global-array-element-shared-view edits.slots 0))
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
    [(Ok _) false]
    [(Err diagnostics-box)
      (let
        [diagnostics : cdiag.CompilerDiagnosticList
          (cdiag.compiler-diagnostic-list-box-shared-view diagnostics-box)]
        [diagnostic : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-first diagnostics)]
        (and
          (= (cdiag.compiler-diagnostic-list-count diagnostics) 1)
          (string.eq
            (cdiag.compiler-diagnostic-message diagnostic)
            "typecheck: unbound name io.missing")
          (=
            (__tl-project-field
              (cdiag.compiler-diagnostic-fixes diagnostic)
              len)
            0)))]))

(define (compiler-check-duplicate-type-location-ok?) : bool
  (match (check_core.compiler-check-source
    "tests/duplicate_type_location.tl"
    "(defstruct Point (x i64))
(defstruct Point (y i64))
(define (main) : i64 0)")
    [(Ok _ _) false]
    [(Err diag-box _)
      (let
        [diag : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-first (deref diag-box))]
        [message : String (cdiag.compiler-diagnostic-message diag)]
        [diag-path : String (cdiag.compiler-diagnostic-path diag)]
        (and
          (string.eq message "symbols: duplicate type declaration Point")
          (string.eq diag-path "tests/duplicate_type_location.tl")
          (= (cdiag.compiler-diagnostic-line diag) 2)
          (= (cdiag.compiler-diagnostic-col diag) 1)))]))

(define (compiler-check-independent-diagnostics-ok?) : bool
  (match (check_core.compiler-check-source
    "tests/multiple_diagnostics.tl"
    "(define (a) : i64 (unknown-one 1))
(define (b) : i64 (unknown-two 2))
(define (c) : i64 (+ \"str\" 1))
(define (main) : i64 0)")
    [(Ok _ _) false]
    [(Err diagnostics-box _)
      (let
        [diagnostics : cdiag.CompilerDiagnosticList
          (cdiag.compiler-diagnostic-list-box-shared-view diagnostics-box)]
        [first : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-get diagnostics 0)]
        [second : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-get diagnostics 1)]
        [third : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-get diagnostics 2)]
        (and
          (= (cdiag.compiler-diagnostic-list-count diagnostics) 3)
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
    [(Ok _ _) false]
    [(Err diagnostics-box _)
      (let
        [diagnostics : cdiag.CompilerDiagnosticList
          (cdiag.compiler-diagnostic-list-box-shared-view diagnostics-box)]
        [first : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-get diagnostics 0)]
        [second : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-get diagnostics 1)]
        [third : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-get diagnostics 2)]
        (and
          (= (cdiag.compiler-diagnostic-list-count diagnostics) 3)
          (string.eq
            (cdiag.compiler-diagnostic-message first)
            "parse: malformed define")
          (string.eq
            (cdiag.compiler-diagnostic-code-or-empty first)
            (cdiag.compiler-diagnostic-code-parse-malformed-form))
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
        (check_core.compiler-check-source
          (tc_core.tc-global-shared-view path)
          (tc_core.tc-global-shared-view source)))
      (compiler-check-parser-recovery-result-ok?
        (compiler_check_core.compiler-check-package-source-with-roots-and-cfg
          path
          source
          (svec.new)
          "."
          (compiler_load.compiler-pkg-deps-empty)
          (compiler_check_core.compiler-check-language-cfgs))))))

(define (compiler-check-poison-suppresses-derived-diagnostics-ok?) : bool
  (match (check_core.compiler-check-source
    "tests/poison_diagnostics.tl"
    "(define (broken) : i64 (unknown-origin 1))
(define (derived-one) : i64 (broken))
(define (derived-two) : i64 (+ (derived-one) 1))
(define (derived-three) : i64 (derived-two))
(define (main) : i64 0)")
    [(Ok _ _) false]
    [(Err diagnostics-box _)
      (let
        [diagnostics : cdiag.CompilerDiagnosticList
          (cdiag.compiler-diagnostic-list-box-shared-view diagnostics-box)]
        [first : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-first diagnostics)]
        (and
          (= (cdiag.compiler-diagnostic-list-count diagnostics) 1)
          (string.eq
            (cdiag.compiler-diagnostic-message first)
            "typecheck: unbound name unknown-origin")))]))

(define (compiler-check-semantic-access-code
  [access : semantic_index.CompilerSemanticAccess]) : i64
  (match access
    [(None) 0]
    [(Read) 1]
    [(Write) 2]
    [(ReadWrite) 3]))

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
    (match (sem_tests.compiler-check-source-index-with-roots
      (tc_core.tc-global-shared-view path)
      (tc_core.tc-global-shared-view source)
      (svec.new))
      [(Ok _ index)
        (let
          [slot-definition : i64
            (sem_tests.compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "slot"
              Definition
              0)]
          [slot-write : i64
            (sem_tests.compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "slot"
              Use
              0)]
          [slot-write-record : semantic_index.CompilerSemanticRecord
            (semantic_index.compiler-semantic-source-index-get
              (& index)
              slot-write)]
          [slot-rhs-read : i64
            (sem_tests.compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "slot"
              Use
              1)]
          [slot-result-read : i64
            (sem_tests.compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "slot"
              Use
              2)]
          [shadow-param-definition : i64
            (sem_tests.compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "shadowed"
              Definition
              0)]
          [shadow-local-definition : i64
            (sem_tests.compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "shadowed"
              Definition
              1)]
          [shadow-param-read : i64
            (sem_tests.compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "shadowed"
              Use
              0)]
          [shadow-local-write : i64
            (sem_tests.compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "shadowed"
              Use
              1)]
          [shadow-local-read : i64
            (sem_tests.compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "shadowed"
              Use
              2)]
          [shadow-local-result-read : i64
            (sem_tests.compiler-semantic-source-index-find-name-occurrence
              (& index)
              path
              "shadowed"
              Use
              3)]
          [bump-read : i64
            (sem_tests.compiler-semantic-source-index-find-record
              (& index)
              path
              "bump"
              Use
              -1)]
          [import-read : i64
            (sem_tests.compiler-semantic-source-index-find-record
              (& index)
              path
              "imported-value"
              Use
              -1)]
          [macro-read : i64
            (sem_tests.compiler-semantic-source-index-find-macro-use
              (& index)
              "wrap"
              true
              0)]
          [generated-macro : i64
            (sem_tests.compiler-semantic-source-index-find-macro-use
              (& index)
              "wrap"
              false
              0)]
          [generated-definition : i64
            (sem_tests.compiler-semantic-source-index-find-record
              (& index)
              ""
              "generated-from-macro"
              Definition
              -1)]
          [unknown-ok : bool
            (match (sem_tests.compiler-check-source-index-with-roots
              "src/tests/semantic_access_unknown.tl"
              "(module semantic.access.unknown)
(define (broken) : i64 unresolved-name)"
              (svec.new))
              [(Partial _ partial)
                (let
                  [ok : bool
                    (<
                      (sem_tests.compiler-semantic-source-index-find-name-occurrence
                        (& partial)
                        "src/tests/semantic_access_unknown.tl"
                        "unresolved-name"
                        Use
                        0)
                      0)]
                  (semantic_index.compiler-semantic-source-index-release!
                    (&mut partial))
                  ok)]
              [(Ok _ complete)
                (semantic_index.compiler-semantic-source-index-release!
                  (&mut complete))
                false]
              [(Err _) false])]
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
          (semantic_index.compiler-semantic-source-index-release! (&mut index))
          ok)]
      [(Partial _ partial)
        (semantic_index.compiler-semantic-source-index-release! (&mut partial))
        false]
      [(Err _) false])))

(define (compiler-check-advisory-result-ok?) : bool
  (let
    [job : tc_core.TcJobState (tc_core.tc-job-state-new)]
    [warning : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-with-level
        (&
          (cdiag.compiler-diagnostic-simple
            "tests/check_advisory.tl"
            1
            1
            "successful check advisory"))
        CompilerDiagnosticWarning)]
    [fatal : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-simple
        "tests/check_advisory.tl"
        2
        1
        "fatal after advisory")]
    [_append : bool
      (cdiag_tests.compiler-advisory-sink-push!
        (tc_core.tc-job-state-advisory-sink job)
        Semantic
        (& warning))]
    [success : check_core.ResultCompilerCheck
      (Ok
        (CompilerTypecheckSummary 1 0 0)
        (check_core.compiler-check-advisories-for-job job))]
    [failure : check_core.ResultCompilerCheck
      (Err
        (cdiag.compiler-diagnostic-list-box-single (box fatal))
        (check_core.compiler-check-advisories-for-job job))]
    [carried? : bool
      (and
        (match success
          [(Ok _ advisories)
            (= (cdiag.compiler-advisory-list-count (& advisories)) 1)]
          [(Err _ _) false])
        (match failure
          [(Ok _ _) false]
          [(Err _ advisories)
            (= (cdiag.compiler-advisory-list-count (& advisories)) 1)]))]
    (tc_core.tc-job-state-reset-file-state! job)
    (let
      [after-reset : cdiag.CompilerAdvisoryList
        (check_core.compiler-check-advisories-for-job job)]
      (and carried? (= (cdiag.compiler-advisory-list-count (& after-reset)) 0)))))

(define (compiler-check-tests-ok?) : bool
  (cbi.compiler-builtin-initialize-for-parse!)
  (and
    (= (compiler-check-self-test) 42)
    (compiler-check-near-miss-fix-ok?)
    (compiler-check-stdlib-import-help-not-machine-fix-ok?)
    (compiler-check-duplicate-type-location-ok?)
    (compiler-check-independent-diagnostics-ok?)
    (compiler-check-parser-recovery-diagnostics-ok?)
    (compiler-check-poison-suppresses-derived-diagnostics-ok?)
    (sem_tests.compiler-check-semantic-index-ok?)
    (compiler-check-semantic-access-ok?)
    (compiler-check-advisory-result-ok?)
    (compiler-check-subform-diagnostic-spans-ok?)
    (compiler-check-qualified-near-miss-ok?)
    (compiler-check-qualified-unbound-display-ok?)
    (overlay_tests.compiler-source-overlay-tests-ok?)))

(define (compiler-check-source-ok? [path : String] [source : String]) : bool
  (match (check_core.compiler-check-source path source)
    [(Ok _ _) true]
    [(Err _ _) false]))

(define (compiler-check-source-error-ok?
  [path : String]
  [source : String]
  [want : String]) : bool
  (match (check_core.compiler-check-source path source)
    [(Ok _ _) false]
    [(Err diag _)
      (let
        [diagnostics : cdiag.CompilerDiagnosticList
          (cdiag.compiler-diagnostic-list-box-shared-view diag)]
        [first : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-first diagnostics)]
        (string.eq (cdiag.compiler-diagnostic-message first) want))]))

(define (compiler-check-virtual-import-source) : String
  "(import compiler_ast_types as ast)
(import compiler_ast_types as ast)
(define selected : ast.AstType (ast.AstType.I64))
(define (main) : i64
  (match (unsafe (ptr-read (ptr-addr-of selected)))
    [(ast.AstType.I64) 42]
    [_ 0]))")

(define (compiler-check-direct-source [path : String] [source : String]) : check_core.ResultCompilerCheck
  (check_core.compiler-check-reset-pools!)
  (tc_core.tc-job-state-reset-advisories! (tc_core.tc-serial-job-state))
  (match (parser.parse-ast-source-recovery-diagnostic-with-cfg
    (owned_view.compiler-owned-shared-view path)
    source
    (check_core.compiler-check-language-cfgs))
    [(Parsed program diagnostics)
      (check_core.compiler-check-result-with-parse-diagnostics
        (deref diagnostics)
        (match program
          [(Program decls-box)
            (check_core.compiler-check-program
              path
              (ast.ast-decl-list-box-shared-view decls-box)
              (ast.ast-decl-path-list-new)
              (svec.new)
              (check_core.compiler-check-language-cfgs)
              (tc_api.compiler-typecheck-prefix-cache-scope
                "typecheck-prefix-check"
                (svec.new)
                (check_core.compiler-check-language-cfgs))
              (tc_core.tc-serial-job-state))]))]
    [(Fatal diagnostics)
      (Err diagnostics (check_core.compiler-check-serial-advisories))]))

(define (compiler-check-direct-source-ok? [path : String] [source : String]) : bool
  (match (compiler-check-direct-source path source)
    [(Ok _ _) true]
    [(Err _ _) false]))

;; The implicit core prelude and compiler-private dynamic-buffer forms compose
;; without any compatibility-module import.
(define (compiler-check-implicit-core-prelude-source) : String
  "
(define (main) : i64
  (let
    [value : i64 0]
    [items : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    (begin
      (when (and (> 5 3) (< 2 4) (= 1 1)) (set! value (+ value 10)))
      (unless (or false false false) (set! value (+ value 20)))
      (set! (array-ref items 0) value)
      (__tl_array-push! items 2)
      (+
        (__tl_array-length items)
        (+ (array-ref items 0) (array-ref items 1))))))")

;; Private dynamic-buffer parser coverage remains separate from public fixed
;; arrays and generated vectors.
(define (compiler-check-private-dynamic-buffer-source) : String
  "(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    (array-length items)))")

(define (compiler-check-virtual-import-ok?) : bool
  (match (check_core.compiler-check-source
    "src/virtual_entry.tl"
    (compiler-check-virtual-import-source))
    [(Ok summary _) (> (tc_api.compiler-typecheck-summary-score summary) 0)]
    [(Err _ _) false]))

(define (compiler-check-inline-layout-name-ok?
  [ctx : tc_core.TcContext]
  [name : String]) : bool
  (match (tc_api.compiler-typecheck-context-program ctx)
    [(Program decls-box)
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        [index : i64 0]
        [name-id : i64 -1]
        (while (and (< name-id 0) (< index decls.len))
          (let
            [decl : ast.AstDecl
              (ast.ast-decl-list-get (& decls) index (ast.ast-decl-fallback))]
            (match decl
              [(DefStruct decl-meta candidate _ _ _)
                (if (string.eq (tc_core.tc-env-key-name-text candidate) name)
                  (set! name-id candidate)
                  unit)]
              [(DefStructLifetimes decl-meta candidate _ _ _ _)
                (if (string.eq (tc_core.tc-env-key-name-text candidate) name)
                  (set! name-id candidate)
                  unit)]
              [(DefEnum decl-meta candidate _ _)
                (if (string.eq (tc_core.tc-env-key-name-text candidate) name)
                  (set! name-id candidate)
                  unit)]
              [(DefEnumLifetimes decl-meta candidate _ _ _)
                (if (string.eq (tc_core.tc-env-key-name-text candidate) name)
                  (set! name-id candidate)
                  unit)]
              [_ unit])
            (set! index (+ index 1))))
        (if (< name-id 0)
          false
          (match (tc_core.tc-inline-aggregate-layout-finite-ok ctx name name-id)
            [(Ok) true]
            [(Err _) false])))]))

(define (compiler-check-virtual-import-inline-layout-ok?) : bool
  (match (compiler_load.compiler-load-source-with-paths
    "src/virtual_entry.tl"
    (compiler-check-virtual-import-source)
    (sym_i64_env.sym-i64-empty))
    [(Ok decls _ _ _)
      (let
        [program : ast.AstProgram (ast.ast-program decls)]
        (match (csym.build-compiler-symbols program)
          [(Ok symbols)
            (match (csym.build-compiler-registries program)
              [(Ok registries)
                (let
                  [ctx : tc_core.TcContext
                    (tc_core.tc-context-new
                      program
                      symbols
                      registries
                      ""
                      cbi.compiler-builtin-id-fix-empty
                      (ast.ast-node-pool-context-capture-active))]
                  (and
                    (compiler-check-inline-layout-name-ok? ctx "AstTypeList")
                    (compiler-check-inline-layout-name-ok? ctx "AstExprList")
                    (compiler-check-inline-layout-name-ok? ctx "AstPatternList")
                    (compiler-check-inline-layout-name-ok? ctx "AstDeclList")
                    (compiler-check-inline-layout-name-ok? ctx "AstParamList")
                    (compiler-check-inline-layout-name-ok?
                      ctx
                      "AstVariantDefList")))]
              [(Err _) false])]
          [(Err _) false]))]
    [(Err _) false]))

(define (compiler-check-export-ok?) : bool
  (match (check_core.compiler-check-source
    "src/export_entry.tl"
    "(defstruct Pair (left i64))
(defenum Maybe (Present i64))
(define answer : i64 42)
(define (main) : i64 answer)")
    [(Ok summary _) (> (tc_api.compiler-typecheck-summary-score summary) 0)]
    [(Err _ _) false]))

(define (compiler-check-qualified-export-cache-reset-ok?) : bool
  (and
    (compiler-check-direct-source-ok?
      "tests/qualified_export_cache_exported.tl"
      "(module a)
(define x : i64 1)
(module b)
(import a)
(define (main) : i64 a.x)")
    ;; There is no export list: values are reachable across modules through the
    ;; module symbol table, so this previously-private access type-checks.
    (compiler-check-direct-source-ok?
      "tests/qualified_export_cache_private.tl"
      "(module a)
(define x : i64 1)
(module b)
(import a)
(define (main) : i64 a.x)")))

(define (compiler-check-virtual-error-ok?) : bool
  (match (check_core.compiler-check-source
    "docs/examples/bad_type.tl"
    "(define (main) : i64 true)")
    [(Ok _ _) false]
    [(Err diag _)
      (let
        [diagnostics : cdiag.CompilerDiagnosticList
          (cdiag.compiler-diagnostic-list-box-shared-view diag)]
        [first : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-first diagnostics)]
        (if (string.eq
          (cdiag.compiler-diagnostic-path first)
          "docs/examples/bad_type.tl")
          (if (= (cdiag.compiler-diagnostic-line first) 1)
            (string.eq
              (cdiag.compiler-diagnostic-message first)
              "typecheck: return type mismatch: expected i64, found bool")
            false)
          false))]))

(define (compiler-check-runtime-stdlib-boundary-no-import-ok?) : bool
  (and
    (compiler-check-source-error-ok?
      "tests/runtime_boundary_no_tl"
      "(define (main) : i64 (begin (flush-stdout) 0))"
      "typecheck: unbound name flush-stdout")
    (compiler-check-source-error-ok?
      "tests/runtime_boundary_no_file.tl"
      "(define (main [path : String]) : String (io.read-file path))"
      "typecheck: unknown qualified name io.read-file; import the module or use a visible dotted module alias")
    (compiler-check-source-error-ok?
      "tests/runtime_boundary_no_env.tl"
      "(define (main [name : String]) : String (var-value name))"
      "typecheck: unbound name var-value")
    (compiler-check-source-error-ok?
      "tests/runtime_boundary_no_fs.tl"
      "(define (main) : String (current-dir))"
      "typecheck: unbound name current-dir")
    (compiler-check-source-error-ok?
      "tests/runtime_boundary_no_profile.tl"
      "(define (main) : i64 (profile-now-ms))"
      "typecheck: unbound name profile-now-ms")))

(define (compiler-check-private-dynamic-buffer-vector-ok?) : bool
  (compiler-check-source-ok?
    "tests/private_dynamic_buffer_vector.tl"
    "(import stdlib.vector)
(import (vector.vector String) as svec)
(import (vector.vector i64) as i64vec)
(define (main) : i64
  (let
    [items : i64vec.Vec (i64vec.with-capacity 2)]
    (begin
      (i64vec.push-ref! (&mut items) 41)
      (i64vec.push-ref! (&mut items) 1)
      (i64vec.len (& items)))))"))

(define (compiler-check-private-dynamic-buffer-accepted-ok?) : bool
  (compiler-check-source-ok?
    "tests/private_dynamic_buffer_public.tl"
    (compiler-check-private-dynamic-buffer-source)))

(define (compiler-check-implicit-core-prelude-ok?) : bool
  (compiler-check-source-ok?
    "tests/implicit_core_prelude_check.tl"
    (compiler-check-implicit-core-prelude-source)))

(define (compiler-check-seen-root-ok?) : bool
  (let
    [path : String "src/already_loaded.tl"]
    [source : String "(define answer : i64 1)"]
    (match (compiler_load.compiler-load-source
      (owned_view.compiler-owned-shared-view path)
      (owned_view.compiler-owned-shared-view source)
      (sym_i64_env.sym-i64-empty))
      [(Ok _ seen)
        (match (compiler_load.compiler-load-source path source seen)
          [(Ok decls _)
            (match (ast.ast-decl-list-step decls)
              [(Nil) true]
              [_ false])]
          [(Err _) false])]
      [(Err _) false])))

(define (compiler-check-pool-reset-ok?) : bool
  (let
    [source : String "(define (main) : i64 0)"]
    (ast.ty-node-pool-reset!)
    (match (check_core.compiler-check-source
      "tests/pool_reset_a.tl"
      (owned_view.compiler-owned-shared-view source))
      [(Ok _ _)
        (let
          [first-len : i64 (ast.ty-node-pool-len)]
          (match (check_core.compiler-check-source
            "tests/pool_reset_b.tl"
            source)
            [(Ok _ _)
              (let
                [second-len : i64 (ast.ty-node-pool-len)]
                (and (> first-len 0) (= first-len second-len)))]
            [(Err _ _) false]))]
      [(Err _ _) false])))

(define (compiler-check-target-cfg-ok?) : bool
  (let
    [source : String
      "(cfg linux (define platform-value : i64 40))
(cfg windows (define platform-value : i64 40))
(cfg tooling-feature (define cfg-value : i64 2))
(define (main) : i64 (+ platform-value cfg-value))"]
    [names : svec.Vec (svec.new)]
    (svec.push-ref! (&mut names) "tooling-feature")
    (and
      (match (check_core.compiler-check-source-with-roots-and-cfg
        "tests/check_cfg_linux.tl"
        (owned_view.compiler-owned-shared-view source)
        (svec.new)
        (target_cfg.compiler-target-cfgs-with-names
          Linux
          (owned_view.compiler-owned-shared-view names)))
        [(Ok _ _) true]
        [(Err _ _) false])
      (match (check_core.compiler-check-source-with-roots-and-cfg
        "tests/check_cfg_windows.tl"
        source
        (svec.new)
        (target_cfg.compiler-target-cfgs-with-names Windows names))
        [(Ok _ _) true]
        [(Err _ _) false]))))

(define (compiler-check-self-test) : i64
  (unless
    (= (load_tests.compiler-load-self-test) 42)
    (return (io.panic "compiler-check: loader smoke mismatch")))
  (unless
    (compiler-check-virtual-import-ok?)
    (return (io.panic "compiler-check: virtual import smoke mismatch")))
  (unless
    (compiler-check-virtual-import-inline-layout-ok?)
    (return
      (io.panic "compiler-check: virtual import inline layout smoke mismatch")))
  (unless
    (compiler-check-export-ok?)
    (return (io.panic "compiler-check: export smoke mismatch")))
  (unless
    (compiler-check-qualified-export-cache-reset-ok?)
    (return
      (io.panic "compiler-check: qualified export cache reset smoke mismatch")))
  (unless
    (compiler-check-virtual-error-ok?)
    (return (io.panic "compiler-check: virtual diagnostic smoke mismatch")))
  (unless
    (compiler-check-runtime-stdlib-boundary-no-import-ok?)
    (return
      (io.panic
        "compiler-check: runtime stdlib boundary no-import smoke mismatch")))
  (unless
    (compiler-check-source-ok?
      "tests/runtime_boundary_tl"
      "(import stdlib.io)
(import stdlib.byte_buf)
(define (main [path : String]) : i64
  (let
    [data : byte_buf.ByteBuf (io.read-file (clone path))]
    (begin
      (io.print-format \"{}\" \"\")
      (io.flush-stdout)
      (+ (byte_buf.len (& data))
         (unsafe (io.file-open-status path 0))))))")
    (return
      (io.panic "compiler-check: runtime stdlib io boundary smoke mismatch")))
  (unless
    (compiler-check-source-ok?
      "tests/runtime_boundary_env.tl"
      "(import stdlib.env)
(import stdlib.string)
(define (main [name : String]) : i64
  (+ (if (env.var-exists? name) 1 0)
     (+ (string.string-length (env.var-value name))
        (string.string-length (env.path-separator)))))")
    (return
      (io.panic "compiler-check: runtime stdlib env boundary smoke mismatch")))
  (unless
    (compiler-check-source-ok?
      "tests/runtime_boundary_fs.tl"
      "(import stdlib.fs)
(import stdlib.string)
(define (main [path : String]) : i64
  (+ (fs.process-id)
     (+ (fs.current-dir-status)
        (+ (string.string-length (fs.current-dir))
           (fs.file-size-status path)))))")
    (return
      (io.panic "compiler-check: runtime stdlib fs boundary smoke mismatch")))
  (unless
    (compiler-check-source-ok?
      "tests/runtime_boundary_profile.tl"
      "(import stdlib.profile)
(define (main) : i64
  (begin
    (profile.alloc-reset-peak)
    (+ (profile.now-ms)
       (+ (profile.alloc-total)
          (+ (profile.alloc-live) (profile.alloc-peak))))))")
    (return
      (io.panic
        "compiler-check: runtime stdlib profile boundary smoke mismatch")))
  (unless
    (compiler-check-private-dynamic-buffer-vector-ok?)
    (return
      (io.panic "compiler-check: private dynamic-buffer vector smoke mismatch")))
  (unless
    (compiler-check-private-dynamic-buffer-accepted-ok?)
    (return
      (io.panic "compiler-check: private dynamic-buffer public smoke mismatch")))
  (unless
    (compiler-check-implicit-core-prelude-ok?)
    (return (io.panic "compiler-check: implicit core prelude smoke mismatch")))
  (unless
    (compiler-check-seen-root-ok?)
    (return (io.panic "compiler-check: seen root smoke mismatch")))
  (unless
    (compiler-check-pool-reset-ok?)
    (return (io.panic "compiler-check: pool reset smoke mismatch")))
  (unless
    (compiler-check-target-cfg-ok?)
    (return (io.panic "compiler-check: target/cfg smoke mismatch")))
  42)