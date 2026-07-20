;; compiler_check_core.tl - Shared selfhost check/typecheck helpers.
(import stdlib.io)
(import stdlib.arena)
(import stdlib.string)
(import stdlib.vector)
(import (vector String) as svec)
(cfg compile-profile (import stdlib.profile))
(import "compiler_load.tl")
(import "compiler_typecheck_api.tl")
(import compiler_builtin_ids as cbi)
(import sym_i64_env)

(defenum ResultCompilerCheck
  (Ok CompilerTypecheckSummary)
  (Err (Box CompilerDiagnostic)))

(defenum ResultCompilerCheckWithPaths
  (Ok CompilerTypecheckSummary AstDeclPathList)
  (Err (Box CompilerDiagnostic)))

;; Tool-facing semantic data is copied into an explicitly owned arena. None of
;; these records retain TcContext, TcTypeEnv, parser sidecars, or intern-pool
;; strings, so a later check can reset compiler state without invalidating a
;; caller's last-good index.
(defstruct CompilerSemanticSymbolId
  (module-id i64)
  (declaration-ordinal i64)
  (local-ordinal i64))

(defenum CompilerSemanticSymbolKind
  (Value)
  (Function)
  (Macro)
  (ExternValue)
  (ExternFunction)
  (Struct)
  (Enum)
  (Parameter)
  (Local))

(defenum CompilerSemanticRecordRole
  (Definition)
  (Use))

(defenum CompilerSemanticProvenance
  (EditableSource)
  (Generated String String String))

(defstruct CompilerSemanticSpan
  (path String)
  (start-byte i64)
  (end-byte i64)
  (source AstSourceSpan))

(defstruct CompilerSemanticRecord
  (symbol CompilerSemanticSymbolId)
  (role CompilerSemanticRecordRole)
  (kind CompilerSemanticSymbolKind)
  (display-name String)
  (resolved-type String)
  (documentation String)
  (module-id i64)
  (span CompilerSemanticSpan)
  (editable bool)
  (provenance CompilerSemanticProvenance))

(defstruct CompilerSemanticRecordVec
  (items (Array CompilerSemanticRecord))
  (len i64))

(defstruct CompilerSemanticSourceIndex
  (owner-arena i64)
  (records (Array CompilerSemanticRecord))
  (len i64)
  ;; A failed check returns no replacement index. Callers keep their previous
  ;; successful value until this flag can also represent partial checks.
  (complete bool))

(defenum ResultCompilerCheckWithSemanticIndex
  (Ok CompilerTypecheckSummary CompilerSemanticSourceIndex)
  (Err (Box CompilerDiagnostic)))

(defenum CompilerSemanticMaybeDecl
  (Some i64 CompilerSemanticSymbolKind)
  (None))

(define (compiler-semantic-record-fallback) : CompilerSemanticRecord
  (CompilerSemanticRecord
    (CompilerSemanticSymbolId 0 -1 -1)
    CompilerSemanticRecordRole.Definition
    CompilerSemanticSymbolKind.Value
    ""
    ""
    ""
    0
    (CompilerSemanticSpan "" -1 -1 (ast-source-span 1 1 1 1))
    false
    CompilerSemanticProvenance.EditableSource))

(define (compiler-semantic-record-vec-new [capacity : i64]) : CompilerSemanticRecordVec
  (CompilerSemanticRecordVec
    (array.make-array
      CompilerSemanticRecord
      (if (< capacity 1)
        1
        capacity))
    0))

(define (compiler-semantic-record-vec-push!
  [records : (&mut records CompilerSemanticRecordVec)]
  [record : CompilerSemanticRecord]) : unit
  (begin
    (if (>= (struct-get records len) (array-length (struct-get records items)))
      (io.panic "semantic index: record capacity exceeded")
      unit)
    (let
      [index : i64 (struct-get records len)]
      (begin
        (array-set! (struct-get records items) index record)
        (set! (struct-get records len) (+ index 1))))))

(define (compiler-semantic-source-index-len
  [index : (& index CompilerSemanticSourceIndex)]) : i64
  (struct-get index len))

(define (compiler-semantic-source-index-get
  [index : (& index CompilerSemanticSourceIndex)]
  [record-index : i64]) : CompilerSemanticRecord
  (if (and (>= record-index 0) (< record-index (struct-get index len)))
    (array-ref (struct-get index records) record-index)
    (compiler-semantic-record-fallback)))

(define (compiler-semantic-source-index-complete?
  [index : (& index CompilerSemanticSourceIndex)]) : bool
  (struct-get index complete))

(define (compiler-semantic-source-index-release!
  [index : (&mut index CompilerSemanticSourceIndex)]) : unit
  (let
    [owner : i64 (struct-get index owner-arena)]
    (if (> owner 0)
      (begin
        (set! (struct-get index owner-arena) 0)
        (set! (struct-get index len) 0)
        (unsafe
          (arena.tl_arena_destroy owner)))
      unit)))

(define (compiler-semantic-decl-symbol [decl : AstDecl]) : CompilerSemanticMaybeDecl
  (match decl
    [(AstDecl.Def _ name _ _)
      (CompilerSemanticMaybeDecl.Some name CompilerSemanticSymbolKind.Value)]
    [(AstDecl.DefFn _ name _ _ _ _)
      (CompilerSemanticMaybeDecl.Some name CompilerSemanticSymbolKind.Function)]
    [(AstDecl.DefMacro _ name _ _ _)
      (CompilerSemanticMaybeDecl.Some name CompilerSemanticSymbolKind.Macro)]
    [(AstDecl.Extern _ name kind _ _)
      (CompilerSemanticMaybeDecl.Some
        name
        (match kind
          [(AstExternKind.Value) CompilerSemanticSymbolKind.ExternValue]
          [(AstExternKind.Function) CompilerSemanticSymbolKind.ExternFunction]))]
    [(AstDecl.DefEnum _ name _ _)
      (CompilerSemanticMaybeDecl.Some name CompilerSemanticSymbolKind.Enum)]
    [(AstDecl.DefEnumLifetimes _ name _ _ _)
      (CompilerSemanticMaybeDecl.Some name CompilerSemanticSymbolKind.Enum)]
    [(AstDecl.DefStruct _ name _ _ _)
      (CompilerSemanticMaybeDecl.Some name CompilerSemanticSymbolKind.Struct)]
    [(AstDecl.DefStructLifetimes _ name _ _ _ _)
      (CompilerSemanticMaybeDecl.Some name CompilerSemanticSymbolKind.Struct)]
    [(AstDecl.DefDispatch _ name _)
      (CompilerSemanticMaybeDecl.Some name CompilerSemanticSymbolKind.Function)]
    [(AstDecl.Unsafe inner) (compiler-semantic-decl-symbol (box-get inner))]
    [_ CompilerSemanticMaybeDecl.None]))

