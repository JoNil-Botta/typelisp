;; Stage 1 producer. The checked context and its process-local IDs stay here.
(import compiler_tli_types as tli)
(import compiler_tli_codec as codec)
(import compiler_ast_types as ast)
(import compiler_symbols as symbols)
(import compiler_typecheck_api as api)
(import compiler_typecheck_core as tc)
(import compiler_global_effects as effects)
(import compiler_ctfe as ctfe)
(import compiler_intern as intern)
(import compiler_diagnostic as diag)
(import compiler_lower as lower)
(import compiler_ir_types as ir)
(import compiler_cfg_core as cfg_core)
(import sym_i64_env)
(import stdlib.math)
(import stdlib.byte_buf)
(import stdlib.byte_buf_core as buf)
(import stdlib.byte_le as le)
(import stdlib.crypto_sha256 as sha)
(import stdlib.iterator)
(import stdlib.io)
(import stdlib.str_cat)
(import stdlib.string)
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
(cfg
  embedded-stdlib-tlci
  (import compiler_embedded_stdlib_tlci_payload as tlci_payload))

(defstruct TliSource
  (module-name String)
  (path String)
  (digest (Array u8 32)))

(defstruct TliExtractModule
  (flags i64)
  (imports imports.Vec)
  (inits strings.Vec)
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
  (let
    [snapshot : cfg_core.CompilerCfgSnapshot
      (cfg_core.compiler-cfg-snapshot-from-env cfgs)]
    [out : buf.ByteBufBuilder (buf.byte-buf-builder-new)]
    (for [index (iterator.range 0 snapshot.len)]
      (let
        [name (& (array-ref snapshot.slots index))]
        (le.push-u64! (&mut out) (string.string-length name))
        (buf.byte-buf-builder-append-string (&mut out) (string.copy name))
        (le.push-u64! (&mut out) (array-ref snapshot.values index))))
    (let
      [owner : byte_buf.ByteBuf
        (byte_buf.from-array (buf.byte-buf-builder-finish-array (& out)))]
      (tli-extract-sha256 (byte_buf.as-bytes (& owner))))))

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

(define (tli-extract-types [ctx : tc.TcContext] [items : (& ast.AstTypeList)]) : (__tl_dyn-array
    tli.TliType)
  (let
    [out : (__tl_dyn-array tli.TliType) (__tl_make-array tli.TliType items.len)]
    (for [index (iterator.range 0 items.len)]
      (set!
        (array-ref out index)
        (tli-extract-child ctx (array-ref items.slots index))))
    out))

(define (tli-extract-child [ctx : tc.TcContext] [id : i64]) : tli.TliType
  (tli-extract-type ctx (tc.tc-context-type-get ctx id)))

(define (tli-extract-type [ctx : tc.TcContext] [ty : ast.AstType]) : tli.TliType
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
    [(DynArray elem) (tli.TliType.DynArray (box (tli-extract-child ctx elem)))]
    [(Box elem) (tli.TliType.Box (box (tli-extract-child ctx elem)))]
    [(Ptr elem) (tli.TliType.Ptr (box (tli-extract-child ctx elem)))]
    [(MutPtr elem) (tli.TliType.MutPtr (box (tli-extract-child ctx elem)))]
    [(Slice elem) (tli.TliType.Slice (box (tli-extract-child ctx elem)))]
    [(Region life inner)
      (tli.TliType.Region
        (tli-extract-name life)
        (box (tli-extract-child ctx inner)))]
    [(Ref life inner)
      (tli.TliType.Ref
        (tli-extract-name life)
        (box (tli-extract-child ctx inner)))]
    [(MutRef life inner)
      (tli.TliType.MutRef
        (tli-extract-name life)
        (box (tli-extract-child ctx inner)))]
    [(Invalidate life inner)
      (tli.TliType.Invalidate
        (tli-extract-name life)
        (box (tli-extract-child ctx inner)))]
    [(Enum nominal) (tli.TliType.Enum (tli-extract-name nominal))]
    [(EnumArgs nominal lives)
      (tli.TliType.EnumArgs
        (tli-extract-name nominal)
        (tli-extract-lifetimes (& (__tl-box-place lives))))]
    [(Struct nominal) (tli.TliType.Struct (tli-extract-name nominal))]
    [(StructArgs nominal lives)
      (tli.TliType.StructArgs
        (tli-extract-name nominal)
        (tli-extract-lifetimes (& (__tl-box-place lives))))]
    [(Var nominal) (tli.TliType.Var (tli-extract-name nominal))]
    [(VarArgs nominal lives)
      (tli.TliType.VarArgs
        (tli-extract-name nominal)
        (tli-extract-lifetimes (& (__tl-box-place lives))))]
    [(Func params ret)
      (tli.TliType.Func
        (tli-extract-types ctx (& (__tl-box-place params)))
        (box (tli-extract-child ctx ret)))]
    [(Tuple items)
      (tli.TliType.Tuple (tli-extract-types ctx (& (__tl-box-place items))))]
    [(Array elem count)
      (tli.TliType.Array (box (tli-extract-child ctx elem)) count)]
    [(CFunc signature mode)
      (tli.TliType.CFunc
        (box (tli-extract-child ctx signature))
        (ast.ast-c-function-mode-key mode))]))

