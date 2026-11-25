;; Stage 1/3 shared TLI producer. The checked context and its process-local IDs stay here.
(import compiler_abi as abi)
(import compiler_tli_types as tli)
(import compiler_tli_codec as codec)
(import compiler_tli_hydrate as hydrate)
(import compiler_ast_types as ast)
(import compiler_backend as backend)
(import compiler_backend_operands as be_operand)
(import compiler_backend_state as be_state)
(import compiler_load as load)
(import compiler_optimize as opt)
(import compiler_parse_core as parser)
(import compiler_profile_state as profile_state)
(import compiler_specialize as spec)
(import compiler_symbols as symbols)
(import compiler_typecheck_api as api)
(import compiler_typecheck_core as tc)
(import compiler_global_effects as effects)
(import compiler_intern as intern)
(import compiler_diagnostic as diag)
(import compiler_lower as lower)
(import compiler_ir_types as ir)
(import sym_i64_env)
(import stdlib.math)
(import stdlib.byte_buf)
(import stdlib.byte_buf_core as buf)
(import stdlib.crypto_sha256 as sha)
(import stdlib.fs)
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as i64_map)
(import (hashmap.hashmap String i64) as str_map)
(import stdlib.iterator)
(import stdlib.io)
(import stdlib.sort)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.string)
(import stdlib.text_buf)
(import stdlib.vector)
(import (vector.vector String) as strings)
(import (vector.vector tli.TliImport core) as imports)
(import (vector.vector tli.TliTypeDecl core) as types)
(import (vector.vector tli.TliFnDecl core) as functions)
(import (vector.vector tli.TliValueDecl core) as values)
(import (vector.vector tli.TliMacroHandle core) as macros)
(import (vector.vector tli.TliDispatchDecl core) as dispatches)
(import (vector.vector tli.TliGlobalWrite core) as writes)
(import (vector.vector i64) as indices)
(cfg embedded-stdlib-tlci (import compiler_embedded_stdlib_tlci as tlci))

(defstruct TliPackageCompanionBinding
  (has-companion bool)
  (tlci-sha256 (Array u8 32))
  (macro-identities (__tl_dyn-array String)))

(define (tli-package-companion-binding-empty) : TliPackageCompanionBinding
  (TliPackageCompanionBinding
    false
    (make-array u8 32)
    (__tl_make-array String 0)))

(defstruct TliPartitionedEmitResult
  (asm-files (__tl_dyn-array String))
  (emitted-modules i64)
  (skipped-modules i64))

(defenum ResultTliPartitionedEmit
  (Ok TliPartitionedEmitResult)
  (Err String))

(defstruct TliSource
  (module-name String)
  (path String)
  (digest (Array u8 32)))

(import (vector.vector TliSource core) as source_rows)

(defstruct TliExtractModule
  (flags i64)
  (imports imports.Vec)
  (types types.Vec)
  (functions functions.Vec)
  (values values.Vec)
  (macros macros.Vec)
  (dispatches dispatches.Vec))

(defenum TliExtractResult
  (Ok tli.TliBundle)
  (Err String))

(define (tli-extract-sha256 [source : (& source bytes)]) : (Array u8 32)
  (match (sha.digest source)
    [(Sha256FinalizeOk digest) (sha.digest-bytes (& digest))]
    [(Sha256FinalizeErr _) (io.panic "TLI source exceeds SHA-256 input limit")]))

(define (tli-extract-cfg-digest [cfgs : sym_i64_env.SymI64Env]) : (Array u8 32)
  (hydrate.tli-hydrate-cfg-digest cfgs))

(define (tli-extract-name [id : i64]) : String
  (string.copy (ast.ast-nominal-name-id-display id)))

(define (tli-extract-lifetimes [items : (& ast.AstLifetimeList)]) : (__tl_dyn-array
    String)
  (let
    [out : (__tl_dyn-array String) (__tl_make-array String items.len)]
    (for [index (iterator.range 0 items.len)]
      (set!
        (array-ref out index)
        (tli-extract-name (array-ref items.slots index))))
    out))

(define (tli-extract-nominal-name
  [sources : (& sources (__tl_dyn-array TliSource))]
  [root-type-slots : (& root-type-slots str_map.Map)]
  [id : i64]) : String
  (let
    [raw : String (tli-extract-name id)]
    (if (string.contains (& raw) "/")
      raw
      (let
        [slot : i64
          (str_map.get-value-or root-type-slots (string.copy (& raw)) -1)]
        (if (and (>= slot 0) (< slot (array-length sources)))
          (symbols.compiler-symbol-module-key
            (string.copy (& (array-ref sources slot).module-name))
            raw)
          raw)))))

(define (tli-extract-types-in
  [ctx : tc.TcContext]
  [sources : (& sources (__tl_dyn-array TliSource))]
  [root-type-slots : (& root-type-slots str_map.Map)]
  [items : (& ast.AstTypeList)]) : (__tl_dyn-array tli.TliType)
  (let
    [out : (__tl_dyn-array tli.TliType) (__tl_make-array tli.TliType items.len)]
    (for [index (iterator.range 0 items.len)]
      (set!
        (array-ref out index)
        (tli-extract-child-in
          ctx
          sources
          root-type-slots
          (array-ref items.slots index))))
    out))

(define (tli-extract-child-in
  [ctx : tc.TcContext]
  [sources : (& sources (__tl_dyn-array TliSource))]
  [root-type-slots : (& root-type-slots str_map.Map)]
  [id : i64]) : tli.TliType
  (tli-extract-type-in
    ctx
    sources
    root-type-slots
    (tc.tc-context-type-get ctx id)))

(define (tli-extract-type-in
  [ctx : tc.TcContext]
  [sources : (& sources (__tl_dyn-array TliSource))]
  [root-type-slots : (& root-type-slots str_map.Map)]
  [ty : ast.AstType]) : tli.TliType
  (match (tc.tc-resolve-type ctx ty)
    [(I64) (tli.TliType.I64)]
    [(I32) (tli.TliType.I32)]
    [(I16) (tli.TliType.I16)]
    [(I8) (tli.TliType.I8)]
    [(U64) (tli.TliType.U64)]
    [(U32) (tli.TliType.U32)]
    [(U16) (tli.TliType.U16)]
    [(U8) (tli.TliType.U8)]
    [(F64) (tli.TliType.F64)]
    [(F32) (tli.TliType.F32)]
    [(Bool) (tli.TliType.Bool)]
    [(Char) (tli.TliType.Char)]
    [(String) (tli.TliType.String)]
    [(Str) (tli.TliType.Str)]
    [(Bytes) (tli.TliType.Bytes)]
    [(Unit) (tli.TliType.Unit)]
    [(Never) (tli.TliType.Never)]
    [(Expr) (tli.TliType.Expr)]
    [(ExprList) (tli.TliType.ExprList)]
    [(DynArray elem)
      (tli.TliType.DynArray
        (box (tli-extract-child-in ctx sources root-type-slots elem)))]
    [(Box elem)
      (tli.TliType.Box
        (box (tli-extract-child-in ctx sources root-type-slots elem)))]
    [(Ptr elem)
      (tli.TliType.Ptr
        (box (tli-extract-child-in ctx sources root-type-slots elem)))]
    [(MutPtr elem)
      (tli.TliType.MutPtr
        (box (tli-extract-child-in ctx sources root-type-slots elem)))]
    [(Slice elem)
      (tli.TliType.Slice
        (box (tli-extract-child-in ctx sources root-type-slots elem)))]
    [(Region life inner)
      (tli.TliType.Region
        (tli-extract-name life)
        (box (tli-extract-child-in ctx sources root-type-slots inner)))]
    [(Ref life inner)
      (tli.TliType.Ref
        (tli-extract-name life)
        (box (tli-extract-child-in ctx sources root-type-slots inner)))]
    [(MutRef life inner)
      (tli.TliType.MutRef
        (tli-extract-name life)
        (box (tli-extract-child-in ctx sources root-type-slots inner)))]
    [(Invalidate life inner)
      (tli.TliType.Invalidate
        (tli-extract-name life)
        (box (tli-extract-child-in ctx sources root-type-slots inner)))]
    [(Enum nominal)
      (tli.TliType.Enum
        (tli-extract-nominal-name sources root-type-slots nominal))]
    [(EnumArgs nominal lives)
      (tli.TliType.EnumArgs
        (tli-extract-nominal-name sources root-type-slots nominal)
        (tli-extract-lifetimes (& (__tl-box-place lives))))]
    [(Struct nominal)
      (tli.TliType.Struct
        (tli-extract-nominal-name sources root-type-slots nominal))]
    [(StructArgs nominal lives)
      (tli.TliType.StructArgs
        (tli-extract-nominal-name sources root-type-slots nominal)
        (tli-extract-lifetimes (& (__tl-box-place lives))))]
    [(Var nominal)
      (tli.TliType.Var
        (tli-extract-nominal-name sources root-type-slots nominal))]
    [(VarArgs nominal lives)
      (tli.TliType.VarArgs
        (tli-extract-nominal-name sources root-type-slots nominal)
        (tli-extract-lifetimes (& (__tl-box-place lives))))]
    [(Func params ret)
      (tli.TliType.Func
        (tli-extract-types-in
          ctx
          sources
          root-type-slots
          (& (__tl-box-place params)))
        (box (tli-extract-child-in ctx sources root-type-slots ret)))]
    [(Tuple items)
      (tli.TliType.Tuple
        (tli-extract-types-in
          ctx
          sources
          root-type-slots
          (& (__tl-box-place items))))]
    [(Array elem count)
      (tli.TliType.Array
        (box (tli-extract-child-in ctx sources root-type-slots elem))
        count)]
    [(CFunc signature mode)
      (tli.TliType.CFunc
        (box (tli-extract-child-in ctx sources root-type-slots signature))
        (ast.ast-c-function-mode-key mode))]))

(define (tli-extract-type [ctx : tc.TcContext] [ty : ast.AstType]) : tli.TliType
  (let
    [empty-sources : (__tl_dyn-array TliSource) (__tl_make-array TliSource 0)]
    [empty-roots : str_map.Map (str_map.with-capacity 4)]
    (tli-extract-type-in ctx (& empty-sources) (& empty-roots) ty)))

(define (tli-extract-cleanup-symbol
  [ctx : tc.TcContext]
  [name : intern.InternSyntaxId]) : tli.TliCleanup
  (let
    [raw : i64 (intern.intern-syntax-id-value name)]
    [resolved : i64
      (if (tc.tc-source-slash-qualified-id?
        (tc.tc-context-structural-session ctx)
        (tli-extract-name raw)
        raw)
        (tc.tc-cleanup-source-slash-alias-helper-name ctx raw)
        raw)]
    [handle : i64
      (tc.tc-move-qualified-value-symbol-handle-id
        ctx
        resolved
        (tc.tc-global-effect-handle ctx tc.TcNameIdList.Nil resolved))]
    [kind : i64 (symbols.compiler-symbol-handle-kind handle)]
    [index : i64 (symbols.compiler-symbol-handle-index handle)]
    (tli.TliCleanup.Fn
      (cond
        [(or
            (= kind (symbols.compiler-symbol-kind-function-define))
            (= kind (symbols.compiler-symbol-kind-extern)))
          (tli-extract-symbol-at ctx index)]
        [(or
            (= kind (symbols.compiler-symbol-kind-struct-cleanup))
            (= kind (symbols.compiler-symbol-kind-enum-cleanup)))
          (match (symbols.compiler-symbols-decl-at-index
            (tc.tc-context-symbols (& ctx))
            index)
            [(Ok decl)
              (match (ast.ast-decl-unwrapped (& decl))
                [(or (DefStruct _ _ _ (Fn cleanup) _)
                     (DefStructLifetimes _ _ _ _ (Fn cleanup) _)
                     (DefEnum _ _ (Fn cleanup) _)
                     (DefEnumLifetimes _ _ _ (Fn cleanup) _))
                  (tc.macro-tlci-catalog-identity
                    (tli-extract-module-name (tli-extract-owner ctx index))
                    (tli-extract-name (intern.intern-syntax-id-value cleanup)))]
                [_ (io.panic "TLI expected a cleanup declaration")])]
            [(Err message) (io.panic message)])]
        [else
          (tc.macro-tlci-catalog-identity
            (string.copy (tc.tc-context-module ctx))
            (tli-extract-name resolved))]))))

(define (tli-extract-fields
  [ctx : tc.TcContext]
  [sources : (& sources (__tl_dyn-array TliSource))]
  [root-type-slots : (& root-type-slots str_map.Map)]
  [items : (& ast.AstFieldDefList)]
  [offsets : (& tc.TcInlineFieldLayoutList)]
  [aligns : (& ast.AstFieldAligns)]) : tli.TliTypeBody
  (let
    [out : (__tl_dyn-array tli.TliField)
      (__tl_make-array tli.TliField items.len)]
    (for [index (iterator.range 0 items.len)]
      (match (ast.ast-field-def-list-get
        items
        index
        (ast.ast-field-def-fallback))
        [(Def name ty cleanup)
          (let
            [offset : i64
              (if (< index (array-length offsets.slots))
                (match (& (array-ref offsets.slots index))
                  [(Field _ _ n) n])
                0)]
            [alignment : i64
              (if (< index (array-length aligns.slots))
                (array-ref aligns.slots index)
                0)]
            (set!
              (array-ref out index)
              (tli.TliField
                (intern.intern-syntax-id-text name)
                (tli-extract-type-in ctx sources root-type-slots ty)
                (match cleanup
                  [(Fn fn-name) (tli-extract-cleanup-symbol ctx fn-name)]
                  [(Owned) (tli.TliCleanup.Owned)]
                  [(No) (tli.TliCleanup.No)])
                offset
                alignment)))]))
    (tli.TliTypeBody.Struct out)))