(define (compiler-semantic-source-offset
  [source : String]
  [target-line : i64]
  [target-col : i64]) : i64
  (let
    [index : i64 0]
    [line : i64 1]
    [col : i64 1]
    [len : i64 (string.string-length source)]
    (begin
      (while (and
        (< index len)
        (or (< line target-line) (and (= line target-line) (< col target-col))))
        (begin
          (if (= (string.string-ref source index) '\n')
            (begin
              (set! line (+ line 1))
              (set! col 1))
            (set! col (+ col 1)))
          (set! index (+ index 1))))
      index)))

(define (compiler-semantic-source-position [source : String] [target : i64]) : AstSourceSpan
  (let
    [index : i64 0]
    [line : i64 1]
    [col : i64 1]
    [limit : i64
      (if (< target (string.string-length source))
        target
        (string.string-length source))]
    (begin
      (while (< index limit)
        (begin
          (if (= (string.string-ref source index) '\n')
            (begin
              (set! line (+ line 1))
              (set! col 1))
            (set! col (+ col 1)))
          (set! index (+ index 1))))
      (ast-source-span line col line col))))

(define (compiler-semantic-delimiter? [c : char]) : bool
  (or
    (= c ' ')
    (= c '\t')
    (= c '\r')
    (= c '\n')
    (= c '(')
    (= c ')')
    (= c '[')
    (= c ']')
    (= c '{')
    (= c '}')))

(define (compiler-semantic-source-name-at?
  [source : String]
  [name : String]
  [start : i64]
  [limit : i64]) : bool
  (let
    [name-len : i64 (string.string-length name)]
    [offset : i64 0]
    [matches : bool true]
    (begin
      (if (or
        (> (+ start name-len) limit)
        (and
          (> start 0)
          (not
            (compiler-semantic-delimiter?
              (string.string-ref source (- start 1)))))
        (and
          (< (+ start name-len) (string.string-length source))
          (< (+ start name-len) limit)
          (not
            (compiler-semantic-delimiter?
              (string.string-ref source (+ start name-len))))))
        (set! matches false)
        unit)
      (while (and matches (< offset name-len))
        (if (=
          (string.string-ref source (+ start offset))
          (string.string-ref name offset))
          (set! offset (+ offset 1))
          (set! matches false)))
      matches)))

(define (compiler-semantic-top-level-form-start
  [source : String]
  [before : i64]) : i64
  (let
    [cursor : i64
      (if (< before (string.string-length source))
        before
        (string.string-length source))]
    [found : i64 0]
    [done : bool false]
    (begin
      (while (and (not done) (> cursor 0))
        (begin
          (set! cursor (- cursor 1))
          (if (and
            (= (string.string-ref source cursor) '(')
            (or (= cursor 0) (= (string.string-ref source (- cursor 1)) '\n')))
            (begin
              (set! found cursor)
              (set! done true))
            unit)))
      found)))

(define (compiler-semantic-definition-span
  [path : String]
  [source : String]
  [name : String]
  [origin : AstSourceSpan]) : CompilerSemanticSpan
  (let
    [origin-start : i64
      (compiler-semantic-source-offset
        source
        (ast-source-span-start-line origin)
        (ast-source-span-start-col origin))]
    [start : i64 (compiler-semantic-top-level-form-start source origin-start)]
    [end : i64
      (compiler-semantic-source-offset
        source
        (ast-source-span-end-line origin)
        (ast-source-span-end-col origin))]
    [cursor : i64 start]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (< cursor end))
        (if (compiler-semantic-source-name-at? source name cursor end)
          (set! found cursor)
          (set! cursor (+ cursor 1))))
      (if (< found 0)
        (CompilerSemanticSpan (string.copy (& path)) start end origin)
        (let
          [name-len : i64 (string.string-length name)]
          [position : AstSourceSpan
            (compiler-semantic-source-position source found)]
          [line : i64 (ast-source-span-start-line position)]
          [col : i64 (ast-source-span-start-col position)]
          (CompilerSemanticSpan
            (string.copy (& path))
            found
            (+ found name-len)
            (ast-source-span line col line (+ col name-len))))))))

(define (compiler-semantic-decl-origin
  [decls : (& decls AstDeclList)]
  [index : i64]
  [decl : AstDecl]) : CompilerParseMaybeDeclSpan
  (match (compiler-parse-decl-origin-span decls index)
    [(CompilerParseMaybeDeclSpan.Some span)
      (CompilerParseMaybeDeclSpan.Some span)]
    [(CompilerParseMaybeDeclSpan.None)
      (let
        [maybe-span : TcMaybeAstSourceSpan
          (match decl
            [(AstDecl.Def _ _ _ expr) (tc-expr-id-maybe-span expr)]
            [(AstDecl.DefFn _ _ _ _ body _) (tc-expr-id-maybe-span body)]
            [(AstDecl.DefMacro _ _ _ _ body) (tc-expr-id-maybe-span body)]
            [(AstDecl.Unsafe inner)
              (match (compiler-semantic-decl-origin decls index (box-get inner))
                [(CompilerParseMaybeDeclSpan.Some span)
                  (TcMaybeAstSourceSpan.Some span)]
                [(CompilerParseMaybeDeclSpan.None) TcMaybeAstSourceSpan.No])]
            [_ TcMaybeAstSourceSpan.No])]
        (match maybe-span
          [(TcMaybeAstSourceSpan.Some span)
            (CompilerParseMaybeDeclSpan.Some span)]
          [(TcMaybeAstSourceSpan.No) CompilerParseMaybeDeclSpan.None]))]))

(define (compiler-semantic-decl-type
  [ctx : TcContext]
  [env : TcTypeEnv]
  [decl : AstDecl]
  [kind : CompilerSemanticSymbolKind]
  [name : String]) : String
  (match kind
    [(CompilerSemanticSymbolKind.Struct) (string.append "struct " name)]
    [(CompilerSemanticSymbolKind.Enum) (string.append "enum " name)]
    [(CompilerSemanticSymbolKind.Macro)
      (match decl
        [(AstDecl.DefMacro _ _ params ret _)
          (tc-type-render
            (ast-ty-func
              (tc-macro-param-type-list ctx params)
              (tc-resolve-type ctx ret)))]
        [(AstDecl.Unsafe inner)
          (compiler-semantic-decl-type ctx env (box-get inner) kind name)]
        [_ "macro"])]
    [_
      (match (tc-top-decl-type-with-env ctx env decl)
        [(ResultTcType.Ok ty) (tc-type-render ty)]
        [(ResultTcType.Err _) ""])]))

(define (compiler-semantic-decl-provenance [decl : AstDecl]) : CompilerSemanticProvenance
  (match (ast-decl-generated-meta decl)
    [(AstGeneratedDeclMeta.No) CompilerSemanticProvenance.EditableSource]
    [(AstGeneratedDeclMeta.Some generator item _ key)
      (CompilerSemanticProvenance.Generated
        (string.copy (& generator))
        (string.copy (& item))
        (string.copy (& key)))]))