(define (tli-extract-cleanup-symbol
  [ctx : tc.TcContext]
  [name : intern.InternSyntaxId]) : tli.TliCleanup
  (let
    [raw : i64 (intern.intern-syntax-id-value name)]
    [handle : i64 (tc.tc-global-effect-handle ctx tc.TcNameIdList.Nil raw)]
    [kind : i64 (symbols.compiler-symbol-handle-kind handle)]
    (tli.TliCleanup.Fn
      (if (and
        (symbols.compiler-symbols-handle-found? handle)
        (or
          (= kind (symbols.compiler-symbol-kind-function-define))
          (= kind (symbols.compiler-symbol-kind-extern))))
        (tli-extract-symbol-at
          ctx
          (symbols.compiler-symbol-handle-index handle))
        (tc.macro-tlci-catalog-identity
          (string.copy (tc.tc-context-module ctx))
          (tli-extract-name raw))))))

(define (tli-extract-fields
  [ctx : tc.TcContext]
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
                (tli-extract-type ctx ty)
                (match cleanup
                  [(Fn fn-name) (tli-extract-cleanup-symbol ctx fn-name)]
                  [(Owned) (tli.TliCleanup.Owned)]
                  [(No) (tli.TliCleanup.No)])
                offset
                alignment)))]))
    (tli.TliTypeBody.Struct out)))

(define (tli-extract-variants
  [ctx : tc.TcContext]
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
                  (tli-extract-child ctx (array-ref items.slots slot))
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
              [(Fn fn-name) (tli-extract-cleanup-symbol ctx fn-name)])]
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
                  (tli-extract-fields ctx fields offsets fields-align)))]))]
      [_ (io.panic "TLI expected a checked struct layout")])))

(define (tli-extract-enum!
  [out : (&mut types.Vec)]
  [ctx : tc.TcContext]
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
        (types.push-ref!
          out
          (tli-extract-type-row
            module-name
            name
            flags
            lifetimes
            (match cleanup
              [(No) (tli.TliCleanup.No)]
              [(Fn fn-name) (tli-extract-cleanup-symbol ctx fn-name)])
            size
            alignment
            0
            0
            (tli-extract-variants ctx variants)))]
      [_ (io.panic "TLI expected a checked enum layout")])))

(defstruct TliExtractEffects
  (globals (__tl_dyn-array writes.Vec))
  (indirect (__tl_dyn-array i64))
  (global-arena (__tl_dyn-array i64))
  (param-arena (__tl_dyn-array i64))
  (param-calls (__tl_dyn-array (__tl_dyn-array i64))))

