(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)

;; Portable semantic interfaces. Offsets are absolute; u64 wire fields other
;; than offsets and lengths are stored as their full i64 bit patterns.
(define tli-magic : i64
  0x00494c54)
(define tli-schema-version : i64
  5)
(define tli-header-size : i64
  144)

;; `content_sha256` lies at [80..112] and `index_sha256` at [112..144].
(define tli-content-digest-offset : i64
  80)
(define tli-index-digest-offset : i64
  112)
(define tli-directory-entry-size : i64
  56)
(define tli-max-type-depth : i64
  64)
(define tli-is-stdlib-bundle : i64
  1)
(define tli-has-compact-ir : i64
  2)
(define tli-has-tlci-companion : i64
  4)

(defenum TliDecodeError
  (Magic)
  (SchemaVersion)
  (Flags)
  (Truncated)
  (OffsetOutOfRange)
  (Overlap)
  (Utf8)
  (Limit)
  (StringIdOutOfRange)
  (UnknownTag)
  (DigestMismatch)
  (CfgFingerprintMismatch)
  (CompilerBuildMismatch)
  (TargetMismatch)
  (TrailingBytes))

(defstruct TliDecodeFailure
  (kind TliDecodeError)
  (offset i64)
  (message String))

(defenum TliType
  (I64)
  (I32)
  (I16)
  (I8)
  (U64)
  (U32)
  (U16)
  (U8)
  (F64)
  (F32)
  (Bool)
  (Char)
  (String)
  (Str)
  (Bytes)
  (Unit)
  (Never)
  (Expr)
  (ExprList)
  (Func (__tl_dyn-array TliType) (Box TliType))
  (Tuple (__tl_dyn-array TliType))
  (Array (Box TliType) i64)
  (DynArray (Box TliType))
  (Box (Box TliType))
  (Region String (Box TliType))
  (Ref String (Box TliType))
  (MutRef String (Box TliType))
  (Enum String)
  (EnumArgs String (__tl_dyn-array String))
  (Struct String)
  (StructArgs String (__tl_dyn-array String))
  (Var String)
  (VarArgs String (__tl_dyn-array String))
  (Ptr (Box TliType))
  (MutPtr (Box TliType))
  (Slice (Box TliType))
  (CFunc (Box TliType) i64)
  (Invalidate String (Box TliType)))

(defenum TliCleanup
  (No)
  (Fn String)
  (Owned))

(defstruct TliField
  (name String)
  (ty TliType)
  (cleanup TliCleanup)
  (byte-offset i64)
  (explicit-align i64)
  (opaque? bool))

(defstruct TliPayload
  (ty TliType)
  (cleanup TliCleanup))

(defstruct TliVariant
  (name String)
  (payloads (__tl_dyn-array TliPayload)))

(defenum TliTypeBody
  (Struct (__tl_dyn-array TliField))
  (Enum (__tl_dyn-array TliVariant)))

(defstruct TliTypeDecl
  (name String)
  (module-name String)
  (flags i64)
  (layout-size i64)
  (layout-align i64)
  (repr-kind i64)
  (repr-align i64)
  (cleanup TliCleanup)
  (lifetimes (__tl_dyn-array String))
  (body TliTypeBody))

(defstruct TliImport
  (module-name String)
  (kind i64)
  (alias String)
  (item String)
  (interface-sha256 (Array u8 32)))

(defstruct TliExternLinkInput
  (kind i64)
  (name String))

(defstruct TliParam
  (name String)
  (ty TliType)
  (is-mut bool))

(defstruct TliGlobalWrite
  (symbol String)
  (flags u8))

(define tli-fn-has-indirect-effects : i64
  32)
(define tli-fn-has-inline-ir : i64
  64)
(define tli-fn-must-use : i64
  128)
(define tli-fn-stores-ambient-arena-arg : i64
  256)
(define tli-fn-spmd-inlineable : i64
  512)
(define tli-fn-no-module-inits : i64
  1024)
(define tli-fn-cold : i64
  2048)
(define tli-fn-effect-flags-mask : i64
  4095)
(define tli-macro-uses-expr-type : i64
  16)
(define tli-compact-body-has-ir : i64
  1)
(define tli-compact-body-has-spmd-expr : i64
  2)
(define tli-compact-global-never-written : i64
  1)