(define (compiler-semantic-index-build-owned
  [ctx : TcContext]
  [env : TcTypeEnv]
  [paths : AstDeclPathList]
  [entry-path : String]
  [entry-source : String]) : CompilerSemanticSourceIndex
  (let
    [previous : i64 (arena.tl_arena_current)]
    [owner : i64 (arena.tl_arena_make)]
    (begin
      (unsafe
        (arena.tl_arena_set owner))
      (let
        [decls : AstDeclList
          (match (tc-context-program ctx)
            [(AstProgram.Program decls-box) (box-get decls-box)])]
        [records : CompilerSemanticRecordVec
          (compiler-semantic-record-vec-new (ast-decl-list-len (& decls)))]
        [index : i64 0]
        [cached-path : String ""]
        [cached-source : String ""]
        (begin
          (while (< index (ast-decl-list-len (& decls)))
            (let
              [decl : AstDecl
                (ast-decl-list-get (& decls) index (ast-decl-fallback))]
              [path : String
                (ast-decl-path-list-get (& paths) index entry-path)]
              [module-id : i64
                (ast-decl-path-list-owner-id
                  (& paths)
                  index
                  cbi.compiler-builtin-id-fix-empty)]
              [path-changed : bool (not (string.eq path cached-path))]
              (begin
                (if path-changed
                  (begin
                    (set! cached-path (string.copy (& path)))
                    (set!
                      cached-source
                      (cond
                        [(string.eq path entry-path)
                          (string.copy (& entry-source))]
                        [(and (not (string.eq path "")) (io.file-exists? path))
                          (io.read-file path)]
                        [else ""])))
                  unit)
                (match (compiler-semantic-decl-symbol decl)
                  [(CompilerSemanticMaybeDecl.Some name-id kind)
                    (let
                      [name : String (tc-env-key-name-text name-id)]
                      [generated : bool
                        (match (ast-decl-generated-meta decl)
                          [(AstGeneratedDeclMeta.No) false]
                          [(AstGeneratedDeclMeta.Some _ _ _ _) true])]
                      [maybe-origin : CompilerParseMaybeDeclSpan
                        (compiler-semantic-decl-origin (& decls) index decl)]
                      [has-origin : bool
                        (match maybe-origin
                          [(CompilerParseMaybeDeclSpan.Some _) true]
                          [(CompilerParseMaybeDeclSpan.None)
                            (and
                              (not generated)
                              (not (string.eq cached-source "")))])]
                      [span : CompilerSemanticSpan
                        (match maybe-origin
                          [(CompilerParseMaybeDeclSpan.Some origin)
                            (if (string.eq cached-source "")
                              (CompilerSemanticSpan
                                (string.copy (& path))
                                -1
                                -1
                                origin)
                              (compiler-semantic-definition-span
                                path
                                cached-source
                                name
                                origin))]
                          [(CompilerParseMaybeDeclSpan.None)
                            (if (and
                              (not generated)
                              (not (string.eq cached-source "")))
                              (let
                                [end-position : AstSourceSpan
                                  (compiler-semantic-source-position
                                    cached-source
                                    (string.string-length cached-source))]
                                (compiler-semantic-definition-span
                                  path
                                  cached-source
                                  name
                                  (ast-source-span
                                    1
                                    1
                                    (ast-source-span-start-line end-position)
                                    (ast-source-span-start-col end-position))))
                              (CompilerSemanticSpan
                                (string.copy (& path))
                                -1
                                -1
                                (ast-source-span 1 1 1 1)))])]
                      [type-text : String
                        (compiler-semantic-decl-type ctx env decl kind name)]
                      (compiler-semantic-record-vec-push!
                        (&mut records)
                        (CompilerSemanticRecord
                          (CompilerSemanticSymbolId module-id index -1)
                          CompilerSemanticRecordRole.Definition
                          kind
                          (string.copy (& name))
                          (string.copy (& type-text))
                          ""
                          module-id
                          span
                          (and (not generated) has-origin)
                          (compiler-semantic-decl-provenance decl))))]
                  [(CompilerSemanticMaybeDecl.None) unit])
                (set! index (+ index 1)))))
          (let
            [result : CompilerSemanticSourceIndex
              (CompilerSemanticSourceIndex
                owner
                (struct-get records items)
                (struct-get records len)
                true)]
            (begin
              (unsafe
                (arena.tl_arena_set previous))
              result)))))))

(cfg
  compile-profile
  (define compiler-check-profile-start-ms : i64
    0))

(cfg
  compile-profile
  (define (compiler-check-profile-start) : unit
    (set! compiler-check-profile-start-ms (profile.now-ms))))

(cfg
  compile-profile
  (define (compiler-check-profile-finish [phase : String]) : unit
    (io.print-error
      (string.append
        "compile-profile|check."
        (string.append
          phase
          (string.append
            "|"
            (string.append
              (string.int->string
                (- (profile.now-ms) compiler-check-profile-start-ms))
              "|0|0|0\n")))))))

(define (compiler-check-language-cfgs) : sym_i64_env.SymI64Env
  (compiler-cfg-enable-compiler-language-features (compiler-cfg-empty)))

(define (compiler-check-diagnostic-with-fallback-path
  [diag : CompilerDiagnostic]
  [path : String]) : CompilerDiagnostic
  (if (string.eq (compiler-diagnostic-path diag) "")
    (compiler-diagnostic-with-path diag path)
    diag))

(define (compiler-check-reset-pools!) : unit
  (compiler-load-session-reset-pools!))

(define (compiler-check-reset-interns!) : unit
  (begin
    (compiler-load-session-reset-interns!)
    (compiler-typecheck-reset-intern-owned-state!)))

(define (compiler-check-program-with-paths-cache
  [path : String]
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [stdlib-roots : svec.Vec]
  [cache-scope : String]) : ResultCompilerCheck
  (begin
    (cfg compile-profile (compiler-check-profile-start))
    (match (typecheck-compiler-program-with-paths-cache
      (ast-program decls)
      paths
      stdlib-roots
      cache-scope)
      [(ResultCompilerTypecheck.Ok summary)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "typecheck"))
          (ResultCompilerCheck.Ok summary))]
      [(ResultCompilerTypecheck.Err diag)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "typecheck"))
          (ResultCompilerCheck.Err
            (box
              (compiler-check-diagnostic-with-fallback-path (box-get diag) path))))])))

(define (compiler-check-program-with-paths
  [path : String]
  [decls : AstDeclList]
  [paths : AstDeclPathList]) : ResultCompilerCheck
  (compiler-check-program-with-paths-cache
    path
    decls
    paths
    (svec.new)
    (tc-prefix-default-cache-scope)))

(define (compiler-check-program [path : String] [decls : AstDeclList]) : ResultCompilerCheck
  (compiler-check-program-with-paths path decls (ast-decl-path-list-new)))

