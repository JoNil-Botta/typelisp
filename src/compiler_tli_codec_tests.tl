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
      (tli.TliField "high" (tli.TliType.I64) (tli.TliCleanup.Owned) 0 16))
    (set!
      (array-ref fields 1)
      (tli.TliField
        "low"
        (tli.TliType.Ref "z-life" (box (tli.TliType.Str)))
        (tli.TliCleanup.Fn "cleanup.field")
        16
        0))
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
      (tli.TliFnSummary 440 -9223372036854775807 extra writes 0 0))))

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
        (tli.TliImport "dependency" i (tli-test-hash i))))
    (set!
      (array-ref imports (tli-test-slot reversed? 6 5))
      (tli.TliImport "dependency" 0 (tli-test-hash 99)))
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
        (__tl_make-array tli.TliMacroParam 0)
        -1
        (tli-test-hash 0)))
    (set!
      (array-ref dispatches (tli-test-slot reversed? 2 0))
      (tli.TliDispatchDecl "dispatch" "fixture" "dispatch.z" 0))
    (set!
      (array-ref dispatches (tli-test-slot reversed? 2 1))
      (tli.TliDispatchDecl "dispatch" "fixture" "dispatch.a" 0))
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
      (tli.TliValueDecl "value" "" "value.sym" ty 0 (tli.TliConst.None)))
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
    (tli.TliBundle 5 "test-build" "linux-x86_64" modules)))

(define (tli-test-encode-plain [ty : tli.TliType]) : (__tl_dyn-array u8)
  (let
    [modules : (__tl_dyn-array tli.TliModuleRecord)
      (__tl_make-array tli.TliModuleRecord 1)]
    (set! (array-ref modules 0) (tli-test-plain-module "plain" ty))
    (codec.tli-encode-bundle
      (& (tli.TliBundle 0 "build" "linux-x86_64" modules)))))

(define (tli-test-record [bytes : (& bytes (__tl_dyn-array u8))]) : i64
  (le.read-u64 bytes (+ (le.read-u64 bytes 40) 8)))

(define (tli-test-refresh-content! [bytes : (&mut bytes (__tl_dyn-array u8))]) : unit
  (let
    [digest : (Array u8 32) (codec.tli-content-digest bytes)]
    (codec.tli-copy-digest! bytes 80 (& digest))))

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
    (le.set-u32! (&mut bytes) 4 2)
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.SchemaVersion))
    (le.set-u32! (&mut bytes) 4 1)
    (le.set-u32! (&mut bytes) 8 8)
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.Flags))
    (le.set-u32! (&mut bytes) 8 tli.tli-has-compact-ir)
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.Flags))
    (le.set-u32! (&mut bytes) 8 0)
    (le.set-u64! (&mut bytes) 16 (+ length 1))
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.Truncated))
    (le.set-u64! (&mut bytes) 16 (- length 1))
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.TrailingBytes))
    (le.set-u64! (&mut bytes) 16 length)
    (le.set-u64! (&mut bytes) 24 -1)
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.OffsetOutOfRange))
    (le.set-u64! (&mut bytes) 24 111)
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.Overlap))
    (le.set-u64! (&mut bytes) 24 112)
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
    (set! (array-ref bytes 124) (cast 0xff : u8))
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.DigestMismatch))
    (tli-test-refresh-content! (&mut bytes))
    (tli-test-invalid-bundle! (& bytes) (tli.TliDecodeError.Utf8))
    (set! (array-ref bytes 124) (cast 98 : u8))
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
  tli-v1-wire-tags-and-digests
  (let
    [wire : (__tl_dyn-array u8) (tli-test-encode-plain (tli.TliType.I64))]
    [bundle : tli.TliBundle (tli-test-bundle false)]
    [types : (__tl_dyn-array tli.TliType) (tli-test-types)]
    [writer : codec.TliWriteContext
      (codec.TliWriteContext
        false
        (codec.tli-collect-pool (& bundle))
        (buf.byte-buf-builder-new))]
    (test.assert-i64-eq (array-length wire) 370 "v1 exemplar length")
    (test.assert-i64-eq
      (tli-test-record (& wire))
      248
      "v1 exemplar record offset")
    (match (codec.tli-decode-directory (& wire))
      [(codec.TliDirectoryResult.Err error)
        (test.assert-true false error.message)]
      [(codec.TliDirectoryResult.Ok directory)
        (let
          [entry (& (array-ref directory.entries 0))]
          (test.assert-owned-string-eq
            (sha256.to-hex (& (sha256.Sha256Digest directory.content-sha256)))
            "1223204e7c164e5fba3d607566d61546d1c8cb3668bd4696d2f8c3dca74e31a3"
            "independently computed content digest")
          (test.assert-owned-string-eq
            (sha256.to-hex (& (sha256.Sha256Digest entry.module-sha256)))
            "354f38cdf127ba160ae911bfba95a83ccbc56e5653a84934fa88793539644c10"
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
    ;; Six imports of 37 bytes, two startup symbols, and their list counts.
    [first-import : i64 (+ start 80)]
    [first-type : i64 (+ first-import (* 6 37) 12 4)]
    [repr : i64 (+ first-type 29)]
    [cleanup : i64 (+ first-type 38)]
    ;; Enum (63 bytes), struct (112 bytes), then the function count.
    [first-fn : i64 (+ first-type 63 112 4)]
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
        (tli.TliConst.String (string.copy (& text)))))
    (let
      [modules : (__tl_dyn-array tli.TliModuleRecord)
        (__tl_make-array tli.TliModuleRecord 1)]
      (set! (array-ref modules 0) module)
      (let
        [bytes : (__tl_dyn-array u8)
          (codec.tli-encode-bundle
            (& (tli.TliBundle 0 (string.copy (& text)) "linux-x86_64" modules)))]
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