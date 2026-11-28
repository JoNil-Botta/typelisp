;; Standalone wire tests. Corruptions below refresh the relevant outer digest
;; so they reach the structural check they are intended to exercise.
(import compiler_tli_types as tli)
(import compiler_tli_codec as codec)
(import compiler_incremental_binary as binary)
(import stdlib.byte_le as le)
(import stdlib.byte_buf_core as buf)
(import stdlib.crypto_sha256 as sha256)
(import stdlib.iterator)
(import stdlib.io)
(import stdlib.string)
(import stdlib.test)

(define (tli-test-hash [first : i64]) : (Array u8 32)
  (let
    [hash : (Array u8 32) (make-array u8 32)]
    (set! (array-ref hash 0) (cast first : u8))
    (set! (array-ref hash 31) (cast (+ first 1) : u8))
    hash))

(define (tli-test-lifetimes) : (__tl_dyn-array String)
  (__tl_make-array "z-life" "a-life"))

(define (tli-test-types) : (__tl_dyn-array tli.TliType)
  (__tl_make-array
    (tli.TliType.I64)
    (tli.TliType.I32)
    (tli.TliType.I16)
    (tli.TliType.I8)
    (tli.TliType.U64)
    (tli.TliType.U32)
    (tli.TliType.U16)
    (tli.TliType.U8)
    (tli.TliType.F64)
    (tli.TliType.F32)
    (tli.TliType.Bool)
    (tli.TliType.Char)
    (tli.TliType.String)
    (tli.TliType.Str)
    (tli.TliType.Bytes)
    (tli.TliType.Unit)
    (tli.TliType.Never)
    (tli.TliType.Expr)
    (tli.TliType.ExprList)
    (tli.TliType.Func (__tl_make-array tli.TliType 0) (box (tli.TliType.Unit)))
    (tli.TliType.Tuple (__tl_make-array tli.TliType 0))
    (tli.TliType.Array (box (tli.TliType.U8)) -1)
    (tli.TliType.DynArray (box (tli.TliType.U8)))
    (tli.TliType.Box (box (tli.TliType.U8)))
    (tli.TliType.Region "r" (box (tli.TliType.U8)))
    (tli.TliType.Ref "r" (box (tli.TliType.U8)))
    (tli.TliType.MutRef "s" (box (tli.TliType.U8)))
    (tli.TliType.Enum "fixture.enum")
    (tli.TliType.EnumArgs "fixture.enum" (tli-test-lifetimes))
    (tli.TliType.Struct "fixture.struct")
    (tli.TliType.StructArgs "fixture.struct" (tli-test-lifetimes))
    (tli.TliType.Var "T")
    (tli.TliType.VarArgs "T" (tli-test-lifetimes))
    (tli.TliType.Ptr (box (tli.TliType.U8)))
    (tli.TliType.MutPtr (box (tli.TliType.U8)))
    (tli.TliType.Slice (box (tli.TliType.U8)))
    (tli.TliType.CFunc
      (box
        (tli.TliType.Func
          (__tl_make-array tli.TliType 0)
          (box (tli.TliType.Unit))))
      3)
    (tli.TliType.Invalidate "s" (box (tli.TliType.U8)))))

(define (tli-test-slot [reversed? : bool] [count : i64] [index : i64]) : i64
  (if reversed?
    (- (- count 1) index)
    index))

(define (tli-test-decls [reversed? : bool]) : (__tl_dyn-array tli.TliTypeDecl)
  (let
    [decls : (__tl_dyn-array tli.TliTypeDecl)
      (__tl_make-array tli.TliTypeDecl 2)]
    [fields : (__tl_dyn-array tli.TliField) (__tl_make-array tli.TliField 2)]
    [payloads : (__tl_dyn-array tli.TliPayload)
      (__tl_make-array tli.TliPayload 2)]
    [variants : (__tl_dyn-array tli.TliVariant)
      (__tl_make-array tli.TliVariant 1)]
    (set!
      (array-ref fields 0)
      (tli.TliField "high" (tli.TliType.I64) (tli.TliCleanup.Owned) 0 16 true))
    (set!
      (array-ref fields 1)
      (tli.TliField
        "low"
        (tli.TliType.Ref "z-life" (box (tli.TliType.Str)))
        (tli.TliCleanup.Fn "cleanup.field")
        16
        0
        false))
    (set!
      (array-ref payloads 0)
      (tli.TliPayload (tli.TliType.I32) (tli.TliCleanup.Owned)))
    (set!
      (array-ref payloads 1)
      (tli.TliPayload (tli.TliType.U8) (tli.TliCleanup.Fn "cleanup.payload")))
    (set! (array-ref variants 0) (tli.TliVariant "variant" payloads))
    (set!
      (array-ref decls (tli-test-slot reversed? 2 0))
      (tli.TliTypeDecl
        "fixture.struct"
        "fixture"
        19
        32
        16
        1
        16
        (tli.TliCleanup.Fn "cleanup.type")
        (tli-test-lifetimes)
        (tli.TliTypeBody.Struct fields)))
    (set!
      (array-ref decls (tli-test-slot reversed? 2 1))
      (tli.TliTypeDecl
        "fixture.enum"
        "fixture"
        0
        16
        8
        0
        0
        (tli.TliCleanup.No)
        (__tl_make-array String 0)
        (tli.TliTypeBody.Enum variants)))
    decls))

