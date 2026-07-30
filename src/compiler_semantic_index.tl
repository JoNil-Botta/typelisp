;; compiler_semantic_index.tl - Owned semantic source index for compiler tooling.
(import stdlib.io)
(import stdlib.arena)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import (option.option i64) as option_i64)
(import "compiler_check_core.tl")

;; Tool-facing semantic data is copied into an explicitly owned arena. None of
;; these records retain TcContext, TcTypeEnv, parser sidecars, or intern-pool
;; strings, so a later check can reset compiler state without invalidating a
;; caller's last-good index.
;; Top-level symbols use local-ordinal -1 and their resolved compiler-symbol
;; handle index as declaration-ordinal. Lexical symbols use a deterministic
;; per-declaration local ordinal, so shadowed spellings remain distinct while
;; definition and use records share one identity.
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
  ;; Empty only when the checked walk cannot reproduce a reliable local type
  ;; fact. Successful inferred lets, patterns, and resources are retained.
  (resolved-type String)
  ;; Adjacent `;:` and `;#` lines are attached to top-level definitions.
  (documentation String)
  (module-id i64)
  (span CompilerSemanticSpan)
  (editable bool)
  (provenance CompilerSemanticProvenance))

(defstruct CompilerSemanticRecordVec
  (items (__tl_dyn-array CompilerSemanticRecord))
  (live (__tl_dyn-array bool))
  (len i64))

(defstruct CompilerSemanticSourceIndex
  (owner-arena i64)
  (records (__tl_dyn-array CompilerSemanticRecord))
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

(defenum CompilerSemanticMaybeSpan
  (Some AstSourceSpan)
  (None))

(defenum CompilerSemanticMaybeHandle
  (Some i64)
  (None))

(defstruct CompilerSemanticBinding
  (name-id i64)
  (symbol CompilerSemanticSymbolId)
  (kind CompilerSemanticSymbolKind)
  (display-name String)
  (resolved-type String))

(defenum CompilerSemanticBindingList
  (Nil)
  (Cons CompilerSemanticBinding (Box CompilerSemanticBindingList)))

(defenum CompilerSemanticMaybeBinding
  (Some CompilerSemanticBinding)
  (None))

(defstruct CompilerSemanticBindResult
  (scope CompilerSemanticBindingList)
  (env TcTypeEnv)
  (next-search i64))

(defstruct CompilerSemanticWalkState
  (ctx TcContext)
  (top-env TcTypeEnv)
  (path String)
  (source String)
  (form-start i64)
  (module-id i64)
  (declaration-ordinal i64)
  (generated bool)
  (provenance CompilerSemanticProvenance)
  (records (Box CompilerSemanticRecordVec))
  (visited-expr-ids (__tl_dyn-array i64))
  (next-local-ordinal (Box i64)))

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
    (array.make-array
      bool
      (if (< capacity 1)
        1
        capacity))
    0))

(define (compiler-semantic-record-vec-grow!
  [records : (&mut records CompilerSemanticRecordVec)]) : unit
  (let
    [old-items : (__tl_dyn-array CompilerSemanticRecord)
      (struct-get records items)]
    [old-live : (__tl_dyn-array bool) (struct-get records live)]
    [old-capacity : i64 (array-length old-items)]
    [new-capacity : i64
      (if (< old-capacity 1)
        1
        (* old-capacity 2))]
    [new-items : (__tl_dyn-array CompilerSemanticRecord)
      (array.make-array CompilerSemanticRecord new-capacity)]
    [new-live : (__tl_dyn-array bool) (array.make-array bool new-capacity)]
    [index : i64 0]
    (begin
      (while (< index (struct-get records len))
        (let
          [taken : (Tuple bool CompilerSemanticRecord)
            (array-take! old-items old-live index)]
          (begin
            (if (tuple-ref taken 0)
              (begin
                (array-set! new-items index (tuple-ref taken 1))
                (array-set! new-live index true))
              unit)
            (set! index (+ index 1)))))
      (set! (struct-get records items) new-items)
      (set! (struct-get records live) new-live))))

(define (compiler-semantic-record-vec-push!
  [records : (&mut records CompilerSemanticRecordVec)]
  [record : CompilerSemanticRecord]) : unit
  (begin
    (if (>= (struct-get records len) (array-length (struct-get records items)))
      (compiler-semantic-record-vec-grow! records)
      unit)
    (let
      [index : i64 (struct-get records len)]
      (begin
        (array-set! (struct-get records items) index record)
        (array-set! (struct-get records live) index true)
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

(define (compiler-semantic-single-quote-end
  [source : String]
  [start : i64]
  [limit : i64]) : i64
  (cond
    [(and
        (<= (+ start 2) limit)
        (not (= (string.string-ref source (+ start 1)) '\\'))
        (= (string.string-ref source (+ start 2)) '\''))
      (+ start 2)]
    [(and
        (<= (+ start 3) limit)
        (= (string.string-ref source (+ start 1)) '\\')
        (= (string.string-ref source (+ start 3)) '\''))
      (+ start 3)]
    [else -1]))

(define (compiler-semantic-double-quote-end
  [source : String]
  [start : i64]
  [limit : i64]) : i64
  (let
    [cursor : i64 (+ start 1)]
    [escaped : bool false]
    [done : bool false]
    (begin
      (while (and (not done) (< cursor limit))
        (let
          [current : char (string.string-ref source cursor)]
          (begin
            (set! cursor (+ cursor 1))
            (if (and (not escaped) (= current '"'))
              (set! done true)
              (set! escaped (and (not escaped) (= current '\\')))))))
      cursor)))

(define (compiler-semantic-name-offset-in-range
  [source : String]
  [name : String]
  [start : i64]
  [limit : i64]) : i64
  (let
    [cursor : i64
      (if (< start 0)
        0
        start)]
    [bounded-limit : i64
      (if (> limit (string.string-length source))
        (string.string-length source)
        limit)]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (< cursor bounded-limit))
        (let
          [current : char (string.string-ref source cursor)]
          (cond
            [(= current ';')
              (begin
                (while (and
                  (< cursor bounded-limit)
                  (not (= (string.string-ref source cursor) '\n')))
                  (set! cursor (+ cursor 1)))
                (set! cursor (+ cursor 1)))]
            [(= current '"')
              (set!
                cursor
                (compiler-semantic-double-quote-end source cursor bounded-limit))]
            [(= current '\'')
              (let
                [char-end : i64
                  (compiler-semantic-single-quote-end
                    source
                    cursor
                    (- bounded-limit 1))]
                (if (>= char-end 0)
                  (set! cursor (+ char-end 1))
                  (set! cursor (+ cursor 1))))]
            [(compiler-semantic-source-name-at?
                source
                name
                cursor
                bounded-limit)
              (set! found cursor)]
            [else (set! cursor (+ cursor 1))])))
      found)))

(define (compiler-semantic-top-level-form-start
  [source : String]
  [before : i64]
  [search-start : i64]) : i64
  (let
    [source-len : i64 (string.string-length source)]
    [limit : i64
      (cond
        [(= source-len 0) -1]
        [(< before 0) 0]
        [(< before source-len) before]
        [else (- source-len 1)])]
    [cursor : i64
      (if (and (>= search-start 0) (<= search-start limit))
        search-start
        0)]
    [depth : i64 0]
    [found : i64 0]
    (begin
      (while (<= cursor limit)
        (let
          [current : char (string.string-ref source cursor)]
          (cond
            [(= current ';')
              (begin
                (while (and
                  (<= cursor limit)
                  (not (= (string.string-ref source cursor) '\n')))
                  (set! cursor (+ cursor 1)))
                (set! cursor (+ cursor 1)))]
            [(= current '"')
              (set!
                cursor
                (compiler-semantic-double-quote-end source cursor (+ limit 1)))]
            [(= current '\'')
              (let
                [char-end : i64
                  (compiler-semantic-single-quote-end source cursor limit)]
                (if (>= char-end 0)
                  (set! cursor (+ char-end 1))
                  (set! cursor (+ cursor 1))))]
            [(= current '(')
              (begin
                (if (= depth 0)
                  (set! found cursor)
                  unit)
                (set! depth (+ depth 1))
                (set! cursor (+ cursor 1)))]
            [(= current ')')
              (begin
                (if (> depth 0)
                  (set! depth (- depth 1))
                  unit)
                (set! cursor (+ cursor 1)))]
            [else (set! cursor (+ cursor 1))])))
      found)))

(define (compiler-semantic-definition-span
  [path : String]
  [source : String]
  [name : String]
  [origin : AstSourceSpan]
  [form-start : i64]) : CompilerSemanticSpan
  (let
    [start : i64
      (if (>= form-start 0)
        form-start
        0)]
    [end : i64
      (compiler-semantic-source-offset
        source
        (ast-source-span-end-line origin)
        (ast-source-span-end-col origin))]
    [found : i64 (compiler-semantic-name-offset-in-range source name start end)]
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
          (ast-source-span line col line (+ col name-len)))))))

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
  [name-id : i64]
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
          (compiler-semantic-decl-type
            ctx
            env
            (box-get inner)
            kind
            name-id
            name)]
        [_ "macro"])]
    [_
      (match (tc-lookup-visible-id ctx env name-id)
        [(ResultTcType.Ok ty) (tc-type-render ty)]
        [(ResultTcType.Err _)
          (match (tc-top-decl-type ctx decl)
            [(ResultTcType.Ok ty) (tc-type-render ty)]
            [(ResultTcType.Err _) ""])])]))

(define (compiler-semantic-decl-provenance [decl : AstDecl]) : CompilerSemanticProvenance
  (match (ast-decl-generated-meta decl)
    [(AstGeneratedDeclMeta.No) CompilerSemanticProvenance.EditableSource]
    [(AstGeneratedDeclMeta.Some generator item _ key)
      (CompilerSemanticProvenance.Generated
        (string.copy (& generator))
        (string.copy (& item))
        (string.copy (& key)))]))

(define (compiler-semantic-use-span-from-origin
  [path : String]
  [source : String]
  [origin : AstSourceSpan]) : CompilerSemanticSpan
  (let
    [start : i64
      (compiler-semantic-source-offset
        source
        (ast-source-span-start-line origin)
        (ast-source-span-start-col origin))]
    [end : i64 start]
    [source-len : i64 (string.string-length source)]
    (begin
      (while (and
        (< end source-len)
        (not (compiler-semantic-delimiter? (string.string-ref source end))))
        (set! end (+ end 1)))
      (let
        [start-position : AstSourceSpan
          (compiler-semantic-source-position source start)]
        [end-position : AstSourceSpan
          (compiler-semantic-source-position source end)]
        (CompilerSemanticSpan
          (string.copy (& path))
          start
          end
          (ast-source-span
            (ast-source-span-start-line start-position)
            (ast-source-span-start-col start-position)
            (ast-source-span-start-line end-position)
            (ast-source-span-start-col end-position)))))))

(define (compiler-semantic-name-span-in-range
  [path : String]
  [source : String]
  [name : String]
  [start : i64]
  [limit : i64]) : CompilerSemanticSpan
  (let
    [bounded-limit : i64
      (if (> limit (string.string-length source))
        (string.string-length source)
        limit)]
    [found : i64
      (compiler-semantic-name-offset-in-range source name start bounded-limit)]
    (if (< found 0)
      (CompilerSemanticSpan
        (string.copy (& path))
        -1
        -1
        (ast-source-span 1 1 1 1))
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
          (ast-source-span line col line (+ col name-len)))))))

(define (compiler-semantic-form-head-end [source : String] [start : i64]) : i64
  (let
    [cursor : i64
      (if (< start 0)
        0
        start)]
    [len : i64 (string.string-length source)]
    (begin
      (while (and
        (< cursor len)
        (or
          (= (string.string-ref source cursor) '(')
          (= (string.string-ref source cursor) ' ')
          (= (string.string-ref source cursor) '\t')
          (= (string.string-ref source cursor) '\r')
          (= (string.string-ref source cursor) '\n')))
        (set! cursor (+ cursor 1)))
      (while (and
        (< cursor len)
        (not (compiler-semantic-delimiter? (string.string-ref source cursor))))
        (set! cursor (+ cursor 1)))
      cursor)))

(define (compiler-semantic-binding-clause-end
  [source : String]
  [start : i64]
  [limit : i64]) : i64
  (let
    [cursor : i64 start]
    [depth : i64 1]
    [bounded-limit : i64
      (if (> limit (string.string-length source))
        (string.string-length source)
        limit)]
    (begin
      (while (and (> depth 0) (< cursor bounded-limit))
        (begin
          (cond
            [(= (string.string-ref source cursor) '[') (set! depth (+ depth 1))]
            [(= (string.string-ref source cursor) ']') (set! depth (- depth 1))]
            [else unit])
          (set! cursor (+ cursor 1))))
      cursor)))

(define (compiler-semantic-line-start-before [source : String] [position : i64]) : i64
  (let
    [cursor : i64 position]
    (begin
      (while (and
        (> cursor 0)
        (not (= (string.string-ref source (- cursor 1)) '\n')))
        (set! cursor (- cursor 1)))
      cursor)))

(define (compiler-semantic-doc-comment-line?
  [source : String]
  [line-start : i64]) : bool
  (let
    [cursor : i64 line-start]
    [len : i64 (string.string-length source)]
    (begin
      (while (and
        (< cursor len)
        (or
          (= (string.string-ref source cursor) ' ')
          (= (string.string-ref source cursor) '\t')))
        (set! cursor (+ cursor 1)))
      (and
        (< (+ cursor 1) len)
        (= (string.string-ref source cursor) ';')
        (or
          (= (string.string-ref source (+ cursor 1)) ':')
          (= (string.string-ref source (+ cursor 1)) '#'))))))