(define (tli-extract-variants
  [ctx : tc.TcContext]
  [sources : (& sources (__tl_dyn-array TliSource))]
  [root-type-slots : (& root-type-slots str_map.Map)]
  [items : (& ast.AstVariantDefList)]) : tli.TliTypeBody
  (let
    [out : (__tl_dyn-array tli.TliVariant)
      (__tl_make-array tli.TliVariant items.len)]
    (for [index (iterator.range 0 items.len)]
      (match (& (array-ref items.slots index))
        [(Def name items cleanups)
          (let
            [payloads : (__tl_dyn-array tli.TliPayload)
              (__tl_make-array tli.TliPayload items.len)]
            (for [slot (iterator.range 0 items.len)]
              (set!
                (array-ref payloads slot)
                (tli.TliPayload
                  (tli-extract-child-in
                    ctx
                    sources
                    root-type-slots
                    (array-ref items.slots slot))
                  (if (< slot cleanups.len)
                    (match (& (array-ref cleanups.slots slot))
                      [(Fn fn-name) (tli-extract-cleanup-symbol ctx fn-name)]
                      [(Owned) (tli.TliCleanup.Owned)]
                      [(No) (tli.TliCleanup.No)])
                    (tli.TliCleanup.No)))))
            (set!
              (array-ref out index)
              (tli.TliVariant (tli-extract-name name) payloads)))]))
    (tli.TliTypeBody.Enum out)))

(define (tli-extract-flag [enabled : bool] [flag : i64]) : i64
  (if enabled
    flag
    0))

(define (tli-extract-owner [ctx : tc.TcContext] [index : i64]) : i64
  (symbols.compiler-symbols-owner-module-id-at-index-or
    (tc.tc-context-symbols (& ctx))
    index
    (symbols.compiler-symbol-root-module-id)))

(define (tli-extract-module-name [id : i64]) : String
  (if (symbols.compiler-symbol-root-module-id? id)
    ""
    (tli-extract-name id)))

(define (tli-extract-symbol-at [ctx : tc.TcContext] [index : i64]) : String
  (symbols.compiler-symbol-module-key
    (tli-extract-module-name (tli-extract-owner ctx index))
    (tli-extract-name
      (symbols.compiler-symbols-decl-name-id-at-index
        (tc.tc-context-symbols (& ctx))
        index))))

(define (tli-extract-type-row
  [module-name : String]
  [name : i64]
  [flags : i64]
  [lifetimes : (& ast.AstLifetimeList)]
  [cleanup : tli.TliCleanup]
  [size : i64]
  [align : i64]
  [repr-kind : i64]
  [repr-align : i64]
  [body : tli.TliTypeBody]) : tli.TliTypeDecl
  (tli.TliTypeDecl
    (tli-extract-name name)
    module-name
    (+
      flags
      (match (& cleanup)
        [(No) 0]
        [_ 16]))
    size
    align
    repr-kind
    repr-align
    cleanup
    (tli-extract-lifetimes lifetimes)
    body))

(define (tli-extract-struct!
  [out : (&mut types.Vec)]
  [ctx : tc.TcContext]
  [sources : (& sources (__tl_dyn-array TliSource))]
  [root-type-slots : (& root-type-slots str_map.Map)]
  [module-name : String]
  [name : i64]
  [flags : i64]
  [lifetimes : (& ast.AstLifetimeList)]
  [repr : (& ast.AstStructRepr)]
  [cleanup : ast.AstStructCleanup]
  [fields : (& ast.AstFieldDefList)]) : unit
  (let
    [id : i64
      (ast.ast-nominal-name-id-key
        (symbols.compiler-symbol-module-key-id-by-id
          (tc.tc-context-module-id ctx)
          name))]
    [layout : tc.TcInlineAggregateLayout
      (match (tc.tc-inline-aggregate-layout-for-id ctx id)
        [(Ok info) info]
        [(Err message)
          (if (!= (bit-and flags 4) 0)
            (tc.TcInlineAggregateLayout.Struct
              0
              0
              (tc.TcInlineFieldLayoutList
                (__tl_make-array tc.TcInlineFieldLayout 0)))
            (io.panic message))])]
    (match (& layout)
      [(Struct size alignment offsets)
        (let
          [cleanup-row : tli.TliCleanup
            (match cleanup
              [(No) (tli.TliCleanup.No)]
              [(Fn fn-name)
                (tli.TliCleanup.Fn
                  (tc.macro-tlci-catalog-identity
                    (string.copy (& module-name))
                    (tli-extract-name (intern.intern-syntax-id-value fn-name))))])]
          (match repr
            [(Default)
              (types.push-ref!
                out
                (tli-extract-type-row
                  module-name
                  name
                  flags
                  lifetimes
                  cleanup-row
                  size
                  alignment
                  0
                  0
                  (tli-extract-fields
                    ctx
                    sources
                    root-type-slots
                    fields
                    offsets
                    (& (ast.AstFieldAligns (__tl_make-array i64 0))))))]
            [(C align fields-align)
              (types.push-ref!
                out
                (tli-extract-type-row
                  module-name
                  name
                  flags
                  lifetimes
                  cleanup-row
                  size
                  alignment
                  1
                  align
                  (tli-extract-fields
                    ctx
                    sources
                    root-type-slots
                    fields
                    offsets
                    fields-align)))]))]
      [_ (io.panic "TLI expected a checked struct layout")])))

(define (tli-extract-enum!
  [out : (&mut types.Vec)]
  [ctx : tc.TcContext]
  [sources : (& sources (__tl_dyn-array TliSource))]
  [root-type-slots : (& root-type-slots str_map.Map)]
  [module-name : String]
  [name : i64]
  [flags : i64]
  [lifetimes : (& ast.AstLifetimeList)]
  [cleanup : ast.AstEnumCleanup]
  [variants : (& ast.AstVariantDefList)]) : unit
  (let
    [id : i64
      (ast.ast-nominal-name-id-key
        (symbols.compiler-symbol-module-key-id-by-id
          (tc.tc-context-module-id ctx)
          name))]
    [layout : tc.TcInlineAggregateLayout
      (match (tc.tc-inline-aggregate-layout-for-id ctx id)
        [(Ok info) info]
        [(Err message)
          (if (!= (bit-and flags 4) 0)
            (tc.TcInlineAggregateLayout.Enum
              0
              0
              (tc.TcInlineVariantLayoutList
                (__tl_make-array tc.TcInlineVariantLayout 0)))
            (io.panic message))])]
    (match layout
      [(Enum size alignment _)
        (let
          [cleanup-row : tli.TliCleanup
            (match cleanup
              [(No) (tli.TliCleanup.No)]
              [(Fn fn-name)
                (tli.TliCleanup.Fn
                  (tc.macro-tlci-catalog-identity
                    (string.copy (& module-name))
                    (tli-extract-name (intern.intern-syntax-id-value fn-name))))])]
          (types.push-ref!
            out
            (tli-extract-type-row
              module-name
              name
              flags
              lifetimes
              cleanup-row
              size
              alignment
              0
              0
              (tli-extract-variants ctx sources root-type-slots variants))))]
      [_ (io.panic "TLI expected a checked enum layout")])))

(defstruct TliExtractEffects
  (globals (__tl_dyn-array writes.Vec))
  (indirect (__tl_dyn-array i64))
  (global-arena (__tl_dyn-array i64))
  (param-arena (__tl_dyn-array i64))
  (impure (__tl_dyn-array i64))
  (arena-graph effects.Graph))

;; A declaration is impure on its own when comptime code may not run it: it is
;; unsafe or extern, or its body fails the comptime-purity walk.
(define (tli-extract-locally-impure?
  [ctx : tc.TcContext]
  [env : tc.TcTypeEnv]
  [index : i64]) : bool
  (match (symbols.compiler-symbols-decl-at-index
    (tc.tc-context-symbols (& ctx))
    index)
    [(Ok decl)
      (match decl
        [(or (Unsafe _) (Extern _ _ _ _ _)) true]
        [(or (Def _ _ _ _) (DefFn _ _ _ _ _ _))
          (not
            (tc.tc-comptime-pure-decl?
              (tc.tc-context-with-nominal-owner-index-module ctx index)
              env
              decl))]
        [_ false])]
    [(Err _) true]))

(define (tli-extract-effects [ctx : tc.TcContext] [env : tc.TcTypeEnv]) : TliExtractEffects
  (let
    [state : (MutPtr tc.TcGlobalCallEffects)
      (tc.tc-global-call-effects-ensure! ctx)]
    [count : i64
      (symbols.compiler-symbols-decl-count (tc.tc-context-symbols (& ctx)))]
    (for [index (iterator.range 0 count)]
      (tc.tc-global-call-effects-collect! ctx state index false)
      (tc.tc-global-call-effects-collect! ctx state index true))
    (let
      [graph : effects.Graph
        (unsafe
          (deref state).graph)]
      [arena-graph : effects.Graph
        (unsafe
          (deref state).arena-graph)]
      [global-writes : (__tl_dyn-array writes.Vec)
        (__tl_make-array writes.Vec count)]
      (for [index (iterator.range 0 count)]
        (set! (array-ref global-writes index) (writes.new)))
      (for [index (iterator.range 0 count)]
        (when
          (effects.written? (& graph) index)
          (let
            [symbol : String (tli-extract-symbol-at ctx index)]
            [summary : (__tl_dyn-array i64)
              (effects.summary! (&mut graph) index)]
            (for [node (iterator.range 0 count)]
              (let
                [witness : i64 (array-ref summary node)]
                (when
                  (!= witness 0)
                  (writes.push-ref!
                    (&mut (array-ref global-writes node))
                    (tli.TliGlobalWrite
                      (string.copy (& symbol))
                      (cast
                        (if (= witness -1)
                          1
                          2)
                        : u8)))))))))
      ;; Put a witness on the indirect union itself so callers are detected
      ;; even when the union has no global writer.
      (effects.add-write! (&mut graph) count count)
      ;; Every locally impure declaration writes one synthetic key, so its
      ;; summary marks each function that can reach impure code.
      (for [index (iterator.range 0 count)]
        (when
          (tli-extract-locally-impure? ctx env index)
          (effects.add-write! (&mut graph) index (+ count 1))))
      (TliExtractEffects
        global-writes
        (effects.summary! (&mut graph) count)
        (effects.summary!
          (&mut arena-graph)
          (tc.tc-arena-store-global-key count))
        (effects.summary!
          (&mut arena-graph)
          (tc.tc-arena-store-argument-key count))
        (effects.summary! (&mut graph) (+ count 1))
        arena-graph))))

(define (tli-extract-summary
  [facts : (& facts TliExtractEffects)]
  [index : i64]
  [params : i64]
  [ret : (& ast.AstType)]
  [comptime-only : bool]
  [unsafe-decl : bool]
  [must-use : bool]) : tli.TliFnSummary
  (let
    [mask : i64 0]
    [extra : indices.Vec (indices.new)]
    (for [param (iterator.range 0 params)]
      (when
        (effects.direct-writer?
          (& facts.arena-graph)
          index
          (tc.tc-arena-store-parameter-key facts.arena-graph.indirect param))
        (if (< param 64)
          (set! mask (bit-or mask (shl 1 param)))
          (indices.push-ref! (&mut extra) param))))
    (tli.TliFnSummary
      (+
        (tli-extract-flag unsafe-decl 1)
        (tli-extract-flag comptime-only 2)
        ;; PURE: a checked comptime declaration, or a runtime function that
        ;; returns, writes no global, makes no indirect call and reaches no
        ;; unsafe, extern or walk-rejected declaration.
        (tli-extract-flag
          (and
            (not unsafe-decl)
            (or
              comptime-only
              (and
                (= (array-ref facts.impure index) 0)
                (= (array-ref facts.indirect index) 0)
                (= (writes.len (& (array-ref facts.globals index))) 0)
                (match ret
                  [(Never) false]
                  [_ true]))))
          4)
        (tli-extract-flag
          (match ret
            [(Never) true]
            [_ false])
          8)
        (tli-extract-flag (!= (array-ref facts.global-arena index) 0) 16)
        (tli-extract-flag
          (!= (array-ref facts.indirect index) 0)
          tli.tli-fn-has-indirect-effects)
        (tli-extract-flag must-use 128)
        (tli-extract-flag
          (!= (array-ref facts.param-arena index) 0)
          tli.tli-fn-stores-ambient-arena-arg))
      mask
      (tli-extract-finish-vector i64 extra)
      (tli-extract-copy-writes (& (array-ref facts.globals index)))
      0
      0)))

(define (tli-extract-params
  [ctx : tc.TcContext]
  [sources : (& sources (__tl_dyn-array TliSource))]
  [root-type-slots : (& root-type-slots str_map.Map)]
  [params : (& ast.AstParamList)]) : (__tl_dyn-array tli.TliParam)
  (let
    [out : (__tl_dyn-array tli.TliParam)
      (__tl_make-array tli.TliParam params.len)]
    (for [index (iterator.range 0 params.len)]
      (match (ast.ast-param-list-get params index (ast.ast-param-fallback))
        [(Param name ty mut?)
          (set!
            (array-ref out index)
            (tli.TliParam
              (tli-extract-name name)
              (tli-extract-type-in ctx sources root-type-slots ty)
              mut?))]))
    out))