(define (tli-test-function [reversed? : bool] [abi : i64]) : tli.TliFnDecl
  (let
    [params : (__tl_dyn-array tli.TliParam) (__tl_make-array tli.TliParam 66)]
    [inputs : (__tl_dyn-array tli.TliExternLinkInput)
      (__tl_make-array tli.TliExternLinkInput 3)]
    [extra : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    [writes : (__tl_dyn-array tli.TliGlobalWrite)
      (__tl_make-array tli.TliGlobalWrite 2)]
    (for [i (iterator.range 0 66)]
      (set!
        (array-ref params i)
        (tli.TliParam "param" (tli.TliType.I64) (= i 1))))
    (set! (array-ref inputs 0) (tli.TliExternLinkInput 2 "-lfixture"))
    (set! (array-ref inputs 1) (tli.TliExternLinkInput 0 "fixture"))
    (set! (array-ref inputs 2) (tli.TliExternLinkInput 1 "/fixture"))
    (set! (array-ref extra 0) 64)
    (set! (array-ref extra 1) 65)
    (set!
      (array-ref writes (tli-test-slot reversed? 2 0))
      (tli.TliGlobalWrite "write.z" (cast 2 : u8)))
    (set!
      (array-ref writes (tli-test-slot reversed? 2 1))
      (tli.TliGlobalWrite "write.a" (cast 1 : u8)))
    (tli.TliFnDecl
      "same-name"
      "fixture"
      (string.int->string abi)
      abi
      1
      "export"
      true
      256
      inputs
      params
      (tli.TliType.Never)
      (tli.TliFnSummary
        440
        -9223372036854775807
        extra
        writes
        -1
        (cast 0 : u8)
        0
        0
        0
        (make-array u8 32)))))

(define (tli-test-const [index : i64]) : tli.TliConst
  (match index
    [0 (tli.TliConst.None)]
    [1 (tli.TliConst.I64 -42)]
    [2 (tli.TliConst.U64 -1)]
    [3 (tli.TliConst.F64Bits 0x7ff8000000000001)]
    [4 (tli.TliConst.Bool true)]
    [5 (tli.TliConst.String "é漢")]
    [_
      (let
        [bytes : (__tl_dyn-array u8) (__tl_make-array u8 3)]
        (set! (array-ref bytes 1) (cast 255 : u8))
        (tli.TliConst.Bytes bytes))]))

(define (tli-test-module [reversed? : bool]) : tli.TliModuleRecord
  (let
    [imports : (__tl_dyn-array tli.TliImport) (__tl_make-array tli.TliImport 6)]
    [order : (__tl_dyn-array String) (__tl_make-array String 2)]
    [fns : (__tl_dyn-array tli.TliFnDecl) (__tl_make-array tli.TliFnDecl 4)]
    [values : (__tl_dyn-array tli.TliValueDecl)
      (__tl_make-array tli.TliValueDecl 7)]
    [macros : (__tl_dyn-array tli.TliMacroHandle)
      (__tl_make-array tli.TliMacroHandle 2)]
    [macro-params : (__tl_dyn-array tli.TliMacroParam)
      (__tl_make-array tli.TliMacroParam 1)]
    [kinds : (__tl_dyn-array u8) (__tl_make-array u8 2)]
    [dispatches : (__tl_dyn-array tli.TliDispatchDecl)
      (__tl_make-array tli.TliDispatchDecl 2)]
    (for [i (iterator.range 0 5)]
      (set!
        (array-ref imports (tli-test-slot reversed? 6 i))
        (tli.TliImport
          "dependency"
          i
          "dep"
          (if (= i 2)
            "item"
            "")
          (tli-test-hash i))))
    (set!
      (array-ref imports (tli-test-slot reversed? 6 5))
      (tli.TliImport "dependency" 0 "" "" (tli-test-hash 99)))
    (set! (array-ref order 0) "__global_init_z")
    (set! (array-ref order 1) "__global_init_a")
    (for [i (iterator.range 0 4)]
      (set!
        (array-ref fns (tli-test-slot reversed? 4 i))
        (tli-test-function reversed? i)))
    (for [i (iterator.range 0 7)]
      (set!
        (array-ref values (tli-test-slot reversed? 7 i))
        (tli.TliValueDecl
          (string.int->string i)
          "fixture"
          "value.symbol"
          (tli.TliType.Unit)
          (if (= i 0)
            0
            8)
          false
          (__tl_make-array tli.TliExternLinkInput 0)
          (tli-test-const i))))
    (set! (array-ref kinds 1) (cast 29 : u8))
    (set!
      (array-ref macro-params 0)
      (tli.TliMacroParam
        "param"
        (tli.TliType.Tuple (tli-test-types))
        true
        kinds))
    (set!
      (array-ref macros (tli-test-slot reversed? 2 0))
      (tli.TliMacroHandle
        "z-macro"
        "fixture"
        "fixture.z"
        13
        (cast 1 : u8)
        macro-params
        17
        (tli-test-hash 43)))
    (set!
      (array-ref macros (tli-test-slot reversed? 2 1))
      (tli.TliMacroHandle
        "a-macro"
        "fixture"
        "fixture.a"
        2
        (cast 0 : u8)
        (__tl_make-array tli.TliMacroParam 0)
        -1
        (tli-test-hash 0)))
    (set!
      (array-ref dispatches (tli-test-slot reversed? 2 0))
      (tli.TliDispatchDecl
        "dispatch"
        "fixture"
        "dispatch.z"
        0
        (tli.TliType.Func
          (__tl_make-array (tli.TliType.I64))
          (box (tli.TliType.I64)))
        (tli.TliFnSummary
          4
          3
          (__tl_make-array i64 0)
          (__tl_make-array tli.TliGlobalWrite 0)
          -1
          (cast 0 : u8)
          0
          0
          0
          (make-array u8 32))))
    (set!
      (array-ref dispatches (tli-test-slot reversed? 2 1))
      (tli.TliDispatchDecl
        "dispatch"
        "fixture"
        "dispatch.a"
        0
        (tli.TliType.Func
          (__tl_make-array (tli.TliType.I64))
          (box (tli.TliType.I64)))
        (tli.TliFnSummary
          16
          0
          (__tl_make-array i64 0)
          (__tl_make-array (tli.TliGlobalWrite "write.a" (cast 1 : u8)))
          -1
          (cast 0 : u8)
          0
          0
          0
          (make-array u8 32))))
    (tli.TliModuleRecord
      "fixture"
      "src/fixture.tl"
      (tli-test-hash 52)
      (tli-test-hash 63)
      15
      imports
      order
      (tli-test-decls reversed?)
      fns
      values
      macros
      dispatches)))

(define (tli-test-plain-module [name : String] [ty : tli.TliType]) : tli.TliModuleRecord
  (let
    [values : (__tl_dyn-array tli.TliValueDecl)
      (__tl_make-array tli.TliValueDecl 1)]
    (set!
      (array-ref values 0)
      (tli.TliValueDecl
        "value"
        ""
        "value.sym"
        ty
        0
        false
        (__tl_make-array tli.TliExternLinkInput 0)
        (tli.TliConst.None)))
    (tli.TliModuleRecord
      name
      "src/plain.tl"
      (tli-test-hash 1)
      (tli-test-hash 2)
      0
      (__tl_make-array tli.TliImport 0)
      (__tl_make-array String 0)
      (__tl_make-array tli.TliTypeDecl 0)
      (__tl_make-array tli.TliFnDecl 0)
      values
      (__tl_make-array tli.TliMacroHandle 0)
      (__tl_make-array tli.TliDispatchDecl 0))))

(define (tli-test-bundle [reversed? : bool]) : tli.TliBundle
  (let
    [modules : (__tl_dyn-array tli.TliModuleRecord)
      (__tl_make-array tli.TliModuleRecord 2)]
    (set!
      (array-ref modules (tli-test-slot reversed? 2 0))
      (tli-test-module reversed?))
    (set!
      (array-ref modules (tli-test-slot reversed? 2 1))
      (tli-test-plain-module "α-module" (tli.TliType.I64)))
    (tli.TliBundle
      5
      "test-build"
      "linux-x86_64"
      modules
      (__tl_make-array tli.TliCompactGlobal 0)
      (__tl_make-array tli.TliCompactBodyEntry 0))))

(define (tli-test-encode-plain [ty : tli.TliType]) : (__tl_dyn-array u8)
  (let
    [modules : (__tl_dyn-array tli.TliModuleRecord)
      (__tl_make-array tli.TliModuleRecord 1)]
    (set! (array-ref modules 0) (tli-test-plain-module "plain" ty))
    (codec.tli-encode-bundle
      (&
        (tli.TliBundle
          0
          "build"
          "linux-x86_64"
          modules
          (__tl_make-array tli.TliCompactGlobal 0)
          (__tl_make-array tli.TliCompactBodyEntry 0))))))

(define (tli-test-record [bytes : (& bytes (__tl_dyn-array u8))]) : i64
  (le.read-u64 bytes (+ (le.read-u64 bytes 40) 8)))

(define (tli-test-refresh-content! [bytes : (&mut bytes (__tl_dyn-array u8))]) : unit
  (let
    [index-end : i64 (+ (le.read-u64 bytes 40) (le.read-u64 bytes 48))]
    [index : (Array u8 32) (codec.tli-index-digest bytes index-end)]
    (codec.tli-copy-digest! bytes tli.tli-index-digest-offset (& index))
    (let
      [digest : (Array u8 32) (codec.tli-content-digest bytes)]
      (codec.tli-copy-digest! bytes tli.tli-content-digest-offset (& digest)))))

;; The first byte of pool entry 1, after the count and the offset table.
(define (tli-test-pool-text [bytes : (& bytes (__tl_dyn-array u8))]) : i64
  (+ tli.tli-header-size 4 (* 4 (+ (le.read-u32 bytes tli.tli-header-size) 1))))

(define (tli-test-refresh-module!
  [bytes : (&mut bytes (__tl_dyn-array u8))]
  [index : i64]) : unit
  (let
    [entry : i64
      (+ (le.read-u64 bytes 40) (* index tli.tli-directory-entry-size))]
    [digest : (Array u8 32)
      (codec.tli-module-digest
        bytes
        (le.read-u64 bytes (+ entry 8))
        (le.read-u64 bytes (+ entry 16)))]
    (codec.tli-copy-digest! bytes (+ entry 24) (& digest))
    (tli-test-refresh-content! bytes)))

(define (tli-test-round-trip [bytes : (& bytes (__tl_dyn-array u8))]) : tli.TliBundle
  (match (codec.tli-decode-bundle bytes)
    [(codec.TliBundleResult.Err error) (io.panic (& error.message))]
    [(codec.TliBundleResult.Ok bundle)
      (let
        [encoded : (__tl_dyn-array u8) (codec.tli-encode-bundle (& bundle))]
        (test.assert-true
          (binary.compiler-incremental-binary-bytes-eq? bytes (& encoded))
          "decoded bundle re-encodes byte for byte")
        bundle)]))

(test
  tli-canonical-round-trip
  (let
    [bytes : (__tl_dyn-array u8)
      (codec.tli-encode-bundle (& (tli-test-bundle false)))]
    [reversed : (__tl_dyn-array u8)
      (codec.tli-encode-bundle (& (tli-test-bundle true)))]
    (test.assert-true
      (binary.compiler-incremental-binary-bytes-eq? (& bytes) (& reversed))
      "shuffling modules and unordered tables preserves the bytes")
    (let
      [bundle : tli.TliBundle (tli-test-round-trip (& bytes))]
      [module (& (array-ref bundle.modules 0))]
      [fn (& (array-ref module.functions 0))]
      [macro (& (array-ref module.macros 1))]
      [dispatch (& (array-ref module.dispatches 0))]
      (test.assert-string-eq
        (& (array-ref module.imports 3).alias)
        "dep"
        "module item alias")
      (test.assert-string-eq
        (& (array-ref module.imports 3).item)
        "item"
        "module item")
      (test.assert-string-eq
        (& module.name)
        "fixture"
        "UTF-8 byte module order")
      (test.assert-string-eq
        (& (array-ref module.global-inits 0))
        "__global_init_z"
        "startup order stays intact")
      (test.assert-i64-eq
        fn.summary.effect-flags
        440
        "arena argument effect bit")
      (test.assert-i64-eq
        fn.summary.arena-arg-store-mask
        -9223372036854775807
        "arena mask supports bit 63")
      (test.assert-i64-eq
        (array-ref fn.summary.arena-arg-store-extra 1)
        65
        "large arena argument")
      (test.assert-string-eq
        (& (array-ref fn.summary.global-writes 0).symbol)
        "write.a"
        "sorted globals")
      (test.assert-string-eq
        (& (array-ref fn.extern-link-inputs 0).name)
        "-lfixture"
        "link input order")
      (test.assert-i64-eq macro.tlci-entry-index 17 "TLCI handle entry")
      (test.assert-string-eq
        (& dispatch.link-symbol)
        "dispatch.a"
        "dispatch tie-break")
      (match (& (array-ref module.types 1).body)
        [(tli.TliTypeBody.Struct fields)
          (test.assert-true (array-ref fields 0).opaque? "opaque field")
          (test.assert-true (not (array-ref fields 1).opaque?) "public field")
          (test.assert-i64-eq
            (array-ref fields 0).explicit-align
            16
            "explicit field alignment")
          (test.assert-string-eq
            (& (array-ref fields 0).name)
            "high"
            "field order stays intact")]
        [_ (test.assert-true false "expected struct")]))))

(define (tli-test-error-number [kind : (& kind tli.TliDecodeError)]) : i64
  (match kind
    [(tli.TliDecodeError.Magic) 1]
    [(tli.TliDecodeError.SchemaVersion) 2]
    [(tli.TliDecodeError.Flags) 3]
    [(tli.TliDecodeError.Truncated) 4]
    [(tli.TliDecodeError.OffsetOutOfRange) 5]
    [(tli.TliDecodeError.Overlap) 6]
    [(tli.TliDecodeError.Utf8) 7]
    [(tli.TliDecodeError.Limit) 8]
    [(tli.TliDecodeError.StringIdOutOfRange) 9]
    [(tli.TliDecodeError.UnknownTag) 10]
    [(tli.TliDecodeError.DigestMismatch) 11]
    [(tli.TliDecodeError.CfgFingerprintMismatch) 12]
    [(tli.TliDecodeError.CompilerBuildMismatch) 13]
    [(tli.TliDecodeError.TargetMismatch) 14]
    [(tli.TliDecodeError.TrailingBytes) 15]))

(define (tli-test-error!
  [error : (& error tli.TliDecodeFailure)]
  [expected : tli.TliDecodeError]) : unit
  (test.assert-i64-eq
    (tli-test-error-number (& error.kind))
    (tli-test-error-number (& expected))
    (string.copy (& error.message))))

(define (tli-test-invalid-directory!
  [result : codec.TliDirectoryResult]
  [expected : tli.TliDecodeError]) : unit
  (match result
    [(codec.TliDirectoryResult.Err error) (tli-test-error! (& error) expected)]
    [_ (test.assert-true false "directory accepted invalid input")]))

(define (tli-test-invalid-module!
  [result : codec.TliModuleResult]
  [expected : tli.TliDecodeError]) : unit
  (match result
    [(codec.TliModuleResult.Err error) (tli-test-error! (& error) expected)]
    [_ (test.assert-true false "module accepted invalid input")]))

(define (tli-test-invalid-bundle!
  [bytes : (& bytes (__tl_dyn-array u8))]
  [expected : tli.TliDecodeError]) : unit
  (match (codec.tli-decode-bundle bytes)
    [(codec.TliBundleResult.Err error) (tli-test-error! (& error) expected)]
    [_ (test.assert-true false "bundle accepted invalid input")]))

(test
  tli-bad-header
  (let
    [bytes : (__tl_dyn-array u8) (tli-test-encode-plain (tli.TliType.I64))]
    [short : (__tl_dyn-array u8) (__tl_make-array u8 3)]
    [length : i64 (array-length bytes)]
    (tli-test-invalid-bundle! (& short) (tli.TliDecodeError.Truncated))
    (le.set-u32! (&mut bytes) 0 0)
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.Magic))
    (le.set-u32! (&mut bytes) 0 tli.tli-magic)
    (le.set-u32! (&mut bytes) 4 1)
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.SchemaVersion))
    (le.set-u32! (&mut bytes) 4 tli.tli-schema-version)
    (le.set-u32! (&mut bytes) 8 8)
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.Flags))
    (le.set-u32! (&mut bytes) 8 tli.tli-has-compact-ir)
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.OffsetOutOfRange))
    (le.set-u32! (&mut bytes) 8 0)
    (le.set-u64! (&mut bytes) 16 (+ length 1))
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.Truncated))
    (le.set-u64! (&mut bytes) 16 (- length 1))
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.TrailingBytes))
    (le.set-u64! (&mut bytes) 16 length)
    (le.set-u64! (&mut bytes) 24 -1)
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.OffsetOutOfRange))
    (le.set-u64! (&mut bytes) 24 (- tli.tli-header-size 1))
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.Overlap))
    (le.set-u64! (&mut bytes) 24 tli.tli-header-size)
    (le.set-u64! (&mut bytes) 64 1)
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.OffsetOutOfRange))
    (le.set-u64! (&mut bytes) 64 0)
    (le.set-u32! (&mut bytes) 12 0xffffffff)
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.Limit))))

