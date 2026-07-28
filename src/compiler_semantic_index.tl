;; compiler_semantic_index.tl - Owned semantic source index for compiler tooling.
(import stdlib.io)
(import stdlib.arena)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import "compiler_check_core.tl")

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
              (compiler-check-diagnostic-with-fallback-path
                (compiler-diagnostic-list-first (box-get diag))
                path))))])))

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