(define tli-compact-ir-call-free : i64
  1)
(define tli-max-spmd-expr-depth : i64
  64)

(defstruct TliFnSummary
  (effect-flags i64)
  (arena-arg-store-mask i64)
  (arena-arg-store-extra (__tl_dyn-array i64))
  (global-writes (__tl_dyn-array TliGlobalWrite))
  (call-memory i64)
  (call-clean u8)
  (return-alias i64)
  (inline-ir-offset i64)
  (inline-ir-len i64)
  (inline-ir-sha256 (Array u8 32)))

(defstruct TliFnDecl
  (name String)
  (module-name String)
  (link-symbol String)
  (abi i64)
  (meta-kind i64)
  (export-symbol String)
  (is-extern bool)
  (extern-flags i64)
  (extern-link-inputs (__tl_dyn-array TliExternLinkInput))
  (params (__tl_dyn-array TliParam))
  (return-type TliType)
  (summary TliFnSummary))

(defenum TliConst
  (None)
  (I64 i64)
  (U64 i64)
  (F64Bits i64)
  (Bool bool)
  (String String)
  (Bytes (__tl_dyn-array u8)))

(defstruct TliValueDecl
  (name String)
  (module-name String)
  (link-symbol String)
  (ty TliType)
  (flags i64)
  (is-extern bool)
  (extern-link-inputs (__tl_dyn-array TliExternLinkInput))
  (const-value TliConst))

(defstruct TliMacroParam
  (name String)
  (ty TliType)
  (is-by-ref bool)
  (type-kinds (__tl_dyn-array u8)))

(defstruct TliMacroHandle
  (name String)
  (module-name String)
  (identity String)
  (flags i64)
  (result-kind u8)
  (params (__tl_dyn-array TliMacroParam))
  (tlci-entry-index i64)
  (tlci-catalog-sha256 (Array u8 32)))

(defstruct TliDispatchDecl
  (name String)
  (module-name String)
  (link-symbol String)
  (flags i64)
  (signature TliType)
  (summary TliFnSummary))

(defstruct TliModuleRecord
  (name String)
  (source-path String)
  (source-sha256 (Array u8 32))
  (cfg-fingerprint-sha256 (Array u8 32))
  (flags i64)
  (imports (__tl_dyn-array TliImport))
  (global-inits (__tl_dyn-array String))
  (types (__tl_dyn-array TliTypeDecl))
  (functions (__tl_dyn-array TliFnDecl))
  (values (__tl_dyn-array TliValueDecl))
  (macros (__tl_dyn-array TliMacroHandle))
  (dispatches (__tl_dyn-array TliDispatchDecl)))

(defenum TliCompactValue
  (Var i64)
  (Global String)
  (GlobalAddr String)
  (Function String)
  (I64 i64)
  (F64Bits i64)
  (Bool bool)
  (Char i64)
  (String String)
  (StrDesc String)
  (Bytes (__tl_dyn-array u8))
  (Unit)
  (StaticArray (__tl_dyn-array u8)))

(defstruct TliCompactCallArgs
  (args (__tl_dyn-array TliCompactValue))
  (sret-index i64))

(defenum TliCompactBinOp
  (Add)
  (Sub)
  (Mul)
  (Div)
  (Mod)
  (SafeDiv)
  (SafeMod)
  (Eq)
  (Ne)
  (Lt)
  (Le)
  (Gt)
  (Ge)
  (BitTestEq)
  (BitTestNe)
  (And)
  (Or)
  (BitAnd)
  (BitOr)
  (BitXor)
  (Shl TliType)
  (Shr TliType)
  (Rotr))

(defenum TliCompactUnOp
  (Neg)
  (Not)
  (BitNot)
  (Sqrt)
  (BitLength))

(defstruct TliCompactPhiInput
  (value TliCompactValue)
  (label i64))

(defstruct TliCompactSwitchCase
  (value i64)
  (label i64))