;; Extern ASTs retain parameter types only. The final anonymous parameter
;; carries the homogeneous tail type when the ABI tag is CVarargsTyped.
(define (tli-extract-extern-params
  [ctx : tc.TcContext]
  [sources : (& sources (__tl_dyn-array TliSource))]
  [root-type-slots : (& root-type-slots str_map.Map)]
  [params : (& ast.AstTypeList)]
  [abi : ast.AstExternAbi]) : (__tl_dyn-array tli.TliParam)
  (let
    [typed-tail : bool
      (match (& abi)
        [(CVarargsTyped _) true]
        [_ false])]
    [out : (__tl_dyn-array tli.TliParam)
      (__tl_make-array
        tli.TliParam
        (+ params.len (tli-extract-flag typed-tail 1)))]
    (for [index (iterator.range 0 params.len)]
      (set!
        (array-ref out index)
        (tli.TliParam
          ""
          (tli-extract-child-in
            ctx
            sources
            root-type-slots
            (array-ref params.slots index))
          false)))
    (match abi
      [(CVarargsTyped tail)
        (set!
          (array-ref out params.len)
          (tli.TliParam
            ""
            (tli-extract-type-in ctx sources root-type-slots tail)
            false))]
      [_ unit])
    out))

(define (tli-extract-link-inputs [items : (& ast.AstExternLinkInputList)]) : (__tl_dyn-array
    tli.TliExternLinkInput)
  (let
    [out : (__tl_dyn-array tli.TliExternLinkInput)
      (__tl_make-array tli.TliExternLinkInput items.len)]
    (for [index (iterator.range 0 items.len)]
      (set!
        (array-ref out index)
        (match (& (array-ref items.slots index))
          [(Lib name) (tli.TliExternLinkInput 0 (string.copy name))]
          [(Search name) (tli.TliExternLinkInput 1 (string.copy name))]
          [(Arg name) (tli.TliExternLinkInput 2 (string.copy name))])))
    out))

(define (tli-extract-bytes [text : (& str)]) : tli.TliConst
  (tli.TliConst.Bytes
    (byte_buf.to-array (byte_buf.from-bytes (byte_buf.str-as-bytes text)))))

(define (tli-extract-const [value : (& ir.CompilerIrValue)] [ty : ast.AstType]) : tli.TliConst
  (match value
    [(I64 n)
      (match (tc.tc-type-strip-region ty)
        [(U64) (tli.TliConst.U64 n)]
        [(U32) (tli.TliConst.U64 (cast (cast n : u32) : i64))]
        [(U16) (tli.TliConst.U64 (cast (cast n : u16) : i64))]
        [(U8) (tli.TliConst.U64 (cast (cast n : u8) : i64))]
        [(I32) (tli.TliConst.I64 (cast (cast n : i32) : i64))]
        [(I16) (tli.TliConst.I64 (cast (cast n : i16) : i64))]
        [(I8) (tli.TliConst.I64 (cast (cast n : i8) : i64))]
        [_ (tli.TliConst.I64 n)])]
    [(Char c) (tli.TliConst.U64 (cast c : i64))]
    [(F64 bits)
      (tli.TliConst.F64Bits
        (match (tc.tc-type-strip-region ty)
          [(F32)
            (cast
              (math.f64-to-bits
                (cast (math.f32-from-bits (cast bits : u32)) : f64))
              : i64)]
          [_ (cast bits : i64)]))]
    [(Bool value) (tli.TliConst.Bool value)]
    [(String value) (tli.TliConst.String (string.copy value))]
    [(or (Bytes value) (StaticArray value)) (tli-extract-bytes value)]
    [_ (tli.TliConst.None)]))

(define (tli-extract-macro-params
  [ctx : tc.TcContext]
  [sources : (& sources (__tl_dyn-array TliSource))]
  [root-type-slots : (& root-type-slots str_map.Map)]
  [items : (& ast.AstMacroParamList)]) : (__tl_dyn-array tli.TliMacroParam)
  (let
    [out : (__tl_dyn-array tli.TliMacroParam)
      (__tl_make-array tli.TliMacroParam items.len)]
    (for [index (iterator.range 0 items.len)]
      (match (ast.ast-macro-param-list-get
        items
        index
        (ast.ast-macro-param-fallback))
        [(Param name ty by-ref kinds)
          (let
            [tags : (__tl_dyn-array u8) (__tl_make-array u8 kinds.len)]
            (for [kind (iterator.range 0 kinds.len)]
              (set!
                (array-ref tags kind)
                (tli.tli-macro-type-kind-tag
                  (& (intern.intern-str (array-ref kinds.slots kind))))))
            (set!
              (array-ref out index)
              (tli.TliMacroParam
                (tli-extract-name name)
                (tli-extract-type-in ctx sources root-type-slots ty)
                by-ref
                tags)))]))
    out))

(cfg
  embedded-stdlib-tlci
  (define (tli-extract-native-catalog-digest [generation : i64]) : (Array u8 32)
    (with-arena
      digest-scratch
      (let
        [frame : i64
          (tlci.compiler-embedded-stdlib-tlci-session-index generation)]
        [bytes : (__tl_dyn-array u8)
          (unsafe
            ;; The decoder caches in its own arena. Only the temporary
            ;; uncompressed frame bytes stay in digest-scratch.
            (tlci.compiler-embedded-stdlib-tlci-decode-frame frame true))]
        (when
          (= (array-length (& bytes)) 0)
          (io.panic "TLI native macro catalog is unavailable"))
        (codec.tli-module-digest (& bytes) 0 (array-length (& bytes)))))))

(define (tli-extract-companion-macro-index
  [companion : (& TliPackageCompanionBinding)]
  [identity : (& str)]) : i64
  (when (not companion.has-companion) (return -1))
  (for [i (iterator.range 0 (array-length companion.macro-identities))]
    (when
      (string.eq (& (array-ref companion.macro-identities i)) identity)
      (return i)))
  -1)

(define (tli-extract-macro
  [ctx : tc.TcContext]
  [sources : (& sources (__tl_dyn-array TliSource))]
  [root-type-slots : (& root-type-slots str_map.Map)]
  [companion : (& TliPackageCompanionBinding)]
  [is-stdlib : bool]
  [module-name : String]
  [name : String]
  [params : (& ast.AstMacroParamList)]
  [ret : ast.AstType]
  [body-box : i64]) : tli.TliMacroHandle
  (let
    [identity : String
      (tc.macro-tlci-catalog-identity
        (string.copy (& module-name))
        (string.copy (& name)))]
    [result-kind : u8
      (cast
        (cond
          [(tc.tc-macro-result-module? (& ret)) 2]
          [(tc.tc-macro-result-decls? (& ret)) 1]
          [else 0])
        : u8)]
    [uses-expr-type? : bool
      (tc.macro-expr-uses-expr-type?
        (tc.tc-context-expr-bases ctx)
        (tc.tc-context-expr-get ctx body-box))]
    [flags : i64
      (+
        4
        (tli-extract-flag (!= result-kind (cast 0 : u8)) 8)
        (tli-extract-flag uses-expr-type? tli.tli-macro-uses-expr-type))]
    [index : i64 -1]
    [digest : (Array u8 32) (make-array u8 32)]
    (if is-stdlib
      (cfg
        embedded-stdlib-tlci
        (match (tlci.compiler-embedded-stdlib-tlci-catalog-lookup
          (string.copy (& identity)))
          [(Resolved entry)
            (set! index entry.entry-index)
            (set!
              digest
              (tli-extract-native-catalog-digest entry.catalog-generation))
            (+= flags 1)]
          [(Shell entry)
            (set!
              digest
              (tli-extract-native-catalog-digest entry.catalog-generation))
            (+= flags 2)]
          [_ unit]))
      (let
        [companion-index : i64
          (tli-extract-companion-macro-index companion (& identity))]
        (when
          (>= companion-index 0)
          (set! index companion-index)
          (set! digest companion.tlci-sha256)
          (+= flags 1))))
    (tli.TliMacroHandle
      name
      module-name
      identity
      flags
      result-kind
      (tli-extract-macro-params ctx sources root-type-slots params)
      index
      digest)))

(define (tli-extract-package-link-symbol
  [decl-path : (& str)]
  [raw-module-name : (& str)]
  [spelling : (& str)]) : String
  (let
    [logical : String
      (if (= (string.string-length raw-module-name) 0)
        (if (> (string.string-length decl-path) 0)
          (str_cat.str-cat (string.copy decl-path) "::" (string.copy spelling))
          (string.copy spelling))
        (if (> (string.string-length decl-path) 0)
          (str_cat.str-cat
            (string.copy decl-path)
            "::"
            (string.copy raw-module-name)
            "/"
            (string.copy spelling))
          (symbols.compiler-symbol-module-key
            (string.copy raw-module-name)
            (string.copy spelling))))]
    (hydrate.tli-hydrate-archive-user-symbol (& logical))))

(define (tli-extract-value!
  [out : (&mut TliExtractModule)]
  [ctx : tc.TcContext]
  [env : tc.TcTypeEnv]
  [sources : (& sources (__tl_dyn-array TliSource))]
  [root-type-slots : (& root-type-slots str_map.Map)]
  [names : lower.LowerNameCache]
  [decl : (& ast.AstDecl)]
  [module-name : String]
  [raw-module-name : (& str)]
  [decl-path : (& str)]
  [is-stdlib : bool]
  [name : i64]
  [expr : i64]
  [flags : i64]) : unit
  (let
    [spelling : String (tli-extract-name name)]
    [symbol : String
      (if is-stdlib
        (symbols.compiler-symbol-module-key
          (string.copy (& module-name))
          (string.copy (& spelling)))
        (tli-extract-package-link-symbol decl-path raw-module-name (& spelling)))]
    [ty : ast.AstType
      (match (tc.tc-lookup-id
        env
        (symbols.compiler-symbol-module-key-id-by-id
          (tc.tc-context-module-id ctx)
          name))
        [(Ok ty) ty]
        [(Err _)
          (match (tc.tc-top-decl-type-with-env
            ctx
            env
            (ast.ast-decl-unwrapped decl))
            [(Ok ty) ty]
            [(Err message) (io.panic message)])])]
    [const : tli.TliConst (tli.TliConst.None)]
    [runtime-init : bool false]
    (match (lower.lower-global-value
      ctx
      names
      (tc.tc-context-expr-get ctx expr)
      (tc.tc-type-without-regions (ast.ty-node-persist (& ty))))
      [(Ok value)
        (set! const (tli-extract-const (& value) (ast.ty-node-persist (& ty))))]
      [(Err _) (set! runtime-init (= (bit-and flags 1) 0))])
    (when runtime-init (set! out.flags (bit-or out.flags 1)))
    (values.push-ref!
      (&mut out.values)
      (tli.TliValueDecl
        spelling
        module-name
        symbol
        (tli-extract-type-in ctx sources root-type-slots ty)
        (+
          flags
          (tli-extract-flag runtime-init 4)
          (match (& const)
            [(None) 0]
            [_ 8]))
        false
        (__tl_make-array tli.TliExternLinkInput 0)
        const))))