(define (tli-extract-effects [ctx : tc.TcContext]) : TliExtractEffects
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
      [param-calls : (__tl_dyn-array (__tl_dyn-array i64))
        (__tl_make-array (__tl_dyn-array i64) 0)]
      [param-limit : i64 0]
      (for [index (iterator.range 0 count)]
        (set! (array-ref global-writes index) (writes.new))
        (match (symbols.compiler-symbols-decl-at-index
          (tc.tc-context-symbols (& ctx))
          index)
          [(Ok decl)
            (match (ast.ast-decl-unwrapped (& decl))
              [(DefFn _ _ params _ _ _)
                (set!
                  param-limit
                  (if (> params.len param-limit)
                    params.len
                    param-limit))]
              [_ unit])]
          [(Err message) (io.panic message)]))
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
      (set! param-calls (__tl_make-array (__tl_dyn-array i64) param-limit))
      (for [index (iterator.range 0 param-limit)]
        (let
          [key : i64 (tc.tc-arena-store-parameter-key count index)]
          (set!
            (array-ref param-calls index)
            (if (effects.written? (& arena-graph) key)
              (effects.summary! (&mut arena-graph) key)
              (__tl_make-array i64 0)))))
      (TliExtractEffects
        global-writes
        (effects.summary! (&mut graph) count)
        (effects.summary!
          (&mut arena-graph)
          (tc.tc-arena-store-global-key count))
        (effects.summary!
          (&mut arena-graph)
          (tc.tc-arena-store-argument-key count))
        param-calls))))

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
      (let
        [summary (& (array-ref facts.param-calls param))]
        (when
          (and (> (array-length summary) 0) (!= (array-ref summary index) 0))
          (if (< param 64)
            (set! mask (bit-or mask (shl 1 param)))
            (indices.push-ref! (&mut extra) param)))))
    (tli.TliFnSummary
      (+
        (tli-extract-flag unsafe-decl 1)
        (tli-extract-flag comptime-only 2)
        ;; The checked comptime contract establishes purity. Runtime
        ;; declarations have no purity certification.
        (tli-extract-flag (and comptime-only (not unsafe-decl)) 4)
        (tli-extract-flag
          (match ret
            [(Never) true]
            [_ false])
          8)
        (tli-extract-flag (!= (array-ref facts.global-arena index) 0) 16)
        (tli-extract-flag
          (or
            (!= (array-ref facts.indirect index) 0)
            (!= (array-ref facts.param-arena index) 0))
          32)
        (tli-extract-flag must-use 128))
      mask
      (tli-extract-finish-vector i64 extra)
      (tli-extract-copy-writes (& (array-ref facts.globals index)))
      0
      0)))

(define (tli-extract-params
  [ctx : tc.TcContext]
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
              (tli-extract-type ctx ty)
              mut?))]))
    out))

;; Extern ASTs retain parameter types only. The final anonymous parameter
;; carries the homogeneous tail type when the ABI tag is CVarargsTyped.
(define (tli-extract-extern-params
  [ctx : tc.TcContext]
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
          (tli-extract-child ctx (array-ref params.slots index))
          false)))
    (match abi
      [(CVarargsTyped tail)
        (set!
          (array-ref out params.len)
          (tli.TliParam "" (tli-extract-type ctx tail) false))]
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
                (cast (array-ref kinds.slots kind) : u8)))
            (set!
              (array-ref out index)
              (tli.TliMacroParam
                (tli-extract-name name)
                (tli-extract-type ctx ty)
                by-ref
                tags)))]))
    out))

(define (tli-extract-macro
  [ctx : tc.TcContext]
  [module-name : String]
  [name : String]
  [params : (& ast.AstMacroParamList)]
  [ret : ast.AstType]
  [_catalog : (& (Array u8 32))]) : tli.TliMacroHandle
  (let
    [identity : String
      (tc.macro-tlci-catalog-identity
        (string.copy (& module-name))
        (string.copy (& name)))]
    [flags : i64
      (+ 4 (tli-extract-flag (tc.tc-macro-result-decl-emitting? (& ret)) 8))]
    [index : i64 -1]
    [digest : (Array u8 32) (make-array u8 32)]
    (cfg
      embedded-stdlib-tlci
      (match (tlci.compiler-embedded-stdlib-tlci-catalog-lookup
        (string.copy (& identity)))
        [(Resolved entry)
          (set!
            index
            (tlci.compiler-embedded-stdlib-tlci-session-index
              entry.catalog-generation))
          (set! digest (deref _catalog))
          (+= flags 1)]
        [(Shell _)
          (set! digest (deref _catalog))
          (+= flags 2)]
        [_ unit]))
    (tli.TliMacroHandle
      name
      module-name
      identity
      flags
      (tli-extract-macro-params ctx params)
      index
      digest)))

