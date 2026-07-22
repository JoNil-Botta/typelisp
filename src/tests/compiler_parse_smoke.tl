;; compiler_parse_smoke.tl - Runnable structural smoke for compiler_parse_core.
(import "../compiler_parse_core.tl")
(import compiler_builtin_ids as cbi)
(import compiler_intern as ci)

(define (compiler-parse-test-decl-origin-start-ok?
  [origin : CompilerParseMaybeDeclSpan]
  [line : i64]
  [col : i64]) : bool
  (match origin
    [(CompilerParseMaybeDeclSpan.Some span)
      (and
        (= (ast-source-span-start-line span) line)
        (= (ast-source-span-start-col span) col))]
    [(CompilerParseMaybeDeclSpan.None) false]))

(define (compiler-parse-test-decl-origin-records-ok?) : bool
  (let
    [mark : i64 (reader.sp-node-pool-len)]
    [ok : bool false]
    (begin
      (match (parse-ast-source
        "(module alpha)
(unsafe (extern (bad [arg0 : (Tuple i64 i64)]) : i64 (:abi c)))
(defstruct RefBox (:lifetimes a a) (value (& a i64)))")
        [(ResultAstProgram.Ok (AstProgram.Program decls-box))
          (let
            [decls : AstDeclList (box-get decls-box)]
            [tail1 : AstDeclList (ast-decl-list-tail decls)]
            [tail2 : AstDeclList (ast-decl-list-tail tail1)]
            [replacement : AstDeclList (ast-decl-list-with-capacity 3)]
            [alias1 : AstDeclList (ast-decl-list-with-capacity 3)]
            [alias2 : AstDeclList (ast-decl-list-with-capacity 3)]
            (begin
              (ast-decl-list-append-from (&mut replacement) (& decls) 0)
              (compiler-parse-decl-origin-register-maybe!
                (& replacement)
                0
                (compiler-parse-decl-origin-span (& decls) 0))
              (compiler-parse-decl-origin-register-maybe!
                (& replacement)
                2
                (compiler-parse-decl-origin-span (& tail2) 0))
              (ast-decl-list-append-from (&mut alias1) (& replacement) 0)
              (compiler-parse-decl-origin-register-list-aliases!
                (& alias1)
                0
                replacement)
              (ast-decl-list-append-from (&mut alias2) (& alias1) 0)
              (compiler-parse-decl-origin-register-list-aliases!
                (& alias2)
                0
                alias1)
              (set!
                ok
                (and
                  (compiler-parse-test-decl-origin-start-ok?
                    (compiler-parse-decl-origin-span (& decls) 0)
                    1
                    1)
                  (compiler-parse-test-decl-origin-start-ok?
                    (compiler-parse-decl-origin-span (& tail1) 0)
                    2
                    9)
                  (compiler-parse-test-decl-origin-start-ok?
                    (compiler-parse-decl-origin-span (& tail2) 0)
                    3
                    1)
                  (compiler-parse-test-decl-origin-start-ok?
                    (compiler-parse-decl-origin-span (& replacement) 0)
                    1
                    1)
                  (match (compiler-parse-decl-origin-span (& replacement) 1)
                    [(CompilerParseMaybeDeclSpan.None) true]
                    [_ false])
                  (compiler-parse-test-decl-origin-start-ok?
                    (compiler-parse-decl-origin-span (& replacement) 2)
                    3
                    1)
                  (compiler-parse-test-decl-origin-start-ok?
                    (compiler-parse-decl-origin-span (& alias2) 0)
                    1
                    1)
                  (match (compiler-parse-decl-origin-span (& alias2) 1)
                    [(CompilerParseMaybeDeclSpan.None) true]
                    [_ false])
                  (compiler-parse-test-decl-origin-start-ok?
                    (compiler-parse-decl-origin-span (& alias2) 2)
                    3
                    1)))
              (reader.sp-node-pool-truncate! mark)
              (compiler-parse-decl-origin-cache-reset!)
              (set!
                ok
                (and
                  ok
                  (match (compiler-parse-decl-origin-span (& decls) 0)
                    [(CompilerParseMaybeDeclSpan.None) true]
                    [_ false])))))]
        [(ResultAstProgram.Err _) (reader.sp-node-pool-truncate! mark)])
      ok)))

(define (compiler-parse-member-origin-boundary-ok?) : bool
  (match (parse-ast-source
    "(defstruct First (x i64))
(defstruct Second (y i64))")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-get (& decls) 0 (ast-decl-fallback))
          [(AstDecl.DefStruct decl-meta _ _ _ fields)
            (let
              [span : AstSourceSpan
                (compiler-parse-field-def-list-span-get
                  (& fields)
                  1
                  (ast-decl-span-fallback))]
              (and
                (= (ast-source-span-start-line span) 1)
                (= (ast-source-span-start-col span) 12)))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-test-name-id? [name-id : i64] [text : String]) : bool
  (match (ci.intern-lookup text)
    [(ci.InternLookupFound expected-id) (= name-id expected-id)]
    [(ci.InternLookupMissing) false]))

(define (compiler-parse-name-id-provenance-ok?) : bool
  ;; Keep the inline-test discovery marker split: this source is parser input,
  ;; not an inline test declaration in this file.
  (match (parse-ast-source
    (string.concat3
      "(module parsed.module)
(defstruct ParsedType (parsed-field i64))
(define (parsed-fn [parsed-param : ParsedType]) : ParsedType parsed-param)
"
      "("
      "test parsed-test unit)"))
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (and
          (match (ast-decl-list-get (& decls) 0 (ast-decl-fallback))
            [(AstDecl.Module name)
              (compiler-parse-test-name-id? name "parsed.module")]
            [_ false])
          (match (ast-decl-list-get (& decls) 1 (ast-decl-fallback))
            [(AstDecl.DefStruct decl-meta name _ _ fields)
              (and
                (compiler-parse-test-name-id? name "ParsedType")
                (match (ast-field-def-list-get
                  (& fields)
                  0
                  (ast-field-def-fallback))
                  [(AstFieldDef.Def field _ _)
                    (compiler-parse-test-name-id? field "parsed-field")]))]
            [_ false])
          (match (ast-decl-list-get (& decls) 2 (ast-decl-fallback))
            [(AstDecl.DefFn decl-meta name params ret _ _)
              (and
                (compiler-parse-test-name-id? name "parsed-fn")
                (match (ast-param-list-get (& params) 0 (ast-param-fallback))
                  [(AstParam.Param param ty _ _)
                    (and
                      (compiler-parse-test-name-id? param "parsed-param")
                      (match ty
                        [(AstType.Var type-name)
                          (compiler-parse-test-name-id? type-name "ParsedType")]
                        [_ false]))])
                (match ret
                  [(AstType.Var type-name)
                    (compiler-parse-test-name-id? type-name "ParsedType")]
                  [_ false]))]
            [_ false])
          (match (ast-decl-list-get (& decls) 3 (ast-decl-fallback))
            [(AstDecl.Test name _ _)
              (compiler-parse-test-name-id? name "parsed-test")]
            [_ false])))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-removed-declaration-errors-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(comptime-decl (define value : i64 1))"
      (parse-ast-removed-declaration-message))
    (compiler-parse-error-ok?
      "(comptime-decls (define value : i64 1))"
      (parse-ast-removed-declaration-message))
    (compiler-parse-error-ok?
      "(define (main) : i64 (comptime-decl (define value : i64 1)))"
      (parse-ast-removed-declaration-message))
    (compiler-parse-error-ok?
      "(define (main) : i64 (comptime-decls (define value : i64 1)))"
      (parse-ast-removed-declaration-message))))

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
  [edit : CompilerDiagnosticTextEdit]) : CompilerDiagnosticMaybeString
  (let
    [span : CompilerDiagnosticSpan (compiler-diagnostic-text-edit-span edit)]
    [start : i64
      (compiler-diagnostic-test-source-position-index
        source
        (compiler-diagnostic-span-start-line span)
        (compiler-diagnostic-span-start-col span))]
    [end : i64
      (compiler-diagnostic-test-source-position-index
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

(define (compiler-diagnostic-fix-model-ok?) : bool
  (let
    [plain : CompilerDiagnostic
      (compiler-diagnostic-simple "plain.tl" 1 1 "plain")]
    [fix : CompilerDiagnosticFix
      (compiler-diagnostic-fix-new
        "Apply both edits"
        CompilerDiagnosticMachineApplicable
        (CompilerDiagnosticTextEditCons
          (compiler-diagnostic-text-edit-new
            (CompilerDiagnosticSpan "" 1 2 1 4)
            "first")
          (box
            (CompilerDiagnosticTextEditCons
              (compiler-diagnostic-text-edit-new
                (CompilerDiagnosticSpan "other.tl" 2 3 2 5)
                "λ")
              (box CompilerDiagnosticTextEditNil)))))]
    [diag : CompilerDiagnostic (compiler-diagnostic-with-fix plain fix)]
    [copied : CompilerDiagnostic (compiler-diagnostic-copy diag)]
    [moved : CompilerDiagnostic
      (compiler-diagnostic-with-primary-span
        (compiler-diagnostic-with-path copied "new.tl")
        (CompilerDiagnosticSpan "new.tl" 4 5 4 6))]
    (and
      (match (compiler-diagnostic-fixes plain)
        [CompilerDiagnosticFixNil true]
        [(CompilerDiagnosticFixCons _ _) false])
      (match (compiler-diagnostic-fixes moved)
        [(CompilerDiagnosticFixCons copied-fix fix-rest)
          (and
            (string.eq
              (compiler-diagnostic-fix-title copied-fix)
              "Apply both edits")
            (match (compiler-diagnostic-fix-applicability copied-fix)
              [CompilerDiagnosticMachineApplicable true]
              [_ false])
            (match (compiler-diagnostic-fix-edits copied-fix)
              [(CompilerDiagnosticTextEditCons first first-rest)
                (match (box-get first-rest)
                  [(CompilerDiagnosticTextEditCons second second-rest)
                    (let
                      [first-span : CompilerDiagnosticSpan
                        (compiler-diagnostic-text-edit-span first)]
                      [second-span : CompilerDiagnosticSpan
                        (compiler-diagnostic-text-edit-span second)]
                      (and
                        (string.eq
                          (compiler-diagnostic-span-path first-span)
                          "new.tl")
                        (string.eq
                          (compiler-diagnostic-text-edit-replacement first)
                          "first")
                        (string.eq
                          (compiler-diagnostic-span-path second-span)
                          "other.tl")
                        (= (compiler-diagnostic-span-start-line second-span) 2)
                        (= (compiler-diagnostic-span-start-col second-span) 3)
                        (string.eq
                          (compiler-diagnostic-text-edit-replacement second)
                          "λ")
                        (match (box-get second-rest)
                          [CompilerDiagnosticTextEditNil true]
                          [(CompilerDiagnosticTextEditCons _ _) false])))]
                  [CompilerDiagnosticTextEditNil false])]
              [CompilerDiagnosticTextEditNil false])
            (match (box-get fix-rest)
              [CompilerDiagnosticFixNil true]
              [(CompilerDiagnosticFixCons _ _) false]))]
        [CompilerDiagnosticFixNil false]))))

(define (compiler-diagnostic-invalid-fixes-rejected-ok?) : bool
  (let
    [base : CompilerDiagnostic
      (compiler-diagnostic-simple "invalid.tl" 1 1 "invalid")]
    [unknown : CompilerDiagnostic
      (compiler-diagnostic-with-fix
        base
        (compiler-diagnostic-fix-new
          "Unknown span"
          CompilerDiagnosticMachineApplicable
          (compiler-diagnostic-text-edit-single
            (compiler-diagnostic-text-edit-new
              (CompilerDiagnosticSpan "" 0 0 0 0)
              "x"))))]
    [overlap : CompilerDiagnostic
      (compiler-diagnostic-with-fix
        base
        (compiler-diagnostic-fix-new
          "Overlapping edits"
          CompilerDiagnosticMachineApplicable
          (CompilerDiagnosticTextEditCons
            (compiler-diagnostic-text-edit-new
              (CompilerDiagnosticSpan "" 1 2 1 6)
              "left")
            (box
              (compiler-diagnostic-text-edit-single
                (compiler-diagnostic-text-edit-new
                  (CompilerDiagnosticSpan "" 1 4 1 7)
                  "right"))))))]
    (and
      (match (compiler-diagnostic-fixes unknown)
        [CompilerDiagnosticFixNil true]
        [(CompilerDiagnosticFixCons _ _) false])
      (match (compiler-diagnostic-fixes overlap)
        [CompilerDiagnosticFixNil true]
        [(CompilerDiagnosticFixCons _ _) false]))))

(define (compiler-diagnostic-unicode-byte-edit-ok?) : bool
  (let
    [source : String "αx\n"]
    [edit : CompilerDiagnosticTextEdit
      (compiler-diagnostic-text-edit-new
        ;; alpha occupies UTF-8 byte columns 1-2, so x is byte column 3.
        (CompilerDiagnosticSpan "unicode.tl" 1 3 1 4)
        "β")]
    (match (compiler-diagnostic-test-apply-edit source edit)
      [(CompilerDiagnosticSomeString updated) (string.eq updated "αβ\n")]
      [CompilerDiagnosticNoString false])))

(define (main) : i64
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (if (and
      (= (compiler-diagnostic-self-test) 42)
      (compiler-parse-test-decl-origin-records-ok?)
      (compiler-parse-member-origin-boundary-ok?)
      (compiler-parse-name-id-provenance-ok?)
      (compiler-parse-removed-declaration-errors-ok?)
      (compiler-diagnostic-fix-model-ok?)
      (compiler-diagnostic-invalid-fixes-rejected-ok?)
      (compiler-diagnostic-unicode-byte-edit-ok?))
      (compiler-parse-smoke)
      1)))