(define (compiler-semantic-doc-comment-text
  [source : String]
  [line-start : i64]) : String
  (let
    [cursor : i64 line-start]
    [len : i64 (string.string-length source)]
    (begin
      (while (and
        (< cursor len)
        (or
          (= (string.string-ref source cursor) ' ')
          (= (string.string-ref source cursor) '\t')))
        (set! cursor (+ cursor 1)))
      (set! cursor (+ cursor 2))
      (if (and (< cursor len) (= (string.string-ref source cursor) ' '))
        (set! cursor (+ cursor 1))
        unit)
      (let
        [end : i64 cursor]
        (begin
          (while (and (< end len) (not (= (string.string-ref source end) '\n')))
            (set! end (+ end 1)))
          (string.substring source cursor (- end cursor)))))))

(define (compiler-semantic-documentation-above
  [source : String]
  [form-start : i64]) : String
  (let
    [line-start : i64 (compiler-semantic-line-start-before source form-start)]
    [documentation : String ""]
    [done : bool false]
    (begin
      (while (and (> line-start 0) (not done))
        (let
          [previous : i64
            (compiler-semantic-line-start-before source (- line-start 1))]
          (if (compiler-semantic-doc-comment-line? source previous)
            (begin
              (set!
                documentation
                (if (string.eq documentation "")
                  (compiler-semantic-doc-comment-text source previous)
                  (string.concat3
                    (compiler-semantic-doc-comment-text source previous)
                    "\n"
                    documentation)))
              (set! line-start previous))
            (set! done true))))
      documentation)))

(define (compiler-semantic-decl-handle
  [ctx : TcContext]
  [module-id : i64]
  [name-id : i64]
  [kind : CompilerSemanticSymbolKind]) : CompilerSemanticMaybeHandle
  (let
    [symbols : CompilerSymbols (tc-context-symbols ctx)]
    (match kind
      [(CompilerSemanticSymbolKind.Struct)
        (match (compiler-symbols-lookup-type-in-module-id
          symbols
          module-id
          name-id)
          [(option_i64.Some handle) (CompilerSemanticMaybeHandle.Some handle)]
          [(option_i64.None) CompilerSemanticMaybeHandle.None])]
      [(CompilerSemanticSymbolKind.Enum)
        (match (compiler-symbols-lookup-type-in-module-id
          symbols
          module-id
          name-id)
          [(option_i64.Some handle) (CompilerSemanticMaybeHandle.Some handle)]
          [(option_i64.None) CompilerSemanticMaybeHandle.None])]
      [(CompilerSemanticSymbolKind.Macro)
        (match (compiler-symbols-lookup-macro-in-module-id
          symbols
          module-id
          name-id)
          [(option_i64.Some handle) (CompilerSemanticMaybeHandle.Some handle)]
          [(option_i64.None) CompilerSemanticMaybeHandle.None])]
      [_
        (match (compiler-symbols-lookup-value-in-module-id
          symbols
          module-id
          name-id)
          [(option_i64.Some handle) (CompilerSemanticMaybeHandle.Some handle)]
          [(option_i64.None) CompilerSemanticMaybeHandle.None])])))

(define (compiler-semantic-use-handle [ctx : TcContext] [lookup-id : i64]) : CompilerSemanticMaybeHandle
  (let
    [symbols : CompilerSymbols (tc-context-symbols ctx)]
    (match (compiler-symbols-lookup-value-id symbols lookup-id)
      [(option_i64.Some handle) (CompilerSemanticMaybeHandle.Some handle)]
      [(option_i64.None)
        (match (compiler-symbols-lookup-macro-id symbols lookup-id)
          [(option_i64.Some handle) (CompilerSemanticMaybeHandle.Some handle)]
          [(option_i64.None)
            (match (compiler-symbols-lookup-type-id symbols lookup-id)
              [(option_i64.Some handle)
                (CompilerSemanticMaybeHandle.Some handle)]
              [(option_i64.None) CompilerSemanticMaybeHandle.None])])])))

(define (compiler-semantic-handle-module-id [ctx : TcContext] [handle : i64]) : i64
  (let
    [index : i64 (compiler-symbol-handle-index handle)]
    [owners : (__tl_dyn-array i64)
      (compiler-symbols-owner-module-ids (tc-context-symbols ctx))]
    (if (and (>= index 0) (< index (array-length owners)))
      (array-ref owners index)
      cbi.compiler-builtin-id-fix-empty)))

(define (compiler-semantic-handle-decl [ctx : TcContext] [handle : i64]) : AstDecl
  (let
    [index : i64 (compiler-symbol-handle-index handle)]
    [decls : (__tl_dyn-array AstDecl)
      (compiler-symbols-decls (tc-context-symbols ctx))]
    (if (and (>= index 0) (< index (array-length decls)))
      (array-ref decls index)
      (ast-decl-fallback))))

(define (compiler-semantic-symbol-for-decl
  [ctx : TcContext]
  [module-id : i64]
  [fallback-ordinal : i64]
  [name-id : i64]
  [kind : CompilerSemanticSymbolKind]) : CompilerSemanticSymbolId
  (match (compiler-semantic-decl-handle ctx module-id name-id kind)
    [(CompilerSemanticMaybeHandle.Some handle)
      (CompilerSemanticSymbolId
        (compiler-semantic-handle-module-id ctx handle)
        (compiler-symbol-handle-index handle)
        -1)]
    [(CompilerSemanticMaybeHandle.None)
      (CompilerSemanticSymbolId module-id fallback-ordinal -1)]))

(define (compiler-semantic-binding-lookup
  [scope : CompilerSemanticBindingList]
  [name-id : i64]) : CompilerSemanticMaybeBinding
  (match scope
    [(CompilerSemanticBindingList.Nil) CompilerSemanticMaybeBinding.None]
    [(CompilerSemanticBindingList.Cons binding rest)
      (if (= (struct-get binding name-id) name-id)
        (CompilerSemanticMaybeBinding.Some binding)
        (compiler-semantic-binding-lookup (box-get rest) name-id))]))

(define (compiler-semantic-record-use-with-binding!
  [state : CompilerSemanticWalkState]
  [binding : CompilerSemanticBinding]
  [span : CompilerSemanticSpan]) : unit
  (compiler-semantic-record-vec-push!
    (&mut (box-get (struct-get state records)))
    (CompilerSemanticRecord
      (struct-get binding symbol)
      CompilerSemanticRecordRole.Use
      (struct-get binding kind)
      (string.copy (& (struct-get binding display-name)))
      (string.copy (& (struct-get binding resolved-type)))
      ""
      (struct-get (struct-get binding symbol) module-id)
      span
      (and
        (not (struct-get state generated))
        (>= (struct-get span start-byte) 0))
      (struct-get state provenance))))

(define (compiler-semantic-record-top-use!
  [state : CompilerSemanticWalkState]
  [name-id : i64]
  [span : CompilerSemanticSpan]) : unit
  (let
    [ctx : TcContext (struct-get state ctx)]
    [env : TcTypeEnv (struct-get state top-env)]
    [name : String (tc-hygiene-name-text-id name-id)]
    (match (tc-source-name-lookup-key-with-field-check-lookup
      ctx
      env
      name
      name-id
      true)
      [(TcNameLookup.Ok _ lookup-id)
        (match (compiler-semantic-use-handle ctx lookup-id)
          [(CompilerSemanticMaybeHandle.Some handle)
            (let
              [decl : AstDecl (compiler-semantic-handle-decl ctx handle)]
              (match (compiler-semantic-decl-symbol decl)
                [(CompilerSemanticMaybeDecl.Some decl-name-id kind)
                  (let
                    [module-id : i64
                      (compiler-semantic-handle-module-id ctx handle)]
                    [decl-ctx : TcContext
                      (if (= module-id cbi.compiler-builtin-id-fix-empty)
                        (tc-context-with-module-id
                          ctx
                          ""
                          cbi.compiler-builtin-id-fix-empty)
                        (tc-context-with-module-id
                          ctx
                          (macro-decl-module-display module-id)
                          module-id))]
                    [display-name : String (tc-env-key-name-text decl-name-id)]
                    [type-text : String
                      (match (tc-lookup-visible-id ctx env lookup-id)
                        [(ResultTcType.Ok ty) (tc-type-render ty)]
                        [(ResultTcType.Err _)
                          (compiler-semantic-decl-type
                            decl-ctx
                            env
                            decl
                            kind
                            decl-name-id
                            display-name)])]
                    (compiler-semantic-record-vec-push!
                      (&mut (box-get (struct-get state records)))
                      (CompilerSemanticRecord
                        (CompilerSemanticSymbolId
                          module-id
                          (compiler-symbol-handle-index handle)
                          -1)
                        CompilerSemanticRecordRole.Use
                        kind
                        (string.copy (& display-name))
                        (string.copy (& type-text))
                        ""
                        module-id
                        span
                        (and
                          (not (struct-get state generated))
                          (>= (struct-get span start-byte) 0))
                        (struct-get state provenance))))]
                [(CompilerSemanticMaybeDecl.None) unit]))]
          [(CompilerSemanticMaybeHandle.None) unit])]
      [(TcNameLookup.Err _) unit])))

(define (compiler-semantic-record-name-use!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingList]
  [name-id : i64]
  [maybe-span : CompilerSemanticMaybeSpan]) : unit
  (let
    [span : CompilerSemanticSpan
      (match maybe-span
        [(CompilerSemanticMaybeSpan.Some origin)
          (if (string.eq (struct-get state source) "")
            (CompilerSemanticSpan
              (string.copy (& (struct-get state path)))
              -1
              -1
              origin)
            (compiler-semantic-use-span-from-origin
              (struct-get state path)
              (struct-get state source)
              origin))]
        [(CompilerSemanticMaybeSpan.None)
          (CompilerSemanticSpan
            (string.copy (& (struct-get state path)))
            -1
            -1
            (ast-source-span 1 1 1 1))])]
    (match (compiler-semantic-binding-lookup scope name-id)
      [(CompilerSemanticMaybeBinding.Some binding)
        (compiler-semantic-record-use-with-binding! state binding span)]
      [(CompilerSemanticMaybeBinding.None)
        (compiler-semantic-record-top-use! state name-id span)])))

(define (compiler-semantic-record-name-use-span!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingList]
  [name-id : i64]
  [span : CompilerSemanticSpan]) : unit
  (match (compiler-semantic-binding-lookup scope name-id)
    [(CompilerSemanticMaybeBinding.Some binding)
      (compiler-semantic-record-use-with-binding! state binding span)]
    [(CompilerSemanticMaybeBinding.None)
      (compiler-semantic-record-top-use! state name-id span)]))

(define (compiler-semantic-bind-local!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingList]
  [env : TcTypeEnv]
  [name-id : i64]
  [kind : CompilerSemanticSymbolKind]
  [maybe-ty : AstMaybeType]
  [search-start : i64]
  [search-limit : i64]) : CompilerSemanticBindResult
  (let
    [name : String (tc-env-key-name-text name-id)]
    [binding-ty : AstType
      (match maybe-ty
        [(AstMaybeType.Some ty) ty]
        [(AstMaybeType.No) (AstType.Unit)])]
    [type-text : String
      (match maybe-ty
        [(AstMaybeType.Some ty) (tc-type-render ty)]
        [(AstMaybeType.No) ""])]
    [local-ordinal : i64 (box-get (struct-get state next-local-ordinal))]
    [symbol : CompilerSemanticSymbolId
      (CompilerSemanticSymbolId
        (struct-get state module-id)
        (struct-get state declaration-ordinal)
        local-ordinal)]
    [span : CompilerSemanticSpan
      (if (or
        (struct-get state generated)
        (string.eq (struct-get state source) ""))
        (CompilerSemanticSpan
          (string.copy (& (struct-get state path)))
          -1
          -1
          (ast-source-span 1 1 1 1))
        (compiler-semantic-name-span-in-range
          (struct-get state path)
          (struct-get state source)
          name
          search-start
          search-limit))]
    [binding : CompilerSemanticBinding
      (CompilerSemanticBinding
        name-id
        symbol
        kind
        (string.copy (& name))
        (string.copy (& type-text)))]
    (begin
      (set! (box-get (struct-get state next-local-ordinal)) (+ local-ordinal 1))
      (compiler-semantic-record-vec-push!
        (&mut (box-get (struct-get state records)))
        (CompilerSemanticRecord
          symbol
          CompilerSemanticRecordRole.Definition
          kind
          (string.copy (& name))
          (string.copy (& type-text))
          ""
          (struct-get state module-id)
          span
          (and
            (not (struct-get state generated))
            (>= (struct-get span start-byte) 0))
          (struct-get state provenance)))
      (CompilerSemanticBindResult
        (CompilerSemanticBindingList.Cons binding (box scope))
        (tc-bind-id env name-id binding-ty)
        (if (>= (struct-get span end-byte) 0)
          (struct-get span end-byte)
          search-start)))))