(define (compiler-check-program-with-paths-index-cache
  [path : String]
  [source : String]
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [stdlib-roots : svec.Vec]
  [cache-scope : String]) : ResultCompilerCheckWithSemanticIndex
  (begin
    (cfg compile-profile (compiler-check-profile-start))
    (match (typecheck-compiler-program-with-paths-checked-cache
      (ast-program decls)
      paths
      stdlib-roots
      cache-scope)
      [(ResultCompilerTypecheckChecked.Ok summary ctx env checked-paths)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "typecheck"))
          (ResultCompilerCheckWithSemanticIndex.Ok
            summary
            (compiler-semantic-index-build-owned
              ctx
              env
              checked-paths
              path
              source)))]
      [(ResultCompilerTypecheckChecked.Err diag)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "typecheck"))
          (ResultCompilerCheckWithSemanticIndex.Err
            (box
              (compiler-check-diagnostic-with-fallback-path (box-get diag) path))))])))

(define (compiler-check-loaded-with-prelude-cache
  [path : String]
  [prelude-decls : AstDeclList]
  [prelude-paths : AstDeclPathList]
  [loaded : ResultCompilerLoadWithPaths]
  [stdlib-roots : svec.Vec]
  [cache-scope : String]) : ResultCompilerCheck
  (match loaded
    [(ResultCompilerLoadWithPaths.Ok entry-decls entry-paths entry-modules _)
      (begin
        (cfg compile-profile (compiler-check-profile-finish "load"))
        (compiler-check-program-with-paths-cache
          path
          (compiler-load-decl-list-append prelude-decls entry-decls)
          (compiler-load-decl-path-list-append
            prelude-paths
            (ast-decl-path-list-with-modules entry-paths entry-modules))
          stdlib-roots
          cache-scope))]
    [(ResultCompilerLoadWithPaths.Err diag)
      (begin
        (cfg compile-profile (compiler-check-profile-finish "load"))
        (ResultCompilerCheck.Err diag))]))

(define (compiler-check-loaded-with-prelude-index-cache
  [path : String]
  [source : String]
  [prelude-decls : AstDeclList]
  [prelude-paths : AstDeclPathList]
  [loaded : ResultCompilerLoadWithPaths]
  [stdlib-roots : svec.Vec]
  [cache-scope : String]) : ResultCompilerCheckWithSemanticIndex
  (match loaded
    [(ResultCompilerLoadWithPaths.Ok entry-decls entry-paths entry-modules _)
      (begin
        (cfg compile-profile (compiler-check-profile-finish "load"))
        (compiler-check-program-with-paths-index-cache
          path
          source
          (compiler-load-decl-list-append prelude-decls entry-decls)
          (compiler-load-decl-path-list-append
            prelude-paths
            (ast-decl-path-list-with-modules entry-paths entry-modules))
          stdlib-roots
          cache-scope))]
    [(ResultCompilerLoadWithPaths.Err diag)
      (begin
        (cfg compile-profile (compiler-check-profile-finish "load"))
        (ResultCompilerCheckWithSemanticIndex.Err diag))]))

(define (compiler-check-loaded-cache-with-paths
  [path : String]
  [loaded : ResultCompilerLoadWithPaths]
  [stdlib-roots : svec.Vec]
  [cache-scope : String]) : ResultCompilerCheckWithPaths
  (match loaded
    [(ResultCompilerLoadWithPaths.Ok decls paths modules _)
      (let
        [owned-paths : AstDeclPathList
          (ast-decl-path-list-with-modules paths modules)]
        (begin
          (cfg compile-profile (compiler-check-profile-finish "load"))
          (match (compiler-check-program-with-paths-cache
            path
            decls
            owned-paths
            stdlib-roots
            cache-scope)
            [(ResultCompilerCheck.Ok summary)
              (ResultCompilerCheckWithPaths.Ok summary owned-paths)]
            [(ResultCompilerCheck.Err diag)
              (ResultCompilerCheckWithPaths.Err diag)])))]
    [(ResultCompilerLoadWithPaths.Err diag)
      (begin
        (cfg compile-profile (compiler-check-profile-finish "load"))
        (ResultCompilerCheckWithPaths.Err diag))]))

(define (compiler-check-loaded-with-prelude
  [path : String]
  [prelude-decls : AstDeclList]
  [prelude-paths : AstDeclPathList]
  [loaded : ResultCompilerLoadWithPaths]) : ResultCompilerCheck
  (compiler-check-loaded-with-prelude-cache
    path
    prelude-decls
    prelude-paths
    loaded
    (svec.new)
    (tc-prefix-default-cache-scope)))

(define (compiler-check-file-loaded-with-prelude
  [path : String]
  [stdlib-roots : svec.Vec]
  [prelude : ResultCompilerLoadWithPaths]) : ResultCompilerCheck
  (match prelude
    [(ResultCompilerLoadWithPaths.Ok
        prelude-decls
        prelude-paths
        prelude-modules
        prelude-seen)
      (compiler-check-loaded-with-prelude-cache
        path
        prelude-decls
        (ast-decl-path-list-with-modules prelude-paths prelude-modules)
        (compiler-load-file-with-paths-and-roots-cfg
          path
          prelude-seen
          stdlib-roots
          (compiler-check-language-cfgs))
        stdlib-roots
        (compiler-typecheck-prefix-cache-scope
          "typecheck-prefix-check"
          stdlib-roots
          (compiler-check-language-cfgs)))]
    [(ResultCompilerLoadWithPaths.Err diag)
      (begin
        (cfg compile-profile (compiler-check-profile-finish "load"))
        (ResultCompilerCheck.Err diag))]))

(define (compiler-check-file [path : String]) : ResultCompilerCheck
  (begin
    (compiler-check-reset-pools!)
    (cfg compile-profile (compiler-check-profile-start))
    (compiler-check-file-loaded-with-prelude
      path
      (svec.new)
      (compiler-load-core-macro-prelude-with-roots-cfg
        (sym_i64_env.sym-i64-empty)
        (svec.new)
        (compiler-check-language-cfgs)))))

(define (compiler-check-file-with-roots
  [path : String]
  [stdlib-roots : svec.Vec]) : ResultCompilerCheck
  (begin
    (compiler-check-reset-pools!)
    (cfg compile-profile (compiler-check-profile-start))
    (compiler-check-file-loaded-with-prelude
      path
      stdlib-roots
      (compiler-load-core-macro-prelude-with-roots-cfg
        (sym_i64_env.sym-i64-empty)
        stdlib-roots
        (compiler-check-language-cfgs)))))

(define (compiler-check-package-file-with-roots
  [path : String]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]) : ResultCompilerCheck
  (begin
    (compiler-check-reset-pools!)
    (cfg compile-profile (compiler-check-profile-start))
    (match (compiler-load-package-core-macro-prelude-with-roots-cfg
      (sym_i64_env.sym-i64-empty)
      stdlib-roots
      manifest-dir
      deps
      (compiler-check-language-cfgs))
      [(ResultCompilerLoadWithPaths.Ok
          prelude-decls
          prelude-paths
          prelude-modules
          prelude-seen)
        (compiler-check-loaded-with-prelude-cache
          path
          prelude-decls
          (ast-decl-path-list-with-modules prelude-paths prelude-modules)
          (compiler-load-package-file-with-paths-and-roots-cfg
            path
            prelude-seen
            stdlib-roots
            manifest-dir
            deps
            (compiler-check-language-cfgs))
          stdlib-roots
          (compiler-typecheck-prefix-cache-scope
            "typecheck-prefix-check"
            stdlib-roots
            (compiler-check-language-cfgs)))]
      [(ResultCompilerLoadWithPaths.Err diag)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "load"))
          (ResultCompilerCheck.Err diag))])))

