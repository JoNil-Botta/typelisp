;; compiler_parse_core.tl - reader.Sexpr -> real compiler AST parser.
;;
;; This module targets `compiler_ast_types.tl`, not the smaller
;; compile_smoke AST. It stays parser-only: the later selfhost passes consume
;; the parsed `AstProgram` for typechecking/lowering.
(import stdlib.array)
(import stdlib.io)
(import compiler_intern as ci)
(import "compiler_ast_types.tl")
(import compiler_builtin_ids as cbi)
(import "compiler_diagnostic.tl")
(import lex as lexer)
(import read as reader)
(import sym_i64_env)
(import stdlib.string)
(import stdlib.option)
(import stdlib.arena)
(import token)
(import (option.option i64) as option_i64)

(defenum CompilerParseMaybeDeclSpan
  (Some AstSourceSpan)
  (None))

(define (compiler-parse-decl-origin-cache-reset!) : unit
  unit)

(define (compiler-parse-token-span-from-ast-span [span : AstSourceSpan]) : token.SourceSpan
  (token.SourceSpan
    (ast-source-span-start-line span)
    (ast-source-span-start-col span)
    (ast-source-span-end-line span)
    (ast-source-span-end-col span)))

(define (compiler-parse-decl-list-storage-key [decls : (& decls AstDeclList)]) : i64
  (unsafe
    (cast
      (ptr->int (ptr-cast (array-data (struct-get decls slots)) : (Ptr u8)))
      : i64)))

;; Declaration origins are cold records in the transient spanned-node pool.
;; A run is marker(key), marker(start slot), then one Nil(span) per slot.
(define (compiler-parse-decl-origin-span-key-slot-depth
  [key : i64]
  [target : i64]
  [depth : i64]) : CompilerParseMaybeDeclSpan
  (let
    [cursor : i64 0]
    [result : CompilerParseMaybeDeclSpan (CompilerParseMaybeDeclSpan.None)]
    [alias-key : i64 0]
    [alias-slot : i64 0]
    [alias-found : bool false]
    (begin
      (while (< cursor (reader.sp-node-pool-len))
        (begin
          (match (reader.sp-node-get cursor)
            [(reader.SpannedSexpr.Int record-key marker marker-span)
              (if (= record-key key)
                (if (and
                  (string.eq marker "__tl_decl_origin")
                  (< (+ cursor 2) (reader.sp-node-pool-len)))
                  (match (reader.sp-node-get (+ cursor 1))
                    [(reader.SpannedSexpr.Int run-start run-marker _)
                      (if (and
                        (= run-start target)
                        (string.eq run-marker "__tl_decl_origin_start"))
                        (match (reader.sp-node-get (+ cursor 2))
                          [(reader.SpannedSexpr.Nil span)
                            (begin
                              (set!
                                result
                                (CompilerParseMaybeDeclSpan.Some
                                  (ast-source-span-from-source-span span)))
                              (set! alias-found false))]
                          [_ unit])
                        unit)]
                    [_ unit])
                  (if (or
                    (string.eq marker "__tl_decl_origin_alias")
                    (string.eq marker "__tl_decl_origin_alias_repeat"))
                    (let
                      [alias-start : i64 (token.span-start-line marker-span)]
                      [alias-count : i64 (token.span-start-col marker-span)]
                      (if (and
                        (>= target alias-start)
                        (< target (+ alias-start alias-count)))
                        (begin
                          (set! alias-key (token.span-end-line marker-span))
                          (set!
                            alias-slot
                            (if (string.eq
                              marker
                              "__tl_decl_origin_alias_repeat")
                              (token.span-end-col marker-span)
                              (+
                                (token.span-end-col marker-span)
                                (- target alias-start))))
                          (set! alias-found true))
                        unit))
                    unit))
                unit)]
            [_ unit])
          (set! cursor (+ cursor 1))))
      (if (and alias-found (< depth 64))
        (compiler-parse-decl-origin-span-key-slot-depth
          alias-key
          alias-slot
          (+ depth 1))
        result))))

(define (compiler-parse-decl-origin-span-key-slot [key : i64] [target : i64]) : CompilerParseMaybeDeclSpan
  (compiler-parse-decl-origin-span-key-slot-depth key target 0))

(define (compiler-parse-decl-origin-span
  [decls : (& decls AstDeclList)]
  [slot : i64]) : CompilerParseMaybeDeclSpan
  (compiler-parse-decl-origin-span-key-slot
    (compiler-parse-decl-list-storage-key decls)
    (+ (struct-get decls offset) slot)))

(define (compiler-parse-decl-origin-register-key-maybe!
  [key : i64]
  [slot : i64]
  [origin : CompilerParseMaybeDeclSpan]) : unit
  (match origin
    [(CompilerParseMaybeDeclSpan.Some span)
      (let
        [marker-span : token.SourceSpan
          (compiler-parse-token-span-from-ast-span span)]
        (begin
          (reader.sp-node-push
            (reader.SpannedSexpr.Int key "__tl_decl_origin" marker-span))
          (reader.sp-node-push
            (reader.SpannedSexpr.Int slot "__tl_decl_origin_start" marker-span))
          (reader.sp-node-push (reader.SpannedSexpr.Nil marker-span))
          unit))]
    [(CompilerParseMaybeDeclSpan.None) unit]))

(define (compiler-parse-decl-origin-register-maybe!
  [decls : (& decls AstDeclList)]
  [slot : i64]
  [origin : CompilerParseMaybeDeclSpan]) : unit
  (compiler-parse-decl-origin-register-key-maybe!
    (compiler-parse-decl-list-storage-key decls)
    (+ (struct-get decls offset) slot)
    origin))

(define (compiler-parse-decl-origin-register-alias-record!
  [decls : (& decls AstDeclList)]
  [decl-slot : i64]
  [count : i64]
  [source-key : i64]
  [source-slot : i64]
  [repeat : bool]) : unit
  (if (<= count 0)
    unit
    (begin
      (reader.sp-node-push
        (reader.SpannedSexpr.Int
          (compiler-parse-decl-list-storage-key decls)
          (if repeat
            "__tl_decl_origin_alias_repeat"
            "__tl_decl_origin_alias")
          (token.SourceSpan
            (+ (struct-get decls offset) decl-slot)
            count
            source-key
            source-slot)))
      unit)))

(define (compiler-parse-decl-origin-copy-direct-records!
  [source : AstDeclList]
  [dest : (& dest AstDeclList)]
  [dest-slot : i64]
  [scan-start : i64]
  [scan-end : i64]) : unit
  (let
    [source-key : i64 (compiler-parse-decl-list-storage-key (& source))]
    [source-start : i64 (struct-get source offset)]
    [source-end : i64 (+ source-start (ast-decl-list-len (& source)))]
    [dest-key : i64 (compiler-parse-decl-list-storage-key dest)]
    [dest-start : i64 (+ (struct-get dest offset) dest-slot)]
    [cursor : i64 scan-start]
    [limit : i64 scan-end]
    (while (< cursor limit)
      (begin
        (match (reader.sp-node-get cursor)
          [(reader.SpannedSexpr.Int record-key marker _)
            (if (and
              (= record-key source-key)
              (string.eq marker "__tl_decl_origin")
              (< (+ cursor 2) limit))
              (match (reader.sp-node-get (+ cursor 1))
                [(reader.SpannedSexpr.Int record-slot run-marker marker-span)
                  (if (and
                    (string.eq run-marker "__tl_decl_origin_start")
                    (>= record-slot source-start)
                    (< record-slot source-end))
                    (begin
                      (reader.sp-node-push
                        (reader.SpannedSexpr.Int
                          dest-key
                          "__tl_decl_origin"
                          marker-span))
                      (reader.sp-node-push
                        (reader.SpannedSexpr.Int
                          (+ dest-start (- record-slot source-start))
                          "__tl_decl_origin_start"
                          marker-span))
                      (reader.sp-node-push (reader.sp-node-get (+ cursor 2)))
                      unit)
                    unit)]
                [_ unit])
              unit)]
          [_ unit])
        (set! cursor (+ cursor 1))))))

(define (compiler-parse-decl-origin-register-list-aliases!
  [decls : (& decls AstDeclList)]
  [decl-slot : i64]
  [source : AstDeclList]) : unit
  (compiler-parse-decl-origin-register-alias-record!
    decls
    decl-slot
    (ast-decl-list-len (& source))
    (compiler-parse-decl-list-storage-key (& source))
    (struct-get source offset)
    false))

(defstruct CompilerParseDeclOriginAlias
  (target-start i64)
  (count i64)
  (source-key i64)
  (source-slot i64))

(defstruct CompilerParseDeclOriginAliasVec
  (items (Array CompilerParseDeclOriginAlias))
  (len i64))

(define (compiler-parse-decl-origin-alias-vec-with-capacity [capacity : i64]) : CompilerParseDeclOriginAliasVec
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (CompilerParseDeclOriginAliasVec
      (make-array CompilerParseDeclOriginAlias cap)
      0)))

(define (compiler-parse-decl-origin-alias-vec-grow!
  [aliases : (&mut aliases CompilerParseDeclOriginAliasVec)]) : unit
  (let
    [old-items : (Array CompilerParseDeclOriginAlias)
      (struct-get aliases items)]
    [len : i64 (struct-get aliases len)]
    [next-items : (Array CompilerParseDeclOriginAlias)
      (make-array CompilerParseDeclOriginAlias (* (array-length old-items) 2))]
    [index : i64 0]
    (begin
      (while (< index len)
        (let
          [item : CompilerParseDeclOriginAlias (array-ref old-items index)]
          (begin
            (array-set!
              next-items
              index
              (CompilerParseDeclOriginAlias
                (struct-get item target-start)
                (struct-get item count)
                (struct-get item source-key)
                (struct-get item source-slot)))
            (set! index (+ index 1)))))
      (set! (struct-get aliases items) next-items))))

(define (compiler-parse-decl-origin-alias-vec-extend-last?
  [aliases : (&mut aliases CompilerParseDeclOriginAliasVec)]
  [target-start : i64]
  [count : i64]
  [source-key : i64]
  [source-slot : i64]
  [repeat : bool]) : bool
  (if (or repeat (<= (struct-get aliases len) 0))
    false
    (let
      [index : i64 (- (struct-get aliases len) 1)]
      [last : CompilerParseDeclOriginAlias
        (array-ref (struct-get aliases items) index)]
      (if (and
        (>= (struct-get last source-slot) 0)
        (= (struct-get last source-key) source-key)
        (=
          (+ (struct-get last target-start) (struct-get last count))
          target-start)
        (=
          (+ (struct-get last source-slot) (struct-get last count))
          source-slot))
        (begin
          (array-set!
            (struct-get aliases items)
            index
            (CompilerParseDeclOriginAlias
              (struct-get last target-start)
              (+ (struct-get last count) count)
              (struct-get last source-key)
              (struct-get last source-slot)))
          true)
        false))))

(define (compiler-parse-decl-origin-alias-vec-push-key-slot!
  [aliases : (&mut aliases CompilerParseDeclOriginAliasVec)]
  [target-start : i64]
  [count : i64]
  [source-key : i64]
  [source-slot : i64]
  [source-decl : AstDecl]
  [repeat : bool]) : unit
  (if (and (> count 0) (compiler-parse-decl-origin-needs-record? source-decl))
    (if (compiler-parse-decl-origin-alias-vec-extend-last?
      aliases
      target-start
      count
      source-key
      source-slot
      repeat)
      unit
      (begin
        (if (>=
          (struct-get aliases len)
          (array-length (struct-get aliases items)))
          (compiler-parse-decl-origin-alias-vec-grow! aliases)
          unit)
        (let
          [index : i64 (struct-get aliases len)]
          (begin
            (array-set!
              (struct-get aliases items)
              index
              (CompilerParseDeclOriginAlias
                target-start
                count
                source-key
                (if repeat
                  (- (- 0 source-slot) 1)
                  source-slot)))
            (set! (struct-get aliases len) (+ index 1))))))
    unit))

(define (compiler-parse-decl-origin-alias-vec-push!
  [aliases : (&mut aliases CompilerParseDeclOriginAliasVec)]
  [target-start : i64]
  [count : i64]
  [source : AstDeclList]
  [repeat : bool]) : unit
  (compiler-parse-decl-origin-alias-vec-push-key-slot!
    aliases
    target-start
    count
    (compiler-parse-decl-list-storage-key (& source))
    (struct-get source offset)
    (ast-decl-list-get (& source) 0 (ast-decl-fallback))
    repeat))

(define (compiler-parse-decl-origin-alias-vec-register!
  [decls : (& decls AstDeclList)]
  [aliases : (& aliases CompilerParseDeclOriginAliasVec)]) : unit
  (let
    [index : i64 0]
    (while (< index (struct-get aliases len))
      (let
        [alias : CompilerParseDeclOriginAlias
          (array-ref (struct-get aliases items) index)]
        (begin
          (compiler-parse-decl-origin-register-alias-record!
            decls
            (struct-get alias target-start)
            (struct-get alias count)
            (struct-get alias source-key)
            (if (< (struct-get alias source-slot) 0)
              (- (- 0 (struct-get alias source-slot)) 1)
              (struct-get alias source-slot))
            (< (struct-get alias source-slot) 0))
          (set! index (+ index 1)))))))

;; Aggregate member origins reuse the transient spanned-node pool instead of
;; widening hot AST nodes. After each top-level form, only marker + span records
;; are compacted below the next form's pool mark; lookup is error-path-only.
(define (compiler-parse-member-origin-span
  [key : i64]
  [member-index : i64]
  [fallback : AstSourceSpan]) : AstSourceSpan
  (let
    [cursor : i64 0]
    [result : AstSourceSpan fallback]
    (begin
      (while (< cursor (reader.sp-node-pool-len))
        (begin
          (match (reader.sp-node-get cursor)
            [(reader.SpannedSexpr.Int record-key marker marker-span)
              (if (and
                (= record-key key)
                (string.eq marker "__tl_member_origin"))
                (let
                  [record-index : i64 (+ cursor 1)]
                  [record-offset : i64 0]
                  [done : bool false]
                  (begin
                    ;; The marker span is the aggregate name and remains a
                    ;; useful fallback if a later transform appends a member.
                    (set! result (ast-source-span-from-source-span marker-span))
                    (while (and
                      (not done)
                      (< record-index (reader.sp-node-pool-len)))
                      (match (reader.sp-node-get record-index)
                        [(reader.SpannedSexpr.Nil span)
                          (if (= record-offset member-index)
                            (begin
                              (set!
                                result
                                (ast-source-span-from-source-span span))
                              (set! done true))
                            (begin
                              (set! record-index (+ record-index 1))
                              (set! record-offset (+ record-offset 1))))]
                        [_ (set! done true)]))))
                unit)]
            [_ unit])
          (set! cursor (+ cursor 1))))
      result)))

(define (compiler-parse-field-def-list-span-get
  [fields : (& fields AstFieldDefList)]
  [index : i64]
  [fallback : AstSourceSpan]) : AstSourceSpan
  (compiler-parse-member-origin-span
    (unsafe
      (cast
        (ptr->int (ptr-cast (array-data (struct-get fields slots)) : (Ptr u8)))
        : i64))
    index
    fallback))

(define (compiler-parse-variant-def-list-span-get
  [variants : (& variants AstVariantDefList)]
  [index : i64]
  [fallback : AstSourceSpan]) : AstSourceSpan
  (compiler-parse-member-origin-span
    (unsafe
      (cast
        (ptr->int
          (ptr-cast (array-data (struct-get variants slots)) : (Ptr u8)))
        : i64))
    index
    fallback))

(define (compiler-parse-member-records-compact!
  [mark : i64]
  [records-start : i64]) : unit
  (let
    [read-index : i64 records-start]
    [write-index : i64 mark]
    [end : i64 (reader.sp-node-pool-len)]
    (begin
      (while (< read-index end)
        (begin
          (array-set!
            reader.sp-node-pool-slots
            write-index
            (reader.sp-node-get read-index))
          (set! read-index (+ read-index 1))
          (set! write-index (+ write-index 1))))
      (reader.sp-node-pool-truncate! write-index))))

(defenum ResultAstType
  (Ok AstType)
  (Err String))

(defenum ResultAstReduceOp
  (Ok AstReduceOp)
  (Err String))

(defenum ResultAstFuncTypeParts
  (Ok AstTypeList AstType)
  (Err String))

(defenum ResultAstTypeList
  (Ok AstTypeList)
  (Err String))

(defenum ResultAstTypeListBuild
  (Ok)
  (Err String))

(defenum ResultAstLifetimeList
  (Ok AstLifetimeList)
  (Err String))

(defenum ResultAstLifetimeListBuild
  (Ok)
  (Err String))

(defenum ResultAstParam
  (Ok AstParam)
  (Err String))

(defenum ResultAstParamList
  (Ok AstParamList)
  (Err String))

(defenum ResultAstParamListBuild
  (Ok)
  (Err String))

(defenum ResultAstMacroParam
  (Ok AstMacroParam)
  (Err String))

(defenum ResultAstMacroTypeKindList
  (Ok AstMacroTypeKindList)
  (Err String))

(defenum ResultAstMacroParamList
  (Ok AstMacroParamList)
  (Err String))

(defenum ResultAstMacroParamListBuild
  (Ok)
  (Err String))

(defenum ResultAstFieldDef
  (Ok AstFieldDef)
  (Err String))

(defenum ResultAstFieldDefList
  (Ok AstFieldDefList)
  (Err String))

(defenum ResultAstFieldDefListBuild
  (Ok)
  (Err String))

(defenum ResultAstFieldCleanup
  (Ok AstFieldCleanup)
  (Err String))

(defenum ResultAstStructRepr
  (Ok AstStructRepr)
  (Err String))

(defenum ResultAstStructCleanup
  (Ok AstStructCleanup)
  (Err String))

(defenum ResultAstEnumCleanup
  (Ok AstEnumCleanup)
  (Err String))

(defenum ResultAstVariantPayloadCleanup
  (Ok AstVariantPayloadCleanup)
  (Err String))

(defenum ResultAstVariantPayloadParts
  (Ok AstTypeList AstVariantPayloadCleanupList)
  (Err String))

(defenum ResultAstStructDefParts
  (Ok AstLifetimeList AstStructRepr AstStructCleanup AstFieldDefList)
  (Err String))

(defenum ResultAstEnumDefParts
  (Ok AstLifetimeList AstEnumCleanup AstVariantDefList)
  (Err String))

(defenum ResultAstExternAbi
  (Ok AstExternAbi)
  (Err String))

(defenum ResultAstExternSymbol
  (Ok String i64)
  (Err String))

(defenum ResultAstFnExport
  (Ok AstFnExport)
  (Err String))

(defenum ResultAstSpmdParamClassList
  (Ok AstSpmdParamClassList)
  (Err String))

(defenum ResultAstSpmdResultClass
  (Ok AstSpmdResultClass)
  (Err String))

(defenum ResultAstSpmdIndexParam
  (Ok i64)
  (Err String))

(defenum ResultAstSpmdSpecialization
  (Ok AstSpmdSpecialization)
  (Err String))

(defenum ResultAstSpmdCallable
  (Ok AstSpmdCallable)
  (Err String))

(defstruct AstSpmdSpecializationParseState
  (lanes i64)
  (args AstSpmdParamClassList)
  (result AstSpmdResultClass)
  (index-param i64)
  (seen-lanes bool)
  (seen-args bool)
  (seen-result bool)
  (seen-index-param bool))

(defenum ResultAstSpmdSpecializationParseState
  (Ok AstSpmdSpecializationParseState)
  (Err String))

(defenum ResultAstExternParts
  (Ok AstExternAbi i64 bool AstType)
  (Err String))

(defenum AstExternHeadItem
  (Param AstType)
  (VarargsOpen)
  (VarargsTyped AstType))

(defenum ResultAstExternHeadItem
  (Ok AstExternHeadItem)
  (Err String))

(defenum ResultAstExternHeader
  (Ok i64 AstTypeList AstExternAbi)
  (Err String))

(defenum ResultAstVariantDef
  (Ok AstVariantDef)
  (Err String))

(defenum ResultAstVariantDefList
  (Ok AstVariantDefList)
  (Err String))

(defenum ResultAstVariantDefListBuild
  (Ok)
  (Err String))

(defenum ResultAstDispatchIsa
  (Ok AstDispatchIsa)
  (Err String))

(defenum ResultAstDispatchVariant
  (Ok AstDispatchVariant)
  (Err String))

(defenum ResultAstDispatchVariantList
  (Ok AstDispatchVariantList)
  (Err String))

(defenum ResultAstDispatchVariantListBuild
  (Ok)
  (Err String))

(defenum ResultAstPattern
  (Ok AstPattern)
  (Err String))

(defenum ResultAstPatternList
  (Ok AstPatternList)
  (Err String))

(defenum ResultAstPatternListBuild
  (Ok)
  (Err String))

(defenum ResultAstLetBinding
  (Ok AstLetBinding)
  (Err String))

(defenum ResultAstResourceBinding
  (Ok AstResourceBinding)
  (Err String))

(defenum ResultAstResourceBindingList
  (Ok AstResourceBindingList)
  (Err String))

(defenum ResultAstResourceBindingListBuild
  (Ok)
  (Err String))

(defenum ResultAstLetParts
  (Ok AstLetBindingList i64)
  (Err String))

(defenum ResultAstMatchArm
  (Ok AstMatchArm)
  (Err String))

(defenum ResultAstMatchArmList
  (Ok AstMatchArmList)
  (Err String))

(defenum ResultAstMatchArmListBuild
  (Ok)
  (Err String))

(defenum ResultAstExpr
  (Ok i64)
  (Err String))

(defstruct AstExprPair
  (first i64)
  (second i64))

(defenum ResultAstExprPair
  (Ok AstExprPair)
  (Err String))

(defenum ResultAstExprList
  (Ok AstExprList)
  (Err String))

(defenum ResultAstExprListBuild
  (Ok)
  (Err String))

(defenum ResultAstDecl
  (Ok AstDecl)
  (Err String))

(defenum ResultAstMaybeDecl
  (NoDecl)
  (SomeDecl AstDecl)
  (Decls AstDeclList)
  (Err String))

(defenum ResultAstDeclList
  (Ok AstDeclList)
  (Err String))

(defenum ResultParseAstDeclVec
  (Ok)
  (Err String))

(defenum ResultParseAstDeclVecDiagnostic
  (Ok)
  (Err (Box CompilerDiagnostic)))

(defenum ResultAstMaybeExpr
  (NoExpr)
  (SomeExpr i64)
  (Err String))

(defenum ResultCompilerCfg
  (Ok bool)
  (Err String))

(defenum ResultAstProgram
  (Ok AstProgram)
  (Err String))

(defenum AstReplItem
  (AstReplDecl AstDecl)
  (AstReplExpr i64))

(defenum ResultAstReplItem
  (Ok AstReplItem)
  (Err String))

(defenum ResultAstDeclListDiagnostic
  (Ok AstDeclList)
  (Err (Box CompilerDiagnostic)))

(defenum ResultAstProgramDiagnostic
  (Ok AstProgram)
  (Err (Box CompilerDiagnostic)))

;; Mutable parser data belongs to one compiler driver. The fixed dispatch
;; arrays avoid arena-lifetime coupling in a state that survives individual
;; file parses; the cached immutable environment is rebuilt when its owning
;; intern table resets. Standalone parser helpers use the default state below
;; as a compatibility adapter, while production drivers attach their state to
;; cfgs with compiler-parse-state-cfgs.
(defstruct CompilerParseState
  (control (Array i64))
  (dispatch-index-keys (Array i64))
  (dispatch-index-tags (Array i64))
  (dispatch-cache (Array sym_i64_env.SymI64Env))
  (dispatch-cache-handle (Array (Array sym_i64_env.SymI64Env)))
  (intern-owner (Array ci.InternCompatState)))

(define compiler-parse-state-control-keys-addr : i64
  0)
(define compiler-parse-state-control-tags-addr : i64
  1)
(define compiler-parse-state-control-cache-addr : i64
  2)
(define compiler-parse-state-control-owner-addr : i64
  3)
(define compiler-parse-state-control-cache-generation : i64
  4)
(define compiler-parse-state-control-cache-table-id : i64
  5)
(define compiler-parse-state-control-marker-id : i64
  6)
(define compiler-parse-state-control-ready : i64
  7)
(define compiler-parse-state-control-has-type-literal : i64
  8)
(define compiler-parse-state-control-reserved : i64
  9)
(define compiler-parse-state-marker-id : i64
  -2)
(define compiler-parse-invocation-marker-id : i64
  -3)
(define compiler-parse-invocation-control-slot : i64
  5)

(define (compiler-parse-array-data-addr-i64 [items : (Array i64)]) : i64
  (cast
    (unsafe
      (ptr->int (ptr-cast (array-data items) : (Ptr u8))))
    : i64))

(define (compiler-parse-intern-owner-data-addr
  [items : (Array ci.InternCompatState)]) : i64
  (if (= (array-length items) 0)
    0
    (cast
      (unsafe
        (ptr->int (ptr-cast (array-data items) : (Ptr u8))))
      : i64)))

(define (compiler-parse-dispatch-cache-handle-data-addr
  [items : (Array (Array sym_i64_env.SymI64Env))]) : i64
  (cast
    (unsafe
      (ptr->int (ptr-cast (array-data items) : (Ptr u8))))
    : i64))

(define (compiler-parse-state-new-from-owner
  [owner : (Array ci.InternCompatState)]) : CompilerParseState
  (let
    [control : (Array i64) (array.make-array i64 10)]
    [keys : (Array i64) (array.make-array i64 512)]
    [tags : (Array i64) (array.make-array i64 512)]
    [cache : (Array sym_i64_env.SymI64Env)
      (array.make-array sym_i64_env.SymI64Env 1)]
    [cache-handle : (Array (Array sym_i64_env.SymI64Env))
      (array.make-array (Array sym_i64_env.SymI64Env) 1)]
    (begin
      (array-set! cache 0 (sym_i64_env.sym-i64-empty))
      (array-set! cache-handle 0 cache)
      (array-set!
        control
        compiler-parse-state-control-keys-addr
        (compiler-parse-array-data-addr-i64 keys))
      (array-set!
        control
        compiler-parse-state-control-tags-addr
        (compiler-parse-array-data-addr-i64 tags))
      (array-set!
        control
        compiler-parse-state-control-cache-addr
        (compiler-parse-dispatch-cache-handle-data-addr cache-handle))
      (array-set!
        control
        compiler-parse-state-control-owner-addr
        (compiler-parse-intern-owner-data-addr owner))
      (array-set! control compiler-parse-state-control-cache-generation -1)
      (array-set! control compiler-parse-state-control-cache-table-id -1)
      (array-set! control compiler-parse-state-control-marker-id -1)
      (array-set! control compiler-parse-state-control-ready 0)
      (array-set! control compiler-parse-state-control-has-type-literal 0)
      (array-set! control compiler-parse-state-control-reserved 0)
      (CompilerParseState control keys tags cache cache-handle owner))))

(define (compiler-parse-state-new) : CompilerParseState
  (compiler-parse-state-new-from-owner
    (array.make-array ci.InternCompatState 0)))

(define (compiler-parse-state-new-with-intern-state
  [intern-state : ci.InternCompatState]) : CompilerParseState
  (let
    [owner : (Array ci.InternCompatState)
      (array.make-array ci.InternCompatState 1)]
    (begin
      (array-set! owner 0 intern-state)
      (compiler-parse-state-new-from-owner owner))))

(define (compiler-parse-state-control-addr [state : CompilerParseState]) : i64
  (compiler-parse-array-data-addr-i64 (struct-get state control)))

(define (compiler-parse-raw-i64-ref [address : i64] [index : i64]) : i64
  (unsafe
    (ptr-read (ptr-offset (int->ptr address : (Ptr i64)) index))))

(define (compiler-parse-raw-i64-set!
  [address : i64]
  [index : i64]
  [value : i64]) : unit
  (unsafe
    (ptr-write! (ptr-offset (int->ptr address : (MutPtr i64)) index) value)))

(define (compiler-parse-state-owner [control : i64]) : ci.InternCompatState
  (unsafe
    (ptr-read
      (int->ptr
        (compiler-parse-raw-i64-ref
          control
          compiler-parse-state-control-owner-addr)
        : (Ptr ci.InternCompatState)))))

(define (compiler-parse-state-owner-generation [control : i64]) : i64
  (if (=
    (compiler-parse-raw-i64-ref control compiler-parse-state-control-owner-addr)
    0)
    (intern-generation)
    (ci.intern-compat-state-generation (compiler-parse-state-owner control))))

(define (compiler-parse-state-owner-table-id [control : i64]) : i64
  (if (=
    (compiler-parse-raw-i64-ref control compiler-parse-state-control-owner-addr)
    0)
    (ci.intern-active-table-id)
    (ci.intern-compat-state-table-id (compiler-parse-state-owner control))))

(define (compiler-parse-state-owner-persistent-arena [control : i64]) : i64
  (if (=
    (compiler-parse-raw-i64-ref control compiler-parse-state-control-owner-addr)
    0)
    (ci.intern-persistent-arena-handle)
    (ci.intern-compat-state-persistent-arena
      (compiler-parse-state-owner control))))

(define (compiler-parse-env-marker-value
  [dispatch : sym_i64_env.SymI64Env]
  [marker-id : i64]) : i64
  (let
    [cursor : sym_i64_env.SymI64Env dispatch]
    (begin
      (while true
        (match cursor
          [(sym_i64_env.SymI64Nil) (return 0)]
          [(sym_i64_env.SymI64Bind name-id value rest)
            (if (= name-id marker-id)
              (return value)
              (set! cursor (box-get rest)))]))
      0)))

(define (compiler-parse-state-cfgs
  [state : CompilerParseState]
  [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (sym_i64_env.sym-i64-bind-id
    cfgs
    compiler-parse-state-marker-id
    (compiler-parse-state-control-addr state)))

(define (compiler-parse-state-type-literal-reset! [state : CompilerParseState]) : unit
  (array-set!
    (struct-get state control)
    compiler-parse-state-control-has-type-literal
    0))

(define (compiler-parse-state-has-type-literal? [state : CompilerParseState]) : bool
  (not
    (=
      (array-ref
        (struct-get state control)
        compiler-parse-state-control-has-type-literal)
      0)))

;; Compatibility state for direct parser helpers and parser-only tests. Driver
;; paths always attach their own state with compiler-parse-state-cfgs.
(define compiler-parse-default-state : CompilerParseState
  (compiler-parse-state-new))

(define (sexpr-colon? [s : reader.Sexpr]) : bool
  (match s
    [(reader.Sexpr.Sym name-id) (= name-id cbi.compiler-builtin-id-fix-colon)]
    [_ false]))

;; ID-to-text is intentionally a boundary, not a classifier. Production
;; callers are limited to lazy unknown-name diagnostics, prefix/content syntax
;; (`:unknown`, typed `...T`, retired name families), and dotted import paths.
(define (compiler-parse-name-text [name-id : i64]) : String
  (cond
    [(ci.intern-macro-global-structural-id? name-id)
      (ci.intern-str (ci.intern-macro-global-source-name-id name-id))]
    [(ci.intern-composite-pair-id? name-id)
      (string.append
        (ci.intern-str (ci.intern-composite-pair-left-id name-id))
        (string.append
          "/"
          (ci.intern-str (ci.intern-composite-pair-right-id name-id))))]
    [(ci.intern-composite-triple-id? name-id)
      (string.append
        (ci.intern-str (ci.intern-composite-triple-left-id name-id))
        (string.append
          "/"
          (string.append
            (ci.intern-str (ci.intern-composite-triple-middle-id name-id))
            (string.append
              "."
              (ci.intern-str (ci.intern-composite-triple-right-id name-id))))))]
    [else (ci.intern-str name-id)]))

(define (compiler-cfg-key-id [name-id : i64]) : i64
  (+ (ci.intern-capacity) name-id))

(define (compiler-cfg-name-id [key-id : i64]) : i64
  (- key-id (ci.intern-capacity)))

(define (compiler-cfg-key-name [key-id : i64]) : String
  (string.append "cfg:" (ci.intern-str (compiler-cfg-name-id key-id))))

(define (compiler-cfg-name [key-id : i64]) : String
  (ci.intern-str (compiler-cfg-name-id key-id)))

(define (compiler-cfg-empty) : sym_i64_env.SymI64Env
  (sym_i64_env.sym-i64-empty))

(define (compiler-cfg-enable-id [cfgs : sym_i64_env.SymI64Env] [name-id : i64]) : sym_i64_env.SymI64Env
  (compiler-cfg-bind-id cfgs name-id 1))

(define (compiler-cfg-bind-id
  [cfgs : sym_i64_env.SymI64Env]
  [name-id : i64]
  [value : i64]) : sym_i64_env.SymI64Env
  (sym_i64_env.sym-i64-bind-id cfgs (compiler-cfg-key-id name-id) value))

(define (compiler-cfg-enable [cfgs : sym_i64_env.SymI64Env] [name : String]) : sym_i64_env.SymI64Env
  (compiler-cfg-bind cfgs name 1))

(define (compiler-cfg-bind
  [cfgs : sym_i64_env.SymI64Env]
  [name : String]
  [value : i64]) : sym_i64_env.SymI64Env
  (compiler-cfg-bind-id
    cfgs
    (ci.intern-source-slice name 0 (ci.intern-private-string-length name))
    value))

(define (compiler-cfg-enable-with-intern-state
  [cfgs : sym_i64_env.SymI64Env]
  [name : String]
  [intern-state : ci.InternCompatState]) : sym_i64_env.SymI64Env
  (compiler-cfg-enable-id
    cfgs
    (ci.intern-compat-state-intern intern-state name)))

(define (compiler-cfg-merge
  [base : sym_i64_env.SymI64Env]
  [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (match cfgs
    [(sym_i64_env.SymI64Nil) base]
    [(sym_i64_env.SymI64Bind name-id value rest)
      (sym_i64_env.sym-i64-bind-id
        (compiler-cfg-merge base (box-get rest))
        name-id
        value)]))

(define (compiler-cfg-enabled?
  [dispatch : sym_i64_env.SymI64Env]
  [name-id : i64]) : bool
  (sym_i64_env.sym-i64-contains-id dispatch (compiler-cfg-key-id name-id)))

(define (compiler-cfg-eval-list-all
  [dispatch : sym_i64_env.SymI64Env]
  [predicates : reader.SpannedSexpr]) : ResultCompilerCfg
  (match predicates
    [(reader.SpannedSexpr.Nil _) (ResultCompilerCfg.Ok true)]
    [(reader.SpannedSexpr.Cons head tail _)
      (match (compiler-cfg-eval dispatch (reader.sp-node-get head))
        [(ResultCompilerCfg.Ok enabled)
          (if enabled
            (compiler-cfg-eval-list-all dispatch (reader.sp-node-get tail))
            (ResultCompilerCfg.Ok false))]
        [(ResultCompilerCfg.Err message) (ResultCompilerCfg.Err message)])]
    [_ (ResultCompilerCfg.Err "parse: cfg all expects predicates")]))

(define (compiler-cfg-eval-list-any
  [dispatch : sym_i64_env.SymI64Env]
  [predicates : reader.SpannedSexpr]) : ResultCompilerCfg
  (match predicates
    [(reader.SpannedSexpr.Nil _) (ResultCompilerCfg.Ok false)]
    [(reader.SpannedSexpr.Cons head tail _)
      (match (compiler-cfg-eval dispatch (reader.sp-node-get head))
        [(ResultCompilerCfg.Ok enabled)
          (if enabled
            (ResultCompilerCfg.Ok true)
            (compiler-cfg-eval-list-any dispatch (reader.sp-node-get tail)))]
        [(ResultCompilerCfg.Err message) (ResultCompilerCfg.Err message)])]
    [_ (ResultCompilerCfg.Err "parse: cfg any expects predicates")]))

(define (compiler-cfg-eval-not
  [dispatch : sym_i64_env.SymI64Env]
  [predicates : reader.SpannedSexpr]) : ResultCompilerCfg
  (match predicates
    [(reader.SpannedSexpr.Cons pred tail _)
      (match (reader.sp-node-get tail)
        [(reader.SpannedSexpr.Nil _)
          (match (compiler-cfg-eval dispatch (reader.sp-node-get pred))
            [(ResultCompilerCfg.Ok enabled)
              (ResultCompilerCfg.Ok (not enabled))]
            [(ResultCompilerCfg.Err message) (ResultCompilerCfg.Err message)])]
        [_
          (ResultCompilerCfg.Err "parse: cfg not expects exactly one predicate")])]
    [_ (ResultCompilerCfg.Err "parse: cfg not expects exactly one predicate")]))

(define (compiler-cfg-eval
  [dispatch : sym_i64_env.SymI64Env]
  [predicate : reader.SpannedSexpr]) : ResultCompilerCfg
  (match predicate
    [(reader.SpannedSexpr.Sym name _)
      (ResultCompilerCfg.Ok (compiler-cfg-enabled? dispatch name))]
    [(reader.SpannedSexpr.Cons head predicates _)
      (match (reader.sp-node-get head)
        [(reader.SpannedSexpr.Sym op _)
          (cond
            [(= op (cbi.compiler-builtin-ctfe-ref 219))
              (compiler-cfg-eval-list-all
                dispatch
                (reader.sp-node-get predicates))]
            [(= op (cbi.compiler-builtin-ctfe-ref 220))
              (compiler-cfg-eval-list-any
                dispatch
                (reader.sp-node-get predicates))]
            [(= op (cbi.compiler-builtin-ctfe-ref 155))
              (compiler-cfg-eval-not dispatch (reader.sp-node-get predicates))]
            [else
              (ResultCompilerCfg.Err
                "parse: cfg predicate expects a name, all, any, or not")])]
        [_ (ResultCompilerCfg.Err "parse: malformed cfg predicate")])]
    [_ (ResultCompilerCfg.Err "parse: malformed cfg predicate")]))

(define (compiler-parse-abstraction-policy-message) : String
  "parse: TypeLisp does not support source-level generics or traits; use defmacro to generate concrete declarations instead")

(define (compiler-parse-generic-type-policy-message [name : String]) : String
  (cond
    [(string.eq name "varying")
      "parse: public SPMD varying source types are deferred; varying is inferred inside foreach"]
    [(string.eq name "Varying")
      "parse: public SPMD varying source types are deferred; varying is inferred inside foreach"]
    [(string.eq name "Vector")
      "parse: public SPMD vector source types are deferred; vector values remain compiler-internal"]
    [(string.eq name "vector")
      "parse: public SPMD vector source types are deferred; vector values remain compiler-internal"]
    [(string.eq name "Mask")
      "parse: public SPMD mask source types are deferred; masks remain compiler-internal"]
    [(string.eq name "mask")
      "parse: public SPMD mask source types are deferred; masks remain compiler-internal"]
    [else
      (string.append
        "parse: unknown type constructor "
        (string.append
          name
          "; TypeLisp has no source-level generic type constructors; use defmacro to generate concrete declarations instead"))]))

(define (compiler-parse-policy-form? [name : i64]) : bool
  (or
    (cbi.compiler-builtin-id-any4?
      name
      (cbi.compiler-builtin-ctfe-ref 265)
      (cbi.compiler-builtin-ctfe-ref 266)
      (cbi.compiler-builtin-ctfe-ref 267)
      (cbi.compiler-builtin-ctfe-ref 268))
    (cbi.compiler-builtin-id-any3?
      name
      (cbi.compiler-builtin-ctfe-ref 269)
      (cbi.compiler-builtin-ctfe-ref 270)
      (cbi.compiler-builtin-ctfe-ref 271))))

(define (compiler-parse-removed-compressed-include-name) : String
  (string.append "include-str-comptime-" "lzss"))

(define (compiler-parse-removed-compressed-include-message) : String
  (string.append
    "parse: include-str-comptime-"
    "lzss is removed; use include-str-lzss"))

(define (ast-source-span-from-source-span [span : token.SourceSpan]) : AstSourceSpan
  (ast-source-span
    (token.span-start-line span)
    (token.span-start-col span)
    (token.span-end-line span)
    (token.span-end-col span)))

;; Parser result enums still carry message strings. Diagnostic parsing records
;; the first failing spanned subform in the invocation frame carried by this
;; dispatch, so nested and interleaved parser calls cannot overwrite it.
(define (parse-ast-error-span-clear! [dispatch : sym_i64_env.SymI64Env]) : unit
  (let
    [invocation : i64
      (compiler-parse-env-marker-value
        dispatch
        compiler-parse-invocation-marker-id)]
    (if (= invocation 0)
      unit
      (compiler-parse-raw-i64-set! invocation 0 0))))

(define (parse-ast-error-span-note!
  [dispatch : sym_i64_env.SymI64Env]
  [span : token.SourceSpan]) : unit
  (let
    [invocation : i64
      (compiler-parse-env-marker-value
        dispatch
        compiler-parse-invocation-marker-id)]
    (if (or
      (= invocation 0)
      (not (= (compiler-parse-raw-i64-ref invocation 0) 0)))
      unit
      (begin
        (compiler-parse-raw-i64-set! invocation 0 1)
        (compiler-parse-raw-i64-set! invocation 1 (token.span-start-line span))
        (compiler-parse-raw-i64-set! invocation 2 (token.span-start-col span))
        (compiler-parse-raw-i64-set! invocation 3 (token.span-end-line span))
        (compiler-parse-raw-i64-set! invocation 4 (token.span-end-col span))))))

(define (parse-ast-error-span-current
  [dispatch : sym_i64_env.SymI64Env]
  [fallback : token.SourceSpan]) : token.SourceSpan
  (let
    [invocation : i64
      (compiler-parse-env-marker-value
        dispatch
        compiler-parse-invocation-marker-id)]
    (if (and
      (not (= invocation 0))
      (not (= (compiler-parse-raw-i64-ref invocation 0) 0)))
      (token.SourceSpan
        (compiler-parse-raw-i64-ref invocation 1)
        (compiler-parse-raw-i64-ref invocation 2)
        (compiler-parse-raw-i64-ref invocation 3)
        (compiler-parse-raw-i64-ref invocation 4))
      fallback)))

(define (parse-ast-error-span-note-expr
  [dispatch : sym_i64_env.SymI64Env]
  [s : reader.SpannedSexpr]
  [result : ResultAstExpr]) : ResultAstExpr
  (match result
    [(ResultAstExpr.Err _)
      (begin
        (parse-ast-error-span-note! dispatch (reader.spanned-sexpr-span s))
        result)]
    [_ result]))

(define (parse-ast-error-span-note-let-binding
  [dispatch : sym_i64_env.SymI64Env]
  [s : reader.SpannedSexpr]
  [result : ResultAstLetBinding]) : ResultAstLetBinding
  (match result
    [(ResultAstLetBinding.Err _)
      (begin
        (parse-ast-error-span-note! dispatch (reader.spanned-sexpr-span s))
        result)]
    [_ result]))

(define (parse-ast-error-span-note-decl
  [dispatch : sym_i64_env.SymI64Env]
  [s : reader.SpannedSexpr]
  [result : ResultAstDecl]) : ResultAstDecl
  (match result
    [(ResultAstDecl.Err _)
      (begin
        (parse-ast-error-span-note! dispatch (reader.spanned-sexpr-span s))
        result)]
    [_ result]))

(define (parse-ast-error-span-note-maybe-decl
  [dispatch : sym_i64_env.SymI64Env]
  [s : reader.SpannedSexpr]
  [result : ResultAstMaybeDecl]) : ResultAstMaybeDecl
  (match result
    [(ResultAstMaybeDecl.Err _)
      (begin
        (parse-ast-error-span-note! dispatch (reader.spanned-sexpr-span s))
        result)]
    [_ result]))

(define (ast-expr-wrap-span
  [pools : AstNodePoolContext]
  [expr : i64]
  [s : reader.SpannedSexpr]) : i64
  (ast-expr-spanned-with-pools
    pools
    expr
    (ast-source-span-from-source-span (reader.spanned-sexpr-span s))))

(define (compiler-parse-tag-unknown) : i64
  0)

(define (compiler-parse-tag-bin-add) : i64
  10)

(define (compiler-parse-tag-bin-sub) : i64
  11)

(define (compiler-parse-tag-bin-mul) : i64
  12)

(define (compiler-parse-tag-bin-div) : i64
  13)

(define (compiler-parse-tag-bin-mod) : i64
  14)

(define (compiler-parse-tag-bin-eq) : i64
  15)

(define (compiler-parse-tag-bin-ne) : i64
  16)

(define (compiler-parse-tag-bin-lt) : i64
  17)

(define (compiler-parse-tag-bin-le) : i64
  18)

(define (compiler-parse-tag-bin-gt) : i64
  19)

(define (compiler-parse-tag-bin-ge) : i64
  20)

(define (compiler-parse-tag-bin-bit-and) : i64
  23)

(define (compiler-parse-tag-bin-bit-or) : i64
  24)

(define (compiler-parse-tag-bin-bit-xor) : i64
  25)

(define (compiler-parse-tag-bin-shl) : i64
  26)

(define (compiler-parse-tag-bin-shr) : i64
  27)

(define (compiler-parse-tag-un-not) : i64
  40)

(define (compiler-parse-tag-un-neg) : i64
  41)

(define (compiler-parse-tag-un-bit-not) : i64
  42)

(define (compiler-parse-tag-ty-i64) : i64
  100)

(define (compiler-parse-tag-ty-i32) : i64
  101)

(define (compiler-parse-tag-ty-i16) : i64
  102)

(define (compiler-parse-tag-ty-i8) : i64
  103)

(define (compiler-parse-tag-ty-u64) : i64
  104)

(define (compiler-parse-tag-ty-u32) : i64
  105)

(define (compiler-parse-tag-ty-u16) : i64
  106)

(define (compiler-parse-tag-ty-u8) : i64
  107)

(define (compiler-parse-tag-ty-f64) : i64
  108)

(define (compiler-parse-tag-ty-f32) : i64
  109)

(define (compiler-parse-tag-ty-bool) : i64
  110)

(define (compiler-parse-tag-ty-char) : i64
  111)

(define (compiler-parse-tag-ty-string) : i64
  112)

(define (compiler-parse-tag-ty-str) : i64
  116)

(define (compiler-parse-tag-ty-bytes) : i64
  117)

(define (compiler-parse-tag-unit) : i64
  113)

(define (compiler-parse-tag-ty-never) : i64
  114)

(define (compiler-parse-tag-ty-expr) : i64
  115)

(define (compiler-parse-tag-ty-func) : i64
  130)

(define (compiler-parse-tag-ty-tuple) : i64
  131)

(define (compiler-parse-tag-ty-array) : i64
  132)

(define (compiler-parse-tag-ty-region) : i64
  133)

(define (compiler-parse-tag-ty-ptr) : i64
  134)

(define (compiler-parse-tag-ty-mut-ptr) : i64
  135)

(define (compiler-parse-tag-ty-ref) : i64
  136)

(define (compiler-parse-tag-ty-mut-ref) : i64
  137)

(define (compiler-parse-tag-ty-box) : i64
  138)

(define (compiler-parse-tag-ty-dyn-array) : i64
  139)

(define (compiler-parse-tag-expr-if) : i64
  200)

(define (compiler-parse-tag-expr-let) : i64
  201)

(define (compiler-parse-tag-expr-lambda) : i64
  202)

(define (compiler-parse-tag-expr-while) : i64
  203)

(define (compiler-parse-tag-expr-begin) : i64
  204)

(define (compiler-parse-tag-expr-unsafe) : i64
  254)

(define (compiler-parse-tag-expr-set) : i64
  205)

(define (compiler-parse-tag-expr-ann) : i64
  206)

(define (compiler-parse-tag-expr-cast) : i64
  207)

(define (compiler-parse-tag-expr-tuple) : i64
  220)

(define (compiler-parse-tag-expr-tuple-ref) : i64
  221)

(define (compiler-parse-tag-expr-array) : i64
  222)

(define (compiler-parse-tag-expr-make-array) : i64
  223)

(define (compiler-parse-tag-expr-array-ref) : i64
  240)

(define (compiler-parse-tag-expr-array-set) : i64
  241)

(define (compiler-parse-tag-expr-array-push) : i64
  262)

(define (compiler-parse-tag-expr-array-take) : i64
  303)

(define (compiler-parse-tag-expr-string-ref) : i64
  242)

(define (compiler-parse-tag-expr-char-at) : i64
  243)

(define (compiler-parse-tag-expr-match) : i64
  244)

(define (compiler-parse-tag-expr-foreach) : i64
  245)

(define (compiler-parse-tag-expr-struct-get) : i64
  246)

(define (compiler-parse-tag-expr-comptime) : i64
  247)

(define (compiler-parse-tag-expr-with-region) : i64
  248)

(define (compiler-parse-tag-expr-type-literal) : i64
  249)

;; Legacy parser-only adapters operate on the default state. Production load
;; paths reset and inspect their CompilerDriverState-owned parser state.
(define (compiler-parse-type-literal-tracking-reset!) : unit
  (compiler-parse-state-type-literal-reset! compiler-parse-default-state))

(define (compiler-parse-type-literal-tracking-mark!
  [dispatch : sym_i64_env.SymI64Env]) : unit
  (let
    [control : i64
      (compiler-parse-env-marker-value dispatch compiler-parse-state-marker-id)]
    (if (= control 0)
      unit
      (compiler-parse-raw-i64-set!
        control
        compiler-parse-state-control-has-type-literal
        1))))

(define (compiler-parse-current-load-has-type-literal?) : bool
  (compiler-parse-state-has-type-literal? compiler-parse-default-state))

(define (compiler-parse-tag-expr-init) : i64
  288)

(define (compiler-parse-tag-expr-spmd-reduce) : i64
  250)

(define (compiler-parse-tag-expr-spmd-scan) : i64
  294)

(define (compiler-parse-tag-expr-spmd-broadcast) : i64
  290)

(define (compiler-parse-tag-expr-spmd-shuffle) : i64
  297)

(define (compiler-parse-tag-expr-spmd-program-index) : i64
  295)

(define (compiler-parse-tag-expr-spmd-program-count) : i64
  296)

(define (compiler-parse-tag-expr-try) : i64
  251)

(define (compiler-parse-tag-expr-return) : i64
  270)

(define (compiler-parse-tag-expr-break) : i64
  298)

(define (compiler-parse-tag-expr-continue) : i64
  299)

(define (compiler-parse-tag-expr-ptr-null) : i64
  252)

(define (compiler-parse-tag-expr-ptr-null-check) : i64
  253)

(define (compiler-parse-tag-expr-with-resource) : i64
  255)

(define (compiler-parse-tag-expr-ptr-read) : i64
  256)

(define (compiler-parse-tag-expr-ptr-write) : i64
  257)

(define (compiler-parse-tag-expr-ptr-offset) : i64
  258)

(define (compiler-parse-tag-expr-ptr-cast) : i64
  259)

(define (compiler-parse-tag-expr-ptr-to-int) : i64
  260)

(define (compiler-parse-tag-expr-int-to-ptr) : i64
  261)

(define (compiler-parse-tag-expr-ptr-addr-of) : i64
  289)

(define (compiler-parse-tag-expr-box) : i64
  263)

(define (compiler-parse-tag-expr-box-get) : i64
  264)

(define (compiler-parse-tag-expr-box-take) : i64
  292)

(define (compiler-parse-tag-expr-string-data) : i64
  276)

(define (compiler-parse-tag-expr-string-from-bytes) : i64
  277)

(define (compiler-parse-tag-expr-array-data) : i64
  278)

(define (compiler-parse-tag-expr-program-argc) : i64
  279)

(define (compiler-parse-tag-expr-program-argv) : i64
  280)

(define (compiler-parse-tag-expr-program-envp) : i64
  281)

(define (compiler-parse-tag-expr-cpuid-eax) : i64
  282)

(define (compiler-parse-tag-expr-cpuid-ebx) : i64
  283)

(define (compiler-parse-tag-expr-cpuid-ecx) : i64
  284)

(define (compiler-parse-tag-expr-cpuid-edx) : i64
  285)

(define (compiler-parse-tag-expr-xgetbv) : i64
  286)

(define (compiler-parse-tag-expr-syscall) : i64
  287)

(define (compiler-parse-tag-expr-quote) : i64
  265)

(define (compiler-parse-tag-expr-quasiquote) : i64
  266)

(define (compiler-parse-tag-expr-unquote) : i64
  267)

(define (compiler-parse-tag-expr-unquote-splicing) : i64
  268)

(define (compiler-parse-tag-expr-with-escape) : i64
  269)

(define (compiler-parse-tag-expr-with-scratch) : i64
  293)

(define (compiler-parse-tag-expr-in-arena) : i64
  291)

(define (compiler-parse-tag-lit-true) : i64
  300)

(define (compiler-parse-tag-lit-false) : i64
  301)

(define (compiler-parse-tag-pattern-wildcard) : i64
  302)

(define (compiler-parse-tag-decl-define) : i64
  400)

(define (compiler-parse-tag-decl-extern) : i64
  401)

(define (compiler-parse-tag-decl-defenum) : i64
  402)

(define (compiler-parse-tag-decl-defstruct) : i64
  403)

(define (compiler-parse-tag-decl-import) : i64
  404)

(define (compiler-parse-tag-decl-module) : i64
  406)

(define (compiler-parse-tag-decl-test) : i64
  407)

(define (compiler-parse-tag-decl-defmacro) : i64
  408)

(define (compiler-parse-tag-decl-include-str) : i64
  410)

(define (compiler-parse-tag-decl-include-str-comptime) : i64
  414)

(define (compiler-parse-tag-decl-include-str-lzss) : i64
  415)

(define (compiler-parse-tag-decl-removed-compressed-include) : i64
  416)

(define (compiler-parse-tag-decl-include-bin) : i64
  413)

(define (compiler-parse-tag-decl-defdispatch) : i64
  411)

;; Parser syntax is a closed set, but the scoped symbol environment stores it
;; as an immutable list. Keep that environment as the source of truth for cfg
;; evaluation and custom test dispatches, while indexing the canonical dispatch
;; by intern ID for constant-time syntax lookup.
(define compiler-parse-dispatch-index-capacity : i64
  512)

(define (compiler-parse-dispatch-index-current-control? [control : i64]) : bool
  (and
    (=
      (compiler-parse-raw-i64-ref
        control
        compiler-parse-state-control-cache-generation)
      (compiler-parse-state-owner-generation control))
    (=
      (compiler-parse-raw-i64-ref
        control
        compiler-parse-state-control-cache-table-id)
      (compiler-parse-state-owner-table-id control))))

(define (compiler-parse-dispatch-index-clear! [control : i64]) : unit
  (let
    [keys : i64
      (compiler-parse-raw-i64-ref
        control
        compiler-parse-state-control-keys-addr)]
    [i : i64 0]
    (while (< i compiler-parse-dispatch-index-capacity)
      (begin
        (compiler-parse-raw-i64-set! keys i 0)
        (set! i (+ i 1))))))

(define (compiler-parse-dispatch-index-insert!
  [control : i64]
  [name-id : i64]
  [tag : i64]) : bool
  (let
    [keys : i64
      (compiler-parse-raw-i64-ref
        control
        compiler-parse-state-control-keys-addr)]
    [tags : i64
      (compiler-parse-raw-i64-ref
        control
        compiler-parse-state-control-tags-addr)]
    [encoded : i64 (+ name-id 1)]
    [slot : i64 (bit-and name-id (- compiler-parse-dispatch-index-capacity 1))]
    [steps : i64 0]
    (begin
      (while (< steps compiler-parse-dispatch-index-capacity)
        (let
          [present : i64 (compiler-parse-raw-i64-ref keys slot)]
          (if (or (= present 0) (= present encoded))
            (begin
              (compiler-parse-raw-i64-set! keys slot encoded)
              (compiler-parse-raw-i64-set! tags slot tag)
              (return true))
            (begin
              (set!
                slot
                (bit-and
                  (+ slot 1)
                  (- compiler-parse-dispatch-index-capacity 1)))
              (set! steps (+ steps 1))))))
      false)))

(define (compiler-parse-dispatch-index-populate!
  [control : i64]
  [dispatch : sym_i64_env.SymI64Env]) : unit
  (let
    [generation : i64 (compiler-parse-state-owner-generation control)]
    [table-id : i64 (compiler-parse-state-owner-table-id control)]
    [cursor : sym_i64_env.SymI64Env dispatch]
    [done : bool false]
    (begin
      (compiler-parse-dispatch-index-clear! control)
      (compiler-parse-raw-i64-set!
        control
        compiler-parse-state-control-marker-id
        -1)
      (compiler-parse-raw-i64-set! control compiler-parse-state-control-ready 1)
      (while (and
        (not done)
        (not
          (=
            (compiler-parse-raw-i64-ref
              control
              compiler-parse-state-control-ready)
            0)))
        (match cursor
          [(sym_i64_env.SymI64Nil) (set! done true)]
          [(sym_i64_env.SymI64Bind name-id tag rest)
            (begin
              (if (and
                (>= name-id 0)
                (= tag (compiler-parse-tag-decl-defdispatch)))
                (compiler-parse-raw-i64-set!
                  control
                  compiler-parse-state-control-marker-id
                  name-id)
                unit)
              (if (or
                (< name-id 0)
                (compiler-parse-dispatch-index-insert! control name-id tag))
                (set! cursor (box-get rest))
                (compiler-parse-raw-i64-set!
                  control
                  compiler-parse-state-control-ready
                  0)))]))
      (if (<
        (compiler-parse-raw-i64-ref
          control
          compiler-parse-state-control-marker-id)
        0)
        (compiler-parse-raw-i64-set!
          control
          compiler-parse-state-control-ready
          0)
        unit)
      (compiler-parse-raw-i64-set!
        control
        compiler-parse-state-control-cache-generation
        generation)
      (compiler-parse-raw-i64-set!
        control
        compiler-parse-state-control-cache-table-id
        table-id))))

;; Return the owning control address only when the first non-capability binding
;; is this state's defdispatch marker. Partial/custom environments retain the
;; linked-list fallback.
(define (compiler-parse-dispatch-indexed-control
  [dispatch : sym_i64_env.SymI64Env]) : i64
  (let
    [invocation-control : i64
      (match dispatch
        [(sym_i64_env.SymI64Bind name-id value _)
          (if (= name-id compiler-parse-invocation-marker-id)
            (compiler-parse-raw-i64-ref
              value
              compiler-parse-invocation-control-slot)
            0)]
        [(sym_i64_env.SymI64Nil) 0])]
    [cursor : sym_i64_env.SymI64Env dispatch]
    [control : i64 0]
    [marker-id : i64 -1]
    [marker-tag : i64 -1]
    (begin
      ;; Invocation frames are created only after the complete base dispatch
      ;; has validated this control. Intern reset cannot occur during a parse,
      ;; so the frame is the constant-time production path; the scan below is
      ;; retained for derived and custom test environments.
      (when (not (= invocation-control 0)) (return invocation-control))
      (while (or (= control 0) (< marker-id 0))
        (match cursor
          [(sym_i64_env.SymI64Nil) (return 0)]
          [(sym_i64_env.SymI64Bind name-id tag rest)
            (begin
              (if (= name-id compiler-parse-state-marker-id)
                (set! control tag)
                unit)
              (if (and (>= name-id 0) (< marker-id 0))
                (begin
                  (set! marker-id name-id)
                  (set! marker-tag tag))
                unit)
              (set! cursor (box-get rest)))]))
      (if (and
        (not (= control 0))
        (= marker-tag (compiler-parse-tag-decl-defdispatch))
        (not
          (=
            (compiler-parse-raw-i64-ref
              control
              compiler-parse-state-control-ready)
            0))
        (compiler-parse-dispatch-index-current-control? control)
        (=
          marker-id
          (compiler-parse-raw-i64-ref
            control
            compiler-parse-state-control-marker-id)))
        control
        0))))

(define (compiler-parse-dispatch-indexed? [dispatch : sym_i64_env.SymI64Env]) : bool
  (not (= (compiler-parse-dispatch-indexed-control dispatch) 0)))

(define (compiler-parse-dispatch-index-mark [dispatch : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (let
    [control : i64
      (compiler-parse-env-marker-value dispatch compiler-parse-state-marker-id)]
    (if (and
      (not (= control 0))
      (not
        (=
          (compiler-parse-raw-i64-ref
            control
            compiler-parse-state-control-ready)
          0))
      (compiler-parse-dispatch-index-current-control? control))
      (sym_i64_env.sym-i64-bind-id
        dispatch
        (compiler-parse-raw-i64-ref
          control
          compiler-parse-state-control-marker-id)
        (compiler-parse-tag-decl-defdispatch))
      dispatch)))

(define (compiler-parse-dispatch-index-lookup-id
  [control : i64]
  [name-id : i64]) : i64
  (let
    [keys : i64
      (compiler-parse-raw-i64-ref
        control
        compiler-parse-state-control-keys-addr)]
    [tags : i64
      (compiler-parse-raw-i64-ref
        control
        compiler-parse-state-control-tags-addr)]
    [encoded : i64 (+ name-id 1)]
    [slot : i64 (bit-and name-id (- compiler-parse-dispatch-index-capacity 1))]
    [steps : i64 0]
    (begin
      (while (< steps compiler-parse-dispatch-index-capacity)
        (let
          [present : i64 (compiler-parse-raw-i64-ref keys slot)]
          (cond
            [(= present 0) (return (compiler-parse-tag-unknown))]
            [(= present encoded)
              (return (compiler-parse-raw-i64-ref tags slot))]
            [else
              (begin
                (set!
                  slot
                  (bit-and
                    (+ slot 1)
                    (- compiler-parse-dispatch-index-capacity 1)))
                (set! steps (+ steps 1)))])))
      (compiler-parse-tag-unknown))))

(define (compiler-parse-dispatch-bind
  [env : sym_i64_env.SymI64Env]
  [name : String]
  [tag : i64]) : sym_i64_env.SymI64Env
  (let
    [control : i64
      (compiler-parse-env-marker-value env compiler-parse-state-marker-id)]
    [owner-address : i64
      (if (= control 0)
        0
        (compiler-parse-raw-i64-ref
          control
          compiler-parse-state-control-owner-addr))]
    [name-id : i64
      (if (= owner-address 0)
        (reader.read-stable-symbol-id name)
        (ci.intern-compat-state-intern
          (compiler-parse-state-owner control)
          name))]
    (sym_i64_env.sym-i64-bind-id env name-id tag)))

(define (compiler-parse-dispatch-binops [e : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (let
    [e1 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind e "+" (compiler-parse-tag-bin-add))]
    [e2 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind e1 "-" (compiler-parse-tag-bin-sub))]
    [e3 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind e2 "*" (compiler-parse-tag-bin-mul))]
    [e4 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind e3 "/" (compiler-parse-tag-bin-div))]
    [e5 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind e4 "%" (compiler-parse-tag-bin-mod))]
    [e6 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind e5 "=" (compiler-parse-tag-bin-eq))]
    [e7 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind e6 "!=" (compiler-parse-tag-bin-ne))]
    [e8 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind e7 "<" (compiler-parse-tag-bin-lt))]
    [e9 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind e8 "<=" (compiler-parse-tag-bin-le))]
    [e10 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind e9 ">" (compiler-parse-tag-bin-gt))]
    [e11 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind e10 ">=" (compiler-parse-tag-bin-ge))]
    [e12 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind
        e11
        "bit-and"
        (compiler-parse-tag-bin-bit-and))]
    [e13 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind
        e12
        "bit-or"
        (compiler-parse-tag-bin-bit-or))]
    [e14 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind
        e13
        "bit-xor"
        (compiler-parse-tag-bin-bit-xor))]
    [e15 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind e14 "shl" (compiler-parse-tag-bin-shl))]
    (compiler-parse-dispatch-bind e15 "shr" (compiler-parse-tag-bin-shr))))

(define (compiler-parse-dispatch-unops [e : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (let
    [e1 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind e "not" (compiler-parse-tag-un-not))]
    [e2 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind e1 "neg" (compiler-parse-tag-un-neg))]
    (compiler-parse-dispatch-bind e2 "bit-not" (compiler-parse-tag-un-bit-not))))

(define (compiler-parse-dispatch-types [e : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (let
    [out : sym_i64_env.SymI64Env e]
    (begin
      (set!
        out
        (compiler-parse-dispatch-bind out "i64" (compiler-parse-tag-ty-i64)))
      (set!
        out
        (compiler-parse-dispatch-bind out "i32" (compiler-parse-tag-ty-i32)))
      (set!
        out
        (compiler-parse-dispatch-bind out "i16" (compiler-parse-tag-ty-i16)))
      (set!
        out
        (compiler-parse-dispatch-bind out "i8" (compiler-parse-tag-ty-i8)))
      (set!
        out
        (compiler-parse-dispatch-bind out "u64" (compiler-parse-tag-ty-u64)))
      (set!
        out
        (compiler-parse-dispatch-bind out "u32" (compiler-parse-tag-ty-u32)))
      (set!
        out
        (compiler-parse-dispatch-bind out "u16" (compiler-parse-tag-ty-u16)))
      (set!
        out
        (compiler-parse-dispatch-bind out "u8" (compiler-parse-tag-ty-u8)))
      (set!
        out
        (compiler-parse-dispatch-bind out "f64" (compiler-parse-tag-ty-f64)))
      (set!
        out
        (compiler-parse-dispatch-bind out "f32" (compiler-parse-tag-ty-f32)))
      (set!
        out
        (compiler-parse-dispatch-bind out "bool" (compiler-parse-tag-ty-bool)))
      (set!
        out
        (compiler-parse-dispatch-bind out "char" (compiler-parse-tag-ty-char)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "String"
          (compiler-parse-tag-ty-string)))
      (set!
        out
        (compiler-parse-dispatch-bind out "str" (compiler-parse-tag-ty-str)))
      (set!
        out
        (compiler-parse-dispatch-bind out "bytes" (compiler-parse-tag-ty-bytes)))
      (set!
        out
        (compiler-parse-dispatch-bind out "unit" (compiler-parse-tag-unit)))
      (set!
        out
        (compiler-parse-dispatch-bind out "never" (compiler-parse-tag-ty-never)))
      (set!
        out
        (compiler-parse-dispatch-bind out "->" (compiler-parse-tag-ty-func)))
      (set!
        out
        (compiler-parse-dispatch-bind out "Tuple" (compiler-parse-tag-ty-tuple)))
      (set!
        out
        (compiler-parse-dispatch-bind out "Array" (compiler-parse-tag-ty-array)))
      (set!
        out
        (compiler-parse-dispatch-bind out "in" (compiler-parse-tag-ty-region)))
      (set!
        out
        (compiler-parse-dispatch-bind out "Ptr" (compiler-parse-tag-ty-ptr)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "MutPtr"
          (compiler-parse-tag-ty-mut-ptr)))
      (set!
        out
        (compiler-parse-dispatch-bind out "&" (compiler-parse-tag-ty-ref)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "&mut"
          (compiler-parse-tag-ty-mut-ref)))
      (set!
        out
        (compiler-parse-dispatch-bind out "Box" (compiler-parse-tag-ty-box)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "__tl_dyn-array"
          (compiler-parse-tag-ty-dyn-array)))
      out)))

(define (compiler-parse-dispatch-exprs [e : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (let
    [out : sym_i64_env.SymI64Env e]
    (begin
      (set!
        out
        (compiler-parse-dispatch-bind out "if" (compiler-parse-tag-expr-if)))
      (set!
        out
        (compiler-parse-dispatch-bind out "let" (compiler-parse-tag-expr-let)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "lambda"
          (compiler-parse-tag-expr-lambda)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "while"
          (compiler-parse-tag-expr-while)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "begin"
          (compiler-parse-tag-expr-begin)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "unsafe"
          (compiler-parse-tag-expr-unsafe)))
      (set!
        out
        (compiler-parse-dispatch-bind out "set!" (compiler-parse-tag-expr-set)))
      (set!
        out
        (compiler-parse-dispatch-bind out "ann" (compiler-parse-tag-expr-ann)))
      (set!
        out
        (compiler-parse-dispatch-bind out "cast" (compiler-parse-tag-expr-cast)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "tuple"
          (compiler-parse-tag-expr-tuple)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "tuple-ref"
          (compiler-parse-tag-expr-tuple-ref)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "array"
          (compiler-parse-tag-expr-array)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "make-array"
          (compiler-parse-tag-expr-make-array)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "__tl_make-array"
          (compiler-parse-tag-expr-make-array)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "array-ref"
          (compiler-parse-tag-expr-array-ref)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "__tl_array-ref"
          (compiler-parse-tag-expr-array-ref)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "array-set!"
          (compiler-parse-tag-expr-array-set)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "__tl_array-set!"
          (compiler-parse-tag-expr-array-set)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "array-push!"
          (compiler-parse-tag-expr-array-push)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "__tl_array-push!"
          (compiler-parse-tag-expr-array-push)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "array-take!"
          (compiler-parse-tag-expr-array-take)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "__tl_array-take!"
          (compiler-parse-tag-expr-array-take)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "match"
          (compiler-parse-tag-expr-match)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "foreach"
          (compiler-parse-tag-expr-foreach)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "spmd-reduce"
          (compiler-parse-tag-expr-spmd-reduce)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "spmd-scan"
          (compiler-parse-tag-expr-spmd-scan)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "spmd-broadcast"
          (compiler-parse-tag-expr-spmd-broadcast)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "spmd-shuffle"
          (compiler-parse-tag-expr-spmd-shuffle)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "program-index"
          (compiler-parse-tag-expr-spmd-program-index)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "program-count"
          (compiler-parse-tag-expr-spmd-program-count)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "struct-get"
          (compiler-parse-tag-expr-struct-get)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "comptime"
          (compiler-parse-tag-expr-comptime)))
      ;; `with-arena` is the canonical scoped-arena spelling.
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "with-arena"
          (compiler-parse-tag-expr-with-region)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "with-escape"
          (compiler-parse-tag-expr-with-escape)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "with-scratch"
          (compiler-parse-tag-expr-with-scratch)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "in-arena"
          (compiler-parse-tag-expr-in-arena)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "type"
          (compiler-parse-tag-expr-type-literal)))
      (set!
        out
        (compiler-parse-dispatch-bind out "init" (compiler-parse-tag-expr-init)))
      (set!
        out
        (compiler-parse-dispatch-bind out "try" (compiler-parse-tag-expr-try)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "return"
          (compiler-parse-tag-expr-return)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "break"
          (compiler-parse-tag-expr-break)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "continue"
          (compiler-parse-tag-expr-continue)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "ptr-null"
          (compiler-parse-tag-expr-ptr-null)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "ptr-null?"
          (compiler-parse-tag-expr-ptr-null-check)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "ptr-read"
          (compiler-parse-tag-expr-ptr-read)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "ptr-write!"
          (compiler-parse-tag-expr-ptr-write)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "ptr-offset"
          (compiler-parse-tag-expr-ptr-offset)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "ptr-cast"
          (compiler-parse-tag-expr-ptr-cast)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "ptr->int"
          (compiler-parse-tag-expr-ptr-to-int)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "int->ptr"
          (compiler-parse-tag-expr-int-to-ptr)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "ptr-addr-of"
          (compiler-parse-tag-expr-ptr-addr-of)))
      (set!
        out
        (compiler-parse-dispatch-bind out "box" (compiler-parse-tag-expr-box)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "box-get"
          (compiler-parse-tag-expr-box-get)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "box-take"
          (compiler-parse-tag-expr-box-take)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "string-data"
          (compiler-parse-tag-expr-string-data)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "string-from-bytes"
          (compiler-parse-tag-expr-string-from-bytes)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "array-data"
          (compiler-parse-tag-expr-array-data)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "program-argc"
          (compiler-parse-tag-expr-program-argc)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "program-argv"
          (compiler-parse-tag-expr-program-argv)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "program-envp"
          (compiler-parse-tag-expr-program-envp)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "cpuid-eax"
          (compiler-parse-tag-expr-cpuid-eax)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "cpuid-ebx"
          (compiler-parse-tag-expr-cpuid-ebx)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "cpuid-ecx"
          (compiler-parse-tag-expr-cpuid-ecx)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "cpuid-edx"
          (compiler-parse-tag-expr-cpuid-edx)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "xgetbv"
          (compiler-parse-tag-expr-xgetbv)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "syscall"
          (compiler-parse-tag-expr-syscall)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "with"
          (compiler-parse-tag-expr-with-resource)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "quote"
          (compiler-parse-tag-expr-quote)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "quasiquote"
          (compiler-parse-tag-expr-quasiquote)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "unquote"
          (compiler-parse-tag-expr-unquote)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "unquote-splicing"
          (compiler-parse-tag-expr-unquote-splicing)))
      out)))

(define (compiler-parse-dispatch-patterns [e : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (let
    [e1 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind e "true" (compiler-parse-tag-lit-true))]
    [e2 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind e1 "false" (compiler-parse-tag-lit-false))]
    (compiler-parse-dispatch-bind e2 "_" (compiler-parse-tag-pattern-wildcard))))

(define (compiler-parse-dispatch-decls [e : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (let
    [e1 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind e "define" (compiler-parse-tag-decl-define))]
    [e2 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind
        e1
        "extern"
        (compiler-parse-tag-decl-extern))]
    [e3 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind
        e2
        "defenum"
        (compiler-parse-tag-decl-defenum))]
    [e4 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind
        e3
        "defstruct"
        (compiler-parse-tag-decl-defstruct))]
    [e5 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind
        e4
        "import"
        (compiler-parse-tag-decl-import))]
    [e8 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind
        e5
        "module"
        (compiler-parse-tag-decl-module))]
    [e9 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind e8 "test" (compiler-parse-tag-decl-test))]
    [e10 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind
        e9
        "defmacro"
        (compiler-parse-tag-decl-defmacro))]
    [e12 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind
        e10
        "include-str"
        (compiler-parse-tag-decl-include-str))]
    [e13 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind
        e12
        "include-str-comptime"
        (compiler-parse-tag-decl-include-str-comptime))]
    [e14 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind
        e13
        "include-str-lzss"
        (compiler-parse-tag-decl-include-str-lzss))]
    [e15 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind
        e14
        (compiler-parse-removed-compressed-include-name)
        (compiler-parse-tag-decl-removed-compressed-include))]
    [e16 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind
        e15
        "include-bin"
        (compiler-parse-tag-decl-include-bin))]
    (compiler-parse-dispatch-bind
      e16
      "defdispatch"
      (compiler-parse-tag-decl-defdispatch))))

(define (compiler-parse-dispatch-cache-ref [control : i64]) : sym_i64_env.SymI64Env
  (let
    [cache : (Array sym_i64_env.SymI64Env)
      (unsafe
        (ptr-read
          (int->ptr
            (compiler-parse-raw-i64-ref
              control
              compiler-parse-state-control-cache-addr)
            : (Ptr (Array sym_i64_env.SymI64Env)))))]
    (array-ref cache 0)))

(define (compiler-parse-dispatch-cache-set!
  [control : i64]
  [dispatch : sym_i64_env.SymI64Env]) : unit
  (let
    [cache : (Array sym_i64_env.SymI64Env)
      (unsafe
        (ptr-read
          (int->ptr
            (compiler-parse-raw-i64-ref
              control
              compiler-parse-state-control-cache-addr)
            : (Ptr (Array sym_i64_env.SymI64Env)))))]
    (array-set! cache 0 dispatch)))

(define (compiler-parse-state-owner-floor-refresh! [control : i64]) : unit
  (if (=
    (compiler-parse-raw-i64-ref control compiler-parse-state-control-owner-addr)
    0)
    (ci.intern-persistent-arena-floor-refresh!)
    (ci.intern-compat-state-persistent-arena-floor-refresh!
      (compiler-parse-state-owner control))))

(define (compiler-parse-state-owner-sync-active! [control : i64]) : unit
  (let
    [owner-address : i64
      (compiler-parse-raw-i64-ref
        control
        compiler-parse-state-control-owner-addr)]
    (if (or
      (= owner-address 0)
      (not
        (=
          (compiler-parse-state-owner-table-id control)
          (ci.intern-active-table-id))))
      unit
      (ci.intern-compat-state-install! (compiler-parse-state-owner control)))))

(define (compiler-parse-state-owner-capture-active! [control : i64]) : unit
  (let
    [owner-address : i64
      (compiler-parse-raw-i64-ref
        control
        compiler-parse-state-control-owner-addr)]
    (if (or
      (= owner-address 0)
      (not
        (=
          (compiler-parse-state-owner-table-id control)
          (ci.intern-active-table-id))))
      unit
      (ci.intern-compat-state-capture-from-globals!
        (compiler-parse-state-owner control)))))

(define (compiler-parse-dispatch-env-for-control [control : i64]) : sym_i64_env.SymI64Env
  (begin
    ;; Builtin seeding may have advanced an already-installed owner's scalar
    ;; compatibility view. Capture it before direct state-owned interning.
    (compiler-parse-state-owner-capture-active! control)
    (if (and
      (not
        (=
          (compiler-parse-raw-i64-ref
            control
            compiler-parse-state-control-ready)
          0))
      (compiler-parse-dispatch-index-current-control? control))
      (compiler-parse-dispatch-cache-ref control)
      (let
        [previous-arena : i64 (arena.tl_arena_current)]
        [persistent-arena : i64
          (compiler-parse-state-owner-persistent-arena control)]
        (begin
          (unsafe
            (arena.tl_arena_set persistent-arena))
          (let
            [seed : sym_i64_env.SymI64Env
              (sym_i64_env.sym-i64-bind-id
                (sym_i64_env.sym-i64-empty)
                compiler-parse-state-marker-id
                control)]
            [dispatch : sym_i64_env.SymI64Env
              (compiler-parse-dispatch-decls
                (compiler-parse-dispatch-patterns
                  (compiler-parse-dispatch-exprs
                    (compiler-parse-dispatch-types
                      (compiler-parse-dispatch-unops
                        (compiler-parse-dispatch-binops seed))))))]
            (begin
              (compiler-parse-dispatch-index-populate! control dispatch)
              (compiler-parse-dispatch-cache-set! control dispatch)
              (compiler-parse-state-owner-floor-refresh! control)
              ;; Direct owner interning advances the state's scalar pool count.
              ;; When that owner is already installed, publish those scalars once
              ;; after the immutable dispatch is complete so subsequent source
              ;; lexing continues after its syntax IDs. Inactive owners remain
              ;; untouched, preserving A/B state isolation.
              (compiler-parse-state-owner-sync-active! control)
              (unsafe
                (arena.tl_arena_set previous-arena))
              dispatch)))))))

(define (compiler-parse-dispatch-env-from-cfg [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (let
    [owned-cfgs : sym_i64_env.SymI64Env
      (if (=
        (compiler-parse-env-marker-value cfgs compiler-parse-state-marker-id)
        0)
        (compiler-parse-state-cfgs compiler-parse-default-state cfgs)
        cfgs)]
    [control : i64
      (compiler-parse-env-marker-value
        owned-cfgs
        compiler-parse-state-marker-id)]
    (compiler-parse-dispatch-index-mark
      (compiler-cfg-merge
        (compiler-parse-dispatch-env-for-control control)
        owned-cfgs))))

(define (compiler-parse-dispatch-env) : sym_i64_env.SymI64Env
  (compiler-parse-dispatch-env-from-cfg (compiler-cfg-empty)))

(define (compiler-parse-dispatch-tag
  [dispatch : sym_i64_env.SymI64Env]
  [name-id : i64]) : i64
  (compiler-parse-dispatch-tag-id dispatch name-id))

(define (compiler-parse-dispatch-tag-id
  [dispatch : sym_i64_env.SymI64Env]
  [name-id : i64]) : i64
  (let
    [control : i64 (compiler-parse-dispatch-indexed-control dispatch)]
    (if (not (= control 0))
      (compiler-parse-dispatch-index-lookup-id control name-id)
      (match (sym_i64_env.sym-i64-lookup-id dispatch name-id)
        [(option_i64.Some tag) tag]
        [(option_i64.None) (compiler-parse-tag-unknown)]))))

(define (ast-binop-tag? [tag : i64]) : bool
  (or
    (= tag (compiler-parse-tag-bin-add))
    (= tag (compiler-parse-tag-bin-sub))
    (= tag (compiler-parse-tag-bin-mul))
    (= tag (compiler-parse-tag-bin-div))
    (= tag (compiler-parse-tag-bin-mod))
    (= tag (compiler-parse-tag-bin-eq))
    (= tag (compiler-parse-tag-bin-ne))
    (= tag (compiler-parse-tag-bin-lt))
    (= tag (compiler-parse-tag-bin-le))
    (= tag (compiler-parse-tag-bin-gt))
    (= tag (compiler-parse-tag-bin-ge))
    (= tag (compiler-parse-tag-bin-bit-and))
    (= tag (compiler-parse-tag-bin-bit-or))
    (= tag (compiler-parse-tag-bin-bit-xor))
    (= tag (compiler-parse-tag-bin-shl))
    (= tag (compiler-parse-tag-bin-shr))))

(define (ast-binop? [dispatch : sym_i64_env.SymI64Env] [name : i64]) : bool
  (ast-binop-tag? (compiler-parse-dispatch-tag dispatch name)))

(define (ast-left-fold-binop-tag? [tag : i64]) : bool
  (or
    (= tag (compiler-parse-tag-bin-add))
    (= tag (compiler-parse-tag-bin-mul))
    (= tag (compiler-parse-tag-bin-bit-and))
    (= tag (compiler-parse-tag-bin-bit-or))
    (= tag (compiler-parse-tag-bin-bit-xor))))

(define (ast-binop-from-tag [tag : i64]) : AstBinOp
  (cond
    [(= tag (compiler-parse-tag-bin-add)) (AstBinOp.Add)]
    [(= tag (compiler-parse-tag-bin-sub)) (AstBinOp.Sub)]
    [(= tag (compiler-parse-tag-bin-mul)) (AstBinOp.Mul)]
    [(= tag (compiler-parse-tag-bin-div)) (AstBinOp.Div)]
    [(= tag (compiler-parse-tag-bin-mod)) (AstBinOp.Mod)]
    [(= tag (compiler-parse-tag-bin-eq)) (AstBinOp.Eq)]
    [(= tag (compiler-parse-tag-bin-ne)) (AstBinOp.Ne)]
    [(= tag (compiler-parse-tag-bin-lt)) (AstBinOp.Lt)]
    [(= tag (compiler-parse-tag-bin-le)) (AstBinOp.Le)]
    [(= tag (compiler-parse-tag-bin-gt)) (AstBinOp.Gt)]
    [(= tag (compiler-parse-tag-bin-ge)) (AstBinOp.Ge)]
    [(= tag (compiler-parse-tag-bin-bit-and)) (AstBinOp.BitAnd)]
    [(= tag (compiler-parse-tag-bin-bit-or)) (AstBinOp.BitOr)]
    [(= tag (compiler-parse-tag-bin-bit-xor)) (AstBinOp.BitXor)]
    [(= tag (compiler-parse-tag-bin-shl)) (AstBinOp.Shl)]
    [else (AstBinOp.Shr)]))

(define (ast-binop-from-name [dispatch : sym_i64_env.SymI64Env] [name : i64]) : AstBinOp
  (ast-binop-from-tag (compiler-parse-dispatch-tag dispatch name)))

(define (ast-unop-tag? [tag : i64]) : bool
  (if (= tag (compiler-parse-tag-un-not))
    true
    (if (= tag (compiler-parse-tag-un-neg))
      true
      (= tag (compiler-parse-tag-un-bit-not)))))

(define (ast-unop? [dispatch : sym_i64_env.SymI64Env] [name : i64]) : bool
  (ast-unop-tag? (compiler-parse-dispatch-tag dispatch name)))

(define (ast-unop-from-tag [tag : i64]) : AstUnOp
  (if (= tag (compiler-parse-tag-un-not))
    (AstUnOp.Not)
    (if (= tag (compiler-parse-tag-un-neg))
      (AstUnOp.Neg)
      (AstUnOp.BitNot))))

(define (ast-unop-from-name [dispatch : sym_i64_env.SymI64Env] [name : i64]) : AstUnOp
  (ast-unop-from-tag (compiler-parse-dispatch-tag dispatch name)))

(define (parse-ast-type-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.Sexpr]
  [out : (&mut out AstTypeList)]) : ResultAstTypeListBuild
  (match s
    [(reader.Sexpr.Nil) (ResultAstTypeListBuild.Ok)]
    [(reader.Sexpr.Cons head tail)
      (match (parse-ast-type dispatch pools (box-get head))
        [(ResultAstType.Ok parsed-head)
          (begin
            (ast-type-list-push
              out
              (ast-node-pool-context-type-push pools parsed-head))
            (parse-ast-type-list dispatch pools (box-get tail) out))]
        [(ResultAstType.Err message) (ResultAstTypeListBuild.Err message)])]
    [_ (ResultAstTypeListBuild.Err "parse: malformed type list")]))

(define (parse-ast-type-list-result
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.Sexpr]) : ResultAstTypeList
  (let
    [out : AstTypeList (ast-type-list-new)]
    (match (parse-ast-type-list dispatch pools s (&mut out))
      [(ResultAstTypeListBuild.Ok) (ResultAstTypeList.Ok out)]
      [(ResultAstTypeListBuild.Err message) (ResultAstTypeList.Err message)])))

(define (parse-ast-lifetime-name?
  [dispatch : sym_i64_env.SymI64Env]
  [name : i64]) : bool
  (let
    [tag : i64 (compiler-parse-dispatch-tag dispatch name)]
    (not
      (or
        (and
          (>= tag (compiler-parse-tag-ty-i64))
          (<= tag (compiler-parse-tag-ty-bytes)))
        (and
          (>= tag (compiler-parse-tag-ty-func))
          (<= tag (compiler-parse-tag-ty-dyn-array)))))))

(define (parse-ast-lifetime-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.Sexpr]
  [message : String]
  [out : (&mut out AstLifetimeList)]) : ResultAstLifetimeListBuild
  (match s
    [(reader.Sexpr.Nil) (ResultAstLifetimeListBuild.Ok)]
    [(reader.Sexpr.Cons head tail)
      (match (box-get head)
        [(reader.Sexpr.Sym name)
          (if (parse-ast-lifetime-name? dispatch name)
            (begin
              (ast-lifetime-list-push out name)
              (parse-ast-lifetime-list
                dispatch
                pools
                (box-get tail)
                message
                out))
            (ResultAstLifetimeListBuild.Err message))]
        [_ (ResultAstLifetimeListBuild.Err message)])]
    [(reader.Sexpr.Cons _ _) (ResultAstLifetimeListBuild.Err message)]
    [_ (ResultAstLifetimeListBuild.Err message)]))

(define (parse-ast-lifetime-list-result
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.Sexpr]
  [message : String]) : ResultAstLifetimeList
  (let
    [out : AstLifetimeList (ast-lifetime-list-new)]
    (match (parse-ast-lifetime-list dispatch pools s message (&mut out))
      [(ResultAstLifetimeListBuild.Ok) (ResultAstLifetimeList.Ok out)]
      [(ResultAstLifetimeListBuild.Err parse-message)
        (ResultAstLifetimeList.Err parse-message)])))

(define (parse-ast-lifetime-list-nonempty
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.Sexpr]
  [message : String]) : ResultAstLifetimeList
  (match s
    [(reader.Sexpr.Nil) (ResultAstLifetimeList.Err message)]
    [_ (parse-ast-lifetime-list-result dispatch pools s message)]))

(define (parse-ast-consuming-param-type-allowed? [ty : AstType]) : bool
  (match ty
    [(AstType.Ref _ _) false]
    [(AstType.MutRef _ _) false]
    [(AstType.Consume _) false]
    [_ true]))

(define (parse-ast-func-param-type
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.Sexpr]) : ResultAstType
  (match s
    [(reader.Sexpr.Cons key-node tail)
      (match (box-get key-node)
        [(reader.Sexpr.Sym key)
          (if (= key (cbi.compiler-builtin-ctfe-ref 179))
            (match (box-get tail)
              [(reader.Sexpr.Cons ty-node end)
                (match (box-get end)
                  [(reader.Sexpr.Nil)
                    (match (parse-ast-type dispatch pools (box-get ty-node))
                      [(ResultAstType.Ok ty)
                        (if (parse-ast-consuming-param-type-allowed? ty)
                          (ResultAstType.Ok
                            (ast-ty-consume-with-pools pools ty))
                          (ResultAstType.Err
                            "parse: :consume requires a non-reference parameter type"))]
                      [(ResultAstType.Err message) (ResultAstType.Err message)])]
                  [_
                    (ResultAstType.Err
                      "parse: (:consume T) expects exactly one type")])]
              [_
                (ResultAstType.Err
                  "parse: (:consume T) expects exactly one type")])
            (parse-ast-type dispatch pools s))]
        [_ (parse-ast-type dispatch pools s)])]
    [_ (parse-ast-type dispatch pools s)]))

(define (parse-ast-func-type-parts
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.Sexpr]) : ResultAstFuncTypeParts
  (match s
    [(reader.Sexpr.Cons arg rest)
      (match (box-get rest)
        [(reader.Sexpr.Nil)
          (match (parse-ast-type dispatch pools (box-get arg))
            [(ResultAstType.Ok parsed-ret)
              (ResultAstFuncTypeParts.Ok (ast-type-list-new) parsed-ret)]
            [(ResultAstType.Err message) (ResultAstFuncTypeParts.Err message)])]
        [_
          (match (parse-ast-func-param-type dispatch pools (box-get arg))
            [(ResultAstType.Ok parsed-arg)
              (match (parse-ast-func-type-parts dispatch pools (box-get rest))
                [(ResultAstFuncTypeParts.Ok parsed-args parsed-ret)
                  (ResultAstFuncTypeParts.Ok
                    (ast-type-cons-with-pools pools parsed-arg parsed-args)
                    parsed-ret)]
                [(ResultAstFuncTypeParts.Err message)
                  (ResultAstFuncTypeParts.Err message)])]
            [(ResultAstType.Err message) (ResultAstFuncTypeParts.Err message)])])]
    [_
      (ResultAstFuncTypeParts.Err
        "parse: function type needs at least return type")]))

(define (parse-ast-internal-binary-data
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons bytes-node tail _)
      (match (reader.sp-node-get bytes-node)
        [(reader.SpannedSexpr.Str bytes _)
          (match (reader.sp-node-get tail)
            [(reader.SpannedSexpr.Nil _)
              (ResultAstExpr.Ok
                (ast-node-pool-context-expr-push
                  pools
                  (AstExpr.BinaryData (ci.intern-str bytes))))]
            [_ (ResultAstExpr.Err "parse: malformed internal binary data")])]
        [_ (ResultAstExpr.Err "parse: malformed internal binary data")])]
    [_ (ResultAstExpr.Err "parse: malformed internal binary data")]))

(define (parse-ast-resolved-nominal-type
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.Sexpr]
  [is-struct : bool]) : ResultAstType
  (match rest
    [(reader.Sexpr.Cons name-node lifetimes-box)
      (match (box-get name-node)
        [(reader.Sexpr.Sym name-id)
          (match (parse-ast-lifetime-list-result
            dispatch
            pools
            (box-get lifetimes-box)
            "parse: malformed internal resolved type lifetime list")
            [(ResultAstLifetimeList.Ok lifetimes)
              (ResultAstType.Ok
                (if is-struct
                  (if (ast-lifetime-list-empty? (& lifetimes))
                    (AstType.Struct name-id)
                    (ast-ty-struct-args name-id lifetimes))
                  (if (ast-lifetime-list-empty? (& lifetimes))
                    (AstType.Enum name-id)
                    (ast-ty-enum-args name-id lifetimes))))]
            [(ResultAstLifetimeList.Err message) (ResultAstType.Err message)])]
        [(reader.Sexpr.Str _)
          (ResultAstType.Err
            "parse: malformed internal resolved type name was string")]
        [(reader.Sexpr.Int _ _)
          (ResultAstType.Err
            "parse: malformed internal resolved type name was integer")]
        [(reader.Sexpr.Nil)
          (ResultAstType.Err
            "parse: malformed internal resolved type name was nil")]
        [(reader.Sexpr.Cons _ _)
          (ResultAstType.Err
            "parse: malformed internal resolved type name was list")]
        [(reader.Sexpr.Char _)
          (ResultAstType.Err
            "parse: malformed internal resolved type name was char")]
        [(reader.Sexpr.Float _)
          (ResultAstType.Err
            "parse: malformed internal resolved type name was float")])]
    [_ (ResultAstType.Err "parse: malformed internal resolved type shape")]))

(define (parse-ast-reference-type
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.Sexpr]
  [mutable : bool]) : ResultAstType
  (match rest
    [(reader.Sexpr.Cons first tail)
      (match (box-get tail)
        ;; The parser is context-free. An empty lifetime marker is legal in
        ;; the AST, but the typechecker only accepts it while normalizing a
        ;; function signature into hidden signature-local lifetimes.
        [(reader.Sexpr.Nil)
          (match (parse-ast-type dispatch pools (box-get first))
            [(ResultAstType.Ok inner-ty)
              (if mutable
                (ResultAstType.Ok
                  (ast-ty-mut-ref-with-pools
                    pools
                    cbi.compiler-builtin-id-fix-empty
                    inner-ty))
                (ResultAstType.Ok
                  (ast-ty-ref-with-pools
                    pools
                    cbi.compiler-builtin-id-fix-empty
                    inner-ty)))]
            [(ResultAstType.Err message) (ResultAstType.Err message)])]
        [(reader.Sexpr.Cons inner end)
          (match (box-get end)
            [(reader.Sexpr.Nil)
              (match (box-get first)
                [(reader.Sexpr.Sym region)
                  (match (parse-ast-type dispatch pools (box-get inner))
                    [(ResultAstType.Ok inner-ty)
                      (if mutable
                        (ResultAstType.Ok
                          (ast-ty-mut-ref-with-pools pools region inner-ty))
                        (ResultAstType.Ok
                          (ast-ty-ref-with-pools pools region inner-ty)))]
                    [(ResultAstType.Err message) (ResultAstType.Err message)])]
                [_
                  (ResultAstType.Err
                    "parse: reference lifetime must be an identifier")])]
            [_
              (ResultAstType.Err
                (if mutable
                  "parse: &mut expects an optional lifetime and exactly one type"
                  "parse: & expects an optional lifetime and exactly one type"))])]
        [_
          (ResultAstType.Err
            (if mutable
              "parse: &mut expects an optional lifetime and exactly one type"
              "parse: & expects an optional lifetime and exactly one type"))])]
    [_
      (ResultAstType.Err
        (if mutable
          "parse: &mut expects an optional lifetime and exactly one type"
          "parse: & expects an optional lifetime and exactly one type"))]))

(define (parse-ast-type
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.Sexpr]) : ResultAstType
  (match s
    [(reader.Sexpr.Sym name)
      (let
        [name-id : i64 name]
        [tag : i64 (compiler-parse-dispatch-tag-id dispatch name-id)]
        (cond
          [(= tag (compiler-parse-tag-ty-i64)) (ResultAstType.Ok (AstType.I64))]
          [(= tag (compiler-parse-tag-ty-i32)) (ResultAstType.Ok (AstType.I32))]
          [(= tag (compiler-parse-tag-ty-i16)) (ResultAstType.Ok (AstType.I16))]
          [(= tag (compiler-parse-tag-ty-i8)) (ResultAstType.Ok (AstType.I8))]
          [(= tag (compiler-parse-tag-ty-u64)) (ResultAstType.Ok (AstType.U64))]
          [(= tag (compiler-parse-tag-ty-u32)) (ResultAstType.Ok (AstType.U32))]
          [(= tag (compiler-parse-tag-ty-u16)) (ResultAstType.Ok (AstType.U16))]
          [(= tag (compiler-parse-tag-ty-u8)) (ResultAstType.Ok (AstType.U8))]
          [(= tag (compiler-parse-tag-ty-f64)) (ResultAstType.Ok (AstType.F64))]
          [(= tag (compiler-parse-tag-ty-f32)) (ResultAstType.Ok (AstType.F32))]
          [(= tag (compiler-parse-tag-ty-bool))
            (ResultAstType.Ok (AstType.Bool))]
          [(= tag (compiler-parse-tag-ty-char))
            (ResultAstType.Ok (AstType.Char))]
          [(= tag (compiler-parse-tag-ty-string))
            (ResultAstType.Ok (AstType.String))]
          [(= tag (compiler-parse-tag-ty-str)) (ResultAstType.Ok (AstType.Str))]
          [(= tag (compiler-parse-tag-ty-bytes))
            (ResultAstType.Ok (AstType.Bytes))]
          [(= tag (compiler-parse-tag-unit)) (ResultAstType.Ok (AstType.Unit))]
          [(= tag (compiler-parse-tag-ty-never))
            (ResultAstType.Ok (AstType.Never))]
          [(= tag (compiler-parse-tag-ty-expr))
            (ResultAstType.Ok (AstType.Expr))]
          [else (ResultAstType.Ok (AstType.Var name-id))]))]
    [(reader.Sexpr.Cons head-node rest-box)
      (match (box-get head-node)
        [(reader.Sexpr.Sym head)
          (let
            [rest : reader.Sexpr (box-get rest-box)]
            [head-id : i64 head]
            [tag : i64 (compiler-parse-dispatch-tag-id dispatch head-id)]
            (cond
              ;; Macro output uses these non-lexer-spellable builtin IDs to
              ;; carry already-resolved aggregate types through quasiquotes.
              [(= head (cbi.compiler-builtin-ctfe-ref 106))
                (parse-ast-resolved-nominal-type dispatch pools rest true)]
              [(= head (cbi.compiler-builtin-ctfe-ref 107))
                (parse-ast-resolved-nominal-type dispatch pools rest false)]
              [(= tag (compiler-parse-tag-ty-func))
                (match (parse-ast-func-type-parts dispatch pools rest)
                  [(ResultAstFuncTypeParts.Ok args ret)
                    (ResultAstType.Ok (ast-ty-func-with-pools pools args ret))]
                  [(ResultAstFuncTypeParts.Err message)
                    (ResultAstType.Err message)])]
              [(= tag (compiler-parse-tag-ty-tuple))
                (match (parse-ast-type-list-result dispatch pools rest)
                  [(ResultAstTypeList.Ok elems)
                    (ResultAstType.Ok (ast-ty-tuple elems))]
                  [(ResultAstTypeList.Err message) (ResultAstType.Err message)])]
              [(= tag (compiler-parse-tag-ty-array))
                (match rest
                  [(reader.Sexpr.Cons elem tail)
                    (match (box-get tail)
                      [(reader.Sexpr.Nil)
                        (match (parse-ast-type dispatch pools (box-get elem))
                          [(ResultAstType.Ok elem-ty)
                            (ResultAstType.Ok
                              (ast-ty-dyn-array-with-pools pools elem-ty))]
                          [(ResultAstType.Err message)
                            (ResultAstType.Err message)])]
                      [(reader.Sexpr.Cons size-node end)
                        (match (box-get end)
                          [(reader.Sexpr.Nil)
                            (match (box-get size-node)
                              [(reader.Sexpr.Int size _)
                                (match (parse-ast-type
                                  dispatch
                                  pools
                                  (box-get elem))
                                  [(ResultAstType.Ok elem-ty)
                                    (ResultAstType.Ok
                                      (ast-ty-array-with-pools
                                        pools
                                        elem-ty
                                        size))]
                                  [(ResultAstType.Err message)
                                    (ResultAstType.Err message)])]
                              [_
                                (ResultAstType.Err
                                  "parse: array size must be integer")])]
                          [_ (ResultAstType.Err "parse: malformed array type")])]
                      [_ (ResultAstType.Err "parse: malformed array type")])]
                  [_ (ResultAstType.Err "parse: malformed array type")])]
              [(= tag (compiler-parse-tag-ty-dyn-array))
                (match rest
                  [(reader.Sexpr.Cons elem tail)
                    (match (box-get tail)
                      [(reader.Sexpr.Nil)
                        (match (parse-ast-type dispatch pools (box-get elem))
                          [(ResultAstType.Ok elem-ty)
                            (ResultAstType.Ok
                              (ast-ty-dyn-array-with-pools pools elem-ty))]
                          [(ResultAstType.Err message)
                            (ResultAstType.Err message)])]
                      [_
                        (ResultAstType.Err
                          "parse: __tl_dyn-array expects exactly one type")])]
                  [_
                    (ResultAstType.Err
                      "parse: __tl_dyn-array expects exactly one type")])]
              [(= tag (compiler-parse-tag-ty-ptr))
                (match rest
                  [(reader.Sexpr.Cons elem tail)
                    (match (box-get tail)
                      [(reader.Sexpr.Nil)
                        (match (parse-ast-type dispatch pools (box-get elem))
                          [(ResultAstType.Ok elem-ty)
                            (ResultAstType.Ok
                              (ast-ty-ptr-with-pools pools elem-ty))]
                          [(ResultAstType.Err message)
                            (ResultAstType.Err message)])]
                      [_
                        (ResultAstType.Err
                          "parse: Ptr expects exactly one type")])]
                  [_ (ResultAstType.Err "parse: Ptr expects exactly one type")])]
              [(= tag (compiler-parse-tag-ty-mut-ptr))
                (match rest
                  [(reader.Sexpr.Cons elem tail)
                    (match (box-get tail)
                      [(reader.Sexpr.Nil)
                        (match (parse-ast-type dispatch pools (box-get elem))
                          [(ResultAstType.Ok elem-ty)
                            (ResultAstType.Ok
                              (ast-ty-mut-ptr-with-pools pools elem-ty))]
                          [(ResultAstType.Err message)
                            (ResultAstType.Err message)])]
                      [_
                        (ResultAstType.Err
                          "parse: MutPtr expects exactly one type")])]
                  [_
                    (ResultAstType.Err "parse: MutPtr expects exactly one type")])]
              [(= tag (compiler-parse-tag-ty-box))
                (match rest
                  [(reader.Sexpr.Cons elem tail)
                    (match (box-get tail)
                      [(reader.Sexpr.Nil)
                        (match (parse-ast-type dispatch pools (box-get elem))
                          [(ResultAstType.Ok elem-ty)
                            (ResultAstType.Ok
                              (ast-ty-box-with-pools pools elem-ty))]
                          [(ResultAstType.Err message)
                            (ResultAstType.Err message)])]
                      [_
                        (ResultAstType.Err
                          "parse: Box expects exactly one type")])]
                  [_ (ResultAstType.Err "parse: Box expects exactly one type")])]
              [(= tag (compiler-parse-tag-ty-ref))
                (parse-ast-reference-type dispatch pools rest false)]
              [(= tag (compiler-parse-tag-ty-mut-ref))
                (parse-ast-reference-type dispatch pools rest true)]
              [(= tag (compiler-parse-tag-ty-region))
                (match rest
                  [(reader.Sexpr.Cons region-node tail)
                    (match (box-get tail)
                      [(reader.Sexpr.Cons inner end)
                        (match (box-get end)
                          [(reader.Sexpr.Nil)
                            (match (box-get region-node)
                              [(reader.Sexpr.Sym region)
                                (match (parse-ast-type
                                  dispatch
                                  pools
                                  (box-get inner))
                                  [(ResultAstType.Ok inner-ty)
                                    (ResultAstType.Ok
                                      (ast-ty-region-with-pools
                                        pools
                                        region
                                        inner-ty))]
                                  [(ResultAstType.Err message)
                                    (ResultAstType.Err message)])]
                              [_
                                (ResultAstType.Err
                                  "parse: region name must be an identifier")])]
                          [_ (ResultAstType.Err "parse: malformed region type")])]
                      [_ (ResultAstType.Err "parse: malformed region type")])]
                  [_ (ResultAstType.Err "parse: malformed region type")])]
              [else
                (match (parse-ast-lifetime-list-nonempty
                  dispatch
                  pools
                  rest
                  (compiler-parse-generic-type-policy-message
                    (ci.intern-str head)))
                  [(ResultAstLifetimeList.Ok lifetimes)
                    (ResultAstType.Ok (ast-ty-var-args head-id lifetimes))]
                  [(ResultAstLifetimeList.Err message)
                    (ResultAstType.Err message)])]))]
        [_ (ResultAstType.Err "parse: expected type")])]
    [_ (ResultAstType.Err "parse: expected type")]))

(define (parse-ast-type-spanned
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.SpannedSexpr]) : ResultAstType
  (let
    [result : ResultAstType
      (parse-ast-type dispatch pools (reader.spanned-sexpr-form s))]
    (match result
      [(ResultAstType.Err _)
        (begin
          (parse-ast-error-span-note! dispatch (reader.spanned-sexpr-span s))
          result)]
      [_ result])))

(define (parse-ast-runtime-param-result
  [name : i64]
  [ty : AstType]
  [end : reader.Sexpr]) : ResultAstParam
  (match end
    [(reader.Sexpr.Nil) (ResultAstParam.Ok (ast-param-id name ty false))]
    [(reader.Sexpr.Cons metadata-node after-metadata)
      (match (box-get after-metadata)
        [(reader.Sexpr.Nil)
          (match (box-get metadata-node)
            [(reader.Sexpr.Cons key-node metadata-tail)
              (match (box-get key-node)
                [(reader.Sexpr.Sym key)
                  (if (= key (cbi.compiler-builtin-ctfe-ref 179))
                    (match (box-get metadata-tail)
                      [(reader.Sexpr.Nil)
                        (if (parse-ast-consuming-param-type-allowed? ty)
                          (ResultAstParam.Ok
                            (ast-param-id-with-consume name ty false true))
                          (ResultAstParam.Err
                            "parse: :consume requires a non-reference parameter type"))]
                      [_
                        (ResultAstParam.Err
                          "parse: (:consume) parameter metadata takes no arguments")])
                    (let
                      [key-text : String (ci.intern-str key)]
                      (if (and
                        (> (string.string-length key-text) 0)
                        (= (string.string-ref key-text 0) ':'))
                        (ResultAstParam.Err
                          (string.append
                            "parse: unknown parameter metadata "
                            key-text))
                        (ResultAstParam.Err
                          "parse: malformed parameter metadata"))))]
                [_ (ResultAstParam.Err "parse: malformed parameter metadata")])]
            [_ (ResultAstParam.Err "parse: malformed parameter metadata")])]
        [_ (ResultAstParam.Err "parse: duplicate parameter metadata")])]
    [_ (ResultAstParam.Err "parse: malformed parameter")]))

(define (parse-ast-single-consume-param-metadata? [end : reader.Sexpr]) : bool
  (match end
    [(reader.Sexpr.Cons metadata-node after-metadata)
      (match (box-get after-metadata)
        [(reader.Sexpr.Nil)
          (match (box-get metadata-node)
            [(reader.Sexpr.Cons key-node metadata-tail)
              (match (box-get key-node)
                [(reader.Sexpr.Sym key)
                  (and
                    (= key (cbi.compiler-builtin-ctfe-ref 179))
                    (match (box-get metadata-tail)
                      [(reader.Sexpr.Nil) true]
                      [_ false]))]
                [_ false])]
            [_ false])]
        [_ false])]
    [_ false]))

(define (parse-ast-param
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.Sexpr]) : ResultAstParam
  (match s
    [(reader.Sexpr.Cons first rest)
      (match (box-get first)
        [(reader.Sexpr.Sym first-name)
          (if (= first-name cbi.compiler-builtin-id-fix-comptime)
            (match (box-get rest)
              [(reader.Sexpr.Cons name-node after-name)
                (match (box-get name-node)
                  [(reader.Sexpr.Sym name)
                    (match (box-get after-name)
                      [(reader.Sexpr.Cons colon rest2)
                        (match (box-get rest2)
                          [(reader.Sexpr.Cons ty end)
                            (match (box-get end)
                              [(reader.Sexpr.Nil)
                                (if (sexpr-colon? (box-get colon))
                                  (match (parse-ast-type
                                    dispatch
                                    pools
                                    (box-get ty))
                                    [(ResultAstType.Ok parsed-ty)
                                      (ResultAstParam.Ok
                                        (ast-param-id name parsed-ty true))]
                                    [(ResultAstType.Err message)
                                      (ResultAstParam.Err message)])
                                  (ResultAstParam.Err
                                    "parse: expected ':' in parameter"))]
                              [_
                                (if (parse-ast-single-consume-param-metadata?
                                  (box-get end))
                                  (ResultAstParam.Err
                                    "parse: comptime parameters cannot be consuming")
                                  (ResultAstParam.Err
                                    "parse: malformed parameter"))])]
                          [_ (ResultAstParam.Err "parse: malformed parameter")])]
                      [_ (ResultAstParam.Err "parse: malformed parameter")])]
                  [_ (ResultAstParam.Err "parse: malformed parameter")])]
              [_ (ResultAstParam.Err "parse: malformed parameter")])
            (match (box-get rest)
              [(reader.Sexpr.Cons colon rest2)
                (match (box-get rest2)
                  [(reader.Sexpr.Cons ty end)
                    (if (sexpr-colon? (box-get colon))
                      (match (parse-ast-type dispatch pools (box-get ty))
                        [(ResultAstType.Ok parsed-ty)
                          (parse-ast-runtime-param-result
                            first-name
                            parsed-ty
                            (box-get end))]
                        [(ResultAstType.Err message)
                          (ResultAstParam.Err message)])
                      (ResultAstParam.Err "parse: expected ':' in parameter"))]
                  [_ (ResultAstParam.Err "parse: malformed parameter")])]
              [_ (ResultAstParam.Err "parse: malformed parameter")]))]
        [_ (ResultAstParam.Err "parse: malformed parameter")])]
    [_ (ResultAstParam.Err "parse: malformed parameter")]))

(define (ast-param-list-has-comptime? [params : AstParamList]) : bool
  (ast-param-list-has-comptime-at? (& params) 0))

(define (ast-param-list-has-comptime-at?
  [params : (& params AstParamList)]
  [index : i64]) : bool
  (if (>= index (ast-param-list-len params))
    false
    (match (ast-param-list-get params index (ast-param-fallback))
      [(AstParam.Param _ _ is-comptime _)
        (if is-comptime
          true
          (ast-param-list-has-comptime-at? params (+ index 1)))])))

(define (ast-macro-param-variadic? [param : AstMacroParam]) : bool
  (match param
    [(AstMacroParam.Param _ _ variadic _) variadic]))

(define (ast-macro-param-shape-delimited-variadic? [param : AstMacroParam]) : bool
  (match param
    [(AstMacroParam.Param _ ty variadic _)
      (and
        variadic
        (match ty
          [(AstType.Var name)
            (=
              (ci.intern-qualified-base-id name)
              cbi.compiler-builtin-id-fix-ExprBindingClause)]
          [_ false]))]))

(define (parse-ast-macro-type-kind-known? [name : i64]) : bool
  (or
    (= name (cbi.compiler-builtin-ctfe-ref 159))
    (= name (cbi.compiler-builtin-ctfe-ref 160))
    (= name (cbi.compiler-builtin-ctfe-ref 161))
    (= name (cbi.compiler-builtin-ctfe-ref 162))
    (= name (cbi.compiler-builtin-ctfe-ref 163))
    (= name (cbi.compiler-builtin-ctfe-ref 164))
    (= name (cbi.compiler-builtin-ctfe-ref 165))
    (= name (cbi.compiler-builtin-ctfe-ref 166))
    (= name (cbi.compiler-builtin-ctfe-ref 167))
    (= name (cbi.compiler-builtin-ctfe-ref 168))
    (= name (cbi.compiler-builtin-ctfe-ref 169))
    (= name (cbi.compiler-builtin-ctfe-ref 170))
    (= name (cbi.compiler-builtin-ctfe-ref 223))
    (= name (cbi.compiler-builtin-ctfe-ref 173))
    (= name (cbi.compiler-builtin-ctfe-ref 174))
    (= name (cbi.compiler-builtin-ctfe-ref 125))
    (= name (cbi.compiler-builtin-ctfe-ref 224))
    (= name (cbi.compiler-builtin-ctfe-ref 225))
    (= name (cbi.compiler-builtin-ctfe-ref 124))
    (= name (cbi.compiler-builtin-ctfe-ref 226))
    (= name (cbi.compiler-builtin-ctfe-ref 227))
    (= name (cbi.compiler-builtin-ctfe-ref 171))
    (= name (cbi.compiler-builtin-ctfe-ref 228))
    (= name (cbi.compiler-builtin-ctfe-ref 229))
    (= name (cbi.compiler-builtin-ctfe-ref 230))
    (= name (cbi.compiler-builtin-ctfe-ref 231))
    (= name (cbi.compiler-builtin-ctfe-ref 232))
    (= name (cbi.compiler-builtin-ctfe-ref 233))))

(define (parse-ast-macro-type-kind-error
  [operand-name : String]
  [detail : String]) : String
  (string.concat3
    "parse: macro type operand "
    operand-name
    (string.append " constraint :kind " detail)))

(define (parse-ast-macro-type-kind-list
  [operand-name : String]
  [s : reader.Sexpr]) : ResultAstMacroTypeKindList
  (match s
    [(reader.Sexpr.Nil)
      (ResultAstMacroTypeKindList.Ok (ast-macro-type-kind-list-empty))]
    [(reader.Sexpr.Cons head tail)
      (match (box-get head)
        [(reader.Sexpr.Sym kind-name)
          (if (parse-ast-macro-type-kind-known? kind-name)
            (match (parse-ast-macro-type-kind-list operand-name (box-get tail))
              [(ResultAstMacroTypeKindList.Ok rest)
                (if (ast-macro-type-kind-list-contains-id? rest kind-name)
                  (ResultAstMacroTypeKindList.Err
                    (parse-ast-macro-type-kind-error
                      operand-name
                      (string.append
                        "has duplicate kind "
                        (ci.intern-str kind-name))))
                  (ResultAstMacroTypeKindList.Ok
                    (ast-macro-type-kind-list-cons-id kind-name rest)))]
              [(ResultAstMacroTypeKindList.Err message)
                (ResultAstMacroTypeKindList.Err message)])
            (ResultAstMacroTypeKindList.Err
              (parse-ast-macro-type-kind-error
                operand-name
                (string.append "has unknown kind " (ci.intern-str kind-name)))))]
        [_
          (ResultAstMacroTypeKindList.Err
            (parse-ast-macro-type-kind-error
              operand-name
              "expects unquoted kind names"))])]
    [_
      (ResultAstMacroTypeKindList.Err
        (parse-ast-macro-type-kind-error operand-name "is malformed"))]))

(define (parse-ast-macro-type-kind-constraint
  [operand-name : String]
  [s : reader.Sexpr]) : ResultAstMacroTypeKindList
  (match s
    [(reader.Sexpr.Cons head tail)
      (match (box-get head)
        [(reader.Sexpr.Sym tag)
          (if (= tag (cbi.compiler-builtin-ctfe-ref 221))
            (match (box-get tail)
              [(reader.Sexpr.Nil)
                (ResultAstMacroTypeKindList.Err
                  (parse-ast-macro-type-kind-error
                    operand-name
                    "requires at least one kind"))]
              [(reader.Sexpr.Cons _ _)
                (parse-ast-macro-type-kind-list operand-name (box-get tail))]
              [_
                (ResultAstMacroTypeKindList.Err
                  (parse-ast-macro-type-kind-error operand-name "is malformed"))])
            (ResultAstMacroTypeKindList.Err
              (string.concat3
                "parse: macro type operand "
                operand-name
                (string.append
                  " has unknown constraint form "
                  (ci.intern-str tag)))))]
        [_
          (ResultAstMacroTypeKindList.Err
            (parse-ast-macro-type-kind-error operand-name "is malformed"))])]
    [_
      (ResultAstMacroTypeKindList.Err
        (parse-ast-macro-type-kind-error operand-name "is malformed"))]))

(define (parse-ast-macro-type-operand? [ty : AstType]) : bool
  (match ty
    [(AstType.Var name) (= name cbi.compiler-builtin-id-fix-type)]
    [_ false]))

(define (parse-ast-macro-param-after-type
  [name : i64]
  [parsed-ty : AstType]
  [rest : reader.Sexpr]) : ResultAstMacroParam
  (let
    [name-text : String (ci.intern-str name)]
    (match rest
      [(reader.Sexpr.Nil)
        (ResultAstMacroParam.Ok (ast-macro-param name parsed-ty false))]
      [(reader.Sexpr.Cons suffix suffix-rest)
        (match (box-get suffix)
          [(reader.Sexpr.Sym suffix-name)
            (if (= suffix-name (cbi.compiler-builtin-ctfe-ref 222))
              (match (box-get suffix-rest)
                [(reader.Sexpr.Nil)
                  (ResultAstMacroParam.Ok (ast-macro-param name parsed-ty true))]
                [_ (ResultAstMacroParam.Err "parse: malformed macro operand")])
              (ResultAstMacroParam.Err "parse: malformed macro operand"))]
          [(reader.Sexpr.Cons _ _)
            (if (parse-ast-macro-type-operand? parsed-ty)
              (match (box-get suffix-rest)
                [(reader.Sexpr.Nil)
                  (match (parse-ast-macro-type-kind-constraint
                    name-text
                    (box-get suffix))
                    [(ResultAstMacroTypeKindList.Ok type-kinds)
                      (ResultAstMacroParam.Ok
                        (ast-macro-param-with-type-kinds
                          name
                          parsed-ty
                          false
                          type-kinds))]
                    [(ResultAstMacroTypeKindList.Err message)
                      (ResultAstMacroParam.Err message)])]
                [(reader.Sexpr.Cons maybe-dots after-dots)
                  (match (box-get maybe-dots)
                    [(reader.Sexpr.Sym dots-name)
                      (if (and
                        (= dots-name (cbi.compiler-builtin-ctfe-ref 222))
                        (match (box-get after-dots)
                          [(reader.Sexpr.Nil) true]
                          [_ false]))
                        (ResultAstMacroParam.Err
                          (parse-ast-macro-type-kind-error
                            name-text
                            "is not legal on variadic operands"))
                        (ResultAstMacroParam.Err
                          (parse-ast-macro-type-kind-error
                            name-text
                            "allows only one constraint form")))]
                    [_
                      (ResultAstMacroParam.Err
                        (parse-ast-macro-type-kind-error
                          name-text
                          "allows only one constraint form"))])]
                [_
                  (ResultAstMacroParam.Err
                    (parse-ast-macro-type-kind-error
                      name-text
                      "allows only one constraint form"))])
              (ResultAstMacroParam.Err
                (string.concat3
                  "parse: macro operand "
                  name-text
                  " constraint :kind is only legal on fixed type operands")))]
          [_ (ResultAstMacroParam.Err "parse: malformed macro operand")])]
      [_ (ResultAstMacroParam.Err "parse: malformed macro operand")])))

(define (parse-ast-macro-param
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.Sexpr]) : ResultAstMacroParam
  (match s
    [(reader.Sexpr.Cons name-node rest)
      (match (box-get name-node)
        [(reader.Sexpr.Sym name)
          (if (= name cbi.compiler-builtin-id-fix-comptime)
            (ResultAstMacroParam.Err
              "parse: defmacro operands are already compile-time")
            (match (box-get rest)
              [(reader.Sexpr.Cons colon rest2)
                (match (box-get rest2)
                  [(reader.Sexpr.Cons ty rest3)
                    (if (sexpr-colon? (box-get colon))
                      (match (parse-ast-type dispatch pools (box-get ty))
                        [(ResultAstType.Ok parsed-ty)
                          (parse-ast-macro-param-after-type
                            name
                            parsed-ty
                            (box-get rest3))]
                        [(ResultAstType.Err message)
                          (ResultAstMacroParam.Err message)])
                      (ResultAstMacroParam.Err
                        "parse: expected ':' in macro operand"))]
                  [_ (ResultAstMacroParam.Err "parse: malformed macro operand")])]
              [_ (ResultAstMacroParam.Err "parse: malformed macro operand")]))]
        [_ (ResultAstMacroParam.Err "parse: malformed macro operand")])]
    [_ (ResultAstMacroParam.Err "parse: malformed macro operand")]))

(define (parse-ast-macro-param-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.Sexpr]) : ResultAstMacroParamList
  (let
    [out : AstMacroParamList (ast-macro-param-list-new)]
    (match (parse-ast-macro-param-list-into dispatch pools s (&mut out))
      [(ResultAstMacroParamListBuild.Ok) (ResultAstMacroParamList.Ok out)]
      [(ResultAstMacroParamListBuild.Err message)
        (ResultAstMacroParamList.Err message)])))

(define (parse-ast-macro-param-list-into
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.Sexpr]
  [out : (&mut out AstMacroParamList)]) : ResultAstMacroParamListBuild
  (match s
    [(reader.Sexpr.Nil) ResultAstMacroParamListBuild.Ok]
    [(reader.Sexpr.Cons head tail)
      (match (parse-ast-macro-param dispatch pools (box-get head))
        [(ResultAstMacroParam.Ok parsed-head)
          (if (ast-macro-param-variadic? parsed-head)
            (match (box-get tail)
              [(reader.Sexpr.Nil)
                (begin
                  (ast-macro-param-list-push out parsed-head)
                  ResultAstMacroParamListBuild.Ok)]
              [_
                (if (ast-macro-param-shape-delimited-variadic? parsed-head)
                  (begin
                    (ast-macro-param-list-push out parsed-head)
                    (parse-ast-macro-param-list-into
                      dispatch
                      pools
                      (box-get tail)
                      out))
                  (ResultAstMacroParamListBuild.Err
                    "parse: only ExprBindingClause macro operands may be variadic before a later operand"))])
            (begin
              (ast-macro-param-list-push out parsed-head)
              (parse-ast-macro-param-list-into
                dispatch
                pools
                (box-get tail)
                out)))]
        [(ResultAstMacroParam.Err message)
          (ResultAstMacroParamListBuild.Err message)])]
    [_ (ResultAstMacroParamListBuild.Err "parse: malformed macro operand list")]))

(define (parse-ast-param-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.Sexpr]) : ResultAstParamList
  (let
    [out : AstParamList (ast-param-list-new)]
    (match (parse-ast-param-list-into dispatch pools s (&mut out))
      [(ResultAstParamListBuild.Ok) (ResultAstParamList.Ok out)]
      [(ResultAstParamListBuild.Err message) (ResultAstParamList.Err message)])))

(define (parse-ast-param-list-into
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.Sexpr]
  [out : (&mut out AstParamList)]) : ResultAstParamListBuild
  (match s
    [(reader.Sexpr.Nil) ResultAstParamListBuild.Ok]
    [(reader.Sexpr.Cons head tail)
      (match (parse-ast-param dispatch pools (box-get head))
        [(ResultAstParam.Ok parsed-head)
          (begin
            (ast-param-list-push out parsed-head)
            (parse-ast-param-list-into dispatch pools (box-get tail) out))]
        [(ResultAstParam.Err message) (ResultAstParamListBuild.Err message)])]
    [_ (ResultAstParamListBuild.Err "parse: malformed parameter list")]))

(define (parse-ast-field-cleanup [s : reader.Sexpr]) : ResultAstFieldCleanup
  (match s
    [(reader.Sexpr.Cons key-node tail)
      (match (box-get key-node)
        [(reader.Sexpr.Sym key)
          (cond
            [(= key (cbi.compiler-builtin-ctfe-ref 234))
              (match (box-get tail)
                [(reader.Sexpr.Cons cleanup-node end)
                  (match (box-get end)
                    [(reader.Sexpr.Nil)
                      (match (box-get cleanup-node)
                        [(reader.Sexpr.Sym cleanup-fn)
                          (ResultAstFieldCleanup.Ok
                            (ast-field-cleanup-fn-id cleanup-fn))]
                        [_
                          (ResultAstFieldCleanup.Err
                            "parse: malformed field :cleanup metadata")])]
                    [_
                      (ResultAstFieldCleanup.Err
                        "parse: malformed field :cleanup metadata")])]
                [_
                  (ResultAstFieldCleanup.Err
                    "parse: malformed field :cleanup metadata")])]
            [(= key (cbi.compiler-builtin-ctfe-ref 235))
              (match (box-get tail)
                [(reader.Sexpr.Nil)
                  (ResultAstFieldCleanup.Ok (AstFieldCleanup.Owned))]
                [_
                  (ResultAstFieldCleanup.Err
                    "parse: malformed field :owned metadata")])]
            [(compiler-parse-metadata-key? key)
              (ResultAstFieldCleanup.Err
                (string.append
                  "parse: unknown field metadata "
                  (compiler-parse-name-text key)))]
            [else
              (ResultAstFieldCleanup.Err
                "parse: malformed field cleanup metadata")])]
        [_
          (ResultAstFieldCleanup.Err "parse: malformed field cleanup metadata")])]
    [_ (ResultAstFieldCleanup.Err "parse: malformed field cleanup metadata")]))

(define (parse-ast-variant-payload-cleanup [s : reader.Sexpr]) : ResultAstVariantPayloadCleanup
  (match s
    [(reader.Sexpr.Cons key-node tail)
      (match (box-get key-node)
        [(reader.Sexpr.Sym key)
          (cond
            [(= key (cbi.compiler-builtin-ctfe-ref 234))
              (match (box-get tail)
                [(reader.Sexpr.Cons cleanup-node end)
                  (match (box-get end)
                    [(reader.Sexpr.Nil)
                      (match (box-get cleanup-node)
                        [(reader.Sexpr.Sym cleanup-fn)
                          (ResultAstVariantPayloadCleanup.Ok
                            (ast-variant-payload-cleanup-fn-id cleanup-fn))]
                        [_
                          (ResultAstVariantPayloadCleanup.Err
                            "parse: malformed enum payload :cleanup metadata")])]
                    [_
                      (ResultAstVariantPayloadCleanup.Err
                        "parse: malformed enum payload :cleanup metadata")])]
                [_
                  (ResultAstVariantPayloadCleanup.Err
                    "parse: malformed enum payload :cleanup metadata")])]
            [(= key (cbi.compiler-builtin-ctfe-ref 235))
              (match (box-get tail)
                [(reader.Sexpr.Nil)
                  (ResultAstVariantPayloadCleanup.Ok
                    (AstVariantPayloadCleanup.Owned))]
                [_
                  (ResultAstVariantPayloadCleanup.Err
                    "parse: malformed enum payload :owned metadata")])]
            [(compiler-parse-metadata-key? key)
              (ResultAstVariantPayloadCleanup.Err
                (string.append
                  "parse: unknown enum payload metadata "
                  (compiler-parse-name-text key)))]
            [else
              (ResultAstVariantPayloadCleanup.Err
                "parse: malformed enum payload cleanup metadata")])]
        [_
          (ResultAstVariantPayloadCleanup.Err
            "parse: malformed enum payload cleanup metadata")])]
    [_
      (ResultAstVariantPayloadCleanup.Err
        "parse: malformed enum payload cleanup metadata")]))

(define (parse-ast-field-def
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.Sexpr]
  [allow-cleanup : bool]) : ResultAstFieldDef
  (match s
    [(reader.Sexpr.Cons name-node tail)
      (match (box-get name-node)
        [(reader.Sexpr.Sym name)
          (match (box-get tail)
            [(reader.Sexpr.Cons ty rest)
              (match (box-get rest)
                [(reader.Sexpr.Nil)
                  (match (parse-ast-type dispatch pools (box-get ty))
                    [(ResultAstType.Ok parsed-ty)
                      (ResultAstFieldDef.Ok
                        (ast-field-def-id name parsed-ty (AstFieldCleanup.No)))]
                    [(ResultAstType.Err message)
                      (ResultAstFieldDef.Err message)])]
                [(reader.Sexpr.Cons cleanup-meta extra)
                  (match (box-get extra)
                    [(reader.Sexpr.Nil)
                      (if allow-cleanup
                        (match (parse-ast-type dispatch pools (box-get ty))
                          [(ResultAstType.Ok parsed-ty)
                            (match (parse-ast-field-cleanup
                              (box-get cleanup-meta))
                              [(ResultAstFieldCleanup.Ok parsed-cleanup)
                                (ResultAstFieldDef.Ok
                                  (ast-field-def-id
                                    name
                                    parsed-ty
                                    parsed-cleanup))]
                              [(ResultAstFieldCleanup.Err message)
                                (ResultAstFieldDef.Err message)])]
                          [(ResultAstType.Err message)
                            (ResultAstFieldDef.Err message)])
                        (ResultAstFieldDef.Err
                          "parse: field cleanup metadata requires struct :cleanup metadata"))]
                    [_
                      (ResultAstFieldDef.Err
                        "parse: duplicate field cleanup metadata")])]
                [_ (ResultAstFieldDef.Err "parse: malformed field definition")])]
            [_ (ResultAstFieldDef.Err "parse: malformed field definition")])]
        [_ (ResultAstFieldDef.Err "parse: malformed field definition")])]
    [_ (ResultAstFieldDef.Err "parse: malformed field definition")]))

(define (parse-ast-field-def-list-into
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.Sexpr]
  [allow-cleanup : bool]
  [out : (&mut out AstFieldDefList)]) : ResultAstFieldDefListBuild
  (match s
    [(reader.Sexpr.Nil) (ResultAstFieldDefListBuild.Ok)]
    [(reader.Sexpr.Cons head tail)
      (match (parse-ast-field-def dispatch pools (box-get head) allow-cleanup)
        [(ResultAstFieldDef.Ok parsed-head)
          (begin
            (ast-field-def-list-push out parsed-head)
            (parse-ast-field-def-list-into
              dispatch
              pools
              (box-get tail)
              allow-cleanup
              out))]
        [(ResultAstFieldDef.Err message)
          (ResultAstFieldDefListBuild.Err message)])]
    [_ (ResultAstFieldDefListBuild.Err "parse: malformed field list")]))

(define (parse-ast-field-def-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.Sexpr]
  [allow-cleanup : bool]) : ResultAstFieldDefList
  (let
    [out : AstFieldDefList (ast-field-def-list-new)]
    (match (parse-ast-field-def-list-into
      dispatch
      pools
      s
      allow-cleanup
      (&mut out))
      [(ResultAstFieldDefListBuild.Ok) (ResultAstFieldDefList.Ok out)]
      [(ResultAstFieldDefListBuild.Err message)
        (ResultAstFieldDefList.Err message)])))

(define (compiler-parse-metadata-key? [name-id : i64]) : bool
  ;; Unknown metadata is a genuinely prefix-bearing diagnostic boundary. All
  ;; recognized fixed keys are classified by ID before reaching this helper.
  (let
    [name : String (compiler-parse-name-text name-id)]
    (and (> (string.string-length name) 0) (= (string.string-ref name 0) ':'))))

(define (parse-ast-aggregate-lifetimes-tail
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [tail : reader.Sexpr]) : ResultAstLifetimeList
  (parse-ast-lifetime-list-nonempty
    dispatch
    pools
    tail
    "parse: :lifetimes metadata expects at least one lifetime identifier"))

(define (parse-ast-defstruct-repr-tail [tail : reader.Sexpr]) : ResultAstStructRepr
  (match tail
    [(reader.Sexpr.Cons name-node end)
      (match (box-get end)
        [(reader.Sexpr.Nil)
          (match (box-get name-node)
            [(reader.Sexpr.Sym name)
              (if (= name cbi.compiler-builtin-id-fix-c)
                (ResultAstStructRepr.Ok (AstStructRepr.C))
                (if (= name (cbi.compiler-builtin-ctfe-ref 239))
                  (ResultAstStructRepr.Err "parse: packed repr is reserved")
                  (ResultAstStructRepr.Err
                    (string.append
                      "parse: unknown struct repr "
                      (compiler-parse-name-text name)))))]
            [_ (ResultAstStructRepr.Err "parse: malformed :repr metadata")])]
        [_ (ResultAstStructRepr.Err "parse: malformed :repr metadata")])]
    [_ (ResultAstStructRepr.Err "parse: malformed :repr metadata")]))

(define (parse-ast-defstruct-cleanup-tail [tail : reader.Sexpr]) : ResultAstStructCleanup
  (match tail
    [(reader.Sexpr.Cons cleanup-node end)
      (match (box-get end)
        [(reader.Sexpr.Nil)
          (match (box-get cleanup-node)
            [(reader.Sexpr.Sym cleanup-fn)
              (ResultAstStructCleanup.Ok (ast-struct-cleanup-fn-id cleanup-fn))]
            [_
              (ResultAstStructCleanup.Err
                "parse: malformed defstruct :cleanup metadata")])]
        [_
          (ResultAstStructCleanup.Err
            "parse: malformed defstruct :cleanup metadata")])]
    [_
      (ResultAstStructCleanup.Err
        "parse: malformed defstruct :cleanup metadata")]))

(define (parse-ast-defenum-cleanup-tail [tail : reader.Sexpr]) : ResultAstEnumCleanup
  (match tail
    [(reader.Sexpr.Cons cleanup-node end)
      (match (box-get end)
        [(reader.Sexpr.Nil)
          (match (box-get cleanup-node)
            [(reader.Sexpr.Sym cleanup-fn)
              (ResultAstEnumCleanup.Ok (ast-enum-cleanup-fn-id cleanup-fn))]
            [_
              (ResultAstEnumCleanup.Err
                "parse: malformed defenum :cleanup metadata")])]
        [_
          (ResultAstEnumCleanup.Err
            "parse: malformed defenum :cleanup metadata")])]
    [_ (ResultAstEnumCleanup.Err "parse: malformed defenum :cleanup metadata")]))

(define (parse-ast-defstruct-field-item
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [head : reader.SpannedSexpr]
  [tail : reader.SpannedSexpr]
  [lifetimes : AstLifetimeList]
  [repr : AstStructRepr]
  [cleanup : AstStructCleanup]
  [fields : AstFieldDefList]
  [seen-lifetimes : bool]
  [seen-repr : bool]
  [seen-cleanup : bool]) : ResultAstStructDefParts
  (match (parse-ast-field-def
    dispatch
    pools
    (reader.spanned-sexpr-form head)
    (ast-struct-cleanup? cleanup))
    [(ResultAstFieldDef.Ok parsed-field)
      (let
        [next-fields : AstFieldDefList fields]
        (begin
          (ast-field-def-list-push (&mut next-fields) parsed-field)
          (reader.sp-node-push
            (reader.SpannedSexpr.Nil (reader.spanned-sexpr-span head)))
          (parse-ast-defstruct-items
            dispatch
            pools
            tail
            lifetimes
            repr
            cleanup
            next-fields
            seen-lifetimes
            seen-repr
            seen-cleanup
            true)))]
    [(ResultAstFieldDef.Err message) (ResultAstStructDefParts.Err message)]))

(define (parse-ast-defstruct-items
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [items : reader.SpannedSexpr]
  [lifetimes : AstLifetimeList]
  [repr : AstStructRepr]
  [cleanup : AstStructCleanup]
  [fields : AstFieldDefList]
  [seen-lifetimes : bool]
  [seen-repr : bool]
  [seen-cleanup : bool]
  [seen-field : bool]) : ResultAstStructDefParts
  (match items
    [(reader.SpannedSexpr.Nil _)
      (ResultAstStructDefParts.Ok lifetimes repr cleanup fields)]
    [(reader.SpannedSexpr.Cons head tail _)
      (match (reader.spanned-sexpr-form (reader.sp-node-get head))
        [(reader.Sexpr.Cons key-node after-key)
          (match (box-get key-node)
            [(reader.Sexpr.Sym key)
              (cond
                [(= key (cbi.compiler-builtin-ctfe-ref 236))
                  (if seen-field
                    (ResultAstStructDefParts.Err
                      "parse: defstruct metadata must appear before fields")
                    (if seen-lifetimes
                      (ResultAstStructDefParts.Err
                        "parse: duplicate defstruct :lifetimes metadata")
                      (match (parse-ast-aggregate-lifetimes-tail
                        dispatch
                        pools
                        (box-get after-key))
                        [(ResultAstLifetimeList.Ok next-lifetimes)
                          (parse-ast-defstruct-items
                            dispatch
                            pools
                            (reader.sp-node-get tail)
                            next-lifetimes
                            repr
                            cleanup
                            fields
                            true
                            seen-repr
                            seen-cleanup
                            false)]
                        [(ResultAstLifetimeList.Err message)
                          (ResultAstStructDefParts.Err message)])))]
                [(= key (cbi.compiler-builtin-ctfe-ref 237))
                  (if seen-field
                    (ResultAstStructDefParts.Err
                      "parse: defstruct metadata must appear before fields")
                    (if seen-repr
                      (ResultAstStructDefParts.Err
                        "parse: duplicate defstruct :repr metadata")
                      (match (parse-ast-defstruct-repr-tail (box-get after-key))
                        [(ResultAstStructRepr.Ok next-repr)
                          (if (and
                            (ast-struct-repr-c? next-repr)
                            (ast-struct-cleanup? cleanup))
                            (ResultAstStructDefParts.Err
                              "parse: defstruct cannot combine :repr c with :cleanup metadata")
                            (parse-ast-defstruct-items
                              dispatch
                              pools
                              (reader.sp-node-get tail)
                              lifetimes
                              next-repr
                              cleanup
                              fields
                              seen-lifetimes
                              true
                              seen-cleanup
                              false))]
                        [(ResultAstStructRepr.Err message)
                          (ResultAstStructDefParts.Err message)])))]
                [(= key (cbi.compiler-builtin-ctfe-ref 234))
                  (if seen-field
                    (ResultAstStructDefParts.Err
                      "parse: defstruct metadata must appear before fields")
                    (if seen-cleanup
                      (ResultAstStructDefParts.Err
                        "parse: duplicate defstruct :cleanup metadata")
                      (match (parse-ast-defstruct-cleanup-tail
                        (box-get after-key))
                        [(ResultAstStructCleanup.Ok next-cleanup)
                          (if (ast-struct-repr-c? repr)
                            (ResultAstStructDefParts.Err
                              "parse: defstruct cannot combine :repr c with :cleanup metadata")
                            (parse-ast-defstruct-items
                              dispatch
                              pools
                              (reader.sp-node-get tail)
                              lifetimes
                              repr
                              next-cleanup
                              fields
                              seen-lifetimes
                              seen-repr
                              true
                              false))]
                        [(ResultAstStructCleanup.Err message)
                          (ResultAstStructDefParts.Err message)])))]
                [(compiler-parse-metadata-key? key)
                  (if seen-field
                    (ResultAstStructDefParts.Err
                      "parse: defstruct metadata must appear before fields")
                    (if (= key (cbi.compiler-builtin-ctfe-ref 238))
                      (ResultAstStructDefParts.Err
                        "parse: packed repr is reserved")
                      (ResultAstStructDefParts.Err
                        (string.append
                          "parse: unknown defstruct metadata "
                          (compiler-parse-name-text key)))))]
                [else
                  (parse-ast-defstruct-field-item
                    dispatch
                    pools
                    (reader.sp-node-get head)
                    (reader.sp-node-get tail)
                    lifetimes
                    repr
                    cleanup
                    fields
                    seen-lifetimes
                    seen-repr
                    seen-cleanup)])]
            [_
              (parse-ast-defstruct-field-item
                dispatch
                pools
                (reader.sp-node-get head)
                (reader.sp-node-get tail)
                lifetimes
                repr
                cleanup
                fields
                seen-lifetimes
                seen-repr
                seen-cleanup)])]
        [_
          (parse-ast-defstruct-field-item
            dispatch
            pools
            (reader.sp-node-get head)
            (reader.sp-node-get tail)
            lifetimes
            repr
            cleanup
            fields
            seen-lifetimes
            seen-repr
            seen-cleanup)])]
    [_ (ResultAstStructDefParts.Err "parse: malformed field list")]))

(define (compiler-parse-type-list-has-metadata? [s : reader.Sexpr]) : bool
  (match s
    [(reader.Sexpr.Nil) false]
    [(reader.Sexpr.Cons head rest)
      (match (box-get head)
        [(reader.Sexpr.Cons key-node _)
          (match (box-get key-node)
            [(reader.Sexpr.Sym key)
              (if (compiler-parse-metadata-key? key)
                true
                (compiler-parse-type-list-has-metadata? (box-get rest)))]
            [_ (compiler-parse-type-list-has-metadata? (box-get rest))])]
        [_ (compiler-parse-type-list-has-metadata? (box-get rest))])]
    [_ false]))

(define (compiler-parse-metadata-sexpr? [s : reader.Sexpr]) : bool
  (match s
    [(reader.Sexpr.Cons key-node _)
      (match (box-get key-node)
        [(reader.Sexpr.Sym key) (compiler-parse-metadata-key? key)]
        [_ false])]
    [_ false]))

(define (parse-ast-variant-payload-parts
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.Sexpr]
  [allow-cleanup : bool]) : ResultAstVariantPayloadParts
  (match s
    [(reader.Sexpr.Nil)
      (ResultAstVariantPayloadParts.Ok
        (ast-type-list-new)
        (ast-variant-payload-cleanup-list-new))]
    [(reader.Sexpr.Cons ty-node rest)
      (let
        [ty-form : reader.Sexpr (box-get ty-node)]
        [rest-form : reader.Sexpr (box-get rest)]
        (if (compiler-parse-metadata-sexpr? ty-form)
          (ResultAstVariantPayloadParts.Err
            "parse: enum payload cleanup metadata must follow a payload type")
          (match (parse-ast-type dispatch pools ty-form)
            [(ResultAstType.Ok parsed-ty)
              (match rest-form
                [(reader.Sexpr.Nil)
                  (ResultAstVariantPayloadParts.Ok
                    (ast-type-cons-with-pools
                      pools
                      parsed-ty
                      (ast-type-list-new))
                    (ast-variant-payload-cleanup-cons
                      (AstVariantPayloadCleanup.No)
                      (ast-variant-payload-cleanup-list-new)))]
                [(reader.Sexpr.Cons cleanup-node after-cleanup)
                  (let
                    [cleanup-form : reader.Sexpr (box-get cleanup-node)]
                    (if (compiler-parse-metadata-sexpr? cleanup-form)
                      (if allow-cleanup
                        (match (parse-ast-variant-payload-cleanup cleanup-form)
                          [(ResultAstVariantPayloadCleanup.Ok parsed-cleanup)
                            (match (parse-ast-variant-payload-parts
                              dispatch
                              pools
                              (box-get after-cleanup)
                              allow-cleanup)
                              [(ResultAstVariantPayloadParts.Ok
                                  parsed-rest
                                  cleanup-rest)
                                (ResultAstVariantPayloadParts.Ok
                                  (ast-type-cons-with-pools
                                    pools
                                    parsed-ty
                                    parsed-rest)
                                  (ast-variant-payload-cleanup-cons
                                    parsed-cleanup
                                    cleanup-rest))]
                              [(ResultAstVariantPayloadParts.Err message)
                                (ResultAstVariantPayloadParts.Err message)])]
                          [(ResultAstVariantPayloadCleanup.Err message)
                            (ResultAstVariantPayloadParts.Err message)])
                        (ResultAstVariantPayloadParts.Err
                          "parse: enum payload cleanup metadata requires enum :cleanup metadata"))
                      (match (parse-ast-variant-payload-parts
                        dispatch
                        pools
                        rest-form
                        allow-cleanup)
                        [(ResultAstVariantPayloadParts.Ok
                            parsed-rest
                            cleanup-rest)
                          (ResultAstVariantPayloadParts.Ok
                            (ast-type-cons-with-pools
                              pools
                              parsed-ty
                              parsed-rest)
                            (ast-variant-payload-cleanup-cons
                              (AstVariantPayloadCleanup.No)
                              cleanup-rest))]
                        [(ResultAstVariantPayloadParts.Err message)
                          (ResultAstVariantPayloadParts.Err message)])))]
                [_
                  (ResultAstVariantPayloadParts.Err
                    "parse: malformed enum payload list")])]
            [(ResultAstType.Err message)
              (ResultAstVariantPayloadParts.Err message)])))]
    [_ (ResultAstVariantPayloadParts.Err "parse: malformed enum payload list")]))

(define (parse-ast-variant-def
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.Sexpr]
  [allow-cleanup : bool]) : ResultAstVariantDef
  (match s
    [(reader.Sexpr.Cons name-node fields)
      (match (box-get name-node)
        [(reader.Sexpr.Sym name)
          (if (compiler-parse-metadata-key? name)
            (if (= name (cbi.compiler-builtin-ctfe-ref 234))
              (ResultAstVariantDef.Err
                "parse: defenum metadata must appear before variants")
              (ResultAstVariantDef.Err
                (string.append
                  "parse: unknown defenum metadata "
                  (compiler-parse-name-text name))))
            (match (parse-ast-variant-payload-parts
              dispatch
              pools
              (box-get fields)
              allow-cleanup)
              [(ResultAstVariantPayloadParts.Ok parsed-fields parsed-cleanups)
                (ResultAstVariantDef.Ok
                  (ast-variant-def-id name parsed-fields parsed-cleanups))]
              [(ResultAstVariantPayloadParts.Err message)
                (ResultAstVariantDef.Err message)]))]
        [_ (ResultAstVariantDef.Err "parse: malformed variant definition")])]
    [_ (ResultAstVariantDef.Err "parse: malformed variant definition")]))

(define (parse-ast-variant-def-list-into
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.Sexpr]
  [allow-cleanup : bool]
  [out : (&mut out AstVariantDefList)]) : ResultAstVariantDefListBuild
  (match s
    [(reader.Sexpr.Nil) (ResultAstVariantDefListBuild.Ok)]
    [(reader.Sexpr.Cons head tail)
      (match (parse-ast-variant-def dispatch pools (box-get head) allow-cleanup)
        [(ResultAstVariantDef.Ok parsed-head)
          (begin
            (ast-variant-def-list-push out parsed-head)
            (parse-ast-variant-def-list-into
              dispatch
              pools
              (box-get tail)
              allow-cleanup
              out))]
        [(ResultAstVariantDef.Err message)
          (ResultAstVariantDefListBuild.Err message)])]
    [_ (ResultAstVariantDefListBuild.Err "parse: malformed variant list")]))

(define (parse-ast-variant-def-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.Sexpr]
  [allow-cleanup : bool]) : ResultAstVariantDefList
  (let
    [out : AstVariantDefList (ast-variant-def-list-new)]
    (match (parse-ast-variant-def-list-into
      dispatch
      pools
      s
      allow-cleanup
      (&mut out))
      [(ResultAstVariantDefListBuild.Ok) (ResultAstVariantDefList.Ok out)]
      [(ResultAstVariantDefListBuild.Err message)
        (ResultAstVariantDefList.Err message)])))

(define (parse-ast-dispatch-isa [name : i64]) : ResultAstDispatchIsa
  (cond
    [(= name (cbi.compiler-builtin-ctfe-ref 240))
      (ResultAstDispatchIsa.Ok (AstDispatchIsa.Scalar))]
    [(= name (cbi.compiler-builtin-ctfe-ref 241))
      (ResultAstDispatchIsa.Ok (AstDispatchIsa.Avx2))]
    [(= name (cbi.compiler-builtin-ctfe-ref 242))
      (ResultAstDispatchIsa.Ok (AstDispatchIsa.Avx512))]
    [else
      (ResultAstDispatchIsa.Err
        (string.append
          "parse: unknown defdispatch ISA "
          (compiler-parse-name-text name)))]))

(define (parse-ast-dispatch-variant [s : reader.SpannedSexpr]) : ResultAstDispatchVariant
  (match s
    [(reader.SpannedSexpr.Cons isa-node rest _)
      (match (reader.sp-node-get isa-node)
        [(reader.SpannedSexpr.Sym isa-name _)
          (match (reader.sp-node-get rest)
            [(reader.SpannedSexpr.Cons fn-node end _)
              (match (reader.sp-node-get end)
                [(reader.SpannedSexpr.Nil _)
                  (match (reader.sp-node-get fn-node)
                    [(reader.SpannedSexpr.Sym fn-name _)
                      (match (parse-ast-dispatch-isa isa-name)
                        [(ResultAstDispatchIsa.Ok isa)
                          (ResultAstDispatchVariant.Ok
                            (AstDispatchVariant.Variant isa fn-name))]
                        [(ResultAstDispatchIsa.Err message)
                          (ResultAstDispatchVariant.Err message)])]
                    [_
                      (ResultAstDispatchVariant.Err
                        "parse: malformed defdispatch variant")])]
                [_
                  (ResultAstDispatchVariant.Err
                    "parse: malformed defdispatch variant")])]
            [_
              (ResultAstDispatchVariant.Err
                "parse: malformed defdispatch variant")])]
        [_
          (ResultAstDispatchVariant.Err "parse: malformed defdispatch variant")])]
    [_ (ResultAstDispatchVariant.Err "parse: malformed defdispatch variant")]))

(define (parse-ast-dispatch-variant-list-into
  [variants : reader.SpannedSexpr]
  [out : (&mut out AstDispatchVariantList)]) : ResultAstDispatchVariantListBuild
  (match variants
    [(reader.SpannedSexpr.Nil _) (ResultAstDispatchVariantListBuild.Ok)]
    [(reader.SpannedSexpr.Cons head rest _)
      (match (parse-ast-dispatch-variant (reader.sp-node-get head))
        [(ResultAstDispatchVariant.Ok parsed)
          (begin
            (ast-dispatch-variant-list-push out parsed)
            (parse-ast-dispatch-variant-list-into (reader.sp-node-get rest) out))]
        [(ResultAstDispatchVariant.Err message)
          (ResultAstDispatchVariantListBuild.Err message)])]
    [_
      (ResultAstDispatchVariantListBuild.Err
        "parse: malformed defdispatch variant list")]))

(define (parse-ast-dispatch-variant-list [variants : reader.SpannedSexpr]) : ResultAstDispatchVariantList
  (let
    [out : AstDispatchVariantList (ast-dispatch-variant-list-new)]
    (match (parse-ast-dispatch-variant-list-into variants (&mut out))
      [(ResultAstDispatchVariantListBuild.Ok)
        (ResultAstDispatchVariantList.Ok out)]
      [(ResultAstDispatchVariantListBuild.Err message)
        (ResultAstDispatchVariantList.Err message)])))

(define (parse-ast-defenum-variant-item
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [head : reader.SpannedSexpr]
  [tail : reader.SpannedSexpr]
  [lifetimes : AstLifetimeList]
  [cleanup : AstEnumCleanup]
  [seen-lifetimes : bool]
  [seen-cleanup : bool]) : ResultAstEnumDefParts
  (match (parse-ast-variant-def
    dispatch
    pools
    (reader.spanned-sexpr-form head)
    (ast-enum-cleanup? cleanup))
    [(ResultAstVariantDef.Ok parsed-variant)
      (begin
        (reader.sp-node-push
          (reader.SpannedSexpr.Nil (reader.spanned-sexpr-span head)))
        (match (parse-ast-defenum-items
          dispatch
          pools
          tail
          lifetimes
          cleanup
          seen-lifetimes
          seen-cleanup
          true)
          [(ResultAstEnumDefParts.Ok
              parsed-lifetimes
              parsed-cleanup
              parsed-rest)
            (ResultAstEnumDefParts.Ok
              parsed-lifetimes
              parsed-cleanup
              (ast-variant-def-cons parsed-variant parsed-rest))]
          [(ResultAstEnumDefParts.Err message)
            (ResultAstEnumDefParts.Err message)]))]
    [(ResultAstVariantDef.Err message) (ResultAstEnumDefParts.Err message)]))

(define (parse-ast-defenum-items
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [items : reader.SpannedSexpr]
  [lifetimes : AstLifetimeList]
  [cleanup : AstEnumCleanup]
  [seen-lifetimes : bool]
  [seen-cleanup : bool]
  [seen-variant : bool]) : ResultAstEnumDefParts
  (match items
    [(reader.SpannedSexpr.Nil _)
      (ResultAstEnumDefParts.Ok lifetimes cleanup (ast-variant-def-list-new))]
    [(reader.SpannedSexpr.Cons head tail _)
      (match (reader.spanned-sexpr-form (reader.sp-node-get head))
        [(reader.Sexpr.Cons key-node after-key)
          (match (box-get key-node)
            [(reader.Sexpr.Sym key)
              (cond
                [(not (compiler-parse-metadata-key? key))
                  (parse-ast-defenum-variant-item
                    dispatch
                    pools
                    (reader.sp-node-get head)
                    (reader.sp-node-get tail)
                    lifetimes
                    cleanup
                    seen-lifetimes
                    seen-cleanup)]
                [seen-variant
                  (ResultAstEnumDefParts.Err
                    "parse: defenum metadata must appear before variants")]
                [(= key (cbi.compiler-builtin-ctfe-ref 236))
                  (if seen-lifetimes
                    (ResultAstEnumDefParts.Err
                      "parse: duplicate defenum :lifetimes metadata")
                    (match (parse-ast-aggregate-lifetimes-tail
                      dispatch
                      pools
                      (box-get after-key))
                      [(ResultAstLifetimeList.Ok next-lifetimes)
                        (parse-ast-defenum-items
                          dispatch
                          pools
                          (reader.sp-node-get tail)
                          next-lifetimes
                          cleanup
                          true
                          seen-cleanup
                          false)]
                      [(ResultAstLifetimeList.Err message)
                        (ResultAstEnumDefParts.Err message)]))]
                [(= key (cbi.compiler-builtin-ctfe-ref 234))
                  (if seen-cleanup
                    (ResultAstEnumDefParts.Err
                      "parse: duplicate defenum :cleanup metadata")
                    (match (parse-ast-defenum-cleanup-tail (box-get after-key))
                      [(ResultAstEnumCleanup.Ok next-cleanup)
                        (parse-ast-defenum-items
                          dispatch
                          pools
                          (reader.sp-node-get tail)
                          lifetimes
                          next-cleanup
                          seen-lifetimes
                          true
                          false)]
                      [(ResultAstEnumCleanup.Err message)
                        (ResultAstEnumDefParts.Err message)]))]
                [else
                  (ResultAstEnumDefParts.Err
                    (string.append
                      "parse: unknown defenum metadata "
                      (compiler-parse-name-text key)))])]
            [_
              (parse-ast-defenum-variant-item
                dispatch
                pools
                (reader.sp-node-get head)
                (reader.sp-node-get tail)
                lifetimes
                cleanup
                seen-lifetimes
                seen-cleanup)])]
        [_
          (parse-ast-defenum-variant-item
            dispatch
            pools
            (reader.sp-node-get head)
            (reader.sp-node-get tail)
            lifetimes
            cleanup
            seen-lifetimes
            seen-cleanup)])]
    [_ (ResultAstEnumDefParts.Err "parse: malformed variant list")]))

(define (parse-ast-pattern-list-into
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.Sexpr]
  [out : (&mut out AstPatternList)]) : ResultAstPatternListBuild
  (match s
    [(reader.Sexpr.Nil) (ResultAstPatternListBuild.Ok)]
    [(reader.Sexpr.Cons head tail)
      (match (parse-ast-pattern dispatch pools (box-get head))
        [(ResultAstPattern.Ok parsed-head)
          (begin
            (ast-pattern-list-push out parsed-head)
            (parse-ast-pattern-list-into dispatch pools (box-get tail) out))]
        [(ResultAstPattern.Err message) (ResultAstPatternListBuild.Err message)])]
    [_ (ResultAstPatternListBuild.Err "parse: malformed pattern list")]))

(define (parse-ast-pattern-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.Sexpr]) : ResultAstPatternList
  (let
    [out : AstPatternList (ast-pattern-list-new)]
    (match (parse-ast-pattern-list-into dispatch pools s (&mut out))
      [(ResultAstPatternListBuild.Ok) (ResultAstPatternList.Ok out)]
      [(ResultAstPatternListBuild.Err message)
        (ResultAstPatternList.Err message)])))

(define (parse-ast-pattern
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.Sexpr]) : ResultAstPattern
  (match s
    [(reader.Sexpr.Int n text)
      (ResultAstPattern.Ok (AstPattern.Literal (AstLiteral.Int n text)))]
    [(reader.Sexpr.Float text)
      (ResultAstPattern.Ok (AstPattern.Literal (AstLiteral.Float text)))]
    [(reader.Sexpr.Str string-id)
      (ResultAstPattern.Ok (AstPattern.Literal (AstLiteral.String string-id)))]
    [(reader.Sexpr.Char c)
      (ResultAstPattern.Ok (AstPattern.Literal (AstLiteral.Char c)))]
    [(reader.Sexpr.Sym name)
      (let
        [name-id : i64 name]
        [tag : i64 (compiler-parse-dispatch-tag-id dispatch name-id)]
        (cond
          [(= tag (compiler-parse-tag-pattern-wildcard))
            (ResultAstPattern.Ok AstPattern.Wildcard)]
          [(= tag (compiler-parse-tag-lit-true))
            (ResultAstPattern.Ok (AstPattern.Literal (AstLiteral.Bool true)))]
          [(= tag (compiler-parse-tag-lit-false))
            (ResultAstPattern.Ok (AstPattern.Literal (AstLiteral.Bool false)))]
          [else (ResultAstPattern.Ok (ast-pat-binding-id name-id))]))]
    [(reader.Sexpr.Cons name-node args)
      (match (box-get name-node)
        [(reader.Sexpr.Sym name)
          (match (parse-ast-pattern-list dispatch pools (box-get args))
            [(ResultAstPatternList.Ok parsed-args)
              (ResultAstPattern.Ok (ast-pat-variant-id name parsed-args))]
            [(ResultAstPatternList.Err message) (ResultAstPattern.Err message)])]
        [_ (ResultAstPattern.Err "parse: expected pattern")])]
    [_ (ResultAstPattern.Err "parse: expected pattern")]))

(define (parse-ast-cfg-expr-maybe
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstMaybeExpr
  (match rest
    [(reader.SpannedSexpr.Cons pred then-tail _)
      (match (reader.sp-node-get then-tail)
        [(reader.SpannedSexpr.Cons then-expr rest-tail _)
          (match (reader.sp-node-get rest-tail)
            [(reader.SpannedSexpr.Nil _)
              (match (compiler-cfg-eval dispatch (reader.sp-node-get pred))
                [(ResultCompilerCfg.Ok enabled)
                  (if enabled
                    (match (parse-ast-expr-with-pools
                      dispatch
                      pools
                      (reader.sp-node-get then-expr))
                      [(ResultAstExpr.Ok parsed)
                        (ResultAstMaybeExpr.SomeExpr parsed)]
                      [(ResultAstExpr.Err message)
                        (ResultAstMaybeExpr.Err message)])
                    (ResultAstMaybeExpr.NoExpr))]
                [(ResultCompilerCfg.Err message)
                  (ResultAstMaybeExpr.Err message)])]
            [(reader.SpannedSexpr.Cons else-expr end _)
              (match (reader.sp-node-get end)
                [(reader.SpannedSexpr.Nil _)
                  (match (compiler-cfg-eval dispatch (reader.sp-node-get pred))
                    [(ResultCompilerCfg.Ok enabled)
                      (match (parse-ast-expr-with-pools
                        dispatch
                        pools
                        (if enabled
                          (reader.sp-node-get then-expr)
                          (reader.sp-node-get else-expr)))
                        [(ResultAstExpr.Ok parsed)
                          (ResultAstMaybeExpr.SomeExpr parsed)]
                        [(ResultAstExpr.Err message)
                          (ResultAstMaybeExpr.Err message)])]
                    [(ResultCompilerCfg.Err message)
                      (ResultAstMaybeExpr.Err message)])]
                [_
                  (ResultAstMaybeExpr.Err
                    "parse: cfg expression expects predicate and expression")])]
            [_
              (ResultAstMaybeExpr.Err
                "parse: cfg expression expects predicate and expression")])]
        [_
          (ResultAstMaybeExpr.Err
            "parse: cfg expression expects predicate and expression")])]
    [_
      (ResultAstMaybeExpr.Err
        "parse: cfg expression expects predicate and expression")]))

(define (parse-ast-cfg-expr
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-cfg-expr-maybe dispatch pools rest)
    [(ResultAstMaybeExpr.SomeExpr expr) (ResultAstExpr.Ok expr)]
    [(ResultAstMaybeExpr.NoExpr)
      (ResultAstExpr.Ok
        (ast-node-pool-context-expr-push
          pools
          (AstExpr.Literal AstLiteral.Unit)))]
    [(ResultAstMaybeExpr.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-expr-list-item-maybe
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [head : reader.SpannedSexpr]) : ResultAstMaybeExpr
  (match head
    [(reader.SpannedSexpr.Cons op-node cfg-rest _)
      (match (reader.sp-node-get op-node)
        [(reader.SpannedSexpr.Sym op _)
          (if (= op (cbi.compiler-builtin-ctfe-ref 243))
            (parse-ast-cfg-expr-maybe
              dispatch
              pools
              (reader.sp-node-get cfg-rest))
            (match (parse-ast-expr-with-pools dispatch pools head)
              [(ResultAstExpr.Ok parsed) (ResultAstMaybeExpr.SomeExpr parsed)]
              [(ResultAstExpr.Err message) (ResultAstMaybeExpr.Err message)]))]
        [_
          (match (parse-ast-expr-with-pools dispatch pools head)
            [(ResultAstExpr.Ok parsed) (ResultAstMaybeExpr.SomeExpr parsed)]
            [(ResultAstExpr.Err message) (ResultAstMaybeExpr.Err message)])])]
    [_
      (match (parse-ast-expr-with-pools dispatch pools head)
        [(ResultAstExpr.Ok parsed) (ResultAstMaybeExpr.SomeExpr parsed)]
        [(ResultAstExpr.Err message) (ResultAstMaybeExpr.Err message)])]))

(define (parse-ast-expr-list-into
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.SpannedSexpr]
  [out : (&mut out AstExprList)]) : ResultAstExprListBuild
  (match s
    [(reader.SpannedSexpr.Nil _) (ResultAstExprListBuild.Ok)]
    [(reader.SpannedSexpr.Cons head tail _)
      (match (parse-ast-expr-list-item-maybe
        dispatch
        pools
        (reader.sp-node-get head))
        [(ResultAstMaybeExpr.SomeExpr parsed-head)
          (begin
            (ast-expr-list-push out parsed-head)
            (parse-ast-expr-list-into
              dispatch
              pools
              (reader.sp-node-get tail)
              out))]
        [(ResultAstMaybeExpr.NoExpr)
          (parse-ast-expr-list-into
            dispatch
            pools
            (reader.sp-node-get tail)
            out)]
        [(ResultAstMaybeExpr.Err message) (ResultAstExprListBuild.Err message)])]
    [_ (ResultAstExprListBuild.Err "parse: malformed expression list")]))

(define (parse-ast-expr-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.SpannedSexpr]) : ResultAstExprList
  (let
    [out : AstExprList (ast-expr-list-new)]
    (match (parse-ast-expr-list-into dispatch pools s (&mut out))
      [(ResultAstExprListBuild.Ok) (ResultAstExprList.Ok out)]
      [(ResultAstExprListBuild.Err message) (ResultAstExprList.Err message)])))

(define (parse-ast-body-tail
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.SpannedSexpr]
  [missing-message : String]) : ResultAstExpr
  (match s
    [(reader.SpannedSexpr.Nil _) (ResultAstExpr.Err missing-message)]
    [_
      (match (parse-ast-expr-list dispatch pools s)
        [(ResultAstExprList.Ok exprs)
          (let
            [n : i64 (struct-get (& exprs) len)]
            (cond
              [(= n 0) (ResultAstExpr.Err missing-message)]
              [(= n 1) (ResultAstExpr.Ok (ast-expr-list-get (& exprs) 0 0))]
              [else
                (ResultAstExpr.Ok
                  (ast-node-pool-context-expr-push pools (AstExpr.Begin exprs)))]))]
        [(ResultAstExprList.Err message) (ResultAstExpr.Err message)])]))

(define (parse-ast-call-bracket-clause
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.SpannedSexpr]
  [items : reader.SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-expr-list dispatch pools items)
    [(ResultAstExprList.Ok parsed-items)
      (ResultAstExpr.Ok
        (ast-expr-wrap-span
          pools
          (ast-expr-bracket-clause-with-pools pools parsed-items)
          s))]
    [(ResultAstExprList.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-call-arg-maybe
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [head : reader.SpannedSexpr]) : ResultAstMaybeExpr
  (match head
    [(reader.SpannedSexpr.BracketList items _)
      (match (parse-ast-call-bracket-clause
        dispatch
        pools
        head
        (reader.sp-node-get items))
        [(ResultAstExpr.Ok parsed) (ResultAstMaybeExpr.SomeExpr parsed)]
        [(ResultAstExpr.Err message) (ResultAstMaybeExpr.Err message)])]
    [(reader.SpannedSexpr.Cons op-node cfg-rest _)
      (match (reader.sp-node-get op-node)
        [(reader.SpannedSexpr.Sym op _)
          (if (= op (cbi.compiler-builtin-ctfe-ref 243))
            (parse-ast-cfg-expr-maybe
              dispatch
              pools
              (reader.sp-node-get cfg-rest))
            (match (parse-ast-expr-with-pools dispatch pools head)
              [(ResultAstExpr.Ok parsed) (ResultAstMaybeExpr.SomeExpr parsed)]
              [(ResultAstExpr.Err message) (ResultAstMaybeExpr.Err message)]))]
        [_
          (match (parse-ast-expr-with-pools dispatch pools head)
            [(ResultAstExpr.Ok parsed) (ResultAstMaybeExpr.SomeExpr parsed)]
            [(ResultAstExpr.Err message) (ResultAstMaybeExpr.Err message)])])]
    [_
      (match (parse-ast-expr-with-pools dispatch pools head)
        [(ResultAstExpr.Ok parsed) (ResultAstMaybeExpr.SomeExpr parsed)]
        [(ResultAstExpr.Err message) (ResultAstMaybeExpr.Err message)])]))

(define (parse-ast-call-arg-list-into
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.SpannedSexpr]
  [out : (&mut out AstExprList)]) : ResultAstExprListBuild
  (match s
    [(reader.SpannedSexpr.Nil _) (ResultAstExprListBuild.Ok)]
    [(reader.SpannedSexpr.Cons head tail _)
      (match (parse-ast-call-arg-maybe dispatch pools (reader.sp-node-get head))
        [(ResultAstMaybeExpr.SomeExpr parsed-head)
          (begin
            (ast-expr-list-push out parsed-head)
            (parse-ast-call-arg-list-into
              dispatch
              pools
              (reader.sp-node-get tail)
              out))]
        [(ResultAstMaybeExpr.NoExpr)
          (parse-ast-call-arg-list-into
            dispatch
            pools
            (reader.sp-node-get tail)
            out)]
        [(ResultAstMaybeExpr.Err message) (ResultAstExprListBuild.Err message)])]
    [_ (ResultAstExprListBuild.Err "parse: malformed call argument list")]))

(define (parse-ast-call-arg-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.SpannedSexpr]) : ResultAstExprList
  (let
    [out : AstExprList (ast-expr-list-new)]
    (match (parse-ast-call-arg-list-into dispatch pools s (&mut out))
      [(ResultAstExprListBuild.Ok) (ResultAstExprList.Ok out)]
      [(ResultAstExprListBuild.Err message) (ResultAstExprList.Err message)])))

(define (parse-ast-binary
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [op : AstBinOp]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons left right-tail _)
      (match (reader.sp-node-get right-tail)
        [(reader.SpannedSexpr.Cons right end _)
          (match (reader.sp-node-get end)
            [(reader.SpannedSexpr.Nil _)
              (match (parse-ast-expr-with-pools
                dispatch
                pools
                (reader.sp-node-get left))
                [(ResultAstExpr.Ok parsed-left)
                  (match (parse-ast-expr-with-pools
                    dispatch
                    pools
                    (reader.sp-node-get right))
                    [(ResultAstExpr.Ok parsed-right)
                      (ResultAstExpr.Ok
                        (ast-expr-binary-with-pools
                          pools
                          op
                          parsed-left
                          parsed-right))]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
            [_ (ResultAstExpr.Err "parse: malformed binary expression")])]
        [_ (ResultAstExpr.Err "parse: malformed binary expression")])]
    [_ (ResultAstExpr.Err "parse: malformed binary expression")]))

(define (parse-ast-binary-left-fold-tail
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [op : AstBinOp]
  [acc : i64]
  [tail : reader.SpannedSexpr]) : ResultAstExpr
  (match tail
    [(reader.SpannedSexpr.Nil _) (ResultAstExpr.Ok acc)]
    [(reader.SpannedSexpr.Cons expr rest _)
      (match (parse-ast-expr-with-pools
        dispatch
        pools
        (reader.sp-node-get expr))
        [(ResultAstExpr.Ok parsed-expr)
          (parse-ast-binary-left-fold-tail
            dispatch
            pools
            op
            (ast-expr-binary-with-pools pools op acc parsed-expr)
            (reader.sp-node-get rest))]
        [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
    [_ (ResultAstExpr.Err "parse: malformed binary expression")]))

(define (parse-ast-binary-left-fold
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [op : AstBinOp]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons left right-tail _)
      (match (reader.sp-node-get right-tail)
        [(reader.SpannedSexpr.Cons right tail _)
          (match (parse-ast-expr-with-pools
            dispatch
            pools
            (reader.sp-node-get left))
            [(ResultAstExpr.Ok parsed-left)
              (match (parse-ast-expr-with-pools
                dispatch
                pools
                (reader.sp-node-get right))
                [(ResultAstExpr.Ok parsed-right)
                  (parse-ast-binary-left-fold-tail
                    dispatch
                    pools
                    op
                    (ast-expr-binary-with-pools
                      pools
                      op
                      parsed-left
                      parsed-right)
                    (reader.sp-node-get tail))]
                [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [_ (ResultAstExpr.Err "parse: malformed binary expression")])]
    [_ (ResultAstExpr.Err "parse: malformed binary expression")]))

(define (parse-ast-unary
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [op : AstUnOp]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons expr end _)
      (match (reader.sp-node-get end)
        [(reader.SpannedSexpr.Nil _)
          (match (parse-ast-expr-with-pools
            dispatch
            pools
            (reader.sp-node-get expr))
            [(ResultAstExpr.Ok parsed-expr)
              (ResultAstExpr.Ok
                (ast-expr-unary-with-pools pools op parsed-expr))]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [_ (ResultAstExpr.Err "parse: malformed unary expression")])]
    [_ (ResultAstExpr.Err "parse: malformed unary expression")]))

(define (parse-ast-if-missing-else-message) : String
  "parse: if is missing its else branch")

(define (parse-ast-if-arity-message) : String
  "parse: if expects condition, then branch, and else branch")

(define (parse-ast-if-example-note) : String
  "example: (if condition then-expr else-expr)")

(define (parse-ast-if-one-sided-note) : String
  "use (when condition body...) or (unless condition body...) for one-sided conditionals")

(define (parse-ast-if-message? [message : String]) : bool
  (or
    (string.eq message (parse-ast-if-missing-else-message))
    (string.eq message (parse-ast-if-arity-message))))

(define (parse-ast-if-diagnostic-notes [diag : CompilerDiagnostic]) : CompilerDiagnostic
  (compiler-diagnostic-with-note
    (compiler-diagnostic-with-note diag (parse-ast-if-one-sided-note))
    (parse-ast-if-example-note)))

(define (parse-ast-if
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons cond then-tail _)
      (match (reader.sp-node-get then-tail)
        [(reader.SpannedSexpr.Cons then-branch else-tail _)
          (match (reader.sp-node-get else-tail)
            [(reader.SpannedSexpr.Cons else-branch end _)
              (match (reader.sp-node-get end)
                [(reader.SpannedSexpr.Nil _)
                  (match (parse-ast-expr-with-pools
                    dispatch
                    pools
                    (reader.sp-node-get cond))
                    [(ResultAstExpr.Ok parsed-cond)
                      (match (parse-ast-expr-with-pools
                        dispatch
                        pools
                        (reader.sp-node-get then-branch))
                        [(ResultAstExpr.Ok parsed-then)
                          (match (parse-ast-expr-with-pools
                            dispatch
                            pools
                            (reader.sp-node-get else-branch))
                            [(ResultAstExpr.Ok parsed-else)
                              (ResultAstExpr.Ok
                                (ast-expr-if-with-pools
                                  pools
                                  parsed-cond
                                  parsed-then
                                  parsed-else))]
                            [(ResultAstExpr.Err message)
                              (ResultAstExpr.Err message)])]
                        [(ResultAstExpr.Err message)
                          (ResultAstExpr.Err message)])]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [_ (ResultAstExpr.Err (parse-ast-if-arity-message))])]
            [_ (ResultAstExpr.Err (parse-ast-if-missing-else-message))])]
        [_ (ResultAstExpr.Err (parse-ast-if-arity-message))])]
    [_ (ResultAstExpr.Err (parse-ast-if-arity-message))]))

(define (parse-ast-while
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons cond body-tail _)
      (match (parse-ast-expr-with-pools
        dispatch
        pools
        (reader.sp-node-get cond))
        [(ResultAstExpr.Ok parsed-cond)
          (match (parse-ast-body-tail
            dispatch
            pools
            (reader.sp-node-get body-tail)
            "parse: malformed while")
            [(ResultAstExpr.Ok parsed-body)
              (ResultAstExpr.Ok
                (ast-expr-while-with-pools pools parsed-cond parsed-body))]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
    [_ (ResultAstExpr.Err "parse: malformed while")]))

(define (parse-ast-set
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons target-node value-tail _)
      (match (reader.sp-node-get value-tail)
        [(reader.SpannedSexpr.Cons value end _)
          (match (reader.sp-node-get end)
            [(reader.SpannedSexpr.Nil _)
              (match (parse-ast-expr-with-pools
                dispatch
                pools
                (reader.sp-node-get value))
                [(ResultAstExpr.Ok parsed-value)
                  (match (reader.sp-node-get target-node)
                    [(reader.SpannedSexpr.Sym name _)
                      (ResultAstExpr.Ok
                        (ast-expr-set-id-with-pools pools name parsed-value))]
                    [_
                      (match (parse-ast-expr-with-pools
                        dispatch
                        pools
                        (reader.sp-node-get target-node))
                        [(ResultAstExpr.Ok parsed-target)
                          (match (ast-expr-unspan-with-pools
                            pools
                            (ast-node-pool-context-expr-get pools parsed-target))
                            [(AstExpr.StructGet receiver-box field)
                              (ResultAstExpr.Ok
                                (ast-expr-struct-set-id-with-pools
                                  pools
                                  receiver-box
                                  field
                                  parsed-value))]
                            [(AstExpr.BoxGet receiver-box)
                              (ResultAstExpr.Ok
                                (ast-expr-box-set-with-pools
                                  pools
                                  receiver-box
                                  parsed-value))]
                            [(AstExpr.Unquote _)
                              (ResultAstExpr.Ok
                                (ast-expr-struct-set-id-with-pools
                                  pools
                                  parsed-target
                                  (ast-expr-unquote-set-target-field-id)
                                  parsed-value))]
                            [_
                              (ResultAstExpr.Err
                                "parse: set! target must be a name, struct field place, or box place")])]
                        [(ResultAstExpr.Err message)
                          (ResultAstExpr.Err message)])])]
                [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
            [_ (ResultAstExpr.Err "parse: malformed set!")])]
        [_ (ResultAstExpr.Err "parse: malformed set!")])]
    [_ (ResultAstExpr.Err "parse: malformed set!")]))

(define (parse-ast-ann-like
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [is-cast : bool]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons expr colon-tail _)
      (match (reader.sp-node-get colon-tail)
        [(reader.SpannedSexpr.Cons colon ty-tail _)
          (match (reader.sp-node-get ty-tail)
            [(reader.SpannedSexpr.Cons ty end _)
              (match (reader.sp-node-get end)
                [(reader.SpannedSexpr.Nil _)
                  (if (sexpr-colon?
                    (reader.spanned-sexpr-form (reader.sp-node-get colon)))
                    (match (parse-ast-expr-with-pools
                      dispatch
                      pools
                      (reader.sp-node-get expr))
                      [(ResultAstExpr.Ok parsed-expr)
                        (match (parse-ast-type-spanned
                          dispatch
                          pools
                          (reader.sp-node-get ty))
                          [(ResultAstType.Ok parsed-ty)
                            (if is-cast
                              (ResultAstExpr.Ok
                                (ast-expr-cast-with-pools
                                  pools
                                  parsed-expr
                                  parsed-ty))
                              (ResultAstExpr.Ok
                                (ast-expr-ann-with-pools
                                  pools
                                  parsed-expr
                                  parsed-ty)))]
                          [(ResultAstType.Err message)
                            (ResultAstExpr.Err message)])]
                      [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])
                    (ResultAstExpr.Err "parse: expected ':' in annotation"))]
                [_ (ResultAstExpr.Err "parse: malformed annotation")])]
            [_ (ResultAstExpr.Err "parse: malformed annotation")])]
        [_ (ResultAstExpr.Err "parse: malformed annotation")])]
    [_ (ResultAstExpr.Err "parse: malformed annotation")]))

(define (parse-ast-let-binding
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.SpannedSexpr]) : ResultAstLetBinding
  (let
    [result : ResultAstLetBinding
      (match s
        [(reader.SpannedSexpr.BracketList items _)
          (parse-ast-let-binding dispatch pools (reader.sp-node-get items))]
        [(reader.SpannedSexpr.Cons name-node tail _)
          (match (reader.sp-node-get name-node)
            [(reader.SpannedSexpr.Sym name _)
              (match (reader.sp-node-get tail)
                [(reader.SpannedSexpr.Cons second rest _)
                  (match (reader.sp-node-get rest)
                    [(reader.SpannedSexpr.Nil _)
                      (match (parse-ast-expr-with-pools
                        dispatch
                        pools
                        (reader.sp-node-get second))
                        [(ResultAstExpr.Ok parsed-value)
                          (ResultAstLetBinding.Ok
                            (ast-let-binding-id
                              name
                              AstMaybeType.No
                              parsed-value))]
                        [(ResultAstExpr.Err message)
                          (ResultAstLetBinding.Err message)])]
                    [(reader.SpannedSexpr.Cons ty value-tail _)
                      (match (reader.sp-node-get value-tail)
                        [(reader.SpannedSexpr.Cons value end _)
                          (match (reader.sp-node-get end)
                            [(reader.SpannedSexpr.Nil _)
                              (if (sexpr-colon?
                                (reader.spanned-sexpr-form
                                  (reader.sp-node-get second)))
                                (match (parse-ast-type-spanned
                                  dispatch
                                  pools
                                  (reader.sp-node-get ty))
                                  [(ResultAstType.Ok parsed-ty)
                                    (match (parse-ast-expr-with-pools
                                      dispatch
                                      pools
                                      (reader.sp-node-get value))
                                      [(ResultAstExpr.Ok parsed-value)
                                        (ResultAstLetBinding.Ok
                                          (ast-let-binding-id
                                            name
                                            (AstMaybeType.Some parsed-ty)
                                            parsed-value))]
                                      [(ResultAstExpr.Err message)
                                        (ResultAstLetBinding.Err message)])]
                                  [(ResultAstType.Err message)
                                    (ResultAstLetBinding.Err message)])
                                (ResultAstLetBinding.Err
                                  "parse: expected ':' in let binding"))]
                            [_
                              (ResultAstLetBinding.Err
                                "parse: malformed let binding")])]
                        [_
                          (ResultAstLetBinding.Err
                            "parse: malformed let binding")])]
                    [_ (ResultAstLetBinding.Err "parse: malformed let binding")])]
                [_ (ResultAstLetBinding.Err "parse: malformed let binding")])]
            [_ (ResultAstLetBinding.Err "parse: malformed let binding")])]
        [_ (ResultAstLetBinding.Err "parse: malformed let binding")])]
    (parse-ast-error-span-note-let-binding dispatch s result)))

(define (parse-ast-let-flat-tail-into
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]
  [out : (&mut out AstLetBindingList)]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons head tail _)
      (match (reader.sp-node-get head)
        [(reader.SpannedSexpr.BracketList _ _)
          (match (parse-ast-let-binding
            dispatch
            pools
            (reader.sp-node-get head))
            [(ResultAstLetBinding.Ok parsed-head)
              (begin
                (ast-let-binding-list-push out parsed-head)
                (parse-ast-let-flat-tail-into
                  dispatch
                  pools
                  (reader.sp-node-get tail)
                  out))]
            [(ResultAstLetBinding.Err message) (ResultAstExpr.Err message)])]
        [_ (parse-ast-body-tail dispatch pools rest "parse: let missing body")])]
    [(reader.SpannedSexpr.Nil _) (ResultAstExpr.Err "parse: let missing body")]
    [_ (ResultAstExpr.Err "parse: malformed let")]))

(define (parse-ast-let-flat-tail
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstLetParts
  (let
    [out : AstLetBindingList (ast-let-binding-list-new)]
    (match (parse-ast-let-flat-tail-into dispatch pools rest (&mut out))
      [(ResultAstExpr.Ok parsed-body) (ResultAstLetParts.Ok out parsed-body)]
      [(ResultAstExpr.Err message) (ResultAstLetParts.Err message)])))

(define (parse-ast-let-flat
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons head _ _)
      (match (reader.sp-node-get head)
        [(reader.SpannedSexpr.BracketList items _)
          (match (reader.sp-node-get items)
            [(reader.SpannedSexpr.Nil _)
              (match rest
                [(reader.SpannedSexpr.Cons _ body-tail _)
                  (parse-ast-body-tail
                    dispatch
                    pools
                    (reader.sp-node-get body-tail)
                    "parse: let missing body")]
                [_ (ResultAstExpr.Err "parse: malformed let")])]
            [_
              (match (parse-ast-let-flat-tail dispatch pools rest)
                [(ResultAstLetParts.Ok parsed-bindings parsed-body)
                  (ResultAstExpr.Ok
                    (ast-expr-let-with-pools pools parsed-bindings parsed-body))]
                [(ResultAstLetParts.Err message) (ResultAstExpr.Err message)])])]
        [_ (ResultAstExpr.Err "parse: let requires at least one binding")])]
    [_ (ResultAstExpr.Err "parse: malformed let")]))

(define (parse-ast-let
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons bindings _ _)
      (match (reader.sp-node-get bindings)
        [(reader.SpannedSexpr.BracketList _ _)
          (parse-ast-let-flat dispatch pools rest)]
        [(reader.SpannedSexpr.Nil _)
          (begin
            (parse-ast-error-span-note!
              dispatch
              (reader.spanned-sexpr-span (reader.sp-node-get bindings)))
            (ResultAstExpr.Err
              "parse: (let () body...) was removed; write (let [] body...)"))]
        [(reader.SpannedSexpr.Cons _ _ _)
          (begin
            (parse-ast-error-span-note!
              dispatch
              (reader.spanned-sexpr-span (reader.sp-node-get bindings)))
            (ResultAstExpr.Err
              "parse: parenthesized let bindings were removed; write leading [name [: type] init] bindings without parentheses"))]
        [_ (ResultAstExpr.Err "parse: let requires at least one binding")])]
    [_ (ResultAstExpr.Err "parse: malformed let")]))

(define (parse-ast-lambda
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons params tail _)
      (match (parse-ast-param-list
        dispatch
        pools
        (reader.spanned-sexpr-form (reader.sp-node-get params)))
        [(ResultAstParamList.Ok parsed-params)
          (if (ast-param-list-has-comptime? parsed-params)
            (ResultAstExpr.Err
              "comptime parameters are only supported on top-level function definitions")
            (match (reader.sp-node-get tail)
              [(reader.SpannedSexpr.Cons first rest-tail _)
                (if (sexpr-colon?
                  (reader.spanned-sexpr-form (reader.sp-node-get first)))
                  (match (reader.sp-node-get rest-tail)
                    [(reader.SpannedSexpr.Cons ret body-tail _)
                      (match (parse-ast-type-spanned
                        dispatch
                        pools
                        (reader.sp-node-get ret))
                        [(ResultAstType.Ok parsed-ret)
                          (match (parse-ast-body-tail
                            dispatch
                            pools
                            (reader.sp-node-get body-tail)
                            "parse: malformed lambda")
                            [(ResultAstExpr.Ok parsed-body)
                              (ResultAstExpr.Ok
                                (ast-expr-lambda-with-pools
                                  pools
                                  parsed-params
                                  (AstMaybeType.Some parsed-ret)
                                  parsed-body))]
                            [(ResultAstExpr.Err message)
                              (ResultAstExpr.Err message)])]
                        [(ResultAstType.Err message)
                          (ResultAstExpr.Err message)])]
                    [_ (ResultAstExpr.Err "parse: malformed lambda")])
                  (match (parse-ast-body-tail
                    dispatch
                    pools
                    (reader.sp-node-get tail)
                    "parse: malformed lambda")
                    [(ResultAstExpr.Ok parsed-body)
                      (ResultAstExpr.Ok
                        (ast-expr-lambda-with-pools
                          pools
                          parsed-params
                          AstMaybeType.No
                          parsed-body))]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)]))]
              [_ (ResultAstExpr.Err "parse: malformed lambda")]))]
        [(ResultAstParamList.Err message) (ResultAstExpr.Err message)])]
    [_ (ResultAstExpr.Err "parse: malformed lambda")]))

(define (parse-ast-tuple-ref
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons expr index-tail _)
      (match (reader.sp-node-get index-tail)
        [(reader.SpannedSexpr.Cons index-node end _)
          (match (reader.sp-node-get end)
            [(reader.SpannedSexpr.Nil _)
              (match (reader.sp-node-get index-node)
                [(reader.SpannedSexpr.Int index _ _)
                  (match (parse-ast-expr-with-pools
                    dispatch
                    pools
                    (reader.sp-node-get expr))
                    [(ResultAstExpr.Ok parsed-expr)
                      (ResultAstExpr.Ok
                        (ast-expr-tuple-ref-with-pools pools parsed-expr index))]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [_ (ResultAstExpr.Err "parse: tuple-ref index must be integer")])]
            [_ (ResultAstExpr.Err "parse: malformed tuple-ref")])]
        [_ (ResultAstExpr.Err "parse: malformed tuple-ref")])]
    [_ (ResultAstExpr.Err "parse: malformed tuple-ref")]))

(define (parse-ast-dyn-array-literal
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-expr-list dispatch pools rest)
    [(ResultAstExprList.Ok exprs)
      (ResultAstExpr.Ok (ast-expr-dyn-array-with-pools pools exprs))]
    [(ResultAstExprList.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-make-array
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons elem-ty len-tail _)
      (match (reader.sp-node-get len-tail)
        [(reader.SpannedSexpr.Cons len end _)
          (match (reader.sp-node-get end)
            [(reader.SpannedSexpr.Nil _)
              (match (parse-ast-type-spanned
                dispatch
                pools
                (reader.sp-node-get elem-ty))
                [(ResultAstType.Ok parsed-ty)
                  (match (parse-ast-expr-with-pools
                    dispatch
                    pools
                    (reader.sp-node-get len))
                    [(ResultAstExpr.Ok parsed-len)
                      (ResultAstExpr.Ok
                        (ast-expr-make-array-with-pools
                          pools
                          parsed-ty
                          parsed-len))]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [(ResultAstType.Err _)
                  (parse-ast-dyn-array-literal dispatch pools rest)])]
            [_ (parse-ast-dyn-array-literal dispatch pools rest)])]
        [_ (parse-ast-dyn-array-literal dispatch pools rest)])]
    [_ (parse-ast-dyn-array-literal dispatch pools rest)]))

(define (parse-ast-array-ref-like
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [is-string : bool]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons expr index-tail _)
      (match (reader.sp-node-get index-tail)
        [(reader.SpannedSexpr.Cons index end _)
          (match (reader.sp-node-get end)
            [(reader.SpannedSexpr.Nil _)
              (match (parse-ast-expr-with-pools
                dispatch
                pools
                (reader.sp-node-get expr))
                [(ResultAstExpr.Ok parsed-expr)
                  (match (parse-ast-expr-with-pools
                    dispatch
                    pools
                    (reader.sp-node-get index))
                    [(ResultAstExpr.Ok parsed-index)
                      (if is-string
                        (ResultAstExpr.Ok
                          (ast-expr-string-ref-with-pools
                            pools
                            parsed-expr
                            parsed-index))
                        (ResultAstExpr.Ok
                          (ast-expr-array-ref-with-pools
                            pools
                            parsed-expr
                            parsed-index)))]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
            [_ (ResultAstExpr.Err "parse: malformed ref expression")])]
        [_ (ResultAstExpr.Err "parse: malformed ref expression")])]
    [_ (ResultAstExpr.Err "parse: malformed ref expression")]))

(define (parse-ast-array-set
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons expr index-tail _)
      (match (reader.sp-node-get index-tail)
        [(reader.SpannedSexpr.Cons index value-tail _)
          (match (reader.sp-node-get value-tail)
            [(reader.SpannedSexpr.Cons value end _)
              (match (reader.sp-node-get end)
                [(reader.SpannedSexpr.Nil _)
                  (match (parse-ast-expr-with-pools
                    dispatch
                    pools
                    (reader.sp-node-get expr))
                    [(ResultAstExpr.Ok parsed-expr)
                      (match (parse-ast-expr-with-pools
                        dispatch
                        pools
                        (reader.sp-node-get index))
                        [(ResultAstExpr.Ok parsed-index)
                          (match (parse-ast-expr-with-pools
                            dispatch
                            pools
                            (reader.sp-node-get value))
                            [(ResultAstExpr.Ok parsed-value)
                              (ResultAstExpr.Ok
                                (ast-expr-array-set-with-pools
                                  pools
                                  parsed-expr
                                  parsed-index
                                  parsed-value))]
                            [(ResultAstExpr.Err message)
                              (ResultAstExpr.Err message)])]
                        [(ResultAstExpr.Err message)
                          (ResultAstExpr.Err message)])]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [_ (ResultAstExpr.Err "parse: malformed array-set!")])]
            [_ (ResultAstExpr.Err "parse: malformed array-set!")])]
        [_ (ResultAstExpr.Err "parse: malformed array-set!")])]
    [_ (ResultAstExpr.Err "parse: malformed array-set!")]))

(define (parse-ast-array-push
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons expr value-tail _)
      (match (reader.sp-node-get value-tail)
        [(reader.SpannedSexpr.Cons value end _)
          (match (reader.sp-node-get end)
            [(reader.SpannedSexpr.Nil _)
              (match (parse-ast-expr-with-pools
                dispatch
                pools
                (reader.sp-node-get expr))
                [(ResultAstExpr.Ok parsed-expr)
                  (match (parse-ast-expr-with-pools
                    dispatch
                    pools
                    (reader.sp-node-get value))
                    [(ResultAstExpr.Ok parsed-value)
                      (ResultAstExpr.Ok
                        (ast-expr-array-push-with-pools
                          pools
                          parsed-expr
                          parsed-value))]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
            [_ (ResultAstExpr.Err "parse: malformed array-push!")])]
        [_ (ResultAstExpr.Err "parse: malformed array-push!")])]
    [_ (ResultAstExpr.Err "parse: malformed array-push!")]))

(define (parse-ast-array-take
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons array live-tail _)
      (match (reader.sp-node-get live-tail)
        [(reader.SpannedSexpr.Cons live index-tail _)
          (match (reader.sp-node-get index-tail)
            [(reader.SpannedSexpr.Cons index end _)
              (match (reader.sp-node-get end)
                [(reader.SpannedSexpr.Nil _)
                  (match (parse-ast-expr-with-pools
                    dispatch
                    pools
                    (reader.sp-node-get array))
                    [(ResultAstExpr.Ok parsed-array)
                      (match (parse-ast-expr-with-pools
                        dispatch
                        pools
                        (reader.sp-node-get live))
                        [(ResultAstExpr.Ok parsed-live)
                          (match (parse-ast-expr-with-pools
                            dispatch
                            pools
                            (reader.sp-node-get index))
                            [(ResultAstExpr.Ok parsed-index)
                              (ResultAstExpr.Ok
                                (ast-expr-array-take-with-pools
                                  pools
                                  parsed-array
                                  parsed-live
                                  parsed-index))]
                            [(ResultAstExpr.Err message)
                              (ResultAstExpr.Err message)])]
                        [(ResultAstExpr.Err message)
                          (ResultAstExpr.Err message)])]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [_ (ResultAstExpr.Err "parse: malformed array-take!")])]
            [_ (ResultAstExpr.Err "parse: malformed array-take!")])]
        [_ (ResultAstExpr.Err "parse: malformed array-take!")])]
    [_ (ResultAstExpr.Err "parse: malformed array-take!")]))

(define (parse-ast-borrow
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [mutable : bool]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons first tail _)
      (match (reader.sp-node-get tail)
        [(reader.SpannedSexpr.Nil _)
          (match (parse-ast-expr-with-pools
            dispatch
            pools
            (reader.sp-node-get first))
            [(ResultAstExpr.Ok parsed-place)
              (ResultAstExpr.Ok
                (ast-expr-borrow-with-pools
                  pools
                  mutable
                  AstBorrowLifetime.Inferred
                  parsed-place))]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [(reader.SpannedSexpr.Cons place end _)
          (match (reader.sp-node-get end)
            [(reader.SpannedSexpr.Nil _)
              (match (reader.sp-node-get first)
                [(reader.SpannedSexpr.Sym name _)
                  (match (parse-ast-expr-with-pools
                    dispatch
                    pools
                    (reader.sp-node-get place))
                    [(ResultAstExpr.Ok parsed-place)
                      (ResultAstExpr.Ok
                        (ast-expr-borrow-with-pools
                          pools
                          mutable
                          (AstBorrowLifetime.Named name)
                          parsed-place))]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [_
                  (ResultAstExpr.Err
                    "parse: borrow lifetime must be an identifier")])]
            [_
              (ResultAstExpr.Err
                "parse: borrow expects a place or lifetime and place")])]
        [_
          (ResultAstExpr.Err
            "parse: borrow expects a place or lifetime and place")])]
    [_
      (ResultAstExpr.Err "parse: borrow expects a place or lifetime and place")]))

(define (parse-ast-struct-get
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons expr field-tail _)
      (match (reader.sp-node-get field-tail)
        [(reader.SpannedSexpr.Cons field-node end _)
          (match (reader.sp-node-get end)
            [(reader.SpannedSexpr.Nil _)
              (match (reader.sp-node-get field-node)
                [(reader.SpannedSexpr.Sym field _)
                  (match (parse-ast-expr-with-pools
                    dispatch
                    pools
                    (reader.sp-node-get expr))
                    [(ResultAstExpr.Ok parsed-expr)
                      (ResultAstExpr.Ok
                        (ast-expr-struct-get-id-with-pools
                          pools
                          parsed-expr
                          field))]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [_ (ResultAstExpr.Err "parse: malformed struct-get")])]
            [_ (ResultAstExpr.Err "parse: malformed struct-get")])]
        [_ (ResultAstExpr.Err "parse: malformed struct-get")])]
    [_ (ResultAstExpr.Err "parse: malformed struct-get")]))

;; `(comptime expr)` wraps exactly one inner expression for compile-time
;; evaluation; evaluation itself happens in CTFE, not the parser.
(define (parse-ast-comptime
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons expr end _)
      (match (reader.sp-node-get end)
        [(reader.SpannedSexpr.Nil _)
          (match (parse-ast-expr-with-pools
            dispatch
            pools
            (reader.sp-node-get expr))
            [(ResultAstExpr.Ok parsed-expr)
              (ResultAstExpr.Ok
                (ast-expr-comptime-with-pools pools parsed-expr))]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [_ (ResultAstExpr.Err "parse: comptime expects exactly one expression")])]
    [_ (ResultAstExpr.Err "parse: comptime expects exactly one expression")]))

(define (parse-ast-type-literal
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons ty end _)
      (match (reader.sp-node-get end)
        [(reader.SpannedSexpr.Nil _)
          (match (parse-ast-type-spanned dispatch pools (reader.sp-node-get ty))
            [(ResultAstType.Ok parsed-ty)
              (begin
                (compiler-parse-type-literal-tracking-mark! dispatch)
                (ResultAstExpr.Ok
                  (ast-node-pool-context-expr-push
                    pools
                    (AstExpr.TypeLiteral parsed-ty))))]
            [(ResultAstType.Err message) (ResultAstExpr.Err message)])]
        [_ (ResultAstExpr.Err "parse: type expects exactly one type")])]
    [_ (ResultAstExpr.Err "parse: type expects exactly one type")]))

(define (parse-ast-reduce-op [name-id : i64]) : ResultAstReduceOp
  (cond
    [(= name-id (cbi.compiler-builtin-ctfe-ref 262))
      (ResultAstReduceOp.Ok (AstReduceOp.Sum))]
    [(= name-id (cbi.compiler-builtin-ctfe-ref 263))
      (ResultAstReduceOp.Ok (AstReduceOp.Min))]
    [(= name-id (cbi.compiler-builtin-ctfe-ref 264))
      (ResultAstReduceOp.Ok (AstReduceOp.Max))]
    [(= name-id (cbi.compiler-builtin-ctfe-ref 219))
      (ResultAstReduceOp.Ok (AstReduceOp.All))]
    [(= name-id (cbi.compiler-builtin-ctfe-ref 220))
      (ResultAstReduceOp.Ok (AstReduceOp.Any))]
    [else
      (ResultAstReduceOp.Err
        (string.append
          "parse: unsupported spmd-reduce operator `"
          (string.append
            (compiler-parse-name-text name-id)
            "`; expected one of sum, min, max, all, any")))]))

(define (parse-ast-scan-op [name-id : i64]) : ResultAstReduceOp
  (cond
    [(= name-id (cbi.compiler-builtin-ctfe-ref 262))
      (ResultAstReduceOp.Ok (AstReduceOp.Sum))]
    [(= name-id (cbi.compiler-builtin-ctfe-ref 263))
      (ResultAstReduceOp.Ok (AstReduceOp.Min))]
    [(= name-id (cbi.compiler-builtin-ctfe-ref 264))
      (ResultAstReduceOp.Ok (AstReduceOp.Max))]
    [(= name-id (cbi.compiler-builtin-ctfe-ref 219))
      (ResultAstReduceOp.Ok (AstReduceOp.All))]
    [(= name-id (cbi.compiler-builtin-ctfe-ref 220))
      (ResultAstReduceOp.Ok (AstReduceOp.Any))]
    [else
      (ResultAstReduceOp.Err
        (string.append
          "parse: unsupported spmd-scan operator `"
          (string.append
            (compiler-parse-name-text name-id)
            "`; expected one of sum, min, max, all, any")))]))

(define (parse-ast-spmd-reduce-binding
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [op : AstReduceOp]
  [binding : reader.SpannedSexpr]
  [init : reader.SpannedSexpr]
  [value : reader.SpannedSexpr]) : ResultAstExpr
  (match binding
    [(reader.SpannedSexpr.BracketList items _)
      (parse-ast-spmd-reduce-binding
        dispatch
        pools
        op
        (reader.sp-node-get items)
        init
        value)]
    [(reader.SpannedSexpr.Cons index-node colon-tail _)
      (match (reader.sp-node-get index-node)
        [(reader.SpannedSexpr.Sym index _)
          (match (reader.sp-node-get colon-tail)
            [(reader.SpannedSexpr.Cons colon index-ty-tail _)
              (match (reader.sp-node-get index-ty-tail)
                [(reader.SpannedSexpr.Cons index-ty start-tail _)
                  (match (reader.sp-node-get start-tail)
                    [(reader.SpannedSexpr.Cons start end-tail _)
                      (match (reader.sp-node-get end-tail)
                        [(reader.SpannedSexpr.Cons end finish _)
                          (match (reader.sp-node-get finish)
                            [(reader.SpannedSexpr.Nil _)
                              (if (sexpr-colon?
                                (reader.spanned-sexpr-form
                                  (reader.sp-node-get colon)))
                                (match (parse-ast-type-spanned
                                  dispatch
                                  pools
                                  (reader.sp-node-get index-ty))
                                  [(ResultAstType.Ok parsed-index-ty)
                                    (match (parse-ast-expr-with-pools
                                      dispatch
                                      pools
                                      (reader.sp-node-get start))
                                      [(ResultAstExpr.Ok parsed-start)
                                        (match (parse-ast-expr-with-pools
                                          dispatch
                                          pools
                                          (reader.sp-node-get end))
                                          [(ResultAstExpr.Ok parsed-end)
                                            (match (parse-ast-expr-with-pools
                                              dispatch
                                              pools
                                              init)
                                              [(ResultAstExpr.Ok parsed-init)
                                                (match (parse-ast-expr-with-pools
                                                  dispatch
                                                  pools
                                                  value)
                                                  [(ResultAstExpr.Ok
                                                      parsed-value)
                                                    (ResultAstExpr.Ok
                                                      (ast-expr-spmd-reduce-id-with-pools
                                                        pools
                                                        op
                                                        index
                                                        parsed-index-ty
                                                        parsed-start
                                                        parsed-end
                                                        parsed-init
                                                        parsed-value))]
                                                  [(ResultAstExpr.Err message)
                                                    (ResultAstExpr.Err message)])]
                                              [(ResultAstExpr.Err message)
                                                (ResultAstExpr.Err message)])]
                                          [(ResultAstExpr.Err message)
                                            (ResultAstExpr.Err message)])]
                                      [(ResultAstExpr.Err message)
                                        (ResultAstExpr.Err message)])]
                                  [(ResultAstType.Err message)
                                    (ResultAstExpr.Err message)])
                                (ResultAstExpr.Err
                                  "parse: expected ':' in spmd-reduce"))]
                            [_
                              (ResultAstExpr.Err "parse: malformed spmd-reduce")])]
                        [_ (ResultAstExpr.Err "parse: malformed spmd-reduce")])]
                    [_ (ResultAstExpr.Err "parse: malformed spmd-reduce")])]
                [_ (ResultAstExpr.Err "parse: malformed spmd-reduce")])]
            [_ (ResultAstExpr.Err "parse: malformed spmd-reduce")])]
        [_ (ResultAstExpr.Err "parse: malformed spmd-reduce")])]
    [_ (ResultAstExpr.Err "parse: malformed spmd-reduce")]))

(define (parse-ast-spmd-reduce
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons op-node binding-tail _)
      (match (reader.sp-node-get op-node)
        [(reader.SpannedSexpr.Sym op-name _)
          (match (reader.sp-node-get binding-tail)
            [(reader.SpannedSexpr.Cons binding-list init-tail _)
              (match (reader.sp-node-get binding-list)
                [(reader.SpannedSexpr.Cons binding binding-list-end _)
                  (match (reader.sp-node-get binding-list-end)
                    [(reader.SpannedSexpr.Nil _)
                      (match (reader.sp-node-get init-tail)
                        [(reader.SpannedSexpr.Cons init value-tail _)
                          (match (reader.sp-node-get value-tail)
                            [(reader.SpannedSexpr.Cons value end _)
                              (match (reader.sp-node-get end)
                                [(reader.SpannedSexpr.Nil _)
                                  (match (parse-ast-reduce-op op-name)
                                    [(ResultAstReduceOp.Ok op)
                                      (parse-ast-spmd-reduce-binding
                                        dispatch
                                        pools
                                        op
                                        (reader.sp-node-get binding)
                                        (reader.sp-node-get init)
                                        (reader.sp-node-get value))]
                                    [(ResultAstReduceOp.Err message)
                                      (ResultAstExpr.Err message)])]
                                [_
                                  (ResultAstExpr.Err
                                    "parse: malformed spmd-reduce")])]
                            [_
                              (ResultAstExpr.Err "parse: malformed spmd-reduce")])]
                        [_ (ResultAstExpr.Err "parse: malformed spmd-reduce")])]
                    [_ (ResultAstExpr.Err "parse: malformed spmd-reduce")])]
                [_ (ResultAstExpr.Err "parse: malformed spmd-reduce")])]
            [_ (ResultAstExpr.Err "parse: malformed spmd-reduce")])]
        [_ (ResultAstExpr.Err "parse: malformed spmd-reduce")])]
    [(reader.SpannedSexpr.Cons _ _ _)
      (ResultAstExpr.Err "parse: malformed spmd-reduce")]
    [_ (ResultAstExpr.Err "parse: malformed spmd-reduce")]))

(define (parse-ast-spmd-scan
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons op-node binding-tail _)
      (match (reader.sp-node-get op-node)
        [(reader.SpannedSexpr.Sym op-name _)
          (match (reader.sp-node-get binding-tail)
            [(reader.SpannedSexpr.Cons binding-list value-tail _)
              (match (reader.sp-node-get binding-list)
                [(reader.SpannedSexpr.Cons range-binding prefix-tail _)
                  (match (reader.sp-node-get prefix-tail)
                    [(reader.SpannedSexpr.Cons prefix-binding binding-end _)
                      (match (reader.sp-node-get binding-end)
                        [(reader.SpannedSexpr.Nil _)
                          (match (reader.sp-node-get value-tail)
                            [(reader.SpannedSexpr.Cons value body-tail _)
                              (match (reader.sp-node-get body-tail)
                                [(reader.SpannedSexpr.Cons body end _)
                                  (match (reader.sp-node-get end)
                                    [(reader.SpannedSexpr.Nil _)
                                      (match (parse-ast-scan-op op-name)
                                        [(ResultAstReduceOp.Ok op)
                                          (parse-ast-spmd-scan-bindings
                                            dispatch
                                            pools
                                            op
                                            (reader.sp-node-get range-binding)
                                            (reader.sp-node-get prefix-binding)
                                            (reader.sp-node-get value)
                                            (reader.sp-node-get body))]
                                        [(ResultAstReduceOp.Err message)
                                          (ResultAstExpr.Err message)])]
                                    [_
                                      (ResultAstExpr.Err
                                        "parse: malformed spmd-scan")])]
                                [_
                                  (ResultAstExpr.Err
                                    "parse: malformed spmd-scan")])]
                            [_ (ResultAstExpr.Err "parse: malformed spmd-scan")])]
                        [_ (ResultAstExpr.Err "parse: malformed spmd-scan")])]
                    [_ (ResultAstExpr.Err "parse: malformed spmd-scan")])]
                [_ (ResultAstExpr.Err "parse: malformed spmd-scan")])]
            [_ (ResultAstExpr.Err "parse: malformed spmd-scan")])]
        [_ (ResultAstExpr.Err "parse: malformed spmd-scan")])]
    [(reader.SpannedSexpr.Cons _ _ _)
      (ResultAstExpr.Err "parse: malformed spmd-scan")]
    [_ (ResultAstExpr.Err "parse: malformed spmd-scan")]))

(define (parse-ast-spmd-scan-bindings
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [op : AstReduceOp]
  [range-binding : reader.SpannedSexpr]
  [prefix-binding : reader.SpannedSexpr]
  [value : reader.SpannedSexpr]
  [body : reader.SpannedSexpr]) : ResultAstExpr
  (match range-binding
    [(reader.SpannedSexpr.BracketList items _)
      (parse-ast-spmd-scan-bindings
        dispatch
        pools
        op
        (reader.sp-node-get items)
        prefix-binding
        value
        body)]
    [(reader.SpannedSexpr.Cons index-node colon-tail _)
      (match (reader.sp-node-get index-node)
        [(reader.SpannedSexpr.Sym index _)
          (match (reader.sp-node-get colon-tail)
            [(reader.SpannedSexpr.Cons colon index-ty-tail _)
              (match (reader.sp-node-get index-ty-tail)
                [(reader.SpannedSexpr.Cons index-ty start-tail _)
                  (match (reader.sp-node-get start-tail)
                    [(reader.SpannedSexpr.Cons start end-tail _)
                      (match (reader.sp-node-get end-tail)
                        [(reader.SpannedSexpr.Cons end finish _)
                          (match (reader.sp-node-get finish)
                            [(reader.SpannedSexpr.Nil _)
                              (if (sexpr-colon?
                                (reader.spanned-sexpr-form
                                  (reader.sp-node-get colon)))
                                (match (parse-ast-type-spanned
                                  dispatch
                                  pools
                                  (reader.sp-node-get index-ty))
                                  [(ResultAstType.Ok parsed-index-ty)
                                    (parse-ast-spmd-scan-prefix-binding
                                      dispatch
                                      pools
                                      op
                                      index
                                      parsed-index-ty
                                      (reader.sp-node-get start)
                                      (reader.sp-node-get end)
                                      prefix-binding
                                      value
                                      body)]
                                  [(ResultAstType.Err message)
                                    (ResultAstExpr.Err message)])
                                (ResultAstExpr.Err
                                  "parse: expected ':' in spmd-scan range binding"))]
                            [_
                              (ResultAstExpr.Err
                                "parse: malformed spmd-scan range binding")])]
                        [_
                          (ResultAstExpr.Err
                            "parse: malformed spmd-scan range binding")])]
                    [_
                      (ResultAstExpr.Err
                        "parse: malformed spmd-scan range binding")])]
                [_
                  (ResultAstExpr.Err "parse: malformed spmd-scan range binding")])]
            [_ (ResultAstExpr.Err "parse: malformed spmd-scan range binding")])]
        [_ (ResultAstExpr.Err "parse: malformed spmd-scan range binding")])]
    [_ (ResultAstExpr.Err "parse: malformed spmd-scan range binding")]))

(define (parse-ast-spmd-scan-prefix-binding
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [op : AstReduceOp]
  [index : i64]
  [index-ty : AstType]
  [start : reader.SpannedSexpr]
  [end : reader.SpannedSexpr]
  [prefix-binding : reader.SpannedSexpr]
  [value : reader.SpannedSexpr]
  [body : reader.SpannedSexpr]) : ResultAstExpr
  (match prefix-binding
    [(reader.SpannedSexpr.BracketList items _)
      (parse-ast-spmd-scan-prefix-binding
        dispatch
        pools
        op
        index
        index-ty
        start
        end
        (reader.sp-node-get items)
        value
        body)]
    [(reader.SpannedSexpr.Cons prefix-node colon-tail _)
      (match (reader.sp-node-get prefix-node)
        [(reader.SpannedSexpr.Sym prefix _)
          (match (reader.sp-node-get colon-tail)
            [(reader.SpannedSexpr.Cons colon prefix-ty-tail _)
              (match (reader.sp-node-get prefix-ty-tail)
                [(reader.SpannedSexpr.Cons prefix-ty init-tail _)
                  (match (reader.sp-node-get init-tail)
                    [(reader.SpannedSexpr.Cons init finish _)
                      (match (reader.sp-node-get finish)
                        [(reader.SpannedSexpr.Nil _)
                          (if (sexpr-colon?
                            (reader.spanned-sexpr-form
                              (reader.sp-node-get colon)))
                            (match (parse-ast-type-spanned
                              dispatch
                              pools
                              (reader.sp-node-get prefix-ty))
                              [(ResultAstType.Ok parsed-prefix-ty)
                                (match (parse-ast-expr-with-pools
                                  dispatch
                                  pools
                                  start)
                                  [(ResultAstExpr.Ok parsed-start)
                                    (match (parse-ast-expr-with-pools
                                      dispatch
                                      pools
                                      end)
                                      [(ResultAstExpr.Ok parsed-end)
                                        (match (parse-ast-expr-with-pools
                                          dispatch
                                          pools
                                          (reader.sp-node-get init))
                                          [(ResultAstExpr.Ok parsed-init)
                                            (match (parse-ast-expr-with-pools
                                              dispatch
                                              pools
                                              value)
                                              [(ResultAstExpr.Ok parsed-value)
                                                (match (parse-ast-expr-with-pools
                                                  dispatch
                                                  pools
                                                  body)
                                                  [(ResultAstExpr.Ok
                                                      parsed-body)
                                                    (ResultAstExpr.Ok
                                                      (ast-expr-spmd-scan-id-with-pools
                                                        pools
                                                        op
                                                        index
                                                        index-ty
                                                        parsed-start
                                                        parsed-end
                                                        prefix
                                                        parsed-prefix-ty
                                                        parsed-init
                                                        parsed-value
                                                        parsed-body))]
                                                  [(ResultAstExpr.Err message)
                                                    (ResultAstExpr.Err message)])]
                                              [(ResultAstExpr.Err message)
                                                (ResultAstExpr.Err message)])]
                                          [(ResultAstExpr.Err message)
                                            (ResultAstExpr.Err message)])]
                                      [(ResultAstExpr.Err message)
                                        (ResultAstExpr.Err message)])]
                                  [(ResultAstExpr.Err message)
                                    (ResultAstExpr.Err message)])]
                              [(ResultAstType.Err message)
                                (ResultAstExpr.Err message)])
                            (ResultAstExpr.Err
                              "parse: expected ':' in spmd-scan prefix binding"))]
                        [_
                          (ResultAstExpr.Err
                            "parse: malformed spmd-scan prefix binding")])]
                    [_
                      (ResultAstExpr.Err
                        "parse: malformed spmd-scan prefix binding")])]
                [_
                  (ResultAstExpr.Err
                    "parse: malformed spmd-scan prefix binding")])]
            [_ (ResultAstExpr.Err "parse: malformed spmd-scan prefix binding")])]
        [_ (ResultAstExpr.Err "parse: malformed spmd-scan prefix binding")])]
    [_ (ResultAstExpr.Err "parse: malformed spmd-scan prefix binding")]))

(define (parse-ast-spmd-broadcast
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons value-node lane-tail _)
      (match (reader.sp-node-get lane-tail)
        [(reader.SpannedSexpr.Cons lane-node end _)
          (match (reader.sp-node-get end)
            [(reader.SpannedSexpr.Nil _)
              (match (parse-ast-expr-with-pools
                dispatch
                pools
                (reader.sp-node-get value-node))
                [(ResultAstExpr.Ok value)
                  (match (parse-ast-expr-with-pools
                    dispatch
                    pools
                    (reader.sp-node-get lane-node))
                    [(ResultAstExpr.Ok lane)
                      (ResultAstExpr.Ok
                        (ast-expr-spmd-broadcast-with-pools pools value lane))]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
            [_ (ResultAstExpr.Err "parse: malformed spmd-broadcast")])]
        [_ (ResultAstExpr.Err "parse: malformed spmd-broadcast")])]
    [_ (ResultAstExpr.Err "parse: malformed spmd-broadcast")]))

(define (parse-ast-spmd-shuffle
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons value-node lane-tail _)
      (match (reader.sp-node-get lane-tail)
        [(reader.SpannedSexpr.Cons lane-node end _)
          (match (reader.sp-node-get end)
            [(reader.SpannedSexpr.Nil _)
              (match (parse-ast-expr-with-pools
                dispatch
                pools
                (reader.sp-node-get value-node))
                [(ResultAstExpr.Ok value)
                  (match (parse-ast-expr-with-pools
                    dispatch
                    pools
                    (reader.sp-node-get lane-node))
                    [(ResultAstExpr.Ok lane)
                      (ResultAstExpr.Ok
                        (ast-expr-spmd-shuffle-with-pools pools value lane))]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
            [_ (ResultAstExpr.Err "parse: malformed spmd-shuffle")])]
        [_ (ResultAstExpr.Err "parse: malformed spmd-shuffle")])]
    [_ (ResultAstExpr.Err "parse: malformed spmd-shuffle")]))

(define (parse-ast-try
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons expr end _)
      (match (reader.sp-node-get end)
        [(reader.SpannedSexpr.Nil _)
          (match (parse-ast-expr-with-pools
            dispatch
            pools
            (reader.sp-node-get expr))
            [(ResultAstExpr.Ok parsed-expr)
              (ResultAstExpr.Ok (ast-expr-try-with-pools pools parsed-expr))]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [_ (ResultAstExpr.Err "parse: try expects exactly one expression")])]
    [_ (ResultAstExpr.Err "parse: try expects exactly one expression")]))

(define (parse-ast-return
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons expr end _)
      (match (reader.sp-node-get end)
        [(reader.SpannedSexpr.Nil _)
          (match (parse-ast-expr-with-pools
            dispatch
            pools
            (reader.sp-node-get expr))
            [(ResultAstExpr.Ok parsed-expr)
              (ResultAstExpr.Ok (ast-expr-return-with-pools pools parsed-expr))]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [_ (ResultAstExpr.Err "parse: return expects exactly one expression")])]
    [_ (ResultAstExpr.Err "parse: return expects exactly one expression")]))

(define (parse-ast-box-like
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]
  [is-get : bool]
  [is-take : bool]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons expr end _)
      (match (reader.sp-node-get end)
        [(reader.SpannedSexpr.Nil _)
          (match (parse-ast-expr-with-pools
            dispatch
            pools
            (reader.sp-node-get expr))
            [(ResultAstExpr.Ok parsed-expr)
              (if is-get
                (ResultAstExpr.Ok
                  (ast-expr-box-get-with-pools pools parsed-expr))
                (if is-take
                  (ResultAstExpr.Ok
                    (ast-expr-box-take-with-pools pools parsed-expr))
                  (ResultAstExpr.Ok (ast-expr-box-with-pools pools parsed-expr))))]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [_
          (ResultAstExpr.Err
            (if is-get
              "parse: box-get expects exactly one expression"
              (if is-take
                "parse: box-take expects exactly one expression"
                "parse: box expects exactly one expression")))])]
    [_
      (ResultAstExpr.Err
        (if is-get
          "parse: box-get expects exactly one expression"
          (if is-take
            "parse: box-take expects exactly one expression"
            "parse: box expects exactly one expression")))]))

;; `(ptr-null : T)` - a colon followed by a pointer type, no leading expression.
;; The parser accepts any type here; the typechecker rejects non-pointer `T`.
(define (parse-ast-ptr-null
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons colon ty-tail _)
      (match (reader.sp-node-get ty-tail)
        [(reader.SpannedSexpr.Cons ty end _)
          (match (reader.sp-node-get end)
            [(reader.SpannedSexpr.Nil _)
              (if (sexpr-colon?
                (reader.spanned-sexpr-form (reader.sp-node-get colon)))
                (match (parse-ast-type-spanned
                  dispatch
                  pools
                  (reader.sp-node-get ty))
                  [(ResultAstType.Ok parsed-ty)
                    (ResultAstExpr.Ok
                      (ast-node-pool-context-expr-push
                        pools
                        (AstExpr.PtrNull parsed-ty)))]
                  [(ResultAstType.Err message) (ResultAstExpr.Err message)])
                (ResultAstExpr.Err "parse: expected ':' in ptr-null"))]
            [_
              (ResultAstExpr.Err
                "parse: ptr-null expects (ptr-null : T) with a pointer type T")])]
        [_
          (ResultAstExpr.Err
            "parse: ptr-null expects (ptr-null : T) with a pointer type T")])]
    [_
      (ResultAstExpr.Err
        "parse: ptr-null expects (ptr-null : T) with a pointer type T")]))

;; `(init : T)` carries an explicit target type. Bare `(init)` is contextual
;; and must be checked/lowered in a position with an expected type.
(define (parse-ast-init
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Nil _)
      (ResultAstExpr.Ok (ast-expr-init-contextual-with-pools pools))]
    [(reader.SpannedSexpr.Cons colon ty-tail _)
      (match (reader.sp-node-get ty-tail)
        [(reader.SpannedSexpr.Cons ty end _)
          (match (reader.sp-node-get end)
            [(reader.SpannedSexpr.Nil _)
              (if (sexpr-colon?
                (reader.spanned-sexpr-form (reader.sp-node-get colon)))
                (match (parse-ast-type-spanned
                  dispatch
                  pools
                  (reader.sp-node-get ty))
                  [(ResultAstType.Ok parsed-ty)
                    (ResultAstExpr.Ok
                      (ast-expr-init-with-pools pools parsed-ty))]
                  [(ResultAstType.Err message) (ResultAstExpr.Err message)])
                (ResultAstExpr.Err "parse: expected ':' in init"))]
            [_ (ResultAstExpr.Err "parse: init expects (init : T)")])]
        [_ (ResultAstExpr.Err "parse: init expects (init : T)")])]
    [_ (ResultAstExpr.Err "parse: init expects (init : T)")]))

;; `(ptr-null? p)` - a single pointer operand.
(define (parse-ast-ptr-null-check
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons expr end _)
      (match (reader.sp-node-get end)
        [(reader.SpannedSexpr.Nil _)
          (match (parse-ast-expr-with-pools
            dispatch
            pools
            (reader.sp-node-get expr))
            [(ResultAstExpr.Ok parsed-expr)
              (ResultAstExpr.Ok
                (ast-expr-ptr-null-check-with-pools pools parsed-expr))]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [_
          (ResultAstExpr.Err "parse: ptr-null? expects exactly one expression")])]
    [_ (ResultAstExpr.Err "parse: ptr-null? expects exactly one expression")]))

(define (parse-ast-ptr-read
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons expr end _)
      (match (reader.sp-node-get end)
        [(reader.SpannedSexpr.Nil _)
          (match (parse-ast-expr-with-pools
            dispatch
            pools
            (reader.sp-node-get expr))
            [(ResultAstExpr.Ok parsed-expr)
              (ResultAstExpr.Ok
                (ast-expr-ptr-read-with-pools pools parsed-expr))]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [_ (ResultAstExpr.Err "parse: ptr-read expects exactly one expression")])]
    [_ (ResultAstExpr.Err "parse: ptr-read expects exactly one expression")]))

(define (parse-ast-ptr-addr-of
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons place end _)
      (match (reader.sp-node-get end)
        [(reader.SpannedSexpr.Nil _)
          (match (parse-ast-expr-with-pools
            dispatch
            pools
            (reader.sp-node-get place))
            [(ResultAstExpr.Ok parsed-place)
              (ResultAstExpr.Ok
                (ast-expr-ptr-addr-of-id-with-pools pools parsed-place))]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [_
          (ResultAstExpr.Err
            "parse: ptr-addr-of expects exactly one addressable place")])]
    [_
      (ResultAstExpr.Err
        "parse: ptr-addr-of expects exactly one addressable place")]))

(define (parse-ast-ptr-write
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons ptr value-tail _)
      (match (reader.sp-node-get value-tail)
        [(reader.SpannedSexpr.Cons value end _)
          (match (reader.sp-node-get end)
            [(reader.SpannedSexpr.Nil _)
              (match (parse-ast-expr-with-pools
                dispatch
                pools
                (reader.sp-node-get ptr))
                [(ResultAstExpr.Ok parsed-ptr)
                  (match (parse-ast-expr-with-pools
                    dispatch
                    pools
                    (reader.sp-node-get value))
                    [(ResultAstExpr.Ok parsed-value)
                      (ResultAstExpr.Ok
                        (ast-expr-ptr-write-with-pools
                          pools
                          parsed-ptr
                          parsed-value))]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
            [_
              (ResultAstExpr.Err
                "parse: ptr-write! expects exactly two expressions")])]
        [_
          (ResultAstExpr.Err
            "parse: ptr-write! expects exactly two expressions")])]
    [_ (ResultAstExpr.Err "parse: ptr-write! expects exactly two expressions")]))

(define (parse-ast-ptr-offset
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons ptr offset-tail _)
      (match (reader.sp-node-get offset-tail)
        [(reader.SpannedSexpr.Cons offset end _)
          (match (reader.sp-node-get end)
            [(reader.SpannedSexpr.Nil _)
              (match (parse-ast-expr-with-pools
                dispatch
                pools
                (reader.sp-node-get ptr))
                [(ResultAstExpr.Ok parsed-ptr)
                  (match (parse-ast-expr-with-pools
                    dispatch
                    pools
                    (reader.sp-node-get offset))
                    [(ResultAstExpr.Ok parsed-offset)
                      (ResultAstExpr.Ok
                        (ast-expr-ptr-offset-with-pools
                          pools
                          parsed-ptr
                          parsed-offset))]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
            [_
              (ResultAstExpr.Err
                "parse: ptr-offset expects exactly two expressions")])]
        [_
          (ResultAstExpr.Err
            "parse: ptr-offset expects exactly two expressions")])]
    [_ (ResultAstExpr.Err "parse: ptr-offset expects exactly two expressions")]))

(define (parse-ast-ptr-cast-like
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [is-int-to-ptr : bool]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons expr colon-tail _)
      (match (reader.sp-node-get colon-tail)
        [(reader.SpannedSexpr.Cons colon ty-tail _)
          (match (reader.sp-node-get ty-tail)
            [(reader.SpannedSexpr.Cons ty end _)
              (match (reader.sp-node-get end)
                [(reader.SpannedSexpr.Nil _)
                  (if (sexpr-colon?
                    (reader.spanned-sexpr-form (reader.sp-node-get colon)))
                    (match (parse-ast-expr-with-pools
                      dispatch
                      pools
                      (reader.sp-node-get expr))
                      [(ResultAstExpr.Ok parsed-expr)
                        (match (parse-ast-type-spanned
                          dispatch
                          pools
                          (reader.sp-node-get ty))
                          [(ResultAstType.Ok parsed-ty)
                            (if is-int-to-ptr
                              (ResultAstExpr.Ok
                                (ast-expr-int-to-ptr-with-pools
                                  pools
                                  parsed-expr
                                  parsed-ty))
                              (ResultAstExpr.Ok
                                (ast-expr-ptr-cast-with-pools
                                  pools
                                  parsed-expr
                                  parsed-ty)))]
                          [(ResultAstType.Err message)
                            (ResultAstExpr.Err message)])]
                      [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])
                    (ResultAstExpr.Err "parse: expected ':' in pointer cast"))]
                [_
                  (ResultAstExpr.Err
                    "parse: pointer cast expects (form expr : pointer-type)")])]
            [_
              (ResultAstExpr.Err
                "parse: pointer cast expects (form expr : pointer-type)")])]
        [_
          (ResultAstExpr.Err
            "parse: pointer cast expects (form expr : pointer-type)")])]
    [_
      (ResultAstExpr.Err
        "parse: pointer cast expects (form expr : pointer-type)")]))

(define (parse-ast-ptr-to-int
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons expr end _)
      (match (reader.sp-node-get end)
        [(reader.SpannedSexpr.Nil _)
          (match (parse-ast-expr-with-pools
            dispatch
            pools
            (reader.sp-node-get expr))
            [(ResultAstExpr.Ok parsed-expr)
              (ResultAstExpr.Ok
                (ast-expr-ptr-to-int-with-pools pools parsed-expr))]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [_ (ResultAstExpr.Err "parse: ptr->int expects exactly one expression")])]
    [_ (ResultAstExpr.Err "parse: ptr->int expects exactly one expression")]))

(define (parse-ast-one-expr
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]
  [name : String]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons expr end _)
      (match (reader.sp-node-get end)
        [(reader.SpannedSexpr.Nil _)
          (parse-ast-expr-with-pools dispatch pools (reader.sp-node-get expr))]
        [_
          (ResultAstExpr.Err
            (string.append
              "parse: "
              (string.append name " expects exactly one expression")))])]
    [_
      (ResultAstExpr.Err
        (string.append
          "parse: "
          (string.append name " expects exactly one expression")))]))

(define (parse-ast-two-exprs
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]
  [name : String]) : ResultAstExprPair
  (match rest
    [(reader.SpannedSexpr.Cons first second-tail _)
      (match (reader.sp-node-get second-tail)
        [(reader.SpannedSexpr.Cons second end _)
          (match (reader.sp-node-get end)
            [(reader.SpannedSexpr.Nil _)
              (match (parse-ast-expr-with-pools
                dispatch
                pools
                (reader.sp-node-get first))
                [(ResultAstExpr.Ok parsed-first)
                  (match (parse-ast-expr-with-pools
                    dispatch
                    pools
                    (reader.sp-node-get second))
                    [(ResultAstExpr.Ok parsed-second)
                      (ResultAstExprPair.Ok
                        (AstExprPair parsed-first parsed-second))]
                    [(ResultAstExpr.Err message)
                      (ResultAstExprPair.Err message)])]
                [(ResultAstExpr.Err message) (ResultAstExprPair.Err message)])]
            [_
              (ResultAstExprPair.Err
                (string.append
                  "parse: "
                  (string.append name " expects exactly two expressions")))])]
        [_
          (ResultAstExprPair.Err
            (string.append
              "parse: "
              (string.append name " expects exactly two expressions")))])]
    [_
      (ResultAstExprPair.Err
        (string.append
          "parse: "
          (string.append name " expects exactly two expressions")))]))

(define (parse-ast-string-data
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-one-expr dispatch pools rest "string-data")
    [(ResultAstExpr.Ok expr)
      (ResultAstExpr.Ok (ast-expr-string-data-with-pools pools expr))]
    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-string-from-bytes
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-two-exprs dispatch pools rest "string-from-bytes")
    [(ResultAstExprPair.Ok pair)
      (ResultAstExpr.Ok
        (ast-expr-string-from-bytes-with-pools
          pools
          (struct-get pair first)
          (struct-get pair second)))]
    [(ResultAstExprPair.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-array-data
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-one-expr dispatch pools rest "array-data")
    [(ResultAstExpr.Ok expr)
      (ResultAstExpr.Ok (ast-expr-array-data-with-pools pools expr))]
    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-no-arg-low-level
  [rest : reader.SpannedSexpr]
  [name : String]
  [expr : i64]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Nil _) (ResultAstExpr.Ok expr)]
    [_
      (ResultAstExpr.Err
        (string.append "parse: " (string.append name " expects no arguments")))]))

(define (parse-ast-cpuid-like
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [tag : i64]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-two-exprs dispatch pools rest "cpuid")
    [(ResultAstExprPair.Ok pair)
      (let
        [leaf : i64 (struct-get pair first)]
        [subleaf : i64 (struct-get pair second)]
        (cond
          [(= tag (compiler-parse-tag-expr-cpuid-eax))
            (ResultAstExpr.Ok
              (ast-expr-cpuid-eax-with-pools pools leaf subleaf))]
          [(= tag (compiler-parse-tag-expr-cpuid-ebx))
            (ResultAstExpr.Ok
              (ast-expr-cpuid-ebx-with-pools pools leaf subleaf))]
          [(= tag (compiler-parse-tag-expr-cpuid-ecx))
            (ResultAstExpr.Ok
              (ast-expr-cpuid-ecx-with-pools pools leaf subleaf))]
          [else
            (ResultAstExpr.Ok
              (ast-expr-cpuid-edx-with-pools pools leaf subleaf))]))]
    [(ResultAstExprPair.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-xgetbv
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-one-expr dispatch pools rest "xgetbv")
    [(ResultAstExpr.Ok expr)
      (ResultAstExpr.Ok (ast-expr-xgetbv-with-pools pools expr))]
    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-syscall-count [args : AstExprList]) : i64
  (struct-get (& args) len))

;; `(syscall number a0 .. a5)`: the syscall number followed by up to six
;; arguments (1 to 7 operands total). Typechecking requires an enclosing
;; `(unsafe ...)` context before this lowers to a raw `syscall` instruction.
(define (parse-ast-syscall
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-expr-list dispatch pools rest)
    [(ResultAstExprList.Ok args)
      (let
        [count : i64 (parse-ast-syscall-count args)]
        (if (< count 1)
          (ResultAstExpr.Err "parse: syscall requires a syscall number")
          (if (> count 7)
            (ResultAstExpr.Err
              "parse: syscall takes at most 7 operands (number plus six arguments)")
            (ResultAstExpr.Ok (ast-expr-syscall-with-pools pools args)))))]
    [(ResultAstExprList.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-with-region
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Nil _)
      (ResultAstExpr.Err
        "parse: with-arena requires a region name before its body")]
    [(reader.SpannedSexpr.Cons _ _ _)
      (match rest
        [(reader.SpannedSexpr.Cons region-node body _)
          (match (reader.sp-node-get region-node)
            [(reader.SpannedSexpr.Sym region _)
              (match (reader.sp-node-get body)
                [(reader.SpannedSexpr.Nil _)
                  (ResultAstExpr.Err
                    (string.append
                      "parse: with-arena '"
                      (string.append
                        (compiler-parse-name-text region)
                        "' requires a non-empty body")))]
                [_
                  (match (parse-ast-expr-list
                    dispatch
                    pools
                    (reader.sp-node-get body))
                    [(ResultAstExprList.Ok exprs)
                      (ResultAstExpr.Ok
                        (ast-node-pool-context-expr-push
                          pools
                          (AstExpr.WithRegion region exprs)))]
                    [(ResultAstExprList.Err message)
                      (ResultAstExpr.Err message)])])]
            [_
              (ResultAstExpr.Err
                "parse: with-arena region name must be an identifier")])]
        [_ (ResultAstExpr.Err "parse: malformed with-arena")])]
    [_ (ResultAstExpr.Err "parse: malformed with-arena")]))

(define (parse-ast-with-escape
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Nil _)
      (ResultAstExpr.Err
        "parse: with-escape requires a scratch arena before its body")]
    [(reader.SpannedSexpr.Cons scratch body _)
      (match (reader.sp-node-get body)
        [(reader.SpannedSexpr.Nil _)
          (ResultAstExpr.Err "parse: with-escape requires a non-empty body")]
        [_
          (match (parse-ast-expr-with-pools
            dispatch
            pools
            (reader.sp-node-get scratch))
            [(ResultAstExpr.Ok parsed-scratch)
              (match (parse-ast-expr-list
                dispatch
                pools
                (reader.sp-node-get body))
                [(ResultAstExprList.Ok exprs)
                  (ResultAstExpr.Ok
                    (ast-expr-with-escape-with-pools pools parsed-scratch exprs))]
                [(ResultAstExprList.Err message) (ResultAstExpr.Err message)])]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])])]
    [_ (ResultAstExpr.Err "parse: malformed with-escape")]))

(define (parse-ast-with-scratch
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Nil _)
      (ResultAstExpr.Err "parse: with-scratch requires a non-empty body")]
    [(reader.SpannedSexpr.Cons _ _ _)
      (match (parse-ast-expr-list dispatch pools rest)
        [(ResultAstExprList.Ok exprs)
          (ResultAstExpr.Ok (ast-expr-with-scratch-with-pools pools exprs))]
        [(ResultAstExprList.Err message) (ResultAstExpr.Err message)])]
    [_ (ResultAstExpr.Err "parse: malformed with-scratch")]))

(define (parse-ast-in-arena
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Nil _)
      (ResultAstExpr.Err "parse: in-arena requires an arena before its body")]
    [(reader.SpannedSexpr.Cons arena body _)
      (match (reader.sp-node-get body)
        [(reader.SpannedSexpr.Nil _)
          (ResultAstExpr.Err "parse: in-arena requires a non-empty body")]
        [_
          (match (parse-ast-expr-with-pools
            dispatch
            pools
            (reader.sp-node-get arena))
            [(ResultAstExpr.Ok parsed-arena)
              (match (parse-ast-expr-list
                dispatch
                pools
                (reader.sp-node-get body))
                [(ResultAstExprList.Ok exprs)
                  (ResultAstExpr.Ok
                    (ast-expr-in-arena-with-pools pools parsed-arena exprs))]
                [(ResultAstExprList.Err message) (ResultAstExpr.Err message)])]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])])]
    [_ (ResultAstExpr.Err "parse: malformed in-arena")]))

(define (parse-ast-resource-binding-items
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [items : reader.SpannedSexpr]) : ResultAstResourceBinding
  (match items
    [(reader.SpannedSexpr.Cons _ _ _)
      (match items
        [(reader.SpannedSexpr.Cons name-node rest _)
          (match (reader.sp-node-get name-node)
            [(reader.SpannedSexpr.Sym name _)
              (match (reader.sp-node-get rest)
                [(reader.SpannedSexpr.Nil _)
                  (ResultAstResourceBinding.Err
                    "parse: with binding is missing initializer")]
                [(reader.SpannedSexpr.Cons init tail _)
                  (match (reader.sp-node-get tail)
                    [(reader.SpannedSexpr.Nil _)
                      (ResultAstResourceBinding.Err
                        "parse: with binding is missing cleanup function")]
                    [(reader.SpannedSexpr.Cons cleanup extra _)
                      (match (reader.sp-node-get extra)
                        [(reader.SpannedSexpr.Nil _)
                          (match (parse-ast-expr-with-pools
                            dispatch
                            pools
                            (reader.sp-node-get init))
                            [(ResultAstExpr.Ok parsed-init)
                              (match (parse-ast-expr-with-pools
                                dispatch
                                pools
                                (reader.sp-node-get cleanup))
                                [(ResultAstExpr.Ok parsed-cleanup)
                                  (ResultAstResourceBinding.Ok
                                    (ast-resource-binding-id
                                      name
                                      parsed-init
                                      parsed-cleanup))]
                                [(ResultAstExpr.Err message)
                                  (ResultAstResourceBinding.Err message)])]
                            [(ResultAstExpr.Err message)
                              (ResultAstResourceBinding.Err message)])]
                        [_
                          (ResultAstResourceBinding.Err
                            "parse: with binding has too many fields")])]
                    [_
                      (ResultAstResourceBinding.Err
                        "parse: malformed with binding")])]
                [_
                  (ResultAstResourceBinding.Err "parse: malformed with binding")])]
            [_
              (ResultAstResourceBinding.Err
                "parse: with binding name must be an identifier")])]
        [_ (ResultAstResourceBinding.Err "parse: malformed with binding")])]
    [_ (ResultAstResourceBinding.Err "parse: malformed with binding")]))

(define (parse-ast-resource-binding
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [binding : reader.SpannedSexpr]) : ResultAstResourceBinding
  (match binding
    [(reader.SpannedSexpr.BracketList items _)
      (parse-ast-resource-binding-items
        dispatch
        pools
        (reader.sp-node-get items))]
    [_
      (ResultAstResourceBinding.Err
        "parse: with binding must use bracket syntax")]))

(define (parse-ast-resource-binding-list-into
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [bindings : reader.SpannedSexpr]
  [out : (&mut out AstResourceBindingList)]) : ResultAstResourceBindingListBuild
  (match bindings
    [(reader.SpannedSexpr.Nil _) (ResultAstResourceBindingListBuild.Ok)]
    [(reader.SpannedSexpr.Cons head rest _)
      (match (parse-ast-resource-binding
        dispatch
        pools
        (reader.sp-node-get head))
        [(ResultAstResourceBinding.Ok parsed-head)
          (begin
            (ast-resource-binding-list-push out parsed-head)
            (parse-ast-resource-binding-list-into
              dispatch
              pools
              (reader.sp-node-get rest)
              out))]
        [(ResultAstResourceBinding.Err message)
          (ResultAstResourceBindingListBuild.Err message)])]
    [_
      (ResultAstResourceBindingListBuild.Err
        "parse: malformed with binding list")]))

(define (parse-ast-resource-binding-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [bindings : reader.SpannedSexpr]) : ResultAstResourceBindingList
  (let
    [out : AstResourceBindingList (ast-resource-binding-list-new)]
    (match (parse-ast-resource-binding-list-into
      dispatch
      pools
      bindings
      (&mut out))
      [(ResultAstResourceBindingListBuild.Ok)
        (ResultAstResourceBindingList.Ok out)]
      [(ResultAstResourceBindingListBuild.Err message)
        (ResultAstResourceBindingList.Err message)])))

(define (parse-ast-with-resource
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Nil _)
      (ResultAstExpr.Err "parse: with requires a binding list before its body")]
    [(reader.SpannedSexpr.Cons bindings body _)
      (match (reader.sp-node-get bindings)
        [(reader.SpannedSexpr.Nil _)
          (ResultAstExpr.Err "parse: with requires a non-empty binding list")]
        [(reader.SpannedSexpr.Cons _ _ _)
          (match (reader.sp-node-get body)
            [(reader.SpannedSexpr.Nil _)
              (ResultAstExpr.Err "parse: with requires a non-empty body")]
            [_
              (match (parse-ast-resource-binding-list
                dispatch
                pools
                (reader.sp-node-get bindings))
                [(ResultAstResourceBindingList.Ok parsed-bindings)
                  (match (parse-ast-expr-list
                    dispatch
                    pools
                    (reader.sp-node-get body))
                    [(ResultAstExprList.Ok parsed-body)
                      (ResultAstExpr.Ok
                        (ast-node-pool-context-expr-push
                          pools
                          (AstExpr.WithResource
                            (box
                              (AstWithResource.WithResource
                                parsed-bindings
                                parsed-body)))))]
                    [(ResultAstExprList.Err message)
                      (ResultAstExpr.Err message)])]
                [(ResultAstResourceBindingList.Err message)
                  (ResultAstExpr.Err message)])])]
        [_ (ResultAstExpr.Err "parse: malformed with binding list")])]
    [_ (ResultAstExpr.Err "parse: malformed with")]))

(define (parse-ast-match-arm
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.SpannedSexpr]) : ResultAstMatchArm
  (match s
    [(reader.SpannedSexpr.BracketList items _)
      (parse-ast-match-arm dispatch pools (reader.sp-node-get items))]
    [(reader.SpannedSexpr.Cons pattern body-tail _)
      (match (reader.sp-node-get body-tail)
        [(reader.SpannedSexpr.Cons body end _)
          (match (reader.sp-node-get end)
            [(reader.SpannedSexpr.Nil _)
              (match (parse-ast-pattern
                dispatch
                pools
                (reader.spanned-sexpr-form (reader.sp-node-get pattern)))
                [(ResultAstPattern.Ok parsed-pattern)
                  (match (parse-ast-expr-with-pools
                    dispatch
                    pools
                    (reader.sp-node-get body))
                    [(ResultAstExpr.Ok parsed-body)
                      (ResultAstMatchArm.Ok
                        (ast-match-arm parsed-pattern parsed-body))]
                    [(ResultAstExpr.Err message)
                      (ResultAstMatchArm.Err message)])]
                [(ResultAstPattern.Err message) (ResultAstMatchArm.Err message)])]
            [_ (ResultAstMatchArm.Err "parse: malformed match arm")])]
        [_ (ResultAstMatchArm.Err "parse: malformed match arm")])]
    [_ (ResultAstMatchArm.Err "parse: malformed match arm")]))

(define (parse-ast-match-arm-list-into
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.SpannedSexpr]
  [out : (&mut out AstMatchArmList)]) : ResultAstMatchArmListBuild
  (match s
    [(reader.SpannedSexpr.Nil _) (ResultAstMatchArmListBuild.Ok)]
    [(reader.SpannedSexpr.Cons head tail _)
      (match (parse-ast-match-arm dispatch pools (reader.sp-node-get head))
        [(ResultAstMatchArm.Ok parsed-head)
          (begin
            (ast-match-arm-list-push out parsed-head)
            (parse-ast-match-arm-list-into
              dispatch
              pools
              (reader.sp-node-get tail)
              out))]
        [(ResultAstMatchArm.Err message)
          (ResultAstMatchArmListBuild.Err message)])]
    [_ (ResultAstMatchArmListBuild.Err "parse: malformed match arm list")]))

(define (parse-ast-match-arm-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.SpannedSexpr]) : ResultAstMatchArmList
  (let
    [out : AstMatchArmList (ast-match-arm-list-new)]
    (match (parse-ast-match-arm-list-into dispatch pools s (&mut out))
      [(ResultAstMatchArmListBuild.Ok) (ResultAstMatchArmList.Ok out)]
      [(ResultAstMatchArmListBuild.Err message)
        (ResultAstMatchArmList.Err message)])))

(define (parse-ast-match
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons scrutinee arms _)
      (match (parse-ast-expr-with-pools
        dispatch
        pools
        (reader.sp-node-get scrutinee))
        [(ResultAstExpr.Ok parsed-scrutinee)
          (match (parse-ast-match-arm-list
            dispatch
            pools
            (reader.sp-node-get arms))
            [(ResultAstMatchArmList.Ok parsed-arms)
              (ResultAstExpr.Ok
                (ast-expr-match-with-pools pools parsed-scrutinee parsed-arms))]
            [(ResultAstMatchArmList.Err message) (ResultAstExpr.Err message)])]
        [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
    [_ (ResultAstExpr.Err "parse: malformed match")]))

(define (parse-ast-foreach-binding
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [binding : reader.SpannedSexpr]
  [body : reader.SpannedSexpr]) : ResultAstExpr
  (match binding
    [(reader.SpannedSexpr.BracketList items _)
      (parse-ast-foreach-binding dispatch pools (reader.sp-node-get items) body)]
    [(reader.SpannedSexpr.Cons index-node colon-tail _)
      (match (reader.sp-node-get index-node)
        [(reader.SpannedSexpr.Sym index _)
          (match (reader.sp-node-get colon-tail)
            [(reader.SpannedSexpr.Cons colon index-ty-tail _)
              (match (reader.sp-node-get index-ty-tail)
                [(reader.SpannedSexpr.Cons index-ty start-tail _)
                  (match (reader.sp-node-get start-tail)
                    [(reader.SpannedSexpr.Cons start end-tail _)
                      (match (reader.sp-node-get end-tail)
                        [(reader.SpannedSexpr.Cons end finish _)
                          (match (reader.sp-node-get finish)
                            [(reader.SpannedSexpr.Nil _)
                              (if (sexpr-colon?
                                (reader.spanned-sexpr-form
                                  (reader.sp-node-get colon)))
                                (match (parse-ast-type-spanned
                                  dispatch
                                  pools
                                  (reader.sp-node-get index-ty))
                                  [(ResultAstType.Ok parsed-index-ty)
                                    (match (parse-ast-expr-with-pools
                                      dispatch
                                      pools
                                      (reader.sp-node-get start))
                                      [(ResultAstExpr.Ok parsed-start)
                                        (match (parse-ast-expr-with-pools
                                          dispatch
                                          pools
                                          (reader.sp-node-get end))
                                          [(ResultAstExpr.Ok parsed-end)
                                            (match (parse-ast-expr-with-pools
                                              dispatch
                                              pools
                                              body)
                                              [(ResultAstExpr.Ok parsed-body)
                                                (ResultAstExpr.Ok
                                                  (ast-expr-foreach-id-with-pools
                                                    pools
                                                    index
                                                    parsed-index-ty
                                                    parsed-start
                                                    parsed-end
                                                    parsed-body))]
                                              [(ResultAstExpr.Err message)
                                                (ResultAstExpr.Err message)])]
                                          [(ResultAstExpr.Err message)
                                            (ResultAstExpr.Err message)])]
                                      [(ResultAstExpr.Err message)
                                        (ResultAstExpr.Err message)])]
                                  [(ResultAstType.Err message)
                                    (ResultAstExpr.Err message)])
                                (ResultAstExpr.Err
                                  "parse: expected ':' in foreach"))]
                            [_
                              (ResultAstExpr.Err
                                "parse: malformed foreach binding")])]
                        [_
                          (ResultAstExpr.Err "parse: malformed foreach binding")])]
                    [_ (ResultAstExpr.Err "parse: malformed foreach binding")])]
                [_ (ResultAstExpr.Err "parse: malformed foreach binding")])]
            [_ (ResultAstExpr.Err "parse: malformed foreach binding")])]
        [_ (ResultAstExpr.Err "parse: malformed foreach binding")])]
    [_ (ResultAstExpr.Err "parse: malformed foreach binding")]))

(define (parse-ast-foreach
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons binding-list body-tail _)
      (match (reader.sp-node-get binding-list)
        [(reader.SpannedSexpr.Cons binding binding-end _)
          (match (reader.sp-node-get binding-end)
            [(reader.SpannedSexpr.Nil _)
              (match (reader.sp-node-get body-tail)
                [(reader.SpannedSexpr.Cons body end _)
                  (match (reader.sp-node-get end)
                    [(reader.SpannedSexpr.Nil _)
                      (parse-ast-foreach-binding
                        dispatch
                        pools
                        (reader.sp-node-get binding)
                        (reader.sp-node-get body))]
                    [_ (ResultAstExpr.Err "parse: malformed foreach")])]
                [_ (ResultAstExpr.Err "parse: malformed foreach")])]
            [_ (ResultAstExpr.Err "parse: malformed foreach")])]
        [_ (ResultAstExpr.Err "parse: malformed foreach")])]
    [_ (ResultAstExpr.Err "parse: malformed foreach")]))

(define (parse-ast-call
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [head : reader.SpannedSexpr]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-expr-with-pools dispatch pools head)
    [(ResultAstExpr.Ok parsed-head)
      (match (parse-ast-call-arg-list dispatch pools rest)
        [(ResultAstExprList.Ok parsed-args)
          (ResultAstExpr.Ok
            (ast-expr-call-with-pools pools parsed-head parsed-args))]
        [(ResultAstExprList.Err message) (ResultAstExpr.Err message)])]
    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-begin
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-expr-list dispatch pools rest)
    [(ResultAstExprList.Ok exprs)
      (ResultAstExpr.Ok
        (ast-node-pool-context-expr-push pools (AstExpr.Begin exprs)))]
    [(ResultAstExprList.Err message) (ResultAstExpr.Err message)]))

;; `(unsafe expr+)` parses like `begin` but requires a non-empty body. It has
;; the same behavior as `begin`; it marks an unsafe context for later raw-pointer
;; ops.
(define (parse-ast-unsafe
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Nil _)
      (ResultAstExpr.Err "parse: unsafe requires a non-empty body")]
    [_
      (match (parse-ast-expr-list dispatch pools rest)
        [(ResultAstExprList.Ok exprs)
          (ResultAstExpr.Ok
            (ast-node-pool-context-expr-push pools (AstExpr.Unsafe exprs)))]
        [(ResultAstExprList.Err message) (ResultAstExpr.Err message)])]))

(define (parse-ast-tuple
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-expr-list dispatch pools rest)
    [(ResultAstExprList.Ok exprs)
      (ResultAstExpr.Ok
        (ast-node-pool-context-expr-push pools (AstExpr.Tuple exprs)))]
    [(ResultAstExprList.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-array
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-expr-list dispatch pools rest)
    [(ResultAstExprList.Ok exprs)
      (ResultAstExpr.Ok
        (ast-node-pool-context-expr-push pools (AstExpr.Array exprs)))]
    [(ResultAstExprList.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-quote-like
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [tag : i64]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match rest
    [(reader.SpannedSexpr.Cons expr end _)
      (match (reader.sp-node-get end)
        [(reader.SpannedSexpr.Nil _)
          (match (parse-ast-expr-with-pools
            dispatch
            pools
            (reader.sp-node-get expr))
            [(ResultAstExpr.Ok parsed)
              (cond
                [(= tag (compiler-parse-tag-expr-quote))
                  (ResultAstExpr.Ok (ast-expr-quote-with-pools pools parsed))]
                [(= tag (compiler-parse-tag-expr-quasiquote))
                  (ResultAstExpr.Ok
                    (ast-expr-quasiquote-with-pools pools parsed))]
                [(= tag (compiler-parse-tag-expr-unquote))
                  (ResultAstExpr.Ok (ast-expr-unquote-with-pools pools parsed))]
                [else
                  (ResultAstExpr.Ok
                    (ast-expr-unquote-splicing-with-pools pools parsed))])]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [_
          (ResultAstExpr.Err "parse: quote form expects exactly one expression")])]
    [_ (ResultAstExpr.Err "parse: quote form expects exactly one expression")]))

(define (parse-ast-list-expr-tag
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [tag : i64]
  [head : reader.SpannedSexpr]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (cond
    [(= tag (compiler-parse-tag-expr-if)) (parse-ast-if dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-let)) (parse-ast-let dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-lambda))
      (parse-ast-lambda dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-while))
      (parse-ast-while dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-begin))
      (parse-ast-begin dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-unsafe))
      (parse-ast-unsafe dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-set)) (parse-ast-set dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-ann))
      (parse-ast-ann-like dispatch pools false rest)]
    [(= tag (compiler-parse-tag-expr-cast))
      (parse-ast-ann-like dispatch pools true rest)]
    [(= tag (compiler-parse-tag-expr-tuple))
      (parse-ast-tuple dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-tuple-ref))
      (parse-ast-tuple-ref dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-array))
      (parse-ast-array dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-make-array))
      (parse-ast-make-array dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-array-ref))
      (parse-ast-array-ref-like dispatch pools false rest)]
    [(= tag (compiler-parse-tag-expr-array-set))
      (parse-ast-array-set dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-array-push))
      (parse-ast-array-push dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-array-take))
      (parse-ast-array-take dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-match))
      (parse-ast-match dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-foreach))
      (parse-ast-foreach dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-spmd-reduce))
      (parse-ast-spmd-reduce dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-spmd-scan))
      (parse-ast-spmd-scan dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-spmd-broadcast))
      (parse-ast-spmd-broadcast dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-spmd-shuffle))
      (parse-ast-spmd-shuffle dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-spmd-program-index))
      (parse-ast-no-arg-low-level
        rest
        "program-index"
        (ast-expr-spmd-program-index-with-pools pools))]
    [(= tag (compiler-parse-tag-expr-spmd-program-count))
      (parse-ast-no-arg-low-level
        rest
        "program-count"
        (ast-expr-spmd-program-count-with-pools pools))]
    [(= tag (compiler-parse-tag-expr-struct-get))
      (parse-ast-struct-get dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-comptime))
      (parse-ast-comptime dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-type-literal))
      (parse-ast-type-literal dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-with-region))
      (parse-ast-with-region dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-with-escape))
      (parse-ast-with-escape dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-with-scratch))
      (parse-ast-with-scratch dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-in-arena))
      (parse-ast-in-arena dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-with-resource))
      (parse-ast-with-resource dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-quote))
      (parse-ast-quote-like dispatch pools tag rest)]
    [(= tag (compiler-parse-tag-expr-quasiquote))
      (parse-ast-quote-like dispatch pools tag rest)]
    [(= tag (compiler-parse-tag-expr-unquote))
      (parse-ast-quote-like dispatch pools tag rest)]
    [(= tag (compiler-parse-tag-expr-unquote-splicing))
      (parse-ast-quote-like dispatch pools tag rest)]
    [(= tag (compiler-parse-tag-expr-try)) (parse-ast-try dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-return))
      (parse-ast-return dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-break))
      (parse-ast-no-arg-low-level
        rest
        "break"
        (ast-expr-break-with-pools pools))]
    [(= tag (compiler-parse-tag-expr-continue))
      (parse-ast-no-arg-low-level
        rest
        "continue"
        (ast-expr-continue-with-pools pools))]
    [(= tag (compiler-parse-tag-expr-box))
      (parse-ast-box-like dispatch pools rest false false)]
    [(= tag (compiler-parse-tag-expr-box-get))
      (parse-ast-box-like dispatch pools rest true false)]
    [(= tag (compiler-parse-tag-expr-box-take))
      (parse-ast-box-like dispatch pools rest false true)]
    [(= tag (compiler-parse-tag-expr-string-data))
      (parse-ast-string-data dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-string-from-bytes))
      (parse-ast-string-from-bytes dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-array-data))
      (parse-ast-array-data dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-program-argc))
      (parse-ast-no-arg-low-level
        rest
        "program-argc"
        (ast-node-pool-context-expr-push pools (AstExpr.ProgramArgc)))]
    [(= tag (compiler-parse-tag-expr-program-argv))
      (parse-ast-no-arg-low-level
        rest
        "program-argv"
        (ast-node-pool-context-expr-push pools (AstExpr.ProgramArgv)))]
    [(= tag (compiler-parse-tag-expr-program-envp))
      (parse-ast-no-arg-low-level
        rest
        "program-envp"
        (ast-node-pool-context-expr-push pools (AstExpr.ProgramEnvp)))]
    [(= tag (compiler-parse-tag-expr-cpuid-eax))
      (parse-ast-cpuid-like dispatch pools tag rest)]
    [(= tag (compiler-parse-tag-expr-cpuid-ebx))
      (parse-ast-cpuid-like dispatch pools tag rest)]
    [(= tag (compiler-parse-tag-expr-cpuid-ecx))
      (parse-ast-cpuid-like dispatch pools tag rest)]
    [(= tag (compiler-parse-tag-expr-cpuid-edx))
      (parse-ast-cpuid-like dispatch pools tag rest)]
    [(= tag (compiler-parse-tag-expr-xgetbv))
      (parse-ast-xgetbv dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-syscall))
      (parse-ast-syscall dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-init))
      (parse-ast-init dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-ptr-null))
      (parse-ast-ptr-null dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-ptr-null-check))
      (parse-ast-ptr-null-check dispatch pools rest)]
    [else (parse-ast-call dispatch pools head rest)]))

(define (parse-ast-list-expr
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [head : reader.SpannedSexpr]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match head
    [(reader.SpannedSexpr.Sym op _)
      (cond
        [(= op (cbi.compiler-builtin-ctfe-ref 213))
          (parse-ast-internal-binary-data pools rest)]
        [(=
            (compiler-parse-dispatch-tag dispatch op)
            (compiler-parse-tag-expr-init))
          (match rest
            [(reader.SpannedSexpr.Cons first _ _)
              (if (sexpr-colon?
                (reader.spanned-sexpr-form (reader.sp-node-get first)))
                (parse-ast-init dispatch pools rest)
                (parse-ast-call dispatch pools head rest))]
            [(reader.SpannedSexpr.Nil _) (parse-ast-init dispatch pools rest)]
            [_ (parse-ast-call dispatch pools head rest)])]
        [else
          (let
            [tag : i64 (compiler-parse-dispatch-tag dispatch op)]
            (cond
              [(= tag (compiler-parse-tag-expr-ptr-addr-of))
                (parse-ast-ptr-addr-of dispatch pools rest)]
              [(= tag (compiler-parse-tag-expr-ptr-read))
                (parse-ast-ptr-read dispatch pools rest)]
              [(= tag (compiler-parse-tag-expr-ptr-write))
                (parse-ast-ptr-write dispatch pools rest)]
              [(= tag (compiler-parse-tag-expr-ptr-offset))
                (parse-ast-ptr-offset dispatch pools rest)]
              [(= tag (compiler-parse-tag-expr-ptr-cast))
                (parse-ast-ptr-cast-like dispatch pools false rest)]
              [(= tag (compiler-parse-tag-expr-ptr-to-int))
                (parse-ast-ptr-to-int dispatch pools rest)]
              [(= tag (compiler-parse-tag-expr-int-to-ptr))
                (parse-ast-ptr-cast-like dispatch pools true rest)]
              [(ast-unop-tag? tag)
                (parse-ast-unary dispatch pools (ast-unop-from-tag tag) rest)]
              [(ast-binop-tag? tag)
                (if (ast-left-fold-binop-tag? tag)
                  (parse-ast-binary-left-fold
                    dispatch
                    pools
                    (ast-binop-from-tag tag)
                    rest)
                  (parse-ast-binary
                    dispatch
                    pools
                    (ast-binop-from-tag tag)
                    rest))]
              [(= tag (compiler-parse-tag-ty-ref))
                (parse-ast-borrow dispatch pools false rest)]
              [(= tag (compiler-parse-tag-ty-mut-ref))
                (parse-ast-borrow dispatch pools true rest)]
              [else
                (if (parse-ast-removed-declaration-name? op)
                  (ResultAstExpr.Err (parse-ast-removed-declaration-message))
                  (parse-ast-list-expr-tag dispatch pools tag head rest))]))])]
    [_ (parse-ast-call dispatch pools head rest)]))

(define (parse-ast-expr-with-pools
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.SpannedSexpr]) : ResultAstExpr
  (let
    [result : ResultAstExpr
      (match s
        [(reader.SpannedSexpr.Int n text _)
          (ResultAstExpr.Ok
            (ast-expr-wrap-span
              pools
              (ast-node-pool-context-expr-push
                pools
                (AstExpr.Literal (AstLiteral.Int n text)))
              s))]
        [(reader.SpannedSexpr.Float text _)
          (ResultAstExpr.Ok
            (ast-expr-wrap-span
              pools
              (ast-node-pool-context-expr-push
                pools
                (AstExpr.Literal (AstLiteral.Float text)))
              s))]
        [(reader.SpannedSexpr.Str string-id _)
          (ResultAstExpr.Ok
            (ast-expr-wrap-span
              pools
              (ast-node-pool-context-expr-push
                pools
                (AstExpr.Literal (AstLiteral.String string-id)))
              s))]
        [(reader.SpannedSexpr.Char c _)
          (ResultAstExpr.Ok
            (ast-expr-wrap-span
              pools
              (ast-node-pool-context-expr-push
                pools
                (AstExpr.Literal (AstLiteral.Char c)))
              s))]
        [(reader.SpannedSexpr.Sym name _)
          (let
            [name-id : i64 name]
            [tag : i64 (compiler-parse-dispatch-tag-id dispatch name-id)]
            (cond
              [(= tag (compiler-parse-tag-lit-true))
                (ResultAstExpr.Ok
                  (ast-expr-wrap-span
                    pools
                    (ast-node-pool-context-expr-push
                      pools
                      (AstExpr.Literal (AstLiteral.Bool true)))
                    s))]
              [(= tag (compiler-parse-tag-lit-false))
                (ResultAstExpr.Ok
                  (ast-expr-wrap-span
                    pools
                    (ast-node-pool-context-expr-push
                      pools
                      (AstExpr.Literal (AstLiteral.Bool false)))
                    s))]
              [(= tag (compiler-parse-tag-unit))
                (ResultAstExpr.Ok
                  (ast-expr-wrap-span
                    pools
                    (ast-node-pool-context-expr-push
                      pools
                      (AstExpr.Literal AstLiteral.Unit))
                    s))]
              [else
                (ResultAstExpr.Ok
                  (ast-expr-wrap-span
                    pools
                    (ast-node-pool-context-expr-push
                      pools
                      (AstExpr.Var name-id))
                    s))]))]
        [(reader.SpannedSexpr.Cons head rest _)
          (match (reader.sp-node-get head)
            [(reader.SpannedSexpr.Sym op _)
              (if (= op (cbi.compiler-builtin-ctfe-ref 243))
                (match (parse-ast-cfg-expr
                  dispatch
                  pools
                  (reader.sp-node-get rest))
                  [(ResultAstExpr.Ok parsed)
                    (ResultAstExpr.Ok (ast-expr-wrap-span pools parsed s))]
                  [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])
                (match (parse-ast-list-expr
                  dispatch
                  pools
                  (reader.sp-node-get head)
                  (reader.sp-node-get rest))
                  [(ResultAstExpr.Ok parsed)
                    (ResultAstExpr.Ok (ast-expr-wrap-span pools parsed s))]
                  [(ResultAstExpr.Err message) (ResultAstExpr.Err message)]))]
            [_
              (match (parse-ast-list-expr
                dispatch
                pools
                (reader.sp-node-get head)
                (reader.sp-node-get rest))
                [(ResultAstExpr.Ok parsed)
                  (ResultAstExpr.Ok (ast-expr-wrap-span pools parsed s))]
                [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])])]
        [_ (ResultAstExpr.Err "parse: malformed expression")])]
    (parse-ast-error-span-note-expr dispatch s result)))

(define (parse-ast-expr
  [dispatch : sym_i64_env.SymI64Env]
  [s : reader.SpannedSexpr]) : ResultAstExpr
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [result : ResultAstExpr (parse-ast-expr-with-pools dispatch pools s)]
    (begin
      (ast-node-pool-context-install! pools)
      result)))

(define (parse-ast-define-value
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [name : i64]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match rest
    [(reader.SpannedSexpr.Cons first tail _)
      (match (reader.sp-node-get tail)
        [(reader.SpannedSexpr.Nil _)
          (match (parse-ast-expr-with-pools
            dispatch
            pools
            (reader.sp-node-get first))
            [(ResultAstExpr.Ok parsed-value)
              (ResultAstDecl.Ok
                (ast-decl-def-id name AstMaybeType.No parsed-value))]
            [(ResultAstExpr.Err message) (ResultAstDecl.Err message)])]
        [(reader.SpannedSexpr.Cons ty value-tail _)
          (match (reader.sp-node-get value-tail)
            [(reader.SpannedSexpr.Cons value end _)
              (match (reader.sp-node-get end)
                [(reader.SpannedSexpr.Nil _)
                  (if (sexpr-colon?
                    (reader.spanned-sexpr-form (reader.sp-node-get first)))
                    (match (parse-ast-type-spanned
                      dispatch
                      pools
                      (reader.sp-node-get ty))
                      [(ResultAstType.Ok parsed-ty)
                        (match (parse-ast-expr-with-pools
                          dispatch
                          pools
                          (reader.sp-node-get value))
                          [(ResultAstExpr.Ok parsed-value)
                            (ResultAstDecl.Ok
                              (ast-decl-def-id
                                name
                                (AstMaybeType.Some parsed-ty)
                                parsed-value))]
                          [(ResultAstExpr.Err message)
                            (ResultAstDecl.Err message)])]
                      [(ResultAstType.Err message) (ResultAstDecl.Err message)])
                    (ResultAstDecl.Err "parse: expected ':' in definition"))]
                [_ (ResultAstDecl.Err "parse: malformed value definition")])]
            [_ (ResultAstDecl.Err "parse: malformed value definition")])]
        [_ (ResultAstDecl.Err "parse: malformed value definition")])]
    [_ (ResultAstDecl.Err "parse: malformed value definition")]))

(define (parse-ast-spmd-param-classes
  [items : reader.Sexpr]
  [out : AstSpmdParamClassList]) : ResultAstSpmdParamClassList
  (match items
    [(reader.Sexpr.Nil) (ResultAstSpmdParamClassList.Ok out)]
    [(reader.Sexpr.Cons head rest)
      (match (box-get head)
        [(reader.Sexpr.Sym name)
          (let
            [next : AstSpmdParamClassList out]
            (if (= name (cbi.compiler-builtin-ctfe-ref 244))
              (begin
                (ast-spmd-param-class-list-push
                  (&mut next)
                  AstSpmdParamClass.Uniform)
                (parse-ast-spmd-param-classes (box-get rest) next))
              (if (= name (cbi.compiler-builtin-ctfe-ref 245))
                (begin
                  (ast-spmd-param-class-list-push
                    (&mut next)
                    AstSpmdParamClass.Varying)
                  (parse-ast-spmd-param-classes (box-get rest) next))
                (ResultAstSpmdParamClassList.Err
                  "parse: :spmd-callable args expects only uniform or varying"))))]
        [_
          (ResultAstSpmdParamClassList.Err
            "parse: :spmd-callable args expects only uniform or varying")])]
    [_
      (ResultAstSpmdParamClassList.Err
        "parse: malformed :spmd-callable args field")]))

(define (parse-ast-spmd-result-class [tail : reader.Sexpr]) : ResultAstSpmdResultClass
  (match tail
    [(reader.Sexpr.Cons head rest)
      (match (box-get rest)
        [(reader.Sexpr.Nil)
          (match (box-get head)
            [(reader.Sexpr.Sym name)
              (cond
                [(= name (cbi.compiler-builtin-ctfe-ref 173))
                  (ResultAstSpmdResultClass.Ok AstSpmdResultClass.Unit)]
                [(= name (cbi.compiler-builtin-ctfe-ref 244))
                  (ResultAstSpmdResultClass.Ok AstSpmdResultClass.Uniform)]
                [(= name (cbi.compiler-builtin-ctfe-ref 245))
                  (ResultAstSpmdResultClass.Ok AstSpmdResultClass.Varying)]
                [else
                  (ResultAstSpmdResultClass.Err
                    "parse: :spmd-callable result expects unit, uniform, or varying")])]
            [_
              (ResultAstSpmdResultClass.Err
                "parse: :spmd-callable result expects unit, uniform, or varying")])]
        [_
          (ResultAstSpmdResultClass.Err
            "parse: :spmd-callable result expects one value")])]
    [_
      (ResultAstSpmdResultClass.Err
        "parse: malformed :spmd-callable result field")]))

(define (parse-ast-spmd-index-param [tail : reader.Sexpr]) : ResultAstSpmdIndexParam
  (match tail
    [(reader.Sexpr.Cons head rest)
      (match (box-get rest)
        [(reader.Sexpr.Nil)
          (match (box-get head)
            [(reader.Sexpr.Sym name)
              (if (= name (cbi.compiler-builtin-ctfe-ref 246))
                (ResultAstSpmdIndexParam.Ok -1)
                (ResultAstSpmdIndexParam.Err
                  "parse: :spmd-callable index-param expects none or a non-negative integer"))]
            [(reader.Sexpr.Int value _)
              (if (>= value 0)
                (ResultAstSpmdIndexParam.Ok value)
                (ResultAstSpmdIndexParam.Err
                  "parse: :spmd-callable index-param expects none or a non-negative integer"))]
            [_
              (ResultAstSpmdIndexParam.Err
                "parse: :spmd-callable index-param expects none or a non-negative integer")])]
        [_
          (ResultAstSpmdIndexParam.Err
            "parse: :spmd-callable index-param expects one value")])]
    [_
      (ResultAstSpmdIndexParam.Err
        "parse: malformed :spmd-callable index-param field")]))

(define (parse-ast-spmd-specialization-fields
  [fields : reader.Sexpr]
  [state : AstSpmdSpecializationParseState]) : ResultAstSpmdSpecializationParseState
  (match fields
    [(reader.Sexpr.Nil) (ResultAstSpmdSpecializationParseState.Ok state)]
    [(reader.Sexpr.Cons field-node rest)
      (match (box-get field-node)
        [(reader.Sexpr.Cons key-node value-tail)
          (match (box-get key-node)
            [(reader.Sexpr.Sym key)
              (cond
                [(= key (cbi.compiler-builtin-ctfe-ref 247))
                  (if (struct-get state seen-lanes)
                    (ResultAstSpmdSpecializationParseState.Err
                      "parse: duplicate :spmd-callable lanes field")
                    (match (box-get value-tail)
                      [(reader.Sexpr.Cons value-node end)
                        (match (box-get end)
                          [(reader.Sexpr.Nil)
                            (match (box-get value-node)
                              [(reader.Sexpr.Int lanes _)
                                (if (> lanes 1)
                                  (parse-ast-spmd-specialization-fields
                                    (box-get rest)
                                    (AstSpmdSpecializationParseState
                                      lanes
                                      (struct-get state args)
                                      (struct-get state result)
                                      (struct-get state index-param)
                                      true
                                      (struct-get state seen-args)
                                      (struct-get state seen-result)
                                      (struct-get state seen-index-param)))
                                  (ResultAstSpmdSpecializationParseState.Err
                                    "parse: :spmd-callable lanes must be greater than one"))]
                              [_
                                (ResultAstSpmdSpecializationParseState.Err
                                  "parse: :spmd-callable lanes expects one integer")])]
                          [_
                            (ResultAstSpmdSpecializationParseState.Err
                              "parse: :spmd-callable lanes expects one integer")])]
                      [_
                        (ResultAstSpmdSpecializationParseState.Err
                          "parse: :spmd-callable lanes expects one integer")]))]
                [(= key (cbi.compiler-builtin-ctfe-ref 248))
                  (if (struct-get state seen-args)
                    (ResultAstSpmdSpecializationParseState.Err
                      "parse: duplicate :spmd-callable args field")
                    (match (parse-ast-spmd-param-classes
                      (box-get value-tail)
                      (ast-spmd-param-class-list-new))
                      [(ResultAstSpmdParamClassList.Err message)
                        (ResultAstSpmdSpecializationParseState.Err message)]
                      [(ResultAstSpmdParamClassList.Ok args)
                        (parse-ast-spmd-specialization-fields
                          (box-get rest)
                          (AstSpmdSpecializationParseState
                            (struct-get state lanes)
                            args
                            (struct-get state result)
                            (struct-get state index-param)
                            (struct-get state seen-lanes)
                            true
                            (struct-get state seen-result)
                            (struct-get state seen-index-param)))]))]
                [(= key (cbi.compiler-builtin-ctfe-ref 249))
                  (if (struct-get state seen-result)
                    (ResultAstSpmdSpecializationParseState.Err
                      "parse: duplicate :spmd-callable result field")
                    (match (parse-ast-spmd-result-class (box-get value-tail))
                      [(ResultAstSpmdResultClass.Err message)
                        (ResultAstSpmdSpecializationParseState.Err message)]
                      [(ResultAstSpmdResultClass.Ok result)
                        (parse-ast-spmd-specialization-fields
                          (box-get rest)
                          (AstSpmdSpecializationParseState
                            (struct-get state lanes)
                            (struct-get state args)
                            result
                            (struct-get state index-param)
                            (struct-get state seen-lanes)
                            (struct-get state seen-args)
                            true
                            (struct-get state seen-index-param)))]))]
                [(= key (cbi.compiler-builtin-ctfe-ref 250))
                  (if (struct-get state seen-index-param)
                    (ResultAstSpmdSpecializationParseState.Err
                      "parse: duplicate :spmd-callable index-param field")
                    (match (parse-ast-spmd-index-param (box-get value-tail))
                      [(ResultAstSpmdIndexParam.Err message)
                        (ResultAstSpmdSpecializationParseState.Err message)]
                      [(ResultAstSpmdIndexParam.Ok index-param)
                        (parse-ast-spmd-specialization-fields
                          (box-get rest)
                          (AstSpmdSpecializationParseState
                            (struct-get state lanes)
                            (struct-get state args)
                            (struct-get state result)
                            index-param
                            (struct-get state seen-lanes)
                            (struct-get state seen-args)
                            (struct-get state seen-result)
                            true))]))]
                [else
                  (ResultAstSpmdSpecializationParseState.Err
                    (string.append
                      "parse: unknown :spmd-callable specialization field "
                      (compiler-parse-name-text key)))])]
            [_
              (ResultAstSpmdSpecializationParseState.Err
                "parse: malformed :spmd-callable specialization field")])]
        [_
          (ResultAstSpmdSpecializationParseState.Err
            "parse: malformed :spmd-callable specialization field")])]
    [_
      (ResultAstSpmdSpecializationParseState.Err
        "parse: malformed :spmd-callable specialization")]))

(define (parse-ast-spmd-specialization
  [tail : reader.Sexpr]
  [param-count : i64]) : ResultAstSpmdSpecialization
  (match (parse-ast-spmd-specialization-fields
    tail
    (AstSpmdSpecializationParseState
      0
      (ast-spmd-param-class-list-new)
      AstSpmdResultClass.Unit
      -1
      false
      false
      false
      false))
    [(ResultAstSpmdSpecializationParseState.Err message)
      (ResultAstSpmdSpecialization.Err message)]
    [(ResultAstSpmdSpecializationParseState.Ok state)
      (cond
        [(not (struct-get state seen-lanes))
          (ResultAstSpmdSpecialization.Err
            "parse: :spmd-callable specialization is missing lanes")]
        [(not (struct-get state seen-args))
          (ResultAstSpmdSpecialization.Err
            "parse: :spmd-callable specialization is missing args")]
        [(not (struct-get state seen-result))
          (ResultAstSpmdSpecialization.Err
            "parse: :spmd-callable specialization is missing result")]
        [(not (struct-get state seen-index-param))
          (ResultAstSpmdSpecialization.Err
            "parse: :spmd-callable specialization is missing index-param")]
        [(not
            (=
              (ast-spmd-param-class-list-len (& (struct-get state args)))
              param-count))
          (ResultAstSpmdSpecialization.Err
            "parse: :spmd-callable args must contain one class per ordinary parameter")]
        [(>= (struct-get state index-param) param-count)
          (ResultAstSpmdSpecialization.Err
            "parse: :spmd-callable index-param is outside the parameter list")]
        [else
          (ResultAstSpmdSpecialization.Ok
            (AstSpmdSpecialization
              (struct-get state lanes)
              (box (struct-get state args))
              (struct-get state result)
              (struct-get state index-param)))])]))

(define (parse-ast-spmd-param-classes-eq-at?
  [left : (& left AstSpmdParamClassList)]
  [right : (& right AstSpmdParamClassList)]
  [index : i64]) : bool
  (if (>= index (ast-spmd-param-class-list-len left))
    (=
      (ast-spmd-param-class-list-len left)
      (ast-spmd-param-class-list-len right))
    (and
      (< index (ast-spmd-param-class-list-len right))
      (match (ast-spmd-param-class-list-get
        left
        index
        AstSpmdParamClass.Uniform)
        [(AstSpmdParamClass.Uniform)
          (match (ast-spmd-param-class-list-get
            right
            index
            AstSpmdParamClass.Varying)
            [(AstSpmdParamClass.Uniform)
              (parse-ast-spmd-param-classes-eq-at? left right (+ index 1))]
            [_ false])]
        [(AstSpmdParamClass.Varying)
          (match (ast-spmd-param-class-list-get
            right
            index
            AstSpmdParamClass.Uniform)
            [(AstSpmdParamClass.Varying)
              (parse-ast-spmd-param-classes-eq-at? left right (+ index 1))]
            [_ false])]))))

(define (parse-ast-spmd-specialization-eq?
  [left : AstSpmdSpecialization]
  [right : AstSpmdSpecialization]) : bool
  (and
    (= (struct-get left lanes) (struct-get right lanes))
    (= (struct-get left result) (struct-get right result))
    (= (struct-get left index-param) (struct-get right index-param))
    (parse-ast-spmd-param-classes-eq-at?
      (& (box-get (struct-get left args)))
      (& (box-get (struct-get right args)))
      0)))

(define (parse-ast-spmd-specialization-present-at?
  [items : (& items AstSpmdSpecializationList)]
  [wanted : AstSpmdSpecialization]
  [index : i64]) : bool
  (if (>= index (ast-spmd-specialization-list-len items))
    false
    (if (parse-ast-spmd-specialization-eq?
      (ast-spmd-specialization-list-get items index wanted)
      wanted)
      true
      (parse-ast-spmd-specialization-present-at? items wanted (+ index 1)))))

(define (parse-ast-spmd-specializations
  [items : reader.Sexpr]
  [param-count : i64]
  [out : AstSpmdSpecializationList]) : ResultAstSpmdCallable
  (match items
    [(reader.Sexpr.Nil)
      (if (= (ast-spmd-specialization-list-len (& out)) 0)
        (ResultAstSpmdCallable.Err
          "parse: :spmd-callable expects at least one specialization")
        (ResultAstSpmdCallable.Ok (AstSpmdCallable.Callable out)))]
    [(reader.Sexpr.Cons item-node rest)
      (match (box-get item-node)
        [(reader.Sexpr.Cons name-node fields)
          (match (box-get name-node)
            [(reader.Sexpr.Sym name)
              (if (= name (cbi.compiler-builtin-ctfe-ref 251))
                (match (parse-ast-spmd-specialization
                  (box-get fields)
                  param-count)
                  [(ResultAstSpmdSpecialization.Err message)
                    (ResultAstSpmdCallable.Err message)]
                  [(ResultAstSpmdSpecialization.Ok specialization)
                    (if (parse-ast-spmd-specialization-present-at?
                      (& out)
                      specialization
                      0)
                      (ResultAstSpmdCallable.Err
                        "parse: duplicate :spmd-callable specialization")
                      (let
                        [next : AstSpmdSpecializationList out]
                        (begin
                          (ast-spmd-specialization-list-push
                            (&mut next)
                            specialization)
                          (parse-ast-spmd-specializations
                            (box-get rest)
                            param-count
                            next))))])
                (ResultAstSpmdCallable.Err
                  "parse: :spmd-callable expects specialization forms"))]
            [_
              (ResultAstSpmdCallable.Err
                "parse: malformed :spmd-callable specialization")])]
        [_
          (ResultAstSpmdCallable.Err
            "parse: malformed :spmd-callable specialization")])]
    [_ (ResultAstSpmdCallable.Err "parse: malformed :spmd-callable metadata")]))

(define (parse-ast-define-fn-spmd-callable-tail
  [tail : reader.Sexpr]
  [param-count : i64]) : ResultAstSpmdCallable
  (parse-ast-spmd-specializations
    tail
    param-count
    (ast-spmd-specialization-list-new)))

(define (parse-ast-define-fn-export-tail [tail : reader.Sexpr]) : ResultAstFnExport
  (match tail
    [(reader.Sexpr.Cons value-node end)
      (match (box-get end)
        [(reader.Sexpr.Nil)
          (match (box-get value-node)
            [(reader.Sexpr.Str value-id)
              (if (> (string.string-length (ci.intern-str value-id)) 0)
                (ResultAstFnExport.Ok (ast-fn-export-id value-id))
                (ResultAstFnExport.Err
                  "parse: define :export-symbol must not be empty"))]
            [_
              (ResultAstFnExport.Err
                "parse: malformed define :export-symbol metadata")])]
        [_
          (ResultAstFnExport.Err
            "parse: malformed define :export-symbol metadata")])]
    [_
      (ResultAstFnExport.Err "parse: malformed define :export-symbol metadata")]))

(define (parse-ast-define-fn-metadata? [item : reader.SpannedSexpr]) : bool
  (match (reader.spanned-sexpr-form item)
    [(reader.Sexpr.Cons key-node _)
      (match (box-get key-node)
        [(reader.Sexpr.Sym key) (compiler-parse-metadata-key? key)]
        [_ false])]
    [_ false]))

(define (parse-ast-define-fn-finish
  [name : i64]
  [params : AstParamList]
  [ret : AstType]
  [body : i64]
  [export : AstFnExport]
  [spmd-callable : AstSpmdCallable]) : ResultAstDecl
  (if (and
    (match export
      [(AstFnExport.Export _) true]
      [_ false])
    (match spmd-callable
      [(AstSpmdCallable.Callable _) true]
      [_ false]))
    (ResultAstDecl.Err
      "parse: define :spmd-callable cannot be combined with :export-symbol")
    (if (ast-param-list-has-comptime? params)
      (match export
        [(AstFnExport.Export _)
          (ResultAstDecl.Err
            "parse: define :export-symbol cannot be used on functions with comptime parameters")]
        [(AstFnExport.No)
          (match spmd-callable
            [(AstSpmdCallable.No)
              (ResultAstDecl.Ok
                (ast-decl-def-fn-metadata-id
                  name
                  params
                  ret
                  body
                  (ast-fn-metadata-full export spmd-callable)))]
            [(AstSpmdCallable.Callable _)
              (ResultAstDecl.Err
                "parse: define :spmd-callable cannot be used on functions with comptime parameters")])])
      (ResultAstDecl.Ok
        (ast-decl-def-fn-metadata-id
          name
          params
          ret
          body
          (ast-fn-metadata-full export spmd-callable))))))

(define (parse-ast-define-fn-rest
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [name : i64]
  [params : AstParamList]
  [export : AstFnExport]
  [seen-export : bool]
  [spmd-callable : AstSpmdCallable]
  [seen-spmd-callable : bool]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match rest
    [(reader.SpannedSexpr.Cons first tail _)
      (if (sexpr-colon? (reader.spanned-sexpr-form (reader.sp-node-get first)))
        (match (reader.sp-node-get tail)
          [(reader.SpannedSexpr.Cons ret body-tail _)
            (match (parse-ast-type-spanned
              dispatch
              pools
              (reader.sp-node-get ret))
              [(ResultAstType.Ok parsed-ret)
                (match (parse-ast-body-tail
                  dispatch
                  pools
                  (reader.sp-node-get body-tail)
                  "parse: malformed function definition")
                  [(ResultAstExpr.Ok parsed-body)
                    (parse-ast-define-fn-finish
                      name
                      params
                      parsed-ret
                      parsed-body
                      export
                      spmd-callable)]
                  [(ResultAstExpr.Err message) (ResultAstDecl.Err message)])]
              [(ResultAstType.Err message) (ResultAstDecl.Err message)])]
          [_ (ResultAstDecl.Err "parse: malformed function definition")])
        (if (parse-ast-define-fn-metadata? (reader.sp-node-get first))
          (match (reader.spanned-sexpr-form (reader.sp-node-get first))
            [(reader.Sexpr.Cons key-node after-key)
              (match (box-get key-node)
                [(reader.Sexpr.Sym key)
                  (cond
                    [(= key (cbi.compiler-builtin-ctfe-ref 252))
                      (if seen-export
                        (ResultAstDecl.Err
                          "parse: duplicate define :export-symbol metadata")
                        (match (parse-ast-define-fn-export-tail
                          (box-get after-key))
                          [(ResultAstFnExport.Ok parsed-export)
                            (parse-ast-define-fn-rest
                              dispatch
                              pools
                              name
                              params
                              parsed-export
                              true
                              spmd-callable
                              seen-spmd-callable
                              (reader.sp-node-get tail))]
                          [(ResultAstFnExport.Err message)
                            (ResultAstDecl.Err message)]))]
                    [(= key (cbi.compiler-builtin-ctfe-ref 253))
                      (if seen-spmd-callable
                        (ResultAstDecl.Err
                          "parse: duplicate define :spmd-callable metadata")
                        (match (parse-ast-define-fn-spmd-callable-tail
                          (box-get after-key)
                          (ast-param-list-len (& params)))
                          [(ResultAstSpmdCallable.Ok parsed-callable)
                            (parse-ast-define-fn-rest
                              dispatch
                              pools
                              name
                              params
                              export
                              seen-export
                              parsed-callable
                              true
                              (reader.sp-node-get tail))]
                          [(ResultAstSpmdCallable.Err message)
                            (ResultAstDecl.Err message)]))]
                    [(compiler-parse-metadata-key? key)
                      (ResultAstDecl.Err
                        (string.append
                          "parse: unknown define metadata "
                          (compiler-parse-name-text key)))]
                    [else
                      (ResultAstDecl.Err "parse: malformed function metadata")])]
                [_ (ResultAstDecl.Err "parse: malformed function definition")])]
            [_ (ResultAstDecl.Err "parse: malformed function definition")])
          (match (parse-ast-body-tail
            dispatch
            pools
            rest
            "parse: malformed function definition")
            [(ResultAstExpr.Ok parsed-body)
              (parse-ast-define-fn-finish
                name
                params
                (AstType.Unit)
                parsed-body
                export
                spmd-callable)]
            [(ResultAstExpr.Err message) (ResultAstDecl.Err message)])))]
    [_ (ResultAstDecl.Err "parse: malformed function definition")]))

(define (parse-ast-define-fn
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [name : i64]
  [params : reader.SpannedSexpr]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match (parse-ast-param-list
    dispatch
    pools
    (reader.spanned-sexpr-form params))
    [(ResultAstParamList.Ok parsed-params)
      (parse-ast-define-fn-rest
        dispatch
        pools
        name
        parsed-params
        AstFnExport.No
        false
        AstSpmdCallable.No
        false
        rest)]
    [(ResultAstParamList.Err message) (ResultAstDecl.Err message)]))

(define (parse-ast-define
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match rest
    [(reader.SpannedSexpr.Cons head after-name _)
      (match (reader.sp-node-get head)
        [(reader.SpannedSexpr.Sym name _)
          (parse-ast-define-value
            dispatch
            pools
            name
            (reader.sp-node-get after-name))]
        [(reader.SpannedSexpr.Cons name-node params _)
          (match (reader.sp-node-get name-node)
            [(reader.SpannedSexpr.Sym name _)
              (parse-ast-define-fn
                dispatch
                pools
                name
                (reader.sp-node-get params)
                (reader.sp-node-get after-name))]
            [_ (ResultAstDecl.Err "parse: malformed define")])]
        [_ (ResultAstDecl.Err "parse: malformed define")])]
    [_ (ResultAstDecl.Err "parse: malformed define")]))

(define (parse-ast-defmacro
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match rest
    [(reader.SpannedSexpr.Cons header after-header _)
      (match (reader.sp-node-get header)
        [(reader.SpannedSexpr.Cons name-node params _)
          (match (reader.sp-node-get name-node)
            [(reader.SpannedSexpr.Sym name _)
              (match (reader.sp-node-get after-header)
                [(reader.SpannedSexpr.Cons colon ret-tail _)
                  (match (reader.sp-node-get ret-tail)
                    [(reader.SpannedSexpr.Cons ret body-tail _)
                      (match (reader.sp-node-get body-tail)
                        [(reader.SpannedSexpr.Cons body end _)
                          (match (reader.sp-node-get end)
                            [(reader.SpannedSexpr.Nil _)
                              (if (sexpr-colon?
                                (reader.spanned-sexpr-form
                                  (reader.sp-node-get colon)))
                                (match (parse-ast-macro-param-list
                                  dispatch
                                  pools
                                  (reader.spanned-sexpr-form
                                    (reader.sp-node-get params)))
                                  [(ResultAstMacroParamList.Ok parsed-params)
                                    (match (parse-ast-type-spanned
                                      dispatch
                                      pools
                                      (reader.sp-node-get ret))
                                      [(ResultAstType.Ok parsed-ret)
                                        (match (parse-ast-expr-with-pools
                                          dispatch
                                          pools
                                          (reader.sp-node-get body))
                                          [(ResultAstExpr.Ok parsed-body)
                                            (ResultAstDecl.Ok
                                              (ast-decl-def-macro-id
                                                name
                                                parsed-params
                                                parsed-ret
                                                parsed-body))]
                                          [(ResultAstExpr.Err message)
                                            (ResultAstDecl.Err message)])]
                                      [(ResultAstType.Err message)
                                        (ResultAstDecl.Err message)])]
                                  [(ResultAstMacroParamList.Err message)
                                    (ResultAstDecl.Err message)])
                                (ResultAstDecl.Err
                                  "parse: expected ':' in macro definition"))]
                            [_ (ResultAstDecl.Err "parse: malformed defmacro")])]
                        [_ (ResultAstDecl.Err "parse: malformed defmacro")])]
                    [_ (ResultAstDecl.Err "parse: malformed defmacro")])]
                [_ (ResultAstDecl.Err "parse: malformed defmacro")])]
            [_ (ResultAstDecl.Err "parse: malformed defmacro")])]
        [_ (ResultAstDecl.Err "parse: malformed defmacro")])]
    [_ (ResultAstDecl.Err "parse: malformed defmacro")]))

(define (parse-ast-extern-varargs-typed-name? [name-id : i64]) : bool
  ;; Unlike the fixed open tail `...`, typed tails encode their type in the
  ;; symbol spelling (`...T`) and therefore require this content boundary.
  (let
    [name : String (compiler-parse-name-text name-id)]
    (if (> (string.string-length name) 3)
      (string.eq (string.substring name 0 3) "...")
      false)))

(define (parse-ast-extern-varargs-tail-id [name-id : i64]) : i64
  (let
    [name : String (compiler-parse-name-text name-id)]
    (reader.read-string-symbol-id
      (string.substring name 3 (- (string.string-length name) 3)))))

(define (parse-ast-extern-varargs-open? [name-id : i64]) : bool
  (= name-id (cbi.compiler-builtin-ctfe-ref 222)))

(define (parse-ast-extern-varargs-tail-type
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [name-id : i64]) : ResultAstType
  (if (parse-ast-extern-varargs-typed-name? name-id)
    (parse-ast-type
      dispatch
      pools
      (reader.Sexpr.Sym (parse-ast-extern-varargs-tail-id name-id)))
    (ResultAstType.Err "parse: expected typed extern varargs tail")))

(define (parse-ast-extern-head-fixed-param
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [item : reader.SpannedSexpr]) : ResultAstExternHeadItem
  (match (parse-ast-param dispatch pools (reader.spanned-sexpr-form item))
    [(ResultAstParam.Ok param)
      (match param
        [(AstParam.Param _ ty comptime? consume?)
          (if comptime?
            (ResultAstExternHeadItem.Err
              "parse: extern parameters cannot be comptime")
            (if consume?
              (ResultAstExternHeadItem.Err
                "parse: extern parameters cannot be consuming")
              (ResultAstExternHeadItem.Ok (AstExternHeadItem.Param ty))))])]
    [(ResultAstParam.Err message) (ResultAstExternHeadItem.Err message)]))

(define (parse-ast-extern-head-bracket-item
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [item : reader.SpannedSexpr]
  [items : reader.SpannedSexpr]) : ResultAstExternHeadItem
  (match items
    [(reader.SpannedSexpr.Cons _ after-name _)
      (match (reader.sp-node-get after-name)
        [(reader.SpannedSexpr.Cons colon after-colon _)
          (match (reader.sp-node-get after-colon)
            [(reader.SpannedSexpr.Cons ty-node end _)
              (match (reader.sp-node-get end)
                [(reader.SpannedSexpr.Nil _)
                  (if (sexpr-colon?
                    (reader.spanned-sexpr-form (reader.sp-node-get colon)))
                    (match (reader.sp-node-get ty-node)
                      [(reader.SpannedSexpr.Sym ty-name _)
                        (if (parse-ast-extern-varargs-open? ty-name)
                          (ResultAstExternHeadItem.Err
                            "parse: extern typed varargs tail needs a type")
                          (if (parse-ast-extern-varargs-typed-name? ty-name)
                            (match (parse-ast-extern-varargs-tail-type
                              dispatch
                              pools
                              ty-name)
                              [(ResultAstType.Ok tail-ty)
                                (ResultAstExternHeadItem.Ok
                                  (AstExternHeadItem.VarargsTyped tail-ty))]
                              [(ResultAstType.Err message)
                                (ResultAstExternHeadItem.Err message)])
                            (parse-ast-extern-head-fixed-param
                              dispatch
                              pools
                              item)))]
                      [_
                        (parse-ast-extern-head-fixed-param dispatch pools item)])
                    (parse-ast-extern-head-fixed-param dispatch pools item))]
                [_ (parse-ast-extern-head-fixed-param dispatch pools item)])]
            [_ (parse-ast-extern-head-fixed-param dispatch pools item)])]
        [_ (parse-ast-extern-head-fixed-param dispatch pools item)])]
    [_ (parse-ast-extern-head-fixed-param dispatch pools item)]))

(define (parse-ast-extern-head-item
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [item : reader.SpannedSexpr]) : ResultAstExternHeadItem
  (match item
    [(reader.SpannedSexpr.Sym name _)
      (if (parse-ast-extern-varargs-open? name)
        (ResultAstExternHeadItem.Ok (AstExternHeadItem.VarargsOpen))
        (if (parse-ast-extern-varargs-typed-name? name)
          (ResultAstExternHeadItem.Err
            "parse: typed extern varargs tail must use bracket syntax")
          (ResultAstExternHeadItem.Err "parse: malformed extern function head")))]
    [(reader.SpannedSexpr.BracketList items _)
      (parse-ast-extern-head-bracket-item
        dispatch
        pools
        item
        (reader.sp-node-get items))]
    [_ (ResultAstExternHeadItem.Err "parse: malformed extern function head")]))

(define (parse-ast-extern-head-items
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [items : reader.SpannedSexpr]) : ResultAstExternHeader
  (match items
    [(reader.SpannedSexpr.Nil _)
      (ResultAstExternHeader.Ok -1 (ast-type-list-new) (AstExternAbi.C))]
    [(reader.SpannedSexpr.Cons item tail _)
      (let
        [item : reader.SpannedSexpr (reader.sp-node-get item)]
        [tail : reader.SpannedSexpr (reader.sp-node-get tail)]
        (match (parse-ast-extern-head-item dispatch pools item)
          [(ResultAstExternHeadItem.Ok parsed-item)
            (match parsed-item
              [(AstExternHeadItem.Param ty)
                (match (parse-ast-extern-head-items dispatch pools tail)
                  [(ResultAstExternHeader.Ok _ parsed-tail parsed-abi)
                    (ResultAstExternHeader.Ok
                      -1
                      (ast-type-cons-with-pools pools ty parsed-tail)
                      parsed-abi)]
                  [(ResultAstExternHeader.Err message)
                    (ResultAstExternHeader.Err message)])]
              [(AstExternHeadItem.VarargsOpen)
                (match tail
                  [(reader.SpannedSexpr.Nil _)
                    (ResultAstExternHeader.Ok
                      -1
                      (ast-type-list-new)
                      (AstExternAbi.CVarargsOpen))]
                  [_
                    (ResultAstExternHeader.Err
                      "parse: extern varargs tail must be final")])]
              [(AstExternHeadItem.VarargsTyped tail-ty)
                (match tail
                  [(reader.SpannedSexpr.Nil _)
                    (ResultAstExternHeader.Ok
                      -1
                      (ast-type-list-new)
                      (AstExternAbi.CVarargsTyped tail-ty))]
                  [_
                    (ResultAstExternHeader.Err
                      "parse: extern varargs tail must be final")])])]
          [(ResultAstExternHeadItem.Err message)
            (ResultAstExternHeader.Err message)]))]
    [_ (ResultAstExternHeader.Err "parse: malformed extern function head")]))

(define (parse-ast-extern-header
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [head : reader.SpannedSexpr]) : ResultAstExternHeader
  (match head
    [(reader.SpannedSexpr.Cons name-node params _)
      (match (reader.sp-node-get name-node)
        [(reader.SpannedSexpr.Sym name _)
          (match (parse-ast-extern-head-items
            dispatch
            pools
            (reader.sp-node-get params))
            [(ResultAstExternHeader.Ok _ param-types abi)
              (ResultAstExternHeader.Ok name param-types abi)]
            [(ResultAstExternHeader.Err message)
              (ResultAstExternHeader.Err message)])]
        [_ (ResultAstExternHeader.Err "parse: malformed extern function head")])]
    [_ (ResultAstExternHeader.Err "parse: malformed extern function head")]))

(define (parse-ast-extern-c-varargs-legacy-message) : String
  "parse: legacy :abi c-varargs metadata is retired; use function-head ... or ...T varargs")

(define (parse-ast-extern-abi-tail [tail : reader.Sexpr]) : ResultAstExternAbi
  (match tail
    [(reader.Sexpr.Cons name-node rest)
      (match (box-get name-node)
        [(reader.Sexpr.Sym name)
          (match (box-get rest)
            [(reader.Sexpr.Nil)
              (if (= name cbi.compiler-builtin-id-fix-c)
                (ResultAstExternAbi.Ok (AstExternAbi.C))
                (if (= name (cbi.compiler-builtin-ctfe-ref 254))
                  (ResultAstExternAbi.Err
                    (parse-ast-extern-c-varargs-legacy-message))
                  (ResultAstExternAbi.Err
                    (string.append
                      "parse: unknown extern ABI "
                      (compiler-parse-name-text name)))))]
            [(reader.Sexpr.Cons fixed-node end)
              (match (box-get end)
                [(reader.Sexpr.Nil)
                  (match (box-get fixed-node)
                    [(reader.Sexpr.Int _ _)
                      (if (= name (cbi.compiler-builtin-ctfe-ref 254))
                        (ResultAstExternAbi.Err
                          (parse-ast-extern-c-varargs-legacy-message))
                        (ResultAstExternAbi.Err
                          (string.append
                            "parse: unknown extern ABI "
                            (compiler-parse-name-text name))))]
                    [_
                      (ResultAstExternAbi.Err
                        "parse: malformed extern :abi metadata")])]
                [_
                  (ResultAstExternAbi.Err
                    "parse: malformed extern :abi metadata")])]
            [_ (ResultAstExternAbi.Err "parse: malformed extern :abi metadata")])]
        [_ (ResultAstExternAbi.Err "parse: malformed extern :abi metadata")])]
    [_ (ResultAstExternAbi.Err "parse: malformed extern :abi metadata")]))

(define (parse-ast-extern-string-tail [key : String] [tail : reader.Sexpr]) : ResultAstExternSymbol
  (match tail
    [(reader.Sexpr.Cons value-node end)
      (match (box-get end)
        [(reader.Sexpr.Nil)
          (match (box-get value-node)
            [(reader.Sexpr.Str value-id)
              (let
                [value : String (ci.intern-str value-id)]
                (if (> (string.string-length value) 0)
                  (ResultAstExternSymbol.Ok value value-id)
                  (ResultAstExternSymbol.Err
                    (string.append
                      "parse: extern "
                      (string.append key " must not be empty")))))]
            [_
              (ResultAstExternSymbol.Err
                (string.append
                  "parse: malformed extern "
                  (string.append key " metadata")))])]
        [_
          (ResultAstExternSymbol.Err
            (string.append
              "parse: malformed extern "
              (string.append key " metadata")))])]
    [_
      (ResultAstExternSymbol.Err
        (string.append
          "parse: malformed extern "
          (string.append key " metadata")))]))

(define (parse-ast-extern-symbol-tail [tail : reader.Sexpr]) : ResultAstExternSymbol
  (parse-ast-extern-string-tail ":symbol" tail))

(define (parse-ast-extern-abi-combine
  [base : AstExternAbi]
  [parsed : AstExternAbi]) : ResultAstExternAbi
  (if (ast-extern-abi-c-varargs? base)
    (match parsed
      [(AstExternAbi.C) (ResultAstExternAbi.Ok base)]
      [_
        (ResultAstExternAbi.Err
          "parse: extern varargs tail cannot be combined with another ABI")])
    (ResultAstExternAbi.Ok parsed)))

(define (parse-ast-extern-items
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [items : reader.SpannedSexpr]
  [abi : AstExternAbi]
  [symbol-id : i64]
  [link-inputs : (&mut link-inputs AstExternLinkInputList)]
  [seen-abi : bool]
  [seen-symbol : bool]) : ResultAstExternParts
  (match items
    [(reader.SpannedSexpr.Cons head tail _)
      (if (sexpr-colon? (reader.spanned-sexpr-form (reader.sp-node-get head)))
        (match (reader.sp-node-get tail)
          [(reader.SpannedSexpr.Cons ty end _)
            (match (reader.sp-node-get end)
              [(reader.SpannedSexpr.Nil _)
                (match (parse-ast-type-spanned
                  dispatch
                  pools
                  (reader.sp-node-get ty))
                  [(ResultAstType.Ok parsed-ty)
                    (ResultAstExternParts.Ok abi symbol-id seen-abi parsed-ty)]
                  [(ResultAstType.Err message)
                    (ResultAstExternParts.Err message)])]
              [_ (ResultAstExternParts.Err "parse: malformed extern")])]
          [_ (ResultAstExternParts.Err "parse: malformed extern")])
        (match (reader.spanned-sexpr-form (reader.sp-node-get head))
          [(reader.Sexpr.Cons key-node after-key)
            (match (box-get key-node)
              [(reader.Sexpr.Sym key)
                (cond
                  [(= key (cbi.compiler-builtin-ctfe-ref 255))
                    (if seen-abi
                      (ResultAstExternParts.Err
                        "parse: duplicate extern :abi metadata")
                      (match (parse-ast-extern-abi-tail (box-get after-key))
                        [(ResultAstExternAbi.Ok parsed-abi)
                          (parse-ast-extern-items
                            dispatch
                            pools
                            (reader.sp-node-get tail)
                            parsed-abi
                            symbol-id
                            link-inputs
                            true
                            seen-symbol)]
                        [(ResultAstExternAbi.Err message)
                          (ResultAstExternParts.Err message)]))]
                  [(= key (cbi.compiler-builtin-ctfe-ref 256))
                    (if seen-symbol
                      (ResultAstExternParts.Err
                        "parse: duplicate extern :symbol metadata")
                      (match (parse-ast-extern-symbol-tail (box-get after-key))
                        [(ResultAstExternSymbol.Ok _ parsed-symbol-id)
                          (parse-ast-extern-items
                            dispatch
                            pools
                            (reader.sp-node-get tail)
                            abi
                            parsed-symbol-id
                            link-inputs
                            seen-abi
                            true)]
                        [(ResultAstExternSymbol.Err message)
                          (ResultAstExternParts.Err message)]))]
                  [(= key (cbi.compiler-builtin-ctfe-ref 257))
                    (match (parse-ast-extern-string-tail
                      ":link-lib"
                      (box-get after-key))
                      [(ResultAstExternSymbol.Ok value _)
                        (begin
                          (ast-extern-link-input-list-push
                            link-inputs
                            (AstExternLinkInput.Lib value))
                          (parse-ast-extern-items
                            dispatch
                            pools
                            (reader.sp-node-get tail)
                            abi
                            symbol-id
                            link-inputs
                            seen-abi
                            seen-symbol))]
                      [(ResultAstExternSymbol.Err message)
                        (ResultAstExternParts.Err message)])]
                  [(= key (cbi.compiler-builtin-ctfe-ref 258))
                    (match (parse-ast-extern-string-tail
                      ":link-search"
                      (box-get after-key))
                      [(ResultAstExternSymbol.Ok value _)
                        (begin
                          (ast-extern-link-input-list-push
                            link-inputs
                            (AstExternLinkInput.Search value))
                          (parse-ast-extern-items
                            dispatch
                            pools
                            (reader.sp-node-get tail)
                            abi
                            symbol-id
                            link-inputs
                            seen-abi
                            seen-symbol))]
                      [(ResultAstExternSymbol.Err message)
                        (ResultAstExternParts.Err message)])]
                  [(= key (cbi.compiler-builtin-ctfe-ref 259))
                    (match (parse-ast-extern-string-tail
                      ":link-arg"
                      (box-get after-key))
                      [(ResultAstExternSymbol.Ok value _)
                        (begin
                          (ast-extern-link-input-list-push
                            link-inputs
                            (AstExternLinkInput.Arg value))
                          (parse-ast-extern-items
                            dispatch
                            pools
                            (reader.sp-node-get tail)
                            abi
                            symbol-id
                            link-inputs
                            seen-abi
                            seen-symbol))]
                      [(ResultAstExternSymbol.Err message)
                        (ResultAstExternParts.Err message)])]
                  [(compiler-parse-metadata-key? key)
                    (ResultAstExternParts.Err
                      (string.append
                        "parse: unknown extern metadata "
                        (compiler-parse-name-text key)))]
                  [else
                    (ResultAstExternParts.Err "parse: expected ':' in extern")])]
              [_ (ResultAstExternParts.Err "parse: expected ':' in extern")])]
          [_ (ResultAstExternParts.Err "parse: expected ':' in extern")]))]
    [_ (ResultAstExternParts.Err "parse: malformed extern")]))

(define (parse-ast-extern-head-finish
  [pools : AstNodePoolContext]
  [abi : AstExternAbi]
  [symbol-id : i64]
  [seen-abi : bool]
  [param-types : AstTypeList]
  [ret : AstType]) : ResultAstExternParts
  (ResultAstExternParts.Ok
    abi
    symbol-id
    seen-abi
    (ast-ty-func-with-pools pools param-types ret)))

(define (parse-ast-extern-head-post-ret
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [items : reader.SpannedSexpr]
  [abi : AstExternAbi]
  [symbol-id : i64]
  [link-inputs : (&mut link-inputs AstExternLinkInputList)]
  [seen-abi : bool]
  [seen-symbol : bool]
  [param-types : AstTypeList]
  [ret : AstType]) : ResultAstExternParts
  (match items
    [(reader.SpannedSexpr.Nil _)
      (parse-ast-extern-head-finish
        pools
        abi
        symbol-id
        seen-abi
        param-types
        ret)]
    [(reader.SpannedSexpr.Cons head tail _)
      (match (reader.spanned-sexpr-form (reader.sp-node-get head))
        [(reader.Sexpr.Cons key-node after-key)
          (match (box-get key-node)
            [(reader.Sexpr.Sym key)
              (cond
                [(= key (cbi.compiler-builtin-ctfe-ref 255))
                  (if seen-abi
                    (ResultAstExternParts.Err
                      "parse: duplicate extern :abi metadata")
                    (match (parse-ast-extern-abi-tail (box-get after-key))
                      [(ResultAstExternAbi.Ok parsed-abi)
                        (match (parse-ast-extern-abi-combine abi parsed-abi)
                          [(ResultAstExternAbi.Ok combined-abi)
                            (parse-ast-extern-head-post-ret
                              dispatch
                              pools
                              (reader.sp-node-get tail)
                              combined-abi
                              symbol-id
                              link-inputs
                              true
                              seen-symbol
                              param-types
                              ret)]
                          [(ResultAstExternAbi.Err message)
                            (ResultAstExternParts.Err message)])]
                      [(ResultAstExternAbi.Err message)
                        (ResultAstExternParts.Err message)]))]
                [(= key (cbi.compiler-builtin-ctfe-ref 256))
                  (if seen-symbol
                    (ResultAstExternParts.Err
                      "parse: duplicate extern :symbol metadata")
                    (match (parse-ast-extern-symbol-tail (box-get after-key))
                      [(ResultAstExternSymbol.Ok _ parsed-symbol-id)
                        (parse-ast-extern-head-post-ret
                          dispatch
                          pools
                          (reader.sp-node-get tail)
                          abi
                          parsed-symbol-id
                          link-inputs
                          seen-abi
                          true
                          param-types
                          ret)]
                      [(ResultAstExternSymbol.Err message)
                        (ResultAstExternParts.Err message)]))]
                [(= key (cbi.compiler-builtin-ctfe-ref 257))
                  (match (parse-ast-extern-string-tail
                    ":link-lib"
                    (box-get after-key))
                    [(ResultAstExternSymbol.Ok value _)
                      (begin
                        (ast-extern-link-input-list-push
                          link-inputs
                          (AstExternLinkInput.Lib value))
                        (parse-ast-extern-head-post-ret
                          dispatch
                          pools
                          (reader.sp-node-get tail)
                          abi
                          symbol-id
                          link-inputs
                          seen-abi
                          seen-symbol
                          param-types
                          ret))]
                    [(ResultAstExternSymbol.Err message)
                      (ResultAstExternParts.Err message)])]
                [(= key (cbi.compiler-builtin-ctfe-ref 258))
                  (match (parse-ast-extern-string-tail
                    ":link-search"
                    (box-get after-key))
                    [(ResultAstExternSymbol.Ok value _)
                      (begin
                        (ast-extern-link-input-list-push
                          link-inputs
                          (AstExternLinkInput.Search value))
                        (parse-ast-extern-head-post-ret
                          dispatch
                          pools
                          (reader.sp-node-get tail)
                          abi
                          symbol-id
                          link-inputs
                          seen-abi
                          seen-symbol
                          param-types
                          ret))]
                    [(ResultAstExternSymbol.Err message)
                      (ResultAstExternParts.Err message)])]
                [(= key (cbi.compiler-builtin-ctfe-ref 259))
                  (match (parse-ast-extern-string-tail
                    ":link-arg"
                    (box-get after-key))
                    [(ResultAstExternSymbol.Ok value _)
                      (begin
                        (ast-extern-link-input-list-push
                          link-inputs
                          (AstExternLinkInput.Arg value))
                        (parse-ast-extern-head-post-ret
                          dispatch
                          pools
                          (reader.sp-node-get tail)
                          abi
                          symbol-id
                          link-inputs
                          seen-abi
                          seen-symbol
                          param-types
                          ret))]
                    [(ResultAstExternSymbol.Err message)
                      (ResultAstExternParts.Err message)])]
                [(compiler-parse-metadata-key? key)
                  (ResultAstExternParts.Err
                    (string.append
                      "parse: unknown extern metadata "
                      (compiler-parse-name-text key)))]
                [else (ResultAstExternParts.Err "parse: malformed extern")])]
            [_ (ResultAstExternParts.Err "parse: malformed extern")])]
        [_ (ResultAstExternParts.Err "parse: malformed extern")])]
    [_ (ResultAstExternParts.Err "parse: malformed extern")]))

(define (parse-ast-extern-head-rest
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [items : reader.SpannedSexpr]
  [abi : AstExternAbi]
  [symbol-id : i64]
  [link-inputs : (&mut link-inputs AstExternLinkInputList)]
  [seen-abi : bool]
  [seen-symbol : bool]
  [param-types : AstTypeList]) : ResultAstExternParts
  (match items
    [(reader.SpannedSexpr.Cons head tail _)
      (if (sexpr-colon? (reader.spanned-sexpr-form (reader.sp-node-get head)))
        (match (reader.sp-node-get tail)
          [(reader.SpannedSexpr.Cons ret end _)
            (match (reader.sp-node-get end)
              [(reader.SpannedSexpr.Nil _)
                (match (parse-ast-type-spanned
                  dispatch
                  pools
                  (reader.sp-node-get ret))
                  [(ResultAstType.Ok parsed-ret)
                    (parse-ast-extern-head-finish
                      pools
                      abi
                      symbol-id
                      seen-abi
                      param-types
                      parsed-ret)]
                  [(ResultAstType.Err message)
                    (ResultAstExternParts.Err message)])]
              [_
                (match (parse-ast-type-spanned
                  dispatch
                  pools
                  (reader.sp-node-get ret))
                  [(ResultAstType.Ok parsed-ret)
                    (parse-ast-extern-head-post-ret
                      dispatch
                      pools
                      (reader.sp-node-get end)
                      abi
                      symbol-id
                      link-inputs
                      seen-abi
                      seen-symbol
                      param-types
                      parsed-ret)]
                  [(ResultAstType.Err message)
                    (ResultAstExternParts.Err message)])])]
          [_ (ResultAstExternParts.Err "parse: malformed extern")])
        (match (reader.spanned-sexpr-form (reader.sp-node-get head))
          [(reader.Sexpr.Cons key-node after-key)
            (match (box-get key-node)
              [(reader.Sexpr.Sym key)
                (cond
                  [(= key (cbi.compiler-builtin-ctfe-ref 255))
                    (if seen-abi
                      (ResultAstExternParts.Err
                        "parse: duplicate extern :abi metadata")
                      (match (parse-ast-extern-abi-tail (box-get after-key))
                        [(ResultAstExternAbi.Ok parsed-abi)
                          (match (parse-ast-extern-abi-combine abi parsed-abi)
                            [(ResultAstExternAbi.Ok combined-abi)
                              (parse-ast-extern-head-rest
                                dispatch
                                pools
                                (reader.sp-node-get tail)
                                combined-abi
                                symbol-id
                                link-inputs
                                true
                                seen-symbol
                                param-types)]
                            [(ResultAstExternAbi.Err message)
                              (ResultAstExternParts.Err message)])]
                        [(ResultAstExternAbi.Err message)
                          (ResultAstExternParts.Err message)]))]
                  [(= key (cbi.compiler-builtin-ctfe-ref 256))
                    (if seen-symbol
                      (ResultAstExternParts.Err
                        "parse: duplicate extern :symbol metadata")
                      (match (parse-ast-extern-symbol-tail (box-get after-key))
                        [(ResultAstExternSymbol.Ok _ parsed-symbol-id)
                          (parse-ast-extern-head-rest
                            dispatch
                            pools
                            (reader.sp-node-get tail)
                            abi
                            parsed-symbol-id
                            link-inputs
                            seen-abi
                            true
                            param-types)]
                        [(ResultAstExternSymbol.Err message)
                          (ResultAstExternParts.Err message)]))]
                  [(= key (cbi.compiler-builtin-ctfe-ref 257))
                    (match (parse-ast-extern-string-tail
                      ":link-lib"
                      (box-get after-key))
                      [(ResultAstExternSymbol.Ok value _)
                        (begin
                          (ast-extern-link-input-list-push
                            link-inputs
                            (AstExternLinkInput.Lib value))
                          (parse-ast-extern-head-rest
                            dispatch
                            pools
                            (reader.sp-node-get tail)
                            abi
                            symbol-id
                            link-inputs
                            seen-abi
                            seen-symbol
                            param-types))]
                      [(ResultAstExternSymbol.Err message)
                        (ResultAstExternParts.Err message)])]
                  [(= key (cbi.compiler-builtin-ctfe-ref 258))
                    (match (parse-ast-extern-string-tail
                      ":link-search"
                      (box-get after-key))
                      [(ResultAstExternSymbol.Ok value _)
                        (begin
                          (ast-extern-link-input-list-push
                            link-inputs
                            (AstExternLinkInput.Search value))
                          (parse-ast-extern-head-rest
                            dispatch
                            pools
                            (reader.sp-node-get tail)
                            abi
                            symbol-id
                            link-inputs
                            seen-abi
                            seen-symbol
                            param-types))]
                      [(ResultAstExternSymbol.Err message)
                        (ResultAstExternParts.Err message)])]
                  [(= key (cbi.compiler-builtin-ctfe-ref 259))
                    (match (parse-ast-extern-string-tail
                      ":link-arg"
                      (box-get after-key))
                      [(ResultAstExternSymbol.Ok value _)
                        (begin
                          (ast-extern-link-input-list-push
                            link-inputs
                            (AstExternLinkInput.Arg value))
                          (parse-ast-extern-head-rest
                            dispatch
                            pools
                            (reader.sp-node-get tail)
                            abi
                            symbol-id
                            link-inputs
                            seen-abi
                            seen-symbol
                            param-types))]
                      [(ResultAstExternSymbol.Err message)
                        (ResultAstExternParts.Err message)])]
                  [(compiler-parse-metadata-key? key)
                    (ResultAstExternParts.Err
                      (string.append
                        "parse: unknown extern metadata "
                        (compiler-parse-name-text key)))]
                  [else
                    (ResultAstExternParts.Err "parse: expected ':' in extern")])]
              [_ (ResultAstExternParts.Err "parse: expected ':' in extern")])]
          [_ (ResultAstExternParts.Err "parse: expected ':' in extern")]))]
    [_ (ResultAstExternParts.Err "parse: malformed extern")]))

(define (parse-ast-extern-function-head
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [head : reader.SpannedSexpr]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match (parse-ast-extern-header dispatch pools head)
    [(ResultAstExternHeader.Ok name param-types abi)
      (let
        [link-inputs : AstExternLinkInputList (ast-extern-link-input-list-new)]
        (match (parse-ast-extern-head-rest
          dispatch
          pools
          rest
          abi
          name
          (&mut link-inputs)
          false
          false
          param-types)
          [(ResultAstExternParts.Ok parsed-abi parsed-symbol-id explicit-abi ty)
            (ResultAstDecl.Ok
              (ast-decl-extern-id
                name
                (AstExternKind.Function)
                (AstExternMetadata.Metadata
                  parsed-abi
                  parsed-symbol-id
                  link-inputs
                  (ast-extern-metadata-flags
                    explicit-abi
                    (= parsed-symbol-id name))
                  AstImportedSpmdMetadata.No)
                ty))]
          [(ResultAstExternParts.Err message) (ResultAstDecl.Err message)]))]
    [(ResultAstExternHeader.Err message) (ResultAstDecl.Err message)]))

(define (parse-ast-extern
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match rest
    [(reader.SpannedSexpr.Cons name-node after-name _)
      (match (reader.sp-node-get name-node)
        [(reader.SpannedSexpr.Sym name _)
          (let
            [link-inputs : AstExternLinkInputList
              (ast-extern-link-input-list-new)]
            (match (parse-ast-extern-items
              dispatch
              pools
              (reader.sp-node-get after-name)
              (AstExternAbi.C)
              name
              (&mut link-inputs)
              false
              false)
              [(ResultAstExternParts.Ok
                  parsed-abi
                  parsed-symbol-id
                  explicit-abi
                  parsed-ty)
                (ResultAstDecl.Ok
                  (ast-decl-extern-id
                    name
                    (AstExternKind.Value)
                    (AstExternMetadata.Metadata
                      parsed-abi
                      parsed-symbol-id
                      link-inputs
                      (ast-extern-metadata-flags
                        explicit-abi
                        (= parsed-symbol-id name))
                      AstImportedSpmdMetadata.No)
                    parsed-ty))]
              [(ResultAstExternParts.Err message) (ResultAstDecl.Err message)]))]
        [_
          (parse-ast-extern-function-head
            dispatch
            pools
            (reader.sp-node-get name-node)
            (reader.sp-node-get after-name))])]
    [_ (ResultAstDecl.Err "parse: malformed extern")]))

(define (parse-ast-defenum
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match rest
    [(reader.SpannedSexpr.Cons name-node variants _)
      (match (reader.sp-node-get name-node)
        [(reader.SpannedSexpr.Sym name _)
          (let
            [member-marker : i64
              (reader.sp-node-push
                (reader.SpannedSexpr.Int
                  0
                  "__tl_member_origin"
                  (reader.spanned-sexpr-span (reader.sp-node-get name-node))))]
            (match (parse-ast-defenum-items
              dispatch
              pools
              (reader.sp-node-get variants)
              (ast-lifetime-list-new)
              (AstEnumCleanup.No)
              false
              false
              false)
              [(ResultAstEnumDefParts.Ok lifetimes cleanup parsed-variants)
                (begin
                  (array-set!
                    reader.sp-node-pool-slots
                    member-marker
                    (reader.SpannedSexpr.Int
                      (unsafe
                        (cast
                          (ptr->int
                            (ptr-cast
                              (array-data
                                (struct-get (& parsed-variants) slots))
                              : (Ptr u8)))
                          : i64))
                      "__tl_member_origin"
                      (reader.spanned-sexpr-span (reader.sp-node-get name-node))))
                  (if (ast-variant-def-list-empty? (& parsed-variants))
                    (ResultAstDecl.Err
                      "parse: defenum needs at least one variant")
                    (if (ast-lifetime-list-empty? (& lifetimes))
                      (ResultAstDecl.Ok
                        (ast-decl-def-enum-id name cleanup parsed-variants))
                      (ResultAstDecl.Ok
                        (ast-decl-def-enum-lifetimes-id
                          name
                          lifetimes
                          cleanup
                          parsed-variants)))))]
              [(ResultAstEnumDefParts.Err message) (ResultAstDecl.Err message)]))]
        [_ (ResultAstDecl.Err "parse: malformed defenum")])]
    [_ (ResultAstDecl.Err "parse: malformed defenum")]))

(define (parse-ast-defstruct
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match rest
    [(reader.SpannedSexpr.Cons name-node fields _)
      (match (reader.sp-node-get name-node)
        [(reader.SpannedSexpr.Sym name _)
          (let
            [member-marker : i64
              (reader.sp-node-push
                (reader.SpannedSexpr.Int
                  0
                  "__tl_member_origin"
                  (reader.spanned-sexpr-span (reader.sp-node-get name-node))))]
            (match (parse-ast-defstruct-items
              dispatch
              pools
              (reader.sp-node-get fields)
              (ast-lifetime-list-new)
              (AstStructRepr.Default)
              (AstStructCleanup.No)
              (ast-field-def-list-new)
              false
              false
              false
              false)
              [(ResultAstStructDefParts.Ok lifetimes repr cleanup parsed-fields)
                (begin
                  (array-set!
                    reader.sp-node-pool-slots
                    member-marker
                    (reader.SpannedSexpr.Int
                      (unsafe
                        (cast
                          (ptr->int
                            (ptr-cast
                              (array-data (struct-get (& parsed-fields) slots))
                              : (Ptr u8)))
                          : i64))
                      "__tl_member_origin"
                      (reader.spanned-sexpr-span (reader.sp-node-get name-node))))
                  (if (ast-field-def-list-empty? (& parsed-fields))
                    (ResultAstDecl.Err
                      "parse: defstruct needs at least one field")
                    (if (ast-lifetime-list-empty? (& lifetimes))
                      (ResultAstDecl.Ok
                        (ast-decl-def-struct-id name repr cleanup parsed-fields))
                      (ResultAstDecl.Ok
                        (ast-decl-def-struct-lifetimes-id
                          name
                          lifetimes
                          repr
                          cleanup
                          parsed-fields)))))]
              [(ResultAstStructDefParts.Err message)
                (ResultAstDecl.Err message)]))]
        [_ (ResultAstDecl.Err "parse: malformed defstruct")])]
    [_ (ResultAstDecl.Err "parse: malformed defstruct")]))

(define (parse-ast-defdispatch [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match rest
    [(reader.SpannedSexpr.Cons name-node variants _)
      (match (reader.sp-node-get name-node)
        [(reader.SpannedSexpr.Sym name _)
          (match (parse-ast-dispatch-variant-list (reader.sp-node-get variants))
            [(ResultAstDispatchVariantList.Ok parsed-variants)
              (if (ast-dispatch-variant-list-empty? (& parsed-variants))
                (ResultAstDecl.Err
                  "parse: defdispatch needs at least one variant")
                (ResultAstDecl.Ok
                  (ast-decl-def-dispatch-id name parsed-variants)))]
            [(ResultAstDispatchVariantList.Err message)
              (ResultAstDecl.Err message)])]
        [_ (ResultAstDecl.Err "parse: malformed defdispatch")])]
    [_ (ResultAstDecl.Err "parse: malformed defdispatch")]))

(define (parse-ast-module-body-forms-into-vec
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [forms : reader.SpannedSexpr]
  [out : (&mut out ParseAstDeclVec)]) : ResultParseAstDeclVec
  (match forms
    [(reader.SpannedSexpr.Nil _) (ResultParseAstDeclVec.Ok)]
    [(reader.SpannedSexpr.Cons form rest _)
      (match (parse-ast-decl-maybe-with-pools
        dispatch
        pools
        (reader.sp-node-get form))
        [(ResultAstMaybeDecl.SomeDecl decl)
          (begin
            (parse-ast-decl-vec-push-with-span
              out
              decl
              (compiler-parse-decl-origin-syntax-span
                dispatch
                (reader.sp-node-get form)))
            (parse-ast-module-body-forms-into-vec
              dispatch
              pools
              (reader.sp-node-get rest)
              out))]
        [(ResultAstMaybeDecl.Decls decls)
          (begin
            (parse-ast-decl-vec-push-list! out decls)
            (parse-ast-module-body-forms-into-vec
              dispatch
              pools
              (reader.sp-node-get rest)
              out))]
        [(ResultAstMaybeDecl.NoDecl)
          (parse-ast-module-body-forms-into-vec
            dispatch
            pools
            (reader.sp-node-get rest)
            out)]
        [(ResultAstMaybeDecl.Err message) (ResultParseAstDeclVec.Err message)])]
    [_ (ResultParseAstDeclVec.Err "parse: malformed module")]))

(define (parse-ast-module-body
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [name : i64]
  [body : reader.SpannedSexpr]) : ResultAstDecl
  (let
    [out : ParseAstDeclVec (parse-ast-decl-vec-new)]
    (match (parse-ast-module-body-forms-into-vec dispatch pools body (&mut out))
      [(ResultParseAstDeclVec.Ok)
        (ResultAstDecl.Ok
          (ast-decl-module-body-id name (parse-ast-decl-vec-to-list (& out))))]
      [(ResultParseAstDeclVec.Err message) (ResultAstDecl.Err message)])))

(define (parse-ast-module
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match rest
    [(reader.SpannedSexpr.Cons name-node end _)
      (match (reader.sp-node-get name-node)
        [(reader.SpannedSexpr.Sym name _)
          (match (reader.sp-node-get end)
            [(reader.SpannedSexpr.Nil _)
              (ResultAstDecl.Ok (ast-decl-module-id name))]
            [_
              (parse-ast-module-body
                dispatch
                pools
                name
                (reader.sp-node-get end))])]
        [_ (ResultAstDecl.Err "parse: malformed module")])]
    [_ (ResultAstDecl.Err "parse: malformed module")]))

(define (parse-ast-import-spec
  [kind : AstImportKind]
  [path : String]
  [module-name : AstMaybeModuleName]
  [alias : AstMaybeImportAlias]
  [span : AstSourceSpan]) : ResultAstDecl
  (ResultAstDecl.Ok
    (AstDecl.Import
      ast-decl-meta-runtime
      (AstImportSpec.Spec kind path module-name alias (box span)))))

(define (parse-ast-import-alias
  [kind : AstImportKind]
  [path : String]
  [module-name : AstMaybeModuleName]
  [tail : reader.SpannedSexpr]
  [span : AstSourceSpan]) : ResultAstDecl
  (match tail
    [(reader.SpannedSexpr.Cons as-node alias-tail _)
      (match (reader.sp-node-get as-node)
        [(reader.SpannedSexpr.Sym as-name _)
          (match (reader.sp-node-get alias-tail)
            [(reader.SpannedSexpr.Cons alias-node end _)
              (match (reader.sp-node-get end)
                [(reader.SpannedSexpr.Nil _)
                  (match (reader.sp-node-get alias-node)
                    [(reader.SpannedSexpr.Sym alias _)
                      (if (cbi.compiler-builtin-id-any2?
                        as-name
                        (cbi.compiler-builtin-ctfe-ref 260)
                        (cbi.compiler-builtin-ctfe-ref 261))
                        (parse-ast-import-spec
                          kind
                          path
                          module-name
                          (AstMaybeImportAlias.Some alias)
                          span)
                        (ResultAstDecl.Err "parse: malformed import"))]
                    [_ (ResultAstDecl.Err "parse: malformed import")])]
                [_ (ResultAstDecl.Err "parse: malformed import")])]
            [_ (ResultAstDecl.Err "parse: malformed import")])]
        [_ (ResultAstDecl.Err "parse: malformed import")])]
    [_ (ResultAstDecl.Err "parse: malformed import")]))

(define (parse-ast-import-module-tail
  [path : String]
  [tail : reader.SpannedSexpr]
  [span : AstSourceSpan]) : ResultAstDecl
  (match tail
    [(reader.SpannedSexpr.Cons module-name-node after-module _)
      (match (reader.sp-node-get module-name-node)
        [(reader.SpannedSexpr.Sym module-name _)
          (match (reader.sp-node-get after-module)
            [(reader.SpannedSexpr.Nil _)
              (parse-ast-import-spec
                (AstImportKind.Path)
                path
                (AstMaybeModuleName.Some module-name)
                AstMaybeImportAlias.No
                span)]
            [_
              (parse-ast-import-alias
                (AstImportKind.Path)
                path
                (AstMaybeModuleName.Some module-name)
                (reader.sp-node-get after-module)
                span)])]
        [_ (ResultAstDecl.Err "parse: malformed import")])]
    [_ (ResultAstDecl.Err "parse: malformed import")]))

(define (parse-ast-import-tail
  [path : String]
  [tail : reader.SpannedSexpr]
  [span : AstSourceSpan]) : ResultAstDecl
  (match tail
    [(reader.SpannedSexpr.Nil _)
      (parse-ast-import-spec
        (AstImportKind.Path)
        path
        AstMaybeModuleName.No
        AstMaybeImportAlias.No
        span)]
    [(reader.SpannedSexpr.Cons head-node after-head _)
      (match (reader.sp-node-get head-node)
        [(reader.SpannedSexpr.Sym head _)
          (if (= head (cbi.compiler-builtin-ctfe-ref 260))
            (parse-ast-import-alias
              (AstImportKind.Path)
              path
              AstMaybeModuleName.No
              tail
              span)
            (if (= head cbi.compiler-builtin-id-fix-module)
              (parse-ast-import-module-tail
                path
                (reader.sp-node-get after-head)
                span)
              (ResultAstDecl.Err "parse: malformed import")))]
        [_ (ResultAstDecl.Err "parse: malformed import")])]
    [_ (ResultAstDecl.Err "parse: malformed import")]))

(define (parse-ast-import-macro-tail
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [call-form : reader.SpannedSexpr]
  [tail : reader.SpannedSexpr]
  [span : AstSourceSpan]) : ResultAstDecl
  (match (parse-ast-expr-with-pools dispatch pools call-form)
    [(ResultAstExpr.Ok call-expr)
      (match (ast-expr-unspan-with-pools
        pools
        (ast-node-pool-context-expr-get pools call-expr))
        [(AstExpr.Call _ _)
          (match tail
            [(reader.SpannedSexpr.Nil _)
              (parse-ast-import-spec
                (AstImportKind.Macro call-expr AstMaybeModuleName.No)
                ""
                AstMaybeModuleName.No
                AstMaybeImportAlias.No
                span)]
            [(reader.SpannedSexpr.Cons head-node _ _)
              (match (reader.sp-node-get head-node)
                [(reader.SpannedSexpr.Sym head _)
                  (if (cbi.compiler-builtin-id-any2?
                    head
                    (cbi.compiler-builtin-ctfe-ref 260)
                    (cbi.compiler-builtin-ctfe-ref 261))
                    (parse-ast-import-alias
                      (AstImportKind.Macro call-expr AstMaybeModuleName.No)
                      ""
                      AstMaybeModuleName.No
                      tail
                      span)
                    (ResultAstDecl.Err "parse: malformed import"))]
                [_ (ResultAstDecl.Err "parse: malformed import")])]
            [_ (ResultAstDecl.Err "parse: malformed import")])]
        [_ (ResultAstDecl.Err "parse: import macro operand must be a call")])]
    [(ResultAstExpr.Err message) (ResultAstDecl.Err message)]))

(define (parse-ast-dotted-import-tl-suffix? [name : String]) : bool
  (let
    [n : i64 (string.string-length name)]
    (if (< n 3)
      false
      (string.eq (string.substring name (- n 3) 3) ".tl"))))

(define (parse-ast-dotted-import-name-valid? [name : String]) : bool
  (let
    [n : i64 (string.string-length name)]
    [i : i64 0]
    [ok : bool (and (> n 0) (not (parse-ast-dotted-import-tl-suffix? name)))]
    [last-was-dot : bool true]
    (begin
      (while ok
        (if (< i n)
          (let
            [c : char (string.string-ref name i)]
            (if (or
              (string.char-eq c '/')
              (string.char-eq c '\\')
              (string.char-eq c ':'))
              (set! ok false)
              (if (string.char-eq c '.')
                (if last-was-dot
                  (set! ok false)
                  (begin
                    (set! last-was-dot true)
                    (set! i (+ i 1))))
                (begin
                  (set! last-was-dot false)
                  (set! i (+ i 1))))))
          (set! ok false)))
      (and (= i n) (not last-was-dot)))))

(define (parse-ast-dotted-import-default-alias-start [name : String]) : i64
  (let
    [n : i64 (string.string-length name)]
    [i : i64 0]
    [start : i64 0]
    (begin
      (while (< i n)
        (begin
          (if (string.char-eq (string.string-ref name i) '.')
            (set! start (+ i 1))
            unit)
          (set! i (+ i 1))))
      start)))

(define (parse-ast-dotted-import-default-alias [name : String]) : String
  (let
    [start : i64 (parse-ast-dotted-import-default-alias-start name)]
    (string.substring name start (- (string.string-length name) start))))

(define (parse-ast-dotted-import-default-alias-id [name-id : i64]) : i64
  (ci.intern-dotted-final-id name-id))

(define (parse-ast-dotted-import-tail
  [module-name-id : i64]
  [tail : reader.SpannedSexpr]
  [span : AstSourceSpan]) : ResultAstDecl
  (let
    [module-name : String (compiler-parse-name-text module-name-id)]
    (if (not (parse-ast-dotted-import-name-valid? module-name))
      (ResultAstDecl.Err "parse: invalid dotted import module name")
      (match tail
        [(reader.SpannedSexpr.Nil _)
          (parse-ast-import-spec
            (AstImportKind.Module)
            module-name
            (AstMaybeModuleName.Some module-name-id)
            (AstMaybeImportAlias.Some
              (parse-ast-dotted-import-default-alias-id module-name-id))
            span)]
        [(reader.SpannedSexpr.Cons head-node _ _)
          (match (reader.sp-node-get head-node)
            [(reader.SpannedSexpr.Sym head _)
              (if (cbi.compiler-builtin-id-any2?
                head
                (cbi.compiler-builtin-ctfe-ref 260)
                (cbi.compiler-builtin-ctfe-ref 261))
                (parse-ast-import-alias
                  (AstImportKind.Module)
                  module-name
                  (AstMaybeModuleName.Some module-name-id)
                  tail
                  span)
                (ResultAstDecl.Err "parse: malformed import"))]
            [_ (ResultAstDecl.Err "parse: malformed import")])]
        [_ (ResultAstDecl.Err "parse: malformed import")]))))

(define (parse-ast-import
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]
  [span : AstSourceSpan]) : ResultAstDecl
  (match rest
    [(reader.SpannedSexpr.Cons path-node tail _)
      (match (reader.sp-node-get path-node)
        [(reader.SpannedSexpr.Str path-id _)
          (parse-ast-import-tail
            (ci.intern-str path-id)
            (reader.sp-node-get tail)
            span)]
        [(reader.SpannedSexpr.Sym module-name _)
          (parse-ast-dotted-import-tail
            module-name
            (reader.sp-node-get tail)
            span)]
        [(reader.SpannedSexpr.Cons _ _ _)
          (parse-ast-import-macro-tail
            dispatch
            pools
            (reader.sp-node-get path-node)
            (reader.sp-node-get tail)
            span)]
        [_ (ResultAstDecl.Err "parse: malformed import")])]
    [_ (ResultAstDecl.Err "parse: malformed import")]))

(define (parse-ast-include-str [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match rest
    [(reader.SpannedSexpr.Nil _)
      (ResultAstDecl.Err "parse: include-str expects name and string path")]
    [(reader.SpannedSexpr.Cons name-node tail _)
      (match (reader.sp-node-get name-node)
        [(reader.SpannedSexpr.Sym name _)
          (match (reader.sp-node-get tail)
            [(reader.SpannedSexpr.Cons path-node after-path _)
              (match (reader.sp-node-get path-node)
                [(reader.SpannedSexpr.Str path-id _)
                  (match (reader.sp-node-get after-path)
                    [(reader.SpannedSexpr.Nil _)
                      (ResultAstDecl.Ok
                        (AstDecl.IncludeStr name (ci.intern-str path-id)))]
                    [_
                      (ResultAstDecl.Err
                        "parse: include-str expects exactly two operands")])]
                [_
                  (ResultAstDecl.Err "parse: include-str path must be a string")])]
            [(reader.SpannedSexpr.Nil _)
              (ResultAstDecl.Err
                "parse: include-str expects name and string path")]
            [_
              (ResultAstDecl.Err
                "parse: include-str expects exactly two operands")])]
        [_ (ResultAstDecl.Err "parse: include-str name must be a symbol")])]
    [_ (ResultAstDecl.Err "parse: malformed include-str")]))

(define (parse-ast-include-str-comptime [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match rest
    [(reader.SpannedSexpr.Nil _)
      (ResultAstDecl.Err
        "parse: include-str-comptime expects name and string path")]
    [(reader.SpannedSexpr.Cons name-node tail _)
      (match (reader.sp-node-get name-node)
        [(reader.SpannedSexpr.Sym name _)
          (match (reader.sp-node-get tail)
            [(reader.SpannedSexpr.Cons path-node after-path _)
              (match (reader.sp-node-get path-node)
                [(reader.SpannedSexpr.Str path-id _)
                  (match (reader.sp-node-get after-path)
                    [(reader.SpannedSexpr.Nil _)
                      (ResultAstDecl.Ok
                        (AstDecl.IncludeStrComptime
                          name
                          (ci.intern-str path-id)))]
                    [_
                      (ResultAstDecl.Err
                        "parse: include-str-comptime expects exactly two operands")])]
                [_
                  (ResultAstDecl.Err
                    "parse: include-str-comptime path must be a string")])]
            [(reader.SpannedSexpr.Nil _)
              (ResultAstDecl.Err
                "parse: include-str-comptime expects name and string path")]
            [_
              (ResultAstDecl.Err
                "parse: include-str-comptime expects exactly two operands")])]
        [_
          (ResultAstDecl.Err
            "parse: include-str-comptime name must be a symbol")])]
    [_ (ResultAstDecl.Err "parse: malformed include-str-comptime")]))

(define (parse-ast-include-str-lzss [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match rest
    [(reader.SpannedSexpr.Nil _)
      (ResultAstDecl.Err "parse: include-str-lzss expects name and string path")]
    [(reader.SpannedSexpr.Cons name-node tail _)
      (match (reader.sp-node-get name-node)
        [(reader.SpannedSexpr.Sym name _)
          (match (reader.sp-node-get tail)
            [(reader.SpannedSexpr.Cons path-node end _)
              (match (reader.sp-node-get path-node)
                [(reader.SpannedSexpr.Str path _)
                  (match (reader.sp-node-get end)
                    [(reader.SpannedSexpr.Nil _)
                      (ResultAstDecl.Ok
                        (AstDecl.IncludeStrLzss name (ci.intern-str path)))]
                    [_
                      (ResultAstDecl.Err
                        "parse: include-str-lzss expects exactly two operands")])]
                [_
                  (ResultAstDecl.Err
                    "parse: include-str-lzss path must be a string")])]
            [(reader.SpannedSexpr.Nil _)
              (ResultAstDecl.Err
                "parse: include-str-lzss expects name and string path")]
            [_
              (ResultAstDecl.Err
                "parse: include-str-lzss expects exactly two operands")])]
        [_ (ResultAstDecl.Err "parse: include-str-lzss name must be a symbol")])]
    [_ (ResultAstDecl.Err "parse: malformed include-str-lzss")]))

(define (parse-ast-include-bin [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match rest
    [(reader.SpannedSexpr.Nil _)
      (ResultAstDecl.Err "parse: include-bin expects name and string path")]
    [(reader.SpannedSexpr.Cons name-node tail _)
      (match (reader.sp-node-get name-node)
        [(reader.SpannedSexpr.Sym name _)
          (match (reader.sp-node-get tail)
            [(reader.SpannedSexpr.Cons path-node after-path _)
              (match (reader.sp-node-get path-node)
                [(reader.SpannedSexpr.Str path-id _)
                  (match (reader.sp-node-get after-path)
                    [(reader.SpannedSexpr.Nil _)
                      (ResultAstDecl.Ok
                        (AstDecl.IncludeBin name (ci.intern-str path-id)))]
                    [_
                      (ResultAstDecl.Err
                        "parse: include-bin expects exactly two operands")])]
                [_
                  (ResultAstDecl.Err "parse: include-bin path must be a string")])]
            [(reader.SpannedSexpr.Nil _)
              (ResultAstDecl.Err
                "parse: include-bin expects name and string path")]
            [_
              (ResultAstDecl.Err
                "parse: include-bin expects exactly two operands")])]
        [_ (ResultAstDecl.Err "parse: include-bin name must be a symbol")])]
    [_ (ResultAstDecl.Err "parse: malformed include-bin")]))

(define (parse-ast-test-body [pools : AstNodePoolContext] [exprs : AstExprList]) : i64
  (if (= (struct-get (& exprs) len) 1)
    (ast-expr-list-get (& exprs) 0 0)
    (ast-node-pool-context-expr-push pools (AstExpr.Begin exprs))))

(define (parse-ast-test
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]
  [form-span : AstSourceSpan]) : ResultAstDecl
  (match rest
    [(reader.SpannedSexpr.Cons name-node body-forms _)
      (match (reader.sp-node-get name-node)
        [(reader.SpannedSexpr.Sym name _)
          (match (reader.sp-node-get body-forms)
            [(reader.SpannedSexpr.Nil _)
              (ResultAstDecl.Err "parse: test needs at least one expression")]
            [_
              (match (parse-ast-expr-list
                dispatch
                pools
                (reader.sp-node-get body-forms))
                [(ResultAstExprList.Ok exprs)
                  (ResultAstDecl.Ok
                    (ast-decl-test-id
                      name
                      (parse-ast-test-body pools exprs)
                      form-span))]
                [(ResultAstExprList.Err message) (ResultAstDecl.Err message)])])]
        [_ (ResultAstDecl.Err "parse: malformed test")])]
    [_ (ResultAstDecl.Err "parse: malformed test")]))

(define (parse-ast-removed-declaration-message) : String
  "parse: comptime-decl and comptime-decls are removed; use defmacro with Module or Decls return type instead")

(define (parse-ast-removed-declaration-name? [name : i64]) : bool
  ;; Preserve the shared diagnostic for the retired prefix family
  ;; comptime-decl/comptime-decls without interning more accepted syntax.
  (let
    [text : String (compiler-parse-name-text name)]
    [n : i64 (string.string-length text)]
    (and
      (or (= n 13) (= n 14))
      (= (string.string-ref text 0) 'c')
      (= (string.string-ref text 1) 'o')
      (= (string.string-ref text 2) 'm')
      (= (string.string-ref text 3) 'p')
      (= (string.string-ref text 4) 't')
      (= (string.string-ref text 5) 'i')
      (= (string.string-ref text 6) 'm')
      (= (string.string-ref text 7) 'e')
      (= (string.string-ref text 8) '-')
      (= (string.string-ref text 9) 'd')
      (= (string.string-ref text 10) 'e')
      (= (string.string-ref text 11) 'c')
      (= (string.string-ref text 12) 'l')
      (if (= n 14)
        (= (string.string-ref text 13) 's')
        true))))

(define (parse-ast-unsafe-decl
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match rest
    [(reader.SpannedSexpr.Cons inner end _)
      (match (reader.sp-node-get end)
        [(reader.SpannedSexpr.Nil _)
          (match (parse-ast-decl dispatch pools (reader.sp-node-get inner))
            [(ResultAstDecl.Ok decl)
              (match decl
                [(AstDecl.DefFn decl-meta _ _ _ _ _)
                  (ResultAstDecl.Ok (ast-decl-unsafe decl))]
                [(AstDecl.Extern decl-meta _ _ _ _)
                  (ResultAstDecl.Ok (ast-decl-unsafe decl))]
                [_
                  (ResultAstDecl.Err
                    "parse: unsafe declaration accepts only function define or extern")])]
            [(ResultAstDecl.Err message) (ResultAstDecl.Err message)])]
        [_
          (ResultAstDecl.Err
            "parse: unsafe declaration expects exactly one declaration")])]
    [_
      (ResultAstDecl.Err
        "parse: unsafe declaration expects exactly one declaration")]))

(define (parse-ast-module-macro-call
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [form : reader.SpannedSexpr]) : ResultAstDecl
  (match (parse-ast-expr-with-pools dispatch pools form)
    [(ResultAstExpr.Ok call-expr)
      (match (ast-expr-unspan-with-pools
        pools
        (ast-node-pool-context-expr-get pools call-expr))
        [(AstExpr.Call _ _)
          (parse-ast-import-spec
            (AstImportKind.MacroDecls call-expr AstMaybeModuleName.No)
            ""
            AstMaybeModuleName.No
            AstMaybeImportAlias.No
            (ast-source-span-from-source-span (reader.spanned-sexpr-span form)))]
        [_ (ResultAstDecl.Err "parse: expected declaration")])]
    [(ResultAstExpr.Err message) (ResultAstDecl.Err message)]))

(define (parse-ast-decl
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.SpannedSexpr]) : ResultAstDecl
  (let
    [result : ResultAstDecl
      (match s
        [(reader.SpannedSexpr.Cons head-node rest _)
          (match (reader.sp-node-get head-node)
            [(reader.SpannedSexpr.Sym head _)
              (let
                [tag : i64 (compiler-parse-dispatch-tag dispatch head)]
                (cond
                  [(= tag (compiler-parse-tag-decl-define))
                    (parse-ast-define dispatch pools (reader.sp-node-get rest))]
                  [(= tag (compiler-parse-tag-decl-extern))
                    (parse-ast-extern dispatch pools (reader.sp-node-get rest))]
                  [(= tag (compiler-parse-tag-decl-defenum))
                    (parse-ast-defenum dispatch pools (reader.sp-node-get rest))]
                  [(= tag (compiler-parse-tag-decl-defstruct))
                    (parse-ast-defstruct
                      dispatch
                      pools
                      (reader.sp-node-get rest))]
                  [(= tag (compiler-parse-tag-decl-defdispatch))
                    (parse-ast-defdispatch (reader.sp-node-get rest))]
                  [(= tag (compiler-parse-tag-decl-defmacro))
                    (parse-ast-defmacro
                      dispatch
                      pools
                      (reader.sp-node-get rest))]
                  [(= tag (compiler-parse-tag-decl-import))
                    (parse-ast-import
                      dispatch
                      pools
                      (reader.sp-node-get rest)
                      (ast-source-span-from-source-span
                        (reader.spanned-sexpr-span s)))]
                  [(= tag (compiler-parse-tag-decl-include-str))
                    (parse-ast-include-str (reader.sp-node-get rest))]
                  [(= tag (compiler-parse-tag-decl-include-str-comptime))
                    (parse-ast-include-str-comptime (reader.sp-node-get rest))]
                  [(= tag (compiler-parse-tag-decl-include-str-lzss))
                    (parse-ast-include-str-lzss (reader.sp-node-get rest))]
                  [(= tag (compiler-parse-tag-decl-removed-compressed-include))
                    (ResultAstDecl.Err
                      (compiler-parse-removed-compressed-include-message))]
                  [(= tag (compiler-parse-tag-decl-include-bin))
                    (parse-ast-include-bin (reader.sp-node-get rest))]
                  [(= tag (compiler-parse-tag-decl-module))
                    (parse-ast-module dispatch pools (reader.sp-node-get rest))]
                  [(parse-ast-removed-declaration-name? head)
                    (ResultAstDecl.Err (parse-ast-removed-declaration-message))]
                  [(= tag (compiler-parse-tag-expr-unsafe))
                    (parse-ast-unsafe-decl
                      dispatch
                      pools
                      (reader.sp-node-get rest))]
                  [(= tag (compiler-parse-tag-decl-test))
                    (parse-ast-test
                      dispatch
                      pools
                      (reader.sp-node-get rest)
                      (ast-source-span-from-source-span
                        (reader.spanned-sexpr-span s)))]
                  [(compiler-parse-policy-form? head)
                    (ResultAstDecl.Err
                      (compiler-parse-abstraction-policy-message))]
                  [else (parse-ast-module-macro-call dispatch pools s)]))]
            [_ (ResultAstDecl.Err "parse: malformed declaration")])]
        [_ (ResultAstDecl.Err "parse: malformed declaration")])]
    (parse-ast-error-span-note-decl dispatch s result)))

(define (parse-ast-decl-maybe-with-pools
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [s : reader.SpannedSexpr]) : ResultAstMaybeDecl
  (let
    [result : ResultAstMaybeDecl
      (match s
        [(reader.SpannedSexpr.Cons head-node rest _)
          (match (reader.sp-node-get head-node)
            [(reader.SpannedSexpr.Sym head _)
              (if (= head (cbi.compiler-builtin-ctfe-ref 243))
                (match (reader.sp-node-get rest)
                  [(reader.SpannedSexpr.Cons pred decl-tail _)
                    (match (reader.sp-node-get decl-tail)
                      [(reader.SpannedSexpr.Cons decl-form end _)
                        (match (reader.sp-node-get end)
                          [(reader.SpannedSexpr.Nil _)
                            (match (compiler-cfg-eval
                              dispatch
                              (reader.sp-node-get pred))
                              [(ResultCompilerCfg.Ok enabled)
                                (if enabled
                                  (parse-ast-decl-maybe-with-pools
                                    dispatch
                                    pools
                                    (reader.sp-node-get decl-form))
                                  (ResultAstMaybeDecl.NoDecl))]
                              [(ResultCompilerCfg.Err message)
                                (ResultAstMaybeDecl.Err message)])]
                          [_
                            (ResultAstMaybeDecl.Err
                              "parse: cfg declaration expects predicate and declaration")])]
                      [_
                        (ResultAstMaybeDecl.Err
                          "parse: cfg declaration expects predicate and declaration")])]
                  [_
                    (ResultAstMaybeDecl.Err
                      "parse: cfg declaration expects predicate and declaration")])
                (match (parse-ast-decl dispatch pools s)
                  [(ResultAstDecl.Ok decl) (ResultAstMaybeDecl.SomeDecl decl)]
                  [(ResultAstDecl.Err message) (ResultAstMaybeDecl.Err message)]))]
            [_
              (match (parse-ast-decl dispatch pools s)
                [(ResultAstDecl.Ok decl) (ResultAstMaybeDecl.SomeDecl decl)]
                [(ResultAstDecl.Err message) (ResultAstMaybeDecl.Err message)])])]
        [_ (ResultAstMaybeDecl.Err "parse: malformed declaration")])]
    (parse-ast-error-span-note-maybe-decl dispatch s result)))

(define (parse-ast-decl-maybe
  [dispatch : sym_i64_env.SymI64Env]
  [s : reader.SpannedSexpr]) : ResultAstMaybeDecl
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [result : ResultAstMaybeDecl
      (parse-ast-decl-maybe-with-pools dispatch pools s)]
    (begin
      (ast-node-pool-context-install! pools)
      result)))

(defstruct ParseAstDeclVec
  (slots (Array AstDecl))
  (spans (Array AstSourceSpan))
  (len i64))

(define (parse-ast-decl-vec-fallback) : AstDecl
  (AstDecl.Module cbi.compiler-builtin-id-fix-lt_parse_ast_decl_vec_fallback_gt))

(define (parse-ast-decl-vec-with-capacity [capacity : i64]) : ParseAstDeclVec
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (ParseAstDeclVec (make-array AstDecl cap) (make-array AstSourceSpan cap) 0)))

(define (parse-ast-decl-vec-new) : ParseAstDeclVec
  (parse-ast-decl-vec-with-capacity 16))

(define (parse-ast-decl-vec-len [v : (& v ParseAstDeclVec)]) : i64
  (struct-get v len))

(define (parse-ast-decl-vec-capacity [v : (& v ParseAstDeclVec)]) : i64
  (array-length (struct-get v slots)))

(define (parse-ast-decl-vec-get
  [v : (& v ParseAstDeclVec)]
  [index : i64]
  [fallback : AstDecl]) : AstDecl
  (if (and (>= index 0) (< index (parse-ast-decl-vec-len v)))
    (array-ref (struct-get v slots) index)
    fallback))

(define (parse-ast-decl-vec-span-get
  [v : (& v ParseAstDeclVec)]
  [index : i64]
  [fallback : AstSourceSpan]) : AstSourceSpan
  (if (and (>= index 0) (< index (parse-ast-decl-vec-len v)))
    (array-ref (struct-get v spans) index)
    fallback))

(define (parse-ast-decl-vec-copy-range
  [dst : (&mut dst (Array AstDecl))]
  [src : (& src (Array AstDecl))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (parse-ast-decl-vec-copy-range dst src (+ index 1) count))))

(define (parse-ast-decl-vec-span-copy-range
  [dst : (&mut dst (Array AstSourceSpan))]
  [src : (& src (Array AstSourceSpan))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (parse-ast-decl-vec-span-copy-range dst src (+ index 1) count))))

(define (parse-ast-decl-vec-grow [v : (&mut v ParseAstDeclVec)]) : unit
  (let
    [n : i64 (struct-get v len)]
    [old-cap : i64 (array-length (struct-get v slots))]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (Array AstDecl) (make-array AstDecl new-cap)]
    [bigger-spans : (Array AstSourceSpan) (make-array AstSourceSpan new-cap)]
    (begin
      (parse-ast-decl-vec-copy-range (&mut bigger) (& (struct-get v slots)) 0 n)
      (parse-ast-decl-vec-span-copy-range
        (&mut bigger-spans)
        (& (struct-get v spans))
        0
        n)
      (set! (struct-get v slots) bigger)
      (set! (struct-get v spans) bigger-spans))))

(define (parse-ast-decl-vec-push-with-span
  [v : (&mut v ParseAstDeclVec)]
  [value : AstDecl]
  [span : AstSourceSpan]) : unit
  (begin
    (if (< (struct-get v len) (array-length (struct-get v slots)))
      unit
      (parse-ast-decl-vec-grow v))
    (let
      [index : i64 (struct-get v len)]
      (begin
        (array-set! (struct-get v slots) index value)
        (array-set! (struct-get v spans) index span)
        (set! (struct-get v len) (+ index 1))))))

(define (parse-ast-decl-vec-push
  [v : (&mut v ParseAstDeclVec)]
  [value : AstDecl]) : unit
  (parse-ast-decl-vec-push-with-span v value (ast-decl-span-fallback)))

(define (parse-ast-decl-vec-push-list!
  [out : (&mut out ParseAstDeclVec)]
  [decls : AstDeclList]) : unit
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) unit]
    [(AstDeclListStep.Cons head rest)
      (begin
        (parse-ast-decl-vec-push out head)
        (parse-ast-decl-vec-push-list! out rest))]))

(define (parse-ast-decl-vec-copy-to-list
  [items : (& items ParseAstDeclVec)]
  [index : i64]
  [out : (&mut out AstDeclList)]) : unit
  (if (>= index (parse-ast-decl-vec-len items))
    unit
    (begin
      (ast-decl-list-push
        out
        (parse-ast-decl-vec-get items index (parse-ast-decl-vec-fallback)))
      (parse-ast-decl-vec-copy-to-list items (+ index 1) out))))

(define (compiler-parse-decl-origin-needs-record? [decl : AstDecl]) : bool
  (match decl
    [(AstDecl.Def decl-meta _ _ _) false]
    [(AstDecl.DefFn decl-meta _ _ _ _ _) false]
    [(AstDecl.DefMacro decl-meta _ _ _ _) false]
    [(AstDecl.Test _ _ _) false]
    [(AstDecl.Unsafe inner-box)
      (compiler-parse-decl-origin-needs-record? (box-get inner-box))]
    [_ true]))

(define (compiler-parse-decl-origin-register-selected!
  [items : (& items ParseAstDeclVec)]
  [out : (& out AstDeclList)]) : unit
  (let
    [index : i64 0]
    (while (< index (parse-ast-decl-vec-len items))
      (begin
        (if (compiler-parse-decl-origin-needs-record?
          (parse-ast-decl-vec-get items index (parse-ast-decl-vec-fallback)))
          (let
            [span : AstSourceSpan (array-ref (struct-get items spans) index)]
            (compiler-parse-decl-origin-register-maybe!
              out
              index
              (CompilerParseMaybeDeclSpan.Some
                (AstSourceSpan
                  (struct-get span start-line)
                  (struct-get span start-col)
                  (struct-get span end-line)
                  (struct-get span end-col)))))
          unit)
        (set! index (+ index 1))))))

(define (parse-ast-decl-vec-to-list [items : (& items ParseAstDeclVec)]) : AstDeclList
  (let
    [out : AstDeclList
      (ast-decl-list-with-capacity (parse-ast-decl-vec-len items))]
    (begin
      (parse-ast-decl-vec-copy-to-list items 0 (&mut out))
      (compiler-parse-decl-origin-register-selected! items (& out))
      out)))

;; Wrappers are declarations semantically, but declaration-shape errors belong
;; to the declaration inside them. Keep the innermost source form's bounds.
(define (compiler-parse-decl-origin-syntax-span
  [dispatch : sym_i64_env.SymI64Env]
  [form : reader.SpannedSexpr]) : AstSourceSpan
  (let
    [fallback : AstSourceSpan
      (ast-source-span-from-source-span (reader.spanned-sexpr-span form))]
    (match form
      [(reader.SpannedSexpr.Cons head-node rest _)
        (match (reader.sp-node-get head-node)
          [(reader.SpannedSexpr.Sym head _)
            (let
              [tag : i64 (compiler-parse-dispatch-tag dispatch head)]
              (cond
                [(= head (cbi.compiler-builtin-ctfe-ref 243))
                  (match (reader.sp-node-get rest)
                    [(reader.SpannedSexpr.Cons _ decl-tail _)
                      (match (reader.sp-node-get decl-tail)
                        [(reader.SpannedSexpr.Cons decl-form _ _)
                          (compiler-parse-decl-origin-syntax-span
                            dispatch
                            (reader.sp-node-get decl-form))]
                        [_ fallback])]
                    [_ fallback])]
                [(= tag (compiler-parse-tag-expr-unsafe))
                  (match (reader.sp-node-get rest)
                    [(reader.SpannedSexpr.Cons inner _ _)
                      (compiler-parse-decl-origin-syntax-span
                        dispatch
                        (reader.sp-node-get inner))]
                    [_ fallback])]
                [else fallback]))]
          [_ fallback])]
      [_ fallback])))

(define (parse-ast-program-forms-into-vec
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [toks : (Array token.SpannedToken)]
  [cur : (Array i64)]
  [out : (&mut out ParseAstDeclVec)]) : ResultParseAstDeclVec
  (if (= (reader.peek-spanned-tag toks cur) (token.tag-end))
    (ResultParseAstDeclVec.Ok)
    (let
      ;; The spanned tree for one top-level form is dead once its AstDecl is
      ;; built (the decl carries AST-pool ids + spans by value, no sp ids), so
      ;; truncate the spanned pool back to here before reading the next form.
      ;; Bounds the spanned pool to a single form so it never has to grow.
      [mark : i64 (reader.sp-node-pool-len)]
      (match (reader.read-form-spanned-result toks cur)
        [(reader.ResultSpannedSexpr.Ok form)
          (let
            [records-start : i64 (reader.sp-node-pool-len)]
            (match (parse-ast-decl-maybe-with-pools dispatch pools form)
              [(ResultAstMaybeDecl.SomeDecl decl)
                (begin
                  (parse-ast-decl-vec-push-with-span
                    out
                    decl
                    (compiler-parse-decl-origin-syntax-span dispatch form))
                  (compiler-parse-member-records-compact! mark records-start)
                  (parse-ast-program-forms-into-vec dispatch pools toks cur out))]
              [(ResultAstMaybeDecl.Decls decls)
                (begin
                  (compiler-parse-member-records-compact! mark records-start)
                  (parse-ast-decl-vec-push-list! out decls)
                  (parse-ast-program-forms-into-vec dispatch pools toks cur out))]
              [(ResultAstMaybeDecl.NoDecl)
                (begin
                  (compiler-parse-member-records-compact! mark records-start)
                  (parse-ast-program-forms-into-vec dispatch pools toks cur out))]
              [(ResultAstMaybeDecl.Err message)
                (begin
                  (reader.sp-node-pool-truncate! mark)
                  (ResultParseAstDeclVec.Err message))]))]
        [(reader.ResultSpannedSexpr.Err err)
          (begin
            (reader.sp-node-pool-truncate! mark)
            (ResultParseAstDeclVec.Err (token.source-error-message err)))]))))

(define (parse-ast-program-forms
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [toks : (Array token.SpannedToken)]
  [cur : (Array i64)]) : ResultAstDeclList
  (let
    [out : ParseAstDeclVec (parse-ast-decl-vec-new)]
    [result : ResultParseAstDeclVec
      (parse-ast-program-forms-into-vec dispatch pools toks cur (&mut out))]
    (match result
      [(ResultParseAstDeclVec.Ok)
        (ResultAstDeclList.Ok (parse-ast-decl-vec-to-list (& out)))]
      [(ResultParseAstDeclVec.Err message) (ResultAstDeclList.Err message)])))

(define (parse-ast-program-dispatch) : sym_i64_env.SymI64Env
  (compiler-parse-dispatch-env))

(define (parse-ast-program-dispatch-with-cfg [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (compiler-parse-dispatch-env-from-cfg cfgs))

(define (parse-ast-program-with-cfg-and-pools
  [toks : (Array token.SpannedToken)]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultAstProgram
  (let
    [cur : (Array i64) (array.make-array i64 1)]
    [base-dispatch : sym_i64_env.SymI64Env
      (parse-ast-program-dispatch-with-cfg cfgs)]
    [invocation : (Array i64) (array.make-array i64 6)]
    [dispatch : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind-id
        base-dispatch
        compiler-parse-invocation-marker-id
        (compiler-parse-array-data-addr-i64 invocation))]
    (begin
      (array-set! cur 0 0)
      (array-set!
        invocation
        compiler-parse-invocation-control-slot
        (compiler-parse-env-marker-value
          base-dispatch
          compiler-parse-state-marker-id))
      (match (parse-ast-program-forms dispatch pools toks cur)
        [(ResultAstDeclList.Ok decls) (ResultAstProgram.Ok (ast-program decls))]
        [(ResultAstDeclList.Err message) (ResultAstProgram.Err message)]))))

(define (parse-ast-program-with-cfg
  [toks : (Array token.SpannedToken)]
  [cfgs : sym_i64_env.SymI64Env]) : ResultAstProgram
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [result : ResultAstProgram
      (parse-ast-program-with-cfg-and-pools toks cfgs pools)]
    (begin
      (ast-node-pool-context-install! pools)
      result)))

(define (parse-ast-program [toks : (Array token.SpannedToken)]) : ResultAstProgram
  (parse-ast-program-with-cfg toks (compiler-cfg-empty)))

(define (parse-ast-source [src : String]) : ResultAstProgram
  (parse-ast-source-with-cfg src (compiler-cfg-empty)))

(define (parse-ast-source-with-cfg-and-pools
  [src : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultAstProgram
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (match (lexer.lex-spanned-result src)
      [(lexer.ResultSpannedTokens.Ok toks)
        (parse-ast-program-with-cfg-and-pools toks cfgs pools)]
      [(lexer.ResultSpannedTokens.Err err)
        (ResultAstProgram.Err (token.source-error-message err))])))

(define (parse-ast-source-with-cfg
  [src : String]
  [cfgs : sym_i64_env.SymI64Env]) : ResultAstProgram
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [result : ResultAstProgram
      (parse-ast-source-with-cfg-and-pools src cfgs pools)]
    (begin
      (ast-node-pool-context-install! pools)
      result)))

(define (parse-ast-repl-module-macro-call-decl? [decl : AstDecl]) : bool
  (match decl
    [(AstDecl.Import
        decl-meta
        (AstImportSpec.Spec
          (AstImportKind.MacroDecls _ _)
          path
          (AstMaybeModuleName.No)
          (AstMaybeImportAlias.No)
          _))
      (string.eq path "")]
    [_ false]))

(define (parse-ast-repl-expr-item
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [form : reader.SpannedSexpr]) : ResultAstReplItem
  (match (parse-ast-expr-with-pools dispatch pools form)
    [(ResultAstExpr.Ok expr) (ResultAstReplItem.Ok (AstReplExpr expr))]
    [(ResultAstExpr.Err message) (ResultAstReplItem.Err message)]))

(define (parse-ast-repl-source-with-pools
  [src : String]
  [pools : AstNodePoolContext]) : ResultAstReplItem
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (let
      [mark : i64 (reader.sp-node-pool-len)]
      (match (lexer.lex-spanned-result src)
        [(lexer.ResultSpannedTokens.Ok toks)
          (let
            [cur : (Array i64) (array.make-array i64 1)]
            [dispatch : sym_i64_env.SymI64Env (parse-ast-program-dispatch)]
            (begin
              (array-set! cur 0 0)
              (if (= (reader.peek-spanned-tag toks cur) (token.tag-end))
                (begin
                  (reader.sp-node-pool-truncate! mark)
                  (ResultAstReplItem.Err "parse: expected REPL input"))
                (match (reader.read-form-spanned-result toks cur)
                  [(reader.ResultSpannedSexpr.Ok form)
                    (let
                      [records-start : i64 (reader.sp-node-pool-len)]
                      (if (= (reader.peek-spanned-tag toks cur) (token.tag-end))
                        (match (parse-ast-decl dispatch pools form)
                          [(ResultAstDecl.Ok decl)
                            (let
                              [result : ResultAstReplItem
                                (if (parse-ast-repl-module-macro-call-decl?
                                  decl)
                                  (parse-ast-repl-expr-item dispatch pools form)
                                  (ResultAstReplItem.Ok (AstReplDecl decl)))]
                              (begin
                                (compiler-parse-member-records-compact!
                                  mark
                                  records-start)
                                result))]
                          [(ResultAstDecl.Err _)
                            (begin
                              (reader.sp-node-pool-truncate! records-start)
                              (let
                                [result : ResultAstReplItem
                                  (parse-ast-repl-expr-item dispatch pools form)]
                                (begin
                                  (reader.sp-node-pool-truncate! mark)
                                  result)))])
                        (begin
                          (reader.sp-node-pool-truncate! mark)
                          (ResultAstReplItem.Err
                            "parse: trailing tokens after REPL input"))))]
                  [(reader.ResultSpannedSexpr.Err err)
                    (begin
                      (reader.sp-node-pool-truncate! mark)
                      (ResultAstReplItem.Err (token.source-error-message err)))]))))]
        [(lexer.ResultSpannedTokens.Err err)
          (begin
            (reader.sp-node-pool-truncate! mark)
            (ResultAstReplItem.Err (token.source-error-message err)))]))))

(define (parse-ast-repl-source [src : String]) : ResultAstReplItem
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [result : ResultAstReplItem (parse-ast-repl-source-with-pools src pools)]
    (begin
      (ast-node-pool-context-install! pools)
      result)))

(define (parse-ast-canonical-diagnostic [diag : CompilerDiagnostic]) : CompilerDiagnostic
  (let
    [canonical : CompilerDiagnostic
      (compiler-diagnostic-with-category
        (compiler-diagnostic-with-code diag (compiler-diagnostic-code-parse))
        "parse")]
    (if (parse-ast-if-message? (compiler-diagnostic-message canonical))
      (parse-ast-if-diagnostic-notes canonical)
      canonical)))

(define (parse-ast-program-forms-diagnostic-into-vec
  [path : String]
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [toks : (Array token.SpannedToken)]
  [cur : (Array i64)]
  [out : (&mut out ParseAstDeclVec)]) : ResultParseAstDeclVecDiagnostic
  (if (= (reader.peek-spanned-tag toks cur) (token.tag-end))
    (ResultParseAstDeclVecDiagnostic.Ok)
    (let
      ;; Bound the spanned pool to a single top-level form (see
      ;; parse-ast-program-forms): the decl carries no sp ids, so truncate back
      ;; before reading the next form.
      [mark : i64 (reader.sp-node-pool-len)]
      (match (reader.read-form-spanned-result toks cur)
        [(reader.ResultSpannedSexpr.Ok spanned-form)
          (let
            [records-start : i64 (reader.sp-node-pool-len)]
            (begin
              (parse-ast-error-span-clear! dispatch)
              (match (parse-ast-decl-maybe-with-pools
                dispatch
                pools
                spanned-form)
                [(ResultAstMaybeDecl.SomeDecl decl)
                  (begin
                    (parse-ast-decl-vec-push-with-span
                      out
                      decl
                      (compiler-parse-decl-origin-syntax-span
                        dispatch
                        spanned-form))
                    (compiler-parse-member-records-compact! mark records-start)
                    (parse-ast-program-forms-diagnostic-into-vec
                      path
                      dispatch
                      pools
                      toks
                      cur
                      out))]
                [(ResultAstMaybeDecl.Decls decls)
                  (begin
                    (compiler-parse-member-records-compact! mark records-start)
                    (parse-ast-decl-vec-push-list! out decls)
                    (parse-ast-program-forms-diagnostic-into-vec
                      path
                      dispatch
                      pools
                      toks
                      cur
                      out))]
                [(ResultAstMaybeDecl.NoDecl)
                  (begin
                    (compiler-parse-member-records-compact! mark records-start)
                    (parse-ast-program-forms-diagnostic-into-vec
                      path
                      dispatch
                      pools
                      toks
                      cur
                      out))]
                [(ResultAstMaybeDecl.Err message)
                  (begin
                    (reader.sp-node-pool-truncate! mark)
                    (ResultParseAstDeclVecDiagnostic.Err
                      (box
                        (parse-ast-canonical-diagnostic
                          (compiler-diagnostic-from-span
                            path
                            (parse-ast-error-span-current
                              dispatch
                              (reader.spanned-sexpr-span spanned-form))
                            message)))))])))]
        [(reader.ResultSpannedSexpr.Err err)
          (begin
            (reader.sp-node-pool-truncate! mark)
            (ResultParseAstDeclVecDiagnostic.Err
              (box
                (parse-ast-canonical-diagnostic
                  (compiler-diagnostic-from-source-error path err)))))]))))

(define (parse-ast-program-forms-diagnostic
  [path : String]
  [dispatch : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [toks : (Array token.SpannedToken)]
  [cur : (Array i64)]) : ResultAstDeclListDiagnostic
  (let
    [out : ParseAstDeclVec (parse-ast-decl-vec-new)]
    [result : ResultParseAstDeclVecDiagnostic
      (parse-ast-program-forms-diagnostic-into-vec
        path
        dispatch
        pools
        toks
        cur
        (&mut out))]
    (match result
      [(ResultParseAstDeclVecDiagnostic.Ok)
        (ResultAstDeclListDiagnostic.Ok (parse-ast-decl-vec-to-list (& out)))]
      [(ResultParseAstDeclVecDiagnostic.Err diag)
        (ResultAstDeclListDiagnostic.Err diag)])))

(define (parse-ast-program-diagnostic
  [path : String]
  [toks : (Array token.SpannedToken)]) : ResultAstProgramDiagnostic
  (parse-ast-program-diagnostic-with-cfg path toks (compiler-cfg-empty)))

(define (parse-ast-program-diagnostic-with-cfg-and-pools
  [path : String]
  [toks : (Array token.SpannedToken)]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultAstProgramDiagnostic
  (let
    [cur : (Array i64) (array.make-array i64 1)]
    [base-dispatch : sym_i64_env.SymI64Env
      (parse-ast-program-dispatch-with-cfg cfgs)]
    [invocation : (Array i64) (array.make-array i64 6)]
    [dispatch : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind-id
        base-dispatch
        compiler-parse-invocation-marker-id
        (compiler-parse-array-data-addr-i64 invocation))]
    (begin
      (array-set! cur 0 0)
      (array-set!
        invocation
        compiler-parse-invocation-control-slot
        (compiler-parse-env-marker-value
          base-dispatch
          compiler-parse-state-marker-id))
      (match (parse-ast-program-forms-diagnostic path dispatch pools toks cur)
        [(ResultAstDeclListDiagnostic.Ok decls)
          (ResultAstProgramDiagnostic.Ok (ast-program decls))]
        [(ResultAstDeclListDiagnostic.Err diag)
          (ResultAstProgramDiagnostic.Err diag)]))))

(define (parse-ast-program-diagnostic-with-cfg
  [path : String]
  [toks : (Array token.SpannedToken)]
  [cfgs : sym_i64_env.SymI64Env]) : ResultAstProgramDiagnostic
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [result : ResultAstProgramDiagnostic
      (parse-ast-program-diagnostic-with-cfg-and-pools path toks cfgs pools)]
    (begin
      (ast-node-pool-context-install! pools)
      result)))

(define (parse-ast-source-diagnostic [path : String] [src : String]) : ResultAstProgramDiagnostic
  (parse-ast-source-diagnostic-with-cfg path src (compiler-cfg-empty)))

(define (parse-ast-source-diagnostic-with-cfg-and-pools
  [path : String]
  [src : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultAstProgramDiagnostic
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (match (lexer.lex-spanned-result src)
      [(lexer.ResultSpannedTokens.Ok toks)
        (parse-ast-program-diagnostic-with-cfg-and-pools path toks cfgs pools)]
      [(lexer.ResultSpannedTokens.Err err)
        (ResultAstProgramDiagnostic.Err
          (box
            (parse-ast-canonical-diagnostic
              (compiler-diagnostic-from-source-error path err))))])))

(define (parse-ast-source-diagnostic-with-cfg
  [path : String]
  [src : String]
  [cfgs : sym_i64_env.SymI64Env]) : ResultAstProgramDiagnostic
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [result : ResultAstProgramDiagnostic
      (parse-ast-source-diagnostic-with-cfg-and-pools path src cfgs pools)]
    (begin
      (ast-node-pool-context-install! pools)
      result)))

(define (ast-decl-list-count [decls : AstDeclList]) : i64
  (ast-decl-list-len (& decls)))

(define (ast-decl-list-tag-sum [decls : AstDeclList]) : i64
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) 0]
    [(AstDeclListStep.Cons decl rest)
      (let
        [rest : AstDeclList rest]
        (+ (ast-decl-tag decl) (ast-decl-list-tag-sum rest)))]))

(define (compiler-parse-expr-list-count [exprs : AstExprList]) : i64
  (struct-get (& exprs) len))

(define (compiler-parse-macro-call-node-ok?
  [call-expr : i64]
  [name : String]
  [want-args : i64]) : bool
  (match (ast-expr-unspan (ast-node-get call-expr))
    [(AstExpr.Call head args)
      (let
        [head-expr : AstExpr (ast-node-get head)]
        (and
          (= (compiler-parse-expr-list-count args) want-args)
          (match (ast-expr-unspan head-expr)
            [(AstExpr.Var found) (string.eq (intern-str found) name)]
            [_ false])))]
    [_ false]))

(define (compiler-parse-resource-binding-count
  [bindings : AstResourceBindingList]) : i64
  (ast-resource-binding-list-len (& bindings)))

(define (ast-first-import-ok? [decls : AstDeclList]) : bool
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Cons
        (AstDecl.Import
          ast-decl-meta-runtime
          (AstImportSpec.Spec (AstImportKind.Path) path _ _ _))
        _)
      (string.eq path "stdlib/test.tl")]
    [_ false]))

(define (ast-first-include-str-ok? [decls : AstDeclList]) : bool
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Cons (AstDecl.IncludeStr name path) _)
      (and (string.eq (intern-str name) "payload") (string.eq path "data.txt"))]
    [_ false]))

(define (ast-first-include-str-comptime-ok? [decls : AstDeclList]) : bool
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Cons (AstDecl.IncludeStrComptime name path) _)
      (and (string.eq (intern-str name) "payload") (string.eq path "data.txt"))]
    [_ false]))

(define (ast-first-include-str-lzss-ok? [decls : AstDeclList]) : bool
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Cons (AstDecl.IncludeStrLzss name path) _)
      (and (string.eq (intern-str name) "payload") (string.eq path "data.txt"))]
    [_ false]))

(define (ast-first-include-bin-ok? [decls : AstDeclList]) : bool
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Cons (AstDecl.IncludeBin name path) _)
      (and (string.eq (intern-str name) "payload") (string.eq path "data.bin"))]
    [_ false]))

(define (compiler-parse-module-decl-ok?) : bool
  (match (parse-ast-source "(module std.io)")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons (AstDecl.Module name) rest)
            (let
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (= name (reader.read-stable-symbol-id "std.io"))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-module-body-ok?) : bool
  (match (parse-ast-source "(module local.helper (define value : i64 1))")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons (AstDecl.ModuleBody name body-box) rest)
            (let
              [rest : AstDeclList rest]
              [body : AstDeclList (box-get body-box)]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (match (ast-decl-list-step body)
                    [(AstDeclListStep.Cons
                        (AstDecl.Def ast-decl-meta-runtime value-name _ _)
                        body-rest)
                      (let
                        [body-rest : AstDeclList body-rest]
                        (and
                          (= name (reader.read-stable-symbol-id "local.helper"))
                          (= value-name (reader.read-stable-symbol-id "value"))
                          (match (ast-decl-list-step body-rest)
                            [(AstDeclListStep.Nil) true]
                            [_ false])))]
                    [_ false])]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-module-body-malformed-ok?) : bool
  (match (parse-ast-source "(module local.helper (define bad))")
    [(ResultAstProgram.Ok _) false]
    [(ResultAstProgram.Err message)
      (string.eq message "parse: malformed value definition")]))

(define (compiler-parse-import-metadata-ok?) : bool
  (match (parse-ast-source "(import \"stdlib/tl\" module std.io :as io)")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons
              (AstDecl.Import
                ast-decl-meta-runtime
                (AstImportSpec.Spec
                  (AstImportKind.Path)
                  path
                  (AstMaybeModuleName.Some module-name)
                  (AstMaybeImportAlias.Some alias)
                  _))
              rest)
            (let
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (and
                    (string.eq path "stdlib/tl")
                    (string.eq (ci.intern-str module-name) "std.io")
                    (string.eq (ci.intern-str alias) "io"))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-dotted-import-explicit-alias-ok?) : bool
  (match (parse-ast-source "(import stdlib.core_macros :as core)")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons
              (AstDecl.Import
                ast-decl-meta-runtime
                (AstImportSpec.Spec
                  (AstImportKind.Module)
                  module-path
                  (AstMaybeModuleName.Some module-name)
                  (AstMaybeImportAlias.Some alias)
                  _))
              rest)
            (let
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (and
                    (string.eq module-path "stdlib.core_macros")
                    (string.eq (ci.intern-str module-name) "stdlib.core_macros")
                    (string.eq (ci.intern-str alias) "core"))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-dotted-import-default-alias-ok?) : bool
  (match (parse-ast-source "(import stdlib.core_macros)")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons
              (AstDecl.Import
                ast-decl-meta-runtime
                (AstImportSpec.Spec
                  (AstImportKind.Module)
                  module-path
                  (AstMaybeModuleName.Some module-name)
                  (AstMaybeImportAlias.Some alias)
                  _))
              rest)
            (let
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (and
                    (string.eq module-path "stdlib.core_macros")
                    (string.eq (ci.intern-str module-name) "stdlib.core_macros")
                    (string.eq (ci.intern-str alias) "core_macros"))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-dotted-import-metadata-ok?) : bool
  (and
    (compiler-parse-dotted-import-explicit-alias-ok?)
    (compiler-parse-dotted-import-default-alias-ok?)))

(define (compiler-parse-module-macro-call-ok?) : bool
  (match (parse-ast-source "(point-vec i64)")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons
              (AstDecl.Import
                ast-decl-meta-runtime
                (AstImportSpec.Spec
                  (AstImportKind.MacroDecls call-expr _)
                  path
                  (AstMaybeModuleName.No)
                  (AstMaybeImportAlias.No)
                  _))
              rest)
            (let
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (and
                    (string.eq path "")
                    (compiler-parse-macro-call-node-ok? call-expr "point-vec" 1))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-macro-import-ok?) : bool
  (match (parse-ast-source "(import (vector.vector i64) as svec)")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons
              (AstDecl.Import
                ast-decl-meta-runtime
                (AstImportSpec.Spec
                  (AstImportKind.Macro call-expr _)
                  path
                  (AstMaybeModuleName.No)
                  (AstMaybeImportAlias.Some alias)
                  _))
              rest)
            (let
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (and
                    (string.eq path "")
                    (string.eq (ci.intern-str alias) "svec")
                    (compiler-parse-macro-call-node-ok?
                      call-expr
                      "vector.vector"
                      1))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-module-macro-surface-ok?) : bool
  (and
    (compiler-parse-module-macro-call-ok?)
    (compiler-parse-macro-import-ok?)
    (compiler-parse-error-ok? "(import vector i64)" "parse: malformed import")))

(define (compiler-parse-dotted-import-errors-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(import stdlib..core)"
      "parse: invalid dotted import module name")
    (compiler-parse-error-ok?
      "(import stdlib/core)"
      "parse: invalid dotted import module name")
    (compiler-parse-error-ok?
      "(import pkg:math.core)"
      "parse: invalid dotted import module name")
    (compiler-parse-error-ok?
      "(import stdlib.core_macros module stdlib.core_macros)"
      "parse: malformed import")))

(define (compiler-parse-include-str-ok?) : bool
  (match (parse-ast-source "(include-str payload \"data.txt\")")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (ast-first-include-str-ok? decls))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-include-str-errors-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(include-str)"
      "parse: include-str expects name and string path")
    (compiler-parse-error-ok?
      "(include-str \"name\" \"data.txt\")"
      "parse: include-str name must be a symbol")
    (compiler-parse-error-ok?
      "(include-str payload data.txt)"
      "parse: include-str path must be a string")
    (compiler-parse-error-ok?
      "(include-str payload \"data.txt\" extra)"
      "parse: include-str expects exactly two operands")
    (compiler-parse-error-ok?
      "(include-str payload)"
      "parse: include-str expects name and string path")))

(define (compiler-parse-include-str-comptime-ok?) : bool
  (match (parse-ast-source "(include-str-comptime payload \"data.txt\")")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (ast-first-include-str-comptime-ok? (box-get decls-box))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-include-str-comptime-errors-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(include-str-comptime)"
      "parse: include-str-comptime expects name and string path")
    (compiler-parse-error-ok?
      "(include-str-comptime \"name\" \"data.txt\")"
      "parse: include-str-comptime name must be a symbol")
    (compiler-parse-error-ok?
      "(include-str-comptime payload data.txt)"
      "parse: include-str-comptime path must be a string")
    (compiler-parse-error-ok?
      "(include-str-comptime payload \"data.txt\" extra)"
      "parse: include-str-comptime expects exactly two operands")))

(define (compiler-parse-include-str-lzss-ok?) : bool
  (match (parse-ast-source "(include-str-lzss payload \"data.txt\")")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (ast-first-include-str-lzss-ok? (box-get decls-box))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-include-str-lzss-errors-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(include-str-lzss)"
      "parse: include-str-lzss expects name and string path")
    (compiler-parse-error-ok?
      "(include-str-lzss \"name\" \"data.txt\")"
      "parse: include-str-lzss name must be a symbol")
    (compiler-parse-error-ok?
      "(include-str-lzss payload data.txt)"
      "parse: include-str-lzss path must be a string")
    (compiler-parse-error-ok?
      "(include-str-lzss payload \"data.txt\" extra)"
      "parse: include-str-lzss expects exactly two operands")))

(define (compiler-parse-removed-compressed-include-rejected?) : bool
  (compiler-parse-error-ok?
    (string.append
      "("
      (string.append
        (compiler-parse-removed-compressed-include-name)
        " payload \"data.txt\")"))
    (compiler-parse-removed-compressed-include-message)))

(define (compiler-parse-include-bin-ok?) : bool
  (match (parse-ast-source "(include-bin payload \"data.bin\")")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (ast-first-include-bin-ok? decls))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-include-bin-errors-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(include-bin)"
      "parse: include-bin expects name and string path")
    (compiler-parse-error-ok?
      "(include-bin \"name\" \"data.bin\")"
      "parse: include-bin name must be a symbol")
    (compiler-parse-error-ok?
      "(include-bin payload data.bin)"
      "parse: include-bin path must be a string")
    (compiler-parse-error-ok?
      "(include-bin payload \"data.bin\" extra)"
      "parse: include-bin expects exactly two operands")
    (compiler-parse-error-ok?
      "(include-bin payload)"
      "parse: include-bin expects name and string path")))

(define (compiler-parse-defdispatch-variants-ok?
  [variants : AstDispatchVariantList]) : bool
  (if (= (struct-get (& variants) len) 3)
    (match (ast-dispatch-variant-list-get
      (& variants)
      0
      (ast-dispatch-variant-fallback))
      [(AstDispatchVariant.Variant (AstDispatchIsa.Scalar) scalar-name)
        (match (ast-dispatch-variant-list-get
          (& variants)
          1
          (ast-dispatch-variant-fallback))
          [(AstDispatchVariant.Variant (AstDispatchIsa.Avx2) avx2-name)
            (match (ast-dispatch-variant-list-get
              (& variants)
              2
              (ast-dispatch-variant-fallback))
              [(AstDispatchVariant.Variant (AstDispatchIsa.Avx512) avx512-name)
                (and
                  (= scalar-name (reader.read-stable-symbol-id "dot-scalar"))
                  (= avx2-name (reader.read-stable-symbol-id "dot-avx2"))
                  (= avx512-name (reader.read-stable-symbol-id "dot-avx512")))]
              [_ false])]
          [_ false])]
      [_ false])
    false))

(define (compiler-parse-defdispatch-shape-ok?) : bool
  (match (parse-ast-source
    "(defdispatch dot (scalar dot-scalar) (avx2 dot-avx2) (avx512 dot-avx512))")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons
              (AstDecl.DefDispatch decl-meta name variants)
              rest)
            (let
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (and
                    (= name (reader.read-stable-symbol-id "dot"))
                    (compiler-parse-defdispatch-variants-ok? variants))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-defdispatch-scalar-only-ok?) : bool
  (match (parse-ast-source "(defdispatch id (scalar id-scalar))")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons
              (AstDecl.DefDispatch decl-meta name variants)
              rest)
            (let
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (and
                    (= name (reader.read-stable-symbol-id "id"))
                    (= (struct-get (& variants) len) 1)
                    (match (ast-dispatch-variant-list-get
                      (& variants)
                      0
                      (ast-dispatch-variant-fallback))
                      [(AstDispatchVariant.Variant
                          (AstDispatchIsa.Scalar)
                          scalar-name)
                        (=
                          scalar-name
                          (reader.read-stable-symbol-id "id-scalar"))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-defdispatch-tests-ok?) : bool
  (and
    (compiler-parse-defdispatch-shape-ok?)
    (compiler-parse-defdispatch-scalar-only-ok?)
    (compiler-parse-error-ok?
      "(defdispatch dot)"
      "parse: defdispatch needs at least one variant")
    (compiler-parse-error-ok?
      "(defdispatch dot (sse2 dot-sse2))"
      "parse: unknown defdispatch ISA sse2")
    (compiler-parse-error-ok?
      "(defdispatch dot (scalar))"
      "parse: malformed defdispatch variant")))

(define (ast-expr-inner-tag [expr : AstExpr]) : i64
  (ast-expr-tag (ast-expr-unspan expr)))

(define (ast-main-body-tag [decls : AstDeclList]) : i64
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) 0]
    [(AstDeclListStep.Cons decl rest)
      (let
        [rest : AstDeclList rest]
        (match decl
          [(AstDecl.DefFn decl-meta name _ _ body-box _)
            (let
              [body : AstExpr (ast-node-get body-box)]
              (if (= name cbi.compiler-builtin-id-fix-main)
                (ast-expr-inner-tag body)
                (ast-main-body-tag rest)))]
          [_ (ast-main-body-tag rest)]))]))

(define (compiler-parse-nested-expr-span-ok?) : bool
  (match (parse-ast-source "(define (main) : i64 (+ 1 (* 2 3)))")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons (AstDecl.DefFn decl-meta _ _ _ body-box _) _)
            (let
              [body : AstExpr (ast-node-get body-box)]
              (match body
                [(AstExpr.Spanned inner-box body-span)
                  (let
                    [inner : AstExpr (ast-node-get inner-box)]
                    (match inner
                      [(AstExpr.Binary _ _ right-box)
                        (let
                          [right : AstExpr (ast-node-get right-box)]
                          (match right
                            [(AstExpr.Spanned right-inner-box right-span)
                              (let
                                [right-inner : AstExpr
                                  (ast-node-get right-inner-box)]
                                (match right-inner
                                  [(AstExpr.Binary _ _ _)
                                    (and
                                      (=
                                        (ast-source-span-start-line body-span)
                                        1)
                                      (=
                                        (ast-source-span-start-line right-span)
                                        1)
                                      (>
                                        (ast-source-span-start-col right-span)
                                        (ast-source-span-start-col body-span)))]
                                  [_ false]))]
                            [_ false]))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [_ false]))

(define (compiler-parse-error-span-ok?) : bool
  (let
    [src : String "(define)"]
    (and
      (match (parse-ast-source src)
        [(ResultAstProgram.Err message)
          (string.eq message "parse: malformed define")]
        [_ false])
      (match (lexer.lex-spanned-result src)
        [(lexer.ResultSpannedTokens.Ok toks)
          (let
            [cur : (Array i64) (make-array i64 1)]
            (begin
              (array-set! cur 0 0)
              (match (reader.read-form-spanned-result toks cur)
                [(reader.ResultSpannedSexpr.Ok form)
                  (let
                    [span : token.SourceSpan (reader.spanned-sexpr-span form)]
                    (and
                      (= (token.span-start-line span) 1)
                      (= (token.span-start-col span) 1)))]
                [(reader.ResultSpannedSexpr.Err _) false])))]
        [(lexer.ResultSpannedTokens.Err _) false]))))

(define (compiler-parse-reader-diagnostic-ok?
  [path : String]
  [src : String]
  [want : String]
  [line : i64]
  [col : i64]) : bool
  (match (parse-ast-source-diagnostic path src)
    [(ResultAstProgramDiagnostic.Err diag)
      (and
        (string.eq (compiler-diagnostic-path (box-get diag)) path)
        (= (compiler-diagnostic-line (box-get diag)) line)
        (= (compiler-diagnostic-col (box-get diag)) col)
        (string.eq (compiler-diagnostic-message (box-get diag)) want))]
    [(ResultAstProgramDiagnostic.Ok _) false]))

(define (compiler-parse-diagnostic-location-ok?
  [path : String]
  [src : String]
  [want : String]
  [line : i64]
  [col : i64]) : bool
  (match (parse-ast-source-diagnostic path src)
    [(ResultAstProgramDiagnostic.Err diag)
      (and
        (string.eq (compiler-diagnostic-path (box-get diag)) path)
        (= (compiler-diagnostic-line (box-get diag)) line)
        (= (compiler-diagnostic-col (box-get diag)) col)
        (string.eq (compiler-diagnostic-message (box-get diag)) want))]
    [(ResultAstProgramDiagnostic.Ok _) false]))

(define (compiler-parse-nested-diagnostic-spans-ok?) : bool
  (and
    (compiler-parse-diagnostic-location-ok?
      "bad-define.tl"
      "(define)"
      "parse: malformed define"
      1
      1)
    (compiler-parse-diagnostic-location-ok?
      "nested-binary.tl"
      "(define (main) : i64
  (+ 1))"
      "parse: malformed binary expression"
      2
      3)
    (compiler-parse-diagnostic-location-ok?
      "nested-let.tl"
      "(define (main) : i64
  (let [x : i64 1]))"
      "parse: let missing body"
      2
      3)
    (compiler-parse-diagnostic-location-ok?
      "annotation-type.tl"
      "(define (main) : i64
  (cast 1 : (Ptr)))"
      "parse: Ptr expects exactly one type"
      2
      13)
    (compiler-parse-diagnostic-location-ok?
      "let-binding.tl"
      "(define (main) : i64
  (let [x : i64] x))"
      "parse: malformed let binding"
      2
      8)
    (compiler-parse-diagnostic-location-ok?
      "legacy-let-bindings.tl"
      "(define (main) : i64
  (let ([x : i64 1]) x))"
      "parse: parenthesized let bindings were removed; write leading [name [: type] init] bindings without parentheses"
      2
      8)
    (compiler-parse-diagnostic-location-ok?
      "legacy-empty-let.tl"
      "(define (main) : i64
  (let () 0))"
      "parse: (let () body...) was removed; write (let [] body...)"
      2
      8)))

(define (compiler-parse-reader-delimiter-diagnostics-ok?) : bool
  (and
    (compiler-parse-reader-diagnostic-ok?
      "missing-paren.tl"
      "(define (main) : i64 0"
      "reader: unterminated list: reached end of input before ')'"
      1
      1)
    (compiler-parse-reader-diagnostic-ok?
      "missing-bracket.tl"
      "["
      "reader: unterminated list: reached end of input before ']'"
      1
      1)
    (compiler-parse-reader-diagnostic-ok?
      "wrong-close-list.tl"
      "(define]"
      "reader: mismatched delimiter: expected ')' but found ']' at 1:8"
      1
      8)
    (compiler-parse-reader-diagnostic-ok?
      "wrong-close-bracket.tl"
      "[define)"
      "reader: mismatched delimiter: expected ']' but found ')' at 1:8"
      1
      8)))

(define (compiler-parse-float-literal-ok?) : bool
  (match (parse-ast-source "(define (main) : f64 1.5)")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons
              (AstDecl.DefFn
                ast-decl-meta-runtime
                name
                _
                (AstType.F64)
                body-box
                _)
              _)
            (let
              [body : AstExpr (ast-node-get body-box)]
              (and
                (= name cbi.compiler-builtin-id-fix-main)
                (match (ast-expr-unspan body)
                  [(AstExpr.Literal (AstLiteral.Float text))
                    (string.eq text "1.5")]
                  [_ false])))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-smoke-source) : String
  "(import \"stdlib/test.tl\")
(defstruct Point (x i64) (y i64))
(defenum Maybe (None) (Some i64))
(extern (io.print-string [arg0 : String]) : unit)
(define answer : i64 42)
(define (main [argc : i64] [name : String]) : i64
  (let
    [x : i64 1]
    [arr (array 1 2 3)]
      (begin
        (set! x (+ x 41))
        (cond
          [(and (= x 42) true)
          (match (Some x) [(Some v) v] [_ 0])]
          [else 0]))))")

(define (compiler-parse-smoke-score [program : AstProgram]) : i64
  (match program
    [(AstProgram.Program decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        (+
          (ast-decl-list-count decls)
          (+
            (ast-decl-list-tag-sum decls)
            (+
              (ast-main-body-tag decls)
              (if (ast-first-import-ok? decls)
                1
                0)))))]))

;; True only when `src` fails to parse with exactly the wanted diagnostic. The
;; counterpart to the success-path smoke: it pins the parser's rejection
;; messages so a regression that drops or relabels an error is caught.
(define (compiler-parse-error-ok? [src : String] [want : String]) : bool
  (match (parse-ast-source src)
    [(ResultAstProgram.Err message) (string.eq message want)]
    [(ResultAstProgram.Ok _) false]))

(define (compiler-parse-error-ok-with-cfg?
  [src : String]
  [cfgs : sym_i64_env.SymI64Env]
  [want : String]) : bool
  (match (parse-ast-source-with-cfg src cfgs)
    [(ResultAstProgram.Err message) (string.eq message want)]
    [(ResultAstProgram.Ok _) false]))

(define (compiler-parse-diagnostic-code-ok?) : bool
  (match (parse-ast-source-diagnostic
    "parse-code.tl"
    (compiler-parse-malformed-binary-source))
    [(ResultAstProgramDiagnostic.Err diag)
      (match (compiler-diagnostic-code (box-get diag))
        [(CompilerDiagnosticSomeString code)
          (and
            (string.eq code (compiler-diagnostic-code-parse))
            (match (compiler-diagnostic-category (box-get diag))
              [(CompilerDiagnosticSomeString category)
                (string.eq category "parse")]
              [CompilerDiagnosticNoString false]))]
        [CompilerDiagnosticNoString false])]
    [(ResultAstProgramDiagnostic.Ok _) false]))

;; Minimal complete programs that lex cleanly but reach a specific parser
;; rejection, one per representative special form.
(define (compiler-parse-malformed-binary-source) : String
  "(define (main) : i64 (+ 1))")

(define (compiler-parse-malformed-if-source) : String
  "(define (main) : i64 (if true 1))")

(define (compiler-parse-if-missing-else-diagnostic-notes-ok?) : bool
  (match (parse-ast-source-diagnostic
    "missing-if-else.tl"
    (compiler-parse-malformed-if-source))
    [(ResultAstProgramDiagnostic.Err diag)
      (let
        [rendered : String (compiler-diagnostic-render (box-get diag))]
        [message-needle : String "parse: if is missing its else branch"]
        [example-needle : String "example: (if condition then-expr else-expr)"]
        [when-needle : String "when condition body..."]
        [unless-needle : String "unless condition body..."]
        (and
          (string.contains (& rendered) (& message-needle))
          (string.contains (& rendered) (& example-needle))
          (string.contains (& rendered) (& when-needle))
          (string.contains (& rendered) (& unless-needle))))]
    [(ResultAstProgramDiagnostic.Ok _) false]))

(define (compiler-parse-malformed-while-source) : String
  "(define (main) : i64 (while true))")

(define (compiler-parse-malformed-set-source) : String
  "(define (main) : i64 (set! x))")

(define (compiler-parse-bracket-cond-source) : String
  "(define (main) : i64 (cond [(= 1 1) 1] [else 0]))")

(define (compiler-parse-qualified-bracket-cond-source) : String
  "(define (main) : i64 (core.cond [(= 1 1) 1] [else 0]))")

(define (compiler-parse-region-source) : String
  "(define (main) : (in r String)
  (with-arena r \"x\"))")

(define (compiler-parse-with-region-empty-source) : String
  "(define (main) : i64 (with-arena r))")

(define (compiler-parse-region-type-bad-source) : String
  "(define (main) : (in 1 String) 0)")

(define (compiler-parse-region-ok?) : bool
  (match (parse-ast-source (compiler-parse-region-source))
    [(ResultAstProgram.Ok _) true]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-arena-source) : String
  "(define (main) : i64
  (with-arena n 5))")

;; `with-arena` is the canonical spelling. Assert it parses to
;; the `AstExpr.WithRegion` form, not an unbound call.
(define (compiler-parse-arena-ok?) : bool
  (match (parse-ast-source (compiler-parse-arena-source))
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons
              (AstDecl.DefFn
                ast-decl-meta-runtime
                name
                _
                (AstType.I64)
                body-box
                _)
              _)
            (let
              [body : AstExpr (ast-node-get body-box)]
              (and
                (= name cbi.compiler-builtin-id-fix-main)
                (match (ast-expr-unspan body)
                  [(AstExpr.WithRegion region _)
                    (= region cbi.compiler-builtin-id-fix-n)]
                  [_ false])))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-raw-pointer-source) : String
  "(extern (raw-map [arg0 : (Ptr i64)]) : (MutPtr (Ptr u8)))")

(define (compiler-parse-type-ptr-u8? [ty : AstType]) : bool
  (match ty
    [(AstType.Ptr elem)
      (match (ty-node-get elem)
        [(AstType.U8) true]
        [_ false])]
    [_ false]))

(define (compiler-parse-type-ptr-i64? [ty : AstType]) : bool
  (match ty
    [(AstType.Ptr elem)
      (match (ty-node-get elem)
        [(AstType.I64) true]
        [_ false])]
    [_ false]))

(define (compiler-parse-type-mut-ptr-u8? [ty : AstType]) : bool
  (match ty
    [(AstType.MutPtr elem)
      (match (ty-node-get elem)
        [(AstType.U8) true]
        [_ false])]
    [_ false]))

(define (compiler-parse-type-mut-ptr-ptr-u8? [ty : AstType]) : bool
  (match ty
    [(AstType.MutPtr elem) (compiler-parse-type-ptr-u8? (ty-node-get elem))]
    [_ false]))

(define (compiler-parse-type-ref-string? [ty : AstType] [region : i64]) : bool
  (match ty
    [(AstType.Ref actual inner)
      (and
        (= actual region)
        (match (ty-node-get inner)
          [(AstType.String) true]
          [_ false]))]
    [_ false]))

(define (compiler-parse-type-ref-str? [ty : AstType] [region : i64]) : bool
  (match ty
    [(AstType.Ref actual inner)
      (and
        (= actual region)
        (match (ty-node-get inner)
          [(AstType.Str) true]
          [_ false]))]
    [_ false]))

(define (compiler-parse-type-mut-ref-dyn-array-i64?
  [ty : AstType]
  [region : i64]) : bool
  (match ty
    [(AstType.MutRef actual inner)
      (and
        (= actual region)
        (match (ty-node-get inner)
          [(AstType.DynArray elem)
            (match (ty-node-get elem)
              [(AstType.I64) true]
              [_ false])]
          [_ false]))]
    [_ false]))

(define (compiler-parse-extern-metadata-source) : String
  "(extern (local-call [arg0 : i64]) : i64 (:abi c) (:symbol \"foreign_exact\") (:link-lib \"m\") (:link-search \"native/lib\") (:link-arg \"-Wl,--as-needed\"))")

(define (compiler-parse-extern-varargs-metadata-source) : String
  "(extern (snprintf [arg0 : (MutPtr u8)] [arg1 : i64] [arg2 : (Ptr u8)] [arg3 : f64]) : i32 (:abi c-varargs 3) (:symbol \"snprintf\"))")

(define (compiler-parse-extern-function-head-varargs-source) : String
  "(extern (snprintf [buf : (MutPtr u8)] [len : i64] [fmt : (Ptr u8)] [arg : ...f64]) : i32 (:symbol \"snprintf\"))
(extern (printf [fmt : (Ptr u8)] ...) : i32 (:symbol \"printf\"))
(extern (local-add [a : i64] [b : i64]) : i64 (:symbol \"foreign_add_exact\"))")

(define (compiler-parse-define-export-symbol-source) : String
  "(define (_write [fd : i32] [buf : (Ptr u8)] [n : i32]) (:export-symbol \"_write\") : i32
  0)")

(define (compiler-parse-param-list-count [params : AstParamList]) : i64
  (ast-param-list-len (& params)))

(define (compiler-parse-type-list-count [types : AstTypeList]) : i64
  (ast-type-list-len (& types)))

(define (compiler-parse-raw-pointer-ops-source) : String
  "(define (main [p : (MutPtr i64)] [n : u64]) : u64
  (unsafe
    (ptr-write! p (ptr-read p))
    (ptr->int (ptr-cast (ptr-offset (int->ptr n : (MutPtr i64)) 1) : (Ptr i64)))))")

(define (compiler-parse-raw-pointer-ok?) : bool
  (match (parse-ast-source (compiler-parse-raw-pointer-source))
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons (AstDecl.Extern decl-meta name _ _ ty) rest)
            (let
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (and
                    (= name (reader.read-stable-symbol-id "raw-map"))
                    (match ty
                      [(AstType.Func args ret)
                        (let
                          [args-list : AstTypeList (box-get args)]
                          (and
                            (= (ast-type-list-len (& args-list)) 1)
                            (compiler-parse-type-ptr-i64?
                              (ty-node-get
                                (ast-type-list-get
                                  (& args-list)
                                  0
                                  (ast-type-id-fallback))))
                            (compiler-parse-type-mut-ptr-ptr-u8?
                              (ty-node-get ret))))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-extern-link-inputs-ok?
  [inputs : AstExternLinkInputList]) : bool
  (and
    (= (ast-extern-link-input-list-len (& inputs)) 3)
    (match (ast-extern-link-input-list-get
      (& inputs)
      0
      (ast-extern-link-input-fallback))
      [(AstExternLinkInput.Lib lib) (string.eq lib "m")]
      [_ false])
    (match (ast-extern-link-input-list-get
      (& inputs)
      1
      (ast-extern-link-input-fallback))
      [(AstExternLinkInput.Search dir) (string.eq dir "native/lib")]
      [_ false])
    (match (ast-extern-link-input-list-get
      (& inputs)
      2
      (ast-extern-link-input-fallback))
      [(AstExternLinkInput.Arg arg-value)
        (string.eq arg-value "-Wl,--as-needed")]
      [_ false])))

(define (compiler-parse-extern-metadata-ok?) : bool
  (match (parse-ast-source (compiler-parse-extern-metadata-source))
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons
              (AstDecl.Extern decl-meta name _ metadata ty)
              rest)
            (let
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (and
                    (= name (reader.read-stable-symbol-id "local-call"))
                    (string.eq
                      (ast-extern-metadata-symbol (box-get metadata))
                      "foreign_exact")
                    (ast-extern-abi-c?
                      (ast-extern-metadata-abi (box-get metadata)))
                    (compiler-parse-extern-link-inputs-ok?
                      (ast-extern-metadata-link-inputs (box-get metadata)))
                    (match ty
                      [(AstType.Func args ret)
                        (let
                          [args-list : AstTypeList (box-get args)]
                          (and
                            (= (ast-type-list-len (& args-list)) 1)
                            (match (ty-node-get
                              (ast-type-list-get
                                (& args-list)
                                0
                                (ast-type-id-fallback)))
                              [(AstType.I64) true]
                              [_ false])
                            (match (ty-node-get ret)
                              [(AstType.I64) true]
                              [_ false])))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-extern-varargs-metadata-rejected-ok?) : bool
  (compiler-parse-error-ok?
    (compiler-parse-extern-varargs-metadata-source)
    (parse-ast-extern-c-varargs-legacy-message)))

(define (compiler-parse-extern-head-typed-varargs-decl-ok? [decl : AstDecl]) : bool
  (match decl
    [(AstDecl.Extern decl-meta name _ metadata ty)
      (and
        (= name (reader.read-stable-symbol-id "snprintf"))
        (match (ast-extern-metadata-abi (box-get metadata))
          [(AstExternAbi.CVarargsTyped tail-ty)
            (match tail-ty
              [(AstType.F64) true]
              [_ false])]
          [_ false])
        (match ty
          [(AstType.Func args ret)
            (let
              [args-list : AstTypeList (box-get args)]
              (and
                (= (compiler-parse-type-list-count args-list) 3)
                (match (ty-node-get ret)
                  [(AstType.I32) true]
                  [_ false])
                (compiler-parse-type-mut-ptr-u8?
                  (ty-node-get
                    (ast-type-list-get (& args-list) 0 (ast-type-id-fallback))))
                (match (ty-node-get
                  (ast-type-list-get (& args-list) 1 (ast-type-id-fallback)))
                  [(AstType.I64) true]
                  [_ false])
                (compiler-parse-type-ptr-u8?
                  (ty-node-get
                    (ast-type-list-get (& args-list) 2 (ast-type-id-fallback))))))]
          [_ false]))]
    [_ false]))

(define (compiler-parse-extern-head-open-varargs-decl-ok? [decl : AstDecl]) : bool
  (match decl
    [(AstDecl.Extern decl-meta name _ metadata ty)
      (and
        (= name (reader.read-stable-symbol-id "printf"))
        (match (ast-extern-metadata-abi (box-get metadata))
          [(AstExternAbi.CVarargsOpen) true]
          [_ false])
        (match ty
          [(AstType.Func args ret)
            (let
              [args-list : AstTypeList (box-get args)]
              (and
                (= (compiler-parse-type-list-count args-list) 1)
                (match (ty-node-get ret)
                  [(AstType.I32) true]
                  [_ false])
                (compiler-parse-type-ptr-u8?
                  (ty-node-get
                    (ast-type-list-get (& args-list) 0 (ast-type-id-fallback))))))]
          [_ false]))]
    [_ false]))

(define (compiler-parse-i64-type? [ty : AstType]) : bool
  (match ty
    [(AstType.I64) true]
    [_ false]))

(define (compiler-parse-two-i64-types? [args : AstTypeList]) : bool
  (and
    (= (ast-type-list-len (& args)) 2)
    (compiler-parse-i64-type?
      (ty-node-get (ast-type-list-get (& args) 0 (ast-type-id-fallback))))
    (compiler-parse-i64-type?
      (ty-node-get (ast-type-list-get (& args) 1 (ast-type-id-fallback))))))

(define (compiler-parse-extern-head-fixed-decl-ok? [decl : AstDecl]) : bool
  (match decl
    [(AstDecl.Extern decl-meta name _ metadata ty)
      (and
        (= name (reader.read-stable-symbol-id "local-add"))
        (string.eq
          (ast-extern-metadata-symbol (box-get metadata))
          "foreign_add_exact")
        (match ty
          [(AstType.Func args ret)
            (and
              (= (compiler-parse-type-list-count (box-get args)) 2)
              (compiler-parse-i64-type? (ty-node-get ret))
              (compiler-parse-two-i64-types? (box-get args)))]
          [_ false]))]
    [_ false]))

(define (compiler-parse-extern-function-head-varargs-ok?) : bool
  (match (parse-ast-source (compiler-parse-extern-function-head-varargs-source))
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (match (ast-decl-list-step (box-get decls-box))
        [(AstDeclListStep.Cons first rest0)
          (let
            [rest0 : AstDeclList rest0]
            (match (ast-decl-list-step rest0)
              [(AstDeclListStep.Cons second rest1)
                (let
                  [rest1 : AstDeclList rest1]
                  (match (ast-decl-list-step rest1)
                    [(AstDeclListStep.Cons third rest2)
                      (let
                        [rest2 : AstDeclList rest2]
                        (match (ast-decl-list-step rest2)
                          [(AstDeclListStep.Nil)
                            (and
                              (compiler-parse-extern-head-typed-varargs-decl-ok?
                                first)
                              (compiler-parse-extern-head-open-varargs-decl-ok?
                                second)
                              (compiler-parse-extern-head-fixed-decl-ok? third))]
                          [_ false]))]
                    [_ false]))]
              [_ false]))]
        [_ false])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-define-export-symbol-ok?) : bool
  (match (parse-ast-source (compiler-parse-define-export-symbol-source))
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons
              (AstDecl.DefFn ast-decl-meta-runtime name params ret _ metadata)
              rest)
            (let
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (and
                    (= name (reader.read-stable-symbol-id "_write"))
                    (= (compiler-parse-param-list-count params) 3)
                    (match ret
                      [(AstType.I32) true]
                      [_ false])
                    (match (ast-fn-metadata-export metadata)
                      [(AstFnExport.Export symbol)
                        (= symbol (reader.read-stable-symbol-id "_write"))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-raw-pointer-ops-ok?) : bool
  (compiler-parse-ok? (compiler-parse-raw-pointer-ops-source)))

(define (compiler-parse-init-ok?) : bool
  (match (parse-ast-source "(define (main) : i64 (init : i64))")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (match (ast-decl-list-step (box-get decls-box))
        [(AstDeclListStep.Cons
            (AstDecl.DefFn decl-meta _ _ _ body-box _)
            done-box)
          (let
            [done : AstDeclList done-box]
            (and
              (ast-decl-list-empty? (& done))
              (match (ast-expr-unspan (ast-node-get body-box))
                [(AstExpr.Init ty)
                  (match ty
                    [(AstMaybeType.Some inner)
                      (match inner
                        [(AstType.I64) true]
                        [_ false])]
                    [_ false])]
                [_ false])))]
        [_ false])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-contextual-init-ok?) : bool
  (match (parse-ast-source
    "(define (init) : i64 7) (define (main) : i64 (init))")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (match (ast-decl-list-step (box-get decls-box))
        [(AstDeclListStep.Cons _ rest)
          (match (ast-decl-list-step rest)
            [(AstDeclListStep.Cons
                (AstDecl.DefFn decl-meta _ _ _ body-box _)
                done-box)
              (let
                [done : AstDeclList done-box]
                (and
                  (ast-decl-list-empty? (& done))
                  (match (ast-expr-unspan (ast-node-get body-box))
                    [(AstExpr.Init ty)
                      (match ty
                        [(AstMaybeType.No) true]
                        [_ false])]
                    [_ false])))]
            [_ false])]
        [_ false])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-init-call-name-source) : String
  "(define (init [n : i64]) : i64 n)
(define (main) : i64 (init 7))")

(define (compiler-parse-init-call-name-ok?) : bool
  (compiler-parse-ok? (compiler-parse-init-call-name-source)))

(define (compiler-parse-box-ok?) : bool
  (and
    (compiler-parse-ok? "(define (main) : (Box i64) (box 7))")
    (compiler-parse-ok? "(define (main [b : (Box i64)]) : i64 (box-get b))")
    (compiler-parse-ok?
      "(define (main) : i64 (with-arena r (let [b : (in r (Box i64)) (box 7)] (box-get b))))")))

(define (compiler-parse-reference-source) : String
  "(define (use [s : (& n String)] [view : (& n str)] [items : (&mut value (Array i64))]) : unit unit)")

(define (compiler-parse-reference-ok?) : bool
  (match (parse-ast-source (compiler-parse-reference-source))
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons (AstDecl.DefFn decl-meta _ params _ _ _) rest)
            (let
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (and
                    (= (ast-param-list-len (& params)) 3)
                    (match (ast-param-list-get
                      (& params)
                      0
                      (ast-param-fallback))
                      [(AstParam.Param _ first-ty false false)
                        (compiler-parse-type-ref-string?
                          first-ty
                          cbi.compiler-builtin-id-fix-n)]
                      [_ false])
                    (match (ast-param-list-get
                      (& params)
                      1
                      (ast-param-fallback))
                      [(AstParam.Param _ second-ty false false)
                        (compiler-parse-type-ref-str?
                          second-ty
                          cbi.compiler-builtin-id-fix-n)]
                      [_ false])
                    (match (ast-param-list-get
                      (& params)
                      2
                      (ast-param-fallback))
                      [(AstParam.Param _ third-ty false false)
                        (compiler-parse-type-mut-ref-dyn-array-i64?
                          third-ty
                          cbi.compiler-builtin-id-fix-value)]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-borrow-source) : String
  "(define (main [x : i64]) : i64
  (begin
    (& x)
    (& x x)
    (&mut x)
    x))")

(define (compiler-parse-borrow-ok?) : bool
  (match (parse-ast-source (compiler-parse-borrow-source))
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons
              (AstDecl.DefFn decl-meta _ _ _ body-box _)
              rest)
            (let
              [body : AstExpr (ast-node-get body-box)]
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (match (ast-expr-unspan body)
                    [(AstExpr.Begin exprs)
                      (if (>= (struct-get (& exprs) len) 2)
                        (let
                          [first : AstExpr
                            (ast-node-get (ast-expr-list-get (& exprs) 0 0))]
                          [second : AstExpr
                            (ast-node-get (ast-expr-list-get (& exprs) 1 0))]
                          (match (ast-expr-unspan first)
                            [(AstExpr.Borrow
                                _
                                AstBorrowLifetime.Inferred
                                first-place-box)
                              (let
                                [first-place : AstExpr
                                  (ast-node-get first-place-box)]
                                (match (ast-expr-unspan first-place)
                                  [(AstExpr.Var first-name)
                                    (if (=
                                      first-name
                                      cbi.compiler-builtin-id-fix-x)
                                      (match (ast-expr-unspan second)
                                        [(AstExpr.Borrow
                                            _
                                            (AstBorrowLifetime.Named lifetime)
                                            second-place-box)
                                          (let
                                            [second-place : AstExpr
                                              (ast-node-get second-place-box)]
                                            (match (ast-expr-unspan
                                              second-place)
                                              [(AstExpr.Var second-name)
                                                (and
                                                  (=
                                                    lifetime
                                                    cbi.compiler-builtin-id-fix-x)
                                                  (=
                                                    second-name
                                                    cbi.compiler-builtin-id-fix-x))]
                                              [_ false]))]
                                        [_ false])
                                      false)]
                                  [_ false]))]
                            [_ false]))
                        false)]
                    [_ false])]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-try-source) : String
  "(define (main) : i64 (wrap (try (read))))")

(define (compiler-parse-try-ok?) : bool
  (match (parse-ast-source (compiler-parse-try-source))
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons
              (AstDecl.DefFn decl-meta _ _ _ body-box _)
              rest)
            (let
              [body : AstExpr (ast-node-get body-box)]
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (match (ast-expr-unspan body)
                    [(AstExpr.Call _ args)
                      (if (= (struct-get (& args) len) 1)
                        (let
                          [arg : AstExpr
                            (ast-node-get (ast-expr-list-get (& args) 0 0))]
                          (match (ast-expr-unspan arg)
                            [(AstExpr.Try _) true]
                            [_ false]))
                        false)]
                    [_ false])]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-return-source) : String
  "(define (main) : i64 (return 42))")

(define (compiler-parse-return-ok?) : bool
  (match (parse-ast-source (compiler-parse-return-source))
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons
              (AstDecl.DefFn decl-meta _ _ _ body-box _)
              rest)
            (let
              [body : AstExpr (ast-node-get body-box)]
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (match (ast-expr-unspan body)
                    [(AstExpr.Return inner-box)
                      (let
                        [inner : AstExpr (ast-node-get inner-box)]
                        (match (ast-expr-unspan inner)
                          [(AstExpr.Literal (AstLiteral.Int 42 _)) true]
                          [_ false]))]
                    [_ false])]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-unit-expr? [expr : AstExpr]) : bool
  (match (ast-expr-unspan expr)
    [(AstExpr.Literal AstLiteral.Unit) true]
    [_ false]))

(define (compiler-parse-return-then-unit-begin? [expr : AstExpr]) : bool
  (match (ast-expr-unspan expr)
    [(AstExpr.Begin exprs)
      (if (= (struct-get (& exprs) len) 2)
        (let
          [first : AstExpr (ast-node-get (ast-expr-list-get (& exprs) 0 0))]
          [last : AstExpr (ast-node-get (ast-expr-list-get (& exprs) 1 0))]
          (and
            (match (ast-expr-unspan first)
              [(AstExpr.Return _) true]
              [_ false])
            (compiler-parse-unit-expr? last)))
        false)]
    [_ false]))

(define (compiler-parse-call-head-name? [expr : AstExpr] [name : String]) : bool
  (match (ast-expr-unspan expr)
    [(AstExpr.Var found) (string.eq (intern-str found) name)]
    [_ false]))

(define (compiler-parse-return-expr? [expr : AstExpr]) : bool
  (match (ast-expr-unspan expr)
    [(AstExpr.Return _) true]
    [_ false]))

(define (compiler-parse-guard-call-args-ok? [args : AstExprList]) : bool
  (if (= (struct-get (& args) len) 2)
    (let
      [cond : AstExpr (ast-node-get (ast-expr-list-get (& args) 0 0))]
      [body-arg : AstExpr (ast-node-get (ast-expr-list-get (& args) 1 0))]
      (and
        (compiler-parse-call-head-name? cond "ok")
        (compiler-parse-return-expr? body-arg)))
    false))

(define (compiler-parse-call-arg-count [args : AstExprList]) : i64
  (struct-get (& args) len))

(define (compiler-parse-call-body-ok?
  [source : String]
  [name : String]
  [want-args : i64]
  [check-guard-args : bool]) : bool
  (match (parse-ast-source source)
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons
              (AstDecl.DefFn decl-meta _ _ _ body-box _)
              rest)
            (let
              [body : AstExpr (ast-node-get body-box)]
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (match (ast-expr-unspan body)
                    [(AstExpr.Call func-box args)
                      (let
                        [func : AstExpr (ast-node-get func-box)]
                        (and
                          (compiler-parse-call-head-name? func name)
                          (= (compiler-parse-call-arg-count args) want-args)
                          (if check-guard-args
                            (compiler-parse-guard-call-args-ok? args)
                            true)))]
                    [_ false])]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-guard-forms-ok?) : bool
  (and
    (compiler-parse-call-body-ok?
      "(define (main [ok : bool]) : unit (when ok (return unit)))"
      "when"
      2
      true)
    (compiler-parse-call-body-ok?
      "(define (main [ok : bool]) : unit (unless ok (return unit)))"
      "unless"
      2
      true)))

(define (compiler-parse-bracket-cond-call-ok?) : bool
  (and
    (compiler-parse-call-body-ok?
      (compiler-parse-bracket-cond-source)
      "cond"
      2
      false)
    (compiler-parse-call-body-ok?
      (compiler-parse-qualified-bracket-cond-source)
      "core.cond"
      2
      false)))

(define (compiler-parse-and-or-macro-call-candidates-ok?) : bool
  (and
    (compiler-parse-call-body-ok? "(define (main) : bool (and))" "and" 0 false)
    (compiler-parse-call-body-ok?
      "(define (main [x : bool]) : bool (and x))"
      "and"
      1
      false)
    (compiler-parse-call-body-ok?
      "(define (main [x : bool] [y : bool]) : bool (and x y))"
      "and"
      2
      false)
    (compiler-parse-call-body-ok?
      "(define (main [x : bool] [y : bool] [z : bool]) : bool (and x y z))"
      "and"
      3
      false)
    (compiler-parse-call-body-ok? "(define (main) : bool (or))" "or" 0 false)
    (compiler-parse-call-body-ok?
      "(define (main [x : bool]) : bool (or x))"
      "or"
      1
      false)
    (compiler-parse-call-body-ok?
      "(define (main [x : bool] [y : bool]) : bool (or x y))"
      "or"
      2
      false)
    (compiler-parse-call-body-ok?
      "(define (main [x : bool] [y : bool] [z : bool]) : bool (or x y z))"
      "or"
      3
      false)))

(define (compiler-parse-unsafe-decl-source) : String
  "(unsafe (define (danger [x : i64]) : i64 x))
(unsafe (extern (raw-call [arg0 : i64]) : i64))")

(define (compiler-parse-unsafe-decl-ok?) : bool
  (match (parse-ast-source (compiler-parse-unsafe-decl-source))
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons first tail)
            (let
              [tail : AstDeclList tail]
              (match first
                [(AstDecl.Unsafe first-inner-box)
                  (let
                    [first-inner : AstDecl (box-get first-inner-box)]
                    (match first-inner
                      [(AstDecl.DefFn decl-meta name _ (AstType.I64) _ _)
                        (match (ast-decl-list-step tail)
                          [(AstDeclListStep.Cons second done-box)
                            (let
                              [done : AstDeclList done-box]
                              (and
                                (ast-decl-list-empty? (& done))
                                (match second
                                  [(AstDecl.Unsafe second-inner-box)
                                    (let
                                      [second-inner : AstDecl
                                        (box-get second-inner-box)]
                                      (match second-inner
                                        [(AstDecl.Extern
                                            _
                                            extern-name
                                            _
                                            _
                                            extern-ty)
                                          (and
                                            (=
                                              name
                                              (reader.read-stable-symbol-id
                                                "danger"))
                                            (=
                                              extern-name
                                              (reader.read-stable-symbol-id
                                                "raw-call"))
                                            (match extern-ty
                                              [(AstType.Func _ ret)
                                                (match (ty-node-get ret)
                                                  [(AstType.I64) true]
                                                  [_ false])]
                                              [_ false]))]
                                        [_ false]))]
                                  [_ false])))]
                          [_ false])]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-field-count [fields : AstFieldDefList]) : i64
  (struct-get (& fields) len))

(define (compiler-parse-field-cleanup-score [cleanup : AstFieldCleanup]) : i64
  (match cleanup
    [(AstFieldCleanup.No) 0]
    [(AstFieldCleanup.Fn _) 10]
    [(AstFieldCleanup.Owned) 100]))

(define (compiler-parse-field-cleanup-list-score [fields : AstFieldDefList]) : i64
  (compiler-parse-field-cleanup-list-score-at (& fields) 0))

(define (compiler-parse-field-cleanup-list-score-at
  [fields : (& fields AstFieldDefList)]
  [index : i64]) : i64
  (if (>= index (struct-get fields len))
    0
    (match (ast-field-def-list-get fields index (ast-field-def-fallback))
      [(AstFieldDef.Def _ _ cleanup)
        (+
          (compiler-parse-field-cleanup-score cleanup)
          (compiler-parse-field-cleanup-list-score-at fields (+ index 1)))])))

(define (compiler-parse-variant-payload-cleanup-score
  [cleanup : AstVariantPayloadCleanup]) : i64
  (match cleanup
    [(AstVariantPayloadCleanup.No) 0]
    [(AstVariantPayloadCleanup.Fn _) 10]
    [(AstVariantPayloadCleanup.Owned) 100]))

(define (compiler-parse-variant-payload-cleanup-list-score
  [cleanups : AstVariantPayloadCleanupList]) : i64
  (compiler-parse-variant-payload-cleanup-list-score-at (& cleanups) 0))

(define (compiler-parse-variant-payload-cleanup-list-score-at
  [cleanups : (& cleanups AstVariantPayloadCleanupList)]
  [index : i64]) : i64
  (if (>= index (struct-get cleanups len))
    0
    (+
      (compiler-parse-variant-payload-cleanup-score
        (ast-variant-payload-cleanup-list-get
          cleanups
          index
          (ast-variant-payload-cleanup-fallback)))
      (compiler-parse-variant-payload-cleanup-list-score-at
        cleanups
        (+ index 1)))))

(define (compiler-parse-variant-list-cleanup-score
  [variants : AstVariantDefList]) : i64
  (compiler-parse-variant-list-cleanup-score-at (& variants) 0))

(define (compiler-parse-variant-list-cleanup-score-at
  [variants : (& variants AstVariantDefList)]
  [index : i64]) : i64
  (if (>= index (struct-get variants len))
    0
    (match (ast-variant-def-list-get variants index (ast-variant-def-fallback))
      [(AstVariantDef.Def _ _ cleanups)
        (+
          (compiler-parse-variant-payload-cleanup-list-score cleanups)
          (compiler-parse-variant-list-cleanup-score-at variants (+ index 1)))])))

(define (compiler-parse-struct-cleanup-source) : String
  "(defstruct Resource
  (:cleanup close-resource)
  (fd i64 (:cleanup close-fd))
  (child i64 (:owned))
  (status i64))")

(define (compiler-parse-struct-cleanup-ok?) : bool
  (match (parse-ast-source (compiler-parse-struct-cleanup-source))
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons
              (AstDecl.DefStruct ast-decl-meta-runtime name repr cleanup fields)
              rest)
            (let
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (and
                    (= name (reader.read-stable-symbol-id "Resource"))
                    (match repr
                      [(AstStructRepr.Default) true]
                      [_ false])
                    (match cleanup
                      [(AstStructCleanup.Fn cleanup-name)
                        (=
                          cleanup-name
                          (reader.read-stable-symbol-id "close-resource"))]
                      [_ false])
                    (= (compiler-parse-field-count fields) 3)
                    (= (compiler-parse-field-cleanup-list-score fields) 110))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-enum-cleanup-source) : String
  "(defenum Resource
  (:cleanup close-resource)
  (File i64 (:cleanup close-fd) Child (:owned) i64))")

(define (compiler-parse-enum-cleanup-ok?) : bool
  (match (parse-ast-source (compiler-parse-enum-cleanup-source))
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons
              (AstDecl.DefEnum decl-meta name cleanup variants)
              rest)
            (let
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (and
                    (= name (reader.read-stable-symbol-id "Resource"))
                    (match cleanup
                      [(AstEnumCleanup.Fn cleanup-name)
                        (=
                          cleanup-name
                          (reader.read-stable-symbol-id "close-resource"))]
                      [_ false])
                    (= (compiler-parse-variant-list-cleanup-score variants) 110))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-cleanup-metadata-ok?) : bool
  (and (compiler-parse-struct-cleanup-ok?) (compiler-parse-enum-cleanup-ok?)))

(define (compiler-parse-repr-c-source) : String
  "(defstruct Stat
  (:repr c)
  (size i64)
  (mtime i64))")

(define (compiler-parse-repr-c-ok?) : bool
  (match (parse-ast-source (compiler-parse-repr-c-source))
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons
              (AstDecl.DefStruct decl-meta name repr _ fields)
              rest)
            (let
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (and
                    (= name (reader.read-stable-symbol-id "Stat"))
                    (ast-struct-repr-c? repr)
                    (= (compiler-parse-field-count fields) 2))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-inline-test-source) : String
  "(test parser-basic
  (+ 1 2)
  3)")

(define (compiler-parse-inline-test-ok?) : bool
  (match (parse-ast-source (compiler-parse-inline-test-source))
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons (AstDecl.Test name body-box span) tail)
            (let
              [body : AstExpr (ast-node-get body-box)]
              [tail : AstDeclList tail]
              (match (ast-decl-list-step tail)
                [(AstDeclListStep.Nil)
                  (and
                    (= name (reader.read-stable-symbol-id "parser-basic"))
                    (= (ast-source-span-start-line span) 1)
                    (match (ast-expr-unspan body)
                      [(AstExpr.Begin exprs)
                        (= (compiler-parse-expr-list-count exprs) 2)]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-malformed-module-source) : String
  "(module)")

(define (compiler-parse-malformed-import-source) : String
  "(import \"stdlib/tl\" as)")

(define (compiler-parse-defgeneric-policy-source) : String
  "(defgeneric Box [T] (value T))")

(define (compiler-parse-trait-policy-source) : String
  "(trait Printable (print-self : (-> Self unit)))")

(define (compiler-parse-generic-type-policy-source) : String
  "(define value : (Option i64) 0)")

(define (compiler-parse-empty-test-source) : String
  "(test empty)")

(define (compiler-parse-malformed-try-source) : String
  "(define (main) : i64 (try))")

(define (compiler-parse-malformed-return-source) : String
  "(define (main) : i64 (return 1 2))")

(define (compiler-parse-repr-c-error-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(defstruct Bad (:repr c) (:repr c) (x i64))"
      "parse: duplicate defstruct :repr metadata")
    (compiler-parse-error-ok?
      "(defstruct Bad (:repr rust) (x i64))"
      "parse: unknown struct repr rust")
    (compiler-parse-error-ok?
      "(defstruct Bad (:repr packed) (x i64))"
      "parse: packed repr is reserved")
    (compiler-parse-error-ok?
      "(defstruct Bad (x i64) (:repr c))"
      "parse: defstruct metadata must appear before fields")
    (compiler-parse-error-ok?
      "(defstruct Bad (:layout c) (x i64))"
      "parse: unknown defstruct metadata :layout")
    (compiler-parse-error-ok?
      "(defstruct Bad (:repr c))"
      "parse: defstruct needs at least one field")))

(define (compiler-parse-cleanup-error-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(defstruct Bad (:cleanup close) (:cleanup close2) (x i64))"
      "parse: duplicate defstruct :cleanup metadata")
    (compiler-parse-error-ok?
      "(defstruct Bad (x i64 (:cleanup close-x)))"
      "parse: field cleanup metadata requires struct :cleanup metadata")
    (compiler-parse-error-ok?
      "(defstruct Bad (:repr c) (:cleanup close) (x i64))"
      "parse: defstruct cannot combine :repr c with :cleanup metadata")
    (compiler-parse-error-ok?
      "(defstruct Bad (:cleanup close) (:repr c) (x i64))"
      "parse: defstruct cannot combine :repr c with :cleanup metadata")
    (compiler-parse-error-ok?
      "(defstruct Bad (:cleanup) (x i64))"
      "parse: malformed defstruct :cleanup metadata")
    (compiler-parse-error-ok?
      "(defstruct Bad (:cleanup close) (x i64 (:cleanup)))"
      "parse: malformed field :cleanup metadata")
    (compiler-parse-error-ok?
      "(defstruct Bad (:cleanup close) (x i64 (:cleanup close-x) (:owned)))"
      "parse: duplicate field cleanup metadata")
    (compiler-parse-error-ok?
      "(defenum Bad (:cleanup close) (:cleanup close2) (A))"
      "parse: duplicate defenum :cleanup metadata")
    (compiler-parse-error-ok?
      "(defenum Bad (:cleanup) (A))"
      "parse: malformed defenum :cleanup metadata")
    (compiler-parse-error-ok?
      "(defenum Bad (A) (:cleanup close))"
      "parse: defenum metadata must appear before variants")
    (compiler-parse-error-ok?
      "(defenum Bad (A i64 (:cleanup close)))"
      "parse: enum payload cleanup metadata requires enum :cleanup metadata")))

(define (compiler-parse-unsafe-decl-error-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(unsafe)"
      "parse: unsafe declaration expects exactly one declaration")
    (compiler-parse-error-ok?
      "(unsafe (define value : i64 1))"
      "parse: unsafe declaration accepts only function define or extern")
    (compiler-parse-error-ok?
      "(unsafe (defstruct Bad (x i64)))"
      "parse: unsafe declaration accepts only function define or extern")
    (compiler-parse-error-ok?
      "(unsafe (extern (a) : i64) (extern (b) : i64))"
      "parse: unsafe declaration expects exactly one declaration")))

(define (compiler-parse-define-export-metadata-error-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(define (f) (:export-symbol \"\") : i64 0)"
      "parse: define :export-symbol must not be empty")
    (compiler-parse-error-ok?
      "(define (f) (:export-symbol bad) : i64 0)"
      "parse: malformed define :export-symbol metadata")
    (compiler-parse-error-ok?
      "(define (f) (:export-symbol \"a\") (:export-symbol \"b\") : i64 0)"
      "parse: duplicate define :export-symbol metadata")
    (compiler-parse-error-ok?
      "(define (f) (:link-lib \"m\") : i64 0)"
      "parse: unknown define metadata :link-lib")
    (compiler-parse-error-ok?
      "(define (f [comptime n : i64]) (:export-symbol \"f\") : i64 n)"
      "parse: define :export-symbol cannot be used on functions with comptime parameters")))

(define (compiler-parse-flat-let-call-body-ok?) : bool
  (match (parse-ast-source
    "(define (id [x : i64]) : i64 x)
(define (main) : i64 (let [x : i64 41] (id x)))")
    [(ResultAstProgram.Ok _) true]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-let-error-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(define (main) : i64 (let 1))"
      "parse: let requires at least one binding")
    (compiler-parse-error-ok?
      "(define (main) : i64 (let [x : i64] x))"
      "parse: malformed let binding")
    (compiler-parse-error-ok?
      "(define (main) : i64 (let [x : i64 1]))"
      "parse: let missing body")
    (compiler-parse-error-ok?
      "(define (main) : i64 (let []))"
      "parse: let missing body")
    (compiler-parse-error-ok?
      "(define (main) : i64 (let ()))"
      "parse: (let () body...) was removed; write (let [] body...)")
    (compiler-parse-error-ok?
      "(define (main) : i64 (let ([x : i64 1]) x))"
      "parse: parenthesized let bindings were removed; write leading [name [: type] init] bindings without parentheses")
    (compiler-parse-error-ok?
      "(define (main) : i64 (let ([x 1] [y (+ x 1)]) y))"
      "parse: parenthesized let bindings were removed; write leading [name [: type] init] bindings without parentheses")))

(define (compiler-parse-abstraction-policy-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      (compiler-parse-defgeneric-policy-source)
      (compiler-parse-abstraction-policy-message))
    (compiler-parse-error-ok?
      (compiler-parse-trait-policy-source)
      (compiler-parse-abstraction-policy-message))
    (compiler-parse-error-ok?
      (compiler-parse-generic-type-policy-source)
      (compiler-parse-generic-type-policy-message "Option"))))

(define (compiler-parse-raw-pointer-error-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(define (main [p : (Ptr)]) : unit unit)"
      "parse: Ptr expects exactly one type")
    (compiler-parse-error-ok?
      "(define (main [p : (MutPtr i64 i64)]) : unit unit)"
      "parse: MutPtr expects exactly one type")
    (compiler-parse-error-ok?
      "(define (main [p : (Ptr (Array))]) : unit unit)"
      "parse: malformed array type")
    (compiler-parse-error-ok?
      "(define (main [p : (Ptr i64)]) : i64 (ptr-read))"
      "parse: ptr-read expects exactly one expression")
    (compiler-parse-error-ok?
      "(define (main [p : (MutPtr i64)]) : unit (ptr-write! p))"
      "parse: ptr-write! expects exactly two expressions")
    (compiler-parse-error-ok?
      "(define (main) : (MutPtr i64) (unsafe (ptr-addr-of)))"
      "parse: ptr-addr-of expects exactly one addressable place")
    (compiler-parse-error-ok?
      "(define (main [x : i64] [y : i64]) : (MutPtr i64) (unsafe (ptr-addr-of x y)))"
      "parse: ptr-addr-of expects exactly one addressable place")
    (compiler-parse-error-ok?
      "(define (main [p : (Ptr i64)]) : (Ptr u8) (ptr-cast p (Ptr u8)))"
      "parse: pointer cast expects (form expr : pointer-type)")))

(define (compiler-parse-box-error-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-parse-error-ok?
        "(define (main [p : (Box)]) : unit unit)"
        "parse: Box expects exactly one type")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(define (main [p : (Box i64 bool)]) : unit unit)"
        "parse: Box expects exactly one type")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(define (main) : (Box i64) (box))"
        "parse: box expects exactly one expression")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(define (main [b : (Box i64)]) : i64 (box-get b b))"
        "parse: box-get expects exactly one expression")
        unit
        (set! ok false))
      ok)))

(define (compiler-parse-extern-metadata-error-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-parse-error-ok?
        "(extern (f) : i64 (:abi stdcall))"
        "parse: unknown extern ABI stdcall")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(extern (f) : i64 (:symbol bad))"
        "parse: malformed extern :symbol metadata")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(extern (f) : i64 (:link-lib bad))"
        "parse: malformed extern :link-lib metadata")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(extern (f) : i64 (:link-arg \"\"))"
        "parse: extern :link-arg must not be empty")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(extern (f) : i64 (:abi c) (:abi c))"
        "parse: duplicate extern :abi metadata")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(extern (f) : i64 (:abi c-varargs))"
        (parse-ast-extern-c-varargs-legacy-message))
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(extern (f) : i64 (:abi c-varargs -1))"
        (parse-ast-extern-c-varargs-legacy-message))
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(extern (f ... [x : i64]) : i64)"
        "parse: extern varargs tail must be final")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(extern (f [x : i64] ...) (:abi c-varargs 1) : i64)"
        (parse-ast-extern-c-varargs-legacy-message))
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(extern (f) : i64 (:link \"x\"))"
        "parse: unknown extern metadata :link")
        unit
        (set! ok false))
      ok)))

(define (compiler-parse-reference-error-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-parse-error-ok?
        "(define (main [p : (&)]) : unit unit)"
        "parse: & expects an optional lifetime and exactly one type")
        unit
        (set! ok false))
      (if (compiler-parse-ok? "(define (main [p : (& r)]) : unit unit)")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(define (main [p : (& 1 i64)]) : unit unit)"
        "parse: reference lifetime must be an identifier")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(define (main [p : (& r i64 i64)]) : unit unit)"
        "parse: & expects an optional lifetime and exactly one type")
        unit
        (set! ok false))
      (if (compiler-parse-ok? "(define (main [p : (&mut phase)]) : unit unit)")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(define (main [x : i64]) : unit (&))"
        "parse: borrow expects a place or lifetime and place")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(define (main [x : i64]) : unit (& x x x))"
        "parse: borrow expects a place or lifetime and place")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(define (main [x : i64]) : unit (& 1 x))"
        "parse: borrow lifetime must be an identifier")
        unit
        (set! ok false))
      ok)))

(define (compiler-parse-special-form-error-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      (compiler-parse-malformed-binary-source)
      "parse: malformed binary expression")
    (compiler-parse-error-ok?
      (compiler-parse-malformed-if-source)
      "parse: if is missing its else branch")
    (compiler-parse-if-missing-else-diagnostic-notes-ok?)
    (compiler-parse-error-ok?
      (compiler-parse-malformed-while-source)
      "parse: malformed while")
    (compiler-parse-error-ok?
      (compiler-parse-malformed-set-source)
      "parse: malformed set!")
    (compiler-parse-error-ok?
      (compiler-parse-with-region-empty-source)
      "parse: with-arena 'r' requires a non-empty body")
    (compiler-parse-error-ok?
      (compiler-parse-region-type-bad-source)
      "parse: region name must be an identifier")
    (compiler-parse-error-ok?
      (compiler-parse-malformed-try-source)
      "parse: try expects exactly one expression")
    (compiler-parse-error-ok?
      (compiler-parse-malformed-return-source)
      "parse: return expects exactly one expression")))

(define (compiler-parse-error-tests-ok?) : bool
  (cond
    [(not (compiler-parse-diagnostic-code-ok?)) false]
    [(not (compiler-parse-nested-diagnostic-spans-ok?)) false]
    [(not (compiler-parse-special-form-error-tests-ok?)) false]
    [(not (compiler-parse-unsafe-decl-error-tests-ok?)) false]
    [(not (compiler-parse-repr-c-error-tests-ok?)) false]
    [(not (compiler-parse-cleanup-error-tests-ok?)) false]
    [(not
        (compiler-parse-error-ok?
          (compiler-parse-malformed-module-source)
          "parse: malformed module"))
      false]
    [(not
        (compiler-parse-error-ok?
          (compiler-parse-malformed-import-source)
          "parse: malformed import"))
      false]
    [(not
        (compiler-parse-error-ok?
          (compiler-parse-empty-test-source)
          "parse: test needs at least one expression"))
      false]
    [(not (compiler-parse-let-error-tests-ok?)) false]
    [(not (compiler-parse-abstraction-policy-tests-ok?)) false]
    [(not (compiler-parse-raw-pointer-error-tests-ok?)) false]
    [(not (compiler-parse-extern-metadata-error-tests-ok?)) false]
    [(not (compiler-parse-box-error-tests-ok?)) false]
    [(not (compiler-parse-reference-error-tests-ok?)) false]
    [else true]))

;; Top-level declaration parsing: accept value/function `define`,
;; `extern`, `defenum`, `defstruct`, and `import`; reject malformed forms with
;; stable diagnostics. Migrated from src/parser.rs declaration coverage.
(define (compiler-parse-ok? [src : String]) : bool
  (match (parse-ast-source src)
    [(ResultAstProgram.Ok _) true]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-ok-with-cfg?
  [src : String]
  [cfgs : sym_i64_env.SymI64Env]) : bool
  (match (parse-ast-source-with-cfg src cfgs)
    [(ResultAstProgram.Ok _) true]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-cfg-decl-count-ok?
  [src : String]
  [cfgs : sym_i64_env.SymI64Env]
  [want : i64]) : bool
  (match (parse-ast-source-with-cfg src cfgs)
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (= (ast-decl-list-count decls) want))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-cfg-error?
  [src : String]
  [cfgs : sym_i64_env.SymI64Env]) : bool
  (match (parse-ast-source-with-cfg src cfgs)
    [(ResultAstProgram.Ok _) false]
    [(ResultAstProgram.Err _) true]))

(define (compiler-parse-cfg-tests-ok?) : bool
  (let
    [feature-cfg : sym_i64_env.SymI64Env
      (compiler-cfg-enable (compiler-cfg-empty) "feature")]
    [windows-feature-cfg : sym_i64_env.SymI64Env
      (compiler-cfg-enable feature-cfg "windows")]
    (and
      (compiler-parse-cfg-decl-count-ok?
        "(cfg feature (define answer : i64 42))"
        (compiler-cfg-empty)
        0)
      (compiler-parse-cfg-decl-count-ok?
        "(cfg feature (define answer : i64 42))"
        feature-cfg
        1)
      (compiler-parse-cfg-decl-count-ok?
        "(cfg feature (define))"
        (compiler-cfg-empty)
        0)
      (compiler-parse-cfg-decl-count-ok?
        "(cfg (all feature windows) (define answer : i64 42))"
        windows-feature-cfg
        1)
      (compiler-parse-cfg-decl-count-ok?
        "(cfg (any missing feature) (define answer : i64 42))"
        feature-cfg
        1)
      (compiler-parse-cfg-decl-count-ok?
        "(cfg (not missing) (define answer : i64 42))"
        feature-cfg
        1)
      (compiler-parse-cfg-decl-count-ok?
        "(define (main) : i64 (begin (cfg feature (if)) 42))"
        (compiler-cfg-empty)
        1)
      (compiler-parse-cfg-decl-count-ok?
        "(define (main) : i64 (cfg feature (if) 42))"
        (compiler-cfg-empty)
        1)
      (compiler-parse-cfg-error?
        "(define (main) : i64 (cfg feature (if) 42))"
        feature-cfg))))

(define (compiler-parse-declaration-tests-ok?) : bool
  (and
    (compiler-parse-ok? "(define answer : i64 42)")
    (compiler-parse-ok? "(define (add [a : i64] [b : i64]) : i64 (+ a b))")
    (compiler-parse-ok? "(extern (puts [arg0 : String]) : unit)")
    (compiler-parse-ok? "(defenum Maybe (Some i64) (None))")
    (compiler-parse-ok? "(defstruct Point (x i64) (y i64))")
    (compiler-parse-ok? "(import \"stdlib/tl\")")
    (compiler-parse-include-str-ok?)
    (compiler-parse-include-str-errors-ok?)
    (compiler-parse-include-str-comptime-ok?)
    (compiler-parse-include-str-comptime-errors-ok?)
    (compiler-parse-include-str-lzss-ok?)
    (compiler-parse-include-str-lzss-errors-ok?)
    (compiler-parse-removed-compressed-include-rejected?)
    (compiler-parse-include-bin-ok?)
    (compiler-parse-include-bin-errors-ok?)
    (compiler-parse-error-ok?
      "(define answer : i64)"
      "parse: malformed value definition")
    (compiler-parse-error-ok?
      "(define (main) : i64)"
      "parse: malformed function definition")
    (compiler-parse-error-ok? "(extern puts)" "parse: malformed extern")
    (compiler-parse-error-ok? "(defenum)" "parse: malformed defenum")
    (compiler-parse-error-ok? "(defstruct)" "parse: malformed defstruct")
    (compiler-parse-error-ok? "(import)" "parse: malformed import")))

;; enum/struct expression coverage: defenum empty rejection,
;; defstruct mixed field types, empty struct rejection, struct-get, and
;; struct construction-as-call.
(define (compiler-parse-enum-struct-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(defenum Empty)"
      "parse: defenum needs at least one variant")
    (compiler-parse-ok? "(defstruct Point (x i64) (y i64))")
    (compiler-parse-ok? "(defstruct Mixed (a i64) (b bool) (c f64))")
    (compiler-parse-error-ok?
      "(defstruct Empty)"
      "parse: defstruct needs at least one field")
    (compiler-parse-ok? "(define (f [p : Point]) : i64 (struct-get p x))")
    (compiler-parse-ok? "(define (f) : Point (Point 1 2))")
    (compiler-parse-ok? "(defstruct RefBox (:lifetimes a) (value (& a i64)))")
    (compiler-parse-ok?
      "(defenum RefOption (:lifetimes a) (SomeRef (& a i64)) (NoRef))")
    (compiler-parse-ok?
      "(define (f [box : (RefBox n)]) : (& n i64) (struct-get box value))")))

;
;; Let-binding parsing accepts only leading bracket bindings, including the
;; canonical empty `[]` wrapper.
(define (compiler-parse-let-tests-ok?) : bool
  (and
    (compiler-parse-ok? "(define (main) : i64 (let [x 1] x))")
    (compiler-parse-ok?
      "(define (main) : i64 (let [x : i64 1] [y : i64 2] (+ x y)))")
    (compiler-parse-ok? "(define (main) : i64 (let [x 1] [y (+ x 1)] y))")
    (compiler-parse-ok? "(define (main) : i64 (let [] 0))")))

(define (compiler-parse-implicit-body-tail-ok?) : bool
  (and
    (compiler-parse-ok? "(define (main) : i64 (let [x : i64 1] x (+ x 1)))")
    (compiler-parse-ok? "(define (main) : i64 (let [] 1 2))")
    (compiler-parse-ok?
      "(define (main) : i64 (begin (while false unit unit) 0))")
    (compiler-parse-ok? "(define (main) : i64 unit 42)")
    (compiler-parse-ok? "(define (main) : i64 ((lambda () : i64 unit 42)))")))

(define (compiler-parse-spmd-tests-ok?) : bool
  (and
    (compiler-parse-ok?
      "(define (main) : i64 (begin (foreach ([i : i64 0 3]) unit) 0))")
    (compiler-parse-ok?
      "(define (main [xs : (Array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (array-ref xs i)))")
    (compiler-parse-ok?
      "(define (main [xs : (Array i64)] [out : (Array i64)] [n : i64]) : i64 (begin (foreach ([i : i64 0 n]) (array-set! out i (spmd-broadcast (array-ref xs i) 0))) 0))")
    (compiler-parse-ok?
      "(define (main [xs : (Array i64)] [out : (Array i64)] [n : i64]) : i64 (begin (foreach ([i : i64 0 n]) (array-set! out i (spmd-shuffle (array-ref xs i) i))) 0))")
    (compiler-parse-ok?
      "(define (main [out : (Array i64)] [n : i64]) : i64 (begin (foreach ([i : i64 0 n]) (array-set! out i (+ (program-index) (program-count)))) 0))")
    ;; An empty range, a non-i64 index type, and expression
    ;; start/end bounds all parse (range semantics are checked later).
    (compiler-parse-ok?
      "(define (main) : i64 (begin (foreach ([i : i64 5 5]) unit) 0))")
    (compiler-parse-ok?
      "(define (main) : i64 (begin (foreach ([i : u32 0 3]) unit) 0))")
    (compiler-parse-ok?
      "(define (main [n : i64]) : i64 (begin (foreach ([i : i64 (+ 0 1) (* n 2)]) unit) 0))")
    ;; An unknown reduce operator is rejected by the parser.
    (compiler-parse-error-ok?
      "(define (main [n : i64]) : i64 (spmd-reduce bogus ([i : i64 0 n]) 0 i))"
      "parse: unsupported spmd-reduce operator `bogus`; expected one of sum, min, max, all, any")
    (compiler-parse-error-ok?
      "(define (main) : i64 (begin (foreach ([i i64 0 3 4]) unit) 0))"
      "parse: expected ':' in foreach")
    (compiler-parse-error-ok?
      "(define (main) : i64 (begin (foreach ([i : i64 0]) unit) 0))"
      "parse: malformed foreach binding")
    (compiler-parse-error-ok?
      "(define (main) : i64 (begin (foreach) 0))"
      "parse: malformed foreach")
    (compiler-parse-error-ok?
      "(define (main) : i64 (spmd-reduce sum))"
      "parse: malformed spmd-reduce")
    (compiler-parse-error-ok?
      "(define (main) : i64 (spmd-broadcast 1))"
      "parse: malformed spmd-broadcast")
    (compiler-parse-error-ok?
      "(define (main) : i64 (spmd-shuffle 1))"
      "parse: malformed spmd-shuffle")
    (compiler-parse-error-ok?
      "(define (main) : i64 (program-index 0))"
      "parse: program-index expects no arguments")
    (compiler-parse-error-ok?
      "(define (main) : i64 (program-count 0))"
      "parse: program-count expects no arguments")))

(define (compiler-parse-pattern-tests-ok?) : bool
  (and
    (compiler-parse-ok? "(define (main) : i64 (match 1 [0 1] [_ 0]))")
    (compiler-parse-ok?
      "(define (main [b : bool]) : i64 (match b [true 1] [false 0]))")
    (compiler-parse-ok?
      "(defenum E (A i64) (B))
(define (main [e : E]) : i64 (match e [(A x) x] [(B) 0]))")
    (compiler-parse-ok? "(define (main) : i64 (match 5 [x x]))")
    (compiler-parse-error-ok?
      "(define (main) : i64 (match))"
      "parse: malformed match")
    (compiler-parse-error-ok?
      "(define (main) : i64 (match 1 [_]))"
      "parse: malformed match arm")
    (compiler-parse-error-ok?
      "(define (main) : i64 (match 1 [() 0]))"
      "parse: expected pattern")))

;; pattern literals: string literal arms, nested string payload,
;; char literals in pattern and value position.
(define (compiler-parse-pattern-string-char-tests-ok?) : bool
  (and
    ;; string literal arms
    (compiler-parse-ok?
      "(define (f [s : String]) : i64 (match s [\"if\" 10] [\"let\" 20] [_ 0]))")
    ;; nested string payload
    (compiler-parse-ok?
      "(defenum Token (TIdent String))\n(define (f [t : Token]) : i64 (match t [(TIdent \"if\") 1] [_ 0]))")
    ;; char literal in pattern (space + literal char)
    (compiler-parse-ok?
      "(define (f [c : char]) : i64 (match c [' ' 1] ['a' 2] [_ 0]))")
    ;; escaped char literal in value position
    (compiler-parse-ok? "(define (f) : char '\\n')")))

;
;; operator parsing: accept unary (not/neg/bit-not), binary
;; arithmetic/comparison, and bitwise/shift operator forms; reject
;; parser-owned malformed unary/binary operator expressions. Parse-shape only;
;; operator type rules live in the typechecker tests.
(define (compiler-parse-operator-tests-ok?) : bool
  (and
    (compiler-parse-ok?
      "(define (main [a : i64] [p : bool]) : i64 (begin (neg a) (bit-not a) (if (not p) 1 0)))")
    (compiler-parse-ok?
      "(define (main [a : i64] [b : i64]) : i64 (begin (+ a b) (- a b) (* a b) (< a b) (<= a b) (> a b) (>= a b) (= a b) (!= a b)))")
    (compiler-parse-ok?
      "(define (main [a : i64] [b : i64] [c : i64] [d : i64]) : i64 (begin (+ a b c d) (* a b c d)))")
    (compiler-parse-ok?
      "(define (main [a : i64] [b : i64] [p : bool]) : i64 (begin (bit-and a b) (bit-or a b) (bit-xor a b) (shl a b) (shr a b) (if (not p) 1 0)))")
    (compiler-parse-ok?
      "(define (main [a : i64] [b : i64] [c : i64] [d : i64]) : i64 (begin (bit-and a b c d) (bit-or a b c d) (bit-xor a b c d)))")
    (compiler-parse-error-ok?
      "(define (main) : i64 (not))"
      "parse: malformed unary expression")
    (compiler-parse-error-ok?
      "(define (main [a : i64]) : i64 (+ a))"
      "parse: malformed binary expression")
    (compiler-parse-error-ok?
      "(define (main) : i64 (+))"
      "parse: malformed binary expression")
    (compiler-parse-error-ok?
      "(define (main [a : i64]) : i64 (* a))"
      "parse: malformed binary expression")
    (compiler-parse-error-ok?
      "(define (main) : i64 (*))"
      "parse: malformed binary expression")
    (compiler-parse-error-ok?
      "(define (main [a : i64]) : i64 (bit-and a))"
      "parse: malformed binary expression")
    (compiler-parse-error-ok?
      "(define (main) : i64 (bit-or))"
      "parse: malformed binary expression")
    (compiler-parse-error-ok?
      "(define (main [a : i64] [b : i64] [c : i64]) : i64 (shl a b c))"
      "parse: malformed binary expression")))

(define (compiler-parse-type-literal-tests-ok?) : bool
  (and
    (compiler-parse-ok? "(define (main) : i64 (begin (type i64) 0))")
    (compiler-parse-ok? "(define (main) : i64 (begin (type (Array i64)) 0))")
    (compiler-parse-ok?
      "(define (main) : i64 (begin (type (__tl_dyn-array i64)) 0))")
    (compiler-parse-ok? "(define (main) : i64 (begin (type (-> i64 i64)) 0))")
    (compiler-parse-error-ok?
      "(define (main) : i64 (begin (type (__tl_dyn-array i64 4)) 0))"
      "parse: __tl_dyn-array expects exactly one type")
    (compiler-parse-error-ok?
      "(define (main) : i64 (type))"
      "parse: type expects exactly one type")
    (compiler-parse-error-ok?
      "(define (main) : i64 (type i64 bool))"
      "parse: type expects exactly one type")))

;; region parsing: `(with-arena <ident> body+)` accepts (basic,
;; multi-expression body, nested region) and rejects missing binder,
;; non-identifier binder, and empty body. Parse-shape + parser-owned diagnostics
;; only; region typing/lowering live in their own tests.
(define (compiler-parse-region-tests-ok?) : bool
  (and
    (compiler-parse-ok? "(define (main) : i64 (with-arena r 0))")
    (compiler-parse-ok? "(define (main) : i64 (with-arena r 1 2 0))")
    (compiler-parse-ok? "(define (main) : i64 (with-arena r (with-arena s 0)))")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with-arena))"
      "parse: with-arena requires a region name before its body")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with-arena 5 0))"
      "parse: with-arena region name must be an identifier")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with-arena r))"
      "parse: with-arena 'r' requires a non-empty body")))

(define (compiler-parse-with-escape-shape-ok?) : bool
  (match (parse-ast-source
    "(define (main) : String (with-escape (arena-make) (string.int->string 42)))")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons
              (AstDecl.DefFn decl-meta _ _ _ body-box _)
              rest)
            (let
              [body : AstExpr (ast-node-get body-box)]
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (match (ast-expr-unspan body)
                    [(AstExpr.WithEscape scratch-box body-exprs)
                      (let
                        [scratch : AstExpr (ast-node-get scratch-box)]
                        (match (ast-expr-unspan scratch)
                          [(AstExpr.Call callee-box call-args)
                            (let
                              [callee : AstExpr (ast-node-get callee-box)]
                              (match (ast-expr-unspan callee)
                                [(AstExpr.Var name)
                                  (and
                                    (= (struct-get (& call-args) len) 0)
                                    (string.eq (intern-str name) "arena-make")
                                    (= (struct-get (& body-exprs) len) 1))]
                                [_ false]))]
                          [_ false]))]
                    [_ false])]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-with-escape-tests-ok?) : bool
  (and
    (compiler-parse-with-escape-shape-ok?)
    (compiler-parse-ok?
      "(define (main) : i64 (let [scratch : Arena (arena-make)] (with-escape scratch 1 2 3)))")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with-escape))"
      "parse: with-escape requires a scratch arena before its body")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with-escape (arena-make)))"
      "parse: with-escape requires a non-empty body")))

(define (compiler-parse-with-scratch-shape-ok?) : bool
  (match (parse-ast-source
    "(define (main) : String (with-scratch (string.int->string 41) (string.int->string 42)))")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons
              (AstDecl.DefFn decl-meta _ _ _ body-box _)
              rest)
            (let
              [body : AstExpr (ast-node-get body-box)]
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (match (ast-expr-unspan body)
                    [(AstExpr.WithScratch body-exprs)
                      (= (struct-get (& body-exprs) len) 2)]
                    [_ false])]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-with-scratch-tests-ok?) : bool
  (and
    (compiler-parse-with-scratch-shape-ok?)
    (compiler-parse-ok? "(define (main) : i64 (with-scratch 1 2 3))")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with-scratch))"
      "parse: with-scratch requires a non-empty body")))

(define (compiler-parse-in-arena-shape-ok?) : bool
  (match (parse-ast-source
    "(define (main [arena : Arena]) : i64 (in-arena arena 1 2))")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons
              (AstDecl.DefFn decl-meta _ _ _ body-box _)
              rest)
            (let
              [body : AstExpr (ast-node-get body-box)]
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (match (ast-expr-unspan body)
                    [(AstExpr.InArena arena-box body-exprs)
                      (let
                        [arena : AstExpr (ast-node-get arena-box)]
                        (match (ast-expr-unspan arena)
                          [(AstExpr.Var name)
                            (and
                              (string.eq (intern-str name) "arena")
                              (= (struct-get (& body-exprs) len) 2))]
                          [_ false]))]
                    [_ false])]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-in-arena-tests-ok?) : bool
  (and
    (compiler-parse-in-arena-shape-ok?)
    (compiler-parse-ok?
      "(define (main) : i64 (let [arena : Arena (arena-current)] (in-arena arena 1 2 3)))")
    (compiler-parse-error-ok?
      "(define (main) : i64 (in-arena))"
      "parse: in-arena requires an arena before its body")
    (compiler-parse-error-ok?
      "(define (main) : i64 (in-arena 0))"
      "parse: in-arena requires a non-empty body")))

(define (compiler-parse-resource-with-source) : String
  "(define (main) : i64
  (with ([h (open-handle) close-handle]
         [tmp (open-temp) close-temp])
    (use h)
    (with ([inner (open-inner tmp) close-inner])
      42)))")

(define (compiler-parse-resource-with-shape-ok?) : bool
  (match (parse-ast-source (compiler-parse-resource-with-source))
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons
              (AstDecl.DefFn decl-meta _ _ _ body-box _)
              rest)
            (let
              [body : AstExpr (ast-node-get body-box)]
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (match (ast-expr-unspan body)
                    [(AstExpr.WithResource wr-box)
                      (match (box-get wr-box)
                        [(AstWithResource.WithResource bindings body-exprs)
                          (if (and
                            (=
                              (compiler-parse-resource-binding-count bindings)
                              2)
                            (= (compiler-parse-expr-list-count body-exprs) 2))
                            (let
                              [nested : AstExpr
                                (ast-node-get
                                  (ast-expr-list-get (& body-exprs) 1 0))]
                              (match (ast-expr-unspan nested)
                                [(AstExpr.WithResource nested-wr-box)
                                  (match (box-get nested-wr-box)
                                    [(AstWithResource.WithResource
                                        nested-bindings
                                        nested-body)
                                      (and
                                        (=
                                          (compiler-parse-resource-binding-count
                                            nested-bindings)
                                          1)
                                        (=
                                          (compiler-parse-expr-list-count
                                            nested-body)
                                          1))])]
                                [_ false]))
                            false)])]
                    [_ false])]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-resource-with-tests-ok?) : bool
  (and
    (compiler-parse-resource-with-shape-ok?)
    (compiler-parse-ok?
      "(define (main) : i64 (with ([h (open-handle) close-handle]) 42))")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with))"
      "parse: with requires a binding list before its body")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with () 42))"
      "parse: with requires a non-empty binding list")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with ([1 (open) close]) 42))"
      "parse: with binding name must be an identifier")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with ([h]) 42))"
      "parse: with binding is missing initializer")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with ([h (open)]) 42))"
      "parse: with binding is missing cleanup function")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with ([h (open) close extra]) 42))"
      "parse: with binding has too many fields")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with ([h (open) close])))"
      "parse: with requires a non-empty body")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with [h (open) close] 42))"
      "parse: malformed with binding list")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with ((h (open) close)) 42))"
      "parse: with binding must use bracket syntax")))

(define (compiler-parse-quote-syntax-shape-ok?) : bool
  (match (parse-ast-source
    "(define (mk [e : Expr]) : Expr `(if ,e true false))")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons
              (AstDecl.DefFn decl-meta _ _ ret-ty body-box _)
              rest)
            (let
              [body : AstExpr (ast-node-get body-box)]
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (and
                    (match ret-ty
                      [(AstType.Var name) (string.eq (intern-str name) "Expr")]
                      [_ false])
                    (match (ast-expr-unspan body)
                      [(AstExpr.Quasiquote template-box)
                        (let
                          [template : AstExpr (ast-node-get template-box)]
                          (match (ast-expr-unspan template)
                            [(AstExpr.If cond-box _ _)
                              (let
                                [cond : AstExpr (ast-node-get cond-box)]
                                (match (ast-expr-unspan cond)
                                  [(AstExpr.Unquote unquoted-box)
                                    (let
                                      [unquoted : AstExpr
                                        (ast-node-get unquoted-box)]
                                      (match (ast-expr-unspan unquoted)
                                        [(AstExpr.Var name)
                                          (string.eq (intern-str name) "e")]
                                        [_ false]))]
                                  [_ false]))]
                            [_ false]))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-quote-syntax-tests-ok?) : bool
  (and
    (compiler-parse-quote-syntax-shape-ok?)
    (compiler-parse-ok? "(define x : Expr '(+ 1 2))")
    (compiler-parse-ok? "(define x : Expr `(begin ,@xs))")
    (compiler-parse-ok?
      "(define (mk [target : Expr]) : Expr `(set! ,target 1))")
    (compiler-parse-error-ok?
      "(define x : Expr (quote))"
      "parse: quote form expects exactly one expression")))

;; REPL-item parsing: `parse-ast-repl-source` accepts a single
;; top-level declaration, a parenthesized expression, or a bare expression, and
;; rejects trailing tokens and a malformed expression. Mirrors the Rust
;; parser's `parse_repl_item` tests.
(define (compiler-parse-repl-decl-ok? [src : String]) : bool
  (match (parse-ast-repl-source src)
    [(ResultAstReplItem.Ok item)
      (match item
        [(AstReplDecl _) true]
        [(AstReplExpr _) false])]
    [(ResultAstReplItem.Err _) false]))

(define (compiler-parse-repl-expr-ok? [src : String]) : bool
  (match (parse-ast-repl-source src)
    [(ResultAstReplItem.Ok item)
      (match item
        [(AstReplExpr _) true]
        [(AstReplDecl _) false])]
    [(ResultAstReplItem.Err _) false]))

(define (compiler-parse-repl-error-ok? [src : String] [expected : String]) : bool
  (match (parse-ast-repl-source src)
    [(ResultAstReplItem.Ok _) false]
    [(ResultAstReplItem.Err message) (string.eq message expected)]))

(define (compiler-parse-repl-tests-ok?) : bool
  (and
    ;; declaration item
    (compiler-parse-repl-decl-ok? "(define x : i64 42)")
    ;; parenthesized expression item
    (compiler-parse-repl-expr-ok? "(+ 1 2)")
    ;; unknown function-style calls are REPL expressions, not module macro decls
    (compiler-parse-repl-expr-ok? "(double 4)")
    ;; bare expression item
    (compiler-parse-repl-expr-ok? "42")
    ;; trailing tokens after a complete item are rejected
    (compiler-parse-repl-error-ok?
      "42 43"
      "parse: trailing tokens after REPL input")
    ;; a malformed expression item surfaces the expression diagnostic
    (compiler-parse-repl-error-ok? "(+ 1)" "parse: malformed binary expression")))

;; comptime function-parameter parsing: `[comptime n : i64]`
;; and the type-valued `[comptime T : type]` parse as top-level function
;; parameters marked comptime; a comptime parameter on a lambda is rejected
;; (comptime params are top-level-only). Mirrors the Rust parser's
;; test_parse_comptime_function_param / _type_valued_comptime_param /
;; _comptime_lambda_param_rejected.
(define (compiler-parse-first-fn-has-comptime-param? [src : String]) : bool
  (match (parse-ast-source src)
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons (AstDecl.DefFn decl-meta _ params _ _ _) _)
            (ast-param-list-has-comptime? params)]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-comptime-param-tests-ok?) : bool
  (and
    (compiler-parse-first-fn-has-comptime-param?
      "(define (scale [comptime n : i64] [x : i64]) : i64 (* n x))")
    (compiler-parse-first-fn-has-comptime-param?
      "(define (alloc [comptime T : type] [n : i64]) : (Array i64) (make-array T n))")
    (compiler-parse-error-ok?
      "(define (main) : i64 ((lambda ([comptime n : i64]) n) 1))"
      "comptime parameters are only supported on top-level function definitions")))

(define (compiler-parse-defmacro-shape-ok?) : bool
  (match (parse-ast-source
    "(defmacro (all [first : bool] [rest : bool ...]) : bool first)")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-step decls)
          [(AstDeclListStep.Cons
              (AstDecl.DefMacro
                ast-decl-meta-runtime
                name
                params
                (AstType.Bool)
                _)
              rest)
            (let
              [rest : AstDeclList rest]
              (match (ast-decl-list-step rest)
                [(AstDeclListStep.Nil)
                  (and
                    (= name (reader.read-stable-symbol-id "all"))
                    (= (ast-macro-param-list-len (& params)) 2)
                    (match (ast-macro-param-list-get
                      (& params)
                      0
                      (ast-macro-param-fallback))
                      [(AstMacroParam.Param
                          first
                          (AstType.Bool)
                          false
                          (AstMacroTypeKindList.Nil))
                        (= first (reader.read-stable-symbol-id "first"))]
                      [_ false])
                    (match (ast-macro-param-list-get
                      (& params)
                      1
                      (ast-macro-param-fallback))
                      [(AstMacroParam.Param
                          rest
                          (AstType.Bool)
                          true
                          (AstMacroTypeKindList.Nil))
                        (= rest (reader.read-stable-symbol-id "rest"))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-macro-type-kind-list-shape-ok?
  [kinds : AstMacroTypeKindList]) : bool
  (match kinds
    [(AstMacroTypeKindList.Cons i64-kind i64-rest)
      (and
        (string.eq (ci.intern-str i64-kind) "i64")
        (match (box-get i64-rest)
          [(AstMacroTypeKindList.Cons struct-kind struct-rest)
            (and
              (string.eq (ci.intern-str struct-kind) "struct")
              (match (box-get struct-rest)
                [(AstMacroTypeKindList.Cons type-var-kind end)
                  (and
                    (string.eq (ci.intern-str type-var-kind) "type-var")
                    (match (box-get end)
                      [(AstMacroTypeKindList.Nil) true]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [_ false]))

(define (compiler-parse-defmacro-type-kind-constraint-shape-ok?) : bool
  (match (parse-ast-source
    "(defmacro (catalog [T : type (:kind i64 struct type-var)]) : Module unit)")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (match (ast-decl-list-step (box-get decls-box))
        [(AstDeclListStep.Cons
            (AstDecl.DefMacro decl-meta name params _ _)
            rest)
          (and
            (string.eq (ci.intern-str name) "catalog")
            (match (ast-decl-list-step rest)
              [(AstDeclListStep.Nil) true]
              [_ false])
            (= (ast-macro-param-list-len (& params)) 1)
            (match (ast-macro-param-list-get
              (& params)
              0
              (ast-macro-param-fallback))
              [(AstMacroParam.Param
                  param-name
                  (AstType.Var type-name)
                  false
                  type-kinds)
                (and
                  (string.eq (ci.intern-str param-name) "T")
                  (string.eq (ci.intern-str type-name) "type")
                  (compiler-parse-macro-type-kind-list-shape-ok? type-kinds))]
              [_ false]))]
        [_ false])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-fixed-source-id-only-ok?
  [text : String]
  [fixed-id : i64]) : bool
  (let
    [source-id : i64 (reader.read-stable-symbol-id text)]
    [generated-id : i64 (ci.intern-generated-canonical-name text)]
    [macro-global-id : i64
      (+ (ci.intern-macro-global-structural-base) source-id)]
    (and
      (= source-id fixed-id)
      (not (= generated-id fixed-id))
      (ci.intern-macro-global-structural-id? macro-global-id)
      (string.eq (compiler-parse-name-text macro-global-id) text)
      (not (= macro-global-id fixed-id)))))

(define (compiler-parse-fixed-syntax-name-provenance-ok?) : bool
  (let
    [source-kind : i64 (reader.read-stable-symbol-id "i64")]
    [generated-kind : i64 (ci.intern-generated-canonical-name "i64")]
    [source-all : i64 (reader.read-stable-symbol-id "all")]
    [generated-all : i64 (ci.intern-generated-canonical-name "all")]
    [source-dots : i64 (reader.read-stable-symbol-id "...")]
    [generated-dots : i64 (ci.intern-generated-canonical-name "...")]
    (and
      (parse-ast-macro-type-kind-known? source-kind)
      (not (parse-ast-macro-type-kind-known? generated-kind))
      (= source-all (cbi.compiler-builtin-ctfe-ref 219))
      (not (= generated-all (cbi.compiler-builtin-ctfe-ref 219)))
      (= source-dots (cbi.compiler-builtin-ctfe-ref 222))
      (not (= generated-dots (cbi.compiler-builtin-ctfe-ref 222)))
      ;; One adversarial spelling per new fixed-name family proves that equal
      ;; rendered text does not confer parser syntax identity.
      (compiler-parse-fixed-source-id-only-ok?
        ":cleanup"
        (cbi.compiler-builtin-ctfe-ref 234))
      (compiler-parse-fixed-source-id-only-ok?
        "scalar"
        (cbi.compiler-builtin-ctfe-ref 240))
      (compiler-parse-fixed-source-id-only-ok?
        "cfg"
        (cbi.compiler-builtin-ctfe-ref 243))
      (compiler-parse-fixed-source-id-only-ok?
        "sum"
        (cbi.compiler-builtin-ctfe-ref 262))
      (compiler-parse-fixed-source-id-only-ok?
        ":spmd-callable"
        (cbi.compiler-builtin-ctfe-ref 253))
      (compiler-parse-fixed-source-id-only-ok?
        ":abi"
        (cbi.compiler-builtin-ctfe-ref 255))
      (compiler-parse-fixed-source-id-only-ok?
        "as"
        (cbi.compiler-builtin-ctfe-ref 260))
      (compiler-parse-fixed-source-id-only-ok?
        "defgeneric"
        (cbi.compiler-builtin-ctfe-ref 265)))))

(define (compiler-parse-defmacro-tests-ok?) : bool
  (and
    (compiler-parse-defmacro-shape-ok?)
    (compiler-parse-defmacro-type-kind-constraint-shape-ok?)
    (compiler-parse-fixed-syntax-name-provenance-ok?)
    (compiler-parse-ok?
      "(defmacro (and2 [lhs : bool] [rhs : bool]) : bool (expr-if lhs rhs (expr-bool false)))")
    (compiler-parse-ok?
      "(defmacro (binding-body [bindings : ExprBindingClause ...] [body : Expr ...]) : Expr (expr-list-nth body 0))")
    (compiler-parse-error-ok?
      "(defmacro (bad [rest : bool ...] [x : bool]) : bool rest)"
      "parse: only ExprBindingClause macro operands may be variadic before a later operand")
    (compiler-parse-error-ok?
      "(defmacro (bad [T : type (:kind)]) : Module unit)"
      "parse: macro type operand T constraint :kind requires at least one kind")
    (compiler-parse-error-ok?
      "(defmacro (bad [T : type (:kind i64 i64)]) : Module unit)"
      "parse: macro type operand T constraint :kind has duplicate kind i64")
    (compiler-parse-error-ok?
      "(defmacro (bad [T : type (:kind record)]) : Module unit)"
      "parse: macro type operand T constraint :kind has unknown kind record")
    (compiler-parse-error-ok?
      "(defmacro (bad [value : Expr (:kind i64)]) : Expr value)"
      "parse: macro operand value constraint :kind is only legal on fixed type operands")
    (compiler-parse-error-ok?
      "(defmacro (bad [T : type (:kind i64) ...]) : Module unit)"
      "parse: macro type operand T constraint :kind is not legal on variadic operands")
    (compiler-parse-error-ok?
      "(defmacro (bad [T : type (:kind i64) (:kind i32)]) : Module unit)"
      "parse: macro type operand T constraint :kind allows only one constraint form")
    (compiler-parse-error-ok?
      "(defmacro (bad [T : type (:shape struct)]) : Module unit)"
      "parse: macro type operand T has unknown constraint form :shape")
    (compiler-parse-error-ok?
      "(defmacro (bad [T : type (:kind \"i64\")]) : Module unit)"
      "parse: macro type operand T constraint :kind expects unquoted kind names")))

(define (compiler-parse-dispatch-state-interleaving-in-arena-ok?) : bool
  (let
    [owner-a : ci.InternCompatState (ci.intern-compat-state-new)]
    [owner-b : ci.InternCompatState (ci.intern-compat-state-new)]
    [name-a : i64 (ci.intern-compat-state-intern owner-a "only-a")]
    [name-b : i64 (ci.intern-compat-state-intern owner-b "only-b")]
    [marker-a : i64 (ci.intern-compat-state-intern owner-a "defdispatch")]
    [marker-b : i64 (ci.intern-compat-state-intern owner-b "defdispatch")]
    [state-a : CompilerParseState
      (compiler-parse-state-new-with-intern-state owner-a)]
    [state-b : CompilerParseState
      (compiler-parse-state-new-with-intern-state owner-b)]
    [control-a : i64 (compiler-parse-state-control-addr state-a)]
    [control-b : i64 (compiler-parse-state-control-addr state-b)]
    [env-a : sym_i64_env.SymI64Env
      (compiler-parse-state-cfgs
        state-a
        (sym_i64_env.sym-i64-bind-id
          (sym_i64_env.sym-i64-bind-id
            (sym_i64_env.sym-i64-empty)
            name-a
            (compiler-parse-tag-bin-add))
          marker-a
          (compiler-parse-tag-decl-defdispatch)))]
    [env-b : sym_i64_env.SymI64Env
      (compiler-parse-state-cfgs
        state-b
        (sym_i64_env.sym-i64-bind-id
          (sym_i64_env.sym-i64-bind-id
            (sym_i64_env.sym-i64-empty)
            name-b
            (compiler-parse-tag-bin-sub))
          marker-b
          (compiler-parse-tag-decl-defdispatch)))]
    (begin
      (compiler-parse-dispatch-index-populate! control-a env-a)
      (compiler-parse-dispatch-index-populate! control-b env-b)
      (let
        [indexed-a : sym_i64_env.SymI64Env
          (compiler-parse-dispatch-index-mark env-a)]
        [indexed-b : sym_i64_env.SymI64Env
          (compiler-parse-dispatch-index-mark env-b)]
        (and
          (= name-a name-b)
          (string.eq (ci.intern-compat-state-str owner-a name-a) "only-a")
          (string.eq (ci.intern-compat-state-str owner-b name-b) "only-b")
          (compiler-parse-dispatch-indexed? indexed-a)
          (compiler-parse-dispatch-indexed? indexed-b)
          (=
            (compiler-parse-dispatch-tag-id indexed-a name-a)
            (compiler-parse-tag-bin-add))
          (=
            (compiler-parse-dispatch-tag-id indexed-b name-b)
            (compiler-parse-tag-bin-sub))
          (=
            (compiler-parse-dispatch-tag-id indexed-a name-a)
            (compiler-parse-tag-bin-add)))))))

(define (compiler-parse-dispatch-state-interleaving-ok?) : bool
  (let
    [previous-arena : i64 (arena.tl_arena_current)]
    [scratch-arena : i64 (arena.tl_arena_make)]
    [ok : bool
      (begin
        (unsafe
          (arena.tl_arena_set scratch-arena))
        (compiler-parse-dispatch-state-interleaving-in-arena-ok?))]
    (begin
      (unsafe
        (arena.tl_arena_set previous-arena))
      (unsafe
        (arena.tl_arena_destroy scratch-arena))
      ok)))

(define (compiler-parse-diagnostic-invocations-interleaving-ok?) : bool
  (let
    [base : sym_i64_env.SymI64Env (compiler-parse-dispatch-env)]
    [frame-a : (Array i64) (array.make-array i64 5)]
    [frame-b : (Array i64) (array.make-array i64 5)]
    [dispatch-a : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind-id
        base
        compiler-parse-invocation-marker-id
        (compiler-parse-array-data-addr-i64 frame-a))]
    [dispatch-b : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind-id
        base
        compiler-parse-invocation-marker-id
        (compiler-parse-array-data-addr-i64 frame-b))]
    [fallback : token.SourceSpan (token.SourceSpan 9 9 9 9)]
    (begin
      (parse-ast-error-span-clear! dispatch-a)
      (parse-ast-error-span-clear! dispatch-b)
      (parse-ast-error-span-note! dispatch-a (token.SourceSpan 1 2 3 4))
      (parse-ast-error-span-note! dispatch-b (token.SourceSpan 5 6 7 8))
      (parse-ast-error-span-note! dispatch-a (token.SourceSpan 10 11 12 13))
      (let
        [span-a : token.SourceSpan
          (parse-ast-error-span-current dispatch-a fallback)]
        [span-b : token.SourceSpan
          (parse-ast-error-span-current dispatch-b fallback)]
        (and
          (= (token.span-start-line span-a) 1)
          (= (token.span-start-col span-a) 2)
          (= (token.span-end-line span-a) 3)
          (= (token.span-end-col span-a) 4)
          (= (token.span-start-line span-b) 5)
          (= (token.span-start-col span-b) 6)
          (= (token.span-end-line span-b) 7)
          (= (token.span-end-col span-b) 8))))))

(define (compiler-parse-type-literal-state-interleaving-ok?) : bool
  (let
    [state-a : CompilerParseState (compiler-parse-state-new)]
    [state-b : CompilerParseState (compiler-parse-state-new)]
    [cfgs-a : sym_i64_env.SymI64Env
      (compiler-parse-state-cfgs state-a (compiler-cfg-empty))]
    [cfgs-b : sym_i64_env.SymI64Env
      (compiler-parse-state-cfgs state-b (compiler-cfg-empty))]
    (begin
      (compiler-parse-state-type-literal-reset! state-a)
      (compiler-parse-state-type-literal-reset! state-b)
      (match (parse-ast-source-with-cfg
        "(define value : i64 (begin (type i64) 1))"
        cfgs-a)
        [(ResultAstProgram.Err _) false]
        [(ResultAstProgram.Ok _)
          (match (parse-ast-source-with-cfg "(define value : i64 1)" cfgs-b)
            [(ResultAstProgram.Err _) false]
            [(ResultAstProgram.Ok _)
              (and
                (compiler-parse-state-has-type-literal? state-a)
                (not (compiler-parse-state-has-type-literal? state-b)))])]))))

(define (compiler-parse-dispatch-index-env-matches?
  [dispatch : sym_i64_env.SymI64Env]) : bool
  (let
    [control : i64 (compiler-parse-dispatch-indexed-control dispatch)]
    [ok : bool (not (= control 0))]
    [cursor : sym_i64_env.SymI64Env dispatch]
    [done : bool false]
    (begin
      (while (and ok (not done))
        (match cursor
          [(sym_i64_env.SymI64Nil) (set! done true)]
          [(sym_i64_env.SymI64Bind name-id tag rest)
            (if (or
              (< name-id 0)
              (= (compiler-parse-dispatch-index-lookup-id control name-id) tag))
              (set! cursor (box-get rest))
              (set! ok false))]))
      (and ok done))))

(define (compiler-parse-dispatch-index-ok?) : bool
  (let
    [full : sym_i64_env.SymI64Env (compiler-parse-dispatch-env)]
    [partial : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-binops (sym_i64_env.sym-i64-empty))]
    [cfgs : sym_i64_env.SymI64Env
      (compiler-cfg-enable (compiler-cfg-empty) "dispatch-index-test")]
    [configured : sym_i64_env.SymI64Env
      (parse-ast-program-dispatch-with-cfg cfgs)]
    (and
      (compiler-parse-dispatch-index-env-matches? full)
      (=
        (compiler-parse-dispatch-tag full (reader.read-stable-symbol-id "if"))
        (compiler-parse-tag-expr-if))
      (=
        (compiler-parse-dispatch-tag
          full
          (reader.read-stable-symbol-id "not-parser-syntax"))
        (compiler-parse-tag-unknown))
      (not (compiler-parse-dispatch-indexed? partial))
      (=
        (compiler-parse-dispatch-tag partial (reader.read-stable-symbol-id "+"))
        (compiler-parse-tag-bin-add))
      (=
        (compiler-parse-dispatch-tag
          partial
          (reader.read-stable-symbol-id "if"))
        (compiler-parse-tag-unknown))
      (compiler-parse-dispatch-indexed? configured)
      (compiler-cfg-enabled?
        configured
        (reader.read-stable-symbol-id "dispatch-index-test")))))

(define (compiler-parse-shape-tests-front-ok? [program : AstProgram]) : bool
  (and
    (= (compiler-parse-smoke-score program) 36)
    (compiler-parse-nested-expr-span-ok?)
    (compiler-parse-error-span-ok?)
    (compiler-parse-float-literal-ok?)
    (compiler-parse-region-ok?)
    (compiler-parse-arena-ok?)))

(define (compiler-parse-shape-tests-middle-ok?) : bool
  (and
    (compiler-parse-dispatch-index-ok?)
    (compiler-parse-dispatch-state-interleaving-ok?)
    (compiler-parse-diagnostic-invocations-interleaving-ok?)
    (compiler-parse-type-literal-state-interleaving-ok?)
    (compiler-parse-unsafe-decl-ok?)
    (compiler-parse-module-decl-ok?)
    (compiler-parse-import-metadata-ok?)
    (compiler-parse-dotted-import-metadata-ok?)
    (compiler-parse-module-macro-surface-ok?)
    (compiler-parse-defdispatch-tests-ok?)
    (compiler-parse-flat-let-call-body-ok?)
    (compiler-parse-implicit-body-tail-ok?)
    (compiler-parse-inline-test-ok?)
    (compiler-parse-try-ok?)))

(define (compiler-parse-error-suite-front-ok?) : bool
  (and
    (compiler-parse-error-tests-ok?)
    (compiler-parse-declaration-tests-ok?)
    (compiler-parse-let-tests-ok?)
    (compiler-parse-spmd-tests-ok?)
    (compiler-parse-pattern-tests-ok?)
    (compiler-parse-pattern-string-char-tests-ok?)))

(define (compiler-parse-error-suite-middle-ok?) : bool
  (and
    (compiler-parse-enum-struct-tests-ok?)
    (compiler-parse-operator-tests-ok?)
    (compiler-parse-type-literal-tests-ok?)
    (compiler-parse-region-tests-ok?)
    (compiler-parse-repl-tests-ok?)
    (compiler-parse-comptime-param-tests-ok?)))

(define (compiler-parse-error-suite-back-ok?) : bool
  (and
    (compiler-parse-defmacro-tests-ok?)
    (compiler-parse-resource-with-tests-ok?)
    (compiler-parse-with-escape-tests-ok?)
    (compiler-parse-with-scratch-tests-ok?)
    (compiler-parse-in-arena-tests-ok?)
    (compiler-parse-quote-syntax-tests-ok?)
    (compiler-parse-define-export-metadata-error-tests-ok?)
    (compiler-parse-dotted-import-errors-ok?)))

(define (compiler-parse-smoke-shapes [program : AstProgram]) : unit
  (begin
    (if (compiler-parse-shape-tests-front-ok? program)
      unit
      (io.panic "parse: compiler AST front shape tests failed"))
    (if (compiler-parse-shape-tests-middle-ok?)
      unit
      (io.panic "parse: compiler AST middle shape tests failed"))
    (if (compiler-parse-repr-c-ok?)
      unit
      (io.panic "parse: repr c shape test failed"))
    (if (compiler-parse-cleanup-metadata-ok?)
      unit
      (io.panic "parse: cleanup metadata shape test failed"))
    (if (compiler-parse-raw-pointer-ok?)
      unit
      (io.panic "parse: raw pointer shape test failed"))
    (if (compiler-parse-extern-metadata-ok?)
      unit
      (io.panic "parse: extern metadata shape test failed"))
    (if (compiler-parse-extern-varargs-metadata-rejected-ok?)
      unit
      (io.panic "parse: extern c-varargs metadata retirement test failed"))
    (if (compiler-parse-extern-function-head-varargs-ok?)
      unit
      (io.panic "parse: extern function-head varargs shape test failed"))
    (if (compiler-parse-define-export-symbol-ok?)
      unit
      (io.panic "parse: define export-symbol shape test failed"))
    (if (compiler-parse-raw-pointer-ops-ok?)
      unit
      (io.panic "parse: raw pointer ops shape test failed"))
    (if (compiler-parse-init-ok?)
      unit
      (io.panic "parse: init shape test failed"))
    (if (compiler-parse-contextual-init-ok?)
      unit
      (io.panic "parse: contextual init shape test failed"))
    (if (compiler-parse-init-call-name-ok?)
      unit
      (io.panic "parse: init call name compatibility test failed"))
    (if (compiler-parse-box-ok?)
      unit
      (io.panic "parse: box shape test failed"))
    (if (compiler-parse-reference-ok?)
      unit
      (io.panic "parse: reference shape test failed"))
    (if (compiler-parse-borrow-ok?)
      unit
      (io.panic "parse: borrow shape test failed"))
    (if (compiler-parse-resource-with-shape-ok?)
      unit
      (io.panic "parse: resource with shape test failed"))
    (if (compiler-parse-with-escape-shape-ok?)
      unit
      (io.panic "parse: with-escape shape test failed"))
    (if (compiler-parse-with-scratch-shape-ok?)
      unit
      (io.panic "parse: with-scratch shape test failed"))
    (if (compiler-parse-in-arena-shape-ok?)
      unit
      (io.panic "parse: in-arena shape test failed"))
    (if (compiler-parse-quote-syntax-shape-ok?)
      unit
      (io.panic "parse: quote syntax shape test failed"))
    unit))

(define (compiler-parse-smoke-errors) : unit
  (begin
    (if (compiler-parse-error-suite-front-ok?)
      unit
      (io.panic "parse: front error-path self-tests failed"))
    (if (compiler-parse-error-suite-middle-ok?)
      unit
      (io.panic "parse: middle error-path self-tests failed"))
    (if (compiler-parse-error-suite-back-ok?)
      unit
      (io.panic "parse: back error-path self-tests failed"))
    unit))

(define (compiler-parse-source-symbol-ids-preserved-ok?) : bool
  (let
    ;; Prime the fixed dispatch-name ids before measuring source parsing.
    [_dispatch : sym_i64_env.SymI64Env (parse-ast-program-dispatch)]
    (match (lexer.lex-spanned-result "(define (f [x : User]) : User x)")
      [(lexer.ResultSpannedTokens.Ok toks)
        (let
          [before : i64 (ci.intern-pool-len)]
          [parsed : ResultAstProgram (parse-ast-program toks)]
          (and
            (= before (ci.intern-pool-len))
            (match parsed
              [(ResultAstProgram.Ok _) true]
              [(ResultAstProgram.Err _) false])))]
      [(lexer.ResultSpannedTokens.Err _) false])))

(define (compiler-parse-spmd-callable-metadata-ok?) : bool
  (and
    (match (parse-ast-source
      "(define (helper [x : i64] [scale : i64])
  (:spmd-callable
    (specialization
      (result varying)
      (args varying uniform)
      (index-param 0)
      (lanes 8)))
  : i64
  (+ x scale))")
      [(ResultAstProgram.Ok (AstProgram.Program decls-box))
        (let
          [decls : AstDeclList (box-get decls-box)]
          (match (ast-decl-list-get (& decls) 0 (ast-decl-fallback))
            [(AstDecl.DefFn decl-meta _ _ _ _ metadata)
              (match (ast-fn-metadata-spmd-callable metadata)
                [(AstSpmdCallable.Callable specializations)
                  (let
                    [fallback : AstSpmdSpecialization
                      (AstSpmdSpecialization
                        2
                        (box (ast-spmd-param-class-list-new))
                        AstSpmdResultClass.Unit
                        -1)]
                    [specialization : AstSpmdSpecialization
                      (ast-spmd-specialization-list-get
                        (& specializations)
                        0
                        fallback)]
                    [args : AstSpmdParamClassList
                      (box-get (struct-get specialization args))]
                    (and
                      (=
                        (ast-spmd-specialization-list-len (& specializations))
                        1)
                      (= (struct-get specialization lanes) 8)
                      (= (struct-get specialization index-param) 0)
                      (match (struct-get specialization result)
                        [(AstSpmdResultClass.Varying) true]
                        [_ false])
                      (match (ast-spmd-param-class-list-get
                        (& args)
                        0
                        AstSpmdParamClass.Uniform)
                        [(AstSpmdParamClass.Varying) true]
                        [_ false])
                      (match (ast-spmd-param-class-list-get
                        (& args)
                        1
                        AstSpmdParamClass.Varying)
                        [(AstSpmdParamClass.Uniform) true]
                        [_ false])))]
                [_ false])]
            [_ false]))]
      [_ false])
    (compiler-parse-error-ok?
      "(define (f [x : i64]) (:spmd-callable (specialization (lanes 8) (args varying) (result varying) (index-param 0)) (specialization (lanes 8) (args varying) (result varying) (index-param 0))) : i64 x)"
      "parse: duplicate :spmd-callable specialization")
    (compiler-parse-error-ok?
      "(define (f [x : i64]) (:spmd-callable (specialization (lanes 8) (args uniform varying) (result varying) (index-param none))) : i64 x)"
      "parse: :spmd-callable args must contain one class per ordinary parameter")
    (compiler-parse-error-ok?
      "(define (f [comptime x : i64]) (:spmd-callable (specialization (lanes 8) (args uniform) (result uniform) (index-param none))) : i64 x)"
      "parse: define :spmd-callable cannot be used on functions with comptime parameters")
    (compiler-parse-error-ok?
      "(define (f [x : i64]) (:export-symbol \"f\") (:spmd-callable (specialization (lanes 8) (args varying) (result varying) (index-param 0))) : i64 x)"
      "parse: define :spmd-callable cannot be combined with :export-symbol")
    (compiler-parse-error-ok?
      "(define (f [x : i64]) (:spmd-callable (specialization (lanes 8) (args varying) (result varying) (bogus none) (index-param 0))) : i64 x)"
      "parse: unknown :spmd-callable specialization field bogus")
    (compiler-parse-error-ok?
      "(define (f [x : i64]) (:spmd-callable (specialization (lanes 1) (args varying) (result varying) (index-param 0))) : i64 x)"
      "parse: :spmd-callable lanes must be greater than one")
    (compiler-parse-error-ok?
      "(define (f [x : i64]) (:spmd-callable (specialization (lanes 8) (args varying) (result varying) (index-param 2))) : i64 x)"
      "parse: :spmd-callable index-param is outside the parameter list")
    (compiler-parse-error-ok?
      "(define (f [x : i64]) (:spmd-callable (specialization (lanes 8) (args dynamic) (result varying) (index-param none))) : i64 x)"
      "parse: :spmd-callable args expects only uniform or varying")
    (compiler-parse-error-ok?
      "(define (f [x : i64]) (:spmd-callable (specialization (args varying) (result varying) (index-param 0))) : i64 x)"
      "parse: :spmd-callable specialization is missing lanes")
    (compiler-parse-error-ok?
      "(define (f [x : i64]) (:spmd-callable (specialization (lanes 8) (lanes 16) (args varying) (result varying) (index-param 0))) : i64 x)"
      "parse: duplicate :spmd-callable lanes field")))

(define (compiler-parse-smoke) : i64
  (match (parse-ast-source (compiler-parse-smoke-source))
    [(ResultAstProgram.Ok program)
      (if (and
        (= (compiler-parse-smoke-score program) 36)
        (compiler-parse-nested-expr-span-ok?)
        (compiler-parse-error-span-ok?)
        (compiler-parse-reader-delimiter-diagnostics-ok?)
        (compiler-parse-float-literal-ok?)
        (compiler-parse-region-ok?)
        (compiler-parse-arena-ok?)
        (compiler-parse-unsafe-decl-ok?)
        (compiler-parse-module-decl-ok?)
        (compiler-parse-module-body-ok?)
        (compiler-parse-module-body-malformed-ok?)
        (compiler-parse-import-metadata-ok?)
        (compiler-parse-dotted-import-metadata-ok?)
        (compiler-parse-module-macro-surface-ok?)
        (compiler-parse-defdispatch-tests-ok?)
        (compiler-parse-flat-let-call-body-ok?)
        (compiler-parse-implicit-body-tail-ok?)
        (compiler-parse-inline-test-ok?)
        (compiler-parse-try-ok?)
        (compiler-parse-return-ok?)
        (compiler-parse-guard-forms-ok?)
        (compiler-parse-bracket-cond-call-ok?)
        (compiler-parse-and-or-macro-call-candidates-ok?)
        (compiler-parse-repr-c-ok?)
        (compiler-parse-cleanup-metadata-ok?)
        (compiler-parse-raw-pointer-ok?)
        (compiler-parse-extern-metadata-ok?)
        (compiler-parse-extern-varargs-metadata-rejected-ok?)
        (compiler-parse-extern-function-head-varargs-ok?)
        (compiler-parse-raw-pointer-ops-ok?)
        (compiler-parse-init-ok?)
        (compiler-parse-contextual-init-ok?)
        (compiler-parse-init-call-name-ok?)
        (reader.read-symbol-id-preservation-ok?)
        (compiler-parse-source-symbol-ids-preserved-ok?)
        (compiler-parse-box-ok?)
        (compiler-parse-reference-ok?)
        (compiler-parse-borrow-ok?)
        (compiler-parse-resource-with-shape-ok?)
        (compiler-parse-spmd-callable-metadata-ok?)
        (compiler-parse-quote-syntax-shape-ok?))
        (if (and
          (compiler-parse-error-tests-ok?)
          (compiler-parse-declaration-tests-ok?)
          (compiler-parse-let-tests-ok?)
          (compiler-parse-spmd-tests-ok?)
          (compiler-parse-pattern-tests-ok?)
          (compiler-parse-pattern-string-char-tests-ok?)
          (compiler-parse-enum-struct-tests-ok?)
          (compiler-parse-operator-tests-ok?)
          (compiler-parse-type-literal-tests-ok?)
          (compiler-parse-region-tests-ok?)
          (compiler-parse-repl-tests-ok?)
          (compiler-parse-comptime-param-tests-ok?)
          (compiler-parse-defmacro-tests-ok?)
          (compiler-parse-resource-with-tests-ok?)
          (compiler-parse-quote-syntax-tests-ok?)
          (compiler-parse-dotted-import-errors-ok?)
          (compiler-parse-cfg-tests-ok?))
          42
          (io.panic "parse: error-path self-tests failed"))
        (io.panic "parse: compiler AST smoke score mismatch"))]
    [(ResultAstProgram.Err message) (io.panic message)]))