(define (compiler-semantic-bind-checked-let!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingList]
  [env : TcTypeEnv]
  [bindings : (& bindings AstLetBindingList)]
  [binding-index : i64]
  [body-id : i64]
  [name-id : i64]
  [maybe-ty : AstMaybeType]
  [init-id : i64]
  [search-start : i64]
  [search-limit : i64]) : CompilerSemanticBindResult
  (let
    [ctx : TcContext (struct-get state ctx)]
    [expr-bases : i64 (tc-context-expr-bases ctx)]
    [init : AstExpr (ast-expr-segment-bases-get expr-bases init-id)]
    [body : AstExpr (ast-expr-segment-bases-get expr-bases body-id)]
    (match (tc-let-binding-init-type-at
      ctx
      env
      (tc-env-key-name-text name-id)
      maybe-ty
      init-id
      bindings
      (+ binding-index 1)
      body)
      [(ResultTcType.Ok init-ty)
        (let
          [resolved-maybe-ty : AstMaybeType
            (tc-let-binding-resolve-maybe-type ctx maybe-ty)]
          [binding-ty : AstType
            (tc-let-binding-plain-bind-type ctx resolved-maybe-ty init-ty)]
          [recorded-maybe-ty : AstMaybeType
            (match resolved-maybe-ty
              [(AstMaybeType.Some ty) (AstMaybeType.Some ty)]
              [(AstMaybeType.No)
                (AstMaybeType.Some (tc-resolve-type ctx binding-ty))])]
          [bound : CompilerSemanticBindResult
            (compiler-semantic-bind-local!
              state
              scope
              env
              name-id
              CompilerSemanticSymbolKind.Local
              recorded-maybe-ty
              search-start
              search-limit)]
          (CompilerSemanticBindResult
            (struct-get bound scope)
            ;; Reproduce the successful checker's special arena-owner,
            ;; arena-phase, and raw C function-pointer binding transition so a
            ;; later inferred binding sees the same exact lexical environment.
            (tc-bind-c-abi-fnptr-if-needed-id ctx env name-id binding-ty init)
            (struct-get bound next-search)))]
      [(ResultTcType.Err _)
        ;; A complete check reached this walk successfully, so this is only a
        ;; fail-closed fallback for facts the replay cannot reproduce.
        (compiler-semantic-bind-local!
          state
          scope
          env
          name-id
          CompilerSemanticSymbolKind.Local
          (tc-let-binding-resolve-maybe-type ctx maybe-ty)
          search-start
          search-limit)])))

(define (compiler-semantic-expr-start-offset
  [state : CompilerSemanticWalkState]
  [expr-id : i64]
  [fallback : i64]) : i64
  (match (tc-expr-id-maybe-span expr-id)
    [(TcMaybeAstSourceSpan.Some span)
      (compiler-semantic-source-offset
        (struct-get state source)
        (ast-source-span-start-line span)
        (ast-source-span-start-col span))]
    [(TcMaybeAstSourceSpan.No) fallback]))

(define (compiler-semantic-expr-end-offset
  [state : CompilerSemanticWalkState]
  [expr-id : i64]
  [fallback : i64]) : i64
  (match (tc-expr-id-maybe-span expr-id)
    [(TcMaybeAstSourceSpan.Some span)
      (compiler-semantic-source-offset
        (struct-get state source)
        (ast-source-span-end-line span)
        (ast-source-span-end-col span))]
    [(TcMaybeAstSourceSpan.No) fallback]))

(define (compiler-semantic-maybe-span-start
  [state : CompilerSemanticWalkState]
  [maybe-span : CompilerSemanticMaybeSpan]
  [fallback : i64]) : i64
  (match maybe-span
    [(CompilerSemanticMaybeSpan.Some span)
      (compiler-semantic-source-offset
        (struct-get state source)
        (ast-source-span-start-line span)
        (ast-source-span-start-col span))]
    [(CompilerSemanticMaybeSpan.None) fallback]))

(define (compiler-semantic-bind-params!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingList]
  [env : TcTypeEnv]
  [params : AstParamList]
  [search-start : i64]
  [search-limit : i64]) : CompilerSemanticBindResult
  (let
    [next-scope : CompilerSemanticBindingList scope]
    [next-env : TcTypeEnv env]
    [cursor : i64 search-start]
    [index : i64 0]
    (begin
      (while (< index (ast-param-list-len (& params)))
        (begin
          (match (ast-param-list-get (& params) index (ast-param-fallback))
            [(AstParam.Param name ty _ _)
              (let
                [bound : CompilerSemanticBindResult
                  (compiler-semantic-bind-local!
                    state
                    next-scope
                    next-env
                    name
                    CompilerSemanticSymbolKind.Parameter
                    (AstMaybeType.Some
                      (tc-resolve-type (struct-get state ctx) ty))
                    cursor
                    search-limit)]
                (begin
                  (set! next-scope (struct-get bound scope))
                  (set! next-env (struct-get bound env))
                  (set!
                    cursor
                    (compiler-semantic-binding-clause-end
                      (struct-get state source)
                      (struct-get bound next-search)
                      search-limit))))])
          (set! index (+ index 1))))
      (CompilerSemanticBindResult next-scope next-env cursor))))

(define (compiler-semantic-bind-macro-params!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingList]
  [env : TcTypeEnv]
  [params : AstMacroParamList]
  [search-start : i64]
  [search-limit : i64]) : CompilerSemanticBindResult
  (let
    [next-scope : CompilerSemanticBindingList scope]
    [next-env : TcTypeEnv env]
    [cursor : i64 search-start]
    [index : i64 0]
    (begin
      (while (< index (ast-macro-param-list-len (& params)))
        (begin
          (match (ast-macro-param-list-get
            (& params)
            index
            (ast-macro-param-fallback))
            [(AstMacroParam.Param name ty _ _)
              (let
                [bound : CompilerSemanticBindResult
                  (compiler-semantic-bind-local!
                    state
                    next-scope
                    next-env
                    name
                    CompilerSemanticSymbolKind.Parameter
                    (AstMaybeType.Some
                      (tc-resolve-type (struct-get state ctx) ty))
                    cursor
                    search-limit)]
                (begin
                  (set! next-scope (struct-get bound scope))
                  (set! next-env (struct-get bound env))
                  (set!
                    cursor
                    (compiler-semantic-binding-clause-end
                      (struct-get state source)
                      (struct-get bound next-search)
                      search-limit))))])
          (set! index (+ index 1))))
      (CompilerSemanticBindResult next-scope next-env cursor))))

(define (compiler-semantic-walk-expr-list!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingList]
  [env : TcTypeEnv]
  [items : AstExprList]) : unit
  (let
    [index : i64 0]
    (while (< index (ast-expr-list-len (& items)))
      (begin
        (compiler-semantic-walk-node!
          state
          scope
          env
          (ast-expr-list-get (& items) index 0))
        (set! index (+ index 1))))))

(define (compiler-semantic-walk-quasiquote-list!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingList]
  [env : TcTypeEnv]
  [items : AstExprList]) : unit
  (let
    [index : i64 0]
    (while (< index (ast-expr-list-len (& items)))
      (begin
        (compiler-semantic-walk-quasiquote-node!
          state
          scope
          env
          (ast-expr-list-get (& items) index 0))
        (set! index (+ index 1))))))

(define (compiler-semantic-walk-quasiquote-let-bindings!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingList]
  [env : TcTypeEnv]
  [bindings : AstLetBindingList]) : unit
  (let
    [index : i64 0]
    (while (< index (ast-let-binding-list-len (& bindings)))
      (begin
        (match (ast-let-binding-list-get
          (& bindings)
          index
          (ast-let-binding-fallback))
          [(AstLetBinding.Binding _ _ init)
            (compiler-semantic-walk-quasiquote-node! state scope env init)])
        (set! index (+ index 1))))))

(define (compiler-semantic-walk-quasiquote-match-arms!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingList]
  [env : TcTypeEnv]
  [arms : AstMatchArmList]) : unit
  (let
    [index : i64 0]
    (while (< index (ast-match-arm-list-len (& arms)))
      (begin
        (match (ast-match-arm-list-get (& arms) index (ast-match-arm-fallback))
          [(AstMatchArm.Arm _ body)
            (compiler-semantic-walk-quasiquote-node! state scope env body)])
        (set! index (+ index 1))))))

(define (compiler-semantic-walk-quasiquote-resource-bindings!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingList]
  [env : TcTypeEnv]
  [bindings : AstResourceBindingList]) : unit
  (let
    [index : i64 0]
    (while (< index (ast-resource-binding-list-len (& bindings)))
      (begin
        (match (ast-resource-binding-list-get
          (& bindings)
          index
          (ast-resource-binding-fallback))
          [(AstResourceBinding.Binding _ init cleanup _)
            (begin
              (compiler-semantic-walk-quasiquote-node! state scope env init)
              (compiler-semantic-walk-quasiquote-node! state scope env cleanup))])
        (set! index (+ index 1))))))