(defenum TliCompactInstr
  (Mov i64 TliCompactValue TliType)
  (Alloc i64 TliType)
  (AddrOf i64 i64 i64)
  (Gep i64 TliCompactValue TliCompactValue TliType)
  (Load i64 TliCompactValue TliType)
  (StoreOwned TliCompactValue TliCompactValue TliType)
  (StorePtr TliCompactValue TliCompactValue TliType)
  (CopyBytes TliCompactValue TliCompactValue i64)
  (BoundsCheck TliCompactValue TliCompactValue i64)
  (Cast i64 TliCompactValue TliType TliType)
  (Bitcast i64 TliCompactValue TliType TliType)
  (BinOp i64 TliCompactBinOp TliCompactValue TliCompactValue TliType)
  (UnOp i64 TliCompactUnOp TliCompactValue TliType)
  (Call i64 String TliCompactCallArgs TliType)
  (CallIndirect i64 TliCompactValue TliCompactCallArgs TliType)
  (CallIndirectC i64 TliCompactValue TliCompactCallArgs TliType)
  (TailCall String TliCompactCallArgs TliType)
  (Store String TliCompactValue TliType)
  (Jump i64)
  (Branch TliCompactValue i64 i64)
  (TotalEnumBranch TliCompactValue i64 i64)
  (Return bool TliCompactValue)
  (Phi i64 (__tl_dyn-array TliCompactPhiInput) TliType)
  (Pack i64 (__tl_dyn-array TliCompactValue) TliType)
  (Word i64 TliCompactValue i64 TliType)
  (Switch TliCompactValue i64 (__tl_dyn-array TliCompactSwitchCase) i64)
  (TotalEnumSwitch
    TliCompactValue
    i64
    (__tl_dyn-array TliCompactSwitchCase)
    i64
    i64))

(defstruct TliCompactBlock
  (label i64)
  (instrs (__tl_dyn-array TliCompactInstr)))

(defstruct TliCompactParam
  (name String)
  (ty TliType)
  (var-id i64))

(defenum TliCompactReturnStorage
  (None)
  (Some i64 i64 i64 i64 TliType TliType (__tl_dyn-array TliType) TliType))

;; The compact extern ABI and declaration hint share a wire byte.
(define tli-compact-extern-cold-bit : i64
  4)

(defstruct TliCompactExternRef
  (symbol String)
  (abi i64)
  (link-symbol String)
  (ty TliType)
  (return-storage TliCompactReturnStorage)
  (cold? bool))

(defstruct TliCompactIrBody
  (ir-flags i64)
  (instr-count i64)
  (params (__tl_dyn-array TliCompactParam))
  (ret-type TliType)
  (next-var i64)
  (blocks (__tl_dyn-array TliCompactBlock))
  (return-storage TliCompactReturnStorage)
  (extern-refs (__tl_dyn-array TliCompactExternRef)))

(defenum TliSpmdLiteral
  (Int i64 String)
  (Float String)
  (Bool bool)
  (Char i64)
  (String String)
  (Unit))

(defstruct TliSpmdLetBinding
  (name String)
  (has-type bool)
  (ty TliType)
  (init (Box TliSpmdExpr)))

(defenum TliSpmdExpr
  (Literal TliSpmdLiteral)
  (Var String)
  (Unary i64 (Box TliSpmdExpr))
  (Binary i64 (Box TliSpmdExpr) (Box TliSpmdExpr))
  (Call (Box TliSpmdExpr) (__tl_dyn-array TliSpmdExpr))
  (If (Box TliSpmdExpr) (Box TliSpmdExpr) (Box TliSpmdExpr))
  (Let (__tl_dyn-array TliSpmdLetBinding) (Box TliSpmdExpr))
  (Begin (__tl_dyn-array TliSpmdExpr))
  (Ann (Box TliSpmdExpr) TliType)
  (Cast (Box TliSpmdExpr) TliType)
  (ArrayRef (Box TliSpmdExpr) (Box TliSpmdExpr))
  (ArraySet (Box TliSpmdExpr) (Box TliSpmdExpr) (Box TliSpmdExpr))
  (StructGet (Box TliSpmdExpr) String)
  (StructSet (Box TliSpmdExpr) String (Box TliSpmdExpr))
  (Tuple (__tl_dyn-array TliSpmdExpr))
  (TupleRef (Box TliSpmdExpr) i64)
  (Set (Box TliSpmdExpr) (Box TliSpmdExpr))
  (Borrow bool String (Box TliSpmdExpr)))

(defstruct TliCompactBody
  (kind i64)
  (ir-body TliCompactIrBody)
  (spmd-expr TliSpmdExpr))

(defstruct TliCompactBodyEntry
  (module-name String)
  (fn-name String)
  (link-symbol String)
  (body TliCompactBody))