;; A checked (comptime ...) initializer still carries its source node. Run
;; the same evaluator the checker used and retain the scalar result on wire.
(define (tli-extract-initializer
  [ctx : tc.TcContext]
  [names : lower.LowerNameCache]
  [expr : ast.AstExpr]
  [ty : ast.AstType]) : lower.ResultLowerValue
  (match expr
    [(or (Spanned inner _) (MacroExpansion inner _ _) (Ann inner _))
      (tli-extract-initializer ctx names (tc.tc-context-expr-get ctx inner) ty)]
    [(Cast inner cast-ty)
      (tli-extract-initializer
        ctx
        names
        (tc.tc-context-expr-get ctx inner)
        (tc.tc-context-type-get ctx cast-ty))]
    [(Comptime inner)
      (let
        [env : ctfe.CtfeEnv
          (tc.tc-ctfe-env-for-comptime ctx (tc.tc-context-expr-get ctx inner))]
        (match (ctfe.compiler-ctfe-eval
          (& (tc.tc-context-expr-get ctx inner))
          env
          (ctfe.ctfe-fuel-limit))
          [(Ok value _)
            (lower.ResultLowerValue.Ok
              (match value
                [(I64 n) (ir.CompilerIrValue.I64 n)]
                [(or (F64 f) (F32 f))
                  (ir.CompilerIrValue.F64
                    (match (& ty)
                      [(F32) (cast (math.f32-to-bits (cast f : f32)) : u64)]
                      [_ (math.f64-to-bits f)]))]
                [(Bool value) (ir.CompilerIrValue.Bool value)]
                [(Char value) (ir.CompilerIrValue.Char value)]
                [(String value _) (ir.CompilerIrValue.String value)]
                [(Unit) (ir.CompilerIrValue.Unit)]
                [_
                  (return
                    (lower.ResultLowerValue.Err
                      (box
                        (lower.lower-diagnostic
                          "TLI comptime initializer has no scalar payload"))))]))]
          [(Err diagnostic) (lower.ResultLowerValue.Err diagnostic)]))]
    [_ (lower.lower-global-value ctx names expr ty)]))

(define (tli-extract-value!
  [out : (&mut TliExtractModule)]
  [ctx : tc.TcContext]
  [env : tc.TcTypeEnv]
  [names : lower.LowerNameCache]
  [decl : (& ast.AstDecl)]
  [module-name : String]
  [name : i64]
  [expr : i64]
  [flags : i64]) : unit
  (let
    [spelling : String (tli-extract-name name)]
    [symbol : String
      (symbols.compiler-symbol-module-key
        (string.copy (& module-name))
        (string.copy (& spelling)))]
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
    (match (tli-extract-initializer
      ctx
      names
      (tc.tc-context-expr-get ctx expr)
      (tc.tc-type-without-regions (ast.ty-node-persist (& ty))))
      [(Ok value)
        (set! const (tli-extract-const (& value) (ast.ty-node-persist (& ty))))]
      [(Err _) (set! runtime-init (= (bit-and flags 1) 0))])
    (when
      runtime-init
      (set! out.flags (bit-or out.flags 1))
      (strings.push-ref!
        (&mut out.inits)
        (str_cat.str-cat "__global_init_" (string.copy (& symbol)))))
    (values.push-ref!
      (&mut out.values)
      (tli.TliValueDecl
        spelling
        module-name
        symbol
        (tli-extract-type ctx ty)
        (+
          flags
          (tli-extract-flag runtime-init 4)
          (match (& const)
            [(None) 0]
            [_ 8]))
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

;; The checker treats the well-known stdlib.comptime surface as compile-time
;; even though those declarations are written without generated metadata.
(define (tli-extract-comptime? [ctx : tc.TcContext] [decl : (& ast.AstDecl)]) : bool
  (or
    (ast.ast-decl-comptime-only? decl)
    (symbols.compiler-symbols-comptime-module-id? (tc.tc-context-module-id ctx))))

(define (tli-extract-local-fn!
  [out : (&mut TliExtractModule)]
  [ctx : tc.TcContext]
  [module-name : String]
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
      (symbols.compiler-symbol-module-key
        (string.copy (& module-name))
        (string.copy (& spelling)))]
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
        (tli-extract-params ctx (& signature.params))
        (tli-extract-type ctx result)
        summary))))

(define (tli-extract-extern!
  [out : (&mut TliExtractModule)]
  [ctx : tc.TcContext]
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
          (set! out.flags (bit-or out.flags 8))
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
                          (& (__tl-box-place params))
                          abi)
                        (tli-extract-type ctx (ast.ty-node-persist (& result)))
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
                  (tli-extract-type ctx ty)
                  (+
                    (tli-extract-flag comptime-only 1)
                    (tli-extract-flag unsafe-decl 2))
                  (tli.TliConst.None)))]))])))