(test
  tli-bad-pool-and-directory
  (let
    [bytes : (__tl_dyn-array u8) (tli-test-encode-plain (tli.TliType.I64))]
    [entry : i64 (le.read-u64 (& bytes) 40)]
    [start : i64 (tli-test-record (& bytes))]
    [build : i64 (le.read-u32 (& bytes) 72)]
    [text : i64 (tli-test-pool-text (& bytes))]
    [first : u8 (array-ref bytes text)]
    (set! (array-ref bytes text) (cast 0xff : u8))
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.DigestMismatch))
    (tli-test-refresh-content! (&mut bytes))
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.Utf8))
    (set! (array-ref bytes text) first)
    (le.set-u32! (&mut bytes) (+ tli.tli-header-size 8) 7)
    (tli-test-refresh-content! (&mut bytes))
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.UnknownTag))
    (le.set-u32! (&mut bytes) (+ tli.tli-header-size 8) 0)
    (tli-test-refresh-content! (&mut bytes))
    (le.set-u32! (&mut bytes) 72 0xffffffff)
    (tli-test-refresh-content! (&mut bytes))
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.StringIdOutOfRange))
    (le.set-u32! (&mut bytes) 72 build)
    (le.set-u64! (&mut bytes) (+ entry 8) (- start 1))
    (tli-test-refresh-content! (&mut bytes))
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.Overlap))
    (le.set-u64! (&mut bytes) (+ entry 8) start)
    (le.set-u64! (&mut bytes) (+ entry 16) -1)
    (tli-test-refresh-content! (&mut bytes))
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.OffsetOutOfRange))))