(define (compiler-check-package-source-with-roots
  [path : String]
  [source : String]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]) : ResultCompilerCheck
  (begin
    (compiler-check-reset-pools!)
    (cfg compile-profile (compiler-check-profile-start))
    (match (compiler-load-package-core-macro-prelude-with-roots-cfg
      (sym_i64_env.sym-i64-empty)
      stdlib-roots
      manifest-dir
      deps
      (compiler-check-language-cfgs))
      [(ResultCompilerLoadWithPaths.Ok
          prelude-decls
          prelude-paths
          prelude-modules
          prelude-seen)
        (let
          [parse-identity : CompilerLoadParseIdentity
            (compiler-load-parse-identity
              path
              (compiler-load-canonical-module-id-from-path path)
              AstMaybeModuleName.No)]
          (match (compiler-load-parse-source-diagnostic-escaping
            path
            source
            (compiler-check-language-cfgs))
            [(ResultAstProgramDiagnostic.Ok program)
              (compiler-check-loaded-with-prelude-cache
                path
                prelude-decls
                (ast-decl-path-list-with-modules prelude-paths prelude-modules)
                (compiler-load-package-program-with-paths-and-roots-expect
                  path
                  program
                  prelude-seen
                  stdlib-roots
                  AstMaybeModuleName.No
                  manifest-dir
                  deps
                  (compiler-check-language-cfgs)
                  parse-identity)
                stdlib-roots
                (compiler-typecheck-prefix-cache-scope
                  "typecheck-prefix-check"
                  stdlib-roots
                  (compiler-check-language-cfgs)))]
            [(ResultAstProgramDiagnostic.Err diag)
              (begin
                (cfg compile-profile (compiler-check-profile-finish "load"))
                (ResultCompilerCheck.Err diag))]))]
      [(ResultCompilerLoadWithPaths.Err diag)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "load"))
          (ResultCompilerCheck.Err diag))])))

(define (compiler-check-package-entry-file-with-roots
  [path : String]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [emit-entry : bool]) : ResultCompilerCheckWithPaths
  (begin
    (compiler-check-reset-pools!)
    (cfg compile-profile (compiler-check-profile-start))
    (compiler-check-loaded-cache-with-paths
      path
      (compiler-load-package-file-with-runtime-cfg
        path
        stdlib-roots
        manifest-dir
        deps
        emit-entry
        (compiler-check-language-cfgs))
      stdlib-roots
      (compiler-typecheck-prefix-cache-scope
        "typecheck-prefix-check"
        stdlib-roots
        (compiler-check-language-cfgs)))))

(define (compiler-check-source [path : String] [source : String]) : ResultCompilerCheck
  (begin
    (compiler-check-reset-pools!)
    (cfg compile-profile (compiler-check-profile-start))
    (match (compiler-load-core-macro-prelude-with-roots-cfg
      (sym_i64_env.sym-i64-empty)
      (svec.new)
      (compiler-check-language-cfgs))
      [(ResultCompilerLoadWithPaths.Ok
          prelude-decls
          prelude-paths
          prelude-modules
          prelude-seen)
        (compiler-check-loaded-with-prelude-cache
          path
          prelude-decls
          (ast-decl-path-list-with-modules prelude-paths prelude-modules)
          (compiler-load-source-with-paths-and-roots-cfg
            path
            source
            prelude-seen
            (svec.new)
            (compiler-check-language-cfgs))
          (svec.new)
          (compiler-typecheck-prefix-cache-scope
            "typecheck-prefix-check"
            (svec.new)
            (compiler-check-language-cfgs)))]
      [(ResultCompilerLoadWithPaths.Err diag)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "load"))
          (ResultCompilerCheck.Err diag))])))

(define (compiler-check-source-with-roots
  [path : String]
  [source : String]
  [stdlib-roots : svec.Vec]) : ResultCompilerCheck
  (begin
    (compiler-check-reset-pools!)
    (cfg compile-profile (compiler-check-profile-start))
    (match (compiler-load-core-macro-prelude-with-roots-cfg
      (sym_i64_env.sym-i64-empty)
      stdlib-roots
      (compiler-check-language-cfgs))
      [(ResultCompilerLoadWithPaths.Ok
          prelude-decls
          prelude-paths
          prelude-modules
          prelude-seen)
        (compiler-check-loaded-with-prelude-cache
          path
          prelude-decls
          (ast-decl-path-list-with-modules prelude-paths prelude-modules)
          (compiler-load-source-with-paths-and-roots-cfg
            path
            source
            prelude-seen
            stdlib-roots
            (compiler-check-language-cfgs))
          stdlib-roots
          (compiler-typecheck-prefix-cache-scope
            "typecheck-prefix-check"
            stdlib-roots
            (compiler-check-language-cfgs)))]
      [(ResultCompilerLoadWithPaths.Err diag)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "load"))
          (ResultCompilerCheck.Err diag))])))

;; Build a replacement index only after a complete semantic check. On error no
;; index is returned, which makes the last-good contract explicit: IDE clients
;; retain their previously owned index and diagnostic handling stays unchanged.
(define (compiler-check-source-index-with-roots
  [path : String]
  [source : String]
  [stdlib-roots : svec.Vec]) : ResultCompilerCheckWithSemanticIndex
  (begin
    (compiler-check-reset-pools!)
    (cfg compile-profile (compiler-check-profile-start))
    (match (compiler-load-core-macro-prelude-with-roots-cfg
      (sym_i64_env.sym-i64-empty)
      stdlib-roots
      (compiler-check-language-cfgs))
      [(ResultCompilerLoadWithPaths.Ok
          prelude-decls
          prelude-paths
          prelude-modules
          prelude-seen)
        (compiler-check-loaded-with-prelude-index-cache
          path
          source
          prelude-decls
          (ast-decl-path-list-with-modules prelude-paths prelude-modules)
          (compiler-load-source-with-paths-and-roots-cfg
            path
            source
            prelude-seen
            stdlib-roots
            (compiler-check-language-cfgs))
          stdlib-roots
          (compiler-typecheck-prefix-cache-scope
            "typecheck-prefix-semantic-index"
            stdlib-roots
            (compiler-check-language-cfgs)))]
      [(ResultCompilerLoadWithPaths.Err diag)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "load"))
          (ResultCompilerCheckWithSemanticIndex.Err diag))])))

(define (compiler-check-source-ok? [path : String] [source : String]) : bool
  (match (compiler-check-source path source)
    [(ResultCompilerCheck.Ok _) true]
    [(ResultCompilerCheck.Err _) false]))