(define (tli-extract-decl!
  [out : (&mut TliExtractModule)]
  [ctx : tc.TcContext]
  [env : tc.TcTypeEnv]
  [module-name : String]
  [index : i64]
  [unsafe-decl : bool]
  [decl : (& ast.AstDecl)]
  [lower-state : lower.CompilerLowerState]
  [facts : (& facts TliExtractEffects)]
  [catalog : (& (Array u8 32))]) : unit
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
          (lower.lower-name-cache-overlay
            lower-state
            lower.LowerNameEnv.Nil
            (tc.tc-context-module-id ctx))
          decl
          module-name
          name
          expr
          (+
            (tli-extract-flag comptime-only 1)
            (tli-extract-flag unsafe-decl 2)))]
      [(DefFn _ name params ret _ meta)
        (tli-extract-local-fn!
          out
          ctx
          module-name
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
          module-name
          name
          type-flags
          (& lives)
          cleanup
          (& variants))]
      [(DefMacro _ name params ret _)
        (set! out.flags (bit-or out.flags 2))
        (macros.push-ref!
          (&mut out.macros)
          (tli-extract-macro
            ctx
            module-name
            (tli-extract-name name)
            (& params)
            ret
            catalog))]
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
  [tag : i64]) : unit
  (for [index (iterator.range 0 out.len)]
    (let
      [row (& (array-ref out.slots index))]
      (when
        (and (= row.kind tag) (string.eq (& row.module-name) (& name)))
        (return unit))))
  (imports.push-ref! out (tli.TliImport name tag (make-array u8 32))))

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
            owner
            expr-bases)]
        [(Import _ spec)
          (let
            [slot : i64
              (tli-extract-find-module
                sources
                (& (tli-extract-module-name current)))]
            (when
              (>= slot 0)
              (match (& spec)
                [(Spec kind path expected _ _)
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
                        tag)))])))]
        [_ unit]))))

(define (tli-extract-finish-module
  [source : (& TliSource)]
  [path : String]
  [cfg-digest : (& (Array u8 32))]
  [record : TliExtractModule]) : tli.TliModuleRecord
  (match record
    [(TliExtractModule flags imps inits tys fns vals macs disps)
      (tli.TliModuleRecord
        (string.copy (& source.module-name))
        path
        source.digest
        (deref cfg-digest)
        flags
        (tli-extract-finish-vector tli.TliImport imps)
        (tli-extract-finish-vector String inits)
        (tli-extract-finish-vector tli.TliTypeDecl tys)
        (tli-extract-finish-vector tli.TliFnDecl fns)
        (tli-extract-finish-vector tli.TliValueDecl vals)
        (tli-extract-finish-vector tli.TliMacroHandle macs)
        (tli-extract-finish-vector tli.TliDispatchDecl disps))]))

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
        (set!
          (array-ref records slot)
          (TliExtractModule
            (tli-extract-flag
              (or
                (string.eq path "stdlib/runtime.tl")
                (string.eq path "stdlib/core_macros.tl"))
              16)
            (imports.new)
            (strings.new)
            (types.new)
            (functions.new)
            (values.new)
            (macros.new)
            (dispatches.new)))))
    (match (& request.program)
      [(Program decls)
        (tli-extract-imports!
          (&mut records)
          sources
          (& (deref decls))
          (symbols.compiler-symbol-root-module-id)
          (ast.ast-node-pool-context-expr-segment-bases (& request.pools)))])
    records))