(test
  tli-lazy-record-cursor-is-bounded-by-its-snapshot
  (let
    [bytes : (__tl_dyn-array u8) (tli-test-encode-plain (tli.TliType.I64))]
    [start : i64 (tli-test-record (& bytes))]
    [short-digest : (Array u8 32) (codec.tli-module-digest (& bytes) start 4)]
    (match (codec.tli-decode-directory-for-lazy
      (& bytes)
      "build"
      "linux-x86_64")
      [(Err error) (io.panic (& error.message))]
      [(Ok directory)
        (set! (array-ref bytes start) (cast 255 : u8))
        (match (codec.tli-decode-module-at (& directory) 0)
          [(Err error) (io.panic (& error.message))]
          [(Ok _) unit])
        ;; The digest passes for the short record, but the source path ID
        ;; begins beyond its range, even though it exists in the snapshot.
        (set! (array-ref directory.entries 0).record-len 4)
        (set! (array-ref directory.entries 0).module-sha256 short-digest)
        (match (codec.tli-decode-module-at (& directory) 0)
          [(Err error)
            (tli-test-error! (& error) (tli.TliDecodeError.Truncated))
            (test.assert-i64-eq
              error.offset
              (+ start 4)
              "absolute short-record offset")]
          [(Ok _) (io.panic "record cursor read past the declared record")])])))

(test
  tli-full-open-checks-index-digest-and-lazy-checks-module-digest
  (let
    [bytes : (__tl_dyn-array u8) (tli-test-encode-plain (tli.TliType.I64))]
    [start : i64 (tli-test-record (& bytes))]
    (match (codec.tli-decode-directory-for-lazy
      (& bytes)
      "build"
      "linux-x86_64")
      [(codec.TliDirectoryResult.Err error)
        (test.assert-true false error.message)]
      [(codec.TliDirectoryResult.Ok _) unit])
    ;; Corrupt `index_sha256` and recompute only `content_sha256`: full open
    ;; still rejects the stale `index_sha256` before accepting the bundle.
    (let
      [saved : u8 (array-ref bytes tli.tli-index-digest-offset)]
      (set!
        (array-ref bytes tli.tli-index-digest-offset)
        (cast (bit-xor (cast saved : i64) 1) : u8))
      (let
        [content : (Array u8 32) (codec.tli-content-digest (& bytes))]
        (codec.tli-copy-digest!
          (&mut bytes)
          tli.tli-content-digest-offset
          (& content)))
      (tli-test-invalid-directory!
        (codec.tli-decode-directory-for (& bytes) "build" "linux-x86_64")
        (tli.TliDecodeError.DigestMismatch))
      (set! (array-ref bytes tli.tli-index-digest-offset) saved)
      (tli-test-refresh-content! (&mut bytes)))
    ;; Lazy open skips `index_sha256` and `content_sha256`, but still rejects
    ;; tampered module record bytes via `module_sha256` when decoding a record.
    (let
      [saved-rec : u8 (array-ref bytes start)]
      (set!
        (array-ref bytes start)
        (cast (bit-xor (cast saved-rec : i64) 1) : u8))
      (match (codec.tli-decode-directory-for-lazy
        (& bytes)
        "build"
        "linux-x86_64")
        [(codec.TliDirectoryResult.Err error)
          (test.assert-true false error.message)]
        [(codec.TliDirectoryResult.Ok directory)
          (match (codec.tli-decode-module-at (& directory) 0)
            [(codec.TliModuleResult.Err error)
              (tli-test-error! (& error) (tli.TliDecodeError.DigestMismatch))]
            [(codec.TliModuleResult.Ok _)
              (test.assert-true false "lazy decode accepted bad module_sha256")])])
      (set! (array-ref bytes start) saved-rec))))

(test
  tli-bad-record
  (let
    [bytes : (__tl_dyn-array u8) (tli-test-encode-plain (tli.TliType.I64))]
    [start : i64 (tli-test-record (& bytes))]
    (set! (array-ref bytes (+ start 108)) (cast 38 : u8))
    (tli-test-refresh-content! (&mut bytes))
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.DigestMismatch))
    (tli-test-refresh-module! (&mut bytes) 0)
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.UnknownTag))
    (set! (array-ref bytes (+ start 108)) (cast 17 : u8))
    (tli-test-refresh-module! (&mut bytes) 0)
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.UnknownTag))
    (set! (array-ref bytes (+ start 108)) (cast 0 : u8))
    (le.set-u32! (&mut bytes) (+ start 76) 0xffffffff)
    (tli-test-refresh-module! (&mut bytes) 0)
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.Limit))
    (le.set-u32! (&mut bytes) (+ start 76) 10)
    (tli-test-refresh-module! (&mut bytes) 0)
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.Truncated))))

(define (tli-test-nested [depth : i64]) : tli.TliType
  (if (= depth 1)
    (tli.TliType.U8)
    (tli.TliType.Box (box (tli-test-nested (- depth 1))))))

(test
  tli-recursion-boundary
  (let
    [bytes : (__tl_dyn-array u8) (tli-test-encode-plain (tli-test-nested 64))]
    [decoded : tli.TliBundle (tli-test-round-trip (& bytes))]
    [deep : (__tl_dyn-array u8) (tli-test-encode-plain (tli-test-nested 65))]
    (test.assert-i64-eq (array-length decoded.modules) 1 "depth 64 is accepted")
    (tli-test-invalid-bundle! (& deep) (tli.TliDecodeError.Limit))))