(defmacro (tli-extract-finish-vector [element-type : Expr] [source : Expr]) : Expr
  `(let
    [v ,source]
    [count v.len]
    [rows (__tl_make-array ,element-type count)]
    [live (__tl_make-array bool count)]
    [index : i64 0]
    (while (< index count)
      (set! (array-ref live index) true)
      (set! index (+ index 1)))
    (set! index 0)
    (while (< index count)
      (set!
        (array-ref rows index)
        (tuple-ref (__tl_array-take! v.slots live index) 1))
      (set! index (+ index 1)))
    rows))

(define (tli-extract-copy-writes [source : (& source writes.Vec)]) : (__tl_dyn-array
    tli.TliGlobalWrite)
  (let
    [count : i64 (writes.len source)]
    [out : (__tl_dyn-array tli.TliGlobalWrite)
      (__tl_make-array tli.TliGlobalWrite count)]
    (for [index (iterator.range 0 count)]
      (let
        [row (& (array-ref source.slots index))]
        (set!
          (array-ref out index)
          (tli.TliGlobalWrite (string.copy (& row.symbol)) row.flags))))
    out))

;; Generated declarations carry comptime provenance. The handwritten
;; stdlib.comptime surface is also compile-time by module identity.
(define (tli-extract-comptime? [ctx : tc.TcContext] [decl : (& ast.AstDecl)]) : bool
  (or
    (symbols.compiler-symbols-comptime-module-id? (tc.tc-context-module-id ctx))
    (and
      (ast.ast-decl-comptime-only? decl)
      (match (ast.ast-decl-generated-meta decl)
        [(No) true]
        [_ false]))))

(define (tli-extract-local-fn!
  [out : (&mut TliExtractModule)]
  [ctx : tc.TcContext]
  [sources : (& sources (__tl_dyn-array TliSource))]
  [root-type-slots : (& root-type-slots str_map.Map)]
  [module-name : String]
  [raw-module-name : (& str)]
  [decl-path : (& str)]
  [is-stdlib : bool]
  [index : i64]
  [name : i64]
  [params : ast.AstParamList]
  [ret : ast.AstType]
  [meta : (& ast.AstFnMetadata)]
  [facts : (& facts TliExtractEffects)]
  [original : (& ast.AstDecl)]
  [unsafe-decl : bool]) : unit
  (let
    [signature : tc.TcElidedSignature
      (match (tc.tc-elide-function-signature
        (tc.tc-context-type-bases ctx)
        params
        ret)
        [(Ok signature) signature]
        [(Err message) (io.panic message)])]
    [spelling : String (tli-extract-name name)]
    [fn-symbol : String
      (if is-stdlib
        (symbols.compiler-symbol-module-key
          (string.copy (& module-name))
          (string.copy (& spelling)))
        (tli-extract-package-link-symbol decl-path raw-module-name (& spelling)))]
    [result : ast.AstType (tc.tc-resolve-type ctx signature.ret)]
    [summary : tli.TliFnSummary
      (tli-extract-summary
        facts
        index
        signature.params.len
        (& result)
        (tli-extract-comptime? ctx original)
        unsafe-decl
        (ast.ast-decl-must-use? original))]
    [meta-kind : i64
      (match meta
        [(No) 0]
        [(Export _) 1]
        [(SpmdCallable _) 2])]
    [export : String
      (match meta
        [(Export symbol) (string.copy (intern.intern-id-str symbol))]
        [_ ""])]
    (functions.push-ref!
      (&mut out.functions)
      (tli.TliFnDecl
        spelling
        module-name
        fn-symbol
        0
        meta-kind
        export
        false
        0
        (__tl_make-array tli.TliExternLinkInput 0)
        (tli-extract-params ctx sources root-type-slots (& signature.params))
        (tli-extract-type-in ctx sources root-type-slots result)
        summary))))

(define (tli-extract-extern!
  [out : (&mut TliExtractModule)]
  [ctx : tc.TcContext]
  [sources : (& sources (__tl_dyn-array TliSource))]
  [root-type-slots : (& root-type-slots str_map.Map)]
  [module-name : String]
  [index : i64]
  [name : i64]
  [kind : ast.AstExternKind]
  [meta : ast.AstExternMetadata]
  [ty : ast.AstType]
  [facts : (& facts TliExtractEffects)]
  [original : (& ast.AstDecl)]
  [unsafe-decl : bool]) : unit
  (let
    [spelling : String (tli-extract-name name)]
    [comptime-only : bool (tli-extract-comptime? ctx original)]
    (match meta
      [(Metadata abi symbol links flags _)
        (let
          [link : String (string.copy (intern.intern-id-str symbol))]
          (when (> links.len 0) (set! out.flags (bit-or out.flags 8)))
          (match kind
            [(Function)
              (match (tc.tc-resolve-type ctx ty)
                [(Func params ret)
                  (let
                    [result : ast.AstType (tc.tc-context-type-get ctx ret)]
                    [abi-tag : i64
                      (match (& abi)
                        [(TypeLisp) 0]
                        [(C) 1]
                        [(CVarargsOpen) 2]
                        [(CVarargsTyped _) 3])]
                    (functions.push-ref!
                      (&mut out.functions)
                      (tli.TliFnDecl
                        spelling
                        module-name
                        link
                        abi-tag
                        0
                        ""
                        true
                        flags
                        (tli-extract-link-inputs (& links))
                        (tli-extract-extern-params
                          ctx
                          sources
                          root-type-slots
                          (& (__tl-box-place params))
                          abi)
                        (tli-extract-type-in
                          ctx
                          sources
                          root-type-slots
                          (ast.ty-node-persist (& result)))
                        (tli-extract-summary
                          facts
                          index
                          0
                          (& result)
                          comptime-only
                          unsafe-decl
                          (ast.ast-decl-must-use? original)))))]
                [_ (io.panic "TLI expected an extern function signature")])]
            [(Value)
              (values.push-ref!
                (&mut out.values)
                (tli.TliValueDecl
                  spelling
                  module-name
                  link
                  (tli-extract-type-in ctx sources root-type-slots ty)
                  (+
                    (tli-extract-flag comptime-only 1)
                    (tli-extract-flag unsafe-decl 2))
                  true
                  (tli-extract-link-inputs (& links))
                  (tli.TliConst.None)))]))])))

(define (tli-extract-decl!
  [out : (&mut TliExtractModule)]
  [ctx : tc.TcContext]
  [env : tc.TcTypeEnv]
  [sources : (& sources (__tl_dyn-array TliSource))]
  [root-type-slots : (& root-type-slots str_map.Map)]
  [companion : (& TliPackageCompanionBinding)]
  [module-name : String]
  [raw-module-name : (& str)]
  [decl-path : (& str)]
  [is-stdlib : bool]
  [index : i64]
  [unsafe-decl : bool]
  [decl : (& ast.AstDecl)]
  [lower-state : lower.CompilerLowerState]
  [facts : (& facts TliExtractEffects)]) : unit
  (let
    [comptime-only : bool (tli-extract-comptime? ctx decl)]
    [type-flags : i64
      (+
        (ast.ast-decl-aggregate-markers decl)
        (tli-extract-flag comptime-only 4)
        (tli-extract-flag unsafe-decl 8))]
    (when (!= (bit-and type-flags 2) 0) (set! out.flags (bit-or out.flags 4)))
    (match (ast.ast-decl-unwrapped decl)
      [(Def _ name _ expr)
        (tli-extract-value!
          out
          ctx
          env
          sources
          root-type-slots
          (lower.lower-name-cache-overlay
            lower-state
            lower.LowerNameEnv.Nil
            (tc.tc-context-module-id ctx))
          decl
          module-name
          raw-module-name
          decl-path
          is-stdlib
          name
          expr
          (+
            (tli-extract-flag comptime-only 1)
            (tli-extract-flag unsafe-decl 2)))]
      [(DefFn _ name params ret _ meta)
        (tli-extract-local-fn!
          out
          ctx
          sources
          root-type-slots
          module-name
          raw-module-name
          decl-path
          is-stdlib
          index
          name
          params
          ret
          (& meta)
          facts
          decl
          unsafe-decl)]
      [(Extern _ name kind meta ty)
        (tli-extract-extern!
          out
          ctx
          sources
          root-type-slots
          module-name
          index
          name
          kind
          (deref meta)
          ty
          facts
          decl
          unsafe-decl)]
      [(DefStruct _ name repr cleanup fields)
        (tli-extract-struct!
          (&mut out.types)
          ctx
          sources
          root-type-slots
          module-name
          name
          type-flags
          (& (ast.ast-lifetime-list-new))
          (& repr)
          cleanup
          (& fields))]
      [(DefStructLifetimes _ name lives repr cleanup fields)
        (tli-extract-struct!
          (&mut out.types)
          ctx
          sources
          root-type-slots
          module-name
          name
          type-flags
          (& lives)
          (& repr)
          cleanup
          (& fields))]
      [(DefEnum _ name cleanup variants)
        (tli-extract-enum!
          (&mut out.types)
          ctx
          sources
          root-type-slots
          module-name
          name
          type-flags
          (& (ast.ast-lifetime-list-new))
          cleanup
          (& variants))]
      [(DefEnumLifetimes _ name lives cleanup variants)
        (tli-extract-enum!
          (&mut out.types)
          ctx
          sources
          root-type-slots
          module-name
          name
          type-flags
          (& lives)
          cleanup
          (& variants))]
      [(DefMacro _ name params ret body-box)
        (set! out.flags (bit-or out.flags 2))
        (macros.push-ref!
          (&mut out.macros)
          (tli-extract-macro
            ctx
            sources
            root-type-slots
            companion
            is-stdlib
            module-name
            (tli-extract-name name)
            (& params)
            ret
            body-box))]
      [(DefDispatch _ name _)
        (let
          [spelling : String (tli-extract-name name)]
          [symbol : String
            (symbols.compiler-symbol-module-key
              (string.copy (& module-name))
              (string.copy (& spelling)))]
          (dispatches.push-ref!
            (&mut out.dispatches)
            (tli.TliDispatchDecl spelling module-name symbol 0)))]
      [_ unit])))

(define (tli-extract-find-module
  [sources : (& sources (__tl_dyn-array TliSource))]
  [name : (& str)]) : i64
  (for [index (iterator.range 0 (array-length sources))]
    (when
      (string.eq name (& (array-ref sources index).module-name))
      (return index)))
  -1)

(define (tli-extract-push-import!
  [out : (&mut out imports.Vec)]
  [name : String]
  [tag : i64]
  [alias : String]
  [item : String]) : unit
  (for [index (iterator.range 0 out.len)]
    (let
      [row (& (array-ref out.slots index))]
      (when
        (and
          (= row.kind tag)
          (string.eq (& row.module-name) (& name))
          (string.eq (& row.alias) (& alias))
          (string.eq (& row.item) (& item)))
        (return unit))))
  (imports.push-ref! out (tli.TliImport name tag alias item (make-array u8 32))))

(define (tli-extract-import-alias
  [decls : (& decls ast.AstDeclList)]
  [initial-owner : i64]
  [owner : i64]
  [qualifier : (& str)]) : String
  (let
    [current : i64 initial-owner]
    (for [index (iterator.range 0 (ast.ast-decl-list-len decls))]
      (match (ast.ast-decl-list-ref-borrowed decls index)
        [(Module name) (set! current name)]
        [(Import _ (Spec kind path expected (Some alias) _))
          (when
            (and
              (= current owner)
              (match kind
                [(or (Module) (ModuleAll) (ModuleItem _)) true]
                [_ false])
              (string.eq qualifier (tli-extract-name alias)))
            (return
              (match expected
                [(Some id) (tli-extract-name id)]
                [(No) (string.copy path)])))]
        [_ unit]))
    (string.copy qualifier)))

(define (tli-extract-macro-import-name
  [decls : (& ast.AstDeclList)]
  [initial-owner : i64]
  [owner : i64]
  [expr-bases : i64]
  [call : i64]) : String
  (match (ast.ast-expr-unspan-with-segment-bases
    expr-bases
    (& (ast.ast-expr-segment-bases-get expr-bases call)))
    [(Call callee _)
      (let
        [id : i64
          (tc.tc-expr-var-name-id
            expr-bases
            (ast.ast-expr-segment-bases-get expr-bases callee))]
        (if (< id 0)
          ""
          (let
            [name : String (tli-extract-name id)]
            [dot : i64 (tc.macro-call-callee-last-dot (& name))]
            (if (< dot 0)
              ""
              (tli-extract-import-alias
                decls
                initial-owner
                owner
                (& (string.substring (& name) 0 dot)))))))]
    [_ ""]))

;; Import aliases belong to the current Module marker. Path owners describe
;; source-file provenance, which can differ from the logical importer.
(define (tli-extract-imports!
  [records : (&mut (__tl_dyn-array TliExtractModule))]
  [sources : (& sources (__tl_dyn-array TliSource))]
  [decls : (& decls ast.AstDeclList)]
  [paths : (& ast.AstDeclPathList)]
  [has-paths : bool]
  [initial-owner : i64]
  [expr-bases : i64]) : unit
  (let
    [current : i64 initial-owner]
    (for [index (iterator.range 0 (ast.ast-decl-list-len decls))]
      (match (ast.ast-decl-list-get decls index (ast.ast-decl-fallback))
        [(Module owner) (set! current owner)]
        [(ModuleBody owner body)
          (tli-extract-imports!
            records
            sources
            (& (__tl-box-place body))
            paths
            false
            owner
            expr-bases)]
        [(Import _ spec)
          (let
            [mod-name : String (tli-extract-module-name current)]
            [slot : i64
              (if (> (string.string-length (& mod-name)) 0)
                (tli-extract-find-module sources (& mod-name))
                (if has-paths
                  (let
                    [decl-path : String
                      (ast.ast-decl-path-list-get paths index "")]
                    (tli-extract-source-for-path sources (& decl-path)))
                  -1))]
            (when
              (>= slot 0)
              (match (& spec)
                [(Spec kind path expected alias _)
                  (let
                    [name : String
                      (match kind
                        [(or (Macro call _) (MacroDecls call _))
                          (tli-extract-macro-import-name
                            decls
                            initial-owner
                            current
                            expr-bases
                            call)]
                        [_
                          (match expected
                            [(Some id) (tli-extract-name id)]
                            [(No) (string.copy path)])])]
                    [tag : i64
                      (match kind
                        [(Module) 0]
                        [(ModuleAll) 1]
                        [(ModuleItem _) 2]
                        [(Macro _ _) 3]
                        [(MacroDecls _ _) 4])]
                    (when
                      (> (string.string-length (& name)) 0)
                      (tli-extract-push-import!
                        (&mut (array-ref records slot).imports)
                        name
                        tag
                        (match alias
                          [(Some id) (tli-extract-name id)]
                          [(No) ""])
                        (match kind
                          [(ModuleItem id) (tli-extract-name id)]
                          [_ ""]))))])))]
        [_ unit]))))

(define (tli-extract-finish-module
  [source : (& TliSource)]
  [path : String]
  [cfg-digest : (& (Array u8 32))]
  [record : TliExtractModule]) : tli.TliModuleRecord
  (match record
    [(TliExtractModule flags imps tys fns vals macs disps)
      (let
        [inits : (__tl_dyn-array String)
          (__tl_make-array String (bit-and flags 1))]
        (when
          (> (array-length inits) 0)
          (set!
            (array-ref inits 0)
            (tli.tli-module-init-symbol (& source.module-name))))
        (tli.TliModuleRecord
          (string.copy (& source.module-name))
          path
          source.digest
          (deref cfg-digest)
          flags
          (tli-extract-finish-vector tli.TliImport imps)
          inits
          (tli-extract-finish-vector tli.TliTypeDecl tys)
          (tli-extract-finish-vector tli.TliFnDecl fns)
          (tli-extract-finish-vector tli.TliValueDecl vals)
          (tli-extract-finish-vector tli.TliMacroHandle macs)
          (tli-extract-finish-vector tli.TliDispatchDecl disps)))]))

(define (tli-extract-empty-module [path : (& str)]) : TliExtractModule
  (TliExtractModule
    (tli-extract-flag
      (or
        (string.eq path "stdlib/runtime.tl")
        (string.eq path "stdlib/core_macros.tl"))
      16)
    (imports.new)
    (types.new)
    (functions.new)
    (values.new)
    (macros.new)
    (dispatches.new)))

(define (tli-extract-open-modules
  [request : (& request api.TypecheckRequest)]
  [sources : (& sources (__tl_dyn-array TliSource))]) : (__tl_dyn-array
    TliExtractModule)
  (let
    [count : i64 (array-length sources)]
    [records : (__tl_dyn-array TliExtractModule)
      (__tl_make-array TliExtractModule count)]
    (for [slot (iterator.range 0 count)]
      (let
        [path (& (array-ref sources slot).path)]
        (set! (array-ref records slot) (tli-extract-empty-module path))))
    (match (& request.program)
      [(Program decls)
        (tli-extract-imports!
          (&mut records)
          sources
          (& (deref decls))
          (& request.paths)
          true
          (symbols.compiler-symbol-root-module-id)
          (ast.ast-node-pool-context-expr-segment-bases (& request.pools)))])
    records))

(define (tli-extract-find-record
  [modules : (& modules (__tl_dyn-array tli.TliModuleRecord))]
  [name : (& str)]) : i64
  (for [index (iterator.range 0 (array-length modules))]
    (when (string.eq name (& (array-ref modules index).name)) (return index)))
  -1)

;; Hash a dependency with the same pool and record encoding the final bundle
;; uses. Visiting dependencies first makes every in-bundle import pin exact.
;; Imports outside the requested source set have no interface artifact here.
(define (tli-extract-pin-module!
  [ctx : (&mut ctx codec.TliWriteContext)]
  [modules : (&mut modules (__tl_dyn-array tli.TliModuleRecord))]
  [states : (&mut states (__tl_dyn-array i64))]
  [digests : (&mut digests (__tl_dyn-array sha.Sha256Digest))]
  [slot : i64]) : bool
  (match (array-ref states slot)
    [2 true]
    [1 false]
    [_
      (set! (array-ref states slot) 1)
      (let
        [count : i64 (array-length (array-ref modules slot).imports)]
        (for [index (iterator.range 0 count)]
          (let
            [target : i64
              (tli-extract-find-record
                modules
                (&
                  (array-ref (array-ref modules slot).imports index).module-name))]
            (when
              (>= target 0)
              (unless
                (tli-extract-pin-module! ctx modules states digests target)
                (return false))
              (set!
                (array-ref (array-ref modules slot).imports index).interface-sha256
                (sha.digest-bytes (& (array-ref digests target))))))))
      (set! ctx.out.len 0)
      (codec.tli-write-module! ctx (& (array-ref modules slot)))
      (set!
        (array-ref digests slot)
        (sha.Sha256Digest
          (codec.tli-module-digest (& ctx.out.slots) 0 ctx.out.len)))
      (set! (array-ref states slot) 2)
      true]))

(define (tli-extract-pin-module-with-load-state!
  [ctx : (&mut ctx codec.TliWriteContext)]
  [modules : (&mut modules (__tl_dyn-array tli.TliModuleRecord))]
  [states : (&mut states (__tl_dyn-array i64))]
  [digests : (&mut digests (__tl_dyn-array sha.Sha256Digest))]
  [load-state : (& load.CompilerLoadSessionState)]
  [slot : i64]) : bool
  (match (array-ref states slot)
    [2 true]
    [1 false]
    [_
      (set! (array-ref states slot) 1)
      (let
        [count : i64 (array-length (array-ref modules slot).imports)]
        (for [index (iterator.range 0 count)]
          (let
            [imp-name : String
              (string.copy
                (&
                  (array-ref (array-ref modules slot).imports index).module-name))]
            [target : i64 (tli-extract-find-record modules (& imp-name))]
            (if (>= target 0)
              (begin
                (unless
                  (tli-extract-pin-module-with-load-state!
                    ctx
                    modules
                    states
                    digests
                    load-state
                    target)
                  (return false))
                (set!
                  (array-ref (array-ref modules slot).imports index).interface-sha256
                  (sha.digest-bytes (& (array-ref digests target)))))
              (match (load.compiler-load-session-state-tli-module-sha256
                load-state
                (& imp-name))
                [(Some ext-digest)
                  (set!
                    (array-ref (array-ref modules slot).imports index).interface-sha256
                    ext-digest)]
                [(None) unit])))))
      (set! ctx.out.len 0)
      (codec.tli-write-module! ctx (& (array-ref modules slot)))
      (set!
        (array-ref digests slot)
        (sha.Sha256Digest
          (codec.tli-module-digest (& ctx.out.slots) 0 ctx.out.len)))
      (set! (array-ref states slot) 2)
      true]))

(define (tli-extract-pin-imports-with-load-state!
  [bundle : (&mut bundle tli.TliBundle)]
  [load-state : (& load.CompilerLoadSessionState)]) : bool
  (let
    [count : i64 (array-length bundle.modules)]
    [ctx : codec.TliWriteContext
      (codec.TliWriteContext
        false
        (codec.tli-collect-pool bundle)
        (buf.byte-buf-builder-new))]
    [states : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [digests : (__tl_dyn-array sha.Sha256Digest)
      (__tl_make-array sha.Sha256Digest count)]
    (for [slot (iterator.range 0 count)]
      (unless
        (tli-extract-pin-module-with-load-state!
          (&mut ctx)
          (&mut bundle.modules)
          (&mut states)
          (&mut digests)
          load-state
          slot)
        (return false)))
    true))

(define (tli-extract-pin-imports! [bundle : (&mut bundle tli.TliBundle)]) : bool
  (let
    [count : i64 (array-length bundle.modules)]
    [ctx : codec.TliWriteContext
      (codec.TliWriteContext
        false
        (codec.tli-collect-pool bundle)
        (buf.byte-buf-builder-new))]
    [states : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [digests : (__tl_dyn-array sha.Sha256Digest)
      (__tl_make-array sha.Sha256Digest count)]
    (for [slot (iterator.range 0 count)]
      (unless
        (tli-extract-pin-module!
          (&mut ctx)
          (&mut bundle.modules)
          (&mut states)
          (&mut digests)
          slot)
        (return false)))
    true))

;; The positional symbol table unwraps Unsafe declarations. Walk the
;; checked program in the same index order to retain the outer wrapper.
(define (tli-extract-unsafe-decls!
  [flags : (&mut flags (__tl_dyn-array bool))]
  [decls : (& decls ast.AstDeclList)]
  [start : i64]) : i64
  (let
    [next : i64 start]
    (for [index (iterator.range 0 (ast.ast-decl-list-len decls))]
      (let
        [decl : ast.AstDecl
          (ast.ast-decl-list-get decls index (ast.ast-decl-fallback))]
        (cond
          [(symbols.compiler-symbol-decl-counts-for-index? (& decl))
            (set!
              (array-ref flags next)
              (match (& decl)
                [(Unsafe _) true]
                [_ false]))
            (+= next 1)]
          [else
            (match decl
              [(ModuleBody _ body)
                (set!
                  next
                  (tli-extract-unsafe-decls!
                    flags
                    (& (__tl-box-place body))
                    next))]
              [_ unit])])))
    next))

(define (tli-extract-source-for-path
  [sources : (& sources (__tl_dyn-array TliSource))]
  [path : (& str)]) : i64
  (for [index (iterator.range 0 (array-length sources))]
    (when (string.eq path (& (array-ref sources index).path)) (return index)))
  -1)

(define (tli-extract-add-generated-sources
  [ctx : tc.TcContext]
  [paths : (& ast.AstDeclPathList)]
  [sources : (& sources (__tl_dyn-array TliSource))]) : (__tl_dyn-array
    TliSource)
  (let
    [seen : sym_i64_env.SymI64Env (sym_i64_env.sym-i64-empty)]
    [out : source_rows.Vec (source_rows.new)]
    [decls : ast.AstDeclList
      (match (tc.tc-context-program ctx)
        [(Program decls) (deref decls)])]
    [count : i64
      (symbols.compiler-symbols-decl-count (tc.tc-context-symbols (& ctx)))]
    (for [index (iterator.range 0 (array-length sources))]
      (let
        [source (& (array-ref sources index))]
        (source_rows.push-ref!
          (&mut out)
          (TliSource
            (string.copy (& source.module-name))
            (string.copy (& source.path))
            source.digest))))
    (for [index (iterator.range 0 count)]
      (let
        [id : i64 (tli-extract-owner ctx index)]
        (when
          (and
            (not (symbols.compiler-symbol-root-module-id? id))
            (not (sym_i64_env.sym-i64-contains-id (& seen) id)))
          (set! seen (sym_i64_env.sym-i64-bind-id seen id 1))
          (let
            [name : String (tli-extract-module-name id)]
            (when
              (< (tli-extract-find-module sources (& name)) 0)
              (let
                [path : String
                  (symbols.compiler-symbol-path-at-index
                    (& decls)
                    paths
                    index
                    0)]
                [origin : i64 (tli-extract-source-for-path sources (& path))]
                (when
                  (>= origin 0)
                  (source_rows.push-ref!
                    (&mut out)
                    (TliSource name path (array-ref sources origin).digest)))))))))
    (tli-extract-finish-vector TliSource out)))

(define (tli-extract-extend-records
  [original : (__tl_dyn-array TliExtractModule)]
  [sources : (& sources (__tl_dyn-array TliSource))]) : (__tl_dyn-array
    TliExtractModule)
  (let
    [count : i64 (array-length original)]
    [records : (__tl_dyn-array TliExtractModule)
      (__tl_make-array TliExtractModule (array-length sources))]
    [live : (__tl_dyn-array bool) (__tl_make-array bool count)]
    (for [index (iterator.range 0 count)]
      (set! (array-ref live index) true))
    (for [index (iterator.range 0 count)]
      (set!
        (array-ref records index)
        (tuple-ref (__tl_array-take! original live index) 1)))
    (for [index (iterator.range count (array-length sources))]
      (set!
        (array-ref records index)
        (tli-extract-empty-module (& (array-ref sources index).path))))
    records))

(define (tli-extract-checked-with-companion
  [ctx : tc.TcContext]
  [env : tc.TcTypeEnv]
  [paths : (& ast.AstDeclPathList)]
  [sources : (& sources (__tl_dyn-array TliSource))]
  [records : (__tl_dyn-array TliExtractModule)]
  [cfg-digest : (& (Array u8 32))]
  [bundle-flags : i64]
  [build : String]
  [target : String]
  [companion : (& TliPackageCompanionBinding)]) : tli.TliBundle
  ;; Macro-expansion CTFE probes aggregate layouts before generated-instance
  ;; import aliases resolve, and caches what it saw. Recorded layouts must match
  ;; the ones lowering emits, so start from the same clean view lowering uses.
  (tc.tc-agg-caches-reset-for-job! (tc.tc-context-job-state ctx))
  (tc.tc-nominal-owner-cache-reset-for-job! (tc.tc-context-job-state ctx))
  (let
    [is-stdlib : bool (!= (bit-and bundle-flags tli.tli-is-stdlib-bundle) 0)]
    [facts : TliExtractEffects (tli-extract-effects ctx env)]
    [decls : ast.AstDeclList
      (match (tc.tc-context-program ctx)
        [(Program decls) (deref decls)])]
    [count : i64 (array-length sources)]
    [decl-count : i64
      (symbols.compiler-symbols-decl-count (tc.tc-context-symbols (& ctx)))]
    [unsafe-decls : (__tl_dyn-array bool) (__tl_make-array bool decl-count)]
    [live : (__tl_dyn-array bool) (__tl_make-array bool count)]
    [paths-out : (__tl_dyn-array String) (__tl_make-array String count)]
    [modules : (__tl_dyn-array tli.TliModuleRecord)
      (__tl_make-array tli.TliModuleRecord count)]
    [root-type-slots : str_map.Map (str_map.with-capacity 16)]
    [lower-state : lower.CompilerLowerState (lower.compiler-lower-state-new)]
    [names : lower.LowerNameCache
      (lower.lower-name-cache-from-env
        lower-state
        (lower.lower-name-env-from-decls-with-state
          lower-state
          (& decls)
          paths
          ""
          lower.LowerNameEnv.Nil))]
    (lower.compiler-lower-state-set-active-global-name-cache! lower-state names)
    (for [slot (iterator.range 0 count)]
      (let
        [path (& (array-ref sources slot).path)]
        (set! (array-ref paths-out slot) (string.copy path))
        (set! (array-ref live slot) true)))
    (tli-extract-imports!
      (&mut records)
      sources
      (& decls)
      paths
      true
      (symbols.compiler-symbol-root-module-id)
      (tc.tc-context-expr-segment-bases ctx))
    (when
      (!=
        (tli-extract-unsafe-decls! (&mut unsafe-decls) (& decls) 0)
        decl-count)
      (io.panic "TLI source and symbol declaration indices disagree"))
    (unless
      is-stdlib
      (for [index (iterator.range 0 decl-count)]
        (let
          [raw-owner-id : i64 (tli-extract-owner ctx index)]
          (when
            (symbols.compiler-symbol-root-module-id? raw-owner-id)
            (let
              [decl-path : String
                (symbols.compiler-symbol-path-at-index (& decls) paths index 0)]
              [origin : i64 (tli-extract-source-for-path sources (& decl-path))]
              (when
                (>= origin 0)
                (match (symbols.compiler-symbols-decl-at-index
                  (tc.tc-context-symbols (& ctx))
                  index)
                  [(Ok decl)
                    (match (ast.ast-decl-unwrapped (& decl))
                      [(or (DefStruct _ name _ _ _)
                           (DefStructLifetimes _ name _ _ _ _)
                           (DefEnum _ name _ _) (DefEnumLifetimes _ name _ _ _))
                        (str_map.insert-ref!
                          (&mut root-type-slots)
                          (tli-extract-name name)
                          origin)]
                      [_ unit])]
                  [(Err _) unit])))))))
    (for [index (iterator.range 0 decl-count)]
      (let
        [module-id : i64 (tli-extract-owner ctx index)]
        [raw-module-name : String (tli-extract-module-name module-id)]
        [decl-path : String
          (symbols.compiler-symbol-path-at-index (& decls) paths index 0)]
        [slot : i64
          (if (> (string.string-length (& raw-module-name)) 0)
            (tli-extract-find-module sources (& raw-module-name))
            (if is-stdlib
              (tli-extract-find-module sources (& raw-module-name))
              (tli-extract-source-for-path sources (& decl-path))))]
        [module-name : String
          (if (> (string.string-length (& raw-module-name)) 0)
            (string.copy (& raw-module-name))
            (if (and (not is-stdlib) (>= slot 0))
              (string.copy (& (array-ref sources slot).module-name))
              (string.copy (& raw-module-name))))]
        (when
          (>= slot 0)
          (when
            (= (string.string-length (& (array-ref paths-out slot))) 0)
            (set! (array-ref paths-out slot) (string.copy (& decl-path))))
          (match (symbols.compiler-symbols-decl-at-index
            (tc.tc-context-symbols (& ctx))
            index)
            [(Ok decl)
              (tli-extract-decl!
                (&mut (array-ref records slot))
                (tc.tc-context-with-nominal-owner-index-module ctx index)
                env
                sources
                (& root-type-slots)
                companion
                module-name
                (& raw-module-name)
                (& decl-path)
                is-stdlib
                index
                (array-ref unsafe-decls index)
                (& decl)
                lower-state
                (& facts))]
            [(Err message) (io.panic message)]))))
    (for [slot (iterator.range 0 count)]
      (set!
        (array-ref modules slot)
        (tli-extract-finish-module
          (& (array-ref sources slot))
          (string.copy (& (array-ref paths-out slot)))
          cfg-digest
          (tuple-ref (__tl_array-take! records live slot) 1))))
    (tli.TliBundle bundle-flags build target modules)))

(define (tli-extract-checked
  [ctx : tc.TcContext]
  [env : tc.TcTypeEnv]
  [paths : (& ast.AstDeclPathList)]
  [sources : (& sources (__tl_dyn-array TliSource))]
  [records : (__tl_dyn-array TliExtractModule)]
  [cfg-digest : (& (Array u8 32))]
  [bundle-flags : i64]
  [build : String]
  [target : String]) : tli.TliBundle
  (let
    [empty-companion : TliPackageCompanionBinding
      (tli-package-companion-binding-empty)]
    (tli-extract-checked-with-companion
      ctx
      env
      paths
      sources
      records
      cfg-digest
      bundle-flags
      build
      target
      (& empty-companion))))

(define (tli-extract
  [request : api.TypecheckRequest]
  [sources : (& sources (__tl_dyn-array TliSource))]
  [bundle-flags : i64]
  [build : String]
  [target : String]) : TliExtractResult
  (let
    [cfg-digest : (Array u8 32) (tli-extract-cfg-digest request.cfgs)]
    [records : (__tl_dyn-array TliExtractModule)
      (tli-extract-open-modules (& request) sources)]
    [job : tc.TcJobState request.job-state]
    (set! request.retain-global-call-effects true)
    (let
      [result : TliExtractResult
        (match (api.typecheck-compiler-request-checked request)
          [(Ok _ ctx env paths)
            (let
              [all-sources : (__tl_dyn-array TliSource)
                (tli-extract-add-generated-sources ctx (& paths) sources)]
              [all-records : (__tl_dyn-array TliExtractModule)
                (tli-extract-extend-records records (& all-sources))]
              [bundle : tli.TliBundle
                (tli-extract-checked
                  ctx
                  env
                  (& paths)
                  (& all-sources)
                  all-records
                  (& cfg-digest)
                  bundle-flags
                  build
                  target)]
              (if (tli-extract-pin-imports! (&mut bundle))
                (Ok bundle)
                (Err "TLI import cycle cannot pin module record digests")))]
          [(or (Partial diagnostics _ _ _) (Err diagnostics))
            (Err
              (diag.compiler-diagnostic-render
                (&
                  (diag.compiler-diagnostic-list-first
                    (& (__tl-box-place diagnostics))))))])]
      (tc.tc-global-call-effects-finish! job)
      (cfg
        embedded-stdlib-tlci
        (tlci.compiler-embedded-stdlib-tlci-session-close!))
      result)))

;; --- Shared single-pass typecheck + partitioned module emitter ---------------
(define (tli-partition-sanitize-module-filename [name : (& str)]) : String
  (let
    [buf : text_buf.TextBuf (text_buf.empty)]
    [n : i64 (string.string-length name)]
    (for [i (iterator.range 0 n)]
      (let
        [c : char (string.string-ref name i)]
        [ok : bool
          (or
            (and (>= c 'a') (<= c 'z'))
            (and (>= c 'A') (<= c 'Z'))
            (and (>= c '0') (<= c '9'))
            (= c '_')
            (= c '-'))]
        (if ok
          (set! buf (text_buf.append buf (string.substring name i 1)))
          (set! buf (text_buf.append buf "_")))))
    (text_buf.render buf)))

(define (tli-partition-pad3 [n : i64]) : String
  (let
    [s : String (string.int->string n)]
    (cond
      [(< n 10) (str_cat.str-cat "00" s)]
      [(< n 100) (str_cat.str-cat "0" s)]
      [else s])))

(define (tli-partition-sort-strings! [items : (&mut (__tl_dyn-array String))]) : unit
  (let
    [n : i64 (array-length (deref items))]
    (for [i (iterator.range 1 n)]
      (let
        [j : i64 i]
        (while (> j 0)
          (let
            [left-gt : bool
              (sort.string-less-borrowed?
                (& (array-ref (deref items) j))
                (& (array-ref (deref items) (- j 1))))]
            (if left-gt
              (let
                [a : String (string.copy (& (array-ref (deref items) (- j 1))))]
                [b : String (string.copy (& (array-ref (deref items) j)))]
                (set! (array-ref (deref items) (- j 1)) b)
                (set! (array-ref (deref items) j) a)
                (-= j 1))
              (break))))))))

(define (tli-partition-fn-physical-signature
  [pools : ast.AstNodePoolContext]
  [params : (& ir.CompilerIrParamSeq)]
  [ret : (& ast.AstType)]) : ast.AstType
  (let
    [list : ast.AstTypeList (ast.ast-type-list-with-capacity params.len)]
    (for [i (iterator.range 0 params.len)]
      (match (& (array-ref params.slots i))
        [(ir.CompilerIrParam.Param _ pty _)
          (ast.ast-type-list-push
            (&mut list)
            (ast.ast-node-pool-context-type-push
              pools
              (ir.compiler-ir-clone-type pools (ast.ty-node-persist pty))))]))
    (let
      [ret-copy : ast.AstType
        (ir.compiler-ir-clone-type pools (ast.ty-node-persist ret))]
      (ast.ast-ty-func list (& ret-copy)))))

(define (tli-partition-intern-symbol!
  [interns : (&mut intern.InternCompatState)]
  [text : String]) : i64
  (let
    [id : i64 (intern.intern-compat-state-intern interns text)]
    (intern.intern-compat-state-install! (& (deref interns)))
    id))

(define (tli-partition-note-ref! [refs : (&mut i64_map.Map)] [symbol-id : i64]) : unit
  (i64_map.insert-ref! refs (ir.compiler-ir-symbol-id symbol-id) 1))

(define (tli-partition-collect-value-refs!
  [refs : (&mut i64_map.Map)]
  [value : (& ir.CompilerIrValue)]) : unit
  (match value
    [(ir.CompilerIrValue.Function name) (tli-partition-note-ref! refs name)]
    [(ir.CompilerIrValue.Global name) (tli-partition-note-ref! refs name)]
    [(ir.CompilerIrValue.GlobalAddr name) (tli-partition-note-ref! refs name)]
    [_ unit]))

(define (tli-partition-fold-value-ref
  [_role : ir.CompilerIrOperandRole]
  [refs : i64_map.Map]
  [value : ir.CompilerIrValue]) : i64_map.Map
  (let
    [out : i64_map.Map refs]
    (tli-partition-collect-value-refs! (&mut out) (& value))
    out))

(define (tli-partition-collect-instr-refs
  [pools : ast.AstNodePoolContext]
  [refs : i64_map.Map]
  [slots : (& (__tl_dyn-array ir.CompilerIrInstr))]
  [index : i64]) : i64_map.Map
  (let
    [out : i64_map.Map refs]
    (match (& (array-ref (deref slots) index))
      [(or (ir.CompilerIrInstr.Call _ name _ _)
           (ir.CompilerIrInstr.TailCall name _ _))
        (tli-partition-note-ref! (&mut out) name)]
      [(ir.CompilerIrInstr.CallCAbiStoreResult payload-box)
        (match (& (deref payload-box))
          [(fields name) (tli-partition-note-ref! (&mut out) name)])]
      [(ir.CompilerIrInstr.SpmdCall payload-box)
        (match (& (deref payload-box))
          [(fields callee) (tli-partition-note-ref! (&mut out) callee)])]
      [(ir.CompilerIrInstr.Store name _ _)
        (tli-partition-note-ref! (&mut out) name)]
      [_ unit])
    (ir.compiler-ir-instr-fold-uses
      (ir.compiler-ir-clone-instr-at pools slots index)
      out
      tli-partition-fold-value-ref)))

(defstruct TliPartitionModuleRefs
  (refs i64_map.Map))

(define (tli-partition-module-refs-contains?
  [mrefs : (& TliPartitionModuleRefs)]
  [symbol-id : i64]) : bool
  (i64_map.contains? (& mrefs.refs) (ir.compiler-ir-symbol-id symbol-id)))

(define (tli-partition-function-has-syscall? [func : (& ir.CompilerIrFunction)]) : bool
  (match func
    [(ir.CompilerIrFunction.Function _ _ _ _ blocks _)
      (match blocks
        [(ir.CompilerIrBlockList.Array block-seq)
          (let
            [found : bool false]
            (for [bi (iterator.range 0 block-seq.len)]
              (when
                (not found)
                (match (& (array-ref block-seq.slots bi))
                  [(ir.CompilerIrBlock.Block _ instrs)
                    (for [ii (iterator.range 0 instrs.len)]
                      (match (& (array-ref instrs.slots ii))
                        [(ir.CompilerIrInstr.Syscall _ _) (set! found true)]
                        [_ unit]))])))
            found)])]))

(define (tli-partition-function-collect-refs
  [pools : ast.AstNodePoolContext]
  [func : (& ir.CompilerIrFunction)]) : i64_map.Map
  (let
    [refs : i64_map.Map (i64_map.with-capacity 32)]
    (match func
      [(ir.CompilerIrFunction.Function _ _ _ _ blocks _)
        (match blocks
          [(ir.CompilerIrBlockList.Array block-seq)
            (for [bi (iterator.range 0 block-seq.len)]
              (match (& (array-ref block-seq.slots bi))
                [(ir.CompilerIrBlock.Block _ instrs)
                  (for [ii (iterator.range 0 instrs.len)]
                    (set!
                      refs
                      (tli-partition-collect-instr-refs
                        pools
                        refs
                        (& instrs.slots)
                        ii)))]))])])
    refs))

(define (tli-partition-windows-syscall-skip-mask
  [pools : ast.AstNodePoolContext]
  [functions : (& ir.CompilerIrFunctionSeq)]) : (__tl_dyn-array bool)
  (let
    [fn-count : i64 functions.len]
    [skip : (__tl_dyn-array bool) (__tl_make-array bool fn-count)]
    [fn-ids : (__tl_dyn-array i64) (__tl_make-array i64 fn-count)]
    [fn-refs : (__tl_dyn-array i64_map.Map)
      (__tl_make-array i64_map.Map fn-count)]
    [changed : bool false]
    (for [i (iterator.range 0 fn-count)]
      (match (& (array-ref functions.slots i))
        [(ir.CompilerIrFunction.Function fn-name _ _ _ _ _)
          (set! (array-ref fn-ids i) (ir.compiler-ir-symbol-id fn-name))])
      (set!
        (array-ref fn-refs i)
        (tli-partition-function-collect-refs
          pools
          (& (array-ref functions.slots i))))
      (when
        (tli-partition-function-has-syscall? (& (array-ref functions.slots i)))
        (set! (array-ref skip i) true)
        (set! changed true)))
    (while changed
      (set! changed false)
      (for [i (iterator.range 0 fn-count)]
        (when
          (not (array-ref skip i))
          (let
            [hit : bool false]
            (for [j (iterator.range 0 fn-count)]
              (when
                (and
                  (not hit)
                  (array-ref skip j)
                  (i64_map.contains?
                    (& (array-ref fn-refs i))
                    (array-ref fn-ids j)))
                (set! hit true)))
            (when hit (set! (array-ref skip i) true) (set! changed true))))))
    skip))

(define (tli-partition-collect-module-refs
  [pools : ast.AstNodePoolContext]
  [globals : (& ir.CompilerIrGlobalSeq)]
  [functions : (& ir.CompilerIrFunctionSeq)]) : TliPartitionModuleRefs
  (let
    [refs : i64_map.Map (i64_map.with-capacity 256)]
    (for [gi (iterator.range 0 globals.len)]
      (match (& (array-ref globals.slots gi))
        [(ir.CompilerIrGlobal.Global _ _ value)
          (tli-partition-collect-value-refs! (&mut refs) (& value))]))
    (for [fi (iterator.range 0 functions.len)]
      (match (& (array-ref functions.slots fi))
        [(ir.CompilerIrFunction.Function _ _ _ _ blocks _)
          (match blocks
            [(ir.CompilerIrBlockList.Array block-seq)
              (for [bi (iterator.range 0 block-seq.len)]
                (match (& (array-ref block-seq.slots bi))
                  [(ir.CompilerIrBlock.Block _ instrs)
                    (for [ii (iterator.range 0 instrs.len)]
                      (set!
                        refs
                        (tli-partition-collect-instr-refs
                          pools
                          refs
                          (& instrs.slots)
                          ii)))]))])]))
    (TliPartitionModuleRefs refs)))

(define (tli-typecheck-for-extract-and-lower [request : api.TypecheckRequest]) : tc.ResultCompilerTypecheckChecked
  (let
    [observer-job : tc.TcJobState request.job-state]
    (tc.tc-job-state-set-parser-control!
      observer-job
      (parser.compiler-parse-control-from-cfg request.cfgs))
    (match request
      [(api.TypecheckRequest
          load-state
          prefix-cache
          job-state
          program
          paths
          stdlib-roots
          cfgs
          cache-scope
          pools
          request-intern-state
          _semantic-observer
          retain-global-call-effects)
        (let
          [intern-state : intern.InternCompatState request-intern-state]
          (tc.tc-spmd-inline-helper-stack-reset-for-job! job-state)
          (tc.tc-macro-call-site-state-reset!
            (tc.tc-job-state-macro-call-sites job-state))
          (tc.tc-typecheck-checked-result-with-pool-check
            job-state
            (let
              [owner-context : spec.SpecOwnerContext
                (spec.spec-owner-context-new pools (& intern-state))]
              [generated-result : spec.ResultGenProgramWithPaths
                (spec.gen-normalize-program-with-paths-and-pools-and-intern-state
                  (& program)
                  (& paths)
                  ""
                  owner-context)]
              (ast.ast-node-pool-context-install! pools)
              (intern.intern-compat-state-capture-from-globals!
                (&mut intern-state))
              (intern.intern-compat-state-install! (& intern-state))
              (match generated-result
                [(Err diag-box)
                  (tc.ResultCompilerTypecheckChecked.Err
                    (diag.compiler-diagnostic-list-box-single diag-box))]
                [(Ok generated generated-paths)
                  (let
                    [load-state-addr : u64 load-state.shared-address]
                    [macro-load-state : load.CompilerLoadSessionState
                      (if (= load-state-addr 0)
                        (load.compiler-load-serial-test-session-state)
                        (unsafe
                          (ptr-read
                            (int->ptr
                              load-state-addr
                              : (Ptr load.CompilerLoadSessionState)))))]
                    [macro-result : tc.ResultMacroExpand
                      (tc.macro-expand-program-with-paths-and-pools-roots-cfg-with-load-state-and-job-state-and-intern-state
                        macro-load-state
                        job-state
                        generated
                        generated-paths
                        pools
                        (strings.clone-vec (& stdlib-roots))
                        cfgs
                        (intern.intern-compat-state-capture-active))]
                    (ast.ast-node-pool-context-capture-active! pools)
                    (intern.intern-compat-state-capture-from-globals!
                      (&mut intern-state))
                    (match macro-result
                      [(Err diag-box)
                        (tc.ResultCompilerTypecheckChecked.Err
                          (diag.compiler-diagnostic-list-box-single diag-box))]
                      [(Ok expanded expanded-paths)
                        (tc.tc-typecheck-specialized-program-with-selected-lowering
                          load-state
                          prefix-cache
                          job-state
                          expanded
                          expanded-paths
                          stdlib-roots
                          cache-scope
                          pools
                          (intern.intern-source-name-session-handle
                            (intern.intern-source-name-session-from-state
                              (& intern-state)))
                          (intern.intern-compat-state-capture-active)
                          true
                          retain-global-call-effects)]))]))))])))

(define (tli-partition-owner-slot
  [name-to-slot : (& str_map.Map)]
  [owner-name : (& str)]) : i64
  (let
    [direct : i64
      (str_map.get-value-or name-to-slot (string.copy owner-name) -1)]
    (if (>= direct 0)
      direct
      (if (> (string.string-length owner-name) 0)
        (let
          [canonical : String
            (load.compiler-load-canonical-module-id-from-path owner-name)]
          (str_map.get-value-or name-to-slot canonical -1))
        -1))))

(define (tli-partition-noexecstack-note) : String
  "\n    .section .note.GNU-stack,\"\",@progbits\n")

(define (tli-emit-partitioned-modules!
  [bundle : (& tli.TliBundle)]
  [whole-program : ir.CompilerIrProgram]
  [whole-spans : ir.CompilerSourceSpans]
  [lower-state : lower.CompilerLowerState]
  [pools : ast.AstNodePoolContext]
  [job : tc.TcJobState]
  [asm-dir : (& str)]
  [manifest-out : (& str)]
  [backend-target : be_state.CompilerBackendTarget]
  [backend-mode : be_state.CompilerBackendMode]
  [windows? : bool]
  [opt-level : i64]
  [is-stdlib? : bool]) : ResultTliPartitionedEmit
  (let
    [interns : intern.InternCompatState
      (lower.compiler-lower-state-interns lower-state)]
    [type-segment-bases : i64
      (ast.ast-node-pool-context-type-segment-bases (& pools))]
    [module-count : i64 (array-length bundle.modules)]
    [sorted-names : (__tl_dyn-array String)
      (__tl_make-array String module-count)]
    [name-to-slot : str_map.Map
      (str_map.with-capacity (+ (* module-count 2) 4))]
    [expected-inits : (__tl_dyn-array bool) (__tl_make-array bool module-count)]
    (intern.intern-compat-state-install! (& interns))
    (ast.ast-node-pool-context-install! pools)
    (for [i (iterator.range 0 module-count)]
      (set!
        (array-ref sorted-names i)
        (string.copy (& (array-ref bundle.modules i).name))))
    (tli-partition-sort-strings! (&mut sorted-names))
    (for [i (iterator.range 0 module-count)]
      (str_map.insert-ref!
        (&mut name-to-slot)
        (string.copy (& (array-ref sorted-names i)))
        i))
    (for [i (iterator.range 0 module-count)]
      (let
        [slot : i64
          (str_map.get-value-or
            (& name-to-slot)
            (string.copy (& (array-ref bundle.modules i).name))
            -1)]
        (when (< slot 0) (return (Err "tli-partition: missing module slot")))
        (set!
          (array-ref expected-inits slot)
          (> (array-length (array-ref bundle.modules i).global-inits) 0))))
    (match whole-program
      [(ir.CompilerIrProgram.Program
          whole-globals
          whole-functions
          whole-externs
          _)
        (let
          [fn-count : i64 whole-functions.len]
          [gl-count : i64 whole-globals.len]
          [ex-count : i64 whole-externs.len]
          [fn-owners : (__tl_dyn-array i64) (__tl_make-array i64 fn-count)]
          [fn-skip : (__tl_dyn-array bool)
            (if (and windows? is-stdlib?)
              (tli-partition-windows-syscall-skip-mask
                pools
                (& whole-functions))
              (__tl_make-array bool fn-count))]
          [gl-owners : (__tl_dyn-array i64) (__tl_make-array i64 gl-count)]
          [gl-private : (__tl_dyn-array bool) (__tl_make-array bool gl-count)]
          [provided-by-fn : i64_map.Map (i64_map.with-capacity 64)]
          [found-inits : (__tl_dyn-array bool)
            (__tl_make-array bool module-count)]
          (for [i (iterator.range 0 ex-count)]
            (match (& (array-ref whole-externs.slots i))
              [(ir.CompilerIrExtern.Extern name-id _ _ _ _ _ _ provided _)
                (when
                  provided
                  (i64_map.insert-ref!
                    (&mut provided-by-fn)
                    (ir.compiler-ir-symbol-id name-id)
                    i))]))
          (for [i (iterator.range 0 fn-count)]
            (match (& (array-ref whole-functions.slots i))
              [(ir.CompilerIrFunction.Function fn-name _ _ _ _ _)
                (let
                  [owner-id : i64
                    (lower.compiler-lower-state-function-owner-module-id
                      lower-state
                      fn-name)]
                  [owner-name : String
                    (if (>= owner-id 0)
                      (lower.lower-name-id-text lower-state owner-id)
                      "")]
                  [slot : i64
                    (tli-partition-owner-slot (& name-to-slot) (& owner-name))]
                  (when
                    (and (< slot 0) is-stdlib?)
                    (return
                      (Err
                        (str_cat.str-cat
                          "build-stdlib-sysroot: unowned function "
                          (ir.compiler-ir-symbol-text fn-name)
                          " (owner="
                          owner-name
                          ")"))))
                  (set! (array-ref fn-owners i) slot)
                  (when
                    (>= slot 0)
                    (let
                      [fn-text : String (ir.compiler-ir-symbol-text fn-name)]
                      [expected-wrapper : String
                        (tli.tli-module-init-symbol
                          (& (array-ref sorted-names slot)))]
                      (when
                        (string.eq (& fn-text) (& expected-wrapper))
                        (when
                          (array-ref fn-skip i)
                          (return
                            (Err
                              (str_cat.str-cat
                                "build-stdlib-sysroot: startup init uses Linux syscall on Windows: "
                                fn-text))))
                        (set! (array-ref found-inits slot) true)))))]))
          (for [i (iterator.range 0 gl-count)]
            (match (& (array-ref whole-globals.slots i))
              [(ir.CompilerIrGlobal.Global gl-name _ _)
                (let
                  [owner-id : i64
                    (lower.compiler-lower-state-global-owner-module-id
                      lower-state
                      gl-name)]
                  [owner-name : String
                    (if (>= owner-id 0)
                      (lower.lower-name-id-text lower-state owner-id)
                      "")]
                  [slot : i64
                    (tli-partition-owner-slot (& name-to-slot) (& owner-name))]
                  (when
                    (and (< slot 0) is-stdlib?)
                    (return
                      (Err
                        (str_cat.str-cat
                          "build-stdlib-sysroot: unowned global "
                          (ir.compiler-ir-symbol-text gl-name)
                          " (owner="
                          owner-name
                          ")"))))
                  (set! (array-ref gl-owners i) slot)
                  (set!
                    (array-ref gl-private i)
                    (intern.intern-compat-state-generated-role-symbol?
                      (& interns)
                      gl-name
                      (intern.intern-generated-symbol-role-nullary-enum-object))))]))
          (for [m (iterator.range 0 module-count)]
            (when
              (!= (array-ref expected-inits m) (array-ref found-inits m))
              (return
                (Err
                  (str_cat.str-cat
                    "tli-partition: .tli and archive disagree on startup init for module "
                    (string.copy (& (array-ref sorted-names m))))))))
          ;; Precompute cross-module extern descriptors for all functions and
          ;; non-private globals.
          (let
            [fn-cross-externs : (__tl_dyn-array ir.CompilerIrExtern)
              (__tl_make-array ir.CompilerIrExtern fn-count)]
            [gl-cross-externs : (__tl_dyn-array ir.CompilerIrExtern)
              (__tl_make-array ir.CompilerIrExtern gl-count)]
            [base-reps : ir.CompilerIrRepresentationIndex
              (lower.lower-representation-index-from-layouts
                type-segment-bases
                job
                (ir.compiler-ir-representation-index-empty))]
            [manifest-buf : text_buf.TextBuf (text_buf.empty)]
            [emitted-files : strings.Vec (strings.new)]
            [emitted-modules : i64 0]
            [skipped-modules : i64 0]
            (for [i (iterator.range 0 fn-count)]
              (match (& (array-ref whole-functions.slots i))
                [(ir.CompilerIrFunction.Function fn-name fn-params fn-ret _ _ _)
                  (let
                    [fn-name-str : String (ir.compiler-ir-symbol-text fn-name)]
                    [fn-sig : ast.AstType
                      (tli-partition-fn-physical-signature
                        pools
                        fn-params
                        fn-ret)]
                    [provided-idx : i64
                      (i64_map.get-value-or
                        (& provided-by-fn)
                        (ir.compiler-ir-symbol-id fn-name)
                        -1)]
                    [link-sym-str : String
                      (if (>= provided-idx 0)
                        (match (& (array-ref whole-externs.slots provided-idx))
                          [(ir.CompilerIrExtern.Extern
                              _
                              _
                              _
                              _
                              prov-abi
                              prov-sym
                              _
                              _
                              _)
                            (let
                              [raw : String
                                (intern.intern-compat-state-str
                                  (& interns)
                                  prov-sym)]
                              (if (and
                                windows?
                                (ast.ast-extern-abi-c? prov-abi))
                                (abi.compiler-abi-c-export-body-symbol raw)
                                raw))])
                        (let
                          [rt-sym : String
                            (be_operand.compiler-backend-runtime-prelude-string-helper-symbol
                              (string.copy (& fn-name-str)))]
                          (if (> (string.string-length (& rt-sym)) 0)
                            rt-sym
                            (be_state.compiler-backend-user-symbol-uncached
                              (string.copy (& fn-name-str))))))]
                    [link-sym-id : i64
                      (tli-partition-intern-symbol! (&mut interns) link-sym-str)]
                    (set!
                      (array-ref fn-cross-externs i)
                      (ir.CompilerIrExtern.Extern
                        fn-name
                        fn-name
                        fn-name-str
                        fn-sig
                        (ast.AstExternAbi.TypeLisp)
                        link-sym-id
                        (ast.ast-extern-link-input-list-new)
                        false
                        (ir.CompilerIrReturnStorage.None))))]))
            (for [i (iterator.range 0 gl-count)]
              (when
                (not (array-ref gl-private i))
                (match (& (array-ref whole-globals.slots i))
                  [(ir.CompilerIrGlobal.Global gl-name gl-ty _)
                    (let
                      [gl-name-str : String
                        (ir.compiler-ir-symbol-text gl-name)]
                      [link-sym-str : String
                        (be_state.compiler-backend-user-symbol-uncached
                          (string.copy (& gl-name-str)))]
                      [link-sym-id : i64
                        (tli-partition-intern-symbol!
                          (&mut interns)
                          link-sym-str)]
                      (set!
                        (array-ref gl-cross-externs i)
                        (ir.CompilerIrExtern.Extern
                          gl-name
                          gl-name
                          gl-name-str
                          (ir.compiler-ir-clone-type
                            pools
                            (ast.ty-node-persist gl-ty))
                          (ast.AstExternAbi.TypeLisp)
                          link-sym-id
                          (ast.ast-extern-link-input-list-new)
                          false
                          (ir.CompilerIrReturnStorage.None))))])))
            ;; Emit each non-empty module independently.
            (for [m (iterator.range 0 module-count)]
              (let
                [mod-name (& (array-ref sorted-names m))]
                [g-builder : ir.CompilerIrGlobalBuilder
                  (ir.compiler-ir-global-builder-with-capacity 16)]
                [f-builder : ir.CompilerIrFunctionBuilder
                  (ir.compiler-ir-function-builder-with-capacity 32)]
                (for [i (iterator.range 0 gl-count)]
                  (when
                    (= (array-ref gl-owners i) m)
                    (ir.compiler-ir-global-builder-push!
                      (&mut g-builder)
                      (ir.compiler-ir-clone-global
                        pools
                        (& (array-ref whole-globals.slots i))))))
                (for [i (iterator.range 0 fn-count)]
                  (when
                    (and
                      (= (array-ref fn-owners i) m)
                      (not (array-ref fn-skip i)))
                    (ir.compiler-ir-function-builder-push!
                      (&mut f-builder)
                      (ir.compiler-ir-clone-function
                        pools
                        (& (array-ref whole-functions.slots i))))))
                (if (and (= g-builder.len 0) (= f-builder.len 0))
                  (+= skipped-modules 1)
                  (let
                    [be-state-mod : be_state.CompilerBackendState
                      (be_state.compiler-backend-state-new
                        (intern.intern-compat-state-capture-active))]
                    [init-globals : ir.CompilerIrGlobalSeq
                      (ir.compiler-ir-global-builder-snapshot-seq (& g-builder))]
                    [mod-functions : ir.CompilerIrFunctionSeq
                      (ir.compiler-ir-function-builder-snapshot (& f-builder))]
                    [refs : TliPartitionModuleRefs
                      (tli-partition-collect-module-refs
                        pools
                        (& init-globals)
                        (& mod-functions))]
                    [e-builder : ir.CompilerIrExternBuilder
                      (ir.compiler-ir-extern-builder-with-capacity 64)]
                    [added-externs : i64_map.Map (i64_map.with-capacity 128)]
                    ;; Copy any referenced private (nullary enum) globals locally.
                    (for [i (iterator.range 0 gl-count)]
                      (when
                        (and
                          (!= (array-ref gl-owners i) m)
                          (array-ref gl-private i))
                        (match (& (array-ref whole-globals.slots i))
                          [(ir.CompilerIrGlobal.Global gl-name _ _)
                            (when
                              (tli-partition-module-refs-contains?
                                (& refs)
                                gl-name)
                              (ir.compiler-ir-global-builder-push!
                                (&mut g-builder)
                                (ir.compiler-ir-clone-global
                                  pools
                                  (& (array-ref whole-globals.slots i)))))])))
                    ;; 1. Keep provided externs owned by this module.
                    (for [i (iterator.range 0 fn-count)]
                      (when
                        (and
                          (= (array-ref fn-owners i) m)
                          (not (array-ref fn-skip i)))
                        (match (& (array-ref whole-functions.slots i))
                          [(ir.CompilerIrFunction.Function fn-name _ _ _ _ _)
                            (let
                              [pidx : i64
                                (i64_map.get-value-or
                                  (& provided-by-fn)
                                  (ir.compiler-ir-symbol-id fn-name)
                                  -1)]
                              (when
                                (>= pidx 0)
                                (i64_map.insert-ref!
                                  (&mut added-externs)
                                  (ir.compiler-ir-symbol-id fn-name)
                                  1)
                                (ir.compiler-ir-extern-builder-push!
                                  (&mut e-builder)
                                  (ir.compiler-ir-clone-extern
                                    pools
                                    (& (array-ref whole-externs.slots pidx))))))])))
                    ;; 2. Keep referenced base non-provided externs (e.g. C FFI).
                    (for [i (iterator.range 0 ex-count)]
                      (match (& (array-ref whole-externs.slots i))
                        [(ir.CompilerIrExtern.Extern
                            name-id
                            src-id
                            _
                            _
                            _
                            link-id
                            _
                            provided
                            _)
                          (when
                            (and
                              (not provided)
                              (not
                                (i64_map.contains?
                                  (& added-externs)
                                  (ir.compiler-ir-symbol-id name-id)))
                              (or
                                (tli-partition-module-refs-contains?
                                  (& refs)
                                  name-id)
                                (tli-partition-module-refs-contains?
                                  (& refs)
                                  src-id)
                                (tli-partition-module-refs-contains?
                                  (& refs)
                                  link-id)))
                            (i64_map.insert-ref!
                              (&mut added-externs)
                              (ir.compiler-ir-symbol-id name-id)
                              1)
                            (ir.compiler-ir-extern-builder-push!
                              (&mut e-builder)
                              (ir.compiler-ir-clone-extern
                                pools
                                (& (array-ref whole-externs.slots i)))))]))
                    ;; 3. Other modules' functions referenced by this module.
                    (for [i (iterator.range 0 fn-count)]
                      (when
                        (!= (array-ref fn-owners i) m)
                        (match (& (array-ref whole-functions.slots i))
                          [(ir.CompilerIrFunction.Function fn-name _ _ _ _ _)
                            (let
                              [fid : i64 (ir.compiler-ir-symbol-id fn-name)]
                              (when
                                (and
                                  (tli-partition-module-refs-contains?
                                    (& refs)
                                    fn-name)
                                  (not
                                    (i64_map.contains? (& added-externs) fid)))
                                (i64_map.insert-ref! (&mut added-externs) fid 1)
                                (ir.compiler-ir-extern-builder-push!
                                  (&mut e-builder)
                                  (ir.compiler-ir-clone-extern
                                    pools
                                    (& (array-ref fn-cross-externs i))))))])))
                    ;; 4. Other modules' non-private globals referenced by this module.
                    (for [i (iterator.range 0 gl-count)]
                      (when
                        (and
                          (!= (array-ref gl-owners i) m)
                          (not (array-ref gl-private i)))
                        (match (& (array-ref whole-globals.slots i))
                          [(ir.CompilerIrGlobal.Global gl-name _ _)
                            (let
                              [gid : i64 (ir.compiler-ir-symbol-id gl-name)]
                              (when
                                (and
                                  (tli-partition-module-refs-contains?
                                    (& refs)
                                    gl-name)
                                  (not
                                    (i64_map.contains? (& added-externs) gid)))
                                (i64_map.insert-ref! (&mut added-externs) gid 1)
                                (ir.compiler-ir-extern-builder-push!
                                  (&mut e-builder)
                                  (ir.compiler-ir-clone-extern
                                    pools
                                    (& (array-ref gl-cross-externs i))))))])))
                    (let
                      [mod-globals : ir.CompilerIrGlobalSeq
                        (ir.compiler-ir-global-builder-snapshot-seq
                          (& g-builder))]
                      [mod-externs : ir.CompilerIrExternSeq
                        (ir.compiler-ir-extern-builder-snapshot-seq
                          (& e-builder))]
                      [claims : ir.CompilerIrReturnStorageIndex
                        (ir.compiler-ir-return-storage-index-claims
                          type-segment-bases
                          (ir.compiler-ir-type-pool-count pools)
                          (& mod-functions)
                          (& mod-externs))]
                      [authority : ir.CompilerIrReturnStorageAuthority
                        (ir.compiler-ir-return-storage-authority-capture
                          pools
                          (& interns)
                          (if windows?
                            1
                            0)
                          claims)]
                      [mod-program : ir.CompilerIrProgram
                        (ir.CompilerIrProgram.Program
                          mod-globals
                          mod-functions
                          mod-externs
                          authority)]
                      [prof : profile_state.CompilerProfileState
                        (profile_state.compiler-profile-state-new)]
                      [mod-reps : ir.CompilerIrRepresentationIndex
                        (ir.compiler-ir-representation-index-with-authority
                          pools
                          (& interns)
                          (if windows?
                            1
                            0)
                          (& mod-program)
                          (ir.compiler-ir-clone-representation-index
                            pools
                            (& base-reps)))]
                      (be_state.compiler-backend-state-set-opt-level!
                        be-state-mod
                        opt-level)
                      (be_state.compiler-backend-state-set-representations-for-pools!
                        be-state-mod
                        (& pools)
                        (ir.compiler-ir-clone-representation-index
                          pools
                          (& mod-reps)))
                      (match (opt.optimize-program
                        mod-program
                        (ir.compiler-source-spans-escape (& whole-spans))
                        (opt.OptimizeRequest
                          pools
                          (intern.intern-compat-state-capture-active)
                          opt-level
                          prof
                          true
                          mod-reps
                          (opt.OptInputRetirement.Retain)
                          (__tl_make-array i64 0)))
                        [(opt.CompilerOptimizedProgram.Program
                            opt-program
                            opt-spans)
                          (match (backend.compiler-backend-emit-program-target-with-mode-with-pools-and-crt-and-profile-state-backend-state
                            be-state-mod
                            pools
                            opt-program
                            backend-target
                            backend-mode
                            opt-spans
                            false
                            false
                            prof)
                            [(Err diag-box)
                              (backend.compiler-backend-state-release-final-arenas!
                                be-state-mod)
                              (return
                                (Err
                                  (str_cat.str-cat
                                    "tli-partition: backend failed for module "
                                    (string.copy mod-name)
                                    ": "
                                    (diag.compiler-diagnostic-render
                                      (& (__tl-box-place diag-box))))))]
                            [(Ok asm)
                              (let
                                [sep : String
                                  (if is-stdlib?
                                    "-"
                                    "_")]
                                [file-name : String
                                  (str_cat.str-cat
                                    (tli-partition-pad3 m)
                                    sep
                                    (tli-partition-sanitize-module-filename
                                      mod-name)
                                    ".s")]
                                [asm-path : String
                                  (fs.path-join asm-dir (& file-name))]
                                [final-asm : String
                                  (if (and
                                    (not windows?)
                                    (not is-stdlib?)
                                    (not
                                      (string.contains
                                        (& asm)
                                        ".note.GNU-stack")))
                                    (str_cat.str-cat
                                      asm
                                      (tli-partition-noexecstack-note))
                                    asm)]
                                (match (io.try-write-file
                                  (& asm-path)
                                  (byte_buf.str-as-bytes (& final-asm)))
                                  [(OkIoUnit) unit]
                                  [(ErrIoUnit _)
                                    (backend.compiler-backend-state-release-final-arenas!
                                      be-state-mod)
                                    (return
                                      (Err
                                        (str_cat.str-cat
                                          "cannot write module asm: "
                                          asm-path)))])
                                (strings.push-ref!
                                  (&mut emitted-files)
                                  (string.copy (& file-name)))
                                (set!
                                  manifest-buf
                                  (text_buf.append
                                    (text_buf.append manifest-buf file-name)
                                    "\n"))
                                (+= emitted-modules 1))])])
                      (backend.compiler-backend-state-release-final-arenas!
                        be-state-mod))))))
            (when
              (> (string.string-length manifest-out) 0)
              (let
                [manifest-text : String (text_buf.render manifest-buf)]
                (match (io.try-write-file
                  manifest-out
                  (byte_buf.str-as-bytes (& manifest-text)))
                  [(OkIoUnit) unit]
                  [(ErrIoUnit _)
                    (return
                      (Err
                        (str_cat.str-cat
                          "cannot write manifest: "
                          (string.copy manifest-out))))])))
            (let
              [out-count : i64 (strings.len (& emitted-files))]
              [out-arr : (__tl_dyn-array String)
                (__tl_make-array String out-count)]
              (for [i (iterator.range 0 out-count)]
                (set!
                  (array-ref out-arr i)
                  (strings.get (& emitted-files) i "")))
              (Ok
                (TliPartitionedEmitResult
                  out-arr
                  emitted-modules
                  skipped-modules)))))])))