(define (compiler-semantic-walk-quasiquote-node!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingList]
  [env : TcTypeEnv]
  [node-id : i64]) : unit
  (match (ast-node-get node-id)
    [(AstExpr.Spanned inner _)
      (compiler-semantic-walk-quasiquote-node! state scope env inner)]
    [(AstExpr.Unquote inner)
      (compiler-semantic-walk-node! state scope env inner)]
    [(AstExpr.UnquoteSplicing inner)
      (compiler-semantic-walk-node! state scope env inner)]
    [(AstExpr.Binary _ left right)
      (begin
        (compiler-semantic-walk-quasiquote-node! state scope env left)
        (compiler-semantic-walk-quasiquote-node! state scope env right))]
    [(AstExpr.Unary _ inner)
      (compiler-semantic-walk-quasiquote-node! state scope env inner)]
    [(AstExpr.Call callee args)
      (begin
        (compiler-semantic-walk-quasiquote-node! state scope env callee)
        (compiler-semantic-walk-quasiquote-list! state scope env args))]
    [(AstExpr.BracketClause items)
      (compiler-semantic-walk-quasiquote-list! state scope env items)]
    [(AstExpr.If condition then-expr else-expr)
      (begin
        (compiler-semantic-walk-quasiquote-node! state scope env condition)
        (compiler-semantic-walk-quasiquote-node! state scope env then-expr)
        (compiler-semantic-walk-quasiquote-node! state scope env else-expr))]
    [(AstExpr.Let payload)
      (match (box-get payload)
        [(AstLet.Let bindings body)
          (begin
            (compiler-semantic-walk-quasiquote-let-bindings!
              state
              scope
              env
              bindings)
            (compiler-semantic-walk-quasiquote-node! state scope env body))])]
    [(AstExpr.Lambda payload)
      (match (box-get payload)
        [(AstLambda.Lambda _ _ body)
          (compiler-semantic-walk-quasiquote-node! state scope env body)])]
    [(AstExpr.Tuple items)
      (compiler-semantic-walk-quasiquote-list! state scope env items)]
    [(AstExpr.TupleRef target _)
      (compiler-semantic-walk-quasiquote-node! state scope env target)]
    [(AstExpr.Array items)
      (compiler-semantic-walk-quasiquote-list! state scope env items)]
    [(AstExpr.DynArray items)
      (compiler-semantic-walk-quasiquote-list! state scope env items)]
    [(AstExpr.MakeArray _ size)
      (compiler-semantic-walk-quasiquote-node! state scope env size)]
    [(AstExpr.ArrayRef target index)
      (begin
        (compiler-semantic-walk-quasiquote-node! state scope env target)
        (compiler-semantic-walk-quasiquote-node! state scope env index))]
    [(AstExpr.ArraySet target index value)
      (begin
        (compiler-semantic-walk-quasiquote-node! state scope env target)
        (compiler-semantic-walk-quasiquote-node! state scope env index)
        (compiler-semantic-walk-quasiquote-node! state scope env value))]
    [(AstExpr.ArrayTake target live index)
      (begin
        (compiler-semantic-walk-quasiquote-node! state scope env target)
        (compiler-semantic-walk-quasiquote-node! state scope env live)
        (compiler-semantic-walk-quasiquote-node! state scope env index))]
    [(AstExpr.ArrayPush target value)
      (begin
        (compiler-semantic-walk-quasiquote-node! state scope env target)
        (compiler-semantic-walk-quasiquote-node! state scope env value))]
    [(AstExpr.StringRef target index)
      (begin
        (compiler-semantic-walk-quasiquote-node! state scope env target)
        (compiler-semantic-walk-quasiquote-node! state scope env index))]
    [(AstExpr.While condition body)
      (begin
        (compiler-semantic-walk-quasiquote-node! state scope env condition)
        (compiler-semantic-walk-quasiquote-node! state scope env body))]
    [(AstExpr.Begin items)
      (compiler-semantic-walk-quasiquote-list! state scope env items)]
    [(AstExpr.Unsafe items)
      (compiler-semantic-walk-quasiquote-list! state scope env items)]
    [(AstExpr.Set _ value)
      (compiler-semantic-walk-quasiquote-node! state scope env value)]
    [(AstExpr.Ann inner _)
      (compiler-semantic-walk-quasiquote-node! state scope env inner)]
    [(AstExpr.Cast inner _)
      (compiler-semantic-walk-quasiquote-node! state scope env inner)]
    [(AstExpr.Borrow _ _ inner)
      (compiler-semantic-walk-quasiquote-node! state scope env inner)]
    [(AstExpr.Match payload)
      (match (box-get payload)
        [(AstMatch.Match scrutinee arms)
          (begin
            (compiler-semantic-walk-quasiquote-node! state scope env scrutinee)
            (compiler-semantic-walk-quasiquote-match-arms! state scope env arms))])]
    [(AstExpr.Foreach payload)
      (match (box-get payload)
        [(AstForeach.Foreach _ _ start end body)
          (begin
            (compiler-semantic-walk-quasiquote-node! state scope env start)
            (compiler-semantic-walk-quasiquote-node! state scope env end)
            (compiler-semantic-walk-quasiquote-node! state scope env body))])]
    [(AstExpr.SpmdReduce payload)
      (match (box-get payload)
        [(AstSpmdReduce.Reduce _ _ _ start end init value)
          (begin
            (compiler-semantic-walk-quasiquote-node! state scope env start)
            (compiler-semantic-walk-quasiquote-node! state scope env end)
            (compiler-semantic-walk-quasiquote-node! state scope env init)
            (compiler-semantic-walk-quasiquote-node! state scope env value))])]
    [(AstExpr.SpmdScan payload)
      (match (box-get payload)
        [(AstSpmdScan.Scan _ _ _ start end _ _ init value body)
          (begin
            (compiler-semantic-walk-quasiquote-node! state scope env start)
            (compiler-semantic-walk-quasiquote-node! state scope env end)
            (compiler-semantic-walk-quasiquote-node! state scope env init)
            (compiler-semantic-walk-quasiquote-node! state scope env value)
            (compiler-semantic-walk-quasiquote-node! state scope env body))])]
    [(AstExpr.SpmdBroadcast value lane)
      (begin
        (compiler-semantic-walk-quasiquote-node! state scope env value)
        (compiler-semantic-walk-quasiquote-node! state scope env lane))]
    [(AstExpr.SpmdShuffle value lane)
      (begin
        (compiler-semantic-walk-quasiquote-node! state scope env value)
        (compiler-semantic-walk-quasiquote-node! state scope env lane))]
    [(AstExpr.StructGet target _)
      (compiler-semantic-walk-quasiquote-node! state scope env target)]
    [(AstExpr.StructSet target _ value)
      (begin
        (compiler-semantic-walk-quasiquote-node! state scope env target)
        (compiler-semantic-walk-quasiquote-node! state scope env value))]
    [(AstExpr.WithRegion _ body)
      (compiler-semantic-walk-quasiquote-list! state scope env body)]
    [(AstExpr.WithEscape scratch body)
      (begin
        (compiler-semantic-walk-quasiquote-node! state scope env scratch)
        (compiler-semantic-walk-quasiquote-list! state scope env body))]
    [(AstExpr.WithScratch body)
      (compiler-semantic-walk-quasiquote-list! state scope env body)]
    [(AstExpr.InArena arena body)
      (begin
        (compiler-semantic-walk-quasiquote-node! state scope env arena)
        (compiler-semantic-walk-quasiquote-list! state scope env body))]
    [(AstExpr.WithResource payload)
      (match (box-get payload)
        [(AstWithResource.WithResource bindings body)
          (begin
            (compiler-semantic-walk-quasiquote-resource-bindings!
              state
              scope
              env
              bindings)
            (compiler-semantic-walk-quasiquote-list! state scope env body))])]
    [(AstExpr.Box inner)
      (compiler-semantic-walk-quasiquote-node! state scope env inner)]
    [(AstExpr.BoxGet inner)
      (compiler-semantic-walk-quasiquote-node! state scope env inner)]
    [(AstExpr.BoxTake inner)
      (compiler-semantic-walk-quasiquote-node! state scope env inner)]
    [(AstExpr.BoxSet target value)
      (begin
        (compiler-semantic-walk-quasiquote-node! state scope env target)
        (compiler-semantic-walk-quasiquote-node! state scope env value))]
    [(AstExpr.Comptime inner)
      (compiler-semantic-walk-quasiquote-node! state scope env inner)]
    [(AstExpr.Try inner)
      (compiler-semantic-walk-quasiquote-node! state scope env inner)]
    [(AstExpr.Return inner)
      (compiler-semantic-walk-quasiquote-node! state scope env inner)]
    [(AstExpr.PtrNullCheck inner)
      (compiler-semantic-walk-quasiquote-node! state scope env inner)]
    [(AstExpr.PtrAddrOf inner)
      (compiler-semantic-walk-quasiquote-node! state scope env inner)]
    [(AstExpr.PtrRead inner)
      (compiler-semantic-walk-quasiquote-node! state scope env inner)]
    [(AstExpr.PtrWrite ptr value)
      (begin
        (compiler-semantic-walk-quasiquote-node! state scope env ptr)
        (compiler-semantic-walk-quasiquote-node! state scope env value))]
    [(AstExpr.PtrOffset ptr offset)
      (begin
        (compiler-semantic-walk-quasiquote-node! state scope env ptr)
        (compiler-semantic-walk-quasiquote-node! state scope env offset))]
    [(AstExpr.PtrCast ptr _)
      (compiler-semantic-walk-quasiquote-node! state scope env ptr)]
    [(AstExpr.PtrToInt ptr)
      (compiler-semantic-walk-quasiquote-node! state scope env ptr)]
    [(AstExpr.IntToPtr value _)
      (compiler-semantic-walk-quasiquote-node! state scope env value)]
    [(AstExpr.StringData value)
      (compiler-semantic-walk-quasiquote-node! state scope env value)]
    [(AstExpr.StringFromBytes data len)
      (begin
        (compiler-semantic-walk-quasiquote-node! state scope env data)
        (compiler-semantic-walk-quasiquote-node! state scope env len))]
    [(AstExpr.ArrayData value)
      (compiler-semantic-walk-quasiquote-node! state scope env value)]
    [(AstExpr.CpuIdEax leaf subleaf)
      (begin
        (compiler-semantic-walk-quasiquote-node! state scope env leaf)
        (compiler-semantic-walk-quasiquote-node! state scope env subleaf))]
    [(AstExpr.CpuIdEbx leaf subleaf)
      (begin
        (compiler-semantic-walk-quasiquote-node! state scope env leaf)
        (compiler-semantic-walk-quasiquote-node! state scope env subleaf))]
    [(AstExpr.CpuIdEcx leaf subleaf)
      (begin
        (compiler-semantic-walk-quasiquote-node! state scope env leaf)
        (compiler-semantic-walk-quasiquote-node! state scope env subleaf))]
    [(AstExpr.CpuIdEdx leaf subleaf)
      (begin
        (compiler-semantic-walk-quasiquote-node! state scope env leaf)
        (compiler-semantic-walk-quasiquote-node! state scope env subleaf))]
    [(AstExpr.Xgetbv index)
      (compiler-semantic-walk-quasiquote-node! state scope env index)]
    [(AstExpr.Syscall args)
      (compiler-semantic-walk-quasiquote-list! state scope env args)]
    [(AstExpr.Quote _) unit]
    ;; CTFE preserves a nested quasiquote wholesale. Its unquotes belong to
    ;; the future quasiquote evaluation rather than the surrounding macro.
    [(AstExpr.Quasiquote _) unit]
    [_ unit]))

(define (compiler-semantic-walk-let!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingList]
  [env : TcTypeEnv]
  [bindings : AstLetBindingList]
  [body-id : i64]
  [maybe-span : CompilerSemanticMaybeSpan]) : unit
  (let
    [next-scope : CompilerSemanticBindingList scope]
    [next-env : TcTypeEnv env]
    [form-start : i64 (compiler-semantic-maybe-span-start state maybe-span 0)]
    [cursor : i64
      (compiler-semantic-form-head-end (struct-get state source) form-start)]
    [body-start : i64
      (compiler-semantic-expr-start-offset
        state
        body-id
        (string.string-length (struct-get state source)))]
    [index : i64 0]
    (begin
      (while (< index (ast-let-binding-list-len (& bindings)))
        (begin
          (match (ast-let-binding-list-get
            (& bindings)
            index
            (ast-let-binding-fallback))
            [(AstLetBinding.Binding name maybe-ty init-id)
              (let
                [init-start : i64
                  (compiler-semantic-expr-start-offset state init-id body-start)]
                (begin
                  (compiler-semantic-walk-node!
                    state
                    next-scope
                    next-env
                    init-id)
                  (let
                    [bound : CompilerSemanticBindResult
                      (compiler-semantic-bind-checked-let!
                        state
                        next-scope
                        next-env
                        (& bindings)
                        index
                        body-id
                        name
                        maybe-ty
                        init-id
                        cursor
                        init-start)]
                    (begin
                      (set! next-scope (struct-get bound scope))
                      (set! next-env (struct-get bound env))
                      (set!
                        cursor
                        (compiler-semantic-expr-end-offset
                          state
                          init-id
                          (struct-get bound next-search)))))))])
          (set! index (+ index 1))))
      (compiler-semantic-walk-node! state next-scope next-env body-id))))

(define (compiler-semantic-walk-lambda!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingList]
  [env : TcTypeEnv]
  [params : AstParamList]
  [body-id : i64]
  [maybe-span : CompilerSemanticMaybeSpan]) : unit
  (let
    [form-start : i64 (compiler-semantic-maybe-span-start state maybe-span 0)]
    [body-start : i64
      (compiler-semantic-expr-start-offset
        state
        body-id
        (string.string-length (struct-get state source)))]
    [bound : CompilerSemanticBindResult
      (compiler-semantic-bind-params!
        state
        scope
        env
        params
        (compiler-semantic-form-head-end (struct-get state source) form-start)
        body-start)]
    (compiler-semantic-walk-node!
      state
      (struct-get bound scope)
      (struct-get bound env)
      body-id)))

(define (compiler-semantic-walk-foreach!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingList]
  [env : TcTypeEnv]
  [name : i64]
  [index-ty : AstType]
  [start-id : i64]
  [end-id : i64]
  [body-id : i64]
  [maybe-span : CompilerSemanticMaybeSpan]) : unit
  (begin
    (compiler-semantic-walk-node! state scope env start-id)
    (compiler-semantic-walk-node! state scope env end-id)
    (let
      [form-start : i64 (compiler-semantic-maybe-span-start state maybe-span 0)]
      [first-expr-start : i64
        (compiler-semantic-expr-start-offset
          state
          start-id
          (compiler-semantic-expr-start-offset
            state
            body-id
            (string.string-length (struct-get state source))))]
      [bound : CompilerSemanticBindResult
        (compiler-semantic-bind-local!
          state
          scope
          env
          name
          CompilerSemanticSymbolKind.Local
          (AstMaybeType.Some (tc-resolve-type (struct-get state ctx) index-ty))
          (compiler-semantic-form-head-end (struct-get state source) form-start)
          first-expr-start)]
      (compiler-semantic-walk-node!
        state
        (struct-get bound scope)
        (struct-get bound env)
        body-id))))

(define (compiler-semantic-walk-spmd-reduce!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingList]
  [env : TcTypeEnv]
  [index-name : i64]
  [index-ty : AstType]
  [start-id : i64]
  [end-id : i64]
  [init-id : i64]
  [value-id : i64]
  [maybe-span : CompilerSemanticMaybeSpan]) : unit
  (let
    [form-start : i64 (compiler-semantic-maybe-span-start state maybe-span 0)]
    [first-expr-start : i64
      (compiler-semantic-expr-start-offset
        state
        start-id
        (string.string-length (struct-get state source)))]
    [bound : CompilerSemanticBindResult
      (compiler-semantic-bind-local!
        state
        scope
        env
        index-name
        CompilerSemanticSymbolKind.Local
        (AstMaybeType.Some (tc-resolve-type (struct-get state ctx) index-ty))
        (compiler-semantic-form-head-end (struct-get state source) form-start)
        first-expr-start)]
    (begin
      (compiler-semantic-walk-node! state scope env start-id)
      (compiler-semantic-walk-node! state scope env end-id)
      (compiler-semantic-walk-node! state scope env init-id)
      (compiler-semantic-walk-node!
        state
        (struct-get bound scope)
        (struct-get bound env)
        value-id))))

(define (compiler-semantic-walk-spmd-scan!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingList]
  [env : TcTypeEnv]
  [index-name : i64]
  [index-ty : AstType]
  [start-id : i64]
  [end-id : i64]
  [prefix-name : i64]
  [prefix-ty : AstType]
  [init-id : i64]
  [value-id : i64]
  [body-id : i64]
  [maybe-span : CompilerSemanticMaybeSpan]) : unit
  (let
    [form-start : i64 (compiler-semantic-maybe-span-start state maybe-span 0)]
    [start-offset : i64
      (compiler-semantic-expr-start-offset
        state
        start-id
        (string.string-length (struct-get state source)))]
    [index-bound : CompilerSemanticBindResult
      (compiler-semantic-bind-local!
        state
        scope
        env
        index-name
        CompilerSemanticSymbolKind.Local
        (AstMaybeType.Some (tc-resolve-type (struct-get state ctx) index-ty))
        (compiler-semantic-form-head-end (struct-get state source) form-start)
        start-offset)]
    [init-offset : i64
      (compiler-semantic-expr-start-offset
        state
        init-id
        (string.string-length (struct-get state source)))]
    [prefix-bound : CompilerSemanticBindResult
      (compiler-semantic-bind-local!
        state
        (struct-get index-bound scope)
        (struct-get index-bound env)
        prefix-name
        CompilerSemanticSymbolKind.Local
        (AstMaybeType.Some (tc-resolve-type (struct-get state ctx) prefix-ty))
        (compiler-semantic-expr-end-offset
          state
          end-id
          (struct-get index-bound next-search))
        init-offset)]
    (begin
      (compiler-semantic-walk-node! state scope env start-id)
      (compiler-semantic-walk-node! state scope env end-id)
      (compiler-semantic-walk-node! state scope env init-id)
      (compiler-semantic-walk-node!
        state
        (struct-get index-bound scope)
        (struct-get index-bound env)
        value-id)
      (compiler-semantic-walk-node!
        state
        (struct-get prefix-bound scope)
        (struct-get prefix-bound env)
        body-id))))