(test
  tli-compatibility-checks-and-lazy-records
  (let
    [bytes : (__tl_dyn-array u8)
      (codec.tli-encode-bundle (& (tli-test-bundle false)))]
    [next-entry : i64
      (+ (le.read-u64 (& bytes) 40) tli.tli-directory-entry-size)]
    [bad-record : i64 (le.read-u64 (& bytes) (+ next-entry 8))]
    (set! (array-ref bytes (+ bad-record 108)) (cast 222 : u8))
    (tli-test-refresh-module! (&mut bytes) 1)
    (tli-test-invalid-directory!
      (codec.tli-decode-directory-for (& bytes) "wrong" "linux-x86_64")
      (tli.TliDecodeError.CompilerBuildMismatch))
    (tli-test-invalid-directory!
      (codec.tli-decode-directory-for (& bytes) "test-build" "wrong")
      (tli.TliDecodeError.TargetMismatch))
    (match (codec.tli-decode-directory-for
      (& bytes)
      "test-build"
      "linux-x86_64")
      [(codec.TliDirectoryResult.Err error)
        (test.assert-true false error.message)]
      [(codec.TliDirectoryResult.Ok directory)
        (test.assert-i64-eq
          (array-length directory.entries)
          2
          "both modules are listed")
        (tli-test-invalid-module!
          (codec.tli-decode-module-at (& directory) -1)
          (tli.TliDecodeError.OffsetOutOfRange))
        (tli-test-invalid-module!
          (codec.tli-decode-module-at (& directory) 1)
          (tli.TliDecodeError.UnknownTag))
        (let
          [wrong : (Array u8 32) (tli-test-hash 60)]
          [right : (Array u8 32) (tli-test-hash 63)]
          (tli-test-invalid-module!
            (codec.tli-decode-module-at-for (& directory) 0 (& wrong))
            (tli.TliDecodeError.CfgFingerprintMismatch))
          (match (codec.tli-decode-module-at-for (& directory) 0 (& right))
            [(codec.TliModuleResult.Err error)
              (test.assert-true false error.message)]
            [(codec.TliModuleResult.Ok module)
              (test.assert-string-eq
                (& module.name)
                "fixture"
                "good module decodes independently")]))])
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.UnknownTag))))

(test
  tli-v5-wire-tags-and-digests
  (let
    [wire : (__tl_dyn-array u8) (tli-test-encode-plain (tli.TliType.I64))]
    [bundle : tli.TliBundle (tli-test-bundle false)]
    [types : (__tl_dyn-array tli.TliType) (tli-test-types)]
    [writer : codec.TliWriteContext
      (codec.tli-write-context-new
        (codec.tli-collect-pool (& bundle))
        (__tl_make-array codec.TliCompactBodyMeta 0))]
    (test.assert-i64-eq (array-length wire) 411 "v5 exemplar length")
    (test.assert-i64-eq
      (tli-test-record (& wire))
      284
      "v5 exemplar record offset")
    (match (codec.tli-decode-directory (& wire))
      [(codec.TliDirectoryResult.Err error)
        (test.assert-true false error.message)]
      [(codec.TliDirectoryResult.Ok directory)
        (let
          [entry (& (array-ref directory.entries 0))]
          (test.assert-owned-string-eq
            (sha256.to-hex (& (sha256.Sha256Digest directory.content-sha256)))
            "eab219c4934b239a82e13aea7d1661fe3fc33d13017a73115b6f3c34ecb04ed2"
            "independently computed content digest")
          (let
            [index : (Array u8 32) (make-array u8 32)]
            (for [byte (iterator.range 0 32)]
              (set!
                (array-ref index byte)
                (array-ref wire (+ tli.tli-index-digest-offset byte))))
            (test.assert-owned-string-eq
              (sha256.to-hex (& (sha256.Sha256Digest index)))
              "ca5b9490efe4e6e6ad1335af50903a080d8f30d3195acb9a5c45ad4dfce44183"
              "independently computed index digest"))
          (test.assert-owned-string-eq
            (sha256.to-hex (& (sha256.Sha256Digest entry.module-sha256)))
            "96fc0aeed04dcf061acd20301f5d5ead15aa9657002d1e1a2112aaa1a787ab01"
            "independently computed module digest"))])
    (for [tag (iterator.range 0 (array-length types))]
      (let
        [start : i64 writer.out.len]
        (codec.tli-write-type! (&mut writer) (& (array-ref types tag)))
        (test.assert-i64-eq
          (cast (array-ref writer.out.slots start) : i64)
          tag
          "every frozen TliType wire tag")))))

(test
  tli-rejects-noncanonical-order-and-reserved-type-tags
  (let
    [bytes : (__tl_dyn-array u8)
      (codec.tli-encode-bundle (& (tli-test-bundle false)))]
    [start : i64 (tli-test-record (& bytes))]
    [dir : i64 (le.read-u64 (& bytes) 40)]
    ;; Six imports of 45 bytes, two startup symbols, and their list counts.
    [first-import : i64 (+ start 80)]
    [first-type : i64 (+ first-import (* 6 45) 12 4)]
    [repr : i64 (+ first-type 29)]
    [cleanup : i64 (+ first-type 38)]
    ;; Enum (63 bytes), struct (114 bytes), then the function count.
    [first-struct : i64 (+ first-type 63)]
    [first-fn : i64 (+ first-struct 114 4)]
    ;; Struct metadata and field count (59 bytes), then the first field's
    ;; 22 bytes before its boolean opacity tag.
    [field-opacity : i64 (+ first-struct 59 22)]
    [first-name : i64 (le.read-u32 (& bytes) dir)]
    [second-name : i64 (le.read-u32 (& bytes) (+ dir 56))]
    (le.set-u32! (&mut bytes) dir second-name)
    (le.set-u32! (&mut bytes) (+ dir 56) first-name)
    (tli-test-refresh-content! (&mut bytes))
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.UnknownTag))
    (le.set-u32! (&mut bytes) dir first-name)
    (le.set-u32! (&mut bytes) (+ dir 56) second-name)
    (set! (array-ref bytes (+ first-import 4)) (cast 3 : u8))
    (tli-test-refresh-module! (&mut bytes) 0)
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.UnknownTag))
    (set! (array-ref bytes (+ first-import 4)) (cast 0 : u8))
    (set! (array-ref bytes repr) (cast 2 : u8))
    (tli-test-refresh-module! (&mut bytes) 0)
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.UnknownTag))
    (set! (array-ref bytes repr) (cast 0 : u8))
    (set! (array-ref bytes cleanup) (cast 2 : u8))
    (tli-test-refresh-module! (&mut bytes) 0)
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.UnknownTag))
    (set! (array-ref bytes cleanup) (cast 0 : u8))
    (set! (array-ref bytes field-opacity) (cast 2 : u8))
    (tli-test-refresh-module! (&mut bytes) 0)
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.UnknownTag))
    (set! (array-ref bytes field-opacity) (cast 1 : u8))
    (set! (array-ref bytes (+ first-fn 12)) (cast 4 : u8))
    (tli-test-refresh-module! (&mut bytes) 0)
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.UnknownTag))
    (set! (array-ref bytes (+ first-fn 12)) (cast 0 : u8))
    (set! (array-ref bytes (+ first-fn 13)) (cast 3 : u8))
    (tli-test-refresh-module! (&mut bytes) 0)
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.UnknownTag))
    (set! (array-ref bytes (+ first-fn 13)) (cast 1 : u8))
    (set! (array-ref bytes (+ first-fn 18)) (cast 2 : u8))
    (tli-test-refresh-module! (&mut bytes) 0)
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.UnknownTag))))

(test
  tli-rejects-trailing-record-bytes
  (let
    [clean : (__tl_dyn-array u8) (tli-test-encode-plain (tli.TliType.I64))]
    [size : i64 (array-length clean)]
    [bytes : (__tl_dyn-array u8) (__tl_make-array u8 (+ size 1))]
    [entry : i64 (le.read-u64 (& clean) 40)]
    [record-size : i64 (le.read-u64 (& clean) (+ entry 16))]
    (buf.byte-buf-builder-copy-array-range-into (&mut bytes) 0 (& clean) 0 size)
    (le.set-u64! (&mut bytes) 16 (+ size 1))
    (le.set-u64! (&mut bytes) (+ entry 16) (+ record-size 1))
    (tli-test-refresh-module! (&mut bytes) 0)
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.TrailingBytes))))

