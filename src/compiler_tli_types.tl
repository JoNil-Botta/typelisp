(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)

;; Portable semantic interfaces. Offsets are absolute; u64 wire fields other
;; than offsets and lengths are stored as their full i64 bit patterns.
(define tli-magic : i64
  0x00494c54)
(define tli-schema-version : i64
  2)
(define tli-header-size : i64
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
  (explicit-align i64))

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
(define tli-fn-stores-ambient-arena-arg : i64
  256)

(defstruct TliFnSummary
  (effect-flags i64)
  (arena-arg-store-mask i64)
  (arena-arg-store-extra (__tl_dyn-array i64))
  (global-writes (__tl_dyn-array TliGlobalWrite))
  (inline-ir-offset i64)
  (inline-ir-len i64))

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
  (flags i64))

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

(defstruct TliBundle
  (flags i64)
  (compiler-build String)
  (target-triple String)
  (modules (__tl_dyn-array TliModuleRecord)))

(defstruct TliDirectoryEntry
  (name String)
  (flags i64)
  (record-offset i64)
  (record-len i64)
  (module-sha256 (Array u8 32)))

;; Shared spelling for the interface producer and the archive producer.
(define (tli-module-init-symbol [module-name : (& str)]) : String
  (str_cat.str-cat "__tl_mod_init_" (string.copy module-name)))