(defstruct TliCompactGlobal
  (symbol String)
  (ty TliType)
  (flags i64)
  (init TliCompactValue))

(define (tli-compact-ir-body-empty) : TliCompactIrBody
  (TliCompactIrBody
    0
    0
    (__tl_make-array TliCompactParam 0)
    (TliType.Unit)
    0
    (__tl_make-array TliCompactBlock 0)
    (TliCompactReturnStorage.None)
    (__tl_make-array TliCompactExternRef 0)))

(define (tli-spmd-expr-empty) : TliSpmdExpr
  (TliSpmdExpr.Literal (TliSpmdLiteral.Unit)))

(defstruct TliBundle
  (flags i64)
  (compiler-build String)
  (target-triple String)
  (modules (__tl_dyn-array TliModuleRecord))
  (compact-globals (__tl_dyn-array TliCompactGlobal))
  (compact-bodies (__tl_dyn-array TliCompactBodyEntry)))

(defstruct TliDirectoryEntry
  (name String)
  (flags i64)
  (record-offset i64)
  (record-len i64)
  (module-sha256 (Array u8 32)))

;; Shared spelling for the interface producer and the archive producer.
(define (tli-module-init-symbol [module-name : (& str)]) : String
  (str_cat.str-cat "__tl_mod_init_" (string.copy module-name)))

;; Canonical wire tags for AstMacroTypeKindList entries (matching the bit
;; positions in `tc-macro-abstract-kind-bit` so `.tli` files never serialize
;; process-local intern string IDs).
(define (tli-macro-type-kind-tag [kind : (& str)]) : u8
  (cast
    (cond
      [(string.eq kind "i64") 0]
      [(string.eq kind "i32") 1]
      [(string.eq kind "i16") 2]
      [(string.eq kind "i8") 3]
      [(string.eq kind "u64") 4]
      [(string.eq kind "u32") 5]
      [(string.eq kind "u16") 6]
      [(string.eq kind "u8") 7]
      [(string.eq kind "f64") 8]
      [(string.eq kind "f32") 9]
      [(string.eq kind "bool") 10]
      [(string.eq kind "char") 11]
      [(string.eq kind "string") 12]
      [(string.eq kind "unit") 13]
      [(string.eq kind "never") 14]
      [(string.eq kind "array") 15]
      [(string.eq kind "dyn-array") 16]
      [(string.eq kind "function") 17]
      [(string.eq kind "tuple") 18]
      [(string.eq kind "struct") 19]
      [(string.eq kind "enum") 20]
      [(string.eq kind "str") 21]
      [(string.eq kind "ptr") 22]
      [(string.eq kind "mut-ptr") 23]
      [(string.eq kind "ref") 24]
      [(string.eq kind "mut-ref") 25]
      [(string.eq kind "region") 26]
      [(string.eq kind "type-var") 27]
      [(string.eq kind "box") 28]
      [(string.eq kind "c-function") 30]
      [(string.eq kind "invalidate") 31]
      [else 29])
    : u8))

(define (tli-macro-type-kind-name [tag : u8]) : String
  (let
    [v : i64 (cast tag : i64)]
    (cond
      [(= v 0) "i64"]
      [(= v 1) "i32"]
      [(= v 2) "i16"]
      [(= v 3) "i8"]
      [(= v 4) "u64"]
      [(= v 5) "u32"]
      [(= v 6) "u16"]
      [(= v 7) "u8"]
      [(= v 8) "f64"]
      [(= v 9) "f32"]
      [(= v 10) "bool"]
      [(= v 11) "char"]
      [(= v 12) "string"]
      [(= v 13) "unit"]
      [(= v 14) "never"]
      [(= v 15) "array"]
      [(= v 16) "dyn-array"]
      [(= v 17) "function"]
      [(= v 18) "tuple"]
      [(= v 19) "struct"]
      [(= v 20) "enum"]
      [(= v 21) "str"]
      [(= v 22) "ptr"]
      [(= v 23) "mut-ptr"]
      [(= v 24) "ref"]
      [(= v 25) "mut-ref"]
      [(= v 26) "region"]
      [(= v 27) "type-var"]
      [(= v 28) "box"]
      [(= v 30) "c-function"]
      [(= v 31) "invalidate"]
      [else "unknown"])))