(define (compiler-semantic-walk-set!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingList]
  [env : TcTypeEnv]
  [name-id : i64]
  [value-id : i64]
  [maybe-span : CompilerSemanticMaybeSpan]) : unit
  (let
    [form-start : i64 (compiler-semantic-maybe-span-start state maybe-span 0)]
    [value-start : i64
      (compiler-semantic-expr-start-offset
        state
        value-id
        (string.string-length (struct-get state source)))]
    [name : String (tc-env-key-name-text name-id)]
    [span : CompilerSemanticSpan
      (compiler-semantic-name-span-in-range
        (struct-get state path)
        (struct-get state source)
        name
        (compiler-semantic-form-head-end (struct-get state source) form-start)
        value-start)]
    (begin
      (compiler-semantic-record-name-use-span! state scope name-id span)
      (compiler-semantic-walk-node! state scope env value-id))))

(define (compiler-semantic-bind-pattern!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingList]
  [env : TcTypeEnv]
  [fact-env : TcTypeEnv]
  [facts-available : bool]
  [bound-names : TcNameIdList]
  [pattern : AstPattern]
  [search-start : i64]
  [search-limit : i64]) : CompilerSemanticBindResult
  (match pattern
    [(AstPattern.Var name maybe-ty)
      (if (tc-name-id-list-contains bound-names name)
        (compiler-semantic-bind-local!
          state
          scope
          env
          name
          CompilerSemanticSymbolKind.Local
          (match maybe-ty
            [(AstMaybeType.Some ty)
              ;; Preserve the existing public annotation text while the arm
              ;; body uses the checker's exact fact environment.
              (AstMaybeType.Some (tc-resolve-type (struct-get state ctx) ty))]
            [(AstMaybeType.No)
              (if facts-available
                (match (tc-lookup-visible-id
                  (struct-get state ctx)
                  fact-env
                  name)
                  [(ResultTcType.Ok ty)
                    (AstMaybeType.Some
                      (tc-resolve-type (struct-get state ctx) ty))]
                  [(ResultTcType.Err _) AstMaybeType.No])
                AstMaybeType.No)])
          search-start
          search-limit)
        (CompilerSemanticBindResult scope env search-start))]
    [(AstPattern.Binding name)
      (if (tc-name-id-list-contains bound-names name)
        (compiler-semantic-bind-local!
          state
          scope
          env
          name
          CompilerSemanticSymbolKind.Local
          (if facts-available
            (match (tc-lookup-visible-id (struct-get state ctx) fact-env name)
              [(ResultTcType.Ok ty)
                (AstMaybeType.Some (tc-resolve-type (struct-get state ctx) ty))]
              [(ResultTcType.Err _) AstMaybeType.No])
            AstMaybeType.No)
          search-start
          search-limit)
        (CompilerSemanticBindResult scope env search-start))]
    [(AstPattern.Tuple items)
      (compiler-semantic-bind-pattern-list!
        state
        scope
        env
        fact-env
        facts-available
        bound-names
        (box-get items)
        search-start
        search-limit)]
    [(AstPattern.Variant _ items)
      (compiler-semantic-bind-pattern-list!
        state
        scope
        env
        fact-env
        facts-available
        bound-names
        (box-get items)
        search-start
        search-limit)]
    [_ (CompilerSemanticBindResult scope env search-start)]))

(define (compiler-semantic-bind-pattern-list!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingList]
  [env : TcTypeEnv]
  [fact-env : TcTypeEnv]
  [facts-available : bool]
  [bound-names : TcNameIdList]
  [patterns : AstPatternList]
  [search-start : i64]
  [search-limit : i64]) : CompilerSemanticBindResult
  (let
    [next-scope : CompilerSemanticBindingList scope]
    [next-env : TcTypeEnv env]
    [cursor : i64 search-start]
    [index : i64 0]
    (begin
      (while (< index (ast-pattern-list-len (& patterns)))
        (let
          [bound : CompilerSemanticBindResult
            (compiler-semantic-bind-pattern!
              state
              next-scope
              next-env
              fact-env
              facts-available
              bound-names
              (ast-pattern-list-get (& patterns) index (ast-pattern-fallback))
              cursor
              search-limit)]
          (begin
            (set! next-scope (struct-get bound scope))
            (set! next-env (struct-get bound env))
            (set! cursor (struct-get bound next-search))
            (set! index (+ index 1)))))
      (CompilerSemanticBindResult next-scope next-env cursor))))

(define (compiler-semantic-pattern-bound-names
  [ctx : TcContext]
  [scrutinee-ty : AstType]
  [pattern : AstPattern]) : TcNameIdList
  ;; An explicitly typed pattern variable is always a binder, including when
  ;; the scrutinee is an enum. Bare enum variant names, by contrast, are not.
  (match pattern
    [(AstPattern.Var name _) (tc-name-id-list-add TcNameIdList.Nil name)]
    [_ (tc-borrow-check-pattern-bound-names ctx scrutinee-ty pattern)]))

(define (compiler-semantic-walk-match-arms!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingList]
  [env : TcTypeEnv]
  [scrutinee-ty : AstMaybeType]
  [arms : AstMatchArmList]
  [search-start : i64]) : unit
  (let
    [index : i64 0]
    [cursor : i64 search-start]
    (while (< index (ast-match-arm-list-len (& arms)))
      (begin
        (match (ast-match-arm-list-get (& arms) index (ast-match-arm-fallback))
          [(AstMatchArm.Arm pattern body)
            (let
              [body-start : i64
                (compiler-semantic-expr-start-offset
                  state
                  body
                  (string.string-length (struct-get state source)))]
              [saved : TcTypeEnvScopedRuntimeSave
                (tc-type-env-scoped-runtime-save)]
              (begin
                (match scrutinee-ty
                  [(AstMaybeType.Some ty)
                    (match (tc-bind-match-pattern
                      (struct-get state ctx)
                      env
                      ty
                      pattern)
                      [(ResultTcEnv.Ok fact-env)
                        (let
                          [bound : CompilerSemanticBindResult
                            (compiler-semantic-bind-pattern!
                              state
                              scope
                              env
                              fact-env
                              true
                              (compiler-semantic-pattern-bound-names
                                (struct-get state ctx)
                                ty
                                pattern)
                              pattern
                              cursor
                              body-start)]
                          (compiler-semantic-walk-node!
                            state
                            (struct-get bound scope)
                            fact-env
                            body))]
                      [(ResultTcEnv.Err _)
                        (let
                          [bound : CompilerSemanticBindResult
                            (compiler-semantic-bind-pattern!
                              state
                              scope
                              env
                              env
                              false
                              (tc-pattern-add-bound-name-ids
                                pattern
                                TcNameIdList.Nil)
                              pattern
                              cursor
                              body-start)]
                          (compiler-semantic-walk-node!
                            state
                            (struct-get bound scope)
                            (struct-get bound env)
                            body))])]
                  [(AstMaybeType.No)
                    (let
                      [bound : CompilerSemanticBindResult
                        (compiler-semantic-bind-pattern!
                          state
                          scope
                          env
                          env
                          false
                          (tc-pattern-add-bound-name-ids
                            pattern
                            TcNameIdList.Nil)
                          pattern
                          cursor
                          body-start)]
                      (compiler-semantic-walk-node!
                        state
                        (struct-get bound scope)
                        (struct-get bound env)
                        body))])
                (tc-type-env-scoped-runtime-restore! saved)
                (set!
                  cursor
                  (compiler-semantic-expr-end-offset state body body-start))))])
        (set! index (+ index 1))))))

(define (compiler-semantic-walk-with-resources!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingList]
  [env : TcTypeEnv]
  [bindings : AstResourceBindingList]
  [body : AstExprList]
  [maybe-span : CompilerSemanticMaybeSpan]) : unit
  (let
    [next-scope : CompilerSemanticBindingList scope]
    [next-env : TcTypeEnv env]
    [form-start : i64 (compiler-semantic-maybe-span-start state maybe-span 0)]
    [cursor : i64
      (compiler-semantic-form-head-end (struct-get state source) form-start)]
    [index : i64 0]
    (begin
      (while (< index (ast-resource-binding-list-len (& bindings)))
        (begin
          (match (ast-resource-binding-list-get
            (& bindings)
            index
            (ast-resource-binding-fallback))
            [(AstResourceBinding.Binding name init cleanup _)
              (let
                [init-start : i64
                  (compiler-semantic-expr-start-offset
                    state
                    init
                    (string.string-length (struct-get state source)))]
                (begin
                  (compiler-semantic-walk-node!
                    state
                    next-scope
                    next-env
                    cleanup)
                  (compiler-semantic-walk-node! state next-scope next-env init)
                  (let
                    [bound : CompilerSemanticBindResult
                      (let
                        [ctx : TcContext (struct-get state ctx)]
                        [expr-bases : i64 (tc-context-expr-bases ctx)]
                        [cleanup-expr : AstExpr
                          (ast-expr-segment-bases-get expr-bases cleanup)]
                        (match (tc-resource-cleanup-resource-type
                          ctx
                          next-env
                          cleanup-expr)
                          [(ResultTcType.Ok expected-init-ty)
                            (match (tc-expr-with-expected-or-actual-id
                              ctx
                              next-env
                              init
                              expected-init-ty)
                              [(ResultTcType.Ok init-ty)
                                (let
                                  [binding-ty : AstType
                                    (tc-type-without-regions init-ty)]
                                  [recorded : CompilerSemanticBindResult
                                    (compiler-semantic-bind-local!
                                      state
                                      next-scope
                                      next-env
                                      name
                                      CompilerSemanticSymbolKind.Local
                                      (AstMaybeType.Some
                                        (tc-resolve-type ctx binding-ty))
                                      cursor
                                      init-start)]
                                  (CompilerSemanticBindResult
                                    (struct-get recorded scope)
                                    (tc-bind-id
                                      (tc-bind-id
                                        next-env
                                        (tc-cleanup-owner-marker-id)
                                        (AstType.Var name))
                                      name
                                      binding-ty)
                                    (struct-get recorded next-search)))]
                              [(ResultTcType.Err _)
                                (compiler-semantic-bind-local!
                                  state
                                  next-scope
                                  next-env
                                  name
                                  CompilerSemanticSymbolKind.Local
                                  AstMaybeType.No
                                  cursor
                                  init-start)])]
                          [(ResultTcType.Err _)
                            (compiler-semantic-bind-local!
                              state
                              next-scope
                              next-env
                              name
                              CompilerSemanticSymbolKind.Local
                              AstMaybeType.No
                              cursor
                              init-start)]))]
                    (begin
                      (set! next-scope (struct-get bound scope))
                      (set! next-env (struct-get bound env))
                      (set!
                        cursor
                        (compiler-semantic-expr-end-offset
                          state
                          cleanup
                          (compiler-semantic-expr-end-offset
                            state
                            init
                            (struct-get bound next-search))))))))])
          (set! index (+ index 1))))
      (compiler-semantic-walk-expr-list! state next-scope next-env body))))

(define (compiler-semantic-walk-node-with-span!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingList]
  [env : TcTypeEnv]
  [node-id : i64]
  [maybe-span : CompilerSemanticMaybeSpan]) : unit
  (let
    [visited : (__tl_dyn-array i64) (struct-get state visited-expr-ids)]
    (if (or
      (< node-id 0)
      (>= node-id (array-length visited))
      (!= (array-ref visited node-id) 0))
      unit
      (begin
        (array-set! visited node-id 1)
        (let
          [expr : AstExpr (ast-node-get node-id)]
          (match expr
            [(AstExpr.Spanned inner-id span)
              (compiler-semantic-walk-node-with-span!
                state
                scope
                env
                inner-id
                (CompilerSemanticMaybeSpan.Some span))]
            [_ (compiler-semantic-walk-expr! state scope env expr maybe-span)]))))))

(define (compiler-semantic-walk-node!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingList]
  [env : TcTypeEnv]
  [node-id : i64]) : unit
  (compiler-semantic-walk-node-with-span!
    state
    scope
    env
    node-id
    CompilerSemanticMaybeSpan.None))

