;; compiler_parse_smoke.tl - Runnable structural smoke for compiler_parse_core.
(import stdlib.str_cat_runtime as str_cat)
(import compiler_parse_core)
(import compiler_ast_types as ast)
(import read as reader)
(import stdlib.string)
(import compiler_diagnostic as diagnostic)
(import compiler_diagnostic_tests)
(import compiler_builtin_ids as cbi)
(import compiler_intern as ci)

(define (compiler-parse-test-decl-origin-start-ok?
  [origin : compiler_parse_core.CompilerParseMaybeDeclSpan]
  [line : i64]
  [col : i64]) : bool
  (match origin
    [(compiler_parse_core.CompilerParseMaybeDeclSpan.Some span)
      (and
        (= (ast.ast-source-span-start-line span) line)
        (= (ast.ast-source-span-start-col span) col))]
    [(compiler_parse_core.CompilerParseMaybeDeclSpan.None) false]))

(define (compiler-parse-test-decl-origin-records-ok?) : bool
  (let
    [mark : i64 (reader.sp-node-pool-len)]
    [ok : bool false]
    (begin
      (match (compiler_parse_core.parse-ast-source
        "(module alpha)
(unsafe (extern (bad [arg0 : (Tuple i64 i64)]) : i64 (:abi c)))
(defstruct RefBox (:lifetimes a a) (value (& a i64)))")
        [(compiler_parse_core.ResultAstProgram.Ok
            (ast.AstProgram.Program decls-box))
          (let
            [decls : ast.AstDeclList (__tl-box-place decls-box)]
            [tail1 : ast.AstDeclList (ast.ast-decl-list-tail decls)]
            [tail2 : ast.AstDeclList (ast.ast-decl-list-tail tail1)]
            [replacement : ast.AstDeclList (ast.ast-decl-list-with-capacity 3)]
            [alias1 : ast.AstDeclList (ast.ast-decl-list-with-capacity 3)]
            [alias2 : ast.AstDeclList (ast.ast-decl-list-with-capacity 3)]
            (begin
              (ast.ast-decl-list-append-from (&mut replacement) (& decls) 0)
              (compiler_parse_core.compiler-parse-decl-origin-register-maybe!
                (& replacement)
                0
                (compiler_parse_core.compiler-parse-decl-origin-span
                  (& decls)
                  0))
              (compiler_parse_core.compiler-parse-decl-origin-register-maybe!
                (& replacement)
                2
                (compiler_parse_core.compiler-parse-decl-origin-span
                  (& tail2)
                  0))
              (ast.ast-decl-list-append-from (&mut alias1) (& replacement) 0)
              (compiler_parse_core.compiler-parse-decl-origin-register-list-aliases!
                (& alias1)
                0
                replacement)
              (ast.ast-decl-list-append-from (&mut alias2) (& alias1) 0)
              (compiler_parse_core.compiler-parse-decl-origin-register-list-aliases!
                (& alias2)
                0
                alias1)
              (set!
                ok
                (and
                  (compiler-parse-test-decl-origin-start-ok?
                    (compiler_parse_core.compiler-parse-decl-origin-span
                      (& decls)
                      0)
                    1
                    1)
                  (compiler-parse-test-decl-origin-start-ok?
                    (compiler_parse_core.compiler-parse-decl-origin-span
                      (& tail1)
                      0)
                    2
                    9)
                  (compiler-parse-test-decl-origin-start-ok?
                    (compiler_parse_core.compiler-parse-decl-origin-span
                      (& tail2)
                      0)
                    3
                    1)
                  (compiler-parse-test-decl-origin-start-ok?
                    (compiler_parse_core.compiler-parse-decl-origin-span
                      (& replacement)
                      0)
                    1
                    1)
                  (match (compiler_parse_core.compiler-parse-decl-origin-span
                    (& replacement)
                    1)
                    [(compiler_parse_core.CompilerParseMaybeDeclSpan.None) true]
                    [_ false])
                  (compiler-parse-test-decl-origin-start-ok?
                    (compiler_parse_core.compiler-parse-decl-origin-span
                      (& replacement)
                      2)
                    3
                    1)
                  (compiler-parse-test-decl-origin-start-ok?
                    (compiler_parse_core.compiler-parse-decl-origin-span
                      (& alias2)
                      0)
                    1
                    1)
                  (match (compiler_parse_core.compiler-parse-decl-origin-span
                    (& alias2)
                    1)
                    [(compiler_parse_core.CompilerParseMaybeDeclSpan.None) true]
                    [_ false])
                  (compiler-parse-test-decl-origin-start-ok?
                    (compiler_parse_core.compiler-parse-decl-origin-span
                      (& alias2)
                      2)
                    3
                    1)))
              (reader.sp-node-pool-truncate! mark)
              (compiler_parse_core.compiler-parse-decl-origin-cache-reset!)
              (set!
                ok
                (and
                  ok
                  (match (compiler_parse_core.compiler-parse-decl-origin-span
                    (& decls)
                    0)
                    [(compiler_parse_core.CompilerParseMaybeDeclSpan.None) true]
                    [_ false])))))]
        [(compiler_parse_core.ResultAstProgram.Err _)
          (reader.sp-node-pool-truncate! mark)])
      ok)))

(define (compiler-parse-member-origin-boundary-ok?) : bool
  (match (compiler_parse_core.parse-ast-source
    "(defstruct First (x i64))
(defstruct Second (y i64))")
    [(compiler_parse_core.ResultAstProgram.Ok
        (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
        (match (ast.ast-decl-list-get (& decls) 0 (ast.ast-decl-fallback))
          [(ast.AstDecl.DefStruct decl-meta _ _ _ fields)
            (let
              [span : ast.AstSourceSpan
                (compiler_parse_core.compiler-parse-field-def-list-span-get
                  (& fields)
                  1
                  (ast.ast-decl-span-fallback))]
              (and
                (= (ast.ast-source-span-start-line span) 1)
                (= (ast.ast-source-span-start-col span) 12)))]
          [_ false]))]
    [(compiler_parse_core.ResultAstProgram.Err _) false]))

(define (compiler-parse-test-name-id? [name-id : i64] [text : String]) : bool
  (match (ci.intern-lookup text)
    [(ci.InternLookupFound expected-id) (= name-id expected-id)]
    [(ci.InternLookupMissing) false]))

(define (compiler-parse-name-id-provenance-ok?) : bool
  ;; Keep the inline-test discovery marker split: this source is parser input,
  ;; not an inline test declaration in this file.
  (match (compiler_parse_core.parse-ast-source
    (str_cat.str-cat
      "(module parsed.module)
(defstruct ParsedType (parsed-field i64))
(define (parsed-fn [parsed-param : ParsedType]) : ParsedType parsed-param)
"
      "("
      "test parsed-test unit)"))
    [(compiler_parse_core.ResultAstProgram.Ok
        (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
        (and
          (match (ast.ast-decl-list-get (& decls) 0 (ast.ast-decl-fallback))
            [(ast.AstDecl.Module name)
              (compiler-parse-test-name-id? name "parsed.module")]
            [_ false])
          (match (ast.ast-decl-list-get (& decls) 1 (ast.ast-decl-fallback))
            [(ast.AstDecl.DefStruct decl-meta name _ _ fields)
              (and
                (compiler-parse-test-name-id? name "ParsedType")
                (match (ast.ast-field-def-list-get
                  (& fields)
                  0
                  (ast.ast-field-def-fallback))
                  [(ast.AstFieldDef.Def field _ _)
                    (compiler-parse-test-name-id? field "parsed-field")]))]
            [_ false])
          (match (ast.ast-decl-list-get (& decls) 2 (ast.ast-decl-fallback))
            [(ast.AstDecl.DefFn decl-meta name params ret _ _)
              (and
                (compiler-parse-test-name-id? name "parsed-fn")
                (match (ast.ast-param-list-get
                  (& params)
                  0
                  (ast.ast-param-fallback))
                  [(ast.AstParam.Param param ty _ _)
                    (and
                      (compiler-parse-test-name-id? param "parsed-param")
                      (match ty
                        [(ast.AstType.Var type-name)
                          (compiler-parse-test-name-id? type-name "ParsedType")]
                        [_ false]))])
                (match ret
                  [(ast.AstType.Var type-name)
                    (compiler-parse-test-name-id? type-name "ParsedType")]
                  [_ false]))]
            [_ false])
          (match (ast.ast-decl-list-get (& decls) 3 (ast.ast-decl-fallback))
            [(ast.AstDecl.Test name _ _)
              (compiler-parse-test-name-id? name "parsed-test")]
            [_ false])))]
    [(compiler_parse_core.ResultAstProgram.Err _) false]))

(define (compiler-parse-removed-declaration-errors-ok?) : bool
  (and
    (compiler_parse_core.compiler-parse-error-ok?
      "(comptime-decl (define value : i64 1))"
      (compiler_parse_core.parse-ast-removed-declaration-message))
    (compiler_parse_core.compiler-parse-error-ok?
      "(comptime-decls (define value : i64 1))"
      (compiler_parse_core.parse-ast-removed-declaration-message))
    (compiler_parse_core.compiler-parse-error-ok?
      "(define (main) : i64 (comptime-decl (define value : i64 1)))"
      (compiler_parse_core.parse-ast-removed-declaration-message))
    (compiler_parse_core.compiler-parse-error-ok?
      "(define (main) : i64 (comptime-decls (define value : i64 1)))"
      (compiler_parse_core.parse-ast-removed-declaration-message))))

(define (compiler-diagnostic-test-source-position-index
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

(define (compiler-diagnostic-test-apply-edit
  [source : String]
  [edit : diagnostic.CompilerDiagnosticTextEdit]) : diagnostic.CompilerDiagnosticMaybeString
  (let
    [span : diagnostic.CompilerDiagnosticSpan
      (diagnostic.compiler-diagnostic-text-edit-span edit)]
    [start : i64
      (compiler-diagnostic-test-source-position-index
        source
        (diagnostic.compiler-diagnostic-span-start-line span)
        (diagnostic.compiler-diagnostic-span-start-col span))]
    [end : i64
      (compiler-diagnostic-test-source-position-index
        source
        (diagnostic.compiler-diagnostic-span-end-line span)
        (diagnostic.compiler-diagnostic-span-end-col span))]
    [source-len : i64 (string.string-length source)]
    (if (or (< start 0) (< end start))
      CompilerDiagnosticNoString
      (CompilerDiagnosticSomeString
        (str_cat.str-cat
          (string.substring source 0 start)
          (diagnostic.compiler-diagnostic-text-edit-replacement edit)
          (string.substring source end (- source-len end)))))))

;; The compiler itself never emits a multi-edit fix, so the shipped module keeps
;; only the single-edit constructor and this fixture builds the pair locally.
(define (compiler-diagnostic-test-edit-pair
  [first : diagnostic.CompilerDiagnosticTextEdit]
  [second : diagnostic.CompilerDiagnosticTextEdit]) : diagnostic.CompilerDiagnosticTextEditSeq
  (let
    [slots : (__tl_dyn-array diagnostic.CompilerDiagnosticTextEdit)
      (__tl_make-array diagnostic.CompilerDiagnosticTextEdit 2)]
    (begin
      (set! (array-ref slots 0) first)
      (set! (array-ref slots 1) second)
      (diagnostic.CompilerDiagnosticTextEditSeq slots 2))))

(define (compiler-diagnostic-fix-model-ok?) : bool
  (let
    [plain : diagnostic.CompilerDiagnostic
      (diagnostic.compiler-diagnostic-simple "plain.tl" 1 1 "plain")]
    [fix : diagnostic.CompilerDiagnosticFix
      (diagnostic.compiler-diagnostic-fix-new
        "Apply both edits"
        CompilerDiagnosticMachineApplicable
        (compiler-diagnostic-test-edit-pair
          (diagnostic.compiler-diagnostic-text-edit-new
            (diagnostic.CompilerDiagnosticSpan "" 1 2 1 4)
            "first")
          (diagnostic.compiler-diagnostic-text-edit-new
            (diagnostic.CompilerDiagnosticSpan "other.tl" 2 3 2 5)
            "λ")))]
    [diag : diagnostic.CompilerDiagnostic
      (diagnostic.compiler-diagnostic-with-fix plain fix)]
    [copied : diagnostic.CompilerDiagnostic
      (diagnostic.compiler-diagnostic-copy diag)]
    [moved : diagnostic.CompilerDiagnostic
      (diagnostic.compiler-diagnostic-with-primary-span
        (diagnostic.compiler-diagnostic-with-path copied "new.tl")
        (diagnostic.CompilerDiagnosticSpan "new.tl" 4 5 4 6))]
    [fixes : diagnostic.CompilerDiagnosticFixSeq
      (diagnostic.compiler-diagnostic-fixes moved)]
    (and
      (=
        (__tl-project-field (diagnostic.compiler-diagnostic-fixes plain) len)
        0)
      (= fixes.len 1)
      (let
        [copied-fix : diagnostic.CompilerDiagnosticFix
          (array-ref fixes.slots 0)]
        [edits : diagnostic.CompilerDiagnosticTextEditSeq
          (diagnostic.compiler-diagnostic-fix-edits copied-fix)]
        (and
          (string.eq
            (diagnostic.compiler-diagnostic-fix-title copied-fix)
            "Apply both edits")
          (match (diagnostic.compiler-diagnostic-fix-applicability copied-fix)
            [CompilerDiagnosticMachineApplicable true]
            [_ false])
          (= edits.len 2)
          (let
            [first : diagnostic.CompilerDiagnosticTextEdit
              (array-ref edits.slots 0)]
            [second : diagnostic.CompilerDiagnosticTextEdit
              (array-ref edits.slots 1)]
            [first-span : diagnostic.CompilerDiagnosticSpan
              (diagnostic.compiler-diagnostic-text-edit-span first)]
            [second-span : diagnostic.CompilerDiagnosticSpan
              (diagnostic.compiler-diagnostic-text-edit-span second)]
            (and
              (string.eq
                (diagnostic.compiler-diagnostic-span-path first-span)
                "new.tl")
              (string.eq
                (diagnostic.compiler-diagnostic-text-edit-replacement first)
                "first")
              (string.eq
                (diagnostic.compiler-diagnostic-span-path second-span)
                "other.tl")
              (= (diagnostic.compiler-diagnostic-span-start-line second-span) 2)
              (= (diagnostic.compiler-diagnostic-span-start-col second-span) 3)
              (string.eq
                (diagnostic.compiler-diagnostic-text-edit-replacement second)
                "λ"))))))))

(define (compiler-diagnostic-invalid-fixes-rejected-ok?) : bool
  (let
    [base : diagnostic.CompilerDiagnostic
      (diagnostic.compiler-diagnostic-simple "invalid.tl" 1 1 "invalid")]
    [unknown : diagnostic.CompilerDiagnostic
      (diagnostic.compiler-diagnostic-with-fix
        base
        (diagnostic.compiler-diagnostic-fix-new
          "Unknown span"
          CompilerDiagnosticMachineApplicable
          (diagnostic.compiler-diagnostic-text-edit-single
            (diagnostic.compiler-diagnostic-text-edit-new
              (diagnostic.CompilerDiagnosticSpan "" 0 0 0 0)
              "x"))))]
    [overlap : diagnostic.CompilerDiagnostic
      (diagnostic.compiler-diagnostic-with-fix
        base
        (diagnostic.compiler-diagnostic-fix-new
          "Overlapping edits"
          CompilerDiagnosticMachineApplicable
          (compiler-diagnostic-test-edit-pair
            (diagnostic.compiler-diagnostic-text-edit-new
              (diagnostic.CompilerDiagnosticSpan "" 1 2 1 6)
              "left")
            (diagnostic.compiler-diagnostic-text-edit-new
              (diagnostic.CompilerDiagnosticSpan "" 1 4 1 7)
              "right"))))]
    (and
      (=
        (__tl-project-field (diagnostic.compiler-diagnostic-fixes unknown) len)
        0)
      (=
        (__tl-project-field (diagnostic.compiler-diagnostic-fixes overlap) len)
        0))))

(define (compiler-diagnostic-unicode-byte-edit-ok?) : bool
  (let
    [source : String "αx\n"]
    [edit : diagnostic.CompilerDiagnosticTextEdit
      (diagnostic.compiler-diagnostic-text-edit-new
        ;; alpha occupies UTF-8 byte columns 1-2, so x is byte column 3.
        (diagnostic.CompilerDiagnosticSpan "unicode.tl" 1 3 1 4)
        "β")]
    (match (compiler-diagnostic-test-apply-edit source edit)
      [(CompilerDiagnosticSomeString updated) (string.eq updated "αβ\n")]
      [CompilerDiagnosticNoString false])))

(define (main) : i64
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (if (and
      (= (compiler_diagnostic_tests.compiler-diagnostic-self-test) 42)
      (compiler-parse-test-decl-origin-records-ok?)
      (compiler-parse-member-origin-boundary-ok?)
      (compiler-parse-name-id-provenance-ok?)
      (compiler-parse-removed-declaration-errors-ok?)
      (compiler-diagnostic-fix-model-ok?)
      (compiler-diagnostic-invalid-fixes-rejected-ok?)
      (compiler-diagnostic-unicode-byte-edit-ok?))
      (compiler_parse_core.compiler-parse-smoke)
      1)))