(test
  tli-preserves-nul-in-utf8-text
  (let
    [raw : (__tl_dyn-array u8)
      (__tl_make-array (cast 0xce : u8) (cast 0xb1 : u8) (cast 0 : u8))]
    [text : String
      (unsafe
        (string-from-bytes
          (ptr-cast (__tl_array-data raw) : (Ptr u8))
          (array-length raw)))]
    [module : tli.TliModuleRecord
      (tli-test-plain-module "plain" (tli.TliType.String))]
    (set!
      (array-ref module.values 0)
      (tli.TliValueDecl
        "value"
        ""
        "value.sym"
        (tli.TliType.String)
        8
        false
        (__tl_make-array tli.TliExternLinkInput 0)
        (tli.TliConst.String (string.copy (& text)))))
    (let
      [modules : (__tl_dyn-array tli.TliModuleRecord)
        (__tl_make-array tli.TliModuleRecord 1)]
      (set! (array-ref modules 0) module)
      (let
        [bytes : (__tl_dyn-array u8)
          (codec.tli-encode-bundle
            (&
              (tli.TliBundle
                0
                (string.copy (& text))
                "linux-x86_64"
                modules
                (__tl_make-array tli.TliCompactGlobal 0)
                (__tl_make-array tli.TliCompactBodyEntry 0))))]
        [decoded : tli.TliBundle (tli-test-round-trip (& bytes))]
        [mod (& (array-ref decoded.modules 0))]
        (test.assert-string-eq
          (& decoded.compiler-build)
          (& text)
          "NUL in pooled text")
        (match (& (array-ref mod.values 0).const-value)
          [(tli.TliConst.String value)
            (test.assert-string-eq value (& text) "NUL in constant text")]
          [_ (test.assert-true false "expected string constant")])))))

(define (tli-test-compact-ir-body) : tli.TliCompactIrBody
  (let
    [params : (__tl_dyn-array tli.TliCompactParam)
      (__tl_make-array tli.TliCompactParam 2)]
    [instrs : (__tl_dyn-array tli.TliCompactInstr)
      (__tl_make-array tli.TliCompactInstr 4)]
    [blocks : (__tl_dyn-array tli.TliCompactBlock)
      (__tl_make-array tli.TliCompactBlock 1)]
    [call-args : (__tl_dyn-array tli.TliCompactValue)
      (__tl_make-array tli.TliCompactValue 1)]
    [extern-refs : (__tl_dyn-array tli.TliCompactExternRef)
      (__tl_make-array tli.TliCompactExternRef 1)]
    [ext-params : (__tl_dyn-array tli.TliType) (__tl_make-array tli.TliType 1)]
    [rs-slot-types : (__tl_dyn-array tli.TliType)
      (__tl_make-array tli.TliType 0)]
    (set! (array-ref params 0) (tli.TliCompactParam "x" (tli.TliType.F64) 0))
    (set! (array-ref params 1) (tli.TliCompactParam "y" (tli.TliType.F64) 1))
    (set! (array-ref call-args 0) (tli.TliCompactValue.Var 0))
    (set! (array-ref ext-params 0) (tli.TliType.F64))
    (set!
      (array-ref extern-refs 0)
      (tli.TliCompactExternRef
        "_tl_helper"
        0
        "_tl_helper"
        (tli.TliType.Func ext-params (box (tli.TliType.F64)))
        (tli.TliCompactReturnStorage.None)))
    (set!
      (array-ref instrs 0)
      (tli.TliCompactInstr.BinOp
        2
        (tli.TliCompactBinOp.Add)
        (tli.TliCompactValue.Var 0)
        (tli.TliCompactValue.Var 1)
        (tli.TliType.F64)))
    (set!
      (array-ref instrs 1)
      (tli.TliCompactInstr.Call
        3
        "_tl_helper"
        (tli.TliCompactCallArgs call-args -1)
        (tli.TliType.F64)))
    (set!
      (array-ref instrs 2)
      (tli.TliCompactInstr.UnOp
        4
        (tli.TliCompactUnOp.Neg)
        (tli.TliCompactValue.Var 3)
        (tli.TliType.F64)))
    (set!
      (array-ref instrs 3)
      (tli.TliCompactInstr.Return true (tli.TliCompactValue.Var 4)))
    (set! (array-ref blocks 0) (tli.TliCompactBlock 0 instrs))
    (tli.TliCompactIrBody
      0
      4
      params
      (tli.TliType.F64)
      5
      blocks
      (tli.TliCompactReturnStorage.Some
        0
        0
        16
        8
        (tli.TliType.F64)
        (tli.TliType.F64)
        rs-slot-types
        (tli.TliType.F64))
      extern-refs)))

(define (tli-test-spmd-expr) : tli.TliSpmdExpr
  (let
    [args : (__tl_dyn-array tli.TliSpmdExpr)
      (__tl_make-array tli.TliSpmdExpr 2)]
    (set! (array-ref args 0) (tli.TliSpmdExpr.Var "x"))
    (set!
      (array-ref args 1)
      (tli.TliSpmdExpr.Literal (tli.TliSpmdLiteral.Float "1.0")))
    (tli.TliSpmdExpr.If
      (box (tli.TliSpmdExpr.Call (box (tli.TliSpmdExpr.Var "<")) args))
      (box (tli.TliSpmdExpr.Var "x"))
      (box (tli.TliSpmdExpr.Var "y")))))

(define (tli-test-deep-spmd-expr [depth : i64]) : tli.TliSpmdExpr
  (if (= depth 1)
    (tli.TliSpmdExpr.Var "x")
    (tli.TliSpmdExpr.Unary 0 (box (tli-test-deep-spmd-expr (- depth 1))))))