;; Hash a dependency with the same pool and record encoding the final bundle
;; uses. Visiting dependencies first makes every in-bundle import pin exact.
;; Imports outside the requested source set have no interface artifact here.
(define (tli-extract-pin-module!
  [ctx : (&mut ctx codec.TliWriteContext)]
  [modules : (&mut modules (__tl_dyn-array tli.TliModuleRecord))]
  [sources : (& sources (__tl_dyn-array TliSource))]
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
              (tli-extract-find-module
                sources
                (&
                  (array-ref (array-ref modules slot).imports index).module-name))]
            (when
              (>= target 0)
              (unless
                (tli-extract-pin-module!
                  ctx
                  modules
                  sources
                  states
                  digests
                  target)
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

(define (tli-extract-pin-imports!
  [bundle : (&mut bundle tli.TliBundle)]
  [sources : (& sources (__tl_dyn-array TliSource))]) : bool
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
          sources
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
    [facts : TliExtractEffects (tli-extract-effects ctx)]
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
    [catalog : (Array u8 32)
      (cfg
        embedded-stdlib-tlci
        (codec.tli-module-digest
          (& tlci_payload.embedded-stdlib-tlci-bytes)
          0
          (array-length tlci_payload.embedded-stdlib-tlci-bytes))
        (make-array u8 32))]
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
      (symbols.compiler-symbol-root-module-id)
      (tc.tc-context-expr-segment-bases ctx))
    (when
      (!=
        (tli-extract-unsafe-decls! (&mut unsafe-decls) (& decls) 0)
        decl-count)
      (io.panic "TLI source and symbol declaration indices disagree"))
    (for [index
      (iterator.range
        0
        (symbols.compiler-symbols-decl-count (tc.tc-context-symbols (& ctx))))]
      (let
        [module-id : i64 (tli-extract-owner ctx index)]
        [module-name : String (tli-extract-module-name module-id)]
        [slot : i64 (tli-extract-find-module sources (& module-name))]
        (when
          (>= slot 0)
          (when
            (= (string.string-length (& (array-ref paths-out slot))) 0)
            (set!
              (array-ref paths-out slot)
              (symbols.compiler-symbol-path-at-index (& decls) paths index 0)))
          (match (symbols.compiler-symbols-decl-at-index
            (tc.tc-context-symbols (& ctx))
            index)
            [(Ok decl)
              (tli-extract-decl!
                (&mut (array-ref records slot))
                (tc.tc-context-with-nominal-owner-index-module ctx index)
                env
                module-name
                index
                (array-ref unsafe-decls index)
                (& decl)
                lower-state
                (& facts)
                (& catalog))]
            [(Err message) (io.panic message)]))))
    (for [slot (iterator.range 0 count)]
      (set!
        (array-ref modules slot)
        (tli-extract-finish-module
          (& (array-ref sources slot))
          (string.copy (& (array-ref paths-out slot)))
          cfg-digest
          (tuple-ref (__tl_array-take! records live slot) 1))))
    (tc.tc-global-call-effects-finish! (tc.tc-context-job-state ctx))
    (tli.TliBundle bundle-flags build target modules)))

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
    (match (api.typecheck-compiler-request-checked request)
      [(Ok _ ctx env paths)
        (let
          [bundle : tli.TliBundle
            (tli-extract-checked
              ctx
              env
              (& paths)
              sources
              records
              (& cfg-digest)
              bundle-flags
              build
              target)]
          (if (tli-extract-pin-imports! (&mut bundle) sources)
            (Ok bundle)
            (Err "TLI import cycle cannot pin module record digests")))]
      [(or (Partial diagnostics _ _ _) (Err diagnostics))
        (Err
          (diag.compiler-diagnostic-render
            (&
              (diag.compiler-diagnostic-list-first
                (& (__tl-box-place diagnostics))))))])))