(define (compiler-semantic-walk-expr!
  [state : CompilerSemanticWalkState]
  [scope : CompilerSemanticBindingList]
  [env : TcTypeEnv]
  [expr : AstExpr]
  [maybe-span : CompilerSemanticMaybeSpan]) : unit
  (match expr
    [(AstExpr.Spanned inner-id span)
      (compiler-semantic-walk-node-with-span!
        state
        scope
        env
        inner-id
        (CompilerSemanticMaybeSpan.Some span))]
    [(AstExpr.Var name)
      (compiler-semantic-record-name-use! state scope name maybe-span)]
    [(AstExpr.Binary _ left right)
      (begin
        (compiler-semantic-walk-node! state scope env left)
        (compiler-semantic-walk-node! state scope env right))]
    [(AstExpr.Unary _ inner)
      (compiler-semantic-walk-node! state scope env inner)]
    [(AstExpr.Call callee args)
      (begin
        (compiler-semantic-walk-node! state scope env callee)
        (compiler-semantic-walk-expr-list! state scope env args))]
    [(AstExpr.If condition then-expr else-expr)
      (begin
        (compiler-semantic-walk-node! state scope env condition)
        (compiler-semantic-walk-node! state scope env then-expr)
        (compiler-semantic-walk-node! state scope env else-expr))]
    [(AstExpr.Let payload)
      (match (box-get payload)
        [(AstLet.Let bindings body)
          (compiler-semantic-walk-let! state scope env bindings body maybe-span)])]
    [(AstExpr.Lambda payload)
      (match (box-get payload)
        [(AstLambda.Lambda params _ body)
          (compiler-semantic-walk-lambda!
            state
            scope
            env
            params
            body
            maybe-span)])]
    [(AstExpr.Tuple items)
      (compiler-semantic-walk-expr-list! state scope env items)]
    [(AstExpr.TupleRef target _)
      (compiler-semantic-walk-node! state scope env target)]
    [(AstExpr.Array items)
      (compiler-semantic-walk-expr-list! state scope env items)]
    [(AstExpr.DynArray items)
      (compiler-semantic-walk-expr-list! state scope env items)]
    [(AstExpr.MakeArray _ size)
      (compiler-semantic-walk-node! state scope env size)]
    [(AstExpr.ArrayRef target index)
      (begin
        (compiler-semantic-walk-node! state scope env target)
        (compiler-semantic-walk-node! state scope env index))]
    [(AstExpr.ArraySet target index value)
      (begin
        (compiler-semantic-walk-node! state scope env target)
        (compiler-semantic-walk-node! state scope env index)
        (compiler-semantic-walk-node! state scope env value))]
    [(AstExpr.ArrayTake target live index)
      (begin
        (compiler-semantic-walk-node! state scope env target)
        (compiler-semantic-walk-node! state scope env live)
        (compiler-semantic-walk-node! state scope env index))]
    [(AstExpr.ArrayPush target value)
      (begin
        (compiler-semantic-walk-node! state scope env target)
        (compiler-semantic-walk-node! state scope env value))]
    [(AstExpr.StringRef target index)
      (begin
        (compiler-semantic-walk-node! state scope env target)
        (compiler-semantic-walk-node! state scope env index))]
    [(AstExpr.While condition body)
      (begin
        (compiler-semantic-walk-node! state scope env condition)
        (compiler-semantic-walk-node! state scope env body))]
    [(AstExpr.Begin items)
      (compiler-semantic-walk-expr-list! state scope env items)]
    [(AstExpr.Unsafe items)
      (compiler-semantic-walk-expr-list! state scope env items)]
    [(AstExpr.Set name value)
      (compiler-semantic-walk-set! state scope env name value maybe-span)]
    [(AstExpr.Ann inner _) (compiler-semantic-walk-node! state scope env inner)]
    [(AstExpr.Cast inner _)
      (compiler-semantic-walk-node! state scope env inner)]
    [(AstExpr.Borrow _ _ inner)
      (compiler-semantic-walk-node! state scope env inner)]
    [(AstExpr.Match payload)
      (match (box-get payload)
        [(AstMatch.Match scrutinee arms)
          (begin
            (compiler-semantic-walk-node! state scope env scrutinee)
            (compiler-semantic-walk-match-arms!
              state
              scope
              env
              (match (tc-expr-id (struct-get state ctx) env scrutinee)
                [(ResultTcType.Ok ty) (AstMaybeType.Some ty)]
                [(ResultTcType.Err _) AstMaybeType.No])
              arms
              (compiler-semantic-expr-end-offset
                state
                scrutinee
                (compiler-semantic-maybe-span-start state maybe-span 0))))])]
    [(AstExpr.Foreach payload)
      (match (box-get payload)
        [(AstForeach.Foreach name index-ty start end body)
          (compiler-semantic-walk-foreach!
            state
            scope
            env
            name
            index-ty
            start
            end
            body
            maybe-span)])]
    [(AstExpr.SpmdReduce payload)
      (match (box-get payload)
        [(AstSpmdReduce.Reduce _ index index-ty start end init value)
          (compiler-semantic-walk-spmd-reduce!
            state
            scope
            env
            index
            index-ty
            start
            end
            init
            value
            maybe-span)])]
    [(AstExpr.SpmdScan payload)
      (match (box-get payload)
        [(AstSpmdScan.Scan
            _
            index
            index-ty
            start
            end
            prefix
            prefix-ty
            init
            value
            body)
          (compiler-semantic-walk-spmd-scan!
            state
            scope
            env
            index
            index-ty
            start
            end
            prefix
            prefix-ty
            init
            value
            body
            maybe-span)])]
    [(AstExpr.SpmdBroadcast value lane)
      (begin
        (compiler-semantic-walk-node! state scope env value)
        (compiler-semantic-walk-node! state scope env lane))]
    [(AstExpr.SpmdShuffle value lane)
      (begin
        (compiler-semantic-walk-node! state scope env value)
        (compiler-semantic-walk-node! state scope env lane))]
    [(AstExpr.StructGet target _)
      (compiler-semantic-walk-node! state scope env target)]
    [(AstExpr.StructSet target _ value)
      (begin
        (compiler-semantic-walk-node! state scope env target)
        (compiler-semantic-walk-node! state scope env value))]
    [(AstExpr.WithRegion _ body)
      (compiler-semantic-walk-expr-list! state scope env body)]
    [(AstExpr.WithEscape scratch body)
      (begin
        (compiler-semantic-walk-node! state scope env scratch)
        (compiler-semantic-walk-expr-list! state scope env body))]
    [(AstExpr.WithScratch body)
      (compiler-semantic-walk-expr-list! state scope env body)]
    [(AstExpr.InArena arena body)
      (begin
        (compiler-semantic-walk-node! state scope env arena)
        (compiler-semantic-walk-expr-list! state scope env body))]
    [(AstExpr.WithResource payload)
      (match (box-get payload)
        [(AstWithResource.WithResource bindings body)
          (compiler-semantic-walk-with-resources!
            state
            scope
            env
            bindings
            body
            maybe-span)])]
    [(AstExpr.Box value) (compiler-semantic-walk-node! state scope env value)]
    [(AstExpr.BoxGet value)
      (compiler-semantic-walk-node! state scope env value)]
    [(AstExpr.BoxTake value)
      (compiler-semantic-walk-node! state scope env value)]
    [(AstExpr.BoxSet target value)
      (begin
        (compiler-semantic-walk-node! state scope env target)
        (compiler-semantic-walk-node! state scope env value))]
    [(AstExpr.Comptime inner)
      (compiler-semantic-walk-node! state scope env inner)]
    [(AstExpr.Quote _) unit]
    [(AstExpr.Quasiquote inner)
      (compiler-semantic-walk-quasiquote-node! state scope env inner)]
    [(AstExpr.Unquote inner)
      (compiler-semantic-walk-node! state scope env inner)]
    [(AstExpr.UnquoteSplicing inner)
      (compiler-semantic-walk-node! state scope env inner)]
    [(AstExpr.BracketClause items)
      (compiler-semantic-walk-expr-list! state scope env items)]
    [(AstExpr.Try inner) (compiler-semantic-walk-node! state scope env inner)]
    [(AstExpr.Return inner)
      (compiler-semantic-walk-node! state scope env inner)]
    [(AstExpr.PtrNullCheck inner)
      (compiler-semantic-walk-node! state scope env inner)]
    [(AstExpr.PtrAddrOf inner)
      (compiler-semantic-walk-node! state scope env inner)]
    [(AstExpr.PtrRead inner)
      (compiler-semantic-walk-node! state scope env inner)]
    [(AstExpr.PtrWrite ptr value)
      (begin
        (compiler-semantic-walk-node! state scope env ptr)
        (compiler-semantic-walk-node! state scope env value))]
    [(AstExpr.PtrOffset ptr offset)
      (begin
        (compiler-semantic-walk-node! state scope env ptr)
        (compiler-semantic-walk-node! state scope env offset))]
    [(AstExpr.PtrCast ptr _) (compiler-semantic-walk-node! state scope env ptr)]
    [(AstExpr.PtrToInt ptr) (compiler-semantic-walk-node! state scope env ptr)]
    [(AstExpr.IntToPtr value _)
      (compiler-semantic-walk-node! state scope env value)]
    [(AstExpr.StringData value)
      (compiler-semantic-walk-node! state scope env value)]
    [(AstExpr.StringFromBytes data len)
      (begin
        (compiler-semantic-walk-node! state scope env data)
        (compiler-semantic-walk-node! state scope env len))]
    [(AstExpr.ArrayData value)
      (compiler-semantic-walk-node! state scope env value)]
    [(AstExpr.CpuIdEax leaf subleaf)
      (begin
        (compiler-semantic-walk-node! state scope env leaf)
        (compiler-semantic-walk-node! state scope env subleaf))]
    [(AstExpr.CpuIdEbx leaf subleaf)
      (begin
        (compiler-semantic-walk-node! state scope env leaf)
        (compiler-semantic-walk-node! state scope env subleaf))]
    [(AstExpr.CpuIdEcx leaf subleaf)
      (begin
        (compiler-semantic-walk-node! state scope env leaf)
        (compiler-semantic-walk-node! state scope env subleaf))]
    [(AstExpr.CpuIdEdx leaf subleaf)
      (begin
        (compiler-semantic-walk-node! state scope env leaf)
        (compiler-semantic-walk-node! state scope env subleaf))]
    [(AstExpr.Xgetbv index)
      (compiler-semantic-walk-node! state scope env index)]
    [(AstExpr.Syscall args)
      (compiler-semantic-walk-expr-list! state scope env args)]
    [_ unit]))

(define (compiler-semantic-decl-param-search-start
  [state : CompilerSemanticWalkState]
  [name-id : i64]
  [body-id : i64]) : i64
  (let
    [body-start : i64
      (compiler-semantic-expr-start-offset
        state
        body-id
        (string.string-length (struct-get state source)))]
    [form-start : i64
      (if (>= (struct-get state form-start) 0)
        (struct-get state form-start)
        0)]
    [name-span : CompilerSemanticSpan
      (compiler-semantic-name-span-in-range
        (struct-get state path)
        (struct-get state source)
        (tc-env-key-name-text name-id)
        (compiler-semantic-form-head-end (struct-get state source) form-start)
        body-start)]
    (if (>= (struct-get name-span end-byte) 0)
      (struct-get name-span end-byte)
      (compiler-semantic-form-head-end (struct-get state source) form-start))))