(define (compiler-check-source-error-ok?
  [path : String]
  [source : String]
  [want : String]) : bool
  (match (compiler-check-source path source)
    [(ResultCompilerCheck.Ok _) false]
    [(ResultCompilerCheck.Err diag)
      (string.eq (compiler-diagnostic-message (box-get diag)) want)]))

(define (compiler-check-virtual-import-source) : String
  "(import \"compiler_ast_types.tl\")
(import \"compiler_ast_types.tl\")
(define selected : AstType (AstType.I64))
(define (main) : i64
  (match selected [(AstType.I64) 42] [_ 0]))")

(define (compiler-check-export-source) : String
  "(defstruct Pair (left i64))
(defenum Maybe (Present i64))
(define answer : i64 42)
(define (main) : i64 answer)")

(define (compiler-check-direct-source [path : String] [source : String]) : ResultCompilerCheck
  (begin
    (compiler-check-reset-pools!)
    (match (compiler-load-parse-source-diagnostic-escaping
      path
      source
      (compiler-check-language-cfgs))
      [(ResultAstProgramDiagnostic.Ok program)
        (match program
          [(AstProgram.Program decls-box)
            (compiler-check-program-with-paths-cache
              path
              (box-get decls-box)
              (ast-decl-path-list-new)
              (svec.new)
              (compiler-typecheck-prefix-cache-scope
                "typecheck-prefix-check"
                (svec.new)
                (compiler-check-language-cfgs)))])]
      [(ResultAstProgramDiagnostic.Err diag) (ResultCompilerCheck.Err diag)])))

(define (compiler-check-direct-source-ok? [path : String] [source : String]) : bool
  (match (compiler-check-direct-source path source)
    [(ResultCompilerCheck.Ok _) true]
    [(ResultCompilerCheck.Err _) false]))

(define (compiler-check-direct-source-error-ok?
  [path : String]
  [source : String]
  [want : String]) : bool
  (match (compiler-check-direct-source path source)
    [(ResultCompilerCheck.Ok _) false]
    [(ResultCompilerCheck.Err diag)
      (string.eq (compiler-diagnostic-message (box-get diag)) want)]))

(define (compiler-check-qualified-export-cache-exported-source) : String
  "(module a)
(define x : i64 1)
(module b)
(import a)
(define (main) : i64 a.x)")

(define (compiler-check-qualified-export-cache-private-source) : String
  "(module a)
(define x : i64 1)
(module b)
(import a)
(define (main) : i64 a.x)")

(define (compiler-check-implicit-core-prelude-source) : String
  "(import \"stdlib/array.tl\" module stdlib.array as arr)
(define (main) : i64
  (let
    [value : i64 0]
    [items : (Array i64) (arr.make-array i64 1)]
    (begin
      (when (and (> 5 3) (< 2 4) (= 1 1)) (set! value (+ value 10)))
      (unless (or false false false) (set! value (+ value 20)))
      (array-set! items 0 value)
      (arr.push! items 2)
      (+
        (arr.length items)
        (+ (arr.ref items 0) (arr.ref items 1))))))")

(define (compiler-check-runtime-stdlib-boundary-io-source) : String
  "(import stdlib.io)
(import stdlib.string)
(define (main [path : String]) : i64
  (begin
    (io.print-string \"\")
    (io.flush-stdout)
    (+ (string.string-length (io.read-file path))
       (io.file-open-status path 0))))")

(define (compiler-check-runtime-stdlib-boundary-env-source) : String
  "(import stdlib.env)
(import stdlib.string)
(define (main [name : String]) : i64
  (+ (if (env.var-exists? name) 1 0)
     (+ (string.string-length (env.var-value name))
        (string.string-length (env.path-separator)))))")

(define (compiler-check-runtime-stdlib-boundary-fs-source) : String
  "(import stdlib.fs)
(import stdlib.string)
(define (main [path : String]) : i64
  (+ (fs.process-id)
     (+ (fs.current-dir-status)
        (+ (string.string-length (fs.current-dir))
           (fs.file-size-status path)))))")

(define (compiler-check-runtime-stdlib-boundary-profile-source) : String
  "(import stdlib.profile)
(define (main) : i64
  (begin
    (profile.alloc-reset-peak)
    (+ (profile.now-ms)
       (+ (profile.alloc-total)
          (+ (profile.alloc-live) (profile.alloc-peak))))))")

(define (compiler-check-private-dynamic-buffer-vector-source) : String
  "(import stdlib.vector)
(import (vector.vector String) as svec)
(import (vector.vector i64) as i64vec)
(define (main) : i64
  (let
    [items : i64vec.Vec (i64vec.with-capacity 2)]
    (begin
      (i64vec.push (&mut items) 41)
      (i64vec.push (&mut items) 1)
      (i64vec.len (& items)))))")

;; Compatibility alias fixture for the __tl_dyn-array alias. The qualified stdlib.array path is
;; covered by compiler-check-implicit-core-prelude-source above.
(define (compiler-check-private-dynamic-buffer-public-source) : String
  "(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (make-array i64 2)]
    (array-length items)))")

(define (compiler-check-virtual-import-ok?) : bool
  (match (compiler-check-source
    "src/virtual_entry.tl"
    (compiler-check-virtual-import-source))
    [(ResultCompilerCheck.Ok summary)
      (> (compiler-typecheck-summary-score summary) 0)]
    [(ResultCompilerCheck.Err _) false]))

(define (compiler-check-inline-layout-name-ok?
  [ctx : TcContext]
  [name : String]) : bool
  (match (tc-context-program ctx)
    [(AstProgram.Program decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        [index : i64 0]
        [name-id : i64 -1]
        (begin
          (while (and (< name-id 0) (< index (struct-get (& decls) len)))
            (let
              [decl : AstDecl
                (ast-decl-list-get (& decls) index (ast-decl-fallback))]
              (begin
                (match decl
                  [(AstDecl.DefStruct decl-meta candidate _ _ _)
                    (if (string.eq (tc-env-key-name-text candidate) name)
                      (set! name-id candidate)
                      unit)]
                  [(AstDecl.DefStructLifetimes decl-meta candidate _ _ _ _)
                    (if (string.eq (tc-env-key-name-text candidate) name)
                      (set! name-id candidate)
                      unit)]
                  [(AstDecl.DefEnum decl-meta candidate _ _)
                    (if (string.eq (tc-env-key-name-text candidate) name)
                      (set! name-id candidate)
                      unit)]
                  [(AstDecl.DefEnumLifetimes decl-meta candidate _ _ _)
                    (if (string.eq (tc-env-key-name-text candidate) name)
                      (set! name-id candidate)
                      unit)]
                  [_ unit])
                (set! index (+ index 1)))))
          (if (< name-id 0)
            false
            (match (tc-inline-aggregate-layout-finite-ok ctx name name-id)
              [(ResultTcUnit.Ok) true]
              [(ResultTcUnit.Err _) false]))))]))

(define (compiler-check-virtual-import-inline-layout-ok?) : bool
  (match (compiler-load-source-with-paths
    "src/virtual_entry.tl"
    (compiler-check-virtual-import-source)
    (sym_i64_env.sym-i64-empty))
    [(ResultCompilerLoadWithPaths.Ok decls _ _ _)
      (let
        [program : AstProgram (ast-program decls)]
        (match (build-compiler-symbols program)
          [(ResultCompilerSymbols.Ok symbols)
            (match (build-compiler-registries program)
              [(ResultCompilerRegistries.Ok registries)
                (let
                  [ctx : TcContext
                    (tc-context-new
                      program
                      symbols
                      registries
                      ""
                      cbi.compiler-builtin-id-fix-empty
                      (ast-node-pool-context-capture-active))]
                  (and
                    (compiler-check-inline-layout-name-ok? ctx "AstTypeList")
                    (compiler-check-inline-layout-name-ok? ctx "AstExprList")
                    (compiler-check-inline-layout-name-ok? ctx "AstPatternList")
                    (compiler-check-inline-layout-name-ok? ctx "AstDeclList")
                    (compiler-check-inline-layout-name-ok? ctx "AstParamList")
                    (compiler-check-inline-layout-name-ok?
                      ctx
                      "AstVariantDefList")))]
              [(ResultCompilerRegistries.Err _) false])]
          [(ResultCompilerSymbols.Err _) false]))]
    [(ResultCompilerLoadWithPaths.Err _) false]))

(define (compiler-check-export-ok?) : bool
  (match (compiler-check-source
    "src/export_entry.tl"
    (compiler-check-export-source))
    [(ResultCompilerCheck.Ok summary)
      (> (compiler-typecheck-summary-score summary) 0)]
    [(ResultCompilerCheck.Err _) false]))

(define (compiler-check-qualified-export-cache-reset-ok?) : bool
  (and
    (compiler-check-direct-source-ok?
      "tests/qualified_export_cache_exported.tl"
      (compiler-check-qualified-export-cache-exported-source))
    ;; There is no export list: values are reachable across modules through the
    ;; module symbol table, so this previously-private access type-checks.
    (compiler-check-direct-source-ok?
      "tests/qualified_export_cache_private.tl"
      (compiler-check-qualified-export-cache-private-source))))

(define (compiler-check-virtual-error-ok?) : bool
  (match (compiler-check-source
    "docs/examples/bad_type.tl"
    "(define (main) : i64 true)")
    [(ResultCompilerCheck.Ok _) false]
    [(ResultCompilerCheck.Err diag)
      (if (string.eq
        (compiler-diagnostic-path (box-get diag))
        "docs/examples/bad_type.tl")
        (if (= (compiler-diagnostic-line (box-get diag)) 1)
          (string.eq
            (compiler-diagnostic-message (box-get diag))
            "typecheck: return type mismatch: expected i64, found bool")
          false)
        false)]))

(define (compiler-check-runtime-stdlib-boundary-no-import-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-check-source-error-ok?
        "tests/runtime_boundary_no_tl"
        "(define (main) : i64 (begin (flush-stdout) 0))"
        "typecheck: unbound name flush-stdout")
        unit
        (set! ok false))
      (if (compiler-check-source-error-ok?
        "tests/runtime_boundary_no_file.tl"
        "(define (main [path : String]) : String (io.read-file path))"
        "typecheck: unknown qualified name io.read-file; import the module or use a visible dotted module alias")
        unit
        (set! ok false))
      (if (compiler-check-source-error-ok?
        "tests/runtime_boundary_no_env.tl"
        "(define (main [name : String]) : String (var-value name))"
        "typecheck: unbound name var-value")
        unit
        (set! ok false))
      (if (compiler-check-source-error-ok?
        "tests/runtime_boundary_no_fs.tl"
        "(define (main) : String (current-dir))"
        "typecheck: unbound name current-dir")
        unit
        (set! ok false))
      (if (compiler-check-source-error-ok?
        "tests/runtime_boundary_no_profile.tl"
        "(define (main) : i64 (profile-now-ms))"
        "typecheck: unbound name profile-now-ms")
        unit
        (set! ok false))
      ok)))

(define (compiler-check-runtime-stdlib-boundary-import-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-check-source-ok?
        "tests/runtime_boundary_tl"
        (compiler-check-runtime-stdlib-boundary-io-source))
        unit
        (set! ok false))
      (if (compiler-check-source-ok?
        "tests/runtime_boundary_env.tl"
        (compiler-check-runtime-stdlib-boundary-env-source))
        unit
        (set! ok false))
      (if (compiler-check-source-ok?
        "tests/runtime_boundary_fs.tl"
        (compiler-check-runtime-stdlib-boundary-fs-source))
        unit
        (set! ok false))
      (if (compiler-check-source-ok?
        "tests/runtime_boundary_profile.tl"
        (compiler-check-runtime-stdlib-boundary-profile-source))
        unit
        (set! ok false))
      ok)))

(define (compiler-check-runtime-stdlib-boundary-ok?) : bool
  (and
    (compiler-check-runtime-stdlib-boundary-no-import-ok?)
    (compiler-check-runtime-stdlib-boundary-import-ok?)))

(define (compiler-check-private-dynamic-buffer-vector-ok?) : bool
  (compiler-check-source-ok?
    "tests/private_dynamic_buffer_vector.tl"
    (compiler-check-private-dynamic-buffer-vector-source)))

(define (compiler-check-private-dynamic-buffer-public-rejected-ok?) : bool
  (compiler-check-source-error-ok?
    "tests/private_dynamic_buffer_public.tl"
    (compiler-check-private-dynamic-buffer-public-source)
    "parse: unknown type constructor __tl_dyn-array; TypeLisp has no source-level generic type constructors; use defmacro to generate concrete declarations instead"))

(define (compiler-check-implicit-core-prelude-ok?) : bool
  (compiler-check-source-ok?
    "tests/implicit_core_prelude_check.tl"
    (compiler-check-implicit-core-prelude-source)))

(define (compiler-check-seen-root-ok?) : bool
  (let
    [path : String "src/already_loaded.tl"]
    [source : String "(define answer : i64 1)"]
    (match (compiler-load-source path source (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoad.Ok _ seen)
        (match (compiler-load-source path source seen)
          [(ResultCompilerLoad.Ok decls _)
            (match (ast-decl-list-step decls)
              [(AstDeclListStep.Nil) true]
              [_ false])]
          [(ResultCompilerLoad.Err _) false])]
      [(ResultCompilerLoad.Err _) false])))

(define (compiler-check-pool-reset-ok?) : bool
  (let
    [source : String "(define (main) : i64 0)"]
    (begin
      (ty-node-pool-reset!)
      (match (compiler-check-source "tests/pool_reset_a.tl" source)
        [(ResultCompilerCheck.Ok _)
          (let
            [first-len : i64 (ty-node-pool-len)]
            (match (compiler-check-source "tests/pool_reset_b.tl" source)
              [(ResultCompilerCheck.Ok _)
                (let
                  [second-len : i64 (ty-node-pool-len)]
                  (and (> first-len 0) (= first-len second-len)))]
              [(ResultCompilerCheck.Err _) false]))]
        [(ResultCompilerCheck.Err _) false]))))

(define (compiler-semantic-source-index-find-definition
  [index : (& index CompilerSemanticSourceIndex)]
  [path : String]
  [name : String]) : i64
  (let
    [record-index : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (< record-index (struct-get index len)))
        (let
          [record : CompilerSemanticRecord
            (array-ref (struct-get index records) record-index)]
          (begin
            (if (and
              (match (struct-get record role)
                [(CompilerSemanticRecordRole.Definition) true]
                [_ false])
              (struct-get record editable)
              (string.eq (struct-get record display-name) name)
              (string.eq (struct-get (struct-get record span) path) path))
              (set! found record-index)
              unit)
            (set! record-index (+ record-index 1)))))
      found)))

(define (compiler-check-semantic-index-record-ok?
  [source : String]
  [record : CompilerSemanticRecord]
  [name : String]
  [kind : CompilerSemanticSymbolKind]) : bool
  (let
    [span : CompilerSemanticSpan (struct-get record span)]
    [start : i64 (struct-get span start-byte)]
    [end : i64 (struct-get span end-byte)]
    (and
      (struct-get record editable)
      (match (struct-get record provenance)
        [(CompilerSemanticProvenance.EditableSource) true]
        [_ false])
      (match kind
        [(CompilerSemanticSymbolKind.Value)
          (match (struct-get record kind)
            [(CompilerSemanticSymbolKind.Value) true]
            [_ false])]
        [(CompilerSemanticSymbolKind.Function)
          (match (struct-get record kind)
            [(CompilerSemanticSymbolKind.Function) true]
            [_ false])]
        [(CompilerSemanticSymbolKind.Struct)
          (match (struct-get record kind)
            [(CompilerSemanticSymbolKind.Struct) true]
            [_ false])]
        [_ false])
      (>= start 0)
      (= (- end start) (string.string-length name))
      (string.eq (string.substring source start (- end start)) name)
      (not (string.eq (struct-get record resolved-type) "")))))

(define (compiler-check-semantic-index-ok?) : bool
  (let
    [path : String "tests/semantic_index_entry.tl"]
    [source : String
      "(module semantic.demo)
(defstruct Pair (left i64))
(define answer : i64 42)
(define (use [answer : i64]) : i64 answer)"]
    (match (compiler-check-source-index-with-roots path source (svec.new))
      [(ResultCompilerCheckWithSemanticIndex.Ok _ first)
        (let
          [answer-index : i64
            (compiler-semantic-source-index-find-definition
              (& first)
              path
              "answer")]
          [use-index : i64
            (compiler-semantic-source-index-find-definition
              (& first)
              path
              "use")]
          [pair-index : i64
            (compiler-semantic-source-index-find-definition
              (& first)
              path
              "Pair")]
          [first-len : i64 (compiler-semantic-source-index-len (& first))]
          (if (or (< answer-index 0) (< use-index 0) (< pair-index 0))
            (begin
              (compiler-semantic-source-index-release! (&mut first))
              false)
            (let
              [answer : CompilerSemanticRecord
                (compiler-semantic-source-index-get (& first) answer-index)]
              [use : CompilerSemanticRecord
                (compiler-semantic-source-index-get (& first) use-index)]
              [pair : CompilerSemanticRecord
                (compiler-semantic-source-index-get (& first) pair-index)]
              [answer-symbol : CompilerSemanticSymbolId
                (struct-get answer symbol)]
              [answer-start : i64
                (struct-get (struct-get answer span) start-byte)]
              (match (compiler-check-source-index-with-roots
                path
                source
                (svec.new))
                [(ResultCompilerCheckWithSemanticIndex.Ok _ second)
                  (let
                    [second-answer-index : i64
                      (compiler-semantic-source-index-find-definition
                        (& second)
                        path
                        "answer")]
                    [second-answer : CompilerSemanticRecord
                      (compiler-semantic-source-index-get
                        (& second)
                        second-answer-index)]
                    [second-symbol : CompilerSemanticSymbolId
                      (struct-get second-answer symbol)]
                    [invalid-keeps-first : bool
                      (match (compiler-check-source-index-with-roots
                        path
                        "(define broken : i64 true)"
                        (svec.new))
                        [(ResultCompilerCheckWithSemanticIndex.Ok _ replacement)
                          (begin
                            (compiler-semantic-source-index-release!
                              (&mut replacement))
                            false)]
                        [(ResultCompilerCheckWithSemanticIndex.Err _) true])]
                    [ok : bool
                      (and
                        (compiler-semantic-source-index-complete? (& first))
                        (compiler-check-semantic-index-record-ok?
                          source
                          answer
                          "answer"
                          CompilerSemanticSymbolKind.Value)
                        (compiler-check-semantic-index-record-ok?
                          source
                          use
                          "use"
                          CompilerSemanticSymbolKind.Function)
                        (compiler-check-semantic-index-record-ok?
                          source
                          pair
                          "Pair"
                          CompilerSemanticSymbolKind.Struct)
                        (> (struct-get answer module-id) 0)
                        (=
                          (struct-get answer-symbol module-id)
                          (struct-get second-symbol module-id))
                        (=
                          (struct-get answer-symbol declaration-ordinal)
                          (struct-get second-symbol declaration-ordinal))
                        (=
                          answer-start
                          (struct-get
                            (struct-get second-answer span)
                            start-byte))
                        invalid-keeps-first
                        (=
                          (compiler-semantic-source-index-len (& first))
                          first-len)
                        (string.eq (struct-get answer display-name) "answer"))]
                    (begin
                      (compiler-semantic-source-index-release! (&mut second))
                      (compiler-semantic-source-index-release! (&mut first))
                      (and
                        ok
                        (= (compiler-semantic-source-index-len (& first)) 0)
                        (= (compiler-semantic-source-index-len (& second)) 0))))]
                [(ResultCompilerCheckWithSemanticIndex.Err _)
                  (begin
                    (compiler-semantic-source-index-release! (&mut first))
                    false)]))))]
      [(ResultCompilerCheckWithSemanticIndex.Err _) false])))

(define (compiler-check-self-test) : i64
  (begin
    (unless
      (= (compiler-load-self-test) 42)
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
      (compiler-check-runtime-stdlib-boundary-ok?)
      (return
        (io.panic "compiler-check: runtime stdlib boundary smoke mismatch")))
    (unless
      (compiler-check-private-dynamic-buffer-vector-ok?)
      (return
        (io.panic
          "compiler-check: private dynamic-buffer vector smoke mismatch")))
    (unless
      (compiler-check-private-dynamic-buffer-public-rejected-ok?)
      (return
        (io.panic
          "compiler-check: private dynamic-buffer public smoke mismatch")))
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
      (compiler-check-semantic-index-ok?)
      (return (io.panic "compiler-check: semantic index smoke mismatch")))
    42))