(define (tli-test-compact-bundle) : tli.TliBundle
  (let
    [mod : tli.TliModuleRecord
      (tli-test-plain-module "compact.mod" (tli.TliType.F64))]
    [fns : (__tl_dyn-array tli.TliFnDecl) (__tl_make-array tli.TliFnDecl 3)]
    [p2 : (__tl_dyn-array tli.TliParam) (__tl_make-array tli.TliParam 2)]
    [p2b : (__tl_dyn-array tli.TliParam) (__tl_make-array tli.TliParam 2)]
    [p2c : (__tl_dyn-array tli.TliParam) (__tl_make-array tli.TliParam 2)]
    [globals : (__tl_dyn-array tli.TliCompactGlobal)
      (__tl_make-array tli.TliCompactGlobal 1)]
    [bodies : (__tl_dyn-array tli.TliCompactBodyEntry)
      (__tl_make-array tli.TliCompactBodyEntry 3)]
    [modules : (__tl_dyn-array tli.TliModuleRecord)
      (__tl_make-array tli.TliModuleRecord 1)]
    (set! (array-ref p2 0) (tli.TliParam "x" (tli.TliType.F64) false))
    (set! (array-ref p2 1) (tli.TliParam "y" (tli.TliType.F64) false))
    (set! (array-ref p2b 0) (tli.TliParam "x" (tli.TliType.F64) false))
    (set! (array-ref p2b 1) (tli.TliParam "y" (tli.TliType.F64) false))
    (set! (array-ref p2c 0) (tli.TliParam "x" (tli.TliType.F64) false))
    (set! (array-ref p2c 1) (tli.TliParam "y" (tli.TliType.F64) false))
    (set!
      (array-ref fns 0)
      (tli.TliFnDecl
        "both"
        "compact.mod"
        "_tl_both"
        0
        0
        ""
        false
        0
        (__tl_make-array tli.TliExternLinkInput 0)
        p2
        (tli.TliType.F64)
        (tli.TliFnSummary
          (+ 1 (+ tli.tli-fn-has-inline-ir tli.tli-fn-spmd-inlineable))
          0
          (__tl_make-array i64 0)
          (__tl_make-array tli.TliGlobalWrite 0)
          0
          (cast 3 : u8)
          1
          0
          0
          (make-array u8 32))))
    (set!
      (array-ref fns 1)
      (tli.TliFnDecl
        "ir-only"
        "compact.mod"
        "_tl_ir_only"
        0
        0
        ""
        false
        0
        (__tl_make-array tli.TliExternLinkInput 0)
        p2b
        (tli.TliType.F64)
        (tli.TliFnSummary
          tli.tli-fn-has-inline-ir
          0
          (__tl_make-array i64 0)
          (__tl_make-array tli.TliGlobalWrite 0)
          5
          (cast 0 : u8)
          0
          0
          0
          (make-array u8 32))))
    (set!
      (array-ref fns 2)
      (tli.TliFnDecl
        "spmd-only"
        "compact.mod"
        "_tl_spmd_only"
        0
        0
        ""
        false
        0
        (__tl_make-array tli.TliExternLinkInput 0)
        p2c
        (tli.TliType.F64)
        (tli.TliFnSummary
          (+ 1 tli.tli-fn-spmd-inlineable)
          0
          (__tl_make-array i64 0)
          (__tl_make-array tli.TliGlobalWrite 0)
          -1
          (cast 0 : u8)
          0
          0
          0
          (make-array u8 32))))
    (set! mod.functions fns)
    (set!
      (array-ref globals 0)
      (tli.TliCompactGlobal
        "_tl_const_pi"
        (tli.TliType.F64)
        tli.tli-compact-global-never-written
        (tli.TliCompactValue.F64Bits 4614256656552045848)))
    (set!
      (array-ref bodies 0)
      (tli.TliCompactBodyEntry
        "compact.mod"
        "both"
        "_tl_both"
        (tli.TliCompactBody
          (+ tli.tli-compact-body-has-ir tli.tli-compact-body-has-spmd-expr)
          (tli-test-compact-ir-body)
          (tli-test-spmd-expr))))
    (set!
      (array-ref bodies 1)
      (tli.TliCompactBodyEntry
        "compact.mod"
        "ir-only"
        "_tl_ir_only"
        (tli.TliCompactBody
          tli.tli-compact-body-has-ir
          (tli-test-compact-ir-body)
          (tli.tli-spmd-expr-empty))))
    (set!
      (array-ref bodies 2)
      (tli.TliCompactBodyEntry
        "compact.mod"
        "spmd-only"
        "_tl_spmd_only"
        (tli.TliCompactBody
          tli.tli-compact-body-has-spmd-expr
          (tli.tli-compact-ir-body-empty)
          (tli-test-spmd-expr))))
    (set! (array-ref modules 0) mod)
    (tli.TliBundle
      tli.tli-has-compact-ir
      "test-build"
      "linux-x86_64"
      modules
      globals
      bodies)))

(test
  tli-compact-ir-round-trip-and-lazy-access
  (let
    [bundle : tli.TliBundle (tli-test-compact-bundle)]
    [bytes : (__tl_dyn-array u8) (codec.tli-encode-bundle (& bundle))]
    [decoded : tli.TliBundle (tli-test-round-trip (& bytes))]
    [mod (& (array-ref decoded.modules 0))]
    [fn0 (& (array-ref mod.functions 0))]
    [fn1 (& (array-ref mod.functions 1))]
    [fn2 (& (array-ref mod.functions 2))]
    (test.assert-i64-eq
      decoded.flags
      tli.tli-has-compact-ir
      "HAS_COMPACT_IR set")
    (test.assert-i64-eq
      (array-length decoded.compact-globals)
      1
      "1 compact global")
    (test.assert-i64-eq
      (array-length decoded.compact-bodies)
      3
      "3 compact bodies")
    (test.assert-i64-eq fn0.summary.call-memory 0 "fn0 call-memory")
    (test.assert-i64-eq (cast fn0.summary.call-clean : i64) 3 "fn0 call-clean")
    (test.assert-i64-eq fn0.summary.return-alias 1 "fn0 return-alias")
    (test.assert-i64-eq fn1.summary.call-memory 5 "fn1 call-memory")
    (test.assert-i64-eq fn2.summary.call-memory -1 "fn2 absent call-memory")
    (test.assert-true (> fn0.summary.inline-ir-len 0) "fn0 has inline_ir_len")
    (test.assert-true (> fn1.summary.inline-ir-len 0) "fn1 has inline_ir_len")
    (test.assert-true (> fn2.summary.inline-ir-len 0) "fn2 has inline_ir_len")
    (match (codec.tli-decode-directory-for-lazy
      (& bytes)
      "test-build"
      "linux-x86_64")
      [(codec.TliDirectoryResult.Err error)
        (test.assert-true false error.message)]
      [(codec.TliDirectoryResult.Ok directory)
        (match (codec.tli-decode-compact-globals (& directory))
          [(codec.TliCompactGlobalsResult.Err error)
            (test.assert-true false error.message)]
          [(codec.TliCompactGlobalsResult.Ok globals)
            (test.assert-i64-eq (array-length globals) 1 "lazy compact globals")
            (test.assert-string-eq
              (& (array-ref globals 0).symbol)
              "_tl_const_pi"
              "lazy global symbol")])
        (match (codec.tli-peek-compact-body-header
          (& directory)
          fn0.summary.inline-ir-offset
          fn0.summary.inline-ir-len
          (& fn0.summary.inline-ir-sha256))
          [(codec.TliCompactBodyHeaderResult.Err error)
            (test.assert-true false error.message)]
          [(codec.TliCompactBodyHeaderResult.Ok hdr)
            (test.assert-i64-eq hdr.kind 3 "peek kind=3")
            (test.assert-i64-eq hdr.instr-count 4 "peek instr-count=4")
            (test.assert-i64-eq hdr.ir-flags 0 "peek ir-flags=0")])
        (match (codec.tli-decode-compact-body-at
          (& directory)
          fn0.summary.inline-ir-offset
          fn0.summary.inline-ir-len
          (& fn0.summary.inline-ir-sha256))
          [(codec.TliCompactBodyResult.Err error)
            (test.assert-true false error.message)]
          [(codec.TliCompactBodyResult.Ok body)
            (test.assert-i64-eq body.kind 3 "lazy decode kind=3")
            (test.assert-i64-eq
              (array-length body.ir-body.blocks)
              1
              "lazy decode 1 block")
            (test.assert-i64-eq
              (array-length body.ir-body.extern-refs)
              1
              "lazy decode 1 extern-ref")])])))