(define (compiler-semantic-walk-decl!
  [state : CompilerSemanticWalkState]
  [decl : AstDecl]) : unit
  (match decl
    [(AstDecl.Def _ _ _ value)
      (compiler-semantic-walk-node!
        state
        CompilerSemanticBindingList.Nil
        (struct-get state top-env)
        value)]
    [(AstDecl.DefFn _ name params _ body _)
      (let
        [body-start : i64
          (compiler-semantic-expr-start-offset
            state
            body
            (string.string-length (struct-get state source)))]
        [bound : CompilerSemanticBindResult
          (compiler-semantic-bind-params!
            state
            CompilerSemanticBindingList.Nil
            (struct-get state top-env)
            params
            (compiler-semantic-decl-param-search-start state name body)
            body-start)]
        (compiler-semantic-walk-node!
          state
          (struct-get bound scope)
          (struct-get bound env)
          body))]
    [(AstDecl.DefMacro _ name params _ body)
      (let
        [body-start : i64
          (compiler-semantic-expr-start-offset
            state
            body
            (string.string-length (struct-get state source)))]
        [bound : CompilerSemanticBindResult
          (compiler-semantic-bind-macro-params!
            state
            CompilerSemanticBindingList.Nil
            (struct-get state top-env)
            params
            (compiler-semantic-decl-param-search-start state name body)
            body-start)]
        (compiler-semantic-walk-node!
          state
          (struct-get bound scope)
          (struct-get bound env)
          body))]
    [(AstDecl.Test _ body _)
      (compiler-semantic-walk-node!
        state
        CompilerSemanticBindingList.Nil
        (struct-get state top-env)
        body)]
    [(AstDecl.Unsafe inner)
      (compiler-semantic-walk-decl! state (box-get inner))]
    [_ unit]))

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
        [walk-state : CompilerSemanticWalkState
          (CompilerSemanticWalkState
            ctx
            env
            ""
            ""
            -1
            cbi.compiler-builtin-id-fix-empty
            -1
            false
            CompilerSemanticProvenance.EditableSource
            (box
              (compiler-semantic-record-vec-new
                (* (ast-decl-list-len (& decls)) 2)))
            (array.make-array
              i64
              (ast-node-pool-context-expr-len (tc-context-pools ctx)))
            (box 0))]
        [index : i64 0]
        [cached-path : String ""]
        [cached-source : String ""]
        [form-search-start : i64 0]
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
              [decl-ctx : TcContext
                (if (= module-id cbi.compiler-builtin-id-fix-empty)
                  (tc-context-with-module-id
                    ctx
                    ""
                    cbi.compiler-builtin-id-fix-empty)
                  (tc-context-with-module-id
                    ctx
                    (macro-decl-module-display module-id)
                    module-id))]
              [generated : bool
                (match (ast-decl-generated-meta decl)
                  [(AstGeneratedDeclMeta.No) false]
                  [(AstGeneratedDeclMeta.Some _ _ _ _) true])]
              [provenance : CompilerSemanticProvenance
                (compiler-semantic-decl-provenance decl)]
              [path-changed : bool (not (string.eq path cached-path))]
              (begin
                (if path-changed
                  (begin
                    (set! cached-path (string.copy (& path)))
                    (set! form-search-start 0)
                    (set!
                      cached-source
                      (cond
                        [(string.eq path entry-path)
                          (string.copy (& entry-source))]
                        [(and (not (string.eq path "")) (io.file-exists? path))
                          (io.read-file path)]
                        [else ""])))
                  unit)
                (set! (struct-get walk-state ctx) decl-ctx)
                (set! (struct-get walk-state top-env) env)
                (set! (struct-get walk-state path) (string.copy (& path)))
                (set!
                  (struct-get walk-state source)
                  (string.copy (& cached-source)))
                (set! (struct-get walk-state form-start) -1)
                (set! (struct-get walk-state module-id) module-id)
                (set! (struct-get walk-state declaration-ordinal) index)
                (set! (struct-get walk-state generated) generated)
                (set! (struct-get walk-state provenance) provenance)
                (set! (box-get (struct-get walk-state next-local-ordinal)) 0)
                (match (compiler-semantic-decl-symbol decl)
                  [(CompilerSemanticMaybeDecl.Some name-id kind)
                    (let
                      [name : String (tc-env-key-name-text name-id)]
                      [maybe-origin : CompilerParseMaybeDeclSpan
                        (compiler-semantic-decl-origin (& decls) index decl)]
                      [form-start : i64
                        (match maybe-origin
                          [(CompilerParseMaybeDeclSpan.Some origin)
                            (if (or generated (string.eq cached-source ""))
                              -1
                              (compiler-semantic-top-level-form-start
                                cached-source
                                (compiler-semantic-source-offset
                                  cached-source
                                  (ast-source-span-start-line origin)
                                  (ast-source-span-start-col origin))
                                form-search-start))]
                          [(CompilerParseMaybeDeclSpan.None)
                            (if (and
                              (not generated)
                              (not (string.eq cached-source "")))
                              0
                              -1)])]
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
                                origin
                                form-start))]
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
                                    (ast-source-span-start-col end-position))
                                  form-start))
                              (CompilerSemanticSpan
                                (string.copy (& path))
                                -1
                                -1
                                (ast-source-span 1 1 1 1)))])]
                      [symbol : CompilerSemanticSymbolId
                        (compiler-semantic-symbol-for-decl
                          decl-ctx
                          module-id
                          index
                          name-id
                          kind)]
                      [type-text : String
                        (compiler-semantic-decl-type
                          decl-ctx
                          env
                          decl
                          kind
                          name-id
                          name)]
                      [documentation : String
                        (if (and
                          (not generated)
                          (not (string.eq cached-source ""))
                          (>= (struct-get span start-byte) 0))
                          (compiler-semantic-documentation-above
                            cached-source
                            form-start)
                          "")]
                      (begin
                        (set! (struct-get walk-state form-start) form-start)
                        (if (>= form-start 0)
                          (set! form-search-start form-start)
                          unit)
                        ;; Local identities are anchored to the resolved
                        ;; declaration handle, not the flattened AST position.
                        (set!
                          (struct-get walk-state module-id)
                          (struct-get symbol module-id))
                        (set!
                          (struct-get walk-state declaration-ordinal)
                          (struct-get symbol declaration-ordinal))
                        (compiler-semantic-record-vec-push!
                          (&mut (box-get (struct-get walk-state records)))
                          (CompilerSemanticRecord
                            symbol
                            CompilerSemanticRecordRole.Definition
                            kind
                            (string.copy (& name))
                            (string.copy (& type-text))
                            (string.copy (& documentation))
                            (struct-get symbol module-id)
                            span
                            (and
                              (not generated)
                              has-origin
                              (>= (struct-get span start-byte) 0))
                            provenance))))]
                  [(CompilerSemanticMaybeDecl.None) unit])
                (compiler-semantic-walk-decl! walk-state decl)
                (set! index (+ index 1)))))
          (let
            [result : CompilerSemanticSourceIndex
              (CompilerSemanticSourceIndex
                owner
                (struct-get (box-get (struct-get walk-state records)) items)
                (struct-get (box-get (struct-get walk-state records)) len)
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

(define (compiler-semantic-symbol-id-eq?
  [left : CompilerSemanticSymbolId]
  [right : CompilerSemanticSymbolId]) : bool
  (and
    (= (struct-get left module-id) (struct-get right module-id))
    (=
      (struct-get left declaration-ordinal)
      (struct-get right declaration-ordinal))
    (= (struct-get left local-ordinal) (struct-get right local-ordinal))))

(define (compiler-semantic-source-index-find-record
  [index : (& index CompilerSemanticSourceIndex)]
  [path : String]
  [name : String]
  [role : CompilerSemanticRecordRole]
  [local-ordinal : i64]) : i64
  (let
    [record-index : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (< record-index (struct-get index len)))
        (let
          [record : CompilerSemanticRecord
            (array-ref (struct-get index records) record-index)]
          [symbol : CompilerSemanticSymbolId (struct-get record symbol)]
          (begin
            (if (and
              (string.eq (struct-get record display-name) name)
              (match role
                [(CompilerSemanticRecordRole.Definition)
                  (match (struct-get record role)
                    [(CompilerSemanticRecordRole.Definition) true]
                    [_ false])]
                [(CompilerSemanticRecordRole.Use)
                  (match (struct-get record role)
                    [(CompilerSemanticRecordRole.Use) true]
                    [_ false])])
              (= (struct-get symbol local-ordinal) local-ordinal)
              (or
                (string.eq path "")
                (string.eq (struct-get (struct-get record span) path) path)))
              (set! found record-index)
              unit)
            (set! record-index (+ record-index 1)))))
      found)))

(define (compiler-semantic-source-index-find-name-occurrence
  [index : (& index CompilerSemanticSourceIndex)]
  [path : String]
  [name : String]
  [role : CompilerSemanticRecordRole]
  [occurrence : i64]) : i64
  (let
    [record-index : i64 0]
    [seen : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (< record-index (struct-get index len)))
        (let
          [record : CompilerSemanticRecord
            (array-ref (struct-get index records) record-index)]
          (begin
            (if (and
              (string.eq (struct-get record display-name) name)
              (match role
                [(CompilerSemanticRecordRole.Definition)
                  (match (struct-get record role)
                    [(CompilerSemanticRecordRole.Definition) true]
                    [_ false])]
                [(CompilerSemanticRecordRole.Use)
                  (match (struct-get record role)
                    [(CompilerSemanticRecordRole.Use) true]
                    [_ false])])
              (or
                (string.eq path "")
                (string.eq (struct-get (struct-get record span) path) path)))
              (if (= seen occurrence)
                (set! found record-index)
                (set! seen (+ seen 1)))
              unit)
            (set! record-index (+ record-index 1)))))
      found)))

(define (compiler-semantic-source-index-find-symbol-role
  [index : (& index CompilerSemanticSourceIndex)]
  [symbol : CompilerSemanticSymbolId]
  [role : CompilerSemanticRecordRole]) : i64
  (let
    [record-index : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (< record-index (struct-get index len)))
        (let
          [record : CompilerSemanticRecord
            (array-ref (struct-get index records) record-index)]
          [record-symbol : CompilerSemanticSymbolId (struct-get record symbol)]
          (begin
            (if (and
              (match role
                [(CompilerSemanticRecordRole.Definition)
                  (match (struct-get record role)
                    [(CompilerSemanticRecordRole.Definition) true]
                    [_ false])]
                [(CompilerSemanticRecordRole.Use)
                  (match (struct-get record role)
                    [(CompilerSemanticRecordRole.Use) true]
                    [_ false])])
              (=
                (struct-get record-symbol module-id)
                (struct-get symbol module-id))
              (=
                (struct-get record-symbol declaration-ordinal)
                (struct-get symbol declaration-ordinal))
              (=
                (struct-get record-symbol local-ordinal)
                (struct-get symbol local-ordinal)))
              (set! found record-index)
              unit)
            (set! record-index (+ record-index 1)))))
      found)))

(define (compiler-semantic-record-span-text-eq?
  [source : String]
  [record : CompilerSemanticRecord]
  [expected : String]) : bool
  (let
    [span : CompilerSemanticSpan (struct-get record span)]
    [start : i64 (struct-get span start-byte)]
    [end : i64 (struct-get span end-byte)]
    (and
      (>= start 0)
      (>= end start)
      (string.eq (string.substring source start (- end start)) expected))))

(define (compiler-semantic-record-vec-growth-ok?) : bool
  (let
    [records : CompilerSemanticRecordVec (compiler-semantic-record-vec-new 1)]
    (begin
      (compiler-semantic-record-vec-push!
        (&mut records)
        (compiler-semantic-record-fallback))
      (compiler-semantic-record-vec-push!
        (&mut records)
        (compiler-semantic-record-fallback))
      (compiler-semantic-record-vec-push!
        (&mut records)
        (compiler-semantic-record-fallback))
      (and
        (= (struct-get records len) 3)
        (>= (array-length (struct-get records items)) 3)
        (array-ref (struct-get records live) 0)
        (array-ref (struct-get records live) 1)
        (array-ref (struct-get records live) 2)))))

(define (compiler-check-semantic-index-base-ok?) : bool
  (let
    [path : String "src/tests/semantic_index_entry.tl"]
    [source : String
      "(module semantic.demo)
(import \"semantic_index_import_dep.tl\" module semantic.index.import_dep as dep)
(defstruct Pair (left i64))
(defmacro (emit-generated) : Decls
  `(define generated-value : i64 7))
(emit-generated)
(define prior-text : String \"(answer)\")
(define prior-char : char '(')
; ordinary source text mentions an unmatched (answer
;: Top answer documentation.
;# Additional answer detail.
  (define answer : i64 42)
(defmacro (wrap [value : Expr]) : Expr
  `(struct-get ,value left))
(define wrapped-answer : i64 (wrap (Pair 8)))
(define (use
  ; answer appears in a comment before the parameter binder.
  [answer : i64]) : i64
  (let
    ; answer appears in a comment before the local binder.
    [answer : i64 (+ answer dep.imported-value)]
    answer))
(define (call-use) : i64 (use answer))
(define (match-use [value : i64]) : i64
  (match value
    [bound bound]))
(defmacro (nested-template [hidden : Expr]) : Expr
  `(quasiquote (begin (unquote hidden))))"]
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
          [param-definition-index : i64
            (compiler-semantic-source-index-find-record
              (& first)
              path
              "answer"
              CompilerSemanticRecordRole.Definition
              0)]
          [param-use-index : i64
            (compiler-semantic-source-index-find-record
              (& first)
              path
              "answer"
              CompilerSemanticRecordRole.Use
              0)]
          [local-definition-index : i64
            (compiler-semantic-source-index-find-record
              (& first)
              path
              "answer"
              CompilerSemanticRecordRole.Definition
              1)]
          [local-use-index : i64
            (compiler-semantic-source-index-find-record
              (& first)
              path
              "answer"
              CompilerSemanticRecordRole.Use
              1)]
          [macro-param-definition-index : i64
            (compiler-semantic-source-index-find-record
              (& first)
              path
              "value"
              CompilerSemanticRecordRole.Definition
              0)]
          [macro-param-use-index : i64
            (compiler-semantic-source-index-find-record
              (& first)
              path
              "value"
              CompilerSemanticRecordRole.Use
              0)]
          [import-definition-index : i64
            (compiler-semantic-source-index-find-record
              (& first)
              ""
              "imported-value"
              CompilerSemanticRecordRole.Definition
              -1)]
          [import-use-index : i64
            (compiler-semantic-source-index-find-record
              (& first)
              path
              "imported-value"
              CompilerSemanticRecordRole.Use
              -1)]
          [answer-use-index : i64
            (compiler-semantic-source-index-find-record
              (& first)
              path
              "answer"
              CompilerSemanticRecordRole.Use
              -1)]
          [function-use-index : i64
            (compiler-semantic-source-index-find-record
              (& first)
              path
              "use"
              CompilerSemanticRecordRole.Use
              -1)]
          [generated-index : i64
            (compiler-semantic-source-index-find-record
              (& first)
              ""
              "generated-value"
              CompilerSemanticRecordRole.Definition
              -1)]
          [pattern-definition-index : i64
            (compiler-semantic-source-index-find-record
              (& first)
              path
              "bound"
              CompilerSemanticRecordRole.Definition
              1)]
          [pattern-use-index : i64
            (compiler-semantic-source-index-find-record
              (& first)
              path
              "bound"
              CompilerSemanticRecordRole.Use
              1)]
          [nested-param-definition-index : i64
            (compiler-semantic-source-index-find-record
              (& first)
              path
              "hidden"
              CompilerSemanticRecordRole.Definition
              0)]
          [nested-param-use-index : i64
            (compiler-semantic-source-index-find-record
              (& first)
              path
              "hidden"
              CompilerSemanticRecordRole.Use
              0)]
          [first-len : i64 (compiler-semantic-source-index-len (& first))]
          (if (or
            (< answer-index 0)
            (< use-index 0)
            (< pair-index 0)
            (< param-definition-index 0)
            (< param-use-index 0)
            (< local-definition-index 0)
            (< local-use-index 0)
            (< macro-param-definition-index 0)
            (< macro-param-use-index 0)
            (< import-definition-index 0)
            (< import-use-index 0)
            (< answer-use-index 0)
            (< function-use-index 0)
            (< generated-index 0)
            (< pattern-definition-index 0)
            (< pattern-use-index 0)
            (< nested-param-definition-index 0)
            (>= nested-param-use-index 0))
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
              [param-definition : CompilerSemanticRecord
                (compiler-semantic-source-index-get
                  (& first)
                  param-definition-index)]
              [param-use : CompilerSemanticRecord
                (compiler-semantic-source-index-get (& first) param-use-index)]
              [local-definition : CompilerSemanticRecord
                (compiler-semantic-source-index-get
                  (& first)
                  local-definition-index)]
              [local-use : CompilerSemanticRecord
                (compiler-semantic-source-index-get (& first) local-use-index)]
              [macro-param-definition : CompilerSemanticRecord
                (compiler-semantic-source-index-get
                  (& first)
                  macro-param-definition-index)]
              [macro-param-use : CompilerSemanticRecord
                (compiler-semantic-source-index-get
                  (& first)
                  macro-param-use-index)]
              [import-definition : CompilerSemanticRecord
                (compiler-semantic-source-index-get
                  (& first)
                  import-definition-index)]
              [import-use : CompilerSemanticRecord
                (compiler-semantic-source-index-get (& first) import-use-index)]
              [answer-use : CompilerSemanticRecord
                (compiler-semantic-source-index-get (& first) answer-use-index)]
              [function-use : CompilerSemanticRecord
                (compiler-semantic-source-index-get
                  (& first)
                  function-use-index)]
              [generated : CompilerSemanticRecord
                (compiler-semantic-source-index-get (& first) generated-index)]
              [pattern-definition : CompilerSemanticRecord
                (compiler-semantic-source-index-get
                  (& first)
                  pattern-definition-index)]
              [pattern-use : CompilerSemanticRecord
                (compiler-semantic-source-index-get (& first) pattern-use-index)]
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
                    [second-param-index : i64
                      (compiler-semantic-source-index-find-record
                        (& second)
                        path
                        "answer"
                        CompilerSemanticRecordRole.Definition
                        0)]
                    [second-param : CompilerSemanticRecord
                      (compiler-semantic-source-index-get
                        (& second)
                        second-param-index)]
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
                        (compiler-semantic-record-vec-growth-ok?)
                        (compiler-semantic-source-index-complete? (& first))
                        (compiler-check-semantic-index-record-ok?
                          source
                          answer
                          "answer"
                          CompilerSemanticSymbolKind.Value)
                        (=
                          (ast-source-span-start-line
                            (struct-get (struct-get answer span) source))
                          12)
                        (=
                          (ast-source-span-start-col
                            (struct-get (struct-get answer span) source))
                          11)
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
                        (string.eq
                          (struct-get answer documentation)
                          "Top answer documentation.\nAdditional answer detail.")
                        (compiler-semantic-symbol-id-eq?
                          (struct-get param-definition symbol)
                          (struct-get param-use symbol))
                        (compiler-semantic-symbol-id-eq?
                          (struct-get local-definition symbol)
                          (struct-get local-use symbol))
                        (compiler-semantic-symbol-id-eq?
                          (struct-get macro-param-definition symbol)
                          (struct-get macro-param-use symbol))
                        (=
                          (struct-get (struct-get use symbol) module-id)
                          (struct-get
                            (struct-get param-definition symbol)
                            module-id))
                        (=
                          (struct-get
                            (struct-get use symbol)
                            declaration-ordinal)
                          (struct-get
                            (struct-get param-definition symbol)
                            declaration-ordinal))
                        (not
                          (compiler-semantic-symbol-id-eq?
                            (struct-get answer symbol)
                            (struct-get param-definition symbol)))
                        (not
                          (compiler-semantic-symbol-id-eq?
                            (struct-get param-definition symbol)
                            (struct-get local-definition symbol)))
                        (compiler-semantic-record-span-text-eq?
                          source
                          param-definition
                          "answer")
                        (=
                          (ast-source-span-start-line
                            (struct-get
                              (struct-get param-definition span)
                              source))
                          18)
                        (=
                          (ast-source-span-start-col
                            (struct-get
                              (struct-get param-definition span)
                              source))
                          4)
                        (compiler-semantic-record-span-text-eq?
                          source
                          param-use
                          "answer")
                        (compiler-semantic-record-span-text-eq?
                          source
                          local-definition
                          "answer")
                        (=
                          (ast-source-span-start-line
                            (struct-get
                              (struct-get local-definition span)
                              source))
                          21)
                        (=
                          (ast-source-span-start-col
                            (struct-get
                              (struct-get local-definition span)
                              source))
                          6)
                        (compiler-semantic-record-span-text-eq?
                          source
                          local-use
                          "answer")
                        (compiler-semantic-record-span-text-eq?
                          source
                          macro-param-definition
                          "value")
                        (compiler-semantic-record-span-text-eq?
                          source
                          macro-param-use
                          "value")
                        (string.eq
                          (struct-get param-definition resolved-type)
                          "i64")
                        (string.eq
                          (struct-get local-definition resolved-type)
                          "i64")
                        (compiler-semantic-record-span-text-eq?
                          source
                          import-use
                          "dep.imported-value")
                        (compiler-semantic-symbol-id-eq?
                          (struct-get import-definition symbol)
                          (struct-get import-use symbol))
                        (compiler-semantic-symbol-id-eq?
                          (struct-get answer symbol)
                          (struct-get answer-use symbol))
                        (compiler-semantic-symbol-id-eq?
                          (struct-get use symbol)
                          (struct-get function-use symbol))
                        (compiler-semantic-record-span-text-eq?
                          source
                          answer-use
                          "answer")
                        (compiler-semantic-record-span-text-eq?
                          source
                          function-use
                          "use")
                        (not (struct-get generated editable))
                        (match (struct-get generated provenance)
                          [(CompilerSemanticProvenance.Generated _ _ _) true]
                          [_ false])
                        (compiler-semantic-symbol-id-eq?
                          (struct-get pattern-definition symbol)
                          (struct-get pattern-use symbol))
                        (compiler-semantic-record-span-text-eq?
                          source
                          pattern-definition
                          "bound")
                        (compiler-semantic-record-span-text-eq?
                          source
                          pattern-use
                          "bound")
                        (string.eq
                          (struct-get pattern-definition resolved-type)
                          "i64")
                        (string.eq
                          (struct-get import-definition documentation)
                          "Imported value documentation.\nAdditional import detail.")
                        (> (struct-get answer module-id) 0)
                        (=
                          (struct-get answer-symbol module-id)
                          (struct-get second-symbol module-id))
                        (=
                          (struct-get answer-symbol declaration-ordinal)
                          (struct-get second-symbol declaration-ordinal))
                        (>= second-param-index 0)
                        (compiler-semantic-symbol-id-eq?
                          (struct-get param-definition symbol)
                          (struct-get second-param symbol))
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

(define (compiler-check-semantic-index-inferred-locals-ok?) : bool
  (let
    [path : String "src/tests/semantic_index_inferred_locals.tl"]
    [source : String
      "(define (plus-one [x : i64]) : i64 (+ x 1))
(define (drop-i64 [_value : i64]) : unit unit)
(defenum SemanticChoice (SemanticEmpty) (SemanticFull i64))
(define (enum-probe [value : SemanticChoice]) : i64
  (match value
    [SemanticEmpty 0]
    [(SemanticFull item) item]))
(define (resource-probe) : i64
  (with ([resource 7 drop-i64]) (+ resource 1)))
(define (probe) : i64
  (let
    [scalar true]
    [closure (lambda ([x : i64]) : i64 (if scalar x x))]
    [alias closure]
    [callback plus-one]
    [nested
      (let
        [callback (lambda ([flag : bool]) : bool flag)]
        (callback scalar))]
    (if nested (alias (callback 0)) 0)))"]
    (match (compiler-check-source-index-with-roots path source (svec.new))
      [(ResultCompilerCheckWithSemanticIndex.Ok _ first)
        (let
          [scalar-definition-index : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& first)
              path
              "scalar"
              CompilerSemanticRecordRole.Definition
              0)]
          [closure-definition-index : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& first)
              path
              "closure"
              CompilerSemanticRecordRole.Definition
              0)]
          [alias-definition-index : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& first)
              path
              "alias"
              CompilerSemanticRecordRole.Definition
              0)]
          [outer-callback-definition-index : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& first)
              path
              "callback"
              CompilerSemanticRecordRole.Definition
              0)]
          [inner-callback-definition-index : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& first)
              path
              "callback"
              CompilerSemanticRecordRole.Definition
              1)]
          [resource-definition-index : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& first)
              path
              "resource"
              CompilerSemanticRecordRole.Definition
              0)]
          [enum-variant-definition-index : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& first)
              path
              "SemanticEmpty"
              CompilerSemanticRecordRole.Definition
              0)]
          [enum-item-definition-index : i64
            (compiler-semantic-source-index-find-name-occurrence
              (& first)
              path
              "item"
              CompilerSemanticRecordRole.Definition
              0)]
          (if (or
            (< scalar-definition-index 0)
            (< closure-definition-index 0)
            (< alias-definition-index 0)
            (< outer-callback-definition-index 0)
            (< inner-callback-definition-index 0)
            (< resource-definition-index 0)
            (>= enum-variant-definition-index 0)
            (< enum-item-definition-index 0))
            (begin
              (compiler-semantic-source-index-release! (&mut first))
              false)
            (let
              [scalar-definition : CompilerSemanticRecord
                (compiler-semantic-source-index-get
                  (& first)
                  scalar-definition-index)]
              [closure-definition : CompilerSemanticRecord
                (compiler-semantic-source-index-get
                  (& first)
                  closure-definition-index)]
              [alias-definition : CompilerSemanticRecord
                (compiler-semantic-source-index-get
                  (& first)
                  alias-definition-index)]
              [outer-callback-definition : CompilerSemanticRecord
                (compiler-semantic-source-index-get
                  (& first)
                  outer-callback-definition-index)]
              [inner-callback-definition : CompilerSemanticRecord
                (compiler-semantic-source-index-get
                  (& first)
                  inner-callback-definition-index)]
              [resource-definition : CompilerSemanticRecord
                (compiler-semantic-source-index-get
                  (& first)
                  resource-definition-index)]
              [enum-item-definition : CompilerSemanticRecord
                (compiler-semantic-source-index-get
                  (& first)
                  enum-item-definition-index)]
              [closure-use-index : i64
                (compiler-semantic-source-index-find-symbol-role
                  (& first)
                  (struct-get closure-definition symbol)
                  CompilerSemanticRecordRole.Use)]
              [alias-use-index : i64
                (compiler-semantic-source-index-find-symbol-role
                  (& first)
                  (struct-get alias-definition symbol)
                  CompilerSemanticRecordRole.Use)]
              [outer-callback-use-index : i64
                (compiler-semantic-source-index-find-symbol-role
                  (& first)
                  (struct-get outer-callback-definition symbol)
                  CompilerSemanticRecordRole.Use)]
              [inner-callback-use-index : i64
                (compiler-semantic-source-index-find-symbol-role
                  (& first)
                  (struct-get inner-callback-definition symbol)
                  CompilerSemanticRecordRole.Use)]
              [resource-use-index : i64
                (compiler-semantic-source-index-find-symbol-role
                  (& first)
                  (struct-get resource-definition symbol)
                  CompilerSemanticRecordRole.Use)]
              [enum-item-use-index : i64
                (compiler-semantic-source-index-find-symbol-role
                  (& first)
                  (struct-get enum-item-definition symbol)
                  CompilerSemanticRecordRole.Use)]
              [closure-use : CompilerSemanticRecord
                (compiler-semantic-source-index-get (& first) closure-use-index)]
              [alias-use : CompilerSemanticRecord
                (compiler-semantic-source-index-get (& first) alias-use-index)]
              [outer-callback-use : CompilerSemanticRecord
                (compiler-semantic-source-index-get
                  (& first)
                  outer-callback-use-index)]
              [inner-callback-use : CompilerSemanticRecord
                (compiler-semantic-source-index-get
                  (& first)
                  inner-callback-use-index)]
              [resource-use : CompilerSemanticRecord
                (compiler-semantic-source-index-get
                  (& first)
                  resource-use-index)]
              [enum-item-use : CompilerSemanticRecord
                (compiler-semantic-source-index-get
                  (& first)
                  enum-item-use-index)]
              (match (compiler-check-source-index-with-roots
                path
                source
                (svec.new))
                [(ResultCompilerCheckWithSemanticIndex.Ok _ second)
                  (let
                    [second-alias-index : i64
                      (compiler-semantic-source-index-find-name-occurrence
                        (& second)
                        path
                        "alias"
                        CompilerSemanticRecordRole.Definition
                        0)]
                    [second-alias : CompilerSemanticRecord
                      (compiler-semantic-source-index-get
                        (& second)
                        second-alias-index)]
                    [ok : bool
                      (and
                        (>= closure-use-index 0)
                        (>= alias-use-index 0)
                        (>= outer-callback-use-index 0)
                        (>= inner-callback-use-index 0)
                        (>= resource-use-index 0)
                        (>= enum-item-use-index 0)
                        (string.eq
                          (struct-get scalar-definition resolved-type)
                          "bool")
                        (string.eq
                          (struct-get closure-definition resolved-type)
                          "(-> i64 i64)")
                        (string.eq
                          (struct-get alias-definition resolved-type)
                          "(-> i64 i64)")
                        (string.eq
                          (struct-get outer-callback-definition resolved-type)
                          "(-> i64 i64)")
                        (string.eq
                          (struct-get inner-callback-definition resolved-type)
                          "(-> bool bool)")
                        (string.eq
                          (struct-get resource-definition resolved-type)
                          "i64")
                        (string.eq
                          (struct-get enum-item-definition resolved-type)
                          "i64")
                        (string.eq
                          (struct-get closure-use resolved-type)
                          "(-> i64 i64)")
                        (string.eq
                          (struct-get alias-use resolved-type)
                          "(-> i64 i64)")
                        (string.eq
                          (struct-get outer-callback-use resolved-type)
                          "(-> i64 i64)")
                        (string.eq
                          (struct-get inner-callback-use resolved-type)
                          "(-> bool bool)")
                        (string.eq
                          (struct-get resource-use resolved-type)
                          "i64")
                        (string.eq
                          (struct-get enum-item-use resolved-type)
                          "i64")
                        (not
                          (compiler-semantic-symbol-id-eq?
                            (struct-get outer-callback-definition symbol)
                            (struct-get inner-callback-definition symbol)))
                        (string.eq
                          (struct-get second-alias resolved-type)
                          "(-> i64 i64)")
                        ;; The second complete check resets compiler state; the
                        ;; first index must still own its rendered type text.
                        (string.eq
                          (struct-get alias-definition resolved-type)
                          "(-> i64 i64)"))]
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

(define (compiler-check-semantic-index-ok?) : bool
  (and
    (compiler-check-semantic-index-base-ok?)
    (compiler-check-semantic-index-inferred-locals-ok?)))