(test
  tli-compact-ir-fail-closed
  (let
    [bundle : tli.TliBundle (tli-test-compact-bundle)]
    [bytes : (__tl_dyn-array u8) (codec.tli-encode-bundle (& bundle))]
    [ir-offset : i64 (le.read-u64 (& bytes) 56)]
    (match (codec.tli-decode-directory-for-lazy
      (& bytes)
      "test-build"
      "linux-x86_64")
      [(codec.TliDirectoryResult.Err error)
        (test.assert-true false error.message)]
      [(codec.TliDirectoryResult.Ok directory)
        (match (codec.tli-decode-module-at (& directory) 0)
          [(codec.TliModuleResult.Err error)
            (test.assert-true false error.message)]
          [(codec.TliModuleResult.Ok mod)
            (let
              [fn0 (& (array-ref mod.functions 0))]
              [bad-digest : (Array u8 32) (tli-test-hash 99)]
              (match (codec.tli-decode-compact-body-at
                (& directory)
                fn0.summary.inline-ir-offset
                fn0.summary.inline-ir-len
                (& bad-digest))
                [(codec.TliCompactBodyResult.Err error)
                  (tli-test-error!
                    (& error)
                    (tli.TliDecodeError.DigestMismatch))]
                [_ (test.assert-true false "accepted bad inline_ir_sha256")])
              (match (codec.tli-decode-compact-body-at
                (& directory)
                (+ directory.compact-ir-len 8)
                fn0.summary.inline-ir-len
                (& fn0.summary.inline-ir-sha256))
                [(codec.TliCompactBodyResult.Err error)
                  (tli-test-error!
                    (& error)
                    (tli.TliDecodeError.OffsetOutOfRange))]
                [_
                  (test.assert-true
                    false
                    "accepted out-of-range inline_ir_offset")])
              ;; Corrupt body kind byte to 4 (invalid bitmask) and recompute content digest.
              (let
                [kind-pos : i64 (+ ir-offset fn0.summary.inline-ir-offset)]
                [saved : u8 (array-ref bytes kind-pos)]
                (set! (array-ref bytes kind-pos) (cast 4 : u8))
                (tli-test-refresh-content! (&mut bytes))
                (tli-test-invalid-bundle!
                  (& bytes)
                  (tli.TliDecodeError.DigestMismatch))
                (set! (array-ref bytes kind-pos) saved)
                (tli-test-refresh-content! (&mut bytes))))])])
    ;; SPMD expr depth boundary (64 accepted, 65 rejected).
    (let
      [deep-ok : tli.TliBundle (tli-test-compact-bundle)]
      [deep-bad : tli.TliBundle (tli-test-compact-bundle)]
      (set!
        (array-ref deep-ok.compact-bodies 2).body.spmd-expr
        (tli-test-deep-spmd-expr 64))
      (set!
        (array-ref deep-bad.compact-bodies 2).body.spmd-expr
        (tli-test-deep-spmd-expr 65))
      (let
        [ok-bytes : (__tl_dyn-array u8) (codec.tli-encode-bundle (& deep-ok))]
        [bad-bytes : (__tl_dyn-array u8) (codec.tli-encode-bundle (& deep-bad))]
        [_decoded : tli.TliBundle (tli-test-round-trip (& ok-bytes))]
        (tli-test-invalid-bundle! (& bad-bytes) (tli.TliDecodeError.Limit))))))

(test
  tli-compact-ir-rotr-round-trip
  (let
    [bundle : tli.TliBundle (tli-test-compact-bundle)]
    (set!
      (array-ref
        (array-ref (array-ref bundle.compact-bodies 0).body.ir-body.blocks 0).instrs
        0)
      (tli.TliCompactInstr.BinOp
        2
        (tli.TliCompactBinOp.Rotr)
        (tli.TliCompactValue.Var 0)
        (tli.TliCompactValue.I64 7)
        (tli.TliType.U32)))
    (let
      [bytes : (__tl_dyn-array u8) (codec.tli-encode-bundle (& bundle))]
      [decoded : tli.TliBundle (tli-test-round-trip (& bytes))]
      (match (&
        (array-ref
          (array-ref (array-ref decoded.compact-bodies 0).body.ir-body.blocks 0).instrs
          0))
        [(tli.TliCompactInstr.BinOp _ op _ _ _)
          (match op
            [(tli.TliCompactBinOp.Rotr) unit]
            [_ (test.assert-true false "expected Rotr binop after round trip")])]
        [_
          (test.assert-true false "expected BinOp instruction after round trip")]))))

;; The compact IR section is decoded fail-closed: a body slice may not reach back
;; into the globals and body count, the body count and the body slices must
;; tile the section exactly, an extern-ref ABI stops at 2 and a `Char` is a
;; Unicode scalar value.
(test
  tli-compact-ir-section-bounds-fail-closed
  (let
    [bundle : tli.TliBundle (tli-test-compact-bundle)]
    [bytes : (__tl_dyn-array u8) (codec.tli-encode-bundle (& bundle))]
    [ir-offset : i64 (le.read-u64 (& bytes) 56)]
    [bodies-start : i64 0]
    (match (codec.tli-decode-directory-for-lazy
      (& bytes)
      "test-build"
      "linux-x86_64")
      [(codec.TliDirectoryResult.Err error)
        (test.assert-true false error.message)]
      [(codec.TliDirectoryResult.Ok directory)
        (set! bodies-start directory.compact-bodies-start)
        (test.assert-i64-eq
          directory.compact-body-count
          3
          "three compact bodies")
        (match (codec.tli-decode-module-at (& directory) 0)
          [(codec.TliModuleResult.Err error)
            (test.assert-true false error.message)]
          [(codec.TliModuleResult.Ok mod)
            (let
              [fn0 (& (array-ref mod.functions 0))]
              (match (codec.tli-decode-compact-body-at
                (& directory)
                (- bodies-start 4)
                fn0.summary.inline-ir-len
                (& fn0.summary.inline-ir-sha256))
                [(codec.TliCompactBodyResult.Err error)
                  (tli-test-error!
                    (& error)
                    (tli.TliDecodeError.OffsetOutOfRange))]
                [_
                  (test.assert-true
                    false
                    "accepted a body slice over the compact body count")]))])])
    ;; One more body than the summaries name, then none at all.
    (let
      [count-pos : i64 (- (+ ir-offset bodies-start) 4)]
      (le.set-u32! (&mut bytes) count-pos 4)
      (tli-test-refresh-content! (&mut bytes))
      (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.OffsetOutOfRange))
      (le.set-u32! (&mut bytes) count-pos 0)
      (tli-test-refresh-content! (&mut bytes))
      (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.OffsetOutOfRange))
      (le.set-u32! (&mut bytes) count-pos 3)
      (tli-test-refresh-content! (&mut bytes))
      (let
        [_decoded : tli.TliBundle (tli-test-round-trip (& bytes))]
        unit)))
  (let
    [bad-abi : tli.TliBundle (tli-test-compact-bundle)]
    (set!
      (array-ref
        (array-ref bad-abi.compact-bodies 0).body.ir-body.extern-refs
        0).abi
      3)
    (tli-test-invalid-bundle!
      (& (codec.tli-encode-bundle (& bad-abi)))
      (tli.TliDecodeError.UnknownTag)))
  (let
    [surrogate : tli.TliBundle (tli-test-compact-bundle)]
    [too-big : tli.TliBundle (tli-test-compact-bundle)]
    (set!
      (array-ref surrogate.compact-globals 0).init
      (tli.TliCompactValue.Char 55296))
    (set!
      (array-ref too-big.compact-bodies 2).body.spmd-expr
      (tli.TliSpmdExpr.Literal (tli.TliSpmdLiteral.Char 1114112)))
    (let
      [bytes : (__tl_dyn-array u8) (codec.tli-encode-bundle (& surrogate))]
      (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.UnknownTag))
      (tli-test-invalid-directory!
        (codec.tli-decode-directory-for-lazy
          (& bytes)
          "test-build"
          "linux-x86_64")
        (tli.TliDecodeError.UnknownTag)))
    (tli-test-invalid-bundle!
      (& (codec.tli-encode-bundle (& too-big)))
      (tli.TliDecodeError.UnknownTag))))