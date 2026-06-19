;; compiler_backend.tl - First selfhost CompilerIrProgram -> x86_64 .s emitter (#447).
(import "../stdlib/io.tl")
(import "../stdlib/arena.tl")
(import "compiler_lower.tl")
(import "compiler_builtin_ids.tl")
(import "compiler_diagnostic.tl")
(import "compiler_optimize.tl")
(import "compiler_regalloc.tl")
(import "../stdlib/text_buf.tl")
(import "compiler_object.tl")
(import "compiler_intern.tl")
(import "sym_i64_env.tl")
(import "../stdlib/hashmap.tl")
(import "../stdlib/string.tl")
(import "../stdlib/str_cat.tl")

(cfg
  compile-profile
  (define compiler-backend-profile-start-ms : i64
    0))
(cfg
  compile-profile
  (define compiler-backend-profile-start-total : i64
    0))
(cfg
  compile-profile
  (define compiler-backend-profile-start-live : i64
    0))
(cfg
  compile-profile
  (define compiler-backend-profile-detail-start-ms : i64
    0))

(cfg
  compile-profile
  (define (compiler-backend-profile-field [value : i64]) : String
    (string-append "|" (int->string value))))

(cfg
  compile-profile
  (define (compiler-backend-profile-start) : unit
    (begin
      (set! compiler-backend-profile-start-ms (profile-now-ms))
      (set! compiler-backend-profile-start-total (profile-alloc-total))
      (set! compiler-backend-profile-start-live (profile-alloc-live))
      (profile-alloc-reset-peak))))

(cfg
  compile-profile
  (define (compiler-backend-profile-finish [phase : String]) : unit
    (let
      [end-ms : i64 (profile-now-ms)]
      [end-total : i64 (profile-alloc-total)]
      [end-live : i64 (profile-alloc-live)]
      [peak-delta : i64
        (- (profile-alloc-peak) compiler-backend-profile-start-live)]
      (print-error
        (string-append
          "compile-profile|backend."
          (string-append
            phase
            (string-append
              (compiler-backend-profile-field
                (- end-ms compiler-backend-profile-start-ms))
              (string-append
                (compiler-backend-profile-field
                  (- end-total compiler-backend-profile-start-total))
                (string-append
                  (compiler-backend-profile-field
                    (- end-live compiler-backend-profile-start-live))
                  (string-append
                    (compiler-backend-profile-field peak-delta)
                    "\n"))))))))))

(cfg
  compile-profile
  (define (compiler-backend-profile-detail-start) : unit
    (set! compiler-backend-profile-detail-start-ms (profile-now-ms))))

(cfg
  compile-profile
  (define (compiler-backend-profile-detail-finish
    [phase : String]
    [name : String]) : unit
    (let
      [elapsed : i64
        (- (profile-now-ms) compiler-backend-profile-detail-start-ms)]
      (if (>= elapsed 1)
        (print-error
          (string-append
            "compile-profile-detail|backend."
            (string-append
              phase
              (string-append
                "|"
                (string-append
                  (int->string elapsed)
                  (string-append "|" (string-append name "\n")))))))
        unit))))

(cfg
  compile-profile
  (define (compiler-backend-profile-function-name [func : CompilerIrFunction]) : String
    (match func
      [(IrFunction name _ _ _ _) name])))

(defenum ResultBackendReg
  (OkBackendReg String)
  (ErrBackendReg String))

(defenum ResultBackendValue
  (OkBackendValue CompilerIrValue)
  (ErrBackendValue String))

(defenum CompilerBackendPhiSource
  (BackendPhiSourceValue CompilerIrValue)
  (BackendPhiSourceTemp))

(defenum CompilerBackendPhiCopy
  (BackendPhiCopy i64 CompilerBackendPhiSource AstType))

(defenum CompilerBackendPhiCopyList
  (BackendPhiCopyNil)
  (BackendPhiCopyCons CompilerBackendPhiCopy (Box CompilerBackendPhiCopyList)))

(define (compiler-backend-phi-copy-cons
  [copy : CompilerBackendPhiCopy]
  [rest : CompilerBackendPhiCopyList]) : CompilerBackendPhiCopyList
  (BackendPhiCopyCons copy (box rest)))

(defenum CompilerBackendMaybePhiCopy
  (BackendNoPhiCopy)
  (BackendSomePhiCopy CompilerBackendPhiCopy))

(defenum ResultBackendPhiCopies
  (OkBackendPhiCopies CompilerBackendPhiCopyList)
  (ErrBackendPhiCopies String))

(defenum CompilerBackendPhiReturnMatch
  (BackendNoPhiReturnMatch)
  (BackendSomePhiReturnMatch CompilerIrValue))

(defenum ResultBackendPhiReturnMatch
  (OkBackendPhiReturnMatch CompilerBackendPhiReturnMatch)
  (ErrBackendPhiReturnMatch String))

(defenum CompilerBackendMaybeImmediate
  (CompilerBackendNoImmediate)
  (CompilerBackendSomeImmediate String))

(defenum CompilerBackendMaybeAsm
  (CompilerBackendNoAsm)
  (CompilerBackendSomeAsm String))

(defenum CompilerBackendPeepholeMove
  (CompilerBackendPeepholeNoMove)
  (CompilerBackendPeepholeMove String String))

(defenum CompilerBackendMaybeI64
  (CompilerBackendNoI64)
  (CompilerBackendSomeI64 i64))

(defenum CompilerBackendUnsignedDivMagic
  (CompilerBackendNoUnsignedDivMagic)
  (CompilerBackendUnsignedDivMagicRoundUp u64 i64)
  (CompilerBackendUnsignedDivMagicRoundDown u64 i64))

(defenum CompilerBackendMaybeLabel
  (CompilerBackendNoLabel)
  (CompilerBackendSomeLabel String))

(defenum CompilerBackendMaybeSignature
  (CompilerBackendNoSignature)
  (CompilerBackendSomeSignature AstTypeList AstType))

(defenum CompilerBackendGlobalTypeList
  (CompilerBackendGlobalTypeNil)
  (CompilerBackendGlobalTypeCons
    String
    AstType
    (Box CompilerBackendGlobalTypeList))
  (CompilerBackendGlobalTypeCache StringI64Map (Array AstType)))

(defenum ResultCompilerBackend
  (OkCompilerBackend String)
  (ErrCompilerBackend CompilerDiagnostic))

(defenum ResultCompilerBackendObject
  (OkCompilerBackendObject CompilerObjectImage)
  (ErrCompilerBackendObject CompilerDiagnostic))

(defstruct CompilerBackendPicOutput
  (asm String)
  (fixups String))

(defstruct CompilerBackendAddressBase
  (asm String)
  (reg String))

(defenum ResultCompilerBackendAddressBase
  (OkCompilerBackendAddressBase CompilerBackendAddressBase)
  (ErrCompilerBackendAddressBase CompilerDiagnostic))

(defstruct CompilerBackendU64DivPow2
  (quot u64)
  (rem u64)
  (overflow bool))

(defstruct CompilerBackendSignedDivMagic
  (magic u64)
  (shift i64))

(defenum ResultCompilerBackendPic
  (OkCompilerBackendPic CompilerBackendPicOutput)
  (ErrCompilerBackendPic CompilerDiagnostic))

(defstruct CompilerBackendRuntimeTailPlan
  (profile bool)
  (hash-string bool))

(defenum CompilerBackendRuntimeHelperOwner
  (BackendRuntimeOwnerUnknown)
  (BackendRuntimeOwnerCore)
  (BackendRuntimeOwnerStdlibFfi)
  (BackendRuntimeOwnerStdlibTypeLisp)
  (BackendRuntimeOwnerCompatibilityAlias)
  (BackendRuntimeOwnerDeprecated))

(defenum ResultCompilerBackendBuffer
  (OkCompilerBackendBuffer TextBuf)
  (ErrCompilerBackendBuffer CompilerDiagnostic))

(defenum ResultCompilerBackendSymbolValidation
  (OkCompilerBackendSymbolValidation StringI64Map)
  (ErrCompilerBackendSymbolValidation CompilerDiagnostic))

(defenum CompilerBackendRuntimePlan
  (BackendRuntimePlan
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    bool
    CompilerBackendRuntimeTailPlan))

(defstruct CompilerBackendRuntimeIndex
  (defines StringI64Map)
  (externs StringI64Map)
  (calls StringI64Map)
  (needs-div-abort bool)
  (needs-shift-abort bool))

(defstruct CompilerBackendProgramIndex
  (functions I64I64Map)
  (function-names (Array String))
  (function-signatures (Array CompilerBackendMaybeSignature))
  (extern-signatures I64I64Map)
  (extern-names (Array String))
  (extern-signature-values (Array CompilerBackendMaybeSignature))
  (extern-references I64I64Map)
  (extern-link-symbols (Array String))
  (extern-provided (Array bool))
  ;; #2386: aggregate type name -> machine-word count, for every register-group
  ;; type constructed anywhere in the program (whole-program compile). Drives the
  ;; backend/regalloc 2-word-vs-handle decision that the type name alone cannot.
  (group-word-counts StringI64Map)
  ;; #2601: aggregate type name -> bit mask of SSE-class words. Bit 0 marks
  ;; word0, bit 1 marks word1. A missing/zero mask means all INTEGER words.
  (group-word-class-masks StringI64Map))

(defstruct CompilerBackendSourceSpanIndex
  (entries StringI64Map)
  (values (Array CompilerMaybeSourceSpan)))

(define (compiler-backend-runtime-tail-profile?
  [tail : CompilerBackendRuntimeTailPlan]) : bool
  (struct-get tail profile))

(define (compiler-backend-runtime-tail-hash-string?
  [tail : CompilerBackendRuntimeTailPlan]) : bool
  (struct-get tail hash-string))

;; Backend code-generation target (#646). Linux/System V and Windows x64 are
;; both modeled here; target-specific runtime helpers are emitted below.
(defenum CompilerBackendTarget
  (BackendTargetLinux)
  (BackendTargetWindows))

(defenum CompilerBackendMode
  (BackendModeScalar)
  (BackendModeAvx2)
  (BackendModeAvx512))

(define (compiler-backend-mode-scalar? [mode : CompilerBackendMode]) : bool
  (match mode
    [(BackendModeScalar) true]
    [_ false]))

;; Whether scalar functions get full register allocation (#perf). Register
;; allocation makes the EMITTED binary faster but its planning + register-aware
;; emission cost more compile time than it saves on a single self-compile, so it
;; is reserved for opt level 2 â€” the high-quality path whose extra cost the
;; benchmark's 2x budget accommodates. opt levels 0-2 stay on the cheap
;; stack-only homing. The driver sets this from the opt level before emitting;
;; it is set deterministically per compile so a given opt level always produces
;; identical assembly (the stage2==stage3 fixpoint holds within each level). SIMD
;; (Avx2/Avx512) functions always use register allocation regardless.
(define compiler-backend-scalar-registers-enabled : bool
  false)

(define (compiler-backend-set-scalar-registers! [enabled : bool]) : unit
  (set! compiler-backend-scalar-registers-enabled enabled))

;; Per-emission cache for interned user-symbol mangling. The generation guard
;; keeps direct helper calls safe across intern-reset! reuse of numeric ids.
(define compiler-backend-user-symbol-cache-values : (Array String)
  (make-array String 262144))
(define compiler-backend-user-symbol-cache-epochs : (Array i64)
  (make-array i64 262144))
(define compiler-backend-user-symbol-cache-epoch : i64
  1)
(define compiler-backend-user-symbol-cache-count-value : i64
  0)
(define compiler-backend-user-symbol-cache-generation : i64
  -1)

(define (compiler-backend-user-symbol-cache-reset!) : unit
  (begin
    (set! compiler-backend-user-symbol-cache-count-value 0)
    (set!
      compiler-backend-user-symbol-cache-epoch
      (+ compiler-backend-user-symbol-cache-epoch 1))
    (set! compiler-backend-user-symbol-cache-generation (intern-generation))))

(define (compiler-backend-user-symbol-cache-ensure-current!) : unit
  (if (= compiler-backend-user-symbol-cache-generation (intern-generation))
    unit
    (compiler-backend-user-symbol-cache-reset!)))

(define (compiler-backend-user-symbol-cache-count) : i64
  compiler-backend-user-symbol-cache-count-value)

(define compiler-backend-addr-of-forwarding-enabled : bool
  false)
(define compiler-backend-addr-of-forwarding-src : (Array i64)
  (make-array i64 0))

(defenum ResultBackendRuntimePlan
  (OkBackendRuntimePlan CompilerBackendRuntimePlan)
  (ErrBackendRuntimePlan String))

(defenum BackendStringList
  (BackendStringNil)
  (BackendStringCons String (Box BackendStringList)))

(define (compiler-backend-string-cons
  [head : String]
  [rest : BackendStringList]) : BackendStringList
  (BackendStringCons head (box rest)))

(define (compiler-backend-empty-string-list) : BackendStringList
  BackendStringNil)

(define compiler-backend-current-phi-targets : BackendStringList
  (compiler-backend-empty-string-list))
(define compiler-backend-current-phi-target-count : i64
  0)

(define (compiler-backend-string-list-contains?
  [items : BackendStringList]
  [needle : String]) : bool
  (match items
    [(BackendStringNil) false]
    [(BackendStringCons head rest)
      (if (string-eq head needle)
        true
        (compiler-backend-string-list-contains? (box-get rest) needle))]))

(defstruct BackendStringSet
  (seen StringI64Map)
  (items BackendStringList))

(defstruct CompilerBackendProgramCollections
  (functions BackendStringSet)
  (strings BackendStringSet)
  (floats BackendStringSet)
  (bytes BackendStringSet)
  (uses-f64-neg bool))

(defenum CompilerBackendCollectState
  (BackendCollectCollections CompilerBackendProgramCollections)
  (BackendCollectGroupCounts StringI64Map)
  (BackendCollectGroupClassMasks StringI64Map CompilerRegVarTypes))

(define (compiler-backend-string-set-new [capacity : i64]) : BackendStringSet
  (BackendStringSet (string-i64-map-with-capacity capacity) BackendStringNil))

(define (compiler-backend-string-set-add
  [set : BackendStringSet]
  [text : String]) : BackendStringSet
  (if (string-i64-map-contains? (struct-get set seen) text)
    set
    (BackendStringSet
      (string-i64-map-put (struct-get set seen) text 1)
      (compiler-backend-string-cons text (struct-get set items)))))

(define (compiler-backend-program-collections-new) : CompilerBackendProgramCollections
  (CompilerBackendProgramCollections
    (compiler-backend-string-set-new 256)
    (compiler-backend-string-set-new 256)
    (compiler-backend-string-set-new 256)
    (compiler-backend-string-set-new 64)
    false))

(define (compiler-backend-program-collections-add-function
  [collections : CompilerBackendProgramCollections]
  [name : String]) : CompilerBackendProgramCollections
  (CompilerBackendProgramCollections
    (compiler-backend-string-set-add (struct-get collections functions) name)
    (struct-get collections strings)
    (struct-get collections floats)
    (struct-get collections bytes)
    (struct-get collections uses-f64-neg)))

(define (compiler-backend-program-collections-add-string
  [collections : CompilerBackendProgramCollections]
  [text : String]) : CompilerBackendProgramCollections
  (CompilerBackendProgramCollections
    (struct-get collections functions)
    (compiler-backend-string-set-add (struct-get collections strings) text)
    (struct-get collections floats)
    (struct-get collections bytes)
    (struct-get collections uses-f64-neg)))

(define (compiler-backend-program-collections-add-float
  [collections : CompilerBackendProgramCollections]
  [text : String]) : CompilerBackendProgramCollections
  (CompilerBackendProgramCollections
    (struct-get collections functions)
    (struct-get collections strings)
    (compiler-backend-string-set-add (struct-get collections floats) text)
    (struct-get collections bytes)
    (struct-get collections uses-f64-neg)))

(define (compiler-backend-program-collections-add-bytes
  [collections : CompilerBackendProgramCollections]
  [text : String]) : CompilerBackendProgramCollections
  (CompilerBackendProgramCollections
    (struct-get collections functions)
    (struct-get collections strings)
    (struct-get collections floats)
    (compiler-backend-string-set-add (struct-get collections bytes) text)
    (struct-get collections uses-f64-neg)))

(define (compiler-backend-program-collections-mark-f64-neg
  [collections : CompilerBackendProgramCollections]) : CompilerBackendProgramCollections
  (CompilerBackendProgramCollections
    (struct-get collections functions)
    (struct-get collections strings)
    (struct-get collections floats)
    (struct-get collections bytes)
    true))

;; Concatenate fixed string groups with one allocation and one linear copy per
;; piece, instead of the right-nested `string-append` chain that reallocates and
;; recopies each growing suffix. Output is byte-identical; this only removes the
;; quadratic copy amplification and the intermediate allocations.
(define (backend-cat3 [a : String] [b : String] [c : String]) : String
  (let
    [la : i64 (string-length a)]
    [lb : i64 (string-length b)]
    [lc : i64 (string-length c)]
    [total : i64 (+ la (+ lb lc))]
    (if (= total 0)
      ""
      (let
        [out : (Array u8) (make-array u8 total)]
        [dst : (MutPtr u8)
          (unsafe
            (array-data out))]
        (begin
          (text-buf-copy-chunk-into (& a) dst 0)
          (text-buf-copy-chunk-into (& b) dst la)
          (text-buf-copy-chunk-into (& c) dst (+ la lb))
          (unsafe
            (string-from-bytes (ptr-cast dst : (Ptr u8)) total)))))))

(define (backend-cat4 [a : String] [b : String] [c : String] [d : String]) : String
  (let
    [la : i64 (string-length a)]
    [lb : i64 (string-length b)]
    [lc : i64 (string-length c)]
    [ld : i64 (string-length d)]
    [total : i64 (+ la (+ lb (+ lc ld)))]
    (if (= total 0)
      ""
      (let
        [out : (Array u8) (make-array u8 total)]
        [dst : (MutPtr u8)
          (unsafe
            (array-data out))]
        (begin
          (text-buf-copy-chunk-into (& a) dst 0)
          (text-buf-copy-chunk-into (& b) dst la)
          (text-buf-copy-chunk-into (& c) dst (+ la lb))
          (text-buf-copy-chunk-into (& d) dst (+ la (+ lb lc)))
          (unsafe
            (string-from-bytes (ptr-cast dst : (Ptr u8)) total)))))))

(define (backend-cat5
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]) : String
  (let
    [la : i64 (string-length a)]
    [lb : i64 (string-length b)]
    [lc : i64 (string-length c)]
    [ld : i64 (string-length d)]
    [le : i64 (string-length e)]
    [total : i64 (+ la (+ lb (+ lc (+ ld le))))]
    (if (= total 0)
      ""
      (let
        [out : (Array u8) (make-array u8 total)]
        [dst : (MutPtr u8)
          (unsafe
            (array-data out))]
        (begin
          (text-buf-copy-chunk-into (& a) dst 0)
          (text-buf-copy-chunk-into (& b) dst la)
          (text-buf-copy-chunk-into (& c) dst (+ la lb))
          (text-buf-copy-chunk-into (& d) dst (+ la (+ lb lc)))
          (text-buf-copy-chunk-into (& e) dst (+ la (+ lb (+ lc ld))))
          (unsafe
            (string-from-bytes (ptr-cast dst : (Ptr u8)) total)))))))

(define (backend-and4 [a : bool] [b : bool] [c : bool] [d : bool]) : bool
  (and a b c d))

(define (backend-or4 [a : bool] [b : bool] [c : bool] [d : bool]) : bool
  (or a b c d))

(define (backend-and8
  [a : bool]
  [b : bool]
  [c : bool]
  [d : bool]
  [e : bool]
  [f : bool]
  [g : bool]
  [h : bool]) : bool
  (and (backend-and4 a b c d) (backend-and4 e f g h)))

(define (backend-or8
  [a : bool]
  [b : bool]
  [c : bool]
  [d : bool]
  [e : bool]
  [f : bool]
  [g : bool]
  [h : bool]) : bool
  (or (backend-or4 a b c d) (backend-or4 e f g h)))

;; Best-available diagnostic for a backend error originating inside `function`
;;
;; (#605). When the lowering provenance side table has a source span for the
;;
;; function, the diagnostic is stamped with that real line/column via
;;
;; `compiler-diagnostic-from-ast-span`; otherwise it falls back to the previous
;;
;; `path:1:1` location. `function` is the raw IR function name (the key used by
;;
;; the spans table), not the mangled assembly symbol.
(define (compiler-backend-source-span-index-fill
  [values : (Array CompilerMaybeSourceSpan)]
  [index : i64]) : unit
  (if (>= index (array-length values))
    unit
    (begin
      (array-set! values index (CompilerNoSourceSpan))
      (compiler-backend-source-span-index-fill values (+ index 1)))))

(define (compiler-backend-source-span-index-add
  [entries : CompilerSourceSpansEntryList]
  [map : StringI64Map]
  [values : (Array CompilerMaybeSourceSpan)]
  [index : i64]) : StringI64Map
  (match entries
    [(CompilerSourceSpansEntryNil) map]
    [(CompilerSourceSpansEntryCons entry rest)
      (match entry
        [(CompilerSourceSpansEntry name span)
          (if (string-i64-map-contains? map name)
            (compiler-backend-source-span-index-add
              (box-get rest)
              map
              values
              index)
            (match (string-i64-map-insert map name index)
              [(StringI64MapInsertOk next-map)
                (begin
                  (array-set! values index (CompilerSomeSourceSpan span))
                  (compiler-backend-source-span-index-add
                    (box-get rest)
                    next-map
                    values
                    (+ index 1)))]
              [(StringI64MapInsertFull next-map) next-map]))])]))

(define (compiler-backend-source-span-index-build [spans : CompilerSourceSpans]) : CompilerBackendSourceSpanIndex
  (match spans
    [(CompilerSourceSpans entries _ _)
      (let
        [count : i64 (compiler-source-spans-count spans)]
        [values : (Array CompilerMaybeSourceSpan)
          (make-array CompilerMaybeSourceSpan count)]
        (begin
          (compiler-backend-source-span-index-fill values 0)
          (CompilerBackendSourceSpanIndex
            (compiler-backend-source-span-index-add
              entries
              (string-i64-map-with-capacity (+ (* count 2) 16))
              values
              0)
            values)))]))

(define (compiler-backend-source-span-index-lookup
  [index : CompilerBackendSourceSpanIndex]
  [name : String]) : CompilerMaybeSourceSpan
  (match (string-i64-map-get (struct-get index entries) name)
    [(StringI64MapFound slot)
      (if (and (>= slot 0) (< slot (array-length (struct-get index values))))
        (array-ref (struct-get index values) slot)
        (CompilerNoSourceSpan))]
    [(StringI64MapMissing) (CompilerNoSourceSpan)]))

(define (compiler-backend-function-diagnostic-index
  [index : CompilerBackendSourceSpanIndex]
  [function : String]
  [message : String]) : CompilerDiagnostic
  (match (compiler-backend-source-span-index-lookup index function)
    [(CompilerSomeSourceSpan span)
      (compiler-diagnostic-from-ast-span "" span message)]
    [(CompilerNoSourceSpan) (compiler-diagnostic-at-start "" message)]))

(define (compiler-backend-function-diagnostic
  [spans : CompilerSourceSpans]
  [function : String]
  [message : String]) : CompilerDiagnostic
  (match (compiler-source-spans-lookup spans function)
    [(CompilerSomeSourceSpan span)
      (compiler-diagnostic-from-ast-span "" span message)]
    [(CompilerNoSourceSpan) (compiler-diagnostic-at-start "" message)]))

(define (compiler-backend-instr-diagnostic
  [spans : CompilerSourceSpans]
  [function : String]
  [instr : CompilerIrInstr]
  [fallback : CompilerDiagnostic]
  [message : String]) : CompilerDiagnostic
  (match (compiler-source-spans-lookup-instr spans function instr)
    [(CompilerSomeSourceSpan span)
      (compiler-diagnostic-from-ast-span "" span message)]
    [(CompilerNoSourceSpan) (compiler-diagnostic-with-message fallback message)]))

(define (compiler-backend-apply-instr-diagnostic
  [diag : CompilerDiagnostic]
  [instr-diag : CompilerDiagnostic]) : CompilerDiagnostic
  (compiler-diagnostic-with-message
    instr-diag
    (compiler-diagnostic-message diag)))

(define (compiler-backend-vector-mask-unimplemented
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (ErrCompilerBackend
    (compiler-diagnostic-with-message
      instr-diag
      "backend: vector/mask IR emission is not implemented")))

(define (compiler-backend-mode-prologue [mode : CompilerBackendMode]) : String
  (match mode
    [(BackendModeAvx2) "    vzeroupper\n"]
    [_ ""]))

(define (compiler-backend-dispatch-avx2-prefix) : String
  "__tl_dispatch_variant_avx2_")

(define (compiler-backend-dispatch-avx512-prefix) : String
  "__tl_dispatch_variant_avx512_")

(define (compiler-backend-effective-mode-for-function-name
  [mode : CompilerBackendMode]
  [name : String]) : CompilerBackendMode
  (if (compiler-backend-string-prefix-at?
    name
    (compiler-backend-dispatch-avx512-prefix)
    0)
    (BackendModeAvx512)
    (if (compiler-backend-string-prefix-at?
      name
      (compiler-backend-dispatch-avx2-prefix)
      0)
      (BackendModeAvx2)
      mode)))

(define (compiler-backend-effective-function-mode
  [mode : CompilerBackendMode]
  [func : CompilerIrFunction]) : CompilerBackendMode
  (match func
    [(IrFunction name _ _ _ _)
      (compiler-backend-effective-mode-for-function-name mode name)]))

(define (compiler-backend-avx2-shape-ok? [elem-ty : AstType] [lanes : i64]) : bool
  (match elem-ty
    [(AstTyI64) (= lanes 4)]
    [(AstTyU64) (= lanes 4)]
    [(AstTyF64) (= lanes 4)]
    [(AstTyF32) (= lanes 8)]
    [(AstTyI32) (= lanes 8)]
    [(AstTyU32) (= lanes 8)]
    [(AstTyI16) (= lanes 16)]
    [(AstTyU16) (= lanes 16)]
    [(AstTyI8) (= lanes 32)]
    [(AstTyU8) (= lanes 32)]
    [_ false]))

(define (compiler-backend-avx2-shape-diagnostic
  [instr-diag : CompilerDiagnostic]
  [elem-ty : AstType]
  [lanes : i64]) : ResultCompilerBackend
  (ErrCompilerBackend
    (compiler-diagnostic-with-message
      instr-diag
      (str-cat
        "backend: unsupported AVX2 vector shape "
        (int->string lanes)
        " x "
        (compiler-ir-type-name elem-ty)))))

(define (compiler-backend-vector-home-to-ymm [home : String]) : String
  (cond
    [(string-eq home "%vec6") "%ymm6"]
    [(string-eq home "%vec7") "%ymm7"]
    [(string-eq home "%vec8") "%ymm8"]
    [(string-eq home "%vec9") "%ymm9"]
    [(string-eq home "%vec10") "%ymm10"]
    [(string-eq home "%vec11") "%ymm11"]
    [(string-eq home "%vec12") "%ymm12"]
    [(string-eq home "%vec13") "%ymm13"]
    [else ""]))

(define (compiler-backend-vector-home-to-xmm [home : String]) : String
  (cond
    [(string-eq home "%vec6") "%xmm6"]
    [(string-eq home "%vec7") "%xmm7"]
    [(string-eq home "%vec8") "%xmm8"]
    [(string-eq home "%vec9") "%xmm9"]
    [(string-eq home "%vec10") "%xmm10"]
    [(string-eq home "%vec11") "%xmm11"]
    [(string-eq home "%vec12") "%xmm12"]
    [(string-eq home "%vec13") "%xmm13"]
    [else ""]))

(define (compiler-backend-vector-home-to-zmm [home : String]) : String
  (cond
    [(string-eq home "%vec6") "%zmm6"]
    [(string-eq home "%vec7") "%zmm7"]
    [(string-eq home "%vec8") "%zmm8"]
    [(string-eq home "%vec9") "%zmm9"]
    [(string-eq home "%vec10") "%zmm10"]
    [(string-eq home "%vec11") "%zmm11"]
    [(string-eq home "%vec12") "%zmm12"]
    [(string-eq home "%vec13") "%zmm13"]
    [else ""]))

(define (compiler-backend-vector-home-unavailable [role : String]) : String
  (str-cat
    "backend: vector register home unavailable for "
    role
    "; unsupported spill, call, or ABI lifetime"))

(define (compiler-backend-mask-home-unavailable [role : String]) : String
  (str-cat
    "backend: mask register home unavailable for "
    role
    "; unsupported spill, call, or ABI lifetime"))

(define (compiler-backend-vector-var-reg
  [assignments : CompilerRegAssignmentList]
  [var : i64]
  [role : String]
  [width : String]) : ResultBackendReg
  (match (compiler-reg-assignment-lookup assignments var)
    [(CompilerRegSomeLocation location)
      (match location
        [(CompilerRegRegister home)
          (let
            [reg : String
              (if (string-eq width "xmm")
                (compiler-backend-vector-home-to-xmm home)
                (if (string-eq width "zmm")
                  (compiler-backend-vector-home-to-zmm home)
                  (compiler-backend-vector-home-to-ymm home)))]
            (if (= (string-length reg) 0)
              (ErrBackendReg (compiler-backend-vector-home-unavailable role))
              (OkBackendReg reg)))]
        [(CompilerRegRegisterPair _ _)
          (ErrBackendReg (compiler-backend-vector-home-unavailable role))]
        [(CompilerRegSpill _)
          (ErrBackendReg
            (string-append
              "backend: vector spills are not implemented for "
              role))])]
    [(CompilerRegNoLocation)
      (ErrBackendReg (compiler-backend-vector-home-unavailable role))]))

(define (compiler-backend-mask-var-reg
  [assignments : CompilerRegAssignmentList]
  [var : i64]
  [role : String]) : ResultBackendReg
  (match (compiler-reg-assignment-lookup assignments var)
    [(CompilerRegSomeLocation location)
      (match location
        [(CompilerRegRegister home)
          (if (compiler-reg-string-list-contains?
            (compiler-reg-mask-registers)
            home)
            (OkBackendReg home)
            (ErrBackendReg (compiler-backend-mask-home-unavailable role)))]
        [(CompilerRegRegisterPair _ _)
          (ErrBackendReg (compiler-backend-mask-home-unavailable role))]
        [(CompilerRegSpill _)
          (ErrBackendReg
            (string-append "backend: mask spills are not implemented for " role))])]
    [(CompilerRegNoLocation)
      (ErrBackendReg (compiler-backend-mask-home-unavailable role))]))

(define (compiler-backend-avx2-vector-value-reg
  [assignments : CompilerRegAssignmentList]
  [value : CompilerIrValue]
  [role : String]) : ResultBackendReg
  (match value
    [(IrValueVar var)
      (compiler-backend-vector-var-reg assignments var role "ymm")]
    [_ (ErrBackendReg (string-append "backend: unsupported AVX2 vector " role))]))

(define (compiler-backend-avx2-vector-move [elem-ty : AstType]) : String
  (match elem-ty
    [(AstTyF64) "vmovupd"]
    [(AstTyF32) "vmovups"]
    [_ "vmovdqu"]))

(define (compiler-backend-avx2-vector-binop-mnemonic
  [op : CompilerIrBinOp]
  [elem-ty : AstType]) : String
  (match op
    [(IrBinAdd)
      (match elem-ty
        [(AstTyI64) "vpaddq"]
        [(AstTyU64) "vpaddq"]
        [(AstTyI32) "vpaddd"]
        [(AstTyU32) "vpaddd"]
        [(AstTyI16) "vpaddw"]
        [(AstTyU16) "vpaddw"]
        [(AstTyI8) "vpaddb"]
        [(AstTyU8) "vpaddb"]
        [(AstTyF64) "vaddpd"]
        [(AstTyF32) "vaddps"]
        [_ ""])]
    [(IrBinMul)
      (match elem-ty
        [(AstTyI32) "vpmulld"]
        [(AstTyU32) "vpmulld"]
        [(AstTyI16) "vpmullw"]
        [(AstTyU16) "vpmullw"]
        [(AstTyF64) "vmulpd"]
        [(AstTyF32) "vmulps"]
        [_ ""])]
    [_ ""]))

(define (compiler-backend-avx2-i64-vector-mul?
  [op : CompilerIrBinOp]
  [elem-ty : AstType]) : bool
  (match op
    [(IrBinMul)
      (match elem-ty
        [(AstTyI64) true]
        [(AstTyU64) true]
        [_ false])]
    [_ false]))

(define (compiler-backend-avx2-vector-reduce-op-mnemonic
  [op : CompilerIrVectorReduceOp]
  [elem-ty : AstType]) : String
  (match op
    [(IrVectorReduceSum)
      (match elem-ty
        [(AstTyI64) "vpaddq"]
        [(AstTyI32) "vpaddd"]
        [(AstTyF64) "vaddpd"]
        [_ ""])]
    [(IrVectorReduceMin)
      (match elem-ty
        [(AstTyI32) "vpminsd"]
        [_ ""])]
    [(IrVectorReduceMax)
      (match elem-ty
        [(AstTyI32) "vpmaxsd"]
        [_ ""])]))

(define (compiler-backend-avx2-indexed-addr [elem-ty : AstType]) : String
  (str-cat "(%rax,%rcx," (int->string (compiler-backend-type-size elem-ty)) ")"))

(define (compiler-backend-emit-avx2-base-index
  [assignments : CompilerRegAssignmentList]
  [base : CompilerIrValue]
  [index : CompilerIrValue]) : ResultCompilerBackend
  (match (compiler-backend-emit-load-value-with-plan assignments base "%rax")
    [(OkCompilerBackend base-asm)
      (match (compiler-backend-emit-load-value-with-plan
        assignments
        index
        "%rcx")
        [(OkCompilerBackend index-asm)
          (OkCompilerBackend
            (string-append
              base-asm
              (string-append "    movq 0(%rax), %rax\n" index-asm)))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
    [(ErrCompilerBackend message) (ErrCompilerBackend message)]))

(define (compiler-backend-emit-avx2-vector-load
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [base : CompilerIrValue]
  [index : CompilerIrValue]
  [lanes : i64]
  [elem-ty : AstType]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (if (compiler-backend-avx2-shape-ok? elem-ty lanes)
    (match (compiler-backend-vector-var-reg assignments dst "load dst" "ymm")
      [(OkBackendReg dst-reg)
        (match (compiler-backend-emit-avx2-base-index assignments base index)
          [(OkCompilerBackend addr-asm)
            (OkCompilerBackend
              (string-append
                addr-asm
                (string-append
                  (str-cat
                    "    "
                    (compiler-backend-avx2-vector-move elem-ty)
                    " "
                    (compiler-backend-avx2-indexed-addr elem-ty)
                    ", ")
                  (str-cat dst-reg "\n"))))]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(ErrBackendReg message)
        (ErrCompilerBackend
          (compiler-diagnostic-with-message instr-diag message))])
    (compiler-backend-avx2-shape-diagnostic instr-diag elem-ty lanes)))

(define (compiler-backend-avx2-splat-load
  [assignments : CompilerRegAssignmentList]
  [value : CompilerIrValue]
  [elem-ty : AstType]) : ResultCompilerBackend
  (match elem-ty
    [(AstTyF64)
      (match (compiler-backend-emit-load-float-value-with-plan
        assignments
        value
        elem-ty
        "%xmm0")
        [(OkCompilerBackend asm)
          (OkCompilerBackend (string-append asm "    vbroadcastsd %xmm0, "))]
        [(ErrCompilerBackend diag) (ErrCompilerBackend diag)])]
    [(AstTyF32)
      (match (compiler-backend-emit-load-float-value-with-plan
        assignments
        value
        elem-ty
        "%xmm0")
        [(OkCompilerBackend asm)
          (OkCompilerBackend (string-append asm "    vbroadcastss %xmm0, "))]
        [(ErrCompilerBackend diag) (ErrCompilerBackend diag)])]
    [(AstTyI32)
      (match (compiler-backend-emit-load-value-with-plan
        assignments
        value
        "%rax")
        [(OkCompilerBackend asm)
          (OkCompilerBackend
            (string-append
              asm
              "    vmovd %eax, %xmm0\n    vpbroadcastd %xmm0, "))]
        [(ErrCompilerBackend diag) (ErrCompilerBackend diag)])]
    [(AstTyU32)
      (match (compiler-backend-emit-load-value-with-plan
        assignments
        value
        "%rax")
        [(OkCompilerBackend asm)
          (OkCompilerBackend
            (string-append
              asm
              "    vmovd %eax, %xmm0\n    vpbroadcastd %xmm0, "))]
        [(ErrCompilerBackend diag) (ErrCompilerBackend diag)])]
    [(AstTyI16)
      (match (compiler-backend-emit-load-value-with-plan
        assignments
        value
        "%rax")
        [(OkCompilerBackend asm)
          (OkCompilerBackend
            (string-append
              asm
              "    vmovd %eax, %xmm0\n    vpbroadcastw %xmm0, "))]
        [(ErrCompilerBackend diag) (ErrCompilerBackend diag)])]
    [(AstTyU16)
      (match (compiler-backend-emit-load-value-with-plan
        assignments
        value
        "%rax")
        [(OkCompilerBackend asm)
          (OkCompilerBackend
            (string-append
              asm
              "    vmovd %eax, %xmm0\n    vpbroadcastw %xmm0, "))]
        [(ErrCompilerBackend diag) (ErrCompilerBackend diag)])]
    [(AstTyI8)
      (match (compiler-backend-emit-load-value-with-plan
        assignments
        value
        "%rax")
        [(OkCompilerBackend asm)
          (OkCompilerBackend
            (string-append
              asm
              "    vmovd %eax, %xmm0\n    vpbroadcastb %xmm0, "))]
        [(ErrCompilerBackend diag) (ErrCompilerBackend diag)])]
    [(AstTyU8)
      (match (compiler-backend-emit-load-value-with-plan
        assignments
        value
        "%rax")
        [(OkCompilerBackend asm)
          (OkCompilerBackend
            (string-append
              asm
              "    vmovd %eax, %xmm0\n    vpbroadcastb %xmm0, "))]
        [(ErrCompilerBackend diag) (ErrCompilerBackend diag)])]
    [_
      (match (compiler-backend-emit-load-value-with-plan
        assignments
        value
        "%rax")
        [(OkCompilerBackend asm)
          (OkCompilerBackend
            (string-append
              asm
              "    vmovq %rax, %xmm0\n    vpbroadcastq %xmm0, "))]
        [(ErrCompilerBackend diag) (ErrCompilerBackend diag)])]))

(define (compiler-backend-emit-avx2-splat
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [value : CompilerIrValue]
  [lanes : i64]
  [elem-ty : AstType]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (if (compiler-backend-avx2-shape-ok? elem-ty lanes)
    (match (compiler-backend-vector-var-reg assignments dst "splat dst" "ymm")
      [(OkBackendReg dst-reg)
        (match (compiler-backend-avx2-splat-load assignments value elem-ty)
          [(OkCompilerBackend load-asm)
            (OkCompilerBackend (str-cat load-asm dst-reg "\n"))]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(ErrBackendReg message)
        (ErrCompilerBackend
          (compiler-diagnostic-with-message instr-diag message))])
    (compiler-backend-avx2-shape-diagnostic instr-diag elem-ty lanes)))

(define (compiler-backend-emit-avx2-i64-vector-mul
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (match (compiler-backend-avx2-vector-value-reg assignments lhs "lhs")
    [(OkBackendReg lhs-reg)
      (match (compiler-backend-avx2-vector-value-reg assignments rhs "rhs")
        [(OkBackendReg rhs-reg)
          (match (compiler-backend-vector-var-reg
            assignments
            dst
            "binop dst"
            "ymm")
            [(OkBackendReg dst-reg)
              (OkCompilerBackend
                (string-append
                  (str-cat "    vpsrlq $32, " lhs-reg ", %ymm0\n")
                  (string-append
                    (str-cat "    vpmuludq " rhs-reg ", %ymm0, %ymm0\n")
                    (string-append
                      (str-cat "    vpsrlq $32, " rhs-reg ", %ymm1\n")
                      (string-append
                        (str-cat "    vpmuludq " lhs-reg ", %ymm1, %ymm1\n")
                        (string-append
                          "    vpaddq %ymm1, %ymm0, %ymm0\n    vpsllq $32, %ymm0, %ymm0\n"
                          (string-append
                            (str-cat "    vpmuludq " rhs-reg ", " lhs-reg ", ")
                            (string-append
                              (str-cat dst-reg "\n")
                              (str-cat
                                "    vpaddq %ymm0, "
                                dst-reg
                                ", "
                                dst-reg
                                "\n")))))))))]
            [(ErrBackendReg message)
              (ErrCompilerBackend
                (compiler-diagnostic-with-message instr-diag message))])]
        [(ErrBackendReg message)
          (ErrCompilerBackend
            (compiler-diagnostic-with-message instr-diag message))])]
    [(ErrBackendReg message)
      (ErrCompilerBackend (compiler-diagnostic-with-message instr-diag message))]))

(define (compiler-backend-emit-avx2-vector-binop
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [op : CompilerIrBinOp]
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [lanes : i64]
  [elem-ty : AstType]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (if (compiler-backend-avx2-shape-ok? elem-ty lanes)
    (let
      [mnemonic : String
        (compiler-backend-avx2-vector-binop-mnemonic op elem-ty)]
      (if (compiler-backend-avx2-i64-vector-mul? op elem-ty)
        (compiler-backend-emit-avx2-i64-vector-mul
          assignments
          dst
          lhs
          rhs
          instr-diag)
        (if (= (string-length mnemonic) 0)
          (ErrCompilerBackend
            (compiler-diagnostic-with-message
              instr-diag
              "backend: unsupported AVX2 vector binary op"))
          (match (compiler-backend-avx2-vector-value-reg assignments lhs "lhs")
            [(OkBackendReg lhs-reg)
              (match (compiler-backend-avx2-vector-value-reg
                assignments
                rhs
                "rhs")
                [(OkBackendReg rhs-reg)
                  (match (compiler-backend-vector-var-reg
                    assignments
                    dst
                    "binop dst"
                    "ymm")
                    [(OkBackendReg dst-reg)
                      (OkCompilerBackend
                        (string-append
                          (str-cat "    " mnemonic " " rhs-reg ", ")
                          (str-cat lhs-reg ", " dst-reg "\n")))]
                    [(ErrBackendReg message)
                      (ErrCompilerBackend
                        (compiler-diagnostic-with-message instr-diag message))])]
                [(ErrBackendReg message)
                  (ErrCompilerBackend
                    (compiler-diagnostic-with-message instr-diag message))])]
            [(ErrBackendReg message)
              (ErrCompilerBackend
                (compiler-diagnostic-with-message instr-diag message))]))))
    (compiler-backend-avx2-shape-diagnostic instr-diag elem-ty lanes)))

(define (compiler-backend-emit-avx2-vector-store
  [assignments : CompilerRegAssignmentList]
  [base : CompilerIrValue]
  [index : CompilerIrValue]
  [value : CompilerIrValue]
  [lanes : i64]
  [elem-ty : AstType]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (if (compiler-backend-avx2-shape-ok? elem-ty lanes)
    (match (compiler-backend-avx2-vector-value-reg
      assignments
      value
      "store value")
      [(OkBackendReg value-reg)
        (match (compiler-backend-emit-avx2-base-index assignments base index)
          [(OkCompilerBackend addr-asm)
            (OkCompilerBackend
              (string-append
                addr-asm
                (string-append
                  (str-cat
                    "    "
                    (compiler-backend-avx2-vector-move elem-ty)
                    " "
                    value-reg
                    ", ")
                  (str-cat (compiler-backend-avx2-indexed-addr elem-ty) "\n"))))]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(ErrBackendReg message)
        (ErrCompilerBackend
          (compiler-diagnostic-with-message instr-diag message))])
    (compiler-backend-avx2-shape-diagnostic instr-diag elem-ty lanes)))

(define (compiler-backend-avx512-shape-ok? [elem-ty : AstType] [lanes : i64]) : bool
  (match elem-ty
    [(AstTyI64) (= lanes 8)]
    [(AstTyU64) (= lanes 8)]
    [(AstTyF64) (= lanes 8)]
    [(AstTyF32) (= lanes 16)]
    [(AstTyI32) (= lanes 16)]
    [(AstTyU32) (= lanes 16)]
    [(AstTyI16) (= lanes 32)]
    [(AstTyU16) (= lanes 32)]
    [(AstTyI8) (= lanes 64)]
    [(AstTyU8) (= lanes 64)]
    [_ false]))

(define (compiler-backend-avx512-shape-diagnostic
  [instr-diag : CompilerDiagnostic]
  [elem-ty : AstType]
  [lanes : i64]) : ResultCompilerBackend
  (ErrCompilerBackend
    (compiler-diagnostic-with-message
      instr-diag
      (str-cat
        "backend: unsupported AVX-512 vector shape "
        (int->string lanes)
        " x "
        (compiler-ir-type-name elem-ty)))))

(define (compiler-backend-avx512-vector-value-reg
  [assignments : CompilerRegAssignmentList]
  [value : CompilerIrValue]
  [role : String]) : ResultBackendReg
  (match value
    [(IrValueVar var)
      (compiler-backend-vector-var-reg assignments var role "zmm")]
    [_
      (ErrBackendReg
        (string-append "backend: unsupported AVX-512 vector " role))]))

(define (compiler-backend-avx512-mask-value-reg
  [assignments : CompilerRegAssignmentList]
  [value : CompilerIrValue]
  [role : String]) : ResultBackendReg
  (match value
    [(IrValueVar var) (compiler-backend-mask-var-reg assignments var role)]
    [_
      (ErrBackendReg (string-append "backend: unsupported AVX-512 mask " role))]))

(define (compiler-backend-avx512-vector-move [elem-ty : AstType]) : String
  (match elem-ty
    [(AstTyF64) "vmovupd"]
    [(AstTyF32) "vmovups"]
    [(AstTyI64) "vmovdqu64"]
    [(AstTyU64) "vmovdqu64"]
    [(AstTyI32) "vmovdqu32"]
    [(AstTyU32) "vmovdqu32"]
    [(AstTyI16) "vmovdqu16"]
    [(AstTyU16) "vmovdqu16"]
    [(AstTyI8) "vmovdqu8"]
    [(AstTyU8) "vmovdqu8"]
    [_ ""]))

(define (compiler-backend-avx512-vector-binop-mnemonic
  [op : CompilerIrBinOp]
  [elem-ty : AstType]) : String
  (match op
    [(IrBinAdd)
      (match elem-ty
        [(AstTyI64) "vpaddq"]
        [(AstTyU64) "vpaddq"]
        [(AstTyI32) "vpaddd"]
        [(AstTyU32) "vpaddd"]
        [(AstTyI16) "vpaddw"]
        [(AstTyU16) "vpaddw"]
        [(AstTyI8) "vpaddb"]
        [(AstTyU8) "vpaddb"]
        [(AstTyF64) "vaddpd"]
        [(AstTyF32) "vaddps"]
        [_ ""])]
    [(IrBinMul)
      (match elem-ty
        [(AstTyI64) "vpmullq"]
        [(AstTyU64) "vpmullq"]
        [(AstTyI32) "vpmulld"]
        [(AstTyU32) "vpmulld"]
        [(AstTyI16) "vpmullw"]
        [(AstTyU16) "vpmullw"]
        [(AstTyF64) "vmulpd"]
        [(AstTyF32) "vmulps"]
        [_ ""])]
    [(IrBinBitAnd)
      (match elem-ty
        [(AstTyI64) "vpandq"]
        [(AstTyU64) "vpandq"]
        [(AstTyI32) "vpandd"]
        [(AstTyU32) "vpandd"]
        [_ ""])]
    [_ ""]))

(define (compiler-backend-avx512-vector-compare-mnemonic [elem-ty : AstType]) : String
  (match elem-ty
    [(AstTyI64) "vpcmpq"]
    [(AstTyU64) "vpcmpuq"]
    [(AstTyI32) "vpcmpd"]
    [(AstTyU32) "vpcmpud"]
    [(AstTyI16) "vpcmpw"]
    [(AstTyU16) "vpcmpuw"]
    [(AstTyI8) "vpcmpb"]
    [(AstTyU8) "vpcmpub"]
    [(AstTyF64) "vcmppd"]
    [(AstTyF32) "vcmpps"]
    [_ ""]))

(define (compiler-backend-avx512-compare-imm [op : CompilerIrBinOp]) : i64
  (match op
    [(IrBinEq) 0]
    [(IrBinLt) 1]
    [(IrBinLe) 2]
    [(IrBinNe) 4]
    [(IrBinGe) 5]
    [(IrBinGt) 6]
    [_ -1]))

(define (compiler-backend-avx512-splat-load
  [assignments : CompilerRegAssignmentList]
  [value : CompilerIrValue]
  [elem-ty : AstType]) : ResultCompilerBackend
  (match elem-ty
    [(AstTyF64)
      (match (compiler-backend-emit-load-float-value-with-plan
        assignments
        value
        elem-ty
        "%xmm0")
        [(OkCompilerBackend asm)
          (OkCompilerBackend (string-append asm "    vbroadcastsd %xmm0, "))]
        [(ErrCompilerBackend diag) (ErrCompilerBackend diag)])]
    [(AstTyF32)
      (match (compiler-backend-emit-load-float-value-with-plan
        assignments
        value
        elem-ty
        "%xmm0")
        [(OkCompilerBackend asm)
          (OkCompilerBackend (string-append asm "    vbroadcastss %xmm0, "))]
        [(ErrCompilerBackend diag) (ErrCompilerBackend diag)])]
    [(AstTyI32)
      (match (compiler-backend-emit-load-value-with-plan
        assignments
        value
        "%rax")
        [(OkCompilerBackend asm)
          (OkCompilerBackend (string-append asm "    vpbroadcastd %eax, "))]
        [(ErrCompilerBackend diag) (ErrCompilerBackend diag)])]
    [(AstTyU32)
      (match (compiler-backend-emit-load-value-with-plan
        assignments
        value
        "%rax")
        [(OkCompilerBackend asm)
          (OkCompilerBackend (string-append asm "    vpbroadcastd %eax, "))]
        [(ErrCompilerBackend diag) (ErrCompilerBackend diag)])]
    [(AstTyI16)
      (match (compiler-backend-emit-load-value-with-plan
        assignments
        value
        "%rax")
        [(OkCompilerBackend asm)
          (OkCompilerBackend
            (string-append
              asm
              "    vmovd %eax, %xmm0\n    vpbroadcastw %xmm0, "))]
        [(ErrCompilerBackend diag) (ErrCompilerBackend diag)])]
    [(AstTyU16)
      (match (compiler-backend-emit-load-value-with-plan
        assignments
        value
        "%rax")
        [(OkCompilerBackend asm)
          (OkCompilerBackend
            (string-append
              asm
              "    vmovd %eax, %xmm0\n    vpbroadcastw %xmm0, "))]
        [(ErrCompilerBackend diag) (ErrCompilerBackend diag)])]
    [(AstTyI8)
      (match (compiler-backend-emit-load-value-with-plan
        assignments
        value
        "%rax")
        [(OkCompilerBackend asm)
          (OkCompilerBackend
            (string-append
              asm
              "    vmovd %eax, %xmm0\n    vpbroadcastb %xmm0, "))]
        [(ErrCompilerBackend diag) (ErrCompilerBackend diag)])]
    [(AstTyU8)
      (match (compiler-backend-emit-load-value-with-plan
        assignments
        value
        "%rax")
        [(OkCompilerBackend asm)
          (OkCompilerBackend
            (string-append
              asm
              "    vmovd %eax, %xmm0\n    vpbroadcastb %xmm0, "))]
        [(ErrCompilerBackend diag) (ErrCompilerBackend diag)])]
    [_
      (match (compiler-backend-emit-load-value-with-plan
        assignments
        value
        "%rax")
        [(OkCompilerBackend asm)
          (OkCompilerBackend (string-append asm "    vpbroadcastq %rax, "))]
        [(ErrCompilerBackend diag) (ErrCompilerBackend diag)])]))

(define (compiler-backend-avx512-vector-reduce-op-mnemonic
  [op : CompilerIrVectorReduceOp]
  [elem-ty : AstType]) : String
  (match op
    [(IrVectorReduceMin)
      (match elem-ty
        [(AstTyI64) "vpminsq"]
        [_ (compiler-backend-avx2-vector-reduce-op-mnemonic op elem-ty)])]
    [(IrVectorReduceMax)
      (match elem-ty
        [(AstTyI64) "vpmaxsq"]
        [_ (compiler-backend-avx2-vector-reduce-op-mnemonic op elem-ty)])]
    [_ (compiler-backend-avx2-vector-reduce-op-mnemonic op elem-ty)]))

(define (compiler-backend-avx512-lane-mask [lanes : i64]) : i64
  (cond
    [(= lanes 8) 0xff]
    [(= lanes 16) 0xffff]
    [(= lanes 32) -1]
    [(= lanes 64) -1]
    [else 0]))

(define (compiler-backend-avx512-mask-op-suffix [lanes : i64]) : String
  (if (> lanes 32)
    "q"
    (if (> lanes 16)
      "d"
      "w")))

(define (compiler-backend-avx512-mask-int-suffix [lanes : i64]) : String
  (if (> lanes 32)
    "q"
    "l"))

(define (compiler-backend-avx512-mask-move-mnemonic [lanes : i64]) : String
  (string-append "kmov" (compiler-backend-avx512-mask-op-suffix lanes)))

(define (compiler-backend-avx512-mask-gpr [lanes : i64]) : String
  (if (> lanes 32)
    "%rax"
    "%eax"))

(define (compiler-backend-avx512-mask-mov-imm-mnemonic [lanes : i64]) : String
  (string-append "mov" (compiler-backend-avx512-mask-int-suffix lanes)))

(define (compiler-backend-avx512-mask-shl-mnemonic [lanes : i64]) : String
  (string-append "shl" (compiler-backend-avx512-mask-int-suffix lanes)))

(define (compiler-backend-avx512-mask-sub-mnemonic [lanes : i64]) : String
  (string-append "sub" (compiler-backend-avx512-mask-int-suffix lanes)))

(define (compiler-backend-avx512-mask-xor-mnemonic [lanes : i64]) : String
  (string-append "xor" (compiler-backend-avx512-mask-int-suffix lanes)))

(define (compiler-backend-avx512-mask-kortest-mnemonic [lanes : i64]) : String
  (string-append "kortest" (compiler-backend-avx512-mask-op-suffix lanes)))

(define (compiler-backend-avx512-mask-cmp-mnemonic [lanes : i64]) : String
  (string-append "cmp" (compiler-backend-avx512-mask-int-suffix lanes)))

(define (compiler-backend-avx512-mask-label
  [function : String]
  [current-label : String]
  [dst : i64]
  [suffix : String]) : String
  (compiler-backend-asm-label
    function
    (str-cat "tail_mask_" current-label "_v" (int->string dst) suffix)))

(define (compiler-backend-lane-id-label
  [function : String]
  [current-label : String]
  [dst : i64]
  [suffix : String]) : String
  (compiler-backend-asm-label
    function
    (str-cat "lane_id_" current-label "_v" (int->string dst) suffix)))

(define (compiler-backend-lane-id-avx512-i64-shape-ok?
  [elem-ty : AstType]
  [lanes : i64]) : bool
  (match elem-ty
    [(AstTyI64) (= lanes 8)]
    [(AstTyU64) (= lanes 8)]
    [_ false]))

(define (compiler-backend-lane-id-avx2-i64-shape-ok?
  [elem-ty : AstType]
  [lanes : i64]) : bool
  (match elem-ty
    [(AstTyI64) (= lanes 4)]
    [(AstTyU64) (= lanes 4)]
    [_ false]))

(define (compiler-backend-avx512-i64-lane-id-data) : String
  "    .quad 0
    .quad 1
    .quad 2
    .quad 3
    .quad 4
    .quad 5
    .quad 6
    .quad 7
")

(define (compiler-backend-avx2-i64-lane-id-data) : String
  "    .quad 0
    .quad 1
    .quad 2
    .quad 3
")

(define (compiler-backend-emit-vector-lane-id
  [function : String]
  [current-label : String]
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [lanes : i64]
  [elem-ty : AstType]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (if (compiler-backend-lane-id-avx512-i64-shape-ok? elem-ty lanes)
    (match (compiler-backend-vector-var-reg assignments dst "lane id dst" "zmm")
      [(OkBackendReg dst-reg)
        (let
          [data-label : String
            (compiler-backend-lane-id-label function current-label dst "_data")]
          [done-label : String
            (compiler-backend-lane-id-label function current-label dst "_done")]
          (OkCompilerBackend
            (string-append
              (str-cat "    jmp " done-label "\n" data-label ":\n")
              (string-append
                (compiler-backend-avx512-i64-lane-id-data)
                (string-append
                  (str-cat done-label ":\n    vmovdqu64 " data-label "(%rip), ")
                  (str-cat dst-reg "\n"))))))]
      [(ErrBackendReg message)
        (ErrCompilerBackend
          (compiler-diagnostic-with-message instr-diag message))])
    (if (compiler-backend-lane-id-avx2-i64-shape-ok? elem-ty lanes)
      (match (compiler-backend-vector-var-reg
        assignments
        dst
        "lane id dst"
        "ymm")
        [(OkBackendReg dst-reg)
          (let
            [data-label : String
              (compiler-backend-lane-id-label
                function
                current-label
                dst
                "_data")]
            [done-label : String
              (compiler-backend-lane-id-label
                function
                current-label
                dst
                "_done")]
            (OkCompilerBackend
              (string-append
                (str-cat "    jmp " done-label "\n" data-label ":\n")
                (string-append
                  (compiler-backend-avx2-i64-lane-id-data)
                  (string-append
                    (str-cat done-label ":\n    vmovdqu " data-label "(%rip), ")
                    (str-cat dst-reg "\n"))))))]
        [(ErrBackendReg message)
          (ErrCompilerBackend
            (compiler-diagnostic-with-message instr-diag message))])
      (compiler-backend-avx512-shape-diagnostic instr-diag elem-ty lanes))))

(define (compiler-backend-emit-avx512-vector-load
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [base : CompilerIrValue]
  [index : CompilerIrValue]
  [lanes : i64]
  [elem-ty : AstType]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (if (compiler-backend-avx512-shape-ok? elem-ty lanes)
    (match (compiler-backend-vector-var-reg assignments dst "load dst" "zmm")
      [(OkBackendReg dst-reg)
        (match (compiler-backend-emit-avx2-base-index assignments base index)
          [(OkCompilerBackend addr-asm)
            (OkCompilerBackend
              (string-append
                addr-asm
                (string-append
                  (str-cat
                    "    "
                    (compiler-backend-avx512-vector-move elem-ty)
                    " "
                    (compiler-backend-avx2-indexed-addr elem-ty)
                    ", ")
                  (str-cat dst-reg "\n"))))]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(ErrBackendReg message)
        (ErrCompilerBackend
          (compiler-diagnostic-with-message instr-diag message))])
    (compiler-backend-avx512-shape-diagnostic instr-diag elem-ty lanes)))

(define (compiler-backend-emit-avx512-splat
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [value : CompilerIrValue]
  [lanes : i64]
  [elem-ty : AstType]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (if (compiler-backend-avx512-shape-ok? elem-ty lanes)
    (match (compiler-backend-vector-var-reg assignments dst "splat dst" "zmm")
      [(OkBackendReg dst-reg)
        (match (compiler-backend-avx512-splat-load assignments value elem-ty)
          [(OkCompilerBackend load-asm)
            (OkCompilerBackend (str-cat load-asm dst-reg "\n"))]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(ErrBackendReg message)
        (ErrCompilerBackend
          (compiler-diagnostic-with-message instr-diag message))])
    (compiler-backend-avx512-shape-diagnostic instr-diag elem-ty lanes)))

(define (compiler-backend-emit-vector-splat
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [value : CompilerIrValue]
  [lanes : i64]
  [elem-ty : AstType]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (if (compiler-backend-avx512-shape-ok? elem-ty lanes)
    (compiler-backend-emit-avx512-splat
      assignments
      dst
      value
      lanes
      elem-ty
      instr-diag)
    (compiler-backend-emit-avx2-splat
      assignments
      dst
      value
      lanes
      elem-ty
      instr-diag)))

(define (compiler-backend-emit-avx512-vector-binop
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [op : CompilerIrBinOp]
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [lanes : i64]
  [elem-ty : AstType]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (if (compiler-backend-avx512-shape-ok? elem-ty lanes)
    (let
      [mnemonic : String
        (compiler-backend-avx512-vector-binop-mnemonic op elem-ty)]
      (if (= (string-length mnemonic) 0)
        (ErrCompilerBackend
          (compiler-diagnostic-with-message
            instr-diag
            "backend: unsupported AVX-512 vector binary op"))
        (match (compiler-backend-avx512-vector-value-reg assignments lhs "lhs")
          [(OkBackendReg lhs-reg)
            (match (compiler-backend-avx512-vector-value-reg
              assignments
              rhs
              "rhs")
              [(OkBackendReg rhs-reg)
                (match (compiler-backend-vector-var-reg
                  assignments
                  dst
                  "binop dst"
                  "zmm")
                  [(OkBackendReg dst-reg)
                    (OkCompilerBackend
                      (string-append
                        (str-cat "    " mnemonic " " rhs-reg ", ")
                        (str-cat lhs-reg ", " dst-reg "\n")))]
                  [(ErrBackendReg message)
                    (ErrCompilerBackend
                      (compiler-diagnostic-with-message instr-diag message))])]
              [(ErrBackendReg message)
                (ErrCompilerBackend
                  (compiler-diagnostic-with-message instr-diag message))])]
          [(ErrBackendReg message)
            (ErrCompilerBackend
              (compiler-diagnostic-with-message instr-diag message))])))
    (compiler-backend-avx512-shape-diagnostic instr-diag elem-ty lanes)))

(define (compiler-backend-emit-avx512-vector-compare
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [op : CompilerIrBinOp]
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [lanes : i64]
  [elem-ty : AstType]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (if (compiler-backend-avx512-shape-ok? elem-ty lanes)
    (let
      [mnemonic : String
        (compiler-backend-avx512-vector-compare-mnemonic elem-ty)]
      [predicate : i64 (compiler-backend-avx512-compare-imm op)]
      (if (or (= (string-length mnemonic) 0) (< predicate 0))
        (ErrCompilerBackend
          (compiler-diagnostic-with-message
            instr-diag
            "backend: unsupported AVX-512 vector compare"))
        (match (compiler-backend-avx512-vector-value-reg
          assignments
          lhs
          "cmp lhs")
          [(OkBackendReg lhs-reg)
            (match (compiler-backend-avx512-vector-value-reg
              assignments
              rhs
              "cmp rhs")
              [(OkBackendReg rhs-reg)
                (match (compiler-backend-mask-var-reg assignments dst "cmp dst")
                  [(OkBackendReg dst-reg)
                    (OkCompilerBackend
                      (string-append
                        (str-cat
                          "    "
                          mnemonic
                          " $"
                          (int->string predicate)
                          ", ")
                        (string-append
                          (str-cat rhs-reg ", " lhs-reg ", ")
                          (str-cat dst-reg "\n"))))]
                  [(ErrBackendReg message)
                    (ErrCompilerBackend
                      (compiler-diagnostic-with-message instr-diag message))])]
              [(ErrBackendReg message)
                (ErrCompilerBackend
                  (compiler-diagnostic-with-message instr-diag message))])]
          [(ErrBackendReg message)
            (ErrCompilerBackend
              (compiler-diagnostic-with-message instr-diag message))])))
    (compiler-backend-avx512-shape-diagnostic instr-diag elem-ty lanes)))

(define (compiler-backend-emit-avx512-vector-store
  [assignments : CompilerRegAssignmentList]
  [base : CompilerIrValue]
  [index : CompilerIrValue]
  [value : CompilerIrValue]
  [lanes : i64]
  [elem-ty : AstType]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (if (compiler-backend-avx512-shape-ok? elem-ty lanes)
    (match (compiler-backend-avx512-vector-value-reg
      assignments
      value
      "store value")
      [(OkBackendReg value-reg)
        (match (compiler-backend-emit-avx2-base-index assignments base index)
          [(OkCompilerBackend addr-asm)
            (OkCompilerBackend
              (string-append
                addr-asm
                (string-append
                  (str-cat
                    "    "
                    (compiler-backend-avx512-vector-move elem-ty)
                    " "
                    value-reg
                    ", ")
                  (str-cat (compiler-backend-avx2-indexed-addr elem-ty) "\n"))))]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(ErrBackendReg message)
        (ErrCompilerBackend
          (compiler-diagnostic-with-message instr-diag message))])
    (compiler-backend-avx512-shape-diagnostic instr-diag elem-ty lanes)))

(define (compiler-backend-emit-vector-load
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [base : CompilerIrValue]
  [index : CompilerIrValue]
  [lanes : i64]
  [elem-ty : AstType]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (if (compiler-backend-avx512-shape-ok? elem-ty lanes)
    (compiler-backend-emit-avx512-vector-load
      assignments
      dst
      base
      index
      lanes
      elem-ty
      instr-diag)
    (compiler-backend-emit-avx2-vector-load
      assignments
      dst
      base
      index
      lanes
      elem-ty
      instr-diag)))

(define (compiler-backend-emit-vector-binop
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [op : CompilerIrBinOp]
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [lanes : i64]
  [elem-ty : AstType]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (if (compiler-backend-avx512-shape-ok? elem-ty lanes)
    (compiler-backend-emit-avx512-vector-binop
      assignments
      dst
      op
      lhs
      rhs
      lanes
      elem-ty
      instr-diag)
    (compiler-backend-emit-avx2-vector-binop
      assignments
      dst
      op
      lhs
      rhs
      lanes
      elem-ty
      instr-diag)))

(define (compiler-backend-emit-vector-reduce
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [op : CompilerIrVectorReduceOp]
  [src : CompilerIrValue]
  [lanes : i64]
  [elem-ty : AstType]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (if (compiler-backend-avx512-shape-ok? elem-ty lanes)
    (compiler-backend-emit-avx512-vector-reduce
      assignments
      dst
      op
      src
      lanes
      elem-ty
      instr-diag)
    (compiler-backend-emit-avx2-vector-reduce
      assignments
      dst
      op
      src
      lanes
      elem-ty
      instr-diag)))

(define (compiler-backend-emit-vector-store
  [assignments : CompilerRegAssignmentList]
  [base : CompilerIrValue]
  [index : CompilerIrValue]
  [value : CompilerIrValue]
  [lanes : i64]
  [elem-ty : AstType]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (if (compiler-backend-avx512-shape-ok? elem-ty lanes)
    (compiler-backend-emit-avx512-vector-store
      assignments
      base
      index
      value
      lanes
      elem-ty
      instr-diag)
    (compiler-backend-emit-avx2-vector-store
      assignments
      base
      index
      value
      lanes
      elem-ty
      instr-diag)))

(define (compiler-backend-emit-avx512-tail-mask
  [function : String]
  [current-label : String]
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [index : CompilerIrValue]
  [end-value : CompilerIrValue]
  [lanes : i64]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (if (= (compiler-backend-avx512-lane-mask lanes) 0)
    (compiler-backend-avx512-shape-diagnostic instr-diag (AstTyI64) lanes)
    (match (compiler-backend-mask-var-reg assignments dst "tail mask dst")
      [(OkBackendReg dst-reg)
        (let
          [full-mask : i64 (compiler-backend-avx512-lane-mask lanes)]
          (match (compiler-backend-emit-load-value-with-plan
            assignments
            index
            "%rax")
            [(OkCompilerBackend index-asm)
              (match (compiler-backend-emit-load-value-with-plan
                assignments
                end-value
                "%rcx")
                [(OkCompilerBackend end-asm)
                  (let
                    [full-label : String
                      (compiler-backend-avx512-mask-label
                        function
                        current-label
                        dst
                        "_full")]
                    [zero-label : String
                      (compiler-backend-avx512-mask-label
                        function
                        current-label
                        dst
                        "_zero")]
                    [done-label : String
                      (compiler-backend-avx512-mask-label
                        function
                        current-label
                        dst
                        "_done")]
                    [mask-gpr : String (compiler-backend-avx512-mask-gpr lanes)]
                    [mask-move : String
                      (compiler-backend-avx512-mask-move-mnemonic lanes)]
                    [mov-imm : String
                      (compiler-backend-avx512-mask-mov-imm-mnemonic lanes)]
                    [shift : String
                      (compiler-backend-avx512-mask-shl-mnemonic lanes)]
                    [sub : String
                      (compiler-backend-avx512-mask-sub-mnemonic lanes)]
                    [xor : String
                      (compiler-backend-avx512-mask-xor-mnemonic lanes)]
                    [body-range : String
                      (str-cat
                        "    subq %rax, %rcx\n    cmpq $"
                        (int->string lanes)
                        ", %rcx\n    jge "
                        full-label
                        "\n")]
                    [body-nonzero-a : String
                      (str-cat
                        "    testq %rcx, %rcx\n    jle "
                        zero-label
                        "\n    "
                        mov-imm
                        " $1, ")]
                    [body-nonzero-b : String
                      (str-cat mask-gpr "\n    " shift " %cl, " mask-gpr "\n")]
                    [body-mask-a : String
                      (str-cat "    " sub " $1, " mask-gpr "\n    ")]
                    [body-mask-b : String
                      (str-cat mask-move " " mask-gpr ", " dst-reg)]
                    [body-mask-c : String
                      (str-cat
                        "\n    jmp "
                        done-label
                        "\n"
                        full-label
                        ":\n    ")]
                    [body-full-a : String
                      (str-cat
                        mov-imm
                        " $"
                        (int->string full-mask)
                        ", "
                        mask-gpr)]
                    [body-full-b : String
                      (str-cat "\n    " mask-move " " mask-gpr ", ")]
                    [body-full-c : String
                      (str-cat
                        dst-reg
                        "\n    jmp "
                        done-label
                        "\n"
                        zero-label
                        ":\n")]
                    [body-zero-a : String
                      (str-cat "    " xor " " mask-gpr ", ")]
                    [body-zero-b : String
                      (str-cat mask-gpr "\n    " mask-move " " mask-gpr)]
                    [body-zero-c : String
                      (str-cat ", " dst-reg "\n" done-label ":\n")]
                    [body-asm : String
                      (string-append
                        body-range
                        (string-append
                          body-nonzero-a
                          (string-append
                            body-nonzero-b
                            (string-append
                              body-mask-a
                              (string-append
                                body-mask-b
                                (string-append
                                  body-mask-c
                                  (string-append
                                    body-full-a
                                    (string-append
                                      body-full-b
                                      (string-append
                                        body-full-c
                                        (string-append
                                          body-zero-a
                                          (string-append
                                            body-zero-b
                                            body-zero-c)))))))))))]
                    (OkCompilerBackend
                      (string-append index-asm (string-append end-asm body-asm))))]
                [(ErrCompilerBackend message)
                  (ErrCompilerBackend
                    (compiler-backend-apply-instr-diagnostic message instr-diag))])]
            [(ErrCompilerBackend message)
              (ErrCompilerBackend
                (compiler-backend-apply-instr-diagnostic message instr-diag))]))]
      [(ErrBackendReg message)
        (ErrCompilerBackend
          (compiler-diagnostic-with-message instr-diag message))])))

(define (compiler-backend-emit-avx512-predicated-load
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [base : CompilerIrValue]
  [index : CompilerIrValue]
  [mask : CompilerIrValue]
  [lanes : i64]
  [elem-ty : AstType]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (match elem-ty
    [(AstTyBool)
      (compiler-backend-emit-avx512-mask-load
        assignments
        dst
        base
        index
        mask
        lanes
        instr-diag)]
    [_
      (if (compiler-backend-avx512-shape-ok? elem-ty lanes)
        (match (compiler-backend-avx512-mask-value-reg
          assignments
          mask
          "load mask")
          [(OkBackendReg mask-reg)
            (match (compiler-backend-vector-var-reg
              assignments
              dst
              "load dst"
              "zmm")
              [(OkBackendReg dst-reg)
                (match (compiler-backend-emit-avx2-base-index
                  assignments
                  base
                  index)
                  [(OkCompilerBackend addr-asm)
                    (OkCompilerBackend
                      (string-append
                        addr-asm
                        (str-cat
                          "    "
                          (compiler-backend-avx512-vector-move elem-ty)
                          " "
                          (compiler-backend-avx2-indexed-addr elem-ty)
                          ", "
                          dst-reg
                          "{"
                          mask-reg
                          "}{z}\n")))]
                  [(ErrCompilerBackend message)
                    (ErrCompilerBackend
                      (compiler-backend-apply-instr-diagnostic
                        message
                        instr-diag))])]
              [(ErrBackendReg message)
                (ErrCompilerBackend
                  (compiler-diagnostic-with-message instr-diag message))])]
          [(ErrBackendReg message)
            (ErrCompilerBackend
              (compiler-diagnostic-with-message instr-diag message))])
        (compiler-backend-avx512-shape-diagnostic instr-diag elem-ty lanes))]))

(define (compiler-backend-emit-avx512-predicated-store
  [assignments : CompilerRegAssignmentList]
  [base : CompilerIrValue]
  [index : CompilerIrValue]
  [value : CompilerIrValue]
  [mask : CompilerIrValue]
  [lanes : i64]
  [elem-ty : AstType]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (match elem-ty
    [(AstTyBool)
      (compiler-backend-emit-avx512-mask-store
        assignments
        base
        index
        value
        mask
        lanes
        instr-diag)]
    [_
      (if (compiler-backend-avx512-shape-ok? elem-ty lanes)
        (match (compiler-backend-avx512-vector-value-reg
          assignments
          value
          "store value")
          [(OkBackendReg value-reg)
            (match (compiler-backend-avx512-mask-value-reg
              assignments
              mask
              "store mask")
              [(OkBackendReg mask-reg)
                (match (compiler-backend-emit-avx2-base-index
                  assignments
                  base
                  index)
                  [(OkCompilerBackend addr-asm)
                    (OkCompilerBackend
                      (string-append
                        addr-asm
                        (str-cat
                          "    "
                          (compiler-backend-avx512-vector-move elem-ty)
                          " "
                          value-reg
                          ", "
                          (compiler-backend-avx2-indexed-addr elem-ty)
                          "{"
                          mask-reg
                          "}\n")))]
                  [(ErrCompilerBackend message)
                    (ErrCompilerBackend
                      (compiler-backend-apply-instr-diagnostic
                        message
                        instr-diag))])]
              [(ErrBackendReg message)
                (ErrCompilerBackend
                  (compiler-diagnostic-with-message instr-diag message))])]
          [(ErrBackendReg message)
            (ErrCompilerBackend
              (compiler-diagnostic-with-message instr-diag message))])
        (compiler-backend-avx512-shape-diagnostic instr-diag elem-ty lanes))]))

(define (compiler-backend-emit-avx512-mask-load
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [base : CompilerIrValue]
  [index : CompilerIrValue]
  [mask : CompilerIrValue]
  [lanes : i64]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (if (= (compiler-backend-avx512-lane-mask lanes) 0)
    (compiler-backend-avx512-shape-diagnostic instr-diag (AstTyBool) lanes)
    (match (compiler-backend-mask-var-reg assignments dst "mask load dst")
      [(OkBackendReg dst-reg)
        (match (compiler-backend-avx512-mask-value-reg
          assignments
          mask
          "mask load active mask")
          [(OkBackendReg mask-reg)
            (match (compiler-backend-emit-avx2-base-index
              assignments
              base
              index)
              [(OkCompilerBackend addr-asm)
                (OkCompilerBackend
                  (string-append
                    addr-asm
                    (str-cat
                      "    vmovdqu8 "
                      (compiler-backend-avx2-indexed-addr (AstTyBool))
                      ", %zmm15{"
                      mask-reg
                      "}{z}\n"
                      "    vpxord %zmm14, %zmm14, %zmm14\n"
                      "    vpcmpub $4, %zmm14, %zmm15, "
                      dst-reg
                      "\n")))]
              [(ErrCompilerBackend message)
                (ErrCompilerBackend
                  (compiler-backend-apply-instr-diagnostic message instr-diag))])]
          [(ErrBackendReg message)
            (ErrCompilerBackend
              (compiler-diagnostic-with-message instr-diag message))])]
      [(ErrBackendReg message)
        (ErrCompilerBackend
          (compiler-diagnostic-with-message instr-diag message))])))

(define (compiler-backend-emit-avx512-mask-store
  [assignments : CompilerRegAssignmentList]
  [base : CompilerIrValue]
  [index : CompilerIrValue]
  [value : CompilerIrValue]
  [mask : CompilerIrValue]
  [lanes : i64]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (if (= (compiler-backend-avx512-lane-mask lanes) 0)
    (compiler-backend-avx512-shape-diagnostic instr-diag (AstTyBool) lanes)
    (match (compiler-backend-avx512-mask-value-reg
      assignments
      value
      "mask store value")
      [(OkBackendReg value-reg)
        (match (compiler-backend-avx512-mask-value-reg
          assignments
          mask
          "mask store active mask")
          [(OkBackendReg mask-reg)
            (match (compiler-backend-emit-avx2-base-index
              assignments
              base
              index)
              [(OkCompilerBackend addr-asm)
                (OkCompilerBackend
                  (string-append
                    addr-asm
                    (str-cat
                      "    vpxord %zmm15, %zmm15, %zmm15\n"
                      "    movl $1, %edx\n    vmovd %edx, %xmm14\n"
                      "    vpbroadcastb %xmm14, %zmm14\n    vmovdqu8 %zmm14, %zmm15{"
                      value-reg
                      "}\n    vmovdqu8 %zmm15, "
                      (compiler-backend-avx2-indexed-addr (AstTyBool))
                      "{"
                      mask-reg
                      "}\n")))]
              [(ErrCompilerBackend message)
                (ErrCompilerBackend
                  (compiler-backend-apply-instr-diagnostic message instr-diag))])]
          [(ErrBackendReg message)
            (ErrCompilerBackend
              (compiler-diagnostic-with-message instr-diag message))])]
      [(ErrBackendReg message)
        (ErrCompilerBackend
          (compiler-diagnostic-with-message instr-diag message))])))

(define (compiler-backend-mask-binop-mnemonic
  [op : CompilerIrMaskBinOp]
  [lanes : i64]) : String
  (match op
    [(IrMaskAnd)
      (string-append "kand" (compiler-backend-avx512-mask-op-suffix lanes))]
    [(IrMaskOr)
      (string-append "kor" (compiler-backend-avx512-mask-op-suffix lanes))]))

(define (compiler-backend-emit-avx512-mask-binop
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [op : CompilerIrMaskBinOp]
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [lanes : i64]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (if (= (compiler-backend-avx512-lane-mask lanes) 0)
    (compiler-backend-avx512-shape-diagnostic instr-diag (AstTyI64) lanes)
    (match (compiler-backend-avx512-mask-value-reg assignments lhs "lhs")
      [(OkBackendReg lhs-reg)
        (match (compiler-backend-avx512-mask-value-reg assignments rhs "rhs")
          [(OkBackendReg rhs-reg)
            (match (compiler-backend-mask-var-reg
              assignments
              dst
              "mask binop dst")
              [(OkBackendReg dst-reg)
                (OkCompilerBackend
                  (if (string-eq lhs-reg rhs-reg)
                    (if (string-eq lhs-reg dst-reg)
                      ""
                      (str-cat
                        "    "
                        (compiler-backend-avx512-mask-move-mnemonic lanes)
                        " "
                        lhs-reg
                        ", "
                        dst-reg
                        "\n"))
                    (str-cat
                      "    "
                      (compiler-backend-mask-binop-mnemonic op lanes)
                      " "
                      rhs-reg
                      ", "
                      lhs-reg
                      ", "
                      dst-reg
                      "\n")))]
              [(ErrBackendReg message)
                (ErrCompilerBackend
                  (compiler-diagnostic-with-message instr-diag message))])]
          [(ErrBackendReg message)
            (ErrCompilerBackend
              (compiler-diagnostic-with-message instr-diag message))])]
      [(ErrBackendReg message)
        (ErrCompilerBackend
          (compiler-diagnostic-with-message instr-diag message))])))

(define (compiler-backend-emit-avx512-mask-not
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [src : CompilerIrValue]
  [lanes : i64]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (let
    [full-mask : i64 (compiler-backend-avx512-lane-mask lanes)]
    [mask-suffix : String (compiler-backend-avx512-mask-op-suffix lanes)]
    [mask-move : String (compiler-backend-avx512-mask-move-mnemonic lanes)]
    [mask-gpr : String (compiler-backend-avx512-mask-gpr lanes)]
    [mov-imm : String (compiler-backend-avx512-mask-mov-imm-mnemonic lanes)]
    (if (= full-mask 0)
      (compiler-backend-avx512-shape-diagnostic instr-diag (AstTyI64) lanes)
      (match (compiler-backend-avx512-mask-value-reg
        assignments
        src
        "not source")
        [(OkBackendReg src-reg)
          (match (compiler-backend-mask-var-reg assignments dst "mask not dst")
            [(OkBackendReg dst-reg)
              (OkCompilerBackend
                (string-append
                  (str-cat
                    "    "
                    (string-append "knot" mask-suffix)
                    " "
                    src-reg
                    ", "
                    dst-reg
                    "\n")
                  (str-cat
                    "    "
                    mov-imm
                    " $"
                    (int->string full-mask)
                    ", "
                    mask-gpr
                    "\n    "
                    mask-move
                    " "
                    mask-gpr
                    ", %k7\n    "
                    (string-append "kand" mask-suffix)
                    " %k7, "
                    dst-reg
                    ", "
                    dst-reg
                    "\n")))]
            [(ErrBackendReg message)
              (ErrCompilerBackend
                (compiler-diagnostic-with-message instr-diag message))])]
        [(ErrBackendReg message)
          (ErrCompilerBackend
            (compiler-diagnostic-with-message instr-diag message))]))))

(define (compiler-backend-emit-avx512-mask-reduce
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [op : CompilerIrMaskReduceOp]
  [src : CompilerIrValue]
  [lanes : i64]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (let
    [full-mask : i64 (compiler-backend-avx512-lane-mask lanes)]
    [mask-move : String (compiler-backend-avx512-mask-move-mnemonic lanes)]
    [mask-gpr : String (compiler-backend-avx512-mask-gpr lanes)]
    [kortest-op : String (compiler-backend-avx512-mask-kortest-mnemonic lanes)]
    [cmp-op : String (compiler-backend-avx512-mask-cmp-mnemonic lanes)]
    (if (= full-mask 0)
      (compiler-backend-avx512-shape-diagnostic instr-diag (AstTyI64) lanes)
      (match (compiler-backend-avx512-mask-value-reg
        assignments
        src
        "reduce source")
        [(OkBackendReg src-reg)
          (OkCompilerBackend
            (string-append
              (match op
                [(IrMaskReduceAny)
                  (str-cat
                    "    "
                    kortest-op
                    " "
                    src-reg
                    ", "
                    src-reg
                    "\n    setne %al\n")]
                [(IrMaskReduceAll)
                  (if (or (= full-mask 0xffff) (= full-mask -1))
                    (str-cat
                      "    "
                      kortest-op
                      " "
                      src-reg
                      ", "
                      src-reg
                      "\n    setc %al\n")
                    (str-cat
                      "    "
                      mask-move
                      " "
                      src-reg
                      ", "
                      mask-gpr
                      "\n    "
                      cmp-op
                      " $"
                      (int->string full-mask)
                      ", "
                      mask-gpr
                      "\n    sete %al\n"))])
              (string-append
                "    movzbl %al, %eax\n"
                (compiler-backend-emit-store-var-with-plan
                  assignments
                  dst
                  "%rax"))))]
        [(ErrBackendReg message)
          (ErrCompilerBackend
            (compiler-diagnostic-with-message instr-diag message))]))))

(define (compiler-backend-emit-avx512-select
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [mask : CompilerIrValue]
  [on-true : CompilerIrValue]
  [on-false : CompilerIrValue]
  [lanes : i64]
  [elem-ty : AstType]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (if (compiler-backend-avx512-shape-ok? elem-ty lanes)
    (let
      [move : String (compiler-backend-avx512-vector-move elem-ty)]
      (if (= (string-length move) 0)
        (ErrCompilerBackend
          (compiler-diagnostic-with-message
            instr-diag
            "backend: unsupported AVX-512 select type"))
        (match (compiler-backend-avx512-vector-value-reg
          assignments
          on-false
          "select false")
          [(OkBackendReg false-reg)
            (match (compiler-backend-avx512-vector-value-reg
              assignments
              on-true
              "select true")
              [(OkBackendReg true-reg)
                (match (compiler-backend-avx512-mask-value-reg
                  assignments
                  mask
                  "select mask")
                  [(OkBackendReg mask-reg)
                    (match (compiler-backend-vector-var-reg
                      assignments
                      dst
                      "select dst"
                      "zmm")
                      [(OkBackendReg dst-reg)
                        (OkCompilerBackend
                          (if (and
                            (string-eq dst-reg true-reg)
                            (not (string-eq true-reg false-reg)))
                            (string-append
                              (str-cat "    " move " " true-reg ", %zmm15\n")
                              (string-append
                                (string-append
                                  (str-cat "    " move " " false-reg ", ")
                                  (str-cat dst-reg "\n"))
                                (string-append
                                  (str-cat "    " move " %zmm15, " dst-reg "{")
                                  (str-cat mask-reg "}\n"))))
                            (string-append
                              (string-append
                                (str-cat "    " move " " false-reg ", ")
                                (str-cat dst-reg "\n"))
                              (string-append
                                (str-cat "    " move " " true-reg ", ")
                                (str-cat dst-reg "{" mask-reg "}\n")))))]
                      [(ErrBackendReg message)
                        (ErrCompilerBackend
                          (compiler-diagnostic-with-message instr-diag message))])]
                  [(ErrBackendReg message)
                    (ErrCompilerBackend
                      (compiler-diagnostic-with-message instr-diag message))])]
              [(ErrBackendReg message)
                (ErrCompilerBackend
                  (compiler-diagnostic-with-message instr-diag message))])]
          [(ErrBackendReg message)
            (ErrCompilerBackend
              (compiler-diagnostic-with-message instr-diag message))])))
    (compiler-backend-avx512-shape-diagnostic instr-diag elem-ty lanes)))

(define (compiler-backend-round-up-16 [n : i64]) : i64
  (if (= n 0)
    0
    (* (/ (+ n 15) 16) 16)))

(define (compiler-backend-frame-size [vars : i64]) : i64
  (compiler-backend-round-up-16 (* vars 8)))

(define (compiler-backend-slot [var-id : i64]) : String
  (string-append (int->string (- 0 (* 8 (+ var-id 1)))) "(%rbp)"))

(define (compiler-backend-frame-offset [offset : i64]) : String
  (string-append (int->string offset) "(%rbp)"))

(define (compiler-backend-plan-uses-reg?
  [assignments : CompilerRegAssignmentList]
  [reg : String]) : bool
  (match assignments
    [(CompilerRegAssignmentNil) false]
    [(CompilerRegAssignmentCons item rest)
      (match item
        [(CompilerRegAssignment _ location)
          (match location
            [(CompilerRegRegister found)
              (if (string-eq found reg)
                true
                (compiler-backend-plan-uses-reg? (box-get rest) reg))]
            [(CompilerRegRegisterPair a b)
              (if (or (string-eq a reg) (string-eq b reg))
                true
                (compiler-backend-plan-uses-reg? (box-get rest) reg))]
            [_ (compiler-backend-plan-uses-reg? (box-get rest) reg)])])]))

(define (compiler-backend-plan-uses-callee-regs?
  [assignments : CompilerRegAssignmentList]) : bool
  (or
    (compiler-backend-plan-uses-reg? assignments "%rbx")
    (compiler-backend-plan-uses-reg? assignments "%r12")
    (compiler-backend-plan-uses-reg? assignments "%r13")
    (compiler-backend-plan-uses-reg? assignments "%r14")
    (compiler-backend-plan-uses-reg? assignments "%r15")))

;; Callee-saved registers are spilled to frame slots that sit just below the
;; var slots: r12..r15 occupy idx 0..3 (offset -(8*(vars+idx+1))(%rbp)) and %rbx
;; occupies idx 4. Reserve the %rbx slot only when the plan actually homes a
;; value there, so functions that use only r12-r15 keep their previous frame
;; size (and byte-identical prologue) — %rbx, added last to the pool, is rare.
(define (compiler-backend-frame-slots
  [vars : i64]
  [assignments : CompilerRegAssignmentList]) : i64
  (if (compiler-backend-plan-uses-callee-regs? assignments)
    (if (compiler-backend-plan-uses-reg? assignments "%rbx")
      (+ vars 5)
      (+ vars 4))
    vars))

;; #2386: reserve a second var-region for the word1 stack slots of any group var
;; that has no register home (stack-only mode). word1 of var V lives at slot index
;; vars+V, so 2*vars slots are needed. In register-allocation mode groups get
;; register pairs and never use these slots (the reservation is then unused).
(define (compiler-backend-frame-slots-with-groups
  [vars : i64]
  [assignments : CompilerRegAssignmentList]
  [has-group-vars : bool]) : i64
  (let
    [base : i64 (compiler-backend-frame-slots vars assignments)]
    (if has-group-vars
      (+ base vars)
      base)))

(define (compiler-backend-param-var? [params : CompilerIrParamList] [var : i64]) : bool
  (match params
    [(IrParamNil) false]
    [(IrParamCons param rest)
      (match param
        [(IrParam _ _ param-var)
          (if (= var param-var)
            true
            (compiler-backend-param-var? (box-get rest) var))])]))

(define (compiler-backend-drop-param-assignments
  [assignments : CompilerRegAssignmentList]
  [params : CompilerIrParamList]) : CompilerRegAssignmentList
  (match assignments
    [(CompilerRegAssignmentNil) CompilerRegAssignmentNil]
    [(CompilerRegAssignmentCons item rest)
      (match item
        [(CompilerRegAssignment var _)
          (let
            [tail : CompilerRegAssignmentList
              (compiler-backend-drop-param-assignments (box-get rest) params)]
            (if (compiler-backend-param-var? params var)
              tail
              (compiler-reg-assignment-cons item tail)))])]))

(define (compiler-backend-callee-save-slot [vars : i64] [idx : i64]) : String
  (compiler-backend-frame-offset (- 0 (* 8 (+ vars (+ idx 1))))))

(define (compiler-backend-asm-label [function : String] [label : String]) : String
  (str-cat ".L" (compiler-backend-asm-safe-symbol function) "_" label))

(define (compiler-backend-arg-reg [idx : i64]) : ResultBackendReg
  (cond
    [(= idx 0) (OkBackendReg "%rdi")]
    [(= idx 1) (OkBackendReg "%rsi")]
    [(= idx 2) (OkBackendReg "%rdx")]
    [(= idx 3) (OkBackendReg "%rcx")]
    [(= idx 4) (OkBackendReg "%r8")]
    [(= idx 5) (OkBackendReg "%r9")]
    [else (ErrBackendReg "backend: too many call args")]))

(define (compiler-backend-float-arg-reg [idx : i64]) : ResultBackendReg
  (cond
    [(= idx 0) (OkBackendReg "%xmm0")]
    [(= idx 1) (OkBackendReg "%xmm1")]
    [(= idx 2) (OkBackendReg "%xmm2")]
    [(= idx 3) (OkBackendReg "%xmm3")]
    [(= idx 4) (OkBackendReg "%xmm4")]
    [(= idx 5) (OkBackendReg "%xmm5")]
    [(= idx 6) (OkBackendReg "%xmm6")]
    [(= idx 7) (OkBackendReg "%xmm7")]
    [else (ErrBackendReg "backend: too many call args")]))

(define (compiler-backend-emit-stack-sub
  [target : CompilerBackendTarget]
  [frame : i64]) : String
  (if (= frame 0)
    ""
    (match target
      [(BackendTargetWindows)
        (if (>= frame 4096)
          (str-cat
            "    movl $"
            (int->string frame)
            ", %eax\n    callq __chkstk\n    subq %rax, %rsp\n"
            ""
            "")
          (str-cat "    subq $" (int->string frame) ", %rsp\n" ""))]
      [(BackendTargetLinux)
        (str-cat "    subq $" (int->string frame) ", %rsp\n" "")])))

(define (compiler-backend-emit-windows-seh-proc
  [target : CompilerBackendTarget]
  [symbol : String]) : String
  (if (compiler-backend-target-windows? target)
    (str-cat ".seh_proc " symbol "\n" "")
    ""))

(define (compiler-backend-emit-windows-seh-push-rbp
  [target : CompilerBackendTarget]) : String
  (if (compiler-backend-target-windows? target)
    "    .seh_pushreg %rbp\n"
    ""))

(define (compiler-backend-emit-windows-seh-set-rbp
  [target : CompilerBackendTarget]) : String
  (if (compiler-backend-target-windows? target)
    "    .seh_setframe %rbp, 0\n"
    ""))

(define (compiler-backend-emit-windows-seh-stackalloc
  [target : CompilerBackendTarget]
  [frame : i64]) : String
  (if (and (compiler-backend-target-windows? target) (> frame 0))
    (str-cat "    .seh_stackalloc " (int->string frame) "\n" "")
    ""))

(define (compiler-backend-emit-windows-seh-endprologue
  [target : CompilerBackendTarget]) : String
  (if (compiler-backend-target-windows? target)
    "    .seh_endprologue\n"
    ""))

(define (compiler-backend-emit-windows-seh-endproc
  [target : CompilerBackendTarget]) : String
  (if (compiler-backend-target-windows? target)
    "    .seh_endproc\n"
    ""))

(define (compiler-backend-emit-function-entry
  [target : CompilerBackendTarget]
  [symbol : String]
  [frame : i64]) : String
  (string-append
    (compiler-backend-emit-windows-seh-proc target symbol)
    (string-append
      symbol
      (string-append
        ":\n    pushq %rbp\n"
        (string-append
          (compiler-backend-emit-windows-seh-push-rbp target)
          (string-append
            "    movq %rsp, %rbp\n"
            (string-append
              (compiler-backend-emit-windows-seh-set-rbp target)
              (string-append
                (compiler-backend-emit-stack-sub target frame)
                (string-append
                  (compiler-backend-emit-windows-seh-stackalloc target frame)
                  (compiler-backend-emit-windows-seh-endprologue target))))))))))

(define (compiler-backend-emit-store-var [var-id : i64] [reg : String]) : String
  (str-cat "    movq " reg ", " (compiler-backend-slot var-id) "\n"))

(define (compiler-backend-float-type? [ty : AstType]) : bool
  (match ty
    [(AstTyF64) true]
    [(AstTyF32) true]
    [_ false]))

(define (compiler-backend-float-move [ty : AstType]) : String
  (match ty
    [(AstTyF32) "movss"]
    [_ "movsd"]))

(define (compiler-backend-float-type-name [ty : AstType]) : String
  (match ty
    [(AstTyF32) "f32"]
    [_ "f64"]))

(define (compiler-backend-emit-store-float-var
  [var-id : i64]
  [reg : String]
  [ty : AstType]) : String
  (string-append
    (str-cat "    " (compiler-backend-float-move ty) " " reg ", ")
    (string-append (compiler-backend-slot var-id) "\n")))

(define (compiler-backend-emit-store-xmm-var [var-id : i64] [reg : String]) : String
  (compiler-backend-emit-store-float-var var-id reg (AstTyF64)))

(define (compiler-backend-forwarded-addr-of-src [var-id : i64]) : i64
  (if compiler-backend-addr-of-forwarding-enabled
    (if (and
      (>= var-id 0)
      (< var-id (array-length compiler-backend-addr-of-forwarding-src)))
      (array-ref compiler-backend-addr-of-forwarding-src var-id)
      (- 0 1))
    (- 0 1)))

(define (compiler-backend-emit-load-var-with-plan
  [assignments : CompilerRegAssignmentList]
  [var-id : i64]
  [reg : String]) : String
  (let
    [forward-src : i64 (compiler-backend-forwarded-addr-of-src var-id)]
    (if (>= forward-src 0)
      (backend-cat5
        "    leaq "
        (compiler-backend-slot forward-src)
        ", "
        reg
        "\n")
      (match (compiler-reg-assignment-lookup assignments var-id)
        [(CompilerRegSomeLocation location)
          (match location
            [(CompilerRegRegister home)
              (if (string-eq home reg)
                ""
                (str-cat "    movq " home ", " reg "\n"))]
            [(CompilerRegRegisterPair home _)
              ;; #2386: loading a whole register-group var into one register is not a
              ;; scalar op; word extraction goes through IrInstrWord. Word0's home is
              ;; the low register -- used only by the (unreached here) group paths.
              (if (string-eq home reg)
                ""
                (str-cat "    movq " home ", " reg "\n"))]
            [(CompilerRegSpill offset)
              (str-cat
                "    movq "
                (compiler-backend-frame-offset offset)
                ", "
                reg
                "\n")])]
        [(CompilerRegNoLocation)
          (str-cat "    movq " (compiler-backend-slot var-id) ", " reg "\n")]))))

(define (compiler-backend-emit-store-var-with-plan
  [assignments : CompilerRegAssignmentList]
  [var-id : i64]
  [reg : String]) : String
  (match (compiler-reg-assignment-lookup assignments var-id)
    [(CompilerRegSomeLocation location)
      (match location
        [(CompilerRegRegister home)
          (if (string-eq home reg)
            ""
            (str-cat "    movq " reg ", " home "\n"))]
        [(CompilerRegRegisterPair home _)
          (if (string-eq home reg)
            ""
            (str-cat "    movq " reg ", " home "\n"))]
        [(CompilerRegSpill offset)
          (str-cat
            "    movq "
            reg
            ", "
            (compiler-backend-frame-offset offset)
            "\n")])]
    [(CompilerRegNoLocation) (compiler-backend-emit-store-var var-id reg)]))

(define (compiler-backend-emit-load-float-var-with-plan
  [assignments : CompilerRegAssignmentList]
  [var-id : i64]
  [ty : AstType]
  [reg : String]) : String
  (let
    [mov : String (compiler-backend-float-move ty)]
    (match (compiler-reg-assignment-lookup assignments var-id)
      [(CompilerRegSomeLocation location)
        (match location
          [(CompilerRegRegister home)
            (if (string-eq home reg)
              ""
              (str-cat "    " mov " " home ", " reg "\n"))]
          ;; #2386: a register-group var is never float-class; unreachable.
          [(CompilerRegRegisterPair _ _) ""]
          [(CompilerRegSpill offset)
            (str-cat
              "    "
              mov
              " "
              (compiler-backend-frame-offset offset)
              ", "
              reg
              "\n")])]
      [(CompilerRegNoLocation)
        (str-cat "    " mov " " (compiler-backend-slot var-id) ", " reg "\n")])))

(define (compiler-backend-emit-load-f64-var-with-plan
  [assignments : CompilerRegAssignmentList]
  [var-id : i64]
  [reg : String]) : String
  (compiler-backend-emit-load-float-var-with-plan
    assignments
    var-id
    (AstTyF64)
    reg))

(define (compiler-backend-emit-store-float-var-with-plan
  [assignments : CompilerRegAssignmentList]
  [var-id : i64]
  [reg : String]
  [ty : AstType]) : String
  (let
    [mov : String (compiler-backend-float-move ty)]
    (match (compiler-reg-assignment-lookup assignments var-id)
      [(CompilerRegSomeLocation location)
        (match location
          [(CompilerRegRegister home)
            (if (string-eq home reg)
              ""
              (str-cat "    " mov " " reg ", " home "\n"))]
          ;; #2386: a register-group var is never float-class; unreachable.
          [(CompilerRegRegisterPair _ _) ""]
          [(CompilerRegSpill offset)
            (str-cat
              "    "
              mov
              " "
              reg
              ", "
              (compiler-backend-frame-offset offset)
              "\n")])]
      [(CompilerRegNoLocation)
        (compiler-backend-emit-store-float-var var-id reg ty)])))

(define (compiler-backend-emit-store-f64-var-with-plan
  [assignments : CompilerRegAssignmentList]
  [var-id : i64]
  [reg : String]) : String
  (compiler-backend-emit-store-float-var-with-plan
    assignments
    var-id
    reg
    (AstTyF64)))

(define (compiler-backend-emit-save-callee-reg
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [reg : String]
  [idx : i64]) : String
  (if (compiler-backend-plan-uses-reg? assignments reg)
    (str-cat
      "    movq "
      reg
      ", "
      (compiler-backend-callee-save-slot vars idx)
      "\n")
    ""))

(define (compiler-backend-emit-restore-callee-reg
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [reg : String]
  [idx : i64]) : String
  (if (compiler-backend-plan-uses-reg? assignments reg)
    (str-cat
      "    movq "
      (compiler-backend-callee-save-slot vars idx)
      ", "
      reg
      "\n")
    ""))

;; Pop restores are correct only when the used callee-save homes are adjacent in
;; stack order. The allocator hands out r12, r13, r14, r15, then rbx; for two or
;; more such homes, `leaq slot, %rsp` plus pops is no larger than the movq loads.
(define (compiler-backend-callee-save-pop-eligible?
  [assignments : CompilerRegAssignmentList]) : bool
  (let
    [r12 : bool (compiler-backend-plan-uses-reg? assignments "%r12")]
    [r13 : bool (compiler-backend-plan-uses-reg? assignments "%r13")]
    [r14 : bool (compiler-backend-plan-uses-reg? assignments "%r14")]
    [r15 : bool (compiler-backend-plan-uses-reg? assignments "%r15")]
    [rbx : bool (compiler-backend-plan-uses-reg? assignments "%rbx")]
    (or
      (and r12 r13 (not r14) (not r15) (not rbx))
      (and r12 r13 r14 (not r15) (not rbx))
      (and r12 r13 r14 r15 (not rbx))
      (and r12 r13 r14 r15 rbx))))

(define (compiler-backend-callee-save-pop-start-idx
  [assignments : CompilerRegAssignmentList]) : i64
  (cond
    [(compiler-backend-plan-uses-reg? assignments "%rbx") 4]
    [(compiler-backend-plan-uses-reg? assignments "%r15") 3]
    [(compiler-backend-plan-uses-reg? assignments "%r14") 2]
    [else 1]))

(define (compiler-backend-emit-pop-callee-reg
  [assignments : CompilerRegAssignmentList]
  [reg : String]) : String
  (if (compiler-backend-plan-uses-reg? assignments reg)
    (str-cat "    popq " reg "\n" "")
    ""))

(define (compiler-backend-emit-restore-callee-regs-pop
  [assignments : CompilerRegAssignmentList]
  [vars : i64]) : String
  (string-append
    (str-cat
      "    leaq "
      (compiler-backend-callee-save-slot
        vars
        (compiler-backend-callee-save-pop-start-idx assignments))
      ", %rsp\n")
    (string-append
      (compiler-backend-emit-pop-callee-reg assignments "%rbx")
      (string-append
        (compiler-backend-emit-pop-callee-reg assignments "%r15")
        (string-append
          (compiler-backend-emit-pop-callee-reg assignments "%r14")
          (string-append
            (compiler-backend-emit-pop-callee-reg assignments "%r13")
            (compiler-backend-emit-pop-callee-reg assignments "%r12")))))))

(define (compiler-backend-emit-save-callee-regs
  [assignments : CompilerRegAssignmentList]
  [vars : i64]) : String
  (string-append
    (compiler-backend-emit-save-callee-reg assignments vars "%r12" 0)
    (string-append
      (compiler-backend-emit-save-callee-reg assignments vars "%r13" 1)
      (string-append
        (compiler-backend-emit-save-callee-reg assignments vars "%r14" 2)
        (string-append
          (compiler-backend-emit-save-callee-reg assignments vars "%r15" 3)
          (compiler-backend-emit-save-callee-reg assignments vars "%rbx" 4))))))

(define (compiler-backend-emit-restore-callee-regs
  [assignments : CompilerRegAssignmentList]
  [vars : i64]) : String
  (if (compiler-backend-callee-save-pop-eligible? assignments)
    (compiler-backend-emit-restore-callee-regs-pop assignments vars)
    (string-append
      (compiler-backend-emit-restore-callee-reg assignments vars "%rbx" 4)
      (string-append
        (compiler-backend-emit-restore-callee-reg assignments vars "%r15" 3)
        (string-append
          (compiler-backend-emit-restore-callee-reg assignments vars "%r14" 2)
          (string-append
            (compiler-backend-emit-restore-callee-reg assignments vars "%r13" 1)
            (compiler-backend-emit-restore-callee-reg assignments vars "%r12" 0)))))))

(define (compiler-backend-return-label [source-function : String]) : String
  (compiler-backend-asm-label
    (compiler-backend-user-symbol source-function)
    "return"))

(define (compiler-backend-inline-return-tail
  [assignments : CompilerRegAssignmentList]
  [vars : i64]) : String
  (string-append
    (compiler-backend-emit-restore-callee-regs assignments vars)
    "    leave\n    ret\n"))

(define (compiler-backend-tail-jump-tail
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [target : String]) : String
  (string-append
    (compiler-backend-emit-restore-callee-regs assignments vars)
    (str-cat "    leave\n    jmp " target "\n" "")))

(define (compiler-backend-char-code [c : char]) : i64
  (cast c : i64))

(define (compiler-backend-imm32? [n : i64]) : bool
  (and (>= n (- 0 2147483648)) (<= n 2147483647)))

(define (compiler-backend-immediate-i64 [n : i64]) : CompilerBackendMaybeImmediate
  (if (compiler-backend-imm32? n)
    (CompilerBackendSomeImmediate (string-append "$" (int->string n)))
    (CompilerBackendNoImmediate)))

(define (compiler-backend-immediate-operand [value : CompilerIrValue]) : CompilerBackendMaybeImmediate
  (match value
    [(IrValueI64 n) (compiler-backend-immediate-i64 n)]
    [(IrValueBool b)
      (if b
        (CompilerBackendSomeImmediate "$1")
        (CompilerBackendSomeImmediate "$0"))]
    [(IrValueChar c)
      (CompilerBackendSomeImmediate
        (string-append "$" (int->string (compiler-backend-char-code c))))]
    [(IrValueUnit) (CompilerBackendSomeImmediate "$0")]
    [_ (CompilerBackendNoImmediate)]))

(define (compiler-backend-value-as-i64 [value : CompilerIrValue]) : CompilerBackendMaybeI64
  (match value
    [(IrValueI64 n) (CompilerBackendSomeI64 n)]
    [(IrValueBool b)
      (if b
        (CompilerBackendSomeI64 1)
        (CompilerBackendSomeI64 0))]
    [(IrValueChar c) (CompilerBackendSomeI64 (compiler-backend-char-code c))]
    [(IrValueUnit) (CompilerBackendSomeI64 0)]
    [_ (CompilerBackendNoI64)]))

(define (compiler-backend-symbol-char [text : String] [idx : i64] [c : char]) : String
  (cond
    [(or
        (and (>= c #A') (<= c #Z'))
        (and (>= c #a') (<= c #z'))
        (and (>= c #0') (<= c #9'))
        (= c #_'))
      (substring text idx 1)]
    [(= c #-') "_"]
    [(= c #?') "_question"]
    [(= c #!') "_bang"]
    [(= c #+') "_plus"]
    [(= c #*') "_star"]
    [(= c #/') "_slash"]
    [(= c #=') "_eq"]
    [(= c #<') "_lt"]
    [(= c #>') "_gt"]
    [(= c #:') "_colon"]
    [else
      (string-append
        "_u"
        (compiler-backend-hex-byte (compiler-backend-char-code c)))]))

(define (compiler-backend-symbol-safe-char? [c : char]) : bool
  (or
    (and (>= c #A') (<= c #Z'))
    (and (>= c #a') (<= c #z'))
    (and (>= c #0') (<= c #9'))
    (= c #_')))

(define (compiler-backend-export-symbol-head-char? [c : char]) : bool
  (or (and (>= c #A') (<= c #Z')) (and (>= c #a') (<= c #z')) (= c #_')))

(define (compiler-backend-export-symbol-tail-char? [c : char]) : bool
  (or (compiler-backend-export-symbol-head-char? c) (and (>= c #0') (<= c #9'))))

(define (compiler-backend-valid-export-symbol? [name : String]) : bool
  (let
    [n : i64 (string-length name)]
    [i : i64 1]
    [valid : bool (> n 0)]
    (begin
      (if valid
        (set!
          valid
          (compiler-backend-export-symbol-head-char? (string-ref name 0)))
        unit)
      (while (and valid (< i n))
        (begin
          (if (compiler-backend-export-symbol-tail-char? (string-ref name i))
            unit
            (set! valid false))
          (set! i (+ i 1))))
      valid)))

(define (compiler-backend-asm-safe-symbol-flush-run
  [name : String]
  [start : i64]
  [end : i64]
  [buf : TextBuf]) : TextBuf
  (if (> end start)
    (text-buf-append buf (substring name start (- end start)))
    buf))

(define (compiler-backend-asm-safe-symbol [name : String]) : String
  (let
    [i : i64 0]
    [n : i64 (string-length name)]
    [start : i64 0]
    [changed : bool false]
    [buf : TextBuf (text-buf-empty)]
    (begin
      (while (< i n)
        (let
          [c : char (string-ref name i)]
          (if (compiler-backend-symbol-safe-char? c)
            (set! i (+ i 1))
            (begin
              (set! changed true)
              (set!
                buf
                (compiler-backend-asm-safe-symbol-flush-run name start i buf))
              (set!
                buf
                (text-buf-append buf (compiler-backend-symbol-char name i c)))
              (set! i (+ i 1))
              (set! start i)))))
      (if changed
        (text-buf-render
          (compiler-backend-asm-safe-symbol-flush-run name start n buf))
        name))))

(define (compiler-backend-user-symbol-separator? [c : char]) : bool
  (or (= c #/') (= c #\\') (= c #:') (= c #.')))

(define (compiler-backend-user-symbol-tl-extension-at?
  [name : String]
  [idx : i64]) : bool
  (let
    [n : i64 (string-length name)]
    [after : i64 (+ idx 3)]
    (and
      (<= after n)
      (= (string-ref name idx) #.')
      (= (string-ref name (+ idx 1)) #t')
      (= (string-ref name (+ idx 2)) #l')
      (or
        (= after n)
        (compiler-backend-user-symbol-separator? (string-ref name after))))))

(define (compiler-backend-user-symbol-body [name : String]) : String
  (let
    [i : i64 0]
    [n : i64 (string-length name)]
    [buf : TextBuf (text-buf-empty)]
    [emitted : bool false]
    [pending-separator : bool false]
    (begin
      (while (< i n)
        (if (compiler-backend-user-symbol-tl-extension-at? name i)
          (set! i (+ i 3))
          (let
            [c : char (string-ref name i)]
            (if (compiler-backend-user-symbol-separator? c)
              (begin
                (if emitted
                  (set! pending-separator true)
                  unit)
                (set! i (+ i 1)))
              (begin
                (if pending-separator
                  (begin
                    (set! buf (text-buf-append buf "_"))
                    (set! pending-separator false))
                  unit)
                (set!
                  buf
                  (text-buf-append buf (compiler-backend-symbol-char name i c)))
                (set! emitted true)
                (set! i (+ i 1)))))))
      (text-buf-render buf))))

(define (compiler-backend-user-symbol-uncached [name : String]) : String
  (if (string-eq name "main")
    "main"
    (string-append "_tl_" (compiler-backend-user-symbol-body name))))

(define (compiler-backend-user-symbol-id [name-id : i64]) : String
  (begin
    (compiler-backend-user-symbol-cache-ensure-current!)
    (if (and
      (>= name-id 0)
      (< name-id (array-length compiler-backend-user-symbol-cache-values)))
      (if (=
        (array-ref compiler-backend-user-symbol-cache-epochs name-id)
        compiler-backend-user-symbol-cache-epoch)
        (array-ref compiler-backend-user-symbol-cache-values name-id)
        (let
          [symbol : String
            (compiler-backend-user-symbol-uncached (intern-str name-id))]
          (begin
            (array-set!
              compiler-backend-user-symbol-cache-values
              name-id
              symbol)
            (array-set!
              compiler-backend-user-symbol-cache-epochs
              name-id
              compiler-backend-user-symbol-cache-epoch)
            (set!
              compiler-backend-user-symbol-cache-count-value
              (+ compiler-backend-user-symbol-cache-count-value 1))
            symbol)))
      (compiler-backend-user-symbol-uncached (intern-str name-id)))))

(define (compiler-backend-user-symbol [name : String]) : String
  (match (intern-lookup name)
    [(InternLookupFound name-id) (compiler-backend-user-symbol-id name-id)]
    [(InternLookupMissing) (compiler-backend-user-symbol-uncached name)]))

(define (compiler-backend-symbol-leaf [name : String]) : String
  (let
    [i : i64 0]
    [n : i64 (string-length name)]
    [start : i64 0]
    (begin
      (while (< i n)
        (begin
          (if (or (= (string-ref name i) #/') (= (string-ref name i) #:'))
            (set! start (+ i 1))
            unit)
          (set! i (+ i 1))))
      (substring name start (- n start)))))

(define (compiler-backend-public-function-symbol? [name : String]) : bool
  (let
    [i : i64 0]
    [n : i64 (string-length name)]
    [found : bool false]
    (begin
      (while (and (< i n) (not found))
        (begin
          (if (= (string-ref name i) #:')
            (set! found true)
            unit)
          (set! i (+ i 1))))
      found)))

(define (compiler-backend-compact-function-symbol? [name : String]) : bool
  (and
    (> (string-length name) 16)
    (not (string-eq name "main"))
    (not (compiler-backend-string-prefix-at? name "__global_init_" 0))
    (not (compiler-backend-public-function-symbol? name))))

(define (compiler-backend-function-symbol-index
  [index : CompilerBackendProgramIndex]
  [name : String]) : String
  (if (compiler-backend-index-extern-provided? index name)
    (compiler-backend-index-extern-link-symbol index name)
    (if (compiler-backend-compact-function-symbol? name)
      (match (compiler-backend-index-function-slot index name)
        [(I64I64MapFound slot) (str-cat "_tl_f" (int->string slot) "")]
        [(I64I64MapMissing) (compiler-backend-user-symbol name)])
      (compiler-backend-user-symbol name))))

(define (compiler-backend-function-symbol-map-comment
  [index : CompilerBackendProgramIndex]
  [name : String]) : String
  (if (and
    (compiler-backend-compact-function-symbol? name)
    (not (compiler-backend-index-extern-provided? index name)))
    (string-append
      "#t "
      (string-append
        (compiler-backend-function-symbol-index index name)
        (string-append
          " "
          (string-append
            (compiler-backend-user-symbol (compiler-backend-symbol-leaf name))
            "\n"))))
    ""))

(define (compiler-backend-closure-descriptor-label [name : String]) : String
  (string-append ".L_tl_fn_desc_" (compiler-backend-asm-safe-symbol name)))

(define (compiler-backend-closure-entry-label [name : String]) : String
  (string-append ".L_tl_fn_entry_" (compiler-backend-asm-safe-symbol name)))

(define (compiler-backend-runtime-user-symbol? [name : String]) : bool
  (let
    [name-id : i64 (compiler-backend-runtime-helper-name-id name)]
    (and
      (>= name-id 0)
      (compiler-builtin-backend-env-path-separator-id? name-id))))

(define (compiler-backend-fixed-fault-symbol? [name : String]) : bool
  (or
    (let
      [name-id : i64 (compiler-backend-runtime-helper-name-id name)]
      (and (>= name-id 0) (compiler-builtin-backend-fixed-fault-id? name-id)))
    ;; #2386: tl_memcpy is emitted unconditionally (see
    ;; compiler-backend-runtime-memcpy-functions); calls to it use the raw symbol,
    ;; not the user-mangled _tl_ name. Main's intern-id fault set (#2529) does not
    ;; include it (it is a copy helper, not a fault), so keep an explicit check.
    (string-eq name "tl_memcpy")))

(define (compiler-backend-call-raw-symbol?
  [plan : CompilerBackendRuntimePlan]
  [name : String]) : bool
  (or
    (compiler-backend-plan-provides? plan name)
    (compiler-backend-fixed-fault-symbol? name)))

(define (compiler-backend-link-symbol
  [name : String]
  [plan : CompilerBackendRuntimePlan]) : String
  (if (compiler-backend-call-raw-symbol? plan name)
    (if (compiler-backend-runtime-user-symbol? name)
      (compiler-backend-user-symbol name)
      name)
    (compiler-backend-asm-safe-symbol name)))

(define (compiler-backend-call-symbol
  [name : String]
  [plan : CompilerBackendRuntimePlan]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]) : String
  (if (compiler-backend-extern-list-references? externs name)
    (let
      [link-symbol : String
        (compiler-backend-extern-list-link-symbol externs name)]
      (if (and
        (string-eq link-symbol name)
        (compiler-backend-call-raw-symbol? plan name)
        (not (compiler-backend-function-list-defines? functions name)))
        (if (compiler-backend-runtime-user-symbol? name)
          (compiler-backend-user-symbol name)
          name)
        (compiler-backend-link-symbol link-symbol plan)))
    (if (and
      (compiler-backend-call-raw-symbol? plan name)
      (not (compiler-backend-function-list-defines? functions name)))
      (if (compiler-backend-runtime-user-symbol? name)
        (compiler-backend-user-symbol name)
        name)
      (compiler-backend-user-symbol name))))

(define (compiler-backend-call-symbol-index
  [name : String]
  [plan : CompilerBackendRuntimePlan]
  [index : CompilerBackendProgramIndex]) : String
  (cond
    [(compiler-backend-index-extern-provided? index name)
      (compiler-backend-index-extern-link-symbol index name)]
    [(compiler-backend-index-extern-references? index name)
      (let
        [link-symbol : String
          (compiler-backend-index-extern-link-symbol index name)]
        (if (and
          (string-eq link-symbol name)
          (compiler-backend-call-raw-symbol? plan name)
          (not (compiler-backend-index-function-defines? index name)))
          (if (compiler-backend-runtime-user-symbol? name)
            (compiler-backend-user-symbol name)
            name)
          (compiler-backend-link-symbol link-symbol plan)))]
    [(and
        (compiler-backend-call-raw-symbol? plan name)
        (not (compiler-backend-index-function-defines? index name)))
      (if (compiler-backend-runtime-user-symbol? name)
        (compiler-backend-user-symbol name)
        name)]
    [else (compiler-backend-function-symbol-index index name)]))

(define (compiler-backend-function-label-scope
  [index : CompilerBackendProgramIndex]
  [name : String]) : String
  (match (compiler-backend-index-function-slot index name)
    [(I64I64MapFound slot) (str-cat "f" (int->string slot) "")]
    [(I64I64MapMissing) (compiler-backend-user-symbol name)]))

(define (compiler-backend-type-size [ty : AstType]) : i64
  (match ty
    [(AstTyI64) 8]
    [(AstTyU64) 8]
    [(AstTyF64) 8]
    [(AstTyI32) 4]
    [(AstTyU32) 4]
    [(AstTyF32) 4]
    [(AstTyI16) 2]
    [(AstTyU16) 2]
    [(AstTyI8) 1]
    [(AstTyU8) 1]
    [(AstTyBool) 1]
    [(AstTyChar) 1]
    [(AstTyUnit) 0]
    [(AstTyNever) 0]
    [(AstTyExpr) 0]
    [(AstTyExprList) 0]
    [(AstTyFunc _ _) 8]
    [(AstTyTuple _) 8]
    [(AstTyArray _ _) 8]
    [(AstTyDynArray _) 8]
    [(AstTyBox _) 8]
    [(AstTyPtr _) 8]
    [(AstTyMutPtr _) 8]
    [(AstTyRef _ _) 8]
    [(AstTyMutRef _ _) 8]
    [(AstTyRegion _ inner) (compiler-backend-type-size (ty-node-get inner))]
    [(AstTyEnum _) 8]
    [(AstTyEnumArgs _ _) 8]
    [(AstTyStruct _) 8]
    [(AstTyStructArgs _ _) 8]
    [(AstTyString) 8]
    [(AstTyStr) 8]
    [(AstTyBytes) 8]
    [(AstTyVar _) 8]
    [(AstTyVarArgs _ _) 8]))

(define (compiler-backend-f64-type? [ty : AstType]) : bool
  (match ty
    [(AstTyF64) true]
    [_ false]))

(define (compiler-backend-type-signed? [ty : AstType]) : bool
  (match ty
    [(AstTyI64) true]
    [(AstTyI32) true]
    [(AstTyI16) true]
    [(AstTyI8) true]
    [_ false]))

(define (compiler-backend-intlike-scalar-type? [ty : AstType]) : bool
  (match ty
    [(AstTyI64) true]
    [(AstTyU64) true]
    [(AstTyI32) true]
    [(AstTyU32) true]
    [(AstTyI16) true]
    [(AstTyU16) true]
    [(AstTyI8) true]
    [(AstTyU8) true]
    [(AstTyBool) true]
    [(AstTyChar) true]
    [_ false]))

(define (compiler-backend-hex-digit [n : i64]) : String
  (cond
    [(= n 0) "0"]
    [(= n 1) "1"]
    [(= n 2) "2"]
    [(= n 3) "3"]
    [(= n 4) "4"]
    [(= n 5) "5"]
    [(= n 6) "6"]
    [(= n 7) "7"]
    [(= n 8) "8"]
    [(= n 9) "9"]
    [(= n 10) "a"]
    [(= n 11) "b"]
    [(= n 12) "c"]
    [(= n 13) "d"]
    [(= n 14) "e"]
    [else "f"]))

(define (compiler-backend-hex-byte [n : i64]) : String
  (string-append
    (compiler-backend-hex-digit (/ n 16))
    (compiler-backend-hex-digit (% n 16))))

(define (compiler-backend-octal-digit [n : i64]) : String
  (cond
    [(= n 0) "0"]
    [(= n 1) "1"]
    [(= n 2) "2"]
    [(= n 3) "3"]
    [(= n 4) "4"]
    [(= n 5) "5"]
    [(= n 6) "6"]
    [else "7"]))

(define (compiler-backend-octal-escape [n : i64]) : String
  (string-append
    "\\"
    (string-append
      (compiler-backend-octal-digit (/ n 64))
      (string-append
        (compiler-backend-octal-digit (% (/ n 8) 8))
        (compiler-backend-octal-digit (% n 8))))))

(define (compiler-backend-escape-string-byte
  [text : String]
  [idx : i64]
  [c : char]) : String
  (cond
    [(= c #"') "\\\""]
    [(= c #\\') "\\\\"]
    [(= c #\newline') "\\n"]
    [(= c #\tab') "\\t"]
    [(= c #\return') "\\r"]
    [(and (>= c #\space') (<= c #~')) (substring text idx 1)]
    [else (compiler-backend-octal-escape (compiler-backend-char-code c))]))

(define (compiler-backend-string-byte-raw? [c : char]) : bool
  (cond
    [(= c #"') false]
    [(= c #\\') false]
    [(< c #\space') false]
    [(> c #~') false]
    [else true]))

(define (compiler-backend-escape-string [text : String]) : String
  (let
    [i : i64 0]
    [n : i64 (string-length text)]
    [buf : TextBuf (text-buf-empty)]
    [start : i64 0]
    [escaped : bool false]
    (begin
      (while (< i n)
        (let
          [c : char (string-ref text i)]
          (if (compiler-backend-string-byte-raw? c)
            (set! i (+ i 1))
            (begin
              (if (< start i)
                (set!
                  buf
                  (text-buf-append buf (substring text start (- i start))))
                unit)
              (set!
                buf
                (text-buf-append
                  buf
                  (compiler-backend-escape-string-byte text i c)))
              (set! i (+ i 1))
              (set! start i)
              (set! escaped true)))))
      (if escaped
        (begin
          (if (< start n)
            (set! buf (text-buf-append buf (substring text start (- n start))))
            unit)
          (text-buf-render buf))
        text))))

(define (compiler-backend-quoted-gas-string [text : String]) : String
  (string-append
    "\""
    (string-append (compiler-backend-escape-string text) "\"")))

(define (compiler-backend-string-label-suffix [text : String]) : String
  (let
    [n : i64 (string-length text)]
    (if (= n 0)
      "empty"
      (str-cat
        "l"
        (int->string n)
        "_"
        (int->string (compiler-backend-string-label-forward-hash text))
        (string-append
          "_"
          (int->string (compiler-backend-string-label-reverse-hash text)))))))

(define (compiler-backend-string-label-forward-hash [key : String]) : i64
  (hash-string (& key)))

(define (compiler-backend-string-label-reverse-hash [text : String]) : i64
  (let
    [i : i64 (- (string-length text) 1)]
    [hash : i64 0]
    (begin
      (while (>= i 0)
        (let
          [next : i64
            (+
              (+ (* hash 131) (compiler-backend-char-code (string-ref text i)))
              1)]
          [reduced : i64 (+ (bit-and next 0x7fffffff) (shr next 31))]
          (begin
            (set!
              hash
              (if (>= reduced 0x7fffffff)
                (- reduced 0x7fffffff)
                reduced))
            (set! i (- i 1)))))
      hash)))

(define (compiler-backend-string-data-label [text : String]) : String
  (string-append ".L_tl_str_data_" (compiler-backend-string-label-suffix text)))

(define (compiler-backend-string-fat-label [text : String]) : String
  (string-append ".L_tl_str_" (compiler-backend-string-label-suffix text)))

(define (compiler-backend-bytes-data-label [text : String]) : String
  (string-append ".L_tl_bin_data_" (compiler-backend-string-label-suffix text)))

(define (compiler-backend-bytes-fat-label [text : String]) : String
  (string-append ".L_tl_bin_" (compiler-backend-string-label-suffix text)))

(define (compiler-backend-f64-label [text : String]) : String
  (string-append ".L_tl_f64_" (compiler-backend-string-label-suffix text)))

(define (compiler-backend-f64-sign-bit-label) : String
  ".L_tl_f64_sign_bit")

(define (compiler-backend-emit-load-float-value-with-plan
  [assignments : CompilerRegAssignmentList]
  [value : CompilerIrValue]
  [ty : AstType]
  [reg : String]) : ResultCompilerBackend
  (let
    [mov : String (compiler-backend-float-move ty)]
    (match value
      [(IrValueVar id)
        (OkCompilerBackend
          (compiler-backend-emit-load-float-var-with-plan assignments id ty reg))]
      [(IrValueGlobal name)
        (OkCompilerBackend
          (str-cat
            "    "
            mov
            " "
            (compiler-backend-user-symbol name)
            "(%rip), "
            reg
            "\n"))]
      [(IrValueF64 text)
        (if (compiler-backend-f64-type? ty)
          (OkCompilerBackend
            (str-cat
              "    movsd "
              (compiler-backend-f64-label text)
              "(%rip), "
              reg
              "\n"))
          (OkCompilerBackend
            (string-append
              (str-cat
                "    movsd "
                (compiler-backend-f64-label text)
                "(%rip), "
                reg
                "\n")
              (str-cat "    cvtsd2ss " reg ", " reg "\n"))))]
      [_
        (ErrCompilerBackend
          (compiler-diagnostic-at-start
            ""
            (string-append
              "backend: expected "
              (string-append (compiler-backend-float-type-name ty) " value"))))])))

(define (compiler-backend-emit-load-f64-value-with-plan
  [assignments : CompilerRegAssignmentList]
  [value : CompilerIrValue]
  [reg : String]) : ResultCompilerBackend
  (compiler-backend-emit-load-float-value-with-plan
    assignments
    value
    (AstTyF64)
    reg))

;; #2997: prefer compact 32-bit encodings for small non-negative immediates.
;; Writing a 32-bit register zero-extends into the full 64-bit register, so for
;; 0 <= n < 2^31 the 64-bit value is exactly n: `xorl r32,r32` (2 bytes) clears
;; the register, and `movl $n,r32` (5-6 bytes) beats `movq $n,r64` (7 bytes, or
;; a 10-byte movabs once n no longer fits a signed-32 immediate). Negative or
;; >= 2^31 values keep the full-width `movq $n` (sign extension / 64-bit
;; immediate), which the assembler widens to movabs as needed.
(define (compiler-backend-emit-load-i64-immediate [n : i64] [reg : String]) : String
  (if (= n 0)
    (let
      [reg32 : String (compiler-backend-reg-part reg 4)]
      (str-cat "    xorl " reg32 ", " reg32 "\n"))
    (if (and (> n 0) (< n 2147483648))
      (let
        [reg32 : String (compiler-backend-reg-part reg 4)]
        (str-cat "    movl $" (int->string n) ", " reg32 "\n"))
      (str-cat "    movq $" (int->string n) ", " reg "\n"))))

(define (compiler-backend-emit-load-value-with-plan
  [assignments : CompilerRegAssignmentList]
  [value : CompilerIrValue]
  [reg : String]) : ResultCompilerBackend
  (match value
    [(IrValueVar id)
      (OkCompilerBackend
        (compiler-backend-emit-load-var-with-plan assignments id reg))]
    [(IrValueGlobal name)
      (OkCompilerBackend
        (str-cat
          "    movq "
          (compiler-backend-user-symbol name)
          "(%rip), "
          reg
          "\n"))]
    [(IrValueGlobalAddr name)
      (OkCompilerBackend
        (str-cat
          "    leaq "
          (compiler-backend-user-symbol name)
          "(%rip), "
          reg
          "\n"))]
    [(IrValueFunction name)
      (OkCompilerBackend
        (str-cat
          "    leaq "
          (compiler-backend-closure-descriptor-label name)
          "(%rip), "
          reg
          "\n"))]
    [(IrValueI64 n)
      (OkCompilerBackend (compiler-backend-emit-load-i64-immediate n reg))]
    [(IrValueBool b)
      (if b
        (OkCompilerBackend (compiler-backend-emit-load-i64-immediate 1 reg))
        (OkCompilerBackend (compiler-backend-emit-load-i64-immediate 0 reg)))]
    [(IrValueChar c)
      (OkCompilerBackend
        (compiler-backend-emit-load-i64-immediate
          (compiler-backend-char-code c)
          reg))]
    [(IrValueUnit)
      (OkCompilerBackend (compiler-backend-emit-load-i64-immediate 0 reg))]
    [(IrValueF64 _)
      (ErrCompilerBackend
        (compiler-diagnostic-at-start
          ""
          "backend: f64 values are not supported yet"))]
    [(IrValueString text)
      (OkCompilerBackend
        (str-cat
          "    leaq "
          (compiler-backend-string-fat-label text)
          "(%rip), "
          reg
          "\n"))]
    [(IrValueBytes text)
      (OkCompilerBackend
        (str-cat
          "    leaq "
          (compiler-backend-bytes-fat-label text)
          "(%rip), "
          reg
          "\n"))]))

(define (compiler-backend-emit-load-value
  [value : CompilerIrValue]
  [reg : String]) : ResultCompilerBackend
  (compiler-backend-emit-load-value-with-plan
    CompilerRegAssignmentNil
    value
    reg))

(define (compiler-backend-emit-load-typed-var-to-reg-with-plan
  [assignments : CompilerRegAssignmentList]
  [id : i64]
  [ty : AstType]
  [reg : String]) : String
  (match (compiler-reg-assignment-lookup assignments id)
    [(CompilerRegSomeLocation location)
      (match location
        [(CompilerRegRegister home)
          (compiler-backend-emit-load-register-to-reg home ty reg)]
        ;; #2386: a whole register-group is loaded word-wise by the group
        ;; ABI paths; reaching the generic scalar load means word0's home.
        [(CompilerRegRegisterPair home _)
          (compiler-backend-emit-load-register-to-reg home ty reg)]
        [(CompilerRegSpill offset)
          (compiler-backend-emit-load-memory-to-reg
            (compiler-backend-frame-offset offset)
            ty
            reg)])]
    [(CompilerRegNoLocation)
      (compiler-backend-emit-load-memory-to-reg
        (compiler-backend-slot id)
        ty
        reg)]))

(define (compiler-backend-address-base-register-ok?
  [home : String]
  [avoid : String]) : bool
  (and
    (not (string-eq home ""))
    (not (string-eq home "%rax"))
    (not (string-eq home "%r11"))
    (if (string-eq avoid "")
      true
      (not (string-eq home avoid)))))

(define (compiler-backend-address-base-home
  [assignments : CompilerRegAssignmentList]
  [value : CompilerIrValue]
  [avoid : String]) : String
  (match value
    [(IrValueVar id)
      (if (>= (compiler-backend-forwarded-addr-of-src id) 0)
        ""
        (match (compiler-reg-assignment-lookup assignments id)
          [(CompilerRegSomeLocation location)
            (match location
              [(CompilerRegRegister home)
                (if (compiler-backend-address-base-register-ok? home avoid)
                  home
                  "")]
              [_ ""])]
          [(CompilerRegNoLocation) ""]))]
    [_ ""]))

(define (compiler-backend-emit-address-base-with-avoid
  [assignments : CompilerRegAssignmentList]
  [value : CompilerIrValue]
  [fallback-reg : String]
  [avoid : String]) : ResultCompilerBackendAddressBase
  (let
    [home : String (compiler-backend-address-base-home assignments value avoid)]
    (if (string-eq home "")
      (match (compiler-backend-emit-load-value-with-plan
        assignments
        value
        fallback-reg)
        [(OkCompilerBackend asm)
          (OkCompilerBackendAddressBase
            (CompilerBackendAddressBase asm fallback-reg))]
        [(ErrCompilerBackend message) (ErrCompilerBackendAddressBase message)])
      (OkCompilerBackendAddressBase (CompilerBackendAddressBase "" home)))))

(define (compiler-backend-emit-address-base
  [assignments : CompilerRegAssignmentList]
  [value : CompilerIrValue]
  [fallback-reg : String]) : ResultCompilerBackendAddressBase
  (compiler-backend-emit-address-base-with-avoid
    assignments
    value
    fallback-reg
    ""))

(define (compiler-backend-emit-load-memory [addr : String] [ty : AstType]) : String
  (let
    [size : i64 (compiler-backend-type-size ty)]
    (cond
      [(= size 8) (str-cat "    movq " addr ", %rax\n")]
      [(= size 4)
        (if (compiler-backend-type-signed? ty)
          (str-cat "    movslq " addr ", %rax\n")
          (str-cat "    movl " addr ", %eax\n"))]
      [(= size 2)
        (if (compiler-backend-type-signed? ty)
          (str-cat "    movswq " addr ", %rax\n")
          (str-cat "    movzwq " addr ", %rax\n"))]
      [(= size 1)
        (if (compiler-backend-type-signed? ty)
          (str-cat "    movsbq " addr ", %rax\n")
          (str-cat "    movzbq " addr ", %rax\n"))]
      [else ""])))

(define (compiler-backend-emit-load-float-memory
  [addr : String]
  [reg : String]
  [ty : AstType]) : String
  (str-cat "    " (compiler-backend-float-move ty) " " addr ", " reg "\n"))

(define (compiler-backend-emit-load-f64-memory [addr : String] [reg : String]) : String
  (compiler-backend-emit-load-float-memory addr reg (AstTyF64)))

(define (compiler-backend-reg-part [reg : String] [size : i64]) : String
  (cond
    [(= size 8) reg]
    [(string-eq reg "%rax")
      (if (= size 4)
        "%eax"
        (if (= size 2)
          "%ax"
          "%al"))]
    [(string-eq reg "%rbx")
      (if (= size 4)
        "%ebx"
        (if (= size 2)
          "%bx"
          "%bl"))]
    [(string-eq reg "%rcx")
      (if (= size 4)
        "%ecx"
        (if (= size 2)
          "%cx"
          "%cl"))]
    [(string-eq reg "%rdx")
      (if (= size 4)
        "%edx"
        (if (= size 2)
          "%dx"
          "%dl"))]
    [(string-eq reg "%rdi")
      (if (= size 4)
        "%edi"
        (if (= size 2)
          "%di"
          "%dil"))]
    [(string-eq reg "%rsi")
      (if (= size 4)
        "%esi"
        (if (= size 2)
          "%si"
          "%sil"))]
    [(string-eq reg "%r12")
      (if (= size 4)
        "%r12d"
        (if (= size 2)
          "%r12w"
          "%r12b"))]
    [(string-eq reg "%r13")
      (if (= size 4)
        "%r13d"
        (if (= size 2)
          "%r13w"
          "%r13b"))]
    [(string-eq reg "%r14")
      (if (= size 4)
        "%r14d"
        (if (= size 2)
          "%r14w"
          "%r14b"))]
    [(string-eq reg "%r15")
      (if (= size 4)
        "%r15d"
        (if (= size 2)
          "%r15w"
          "%r15b"))]
    [(string-eq reg "%r8")
      (if (= size 4)
        "%r8d"
        (if (= size 2)
          "%r8w"
          "%r8b"))]
    [(string-eq reg "%r9")
      (if (= size 4)
        "%r9d"
        (if (= size 2)
          "%r9w"
          "%r9b"))]
    [(string-eq reg "%r10")
      (if (= size 4)
        "%r10d"
        (if (= size 2)
          "%r10w"
          "%r10b"))]
    [(string-eq reg "%r11")
      (if (= size 4)
        "%r11d"
        (if (= size 2)
          "%r11w"
          "%r11b"))]
    [else
      (if (= size 4)
        "%r15d"
        (if (= size 2)
          "%r15w"
          "%r15b"))]))

(define (compiler-backend-emit-load-memory-to-reg
  [addr : String]
  [ty : AstType]
  [reg : String]) : String
  (let
    [size : i64 (compiler-backend-type-size ty)]
    (cond
      [(= size 8) (str-cat "    movq " addr ", " reg "\n")]
      [(= size 4)
        (if (compiler-backend-type-signed? ty)
          (str-cat "    movslq " addr ", " reg "\n")
          (str-cat "    movl " addr ", " (compiler-backend-reg-part reg 4) "\n"))]
      [(= size 2)
        (if (compiler-backend-type-signed? ty)
          (str-cat "    movswq " addr ", " reg "\n")
          (str-cat "    movzwq " addr ", " reg "\n"))]
      [(= size 1)
        (if (compiler-backend-type-signed? ty)
          (str-cat "    movsbq " addr ", " reg "\n")
          (str-cat "    movzbq " addr ", " reg "\n"))]
      [else ""])))

(define (compiler-backend-emit-load-register-to-reg
  [src-reg : String]
  [ty : AstType]
  [dst-reg : String]) : String
  (let
    [size : i64 (compiler-backend-type-size ty)]
    (cond
      [(= size 8)
        (if (string-eq src-reg dst-reg)
          ""
          (str-cat "    movq " src-reg ", " dst-reg "\n"))]
      [(= size 4)
        (if (compiler-backend-type-signed? ty)
          (str-cat
            "    movslq "
            (compiler-backend-reg-part src-reg size)
            ", "
            dst-reg
            "\n")
          (str-cat
            "    movl "
            (compiler-backend-reg-part src-reg size)
            ", "
            (compiler-backend-reg-part dst-reg size)
            "\n"))]
      [(= size 2)
        (if (compiler-backend-type-signed? ty)
          (str-cat
            "    movswq "
            (compiler-backend-reg-part src-reg size)
            ", "
            dst-reg
            "\n")
          (str-cat
            "    movzwq "
            (compiler-backend-reg-part src-reg size)
            ", "
            dst-reg
            "\n"))]
      [(= size 1)
        (if (compiler-backend-type-signed? ty)
          (str-cat
            "    movsbq "
            (compiler-backend-reg-part src-reg size)
            ", "
            dst-reg
            "\n")
          (str-cat
            "    movzbq "
            (compiler-backend-reg-part src-reg size)
            ", "
            dst-reg
            "\n"))]
      [else ""])))

(define (compiler-backend-emit-load-register [reg : String] [ty : AstType]) : String
  (compiler-backend-emit-load-register-to-reg reg ty "%rax"))

(define (compiler-backend-emit-store-rax-to-memory
  [addr : String]
  [ty : AstType]) : String
  (compiler-backend-emit-store-reg-to-memory addr "%rax" ty))

(define (compiler-backend-emit-store-reg-to-memory
  [addr : String]
  [reg : String]
  [ty : AstType]) : String
  (let
    [size : i64 (compiler-backend-type-size ty)]
    (cond
      [(= size 8) (str-cat "    movq " reg ", " addr "\n")]
      [(= size 4)
        (str-cat "    movl " (compiler-backend-reg-part reg 4) ", " addr "\n")]
      [(= size 2)
        (str-cat "    movw " (compiler-backend-reg-part reg 2) ", " addr "\n")]
      [(= size 1)
        (str-cat "    movb " (compiler-backend-reg-part reg 1) ", " addr "\n")]
      [else ""])))

(define (compiler-backend-emit-store-xmm-to-memory
  [addr : String]
  [reg : String]
  [ty : AstType]) : String
  (str-cat "    " (compiler-backend-float-move ty) " " reg ", " addr "\n"))

(define (compiler-backend-store-immediate-mnemonic [ty : AstType]) : String
  (let
    [size : i64 (compiler-backend-type-size ty)]
    (cond
      [(= size 8) "movq"]
      [(= size 4) "movl"]
      [(= size 2) "movw"]
      [(= size 1) "movb"]
      [else ""])))

(define (compiler-backend-emit-store-immediate-to-memory
  [value : CompilerIrValue]
  [addr : String]
  [ty : AstType]) : CompilerBackendMaybeAsm
  (if (compiler-backend-float-type? ty)
    (CompilerBackendNoAsm)
    (match (compiler-backend-immediate-operand value)
      [(CompilerBackendSomeImmediate imm)
        (let
          [mnemonic : String (compiler-backend-store-immediate-mnemonic ty)]
          (if (string-eq mnemonic "")
            (CompilerBackendNoAsm)
            (CompilerBackendSomeAsm
              (str-cat "    " mnemonic " " imm ", " addr "\n"))))]
      [(CompilerBackendNoImmediate) (CompilerBackendNoAsm)])))

(define (compiler-backend-emit-load-immediate-to-reg
  [value : CompilerIrValue]
  [reg : String]) : CompilerBackendMaybeAsm
  (match (compiler-backend-value-as-i64 value)
    [(CompilerBackendSomeI64 n)
      (CompilerBackendSomeAsm (compiler-backend-emit-load-i64-immediate n reg))]
    [(CompilerBackendNoI64)
      (match (compiler-backend-immediate-operand value)
        [(CompilerBackendSomeImmediate imm)
          (CompilerBackendSomeAsm (str-cat "    movq " imm ", " reg "\n"))]
        [(CompilerBackendNoImmediate) (CompilerBackendNoAsm)])]))

(define (compiler-backend-emit-store-immediate-to-var-home
  [assignments : CompilerRegAssignmentList]
  [var-id : i64]
  [value : CompilerIrValue]) : CompilerBackendMaybeAsm
  (match (compiler-backend-immediate-operand value)
    [(CompilerBackendSomeImmediate imm)
      (match (compiler-reg-assignment-lookup assignments var-id)
        [(CompilerRegSomeLocation location)
          (match location
            [(CompilerRegRegister home)
              (compiler-backend-emit-load-immediate-to-reg value home)]
            ;; #2386: an immediate never targets a whole register-group; unreached.
            [(CompilerRegRegisterPair home _)
              (compiler-backend-emit-load-immediate-to-reg value home)]
            [(CompilerRegSpill offset)
              (CompilerBackendSomeAsm
                (str-cat
                  "    movq "
                  imm
                  ", "
                  (compiler-backend-frame-offset offset)
                  "\n"))])]
        [(CompilerRegNoLocation)
          (CompilerBackendSomeAsm
            (str-cat "    movq " imm ", " (compiler-backend-slot var-id) "\n"))])]
    [(CompilerBackendNoImmediate) (CompilerBackendNoAsm)]))

(define (compiler-backend-avx2-vector-reduce-move-scalar [elem-ty : AstType]) : String
  (match elem-ty
    [(AstTyI32) "    vmovd %xmm0, %eax\n"]
    [(AstTyF64) ""]
    [_ "    vmovq %xmm0, %rax\n"]))

(define (compiler-backend-vector-reduce-result-reg [elem-ty : AstType]) : String
  (if (compiler-backend-float-type? elem-ty)
    "%xmm0"
    "%rax"))

(define (compiler-backend-avx2-vector-reduce-horizontal-asm
  [mnemonic : String]
  [ymm : String]
  [xmm : String]
  [elem-ty : AstType]) : String
  (match elem-ty
    [(AstTyF64)
      (string-append
        (str-cat
          "    vextractf128 $1, "
          ymm
          ", %xmm0\n    "
          mnemonic
          " %xmm0, "
          xmm
          ", %xmm0\n")
        "    vunpckhpd %xmm0, %xmm0, %xmm1\n    vaddsd %xmm1, %xmm0, %xmm0\n")]
    [(AstTyI64)
      (string-append
        (str-cat
          "    vextracti128 $1, "
          ymm
          ", %xmm0\n    "
          mnemonic
          " %xmm0, "
          xmm
          ", %xmm0\n")
        (str-cat
          "    vpsrldq $8, %xmm0, %xmm1\n    "
          mnemonic
          " %xmm1, %xmm0, %xmm0\n"
          ""))]
    [(AstTyI32)
      (string-append
        (str-cat
          "    vextracti128 $1, "
          ymm
          ", %xmm0\n    "
          mnemonic
          " %xmm0, "
          xmm
          ", %xmm0\n")
        (string-append
          (str-cat
            "    vpsrldq $8, %xmm0, %xmm1\n    "
            mnemonic
            " %xmm1, %xmm0, %xmm0\n"
            "")
          (str-cat
            "    vpsrldq $4, %xmm0, %xmm1\n    "
            mnemonic
            " %xmm1, %xmm0, %xmm0\n"
            "")))]
    [_ ""]))

(define (compiler-backend-emit-avx2-vector-reduce
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [op : CompilerIrVectorReduceOp]
  [src : CompilerIrValue]
  [lanes : i64]
  [elem-ty : AstType]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (if (compiler-backend-avx2-shape-ok? elem-ty lanes)
    (let
      [mnemonic : String
        (compiler-backend-avx2-vector-reduce-op-mnemonic op elem-ty)]
      (if (= (string-length mnemonic) 0)
        (ErrCompilerBackend
          (compiler-diagnostic-with-message
            instr-diag
            "backend: unsupported AVX2 vector reduction"))
        (match src
          [(IrValueVar src-var)
            (match (compiler-backend-vector-var-reg
              assignments
              src-var
              "reduce source"
              "ymm")
              [(OkBackendReg ymm)
                (match (compiler-backend-vector-var-reg
                  assignments
                  src-var
                  "reduce source"
                  "xmm")
                  [(OkBackendReg xmm)
                    (OkCompilerBackend
                      (string-append
                        (compiler-backend-avx2-vector-reduce-horizontal-asm
                          mnemonic
                          ymm
                          xmm
                          elem-ty)
                        (string-append
                          (compiler-backend-avx2-vector-reduce-move-scalar
                            elem-ty)
                          (compiler-backend-emit-store-typed-var-with-plan
                            assignments
                            dst
                            (compiler-backend-vector-reduce-result-reg elem-ty)
                            elem-ty))))]
                  [(ErrBackendReg message)
                    (ErrCompilerBackend
                      (compiler-diagnostic-with-message instr-diag message))])]
              [(ErrBackendReg message)
                (ErrCompilerBackend
                  (compiler-diagnostic-with-message instr-diag message))])]
          [_
            (ErrCompilerBackend
              (compiler-diagnostic-with-message
                instr-diag
                "backend: unsupported AVX2 vector reduce source"))])))
    (compiler-backend-avx2-shape-diagnostic instr-diag elem-ty lanes)))

(define (compiler-backend-avx512-vector-reduce-horizontal-asm
  [mnemonic : String]
  [zmm : String]
  [ymm : String]
  [elem-ty : AstType]) : String
  (match elem-ty
    [(AstTyF64)
      (string-append
        (string-append
          (str-cat
            "    vextractf64x4 $1, "
            zmm
            ", %ymm0\n    "
            mnemonic
            " %ymm0, "
            ymm
            ", %ymm0\n")
          (str-cat
            "    vextractf128 $1, %ymm0, %xmm1\n    "
            mnemonic
            " %xmm1, %xmm0, %xmm0\n"
            ""))
        "    vunpckhpd %xmm0, %xmm0, %xmm1\n    vaddsd %xmm1, %xmm0, %xmm0\n")]
    [(AstTyI64)
      (string-append
        (string-append
          (str-cat
            "    vextracti64x4 $1, "
            zmm
            ", %ymm0\n    "
            mnemonic
            " %ymm0, "
            ymm
            ", %ymm0\n")
          (str-cat
            "    vextracti128 $1, %ymm0, %xmm1\n    "
            mnemonic
            " %xmm1, %xmm0, %xmm0\n"
            ""))
        (str-cat
          "    vpsrldq $8, %xmm0, %xmm1\n    "
          mnemonic
          " %xmm1, %xmm0, %xmm0\n"
          ""))]
    [(AstTyI32)
      (string-append
        (string-append
          (string-append
            (str-cat
              "    vextracti64x4 $1, "
              zmm
              ", %ymm0\n    "
              mnemonic
              " %ymm0, "
              ymm
              ", %ymm0\n")
            (str-cat
              "    vextracti128 $1, %ymm0, %xmm1\n    "
              mnemonic
              " %xmm1, %xmm0, %xmm0\n"
              ""))
          (str-cat
            "    vpsrldq $8, %xmm0, %xmm1\n    "
            mnemonic
            " %xmm1, %xmm0, %xmm0\n"
            ""))
        (str-cat
          "    vpsrldq $4, %xmm0, %xmm1\n    "
          mnemonic
          " %xmm1, %xmm0, %xmm0\n"
          ""))]
    [_ ""]))

(define (compiler-backend-emit-avx512-vector-reduce
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [op : CompilerIrVectorReduceOp]
  [src : CompilerIrValue]
  [lanes : i64]
  [elem-ty : AstType]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (if (compiler-backend-avx512-shape-ok? elem-ty lanes)
    (let
      [mnemonic : String
        (compiler-backend-avx512-vector-reduce-op-mnemonic op elem-ty)]
      (if (= (string-length mnemonic) 0)
        (ErrCompilerBackend
          (compiler-diagnostic-with-message
            instr-diag
            "backend: unsupported AVX-512 vector reduction"))
        (match src
          [(IrValueVar src-var)
            (match (compiler-backend-vector-var-reg
              assignments
              src-var
              "reduce source"
              "zmm")
              [(OkBackendReg zmm)
                (match (compiler-backend-vector-var-reg
                  assignments
                  src-var
                  "reduce source"
                  "ymm")
                  [(OkBackendReg ymm)
                    (OkCompilerBackend
                      (string-append
                        (compiler-backend-avx512-vector-reduce-horizontal-asm
                          mnemonic
                          zmm
                          ymm
                          elem-ty)
                        (string-append
                          (compiler-backend-avx2-vector-reduce-move-scalar
                            elem-ty)
                          (compiler-backend-emit-store-typed-var-with-plan
                            assignments
                            dst
                            (compiler-backend-vector-reduce-result-reg elem-ty)
                            elem-ty))))]
                  [(ErrBackendReg message)
                    (ErrCompilerBackend
                      (compiler-diagnostic-with-message instr-diag message))])]
              [(ErrBackendReg message)
                (ErrCompilerBackend
                  (compiler-diagnostic-with-message instr-diag message))])]
          [_
            (ErrCompilerBackend
              (compiler-diagnostic-with-message
                instr-diag
                "backend: unsupported AVX-512 vector reduce source"))])))
    (compiler-backend-avx512-shape-diagnostic instr-diag elem-ty lanes)))

(define (compiler-backend-emit-store-typed-var-with-plan
  [assignments : CompilerRegAssignmentList]
  [var-id : i64]
  [reg : String]
  [ty : AstType]) : String
  (if (compiler-backend-float-type? ty)
    (compiler-backend-emit-store-float-var-with-plan assignments var-id reg ty)
    (compiler-backend-emit-store-var-with-plan assignments var-id reg)))

;; #2386: backend emission for multi-word register-resident aggregate groups.
;; IrInstrPack/IrInstrWord are only produced once the size-16 register-resident
;; gate is enabled (the enable step adds the register-allocator group location and
;; the word-marshalling here). Until then they are never emitted, so reaching this
;; path means a lowering/backend representation mismatch -- surface it loudly
;; rather than emit silently wrong code.
;; #2386: build the two words into the destination group's homes. Non-immediate
;; words are loaded into caller-saved scratch %rax/%rdx first and only then moved
;; into the group's homes; immediate words are stored directly after those loads.
;; That keeps reads from the source homes ahead of any destination overwrite.
(define (compiler-backend-emit-group-word-move
  [src : String]
  [dst : String]
  [sse? : bool]) : String
  (if (string-eq src dst)
    ""
    (str-cat
      "    "
      (if sse?
        "movsd"
        "movq")
      " "
      src
      ", "
      dst
      "\n")))

(define (compiler-backend-emit-load-pack-word
  [assignments : CompilerRegAssignmentList]
  [word : CompilerIrValue]
  [sse? : bool]
  [reg : String]) : ResultCompilerBackend
  (if sse?
    (compiler-backend-emit-load-float-value-with-plan
      assignments
      word
      (AstTyF64)
      reg)
    (compiler-backend-emit-load-value-with-plan assignments word reg)))

(define (compiler-backend-pack-word-dst-register? [dst : String]) : bool
  (and (> (string-length dst) 0) (= (string-ref dst 0) #%')))

(define (compiler-backend-emit-pack-word-immediate-store
  [word : CompilerIrValue]
  [dst : String]
  [sse? : bool]) : CompilerBackendMaybeAsm
  (if sse?
    (CompilerBackendNoAsm)
    (if (compiler-backend-pack-word-dst-register? dst)
      (compiler-backend-emit-load-immediate-to-reg word dst)
      (compiler-backend-emit-store-immediate-to-memory word dst (AstTyI64)))))

(define (compiler-backend-emit-load-pack-word-unless-immediate
  [assignments : CompilerRegAssignmentList]
  [word : CompilerIrValue]
  [sse? : bool]
  [reg : String]
  [immediate-store : CompilerBackendMaybeAsm]) : ResultCompilerBackend
  (match immediate-store
    [(CompilerBackendSomeAsm _) (OkCompilerBackend "")]
    [(CompilerBackendNoAsm)
      (compiler-backend-emit-load-pack-word assignments word sse? reg)]))

(define (compiler-backend-emit-pack-word-store
  [scratch : String]
  [dst : String]
  [sse? : bool]
  [immediate-store : CompilerBackendMaybeAsm]) : String
  (match immediate-store
    [(CompilerBackendSomeAsm asm) asm]
    [(CompilerBackendNoAsm)
      (compiler-backend-emit-group-word-move scratch dst sse?)]))

(define (compiler-backend-emit-pack-words-direct-registers
  [assignments : CompilerRegAssignmentList]
  [w0 : CompilerIrValue]
  [w1 : CompilerIrValue]
  [dst0 : String]
  [dst1 : String]
  [sse0? : bool]
  [sse1? : bool]) : CompilerBackendMaybeAsm
  (let
    [src0 : String (compiler-backend-value-register-home assignments w0)]
    [src1 : String (compiler-backend-value-register-home assignments w1)]
    (if (and
      (compiler-backend-pack-word-dst-register? dst0)
      (compiler-backend-pack-word-dst-register? dst1)
      (not (string-eq src0 ""))
      (not (string-eq src1 ""))
      (not (string-eq src0 dst1))
      (not (string-eq src1 dst0)))
      (CompilerBackendSomeAsm
        (string-append
          (compiler-backend-emit-group-word-move src0 dst0 sse0?)
          (compiler-backend-emit-group-word-move src1 dst1 sse1?)))
      (CompilerBackendNoAsm))))

(define (compiler-backend-emit-pack-words
  [assignments : CompilerRegAssignmentList]
  [w0 : CompilerIrValue]
  [w1 : CompilerIrValue]
  [dst0 : String]
  [dst1 : String]
  [sse0? : bool]
  [sse1? : bool]
  [_instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (match (compiler-backend-emit-pack-words-direct-registers
    assignments
    w0
    w1
    dst0
    dst1
    sse0?
    sse1?)
    [(CompilerBackendSomeAsm asm) (OkCompilerBackend asm)]
    [(CompilerBackendNoAsm)
      (let
        [scratch0 : String
          (if sse0?
            "%xmm0"
            "%rax")]
        [scratch1 : String
          (if sse1?
            "%xmm1"
            "%rdx")]
        [store0 : CompilerBackendMaybeAsm
          (compiler-backend-emit-pack-word-immediate-store w0 dst0 sse0?)]
        [store1 : CompilerBackendMaybeAsm
          (compiler-backend-emit-pack-word-immediate-store w1 dst1 sse1?)]
        (match (compiler-backend-emit-load-pack-word-unless-immediate
          assignments
          w0
          sse0?
          scratch0
          store0)
          [(OkCompilerBackend a0)
            (match (compiler-backend-emit-load-pack-word-unless-immediate
              assignments
              w1
              sse1?
              scratch1
              store1)
              [(OkCompilerBackend a1)
                (OkCompilerBackend
                  (string-append
                    (string-append a0 a1)
                    (string-append
                      (compiler-backend-emit-pack-word-store
                        scratch0
                        dst0
                        sse0?
                        store0)
                      (compiler-backend-emit-pack-word-store
                        scratch1
                        dst1
                        sse1?
                        store1))))]
              [(ErrCompilerBackend m) (ErrCompilerBackend m)])]
          [(ErrCompilerBackend m) (ErrCompilerBackend m)]))]))

;; #2386: stack-slot offsets for a group var's two words when it has no register
;; home (stack-only/opt-level<2). word0 reuses the var's ordinary 8-byte slot;
;; word1 lives in a reserved second var-region (offset -(8*(vars+var+1))) so it
;; never collides with another var's slot. The function frame is doubled when it
;; contains any group var (see compiler-backend-emit-function-entry).
(define (compiler-backend-group-word0-slot [var : i64]) : i64
  (- 0 (* 8 (+ var 1))))

;; #2386: word1 halves of stack-resident group vars live in a second var-region
;; placed BELOW the callee-saved register spill area. Basing the region at the raw
;; `vars` count would alias the callee-save slots (which occupy slots vars+1..) and
;; a group param's word1 store would clobber a saved register, corrupting the
;; caller. `frame-slots` already returns vars plus the callee-save reservation
;; (derived from the same `assignments` plan threaded to every word1-slot caller),
;; so basing word1 there keeps the regions disjoint and consistent across every
;; emission path. In stack-only mode (empty plan) `frame-slots` is just `vars`, so
;; the layout is unchanged.
(define (compiler-backend-group-word1-slot
  [var : i64]
  [vars : i64]
  [assignments : CompilerRegAssignmentList]) : i64
  (- 0 (* 8 (+ (compiler-backend-frame-slots vars assignments) (+ var 1)))))

(define (compiler-backend-emit-pack
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [words : CompilerIrValueList]
  [ty : AstType]
  [vars : i64]
  [program-index : CompilerBackendProgramIndex]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (match words
    [(IrValueCons w0 rest0)
      (match (box-get rest0)
        [(IrValueCons w1 _)
          (let
            [w0-sse : bool
              (compiler-backend-group-word-sse? program-index ty 0)]
            [w1-sse : bool
              (compiler-backend-group-word-sse? program-index ty 1)]
            (match (compiler-reg-assignment-lookup assignments dst)
              [(CompilerRegSomeLocation location)
                (match location
                  [(CompilerRegRegisterPair reg-a reg-b)
                    (compiler-backend-emit-pack-words
                      assignments
                      w0
                      w1
                      reg-a
                      reg-b
                      w0-sse
                      w1-sse
                      instr-diag)]
                  [(CompilerRegSpill offset)
                    ;; spilled group: words at [offset] and [offset-8].
                    (compiler-backend-emit-pack-words
                      assignments
                      w0
                      w1
                      (compiler-backend-frame-offset offset)
                      (compiler-backend-frame-offset (- offset 8))
                      w0-sse
                      w1-sse
                      instr-diag)]
                  [_
                    (ErrCompilerBackend
                      (compiler-diagnostic-with-message
                        instr-diag
                        "backend: IrInstrPack dst is not a register-group location"))])]
              [(CompilerRegNoLocation)
                ;; stack-only: the group var lives in two stack slots.
                (compiler-backend-emit-pack-words
                  assignments
                  w0
                  w1
                  (compiler-backend-frame-offset
                    (compiler-backend-group-word0-slot dst))
                  (compiler-backend-frame-offset
                    (compiler-backend-group-word1-slot dst vars assignments))
                  w0-sse
                  w1-sse
                  instr-diag)]))]
        [(IrValueNil)
          (ErrCompilerBackend
            (compiler-diagnostic-with-message
              instr-diag
              "backend: IrInstrPack requires exactly two words (#2386)"))])]
    [(IrValueNil)
      (ErrCompilerBackend
        (compiler-diagnostic-with-message
          instr-diag
          "backend: IrInstrPack requires exactly two words (#2386)"))]))

;; #2386: extract word `index` of a register-group value into `dst`'s home.
(define (compiler-backend-emit-word
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [src : CompilerIrValue]
  [index : i64]
  [ty : AstType]
  [vars : i64]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (match src
    [(IrValueVar src-var)
      (let
        [is-float : bool (compiler-backend-float-type? ty)]
        [scratch : String
          (if is-float
            "%xmm0"
            "%rax")]
        (match (compiler-backend-group-word-operand
          assignments
          src-var
          index
          vars)
          [(OkCompilerBackend operand)
            (OkCompilerBackend
              (if (compiler-backend-peephole-register-operand? operand)
                (compiler-backend-emit-store-typed-var-with-plan
                  assignments
                  dst
                  operand
                  ty)
                (string-append
                  (compiler-backend-emit-group-word-move
                    operand
                    scratch
                    is-float)
                  (compiler-backend-emit-store-typed-var-with-plan
                    assignments
                    dst
                    scratch
                    ty))))]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-diagnostic-with-message
                instr-diag
                (compiler-diagnostic-message message)))]))]
    [_
      (ErrCompilerBackend
        (compiler-diagnostic-with-message
          instr-diag
          "backend: IrInstrWord src must be a register-group var (#2386)"))]))

;; #2386: the assembly operand (register name or memory slot) holding word `index`
;; of a register-group var, regardless of how the allocator homed it. Used by the
;; call/return/param ABI to move group words to/from the ABI registers.
(define (compiler-backend-group-word-operand
  [assignments : CompilerRegAssignmentList]
  [var : i64]
  [index : i64]
  [vars : i64]) : ResultCompilerBackend
  (if (not (or (= index 0) (= index 1)))
    (ErrCompilerBackend
      (compiler-diagnostic-at-start
        ""
        "backend: register-group word index must be 0 or 1 (#2386)"))
    (match (compiler-reg-assignment-lookup assignments var)
      [(CompilerRegSomeLocation location)
        (match location
          [(CompilerRegRegisterPair reg-a reg-b)
            (OkCompilerBackend
              (if (= index 0)
                reg-a
                reg-b))]
          [(CompilerRegSpill _)
            (ErrCompilerBackend
              (compiler-diagnostic-at-start
                ""
                "backend: register-group var assigned spill slot (#2386)"))]
          [(CompilerRegRegister _)
            (ErrCompilerBackend
              (compiler-diagnostic-at-start
                ""
                "backend: register-group var assigned scalar register home (#2386)"))])]
      [(CompilerRegNoLocation)
        (OkCompilerBackend
          (compiler-backend-frame-offset
            (if (= index 0)
              (compiler-backend-group-word0-slot var)
              (compiler-backend-group-word1-slot var vars assignments))))])))

;; #2386: load a group value's two words into `reg0`/`reg1` (for return -> rax:rdx
;; or an argument register pair). The value must be a group var.
(define (compiler-backend-emit-group-load
  [assignments : CompilerRegAssignmentList]
  [value : CompilerIrValue]
  [reg0 : String]
  [reg1 : String]
  [vars : i64]
  [ty : AstType]
  [program-index : CompilerBackendProgramIndex]) : ResultCompilerBackend
  (match value
    [(IrValueVar v)
      (match (compiler-backend-group-word-operand assignments v 0 vars)
        [(OkCompilerBackend word0)
          (match (compiler-backend-group-word-operand assignments v 1 vars)
            [(OkCompilerBackend word1)
              (OkCompilerBackend
                (string-append
                  (compiler-backend-emit-group-word-move
                    word0
                    reg0
                    (compiler-backend-group-word-sse? program-index ty 0))
                  (compiler-backend-emit-group-word-move
                    word1
                    reg1
                    (compiler-backend-group-word-sse? program-index ty 1))))]
            [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
    [_
      (ErrCompilerBackend
        (compiler-diagnostic-at-start
          ""
          "backend: register-group load requires var operand (#2386)"))]))

;; #2386: store a group's two words FROM `reg0`/`reg1` into the group var's home
;; (for a call result captured in rax:rdx, or an incoming group parameter).
(define (compiler-backend-emit-group-store
  [assignments : CompilerRegAssignmentList]
  [var : i64]
  [reg0 : String]
  [reg1 : String]
  [vars : i64]
  [ty : AstType]
  [program-index : CompilerBackendProgramIndex]) : ResultCompilerBackend
  (match (compiler-backend-group-word-operand assignments var 0 vars)
    [(OkCompilerBackend word0)
      (match (compiler-backend-group-word-operand assignments var 1 vars)
        [(OkCompilerBackend word1)
          (OkCompilerBackend
            (string-append
              (compiler-backend-emit-group-word-move
                reg0
                word0
                (compiler-backend-group-word-sse? program-index ty 0))
              (compiler-backend-emit-group-word-move
                reg1
                word1
                (compiler-backend-group-word-sse? program-index ty 1))))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
    [(ErrCompilerBackend message) (ErrCompilerBackend message)]))

(define (compiler-backend-group-return-reg
  [program-index : CompilerBackendProgramIndex]
  [ty : AstType]
  [word-index : i64]) : String
  (if (compiler-backend-group-word-sse? program-index ty word-index)
    (if (and
      (= word-index 1)
      (compiler-backend-group-word-sse? program-index ty 0))
      "%xmm1"
      "%xmm0")
    (if (and
      (= word-index 1)
      (not (compiler-backend-group-word-sse? program-index ty 0)))
      "%rdx"
      "%rax")))

;; #2386: a register-group argument needs TWO consecutive integer arg registers.
;; If fewer than two remain it is passed entirely on the stack (both eightbytes),
;; matching the System V "aggregate spills whole to memory" rule. Self-calls only
;; need call/param symmetry, which this single predicate guarantees.
(define (compiler-backend-group-arg-in-regs?
  [target : CompilerBackendTarget]
  [int-idx : i64]) : bool
  (<= (+ int-idx 2) (compiler-backend-call-register-count target)))

;; #2386: push a group call-arg's two words to the outgoing stack frame at
;; consecutive slots (word0 -> stack-idx, word1 -> stack-idx+1), via %r11 so no
;; in-flight register arg is clobbered.
(define (compiler-backend-emit-group-stack-arg
  [target : CompilerBackendTarget]
  [assignments : CompilerRegAssignmentList]
  [value : CompilerIrValue]
  [stack-idx : i64]
  [vars : i64]
  [ty : AstType]
  [program-index : CompilerBackendProgramIndex]) : ResultCompilerBackend
  (match value
    [(IrValueVar v)
      (match (compiler-backend-group-word-operand assignments v 0 vars)
        [(OkCompilerBackend word0)
          (match (compiler-backend-group-word-operand assignments v 1 vars)
            [(OkCompilerBackend word1)
              (OkCompilerBackend
                (string-append
                  (compiler-backend-emit-group-word-move
                    word0
                    (if (compiler-backend-group-word-sse? program-index ty 0)
                      "%xmm15"
                      "%r11")
                    (compiler-backend-group-word-sse? program-index ty 0))
                  (string-append
                    (compiler-backend-emit-group-word-move
                      (if (compiler-backend-group-word-sse? program-index ty 0)
                        "%xmm15"
                        "%r11")
                      (str-cat
                        (int->string
                          (compiler-backend-outgoing-stack-arg-offset
                            target
                            stack-idx))
                        "(%rsp)"
                        "")
                      (compiler-backend-group-word-sse? program-index ty 0))
                    (string-append
                      (compiler-backend-emit-group-word-move
                        word1
                        (if (compiler-backend-group-word-sse?
                          program-index
                          ty
                          1)
                          "%xmm15"
                          "%r11")
                        (compiler-backend-group-word-sse? program-index ty 1))
                      (compiler-backend-emit-group-word-move
                        (if (compiler-backend-group-word-sse?
                          program-index
                          ty
                          1)
                          "%xmm15"
                          "%r11")
                        (str-cat
                          (int->string
                            (compiler-backend-outgoing-stack-arg-offset
                              target
                              (+ stack-idx 1)))
                          "(%rsp)"
                          "")
                        (compiler-backend-group-word-sse? program-index ty 1))))))]
            [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
    [_
      (ErrCompilerBackend
        (compiler-diagnostic-at-start
          ""
          "backend: register-group stack argument requires var operand (#2386)"))]))

;; #2386: read a stack-passed group parameter's two words from the caller's frame
;; (word0 at stack-idx, word1 at stack-idx+1) into the group var's home.
(define (compiler-backend-emit-group-stack-param
  [target : CompilerBackendTarget]
  [assignments : CompilerRegAssignmentList]
  [var : i64]
  [stack-idx : i64]
  [vars : i64]
  [ty : AstType]
  [program-index : CompilerBackendProgramIndex]) : ResultCompilerBackend
  (match (compiler-backend-emit-group-store
    assignments
    var
    (compiler-backend-group-return-reg program-index ty 0)
    (compiler-backend-group-return-reg program-index ty 1)
    vars
    ty
    program-index)
    [(OkCompilerBackend store)
      (OkCompilerBackend
        (string-append
          (compiler-backend-emit-group-word-move
            (str-cat
              (int->string
                (compiler-backend-incoming-stack-arg-offset target stack-idx))
              "(%rbp)"
              "")
            (compiler-backend-group-return-reg program-index ty 0)
            (compiler-backend-group-word-sse? program-index ty 0))
          (string-append
            (compiler-backend-emit-group-word-move
              (str-cat
                (int->string
                  (compiler-backend-incoming-stack-arg-offset
                    target
                    (+ stack-idx 1)))
                "(%rbp)"
                "")
              (compiler-backend-group-return-reg program-index ty 1)
              (compiler-backend-group-word-sse? program-index ty 1))
            store)))]
    [(ErrCompilerBackend message) (ErrCompilerBackend message)]))

(define (compiler-backend-group-word-arg-reg
  [target : CompilerBackendTarget]
  [sse? : bool]
  [int-idx : i64]
  [float-idx : i64]
  [position : i64]) : ResultBackendReg
  (if sse?
    (compiler-backend-target-float-arg-reg
      target
      (if (compiler-backend-target-windows? target)
        position
        float-idx))
    (compiler-backend-target-arg-reg
      target
      (if (compiler-backend-target-windows? target)
        position
        int-idx))))

(define (compiler-backend-emit-group-word-stack-arg
  [target : CompilerBackendTarget]
  [assignments : CompilerRegAssignmentList]
  [value : CompilerIrValue]
  [word-index : i64]
  [stack-idx : i64]
  [vars : i64]
  [ty : AstType]
  [program-index : CompilerBackendProgramIndex]) : ResultCompilerBackend
  (match value
    [(IrValueVar v)
      (let
        [sse? : bool
          (compiler-backend-group-word-sse? program-index ty word-index)]
        [scratch : String
          (if sse?
            "%xmm15"
            "%r11")]
        (match (compiler-backend-group-word-operand
          assignments
          v
          word-index
          vars)
          [(OkCompilerBackend operand)
            (OkCompilerBackend
              (string-append
                (compiler-backend-emit-group-word-move operand scratch sse?)
                (compiler-backend-emit-group-word-move
                  scratch
                  (str-cat
                    (int->string
                      (compiler-backend-outgoing-stack-arg-offset
                        target
                        stack-idx))
                    "(%rsp)"
                    "")
                  sse?)))]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)]))]
    [_
      (ErrCompilerBackend
        (compiler-diagnostic-at-start
          ""
          "backend: register-group call argument requires var operand (#2386)"))]))

(define (compiler-backend-emit-group-word-call-arg
  [target : CompilerBackendTarget]
  [assignments : CompilerRegAssignmentList]
  [value : CompilerIrValue]
  [word-index : i64]
  [int-idx : i64]
  [float-idx : i64]
  [position : i64]
  [stack-idx : i64]
  [vars : i64]
  [ty : AstType]
  [program-index : CompilerBackendProgramIndex]
  [func-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (let
    [sse? : bool (compiler-backend-group-word-sse? program-index ty word-index)]
    (if (compiler-backend-stack-call-arg-for-banks?
      target
      sse?
      int-idx
      float-idx
      position)
      (compiler-backend-emit-group-word-stack-arg
        target
        assignments
        value
        word-index
        stack-idx
        vars
        ty
        program-index)
      (match (compiler-backend-group-word-arg-reg
        target
        sse?
        int-idx
        float-idx
        position)
        [(OkBackendReg reg)
          (match value
            [(IrValueVar v)
              (match (compiler-backend-group-word-operand
                assignments
                v
                word-index
                vars)
                [(OkCompilerBackend operand)
                  (OkCompilerBackend
                    (compiler-backend-emit-group-word-move operand reg sse?))]
                [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
            [_
              (ErrCompilerBackend
                (compiler-diagnostic-with-message
                  func-diag
                  "backend: register-group call argument requires var operand (#2386)"))])]
        [(ErrBackendReg message)
          (ErrCompilerBackend
            (compiler-diagnostic-with-message func-diag message))]))))

(define (compiler-backend-emit-group-word-store
  [assignments : CompilerRegAssignmentList]
  [var : i64]
  [word-index : i64]
  [reg : String]
  [vars : i64]
  [ty : AstType]
  [program-index : CompilerBackendProgramIndex]) : ResultCompilerBackend
  (match (compiler-backend-group-word-operand assignments var word-index vars)
    [(OkCompilerBackend operand)
      (OkCompilerBackend
        (compiler-backend-emit-group-word-move
          reg
          operand
          (compiler-backend-group-word-sse? program-index ty word-index)))]
    [(ErrCompilerBackend message) (ErrCompilerBackend message)]))

(define (compiler-backend-emit-group-word-param
  [target : CompilerBackendTarget]
  [assignments : CompilerRegAssignmentList]
  [var : i64]
  [word-index : i64]
  [int-idx : i64]
  [float-idx : i64]
  [position : i64]
  [stack-idx : i64]
  [vars : i64]
  [ty : AstType]
  [program-index : CompilerBackendProgramIndex]) : ResultCompilerBackend
  (let
    [sse? : bool (compiler-backend-group-word-sse? program-index ty word-index)]
    [scratch : String
      (compiler-backend-group-return-reg program-index ty word-index)]
    (if (compiler-backend-stack-call-arg-for-banks?
      target
      sse?
      int-idx
      float-idx
      position)
      (match (compiler-backend-emit-group-word-store
        assignments
        var
        word-index
        scratch
        vars
        ty
        program-index)
        [(OkCompilerBackend store)
          (OkCompilerBackend
            (string-append
              (compiler-backend-emit-group-word-move
                (str-cat
                  (int->string
                    (compiler-backend-incoming-stack-arg-offset
                      target
                      stack-idx))
                  "(%rbp)"
                  "")
                scratch
                sse?)
              store))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])
      (match (compiler-backend-group-word-arg-reg
        target
        sse?
        int-idx
        float-idx
        position)
        [(OkBackendReg reg)
          (compiler-backend-emit-group-word-store
            assignments
            var
            word-index
            reg
            vars
            ty
            program-index)]
        [(ErrBackendReg _)
          (ErrCompilerBackend
            (compiler-diagnostic-at-start "" "backend: too many params"))]))))

(define (compiler-backend-emit-load-typed-value-with-plan
  [assignments : CompilerRegAssignmentList]
  [value : CompilerIrValue]
  [ty : AstType]
  [program-index : CompilerBackendProgramIndex]) : ResultCompilerBackend
  (if (compiler-backend-float-type? ty)
    (match value
      [(IrValueGlobal name)
        (OkCompilerBackend
          (str-cat
            "    "
            (compiler-backend-float-move ty)
            " "
            (compiler-backend-global-symbol-index program-index name)
            "(%rip), "
            "%xmm0"
            "\n"))]
      [_
        (compiler-backend-emit-load-float-value-with-plan
          assignments
          value
          ty
          "%xmm0")])
    (match value
      [(IrValueVar id)
        (match (compiler-reg-assignment-lookup assignments id)
          [(CompilerRegSomeLocation location)
            (match location
              [(CompilerRegRegister home)
                (OkCompilerBackend
                  (compiler-backend-emit-load-register home ty))]
              ;; #2386: a whole register-group is loaded word-wise by the group
              ;; ABI paths; reaching the generic scalar load means word0's home.
              [(CompilerRegRegisterPair home _)
                (OkCompilerBackend
                  (compiler-backend-emit-load-register home ty))]
              [(CompilerRegSpill offset)
                (OkCompilerBackend
                  (compiler-backend-emit-load-memory
                    (compiler-backend-frame-offset offset)
                    ty))])]
          [(CompilerRegNoLocation)
            (OkCompilerBackend
              (compiler-backend-emit-load-memory (compiler-backend-slot id) ty))])]
      [(IrValueGlobal name)
        (OkCompilerBackend
          (compiler-backend-emit-load-memory
            (str-cat
              (compiler-backend-global-symbol-index program-index name)
              "(%rip)"
              "")
            ty))]
      [(IrValueGlobalAddr name)
        (OkCompilerBackend
          (str-cat
            "    leaq "
            (compiler-backend-function-or-global-addr-symbol program-index name)
            "(%rip), %rax\n"
            ""
            ""))]
      [_ (compiler-backend-emit-load-value-with-plan assignments value "%rax")])))

(define (compiler-backend-emit-load-typed-value
  [value : CompilerIrValue]
  [ty : AstType]) : ResultCompilerBackend
  (compiler-backend-emit-load-typed-value-with-plan
    CompilerRegAssignmentNil
    value
    ty
    (compiler-backend-program-index-build IrFunctionNil IrExternNil)))

(define (compiler-backend-function-or-global-addr-symbol
  [program-index : CompilerBackendProgramIndex]
  [name : String]) : String
  (if (compiler-backend-index-function-defines? program-index name)
    (compiler-backend-function-symbol-index program-index name)
    (compiler-backend-user-symbol name)))

(define (compiler-backend-global-symbol-index
  [program-index : CompilerBackendProgramIndex]
  [name : String]) : String
  (if (compiler-backend-index-extern-references? program-index name)
    (compiler-backend-index-extern-link-symbol program-index name)
    (compiler-backend-user-symbol name)))

(define (compiler-backend-unsigned-rel-ty? [ty : AstType]) : bool
  (match ty
    [(AstTyU64) true]
    [(AstTyU32) true]
    [(AstTyU16) true]
    [(AstTyU8) true]
    [_ false]))

(define (compiler-backend-global-type-lookup
  [types : CompilerBackendGlobalTypeList]
  [name : String]) : CompilerRegMaybeType
  (match types
    [(CompilerBackendGlobalTypeNil) (CompilerRegNoType)]
    [(CompilerBackendGlobalTypeCons key ty rest)
      (if (string-eq key name)
        (CompilerRegSomeType ty)
        (compiler-backend-global-type-lookup (box-get rest) name))]
    [(CompilerBackendGlobalTypeCache ids values)
      (match (string-i64-map-get ids name)
        [(StringI64MapFound index)
          (CompilerRegSomeType (array-ref values index))]
        [(StringI64MapMissing) (CompilerRegNoType)])]))

(define (compiler-backend-global-type-list-boxed-ok?) : bool
  (let
    [types : CompilerBackendGlobalTypeList
      (CompilerBackendGlobalTypeCons
        "left"
        (AstTyI64)
        (box
          (CompilerBackendGlobalTypeCons
            "right"
            (AstTyBool)
            (box CompilerBackendGlobalTypeNil))))]
    (and
      (match (compiler-backend-global-type-lookup types "left")
        [(CompilerRegSomeType (AstTyI64)) true]
        [_ false])
      (match (compiler-backend-global-type-lookup types "right")
        [(CompilerRegSomeType (AstTyBool)) true]
        [_ false])
      (match (compiler-backend-global-type-lookup types "missing")
        [(CompilerRegNoType) true]
        [_ false]))))

(define (compiler-backend-global-type-count [globals : CompilerIrGlobalList]) : i64
  (match globals
    [(IrGlobalNil) 0]
    [(IrGlobalCons _ rest)
      (+ 1 (compiler-backend-global-type-count (box-get rest)))]))

(define (compiler-backend-global-types-fill
  [globals : CompilerIrGlobalList]
  [ids : StringI64Map]
  [values : (Array AstType)]
  [index : i64]) : StringI64Map
  (match globals
    [(IrGlobalNil) ids]
    [(IrGlobalCons global rest)
      (match global
        [(IrGlobal name ty _)
          (begin
            (array-set! values index ty)
            (compiler-backend-global-types-fill
              (box-get rest)
              (string-i64-map-put ids name index)
              values
              (+ index 1)))])]))

(define (compiler-backend-global-types [globals : CompilerIrGlobalList]) : CompilerBackendGlobalTypeList
  (let
    [count : i64 (compiler-backend-global-type-count globals)]
    [values : (Array AstType) (make-array AstType count)]
    (CompilerBackendGlobalTypeCache
      (compiler-backend-global-types-fill
        globals
        (string-i64-map-with-capacity (+ (* count 2) 16))
        values
        0)
      values)))

(define (compiler-backend-value-type
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [value : CompilerIrValue]) : CompilerRegMaybeType
  (match value
    [(IrValueVar id) (compiler-reg-var-type-lookup types id)]
    [(IrValueGlobal name)
      (compiler-backend-global-type-lookup global-types name)]
    [(IrValueGlobalAddr _) (CompilerRegSomeType (AstTyU64))]
    [(IrValueI64 _) (CompilerRegSomeType (AstTyI64))]
    [(IrValueBool _) (CompilerRegSomeType (AstTyBool))]
    [(IrValueChar _) (CompilerRegSomeType (AstTyChar))]
    [(IrValueF64 _) (CompilerRegSomeType (AstTyF64))]
    [(IrValueString _) (CompilerRegSomeType (AstTyString))]
    [(IrValueBytes _) (CompilerRegSomeType (ast-ty-dyn-array (AstTyU8)))]
    [(IrValueFunction _) (CompilerRegSomeType (AstTyU64))]
    [_ (CompilerRegNoType)]))

(define (compiler-backend-binop-compare-result? [op : CompilerIrBinOp]) : bool
  (match op
    [(IrBinEq) true]
    [(IrBinNe) true]
    [(IrBinLt) true]
    [(IrBinLe) true]
    [(IrBinGt) true]
    [(IrBinGe) true]
    [_ false]))

(define (compiler-backend-binop-bit-or-shift? [op : CompilerIrBinOp]) : bool
  (match op
    [(IrBinBitAnd) true]
    [(IrBinBitOr) true]
    [(IrBinBitXor) true]
    [(IrBinShl) true]
    [(IrBinShr) true]
    [_ false]))

(define (compiler-backend-binop-operand-ty
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [op : CompilerIrBinOp]
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [result-ty : AstType]) : AstType
  (if (compiler-backend-binop-compare-result? op)
    (match (compiler-backend-value-type types global-types lhs)
      [(CompilerRegSomeType ty) ty]
      [(CompilerRegNoType)
        (match (compiler-backend-value-type types global-types rhs)
          [(CompilerRegSomeType ty) ty]
          [(CompilerRegNoType) result-ty])])
    (if (compiler-backend-binop-bit-or-shift? op)
      (match (compiler-backend-value-type types global-types lhs)
        [(CompilerRegSomeType ty) ty]
        [(CompilerRegNoType) result-ty])
      result-ty)))

(define (compiler-backend-value-f64?
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [value : CompilerIrValue]) : bool
  (match value
    [(IrValueF64 _) true]
    [(IrValueVar id)
      (match (compiler-reg-var-type-lookup types id)
        [(CompilerRegSomeType ty) (compiler-backend-f64-type? ty)]
        [(CompilerRegNoType) false])]
    [(IrValueGlobal name)
      (match (compiler-backend-global-type-lookup global-types name)
        [(CompilerRegSomeType ty) (compiler-backend-f64-type? ty)]
        [(CompilerRegNoType) false])]
    [_ false]))

(define (compiler-backend-value-float?
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [value : CompilerIrValue]) : bool
  (match value
    [(IrValueF64 _) true]
    [(IrValueVar id)
      (match (compiler-reg-var-type-lookup types id)
        [(CompilerRegSomeType ty) (compiler-backend-float-type? ty)]
        [(CompilerRegNoType) false])]
    [(IrValueGlobal name)
      (match (compiler-backend-global-type-lookup global-types name)
        [(CompilerRegSomeType ty) (compiler-backend-float-type? ty)]
        [(CompilerRegNoType) false])]
    [_ false]))

;; True when a binary op operates on floating-point values (f32 OR f64), so it
;; must use the scalar-SSE path (xmm registers, addss/addsd, ucomiss/ucomisd)
;; instead of the integer path. The operand precision is recovered separately
;; via compiler-backend-binop-operand-ty.
(define (compiler-backend-binop-f64?
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [ty : AstType]) : bool
  (if (compiler-backend-float-type? ty)
    true
    (if (compiler-backend-value-float? types global-types lhs)
      true
      (compiler-backend-value-float? types global-types rhs))))

(define (compiler-backend-int-instruction-suffix [ty : AstType]) : String
  (let
    [size : i64 (compiler-backend-type-size ty)]
    (cond [(= size 1) "b"] [(= size 2) "w"] [(= size 4) "l"] [else "q"])))

(define (compiler-backend-sized-reg [reg : String] [ty : AstType]) : String
  (compiler-backend-reg-part reg (compiler-backend-type-size ty)))

(define (compiler-backend-binop-reg-asm
  [mnemonic : String]
  [ty : AstType]
  [rhs : String]
  [lhs : String]) : String
  (string-append
    (str-cat
      "    "
      mnemonic
      (compiler-backend-int-instruction-suffix ty)
      " "
      rhs)
    (str-cat ", " lhs "\n")))

(define (compiler-backend-binop-cmp-set-asm
  [ty : AstType]
  [rhs : String]
  [lhs : String]
  [setcc : String]) : String
  (string-append
    (str-cat
      "    cmp"
      (compiler-backend-int-instruction-suffix ty)
      " "
      rhs
      ", ")
    (string-append
      lhs
      (str-cat "\n    " setcc " %al\n    movzbl %al, %eax\n" ""))))

(define (compiler-backend-binop-cmp-reg-asm
  [ty : AstType]
  [rhs : String]
  [lhs : String]) : String
  (string-append
    (str-cat
      "    cmp"
      (compiler-backend-int-instruction-suffix ty)
      " "
      rhs
      ", ")
    (string-append lhs "\n")))

(define (compiler-backend-emit-load-i64-absolute [n : i64] [reg : String]) : String
  (str-cat "    movabsq $" (int->string n) ", " reg "\n"))

(define (compiler-backend-signed-min-value [ty : AstType]) : i64
  (let
    [size : i64 (compiler-backend-type-size ty)]
    (cond
      [(= size 1) (- 0 128)]
      [(= size 2) (- 0 32768)]
      [(= size 4) (- 0 2147483648)]
      [else (- (- 0 9223372036854775807) 1)])))

(define (compiler-backend-div-zero-guard-asm [ty : AstType]) : String
  (let
    [rhs : String (compiler-backend-sized-reg "%r8" ty)]
    (string-append
      (compiler-backend-binop-reg-asm "test" ty rhs rhs)
      "    jne 1f\n    call tl_div_abort\n1:\n")))

(define (compiler-backend-div-overflow-guard-asm [ty : AstType]) : String
  (if (compiler-backend-type-signed? ty)
    (let
      [lhs : String (compiler-backend-sized-reg "%rax" ty)]
      [rhs : String (compiler-backend-sized-reg "%r8" ty)]
      [min-reg : String (compiler-backend-sized-reg "%r10" ty)]
      [neg-one-reg : String (compiler-backend-sized-reg "%r11" ty)]
      (string-append
        (compiler-backend-emit-load-i64-absolute
          (compiler-backend-signed-min-value ty)
          "%r10")
        (string-append
          (compiler-backend-binop-cmp-reg-asm ty min-reg lhs)
          (string-append
            "    jne 1f\n"
            (string-append
              (compiler-backend-emit-load-i64-absolute (- 0 1) "%r11")
              (string-append
                (compiler-backend-binop-cmp-reg-asm ty neg-one-reg rhs)
                "    jne 1f\n    call tl_div_abort\n1:\n"))))))
    ""))

(define (compiler-backend-divmod-guard-asm [ty : AstType]) : String
  (string-append
    (compiler-backend-div-zero-guard-asm ty)
    (compiler-backend-div-overflow-guard-asm ty)))

(define (compiler-backend-binop-divmod-core-asm
  [ty : AstType]
  [want-remainder : bool]) : String
  (let
    [size : i64 (compiler-backend-type-size ty)]
    [signed : bool (compiler-backend-type-signed? ty)]
    (cond
      [(= size 1)
        (string-append
          (if signed
            "    cbw\n    idivb %r8b\n"
            "    andw $0x00ff, %ax\n    divb %r8b\n")
          (if want-remainder
            "    movb %ah, %al\n"
            ""))]
      [(= size 2)
        (string-append
          (if signed
            "    cwd\n    idivw %r8w\n"
            "    xorw %dx, %dx\n    divw %r8w\n")
          (if want-remainder
            "    movw %dx, %ax\n"
            ""))]
      [(= size 4)
        (string-append
          (if signed
            "    cdq\n    idivl %r8d\n"
            "    xorl %edx, %edx\n    divl %r8d\n")
          (if want-remainder
            "    movl %edx, %eax\n"
            ""))]
      [else
        (string-append
          (if signed
            "    cqto\n    idivq %r8\n"
            "    xorq %rdx, %rdx\n    divq %r8\n")
          (if want-remainder
            "    movq %rdx, %rax\n"
            ""))])))

(define (compiler-backend-binop-divmod-asm
  [ty : AstType]
  [want-remainder : bool]) : String
  (string-append
    (compiler-backend-divmod-guard-asm ty)
    (compiler-backend-binop-divmod-core-asm ty want-remainder)))

(define (compiler-backend-emit-load-u64-absolute [n : u64] [reg : String]) : String
  (compiler-backend-emit-load-i64-absolute (cast n : i64) reg))

(define (compiler-backend-u64-max) : u64
  (cast (- 0 1) : u64))

;; Test bit 63 directly instead of `(>= n 2^63)`. The unsigned compare against a
;; constant whose own bit 63 is set is miscompiled by the opt2 pipeline when this
;; helper is inlined into the magic-division codegen below: the opt2-built
;; compiler then treated `0x6666666666666667` (signed-/10 magic, bit 63 clear) as
;; high-bit-set and emitted a spurious "add dividend back" correction, corrupting
;; every constant `/`,`%` in the release self-build (garbled int formatting,
;; #2921). A bit-test (`!= 0`) is sign-agnostic and lowers identically at every
;; opt level, so it dodges the bad rewrite while staying provably equivalent.
(define (compiler-backend-u64-high-bit? [n : u64]) : bool
  (not (= (bit-and n (shl (cast 1 : u64) 63)) (cast 0 : u64))))

(define (compiler-backend-u64-power-of-two? [n : u64]) : bool
  (and (> n (cast 0 : u64)) (= (bit-and n (- n (cast 1 : u64))) (cast 0 : u64))))

(define (compiler-backend-u64-log2 [n : u64]) : i64
  (let
    [out : i64 0]
    [cursor : u64 n]
    (begin
      (while (> cursor (cast 1 : u64))
        (begin
          (set! cursor (shr cursor 1))
          (set! out (+ out 1))))
      out)))

(define (compiler-backend-i64-min-value) : i64
  (- (- 0 9223372036854775807) 1))

(define (compiler-backend-normalized-signed-immediate [n : i64] [ty : AstType]) : i64
  (match ty
    [(AstTyI8) (cast (cast n : i8) : i64)]
    [(AstTyI16) (cast (cast n : i16) : i64)]
    [(AstTyI32) (cast (cast n : i32) : i64)]
    [_ n]))

(define (compiler-backend-normalized-unsigned-immediate
  [n : i64]
  [ty : AstType]) : u64
  (match ty
    [(AstTyU8) (cast (cast n : u8) : u64)]
    [(AstTyU16) (cast (cast n : u16) : u64)]
    [(AstTyU32) (cast (cast n : u32) : u64)]
    [_ (cast n : u64)]))

(define (compiler-backend-divmod-safe-literal-i64? [n : i64] [ty : AstType]) : bool
  (if (compiler-backend-type-signed? ty)
    (let
      [d : i64 (compiler-backend-normalized-signed-immediate n ty)]
      (and (not (= d 0)) (not (= d (- 0 1)))))
    (not
      (= (compiler-backend-normalized-unsigned-immediate n ty) (cast 0 : u64)))))

(define (compiler-backend-divmod-safe-literal?
  [value : CompilerIrValue]
  [ty : AstType]) : bool
  (match (compiler-backend-value-as-i64 value)
    [(CompilerBackendSomeI64 n)
      (compiler-backend-divmod-safe-literal-i64? n ty)]
    [(CompilerBackendNoI64) false]))

(define (compiler-backend-u64-div-pow2 [bits : i64] [divisor : u64]) : CompilerBackendU64DivPow2
  (let
    [i : i64 bits]
    [quot : u64 (cast 0 : u64)]
    [rem : u64 (cast 0 : u64)]
    [overflow : bool false]
    (begin
      (while (>= i 0)
        (begin
          (set! rem (* rem (cast 2 : u64)))
          (if (= i bits)
            (set! rem (+ rem (cast 1 : u64)))
            unit)
          (if (>= rem divisor)
            (begin
              (set! rem (- rem divisor))
              (if (>= i 64)
                (set! overflow true)
                (set! quot (bit-or quot (shl (cast 1 : u64) i)))))
            unit)
          (set! i (- i 1))))
      (CompilerBackendU64DivPow2 quot rem overflow))))

(define (compiler-backend-unsigned-divisor-round-up-magic [divisor : u64]) : CompilerBackendUnsignedDivMagic
  (let
    [shift : i64 0]
    [done : bool false]
    [out : CompilerBackendUnsignedDivMagic (CompilerBackendNoUnsignedDivMagic)]
    (begin
      (while (and (not done) (< shift 64))
        (let
          [pow : CompilerBackendU64DivPow2
            (compiler-backend-u64-div-pow2 (+ 64 shift) divisor)]
          [quot : u64 (struct-get pow quot)]
          [rem : u64 (struct-get pow rem)]
          [overflow : bool (struct-get pow overflow)]
          [limit : u64 (shl (cast 1 : u64) shift)]
          [error : u64
            (if (= rem (cast 0 : u64))
              (cast 0 : u64)
              (- divisor rem))]
          [needs-inc : bool (not (= rem (cast 0 : u64)))]
          [inc-overflow : bool
            (and needs-inc (= quot (compiler-backend-u64-max)))]
          (begin
            (if (and (not overflow) (not inc-overflow) (< error limit))
              (begin
                (set!
                  out
                  (CompilerBackendUnsignedDivMagicRoundUp
                    (if needs-inc
                      (+ quot (cast 1 : u64))
                      quot)
                    shift))
                (set! done true))
              unit)
            (set! shift (+ shift 1)))))
      out)))

(define (compiler-backend-unsigned-divisor-round-down-magic [divisor : u64]) : CompilerBackendUnsignedDivMagic
  (let
    [shift : i64 0]
    [done : bool false]
    [out : CompilerBackendUnsignedDivMagic (CompilerBackendNoUnsignedDivMagic)]
    (begin
      (while (and (not done) (< shift 64))
        (let
          [pow : CompilerBackendU64DivPow2
            (compiler-backend-u64-div-pow2 (+ 64 shift) divisor)]
          [quot : u64 (struct-get pow quot)]
          [rem : u64 (struct-get pow rem)]
          [overflow : bool (struct-get pow overflow)]
          [limit : u64 (shl (cast 1 : u64) shift)]
          (begin
            (if (and (not overflow) (<= rem limit))
              (begin
                (set! out (CompilerBackendUnsignedDivMagicRoundDown quot shift))
                (set! done true))
              unit)
            (set! shift (+ shift 1)))))
      out)))

(define (compiler-backend-unsigned-divisor-magic [divisor : u64]) : CompilerBackendUnsignedDivMagic
  (match (compiler-backend-unsigned-divisor-round-up-magic divisor)
    [(CompilerBackendNoUnsignedDivMagic)
      (compiler-backend-unsigned-divisor-round-down-magic divisor)]
    [(CompilerBackendUnsignedDivMagicRoundUp magic shift)
      (CompilerBackendUnsignedDivMagicRoundUp magic shift)]
    [(CompilerBackendUnsignedDivMagicRoundDown magic shift)
      (CompilerBackendUnsignedDivMagicRoundDown magic shift)]))

(define (compiler-backend-signed-divisor-magic [divisor : i64]) : CompilerBackendSignedDivMagic
  (let
    [ad : u64 (cast divisor : u64)]
    [two63 : u64 (shl (cast 1 : u64) 63)]
    [anc : u64 (- (- two63 (cast 1 : u64)) (% two63 ad))]
    [p : i64 63]
    [q1 : u64 (/ two63 anc)]
    [r1 : u64 (- two63 (* q1 anc))]
    [q2 : u64 (/ two63 ad)]
    [r2 : u64 (- two63 (* q2 ad))]
    [done : bool false]
    (begin
      (while (not done)
        (begin
          (set! p (+ p 1))
          (set! q1 (* q1 (cast 2 : u64)))
          (set! r1 (* r1 (cast 2 : u64)))
          (if (>= r1 anc)
            (begin
              (set! q1 (+ q1 (cast 1 : u64)))
              (set! r1 (- r1 anc)))
            unit)
          (set! q2 (* q2 (cast 2 : u64)))
          (set! r2 (* r2 (cast 2 : u64)))
          (if (>= r2 ad)
            (begin
              (set! q2 (+ q2 (cast 1 : u64)))
              (set! r2 (- r2 ad)))
            unit)
          (let
            [delta : u64 (- ad r2)]
            (if (or (< q1 delta) (and (= q1 delta) (= r1 (cast 0 : u64))))
              unit
              (set! done true)))))
      (CompilerBackendSignedDivMagic (+ q2 (cast 1 : u64)) (- p 64)))))

(define (compiler-backend-divmod-shift-rax [mnemonic : String] [shift : i64]) : String
  (if (= shift 0)
    ""
    (str-cat "    " mnemonic "q $" (int->string shift) ", %rax\n")))

(define (compiler-backend-divmod-shift-reg
  [mnemonic : String]
  [shift : i64]
  [reg : String]) : String
  (if (= shift 0)
    ""
    (str-cat "    " mnemonic "q $" (int->string shift) ", " reg "\n")))

(define (compiler-backend-divmod-remainder-from-quotient-reg
  [divisor : u64]
  [quotient-reg : String]) : String
  (string-append
    (compiler-backend-emit-load-u64-absolute divisor "%r8")
    (str-cat
      "    imulq "
      quotient-reg
      ", %r8\n"
      "    movq %r10, %rax\n    subq %r8, %rax\n"
      "")))

(define (compiler-backend-divmod-remainder-from-quotient [divisor : u64]) : String
  (compiler-backend-divmod-remainder-from-quotient-reg divisor "%rax"))

(define (compiler-backend-unsigned-power-divmod-asm
  [divisor : u64]
  [want-remainder : bool]) : String
  (let
    [shift : i64 (compiler-backend-u64-log2 divisor)]
    [mask : u64 (- divisor (cast 1 : u64))]
    (if want-remainder
      (if (= mask (cast 0 : u64))
        "    xorq %rax, %rax\n"
        (string-append
          (compiler-backend-emit-load-u64-absolute mask "%r8")
          "    andq %r8, %rax\n"))
      (compiler-backend-divmod-shift-rax "shr" shift))))

(define (compiler-backend-unsigned-high-bit-divmod-asm
  [divisor : u64]
  [want-remainder : bool]) : String
  (if want-remainder
    (string-append
      "    movq %rax, %r10\n"
      (string-append
        (compiler-backend-emit-load-u64-absolute divisor "%r8")
        "    cmpq %r8, %rax\n    jb 1f\n    subq %r8, %r10\n1:\n    movq %r10, %rax\n"))
    (string-append
      (compiler-backend-emit-load-u64-absolute divisor "%r8")
      "    cmpq %r8, %rax\n    setae %al\n    movzbq %al, %rax\n")))

(define (compiler-backend-unsigned-magic-divmod-asm
  [divisor : u64]
  [want-remainder : bool]) : CompilerBackendMaybeAsm
  (match (compiler-backend-unsigned-divisor-magic divisor)
    [(CompilerBackendUnsignedDivMagicRoundUp magic shift)
      (let
        [quotient-asm : String
          (if want-remainder
            (string-append
              "    movq %rax, %r10\n"
              (string-append
                (compiler-backend-emit-load-u64-absolute magic "%r8")
                (string-append
                  "    mulq %r8\n"
                  (compiler-backend-divmod-shift-reg "shr" shift "%rdx"))))
            (string-append
              (compiler-backend-emit-load-u64-absolute magic "%r8")
              (string-append
                "    mulq %r8\n    movq %rdx, %rax\n"
                (compiler-backend-divmod-shift-rax "shr" shift))))]
        (CompilerBackendSomeAsm
          (if want-remainder
            (string-append
              quotient-asm
              (compiler-backend-divmod-remainder-from-quotient-reg
                divisor
                "%rdx"))
            quotient-asm)))]
    [(CompilerBackendUnsignedDivMagicRoundDown magic shift)
      (let
        [quotient-asm : String
          (if want-remainder
            (string-append
              "    movq %rax, %r10\n"
              (string-append
                (compiler-backend-emit-load-u64-absolute magic "%r8")
                (string-append
                  "    mulq %r8\n    addq %r8, %rax\n    adcq $0, %rdx\n"
                  (compiler-backend-divmod-shift-reg "shr" shift "%rdx"))))
            (string-append
              (compiler-backend-emit-load-u64-absolute magic "%r8")
              (string-append
                "    mulq %r8\n    addq %r8, %rax\n    adcq $0, %rdx\n    movq %rdx, %rax\n"
                (compiler-backend-divmod-shift-rax "shr" shift))))]
        (CompilerBackendSomeAsm
          (if want-remainder
            (string-append
              quotient-asm
              (compiler-backend-divmod-remainder-from-quotient-reg
                divisor
                "%rdx"))
            quotient-asm)))]
    [(CompilerBackendNoUnsignedDivMagic) (CompilerBackendNoAsm)]))

(define (compiler-backend-signed-power-divmod-asm
  [divisor : u64]
  [negative-divisor : bool]
  [want-remainder : bool]) : String
  (let
    [shift : i64 (compiler-backend-u64-log2 divisor)]
    [mask : u64 (- divisor (cast 1 : u64))]
    [quotient-asm : String
      (string-append
        "    movq %rax, %r10\n    movq %rax, %r11\n    sarq $63, %r11\n"
        (string-append
          (compiler-backend-emit-load-u64-absolute mask "%r8")
          (string-append
            "    andq %r8, %r11\n    addq %r11, %rax\n"
            (compiler-backend-divmod-shift-rax "sar" shift))))]
    (if want-remainder
      (string-append
        quotient-asm
        (compiler-backend-divmod-remainder-from-quotient divisor))
      (if negative-divisor
        (string-append quotient-asm "    negq %rax\n")
        quotient-asm))))

(define (compiler-backend-signed-magic-divmod-asm
  [divisor : i64]
  [negative-divisor : bool]
  [want-remainder : bool]) : String
  (let
    [plan : CompilerBackendSignedDivMagic
      (compiler-backend-signed-divisor-magic divisor)]
    [magic : u64 (struct-get plan magic)]
    [shift : i64 (struct-get plan shift)]
    [quotient-asm : String
      (if want-remainder
        (string-append
          "    movq %rax, %r10\n"
          (string-append
            (compiler-backend-emit-load-u64-absolute magic "%r8")
            (string-append
              "    imulq %r8\n"
              (string-append
                (if (compiler-backend-u64-high-bit? magic)
                  "    addq %r10, %rdx\n"
                  "")
                (string-append
                  (compiler-backend-divmod-shift-reg "sar" shift "%rdx")
                  "    movq %r10, %r11\n    sarq $63, %r11\n    subq %r11, %rdx\n")))))
        (string-append
          "    movq %rax, %r10\n"
          (string-append
            (compiler-backend-emit-load-u64-absolute magic "%r8")
            (string-append
              "    imulq %r8\n    movq %rdx, %rax\n"
              (string-append
                (if (compiler-backend-u64-high-bit? magic)
                  "    addq %r10, %rax\n"
                  "")
                (string-append
                  (compiler-backend-divmod-shift-rax "sar" shift)
                  "    movq %r10, %r11\n    sarq $63, %r11\n    subq %r11, %rax\n"))))))]
    (if want-remainder
      (string-append
        quotient-asm
        (compiler-backend-divmod-remainder-from-quotient-reg
          (cast divisor : u64)
          "%rdx"))
      (if negative-divisor
        (string-append quotient-asm "    negq %rax\n")
        quotient-asm))))

(define (compiler-backend-signed-constant-divmod-strength-asm
  [divisor : i64]
  [want-remainder : bool]) : CompilerBackendMaybeAsm
  (if (= divisor 1)
    (CompilerBackendSomeAsm
      (if want-remainder
        "    xorq %rax, %rax\n"
        ""))
    (if (= divisor (compiler-backend-i64-min-value))
      (CompilerBackendNoAsm)
      (let
        [negative-divisor : bool (< divisor 0)]
        [abs-divisor : i64
          (if (< divisor 0)
            (- 0 divisor)
            divisor)]
        [abs-u64 : u64 (cast abs-divisor : u64)]
        (CompilerBackendSomeAsm
          (if (compiler-backend-u64-power-of-two? abs-u64)
            (compiler-backend-signed-power-divmod-asm
              abs-u64
              negative-divisor
              want-remainder)
            (compiler-backend-signed-magic-divmod-asm
              abs-divisor
              negative-divisor
              want-remainder)))))))

(define (compiler-backend-unsigned-constant-divmod-strength-asm
  [divisor : u64]
  [want-remainder : bool]) : CompilerBackendMaybeAsm
  (if (compiler-backend-u64-power-of-two? divisor)
    (CompilerBackendSomeAsm
      (compiler-backend-unsigned-power-divmod-asm divisor want-remainder))
    (compiler-backend-unsigned-magic-divmod-asm divisor want-remainder)))

(define (compiler-backend-constant-divmod-unguarded-asm
  [n : i64]
  [ty : AstType]
  [want-remainder : bool]) : String
  (string-append
    (compiler-backend-emit-load-i64-absolute
      (if (compiler-backend-type-signed? ty)
        (compiler-backend-normalized-signed-immediate n ty)
        (cast (compiler-backend-normalized-unsigned-immediate n ty) : i64))
      "%r8")
    (compiler-backend-binop-divmod-core-asm ty want-remainder)))

(define (compiler-backend-constant-divmod-asm
  [n : i64]
  [ty : AstType]
  [want-remainder : bool]) : CompilerBackendMaybeAsm
  (cond
    [(not (compiler-backend-divmod-safe-literal-i64? n ty))
      (CompilerBackendNoAsm)]
    [(not (= (compiler-backend-type-size ty) 8))
      (CompilerBackendSomeAsm
        (compiler-backend-constant-divmod-unguarded-asm n ty want-remainder))]
    [(compiler-backend-type-signed? ty)
      (let
        [divisor : i64 (compiler-backend-normalized-signed-immediate n ty)]
        (match (compiler-backend-signed-constant-divmod-strength-asm
          divisor
          want-remainder)
          [(CompilerBackendSomeAsm asm) (CompilerBackendSomeAsm asm)]
          [(CompilerBackendNoAsm)
            (CompilerBackendSomeAsm
              (compiler-backend-constant-divmod-unguarded-asm
                n
                ty
                want-remainder))]))]
    [else
      (let
        [divisor : u64 (compiler-backend-normalized-unsigned-immediate n ty)]
        ;; The 64-bit magic search below assumes divisor < 2^63 so rem*2 cannot
        ;; overflow while generating constants. Wider unsigned literals reduce to
        ;; a compare because the quotient can only be 0 or 1.
        (if (compiler-backend-u64-high-bit? divisor)
          (CompilerBackendSomeAsm
            (compiler-backend-unsigned-high-bit-divmod-asm
              divisor
              want-remainder))
          (match (compiler-backend-unsigned-constant-divmod-strength-asm
            divisor
            want-remainder)
            [(CompilerBackendSomeAsm asm) (CompilerBackendSomeAsm asm)]
            [(CompilerBackendNoAsm)
              (CompilerBackendSomeAsm
                (compiler-backend-constant-divmod-unguarded-asm
                  n
                  ty
                  want-remainder))])))]))

(define (compiler-backend-constant-safe-divmod-asm
  [n : i64]
  [ty : AstType]
  [want-remainder : bool]) : CompilerBackendMaybeAsm
  (match (compiler-backend-constant-divmod-asm n ty want-remainder)
    [(CompilerBackendSomeAsm asm) (CompilerBackendSomeAsm asm)]
    [(CompilerBackendNoAsm)
      (if (and
        (compiler-backend-type-signed? ty)
        (= (compiler-backend-normalized-signed-immediate n ty) (- 0 1)))
        (CompilerBackendSomeAsm
          (compiler-backend-constant-divmod-unguarded-asm n ty want-remainder))
        (CompilerBackendNoAsm))]))

(define (compiler-backend-binop-literal-divmod-asm
  [op : CompilerIrBinOp]
  [rhs : CompilerIrValue]
  [ty : AstType]) : CompilerBackendMaybeAsm
  (match op
    [(IrBinDiv)
      (match (compiler-backend-value-as-i64 rhs)
        [(CompilerBackendSomeI64 n)
          (compiler-backend-constant-divmod-asm n ty false)]
        [(CompilerBackendNoI64) (CompilerBackendNoAsm)])]
    [(IrBinMod)
      (match (compiler-backend-value-as-i64 rhs)
        [(CompilerBackendSomeI64 n)
          (compiler-backend-constant-divmod-asm n ty true)]
        [(CompilerBackendNoI64) (CompilerBackendNoAsm)])]
    [(IrBinSafeDiv)
      (match (compiler-backend-value-as-i64 rhs)
        [(CompilerBackendSomeI64 n)
          (compiler-backend-constant-safe-divmod-asm n ty false)]
        [(CompilerBackendNoI64) (CompilerBackendNoAsm)])]
    [(IrBinSafeMod)
      (match (compiler-backend-value-as-i64 rhs)
        [(CompilerBackendSomeI64 n)
          (compiler-backend-constant-safe-divmod-asm n ty true)]
        [(CompilerBackendNoI64) (CompilerBackendNoAsm)])]
    [_ (CompilerBackendNoAsm)]))

(define (compiler-backend-shift-count-width [ty : AstType]) : i64
  (* (compiler-backend-type-size ty) 8))

(define (compiler-backend-shift-count-valid? [count : i64] [ty : AstType]) : bool
  (and (>= count 0) (< count (compiler-backend-shift-count-width ty))))

(define (compiler-backend-shift-guard-asm [ty : AstType]) : String
  (string-append
    "    testq %r8, %r8\n    jge 1f\n    call tl_shift_abort\n1:\n"
    (str-cat
      "    cmpq $"
      (int->string (compiler-backend-shift-count-width ty))
      ", %r8\n    jb 1f\n    call tl_shift_abort\n1:\n"
      ""
      "")))

(define (compiler-backend-binop-shift-asm
  [mnemonic : String]
  [ty : AstType]
  [lhs : String]) : String
  (string-append
    (compiler-backend-shift-guard-asm ty)
    (string-append
      "    movq %r8, %rcx\n"
      (str-cat
        "    "
        mnemonic
        (compiler-backend-int-instruction-suffix ty)
        " %cl, "
        lhs
        "\n"))))

(define (compiler-backend-binop-asm [op : CompilerIrBinOp] [ty : AstType]) : String
  (let
    [lhs : String (compiler-backend-sized-reg "%rax" ty)]
    [rhs : String (compiler-backend-sized-reg "%r8" ty)]
    [_suffix : String (compiler-backend-int-instruction-suffix ty)]
    (match op
      [(IrBinAdd) (compiler-backend-binop-reg-asm "add" ty rhs lhs)]
      [(IrBinSub) (compiler-backend-binop-reg-asm "sub" ty rhs lhs)]
      [(IrBinMul)
        (if (= (compiler-backend-type-size ty) 1)
          "    imulq %r8, %rax\n"
          (compiler-backend-binop-reg-asm "imul" ty rhs lhs))]
      [(IrBinDiv) (compiler-backend-binop-divmod-asm ty false)]
      [(IrBinMod) (compiler-backend-binop-divmod-asm ty true)]
      [(IrBinSafeDiv) (compiler-backend-binop-divmod-core-asm ty false)]
      [(IrBinSafeMod) (compiler-backend-binop-divmod-core-asm ty true)]
      [(IrBinEq) (compiler-backend-binop-cmp-set-asm ty rhs lhs "sete")]
      [(IrBinNe) (compiler-backend-binop-cmp-set-asm ty rhs lhs "setne")]
      [(IrBinLt)
        (compiler-backend-binop-cmp-set-asm
          ty
          rhs
          lhs
          (if (compiler-backend-unsigned-rel-ty? ty)
            "setb"
            "setl"))]
      [(IrBinLe)
        (compiler-backend-binop-cmp-set-asm
          ty
          rhs
          lhs
          (if (compiler-backend-unsigned-rel-ty? ty)
            "setbe"
            "setle"))]
      [(IrBinGt)
        (compiler-backend-binop-cmp-set-asm
          ty
          rhs
          lhs
          (if (compiler-backend-unsigned-rel-ty? ty)
            "seta"
            "setg"))]
      [(IrBinGe)
        (compiler-backend-binop-cmp-set-asm
          ty
          rhs
          lhs
          (if (compiler-backend-unsigned-rel-ty? ty)
            "setae"
            "setge"))]
      [(IrBinAnd) (compiler-backend-binop-reg-asm "and" ty rhs lhs)]
      [(IrBinOr) (compiler-backend-binop-reg-asm "or" ty rhs lhs)]
      [(IrBinBitAnd) (compiler-backend-binop-reg-asm "and" ty rhs lhs)]
      [(IrBinBitOr) (compiler-backend-binop-reg-asm "or" ty rhs lhs)]
      [(IrBinBitXor) (compiler-backend-binop-reg-asm "xor" ty rhs lhs)]
      [(IrBinShl) (compiler-backend-binop-shift-asm "shl" ty lhs)]
      [(IrBinShr)
        (compiler-backend-binop-shift-asm
          (if (compiler-backend-type-signed? ty)
            "sar"
            "shr")
          ty
          lhs)])))

(define (compiler-backend-binop-test-zero-asm [ty : AstType] [setcc : String]) : String
  (let
    [lhs : String (compiler-backend-sized-reg "%rax" ty)]
    (string-append
      (compiler-backend-binop-reg-asm "test" ty lhs lhs)
      (str-cat "    " setcc " %al\n    movzbl %al, %eax\n" ""))))

(define (compiler-backend-binop-immediate-cmp-asm
  [ty : AstType]
  [imm : String]
  [setcc : String]) : String
  (compiler-backend-binop-cmp-set-asm
    ty
    imm
    (compiler-backend-sized-reg "%rax" ty)
    setcc))

(define (compiler-backend-binop-immediate-shift-asm
  [mnemonic : String]
  [ty : AstType]
  [imm : String]) : CompilerBackendMaybeAsm
  (let
    [count : i64 (string->int (substring imm 1 (- (string-length imm) 1)))]
    (if (compiler-backend-shift-count-valid? count ty)
      (CompilerBackendSomeAsm
        (string-append
          (str-cat
            "    "
            mnemonic
            (compiler-backend-int-instruction-suffix ty)
            " "
            imm)
          (str-cat ", " (compiler-backend-sized-reg "%rax" ty) "\n")))
      (CompilerBackendNoAsm))))

(define (compiler-backend-binop-immediate-reg-asm
  [mnemonic : String]
  [ty : AstType]
  [imm : String]) : String
  (compiler-backend-binop-reg-asm
    mnemonic
    ty
    imm
    (compiler-backend-sized-reg "%rax" ty)))

(define (compiler-backend-binop-immediate-asm
  [op : CompilerIrBinOp]
  [imm : String]
  [ty : AstType]) : CompilerBackendMaybeAsm
  (match op
    [(IrBinAdd)
      (CompilerBackendSomeAsm
        (compiler-backend-binop-immediate-reg-asm "add" ty imm))]
    [(IrBinSub)
      (CompilerBackendSomeAsm
        (compiler-backend-binop-immediate-reg-asm "sub" ty imm))]
    [(IrBinMul)
      (CompilerBackendSomeAsm
        (if (= (compiler-backend-type-size ty) 1)
          (str-cat "    imulq " imm ", %rax\n")
          (compiler-backend-binop-immediate-reg-asm "imul" ty imm)))]
    [(IrBinEq)
      (CompilerBackendSomeAsm
        (if (string-eq imm "$0")
          (compiler-backend-binop-test-zero-asm ty "sete")
          (compiler-backend-binop-immediate-cmp-asm ty imm "sete")))]
    [(IrBinNe)
      (CompilerBackendSomeAsm
        (if (string-eq imm "$0")
          (compiler-backend-binop-test-zero-asm ty "setne")
          (compiler-backend-binop-immediate-cmp-asm ty imm "setne")))]
    [(IrBinLt)
      (CompilerBackendSomeAsm
        (compiler-backend-binop-immediate-cmp-asm
          ty
          imm
          (if (compiler-backend-unsigned-rel-ty? ty)
            "setb"
            "setl")))]
    [(IrBinLe)
      (CompilerBackendSomeAsm
        (compiler-backend-binop-immediate-cmp-asm
          ty
          imm
          (if (compiler-backend-unsigned-rel-ty? ty)
            "setbe"
            "setle")))]
    [(IrBinGt)
      (CompilerBackendSomeAsm
        (compiler-backend-binop-immediate-cmp-asm
          ty
          imm
          (if (compiler-backend-unsigned-rel-ty? ty)
            "seta"
            "setg")))]
    [(IrBinGe)
      (CompilerBackendSomeAsm
        (compiler-backend-binop-immediate-cmp-asm
          ty
          imm
          (if (compiler-backend-unsigned-rel-ty? ty)
            "setae"
            "setge")))]
    [(IrBinAnd)
      (CompilerBackendSomeAsm
        (compiler-backend-binop-immediate-reg-asm "and" ty imm))]
    [(IrBinOr)
      (CompilerBackendSomeAsm
        (compiler-backend-binop-immediate-reg-asm "or" ty imm))]
    [(IrBinBitAnd)
      (CompilerBackendSomeAsm
        (compiler-backend-binop-immediate-reg-asm "and" ty imm))]
    [(IrBinBitOr)
      (CompilerBackendSomeAsm
        (compiler-backend-binop-immediate-reg-asm "or" ty imm))]
    [(IrBinBitXor)
      (CompilerBackendSomeAsm
        (compiler-backend-binop-immediate-reg-asm "xor" ty imm))]
    [(IrBinShl) (compiler-backend-binop-immediate-shift-asm "shl" ty imm)]
    [(IrBinShr)
      (compiler-backend-binop-immediate-shift-asm
        (if (compiler-backend-type-signed? ty)
          "sar"
          "shr")
        ty
        imm)]
    [_ (CompilerBackendNoAsm)]))

(define (compiler-backend-unop-asm [op : CompilerIrUnOp]) : String
  (match op
    [(IrUnNeg) "    negq %rax\n"]
    [(IrUnNot) "    xorq $1, %rax\n"]
    [(IrUnBitNot) "    notq %rax\n"]))

(define (compiler-backend-unop-reg-asm [op : CompilerIrUnOp] [reg : String]) : String
  (match op
    [(IrUnNeg) (str-cat "    negq " reg "\n")]
    [(IrUnNot) (str-cat "    xorq $1, " reg "\n")]
    [(IrUnBitNot) (str-cat "    notq " reg "\n")]))

;; Scalar floating-point binary ops. `fty` selects single (`ss`, f32) vs double
;; (`sd`, f64) precision; comparisons use ucomiss/ucomisd accordingly. Operands
;; are in %xmm0 (lhs) and %xmm1 (rhs); arithmetic leaves the result in %xmm0,
;; comparisons leave a 0/1 in %eax.
(define (compiler-backend-float-binop-asm
  [op : CompilerIrBinOp]
  [fty : AstType]) : ResultCompilerBackend
  (let
    [s : String
      (if (compiler-backend-f64-type? fty)
        "sd"
        "ss")]
    [c : String
      (if (compiler-backend-f64-type? fty)
        "ucomisd"
        "ucomiss")]
    (match op
      [(IrBinAdd)
        (OkCompilerBackend
          (string-append "    add" (string-append s " %xmm1, %xmm0\n")))]
      [(IrBinSub)
        (OkCompilerBackend
          (string-append "    sub" (string-append s " %xmm1, %xmm0\n")))]
      [(IrBinMul)
        (OkCompilerBackend
          (string-append "    mul" (string-append s " %xmm1, %xmm0\n")))]
      [(IrBinDiv)
        (OkCompilerBackend
          (string-append "    div" (string-append s " %xmm1, %xmm0\n")))]
      [(IrBinSafeDiv)
        (OkCompilerBackend
          (string-append "    div" (string-append s " %xmm1, %xmm0\n")))]
      [(IrBinEq)
        (OkCompilerBackend
          (string-append
            "    "
            (string-append
              c
              " %xmm1, %xmm0\n    sete %al\n    movzbl %al, %eax\n")))]
      [(IrBinNe)
        (OkCompilerBackend
          (string-append
            "    "
            (string-append
              c
              " %xmm1, %xmm0\n    setne %al\n    movzbl %al, %eax\n")))]
      [(IrBinLt)
        (OkCompilerBackend
          (string-append
            "    "
            (string-append
              c
              " %xmm1, %xmm0\n    setb %al\n    movzbl %al, %eax\n")))]
      [(IrBinLe)
        (OkCompilerBackend
          (string-append
            "    "
            (string-append
              c
              " %xmm1, %xmm0\n    setbe %al\n    movzbl %al, %eax\n")))]
      [(IrBinGt)
        (OkCompilerBackend
          (string-append
            "    "
            (string-append
              c
              " %xmm1, %xmm0\n    seta %al\n    movzbl %al, %eax\n")))]
      [(IrBinGe)
        (OkCompilerBackend
          (string-append
            "    "
            (string-append
              c
              " %xmm1, %xmm0\n    setae %al\n    movzbl %al, %eax\n")))]
      [_
        (ErrCompilerBackend
          (compiler-diagnostic-at-start "" "backend: unsupported f64 binary op"))])))

(define (compiler-backend-f64-binop-asm [op : CompilerIrBinOp]) : ResultCompilerBackend
  (compiler-backend-float-binop-asm op (AstTyF64)))

(define (compiler-backend-f64-unop-asm [op : CompilerIrUnOp]) : ResultCompilerBackend
  (match op
    [(IrUnNeg)
      (OkCompilerBackend
        (str-cat
          "    xorpd "
          (compiler-backend-f64-sign-bit-label)
          "(%rip), %xmm0\n"))]
    [_
      (ErrCompilerBackend
        (compiler-diagnostic-at-start "" "backend: unsupported f64 unary op"))]))

;; 64-bit accumulate-in-place mnemonic for the arithmetic/bitwise binops whose
;; result can be computed directly in the destination register (dst = lhs <op>
;; rhs via "<op>q src, dst"). Comparisons, div/mod and shifts are excluded (they
;; need %rax/%rdx/%rcx or setcc) and return "".
(define (compiler-backend-binop-direct-mnemonic [op : CompilerIrBinOp]) : String
  (match op
    [(IrBinAdd) "addq"]
    [(IrBinSub) "subq"]
    [(IrBinMul) "imulq"]
    [(IrBinAnd) "andq"]
    [(IrBinOr) "orq"]
    [(IrBinBitAnd) "andq"]
    [(IrBinBitOr) "orq"]
    [(IrBinBitXor) "xorq"]
    [_ ""]))

;; #2386 (roadmap #1): the scalar register home of a value if it is a var the
;; allocator placed in a single GP register, else "". Used by the direct binop
;; path to source an operand straight from its home register instead of staging
;; it through %r8 (`movq %r13,%r8 ; addq %r8,%r12` -> `addq %r13,%r12`). Only a
;; plain CompilerRegRegister qualifies; group register-pairs are aggregates and
;; never appear as scalar binop operands.
(define (compiler-backend-value-scalar-register
  [assignments : CompilerRegAssignmentList]
  [value : CompilerIrValue]) : String
  (match value
    [(IrValueVar id)
      (if (>= (compiler-backend-forwarded-addr-of-src id) 0)
        ""
        (match (compiler-reg-assignment-lookup assignments id)
          [(CompilerRegSomeLocation location)
            (match location
              [(CompilerRegRegister r) r]
              [_ ""])]
          [(CompilerRegNoLocation) ""]))]
    [_ ""]))

;; Stack address of a scalar variable value that can be used as an instruction
;; source operand. Forwarded addr-of values are not stack loads and must fall
;; back to the ordinary load path.
(define (compiler-backend-value-stack-address
  [assignments : CompilerRegAssignmentList]
  [value : CompilerIrValue]) : String
  (match value
    [(IrValueVar id)
      (if (>= (compiler-backend-forwarded-addr-of-src id) 0)
        ""
        (match (compiler-reg-assignment-lookup assignments id)
          [(CompilerRegSomeLocation location)
            (match location
              [(CompilerRegSpill offset) (compiler-backend-frame-offset offset)]
              [_ ""])]
          [(CompilerRegNoLocation) (compiler-backend-slot id)]))]
    [_ ""]))

(define (compiler-backend-immediate-displacement [imm : String]) : String
  (substring imm 1 (- (string-length imm) 1)))

(define (compiler-backend-binop-source-asm
  [op : CompilerIrBinOp]
  [ty : AstType]
  [rhs : String]) : CompilerBackendMaybeAsm
  (match op
    [(IrBinAdd)
      (CompilerBackendSomeAsm
        (compiler-backend-binop-reg-asm
          "add"
          ty
          rhs
          (compiler-backend-sized-reg "%rax" ty)))]
    [(IrBinSub)
      (CompilerBackendSomeAsm
        (compiler-backend-binop-reg-asm
          "sub"
          ty
          rhs
          (compiler-backend-sized-reg "%rax" ty)))]
    [(IrBinMul)
      (if (= (compiler-backend-type-size ty) 1)
        (CompilerBackendNoAsm)
        (CompilerBackendSomeAsm
          (compiler-backend-binop-reg-asm
            "imul"
            ty
            rhs
            (compiler-backend-sized-reg "%rax" ty))))]
    [(IrBinEq)
      (CompilerBackendSomeAsm
        (compiler-backend-binop-cmp-set-asm
          ty
          rhs
          (compiler-backend-sized-reg "%rax" ty)
          "sete"))]
    [(IrBinNe)
      (CompilerBackendSomeAsm
        (compiler-backend-binop-cmp-set-asm
          ty
          rhs
          (compiler-backend-sized-reg "%rax" ty)
          "setne"))]
    [(IrBinLt)
      (CompilerBackendSomeAsm
        (compiler-backend-binop-cmp-set-asm
          ty
          rhs
          (compiler-backend-sized-reg "%rax" ty)
          (if (compiler-backend-unsigned-rel-ty? ty)
            "setb"
            "setl")))]
    [(IrBinLe)
      (CompilerBackendSomeAsm
        (compiler-backend-binop-cmp-set-asm
          ty
          rhs
          (compiler-backend-sized-reg "%rax" ty)
          (if (compiler-backend-unsigned-rel-ty? ty)
            "setbe"
            "setle")))]
    [(IrBinGt)
      (CompilerBackendSomeAsm
        (compiler-backend-binop-cmp-set-asm
          ty
          rhs
          (compiler-backend-sized-reg "%rax" ty)
          (if (compiler-backend-unsigned-rel-ty? ty)
            "seta"
            "setg")))]
    [(IrBinGe)
      (CompilerBackendSomeAsm
        (compiler-backend-binop-cmp-set-asm
          ty
          rhs
          (compiler-backend-sized-reg "%rax" ty)
          (if (compiler-backend-unsigned-rel-ty? ty)
            "setae"
            "setge")))]
    [(IrBinAnd)
      (CompilerBackendSomeAsm
        (compiler-backend-binop-reg-asm
          "and"
          ty
          rhs
          (compiler-backend-sized-reg "%rax" ty)))]
    [(IrBinOr)
      (CompilerBackendSomeAsm
        (compiler-backend-binop-reg-asm
          "or"
          ty
          rhs
          (compiler-backend-sized-reg "%rax" ty)))]
    [(IrBinBitAnd)
      (CompilerBackendSomeAsm
        (compiler-backend-binop-reg-asm
          "and"
          ty
          rhs
          (compiler-backend-sized-reg "%rax" ty)))]
    [(IrBinBitOr)
      (CompilerBackendSomeAsm
        (compiler-backend-binop-reg-asm
          "or"
          ty
          rhs
          (compiler-backend-sized-reg "%rax" ty)))]
    [(IrBinBitXor)
      (CompilerBackendSomeAsm
        (compiler-backend-binop-reg-asm
          "xor"
          ty
          rhs
          (compiler-backend-sized-reg "%rax" ty)))]
    [_ (CompilerBackendNoAsm)]))

(define (compiler-backend-emit-binop-direct-immediate
  [assignments : CompilerRegAssignmentList]
  [dst-home : String]
  [mnem : String]
  [op : CompilerIrBinOp]
  [lhs : CompilerIrValue]
  [imm : String]) : ResultCompilerBackend
  (let
    [lhs-reg : String (compiler-backend-value-scalar-register assignments lhs)]
    (if (and
      (not (string-eq lhs-reg ""))
      (match op
        [(IrBinMul) true]
        [_ false]))
      (OkCompilerBackend
        (str-cat "    imulq " imm ", " lhs-reg ", " dst-home "\n"))
      (if (and
        (not (string-eq lhs-reg ""))
        (not (string-eq lhs-reg dst-home))
        (not (string-eq imm "$0"))
        (match op
          [(IrBinAdd) true]
          [_ false]))
        (OkCompilerBackend
          (str-cat
            "    leaq "
            (compiler-backend-immediate-displacement imm)
            "("
            lhs-reg
            "), "
            dst-home
            "\n"))
        (match (compiler-backend-emit-load-value-with-plan
          assignments
          lhs
          dst-home)
          [(OkCompilerBackend lhs-asm)
            (OkCompilerBackend
              (string-append
                lhs-asm
                (str-cat "    " mnem " " imm ", " dst-home "\n")))]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)])))))

(define (compiler-backend-emit-binop
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [op : CompilerIrBinOp]
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [ty : AstType]) : ResultCompilerBackend
  (if (compiler-backend-binop-f64? types global-types lhs rhs ty)
    (let
      [fty : AstType
        (compiler-backend-binop-operand-ty types global-types op lhs rhs ty)]
      (match (compiler-backend-emit-load-float-value-with-plan
        assignments
        lhs
        fty
        "%xmm0")
        [(OkCompilerBackend lhs-asm)
          (match (compiler-backend-emit-load-float-value-with-plan
            assignments
            rhs
            fty
            "%xmm1")
            [(OkCompilerBackend rhs-asm)
              (match (compiler-backend-float-binop-asm op fty)
                [(OkCompilerBackend op-asm)
                  (OkCompilerBackend
                    (string-append
                      lhs-asm
                      (string-append
                        rhs-asm
                        (string-append
                          op-asm
                          (if (compiler-backend-float-type? ty)
                            (compiler-backend-emit-store-float-var-with-plan
                              assignments
                              dst
                              "%xmm0"
                              ty)
                            (compiler-backend-emit-store-var-with-plan
                              assignments
                              dst
                              "%rax"))))))]
                [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
            [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)]))
    (let
      [operand-ty : AstType
        (compiler-backend-binop-operand-ty types global-types op lhs rhs ty)]
      [dst-home : String (compiler-backend-var-register-home assignments dst)]
      [mnem : String (compiler-backend-binop-direct-mnemonic op)]
      (if (if (string-eq dst-home "")
        false
        (if (= (compiler-backend-type-size operand-ty) 8)
          (not (string-eq mnem ""))
          false))
        ;; Accumulate directly in the destination register: dst = lhs <op> rhs.
        ;; #2386 (roadmap #1): if rhs already lives in a register distinct from
        ;; dst-home, source the op straight from that home -- load lhs into
        ;; dst-home, then "<op> rhs-home, dst-home" -- skipping the "movq
        ;; rhs-home,%r8" stage entirely (rhs-home != dst-home guarantees the lhs
        ;; load cannot clobber it). Otherwise stage rhs through %r8 FIRST: lhs
        ;; goes into dst's home register, which may itself be rhs's home, and
        ;; loading lhs first would clobber rhs.
        (match (compiler-backend-immediate-operand rhs)
          [(CompilerBackendSomeImmediate imm)
            (compiler-backend-emit-binop-direct-immediate
              assignments
              dst-home
              mnem
              op
              lhs
              imm)]
          [(CompilerBackendNoImmediate)
            (let
              [rhs-reg : String
                (compiler-backend-value-scalar-register assignments rhs)]
              (if (if (string-eq rhs-reg "")
                false
                (not (string-eq rhs-reg dst-home)))
                (match (compiler-backend-emit-load-value-with-plan
                  assignments
                  lhs
                  dst-home)
                  [(OkCompilerBackend lhs-asm)
                    (OkCompilerBackend
                      (string-append
                        lhs-asm
                        (str-cat
                          "    "
                          mnem
                          " "
                          rhs-reg
                          (string-append ", " (string-append dst-home "\n")))))]
                  [(ErrCompilerBackend message) (ErrCompilerBackend message)])
                (match (compiler-backend-emit-load-value-with-plan
                  assignments
                  rhs
                  "%r8")
                  [(OkCompilerBackend rhs-asm)
                    (match (compiler-backend-emit-load-value-with-plan
                      assignments
                      lhs
                      dst-home)
                      [(OkCompilerBackend lhs-asm)
                        (OkCompilerBackend
                          (string-append
                            rhs-asm
                            (string-append
                              lhs-asm
                              (str-cat "    " mnem " %r8, " dst-home "\n"))))]
                      [(ErrCompilerBackend message)
                        (ErrCompilerBackend message)])]
                  [(ErrCompilerBackend message) (ErrCompilerBackend message)])))])
        (match (compiler-backend-emit-load-value-with-plan
          assignments
          lhs
          "%rax")
          [(OkCompilerBackend lhs-asm)
            (match (compiler-backend-binop-literal-divmod-asm op rhs operand-ty)
              [(CompilerBackendSomeAsm op-asm)
                (OkCompilerBackend
                  (string-append
                    lhs-asm
                    (string-append
                      op-asm
                      (compiler-backend-emit-store-typed-var-with-plan
                        assignments
                        dst
                        "%rax"
                        ty))))]
              [(CompilerBackendNoAsm)
                (match (compiler-backend-immediate-operand rhs)
                  [(CompilerBackendSomeImmediate imm)
                    (match (compiler-backend-binop-immediate-asm
                      op
                      imm
                      operand-ty)
                      [(CompilerBackendSomeAsm op-asm)
                        (OkCompilerBackend
                          (string-append
                            lhs-asm
                            (string-append
                              op-asm
                              (compiler-backend-emit-store-typed-var-with-plan
                                assignments
                                dst
                                "%rax"
                                ty))))]
                      [(CompilerBackendNoAsm)
                        (match (compiler-backend-emit-load-value-with-plan
                          assignments
                          rhs
                          "%r8")
                          [(OkCompilerBackend rhs-asm)
                            (OkCompilerBackend
                              (string-append
                                lhs-asm
                                (string-append
                                  rhs-asm
                                  (string-append
                                    (compiler-backend-binop-asm op operand-ty)
                                    (compiler-backend-emit-store-typed-var-with-plan
                                      assignments
                                      dst
                                      "%rax"
                                      ty)))))]
                          [(ErrCompilerBackend message)
                            (ErrCompilerBackend message)])])]
                  [(CompilerBackendNoImmediate)
                    (let
                      [rhs-address : String
                        (compiler-backend-value-stack-address assignments rhs)]
                      (if (not (string-eq rhs-address ""))
                        (match (compiler-backend-binop-source-asm
                          op
                          operand-ty
                          rhs-address)
                          [(CompilerBackendSomeAsm op-asm)
                            (OkCompilerBackend
                              (string-append
                                lhs-asm
                                (string-append
                                  op-asm
                                  (compiler-backend-emit-store-typed-var-with-plan
                                    assignments
                                    dst
                                    "%rax"
                                    ty))))]
                          [(CompilerBackendNoAsm)
                            (match (compiler-backend-emit-load-value-with-plan
                              assignments
                              rhs
                              "%r8")
                              [(OkCompilerBackend rhs-asm)
                                (OkCompilerBackend
                                  (string-append
                                    lhs-asm
                                    (string-append
                                      rhs-asm
                                      (string-append
                                        (compiler-backend-binop-asm
                                          op
                                          operand-ty)
                                        (compiler-backend-emit-store-typed-var-with-plan
                                          assignments
                                          dst
                                          "%rax"
                                          ty)))))]
                              [(ErrCompilerBackend message)
                                (ErrCompilerBackend message)])])
                        (match (compiler-backend-emit-load-value-with-plan
                          assignments
                          rhs
                          "%r8")
                          [(OkCompilerBackend rhs-asm)
                            (OkCompilerBackend
                              (string-append
                                lhs-asm
                                (string-append
                                  rhs-asm
                                  (string-append
                                    (compiler-backend-binop-asm op operand-ty)
                                    (compiler-backend-emit-store-typed-var-with-plan
                                      assignments
                                      dst
                                      "%rax"
                                      ty)))))]
                          [(ErrCompilerBackend message)
                            (ErrCompilerBackend message)])))])])]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)])))))

(define (compiler-backend-empty-assignments?
  [assignments : CompilerRegAssignmentList]) : bool
  (match assignments
    [(CompilerRegAssignmentNil) true]
    [_ false]))

(define (compiler-backend-commutative-binop? [op : CompilerIrBinOp]) : bool
  (match op
    [(IrBinAdd) true]
    [(IrBinMul) true]
    [(IrBinAnd) true]
    [(IrBinOr) true]
    [(IrBinBitAnd) true]
    [(IrBinBitOr) true]
    [(IrBinBitXor) true]
    [_ false]))

(define (compiler-backend-rax-forwardable-binop?
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [assignments : CompilerRegAssignmentList]
  [op : CompilerIrBinOp]
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [ty : AstType]) : bool
  (and
    (compiler-backend-empty-assignments? assignments)
    (not (compiler-backend-compare-op? op))
    (not (compiler-backend-binop-f64? types global-types lhs rhs ty))))

(define (compiler-backend-binop-result-store
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [ty : AstType]
  [store-result : bool]) : String
  (if store-result
    (compiler-backend-emit-store-typed-var-with-plan assignments dst "%rax" ty)
    ""))

(define (compiler-backend-emit-binop-rax-rhs
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [op : CompilerIrBinOp]
  [rhs : CompilerIrValue]
  [operand-ty : AstType]
  [result-ty : AstType]
  [store-result : bool]) : ResultCompilerBackend
  (let
    [store : String
      (compiler-backend-binop-result-store
        assignments
        dst
        result-ty
        store-result)]
    (match (compiler-backend-binop-literal-divmod-asm op rhs operand-ty)
      [(CompilerBackendSomeAsm op-asm)
        (OkCompilerBackend (string-append op-asm store))]
      [(CompilerBackendNoAsm)
        (match (compiler-backend-immediate-operand rhs)
          [(CompilerBackendSomeImmediate imm)
            (match (compiler-backend-binop-immediate-asm op imm operand-ty)
              [(CompilerBackendSomeAsm op-asm)
                (OkCompilerBackend (string-append op-asm store))]
              [(CompilerBackendNoAsm)
                (match (compiler-backend-emit-load-value-with-plan
                  assignments
                  rhs
                  "%r8")
                  [(OkCompilerBackend rhs-asm)
                    (OkCompilerBackend
                      (string-append
                        rhs-asm
                        (string-append
                          (compiler-backend-binop-asm op operand-ty)
                          store)))]
                  [(ErrCompilerBackend message) (ErrCompilerBackend message)])])]
          [(CompilerBackendNoImmediate)
            (match (compiler-backend-emit-load-value-with-plan
              assignments
              rhs
              "%r8")
              [(OkCompilerBackend rhs-asm)
                (OkCompilerBackend
                  (string-append
                    rhs-asm
                    (string-append
                      (compiler-backend-binop-asm op operand-ty)
                      store)))]
              [(ErrCompilerBackend message) (ErrCompilerBackend message)])])])))

(define (compiler-backend-emit-binop-to-rax
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [op : CompilerIrBinOp]
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [ty : AstType]
  [store-result : bool]) : ResultCompilerBackend
  (if (compiler-backend-rax-forwardable-binop?
    types
    global-types
    assignments
    op
    lhs
    rhs
    ty)
    (let
      [operand-ty : AstType
        (compiler-backend-binop-operand-ty types global-types op lhs rhs ty)]
      (match (compiler-backend-emit-load-value-with-plan assignments lhs "%rax")
        [(OkCompilerBackend lhs-asm)
          (match (compiler-backend-emit-binop-rax-rhs
            assignments
            dst
            op
            rhs
            operand-ty
            ty
            store-result)
            [(OkCompilerBackend op-asm)
              (OkCompilerBackend (string-append lhs-asm op-asm))]
            [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)]))
    (compiler-backend-emit-binop
      types
      global-types
      assignments
      dst
      op
      lhs
      rhs
      ty)))

(define (compiler-backend-emit-binop-with-rax-value
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [assignments : CompilerRegAssignmentList]
  [rax-var : i64]
  [dst : i64]
  [op : CompilerIrBinOp]
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [ty : AstType]
  [store-result : bool]) : ResultCompilerBackend
  (if (compiler-backend-rax-forwardable-binop?
    types
    global-types
    assignments
    op
    lhs
    rhs
    ty)
    (let
      [operand-ty : AstType
        (compiler-backend-binop-operand-ty types global-types op lhs rhs ty)]
      (if (compiler-backend-branch-uses-var? lhs rax-var)
        (compiler-backend-emit-binop-rax-rhs
          assignments
          dst
          op
          rhs
          operand-ty
          ty
          store-result)
        (if (and
          (compiler-backend-branch-uses-var? rhs rax-var)
          (compiler-backend-commutative-binop? op))
          (compiler-backend-emit-binop-rax-rhs
            assignments
            dst
            op
            lhs
            operand-ty
            ty
            store-result)
          (compiler-backend-emit-binop
            types
            global-types
            assignments
            dst
            op
            lhs
            rhs
            ty))))
    (compiler-backend-emit-binop
      types
      global-types
      assignments
      dst
      op
      lhs
      rhs
      ty)))

(define (compiler-backend-emit-binop-return
  [source-function : String]
  [blocks : CompilerIrBlockList]
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [op : CompilerIrBinOp]
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [ty : AstType]) : ResultCompilerBackend
  (let
    [return-tail : String
      (compiler-backend-return-tail source-function assignments vars blocks)]
    (if (compiler-backend-binop-f64? types global-types lhs rhs ty)
      (let
        [fty : AstType
          (compiler-backend-binop-operand-ty types global-types op lhs rhs ty)]
        (match (compiler-backend-emit-load-float-value-with-plan
          assignments
          lhs
          fty
          "%xmm0")
          [(OkCompilerBackend lhs-asm)
            (match (compiler-backend-emit-load-float-value-with-plan
              assignments
              rhs
              fty
              "%xmm1")
              [(OkCompilerBackend rhs-asm)
                (match (compiler-backend-float-binop-asm op fty)
                  [(OkCompilerBackend op-asm)
                    (OkCompilerBackend
                      (string-append
                        lhs-asm
                        (string-append
                          rhs-asm
                          (string-append op-asm return-tail))))]
                  [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
              [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)]))
      (let
        [operand-ty : AstType
          (compiler-backend-binop-operand-ty types global-types op lhs rhs ty)]
        (match (compiler-backend-emit-load-value-with-plan
          assignments
          lhs
          "%rax")
          [(OkCompilerBackend lhs-asm)
            (match (compiler-backend-binop-literal-divmod-asm op rhs operand-ty)
              [(CompilerBackendSomeAsm op-asm)
                (OkCompilerBackend
                  (string-append lhs-asm (string-append op-asm return-tail)))]
              [(CompilerBackendNoAsm)
                (match (compiler-backend-immediate-operand rhs)
                  [(CompilerBackendSomeImmediate imm)
                    (match (compiler-backend-binop-immediate-asm
                      op
                      imm
                      operand-ty)
                      [(CompilerBackendSomeAsm op-asm)
                        (OkCompilerBackend
                          (string-append
                            lhs-asm
                            (string-append op-asm return-tail)))]
                      [(CompilerBackendNoAsm)
                        (match (compiler-backend-emit-load-value-with-plan
                          assignments
                          rhs
                          "%r8")
                          [(OkCompilerBackend rhs-asm)
                            (OkCompilerBackend
                              (string-append
                                lhs-asm
                                (string-append
                                  rhs-asm
                                  (string-append
                                    (compiler-backend-binop-asm op operand-ty)
                                    return-tail))))]
                          [(ErrCompilerBackend message)
                            (ErrCompilerBackend message)])])]
                  [(CompilerBackendNoImmediate)
                    (match (compiler-backend-emit-load-value-with-plan
                      assignments
                      rhs
                      "%r8")
                      [(OkCompilerBackend rhs-asm)
                        (OkCompilerBackend
                          (string-append
                            lhs-asm
                            (string-append
                              rhs-asm
                              (string-append
                                (compiler-backend-binop-asm op operand-ty)
                                return-tail))))]
                      [(ErrCompilerBackend message)
                        (ErrCompilerBackend message)])])])]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)])))))

(define (compiler-backend-jump-label [function : String] [label : String]) : String
  (str-cat "    jmp " (compiler-backend-asm-label function label) "\n" ""))

(define (compiler-backend-jump-target-is-fallthrough?
  [target : String]
  [fallthrough : CompilerBackendMaybeLabel]) : bool
  (match fallthrough
    [(CompilerBackendSomeLabel label) (string-eq target label)]
    [(CompilerBackendNoLabel) false]))

(define (compiler-backend-emit-branch-jumps
  [function : String]
  [true-label : String]
  [false-label : String]
  [fallthrough : CompilerBackendMaybeLabel]) : String
  (if (compiler-backend-jump-target-is-fallthrough? false-label fallthrough)
    (str-cat
      "    jne "
      (compiler-backend-asm-label function true-label)
      "\n"
      "")
    (if (compiler-backend-jump-target-is-fallthrough? true-label fallthrough)
      (str-cat
        "    je "
        (compiler-backend-asm-label function false-label)
        "\n"
        "")
      (str-cat
        "    jne "
        (compiler-backend-asm-label function true-label)
        "\n    jmp "
        (compiler-backend-asm-label function false-label)
        "\n"))))

(define (compiler-backend-branch-test-var-asm
  [assignments : CompilerRegAssignmentList]
  [var-id : i64]) : String
  (if (>= (compiler-backend-forwarded-addr-of-src var-id) 0)
    ""
    (match (compiler-reg-assignment-lookup assignments var-id)
      [(CompilerRegSomeLocation location)
        (match location
          [(CompilerRegRegister home)
            (str-cat "    testq " home ", " home "\n")]
          [(CompilerRegRegisterPair _ _) ""]
          [(CompilerRegSpill offset)
            (str-cat
              "    cmpq $0, "
              (compiler-backend-frame-offset offset)
              "\n")])]
      [(CompilerRegNoLocation)
        (str-cat "    cmpq $0, " (compiler-backend-slot var-id) "\n")])))

(define (compiler-backend-emit-load-test-branch
  [assignments : CompilerRegAssignmentList]
  [function : String]
  [cond : CompilerIrValue]
  [true-label : String]
  [false-label : String]
  [fallthrough : CompilerBackendMaybeLabel]) : ResultCompilerBackend
  (match (compiler-backend-emit-load-value-with-plan assignments cond "%rax")
    [(OkCompilerBackend load)
      (OkCompilerBackend
        (string-append
          load
          (string-append
            "    testq %rax, %rax\n"
            (compiler-backend-emit-branch-jumps
              function
              true-label
              false-label
              fallthrough))))]
    [(ErrCompilerBackend message) (ErrCompilerBackend message)]))

(define (compiler-backend-emit-branch
  [assignments : CompilerRegAssignmentList]
  [function : String]
  [cond : CompilerIrValue]
  [true-label : String]
  [false-label : String]
  [fallthrough : CompilerBackendMaybeLabel]) : ResultCompilerBackend
  (match cond
    [(IrValueBool b)
      (if b
        (OkCompilerBackend
          (if (compiler-backend-jump-target-is-fallthrough?
            true-label
            fallthrough)
            ""
            (compiler-backend-jump-label function true-label)))
        (OkCompilerBackend
          (if (compiler-backend-jump-target-is-fallthrough?
            false-label
            fallthrough)
            ""
            (compiler-backend-jump-label function false-label))))]
    [(IrValueVar id)
      (let
        [test-asm : String
          (compiler-backend-branch-test-var-asm assignments id)]
        (if (string-eq test-asm "")
          (compiler-backend-emit-load-test-branch
            assignments
            function
            cond
            true-label
            false-label
            fallthrough)
          (OkCompilerBackend
            (string-append
              test-asm
              (compiler-backend-emit-branch-jumps
                function
                true-label
                false-label
                fallthrough)))))]
    [_
      (match (compiler-backend-emit-load-value-with-plan
        assignments
        cond
        "%rax")
        [(OkCompilerBackend load)
          (OkCompilerBackend
            (string-append
              load
              (string-append
                "    testq %rax, %rax\n"
                (if (compiler-backend-jump-target-is-fallthrough?
                  false-label
                  fallthrough)
                  (str-cat
                    "    jne "
                    (compiler-backend-asm-label function true-label)
                    "\n"
                    "")
                  (if (compiler-backend-jump-target-is-fallthrough?
                    true-label
                    fallthrough)
                    (str-cat
                      "    je "
                      (compiler-backend-asm-label function false-label)
                      "\n"
                      "")
                    (str-cat
                      "    jne "
                      (compiler-backend-asm-label function true-label)
                      "\n    jmp "
                      (compiler-backend-asm-label function false-label)
                      "\n"))))))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]))

(define (compiler-backend-compare-op? [op : CompilerIrBinOp]) : bool
  (match op
    [(IrBinEq) true]
    [(IrBinNe) true]
    [(IrBinLt) true]
    [(IrBinLe) true]
    [(IrBinGt) true]
    [(IrBinGe) true]
    [_ false]))

(define (compiler-backend-divmod-op? [op : CompilerIrBinOp]) : bool
  (match op
    [(IrBinDiv) true]
    [(IrBinMod) true]
    [(IrBinSafeDiv) true]
    [(IrBinSafeMod) true]
    [_ false]))

(define (compiler-backend-compare-true-jcc
  [op : CompilerIrBinOp]
  [ty : AstType]) : String
  (match op
    [(IrBinEq) "je"]
    [(IrBinNe) "jne"]
    [(IrBinLt)
      (if (compiler-backend-unsigned-rel-ty? ty)
        "jb"
        "jl")]
    [(IrBinLe)
      (if (compiler-backend-unsigned-rel-ty? ty)
        "jbe"
        "jle")]
    [(IrBinGt)
      (if (compiler-backend-unsigned-rel-ty? ty)
        "ja"
        "jg")]
    [(IrBinGe)
      (if (compiler-backend-unsigned-rel-ty? ty)
        "jae"
        "jge")]
    [_ ""]))

(define (compiler-backend-compare-false-jcc
  [op : CompilerIrBinOp]
  [ty : AstType]) : String
  (match op
    [(IrBinEq) "jne"]
    [(IrBinNe) "je"]
    [(IrBinLt)
      (if (compiler-backend-unsigned-rel-ty? ty)
        "jae"
        "jge")]
    [(IrBinLe)
      (if (compiler-backend-unsigned-rel-ty? ty)
        "ja"
        "jg")]
    [(IrBinGt)
      (if (compiler-backend-unsigned-rel-ty? ty)
        "jbe"
        "jle")]
    [(IrBinGe)
      (if (compiler-backend-unsigned-rel-ty? ty)
        "jb"
        "jl")]
    [_ ""]))

(define (compiler-backend-emit-jcc-label
  [jcc : String]
  [function : String]
  [label : String]) : String
  (str-cat "    " jcc " " (compiler-backend-asm-label function label) "\n"))

(define (compiler-backend-emit-compare-branch-jumps
  [function : String]
  [true-label : String]
  [false-label : String]
  [fallthrough : CompilerBackendMaybeLabel]
  [true-jcc : String]
  [false-jcc : String]) : String
  (if (compiler-backend-jump-target-is-fallthrough? false-label fallthrough)
    (compiler-backend-emit-jcc-label true-jcc function true-label)
    (if (compiler-backend-jump-target-is-fallthrough? true-label fallthrough)
      (compiler-backend-emit-jcc-label false-jcc function false-label)
      (string-append
        (compiler-backend-emit-jcc-label true-jcc function true-label)
        (compiler-backend-jump-label function false-label)))))

(define (compiler-backend-compare-uses-zero-test? [op : CompilerIrBinOp]) : bool
  (match op
    [(IrBinEq) true]
    [(IrBinNe) true]
    [_ false]))

(define (compiler-backend-emit-compare-flags
  [op : CompilerIrBinOp]
  [rhs : String]
  [ty : AstType]) : String
  (if (and (string-eq rhs "$0") (compiler-backend-compare-uses-zero-test? op))
    (compiler-backend-binop-reg-asm
      "test"
      ty
      (compiler-backend-sized-reg "%rax" ty)
      (compiler-backend-sized-reg "%rax" ty))
    (string-append
      (str-cat
        "    cmp"
        (compiler-backend-int-instruction-suffix ty)
        " "
        rhs
        ", ")
      (str-cat (compiler-backend-sized-reg "%rax" ty) "\n" ""))))

;; A scalar register-homed var IS its own cmp source operand, so a comparison can
;; emit `cmp <home>, %rax` directly instead of `movq <home>, %r8; cmp %r8, %rax`
;; -- one fewer instruction per comparison (hot in every loop bound test). Returns
;; "" (forcing the %r8 load path) for spilled vars, register groups/pairs (not a
;; scalar operand) and addr-of-forwarded vars (whose value is a computed address,
;; not the contents of the home register). The home is always a callee-saved
;; register (never %rax/%r8), so it cannot be clobbered by the lhs load into %rax.
(define (compiler-backend-value-scalar-register-home
  [assignments : CompilerRegAssignmentList]
  [value : CompilerIrValue]) : String
  (match value
    [(IrValueVar id)
      (if (>= (compiler-backend-forwarded-addr-of-src id) 0)
        ""
        (match (compiler-reg-assignment-lookup assignments id)
          [(CompilerRegSomeLocation location)
            (match location
              [(CompilerRegRegister r) r]
              [_ ""])]
          [_ ""]))]
    [_ ""]))

(define (compiler-backend-emit-compare-branch
  [assignments : CompilerRegAssignmentList]
  [function : String]
  [op : CompilerIrBinOp]
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [ty : AstType]
  [true-label : String]
  [false-label : String]
  [fallthrough : CompilerBackendMaybeLabel]) : ResultCompilerBackend
  (let
    [true-jcc : String (compiler-backend-compare-true-jcc op ty)]
    [false-jcc : String (compiler-backend-compare-false-jcc op ty)]
    (if (string-eq true-jcc "")
      (ErrCompilerBackend
        (compiler-diagnostic-at-start "" "backend: unsupported compare branch"))
      (match (compiler-backend-emit-load-value-with-plan assignments lhs "%rax")
        [(OkCompilerBackend lhs-asm)
          (match (compiler-backend-immediate-operand rhs)
            [(CompilerBackendSomeImmediate imm)
              (OkCompilerBackend
                (string-append
                  lhs-asm
                  (string-append
                    (compiler-backend-emit-compare-flags op imm ty)
                    (compiler-backend-emit-compare-branch-jumps
                      function
                      true-label
                      false-label
                      fallthrough
                      true-jcc
                      false-jcc))))]
            [(CompilerBackendNoImmediate)
              (let
                [rhs-home : String
                  (compiler-backend-value-scalar-register-home assignments rhs)]
                (if (not (string-eq rhs-home ""))
                  (OkCompilerBackend
                    (string-append
                      lhs-asm
                      (string-append
                        (compiler-backend-emit-compare-flags
                          op
                          (compiler-backend-sized-reg rhs-home ty)
                          ty)
                        (compiler-backend-emit-compare-branch-jumps
                          function
                          true-label
                          false-label
                          fallthrough
                          true-jcc
                          false-jcc))))
                  (match (compiler-backend-emit-load-value-with-plan
                    assignments
                    rhs
                    "%r8")
                    [(OkCompilerBackend rhs-asm)
                      (OkCompilerBackend
                        (string-append
                          lhs-asm
                          (string-append
                            rhs-asm
                            (string-append
                              (compiler-backend-emit-compare-flags
                                op
                                (compiler-backend-sized-reg "%r8" ty)
                                ty)
                              (compiler-backend-emit-compare-branch-jumps
                                function
                                true-label
                                false-label
                                fallthrough
                                true-jcc
                                false-jcc)))))]
                    [(ErrCompilerBackend message) (ErrCompilerBackend message)])))])]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)]))))

(define (compiler-backend-load-compare-type? [ty : AstType]) : bool
  (and
    (not (compiler-backend-float-type? ty))
    (= (compiler-backend-type-size ty) 8)))

(define (compiler-backend-emit-compare-memory-address-flags
  [rhs : String]
  [addr : String]) : String
  (str-cat "    cmpq " rhs ", " addr "\n"))

(define (compiler-backend-emit-compare-memory-flags [rhs : String]) : String
  (compiler-backend-emit-compare-memory-address-flags rhs "(%r10)"))

(define (compiler-backend-emit-load-compare-branch
  [assignments : CompilerRegAssignmentList]
  [function : String]
  [ptr : CompilerIrValue]
  [op : CompilerIrBinOp]
  [rhs : CompilerIrValue]
  [ty : AstType]
  [true-label : String]
  [false-label : String]
  [fallthrough : CompilerBackendMaybeLabel]) : ResultCompilerBackend
  (let
    [true-jcc : String (compiler-backend-compare-true-jcc op ty)]
    [false-jcc : String (compiler-backend-compare-false-jcc op ty)]
    (if (string-eq true-jcc "")
      (ErrCompilerBackend
        (compiler-diagnostic-at-start
          ""
          "backend: unsupported load compare branch"))
      (match (compiler-backend-emit-load-value-with-plan assignments ptr "%r10")
        [(OkCompilerBackend ptr-asm)
          (match (compiler-backend-immediate-operand rhs)
            [(CompilerBackendSomeImmediate imm)
              (OkCompilerBackend
                (string-append
                  ptr-asm
                  (string-append
                    (compiler-backend-emit-compare-memory-flags imm)
                    (compiler-backend-emit-compare-branch-jumps
                      function
                      true-label
                      false-label
                      fallthrough
                      true-jcc
                      false-jcc))))]
            [(CompilerBackendNoImmediate)
              (match (compiler-backend-emit-load-value-with-plan
                assignments
                rhs
                "%r8")
                [(OkCompilerBackend rhs-asm)
                  (OkCompilerBackend
                    (string-append
                      ptr-asm
                      (string-append
                        rhs-asm
                        (string-append
                          (compiler-backend-emit-compare-memory-flags "%r8")
                          (compiler-backend-emit-compare-branch-jumps
                            function
                            true-label
                            false-label
                            fallthrough
                            true-jcc
                            false-jcc)))))]
                [(ErrCompilerBackend message) (ErrCompilerBackend message)])])]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)]))))

(define (compiler-backend-emit-gep-load-compare-branch
  [assignments : CompilerRegAssignmentList]
  [function : String]
  [base : CompilerIrValue]
  [offset : CompilerIrValue]
  [elem-ty : AstType]
  [op : CompilerIrBinOp]
  [rhs : CompilerIrValue]
  [ty : AstType]
  [true-label : String]
  [false-label : String]
  [fallthrough : CompilerBackendMaybeLabel]) : ResultCompilerBackend
  (let
    [true-jcc : String (compiler-backend-compare-true-jcc op ty)]
    [false-jcc : String (compiler-backend-compare-false-jcc op ty)]
    (if (string-eq true-jcc "")
      (ErrCompilerBackend
        (compiler-diagnostic-at-start
          ""
          "backend: unsupported gep load compare branch"))
      (match (compiler-backend-value-as-i64 offset)
        [(CompilerBackendSomeI64 n)
          (let
            [disp : i64 (* n (compiler-backend-type-size elem-ty))]
            [addr : String (compiler-backend-r10-address disp)]
            (match (compiler-backend-emit-load-value-with-plan
              assignments
              base
              "%r10")
              [(OkCompilerBackend base-asm)
                (match (compiler-backend-immediate-operand rhs)
                  [(CompilerBackendSomeImmediate imm)
                    (OkCompilerBackend
                      (string-append
                        base-asm
                        (string-append
                          (compiler-backend-emit-compare-memory-address-flags
                            imm
                            addr)
                          (compiler-backend-emit-compare-branch-jumps
                            function
                            true-label
                            false-label
                            fallthrough
                            true-jcc
                            false-jcc))))]
                  [(CompilerBackendNoImmediate)
                    (match (compiler-backend-emit-load-value-with-plan
                      assignments
                      rhs
                      "%r8")
                      [(OkCompilerBackend rhs-asm)
                        (OkCompilerBackend
                          (string-append
                            base-asm
                            (string-append
                              rhs-asm
                              (string-append
                                (compiler-backend-emit-compare-memory-address-flags
                                  "%r8"
                                  addr)
                                (compiler-backend-emit-compare-branch-jumps
                                  function
                                  true-label
                                  false-label
                                  fallthrough
                                  true-jcc
                                  false-jcc)))))]
                      [(ErrCompilerBackend message)
                        (ErrCompilerBackend message)])])]
              [(ErrCompilerBackend message) (ErrCompilerBackend message)]))]
        [(CompilerBackendNoI64)
          (ErrCompilerBackend
            (compiler-diagnostic-at-start
              ""
              "backend: non-immediate fused gep load compare branch"))]))))

(define (compiler-backend-bounds-length-operand
  [assignments : CompilerRegAssignmentList]
  [length : CompilerIrValue]) : String
  (match (compiler-backend-immediate-operand length)
    [(CompilerBackendSomeImmediate imm) imm]
    [(CompilerBackendNoImmediate)
      (let
        [length-reg : String
          (compiler-backend-value-scalar-register-home assignments length)]
        (if (not (string-eq length-reg ""))
          length-reg
          (compiler-backend-value-stack-address assignments length)))]))

(define (compiler-backend-bounds-check-tail
  [call-space : i64]
  [ok-symbol : String]
  [plan : CompilerBackendRuntimePlan]
  [program-index : CompilerBackendProgramIndex]) : String
  (string-append
    (compiler-backend-emit-call-space-sub call-space)
    (str-cat
      "    call "
      (compiler-backend-call-symbol-index "tl_oob_abort" plan program-index)
      "\n"
      (string-append
        (compiler-backend-emit-call-space-add call-space)
        (str-cat ok-symbol ":\n" "" ""))
      "")))

(define (compiler-backend-bounds-check-asm
  [index-asm : String]
  [length-asm : String]
  [length-operand : String]
  [index-operand : String]
  [call-space : i64]
  [ok-symbol : String]
  [plan : CompilerBackendRuntimePlan]
  [program-index : CompilerBackendProgramIndex]) : String
  (string-append
    index-asm
    (string-append
      length-asm
      (string-append
        (str-cat
          "    cmpq "
          length-operand
          ", "
          index-operand
          "\n    jb "
          ok-symbol
          "\n")
        (compiler-backend-bounds-check-tail
          call-space
          ok-symbol
          plan
          program-index)))))

(define (compiler-backend-emit-bounds-check
  [target : CompilerBackendTarget]
  [function : String]
  [assignments : CompilerRegAssignmentList]
  [index : CompilerIrValue]
  [length : CompilerIrValue]
  [ok-label : String]
  [plan : CompilerBackendRuntimePlan]
  [_functions : CompilerIrFunctionList]
  [_externs : CompilerIrExternList]
  [program-index : CompilerBackendProgramIndex]) : ResultCompilerBackend
  (let
    [call-space : i64
      (compiler-backend-call-arg-space
        target
        (IrCallArgsNil)
        AstTypeNil
        false
        program-index)]
    [ok-symbol : String (compiler-backend-asm-label function ok-label)]
    [index-reg : String
      (compiler-backend-value-scalar-register-home assignments index)]
    [index-operand : String
      (if (string-eq index-reg "")
        "%rax"
        index-reg)]
    (if (string-eq index-reg "")
      (match (compiler-backend-emit-load-value-with-plan
        assignments
        index
        "%rax")
        [(OkCompilerBackend index-asm)
          (let
            [length-operand : String
              (compiler-backend-bounds-length-operand assignments length)]
            (if (not (string-eq length-operand ""))
              (OkCompilerBackend
                (compiler-backend-bounds-check-asm
                  index-asm
                  ""
                  length-operand
                  index-operand
                  call-space
                  ok-symbol
                  plan
                  program-index))
              (match (compiler-backend-emit-load-value-with-plan
                assignments
                length
                "%r11")
                [(OkCompilerBackend length-asm)
                  (OkCompilerBackend
                    (compiler-backend-bounds-check-asm
                      index-asm
                      length-asm
                      "%r11"
                      index-operand
                      call-space
                      ok-symbol
                      plan
                      program-index))]
                [(ErrCompilerBackend message) (ErrCompilerBackend message)])))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])
      (let
        [length-operand : String
          (compiler-backend-bounds-length-operand assignments length)]
        (if (not (string-eq length-operand ""))
          (OkCompilerBackend
            (compiler-backend-bounds-check-asm
              ""
              ""
              length-operand
              index-operand
              call-space
              ok-symbol
              plan
              program-index))
          (match (compiler-backend-emit-load-value-with-plan
            assignments
            length
            "%r11")
            [(OkCompilerBackend length-asm)
              (OkCompilerBackend
                (compiler-backend-bounds-check-asm
                  ""
                  length-asm
                  "%r11"
                  index-operand
                  call-space
                  ok-symbol
                  plan
                  program-index))]
            [(ErrCompilerBackend message) (ErrCompilerBackend message)]))))))

(define (compiler-backend-emit-unop
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [op : CompilerIrUnOp]
  [src : CompilerIrValue]
  [ty : AstType]) : ResultCompilerBackend
  (if (compiler-backend-f64-type? ty)
    (match (compiler-backend-emit-load-f64-value-with-plan
      assignments
      src
      "%xmm0")
      [(OkCompilerBackend src-asm)
        (match (compiler-backend-f64-unop-asm op)
          [(OkCompilerBackend op-asm)
            (OkCompilerBackend
              (string-append
                src-asm
                (string-append
                  op-asm
                  (compiler-backend-emit-store-f64-var-with-plan
                    assignments
                    dst
                    "%xmm0"))))]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
      [(ErrCompilerBackend message) (ErrCompilerBackend message)])
    (let
      [dst-home : String (compiler-backend-var-register-home assignments dst)]
      (if (string-eq dst-home "")
        (match (compiler-backend-emit-load-value-with-plan
          assignments
          src
          "%rax")
          [(OkCompilerBackend src-asm)
            (OkCompilerBackend
              (string-append
                src-asm
                (string-append
                  (compiler-backend-unop-asm op)
                  (compiler-backend-emit-store-var-with-plan
                    assignments
                    dst
                    "%rax"))))]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)])
        (match (compiler-backend-emit-load-value-with-plan
          assignments
          src
          dst-home)
          [(OkCompilerBackend src-asm)
            (OkCompilerBackend
              (string-append
                src-asm
                (compiler-backend-unop-reg-asm op dst-home)))]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)])))))

(define (compiler-backend-emit-addr-of
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [src : i64]) : ResultCompilerBackend
  (if (>= (compiler-backend-forwarded-addr-of-src dst) 0)
    (OkCompilerBackend "")
    (let
      [slot : String (compiler-backend-slot src)]
      (OkCompilerBackend
        (match (compiler-reg-assignment-lookup assignments dst)
          [(CompilerRegSomeLocation location)
            (match location
              [(CompilerRegRegister home)
                (str-cat "    leaq " slot ", " home "\n")]
              [(CompilerRegRegisterPair home _)
                (str-cat "    leaq " slot ", " home "\n")]
              [(CompilerRegSpill offset)
                (string-append
                  (str-cat "    leaq " slot ", " "%rax" "\n")
                  (str-cat
                    "    movq %rax, "
                    (compiler-backend-frame-offset offset)
                    "\n"
                    ""
                    ""))])]
          [(CompilerRegNoLocation)
            (string-append
              (str-cat "    leaq " slot ", " "%rax" "\n")
              (compiler-backend-emit-store-var-with-plan assignments dst "%rax"))])))))

(define (compiler-backend-gep-index-asm [scale : i64]) : String
  (if (= scale 1)
    "    addq %r8, %rax\n"
    (if (or (= scale 2) (= scale 4) (= scale 8))
      (str-cat "    leaq (%rax,%r8," (int->string scale) "), %rax\n" "")
      (string-append
        (str-cat "    imulq $" (int->string scale) ", " "%r8" "\n")
        "    addq %r8, %rax\n"))))

(define (compiler-backend-gep-index-r10-asm [scale : i64]) : String
  (if (= scale 1)
    "    addq %r8, %r10\n"
    (if (or (= scale 2) (= scale 4) (= scale 8))
      (str-cat "    leaq (%r10,%r8," (int->string scale) "), %r10\n" "")
      (string-append
        (str-cat "    imulq $" (int->string scale) ", " "%r8" "\n")
        "    addq %r8, %r10\n"))))

(define (compiler-backend-gep-index-address-r10 [scale : i64]) : String
  (if (or (= scale 1) (= scale 2) (= scale 4) (= scale 8))
    (str-cat "(%r10,%r8," (int->string scale) ")" "")
    ""))

(define (compiler-backend-gep-index-address [base-reg : String] [scale : i64]) : String
  (if (or (= scale 1) (= scale 2) (= scale 4) (= scale 8))
    (str-cat "(" base-reg ",%r8," (int->string scale) ")")
    ""))

(define (compiler-backend-gep-immediate-asm [disp : i64]) : CompilerBackendMaybeAsm
  (if (= disp 0)
    (CompilerBackendSomeAsm "")
    (if (compiler-backend-imm32? disp)
      (CompilerBackendSomeAsm
        (str-cat "    addq $" (int->string disp) ", %rax\n" ""))
      (CompilerBackendNoAsm))))

(define (compiler-backend-gep-immediate-r10-asm [disp : i64]) : CompilerBackendMaybeAsm
  (if (= disp 0)
    (CompilerBackendSomeAsm "")
    (if (compiler-backend-imm32? disp)
      (CompilerBackendSomeAsm
        (str-cat "    addq $" (int->string disp) ", %r10\n" ""))
      (CompilerBackendNoAsm))))

(define (compiler-backend-emit-gep
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [base : CompilerIrValue]
  [offset : CompilerIrValue]
  [elem-ty : AstType]) : ResultCompilerBackend
  (match (compiler-backend-emit-load-value-with-plan assignments base "%rax")
    [(OkCompilerBackend base-asm)
      (let
        [scale : i64 (compiler-backend-type-size elem-ty)]
        (match (compiler-backend-value-as-i64 offset)
          [(CompilerBackendSomeI64 n)
            (match (compiler-backend-gep-immediate-asm (* n scale))
              [(CompilerBackendSomeAsm offset-asm)
                (OkCompilerBackend
                  (string-append
                    base-asm
                    (string-append
                      offset-asm
                      (compiler-backend-emit-store-var-with-plan
                        assignments
                        dst
                        "%rax"))))]
              [(CompilerBackendNoAsm)
                (match (compiler-backend-emit-load-value-with-plan
                  assignments
                  offset
                  "%r8")
                  [(OkCompilerBackend offset-asm)
                    (OkCompilerBackend
                      (string-append
                        base-asm
                        (string-append
                          offset-asm
                          (string-append
                            (compiler-backend-gep-index-asm scale)
                            (compiler-backend-emit-store-var-with-plan
                              assignments
                              dst
                              "%rax")))))]
                  [(ErrCompilerBackend message) (ErrCompilerBackend message)])])]
          [(CompilerBackendNoI64)
            (match (compiler-backend-emit-load-value-with-plan
              assignments
              offset
              "%r8")
              [(OkCompilerBackend offset-asm)
                (OkCompilerBackend
                  (string-append
                    base-asm
                    (string-append
                      offset-asm
                      (string-append
                        (compiler-backend-gep-index-asm scale)
                        (compiler-backend-emit-store-var-with-plan
                          assignments
                          dst
                          "%rax")))))]
              [(ErrCompilerBackend message) (ErrCompilerBackend message)])]))]
    [(ErrCompilerBackend message) (ErrCompilerBackend message)]))

(define (compiler-backend-emit-load-instr
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [src : CompilerIrValue]
  [ty : AstType]) : ResultCompilerBackend
  (match (compiler-backend-emit-load-value-with-plan assignments src "%r10")
    [(OkCompilerBackend ptr-asm)
      (OkCompilerBackend
        (if (compiler-backend-float-type? ty)
          (string-append
            ptr-asm
            (string-append
              (compiler-backend-emit-load-float-memory "(%r10)" "%xmm0" ty)
              (compiler-backend-emit-store-float-var-with-plan
                assignments
                dst
                "%xmm0"
                ty)))
          (string-append
            ptr-asm
            (string-append
              (compiler-backend-emit-load-memory "(%r10)" ty)
              (compiler-backend-emit-store-var-with-plan assignments dst "%rax")))))]
    [(ErrCompilerBackend message) (ErrCompilerBackend message)]))

(define (compiler-backend-r10-address [disp : i64]) : String
  (if (= disp 0)
    "(%r10)"
    (str-cat (int->string disp) "(%r10)" "" "")))

(define (compiler-backend-copy-address [disp : i64] [reg : String]) : String
  (if (= disp 0)
    (str-cat "(" reg ")" "")
    (str-cat (int->string disp) "(" reg ")")))

(define (compiler-backend-copy-chunk-size [remaining : i64]) : i64
  (cond [(>= remaining 8) 8] [(>= remaining 4) 4] [(>= remaining 2) 2] [else 1]))

(define (compiler-backend-copy-chunk-type [chunk : i64]) : AstType
  (cond
    [(= chunk 8) (AstTyU64)]
    [(= chunk 4) (AstTyU32)]
    [(= chunk 2) (AstTyU16)]
    [else (AstTyU8)]))

(define (compiler-backend-emit-copy-bytes-chunks
  [dst-reg : String]
  [src-reg : String]
  [offset : i64]
  [remaining : i64]) : String
  (if (<= remaining 0)
    ""
    (if (>= remaining 16)
      ;; 16-byte chunks through %xmm15 (the per-instruction float scratch, see
      ;; the stack-passed-arg path): movups tolerates the 8-byte alignment of
      ;; inline aggregates and halves the instruction count of large copies
      ;; versus unrolled 8-byte mov pairs (#2371).
      (string-append
        (str-cat
          "    movups "
          (compiler-backend-copy-address offset src-reg)
          ", %xmm15\n"
          "")
        (string-append
          (str-cat
            "    movups %xmm15, "
            (compiler-backend-copy-address offset dst-reg)
            "\n"
            "")
          (compiler-backend-emit-copy-bytes-chunks
            dst-reg
            src-reg
            (+ offset 16)
            (- remaining 16))))
      (let
        [chunk : i64 (compiler-backend-copy-chunk-size remaining)]
        [chunk-ty : AstType (compiler-backend-copy-chunk-type chunk)]
        [reg : String (compiler-backend-sized-reg "%rax" chunk-ty)]
        (string-append
          (str-cat
            "    mov"
            (compiler-backend-int-instruction-suffix chunk-ty)
            " "
            (compiler-backend-copy-address offset src-reg)
            ", ")
          (string-append
            reg
            (string-append
              "\n"
              (string-append
                (str-cat
                  "    mov"
                  (compiler-backend-int-instruction-suffix chunk-ty)
                  " "
                  reg
                  ", ")
                (string-append
                  (compiler-backend-copy-address offset dst-reg)
                  (string-append
                    "\n"
                    (compiler-backend-emit-copy-bytes-chunks
                      dst-reg
                      src-reg
                      (+ offset chunk)
                      (- remaining chunk))))))))))))

(define (compiler-backend-emit-copy-bytes
  [assignments : CompilerRegAssignmentList]
  [dst : CompilerIrValue]
  [src : CompilerIrValue]
  [size : i64]) : ResultCompilerBackend
  (if (<= size 0)
    (OkCompilerBackend "")
    (let
      [dst-home : String (compiler-backend-value-register-home assignments dst)]
      [dst-reg : String
        (if (string-eq dst-home "")
          "%r10"
          dst-home)]
      (match (if (string-eq dst-home "")
        (compiler-backend-emit-load-value-with-plan assignments dst "%r10")
        (OkCompilerBackend ""))
        [(OkCompilerBackend dst-asm)
          (let
            [src-home : String
              (compiler-backend-value-register-home assignments src)]
            [src-reg : String
              (if (string-eq src-home "")
                "%r11"
                src-home)]
            (match (if (string-eq src-home "")
              (compiler-backend-emit-load-value-with-plan
                assignments
                src
                "%r11")
              (OkCompilerBackend ""))
              [(OkCompilerBackend src-asm)
                (OkCompilerBackend
                  (string-append
                    dst-asm
                    (string-append
                      src-asm
                      (compiler-backend-emit-copy-bytes-chunks
                        dst-reg
                        src-reg
                        0
                        size))))]
              [(ErrCompilerBackend message) (ErrCompilerBackend message)]))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)]))))

(define (compiler-backend-emit-copy-bytes-from-gep
  [assignments : CompilerRegAssignmentList]
  [base : CompilerIrValue]
  [offset : CompilerIrValue]
  [elem-ty : AstType]
  [src : CompilerIrValue]
  [size : i64]) : ResultCompilerBackend
  (if (<= size 0)
    (OkCompilerBackend "")
    (match (compiler-backend-emit-load-value-with-plan assignments base "%r10")
      [(OkCompilerBackend base-asm)
        (let
          [scale : i64 (compiler-backend-type-size elem-ty)]
          (match (compiler-backend-value-as-i64 offset)
            [(CompilerBackendSomeI64 n)
              (match (compiler-backend-gep-immediate-r10-asm (* n scale))
                [(CompilerBackendSomeAsm offset-asm)
                  (match (compiler-backend-emit-load-value-with-plan
                    assignments
                    src
                    "%r11")
                    [(OkCompilerBackend src-asm)
                      (OkCompilerBackend
                        (string-append
                          base-asm
                          (string-append
                            offset-asm
                            (string-append
                              src-asm
                              (compiler-backend-emit-copy-bytes-chunks
                                "%r10"
                                "%r11"
                                0
                                size)))))]
                    [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
                [(CompilerBackendNoAsm)
                  (ErrCompilerBackend
                    (compiler-diagnostic-at-start
                      ""
                      "backend: fused gep copy displacement out of range"))])]
            [(CompilerBackendNoI64)
              (match (compiler-backend-emit-load-value-with-plan
                assignments
                offset
                "%r8")
                [(OkCompilerBackend offset-asm)
                  (match (compiler-backend-emit-load-value-with-plan
                    assignments
                    src
                    "%r11")
                    [(OkCompilerBackend src-asm)
                      (OkCompilerBackend
                        (string-append
                          base-asm
                          (string-append
                            offset-asm
                            (string-append
                              (compiler-backend-gep-index-r10-asm scale)
                              (string-append
                                src-asm
                                (compiler-backend-emit-copy-bytes-chunks
                                  "%r10"
                                  "%r11"
                                  0
                                  size))))))]
                    [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
                [(ErrCompilerBackend message) (ErrCompilerBackend message)])]))]
      [(ErrCompilerBackend message) (ErrCompilerBackend message)])))

(define (compiler-backend-emit-c-memory-stack-arg
  [target : CompilerBackendTarget]
  [assignments : CompilerRegAssignmentList]
  [value : CompilerIrValue]
  [stack-idx : i64]
  [size : i64]) : ResultCompilerBackend
  (match (compiler-backend-emit-load-value-with-plan assignments value "%r11")
    [(OkCompilerBackend src-asm)
      (OkCompilerBackend
        (string-append
          src-asm
          (string-append
            (str-cat
              "    leaq "
              (int->string
                (compiler-backend-outgoing-stack-arg-offset target stack-idx))
              "(%rsp), %r10\n")
            (compiler-backend-emit-copy-bytes-chunks "%r10" "%r11" 0 size))))]
    [(ErrCompilerBackend message) (ErrCompilerBackend message)]))

(define (compiler-backend-emit-load-from-gep
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [base : CompilerIrValue]
  [offset : CompilerIrValue]
  [elem-ty : AstType]
  [load-ty : AstType]) : ResultCompilerBackend
  (match (compiler-backend-value-as-i64 offset)
    [(CompilerBackendSomeI64 n)
      (let
        [disp : i64 (* n (compiler-backend-type-size elem-ty))]
        [addr : String (compiler-backend-r10-address disp)]
        (match (compiler-backend-emit-load-value-with-plan
          assignments
          base
          "%r10")
          [(OkCompilerBackend base-asm)
            (OkCompilerBackend
              (if (compiler-backend-float-type? load-ty)
                (string-append
                  base-asm
                  (string-append
                    (compiler-backend-emit-load-float-memory
                      addr
                      "%xmm0"
                      load-ty)
                    (compiler-backend-emit-store-float-var-with-plan
                      assignments
                      dst
                      "%xmm0"
                      load-ty)))
                (string-append
                  base-asm
                  (string-append
                    (compiler-backend-emit-load-memory addr load-ty)
                    (compiler-backend-emit-store-var-with-plan
                      assignments
                      dst
                      "%rax")))))]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)]))]
    [(CompilerBackendNoI64)
      (let
        [scale : i64 (compiler-backend-type-size elem-ty)]
        [addr : String (compiler-backend-gep-index-address-r10 scale)]
        [addr-asm : String
          (if (string-eq addr "")
            (compiler-backend-gep-index-r10-asm scale)
            "")]
        [load-addr : String
          (if (string-eq addr "")
            "(%r10)"
            addr)]
        (match (compiler-backend-emit-load-value-with-plan
          assignments
          base
          "%r10")
          [(OkCompilerBackend base-asm)
            (match (compiler-backend-emit-load-value-with-plan
              assignments
              offset
              "%r8")
              [(OkCompilerBackend offset-asm)
                (OkCompilerBackend
                  (if (compiler-backend-float-type? load-ty)
                    (string-append
                      base-asm
                      (string-append
                        offset-asm
                        (string-append
                          addr-asm
                          (string-append
                            (compiler-backend-emit-load-float-memory
                              load-addr
                              "%xmm0"
                              load-ty)
                            (compiler-backend-emit-store-float-var-with-plan
                              assignments
                              dst
                              "%xmm0"
                              load-ty)))))
                    (string-append
                      base-asm
                      (string-append
                        offset-asm
                        (string-append
                          addr-asm
                          (string-append
                            (compiler-backend-emit-load-memory
                              load-addr
                              load-ty)
                            (compiler-backend-emit-store-var-with-plan
                              assignments
                              dst
                              "%rax")))))))]
              [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)]))]))

(define (compiler-backend-emit-load-from-gep-r10-live
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [offset : CompilerIrValue]
  [elem-ty : AstType]
  [load-ty : AstType]) : ResultCompilerBackend
  (match (compiler-backend-value-as-i64 offset)
    [(CompilerBackendSomeI64 n)
      (let
        [disp : i64 (* n (compiler-backend-type-size elem-ty))]
        [addr : String (compiler-backend-r10-address disp)]
        (OkCompilerBackend
          (if (compiler-backend-float-type? load-ty)
            (string-append
              (compiler-backend-emit-load-float-memory addr "%xmm0" load-ty)
              (compiler-backend-emit-store-float-var-with-plan
                assignments
                dst
                "%xmm0"
                load-ty))
            (string-append
              (compiler-backend-emit-load-memory addr load-ty)
              (compiler-backend-emit-store-var-with-plan assignments dst "%rax")))))]
    [(CompilerBackendNoI64)
      (ErrCompilerBackend
        (compiler-diagnostic-at-start
          ""
          "backend: non-immediate r10-live gep load"))]))

(define (compiler-backend-emit-load-from-gep-pair
  [assignments : CompilerRegAssignmentList]
  [base : CompilerIrValue]
  [offset0 : CompilerIrValue]
  [elem-ty0 : AstType]
  [load-dst0 : i64]
  [load-ty0 : AstType]
  [offset1 : CompilerIrValue]
  [elem-ty1 : AstType]
  [load-dst1 : i64]
  [load-ty1 : AstType]) : ResultCompilerBackend
  (match (compiler-backend-emit-load-from-gep
    assignments
    load-dst0
    base
    offset0
    elem-ty0
    load-ty0)
    [(OkCompilerBackend first-asm)
      (match (compiler-backend-emit-load-from-gep-r10-live
        assignments
        load-dst1
        offset1
        elem-ty1
        load-ty1)
        [(OkCompilerBackend second-asm)
          (OkCompilerBackend (string-append first-asm second-asm))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
    [(ErrCompilerBackend message) (ErrCompilerBackend message)]))

(define (compiler-backend-emit-load-load
  [assignments : CompilerRegAssignmentList]
  [first-dst : i64]
  [ptr : CompilerIrValue]
  [first-ty : AstType]
  [second-dst : i64]
  [second-ty : AstType]) : ResultCompilerBackend
  (let
    [_first-dst : i64 first-dst]
    (if (= (compiler-backend-type-size first-ty) 8)
      (match (compiler-backend-emit-load-value-with-plan assignments ptr "%r10")
        [(OkCompilerBackend ptr-asm)
          (OkCompilerBackend
            (string-append
              ptr-asm
              (string-append
                "    movq (%r10), %r10\n"
                (if (compiler-backend-float-type? second-ty)
                  (string-append
                    (compiler-backend-emit-load-float-memory
                      "(%r10)"
                      "%xmm0"
                      second-ty)
                    (compiler-backend-emit-store-float-var-with-plan
                      assignments
                      second-dst
                      "%xmm0"
                      second-ty))
                  (string-append
                    (compiler-backend-emit-load-memory "(%r10)" second-ty)
                    (compiler-backend-emit-store-var-with-plan
                      assignments
                      second-dst
                      "%rax"))))))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])
      (compiler-backend-emit-load-instr assignments first-dst ptr first-ty))))

(define (compiler-backend-emit-store-value-to-address
  [assignments : CompilerRegAssignmentList]
  [src : CompilerIrValue]
  [ty : AstType]
  [addr : String]
  [program-index : CompilerBackendProgramIndex]) : ResultCompilerBackend
  (match (compiler-backend-emit-store-immediate-to-memory src addr ty)
    [(CompilerBackendSomeAsm store-asm) (OkCompilerBackend store-asm)]
    [(CompilerBackendNoAsm)
      (match (compiler-backend-emit-load-typed-value-with-plan
        assignments
        src
        ty
        program-index)
        [(OkCompilerBackend src-asm)
          (OkCompilerBackend
            (string-append
              src-asm
              (if (compiler-backend-float-type? ty)
                (compiler-backend-emit-store-xmm-to-memory addr "%xmm0" ty)
                (compiler-backend-emit-store-rax-to-memory addr ty))))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]))

(define (compiler-backend-emit-store-ptr
  [assignments : CompilerRegAssignmentList]
  [dst : CompilerIrValue]
  [src : CompilerIrValue]
  [ty : AstType]
  [program-index : CompilerBackendProgramIndex]) : ResultCompilerBackend
  (match (compiler-backend-emit-address-base assignments dst "%r10")
    [(OkCompilerBackendAddressBase base)
      (let
        [ptr-asm : String (struct-get base asm)]
        [addr : String (compiler-backend-copy-address 0 (struct-get base reg))]
        (match (compiler-backend-emit-store-value-to-address
          assignments
          src
          ty
          addr
          program-index)
          [(OkCompilerBackend store-asm)
            (OkCompilerBackend (string-append ptr-asm store-asm))]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)]))]
    [(ErrCompilerBackendAddressBase message) (ErrCompilerBackend message)]))

(define (compiler-backend-emit-store-to-gep
  [assignments : CompilerRegAssignmentList]
  [base : CompilerIrValue]
  [offset : CompilerIrValue]
  [elem-ty : AstType]
  [value : CompilerIrValue]
  [store-ty : AstType]
  [program-index : CompilerBackendProgramIndex]) : ResultCompilerBackend
  (match (compiler-backend-value-as-i64 offset)
    [(CompilerBackendSomeI64 n)
      (let
        [disp : i64 (* n (compiler-backend-type-size elem-ty))]
        (match (compiler-backend-emit-address-base assignments base "%r10")
          [(OkCompilerBackendAddressBase base-plan)
            (let
              [base-asm : String (struct-get base-plan asm)]
              [addr : String
                (compiler-backend-copy-address disp (struct-get base-plan reg))]
              (match (compiler-backend-emit-store-value-to-address
                assignments
                value
                store-ty
                addr
                program-index)
                [(OkCompilerBackend store-asm)
                  (OkCompilerBackend (string-append base-asm store-asm))]
                [(ErrCompilerBackend message) (ErrCompilerBackend message)]))]
          [(ErrCompilerBackendAddressBase message) (ErrCompilerBackend message)]))]
    [(CompilerBackendNoI64)
      (let
        [scale : i64 (compiler-backend-type-size elem-ty)]
        (match (compiler-backend-emit-address-base-with-avoid
          assignments
          base
          "%r10"
          "%r8")
          [(OkCompilerBackendAddressBase base-plan)
            (match (compiler-backend-emit-load-value-with-plan
              assignments
              offset
              "%r8")
              [(OkCompilerBackend offset-asm)
                (let
                  [base-reg : String (struct-get base-plan reg)]
                  [addr : String
                    (compiler-backend-gep-index-address base-reg scale)]
                  [addr-asm : String
                    (if (string-eq addr "")
                      (string-append
                        (if (string-eq base-reg "%r10")
                          ""
                          (str-cat "    movq " base-reg ", " "%r10" "\n"))
                        (compiler-backend-gep-index-r10-asm scale))
                      "")]
                  [store-addr : String
                    (if (string-eq addr "")
                      "(%r10)"
                      addr)]
                  (match (compiler-backend-emit-store-value-to-address
                    assignments
                    value
                    store-ty
                    store-addr
                    program-index)
                    [(OkCompilerBackend store-asm)
                      (OkCompilerBackend
                        (string-append
                          (struct-get base-plan asm)
                          (string-append
                            offset-asm
                            (string-append addr-asm store-asm))))]
                    [(ErrCompilerBackend message) (ErrCompilerBackend message)]))]
              [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
          [(ErrCompilerBackendAddressBase message) (ErrCompilerBackend message)]))]))

(define (compiler-backend-emit-store-ptr-pair
  [assignments : CompilerRegAssignmentList]
  [ptr : CompilerIrValue]
  [value0 : CompilerIrValue]
  [ty0 : AstType]
  [disp : i64]
  [value1 : CompilerIrValue]
  [ty1 : AstType]
  [program-index : CompilerBackendProgramIndex]) : ResultCompilerBackend
  (match (compiler-backend-emit-address-base assignments ptr "%r10")
    [(OkCompilerBackendAddressBase base-plan)
      (let
        [base-asm : String (struct-get base-plan asm)]
        [base-reg : String (struct-get base-plan reg)]
        [addr0 : String (compiler-backend-copy-address 0 base-reg)]
        [addr1 : String (compiler-backend-copy-address disp base-reg)]
        (match (compiler-backend-emit-store-value-to-address
          assignments
          value0
          ty0
          addr0
          program-index)
          [(OkCompilerBackend store0)
            (match (compiler-backend-emit-store-value-to-address
              assignments
              value1
              ty1
              addr1
              program-index)
              [(OkCompilerBackend store1)
                (OkCompilerBackend
                  (string-append base-asm (string-append store0 store1)))]
              [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)]))]
    [(ErrCompilerBackendAddressBase message) (ErrCompilerBackend message)]))

(define (compiler-backend-float-precision-cast-asm
  [from-ty : AstType]
  [to-ty : AstType]) : String
  (match from-ty
    [(AstTyF64)
      (match to-ty
        [(AstTyF32) "    cvtsd2ss %xmm0, %xmm0\n"]
        [_ ""])]
    [(AstTyF32)
      (match to-ty
        [(AstTyF64) "    cvtss2sd %xmm0, %xmm0\n"]
        [_ ""])]
    [_ ""]))

(define (compiler-backend-int-to-float-cast-asm [to-ty : AstType]) : String
  (match to-ty
    [(AstTyF32) "    cvtsi2ssq %rax, %xmm0\n"]
    [_ "    cvtsi2sdq %rax, %xmm0\n"]))

(define (compiler-backend-u64-to-float-cast-op [to-ty : AstType]) : String
  (match to-ty
    [(AstTyF32) "ss"]
    [_ "sd"]))

(define (compiler-backend-u64-to-float-cast-label
  [current-label : String]
  [dst : i64]
  [suffix : String]) : String
  (str-cat "cast_u64_float_" current-label "_v" (int->string dst) suffix))

(define (compiler-backend-u64-to-float-cast-asm
  [function : String]
  [current-label : String]
  [dst : i64]
  [to-ty : AstType]) : String
  (let
    [op : String (compiler-backend-u64-to-float-cast-op to-ty)]
    [high-label : String
      (compiler-backend-u64-to-float-cast-label current-label dst "_high")]
    [done-label : String
      (compiler-backend-u64-to-float-cast-label current-label dst "_done")]
    [high-symbol : String (compiler-backend-asm-label function high-label)]
    [done-symbol : String (compiler-backend-asm-label function done-label)]
    (string-append
      "    testq %rax, %rax\n"
      (string-append
        (str-cat "    js " high-symbol "\n    cvtsi2" op "q %rax, %xmm0\n")
        (string-append
          (str-cat "    jmp " done-symbol "\n")
          (string-append
            (str-cat high-symbol ":\n" "")
            (string-append
              "    movq %rax, %r11\n    andq $1, %r11\n    shrq $1, %rax\n    orq %r11, %rax\n"
              (string-append
                (str-cat
                  "    cvtsi2"
                  op
                  "q %rax, %xmm0\n    add"
                  op
                  " %xmm0, %xmm0\n")
                (str-cat done-symbol ":\n" "")))))))))

(define (compiler-backend-float-to-int-cast-asm [from-ty : AstType]) : String
  (match from-ty
    [(AstTyF32) "    cvttss2siq %xmm0, %rax\n"]
    [_ "    cvttsd2siq %xmm0, %rax\n"]))

(define (compiler-backend-emit-float-to-float-cast
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [src : CompilerIrValue]
  [from-ty : AstType]
  [to-ty : AstType]) : ResultCompilerBackend
  (match (compiler-backend-emit-load-float-value-with-plan
    assignments
    src
    from-ty
    "%xmm0")
    [(OkCompilerBackend load)
      (OkCompilerBackend
        (string-append
          load
          (string-append
            (compiler-backend-float-precision-cast-asm from-ty to-ty)
            (compiler-backend-emit-store-float-var-with-plan
              assignments
              dst
              "%xmm0"
              to-ty))))]
    [(ErrCompilerBackend message) (ErrCompilerBackend message)]))

(define (compiler-backend-emit-int-to-float-cast
  [function : String]
  [current-label : String]
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [src : CompilerIrValue]
  [from-ty : AstType]
  [to-ty : AstType]
  [program-index : CompilerBackendProgramIndex]) : ResultCompilerBackend
  (match (compiler-backend-emit-load-typed-value-with-plan
    assignments
    src
    from-ty
    program-index)
    [(OkCompilerBackend load)
      (OkCompilerBackend
        (string-append
          load
          (string-append
            (match from-ty
              [(AstTyU64)
                (compiler-backend-u64-to-float-cast-asm
                  function
                  current-label
                  dst
                  to-ty)]
              [_ (compiler-backend-int-to-float-cast-asm to-ty)])
            (compiler-backend-emit-store-float-var-with-plan
              assignments
              dst
              "%xmm0"
              to-ty))))]
    [(ErrCompilerBackend message) (ErrCompilerBackend message)]))

(define (compiler-backend-emit-float-to-int-cast
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [src : CompilerIrValue]
  [from-ty : AstType]
  [to-ty : AstType]) : ResultCompilerBackend
  (match (compiler-backend-emit-load-float-value-with-plan
    assignments
    src
    from-ty
    "%xmm0")
    [(OkCompilerBackend load)
      (OkCompilerBackend
        (string-append
          load
          (string-append
            (compiler-backend-float-to-int-cast-asm from-ty)
            (compiler-backend-emit-store-typed-var-with-plan
              assignments
              dst
              "%rax"
              to-ty))))]
    [(ErrCompilerBackend message) (ErrCompilerBackend message)]))

(define (compiler-backend-emit-cast
  [function : String]
  [current-label : String]
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [src : CompilerIrValue]
  [from-ty : AstType]
  [to-ty : AstType]
  [program-index : CompilerBackendProgramIndex]) : ResultCompilerBackend
  (if (and
    (opt-type-eq from-ty to-ty)
    (compiler-backend-value-same-home? assignments dst src))
    (OkCompilerBackend "")
    (let
      [from-is-float : bool (compiler-backend-float-type? from-ty)]
      [to-is-float : bool (compiler-backend-float-type? to-ty)]
      (cond
        [(and from-is-float to-is-float)
          (compiler-backend-emit-float-to-float-cast
            assignments
            dst
            src
            from-ty
            to-ty)]
        [(and (not from-is-float) to-is-float)
          (compiler-backend-emit-int-to-float-cast
            function
            current-label
            assignments
            dst
            src
            from-ty
            to-ty
            program-index)]
        [(and from-is-float (not to-is-float))
          (compiler-backend-emit-float-to-int-cast
            assignments
            dst
            src
            from-ty
            to-ty)]
        [else
          (let
            [dst-home : String
              (compiler-backend-var-register-home assignments dst)]
            [from-size : i64 (compiler-backend-type-size from-ty)]
            [to-size : i64 (compiler-backend-type-size to-ty)]
            (if (if (string-eq dst-home "")
              false
              (and
                (compiler-backend-intlike-scalar-type? from-ty)
                (compiler-backend-intlike-scalar-type? to-ty)
                (< from-size to-size)
                (< from-size 8)))
              (match src
                [(IrValueVar src-id)
                  ;; #2981: widening int/char/bool casts can extend straight
                  ;; into the destination register home. This preserves the
                  ;; typed sign/zero-extension load while skipping the
                  ;; %rax store round-trip.
                  (OkCompilerBackend
                    (compiler-backend-emit-load-typed-var-to-reg-with-plan
                      assignments
                      src-id
                      from-ty
                      dst-home))]
                [_
                  (match (compiler-backend-emit-load-typed-value-with-plan
                    assignments
                    src
                    from-ty
                    program-index)
                    [(OkCompilerBackend load)
                      (OkCompilerBackend
                        (string-append
                          load
                          (compiler-backend-emit-store-typed-var-with-plan
                            assignments
                            dst
                            (if to-is-float
                              "%xmm0"
                              "%rax")
                            to-ty)))]
                    [(ErrCompilerBackend message) (ErrCompilerBackend message)])])
              (if (if (string-eq dst-home "")
                false
                (= from-size to-size))
                ;; #2981: a same-width int/char cast only reinterprets
                ;; signedness; it needs neither extension nor narrowing, so
                ;; copy the source straight into the destination register
                ;; home (which holds the full normalized 64-bit value),
                ;; skipping the %rax round-trip. Width-changing casts keep
                ;; the typed load+store below so sign/zero extension is
                ;; applied.
                (compiler-backend-emit-load-value-with-plan
                  assignments
                  src
                  dst-home)
                (match (compiler-backend-emit-load-typed-value-with-plan
                  assignments
                  src
                  from-ty
                  program-index)
                  [(OkCompilerBackend load)
                    (OkCompilerBackend
                      (string-append
                        load
                        (compiler-backend-emit-store-typed-var-with-plan
                          assignments
                          dst
                          (if to-is-float
                            "%xmm0"
                            "%rax")
                          to-ty)))]
                  [(ErrCompilerBackend message) (ErrCompilerBackend message)]))))]))))

(define (compiler-backend-bitcast-width [ty : AstType]) : i64
  (match ty
    [(AstTyF32) 4]
    [(AstTyI32) 4]
    [(AstTyU32) 4]
    [(AstTyF64) 8]
    [(AstTyI64) 8]
    [(AstTyU64) 8]
    [_ 0]))

(define (compiler-backend-bitcast-int-type? [ty : AstType]) : bool
  (match ty
    [(AstTyI32) true]
    [(AstTyU32) true]
    [(AstTyI64) true]
    [(AstTyU64) true]
    [_ false]))

(define (compiler-backend-float-to-int-bitcast-asm [from-ty : AstType]) : String
  (match from-ty
    [(AstTyF32) "    movd %xmm0, %eax\n"]
    [_ "    movq %xmm0, %rax\n"]))

(define (compiler-backend-int-to-float-bitcast-asm [to-ty : AstType]) : String
  (match to-ty
    [(AstTyF32) "    movd %eax, %xmm0\n"]
    [_ "    movq %rax, %xmm0\n"]))

(define (compiler-backend-bitcast-compatible?
  [_from-ty : AstType]
  [_to-ty : AstType]
  [from-width : i64]
  [to-width : i64]
  [from-float : bool]
  [to-float : bool]
  [from-int : bool]
  [to-int : bool]) : bool
  (or
    (= from-width to-width)
    (and from-float to-int (= from-width 4) (= to-width 8))
    (and from-int to-float (= from-width 8) (= to-width 4))))

(define (compiler-backend-emit-bitcast
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [src : CompilerIrValue]
  [from-ty : AstType]
  [to-ty : AstType]
  [program-index : CompilerBackendProgramIndex]) : ResultCompilerBackend
  (let
    [from-width : i64 (compiler-backend-bitcast-width from-ty)]
    [to-width : i64 (compiler-backend-bitcast-width to-ty)]
    [from-float : bool (compiler-backend-float-type? from-ty)]
    [to-float : bool (compiler-backend-float-type? to-ty)]
    [from-int : bool (compiler-backend-bitcast-int-type? from-ty)]
    [to-int : bool (compiler-backend-bitcast-int-type? to-ty)]
    (cond
      [(or
          (= from-width 0)
          (= to-width 0)
          (not
            (compiler-backend-bitcast-compatible?
              from-ty
              to-ty
              from-width
              to-width
              from-float
              to-float
              from-int
              to-int)))
        (ErrCompilerBackend
          (compiler-diagnostic-at-start "" "backend: unsupported bitcast width"))]
      [(and from-float to-int)
        (match (compiler-backend-emit-load-float-value-with-plan
          assignments
          src
          from-ty
          "%xmm0")
          [(OkCompilerBackend load)
            (OkCompilerBackend
              (string-append
                load
                (string-append
                  (compiler-backend-float-to-int-bitcast-asm from-ty)
                  (compiler-backend-emit-store-typed-var-with-plan
                    assignments
                    dst
                    "%rax"
                    to-ty))))]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
      [(and from-int to-float)
        (match (compiler-backend-emit-load-typed-value-with-plan
          assignments
          src
          from-ty
          program-index)
          [(OkCompilerBackend load)
            (OkCompilerBackend
              (string-append
                load
                (string-append
                  (compiler-backend-int-to-float-bitcast-asm to-ty)
                  (compiler-backend-emit-store-float-var-with-plan
                    assignments
                    dst
                    "%xmm0"
                    to-ty))))]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
      [(and from-int to-int)
        (match (compiler-backend-emit-load-typed-value-with-plan
          assignments
          src
          from-ty
          program-index)
          [(OkCompilerBackend load)
            (OkCompilerBackend
              (string-append
                load
                (compiler-backend-emit-store-typed-var-with-plan
                  assignments
                  dst
                  "%rax"
                  to-ty)))]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
      [(and from-float to-float)
        (match (compiler-backend-emit-load-float-value-with-plan
          assignments
          src
          from-ty
          "%xmm0")
          [(OkCompilerBackend load)
            (OkCompilerBackend
              (string-append
                load
                (compiler-backend-emit-store-float-var-with-plan
                  assignments
                  dst
                  "%xmm0"
                  to-ty)))]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
      [else
        (ErrCompilerBackend
          (compiler-diagnostic-at-start "" "backend: unsupported bitcast type"))])))

(define (compiler-backend-ir-value-list-count [args : CompilerIrValueList]) : i64
  (match args
    [(IrValueNil) 0]
    [(IrValueCons _ rest)
      (+ 1 (compiler-backend-ir-value-list-count (box-get rest)))]))

(define (compiler-backend-call-args-count [args : CompilerIrCallArgs]) : i64
  (match args
    [(IrCallArgsNil) 0]
    [(IrCallArgsOne _) 1]
    [(IrCallArgsTwo _ _) 2]
    [(IrCallArgsArray values) (array-length values)]))

(define (compiler-backend-call-arg-at [args : CompilerIrCallArgs] [index : i64]) : CompilerIrValue
  (match args
    [(IrCallArgsNil) (IrValueUnit)]
    [(IrCallArgsOne value)
      (if (= index 0)
        value
        (IrValueUnit))]
    [(IrCallArgsTwo a b)
      (if (= index 0)
        a
        (if (= index 1)
          b
          (IrValueUnit)))]
    [(IrCallArgsArray values) (array-ref values index)]))

(define (compiler-backend-fast-alloc-size [args : CompilerIrCallArgs]) : i64
  (match args
    [(IrCallArgsOne (IrValueI64 size))
      (if (or (<= size 0) (> size 64))
        0
        (* (/ (+ size 7) 8) 8))]
    [_ 0]))

(define (compiler-backend-fast-alloc-label [size : i64]) : String
  (str-cat ".L_tl_alloc" (int->string size) "" ""))

(define (compiler-backend-inline-fast-alloc? [size : i64]) : bool
  (= size 16))

(define (compiler-backend-fast-alloc-site-label
  [function : String]
  [current-label : String]
  [dst : i64]
  [suffix : String]) : String
  (compiler-backend-asm-label
    function
    (str-cat "alloc" current-label "_v" (int->string dst) suffix)))

(define (compiler-backend-emit-inline-fast-alloc
  [target : CompilerBackendTarget]
  [function : String]
  [current-label : String]
  [dst : i64]
  [size : i64]
  [profile : bool]) : String
  (let
    [size-text : String (int->string size)]
    [slow-label : String
      (compiler-backend-fast-alloc-site-label
        function
        current-label
        dst
        "_slow")]
    [done-label : String
      (compiler-backend-fast-alloc-site-label
        function
        current-label
        dst
        "_done")]
    [profile-label : String
      (compiler-backend-fast-alloc-site-label
        function
        current-label
        dst
        "_profile_done")]
    [next-reg : String
      (if (compiler-backend-target-windows? target)
        "%r10"
        "%rcx")]
    (string-append
      (string-append
        (compiler-backend-current-arena-load target "%r8")
        (str-cat
          "    testq %r8, %r8\n    jz "
          slow-label
          "\n    movq 16(%r8), %rax\n    movq %rax, "
          next-reg
          "\n"))
      (string-append
        (str-cat "    addq $" size-text ", " next-reg "\n")
        (string-append
          (str-cat "    jc " slow-label "\n    cmpq 24(%r8), " next-reg "\n")
          (string-append
            (str-cat "    ja " slow-label "\n    movq " next-reg ", 16(%r8)\n")
            (string-append
              (compiler-backend-runtime-profile-alloc-account
                (string-append "$" size-text)
                profile-label
                profile)
              (string-append
                (str-cat "    jmp " done-label "\n" slow-label ":\n")
                (str-cat
                  "    call "
                  (compiler-backend-fast-alloc-label size)
                  "\n"
                  done-label
                  ":\n")))))))))

(define (compiler-backend-call-register-count [target : CompilerBackendTarget]) : i64
  (match target
    [(BackendTargetLinux) 6]
    [(BackendTargetWindows) 4]))

;; Number of f64 argument registers (#750). System V uses xmm0..xmm7 (8) and
;; Windows shares its 4 positional slots, so the float bank also tops out at 4.
(define (compiler-backend-call-float-register-count
  [target : CompilerBackendTarget]) : i64
  (match target
    [(BackendTargetLinux) 8]
    [(BackendTargetWindows) 4]))

(define (compiler-backend-emit-call-space-sub [space : i64]) : String
  (if (= space 0)
    ""
    (str-cat "    subq $" (int->string space) ", %rsp\n" "")))

(define (compiler-backend-emit-call-space-add [space : i64]) : String
  (if (= space 0)
    ""
    (str-cat "    addq $" (int->string space) ", %rsp\n" "")))

;; Whether the argument at the given bank indexes is passed on the stack
;; (#750). Windows shares one positional slot bank (`position`); System V keeps
;; the integer and float banks independent, so an arg spills only once its own
;; bank is exhausted (rdi..r9 / xmm0..xmm7).
(define (compiler-backend-stack-call-arg-for-banks?
  [target : CompilerBackendTarget]
  [is-float : bool]
  [int-idx : i64]
  [float-idx : i64]
  [position : i64]) : bool
  (match target
    [(BackendTargetWindows)
      (>= position (compiler-backend-call-register-count target))]
    [(BackendTargetLinux)
      (if is-float
        (>= float-idx (compiler-backend-call-float-register-count target))
        (>= int-idx (compiler-backend-call-register-count target)))]))

(define (compiler-backend-param-type-list [params : CompilerIrParamList]) : AstTypeList
  (match params
    [(IrParamNil) AstTypeNil]
    [(IrParamCons param rest)
      (match param
        [(IrParam _ ty _)
          (ast-type-cons ty (compiler-backend-param-type-list (box-get rest)))])]))

(define (compiler-backend-type-list-count [types : AstTypeList]) : i64
  (match types
    [(AstTypeNil) 0]
    [(AstTypeCons _ rest)
      (let
        [rest : AstTypeList (box-get rest)]
        (+ 1 (compiler-backend-type-list-count rest)))]))

(define (compiler-backend-param-list-from-types
  [types : AstTypeList]
  [idx : i64]) : CompilerIrParamList
  (match types
    [(AstTypeNil) IrParamNil]
    [(AstTypeCons ty rest)
      (let
        [ty : AstType (ty-node-get ty)]
        [rest : AstTypeList (box-get rest)]
        (compiler-ir-param-cons
          (IrParam (string-append "arg" (int->string idx)) ty idx)
          (compiler-backend-param-list-from-types rest (+ idx 1))))]))

(define (compiler-backend-var-value-list [count : i64] [idx : i64]) : CompilerIrValueList
  (if (>= idx count)
    IrValueNil
    (compiler-ir-value-cons
      (IrValueVar idx)
      (compiler-backend-var-value-list count (+ idx 1)))))

(define (compiler-backend-function-param-types
  [functions : CompilerIrFunctionList]
  [name : String]) : AstTypeList
  (match functions
    [(IrFunctionNil) AstTypeNil]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction fname params _ _ _)
          (if (string-eq fname name)
            (compiler-backend-param-type-list params)
            (compiler-backend-function-param-types (box-get rest) name))])]
    [(IrFunctionArray seq)
      (compiler-backend-function-param-types
        (compiler-ir-function-seq-to-list seq)
        name)]))

(define (compiler-backend-extern-param-types
  [externs : CompilerIrExternList]
  [name : String]) : AstTypeList
  (match externs
    [(IrExternNil) AstTypeNil]
    [(IrExternCons item rest)
      (match item
        [(IrExtern extern-name ty _ _ _ _)
          (if (string-eq extern-name name)
            (match ty
              [(AstTyFunc args _) args]
              [_ AstTypeNil])
            (compiler-backend-extern-param-types (box-get rest) name))])]))

(define (compiler-backend-function-signature
  [functions : CompilerIrFunctionList]
  [name : String]) : CompilerBackendMaybeSignature
  (match functions
    [(IrFunctionNil) (CompilerBackendNoSignature)]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction fname params ret-ty _ _)
          (if (string-eq fname name)
            (CompilerBackendSomeSignature
              (compiler-backend-param-type-list params)
              ret-ty)
            (compiler-backend-function-signature (box-get rest) name))])]
    [(IrFunctionArray seq)
      (compiler-backend-function-signature
        (compiler-ir-function-seq-to-list seq)
        name)]))

(define (compiler-backend-extern-signature
  [externs : CompilerIrExternList]
  [name : String]) : CompilerBackendMaybeSignature
  (match externs
    [(IrExternNil) (CompilerBackendNoSignature)]
    [(IrExternCons item rest)
      (match item
        [(IrExtern extern-name ty _ _ _ _)
          (if (string-eq extern-name name)
            (match ty
              [(AstTyFunc args ret-ty)
                (CompilerBackendSomeSignature args (ty-node-get ret-ty))]
              [_ (CompilerBackendNoSignature)])
            (compiler-backend-extern-signature (box-get rest) name))])]))

(define (compiler-backend-function-list-count
  [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(IrFunctionNil) 0]
    [(IrFunctionCons _ rest)
      (+ 1 (compiler-backend-function-list-count (box-get rest)))]
    [(IrFunctionArray seq) (compiler-ir-function-seq-count seq)]))

(define (compiler-backend-extern-list-count [externs : CompilerIrExternList]) : i64
  (match externs
    [(IrExternNil) 0]
    [(IrExternCons _ rest)
      (+ 1 (compiler-backend-extern-list-count (box-get rest)))]))

;; Intern the name (instead of intern-lookup) so EVERY indexed entry is
;; reachable through the id map. The lookup-only form silently skipped names
;; that were never interned (generated helper names), which forced the query
;; side to keep an O(n) full-array string-scan fallback for every id-map miss.
;; Negative queries -- every "is this callee a function?" probe for an extern
;; or runtime helper -- paid that scan against all ~6.5k function names on
;; each call site emitted (~16% of self-compile CPU in string-eq). With the
;; build side interning, an id-map miss is a definitive "absent" and the scan
;; is gone.
(define (compiler-backend-program-index-bind-name
  [ids : I64I64Map]
  [name : String]
  [index : i64]) : I64I64Map
  (i64-i64-map-put ids (intern name) index))

(define (compiler-backend-program-index-functions-into
  [functions : CompilerIrFunctionList]
  [ids : I64I64Map]
  [names : (Array String)]
  [signatures : (Array CompilerBackendMaybeSignature)]
  [index : i64]) : I64I64Map
  (match functions
    [(IrFunctionNil) ids]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction name params ret-ty _ _)
          (begin
            (array-set! names index name)
            (array-set!
              signatures
              index
              (CompilerBackendSomeSignature
                (compiler-backend-param-type-list params)
                ret-ty))
            (compiler-backend-program-index-functions-into
              (box-get rest)
              (compiler-backend-program-index-bind-name ids name index)
              names
              signatures
              (+ index 1)))])]
    [(IrFunctionArray seq)
      (compiler-backend-program-index-functions-into
        (compiler-ir-function-seq-to-list seq)
        ids
        names
        signatures
        index)]))

(define (compiler-backend-program-index-extern-signature [ty : AstType]) : CompilerBackendMaybeSignature
  (match ty
    [(AstTyFunc args ret-ty)
      (CompilerBackendSomeSignature args (ty-node-get ret-ty))]
    [_ (CompilerBackendNoSignature)]))

(define (compiler-backend-program-index-extern-signatures-into
  [externs : CompilerIrExternList]
  [signature-ids : I64I64Map]
  [names : (Array String)]
  [signatures : (Array CompilerBackendMaybeSignature)]
  [index : i64]) : I64I64Map
  (match externs
    [(IrExternNil) signature-ids]
    [(IrExternCons item rest)
      (match item
        [(IrExtern extern-name ty _ _ _ _)
          (begin
            (array-set! names index extern-name)
            (array-set!
              signatures
              index
              (compiler-backend-program-index-extern-signature ty))
            (compiler-backend-program-index-extern-signatures-into
              (box-get rest)
              (compiler-backend-program-index-bind-name
                signature-ids
                extern-name
                index)
              names
              signatures
              (+ index 1)))])]))

;; First pass: fill the side arrays and bind the LINK SYMBOLS only.
(define (compiler-backend-program-index-extern-references-into
  [externs : CompilerIrExternList]
  [reference-ids : I64I64Map]
  [link-symbols : (Array String)]
  [provideds : (Array bool)]
  [index : i64]) : I64I64Map
  (match externs
    [(IrExternNil) reference-ids]
    [(IrExternCons item rest)
      (match item
        [(IrExtern _ _ _ link-symbol _ provided)
          (begin
            (array-set! link-symbols index link-symbol)
            (array-set! provideds index provided)
            (compiler-backend-program-index-extern-references-into
              (box-get rest)
              (compiler-backend-program-index-bind-name
                reference-ids
                link-symbol
                index)
              link-symbols
              provideds
              (+ index 1)))])]))

;; Second pass: bind the extern NAMES after every link symbol, so a name
;; binding always overwrites a link-symbol binding for the same spelling.
;; This preserves the retired scan-fallback's priority (extern names were
;; searched before link symbols) in the single reference map.
(define (compiler-backend-program-index-extern-reference-names-into
  [externs : CompilerIrExternList]
  [reference-ids : I64I64Map]
  [index : i64]) : I64I64Map
  (match externs
    [(IrExternNil) reference-ids]
    [(IrExternCons item rest)
      (match item
        [(IrExtern extern-name _ _ _ _ _)
          (compiler-backend-program-index-extern-reference-names-into
            (box-get rest)
            (compiler-backend-program-index-bind-name
              reference-ids
              extern-name
              index)
            (+ index 1))])]))

;; #2386: the aggregate type name a register-group value carries (for the
;; type-name -> word-count map). Empty for non-aggregate types.
(define (compiler-backend-aggregate-type-name [ty : AstType]) : String
  (match ty
    [(AstTyStruct name) (intern-str name)]
    [(AstTyStructArgs name _) (intern-str name)]
    [(AstTyEnum name) (intern-str name)]
    [(AstTyEnumArgs name _) (intern-str name)]
    [(AstTyRegion _ inner)
      (compiler-backend-aggregate-type-name (ty-node-get inner))]
    [_ ""]))

(define (compiler-backend-collect-group-counts-instr
  [map : StringI64Map]
  [instr : CompilerIrInstr]) : StringI64Map
  (match instr
    [(IrInstrPack _ words ty)
      (let
        [name : String (compiler-backend-aggregate-type-name ty)]
        (if (string-eq name "")
          map
          (if (string-i64-map-contains? map name)
            map
            (match (string-i64-map-insert
              map
              name
              (compiler-ir-value-list-count words))
              [(StringI64MapInsertOk next) next]
              [(StringI64MapInsertFull next) next]))))]
    [_ map]))

(define (compiler-backend-collect-group-counts-functions
  [map : StringI64Map]
  [functions : CompilerIrFunctionList]) : StringI64Map
  (match (compiler-backend-collect-functions-shared
    (BackendCollectGroupCounts map)
    functions)
    [(BackendCollectGroupCounts out) out]
    [_ map]))

(define (compiler-backend-group-word-sse-bit [index : i64]) : i64
  (if (= index 0)
    1
    2))

(define (compiler-backend-pack-word-value-sse?
  [type-info : CompilerRegVarTypes]
  [value : CompilerIrValue]) : bool
  (match value
    [(IrValueVar id)
      (match (compiler-reg-var-types-lookup type-info id)
        [(CompilerRegSomeType ty) (compiler-backend-float-type? ty)]
        [(CompilerRegNoType) false])]
    [(IrValueF64 _) true]
    [_ false]))

(define (compiler-backend-pack-word-class-mask
  [type-info : CompilerRegVarTypes]
  [words : CompilerIrValueList]
  [index : i64]
  [mask : i64]) : i64
  (match words
    [(IrValueNil) mask]
    [(IrValueCons word rest)
      (compiler-backend-pack-word-class-mask
        type-info
        (box-get rest)
        (+ index 1)
        (if (compiler-backend-pack-word-value-sse? type-info word)
          (bit-or mask (compiler-backend-group-word-sse-bit index))
          mask))]))

(define (compiler-backend-empty-reg-var-types) : CompilerRegVarTypes
  (CompilerRegVarTypes
    CompilerRegVarTypeNil
    (make-array i64 0)
    (make-array AstType 0)))

(define (compiler-backend-collect-group-counts-instr-seq
  [map : StringI64Map]
  [instrs : CompilerIrInstrSeq]
  [index : i64]) : StringI64Map
  (if (>= index (compiler-ir-instr-seq-count instrs))
    map
    (compiler-backend-collect-group-counts-instr-seq
      (compiler-backend-collect-group-counts-instr
        map
        (compiler-ir-instr-seq-ref instrs index))
      instrs
      (+ index 1))))

(define (compiler-backend-collect-group-class-masks-instr-seq
  [map : StringI64Map]
  [type-info : CompilerRegVarTypes]
  [instrs : CompilerIrInstrSeq]
  [index : i64]) : StringI64Map
  (if (>= index (compiler-ir-instr-seq-count instrs))
    map
    (compiler-backend-collect-group-class-masks-instr-seq
      (compiler-backend-collect-group-class-masks-instr
        map
        type-info
        (compiler-ir-instr-seq-ref instrs index))
      type-info
      instrs
      (+ index 1))))

;; #2386: share the function/block traversal while keeping each instruction
;; sequence leaf direct, avoiding a callback or tagged dispatch per instruction.
(define (compiler-backend-collect-block-shared
  [state : CompilerBackendCollectState]
  [block : CompilerIrBlock]) : CompilerBackendCollectState
  (match block
    [(IrBlock _ instrs)
      (match state
        [(BackendCollectCollections collections)
          (BackendCollectCollections
            (compiler-backend-collect-instr-seq-collections collections instrs))]
        [(BackendCollectGroupCounts map)
          (BackendCollectGroupCounts
            (compiler-backend-collect-group-counts-instr-seq map instrs 0))]
        [(BackendCollectGroupClassMasks map type-info)
          (BackendCollectGroupClassMasks
            (compiler-backend-collect-group-class-masks-instr-seq
              map
              type-info
              instrs
              0)
            type-info)])]))

(define (compiler-backend-collect-block-seq-shared
  [state : CompilerBackendCollectState]
  [seq : CompilerIrBlockSeq]
  [index : i64]) : CompilerBackendCollectState
  (if (>= index (compiler-ir-block-seq-count seq))
    state
    (compiler-backend-collect-block-seq-shared
      (compiler-backend-collect-block-shared
        state
        (compiler-ir-block-seq-ref seq index))
      seq
      (+ index 1))))

(define (compiler-backend-collect-blocks-shared
  [state : CompilerBackendCollectState]
  [blocks : CompilerIrBlockList]) : CompilerBackendCollectState
  (match blocks
    [(IrBlockNil) state]
    [(IrBlockCons block rest)
      (compiler-backend-collect-blocks-shared
        (compiler-backend-collect-block-shared state block)
        (box-get rest))]
    [(IrBlockArray seq) (compiler-backend-collect-block-seq-shared state seq 0)]))

(define (compiler-backend-collect-enter-function-shared
  [state : CompilerBackendCollectState]
  [func : CompilerIrFunction]) : CompilerBackendCollectState
  (match state
    [(BackendCollectGroupClassMasks map _)
      (BackendCollectGroupClassMasks map (compiler-reg-function-var-types func))]
    [_ state]))

(define (compiler-backend-collect-function-shared
  [state : CompilerBackendCollectState]
  [func : CompilerIrFunction]) : CompilerBackendCollectState
  (match func
    [(IrFunction _ _ _ _ blocks)
      (compiler-backend-collect-blocks-shared
        (compiler-backend-collect-enter-function-shared state func)
        blocks)]))

(define (compiler-backend-collect-function-seq-shared
  [state : CompilerBackendCollectState]
  [seq : CompilerIrFunctionSeq]
  [index : i64]) : CompilerBackendCollectState
  (if (>= index (compiler-ir-function-seq-count seq))
    state
    (compiler-backend-collect-function-seq-shared
      (compiler-backend-collect-function-shared
        state
        (compiler-ir-function-seq-ref seq index))
      seq
      (+ index 1))))

(define (compiler-backend-collect-functions-shared
  [state : CompilerBackendCollectState]
  [functions : CompilerIrFunctionList]) : CompilerBackendCollectState
  (match functions
    [(IrFunctionNil) state]
    [(IrFunctionCons func rest)
      (compiler-backend-collect-functions-shared
        (compiler-backend-collect-function-shared state func)
        (box-get rest))]
    [(IrFunctionArray seq)
      (compiler-backend-collect-function-seq-shared state seq 0)]))

(define (compiler-backend-merge-group-class-mask
  [map : StringI64Map]
  [name : String]
  [mask : i64]) : StringI64Map
  (if (string-eq name "")
    map
    (match (string-i64-map-get map name)
      [(StringI64MapFound found)
        (string-i64-map-put map name (bit-or found mask))]
      [(StringI64MapMissing) (string-i64-map-put map name mask)])))

(define (compiler-backend-collect-group-class-masks-instr
  [map : StringI64Map]
  [type-info : CompilerRegVarTypes]
  [instr : CompilerIrInstr]) : StringI64Map
  (match instr
    [(IrInstrPack _ words ty)
      (compiler-backend-merge-group-class-mask
        map
        (compiler-backend-aggregate-type-name ty)
        (compiler-backend-pack-word-class-mask type-info words 0 0))]
    [_ map]))

(define (compiler-backend-collect-group-class-masks-functions
  [map : StringI64Map]
  [functions : CompilerIrFunctionList]) : StringI64Map
  (match (compiler-backend-collect-functions-shared
    (BackendCollectGroupClassMasks map (compiler-backend-empty-reg-var-types))
    functions)
    [(BackendCollectGroupClassMasks out _) out]
    [_ map]))

(define (compiler-backend-program-index-build
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]) : CompilerBackendProgramIndex
  (let
    [function-count : i64 (compiler-backend-function-list-count functions)]
    [extern-count : i64 (compiler-backend-extern-list-count externs)]
    [function-names : (Array String) (make-array String function-count)]
    [function-signatures : (Array CompilerBackendMaybeSignature)
      (make-array CompilerBackendMaybeSignature function-count)]
    [extern-names : (Array String) (make-array String extern-count)]
    [extern-signatures : (Array CompilerBackendMaybeSignature)
      (make-array CompilerBackendMaybeSignature extern-count)]
    [extern-link-symbols : (Array String) (make-array String extern-count)]
    [extern-provided : (Array bool) (make-array bool extern-count)]
    [function-ids : I64I64Map
      (compiler-backend-program-index-functions-into
        functions
        (i64-i64-map-with-capacity (+ (* function-count 2) 1))
        function-names
        function-signatures
        0)]
    [extern-signature-ids : I64I64Map
      (compiler-backend-program-index-extern-signatures-into
        externs
        (i64-i64-map-with-capacity (+ (* extern-count 2) 1))
        extern-names
        extern-signatures
        0)]
    [extern-reference-ids : I64I64Map
      (compiler-backend-program-index-extern-reference-names-into
        externs
        (compiler-backend-program-index-extern-references-into
          externs
          (i64-i64-map-with-capacity (+ (* extern-count 4) 1))
          extern-link-symbols
          extern-provided
          0)
        0)]
    [group-word-counts : StringI64Map
      (compiler-backend-collect-group-counts-functions
        (string-i64-map-with-capacity (+ (* function-count 2) 1))
        functions)]
    [group-word-class-masks : StringI64Map
      (compiler-backend-collect-group-class-masks-functions
        (string-i64-map-with-capacity (+ (* function-count 2) 1))
        functions)]
    (CompilerBackendProgramIndex
      function-ids
      function-names
      function-signatures
      extern-signature-ids
      extern-names
      extern-signatures
      extern-reference-ids
      extern-link-symbols
      extern-provided
      group-word-counts
      group-word-class-masks)))

;; #2386: machine-word count for a value's type -- 2 (or more) for a
;; register-group aggregate constructed somewhere in the program, else 1.
(define (compiler-backend-group-word-count
  [index : CompilerBackendProgramIndex]
  [ty : AstType]) : i64
  (let
    [name : String (compiler-backend-aggregate-type-name ty)]
    (if (string-eq name "")
      1
      (match (string-i64-map-get (struct-get index group-word-counts) name)
        [(StringI64MapFound count) count]
        [(StringI64MapMissing) 1]))))

(define (compiler-backend-group-type?
  [index : CompilerBackendProgramIndex]
  [ty : AstType]) : bool
  (> (compiler-backend-group-word-count index ty) 1))

(define (compiler-backend-group-word-class-mask
  [index : CompilerBackendProgramIndex]
  [ty : AstType]) : i64
  (let
    [name : String (compiler-backend-aggregate-type-name ty)]
    (if (string-eq name "")
      0
      (match (string-i64-map-get (struct-get index group-word-class-masks) name)
        [(StringI64MapFound mask) mask]
        [(StringI64MapMissing) 0]))))

(define (compiler-backend-group-word-sse?
  [index : CompilerBackendProgramIndex]
  [ty : AstType]
  [word-index : i64]) : bool
  (not
    (=
      (bit-and
        (compiler-backend-group-word-class-mask index ty)
        (compiler-backend-group-word-sse-bit word-index))
      0)))

(define (compiler-backend-group-word-type
  [index : CompilerBackendProgramIndex]
  [ty : AstType]
  [word-index : i64]) : AstType
  (if (compiler-backend-group-word-sse? index ty word-index)
    (AstTyF64)
    (AstTyI64)))

;; Every indexed name is interned at index-build time (see
;; compiler-backend-program-index-bind-name), so a name the intern table has
;; never seen cannot be in the index, and an id-map miss is definitive. The
;; extern-reference map binds both the extern name and its link symbol, so one
;; map probe covers both spellings.
(define (compiler-backend-index-function-slot
  [index : CompilerBackendProgramIndex]
  [name : String]) : I64I64MapLookup
  (match (intern-lookup name)
    [(InternLookupFound name-id)
      (i64-i64-map-get (struct-get index functions) name-id)]
    [(InternLookupMissing) (I64I64MapMissing)]))

(define (compiler-backend-index-extern-signature-slot
  [index : CompilerBackendProgramIndex]
  [name : String]) : I64I64MapLookup
  (match (intern-lookup name)
    [(InternLookupFound name-id)
      (i64-i64-map-get (struct-get index extern-signatures) name-id)]
    [(InternLookupMissing) (I64I64MapMissing)]))

(define (compiler-backend-index-extern-reference-slot
  [index : CompilerBackendProgramIndex]
  [name : String]) : I64I64MapLookup
  (match (intern-lookup name)
    [(InternLookupFound name-id)
      (i64-i64-map-get (struct-get index extern-references) name-id)]
    [(InternLookupMissing) (I64I64MapMissing)]))

(define (compiler-backend-index-function-signature-id
  [index : CompilerBackendProgramIndex]
  [name-id : i64]) : CompilerBackendMaybeSignature
  (match (i64-i64-map-get (struct-get index functions) name-id)
    [(I64I64MapFound slot)
      (array-ref (struct-get index function-signatures) slot)]
    [(I64I64MapMissing) (CompilerBackendNoSignature)]))

(define (compiler-backend-index-function-signature
  [index : CompilerBackendProgramIndex]
  [name : String]) : CompilerBackendMaybeSignature
  (match (compiler-backend-index-function-slot index name)
    [(I64I64MapFound slot)
      (array-ref (struct-get index function-signatures) slot)]
    [(I64I64MapMissing) (CompilerBackendNoSignature)]))

(define (compiler-backend-index-extern-signature-id
  [index : CompilerBackendProgramIndex]
  [name-id : i64]) : CompilerBackendMaybeSignature
  (match (i64-i64-map-get (struct-get index extern-signatures) name-id)
    [(I64I64MapFound slot)
      (array-ref (struct-get index extern-signature-values) slot)]
    [(I64I64MapMissing) (CompilerBackendNoSignature)]))

(define (compiler-backend-index-extern-signature
  [index : CompilerBackendProgramIndex]
  [name : String]) : CompilerBackendMaybeSignature
  (match (compiler-backend-index-extern-signature-slot index name)
    [(I64I64MapFound slot)
      (array-ref (struct-get index extern-signature-values) slot)]
    [(I64I64MapMissing) (CompilerBackendNoSignature)]))

(define (compiler-backend-index-signature-id
  [index : CompilerBackendProgramIndex]
  [name-id : i64]) : CompilerBackendMaybeSignature
  (match (compiler-backend-index-function-signature-id index name-id)
    [(CompilerBackendSomeSignature args ret-ty)
      (CompilerBackendSomeSignature args ret-ty)]
    [(CompilerBackendNoSignature)
      (compiler-backend-index-extern-signature-id index name-id)]))

(define (compiler-backend-index-signature
  [index : CompilerBackendProgramIndex]
  [name : String]) : CompilerBackendMaybeSignature
  (match (compiler-backend-index-function-signature index name)
    [(CompilerBackendSomeSignature args ret-ty)
      (CompilerBackendSomeSignature args ret-ty)]
    [(CompilerBackendNoSignature)
      (compiler-backend-index-extern-signature index name)]))

(define (compiler-backend-index-function-defines-id?
  [index : CompilerBackendProgramIndex]
  [name-id : i64]) : bool
  (i64-i64-map-contains? (struct-get index functions) name-id))

(define (compiler-backend-index-function-defines?
  [index : CompilerBackendProgramIndex]
  [name : String]) : bool
  (match (compiler-backend-index-function-slot index name)
    [(I64I64MapFound _) true]
    [(I64I64MapMissing) false]))

(define (compiler-backend-index-extern-references-id?
  [index : CompilerBackendProgramIndex]
  [name-id : i64]) : bool
  (i64-i64-map-contains? (struct-get index extern-references) name-id))

(define (compiler-backend-index-extern-references?
  [index : CompilerBackendProgramIndex]
  [name : String]) : bool
  (match (compiler-backend-index-extern-reference-slot index name)
    [(I64I64MapFound _) true]
    [(I64I64MapMissing) false]))

(define (compiler-backend-index-extern-link-symbol-id
  [index : CompilerBackendProgramIndex]
  [name-id : i64]) : String
  (match (i64-i64-map-get (struct-get index extern-references) name-id)
    [(I64I64MapFound slot)
      (array-ref (struct-get index extern-link-symbols) slot)]
    [(I64I64MapMissing) (intern-str name-id)]))

(define (compiler-backend-index-extern-link-symbol
  [index : CompilerBackendProgramIndex]
  [name : String]) : String
  (match (compiler-backend-index-extern-reference-slot index name)
    [(I64I64MapFound slot)
      (array-ref (struct-get index extern-link-symbols) slot)]
    [(I64I64MapMissing) name]))

(define (compiler-backend-index-extern-provided-id?
  [index : CompilerBackendProgramIndex]
  [name-id : i64]) : bool
  (match (i64-i64-map-get (struct-get index extern-signatures) name-id)
    [(I64I64MapFound slot) (array-ref (struct-get index extern-provided) slot)]
    [(I64I64MapMissing) false]))

(define (compiler-backend-index-extern-provided?
  [index : CompilerBackendProgramIndex]
  [name : String]) : bool
  (match (compiler-backend-index-extern-signature-slot index name)
    [(I64I64MapFound slot) (array-ref (struct-get index extern-provided) slot)]
    [(I64I64MapMissing) false]))

(define (compiler-backend-symbol-validation-error [message : String]) : ResultCompilerBackendSymbolValidation
  (ErrCompilerBackendSymbolValidation (compiler-diagnostic-at-start "" message)))

(define (compiler-backend-emits-extern-symbol?
  [name : String]
  [link-symbol : String]
  [provided : bool]
  [plan : CompilerBackendRuntimePlan]) : bool
  (not
    (or
      provided
      (compiler-backend-fixed-fault-symbol? link-symbol)
      (and
        (string-eq name link-symbol)
        (compiler-backend-plan-provides? plan name))
      (compiler-backend-plan-provides? plan link-symbol))))

(define (compiler-backend-validate-global-symbols-into
  [globals : CompilerIrGlobalList]
  [seen : StringI64Map]) : ResultCompilerBackendSymbolValidation
  (match globals
    [(IrGlobalNil) (OkCompilerBackendSymbolValidation seen)]
    [(IrGlobalCons global rest)
      (match global
        [(IrGlobal name _ _)
          (let
            [symbol : String (compiler-backend-user-symbol name)]
            (if (string-i64-map-contains? seen symbol)
              (compiler-backend-symbol-validation-error
                (string-append
                  "backend: duplicate emitted global symbol "
                  symbol))
              (compiler-backend-validate-global-symbols-into
                (box-get rest)
                (string-i64-map-put seen symbol 1))))])]))

(define (compiler-backend-validate-function-symbols-into
  [functions : CompilerIrFunctionList]
  [_plan : CompilerBackendRuntimePlan]
  [index : CompilerBackendProgramIndex]
  [seen : StringI64Map]) : ResultCompilerBackendSymbolValidation
  (match functions
    [(IrFunctionNil) (OkCompilerBackendSymbolValidation seen)]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction name _ _ _ _)
          (let
            [symbol : String
              (compiler-backend-function-symbol-index index name)]
            (cond
              [(and
                  (string-eq name "main")
                  (compiler-backend-index-extern-provided? index name))
                (compiler-backend-symbol-validation-error
                  "backend: main cannot use :export-symbol")]
              [(string-i64-map-contains? seen symbol)
                (compiler-backend-symbol-validation-error
                  (string-append
                    "backend: duplicate emitted function symbol "
                    symbol))]
              [(and
                  (compiler-backend-index-extern-provided? index name)
                  (not (compiler-backend-valid-export-symbol? symbol)))
                (compiler-backend-symbol-validation-error
                  (string-append
                    "backend: invalid exported function symbol "
                    symbol))]
              [(and
                  (compiler-backend-index-extern-provided? index name)
                  (compiler-backend-runtime-helper-known? symbol))
                (compiler-backend-symbol-validation-error
                  (string-append
                    "backend: exported function symbol collides with runtime symbol "
                    symbol))]
              [else
                (compiler-backend-validate-function-symbols-into
                  (box-get rest)
                  _plan
                  index
                  (string-i64-map-put seen symbol 1))]))])]
    [(IrFunctionArray seq)
      (compiler-backend-validate-function-symbols-into
        (compiler-ir-function-seq-to-list seq)
        _plan
        index
        seen)]))

(define (compiler-backend-validate-extern-symbols-into
  [externs : CompilerIrExternList]
  [plan : CompilerBackendRuntimePlan]
  [seen : StringI64Map]) : ResultCompilerBackendSymbolValidation
  (match externs
    [(IrExternNil) (OkCompilerBackendSymbolValidation seen)]
    [(IrExternCons ext rest)
      (match ext
        [(IrExtern name _ _ link-symbol _ provided)
          (if (compiler-backend-emits-extern-symbol?
            name
            link-symbol
            provided
            plan)
            (let
              [symbol : String (compiler-backend-link-symbol link-symbol plan)]
              (if (string-i64-map-contains? seen symbol)
                (compiler-backend-symbol-validation-error
                  (string-append
                    "backend: extern symbol collides with emitted symbol "
                    symbol))
                (compiler-backend-validate-extern-symbols-into
                  (box-get rest)
                  plan
                  seen)))
            (compiler-backend-validate-extern-symbols-into
              (box-get rest)
              plan
              seen))])]))

(define (compiler-backend-validate-function-symbols
  [globals : CompilerIrGlobalList]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [plan : CompilerBackendRuntimePlan]
  [index : CompilerBackendProgramIndex]) : ResultCompilerBackendSymbolValidation
  (match (compiler-backend-validate-global-symbols-into
    globals
    (string-i64-map-with-capacity
      (+
        (*
          (+
            (compiler-ir-global-list-count globals)
            (compiler-backend-function-list-count functions))
          2)
        1)))
    [(OkCompilerBackendSymbolValidation seen)
      (match (compiler-backend-validate-function-symbols-into
        functions
        plan
        index
        seen)
        [(OkCompilerBackendSymbolValidation function-seen)
          (compiler-backend-validate-extern-symbols-into
            externs
            plan
            function-seen)]
        [(ErrCompilerBackendSymbolValidation message)
          (ErrCompilerBackendSymbolValidation message)])]
    [(ErrCompilerBackendSymbolValidation message)
      (ErrCompilerBackendSymbolValidation message)]))

(define (compiler-backend-signature
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [name : String]) : CompilerBackendMaybeSignature
  (match (compiler-backend-function-signature functions name)
    [(CompilerBackendSomeSignature args ret-ty)
      (CompilerBackendSomeSignature args ret-ty)]
    [(CompilerBackendNoSignature)
      (compiler-backend-extern-signature externs name)]))

(define (compiler-backend-runtime-param-types [name : String]) : AstTypeList
  (let
    [name-id : i64 (compiler-backend-runtime-helper-name-id name)]
    (cond
      [(compiler-builtin-backend-tl-print-char-id? name-id)
        (ast-type-cons (AstTyChar) AstTypeNil)]
      [(compiler-builtin-backend-tl-print-f64-id? name-id)
        (ast-type-cons (AstTyF64) AstTypeNil)]
      [(compiler-builtin-backend-tl-array-fill8-id? name-id)
        (ast-type-cons
          (ast-ty-mut-ptr (AstTyU8))
          (ast-type-cons (AstTyI64) (ast-type-cons (AstTyU64) AstTypeNil)))]
      [(compiler-builtin-backend-tl-array-zero-id? name-id)
        (ast-type-cons
          (ast-ty-mut-ptr (AstTyU8))
          (ast-type-cons (AstTyI64) AstTypeNil))]
      [else AstTypeNil])))

(define (compiler-backend-call-param-types
  [name : String]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]) : AstTypeList
  (match (compiler-backend-signature functions externs name)
    [(CompilerBackendSomeSignature param-types _) param-types]
    [(CompilerBackendNoSignature) (compiler-backend-runtime-param-types name)]))

(define (compiler-backend-extern-fixed-param-count [ty : AstType]) : i64
  (match ty
    [(AstTyFunc args _) (compiler-backend-type-list-count args)]
    [_ -1]))

(define (compiler-backend-extern-varargs-fixed-param-count
  [externs : CompilerIrExternList]
  [name : String]) : i64
  (match externs
    [(IrExternNil) -1]
    [(IrExternCons item rest)
      (match item
        [(IrExtern extern-name ty abi link-symbol _ _)
          (if (or (string-eq name extern-name) (string-eq name link-symbol))
            (if (ast-extern-abi-c-varargs? abi)
              (compiler-backend-extern-fixed-param-count ty)
              -1)
            (compiler-backend-extern-varargs-fixed-param-count
              (box-get rest)
              name))])]))

(define (compiler-backend-varargs-linux-vector-count
  [types : AstTypeList]
  [float-idx : i64]
  [count : i64]) : i64
  (match types
    [(AstTypeNil) count]
    [(AstTypeCons ty rest)
      (let
        [ty : AstType (ty-node-get ty)]
        [rest : AstTypeList (box-get rest)]
        [is-float : bool (compiler-backend-float-type? ty)]
        [next-float : i64
          (if is-float
            (+ float-idx 1)
            float-idx)]
        [next-count : i64
          (if (and is-float (< float-idx 8))
            (+ count 1)
            count)]
        (compiler-backend-varargs-linux-vector-count rest next-float next-count))]))

(define (compiler-backend-windows-vararg-int-reg [position : i64]) : String
  (cond
    [(= position 0) "%rcx"]
    [(= position 1) "%rdx"]
    [(= position 2) "%r8"]
    [(= position 3) "%r9"]
    [else ""]))

(define (compiler-backend-windows-vararg-dup-asm
  [types : AstTypeList]
  [fixed-count : i64]
  [position : i64]) : String
  (match types
    [(AstTypeNil) ""]
    [(AstTypeCons ty rest)
      (let
        [ty : AstType (ty-node-get ty)]
        [rest : AstTypeList (box-get rest)]
        [tail : String
          (compiler-backend-windows-vararg-dup-asm
            rest
            fixed-count
            (+ position 1))]
        [reg : String (compiler-backend-windows-vararg-int-reg position)]
        (if (and
          (>= position fixed-count)
          (< position 4)
          (compiler-backend-float-type? ty))
          (str-cat
            "    movq %xmm"
            (int->string position)
            ", "
            reg
            (string-append "\n" tail))
          tail))]))

(define (compiler-backend-varargs-pre-call
  [target : CompilerBackendTarget]
  [name : String]
  [externs : CompilerIrExternList]
  [param-types : AstTypeList]) : String
  (let
    [fixed-count : i64
      (compiler-backend-extern-varargs-fixed-param-count externs name)]
    (if (< fixed-count 0)
      ""
      (match target
        [(BackendTargetLinux)
          (str-cat
            "    movb $"
            (int->string
              (compiler-backend-varargs-linux-vector-count param-types 0 0))
            ", %al\n"
            ""
            "")]
        [(BackendTargetWindows)
          (compiler-backend-windows-vararg-dup-asm param-types fixed-count 0)]))))

(define (compiler-backend-call-param-types-index
  [name : String]
  [index : CompilerBackendProgramIndex]) : AstTypeList
  (match (compiler-backend-index-signature index name)
    [(CompilerBackendSomeSignature param-types _) param-types]
    [(CompilerBackendNoSignature) (compiler-backend-runtime-param-types name)]))

(define (compiler-backend-call-actual-type
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [value : CompilerIrValue]) : AstType
  (match (compiler-backend-value-type types global-types value)
    [(CompilerRegSomeType ty) ty]
    [(CompilerRegNoType) (AstTyI64)]))

(define (compiler-backend-call-actual-param-types-from
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [args : CompilerIrCallArgs]
  [fixed-types : AstTypeList]
  [fixed-count : i64]
  [index : i64]) : AstTypeList
  (if (>= index (compiler-backend-call-args-count args))
    AstTypeNil
    (if (< index fixed-count)
      (match fixed-types
        [(AstTypeCons ty rest)
          (ast-type-cons
            (ty-node-get ty)
            (compiler-backend-call-actual-param-types-from
              types
              global-types
              args
              (box-get rest)
              fixed-count
              (+ index 1)))]
        [(AstTypeNil)
          (ast-type-cons
            (compiler-backend-call-actual-type
              types
              global-types
              (compiler-backend-call-arg-at args index))
            (compiler-backend-call-actual-param-types-from
              types
              global-types
              args
              AstTypeNil
              fixed-count
              (+ index 1)))])
      (ast-type-cons
        (compiler-backend-call-actual-type
          types
          global-types
          (compiler-backend-call-arg-at args index))
        (compiler-backend-call-actual-param-types-from
          types
          global-types
          args
          fixed-types
          fixed-count
          (+ index 1))))))

(define (compiler-backend-call-actual-param-types
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [args : CompilerIrCallArgs]) : AstTypeList
  (compiler-backend-call-actual-param-types-from
    types
    global-types
    args
    AstTypeNil
    0
    0))

(define (compiler-backend-call-actual-param-type-at
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [args : CompilerIrCallArgs]
  [index : i64]) : AstType
  (if (< index (compiler-backend-call-args-count args))
    (compiler-backend-call-actual-type
      types
      global-types
      (compiler-backend-call-arg-at args index))
    (AstTyI64)))

(define (compiler-backend-call-c-abi-param-types-from
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [args : CompilerIrCallArgs]
  [declared-types : AstTypeList]
  [arg-index : i64]
  [program-index : CompilerBackendProgramIndex]) : AstTypeList
  (if (>= arg-index (compiler-backend-call-args-count args))
    AstTypeNil
    (match declared-types
      [(AstTypeCons declared rest)
        (let
          [declared-ty : AstType (ty-node-get declared)]
          [rest-declared : AstTypeList (box-get rest)]
          [memory-size : i64
            (compiler-backend-c-memory-aggregate-marker-size
              args
              (+ arg-index 1))]
          [aggregate? : bool
            (not
              (string-eq (compiler-backend-aggregate-type-name declared-ty) ""))]
          (if (and (> memory-size 0) aggregate?)
            (ast-type-cons
              declared-ty
              (ast-type-cons
                (AstTyI64)
                (ast-type-cons
                  (AstTyUnit)
                  (compiler-backend-call-c-abi-param-types-from
                    types
                    global-types
                    args
                    rest-declared
                    (+ arg-index 3)
                    program-index))))
            (if (and
              aggregate?
              (compiler-backend-group-type? program-index declared-ty)
              (< (+ arg-index 1) (compiler-backend-call-args-count args)))
              (ast-type-cons
                (compiler-backend-call-actual-param-type-at
                  types
                  global-types
                  args
                  arg-index)
                (ast-type-cons
                  (compiler-backend-call-actual-param-type-at
                    types
                    global-types
                    args
                    (+ arg-index 1))
                  (compiler-backend-call-c-abi-param-types-from
                    types
                    global-types
                    args
                    rest-declared
                    (+ arg-index 2)
                    program-index)))
              (ast-type-cons
                (compiler-backend-call-actual-param-type-at
                  types
                  global-types
                  args
                  arg-index)
                (compiler-backend-call-c-abi-param-types-from
                  types
                  global-types
                  args
                  rest-declared
                  (+ arg-index 1)
                  program-index)))))]
      [(AstTypeNil)
        (compiler-backend-call-actual-param-types-from
          types
          global-types
          args
          AstTypeNil
          0
          arg-index)])))

(define (compiler-backend-call-c-abi-param-types
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [args : CompilerIrCallArgs]
  [declared-types : AstTypeList]
  [program-index : CompilerBackendProgramIndex]) : AstTypeList
  (compiler-backend-call-c-abi-param-types-from
    types
    global-types
    args
    declared-types
    0
    program-index))

(define (compiler-backend-type-list-has-aggregate? [types : AstTypeList]) : bool
  (match types
    [(AstTypeNil) false]
    [(AstTypeCons ty rest)
      (or
        (not
          (string-eq (compiler-backend-aggregate-type-name (ty-node-get ty)) ""))
        (compiler-backend-type-list-has-aggregate? (box-get rest)))]))

(define (compiler-backend-c-aggregate-extern-call?
  [externs : CompilerIrExternList]
  [name : String]) : bool
  (match externs
    [(IrExternNil) false]
    [(IrExternCons item rest)
      (match item
        [(IrExtern extern-name ty abi link-symbol _ _)
          (if (or (string-eq name extern-name) (string-eq name link-symbol))
            (if (ast-extern-abi-c? abi)
              (match ty
                [(AstTyFunc args _)
                  (compiler-backend-type-list-has-aggregate? args)]
                [_ false])
              false)
            (compiler-backend-c-aggregate-extern-call? (box-get rest) name))])]))

(define (compiler-backend-call-param-types-for-call
  [name : String]
  [args : CompilerIrCallArgs]
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [externs : CompilerIrExternList]
  [index : CompilerBackendProgramIndex]) : AstTypeList
  (let
    [param-types : AstTypeList
      (compiler-backend-call-param-types-index name index)]
    [fixed-count : i64
      (compiler-backend-extern-varargs-fixed-param-count externs name)]
    (if (compiler-backend-c-aggregate-extern-call? externs name)
      (compiler-backend-call-c-abi-param-types
        types
        global-types
        args
        param-types
        index)
      (if (< fixed-count 0)
        (if (=
          (compiler-backend-call-args-count args)
          (compiler-backend-type-list-count param-types))
          param-types
          (compiler-backend-call-actual-param-types types global-types args))
        (compiler-backend-call-actual-param-types-from
          types
          global-types
          args
          param-types
          fixed-count
          0)))))

;; Byte offset from %rsp where the `stack-idx`-th stack-passed OUTGOING argument
;; is stored (#750). Stack args are numbered sequentially in argument order (0,
;; 1, ...) independent of which register bank overflowed. System V packs them at
;; 0,8,16,...; Windows packs them after the 32-byte shadow space.
(define (compiler-backend-outgoing-stack-arg-offset
  [target : CompilerBackendTarget]
  [stack-idx : i64]) : i64
  (+ (compiler-backend-outgoing-shadow-space target) (* stack-idx 8)))

;; Byte offset from %rbp where the `stack-idx`-th INCOMING stack argument lives
;; (#750). System V's first stack arg sits at 16(%rbp) (saved %rbp + return
;; address); Windows adds its 32-byte shadow space (48(%rbp)).
(define (compiler-backend-incoming-stack-arg-offset
  [target : CompilerBackendTarget]
  [stack-idx : i64]) : i64
  (+ (+ 16 (compiler-backend-outgoing-shadow-space target)) (* stack-idx 8)))

(define (compiler-backend-stack-slots-for-size [size : i64]) : i64
  (if (<= size 0)
    0
    (/ (+ size 7) 8)))

(define (compiler-backend-c-memory-aggregate-type?
  [target : CompilerBackendTarget]
  [c-abi? : bool]
  [ty : AstType]) : bool
  (and
    c-abi?
    (compiler-backend-target-linux? target)
    (not (string-eq (compiler-backend-aggregate-type-name ty) ""))))

(define (compiler-backend-c-memory-aggregate-marker-size
  [args : CompilerIrCallArgs]
  [index : i64]) : i64
  (if (< (+ index 1) (compiler-backend-call-args-count args))
    (match (compiler-backend-call-arg-at args index)
      [(IrValueI64 size)
        (match (compiler-backend-call-arg-at args (+ index 1))
          [(IrValueUnit) size]
          [_ 0])]
      [_ 0])
    0))

(define (compiler-backend-skip-c-memory-marker-types [types : AstTypeList]) : AstTypeList
  (match types
    [(AstTypeCons _ rest-size)
      (match (box-get rest-size)
        [(AstTypeCons _ rest-sentinel) (box-get rest-sentinel)]
        [(AstTypeNil) AstTypeNil])]
    [(AstTypeNil) AstTypeNil]))

;; Count the OUTGOING arguments that must be passed on the stack (#750). Walks
;; the args in order, tracking the integer/float/position banks exactly as
;; `compiler-backend-emit-call-args` does, and counts every arg whose bank is
;; already full.
(define (compiler-backend-call-stack-arg-count
  [target : CompilerBackendTarget]
  [args : CompilerIrCallArgs]
  [types : AstTypeList]
  [c-abi? : bool]
  [arg-index : i64]
  [int-idx : i64]
  [float-idx : i64]
  [position : i64]
  [stack-count : i64]
  [program-index : CompilerBackendProgramIndex]) : i64
  (if (>= arg-index (compiler-backend-call-args-count args))
    stack-count
    (let
      [arg-ty : AstType
        (match types
          [(AstTypeCons ty _) (ty-node-get ty)]
          [(AstTypeNil) (AstTyI64)])]
      [rest-types : AstTypeList
        (match types
          [(AstTypeCons _ tail)
            (let
              [tail : AstTypeList (box-get tail)]
              tail)]
          [(AstTypeNil) AstTypeNil])]
      [is-float : bool (compiler-backend-float-type? arg-ty)]
      [memory-aggregate? : bool
        (compiler-backend-c-memory-aggregate-type? target c-abi? arg-ty)]
      [memory-size : i64
        (if memory-aggregate?
          (compiler-backend-c-memory-aggregate-marker-size args (+ arg-index 1))
          0)]
      ;; #2386: a register-group arg occupies two integer slots and, when it does
      ;; not fit in the remaining arg registers, two stack slots -- mirror exactly
      ;; what emit-call-args does so the reserved frame space matches. That
      ;; includes Windows: emit-call-args groups on BOTH targets (indexing by
      ;; `position` there), so counting a Windows group arg as one scalar slot
      ;; made tail-call stack accounting diverge from emission.
      (if (> memory-size 0)
        (compiler-backend-call-stack-arg-count
          target
          args
          (compiler-backend-skip-c-memory-marker-types rest-types)
          c-abi?
          (+ arg-index 3)
          int-idx
          float-idx
          (+ position 1)
          (+ stack-count (compiler-backend-stack-slots-for-size memory-size))
          program-index)
        (if (compiler-backend-group-type? program-index arg-ty)
          (let
            [w0-sse : bool
              (compiler-backend-group-word-sse? program-index arg-ty 0)]
            [w0-stack : bool
              (compiler-backend-stack-call-arg-for-banks?
                target
                w0-sse
                int-idx
                float-idx
                position)]
            [int1 : i64
              (if w0-sse
                int-idx
                (+ int-idx 1))]
            [float1 : i64
              (if w0-sse
                (+ float-idx 1)
                float-idx)]
            [pos1 : i64 (+ position 1)]
            [w1-sse : bool
              (compiler-backend-group-word-sse? program-index arg-ty 1)]
            [w1-stack : bool
              (compiler-backend-stack-call-arg-for-banks?
                target
                w1-sse
                int1
                float1
                pos1)]
            (compiler-backend-call-stack-arg-count
              target
              args
              rest-types
              c-abi?
              (+ arg-index 1)
              (if w1-sse
                int1
                (+ int1 1))
              (if w1-sse
                (+ float1 1)
                float1)
              (+ position 2)
              (+
                stack-count
                (+
                  (if w0-stack
                    1
                    0)
                  (if w1-stack
                    1
                    0)))
              program-index))
          (compiler-backend-call-stack-arg-count
            target
            args
            rest-types
            c-abi?
            (+ arg-index 1)
            (if is-float
              int-idx
              (+ int-idx 1))
            (if is-float
              (+ float-idx 1)
              float-idx)
            (+ position 1)
            (if (compiler-backend-stack-call-arg-for-banks?
              target
              is-float
              int-idx
              float-idx
              position)
              (+ stack-count 1)
              stack-count)
            program-index))))))

(define (compiler-backend-type-list-stack-arg-count
  [target : CompilerBackendTarget]
  [types : AstTypeList]
  [int-idx : i64]
  [float-idx : i64]
  [position : i64]
  [stack-count : i64]
  [program-index : CompilerBackendProgramIndex]) : i64
  (match types
    [(AstTypeNil) stack-count]
    [(AstTypeCons ty rest)
      (let
        [arg-ty : AstType (ty-node-get ty)]
        [rest-types : AstTypeList (box-get rest)]
        [is-float : bool (compiler-backend-float-type? arg-ty)]
        [next-int : i64
          (if is-float
            int-idx
            (+ int-idx 1))]
        [next-float : i64
          (if is-float
            (+ float-idx 1)
            float-idx)]
        (if (compiler-backend-group-type? program-index arg-ty)
          (let
            [w0-sse : bool
              (compiler-backend-group-word-sse? program-index arg-ty 0)]
            [w0-stack : bool
              (compiler-backend-stack-call-arg-for-banks?
                target
                w0-sse
                int-idx
                float-idx
                position)]
            [int1 : i64
              (if w0-sse
                int-idx
                (+ int-idx 1))]
            [float1 : i64
              (if w0-sse
                (+ float-idx 1)
                float-idx)]
            [w1-sse : bool
              (compiler-backend-group-word-sse? program-index arg-ty 1)]
            [w1-stack : bool
              (compiler-backend-stack-call-arg-for-banks?
                target
                w1-sse
                int1
                float1
                (+ position 1))]
            (compiler-backend-type-list-stack-arg-count
              target
              rest-types
              (if w1-sse
                int1
                (+ int1 1))
              (if w1-sse
                (+ float1 1)
                float1)
              (+ position 2)
              (+
                stack-count
                (+
                  (if w0-stack
                    1
                    0)
                  (if w1-stack
                    1
                    0)))
              program-index))
          (compiler-backend-type-list-stack-arg-count
            target
            rest-types
            next-int
            next-float
            (+ position 1)
            (if (compiler-backend-stack-call-arg-for-banks?
              target
              is-float
              int-idx
              float-idx
              position)
              (+ stack-count 1)
              stack-count)
            program-index)))]))

(define (compiler-backend-incoming-stack-arg-count
  [target : CompilerBackendTarget]
  [source-function : String]
  [program-index : CompilerBackendProgramIndex]) : i64
  (compiler-backend-type-list-stack-arg-count
    target
    (compiler-backend-call-param-types-index source-function program-index)
    0
    0
    0
    0
    program-index))

;; #2386: true when any arg type is a 2-word register group.
(define (compiler-backend-type-list-has-group?
  [types : AstTypeList]
  [program-index : CompilerBackendProgramIndex]) : bool
  (match types
    [(AstTypeNil) false]
    [(AstTypeCons ty rest)
      (if (compiler-backend-group-type? program-index (ty-node-get ty))
        true
        (compiler-backend-type-list-has-group? (box-get rest) program-index))]))

(define (compiler-backend-direct-tail-call?
  [target : CompilerBackendTarget]
  [source-function : String]
  [name : String]
  [args : CompilerIrCallArgs]
  [types : AstTypeList]
  [program-index : CompilerBackendProgramIndex]) : bool
  (let
    [tail-stack : i64
      (compiler-backend-call-stack-arg-count
        target
        args
        types
        false
        0
        0
        0
        0
        0
        program-index)]
    (and
      (compiler-backend-index-function-defines? program-index name)
      (<=
        tail-stack
        (compiler-backend-incoming-stack-arg-count
          target
          source-function
          program-index))
      ;; #2386: the staged tail-call path stages each arg scalar-wise (one
      ;; 8-byte slot, word0 only), so a register-group arg that needs stack
      ;; staging would lose word1 and shift every later arg. Decline the
      ;; direct tail call and fall back to a plain call instead.
      (or
        (= tail-stack 0)
        (not (compiler-backend-type-list-has-group? types program-index))))))

;; Total %rsp adjustment reserved for a call's stack-passed args (#750):
;; `roundup16(shadow + stack-arg-count * 8)`. System V has no shadow space, so
;; this is 0 whenever every arg fits in registers.
(define (compiler-backend-call-arg-space
  [target : CompilerBackendTarget]
  [args : CompilerIrCallArgs]
  [types : AstTypeList]
  [c-abi? : bool]
  [program-index : CompilerBackendProgramIndex]) : i64
  (compiler-backend-call-arg-space-from
    target
    args
    types
    c-abi?
    0
    0
    0
    0
    program-index))

(define (compiler-backend-call-arg-space-from
  [target : CompilerBackendTarget]
  [args : CompilerIrCallArgs]
  [types : AstTypeList]
  [c-abi? : bool]
  [arg-index : i64]
  [int-idx : i64]
  [float-idx : i64]
  [position : i64]
  [program-index : CompilerBackendProgramIndex]) : i64
  (let
    [stack-count : i64
      (compiler-backend-call-stack-arg-count
        target
        args
        types
        c-abi?
        arg-index
        int-idx
        float-idx
        position
        0
        program-index)]
    (match target
      [(BackendTargetWindows) 0]
      [(BackendTargetLinux)
        (if (= stack-count 0)
          0
          (compiler-backend-round-up-16 (* stack-count 8)))])))

(define (compiler-backend-closure-call-arg-space
  [target : CompilerBackendTarget]
  [args : CompilerIrCallArgs]
  [types : AstTypeList]
  [program-index : CompilerBackendProgramIndex]) : i64
  (compiler-backend-call-arg-space-from
    target
    args
    types
    false
    0
    1
    0
    1
    program-index))

;; #2386: number of 8-byte STACK slots a Windows call's args occupy, mirroring
;; emit-call-args exactly. A register-group value takes two consecutive arg slots:
;; it stays in registers only when both fit (position+2 <= 4), otherwise the whole
;; group spills to two stack words (a group straddling the 4-register boundary
;; wastes the lone remaining register, per the System V whole-aggregate rule we
;; reuse for internal self-calls). Scalars take one slot, on the stack past the
;; four register positions. Sizing the outgoing area by actual stack words (not
;; positions-past-4) keeps a boundary group's second word inside the reservation.
(define (compiler-backend-windows-stack-word-count
  [args : CompilerIrCallArgs]
  [types : AstTypeList]
  [arg-index : i64]
  [position : i64]
  [stack-words : i64]
  [program-index : CompilerBackendProgramIndex]) : i64
  (if (>= arg-index (compiler-backend-call-args-count args))
    stack-words
    (let
      [arg-ty : AstType
        (match types
          [(AstTypeCons ty _) (ty-node-get ty)]
          [(AstTypeNil) (AstTyI64)])]
      [rest-types : AstTypeList
        (match types
          [(AstTypeCons _ tail) (box-get tail)]
          [(AstTypeNil) AstTypeNil])]
      (if (compiler-backend-group-type? program-index arg-ty)
        (compiler-backend-windows-stack-word-count
          args
          rest-types
          (+ arg-index 1)
          (+ position 2)
          ;; both halves fit in the 4 Windows int arg registers (rcx,rdx,r8,r9)?
          (if (<= (+ position 2) 4)
            stack-words
            (+ stack-words 2))
          program-index)
        (compiler-backend-windows-stack-word-count
          args
          rest-types
          (+ arg-index 1)
          (+ position 1)
          (if (< position 4)
            stack-words
            (+ stack-words 1))
          program-index)))))

(define (compiler-backend-windows-words-stack-space [stack-words : i64]) : i64
  (if (> stack-words 0)
    (compiler-backend-round-up-16 (* stack-words 8))
    0))

(define (compiler-backend-windows-stack-arg-space
  [args : CompilerIrCallArgs]
  [types : AstTypeList]
  [program-index : CompilerBackendProgramIndex]) : i64
  (compiler-backend-windows-words-stack-space
    (compiler-backend-windows-stack-word-count args types 0 0 0 program-index)))

;; Indirect (closure) calls carry no callee signature here, so size conservatively:
;; the leading environment pointer plus two stack words per argument is always an
;; upper bound on the real footprint.
(define (compiler-backend-windows-closure-stack-arg-space
  [args : CompilerIrCallArgs]) : i64
  (compiler-backend-windows-words-stack-space
    (+ 1 (* 2 (compiler-backend-call-args-count args)))))

(define (compiler-backend-instr-needs-outgoing-space? [instr : CompilerIrInstr]) : bool
  (match instr
    [(IrInstrCall _ _ _ _) true]
    [(IrInstrCallIndirect _ _ _ _) true]
    [(IrInstrCallIndirectC _ _ _ _) true]
    [(IrInstrCallCAbiStoreResult _ _ _ _) true]
    [(IrInstrCallIndirectCAbiStoreResult _ _ _ _) true]
    [(IrInstrTailCall _ _ _) true]
    [(IrInstrTailCallIndirect _ _ _) true]
    [(IrInstrBoundsCheck _ _ _) true]
    [_ false]))

(define (compiler-backend-instr-seq-need-outgoing-space?
  [instrs : CompilerIrInstrSeq]) : bool
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (< index count) (not found))
        (begin
          (if (compiler-backend-instr-needs-outgoing-space?
            (array-ref slots index))
            (set! found true)
            unit)
          (set! index (+ index 1))))
      found)))

(define (compiler-backend-blocks-need-outgoing-space?
  [blocks : CompilerIrBlockList]) : bool
  (match blocks
    [(IrBlockNil) false]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (if (compiler-backend-instr-seq-need-outgoing-space? instrs)
            true
            (compiler-backend-blocks-need-outgoing-space? (box-get rest)))])]
    [(IrBlockArray seq)
      (compiler-backend-blocks-need-outgoing-space?
        (compiler-ir-block-seq-to-list seq))]))

(define (compiler-backend-instr-outgoing-stack-space
  [instr : CompilerIrInstr]
  [program-index : CompilerBackendProgramIndex]) : i64
  (match instr
    [(IrInstrCall _ name args _)
      (compiler-backend-windows-stack-arg-space
        args
        (compiler-backend-call-param-types-index name program-index)
        program-index)]
    [(IrInstrCallIndirect _ _ args _)
      (compiler-backend-windows-closure-stack-arg-space args)]
    [(IrInstrTailCall name args _)
      (compiler-backend-windows-stack-arg-space
        args
        (compiler-backend-call-param-types-index name program-index)
        program-index)]
    [(IrInstrCallIndirectC _ _ args _)
      (compiler-backend-windows-closure-stack-arg-space args)]
    [(IrInstrCallCAbiStoreResult _ name args _)
      (+
        (compiler-backend-windows-stack-arg-space
          args
          (compiler-backend-call-param-types-index name program-index)
          program-index)
        16)]
    [(IrInstrCallIndirectCAbiStoreResult _ _ args _)
      (+ (compiler-backend-windows-closure-stack-arg-space args) 16)]
    [(IrInstrTailCallIndirect _ args _)
      (compiler-backend-windows-closure-stack-arg-space args)]
    [_ 0]))

(define (compiler-backend-instr-seq-outgoing-stack-space
  [instrs : CompilerIrInstrSeq]
  [max-space : i64]
  [program-index : CompilerBackendProgramIndex]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [out : i64 max-space]
    (begin
      (while (< index count)
        (begin
          (set!
            out
            (compiler-reg-max
              out
              (compiler-backend-instr-outgoing-stack-space
                (array-ref slots index)
                program-index)))
          (set! index (+ index 1))))
      out)))

(define (compiler-backend-blocks-outgoing-stack-space
  [blocks : CompilerIrBlockList]
  [max-space : i64]
  [program-index : CompilerBackendProgramIndex]) : i64
  (match blocks
    [(IrBlockNil) max-space]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (compiler-backend-blocks-outgoing-stack-space
            (box-get rest)
            (compiler-backend-instr-seq-outgoing-stack-space
              instrs
              max-space
              program-index)
            program-index)])]
    [(IrBlockArray seq)
      (compiler-backend-blocks-outgoing-stack-space
        (compiler-ir-block-seq-to-list seq)
        max-space
        program-index)]))

(define (compiler-backend-outgoing-frame-space
  [target : CompilerBackendTarget]
  [blocks : CompilerIrBlockList]
  [program-index : CompilerBackendProgramIndex]) : i64
  (if (compiler-backend-blocks-need-outgoing-space? blocks)
    (match target
      [(BackendTargetWindows)
        (compiler-backend-round-up-16
          (+
            (compiler-backend-outgoing-shadow-space target)
            (compiler-backend-blocks-outgoing-stack-space
              blocks
              0
              program-index)))]
      [(BackendTargetLinux) (compiler-backend-outgoing-shadow-space target)])
    0))

(define (compiler-backend-emit-scalar-stack-call-arg
  [target : CompilerBackendTarget]
  [assignments : CompilerRegAssignmentList]
  [value : CompilerIrValue]
  [arg-ty : AstType]
  [is-float : bool]
  [stack-idx : i64]) : ResultCompilerBackend
  (let
    [slot : String
      (str-cat
        (int->string
          (compiler-backend-outgoing-stack-arg-offset target stack-idx))
        "(%rsp)\n"
        "")]
    (if is-float
      (match (compiler-backend-emit-load-float-value-with-plan
        assignments
        value
        arg-ty
        "%xmm15")
        [(OkCompilerBackend head)
          (OkCompilerBackend
            (str-cat
              head
              "    "
              (compiler-backend-float-move arg-ty)
              " %xmm15, "
              slot))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])
      (match (compiler-backend-immediate-operand value)
        [(CompilerBackendSomeImmediate imm)
          (OkCompilerBackend (str-cat "    movq " imm ", " slot))]
        [(CompilerBackendNoImmediate)
          (match (compiler-backend-emit-load-value-with-plan
            assignments
            value
            "%r11")
            [(OkCompilerBackend head)
              (OkCompilerBackend (str-cat head "    movq %r11, " slot ""))]
            [(ErrCompilerBackend message) (ErrCompilerBackend message)])]))))

(define (compiler-backend-emit-call-args
  [target : CompilerBackendTarget]
  [assignments : CompilerRegAssignmentList]
  [args : CompilerIrCallArgs]
  [types : AstTypeList]
  [c-abi? : bool]
  [arg-index : i64]
  [int-idx : i64]
  [float-idx : i64]
  [position : i64]
  [stack-idx : i64]
  [func-diag : CompilerDiagnostic]
  [program-index : CompilerBackendProgramIndex]
  [vars : i64]) : ResultCompilerBackend
  (if (>= arg-index (compiler-backend-call-args-count args))
    (OkCompilerBackend "")
    (let
      [value : CompilerIrValue (compiler-backend-call-arg-at args arg-index)]
      [arg-ty : AstType
        (match types
          [(AstTypeCons ty _) (ty-node-get ty)]
          [(AstTypeNil) (AstTyI64)])]
      [rest-types : AstTypeList
        (match types
          [(AstTypeCons _ tail)
            (let
              [tail : AstTypeList (box-get tail)]
              tail)]
          [(AstTypeNil) AstTypeNil])]
      [is-float : bool (compiler-backend-float-type? arg-ty)]
      [next-int : i64
        (if is-float
          int-idx
          (+ int-idx 1))]
      [next-float : i64
        (if is-float
          (+ float-idx 1)
          float-idx)]
      [memory-aggregate? : bool
        (compiler-backend-c-memory-aggregate-type? target c-abi? arg-ty)]
      [memory-size : i64
        (if memory-aggregate?
          (compiler-backend-c-memory-aggregate-marker-size args (+ arg-index 1))
          0)]
      ;; #2386: a register-group argument occupies TWO consecutive integer arg
      ;; registers. Linux SysV indexes them by `int-idx`; Windows by the unified
      ;; `position`. The selfhost only passes register-group values between its own
      ;; functions (never to an `(:abi c)` boundary), so a 2-register/2-stack-slot
      ;; convention with a %rax:%rdx return is self-consistent on both targets.
      (cond
        [(> memory-size 0)
          (match (compiler-backend-emit-c-memory-stack-arg
            target
            assignments
            value
            stack-idx
            memory-size)
            [(OkCompilerBackend head)
              (match (compiler-backend-emit-call-args
                target
                assignments
                args
                (compiler-backend-skip-c-memory-marker-types rest-types)
                c-abi?
                (+ arg-index 3)
                int-idx
                float-idx
                (+ position 1)
                (+
                  stack-idx
                  (compiler-backend-stack-slots-for-size memory-size))
                func-diag
                program-index
                vars)
                [(OkCompilerBackend tail)
                  (OkCompilerBackend (string-append head tail))]
                [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
            [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
        [(compiler-backend-group-type? program-index arg-ty)
          (let
            [w0-sse : bool
              (compiler-backend-group-word-sse? program-index arg-ty 0)]
            [w0-stack : bool
              (compiler-backend-stack-call-arg-for-banks?
                target
                w0-sse
                int-idx
                float-idx
                position)]
            [int1 : i64
              (if w0-sse
                int-idx
                (+ int-idx 1))]
            [float1 : i64
              (if w0-sse
                (+ float-idx 1)
                float-idx)]
            [stack1 : i64
              (if w0-stack
                (+ stack-idx 1)
                stack-idx)]
            [w1-sse : bool
              (compiler-backend-group-word-sse? program-index arg-ty 1)]
            [w1-stack : bool
              (compiler-backend-stack-call-arg-for-banks?
                target
                w1-sse
                int1
                float1
                (+ position 1))]
            (match (compiler-backend-emit-group-word-call-arg
              target
              assignments
              value
              0
              int-idx
              float-idx
              position
              stack-idx
              vars
              arg-ty
              program-index
              func-diag)
              [(OkCompilerBackend head0)
                (match (compiler-backend-emit-group-word-call-arg
                  target
                  assignments
                  value
                  1
                  int1
                  float1
                  (+ position 1)
                  stack1
                  vars
                  arg-ty
                  program-index
                  func-diag)
                  [(OkCompilerBackend head1)
                    (match (compiler-backend-emit-call-args
                      target
                      assignments
                      args
                      rest-types
                      c-abi?
                      (+ arg-index 1)
                      (if w1-sse
                        int1
                        (+ int1 1))
                      (if w1-sse
                        (+ float1 1)
                        float1)
                      (+ position 2)
                      (if w1-stack
                        (+ stack1 1)
                        stack1)
                      func-diag
                      program-index
                      vars)
                      [(OkCompilerBackend tail)
                        (OkCompilerBackend
                          (string-append head0 (string-append head1 tail)))]
                      [(ErrCompilerBackend message)
                        (ErrCompilerBackend message)])]
                  [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
              [(ErrCompilerBackend message) (ErrCompilerBackend message)]))]
        [(compiler-backend-stack-call-arg-for-banks?
            target
            is-float
            int-idx
            float-idx
            position)
          (match (compiler-backend-emit-scalar-stack-call-arg
            target
            assignments
            value
            arg-ty
            is-float
            stack-idx)
            [(OkCompilerBackend head)
              (match (compiler-backend-emit-call-args
                target
                assignments
                args
                rest-types
                c-abi?
                (+ arg-index 1)
                next-int
                next-float
                (+ position 1)
                (+ stack-idx 1)
                func-diag
                program-index
                vars)
                [(OkCompilerBackend tail)
                  (OkCompilerBackend (string-append head tail))]
                [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
            [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
        [else
          (match (if is-float
            (compiler-backend-target-float-arg-reg
              target
              (if (compiler-backend-target-windows? target)
                position
                float-idx))
            (compiler-backend-target-arg-reg
              target
              (if (compiler-backend-target-windows? target)
                position
                int-idx)))
            [(OkBackendReg reg)
              (match (if is-float
                (compiler-backend-emit-load-float-value-with-plan
                  assignments
                  value
                  arg-ty
                  reg)
                (compiler-backend-emit-load-value-with-plan
                  assignments
                  value
                  reg))
                [(OkCompilerBackend head)
                  (match (compiler-backend-emit-call-args
                    target
                    assignments
                    args
                    rest-types
                    c-abi?
                    (+ arg-index 1)
                    next-int
                    next-float
                    (+ position 1)
                    stack-idx
                    func-diag
                    program-index
                    vars)
                    [(OkCompilerBackend tail)
                      (OkCompilerBackend (string-append head tail))]
                    [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
                [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
            [(ErrBackendReg message)
              (ErrCompilerBackend
                (compiler-diagnostic-with-message func-diag message))])]))))

(define (compiler-backend-tail-final-stack-slot
  [target : CompilerBackendTarget]
  [stack-idx : i64]) : String
  (string-append
    (int->string (compiler-backend-incoming-stack-arg-offset target stack-idx))
    "(%rbp)"))

(define (compiler-backend-emit-direct-tail-stack-call-arg
  [target : CompilerBackendTarget]
  [assignments : CompilerRegAssignmentList]
  [value : CompilerIrValue]
  [arg-ty : AstType]
  [is-float : bool]
  [stack-idx : i64]) : ResultCompilerBackend
  (let
    [slot : String (compiler-backend-tail-final-stack-slot target stack-idx)]
    (if is-float
      (match (compiler-backend-emit-load-float-value-with-plan
        assignments
        value
        arg-ty
        "%xmm15")
        [(OkCompilerBackend head)
          (OkCompilerBackend
            (str-cat
              head
              "    "
              (compiler-backend-float-move arg-ty)
              " %xmm15, "
              (string-append slot "\n")))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])
      (match (compiler-backend-immediate-operand value)
        [(CompilerBackendSomeImmediate imm)
          (OkCompilerBackend (str-cat "    movq " imm ", " slot "\n"))]
        [(CompilerBackendNoImmediate)
          (match (compiler-backend-emit-load-value-with-plan
            assignments
            value
            "%r11")
            [(OkCompilerBackend head)
              (OkCompilerBackend (str-cat head "    movq %r11, " slot "\n" ""))]
            [(ErrCompilerBackend message) (ErrCompilerBackend message)])]))))

(define (compiler-backend-emit-direct-tail-call-args-from
  [target : CompilerBackendTarget]
  [assignments : CompilerRegAssignmentList]
  [args : CompilerIrCallArgs]
  [types : AstTypeList]
  [arg-index : i64]
  [int-idx : i64]
  [float-idx : i64]
  [position : i64]
  [stack-idx : i64]
  [func-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (if (>= arg-index (compiler-backend-call-args-count args))
    (OkCompilerBackend "")
    (let
      [value : CompilerIrValue (compiler-backend-call-arg-at args arg-index)]
      [arg-ty : AstType
        (match types
          [(AstTypeCons ty _) (ty-node-get ty)]
          [(AstTypeNil) (AstTyI64)])]
      [rest-types : AstTypeList
        (match types
          [(AstTypeCons _ tail)
            (let
              [tail : AstTypeList (box-get tail)]
              tail)]
          [(AstTypeNil) AstTypeNil])]
      [is-float : bool (compiler-backend-float-type? arg-ty)]
      [next-int : i64
        (if is-float
          int-idx
          (+ int-idx 1))]
      [next-float : i64
        (if is-float
          (+ float-idx 1)
          float-idx)]
      (if (compiler-backend-stack-call-arg-for-banks?
        target
        is-float
        int-idx
        float-idx
        position)
        (match (compiler-backend-emit-direct-tail-stack-call-arg
          target
          assignments
          value
          arg-ty
          is-float
          stack-idx)
          [(OkCompilerBackend head)
            (match (compiler-backend-emit-direct-tail-call-args-from
              target
              assignments
              args
              rest-types
              (+ arg-index 1)
              next-int
              next-float
              (+ position 1)
              (+ stack-idx 1)
              func-diag)
              [(OkCompilerBackend tail)
                (OkCompilerBackend (string-append head tail))]
              [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)])
        (match (if is-float
          (compiler-backend-target-float-arg-reg
            target
            (if (compiler-backend-target-windows? target)
              position
              float-idx))
          (compiler-backend-target-arg-reg
            target
            (if (compiler-backend-target-windows? target)
              position
              int-idx)))
          [(OkBackendReg reg)
            (match (if is-float
              (compiler-backend-emit-load-float-value-with-plan
                assignments
                value
                arg-ty
                reg)
              (compiler-backend-emit-load-value-with-plan assignments value reg))
              [(OkCompilerBackend head)
                (match (compiler-backend-emit-direct-tail-call-args-from
                  target
                  assignments
                  args
                  rest-types
                  (+ arg-index 1)
                  next-int
                  next-float
                  (+ position 1)
                  stack-idx
                  func-diag)
                  [(OkCompilerBackend tail)
                    (OkCompilerBackend (string-append head tail))]
                  [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
              [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
          [(ErrBackendReg message)
            (ErrCompilerBackend
              (compiler-diagnostic-with-message func-diag message))])))))

(define (compiler-backend-emit-direct-tail-call-args
  [target : CompilerBackendTarget]
  [assignments : CompilerRegAssignmentList]
  [args : CompilerIrCallArgs]
  [types : AstTypeList]
  [func-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (compiler-backend-emit-direct-tail-call-args-from
    target
    assignments
    args
    types
    0
    0
    0
    0
    0
    func-diag))

(define (compiler-backend-phi-input-value
  [inputs : CompilerIrPhiInputList]
  [from-label : String]) : ResultBackendValue
  (match inputs
    [(IrPhiInputNil)
      (ErrBackendValue
        (string-append "backend: missing phi input from " from-label))]
    [(IrPhiInputCons value label rest)
      (if (string-eq label from-label)
        (OkBackendValue value)
        (compiler-backend-phi-input-value (box-get rest) from-label))]))

(define (compiler-backend-vars-same-home?
  [assignments : CompilerRegAssignmentList]
  [left : i64]
  [right : i64]) : bool
  (if (= left right)
    true
    (match (compiler-reg-assignment-lookup assignments left)
      [(CompilerRegSomeLocation left-location)
        (match (compiler-reg-assignment-lookup assignments right)
          [(CompilerRegSomeLocation right-location)
            (compiler-reg-location-eq? left-location right-location)]
          [(CompilerRegNoLocation) false])]
      [(CompilerRegNoLocation) false])))

(define (compiler-backend-value-same-home?
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [src : CompilerIrValue]) : bool
  (match src
    [(IrValueVar src-var)
      (compiler-backend-vars-same-home? assignments dst src-var)]
    [_ false]))

(define (compiler-backend-phi-same-home?
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [value : CompilerIrValue]) : bool
  (compiler-backend-value-same-home? assignments dst value))

(define (compiler-backend-phi-source-uses-home?
  [assignments : CompilerRegAssignmentList]
  [source : CompilerBackendPhiSource]
  [dst : i64]) : bool
  (match source
    [(BackendPhiSourceValue value)
      (match value
        [(IrValueVar found)
          (compiler-backend-vars-same-home? assignments found dst)]
        [_ false])]
    [(BackendPhiSourceTemp) false]))

(define (compiler-backend-phi-copy-source-uses-home?
  [assignments : CompilerRegAssignmentList]
  [copy : CompilerBackendPhiCopy]
  [dst : i64]) : bool
  (match copy
    [(BackendPhiCopy _ source _)
      (compiler-backend-phi-source-uses-home? assignments source dst)]))

(define (compiler-backend-phi-copy-list-source-uses-home?
  [assignments : CompilerRegAssignmentList]
  [copies : CompilerBackendPhiCopyList]
  [dst : i64]) : bool
  (match copies
    [(BackendPhiCopyNil) false]
    [(BackendPhiCopyCons copy rest)
      (if (compiler-backend-phi-copy-source-uses-home? assignments copy dst)
        true
        (compiler-backend-phi-copy-list-source-uses-home?
          assignments
          (box-get rest)
          dst))]))

(define (compiler-backend-phi-copy-list-find-unblocked
  [assignments : CompilerRegAssignmentList]
  [remaining : CompilerBackendPhiCopyList]
  [all : CompilerBackendPhiCopyList]) : CompilerBackendMaybePhiCopy
  (match remaining
    [(BackendPhiCopyNil) BackendNoPhiCopy]
    [(BackendPhiCopyCons copy rest)
      (match copy
        [(BackendPhiCopy dst _ _)
          (if (compiler-backend-phi-copy-list-source-uses-home?
            assignments
            all
            dst)
            (compiler-backend-phi-copy-list-find-unblocked
              assignments
              (box-get rest)
              all)
            (BackendSomePhiCopy copy))])]))

(define (compiler-backend-phi-copy-list-remove-dst
  [copies : CompilerBackendPhiCopyList]
  [dst : i64]) : CompilerBackendPhiCopyList
  (match copies
    [(BackendPhiCopyNil) BackendPhiCopyNil]
    [(BackendPhiCopyCons copy rest)
      (match copy
        [(BackendPhiCopy found-dst _ _)
          (if (= found-dst dst)
            (compiler-backend-phi-copy-list-remove-dst (box-get rest) dst)
            (compiler-backend-phi-copy-cons
              copy
              (compiler-backend-phi-copy-list-remove-dst (box-get rest) dst)))])]))

(define (compiler-backend-phi-source-replace-home
  [assignments : CompilerRegAssignmentList]
  [source : CompilerBackendPhiSource]
  [dst : i64]) : CompilerBackendPhiSource
  (match source
    [(BackendPhiSourceValue value)
      (match value
        [(IrValueVar found)
          (if (compiler-backend-vars-same-home? assignments found dst)
            (BackendPhiSourceTemp)
            source)]
        [_ source])]
    [(BackendPhiSourceTemp) source]))

(define (compiler-backend-phi-copy-list-replace-source-home
  [assignments : CompilerRegAssignmentList]
  [copies : CompilerBackendPhiCopyList]
  [dst-home-var : i64]) : CompilerBackendPhiCopyList
  (match copies
    [(BackendPhiCopyNil) BackendPhiCopyNil]
    [(BackendPhiCopyCons copy rest)
      (match copy
        [(BackendPhiCopy dst source ty)
          (compiler-backend-phi-copy-cons
            (BackendPhiCopy
              dst
              (compiler-backend-phi-source-replace-home
                assignments
                source
                dst-home-var)
              ty)
            (compiler-backend-phi-copy-list-replace-source-home
              assignments
              (box-get rest)
              dst-home-var))])]))

(define (compiler-backend-phi-source-is-var?
  [source : CompilerBackendPhiSource]
  [var : i64]) : bool
  (match source
    [(BackendPhiSourceValue value)
      (match value
        [(IrValueVar id) (= id var)]
        [_ false])]
    [(BackendPhiSourceTemp) false]))

(define (compiler-backend-phi-source-replace-var
  [source : CompilerBackendPhiSource]
  [var : i64]
  [replacement : CompilerIrValue]) : CompilerBackendPhiSource
  (if (compiler-backend-phi-source-is-var? source var)
    (BackendPhiSourceValue replacement)
    source))

(define (compiler-backend-phi-copy-list-has-source-var?
  [copies : CompilerBackendPhiCopyList]
  [var : i64]) : bool
  (match copies
    [(BackendPhiCopyNil) false]
    [(BackendPhiCopyCons copy rest)
      (match copy
        [(BackendPhiCopy _ source _)
          (or
            (compiler-backend-phi-source-is-var? source var)
            (compiler-backend-phi-copy-list-has-source-var? (box-get rest) var))])]))

(define (compiler-backend-phi-copy-list-replace-source-var
  [copies : CompilerBackendPhiCopyList]
  [var : i64]
  [replacement : CompilerIrValue]) : CompilerBackendPhiCopyList
  (match copies
    [(BackendPhiCopyNil) BackendPhiCopyNil]
    [(BackendPhiCopyCons copy rest)
      (match copy
        [(BackendPhiCopy dst source ty)
          (compiler-backend-phi-copy-cons
            (BackendPhiCopy
              dst
              (compiler-backend-phi-source-replace-var source var replacement)
              ty)
            (compiler-backend-phi-copy-list-replace-source-var
              (box-get rest)
              var
              replacement))])]))

(define (compiler-backend-phi-group-temp-reg
  [program-index : CompilerBackendProgramIndex]
  [ty : AstType]
  [word-index : i64]) : String
  (if (compiler-backend-group-word-sse? program-index ty word-index)
    (if (= word-index 0)
      "%xmm14"
      "%xmm15")
    (if (= word-index 0)
      "%r10"
      "%r11")))

(define (compiler-backend-emit-phi-temp-save
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [ty : AstType]
  [program-index : CompilerBackendProgramIndex]
  [vars : i64]) : ResultCompilerBackend
  (if (compiler-backend-group-type? program-index ty)
    (compiler-backend-emit-group-load
      assignments
      (IrValueVar dst)
      (compiler-backend-phi-group-temp-reg program-index ty 0)
      (compiler-backend-phi-group-temp-reg program-index ty 1)
      vars
      ty
      program-index)
    (OkCompilerBackend
      (compiler-backend-emit-load-var-with-plan assignments dst "%r11"))))

(define (compiler-backend-emit-phi-temp-restore
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [ty : AstType]
  [program-index : CompilerBackendProgramIndex]
  [vars : i64]) : ResultCompilerBackend
  (if (compiler-backend-group-type? program-index ty)
    (compiler-backend-emit-group-store
      assignments
      dst
      (compiler-backend-phi-group-temp-reg program-index ty 0)
      (compiler-backend-phi-group-temp-reg program-index ty 1)
      vars
      ty
      program-index)
    (OkCompilerBackend
      (compiler-backend-emit-store-var-with-plan assignments dst "%r11"))))

(define (compiler-backend-emit-phi-source-load-store
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [value : CompilerIrValue]
  [ty : AstType]
  [program-index : CompilerBackendProgramIndex]) : ResultCompilerBackend
  (match (compiler-backend-emit-load-typed-value-with-plan
    assignments
    value
    ty
    program-index)
    [(OkCompilerBackend load)
      (OkCompilerBackend
        (string-append
          load
          (compiler-backend-emit-store-typed-var-with-plan
            assignments
            dst
            (if (compiler-backend-float-type? ty)
              "%xmm0"
              "%rax")
            ty)))]
    [(ErrCompilerBackend message) (ErrCompilerBackend message)]))

(define (compiler-backend-emit-phi-var-source-direct
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [src-id : i64]) : CompilerBackendMaybeAsm
  (if (>= (compiler-backend-forwarded-addr-of-src src-id) 0)
    (CompilerBackendNoAsm)
    (match (compiler-reg-assignment-lookup assignments dst)
      [(CompilerRegSomeLocation dst-location)
        (match dst-location
          [(CompilerRegRegister dst-home)
            (match (compiler-reg-assignment-lookup assignments src-id)
              [(CompilerRegSomeLocation src-location)
                (match src-location
                  [(CompilerRegRegister src-home)
                    (CompilerBackendSomeAsm
                      (if (string-eq src-home dst-home)
                        ""
                        (str-cat "    movq " src-home ", " dst-home "\n")))]
                  [(CompilerRegRegisterPair _ _) (CompilerBackendNoAsm)]
                  [(CompilerRegSpill src-offset)
                    (CompilerBackendSomeAsm
                      (str-cat
                        "    movq "
                        (compiler-backend-frame-offset src-offset)
                        ", "
                        dst-home
                        "\n"))])]
              [(CompilerRegNoLocation)
                (CompilerBackendSomeAsm
                  (str-cat
                    "    movq "
                    (compiler-backend-slot src-id)
                    ", "
                    dst-home
                    "\n"))])]
          [(CompilerRegRegisterPair _ _) (CompilerBackendNoAsm)]
          [(CompilerRegSpill dst-offset)
            (match (compiler-reg-assignment-lookup assignments src-id)
              [(CompilerRegSomeLocation src-location)
                (match src-location
                  [(CompilerRegRegister src-home)
                    (CompilerBackendSomeAsm
                      (str-cat
                        "    movq "
                        src-home
                        ", "
                        (compiler-backend-frame-offset dst-offset)
                        "\n"))]
                  [_ (CompilerBackendNoAsm)])]
              [(CompilerRegNoLocation) (CompilerBackendNoAsm)])])]
      [(CompilerRegNoLocation)
        (match (compiler-reg-assignment-lookup assignments src-id)
          [(CompilerRegSomeLocation src-location)
            (match src-location
              [(CompilerRegRegister src-home)
                (CompilerBackendSomeAsm
                  (str-cat
                    "    movq "
                    src-home
                    ", "
                    (compiler-backend-slot dst)
                    "\n"))]
              [_ (CompilerBackendNoAsm)])]
          [(CompilerRegNoLocation) (CompilerBackendNoAsm)])])))

(define (compiler-backend-emit-phi-source-immediate-or-load-store
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [value : CompilerIrValue]
  [ty : AstType]
  [program-index : CompilerBackendProgramIndex]) : ResultCompilerBackend
  (match (compiler-backend-emit-store-immediate-to-var-home
    assignments
    dst
    value)
    [(CompilerBackendSomeAsm asm) (OkCompilerBackend asm)]
    [(CompilerBackendNoAsm)
      (compiler-backend-emit-phi-source-load-store
        assignments
        dst
        value
        ty
        program-index)]))

(define (compiler-backend-emit-phi-source-scalar-to-var
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [value : CompilerIrValue]
  [ty : AstType]
  [program-index : CompilerBackendProgramIndex]) : ResultCompilerBackend
  (if (compiler-backend-float-type? ty)
    (compiler-backend-emit-phi-source-load-store
      assignments
      dst
      value
      ty
      program-index)
    (match value
      [(IrValueVar src-id)
        (match (compiler-backend-emit-phi-var-source-direct
          assignments
          dst
          src-id)
          [(CompilerBackendSomeAsm asm) (OkCompilerBackend asm)]
          [(CompilerBackendNoAsm)
            (compiler-backend-emit-phi-source-immediate-or-load-store
              assignments
              dst
              value
              ty
              program-index)])]
      [_
        (compiler-backend-emit-phi-source-immediate-or-load-store
          assignments
          dst
          value
          ty
          program-index)])))

(define (compiler-backend-emit-phi-source-to-var
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [source : CompilerBackendPhiSource]
  [ty : AstType]
  [program-index : CompilerBackendProgramIndex]
  [vars : i64]) : ResultCompilerBackend
  (match source
    [(BackendPhiSourceTemp)
      (compiler-backend-emit-phi-temp-restore
        assignments
        dst
        ty
        program-index
        vars)]
    [(BackendPhiSourceValue value)
      (if (compiler-backend-phi-same-home? assignments dst value)
        (OkCompilerBackend "")
        ;; #2386: a register-group phi value carries two words -- copy both halves
        ;; (rax:rdx) through the group ABI, not just word0 via the scalar path.
        (if (compiler-backend-group-type? program-index ty)
          (match (compiler-backend-emit-group-load
            assignments
            value
            (compiler-backend-group-return-reg program-index ty 0)
            (compiler-backend-group-return-reg program-index ty 1)
            vars
            ty
            program-index)
            [(OkCompilerBackend load)
              (match (compiler-backend-emit-group-store
                assignments
                dst
                (compiler-backend-group-return-reg program-index ty 0)
                (compiler-backend-group-return-reg program-index ty 1)
                vars
                ty
                program-index)
                [(OkCompilerBackend store)
                  (OkCompilerBackend (string-append load store))]
                [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
            [(ErrCompilerBackend message) (ErrCompilerBackend message)])
          (compiler-backend-emit-phi-source-scalar-to-var
            assignments
            dst
            value
            ty
            program-index)))]))

(define (compiler-backend-emit-phi-copy-item
  [assignments : CompilerRegAssignmentList]
  [copy : CompilerBackendPhiCopy]
  [program-index : CompilerBackendProgramIndex]
  [vars : i64]) : ResultCompilerBackend
  (match copy
    [(BackendPhiCopy dst source ty)
      (compiler-backend-emit-phi-source-to-var
        assignments
        dst
        source
        ty
        program-index
        vars)]))

(define (compiler-backend-emit-phi-copy-list
  [assignments : CompilerRegAssignmentList]
  [copies : CompilerBackendPhiCopyList]
  [program-index : CompilerBackendProgramIndex]
  [vars : i64]) : ResultCompilerBackend
  (match copies
    [(BackendPhiCopyNil) (OkCompilerBackend "")]
    [(BackendPhiCopyCons first _)
      (match (compiler-backend-phi-copy-list-find-unblocked
        assignments
        copies
        copies)
        [(BackendSomePhiCopy copy)
          (match copy
            [(BackendPhiCopy dst _ _)
              (match (compiler-backend-emit-phi-copy-item
                assignments
                copy
                program-index
                vars)
                [(OkCompilerBackend head)
                  (match (compiler-backend-emit-phi-copy-list
                    assignments
                    (compiler-backend-phi-copy-list-remove-dst copies dst)
                    program-index
                    vars)
                    [(OkCompilerBackend tail)
                      (OkCompilerBackend (string-append head tail))]
                    [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
                [(ErrCompilerBackend message) (ErrCompilerBackend message)])])]
        [(BackendNoPhiCopy)
          (match first
            [(BackendPhiCopy dst source ty)
              (match (compiler-backend-emit-phi-temp-save
                assignments
                dst
                ty
                program-index
                vars)
                [(OkCompilerBackend save)
                  (match (compiler-backend-emit-phi-source-to-var
                    assignments
                    dst
                    source
                    ty
                    program-index
                    vars)
                    [(OkCompilerBackend head)
                      (match (compiler-backend-emit-phi-copy-list
                        assignments
                        (compiler-backend-phi-copy-list-replace-source-home
                          assignments
                          (compiler-backend-phi-copy-list-remove-dst copies dst)
                          dst)
                        program-index
                        vars)
                        [(OkCompilerBackend tail)
                          (OkCompilerBackend
                            (string-append save (string-append head tail)))]
                        [(ErrCompilerBackend message)
                          (ErrCompilerBackend message)])]
                    [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
                [(ErrCompilerBackend message) (ErrCompilerBackend message)])])])]))

(define (compiler-backend-leading-phi-copies
  [assignments : CompilerRegAssignmentList]
  [instrs : CompilerIrInstrList]
  [from-label : String]) : ResultBackendPhiCopies
  (match instrs
    [(IrInstrNil) (OkBackendPhiCopies BackendPhiCopyNil)]
    [(IrInstrCons instr rest)
      (match instr
        [(IrInstrPhi dst inputs ty)
          (match (compiler-backend-phi-input-value inputs from-label)
            [(OkBackendValue value)
              (match (compiler-backend-leading-phi-copies
                assignments
                (box-get rest)
                from-label)
                [(OkBackendPhiCopies tail)
                  (if (compiler-backend-phi-same-home? assignments dst value)
                    (OkBackendPhiCopies tail)
                    (OkBackendPhiCopies
                      (compiler-backend-phi-copy-cons
                        (BackendPhiCopy dst (BackendPhiSourceValue value) ty)
                        tail)))]
                [(ErrBackendPhiCopies message) (ErrBackendPhiCopies message)])]
            [(ErrBackendValue message) (ErrBackendPhiCopies message)])]
        [_ (OkBackendPhiCopies BackendPhiCopyNil)])]))

(define (compiler-backend-leading-phi-copies-seq-from
  [assignments : CompilerRegAssignmentList]
  [instrs : CompilerIrInstrSeq]
  [index : i64]
  [from-label : String]) : ResultBackendPhiCopies
  (if (>= index (compiler-ir-instr-seq-count instrs))
    (OkBackendPhiCopies BackendPhiCopyNil)
    (match (compiler-ir-instr-seq-ref instrs index)
      [(IrInstrPhi dst inputs ty)
        (match (compiler-backend-phi-input-value inputs from-label)
          [(OkBackendValue value)
            (match (compiler-backend-leading-phi-copies-seq-from
              assignments
              instrs
              (+ index 1)
              from-label)
              [(OkBackendPhiCopies tail)
                (if (compiler-backend-phi-same-home? assignments dst value)
                  (OkBackendPhiCopies tail)
                  (OkBackendPhiCopies
                    (compiler-backend-phi-copy-cons
                      (BackendPhiCopy dst (BackendPhiSourceValue value) ty)
                      tail)))]
              [(ErrBackendPhiCopies message) (ErrBackendPhiCopies message)])]
          [(ErrBackendValue message) (ErrBackendPhiCopies message)])]
      [_ (OkBackendPhiCopies BackendPhiCopyNil)])))

(define (compiler-backend-leading-phi-copies-seq
  [assignments : CompilerRegAssignmentList]
  [instrs : CompilerIrInstrSeq]
  [from-label : String]) : ResultBackendPhiCopies
  (compiler-backend-leading-phi-copies-seq-from assignments instrs 0 from-label))

(define (compiler-backend-emit-leading-phi-copies
  [assignments : CompilerRegAssignmentList]
  [instrs : CompilerIrInstrSeq]
  [from-label : String]
  [program-index : CompilerBackendProgramIndex]
  [vars : i64]) : ResultCompilerBackend
  (match (compiler-backend-leading-phi-copies-seq assignments instrs from-label)
    [(OkBackendPhiCopies copies)
      (compiler-backend-emit-phi-copy-list
        assignments
        copies
        program-index
        vars)]
    [(ErrBackendPhiCopies message)
      (ErrCompilerBackend (compiler-diagnostic-at-start "" message))]))

(define (compiler-backend-emit-phi-edge-copies
  [assignments : CompilerRegAssignmentList]
  [blocks : CompilerIrBlockList]
  [target-label : String]
  [from-label : String]
  [program-index : CompilerBackendProgramIndex]
  [vars : i64]) : ResultCompilerBackend
  (match blocks
    [(IrBlockNil)
      (ErrCompilerBackend
        (compiler-diagnostic-at-start
          ""
          (string-append "backend: unknown block " target-label)))]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock block-label instrs)
          (if (string-eq block-label target-label)
            (compiler-backend-emit-leading-phi-copies
              assignments
              instrs
              from-label
              program-index
              vars)
            (compiler-backend-emit-phi-edge-copies
              assignments
              (box-get rest)
              target-label
              from-label
              program-index
              vars))])]
    [(IrBlockArray seq)
      (compiler-backend-emit-phi-edge-copies
        assignments
        (compiler-ir-block-seq-to-list seq)
        target-label
        from-label
        program-index
        vars)]))

(define (compiler-backend-emit-mov-phi-copy-edge
  [assignments : CompilerRegAssignmentList]
  [blocks : CompilerIrBlockList]
  [target-label : String]
  [from-label : String]
  [moved-dst : i64]
  [moved-src : CompilerIrValue]
  [program-index : CompilerBackendProgramIndex]
  [vars : i64]) : ResultCompilerBackend
  (match blocks
    [(IrBlockNil)
      (ErrCompilerBackend
        (compiler-diagnostic-at-start
          ""
          (string-append "backend: unknown block " target-label)))]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock block-label instrs)
          (if (string-eq block-label target-label)
            (match (compiler-backend-leading-phi-copies-seq
              assignments
              instrs
              from-label)
              [(OkBackendPhiCopies copies)
                (if (compiler-backend-phi-copy-list-has-source-var?
                  copies
                  moved-dst)
                  (compiler-backend-emit-phi-copy-list
                    assignments
                    (compiler-backend-phi-copy-list-replace-source-var
                      copies
                      moved-dst
                      moved-src)
                    program-index
                    vars)
                  (OkCompilerBackend ""))]
              [(ErrBackendPhiCopies message)
                (ErrCompilerBackend (compiler-diagnostic-at-start "" message))])
            (compiler-backend-emit-mov-phi-copy-edge
              assignments
              (box-get rest)
              target-label
              from-label
              moved-dst
              moved-src
              program-index
              vars))])]
    [(IrBlockArray seq)
      (compiler-backend-emit-mov-phi-copy-edge
        assignments
        (compiler-ir-block-seq-to-list seq)
        target-label
        from-label
        moved-dst
        moved-src
        program-index
        vars)]))

(define (compiler-backend-instr-seq-starts-with-phi?
  [instrs : CompilerIrInstrSeq]) : bool
  (if (= (compiler-ir-instr-seq-count instrs) 0)
    false
    (match (compiler-ir-instr-seq-ref instrs 0)
      [(IrInstrPhi _ _ _) true]
      [_ false])))

(define (compiler-backend-phi-target-labels
  [blocks : CompilerIrBlockList]
  [out : BackendStringList]) : BackendStringList
  (match blocks
    [(IrBlockNil) out]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label instrs)
          (compiler-backend-phi-target-labels
            (box-get rest)
            (if (compiler-backend-instr-seq-starts-with-phi? instrs)
              (begin
                (set!
                  compiler-backend-current-phi-target-count
                  (+ compiler-backend-current-phi-target-count 1))
                (compiler-backend-string-cons label out))
              out))])]
    [(IrBlockArray seq)
      (compiler-backend-phi-target-labels
        (compiler-ir-block-seq-to-list seq)
        out)]))

(define (compiler-backend-phi-target-labels-for-blocks
  [blocks : CompilerIrBlockList]) : BackendStringList
  (begin
    (set! compiler-backend-current-phi-target-count 0)
    (compiler-backend-phi-target-labels
      blocks
      (compiler-backend-empty-string-list))))

(define (compiler-backend-branch-needs-phi-copies?
  [true-label : String]
  [false-label : String]) : bool
  (if (= compiler-backend-current-phi-target-count 0)
    false
    (or
      (compiler-backend-string-list-contains?
        compiler-backend-current-phi-targets
        true-label)
      (compiler-backend-string-list-contains?
        compiler-backend-current-phi-targets
        false-label))))

(define (compiler-backend-branch-edge-label
  [current-label : String]
  [suffix : String]) : String
  (string-append (string-append current-label "_branch_") suffix))

(define (compiler-backend-branch-edge-target
  [edge-label : String]
  [target-label : String]
  [copies : String]) : String
  (if (string-eq copies "")
    target-label
    edge-label))

(define (compiler-backend-branch-edge-fallthrough
  [current-label : String]
  [true-copies : String]
  [false-copies : String]
  [fallthrough : CompilerBackendMaybeLabel]) : CompilerBackendMaybeLabel
  (if (not (string-eq true-copies ""))
    (CompilerBackendSomeLabel
      (compiler-backend-branch-edge-label current-label "true"))
    (if (not (string-eq false-copies ""))
      (CompilerBackendSomeLabel
        (compiler-backend-branch-edge-label current-label "false"))
      fallthrough)))

(define (compiler-backend-emit-branch-edge-block
  [function : String]
  [edge-label : String]
  [target-label : String]
  [copies : String]) : String
  (if (string-eq copies "")
    ""
    (str-cat
      (compiler-backend-asm-label function edge-label)
      ":\n"
      copies
      (compiler-backend-jump-label function target-label)
      "")))

(define (compiler-backend-emit-branch-edges
  [function : String]
  [current-label : String]
  [true-label : String]
  [false-label : String]
  [true-copies : String]
  [false-copies : String]
  [branch-asm : String]) : String
  (let
    [true-edge : String
      (compiler-backend-branch-edge-label current-label "true")]
    [false-edge : String
      (compiler-backend-branch-edge-label current-label "false")]
    (string-append
      branch-asm
      (string-append
        (compiler-backend-emit-branch-edge-block
          function
          true-edge
          true-label
          true-copies)
        (compiler-backend-emit-branch-edge-block
          function
          false-edge
          false-label
          false-copies)))))

(define (compiler-backend-emit-branch-with-phi-copies
  [assignments : CompilerRegAssignmentList]
  [function : String]
  [blocks : CompilerIrBlockList]
  [current-label : String]
  [cond : CompilerIrValue]
  [true-label : String]
  [false-label : String]
  [fallthrough : CompilerBackendMaybeLabel]
  [program-index : CompilerBackendProgramIndex]
  [vars : i64]) : ResultCompilerBackend
  (if (not (compiler-backend-branch-needs-phi-copies? true-label false-label))
    (compiler-backend-emit-branch
      assignments
      function
      cond
      true-label
      false-label
      fallthrough)
    (match (compiler-backend-emit-phi-edge-copies
      assignments
      blocks
      true-label
      current-label
      program-index
      vars)
      [(OkCompilerBackend true-copies)
        (match (compiler-backend-emit-phi-edge-copies
          assignments
          blocks
          false-label
          current-label
          program-index
          vars)
          [(OkCompilerBackend false-copies)
            (let
              [true-edge : String
                (compiler-backend-branch-edge-label current-label "true")]
              [false-edge : String
                (compiler-backend-branch-edge-label current-label "false")]
              [true-target : String
                (compiler-backend-branch-edge-target
                  true-edge
                  true-label
                  true-copies)]
              [false-target : String
                (compiler-backend-branch-edge-target
                  false-edge
                  false-label
                  false-copies)]
              [edge-fallthrough : CompilerBackendMaybeLabel
                (compiler-backend-branch-edge-fallthrough
                  current-label
                  true-copies
                  false-copies
                  fallthrough)]
              (match (compiler-backend-emit-branch
                assignments
                function
                cond
                true-target
                false-target
                edge-fallthrough)
                [(OkCompilerBackend branch-asm)
                  (OkCompilerBackend
                    (compiler-backend-emit-branch-edges
                      function
                      current-label
                      true-label
                      false-label
                      true-copies
                      false-copies
                      branch-asm))]
                [(ErrCompilerBackend message) (ErrCompilerBackend message)]))]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
      [(ErrCompilerBackend message) (ErrCompilerBackend message)])))

(define (compiler-backend-emit-compare-branch-with-phi-copies
  [assignments : CompilerRegAssignmentList]
  [function : String]
  [blocks : CompilerIrBlockList]
  [current-label : String]
  [op : CompilerIrBinOp]
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [ty : AstType]
  [true-label : String]
  [false-label : String]
  [fallthrough : CompilerBackendMaybeLabel]
  [program-index : CompilerBackendProgramIndex]
  [vars : i64]) : ResultCompilerBackend
  (if (not (compiler-backend-branch-needs-phi-copies? true-label false-label))
    (compiler-backend-emit-compare-branch
      assignments
      function
      op
      lhs
      rhs
      ty
      true-label
      false-label
      fallthrough)
    (match (compiler-backend-emit-phi-edge-copies
      assignments
      blocks
      true-label
      current-label
      program-index
      vars)
      [(OkCompilerBackend true-copies)
        (match (compiler-backend-emit-phi-edge-copies
          assignments
          blocks
          false-label
          current-label
          program-index
          vars)
          [(OkCompilerBackend false-copies)
            (let
              [true-edge : String
                (compiler-backend-branch-edge-label current-label "true")]
              [false-edge : String
                (compiler-backend-branch-edge-label current-label "false")]
              [true-target : String
                (compiler-backend-branch-edge-target
                  true-edge
                  true-label
                  true-copies)]
              [false-target : String
                (compiler-backend-branch-edge-target
                  false-edge
                  false-label
                  false-copies)]
              [edge-fallthrough : CompilerBackendMaybeLabel
                (compiler-backend-branch-edge-fallthrough
                  current-label
                  true-copies
                  false-copies
                  fallthrough)]
              (match (compiler-backend-emit-compare-branch
                assignments
                function
                op
                lhs
                rhs
                ty
                true-target
                false-target
                edge-fallthrough)
                [(OkCompilerBackend branch-asm)
                  (OkCompilerBackend
                    (compiler-backend-emit-branch-edges
                      function
                      current-label
                      true-label
                      false-label
                      true-copies
                      false-copies
                      branch-asm))]
                [(ErrCompilerBackend message) (ErrCompilerBackend message)]))]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
      [(ErrCompilerBackend message) (ErrCompilerBackend message)])))

(define (compiler-backend-emit-load-compare-branch-with-phi-copies
  [assignments : CompilerRegAssignmentList]
  [function : String]
  [blocks : CompilerIrBlockList]
  [current-label : String]
  [ptr : CompilerIrValue]
  [op : CompilerIrBinOp]
  [rhs : CompilerIrValue]
  [ty : AstType]
  [true-label : String]
  [false-label : String]
  [fallthrough : CompilerBackendMaybeLabel]
  [program-index : CompilerBackendProgramIndex]
  [vars : i64]) : ResultCompilerBackend
  (if (not (compiler-backend-branch-needs-phi-copies? true-label false-label))
    (compiler-backend-emit-load-compare-branch
      assignments
      function
      ptr
      op
      rhs
      ty
      true-label
      false-label
      fallthrough)
    (match (compiler-backend-emit-phi-edge-copies
      assignments
      blocks
      true-label
      current-label
      program-index
      vars)
      [(OkCompilerBackend true-copies)
        (match (compiler-backend-emit-phi-edge-copies
          assignments
          blocks
          false-label
          current-label
          program-index
          vars)
          [(OkCompilerBackend false-copies)
            (let
              [true-edge : String
                (compiler-backend-branch-edge-label current-label "true")]
              [false-edge : String
                (compiler-backend-branch-edge-label current-label "false")]
              [true-target : String
                (compiler-backend-branch-edge-target
                  true-edge
                  true-label
                  true-copies)]
              [false-target : String
                (compiler-backend-branch-edge-target
                  false-edge
                  false-label
                  false-copies)]
              [edge-fallthrough : CompilerBackendMaybeLabel
                (compiler-backend-branch-edge-fallthrough
                  current-label
                  true-copies
                  false-copies
                  fallthrough)]
              (match (compiler-backend-emit-load-compare-branch
                assignments
                function
                ptr
                op
                rhs
                ty
                true-target
                false-target
                edge-fallthrough)
                [(OkCompilerBackend branch-asm)
                  (OkCompilerBackend
                    (compiler-backend-emit-branch-edges
                      function
                      current-label
                      true-label
                      false-label
                      true-copies
                      false-copies
                      branch-asm))]
                [(ErrCompilerBackend message) (ErrCompilerBackend message)]))]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
      [(ErrCompilerBackend message) (ErrCompilerBackend message)])))

(define (compiler-backend-emit-gep-load-compare-branch-with-phi-copies
  [assignments : CompilerRegAssignmentList]
  [function : String]
  [blocks : CompilerIrBlockList]
  [current-label : String]
  [base : CompilerIrValue]
  [offset : CompilerIrValue]
  [elem-ty : AstType]
  [op : CompilerIrBinOp]
  [rhs : CompilerIrValue]
  [ty : AstType]
  [true-label : String]
  [false-label : String]
  [fallthrough : CompilerBackendMaybeLabel]
  [program-index : CompilerBackendProgramIndex]
  [vars : i64]) : ResultCompilerBackend
  (if (not (compiler-backend-branch-needs-phi-copies? true-label false-label))
    (compiler-backend-emit-gep-load-compare-branch
      assignments
      function
      base
      offset
      elem-ty
      op
      rhs
      ty
      true-label
      false-label
      fallthrough)
    (match (compiler-backend-emit-phi-edge-copies
      assignments
      blocks
      true-label
      current-label
      program-index
      vars)
      [(OkCompilerBackend true-copies)
        (match (compiler-backend-emit-phi-edge-copies
          assignments
          blocks
          false-label
          current-label
          program-index
          vars)
          [(OkCompilerBackend false-copies)
            (let
              [true-edge : String
                (compiler-backend-branch-edge-label current-label "true")]
              [false-edge : String
                (compiler-backend-branch-edge-label current-label "false")]
              [true-target : String
                (compiler-backend-branch-edge-target
                  true-edge
                  true-label
                  true-copies)]
              [false-target : String
                (compiler-backend-branch-edge-target
                  false-edge
                  false-label
                  false-copies)]
              [edge-fallthrough : CompilerBackendMaybeLabel
                (compiler-backend-branch-edge-fallthrough
                  current-label
                  true-copies
                  false-copies
                  fallthrough)]
              (match (compiler-backend-emit-gep-load-compare-branch
                assignments
                function
                base
                offset
                elem-ty
                op
                rhs
                ty
                true-target
                false-target
                edge-fallthrough)
                [(OkCompilerBackend branch-asm)
                  (OkCompilerBackend
                    (compiler-backend-emit-branch-edges
                      function
                      current-label
                      true-label
                      false-label
                      true-copies
                      false-copies
                      branch-asm))]
                [(ErrCompilerBackend message) (ErrCompilerBackend message)]))]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
      [(ErrCompilerBackend message) (ErrCompilerBackend message)])))

(define (compiler-backend-tail-call-return-normalize [ty : AstType]) : String
  (if (= (compiler-backend-type-size ty) 0)
    "    movq $0, %rax\n"
    ""))

(define (compiler-backend-instr-return-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(IrInstrReturn _) 1]
    [_ 0]))

(define (compiler-backend-instr-seq-return-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [out : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            out
            (+
              out
              (compiler-backend-instr-return-count (array-ref slots index))))
          (set! index (+ index 1))))
      out)))

(define (compiler-backend-block-list-return-count
  [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (compiler-backend-instr-seq-return-count instrs)
            (compiler-backend-block-list-return-count (box-get rest)))])]
    [(IrBlockArray seq)
      (compiler-backend-block-list-return-count
        (compiler-ir-block-seq-to-list seq))]))

(define (compiler-backend-use-shared-return?
  [assignments : CompilerRegAssignmentList]
  [blocks : CompilerIrBlockList]) : bool
  (and
    (compiler-backend-plan-uses-callee-regs? assignments)
    (> (compiler-backend-block-list-return-count blocks) 1)))

(define (compiler-backend-return-tail
  [source-function : String]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [blocks : CompilerIrBlockList]) : String
  (if (compiler-backend-use-shared-return? assignments blocks)
    (str-cat "    jmp " (compiler-backend-return-label source-function) "\n" "")
    (compiler-backend-inline-return-tail assignments vars)))

(define (compiler-backend-return-epilogue
  [source-function : String]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [blocks : CompilerIrBlockList]) : String
  (if (compiler-backend-use-shared-return? assignments blocks)
    (str-cat
      (compiler-backend-return-label source-function)
      ":\n"
      (compiler-backend-inline-return-tail assignments vars)
      "")
    ""))

(define (compiler-backend-emit-return
  [source-function : String]
  [blocks : CompilerIrBlockList]
  [value : CompilerIrMaybeValue]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [ret-ty : AstType]
  [program-index : CompilerBackendProgramIndex]) : ResultCompilerBackend
  (match value
    [(IrNoValue)
      (OkCompilerBackend
        (string-append
          (if (string-eq source-function "main")
            "    xorl %eax, %eax\n"
            "")
          (compiler-backend-return-tail source-function assignments vars blocks)))]
    [(IrSomeValue v)
      ;; #2386: a register-group return goes in %rax:%rdx (word0:word1).
      (if (compiler-backend-group-type? program-index ret-ty)
        (match (compiler-backend-emit-group-load
          assignments
          v
          (compiler-backend-group-return-reg program-index ret-ty 0)
          (compiler-backend-group-return-reg program-index ret-ty 1)
          vars
          ret-ty
          program-index)
          [(OkCompilerBackend load)
            (OkCompilerBackend
              (string-append
                load
                (compiler-backend-return-tail
                  source-function
                  assignments
                  vars
                  blocks)))]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)])
        (match (compiler-backend-emit-load-typed-value-with-plan
          assignments
          v
          ret-ty
          program-index)
          [(OkCompilerBackend load)
            (OkCompilerBackend
              (string-append
                load
                (compiler-backend-return-tail
                  source-function
                  assignments
                  vars
                  blocks)))]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)]))]))

(define (compiler-backend-emit-tail-call
  [target : CompilerBackendTarget]
  [source-function : String]
  [blocks : CompilerIrBlockList]
  [name : String]
  [args : CompilerIrCallArgs]
  [ty : AstType]
  [assignments : CompilerRegAssignmentList]
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [vars : i64]
  [plan : CompilerBackendRuntimePlan]
  [_functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [program-index : CompilerBackendProgramIndex]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (let
    [param-types : AstTypeList
      (compiler-backend-call-param-types-for-call
        name
        args
        types
        global-types
        externs
        program-index)]
    [c-abi? : bool (compiler-backend-c-aggregate-extern-call? externs name)]
    [call-space : i64
      (compiler-backend-call-arg-space
        target
        args
        param-types
        c-abi?
        program-index)]
    [tail-stack-count : i64
      (compiler-backend-call-stack-arg-count
        target
        args
        param-types
        c-abi?
        0
        0
        0
        0
        0
        program-index)]
    [target-symbol : String
      (compiler-backend-call-symbol-index name plan program-index)]
    (if (compiler-backend-direct-tail-call?
      target
      source-function
      name
      args
      param-types
      program-index)
      (match (if (= tail-stack-count 0)
        (compiler-backend-emit-call-args
          target
          assignments
          args
          param-types
          c-abi?
          0
          0
          0
          0
          0
          instr-diag
          program-index
          vars)
        (compiler-backend-emit-direct-tail-call-args
          target
          assignments
          args
          param-types
          instr-diag))
        [(OkCompilerBackend args-asm)
          (OkCompilerBackend
            (string-append
              args-asm
              (compiler-backend-tail-jump-tail assignments vars target-symbol)))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])
      (match (compiler-backend-emit-call-args
        target
        assignments
        args
        param-types
        c-abi?
        0
        0
        0
        0
        0
        instr-diag
        program-index
        vars)
        [(OkCompilerBackend args-asm)
          (OkCompilerBackend
            (string-append
              (compiler-backend-emit-call-space-sub call-space)
              (string-append
                args-asm
                (string-append
                  (compiler-backend-varargs-pre-call
                    target
                    name
                    externs
                    param-types)
                  (str-cat
                    "    call "
                    target-symbol
                    "\n"
                    (string-append
                      (compiler-backend-emit-call-space-add call-space)
                      (string-append
                        (compiler-backend-tail-call-return-normalize ty)
                        (compiler-backend-return-tail
                          source-function
                          assignments
                          vars
                          blocks)))
                    "")))))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)]))))

(define (compiler-backend-trivial-phi-return-find
  [instrs : CompilerIrInstrSeq]
  [from-label : String]
  [returned-dst : i64]
  [index : i64]
  [last-index : i64]
  [found : CompilerBackendPhiReturnMatch]) : ResultBackendPhiReturnMatch
  (if (>= index last-index)
    (OkBackendPhiReturnMatch found)
    (match (compiler-ir-instr-seq-ref instrs index)
      [(IrInstrPhi dst inputs _)
        (match (compiler-backend-phi-input-value inputs from-label)
          [(OkBackendValue incoming)
            (compiler-backend-trivial-phi-return-find
              instrs
              from-label
              returned-dst
              (+ index 1)
              last-index
              (if (= dst returned-dst)
                (BackendSomePhiReturnMatch incoming)
                found))]
          [(ErrBackendValue message) (ErrBackendPhiReturnMatch message)])]
      [_ (OkBackendPhiReturnMatch (BackendNoPhiReturnMatch))])))

(define (compiler-backend-emit-trivial-phi-return-edge-instrs
  [source-function : String]
  [blocks : CompilerIrBlockList]
  [instrs : CompilerIrInstrSeq]
  [from-label : String]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [ret-ty : AstType]
  [program-index : CompilerBackendProgramIndex]) : ResultCompilerBackend
  (if (< (compiler-ir-instr-seq-count instrs) 2)
    (OkCompilerBackend "")
    (let
      [last-index : i64 (- (compiler-ir-instr-seq-count instrs) 1)]
      [last : CompilerIrInstr (compiler-ir-instr-seq-ref instrs last-index)]
      (match last
        [(IrInstrReturn maybe)
          (match maybe
            [(IrSomeValue value)
              (match value
                [(IrValueVar returned-dst)
                  (match (compiler-backend-trivial-phi-return-find
                    instrs
                    from-label
                    returned-dst
                    0
                    last-index
                    (BackendNoPhiReturnMatch))
                    [(OkBackendPhiReturnMatch found)
                      (match found
                        [(BackendSomePhiReturnMatch incoming)
                          ;; The real program-index must reach emit-return here:
                          ;; an empty index makes the register-group return check
                          ;; always false, so a 16-byte group return would load
                          ;; only word0 (#2386 word1-drop miscompile).
                          (compiler-backend-emit-return
                            source-function
                            blocks
                            (IrSomeValue incoming)
                            assignments
                            vars
                            ret-ty
                            program-index)]
                        [(BackendNoPhiReturnMatch) (OkCompilerBackend "")])]
                    [(ErrBackendPhiReturnMatch message)
                      (ErrCompilerBackend
                        (compiler-diagnostic-at-start "" message))])]
                [_ (OkCompilerBackend "")])]
            [(IrNoValue) (OkCompilerBackend "")])]
        [_ (OkCompilerBackend "")]))))

(define (compiler-backend-emit-trivial-phi-return-edge
  [source-function : String]
  [blocks : CompilerIrBlockList]
  [target-label : String]
  [from-label : String]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [ret-ty : AstType]
  [program-index : CompilerBackendProgramIndex]) : ResultCompilerBackend
  (match blocks
    [(IrBlockNil) (OkCompilerBackend "")]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock block-label instrs)
          (if (string-eq block-label target-label)
            (compiler-backend-emit-trivial-phi-return-edge-instrs
              source-function
              blocks
              instrs
              from-label
              assignments
              vars
              ret-ty
              program-index)
            (compiler-backend-emit-trivial-phi-return-edge
              source-function
              (box-get rest)
              target-label
              from-label
              assignments
              vars
              ret-ty
              program-index))])]
    [(IrBlockArray seq)
      (compiler-backend-emit-trivial-phi-return-edge
        source-function
        (compiler-ir-block-seq-to-list seq)
        target-label
        from-label
        assignments
        vars
        ret-ty
        program-index)]))

(define (compiler-backend-emit-mov-trivial-phi-return-edge-instrs
  [source-function : String]
  [blocks : CompilerIrBlockList]
  [instrs : CompilerIrInstrSeq]
  [from-label : String]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [ret-ty : AstType]
  [moved-dst : i64]
  [moved-src : CompilerIrValue]
  [program-index : CompilerBackendProgramIndex]) : ResultCompilerBackend
  (if (< (compiler-ir-instr-seq-count instrs) 2)
    (OkCompilerBackend "")
    (let
      [last-index : i64 (- (compiler-ir-instr-seq-count instrs) 1)]
      [last : CompilerIrInstr (compiler-ir-instr-seq-ref instrs last-index)]
      (match last
        [(IrInstrReturn maybe)
          (match maybe
            [(IrSomeValue value)
              (match value
                [(IrValueVar returned-dst)
                  (match (compiler-backend-trivial-phi-return-find
                    instrs
                    from-label
                    returned-dst
                    0
                    last-index
                    (BackendNoPhiReturnMatch))
                    [(OkBackendPhiReturnMatch found)
                      (match found
                        [(BackendSomePhiReturnMatch incoming)
                          (if (compiler-backend-branch-uses-var?
                            incoming
                            moved-dst)
                            ;; Same #2386 word1-drop hazard as the plain trivial
                            ;; phi return edge: emit-return needs the real
                            ;; program-index to spot register-group returns.
                            (compiler-backend-emit-return
                              source-function
                              blocks
                              (IrSomeValue moved-src)
                              assignments
                              vars
                              ret-ty
                              program-index)
                            (OkCompilerBackend ""))]
                        [(BackendNoPhiReturnMatch) (OkCompilerBackend "")])]
                    [(ErrBackendPhiReturnMatch message)
                      (ErrCompilerBackend
                        (compiler-diagnostic-at-start "" message))])]
                [_ (OkCompilerBackend "")])]
            [(IrNoValue) (OkCompilerBackend "")])]
        [_ (OkCompilerBackend "")]))))

(define (compiler-backend-emit-mov-trivial-phi-return-edge
  [source-function : String]
  [blocks : CompilerIrBlockList]
  [target-label : String]
  [from-label : String]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [ret-ty : AstType]
  [moved-dst : i64]
  [moved-src : CompilerIrValue]
  [program-index : CompilerBackendProgramIndex]) : ResultCompilerBackend
  (match blocks
    [(IrBlockNil) (OkCompilerBackend "")]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock block-label instrs)
          (if (string-eq block-label target-label)
            (compiler-backend-emit-mov-trivial-phi-return-edge-instrs
              source-function
              blocks
              instrs
              from-label
              assignments
              vars
              ret-ty
              moved-dst
              moved-src
              program-index)
            (compiler-backend-emit-mov-trivial-phi-return-edge
              source-function
              (box-get rest)
              target-label
              from-label
              assignments
              vars
              ret-ty
              moved-dst
              moved-src
              program-index))])]
    [(IrBlockArray seq)
      (compiler-backend-emit-mov-trivial-phi-return-edge
        source-function
        (compiler-ir-block-seq-to-list seq)
        target-label
        from-label
        assignments
        vars
        ret-ty
        moved-dst
        moved-src
        program-index)]))

;; The destination's home register, or "" if it is spilled / has no home. Used to
;; load a move's source directly into the destination register (1 instr) instead
;; of routing through %rax and storing back (2 instrs).
(define (compiler-backend-var-register-home
  [assignments : CompilerRegAssignmentList]
  [var : i64]) : String
  (match (compiler-reg-assignment-lookup assignments var)
    [(CompilerRegSomeLocation location)
      (match location
        [(CompilerRegRegister r) r]
        [(CompilerRegRegisterPair r _) r]
        [_ ""])]
    [_ ""]))

(define (compiler-backend-value-register-home
  [assignments : CompilerRegAssignmentList]
  [value : CompilerIrValue]) : String
  (match value
    [(IrValueVar id)
      (match (compiler-reg-assignment-lookup assignments id)
        [(CompilerRegSomeLocation location)
          (match location
            [(CompilerRegRegister home) home]
            [_ ""])]
        [(CompilerRegNoLocation) ""])]
    [_ ""]))

(define (compiler-backend-emit-direct-global-store
  [assignments : CompilerRegAssignmentList]
  [name : String]
  [value : CompilerIrValue]
  [ty : AstType]) : CompilerBackendMaybeAsm
  (if (compiler-backend-float-type? ty)
    (CompilerBackendNoAsm)
    (let
      [home : String (compiler-backend-value-register-home assignments value)]
      (if (string-eq home "")
        (CompilerBackendNoAsm)
        (CompilerBackendSomeAsm
          (str-cat
            "    movq "
            home
            ", "
            (compiler-backend-user-symbol name)
            "(%rip)\n"))))))

(define (compiler-backend-emit-mov
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [src : CompilerIrValue]
  [ty : AstType]
  [program-index : CompilerBackendProgramIndex]
  [vars : i64]) : ResultCompilerBackend
  (cond
    [(compiler-backend-group-type? program-index ty)
      (match (compiler-backend-emit-group-load
        assignments
        src
        (compiler-backend-group-return-reg program-index ty 0)
        (compiler-backend-group-return-reg program-index ty 1)
        vars
        ty
        program-index)
        [(OkCompilerBackend load)
          (match (compiler-backend-emit-group-store
            assignments
            dst
            (compiler-backend-group-return-reg program-index ty 0)
            (compiler-backend-group-return-reg program-index ty 1)
            vars
            ty
            program-index)
            [(OkCompilerBackend store)
              (OkCompilerBackend (string-append load store))]
            [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
    [(compiler-backend-value-same-home? assignments dst src)
      (OkCompilerBackend "")]
    [(compiler-backend-float-type? ty)
      (match (compiler-backend-emit-load-typed-value-with-plan
        assignments
        src
        ty
        program-index)
        [(OkCompilerBackend load)
          (OkCompilerBackend
            (string-append
              load
              (compiler-backend-emit-store-typed-var-with-plan
                assignments
                dst
                "%xmm0"
                ty)))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
    [else
      (match (compiler-backend-emit-store-immediate-to-var-home
        assignments
        dst
        src)
        [(CompilerBackendSomeAsm asm) (OkCompilerBackend asm)]
        [(CompilerBackendNoAsm)
          (let
            [dst-home : String
              (compiler-backend-var-register-home assignments dst)]
            ;; Load src straight into the destination register home (a plain movq
            ;; / leaq), skipping the %rax staging store. emit-load-value-with-plan
            ;; handles var/global/global-addr sources and elides the move when src
            ;; already lives in dst's home.
            ;;
            ;; #2981: a var source can always take this path regardless of `ty`
            ;; width. Register and spill homes always hold the full normalized
            ;; 64-bit value (emit-store-var-with-plan stores every scalar with a
            ;; bare `movq`, and narrowing/extension happens when the value is first
            ;; produced), so a `movq src-home, dst-home` copy needs no per-type
            ;; reload. Non-var sources (globals/global-addr loaded from memory)
            ;; still require the typed narrowing path unless they are 8 bytes.
            (if (if (string-eq dst-home "")
              false
              (match src
                [(IrValueVar _) true]
                [_ (= (compiler-backend-type-size ty) 8)]))
              (compiler-backend-emit-load-value-with-plan
                assignments
                src
                dst-home)
              (match (match src
                [(IrValueGlobalAddr name)
                  (OkCompilerBackend
                    (str-cat
                      "    leaq "
                      (compiler-backend-function-or-global-addr-symbol
                        program-index
                        name)
                      "(%rip), %rax\n"
                      ""
                      ""))]
                [_
                  (compiler-backend-emit-load-typed-value-with-plan
                    assignments
                    src
                    ty
                    program-index)])
                [(OkCompilerBackend load)
                  (OkCompilerBackend
                    (string-append
                      load
                      (compiler-backend-emit-store-typed-var-with-plan
                        assignments
                        dst
                        "%rax"
                        ty)))]
                [(ErrCompilerBackend message) (ErrCompilerBackend message)])))])]))

(define (compiler-backend-emit-call-result-store
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [ty : AstType]
  [vars : i64]
  [program-index : CompilerBackendProgramIndex]) : ResultCompilerBackend
  (if (compiler-backend-group-type? program-index ty)
    (compiler-backend-emit-group-store
      assignments
      dst
      (compiler-backend-group-return-reg program-index ty 0)
      (compiler-backend-group-return-reg program-index ty 1)
      vars
      ty
      program-index)
    (OkCompilerBackend
      (compiler-backend-emit-store-typed-var-with-plan
        assignments
        dst
        (if (compiler-backend-float-type? ty)
          "%xmm0"
          "%rax")
        ty))))

(define (compiler-backend-c-abi-return-int-reg [idx : i64]) : String
  (if (= idx 0)
    "%rax"
    "%rdx"))

(define (compiler-backend-c-abi-return-sse-reg [idx : i64]) : String
  (if (= idx 0)
    "%xmm0"
    "%xmm1"))

(define (compiler-backend-c-abi-return-slot-addr
  [base-reg : String]
  [offset : i64]) : String
  (str-cat (int->string offset) "(" base-reg ")"))

(define (compiler-backend-emit-c-abi-return-slot-store
  [base-reg : String]
  [slot : CompilerIrCAbiReturnSlot]
  [int-idx : i64]
  [sse-idx : i64]) : String
  (match slot
    [(IrCAbiReturnSlot ty offset)
      (let
        [sse? : bool (compiler-backend-float-type? ty)]
        [reg : String
          (if sse?
            (compiler-backend-c-abi-return-sse-reg sse-idx)
            (compiler-backend-c-abi-return-int-reg int-idx))]
        [addr : String
          (compiler-backend-c-abi-return-slot-addr base-reg offset)]
        (if sse?
          (compiler-backend-emit-store-xmm-to-memory addr reg ty)
          (compiler-backend-emit-store-reg-to-memory addr reg ty)))]))

(define (compiler-backend-emit-c-abi-return-slot-stores
  [base-reg : String]
  [slots : CompilerIrCAbiReturnSlotList]
  [int-idx : i64]
  [sse-idx : i64]) : String
  (match slots
    [(IrCAbiReturnSlotNil) ""]
    [(IrCAbiReturnSlotCons slot rest)
      (match slot
        [(IrCAbiReturnSlot ty _)
          (let
            [sse? : bool (compiler-backend-float-type? ty)]
            (string-append
              (compiler-backend-emit-c-abi-return-slot-store
                base-reg
                slot
                int-idx
                sse-idx)
              (compiler-backend-emit-c-abi-return-slot-stores
                base-reg
                (box-get rest)
                (if sse?
                  int-idx
                  (+ int-idx 1))
                (if sse?
                  (+ sse-idx 1)
                  sse-idx))))])]))

(define (compiler-backend-emit-c-abi-return-base-save
  [assignments : CompilerRegAssignmentList]
  [base : CompilerIrValue]
  [save-offset : i64]) : ResultCompilerBackend
  (match (compiler-backend-emit-load-value-with-plan assignments base "%r11")
    [(OkCompilerBackend base-asm)
      (OkCompilerBackend
        (string-append
          base-asm
          (str-cat "    movq %r11, " (int->string save-offset) "(%rsp)\n")))]
    [(ErrCompilerBackend message) (ErrCompilerBackend message)]))

(define (compiler-backend-emit-c-abi-return-stores
  [save-offset : i64]
  [slots : CompilerIrCAbiReturnSlotList]) : String
  (string-append
    (str-cat "    movq " (int->string save-offset) "(%rsp), %r11\n")
    (compiler-backend-emit-c-abi-return-slot-stores "%r11" slots 0 0)))

(define (compiler-backend-emit-entry-load
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [label : String]
  [ty : AstType]) : ResultCompilerBackend
  (let
    [scratch-asm : String
      (string-append
        (str-cat "    movq " label "(%rip), %rax\n" "" "")
        (compiler-backend-emit-store-typed-var-with-plan
          assignments
          dst
          "%rax"
          ty))]
    (match (compiler-reg-assignment-lookup assignments dst)
      [(CompilerRegSomeLocation location)
        (match location
          ;; Entry loads produce one pointer-sized word; aggregate register-pair
          ;; homes stay on the scratch fallback.
          [(CompilerRegRegister home)
            (OkCompilerBackend (str-cat "    movq " label "(%rip), " home "\n"))]
          [_ (OkCompilerBackend scratch-asm)])]
      [(CompilerRegNoLocation) (OkCompilerBackend scratch-asm)])))

(define (compiler-backend-cpuid-result-move [reg-index : i64]) : String
  (cond
    [(= reg-index 0) ""]
    [(= reg-index 1) "    movl %ebx, %eax\n"]
    [(= reg-index 2) "    movl %ecx, %eax\n"]
    [(= reg-index 3) "    movl %edx, %eax\n"]
    [else "    xorq %rax, %rax\n"]))

(define (compiler-backend-emit-cpuid
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [leaf : CompilerIrValue]
  [subleaf : CompilerIrValue]
  [reg-index : i64]) : ResultCompilerBackend
  (match (compiler-backend-emit-load-value-with-plan assignments subleaf "%rcx")
    [(OkCompilerBackend subleaf-asm)
      (match (compiler-backend-emit-load-value-with-plan
        assignments
        leaf
        "%rax")
        [(OkCompilerBackend leaf-asm)
          (OkCompilerBackend
            (string-append
              subleaf-asm
              (string-append
                leaf-asm
                (string-append
                  "    pushq %rbx\n    cpuid\n"
                  (string-append
                    (compiler-backend-cpuid-result-move reg-index)
                    (string-append
                      "    popq %rbx\n"
                      (compiler-backend-emit-store-typed-var-with-plan
                        assignments
                        dst
                        "%rax"
                        (AstTyI64))))))))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
    [(ErrCompilerBackend message) (ErrCompilerBackend message)]))

(define (compiler-backend-emit-xgetbv
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [index : CompilerIrValue]) : ResultCompilerBackend
  (match (compiler-backend-emit-load-value-with-plan assignments index "%rcx")
    [(OkCompilerBackend index-asm)
      (OkCompilerBackend
        (string-append
          index-asm
          (string-append
            "    xgetbv\n    shlq $32, %rdx\n    orq %rdx, %rax\n"
            (compiler-backend-emit-store-typed-var-with-plan
              assignments
              dst
              "%rax"
              (AstTyI64)))))]
    [(ErrCompilerBackend message) (ErrCompilerBackend message)]))

;; Linux syscall argument register for operand position: 0=number, 1..6=args.
(define (compiler-backend-syscall-reg [pos : i64]) : String
  (cond
    [(= pos 0) "%rax"]
    [(= pos 1) "%rdi"]
    [(= pos 2) "%rsi"]
    [(= pos 3) "%rdx"]
    [(= pos 4) "%r10"]
    [(= pos 5) "%r8"]
    [(= pos 6) "%r9"]
    [else "%rax"]))

;; SysV register allocation keeps TypeLisp values in callee-saved homes
;; (%rbx/%r12-%r15) or stack slots, which do not overlap the Linux syscall
;; operand registers. Load operands directly into the kernel ABI registers.
(define (compiler-backend-emit-syscall-loads
  [assignments : CompilerRegAssignmentList]
  [args : CompilerIrCallArgs]
  [index : i64]
  [count : i64]) : ResultCompilerBackend
  (if (>= index count)
    (OkCompilerBackend "")
    (match (compiler-backend-emit-load-value-with-plan
      assignments
      (compiler-backend-call-arg-at args index)
      (compiler-backend-syscall-reg index))
      [(OkCompilerBackend load-asm)
        (match (compiler-backend-emit-syscall-loads
          assignments
          args
          (+ index 1)
          count)
          [(OkCompilerBackend rest-asm)
            (OkCompilerBackend (string-append load-asm rest-asm))]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
      [(ErrCompilerBackend message) (ErrCompilerBackend message)])))

;; `syscall` clobbers %rcx/%r11 and uses Linux syscall arg registers. The primary
;; integer pool is callee-saved, and the scalar caller-saved extension rejects
;; intervals spanning syscall points, so no live register home can be lost; the
;; raw kernel result lands in %rax -> dst. The raw `syscall` instruction and its
;; register ABI are Linux x86_64 only; emitting it for any other target would
;; silently miscompile, so reject it instead.
(define (compiler-backend-emit-syscall
  [target : CompilerBackendTarget]
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [args : CompilerIrCallArgs]) : ResultCompilerBackend
  (if (compiler-backend-target-windows? target)
    (ErrCompilerBackend
      (compiler-diagnostic-at-start
        ""
        "backend: syscall is only supported on the linux-x86_64 target"))
    (let
      [count : i64 (compiler-backend-call-args-count args)]
      (match (compiler-backend-emit-syscall-loads assignments args 0 count)
        [(OkCompilerBackend load-asm)
          (OkCompilerBackend
            (string-append
              load-asm
              (string-append
                "    syscall\n"
                (compiler-backend-emit-store-typed-var-with-plan
                  assignments
                  dst
                  "%rax"
                  (AstTyI64)))))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)]))))

(define (compiler-backend-emit-instr
  [target : CompilerBackendTarget]
  [function : String]
  [source-function : String]
  [blocks : CompilerIrBlockList]
  [current-label : String]
  [fallthrough : CompilerBackendMaybeLabel]
  [instr : CompilerIrInstr]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [ret-ty : AstType]
  [plan : CompilerBackendRuntimePlan]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [program-index : CompilerBackendProgramIndex]
  [spans : CompilerSourceSpans]
  [func-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (let
    [instr-diag : CompilerDiagnostic
      (compiler-backend-instr-diagnostic
        spans
        source-function
        instr
        func-diag
        "")]
    (match instr
      [(IrInstrMov dst src ty)
        (match (compiler-backend-emit-mov
          assignments
          dst
          src
          ty
          program-index
          vars)
          [(OkCompilerBackend asm) (OkCompilerBackend asm)]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(IrInstrAlloc _ _) (OkCompilerBackend "")]
      [(IrInstrAddrOf dst src)
        (match (compiler-backend-emit-addr-of assignments dst src)
          [(OkCompilerBackend asm) (OkCompilerBackend asm)]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(IrInstrGep dst base offset elem-ty)
        (match (compiler-backend-emit-gep assignments dst base offset elem-ty)
          [(OkCompilerBackend asm) (OkCompilerBackend asm)]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(IrInstrLoad dst src ty)
        (match (compiler-backend-emit-load-instr assignments dst src ty)
          [(OkCompilerBackend asm) (OkCompilerBackend asm)]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(IrInstrStorePtr dst src ty)
        (match (compiler-backend-emit-store-ptr
          assignments
          dst
          src
          ty
          program-index)
          [(OkCompilerBackend asm) (OkCompilerBackend asm)]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(IrInstrCopyBytes dst src size)
        (match (compiler-backend-emit-copy-bytes assignments dst src size)
          [(OkCompilerBackend asm) (OkCompilerBackend asm)]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(IrInstrBoundsCheck index length ok-label)
        (match (compiler-backend-emit-bounds-check
          target
          function
          assignments
          index
          length
          ok-label
          plan
          functions
          externs
          program-index)
          [(OkCompilerBackend asm) (OkCompilerBackend asm)]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(IrInstrCast dst src from-ty to-ty)
        (match (compiler-backend-emit-cast
          function
          current-label
          assignments
          dst
          src
          from-ty
          to-ty
          program-index)
          [(OkCompilerBackend asm) (OkCompilerBackend asm)]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(IrInstrBitcast dst src from-ty to-ty)
        (match (compiler-backend-emit-bitcast
          assignments
          dst
          src
          from-ty
          to-ty
          program-index)
          [(OkCompilerBackend asm) (OkCompilerBackend asm)]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(IrInstrBinOp dst op lhs rhs ty)
        (match (compiler-backend-emit-binop
          types
          global-types
          assignments
          dst
          op
          lhs
          rhs
          ty)
          [(OkCompilerBackend asm) (OkCompilerBackend asm)]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(IrInstrUnOp dst op src ty)
        (match (compiler-backend-emit-unop assignments dst op src ty)
          [(OkCompilerBackend asm) (OkCompilerBackend asm)]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(IrInstrLaneId dst lanes elem-ty)
        (compiler-backend-emit-vector-lane-id
          function
          current-label
          assignments
          dst
          lanes
          elem-ty
          instr-diag)]
      [(IrInstrSplat dst value lanes elem-ty)
        (compiler-backend-emit-vector-splat
          assignments
          dst
          value
          lanes
          elem-ty
          instr-diag)]
      [(IrInstrVectorBinOp dst op lhs rhs lanes elem-ty)
        (compiler-backend-emit-vector-binop
          assignments
          dst
          op
          lhs
          rhs
          lanes
          elem-ty
          instr-diag)]
      [(IrInstrVectorReduce dst op src lanes elem-ty)
        (compiler-backend-emit-vector-reduce
          assignments
          dst
          op
          src
          lanes
          elem-ty
          instr-diag)]
      [(IrInstrVectorCompare dst op lhs rhs lanes elem-ty)
        (compiler-backend-emit-avx512-vector-compare
          assignments
          dst
          op
          lhs
          rhs
          lanes
          elem-ty
          instr-diag)]
      [(IrInstrMaskBinOp dst op lhs rhs lanes)
        (compiler-backend-emit-avx512-mask-binop
          assignments
          dst
          op
          lhs
          rhs
          lanes
          instr-diag)]
      [(IrInstrMaskNot dst src lanes)
        (compiler-backend-emit-avx512-mask-not
          assignments
          dst
          src
          lanes
          instr-diag)]
      [(IrInstrMaskReduce dst op src lanes)
        (compiler-backend-emit-avx512-mask-reduce
          assignments
          dst
          op
          src
          lanes
          instr-diag)]
      [(IrInstrSelect dst mask on-true on-false lanes elem-ty)
        (compiler-backend-emit-avx512-select
          assignments
          dst
          mask
          on-true
          on-false
          lanes
          elem-ty
          instr-diag)]
      [(IrInstrVectorLoad dst base index lanes elem-ty)
        (compiler-backend-emit-vector-load
          assignments
          dst
          base
          index
          lanes
          elem-ty
          instr-diag)]
      [(IrInstrVectorStore base index value lanes elem-ty)
        (compiler-backend-emit-vector-store
          assignments
          base
          index
          value
          lanes
          elem-ty
          instr-diag)]
      [(IrInstrPredicatedStore base index value mask lanes elem-ty)
        (compiler-backend-emit-avx512-predicated-store
          assignments
          base
          index
          value
          mask
          lanes
          elem-ty
          instr-diag)]
      [(IrInstrPredicatedLoad dst base index mask lanes elem-ty)
        (compiler-backend-emit-avx512-predicated-load
          assignments
          dst
          base
          index
          mask
          lanes
          elem-ty
          instr-diag)]
      [(IrInstrTailMask dst index len lanes)
        (compiler-backend-emit-avx512-tail-mask
          function
          current-label
          assignments
          dst
          index
          len
          lanes
          instr-diag)]
      [(IrInstrEntryArgc dst)
        (compiler-backend-emit-entry-load
          assignments
          dst
          ".L_tl_argc"
          (AstTyI64))]
      [(IrInstrEntryArgv dst)
        (compiler-backend-emit-entry-load
          assignments
          dst
          ".L_tl_argv"
          (ast-ty-ptr (ast-ty-ptr (AstTyU8))))]
      [(IrInstrEntryEnvp dst)
        (compiler-backend-emit-entry-load
          assignments
          dst
          ".L_tl_envp"
          (ast-ty-ptr (ast-ty-ptr (AstTyU8))))]
      [(IrInstrCpuId dst leaf subleaf reg-index)
        (compiler-backend-emit-cpuid assignments dst leaf subleaf reg-index)]
      [(IrInstrXgetbv dst index)
        (compiler-backend-emit-xgetbv assignments dst index)]
      [(IrInstrSyscall dst args)
        (compiler-backend-emit-syscall target assignments dst args)]
      [(IrInstrCall dst name args ty)
        (let
          [fast-alloc-size : i64 (compiler-backend-fast-alloc-size args)]
          [call-symbol : String
            (compiler-backend-call-symbol-index name plan program-index)]
          (if (and
            (> fast-alloc-size 0)
            (compiler-builtin-backend-tl-alloc-id?
              (compiler-backend-runtime-helper-name-id name))
            (compiler-backend-plan-provides? plan "tl_alloc")
            (compiler-builtin-backend-tl-alloc-id?
              (compiler-backend-runtime-helper-name-id call-symbol)))
            (OkCompilerBackend
              (string-append
                (if (compiler-backend-inline-fast-alloc? fast-alloc-size)
                  (compiler-backend-emit-inline-fast-alloc
                    target
                    function
                    current-label
                    dst
                    fast-alloc-size
                    (compiler-backend-plan-provides?
                      plan
                      "tl_profile_alloc_total"))
                  (str-cat
                    "    call "
                    (compiler-backend-fast-alloc-label fast-alloc-size)
                    "\n"
                    ""
                    ""))
                (compiler-backend-emit-store-typed-var-with-plan
                  assignments
                  dst
                  "%rax"
                  ty)))
            (let
              [param-types : AstTypeList
                (compiler-backend-call-param-types-for-call
                  name
                  args
                  types
                  global-types
                  externs
                  program-index)]
              [c-abi? : bool
                (compiler-backend-c-aggregate-extern-call? externs name)]
              [call-space : i64
                (compiler-backend-call-arg-space
                  target
                  args
                  param-types
                  c-abi?
                  program-index)]
              (match (compiler-backend-emit-call-args
                target
                assignments
                args
                param-types
                c-abi?
                0
                0
                0
                0
                0
                instr-diag
                program-index
                vars)
                [(OkCompilerBackend args-asm)
                  (match (compiler-backend-emit-call-result-store
                    assignments
                    dst
                    ty
                    vars
                    program-index)
                    [(OkCompilerBackend result-store)
                      (OkCompilerBackend
                        (string-append
                          (compiler-backend-emit-call-space-sub call-space)
                          (string-append
                            args-asm
                            (string-append
                              (compiler-backend-varargs-pre-call
                                target
                                name
                                externs
                                param-types)
                              (str-cat
                                "    call "
                                call-symbol
                                "\n"
                                (string-append
                                  (compiler-backend-emit-call-space-add
                                    call-space)
                                  result-store)
                                "")))))]
                    [(ErrCompilerBackend message)
                      (ErrCompilerBackend
                        (compiler-backend-apply-instr-diagnostic
                          message
                          instr-diag))])]
                [(ErrCompilerBackend message)
                  (ErrCompilerBackend
                    (compiler-backend-apply-instr-diagnostic message instr-diag))]))))]
      [(IrInstrCallIndirect dst func args ty)
        (compiler-backend-emit-indirect-call
          target
          dst
          func
          args
          ty
          assignments
          types
          functions
          externs
          program-index
          vars
          instr-diag)]
      [(IrInstrCallIndirectC dst func args ty)
        (compiler-backend-emit-indirect-c-call
          target
          dst
          func
          args
          ty
          assignments
          types
          functions
          externs
          program-index
          vars
          instr-diag)]
      [(IrInstrCallCAbiStoreResult base name args slots)
        (compiler-backend-emit-c-abi-store-result-call
          target
          base
          name
          args
          slots
          assignments
          types
          global-types
          plan
          externs
          program-index
          vars
          instr-diag)]
      [(IrInstrCallIndirectCAbiStoreResult base func args slots)
        (compiler-backend-emit-indirect-c-abi-store-result-call
          target
          base
          func
          args
          slots
          assignments
          types
          functions
          externs
          program-index
          vars
          instr-diag)]
      [(IrInstrTailCall name args ty)
        (match (compiler-backend-emit-tail-call
          target
          source-function
          blocks
          name
          args
          ty
          assignments
          types
          global-types
          vars
          plan
          functions
          externs
          program-index
          instr-diag)
          [(OkCompilerBackend asm) (OkCompilerBackend asm)]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(IrInstrStore name value ty)
        (let
          [addr : String
            (str-cat (compiler-backend-user-symbol name) "(%rip)" "")]
          (if (compiler-backend-group-type? program-index ty)
            ;; #2386: storing a register-group into a global writes both words
            ;; inline (word0 at sym, word1 at sym+8).
            (let
              [reg0 : String
                (compiler-backend-group-return-reg program-index ty 0)]
              [reg1 : String
                (compiler-backend-group-return-reg program-index ty 1)]
              [sym0 : String
                (str-cat (compiler-backend-user-symbol name) "(%rip)" "")]
              [sym1 : String
                (str-cat (compiler-backend-user-symbol name) "+8(%rip)" "")]
              (match (compiler-backend-emit-group-load
                assignments
                value
                reg0
                reg1
                vars
                ty
                program-index)
                [(OkCompilerBackend load)
                  (OkCompilerBackend
                    (string-append
                      load
                      (string-append
                        (compiler-backend-emit-group-word-move
                          reg0
                          sym0
                          (compiler-backend-group-word-sse? program-index ty 0))
                        (compiler-backend-emit-group-word-move
                          reg1
                          sym1
                          (compiler-backend-group-word-sse? program-index ty 1)))))]
                [(ErrCompilerBackend message)
                  (ErrCompilerBackend
                    (compiler-backend-apply-instr-diagnostic message instr-diag))]))
            (match (compiler-backend-emit-store-immediate-to-memory
              value
              addr
              ty)
              [(CompilerBackendSomeAsm store-asm) (OkCompilerBackend store-asm)]
              [(CompilerBackendNoAsm)
                (match (compiler-backend-emit-direct-global-store
                  assignments
                  name
                  value
                  ty)
                  [(CompilerBackendSomeAsm store-asm)
                    (OkCompilerBackend store-asm)]
                  [(CompilerBackendNoAsm)
                    (match (compiler-backend-emit-load-typed-value-with-plan
                      assignments
                      value
                      ty
                      program-index)
                      [(OkCompilerBackend load)
                        (OkCompilerBackend
                          (string-append
                            load
                            (if (compiler-backend-float-type? ty)
                              (str-cat
                                "    "
                                (compiler-backend-float-move ty)
                                " %xmm0, "
                                (compiler-backend-user-symbol name)
                                "(%rip)\n")
                              (str-cat
                                "    movq %rax, "
                                (compiler-backend-user-symbol name)
                                "(%rip)\n"
                                ""))))]
                      [(ErrCompilerBackend message)
                        (ErrCompilerBackend
                          (compiler-backend-apply-instr-diagnostic
                            message
                            instr-diag))])])])))]
      [(IrInstrJump target)
        (match (compiler-backend-emit-trivial-phi-return-edge
          source-function
          blocks
          target
          current-label
          assignments
          vars
          ret-ty
          program-index)
          [(OkCompilerBackend direct-return)
            (if (string-eq direct-return "")
              (match (compiler-backend-emit-phi-edge-copies
                assignments
                blocks
                target
                current-label
                program-index
                vars)
                [(OkCompilerBackend copies)
                  (OkCompilerBackend
                    (string-append
                      copies
                      (if (compiler-backend-jump-target-is-fallthrough?
                        target
                        fallthrough)
                        ""
                        (str-cat
                          "    jmp "
                          (compiler-backend-asm-label function target)
                          "\n"
                          ""))))]
                [(ErrCompilerBackend message)
                  (ErrCompilerBackend
                    (compiler-backend-apply-instr-diagnostic message instr-diag))])
              (OkCompilerBackend direct-return))]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(IrInstrBranch cond true-label false-label)
        (match (compiler-backend-emit-branch-with-phi-copies
          assignments
          function
          blocks
          current-label
          cond
          true-label
          false-label
          fallthrough
          program-index
          vars)
          [(OkCompilerBackend asm) (OkCompilerBackend asm)]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(IrInstrReturn value)
        (match (compiler-backend-emit-return
          source-function
          blocks
          value
          assignments
          vars
          ret-ty
          program-index)
          [(OkCompilerBackend asm) (OkCompilerBackend asm)]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(IrInstrPhi _ _ _) (OkCompilerBackend "")]
      [(IrInstrPack dst words ty)
        (compiler-backend-emit-pack
          assignments
          dst
          words
          ty
          vars
          program-index
          instr-diag)]
      [(IrInstrWord dst src index ty)
        (compiler-backend-emit-word
          assignments
          dst
          src
          index
          ty
          vars
          instr-diag)]
      [(IrInstrTailCallIndirect func args ty)
        (match (compiler-backend-emit-tail-indirect-call
          target
          source-function
          blocks
          func
          args
          ty
          assignments
          types
          vars
          functions
          externs
          program-index
          instr-diag)
          [(OkCompilerBackend asm) (OkCompilerBackend asm)]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])])))

(define (compiler-backend-use-count-inc [counts : (Array i64)] [var : i64]) : unit
  (if (< var 0)
    unit
    (if (>= var (array-length counts))
      unit
      (begin
        (array-set! counts var (+ (array-ref counts var) 1))
        unit))))

(define (compiler-backend-count-value-use
  [counts : (Array i64)]
  [value : CompilerIrValue]) : unit
  (match value
    [(IrValueVar id) (compiler-backend-use-count-inc counts id)]
    [_ unit]))

(define (compiler-backend-count-value-list-uses
  [counts : (Array i64)]
  [values : CompilerIrValueList]) : unit
  (match values
    [(IrValueNil) unit]
    [(IrValueCons value rest)
      (begin
        (compiler-backend-count-value-use counts value)
        (compiler-backend-count-value-list-uses counts (box-get rest)))]))

(define (compiler-backend-count-call-args-array-uses
  [counts : (Array i64)]
  [values : (Array CompilerIrValue)]
  [index : i64]) : unit
  (if (>= index (array-length values))
    unit
    (begin
      (compiler-backend-count-value-use counts (array-ref values index))
      (compiler-backend-count-call-args-array-uses counts values (+ index 1)))))

(define (compiler-backend-count-call-args-uses
  [counts : (Array i64)]
  [args : CompilerIrCallArgs]) : unit
  (match args
    [(IrCallArgsNil) unit]
    [(IrCallArgsOne value) (compiler-backend-count-value-use counts value)]
    [(IrCallArgsTwo a b)
      (begin
        (compiler-backend-count-value-use counts a)
        (compiler-backend-count-value-use counts b))]
    [(IrCallArgsArray values)
      (compiler-backend-count-call-args-array-uses counts values 0)]))

(define (compiler-backend-count-phi-input-uses
  [counts : (Array i64)]
  [inputs : CompilerIrPhiInputList]) : unit
  (match inputs
    [(IrPhiInputNil) unit]
    [(IrPhiInputCons value _ rest)
      (begin
        (compiler-backend-count-value-use counts value)
        (compiler-backend-count-phi-input-uses counts (box-get rest)))]))

(define (compiler-backend-count-instr-uses
  [counts : (Array i64)]
  [instr : CompilerIrInstr]) : unit
  (match instr
    [(IrInstrMov _ src _) (compiler-backend-count-value-use counts src)]
    [(IrInstrAddrOf _ src) (compiler-backend-use-count-inc counts src)]
    [(IrInstrGep _ base offset _)
      (begin
        (compiler-backend-count-value-use counts base)
        (compiler-backend-count-value-use counts offset))]
    [(IrInstrLoad _ src _) (compiler-backend-count-value-use counts src)]
    [(IrInstrStorePtr dst src _)
      (begin
        (compiler-backend-count-value-use counts dst)
        (compiler-backend-count-value-use counts src))]
    [(IrInstrCopyBytes dst src _)
      (begin
        (compiler-backend-count-value-use counts dst)
        (compiler-backend-count-value-use counts src))]
    [(IrInstrBoundsCheck index length _)
      (begin
        (compiler-backend-count-value-use counts index)
        (compiler-backend-count-value-use counts length))]
    [(IrInstrCast _ src _ _) (compiler-backend-count-value-use counts src)]
    [(IrInstrBitcast _ src _ _) (compiler-backend-count-value-use counts src)]
    [(IrInstrBinOp _ _ lhs rhs _)
      (begin
        (compiler-backend-count-value-use counts lhs)
        (compiler-backend-count-value-use counts rhs))]
    [(IrInstrUnOp _ _ src _) (compiler-backend-count-value-use counts src)]
    [(IrInstrSplat _ value _ _) (compiler-backend-count-value-use counts value)]
    [(IrInstrVectorBinOp _ _ lhs rhs _ _)
      (begin
        (compiler-backend-count-value-use counts lhs)
        (compiler-backend-count-value-use counts rhs))]
    [(IrInstrVectorReduce _ _ src _ _)
      (compiler-backend-count-value-use counts src)]
    [(IrInstrVectorCompare _ _ lhs rhs _ _)
      (begin
        (compiler-backend-count-value-use counts lhs)
        (compiler-backend-count-value-use counts rhs))]
    [(IrInstrMaskBinOp _ _ lhs rhs _)
      (begin
        (compiler-backend-count-value-use counts lhs)
        (compiler-backend-count-value-use counts rhs))]
    [(IrInstrMaskNot _ src _) (compiler-backend-count-value-use counts src)]
    [(IrInstrMaskReduce _ _ src _)
      (compiler-backend-count-value-use counts src)]
    [(IrInstrSelect _ mask on-true on-false _ _)
      (begin
        (compiler-backend-count-value-use counts mask)
        (compiler-backend-count-value-use counts on-true)
        (compiler-backend-count-value-use counts on-false))]
    [(IrInstrVectorLoad _ base index _ _)
      (begin
        (compiler-backend-count-value-use counts base)
        (compiler-backend-count-value-use counts index))]
    [(IrInstrVectorStore base index value _ _)
      (begin
        (compiler-backend-count-value-use counts base)
        (compiler-backend-count-value-use counts index)
        (compiler-backend-count-value-use counts value))]
    [(IrInstrPredicatedStore base index value mask _ _)
      (begin
        (compiler-backend-count-value-use counts base)
        (compiler-backend-count-value-use counts index)
        (compiler-backend-count-value-use counts value)
        (compiler-backend-count-value-use counts mask))]
    [(IrInstrPredicatedLoad _ base index mask _ _)
      (begin
        (compiler-backend-count-value-use counts base)
        (compiler-backend-count-value-use counts index)
        (compiler-backend-count-value-use counts mask))]
    [(IrInstrTailMask _ index length _)
      (begin
        (compiler-backend-count-value-use counts index)
        (compiler-backend-count-value-use counts length))]
    [(IrInstrEntryArgc _) unit]
    [(IrInstrEntryArgv _) unit]
    [(IrInstrEntryEnvp _) unit]
    [(IrInstrCpuId _ leaf subleaf _)
      (begin
        (compiler-backend-count-value-use counts leaf)
        (compiler-backend-count-value-use counts subleaf))]
    [(IrInstrXgetbv _ index) (compiler-backend-count-value-use counts index)]
    [(IrInstrSyscall _ args)
      (compiler-backend-count-call-args-uses counts args)]
    [(IrInstrCall _ _ args _)
      (compiler-backend-count-call-args-uses counts args)]
    [(IrInstrCallIndirect _ callee args _)
      (begin
        (compiler-backend-count-value-use counts callee)
        (compiler-backend-count-call-args-uses counts args))]
    [(IrInstrCallIndirectC _ callee args _)
      (begin
        (compiler-backend-count-value-use counts callee)
        (compiler-backend-count-call-args-uses counts args))]
    [(IrInstrCallCAbiStoreResult base _ args _)
      (begin
        (compiler-backend-count-value-use counts base)
        (compiler-backend-count-call-args-uses counts args))]
    [(IrInstrCallIndirectCAbiStoreResult base callee args _)
      (begin
        (compiler-backend-count-value-use counts base)
        (compiler-backend-count-value-use counts callee)
        (compiler-backend-count-call-args-uses counts args))]
    [(IrInstrTailCall _ args _)
      (compiler-backend-count-call-args-uses counts args)]
    [(IrInstrTailCallIndirect callee args _)
      (begin
        (compiler-backend-count-value-use counts callee)
        (compiler-backend-count-call-args-uses counts args))]
    [(IrInstrStore _ value _) (compiler-backend-count-value-use counts value)]
    [(IrInstrBranch cond _ _) (compiler-backend-count-value-use counts cond)]
    [(IrInstrReturn maybe)
      (match maybe
        [(IrNoValue) unit]
        [(IrSomeValue value) (compiler-backend-count-value-use counts value)])]
    [(IrInstrPhi _ inputs _)
      (compiler-backend-count-phi-input-uses counts inputs)]
    ;; #2386 register-group instrs: count their operand uses so the
    ;; single-use fusion peepholes cannot elide the home store of a var a
    ;; Pack/Word still reads (-O2 copy-prop substitutes vars directly into
    ;; Pack/Word operands).
    [(IrInstrPack _ words _)
      (compiler-backend-count-value-list-uses counts words)]
    [(IrInstrWord _ src _ _) (compiler-backend-count-value-use counts src)]
    ;; Operand-free IR instructions intentionally add no value uses.
    [(IrInstrAlloc _ _) unit]
    [(IrInstrLaneId _ _ _) unit]
    [(IrInstrEntryArgc _) unit]
    [(IrInstrEntryArgv _) unit]
    [(IrInstrEntryEnvp _) unit]
    [(IrInstrJump _) unit]))

(define (compiler-backend-count-instr-seq-uses
  [counts : (Array i64)]
  [instrs : CompilerIrInstrSeq]) : unit
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (compiler-backend-count-instr-uses counts (array-ref slots index))
          (set! index (+ index 1))))
      unit)))

(define (compiler-backend-count-block-uses
  [counts : (Array i64)]
  [blocks : CompilerIrBlockList]) : unit
  (match blocks
    [(IrBlockNil) unit]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (begin
            (compiler-backend-count-instr-seq-uses counts instrs)
            (compiler-backend-count-block-uses counts (box-get rest)))])]
    [(IrBlockArray seq)
      (compiler-backend-count-block-uses
        counts
        (compiler-ir-block-seq-to-list seq))]))

(define (compiler-backend-function-use-counts
  [vars : i64]
  [blocks : CompilerIrBlockList]) : (Array i64)
  (let
    [counts : (Array i64) (make-array i64 vars)]
    (begin
      (compiler-backend-count-block-uses counts blocks)
      counts)))

(define (compiler-backend-var-single-use? [counts : (Array i64)] [var : i64]) : bool
  (if (< var 0)
    false
    (if (>= var (array-length counts))
      false
      (= (array-ref counts var) 1))))

(define (compiler-backend-addr-of-forwarding-fill!
  [items : (Array i64)]
  [index : i64]) : unit
  (if (>= index (array-length items))
    unit
    (begin
      (array-set! items index (- 0 1))
      (compiler-backend-addr-of-forwarding-fill! items (+ index 1)))))

(define (compiler-backend-addr-of-forwarding-record!
  [items : (Array i64)]
  [use-counts : (Array i64)]
  [instr : CompilerIrInstr]) : unit
  (match instr
    [(IrInstrAddrOf dst src)
      (if (and
        (>= dst 0)
        (< dst (array-length items))
        (compiler-backend-var-single-use? use-counts dst))
        (array-set! items dst src)
        unit)]
    [_ unit]))

(define (compiler-backend-addr-of-forwarding-record-seq!
  [items : (Array i64)]
  [use-counts : (Array i64)]
  [instrs : CompilerIrInstrSeq]) : unit
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (compiler-backend-addr-of-forwarding-record!
            items
            use-counts
            (array-ref slots index))
          (set! index (+ index 1))))
      unit)))

(define (compiler-backend-addr-of-forwarding-record-blocks!
  [items : (Array i64)]
  [use-counts : (Array i64)]
  [blocks : CompilerIrBlockList]) : unit
  (match blocks
    [(IrBlockNil) unit]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (begin
            (compiler-backend-addr-of-forwarding-record-seq!
              items
              use-counts
              instrs)
            (compiler-backend-addr-of-forwarding-record-blocks!
              items
              use-counts
              (box-get rest)))])]
    [(IrBlockArray seq)
      (compiler-backend-addr-of-forwarding-record-blocks!
        items
        use-counts
        (compiler-ir-block-seq-to-list seq))]))

(define (compiler-backend-addr-of-forwarding-enable!
  [vars : i64]
  [blocks : CompilerIrBlockList]
  [use-counts : (Array i64)]) : unit
  (let
    [items : (Array i64) (make-array i64 vars)]
    (begin
      (compiler-backend-addr-of-forwarding-fill! items 0)
      (compiler-backend-addr-of-forwarding-record-blocks!
        items
        use-counts
        blocks)
      (set! compiler-backend-addr-of-forwarding-src items)
      (set! compiler-backend-addr-of-forwarding-enabled true))))

(define (compiler-backend-addr-of-forwarding-disable!) : unit
  (begin
    (set! compiler-backend-addr-of-forwarding-enabled false)
    (set! compiler-backend-addr-of-forwarding-src (make-array i64 0))))

(define (compiler-backend-branch-uses-var? [cond : CompilerIrValue] [var : i64]) : bool
  (match cond
    [(IrValueVar id) (= id var)]
    [_ false]))

(define (compiler-backend-rest-starts-load-compare-branch?
  [rest : CompilerIrInstrList]
  [load-dst : i64]
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [use-counts : (Array i64)]) : bool
  (match rest
    [(IrInstrCons maybe-cmp after-cmp)
      (match maybe-cmp
        [(IrInstrBinOp cmp-dst op lhs rhs cmp-ty)
          (if (and
            (compiler-backend-compare-op? op)
            (compiler-backend-branch-uses-var? lhs load-dst)
            (compiler-backend-var-single-use? use-counts cmp-dst)
            (not
              (compiler-backend-binop-f64? types global-types lhs rhs cmp-ty)))
            (match (box-get after-cmp)
              [(IrInstrCons branch _)
                (match branch
                  [(IrInstrBranch cond _ _)
                    (compiler-backend-branch-uses-var? cond cmp-dst)]
                  [_ false])]
              [_ false])
            false)]
        [_ false])]
    [_ false]))

(define (compiler-backend-fused-compare-fallthrough
  [rest : CompilerIrInstrList]
  [fallthrough : CompilerBackendMaybeLabel]) : CompilerBackendMaybeLabel
  (match rest
    [(IrInstrNil) fallthrough]
    [_ (CompilerBackendNoLabel)]))

;; A block-terminator fusion (mov/call/binop directly into a return) emits the
;; whole tail of the block and does not recurse, so it must flush the buffer of
;; the instructions already emitted before it: render buf followed by the
;; terminator's asm.
(define (compiler-backend-emit-terminator-into
  [result : ResultCompilerBackend]
  [buf : TextBuf]) : ResultCompilerBackend
  (match result
    [(OkCompilerBackend asm)
      (OkCompilerBackend (text-buf-render (text-buf-append buf asm)))]
    [(ErrCompilerBackend message) (ErrCompilerBackend message)]))

(define (compiler-backend-emit-instrs-normal
  [target : CompilerBackendTarget]
  [function : String]
  [source-function : String]
  [blocks : CompilerIrBlockList]
  [current-label : String]
  [fallthrough : CompilerBackendMaybeLabel]
  [instr : CompilerIrInstr]
  [rest : CompilerIrInstrList]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [ret-ty : AstType]
  [plan : CompilerBackendRuntimePlan]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [program-index : CompilerBackendProgramIndex]
  [spans : CompilerSourceSpans]
  [func-diag : CompilerDiagnostic]
  [use-counts : (Array i64)]
  [buf : TextBuf]) : ResultCompilerBackend
  (match (compiler-backend-emit-instr
    target
    function
    source-function
    blocks
    current-label
    (match rest
      [(IrInstrNil) fallthrough]
      [_ (CompilerBackendNoLabel)])
    instr
    assignments
    vars
    types
    global-types
    ret-ty
    plan
    functions
    externs
    program-index
    spans
    func-diag)
    [(OkCompilerBackend head)
      (compiler-backend-emit-instrs
        target
        function
        source-function
        blocks
        current-label
        fallthrough
        rest
        assignments
        vars
        types
        global-types
        ret-ty
        plan
        functions
        externs
        program-index
        spans
        func-diag
        use-counts
        (text-buf-append buf head))]
    [(ErrCompilerBackend message) (ErrCompilerBackend message)]))

(define (compiler-backend-emit-fused-result-rest
  [target : CompilerBackendTarget]
  [function : String]
  [source-function : String]
  [blocks : CompilerIrBlockList]
  [current-label : String]
  [fallthrough : CompilerBackendMaybeLabel]
  [result : ResultCompilerBackend]
  [rest : CompilerIrInstrList]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [ret-ty : AstType]
  [plan : CompilerBackendRuntimePlan]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [program-index : CompilerBackendProgramIndex]
  [spans : CompilerSourceSpans]
  [func-diag : CompilerDiagnostic]
  [use-counts : (Array i64)]
  [buf : TextBuf]) : ResultCompilerBackend
  (match result
    [(OkCompilerBackend head)
      (compiler-backend-emit-instrs
        target
        function
        source-function
        blocks
        current-label
        fallthrough
        rest
        assignments
        vars
        types
        global-types
        ret-ty
        plan
        functions
        externs
        program-index
        spans
        func-diag
        use-counts
        (text-buf-append buf head))]
    [(ErrCompilerBackend message) (ErrCompilerBackend message)]))

(define (compiler-backend-rax-forwardable-consumer?
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [assignments : CompilerRegAssignmentList]
  [rax-var : i64]
  [instr : CompilerIrInstr]) : bool
  (match instr
    [(IrInstrBinOp _ op lhs rhs ty)
      (and
        (compiler-backend-rax-forwardable-binop?
          types
          global-types
          assignments
          op
          lhs
          rhs
          ty)
        (or
          (compiler-backend-branch-uses-var? lhs rax-var)
          (and
            (compiler-backend-branch-uses-var? rhs rax-var)
            (compiler-backend-commutative-binop? op))))]
    [(IrInstrMov _ src _) (compiler-backend-branch-uses-var? src rax-var)]
    [(IrInstrReturn maybe)
      (match maybe
        [(IrSomeValue value) (compiler-backend-branch-uses-var? value rax-var)]
        [(IrNoValue) false])]
    [_ false]))

(define (compiler-backend-rest-starts-rax-forwardable-consumer?
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [assignments : CompilerRegAssignmentList]
  [rax-var : i64]
  [rest : CompilerIrInstrList]) : bool
  (match rest
    [(IrInstrCons instr _)
      (compiler-backend-rax-forwardable-consumer?
        types
        global-types
        assignments
        rax-var
        instr)]
    [(IrInstrNil) false]))

(define (compiler-backend-emit-instrs-materialize-rax
  [target : CompilerBackendTarget]
  [function : String]
  [source-function : String]
  [blocks : CompilerIrBlockList]
  [current-label : String]
  [fallthrough : CompilerBackendMaybeLabel]
  [rax-var : i64]
  [rax-ty : AstType]
  [instrs : CompilerIrInstrList]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [ret-ty : AstType]
  [plan : CompilerBackendRuntimePlan]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [program-index : CompilerBackendProgramIndex]
  [spans : CompilerSourceSpans]
  [func-diag : CompilerDiagnostic]
  [use-counts : (Array i64)]
  [buf : TextBuf]) : ResultCompilerBackend
  (compiler-backend-emit-instrs
    target
    function
    source-function
    blocks
    current-label
    fallthrough
    instrs
    assignments
    vars
    types
    global-types
    ret-ty
    plan
    functions
    externs
    program-index
    spans
    func-diag
    use-counts
    (text-buf-append
      buf
      (compiler-backend-emit-store-typed-var-with-plan
        assignments
        rax-var
        "%rax"
        rax-ty))))

(define (compiler-backend-emit-instrs-with-rax
  [target : CompilerBackendTarget]
  [function : String]
  [source-function : String]
  [blocks : CompilerIrBlockList]
  [current-label : String]
  [fallthrough : CompilerBackendMaybeLabel]
  [rax-var : i64]
  [rax-ty : AstType]
  [instrs : CompilerIrInstrList]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [ret-ty : AstType]
  [plan : CompilerBackendRuntimePlan]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [program-index : CompilerBackendProgramIndex]
  [spans : CompilerSourceSpans]
  [func-diag : CompilerDiagnostic]
  [use-counts : (Array i64)]
  [buf : TextBuf]) : ResultCompilerBackend
  (match instrs
    [(IrInstrNil)
      (OkCompilerBackend
        (text-buf-render
          (text-buf-append
            buf
            (compiler-backend-emit-store-typed-var-with-plan
              assignments
              rax-var
              "%rax"
              rax-ty))))]
    [(IrInstrCons instr rest)
      (match instr
        [(IrInstrBinOp dst op lhs rhs ty)
          (if (compiler-backend-rax-forwardable-consumer?
            types
            global-types
            assignments
            rax-var
            instr)
            (let
              [keep-live : bool
                (compiler-backend-var-single-use? use-counts dst)]
              (match (compiler-backend-emit-binop-with-rax-value
                types
                global-types
                assignments
                rax-var
                dst
                op
                lhs
                rhs
                ty
                (not keep-live))
                [(OkCompilerBackend head)
                  (if keep-live
                    (compiler-backend-emit-instrs-with-rax
                      target
                      function
                      source-function
                      blocks
                      current-label
                      fallthrough
                      dst
                      ty
                      (box-get rest)
                      assignments
                      vars
                      types
                      global-types
                      ret-ty
                      plan
                      functions
                      externs
                      program-index
                      spans
                      func-diag
                      use-counts
                      (text-buf-append buf head))
                    (compiler-backend-emit-instrs
                      target
                      function
                      source-function
                      blocks
                      current-label
                      fallthrough
                      (box-get rest)
                      assignments
                      vars
                      types
                      global-types
                      ret-ty
                      plan
                      functions
                      externs
                      program-index
                      spans
                      func-diag
                      use-counts
                      (text-buf-append buf head)))]
                [(ErrCompilerBackend message) (ErrCompilerBackend message)]))
            (compiler-backend-emit-instrs-materialize-rax
              target
              function
              source-function
              blocks
              current-label
              fallthrough
              rax-var
              rax-ty
              instrs
              assignments
              vars
              types
              global-types
              ret-ty
              plan
              functions
              externs
              program-index
              spans
              func-diag
              use-counts
              buf))]
        [(IrInstrMov dst src ty)
          (if (compiler-backend-branch-uses-var? src rax-var)
            (if (compiler-backend-var-single-use? use-counts dst)
              (compiler-backend-emit-instrs-with-rax
                target
                function
                source-function
                blocks
                current-label
                fallthrough
                dst
                ty
                (box-get rest)
                assignments
                vars
                types
                global-types
                ret-ty
                plan
                functions
                externs
                program-index
                spans
                func-diag
                use-counts
                buf)
              (compiler-backend-emit-instrs
                target
                function
                source-function
                blocks
                current-label
                fallthrough
                (box-get rest)
                assignments
                vars
                types
                global-types
                ret-ty
                plan
                functions
                externs
                program-index
                spans
                func-diag
                use-counts
                (text-buf-append
                  buf
                  (compiler-backend-emit-store-typed-var-with-plan
                    assignments
                    dst
                    "%rax"
                    ty))))
            (compiler-backend-emit-instrs-materialize-rax
              target
              function
              source-function
              blocks
              current-label
              fallthrough
              rax-var
              rax-ty
              instrs
              assignments
              vars
              types
              global-types
              ret-ty
              plan
              functions
              externs
              program-index
              spans
              func-diag
              use-counts
              buf))]
        [(IrInstrReturn maybe)
          (match maybe
            [(IrSomeValue value)
              (if (and
                (compiler-backend-branch-uses-var? value rax-var)
                (match (box-get rest)
                  [(IrInstrNil) true]
                  [_ false]))
                (OkCompilerBackend
                  (text-buf-render
                    (text-buf-append
                      buf
                      (compiler-backend-return-tail
                        source-function
                        assignments
                        vars
                        blocks))))
                (compiler-backend-emit-instrs-materialize-rax
                  target
                  function
                  source-function
                  blocks
                  current-label
                  fallthrough
                  rax-var
                  rax-ty
                  instrs
                  assignments
                  vars
                  types
                  global-types
                  ret-ty
                  plan
                  functions
                  externs
                  program-index
                  spans
                  func-diag
                  use-counts
                  buf))]
            [(IrNoValue)
              (compiler-backend-emit-instrs-materialize-rax
                target
                function
                source-function
                blocks
                current-label
                fallthrough
                rax-var
                rax-ty
                instrs
                assignments
                vars
                types
                global-types
                ret-ty
                plan
                functions
                externs
                program-index
                spans
                func-diag
                use-counts
                buf)])]
        [_
          (compiler-backend-emit-instrs-materialize-rax
            target
            function
            source-function
            blocks
            current-label
            fallthrough
            rax-var
            rax-ty
            instrs
            assignments
            vars
            types
            global-types
            ret-ty
            plan
            functions
            externs
            program-index
            spans
            func-diag
            use-counts
            buf)])]))

(define (compiler-backend-emit-fused-compare-branch-rest
  [target : CompilerBackendTarget]
  [function : String]
  [source-function : String]
  [blocks : CompilerIrBlockList]
  [current-label : String]
  [fallthrough : CompilerBackendMaybeLabel]
  [dst : i64]
  [op : CompilerIrBinOp]
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [ty : AstType]
  [true-label : String]
  [false-label : String]
  [rest : CompilerIrInstrList]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [ret-ty : AstType]
  [plan : CompilerBackendRuntimePlan]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [program-index : CompilerBackendProgramIndex]
  [spans : CompilerSourceSpans]
  [func-diag : CompilerDiagnostic]
  [use-counts : (Array i64)]
  [buf : TextBuf]) : ResultCompilerBackend
  (match (compiler-backend-emit-compare-branch-with-phi-copies
    assignments
    function
    blocks
    current-label
    op
    lhs
    rhs
    (compiler-backend-binop-operand-ty types global-types op lhs rhs ty)
    true-label
    false-label
    (compiler-backend-fused-compare-fallthrough rest fallthrough)
    program-index
    vars)
    [(OkCompilerBackend head)
      (compiler-backend-emit-instrs
        target
        function
        source-function
        blocks
        current-label
        fallthrough
        rest
        assignments
        vars
        types
        global-types
        ret-ty
        plan
        functions
        externs
        program-index
        spans
        func-diag
        use-counts
        (text-buf-append buf head))]
    [(ErrCompilerBackend message)
      (ErrCompilerBackend
        (compiler-backend-apply-instr-diagnostic
          message
          (compiler-backend-instr-diagnostic
            spans
            source-function
            (IrInstrBinOp dst op lhs rhs ty)
            func-diag
            "")))]))

(define (compiler-backend-emit-fused-load-compare-branch-rest
  [target : CompilerBackendTarget]
  [function : String]
  [source-function : String]
  [blocks : CompilerIrBlockList]
  [current-label : String]
  [fallthrough : CompilerBackendMaybeLabel]
  [load-dst : i64]
  [ptr : CompilerIrValue]
  [load-ty : AstType]
  [_cmp-dst : i64]
  [op : CompilerIrBinOp]
  [rhs : CompilerIrValue]
  [cmp-ty : AstType]
  [true-label : String]
  [false-label : String]
  [rest : CompilerIrInstrList]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [ret-ty : AstType]
  [plan : CompilerBackendRuntimePlan]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [program-index : CompilerBackendProgramIndex]
  [spans : CompilerSourceSpans]
  [func-diag : CompilerDiagnostic]
  [use-counts : (Array i64)]
  [buf : TextBuf]) : ResultCompilerBackend
  (match (compiler-backend-emit-load-compare-branch-with-phi-copies
    assignments
    function
    blocks
    current-label
    ptr
    op
    rhs
    cmp-ty
    true-label
    false-label
    (compiler-backend-fused-compare-fallthrough rest fallthrough)
    program-index
    vars)
    [(OkCompilerBackend head)
      (compiler-backend-emit-instrs
        target
        function
        source-function
        blocks
        current-label
        fallthrough
        rest
        assignments
        vars
        types
        global-types
        ret-ty
        plan
        functions
        externs
        program-index
        spans
        func-diag
        use-counts
        (text-buf-append buf head))]
    [(ErrCompilerBackend message)
      (ErrCompilerBackend
        (compiler-backend-apply-instr-diagnostic
          message
          (compiler-backend-instr-diagnostic
            spans
            source-function
            (IrInstrLoad load-dst ptr load-ty)
            func-diag
            "")))]))

(define (compiler-backend-emit-fused-gep-load-compare-branch-rest
  [target : CompilerBackendTarget]
  [function : String]
  [source-function : String]
  [blocks : CompilerIrBlockList]
  [current-label : String]
  [fallthrough : CompilerBackendMaybeLabel]
  [gep-dst : i64]
  [base : CompilerIrValue]
  [offset : CompilerIrValue]
  [elem-ty : AstType]
  [_load-dst : i64]
  [_load-ty : AstType]
  [_cmp-dst : i64]
  [op : CompilerIrBinOp]
  [rhs : CompilerIrValue]
  [cmp-ty : AstType]
  [true-label : String]
  [false-label : String]
  [rest : CompilerIrInstrList]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [ret-ty : AstType]
  [plan : CompilerBackendRuntimePlan]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [program-index : CompilerBackendProgramIndex]
  [spans : CompilerSourceSpans]
  [func-diag : CompilerDiagnostic]
  [use-counts : (Array i64)]
  [buf : TextBuf]) : ResultCompilerBackend
  (match (compiler-backend-emit-gep-load-compare-branch-with-phi-copies
    assignments
    function
    blocks
    current-label
    base
    offset
    elem-ty
    op
    rhs
    cmp-ty
    true-label
    false-label
    (compiler-backend-fused-compare-fallthrough rest fallthrough)
    program-index
    vars)
    [(OkCompilerBackend head)
      (compiler-backend-emit-instrs
        target
        function
        source-function
        blocks
        current-label
        fallthrough
        rest
        assignments
        vars
        types
        global-types
        ret-ty
        plan
        functions
        externs
        program-index
        spans
        func-diag
        use-counts
        (text-buf-append buf head))]
    [(ErrCompilerBackend message)
      (ErrCompilerBackend
        (compiler-backend-apply-instr-diagnostic
          message
          (compiler-backend-instr-diagnostic
            spans
            source-function
            (IrInstrGep gep-dst base offset elem-ty)
            func-diag
            "")))]))

(define (compiler-backend-emit-fused-gep-load-rest
  [target : CompilerBackendTarget]
  [function : String]
  [source-function : String]
  [blocks : CompilerIrBlockList]
  [current-label : String]
  [fallthrough : CompilerBackendMaybeLabel]
  [_gep-dst : i64]
  [base : CompilerIrValue]
  [offset : CompilerIrValue]
  [elem-ty : AstType]
  [load-dst : i64]
  [load-ty : AstType]
  [rest : CompilerIrInstrList]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [ret-ty : AstType]
  [plan : CompilerBackendRuntimePlan]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [program-index : CompilerBackendProgramIndex]
  [spans : CompilerSourceSpans]
  [func-diag : CompilerDiagnostic]
  [use-counts : (Array i64)]
  [buf : TextBuf]) : ResultCompilerBackend
  (let
    [single : ResultCompilerBackend
      (compiler-backend-emit-load-from-gep
        assignments
        load-dst
        base
        offset
        elem-ty
        load-ty)]
    (match (compiler-backend-value-as-i64 offset)
      [(CompilerBackendSomeI64 _)
        (match rest
          [(IrInstrCons maybe-gep after-gep)
            (match maybe-gep
              [(IrInstrGep gep-dst2 base2 offset2 elem-ty2)
                (if (and
                  (compiler-backend-var-single-use? use-counts gep-dst2)
                  (opt-value-eq base2 base))
                  (match (compiler-backend-value-as-i64 offset2)
                    [(CompilerBackendSomeI64 _)
                      (match (box-get after-gep)
                        [(IrInstrCons maybe-load after-load2)
                          (match maybe-load
                            [(IrInstrLoad load-dst2 src2 load-ty2)
                              (if (and
                                (compiler-backend-branch-uses-var?
                                  src2
                                  gep-dst2)
                                (not
                                  (and
                                    (compiler-backend-load-compare-type?
                                      load-ty2)
                                    (compiler-backend-var-single-use?
                                      use-counts
                                      load-dst2)
                                    (compiler-backend-rest-starts-load-compare-branch?
                                      (box-get after-load2)
                                      load-dst2
                                      types
                                      global-types
                                      use-counts))))
                                (compiler-backend-emit-fused-result-rest
                                  target
                                  function
                                  source-function
                                  blocks
                                  current-label
                                  fallthrough
                                  (compiler-backend-emit-load-from-gep-pair
                                    assignments
                                    base
                                    offset
                                    elem-ty
                                    load-dst
                                    load-ty
                                    offset2
                                    elem-ty2
                                    load-dst2
                                    load-ty2)
                                  (box-get after-load2)
                                  assignments
                                  vars
                                  types
                                  global-types
                                  ret-ty
                                  plan
                                  functions
                                  externs
                                  program-index
                                  spans
                                  func-diag
                                  use-counts
                                  buf)
                                (compiler-backend-emit-fused-result-rest
                                  target
                                  function
                                  source-function
                                  blocks
                                  current-label
                                  fallthrough
                                  single
                                  rest
                                  assignments
                                  vars
                                  types
                                  global-types
                                  ret-ty
                                  plan
                                  functions
                                  externs
                                  program-index
                                  spans
                                  func-diag
                                  use-counts
                                  buf))]
                            [_
                              (compiler-backend-emit-fused-result-rest
                                target
                                function
                                source-function
                                blocks
                                current-label
                                fallthrough
                                single
                                rest
                                assignments
                                vars
                                types
                                global-types
                                ret-ty
                                plan
                                functions
                                externs
                                program-index
                                spans
                                func-diag
                                use-counts
                                buf)])]
                        [_
                          (compiler-backend-emit-fused-result-rest
                            target
                            function
                            source-function
                            blocks
                            current-label
                            fallthrough
                            single
                            rest
                            assignments
                            vars
                            types
                            global-types
                            ret-ty
                            plan
                            functions
                            externs
                            program-index
                            spans
                            func-diag
                            use-counts
                            buf)])]
                    [(CompilerBackendNoI64)
                      (compiler-backend-emit-fused-result-rest
                        target
                        function
                        source-function
                        blocks
                        current-label
                        fallthrough
                        single
                        rest
                        assignments
                        vars
                        types
                        global-types
                        ret-ty
                        plan
                        functions
                        externs
                        program-index
                        spans
                        func-diag
                        use-counts
                        buf)])
                  (compiler-backend-emit-fused-result-rest
                    target
                    function
                    source-function
                    blocks
                    current-label
                    fallthrough
                    single
                    rest
                    assignments
                    vars
                    types
                    global-types
                    ret-ty
                    plan
                    functions
                    externs
                    program-index
                    spans
                    func-diag
                    use-counts
                    buf))]
              [_
                (compiler-backend-emit-fused-result-rest
                  target
                  function
                  source-function
                  blocks
                  current-label
                  fallthrough
                  single
                  rest
                  assignments
                  vars
                  types
                  global-types
                  ret-ty
                  plan
                  functions
                  externs
                  program-index
                  spans
                  func-diag
                  use-counts
                  buf)])]
          [_
            (compiler-backend-emit-fused-result-rest
              target
              function
              source-function
              blocks
              current-label
              fallthrough
              single
              rest
              assignments
              vars
              types
              global-types
              ret-ty
              plan
              functions
              externs
              program-index
              spans
              func-diag
              use-counts
              buf)])]
      [(CompilerBackendNoI64)
        (compiler-backend-emit-fused-result-rest
          target
          function
          source-function
          blocks
          current-label
          fallthrough
          single
          rest
          assignments
          vars
          types
          global-types
          ret-ty
          plan
          functions
          externs
          program-index
          spans
          func-diag
          use-counts
          buf)])))

(define (compiler-backend-emit-fused-gep-store-rest
  [target : CompilerBackendTarget]
  [function : String]
  [source-function : String]
  [blocks : CompilerIrBlockList]
  [current-label : String]
  [fallthrough : CompilerBackendMaybeLabel]
  [gep-dst : i64]
  [base : CompilerIrValue]
  [offset : CompilerIrValue]
  [elem-ty : AstType]
  [value : CompilerIrValue]
  [store-ty : AstType]
  [rest : CompilerIrInstrList]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [ret-ty : AstType]
  [plan : CompilerBackendRuntimePlan]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [program-index : CompilerBackendProgramIndex]
  [spans : CompilerSourceSpans]
  [func-diag : CompilerDiagnostic]
  [use-counts : (Array i64)]
  [buf : TextBuf]) : ResultCompilerBackend
  (match (compiler-backend-emit-store-to-gep
    assignments
    base
    offset
    elem-ty
    value
    store-ty
    program-index)
    [(OkCompilerBackend head)
      (compiler-backend-emit-instrs
        target
        function
        source-function
        blocks
        current-label
        fallthrough
        rest
        assignments
        vars
        types
        global-types
        ret-ty
        plan
        functions
        externs
        program-index
        spans
        func-diag
        use-counts
        (text-buf-append buf head))]
    [(ErrCompilerBackend message)
      (ErrCompilerBackend
        (compiler-backend-apply-instr-diagnostic
          message
          (compiler-backend-instr-diagnostic
            spans
            source-function
            (IrInstrGep gep-dst base offset elem-ty)
            func-diag
            "")))]))

(define (compiler-backend-emit-fused-mov-trivial-phi-return-rest
  [target : CompilerBackendTarget]
  [function : String]
  [source-function : String]
  [blocks : CompilerIrBlockList]
  [current-label : String]
  [fallthrough : CompilerBackendMaybeLabel]
  [dst : i64]
  [src : CompilerIrValue]
  [ty : AstType]
  [target-label : String]
  [after-jump : CompilerIrInstrList]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [ret-ty : AstType]
  [plan : CompilerBackendRuntimePlan]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [program-index : CompilerBackendProgramIndex]
  [spans : CompilerSourceSpans]
  [func-diag : CompilerDiagnostic]
  [use-counts : (Array i64)]
  [buf : TextBuf]) : ResultCompilerBackend
  (match (compiler-backend-emit-mov-trivial-phi-return-edge
    source-function
    blocks
    target-label
    current-label
    assignments
    vars
    ret-ty
    dst
    src
    program-index)
    [(OkCompilerBackend direct-return)
      (if (string-eq direct-return "")
        (if (compiler-backend-var-single-use? use-counts dst)
          (match (compiler-backend-emit-mov-phi-copy-edge
            assignments
            blocks
            target-label
            current-label
            dst
            src
            program-index
            vars)
            [(OkCompilerBackend fused-copies)
              (if (string-eq fused-copies "")
                (compiler-backend-emit-instrs-normal
                  target
                  function
                  source-function
                  blocks
                  current-label
                  fallthrough
                  (IrInstrMov dst src ty)
                  (compiler-ir-instr-cons (IrInstrJump target-label) after-jump)
                  assignments
                  vars
                  types
                  global-types
                  ret-ty
                  plan
                  functions
                  externs
                  program-index
                  spans
                  func-diag
                  use-counts
                  buf)
                (match (compiler-backend-emit-trivial-phi-return-edge
                  source-function
                  blocks
                  target-label
                  current-label
                  assignments
                  vars
                  ret-ty
                  program-index)
                  [(OkCompilerBackend plain-direct-return)
                    (compiler-backend-emit-instrs
                      target
                      function
                      source-function
                      blocks
                      current-label
                      fallthrough
                      after-jump
                      assignments
                      vars
                      types
                      global-types
                      ret-ty
                      plan
                      functions
                      externs
                      program-index
                      spans
                      func-diag
                      use-counts
                      (text-buf-append
                        buf
                        (if (string-eq plain-direct-return "")
                          (string-append
                            fused-copies
                            (if (compiler-backend-jump-target-is-fallthrough?
                              target-label
                              fallthrough)
                              ""
                              (compiler-backend-jump-label
                                function
                                target-label)))
                          plain-direct-return)))]
                  [(ErrCompilerBackend message)
                    (ErrCompilerBackend
                      (compiler-backend-apply-instr-diagnostic
                        message
                        (compiler-backend-instr-diagnostic
                          spans
                          source-function
                          (IrInstrMov dst src ty)
                          func-diag
                          "")))]))]
            [(ErrCompilerBackend message)
              (ErrCompilerBackend
                (compiler-backend-apply-instr-diagnostic
                  message
                  (compiler-backend-instr-diagnostic
                    spans
                    source-function
                    (IrInstrMov dst src ty)
                    func-diag
                    "")))])
          (compiler-backend-emit-instrs-normal
            target
            function
            source-function
            blocks
            current-label
            fallthrough
            (IrInstrMov dst src ty)
            (compiler-ir-instr-cons (IrInstrJump target-label) after-jump)
            assignments
            vars
            types
            global-types
            ret-ty
            plan
            functions
            externs
            program-index
            spans
            func-diag
            use-counts
            buf))
        (compiler-backend-emit-instrs
          target
          function
          source-function
          blocks
          current-label
          fallthrough
          after-jump
          assignments
          vars
          types
          global-types
          ret-ty
          plan
          functions
          externs
          program-index
          spans
          func-diag
          use-counts
          (text-buf-append buf direct-return)))]
    [(ErrCompilerBackend message)
      (ErrCompilerBackend
        (compiler-backend-apply-instr-diagnostic
          message
          (compiler-backend-instr-diagnostic
            spans
            source-function
            (IrInstrMov dst src ty)
            func-diag
            "")))]))

(define (compiler-backend-emit-call-return
  [target : CompilerBackendTarget]
  [source-function : String]
  [blocks : CompilerIrBlockList]
  [name : String]
  [args : CompilerIrCallArgs]
  [assignments : CompilerRegAssignmentList]
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [vars : i64]
  [plan : CompilerBackendRuntimePlan]
  [_functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [program-index : CompilerBackendProgramIndex]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (let
    [param-types : AstTypeList
      (compiler-backend-call-param-types-for-call
        name
        args
        types
        global-types
        externs
        program-index)]
    [c-abi? : bool (compiler-backend-c-aggregate-extern-call? externs name)]
    [call-space : i64
      (compiler-backend-call-arg-space
        target
        args
        param-types
        c-abi?
        program-index)]
    (match (compiler-backend-emit-call-args
      target
      assignments
      args
      param-types
      c-abi?
      0
      0
      0
      0
      0
      instr-diag
      program-index
      vars)
      [(OkCompilerBackend args-asm)
        (OkCompilerBackend
          (string-append
            (compiler-backend-emit-call-space-sub call-space)
            (string-append
              args-asm
              (string-append
                (compiler-backend-varargs-pre-call
                  target
                  name
                  externs
                  param-types)
                (str-cat
                  "    call "
                  (compiler-backend-call-symbol-index name plan program-index)
                  "\n"
                  (string-append
                    (compiler-backend-emit-call-space-add call-space)
                    (compiler-backend-return-tail
                      source-function
                      assignments
                      vars
                      blocks))
                  "")))))]
      [(ErrCompilerBackend message)
        (ErrCompilerBackend
          (compiler-backend-apply-instr-diagnostic message instr-diag))])))

(define (compiler-backend-indirect-call-param-types
  [types : CompilerRegVarTypeList]
  [func : CompilerIrValue]
  [_functions : CompilerIrFunctionList]
  [_externs : CompilerIrExternList]
  [program-index : CompilerBackendProgramIndex]) : AstTypeList
  (match func
    [(IrValueFunction name)
      (match (compiler-backend-index-signature program-index name)
        [(CompilerBackendSomeSignature param-types _) param-types]
        [(CompilerBackendNoSignature) AstTypeNil])]
    [_
      (match (compiler-backend-value-type
        types
        (CompilerBackendGlobalTypeNil)
        func)
        [(CompilerRegSomeType ty)
          (match ty
            [(AstTyFunc param-types _) param-types]
            [_ AstTypeNil])]
        [(CompilerRegNoType) AstTypeNil])]))

(define (compiler-backend-indirect-tail-call-register-only?
  [target : CompilerBackendTarget]
  [args : CompilerIrCallArgs]
  [types : AstTypeList]
  [program-index : CompilerBackendProgramIndex]) : bool
  (=
    (compiler-backend-call-stack-arg-count
      target
      args
      types
      false
      0
      1
      0
      1
      0
      program-index)
    0))

(define (compiler-backend-emit-indirect-call
  [target : CompilerBackendTarget]
  [dst : i64]
  [func : CompilerIrValue]
  [args : CompilerIrCallArgs]
  [ty : AstType]
  [assignments : CompilerRegAssignmentList]
  [types : CompilerRegVarTypeList]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [program-index : CompilerBackendProgramIndex]
  [vars : i64]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (let
    [param-types : AstTypeList
      (compiler-backend-indirect-call-param-types
        types
        func
        functions
        externs
        program-index)]
    [call-space : i64
      (compiler-backend-closure-call-arg-space
        target
        args
        param-types
        program-index)]
    (match (compiler-backend-emit-call-args
      target
      assignments
      args
      param-types
      false
      0
      1
      0
      1
      0
      instr-diag
      program-index
      ;; vars must be the real frame var count: group-word1 slots live at
      ;; -(8*(vars+var+1))(%rbp), so 0 here made a stack-homed group arg read
      ;; its word0 slot for BOTH words (#2386 closure-arg miscompile).
      vars)
      [(OkCompilerBackend args-asm)
        (match (compiler-backend-emit-load-value-with-plan
          assignments
          func
          "%r11")
          [(OkCompilerBackend func-asm)
            (match (compiler-backend-target-arg-reg target 0)
              [(OkBackendReg env-reg)
                (match (compiler-backend-emit-call-result-store
                  assignments
                  dst
                  ty
                  vars
                  program-index)
                  [(OkCompilerBackend result-store)
                    (OkCompilerBackend
                      (string-append
                        (compiler-backend-emit-call-space-sub call-space)
                        (string-append
                          args-asm
                          (string-append
                            func-asm
                            (str-cat
                              "    movq 8(%r11), "
                              env-reg
                              "\n    call *(%r11)\n"
                              (string-append
                                (compiler-backend-emit-call-space-add
                                  call-space)
                                result-store)
                              "")))))]
                  [(ErrCompilerBackend message)
                    (ErrCompilerBackend
                      (compiler-backend-apply-instr-diagnostic
                        message
                        instr-diag))])]
              [(ErrBackendReg message)
                (ErrCompilerBackend
                  (compiler-diagnostic-with-message instr-diag message))])]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(ErrCompilerBackend message)
        (ErrCompilerBackend
          (compiler-backend-apply-instr-diagnostic message instr-diag))])))

(define (compiler-backend-emit-tail-indirect-call
  [target : CompilerBackendTarget]
  [source-function : String]
  [blocks : CompilerIrBlockList]
  [func : CompilerIrValue]
  [args : CompilerIrCallArgs]
  [ty : AstType]
  [assignments : CompilerRegAssignmentList]
  [types : CompilerRegVarTypeList]
  [vars : i64]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [program-index : CompilerBackendProgramIndex]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (let
    [param-types : AstTypeList
      (compiler-backend-indirect-call-param-types
        types
        func
        functions
        externs
        program-index)]
    [call-space : i64
      (compiler-backend-closure-call-arg-space
        target
        args
        param-types
        program-index)]
    [register-only : bool
      (compiler-backend-indirect-tail-call-register-only?
        target
        args
        param-types
        program-index)]
    (match (compiler-backend-emit-call-args
      target
      assignments
      args
      param-types
      false
      0
      1
      0
      1
      0
      instr-diag
      program-index
      vars)
      [(OkCompilerBackend args-asm)
        (match (compiler-backend-emit-load-value-with-plan
          assignments
          func
          "%r11")
          [(OkCompilerBackend func-asm)
            (match (compiler-backend-target-arg-reg target 0)
              [(OkBackendReg env-reg)
                (let
                  [descriptor-asm : String
                    (str-cat func-asm "    movq 8(%r11), " env-reg "\n" "")]
                  (if register-only
                    (OkCompilerBackend
                      (string-append
                        args-asm
                        (string-append
                          descriptor-asm
                          (compiler-backend-tail-jump-tail
                            assignments
                            vars
                            "*(%r11)"))))
                    (OkCompilerBackend
                      (string-append
                        (compiler-backend-emit-call-space-sub call-space)
                        (string-append
                          args-asm
                          (string-append
                            descriptor-asm
                            (str-cat
                              "    call *(%r11)\n"
                              (compiler-backend-emit-call-space-add call-space)
                              (string-append
                                (compiler-backend-tail-call-return-normalize ty)
                                (compiler-backend-return-tail
                                  source-function
                                  assignments
                                  vars
                                  blocks))
                              ""
                              "")))))))]
              [(ErrBackendReg message)
                (ErrCompilerBackend
                  (compiler-diagnostic-with-message instr-diag message))])]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(ErrCompilerBackend message)
        (ErrCompilerBackend
          (compiler-backend-apply-instr-diagnostic message instr-diag))])))

(define (compiler-backend-emit-indirect-c-call
  [target : CompilerBackendTarget]
  [dst : i64]
  [func : CompilerIrValue]
  [args : CompilerIrCallArgs]
  [ty : AstType]
  [assignments : CompilerRegAssignmentList]
  [types : CompilerRegVarTypeList]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [program-index : CompilerBackendProgramIndex]
  [vars : i64]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (let
    [declared-param-types : AstTypeList
      (compiler-backend-indirect-call-param-types
        types
        func
        functions
        externs
        program-index)]
    [param-types : AstTypeList
      (if (compiler-backend-type-list-has-aggregate? declared-param-types)
        (compiler-backend-call-c-abi-param-types
          types
          (CompilerBackendGlobalTypeNil)
          args
          declared-param-types
          program-index)
        (if (=
          (compiler-backend-call-args-count args)
          (compiler-backend-type-list-count declared-param-types))
          declared-param-types
          (compiler-backend-call-actual-param-types
            types
            (CompilerBackendGlobalTypeNil)
            args)))]
    [call-space : i64
      (compiler-backend-call-arg-space
        target
        args
        param-types
        true
        program-index)]
    (match (compiler-backend-emit-call-args
      target
      assignments
      args
      param-types
      true
      0
      0
      0
      0
      0
      instr-diag
      program-index
      ;; Real frame var count for group-word1 slot addressing (see
      ;; emit-indirect-call): latent today because C-ABI lowering never passes
      ;; 16-byte aggregates by value, but keep it correct.
      vars)
      [(OkCompilerBackend args-asm)
        (match (compiler-backend-emit-load-value-with-plan
          assignments
          func
          "%rax")
          [(OkCompilerBackend func-asm)
            (OkCompilerBackend
              (string-append
                (compiler-backend-emit-call-space-sub call-space)
                (string-append
                  args-asm
                  (string-append
                    func-asm
                    (str-cat
                      "    call *%rax\n"
                      (compiler-backend-emit-call-space-add call-space)
                      (compiler-backend-emit-store-typed-var-with-plan
                        assignments
                        dst
                        (if (compiler-backend-float-type? ty)
                          "%xmm0"
                          "%rax")
                        ty)
                      ""
                      "")))))]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(ErrCompilerBackend message)
        (ErrCompilerBackend
          (compiler-backend-apply-instr-diagnostic message instr-diag))])))

(define (compiler-backend-emit-c-abi-store-result-call
  [target : CompilerBackendTarget]
  [base : CompilerIrValue]
  [name : String]
  [args : CompilerIrCallArgs]
  [slots : CompilerIrCAbiReturnSlotList]
  [assignments : CompilerRegAssignmentList]
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [plan : CompilerBackendRuntimePlan]
  [externs : CompilerIrExternList]
  [program-index : CompilerBackendProgramIndex]
  [vars : i64]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (let
    [param-types : AstTypeList
      (compiler-backend-call-param-types-for-call
        name
        args
        types
        global-types
        externs
        program-index)]
    [c-abi? : bool (compiler-backend-c-aggregate-extern-call? externs name)]
    [call-space : i64
      (compiler-backend-call-arg-space
        target
        args
        param-types
        c-abi?
        program-index)]
    [total-space : i64 (+ call-space 16)]
    [call-symbol : String
      (compiler-backend-call-symbol-index name plan program-index)]
    (match (compiler-backend-emit-call-args
      target
      assignments
      args
      param-types
      c-abi?
      0
      0
      0
      0
      0
      instr-diag
      program-index
      vars)
      [(OkCompilerBackend args-asm)
        (match (compiler-backend-emit-c-abi-return-base-save
          assignments
          base
          call-space)
          [(OkCompilerBackend base-save)
            (OkCompilerBackend
              (string-append
                (compiler-backend-emit-call-space-sub total-space)
                (string-append
                  args-asm
                  (string-append
                    base-save
                    (string-append
                      (compiler-backend-varargs-pre-call
                        target
                        name
                        externs
                        param-types)
                      (str-cat
                        "    call "
                        call-symbol
                        "\n"
                        (string-append
                          (compiler-backend-emit-c-abi-return-stores
                            call-space
                            slots)
                          (compiler-backend-emit-call-space-add total-space))
                        ""))))))]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(ErrCompilerBackend message)
        (ErrCompilerBackend
          (compiler-backend-apply-instr-diagnostic message instr-diag))])))

(define (compiler-backend-emit-indirect-c-abi-store-result-call
  [target : CompilerBackendTarget]
  [base : CompilerIrValue]
  [func : CompilerIrValue]
  [args : CompilerIrCallArgs]
  [slots : CompilerIrCAbiReturnSlotList]
  [assignments : CompilerRegAssignmentList]
  [types : CompilerRegVarTypeList]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [program-index : CompilerBackendProgramIndex]
  [vars : i64]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (let
    [declared-param-types : AstTypeList
      (compiler-backend-indirect-call-param-types
        types
        func
        functions
        externs
        program-index)]
    [param-types : AstTypeList
      (if (compiler-backend-type-list-has-aggregate? declared-param-types)
        (compiler-backend-call-c-abi-param-types
          types
          (CompilerBackendGlobalTypeNil)
          args
          declared-param-types
          program-index)
        (if (=
          (compiler-backend-call-args-count args)
          (compiler-backend-type-list-count declared-param-types))
          declared-param-types
          (compiler-backend-call-actual-param-types
            types
            (CompilerBackendGlobalTypeNil)
            args)))]
    [call-space : i64
      (compiler-backend-call-arg-space
        target
        args
        param-types
        true
        program-index)]
    [total-space : i64 (+ call-space 16)]
    (match (compiler-backend-emit-call-args
      target
      assignments
      args
      param-types
      true
      0
      0
      0
      0
      0
      instr-diag
      program-index
      vars)
      [(OkCompilerBackend args-asm)
        (match (compiler-backend-emit-c-abi-return-base-save
          assignments
          base
          call-space)
          [(OkCompilerBackend base-save)
            (match (compiler-backend-emit-load-value-with-plan
              assignments
              func
              "%rax")
              [(OkCompilerBackend func-asm)
                (OkCompilerBackend
                  (string-append
                    (compiler-backend-emit-call-space-sub total-space)
                    (string-append
                      args-asm
                      (string-append
                        base-save
                        (string-append
                          func-asm
                          (backend-cat5
                            "    call *%rax\n"
                            (compiler-backend-emit-c-abi-return-stores
                              call-space
                              slots)
                            (compiler-backend-emit-call-space-add total-space)
                            ""
                            ""))))))]
              [(ErrCompilerBackend message)
                (ErrCompilerBackend
                  (compiler-backend-apply-instr-diagnostic message instr-diag))])]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(ErrCompilerBackend message)
        (ErrCompilerBackend
          (compiler-backend-apply-instr-diagnostic message instr-diag))])))

(define (compiler-backend-emit-instrs
  [target : CompilerBackendTarget]
  [function : String]
  [source-function : String]
  [blocks : CompilerIrBlockList]
  [current-label : String]
  [fallthrough : CompilerBackendMaybeLabel]
  [instrs : CompilerIrInstrList]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [ret-ty : AstType]
  [plan : CompilerBackendRuntimePlan]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [program-index : CompilerBackendProgramIndex]
  [spans : CompilerSourceSpans]
  [func-diag : CompilerDiagnostic]
  [use-counts : (Array i64)]
  [buf : TextBuf]) : ResultCompilerBackend
  (match instrs
    [(IrInstrNil) (OkCompilerBackend (text-buf-render buf))]
    [(IrInstrCons instr rest)
      (match instr
        [(IrInstrMov dst src ty)
          (match (box-get rest)
            [(IrInstrCons next after-jump)
              (match next
                [(IrInstrCast cast-dst cast-src _ _)
                  (match (box-get after-jump)
                    [(IrInstrCons after-cast after-binop)
                      (match after-cast
                        [(IrInstrBinOp bin-dst op lhs rhs bin-ty)
                          (if (and
                            (compiler-backend-divmod-op? op)
                            (compiler-backend-branch-uses-var? cast-src dst)
                            (compiler-backend-branch-uses-var? rhs cast-dst)
                            (compiler-backend-var-single-use? use-counts dst)
                            (compiler-backend-var-single-use?
                              use-counts
                              cast-dst)
                            (compiler-backend-divmod-safe-literal? src bin-ty))
                            (match (compiler-backend-emit-binop
                              types
                              global-types
                              assignments
                              bin-dst
                              op
                              lhs
                              src
                              bin-ty)
                              [(OkCompilerBackend binop-asm)
                                (compiler-backend-emit-instrs
                                  target
                                  function
                                  source-function
                                  blocks
                                  current-label
                                  fallthrough
                                  (box-get after-binop)
                                  assignments
                                  vars
                                  types
                                  global-types
                                  ret-ty
                                  plan
                                  functions
                                  externs
                                  program-index
                                  spans
                                  func-diag
                                  use-counts
                                  (text-buf-append buf binop-asm))]
                              [(ErrCompilerBackend message)
                                (ErrCompilerBackend message)])
                            (compiler-backend-emit-instrs-normal
                              target
                              function
                              source-function
                              blocks
                              current-label
                              fallthrough
                              instr
                              (box-get rest)
                              assignments
                              vars
                              types
                              global-types
                              ret-ty
                              plan
                              functions
                              externs
                              program-index
                              spans
                              func-diag
                              use-counts
                              buf))]
                        [_
                          (compiler-backend-emit-instrs-normal
                            target
                            function
                            source-function
                            blocks
                            current-label
                            fallthrough
                            instr
                            (box-get rest)
                            assignments
                            vars
                            types
                            global-types
                            ret-ty
                            plan
                            functions
                            externs
                            program-index
                            spans
                            func-diag
                            use-counts
                            buf)])]
                    [_
                      (compiler-backend-emit-instrs-normal
                        target
                        function
                        source-function
                        blocks
                        current-label
                        fallthrough
                        instr
                        (box-get rest)
                        assignments
                        vars
                        types
                        global-types
                        ret-ty
                        plan
                        functions
                        externs
                        program-index
                        spans
                        func-diag
                        use-counts
                        buf)])]
                [(IrInstrBinOp bin-dst op lhs rhs bin-ty)
                  (if (and
                    (compiler-backend-divmod-op? op)
                    (compiler-backend-branch-uses-var? rhs dst)
                    (compiler-backend-divmod-safe-literal? src bin-ty))
                    (match (if (compiler-backend-var-single-use? use-counts dst)
                      (OkCompilerBackend "")
                      (compiler-backend-emit-mov
                        assignments
                        dst
                        src
                        ty
                        program-index
                        vars))
                      [(OkCompilerBackend prefix)
                        (match (compiler-backend-emit-binop
                          types
                          global-types
                          assignments
                          bin-dst
                          op
                          lhs
                          src
                          bin-ty)
                          [(OkCompilerBackend binop-asm)
                            (compiler-backend-emit-instrs
                              target
                              function
                              source-function
                              blocks
                              current-label
                              fallthrough
                              (box-get after-jump)
                              assignments
                              vars
                              types
                              global-types
                              ret-ty
                              plan
                              functions
                              externs
                              program-index
                              spans
                              func-diag
                              use-counts
                              (text-buf-append
                                (text-buf-append buf prefix)
                                binop-asm))]
                          [(ErrCompilerBackend message)
                            (ErrCompilerBackend message)])]
                      [(ErrCompilerBackend message)
                        (ErrCompilerBackend message)])
                    (compiler-backend-emit-instrs-normal
                      target
                      function
                      source-function
                      blocks
                      current-label
                      fallthrough
                      instr
                      (box-get rest)
                      assignments
                      vars
                      types
                      global-types
                      ret-ty
                      plan
                      functions
                      externs
                      program-index
                      spans
                      func-diag
                      use-counts
                      buf))]
                [(IrInstrJump target-label)
                  (compiler-backend-emit-fused-mov-trivial-phi-return-rest
                    target
                    function
                    source-function
                    blocks
                    current-label
                    fallthrough
                    dst
                    src
                    ty
                    target-label
                    (box-get after-jump)
                    assignments
                    vars
                    types
                    global-types
                    ret-ty
                    plan
                    functions
                    externs
                    program-index
                    spans
                    func-diag
                    use-counts
                    buf)]
                [(IrInstrReturn maybe)
                  (match (box-get after-jump)
                    [(IrInstrNil)
                      (match maybe
                        [(IrSomeValue value)
                          (if (compiler-backend-branch-uses-var? value dst)
                            (match (compiler-backend-emit-return
                              source-function
                              blocks
                              (IrSomeValue src)
                              assignments
                              vars
                              ret-ty
                              program-index)
                              [(OkCompilerBackend asm)
                                (OkCompilerBackend
                                  (text-buf-render (text-buf-append buf asm)))]
                              [(ErrCompilerBackend message)
                                (ErrCompilerBackend
                                  (compiler-backend-apply-instr-diagnostic
                                    message
                                    (compiler-backend-instr-diagnostic
                                      spans
                                      source-function
                                      instr
                                      func-diag
                                      "")))])
                            (compiler-backend-emit-instrs-normal
                              target
                              function
                              source-function
                              blocks
                              current-label
                              fallthrough
                              instr
                              (box-get rest)
                              assignments
                              vars
                              types
                              global-types
                              ret-ty
                              plan
                              functions
                              externs
                              program-index
                              spans
                              func-diag
                              use-counts
                              buf))]
                        [(IrNoValue)
                          (compiler-backend-emit-instrs-normal
                            target
                            function
                            source-function
                            blocks
                            current-label
                            fallthrough
                            instr
                            (box-get rest)
                            assignments
                            vars
                            types
                            global-types
                            ret-ty
                            plan
                            functions
                            externs
                            program-index
                            spans
                            func-diag
                            use-counts
                            buf)])]
                    [_
                      (compiler-backend-emit-instrs-normal
                        target
                        function
                        source-function
                        blocks
                        current-label
                        fallthrough
                        instr
                        (box-get rest)
                        assignments
                        vars
                        types
                        global-types
                        ret-ty
                        plan
                        functions
                        externs
                        program-index
                        spans
                        func-diag
                        use-counts
                        buf)])]
                [_
                  (compiler-backend-emit-instrs-normal
                    target
                    function
                    source-function
                    blocks
                    current-label
                    fallthrough
                    instr
                    (box-get rest)
                    assignments
                    vars
                    types
                    global-types
                    ret-ty
                    plan
                    functions
                    externs
                    program-index
                    spans
                    func-diag
                    use-counts
                    buf)])]
            [_
              (compiler-backend-emit-instrs-normal
                target
                function
                source-function
                blocks
                current-label
                fallthrough
                instr
                (box-get rest)
                assignments
                vars
                types
                global-types
                ret-ty
                plan
                functions
                externs
                program-index
                spans
                func-diag
                use-counts
                buf)])]
        [(IrInstrCall dst name args ty)
          (match (box-get rest)
            [(IrInstrCons next after-return)
              (match next
                [(IrInstrReturn maybe)
                  (match (box-get after-return)
                    [(IrInstrNil)
                      (match maybe
                        [(IrSomeValue value)
                          (if (and
                            (compiler-backend-branch-uses-var? value dst)
                            (opt-type-eq ty ret-ty))
                            (compiler-backend-emit-terminator-into
                              (compiler-backend-emit-call-return
                                target
                                source-function
                                blocks
                                name
                                args
                                assignments
                                types
                                global-types
                                vars
                                plan
                                functions
                                externs
                                program-index
                                (compiler-backend-instr-diagnostic
                                  spans
                                  source-function
                                  instr
                                  func-diag
                                  ""))
                              buf)
                            (compiler-backend-emit-instrs-normal
                              target
                              function
                              source-function
                              blocks
                              current-label
                              fallthrough
                              instr
                              (box-get rest)
                              assignments
                              vars
                              types
                              global-types
                              ret-ty
                              plan
                              functions
                              externs
                              program-index
                              spans
                              func-diag
                              use-counts
                              buf))]
                        [(IrNoValue)
                          (compiler-backend-emit-instrs-normal
                            target
                            function
                            source-function
                            blocks
                            current-label
                            fallthrough
                            instr
                            (box-get rest)
                            assignments
                            vars
                            types
                            global-types
                            ret-ty
                            plan
                            functions
                            externs
                            program-index
                            spans
                            func-diag
                            use-counts
                            buf)])]
                    [_
                      (compiler-backend-emit-instrs-normal
                        target
                        function
                        source-function
                        blocks
                        current-label
                        fallthrough
                        instr
                        (box-get rest)
                        assignments
                        vars
                        types
                        global-types
                        ret-ty
                        plan
                        functions
                        externs
                        program-index
                        spans
                        func-diag
                        use-counts
                        buf)])]
                [_
                  (compiler-backend-emit-instrs-normal
                    target
                    function
                    source-function
                    blocks
                    current-label
                    fallthrough
                    instr
                    (box-get rest)
                    assignments
                    vars
                    types
                    global-types
                    ret-ty
                    plan
                    functions
                    externs
                    program-index
                    spans
                    func-diag
                    use-counts
                    buf)])]
            [_
              (compiler-backend-emit-instrs-normal
                target
                function
                source-function
                blocks
                current-label
                fallthrough
                instr
                (box-get rest)
                assignments
                vars
                types
                global-types
                ret-ty
                plan
                functions
                externs
                program-index
                spans
                func-diag
                use-counts
                buf)])]
        [(IrInstrStorePtr ptr value0 ty0)
          (match (box-get rest)
            [(IrInstrCons maybe-gep after-gep)
              (match maybe-gep
                [(IrInstrGep gep-dst base offset elem-ty)
                  (if (and
                    (opt-value-eq base ptr)
                    (compiler-backend-var-single-use? use-counts gep-dst))
                    (match (compiler-backend-value-as-i64 offset)
                      [(CompilerBackendSomeI64 n)
                        (let
                          [disp : i64
                            (* n (compiler-backend-type-size elem-ty))]
                          (if (compiler-backend-imm32? disp)
                            (match (box-get after-gep)
                              [(IrInstrCons maybe-store after-store)
                                (match maybe-store
                                  [(IrInstrStorePtr dst value1 ty1)
                                    (if (compiler-backend-branch-uses-var?
                                      dst
                                      gep-dst)
                                      (compiler-backend-emit-fused-result-rest
                                        target
                                        function
                                        source-function
                                        blocks
                                        current-label
                                        fallthrough
                                        (compiler-backend-emit-store-ptr-pair
                                          assignments
                                          ptr
                                          value0
                                          ty0
                                          disp
                                          value1
                                          ty1
                                          program-index)
                                        (box-get after-store)
                                        assignments
                                        vars
                                        types
                                        global-types
                                        ret-ty
                                        plan
                                        functions
                                        externs
                                        program-index
                                        spans
                                        func-diag
                                        use-counts
                                        buf)
                                      (compiler-backend-emit-instrs-normal
                                        target
                                        function
                                        source-function
                                        blocks
                                        current-label
                                        fallthrough
                                        instr
                                        (box-get rest)
                                        assignments
                                        vars
                                        types
                                        global-types
                                        ret-ty
                                        plan
                                        functions
                                        externs
                                        program-index
                                        spans
                                        func-diag
                                        use-counts
                                        buf))]
                                  [_
                                    (compiler-backend-emit-instrs-normal
                                      target
                                      function
                                      source-function
                                      blocks
                                      current-label
                                      fallthrough
                                      instr
                                      (box-get rest)
                                      assignments
                                      vars
                                      types
                                      global-types
                                      ret-ty
                                      plan
                                      functions
                                      externs
                                      program-index
                                      spans
                                      func-diag
                                      use-counts
                                      buf)])]
                              [_
                                (compiler-backend-emit-instrs-normal
                                  target
                                  function
                                  source-function
                                  blocks
                                  current-label
                                  fallthrough
                                  instr
                                  (box-get rest)
                                  assignments
                                  vars
                                  types
                                  global-types
                                  ret-ty
                                  plan
                                  functions
                                  externs
                                  program-index
                                  spans
                                  func-diag
                                  use-counts
                                  buf)])
                            (compiler-backend-emit-instrs-normal
                              target
                              function
                              source-function
                              blocks
                              current-label
                              fallthrough
                              instr
                              (box-get rest)
                              assignments
                              vars
                              types
                              global-types
                              ret-ty
                              plan
                              functions
                              externs
                              program-index
                              spans
                              func-diag
                              use-counts
                              buf)))]
                      [(CompilerBackendNoI64)
                        (compiler-backend-emit-instrs-normal
                          target
                          function
                          source-function
                          blocks
                          current-label
                          fallthrough
                          instr
                          (box-get rest)
                          assignments
                          vars
                          types
                          global-types
                          ret-ty
                          plan
                          functions
                          externs
                          program-index
                          spans
                          func-diag
                          use-counts
                          buf)])
                    (compiler-backend-emit-instrs-normal
                      target
                      function
                      source-function
                      blocks
                      current-label
                      fallthrough
                      instr
                      (box-get rest)
                      assignments
                      vars
                      types
                      global-types
                      ret-ty
                      plan
                      functions
                      externs
                      program-index
                      spans
                      func-diag
                      use-counts
                      buf))]
                [_
                  (compiler-backend-emit-instrs-normal
                    target
                    function
                    source-function
                    blocks
                    current-label
                    fallthrough
                    instr
                    (box-get rest)
                    assignments
                    vars
                    types
                    global-types
                    ret-ty
                    plan
                    functions
                    externs
                    program-index
                    spans
                    func-diag
                    use-counts
                    buf)])]
            [_
              (compiler-backend-emit-instrs-normal
                target
                function
                source-function
                blocks
                current-label
                fallthrough
                instr
                (box-get rest)
                assignments
                vars
                types
                global-types
                ret-ty
                plan
                functions
                externs
                program-index
                spans
                func-diag
                use-counts
                buf)])]
        [(IrInstrGep gep-dst base offset elem-ty)
          (if (compiler-backend-var-single-use? use-counts gep-dst)
            (match (compiler-backend-value-as-i64 offset)
              [(CompilerBackendSomeI64 n)
                (match (box-get rest)
                  [(IrInstrCons next after-load)
                    (match next
                      [(IrInstrLoad load-dst src load-ty)
                        (if (compiler-backend-branch-uses-var? src gep-dst)
                          (if (and
                            (compiler-backend-load-compare-type? load-ty)
                            (compiler-backend-var-single-use?
                              use-counts
                              load-dst))
                            (match (box-get after-load)
                              [(IrInstrCons maybe-cmp after-cmp)
                                (match maybe-cmp
                                  [(IrInstrBinOp cmp-dst op lhs rhs cmp-ty)
                                    (if (and
                                      (compiler-backend-compare-op? op)
                                      (compiler-backend-branch-uses-var?
                                        lhs
                                        load-dst)
                                      (compiler-backend-var-single-use?
                                        use-counts
                                        cmp-dst)
                                      (not
                                        (compiler-backend-binop-f64?
                                          types
                                          global-types
                                          lhs
                                          rhs
                                          cmp-ty)))
                                      (match (box-get after-cmp)
                                        [(IrInstrCons branch after-branch)
                                          (match branch
                                            [(IrInstrBranch
                                                cond
                                                true-label
                                                false-label)
                                              (if (compiler-backend-branch-uses-var?
                                                cond
                                                cmp-dst)
                                                (compiler-backend-emit-fused-gep-load-compare-branch-rest
                                                  target
                                                  function
                                                  source-function
                                                  blocks
                                                  current-label
                                                  fallthrough
                                                  gep-dst
                                                  base
                                                  offset
                                                  elem-ty
                                                  load-dst
                                                  load-ty
                                                  cmp-dst
                                                  op
                                                  rhs
                                                  cmp-ty
                                                  true-label
                                                  false-label
                                                  (box-get after-branch)
                                                  assignments
                                                  vars
                                                  types
                                                  global-types
                                                  ret-ty
                                                  plan
                                                  functions
                                                  externs
                                                  program-index
                                                  spans
                                                  func-diag
                                                  use-counts
                                                  buf)
                                                (compiler-backend-emit-fused-gep-load-rest
                                                  target
                                                  function
                                                  source-function
                                                  blocks
                                                  current-label
                                                  fallthrough
                                                  gep-dst
                                                  base
                                                  offset
                                                  elem-ty
                                                  load-dst
                                                  load-ty
                                                  (box-get after-load)
                                                  assignments
                                                  vars
                                                  types
                                                  global-types
                                                  ret-ty
                                                  plan
                                                  functions
                                                  externs
                                                  program-index
                                                  spans
                                                  func-diag
                                                  use-counts
                                                  buf))]
                                            [_
                                              (compiler-backend-emit-fused-gep-load-rest
                                                target
                                                function
                                                source-function
                                                blocks
                                                current-label
                                                fallthrough
                                                gep-dst
                                                base
                                                offset
                                                elem-ty
                                                load-dst
                                                load-ty
                                                (box-get after-load)
                                                assignments
                                                vars
                                                types
                                                global-types
                                                ret-ty
                                                plan
                                                functions
                                                externs
                                                program-index
                                                spans
                                                func-diag
                                                use-counts
                                                buf)])]
                                        [_
                                          (compiler-backend-emit-fused-gep-load-rest
                                            target
                                            function
                                            source-function
                                            blocks
                                            current-label
                                            fallthrough
                                            gep-dst
                                            base
                                            offset
                                            elem-ty
                                            load-dst
                                            load-ty
                                            (box-get after-load)
                                            assignments
                                            vars
                                            types
                                            global-types
                                            ret-ty
                                            plan
                                            functions
                                            externs
                                            program-index
                                            spans
                                            func-diag
                                            use-counts
                                            buf)])
                                      (compiler-backend-emit-fused-gep-load-rest
                                        target
                                        function
                                        source-function
                                        blocks
                                        current-label
                                        fallthrough
                                        gep-dst
                                        base
                                        offset
                                        elem-ty
                                        load-dst
                                        load-ty
                                        (box-get after-load)
                                        assignments
                                        vars
                                        types
                                        global-types
                                        ret-ty
                                        plan
                                        functions
                                        externs
                                        program-index
                                        spans
                                        func-diag
                                        use-counts
                                        buf))]
                                  [_
                                    (compiler-backend-emit-fused-gep-load-rest
                                      target
                                      function
                                      source-function
                                      blocks
                                      current-label
                                      fallthrough
                                      gep-dst
                                      base
                                      offset
                                      elem-ty
                                      load-dst
                                      load-ty
                                      (box-get after-load)
                                      assignments
                                      vars
                                      types
                                      global-types
                                      ret-ty
                                      plan
                                      functions
                                      externs
                                      program-index
                                      spans
                                      func-diag
                                      use-counts
                                      buf)])]
                              [_
                                (compiler-backend-emit-fused-gep-load-rest
                                  target
                                  function
                                  source-function
                                  blocks
                                  current-label
                                  fallthrough
                                  gep-dst
                                  base
                                  offset
                                  elem-ty
                                  load-dst
                                  load-ty
                                  (box-get after-load)
                                  assignments
                                  vars
                                  types
                                  global-types
                                  ret-ty
                                  plan
                                  functions
                                  externs
                                  program-index
                                  spans
                                  func-diag
                                  use-counts
                                  buf)])
                            (compiler-backend-emit-fused-gep-load-rest
                              target
                              function
                              source-function
                              blocks
                              current-label
                              fallthrough
                              gep-dst
                              base
                              offset
                              elem-ty
                              load-dst
                              load-ty
                              (box-get after-load)
                              assignments
                              vars
                              types
                              global-types
                              ret-ty
                              plan
                              functions
                              externs
                              program-index
                              spans
                              func-diag
                              use-counts
                              buf))
                          (compiler-backend-emit-instrs-normal
                            target
                            function
                            source-function
                            blocks
                            current-label
                            fallthrough
                            instr
                            (box-get rest)
                            assignments
                            vars
                            types
                            global-types
                            ret-ty
                            plan
                            functions
                            externs
                            program-index
                            spans
                            func-diag
                            use-counts
                            buf))]
                      [(IrInstrStorePtr dst value store-ty)
                        (if (compiler-backend-branch-uses-var? dst gep-dst)
                          (compiler-backend-emit-fused-gep-store-rest
                            target
                            function
                            source-function
                            blocks
                            current-label
                            fallthrough
                            gep-dst
                            base
                            offset
                            elem-ty
                            value
                            store-ty
                            (box-get after-load)
                            assignments
                            vars
                            types
                            global-types
                            ret-ty
                            plan
                            functions
                            externs
                            program-index
                            spans
                            func-diag
                            use-counts
                            buf)
                          (compiler-backend-emit-instrs-normal
                            target
                            function
                            source-function
                            blocks
                            current-label
                            fallthrough
                            instr
                            (box-get rest)
                            assignments
                            vars
                            types
                            global-types
                            ret-ty
                            plan
                            functions
                            externs
                            program-index
                            spans
                            func-diag
                            use-counts
                            buf))]
                      [(IrInstrCopyBytes copy-dst copy-src copy-size)
                        (if (and
                          (compiler-backend-branch-uses-var? copy-dst gep-dst)
                          (compiler-backend-imm32?
                            (* n (compiler-backend-type-size elem-ty))))
                          (compiler-backend-emit-fused-result-rest
                            target
                            function
                            source-function
                            blocks
                            current-label
                            fallthrough
                            (compiler-backend-emit-copy-bytes-from-gep
                              assignments
                              base
                              offset
                              elem-ty
                              copy-src
                              copy-size)
                            (box-get after-load)
                            assignments
                            vars
                            types
                            global-types
                            ret-ty
                            plan
                            functions
                            externs
                            program-index
                            spans
                            func-diag
                            use-counts
                            buf)
                          (compiler-backend-emit-instrs-normal
                            target
                            function
                            source-function
                            blocks
                            current-label
                            fallthrough
                            instr
                            (box-get rest)
                            assignments
                            vars
                            types
                            global-types
                            ret-ty
                            plan
                            functions
                            externs
                            program-index
                            spans
                            func-diag
                            use-counts
                            buf))]
                      [_
                        (compiler-backend-emit-instrs-normal
                          target
                          function
                          source-function
                          blocks
                          current-label
                          fallthrough
                          instr
                          (box-get rest)
                          assignments
                          vars
                          types
                          global-types
                          ret-ty
                          plan
                          functions
                          externs
                          program-index
                          spans
                          func-diag
                          use-counts
                          buf)])]
                  [_
                    (compiler-backend-emit-instrs-normal
                      target
                      function
                      source-function
                      blocks
                      current-label
                      fallthrough
                      instr
                      (box-get rest)
                      assignments
                      vars
                      types
                      global-types
                      ret-ty
                      plan
                      functions
                      externs
                      program-index
                      spans
                      func-diag
                      use-counts
                      buf)])]
              [(CompilerBackendNoI64)
                (match (box-get rest)
                  [(IrInstrCons next after-gep)
                    (match next
                      [(IrInstrMov ptr-var src _)
                        (if (and
                          (compiler-backend-branch-uses-var? src gep-dst)
                          (compiler-backend-var-single-use? use-counts ptr-var))
                          (match (box-get after-gep)
                            [(IrInstrCons maybe-store after-store)
                              (match maybe-store
                                [(IrInstrStorePtr dst value store-ty)
                                  (if (compiler-backend-branch-uses-var?
                                    dst
                                    ptr-var)
                                    (compiler-backend-emit-fused-gep-store-rest
                                      target
                                      function
                                      source-function
                                      blocks
                                      current-label
                                      fallthrough
                                      gep-dst
                                      base
                                      offset
                                      elem-ty
                                      value
                                      store-ty
                                      (box-get after-store)
                                      assignments
                                      vars
                                      types
                                      global-types
                                      ret-ty
                                      plan
                                      functions
                                      externs
                                      program-index
                                      spans
                                      func-diag
                                      use-counts
                                      buf)
                                    (compiler-backend-emit-instrs-normal
                                      target
                                      function
                                      source-function
                                      blocks
                                      current-label
                                      fallthrough
                                      instr
                                      (box-get rest)
                                      assignments
                                      vars
                                      types
                                      global-types
                                      ret-ty
                                      plan
                                      functions
                                      externs
                                      program-index
                                      spans
                                      func-diag
                                      use-counts
                                      buf))]
                                [_
                                  (compiler-backend-emit-instrs-normal
                                    target
                                    function
                                    source-function
                                    blocks
                                    current-label
                                    fallthrough
                                    instr
                                    (box-get rest)
                                    assignments
                                    vars
                                    types
                                    global-types
                                    ret-ty
                                    plan
                                    functions
                                    externs
                                    program-index
                                    spans
                                    func-diag
                                    use-counts
                                    buf)])]
                            [_
                              (compiler-backend-emit-instrs-normal
                                target
                                function
                                source-function
                                blocks
                                current-label
                                fallthrough
                                instr
                                (box-get rest)
                                assignments
                                vars
                                types
                                global-types
                                ret-ty
                                plan
                                functions
                                externs
                                program-index
                                spans
                                func-diag
                                use-counts
                                buf)])
                          (compiler-backend-emit-instrs-normal
                            target
                            function
                            source-function
                            blocks
                            current-label
                            fallthrough
                            instr
                            (box-get rest)
                            assignments
                            vars
                            types
                            global-types
                            ret-ty
                            plan
                            functions
                            externs
                            program-index
                            spans
                            func-diag
                            use-counts
                            buf))]
                      [(IrInstrLoad load-dst src load-ty)
                        (if (compiler-backend-branch-uses-var? src gep-dst)
                          (compiler-backend-emit-fused-gep-load-rest
                            target
                            function
                            source-function
                            blocks
                            current-label
                            fallthrough
                            gep-dst
                            base
                            offset
                            elem-ty
                            load-dst
                            load-ty
                            (box-get after-gep)
                            assignments
                            vars
                            types
                            global-types
                            ret-ty
                            plan
                            functions
                            externs
                            program-index
                            spans
                            func-diag
                            use-counts
                            buf)
                          (compiler-backend-emit-instrs-normal
                            target
                            function
                            source-function
                            blocks
                            current-label
                            fallthrough
                            instr
                            (box-get rest)
                            assignments
                            vars
                            types
                            global-types
                            ret-ty
                            plan
                            functions
                            externs
                            program-index
                            spans
                            func-diag
                            use-counts
                            buf))]
                      [(IrInstrStorePtr dst value store-ty)
                        (if (compiler-backend-branch-uses-var? dst gep-dst)
                          (compiler-backend-emit-fused-gep-store-rest
                            target
                            function
                            source-function
                            blocks
                            current-label
                            fallthrough
                            gep-dst
                            base
                            offset
                            elem-ty
                            value
                            store-ty
                            (box-get after-gep)
                            assignments
                            vars
                            types
                            global-types
                            ret-ty
                            plan
                            functions
                            externs
                            program-index
                            spans
                            func-diag
                            use-counts
                            buf)
                          (compiler-backend-emit-instrs-normal
                            target
                            function
                            source-function
                            blocks
                            current-label
                            fallthrough
                            instr
                            (box-get rest)
                            assignments
                            vars
                            types
                            global-types
                            ret-ty
                            plan
                            functions
                            externs
                            program-index
                            spans
                            func-diag
                            use-counts
                            buf))]
                      [(IrInstrCopyBytes copy-dst copy-src copy-size)
                        (if (compiler-backend-branch-uses-var? copy-dst gep-dst)
                          (compiler-backend-emit-fused-result-rest
                            target
                            function
                            source-function
                            blocks
                            current-label
                            fallthrough
                            (compiler-backend-emit-copy-bytes-from-gep
                              assignments
                              base
                              offset
                              elem-ty
                              copy-src
                              copy-size)
                            (box-get after-gep)
                            assignments
                            vars
                            types
                            global-types
                            ret-ty
                            plan
                            functions
                            externs
                            program-index
                            spans
                            func-diag
                            use-counts
                            buf)
                          (compiler-backend-emit-instrs-normal
                            target
                            function
                            source-function
                            blocks
                            current-label
                            fallthrough
                            instr
                            (box-get rest)
                            assignments
                            vars
                            types
                            global-types
                            ret-ty
                            plan
                            functions
                            externs
                            program-index
                            spans
                            func-diag
                            use-counts
                            buf))]
                      [_
                        (compiler-backend-emit-instrs-normal
                          target
                          function
                          source-function
                          blocks
                          current-label
                          fallthrough
                          instr
                          (box-get rest)
                          assignments
                          vars
                          types
                          global-types
                          ret-ty
                          plan
                          functions
                          externs
                          program-index
                          spans
                          func-diag
                          use-counts
                          buf)])]
                  [_
                    (compiler-backend-emit-instrs-normal
                      target
                      function
                      source-function
                      blocks
                      current-label
                      fallthrough
                      instr
                      (box-get rest)
                      assignments
                      vars
                      types
                      global-types
                      ret-ty
                      plan
                      functions
                      externs
                      program-index
                      spans
                      func-diag
                      use-counts
                      buf)])])
            (compiler-backend-emit-instrs-normal
              target
              function
              source-function
              blocks
              current-label
              fallthrough
              instr
              (box-get rest)
              assignments
              vars
              types
              global-types
              ret-ty
              plan
              functions
              externs
              program-index
              spans
              func-diag
              use-counts
              buf))]
        [(IrInstrLoad load-dst ptr load-ty)
          (if (and
            (compiler-backend-load-compare-type? load-ty)
            (compiler-backend-var-single-use? use-counts load-dst))
            (match (box-get rest)
              [(IrInstrCons next after-cmp)
                (match next
                  [(IrInstrLoad second-dst second-src second-ty)
                    (if (compiler-backend-branch-uses-var? second-src load-dst)
                      (compiler-backend-emit-fused-result-rest
                        target
                        function
                        source-function
                        blocks
                        current-label
                        fallthrough
                        (compiler-backend-emit-load-load
                          assignments
                          load-dst
                          ptr
                          load-ty
                          second-dst
                          second-ty)
                        (box-get after-cmp)
                        assignments
                        vars
                        types
                        global-types
                        ret-ty
                        plan
                        functions
                        externs
                        program-index
                        spans
                        func-diag
                        use-counts
                        buf)
                      (compiler-backend-emit-instrs-normal
                        target
                        function
                        source-function
                        blocks
                        current-label
                        fallthrough
                        instr
                        (box-get rest)
                        assignments
                        vars
                        types
                        global-types
                        ret-ty
                        plan
                        functions
                        externs
                        program-index
                        spans
                        func-diag
                        use-counts
                        buf))]
                  [(IrInstrBinOp cmp-dst op lhs rhs cmp-ty)
                    (if (and
                      (compiler-backend-compare-op? op)
                      (compiler-backend-branch-uses-var? lhs load-dst)
                      (compiler-backend-var-single-use? use-counts cmp-dst)
                      (not
                        (compiler-backend-binop-f64?
                          types
                          global-types
                          lhs
                          rhs
                          cmp-ty)))
                      (match (box-get after-cmp)
                        [(IrInstrCons branch after-branch)
                          (match branch
                            [(IrInstrBranch cond true-label false-label)
                              (if (compiler-backend-branch-uses-var?
                                cond
                                cmp-dst)
                                (compiler-backend-emit-fused-load-compare-branch-rest
                                  target
                                  function
                                  source-function
                                  blocks
                                  current-label
                                  fallthrough
                                  load-dst
                                  ptr
                                  load-ty
                                  cmp-dst
                                  op
                                  rhs
                                  cmp-ty
                                  true-label
                                  false-label
                                  (box-get after-branch)
                                  assignments
                                  vars
                                  types
                                  global-types
                                  ret-ty
                                  plan
                                  functions
                                  externs
                                  program-index
                                  spans
                                  func-diag
                                  use-counts
                                  buf)
                                (compiler-backend-emit-instrs-normal
                                  target
                                  function
                                  source-function
                                  blocks
                                  current-label
                                  fallthrough
                                  instr
                                  (box-get rest)
                                  assignments
                                  vars
                                  types
                                  global-types
                                  ret-ty
                                  plan
                                  functions
                                  externs
                                  program-index
                                  spans
                                  func-diag
                                  use-counts
                                  buf))]
                            [_
                              (compiler-backend-emit-instrs-normal
                                target
                                function
                                source-function
                                blocks
                                current-label
                                fallthrough
                                instr
                                (box-get rest)
                                assignments
                                vars
                                types
                                global-types
                                ret-ty
                                plan
                                functions
                                externs
                                program-index
                                spans
                                func-diag
                                use-counts
                                buf)])]
                        [_
                          (compiler-backend-emit-instrs-normal
                            target
                            function
                            source-function
                            blocks
                            current-label
                            fallthrough
                            instr
                            (box-get rest)
                            assignments
                            vars
                            types
                            global-types
                            ret-ty
                            plan
                            functions
                            externs
                            program-index
                            spans
                            func-diag
                            use-counts
                            buf)])
                      (compiler-backend-emit-instrs-normal
                        target
                        function
                        source-function
                        blocks
                        current-label
                        fallthrough
                        instr
                        (box-get rest)
                        assignments
                        vars
                        types
                        global-types
                        ret-ty
                        plan
                        functions
                        externs
                        program-index
                        spans
                        func-diag
                        use-counts
                        buf))]
                  [_
                    (compiler-backend-emit-instrs-normal
                      target
                      function
                      source-function
                      blocks
                      current-label
                      fallthrough
                      instr
                      (box-get rest)
                      assignments
                      vars
                      types
                      global-types
                      ret-ty
                      plan
                      functions
                      externs
                      program-index
                      spans
                      func-diag
                      use-counts
                      buf)])]
              [_
                (compiler-backend-emit-instrs-normal
                  target
                  function
                  source-function
                  blocks
                  current-label
                  fallthrough
                  instr
                  (box-get rest)
                  assignments
                  vars
                  types
                  global-types
                  ret-ty
                  plan
                  functions
                  externs
                  program-index
                  spans
                  func-diag
                  use-counts
                  buf)])
            (compiler-backend-emit-instrs-normal
              target
              function
              source-function
              blocks
              current-label
              fallthrough
              instr
              (box-get rest)
              assignments
              vars
              types
              global-types
              ret-ty
              plan
              functions
              externs
              program-index
              spans
              func-diag
              use-counts
              buf))]
        [(IrInstrBinOp dst op lhs rhs ty)
          (if (and
            (compiler-backend-var-single-use? use-counts dst)
            (compiler-backend-rax-forwardable-binop?
              types
              global-types
              assignments
              op
              lhs
              rhs
              ty)
            (compiler-backend-rest-starts-rax-forwardable-consumer?
              types
              global-types
              assignments
              dst
              (box-get rest)))
            (match (compiler-backend-emit-binop-to-rax
              types
              global-types
              assignments
              dst
              op
              lhs
              rhs
              ty
              false)
              [(OkCompilerBackend head)
                (compiler-backend-emit-instrs-with-rax
                  target
                  function
                  source-function
                  blocks
                  current-label
                  fallthrough
                  dst
                  ty
                  (box-get rest)
                  assignments
                  vars
                  types
                  global-types
                  ret-ty
                  plan
                  functions
                  externs
                  program-index
                  spans
                  func-diag
                  use-counts
                  (text-buf-append buf head))]
              [(ErrCompilerBackend message) (ErrCompilerBackend message)])
            (if (and
              (compiler-backend-compare-op? op)
              (compiler-backend-var-single-use? use-counts dst)
              (not (compiler-backend-binop-f64? types global-types lhs rhs ty)))
              (match (box-get rest)
                [(IrInstrCons next after-branch)
                  (match next
                    [(IrInstrReturn maybe)
                      (match (box-get after-branch)
                        [(IrInstrNil)
                          (match maybe
                            [(IrSomeValue value)
                              (if (compiler-backend-branch-uses-var? value dst)
                                (compiler-backend-emit-terminator-into
                                  (compiler-backend-emit-binop-return
                                    source-function
                                    blocks
                                    types
                                    global-types
                                    assignments
                                    vars
                                    op
                                    lhs
                                    rhs
                                    ty)
                                  buf)
                                (compiler-backend-emit-instrs-normal
                                  target
                                  function
                                  source-function
                                  blocks
                                  current-label
                                  fallthrough
                                  instr
                                  (box-get rest)
                                  assignments
                                  vars
                                  types
                                  global-types
                                  ret-ty
                                  plan
                                  functions
                                  externs
                                  program-index
                                  spans
                                  func-diag
                                  use-counts
                                  buf))]
                            [(IrNoValue)
                              (compiler-backend-emit-instrs-normal
                                target
                                function
                                source-function
                                blocks
                                current-label
                                fallthrough
                                instr
                                (box-get rest)
                                assignments
                                vars
                                types
                                global-types
                                ret-ty
                                plan
                                functions
                                externs
                                program-index
                                spans
                                func-diag
                                use-counts
                                buf)])]
                        [_
                          (compiler-backend-emit-instrs-normal
                            target
                            function
                            source-function
                            blocks
                            current-label
                            fallthrough
                            instr
                            (box-get rest)
                            assignments
                            vars
                            types
                            global-types
                            ret-ty
                            plan
                            functions
                            externs
                            program-index
                            spans
                            func-diag
                            use-counts
                            buf)])]
                    [(IrInstrBranch cond true-label false-label)
                      (if (compiler-backend-branch-uses-var? cond dst)
                        (compiler-backend-emit-fused-compare-branch-rest
                          target
                          function
                          source-function
                          blocks
                          current-label
                          fallthrough
                          dst
                          op
                          lhs
                          rhs
                          ty
                          true-label
                          false-label
                          (box-get after-branch)
                          assignments
                          vars
                          types
                          global-types
                          ret-ty
                          plan
                          functions
                          externs
                          program-index
                          spans
                          func-diag
                          use-counts
                          buf)
                        (compiler-backend-emit-instrs-normal
                          target
                          function
                          source-function
                          blocks
                          current-label
                          fallthrough
                          instr
                          (box-get rest)
                          assignments
                          vars
                          types
                          global-types
                          ret-ty
                          plan
                          functions
                          externs
                          program-index
                          spans
                          func-diag
                          use-counts
                          buf))]
                    [_
                      (compiler-backend-emit-instrs-normal
                        target
                        function
                        source-function
                        blocks
                        current-label
                        fallthrough
                        instr
                        (box-get rest)
                        assignments
                        vars
                        types
                        global-types
                        ret-ty
                        plan
                        functions
                        externs
                        program-index
                        spans
                        func-diag
                        use-counts
                        buf)])]
                [_
                  (compiler-backend-emit-instrs-normal
                    target
                    function
                    source-function
                    blocks
                    current-label
                    fallthrough
                    instr
                    (box-get rest)
                    assignments
                    vars
                    types
                    global-types
                    ret-ty
                    plan
                    functions
                    externs
                    program-index
                    spans
                    func-diag
                    use-counts
                    buf)])
              (compiler-backend-emit-instrs-normal
                target
                function
                source-function
                blocks
                current-label
                fallthrough
                instr
                (box-get rest)
                assignments
                vars
                types
                global-types
                ret-ty
                plan
                functions
                externs
                program-index
                spans
                func-diag
                use-counts
                buf)))]
        [_
          (compiler-backend-emit-instrs-normal
            target
            function
            source-function
            blocks
            current-label
            fallthrough
            instr
            (box-get rest)
            assignments
            vars
            types
            global-types
            ret-ty
            plan
            functions
            externs
            program-index
            spans
            func-diag
            use-counts
            buf)])]))

(define (compiler-backend-emit-block
  [target : CompilerBackendTarget]
  [function : String]
  [source-function : String]
  [blocks : CompilerIrBlockList]
  [block : CompilerIrBlock]
  [fallthrough : CompilerBackendMaybeLabel]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [ret-ty : AstType]
  [plan : CompilerBackendRuntimePlan]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [program-index : CompilerBackendProgramIndex]
  [spans : CompilerSourceSpans]
  [func-diag : CompilerDiagnostic]
  [use-counts : (Array i64)]) : ResultCompilerBackend
  (match block
    [(IrBlock label instrs)
      (match (compiler-backend-emit-instrs
        target
        function
        source-function
        blocks
        label
        fallthrough
        (compiler-ir-instr-seq-to-list instrs)
        assignments
        vars
        types
        global-types
        ret-ty
        plan
        functions
        externs
        program-index
        spans
        func-diag
        use-counts
        (text-buf-empty))
        [(OkCompilerBackend body)
          (OkCompilerBackend
            (str-cat (compiler-backend-asm-label function label) ":\n" body ""))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]))

(define (compiler-backend-next-block-label [blocks : CompilerIrBlockList]) : CompilerBackendMaybeLabel
  (match blocks
    [(IrBlockNil) (CompilerBackendNoLabel)]
    [(IrBlockCons block _)
      (match block
        [(IrBlock label _) (CompilerBackendSomeLabel label)])]
    [(IrBlockArray seq)
      (compiler-backend-next-block-label (compiler-ir-block-seq-to-list seq))]))

(define (compiler-backend-emit-blocks-into
  [target : CompilerBackendTarget]
  [function : String]
  [source-function : String]
  [all-blocks : CompilerIrBlockList]
  [blocks : CompilerIrBlockList]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [ret-ty : AstType]
  [plan : CompilerBackendRuntimePlan]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [program-index : CompilerBackendProgramIndex]
  [spans : CompilerSourceSpans]
  [func-diag : CompilerDiagnostic]
  [use-counts : (Array i64)]
  [buf : TextBuf]) : ResultCompilerBackend
  (match blocks
    [(IrBlockNil) (OkCompilerBackend (text-buf-render buf))]
    [(IrBlockCons block rest)
      (match (compiler-backend-emit-block
        target
        function
        source-function
        all-blocks
        block
        (compiler-backend-next-block-label (box-get rest))
        assignments
        vars
        types
        global-types
        ret-ty
        plan
        functions
        externs
        program-index
        spans
        func-diag
        use-counts)
        [(OkCompilerBackend head)
          (compiler-backend-emit-blocks-into
            target
            function
            source-function
            all-blocks
            (box-get rest)
            assignments
            vars
            types
            global-types
            ret-ty
            plan
            functions
            externs
            program-index
            spans
            func-diag
            use-counts
            (text-buf-append buf head))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
    [(IrBlockArray seq)
      (compiler-backend-emit-blocks-into
        target
        function
        source-function
        all-blocks
        (compiler-ir-block-seq-to-list seq)
        assignments
        vars
        types
        global-types
        ret-ty
        plan
        functions
        externs
        program-index
        spans
        func-diag
        use-counts
        buf)]))

(define (compiler-backend-emit-blocks
  [target : CompilerBackendTarget]
  [function : String]
  [source-function : String]
  [all-blocks : CompilerIrBlockList]
  [blocks : CompilerIrBlockList]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [types : CompilerRegVarTypeList]
  [global-types : CompilerBackendGlobalTypeList]
  [ret-ty : AstType]
  [plan : CompilerBackendRuntimePlan]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [program-index : CompilerBackendProgramIndex]
  [spans : CompilerSourceSpans]
  [func-diag : CompilerDiagnostic]
  [use-counts : (Array i64)]) : ResultCompilerBackend
  (compiler-backend-emit-blocks-into
    target
    function
    source-function
    all-blocks
    blocks
    assignments
    vars
    types
    global-types
    ret-ty
    plan
    functions
    externs
    program-index
    spans
    func-diag
    use-counts
    (text-buf-empty)))

;; Move INCOMING parameters into their local frame slots (#750). Register
;; params come from rdi/rsi/.. (or xmm0..) per the calling convention; params
;; beyond a bank's registers are read back from the caller's stack frame at
;; `compiler-backend-incoming-stack-arg-offset`, indexed by a sequential
;; stack-param counter that mirrors the call site.
(define (compiler-backend-emit-param-spills
  [target : CompilerBackendTarget]
  [assignments : CompilerRegAssignmentList]
  [params : CompilerIrParamList]
  [int-idx : i64]
  [float-idx : i64]
  [position : i64]
  [stack-idx : i64]
  [program-index : CompilerBackendProgramIndex]
  [vars : i64]) : ResultCompilerBackend
  (match params
    [(IrParamNil) (OkCompilerBackend "")]
    [(IrParamCons param rest)
      (match param
        [(IrParam _ ty var-id)
          (let
            [is-float : bool (compiler-backend-float-type? ty)]
            [next-int : i64
              (if is-float
                int-idx
                (+ int-idx 1))]
            [next-float : i64
              (if is-float
                (+ float-idx 1)
                float-idx)]
            ;; #2386/#2601: a register-group parameter occupies two eightbytes.
            ;; INTEGER words advance the integer bank; SSE words advance the float
            ;; bank. This mirrors emit-call-args so self-calls agree on register vs
            ;; stack placement for mixed-bank aggregate words.
            (if (compiler-backend-group-type? program-index ty)
              (let
                [w0-sse : bool
                  (compiler-backend-group-word-sse? program-index ty 0)]
                [w0-stack : bool
                  (compiler-backend-stack-call-arg-for-banks?
                    target
                    w0-sse
                    int-idx
                    float-idx
                    position)]
                [int1 : i64
                  (if w0-sse
                    int-idx
                    (+ int-idx 1))]
                [float1 : i64
                  (if w0-sse
                    (+ float-idx 1)
                    float-idx)]
                [stack1 : i64
                  (if w0-stack
                    (+ stack-idx 1)
                    stack-idx)]
                [w1-sse : bool
                  (compiler-backend-group-word-sse? program-index ty 1)]
                [w1-stack : bool
                  (compiler-backend-stack-call-arg-for-banks?
                    target
                    w1-sse
                    int1
                    float1
                    (+ position 1))]
                (match (compiler-backend-emit-group-word-param
                  target
                  assignments
                  var-id
                  0
                  int-idx
                  float-idx
                  position
                  stack-idx
                  vars
                  ty
                  program-index)
                  [(OkCompilerBackend head0)
                    (match (compiler-backend-emit-group-word-param
                      target
                      assignments
                      var-id
                      1
                      int1
                      float1
                      (+ position 1)
                      stack1
                      vars
                      ty
                      program-index)
                      [(OkCompilerBackend head1)
                        (match (compiler-backend-emit-param-spills
                          target
                          assignments
                          (box-get rest)
                          (if w1-sse
                            int1
                            (+ int1 1))
                          (if w1-sse
                            (+ float1 1)
                            float1)
                          (+ position 2)
                          (if w1-stack
                            (+ stack1 1)
                            stack1)
                          program-index
                          vars)
                          [(OkCompilerBackend tail)
                            (OkCompilerBackend
                              (string-append head0 (string-append head1 tail)))]
                          [(ErrCompilerBackend message)
                            (ErrCompilerBackend message)])]
                      [(ErrCompilerBackend message)
                        (ErrCompilerBackend message)])]
                  [(ErrCompilerBackend message) (ErrCompilerBackend message)]))
              (if (compiler-backend-stack-call-arg-for-banks?
                target
                is-float
                int-idx
                float-idx
                position)
                (match (compiler-backend-emit-param-spills
                  target
                  assignments
                  (box-get rest)
                  next-int
                  next-float
                  (+ position 1)
                  (+ stack-idx 1)
                  program-index
                  vars)
                  [(OkCompilerBackend tail)
                    (OkCompilerBackend
                      (string-append
                        (if is-float
                          (str-cat
                            "    "
                            (compiler-backend-float-move ty)
                            " "
                            (int->string
                              (compiler-backend-incoming-stack-arg-offset
                                target
                                stack-idx))
                            "(%rbp), %xmm0\n")
                          (str-cat
                            "    movq "
                            (int->string
                              (compiler-backend-incoming-stack-arg-offset
                                target
                                stack-idx))
                            "(%rbp), %rax\n"
                            ""))
                        (string-append
                          (compiler-backend-emit-store-typed-var-with-plan
                            assignments
                            var-id
                            (if is-float
                              "%xmm0"
                              "%rax")
                            ty)
                          tail)))]
                  [(ErrCompilerBackend message) (ErrCompilerBackend message)])
                (match (if is-float
                  (compiler-backend-target-float-arg-reg
                    target
                    (if (compiler-backend-target-windows? target)
                      position
                      float-idx))
                  (compiler-backend-target-arg-reg
                    target
                    (if (compiler-backend-target-windows? target)
                      position
                      int-idx)))
                  [(OkBackendReg reg)
                    (match (compiler-backend-emit-param-spills
                      target
                      assignments
                      (box-get rest)
                      next-int
                      next-float
                      (+ position 1)
                      stack-idx
                      program-index
                      vars)
                      [(OkCompilerBackend tail)
                        (OkCompilerBackend
                          (string-append
                            (compiler-backend-emit-store-typed-var-with-plan
                              assignments
                              var-id
                              reg
                              ty)
                            tail))]
                      [(ErrCompilerBackend message)
                        (ErrCompilerBackend message)])]
                  [(ErrBackendReg _)
                    (ErrCompilerBackend
                      (compiler-diagnostic-at-start
                        ""
                        "backend: too many params"))]))))])]))

(define (compiler-backend-emit-windows-main-argv-capture
  [target : CompilerBackendTarget]
  [name : String]
  [emit-entry : bool]
  [plan : CompilerBackendRuntimePlan]) : String
  (if (and
    emit-entry
    (compiler-backend-target-windows? target)
    (string-eq name "main"))
    (let
      [_ : CompilerBackendRuntimePlan plan]
      "    movq %rcx, .L_tl_argc(%rip)
    movq %rdx, .L_tl_argv(%rip)
")
    ""))

(define (compiler-backend-emit-linux-crt-main-argv-capture
  [target : CompilerBackendTarget]
  [name : String]
  [crt-entry : bool]
  [plan : CompilerBackendRuntimePlan]) : String
  (if (and
    crt-entry
    (compiler-backend-target-linux? target)
    (string-eq name "main"))
    (let
      [_ : CompilerBackendRuntimePlan plan]
      "    movq %rdi, .L_tl_argc(%rip)
    movq %rsi, .L_tl_argv(%rip)
    movq %rdx, .L_tl_envp(%rip)
")
    ""))

(define (compiler-backend-emit-function
  [target : CompilerBackendTarget]
  [mode : CompilerBackendMode]
  [func : CompilerIrFunction]
  [functions : CompilerIrFunctionList]
  [globals : CompilerIrGlobalList]
  [global-types : CompilerBackendGlobalTypeList]
  [externs : CompilerIrExternList]
  [plan : CompilerBackendRuntimePlan]
  [program-index : CompilerBackendProgramIndex]
  [spans : CompilerSourceSpans]
  [span-index : CompilerBackendSourceSpanIndex]
  [emit-entry : bool]
  [crt-entry : bool]) : ResultCompilerBackend
  (match func
    [(IrFunction name params ret-ty vars raw-blocks)
      ;; The provenance fallback diagnostic for this function (#605): backend
      ;; errors raised while emitting its body stamp this function's source span
      ;; (or `1:1` when none was recorded) rather than always `1:1`.
      (let
        [blocks : CompilerIrBlockList
          (compiler-ir-block-list-force-cons raw-blocks)]
        [walk-func : CompilerIrFunction
          (IrFunction name params ret-ty vars blocks)]
        [func-diag : CompilerDiagnostic
          (compiler-backend-function-diagnostic-index span-index name "")]
        ;; #2386: ensure the register allocator can see the program-wide group
        ;; word-count map (so a group-typed call result / param / mov gets a
        ;; register PAIR, not a single register). Idempotent per function.
        [_ra-grp : unit
          (compiler-reg-set-group-counts!
            (struct-get program-index group-word-counts))]
        [_ra-grp-mask : unit
          (compiler-reg-set-group-class-masks!
            (struct-get program-index group-word-class-masks))]
        [reg-plan : CompilerRegPlan
          (if (compiler-backend-mode-scalar? mode)
            (if compiler-backend-scalar-registers-enabled
              (compiler-reg-plan-function-scalar walk-func)
              (compiler-reg-plan-function-stack-only walk-func))
            (compiler-reg-plan-function walk-func))]
        [_regalloc-census : unit
          (cfg
            regalloc-census
            (if (if (compiler-backend-mode-scalar? mode)
              compiler-backend-scalar-registers-enabled
              false)
              (compiler-reg-call-span-census-record-plan! walk-func reg-plan)
              unit)
            unit)]
        [plan-types : CompilerRegVarTypeList (compiler-reg-plan-types reg-plan)]
        ;; Computed once per function: the gate below, the coloring pass, and
        ;; the frame layout all consume it (the per-block fixpoint scan is too
        ;; costly to repeat).
        [fn-group-vars : CompilerLiveI64Set
          (compiler-reg-function-group-vars walk-func plan-types)]
        [has-group-vars : bool (> (compiler-live-set-count fn-group-vars) 0)]
        ;; #2598: compact the frame after regalloc by renumbering stack-resident
        ;; values into a dense slot prefix. Plans without intervals (the
        ;; stack-only opt0/opt1 path) pass through unchanged; `slot-vars`
        ;; replaces the raw var count everywhere the frame layout is derived,
        ;; while `vars` keeps indexing per-variable side tables.
        [coloring
          : CompilerRegColoring
          ;; Stack-homed register groups keep word0 in their remapped formula
          ;; slot; word1 indexes the second var-region by the same remapped id.
          ;; That keeps both words inside the `slot-vars`-sized frame instead of
          ;; preserving the old high raw ids that drove #2598 frame growth.
          (compiler-reg-color-stack-slots
            reg-plan
            fn-group-vars
            params
            blocks
            vars)]
        [assignments : CompilerRegAssignmentList
          (match coloring
            [(CompilerRegColoringNone) (compiler-reg-plan-assignments reg-plan)]
            [(CompilerRegColoringRemap remap _)
              (compiler-reg-color-rebuild-assignments
                remap
                vars
                (compiler-reg-plan-assignments reg-plan))])]
        [emit-blocks-list : CompilerIrBlockList
          (match coloring
            [(CompilerRegColoringNone) blocks]
            [(CompilerRegColoringRemap remap _)
              (compiler-reg-remap-blocks remap blocks)])]
        [slot-vars : i64
          (match coloring
            [(CompilerRegColoringNone) vars]
            [(CompilerRegColoringRemap _ slots) slots])]
        [types : CompilerRegVarTypeList
          (match coloring
            [(CompilerRegColoringNone) plan-types]
            [(CompilerRegColoringRemap remap _)
              (compiler-reg-color-rebuild-types remap vars plan-types)])]
        [use-counts : (Array i64)
          (compiler-backend-function-use-counts vars emit-blocks-list)]
        [_phi-targets : unit
          (set!
            compiler-backend-current-phi-targets
            (compiler-backend-phi-target-labels-for-blocks blocks))]
        (match (compiler-backend-emit-param-spills
          target
          assignments
          params
          0
          0
          0
          0
          program-index
          slot-vars)
          [(OkCompilerBackend spills)
            (let
              [symbol : String
                (compiler-backend-function-symbol-index program-index name)]
              [label-scope : String
                (compiler-backend-function-label-scope program-index name)]
              [_addr-forward : unit
                (compiler-backend-addr-of-forwarding-enable!
                  vars
                  emit-blocks-list
                  use-counts)]
              (match (compiler-backend-emit-blocks
                target
                label-scope
                name
                emit-blocks-list
                emit-blocks-list
                assignments
                slot-vars
                types
                global-types
                ret-ty
                plan
                functions
                externs
                program-index
                spans
                func-diag
                use-counts)
                [(OkCompilerBackend body)
                  (let
                    [frame : i64
                      (+
                        (compiler-backend-frame-size
                          (compiler-backend-frame-slots-with-groups
                            slot-vars
                            assignments
                            has-group-vars))
                        (compiler-backend-outgoing-frame-space
                          target
                          blocks
                          program-index))]
                    [_addr-forward-done : unit
                      (compiler-backend-addr-of-forwarding-disable!)]
                    (OkCompilerBackend
                      (str-cat
                        (compiler-backend-function-symbol-map-comment
                          program-index
                          name)
                        ".globl "
                        symbol
                        "\n"
                        (compiler-backend-emit-function-entry
                          target
                          symbol
                          frame)
                        ""
                        ""
                        (compiler-backend-mode-prologue mode)
                        (compiler-backend-emit-save-callee-regs
                          assignments
                          slot-vars)
                        (compiler-backend-emit-windows-main-argv-capture
                          target
                          name
                          emit-entry
                          plan)
                        (compiler-backend-emit-linux-crt-main-argv-capture
                          target
                          name
                          crt-entry
                          plan)
                        (if (and
                          (string-eq name "main")
                          (or
                            (compiler-backend-target-windows? target)
                            (and
                              crt-entry
                              (compiler-backend-target-linux? target))))
                          (compiler-backend-global-initializers
                            globals
                            program-index)
                          "")
                        spills
                        body
                        (compiler-backend-return-epilogue
                          name
                          assignments
                          slot-vars
                          emit-blocks-list)
                        (compiler-backend-emit-windows-seh-endproc target)
                        "\n")))]
                [(ErrCompilerBackend message)
                  (let
                    [_addr-forward-done : unit
                      (compiler-backend-addr-of-forwarding-disable!)]
                    (ErrCompilerBackend message))]))]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)]))]))

;; 0: every function escapes through a per-function scratch arena. The old
;; limit of 24 sent small-function transients to the program arena to skip
;; the scratch/clone overhead, but their summed assembly-text churn stays
;; resident for the whole compile (#2596 RSS calibration); the per-function
;; arena reclaims it.
(define (compiler-backend-direct-emit-instr-limit) : i64
  0)

(define (compiler-backend-emit-function-direct? [func : CompilerIrFunction]) : bool
  (match func
    [(IrFunction _ _ _ _ blocks)
      (<=
        (compiler-ir-block-list-instruction-count blocks)
        (compiler-backend-direct-emit-instr-limit))]))

(define (compiler-backend-emit-function-scratch
  [target : CompilerBackendTarget]
  [mode : CompilerBackendMode]
  [func : CompilerIrFunction]
  [all-functions : CompilerIrFunctionList]
  [globals : CompilerIrGlobalList]
  [global-types : CompilerBackendGlobalTypeList]
  [externs : CompilerIrExternList]
  [plan : CompilerBackendRuntimePlan]
  [program-index : CompilerBackendProgramIndex]
  [spans : CompilerSourceSpans]
  [span-index : CompilerBackendSourceSpanIndex]
  [emit-entry : bool]
  [crt-entry : bool]) : ResultCompilerBackend
  (with-scratch
    (compiler-backend-emit-function
      target
      mode
      func
      all-functions
      globals
      global-types
      externs
      plan
      program-index
      spans
      span-index
      emit-entry
      crt-entry)))

;; Keep the direct path available for A/B experiments by raising
;; `compiler-backend-direct-emit-instr-limit`; normal builds route emitted
;; functions through a scratch arena so transient assembly strings stay within
;; the self-build memory budget.
(define (compiler-backend-emit-function-escaping
  [target : CompilerBackendTarget]
  [mode : CompilerBackendMode]
  [func : CompilerIrFunction]
  [all-functions : CompilerIrFunctionList]
  [globals : CompilerIrGlobalList]
  [global-types : CompilerBackendGlobalTypeList]
  [externs : CompilerIrExternList]
  [plan : CompilerBackendRuntimePlan]
  [program-index : CompilerBackendProgramIndex]
  [spans : CompilerSourceSpans]
  [span-index : CompilerBackendSourceSpanIndex]
  [emit-entry : bool]
  [crt-entry : bool]) : ResultCompilerBackend
  (if (compiler-backend-emit-function-direct? func)
    (compiler-backend-emit-function
      target
      mode
      func
      all-functions
      globals
      global-types
      externs
      plan
      program-index
      spans
      span-index
      emit-entry
      crt-entry)
    (compiler-backend-emit-function-scratch
      target
      mode
      func
      all-functions
      globals
      global-types
      externs
      plan
      program-index
      spans
      span-index
      emit-entry
      crt-entry)))

(define (compiler-backend-emit-functions-into
  [target : CompilerBackendTarget]
  [mode : CompilerBackendMode]
  [functions : CompilerIrFunctionList]
  [all-functions : CompilerIrFunctionList]
  [globals : CompilerIrGlobalList]
  [global-types : CompilerBackendGlobalTypeList]
  [externs : CompilerIrExternList]
  [plan : CompilerBackendRuntimePlan]
  [program-index : CompilerBackendProgramIndex]
  [spans : CompilerSourceSpans]
  [span-index : CompilerBackendSourceSpanIndex]
  [emit-entry : bool]
  [crt-entry : bool]
  [buf : TextBuf]) : ResultCompilerBackend
  (match functions
    [(IrFunctionNil) (OkCompilerBackend (text-buf-render buf))]
    [(IrFunctionCons func rest)
      (match (compiler-backend-emit-function-escaping
        target
        (compiler-backend-effective-function-mode mode func)
        func
        all-functions
        globals
        global-types
        externs
        plan
        program-index
        spans
        span-index
        emit-entry
        crt-entry)
        [(OkCompilerBackend head)
          (compiler-backend-emit-functions-into
            target
            mode
            (box-get rest)
            all-functions
            globals
            global-types
            externs
            plan
            program-index
            spans
            span-index
            emit-entry
            crt-entry
            (text-buf-append buf head))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
    [(IrFunctionArray seq)
      (compiler-backend-emit-functions-into
        target
        mode
        (compiler-ir-function-seq-to-list seq)
        all-functions
        globals
        global-types
        externs
        plan
        program-index
        spans
        span-index
        emit-entry
        crt-entry
        buf)]))

(define (compiler-backend-emit-functions
  [target : CompilerBackendTarget]
  [mode : CompilerBackendMode]
  [functions : CompilerIrFunctionList]
  [globals : CompilerIrGlobalList]
  [all-functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [plan : CompilerBackendRuntimePlan]
  [program-index : CompilerBackendProgramIndex]
  [spans : CompilerSourceSpans]
  [emit-entry : bool]
  [crt-entry : bool]) : ResultCompilerBackend
  (let
    [span-index : CompilerBackendSourceSpanIndex
      (compiler-backend-source-span-index-build spans)]
    [global-types : CompilerBackendGlobalTypeList
      (compiler-backend-global-types globals)]
    ;; #2386: hand the program-wide group word-count map to the register allocator
    ;; so it recognises group-typed vars (call results, params, movs) that no local
    ;; IrInstrPack produced.
    [_ra-grp : unit
      (compiler-reg-set-group-counts!
        (struct-get program-index group-word-counts))]
    [_ra-grp-mask : unit
      (compiler-reg-set-group-class-masks!
        (struct-get program-index group-word-class-masks))]
    (compiler-backend-emit-functions-into
      target
      mode
      functions
      all-functions
      globals
      global-types
      externs
      plan
      program-index
      spans
      span-index
      emit-entry
      crt-entry
      (text-buf-empty))))

(define (compiler-backend-implicit-main-function) : CompilerIrFunction
  (IrFunction
    "main"
    IrParamNil
    (AstTyI64)
    1
    (compiler-ir-block-list-compact
      (compiler-ir-block-cons
        (compiler-ir-block
          "entry"
          (compiler-ir-instr-cons
            (IrInstrReturn (IrSomeValue (IrValueI64 0)))
            IrInstrNil))
        IrBlockNil))))

(define (compiler-backend-functions-with-implicit-main
  [functions : CompilerIrFunctionList]
  [emit-entry : bool]) : CompilerIrFunctionList
  (if (and
    emit-entry
    (not (compiler-backend-function-list-defines? functions "main")))
    (compiler-ir-function-cons
      (compiler-backend-implicit-main-function)
      functions)
    functions))

(define (compiler-backend-emit-functions-buffer-into
  [target : CompilerBackendTarget]
  [mode : CompilerBackendMode]
  [functions : CompilerIrFunctionList]
  [all-functions : CompilerIrFunctionList]
  [globals : CompilerIrGlobalList]
  [global-types : CompilerBackendGlobalTypeList]
  [externs : CompilerIrExternList]
  [plan : CompilerBackendRuntimePlan]
  [program-index : CompilerBackendProgramIndex]
  [spans : CompilerSourceSpans]
  [span-index : CompilerBackendSourceSpanIndex]
  [emit-entry : bool]
  [crt-entry : bool]
  [buf : TextBuf]) : ResultCompilerBackendBuffer
  (match functions
    [(IrFunctionNil) (OkCompilerBackendBuffer buf)]
    [(IrFunctionCons func rest)
      (begin
        (cfg compile-profile (compiler-backend-profile-detail-start))
        (match (compiler-backend-emit-function-escaping
          target
          (compiler-backend-effective-function-mode mode func)
          func
          all-functions
          globals
          global-types
          externs
          plan
          program-index
          spans
          span-index
          emit-entry
          crt-entry)
          [(OkCompilerBackend head)
            (begin
              (cfg
                compile-profile
                (compiler-backend-profile-detail-finish
                  "function"
                  (compiler-backend-profile-function-name func)))
              (compiler-backend-emit-functions-buffer-into
                target
                mode
                (box-get rest)
                all-functions
                globals
                global-types
                externs
                plan
                program-index
                spans
                span-index
                emit-entry
                crt-entry
                (text-buf-append buf head)))]
          [(ErrCompilerBackend message)
            (begin
              (cfg
                compile-profile
                (compiler-backend-profile-detail-finish
                  "function"
                  (compiler-backend-profile-function-name func)))
              (ErrCompilerBackendBuffer message))]))]
    [(IrFunctionArray seq)
      (compiler-backend-emit-functions-buffer-into
        target
        mode
        (compiler-ir-function-seq-to-list seq)
        all-functions
        globals
        global-types
        externs
        plan
        program-index
        spans
        span-index
        emit-entry
        crt-entry
        buf)]))

(define (compiler-backend-emit-functions-buffer
  [target : CompilerBackendTarget]
  [mode : CompilerBackendMode]
  [functions : CompilerIrFunctionList]
  [globals : CompilerIrGlobalList]
  [all-functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [plan : CompilerBackendRuntimePlan]
  [program-index : CompilerBackendProgramIndex]
  [spans : CompilerSourceSpans]
  [emit-entry : bool]
  [crt-entry : bool]) : ResultCompilerBackendBuffer
  (let
    [span-index : CompilerBackendSourceSpanIndex
      (compiler-backend-source-span-index-build spans)]
    [global-types : CompilerBackendGlobalTypeList
      (compiler-backend-global-types globals)]
    [_ra-grp : unit
      (compiler-reg-set-group-counts!
        (struct-get program-index group-word-counts))]
    [_ra-grp-mask : unit
      (compiler-reg-set-group-class-masks!
        (struct-get program-index group-word-class-masks))]
    (compiler-backend-emit-functions-buffer-into
      target
      mode
      functions
      all-functions
      globals
      global-types
      externs
      plan
      program-index
      spans
      span-index
      emit-entry
      crt-entry
      (text-buf-empty))))

(define (compiler-backend-emit-closure-descriptor-entry [name : String]) : String
  (str-cat
    (compiler-backend-closure-descriptor-label name)
    ":\n    .quad "
    (compiler-backend-closure-entry-label name)
    "\n    .quad 0\n"
    ""))

(define (compiler-backend-emit-closure-descriptor-entry-into
  [name : String]
  [_functions : CompilerIrFunctionList]
  [_externs : CompilerIrExternList]
  [program-index : CompilerBackendProgramIndex]
  [buf : TextBuf]) : TextBuf
  (match (compiler-backend-index-signature program-index name)
    [(CompilerBackendSomeSignature _ _)
      (text-buf-append
        buf
        (compiler-backend-emit-closure-descriptor-entry name))]
    [(CompilerBackendNoSignature) buf]))

(define (compiler-backend-emit-closure-descriptor-entries-into
  [names : BackendStringList]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [program-index : CompilerBackendProgramIndex]
  [buf : TextBuf]) : TextBuf
  (match names
    [(BackendStringNil) buf]
    [(BackendStringCons name rest)
      (compiler-backend-emit-closure-descriptor-entries-into
        (box-get rest)
        functions
        externs
        program-index
        (compiler-backend-emit-closure-descriptor-entry-into
          name
          functions
          externs
          program-index
          buf))]))

(define (compiler-backend-emit-closure-descriptors
  [names : BackendStringList]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [program-index : CompilerBackendProgramIndex]) : String
  (text-buf-render
    (compiler-backend-emit-closure-descriptors-into
      names
      functions
      externs
      program-index
      (text-buf-empty))))

(define (compiler-backend-emit-closure-descriptors-into
  [names : BackendStringList]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [program-index : CompilerBackendProgramIndex]
  [buf : TextBuf]) : TextBuf
  (match names
    [(BackendStringNil) buf]
    [_
      (compiler-backend-emit-closure-descriptor-entries-into
        names
        functions
        externs
        program-index
        (text-buf-append buf "    .section .rodata\n    .balign 8\n"))]))

(define (compiler-backend-closure-adapter-outgoing-frame-space
  [target : CompilerBackendTarget]
  [args : CompilerIrCallArgs]) : i64
  (match target
    [(BackendTargetLinux) 0]
    [(BackendTargetWindows)
      ;; #2386: no callee signature here -- size conservatively at two positions
      ;; per forwarded argument so a register-group never overruns the area.
      (compiler-backend-round-up-16
        (+
          (compiler-backend-outgoing-shadow-space target)
          (compiler-backend-windows-words-stack-space
            (* 2 (compiler-backend-call-args-count args)))))]))

(define (compiler-backend-emit-closure-entry-adapter
  [target : CompilerBackendTarget]
  [name : String]
  [param-types : AstTypeList]
  [_ret-ty : AstType]
  [plan : CompilerBackendRuntimePlan]
  [_functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [program-index : CompilerBackendProgramIndex]) : ResultCompilerBackend
  (let
    [params : CompilerIrParamList
      (compiler-backend-param-list-from-types param-types 0)]
    [vars : i64 (compiler-backend-type-list-count param-types)]
    [args : CompilerIrCallArgs
      (compiler-ir-call-args-from-list
        (compiler-backend-var-value-list
          (compiler-backend-type-list-count param-types)
          0))]
    [frame : i64
      (+
        (compiler-backend-frame-size
          ;; #2386: group params spill word1 at -(8*(vars+var+1))(%rbp); the
          ;; frame must cover those slots (no red zone on Windows -- the
          ;; outgoing stack-arg area would clobber them otherwise).
          (compiler-backend-frame-slots-with-groups
            vars
            CompilerRegAssignmentNil
            (compiler-backend-type-list-has-group? param-types program-index)))
        (compiler-backend-closure-adapter-outgoing-frame-space target args))]
    [call-space : i64
      (compiler-backend-call-arg-space
        target
        args
        param-types
        false
        program-index)]
    [diag : CompilerDiagnostic (compiler-diagnostic-at-start "" "")]
    (match (compiler-backend-emit-param-spills
      target
      CompilerRegAssignmentNil
      params
      1
      0
      1
      0
      program-index
      vars)
      [(OkCompilerBackend spills)
        (match (compiler-backend-emit-call-args
          target
          CompilerRegAssignmentNil
          args
          param-types
          false
          0
          0
          0
          0
          0
          diag
          program-index
          vars)
          [(OkCompilerBackend args-asm)
            (OkCompilerBackend
              (str-cat
                (compiler-backend-emit-function-entry
                  target
                  (compiler-backend-closure-entry-label name)
                  frame)
                ""
                ""
                (string-append
                  spills
                  (string-append
                    (compiler-backend-emit-call-space-sub call-space)
                    (string-append
                      args-asm
                      (string-append
                        (compiler-backend-varargs-pre-call
                          target
                          name
                          externs
                          param-types)
                        (str-cat
                          "    call "
                          (compiler-backend-call-symbol-index
                            name
                            plan
                            program-index)
                          "\n"
                          (string-append
                            (compiler-backend-emit-call-space-add call-space)
                            (string-append
                              "    movq %rbp, %rsp\n    popq %rbp\n    ret\n"
                              (string-append
                                (compiler-backend-emit-windows-seh-endproc
                                  target)
                                "\n")))
                          "")))))
                ""))]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
      [(ErrCompilerBackend message) (ErrCompilerBackend message)])))

(define (compiler-backend-emit-closure-entry-adapters-into
  [target : CompilerBackendTarget]
  [names : BackendStringList]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [plan : CompilerBackendRuntimePlan]
  [program-index : CompilerBackendProgramIndex]
  [buf : TextBuf]) : ResultCompilerBackend
  (match (compiler-backend-emit-closure-entry-adapters-buffer-into
    target
    names
    functions
    externs
    plan
    program-index
    buf)
    [(OkCompilerBackendBuffer out) (OkCompilerBackend (text-buf-render out))]
    [(ErrCompilerBackendBuffer message) (ErrCompilerBackend message)]))

(define (compiler-backend-emit-closure-entry-adapters-buffer-into
  [target : CompilerBackendTarget]
  [names : BackendStringList]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [plan : CompilerBackendRuntimePlan]
  [program-index : CompilerBackendProgramIndex]
  [buf : TextBuf]) : ResultCompilerBackendBuffer
  (match names
    [(BackendStringNil) (OkCompilerBackendBuffer buf)]
    [(BackendStringCons name rest)
      (match (compiler-backend-index-signature program-index name)
        [(CompilerBackendSomeSignature param-types ret-ty)
          (match (compiler-backend-emit-closure-entry-adapter
            target
            name
            param-types
            ret-ty
            plan
            functions
            externs
            program-index)
            [(OkCompilerBackend head)
              (compiler-backend-emit-closure-entry-adapters-buffer-into
                target
                (box-get rest)
                functions
                externs
                plan
                program-index
                (text-buf-append buf head))]
            [(ErrCompilerBackend message) (ErrCompilerBackendBuffer message)])]
        [(CompilerBackendNoSignature)
          (compiler-backend-emit-closure-entry-adapters-buffer-into
            target
            (box-get rest)
            functions
            externs
            plan
            program-index
            buf)])]))

(define (compiler-backend-emit-closure-entry-adapters
  [target : CompilerBackendTarget]
  [names : BackendStringList]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [plan : CompilerBackendRuntimePlan]
  [program-index : CompilerBackendProgramIndex]) : ResultCompilerBackend
  (compiler-backend-emit-closure-entry-adapters-into
    target
    names
    functions
    externs
    plan
    program-index
    (text-buf-empty)))

(define (compiler-backend-string-list-reverse-into
  [strings : BackendStringList]
  [out : BackendStringList]) : BackendStringList
  (match strings
    [(BackendStringNil) out]
    [(BackendStringCons head rest)
      (compiler-backend-string-list-reverse-into
        (box-get rest)
        (compiler-backend-string-cons head out))]))

(define (compiler-backend-string-list-reverse [strings : BackendStringList]) : BackendStringList
  (compiler-backend-string-list-reverse-into strings BackendStringNil))

(define (compiler-backend-string-set-list [set : BackendStringSet]) : BackendStringList
  (compiler-backend-string-list-reverse (struct-get set items)))

(define (compiler-backend-program-collections-functions
  [collections : CompilerBackendProgramCollections]) : BackendStringList
  (compiler-backend-string-set-list (struct-get collections functions)))

(define (compiler-backend-program-collections-strings
  [collections : CompilerBackendProgramCollections]) : BackendStringList
  (compiler-backend-string-set-list (struct-get collections strings)))

(define (compiler-backend-program-collections-floats
  [collections : CompilerBackendProgramCollections]) : BackendStringList
  (compiler-backend-string-set-list (struct-get collections floats)))

(define (compiler-backend-program-collections-bytes
  [collections : CompilerBackendProgramCollections]) : BackendStringList
  (compiler-backend-string-set-list (struct-get collections bytes)))

(define (compiler-backend-program-collections-uses-f64-neg?
  [collections : CompilerBackendProgramCollections]) : bool
  (struct-get collections uses-f64-neg))

(define (compiler-backend-collect-value-collections
  [collections : CompilerBackendProgramCollections]
  [value : CompilerIrValue]) : CompilerBackendProgramCollections
  (match value
    [(IrValueFunction name)
      (compiler-backend-program-collections-add-function collections name)]
    [(IrValueString text)
      (compiler-backend-program-collections-add-string collections text)]
    [(IrValueF64 text)
      (compiler-backend-program-collections-add-float collections text)]
    [(IrValueBytes text)
      (compiler-backend-program-collections-add-bytes collections text)]
    [_ collections]))

(define (compiler-backend-collect-maybe-value-collections
  [collections : CompilerBackendProgramCollections]
  [value : CompilerIrMaybeValue]) : CompilerBackendProgramCollections
  (match value
    [(IrNoValue) collections]
    [(IrSomeValue inner)
      (compiler-backend-collect-value-collections collections inner)]))

(define (compiler-backend-collect-value-list-collections
  [collections : CompilerBackendProgramCollections]
  [values : CompilerIrValueList]) : CompilerBackendProgramCollections
  (match values
    [(IrValueNil) collections]
    [(IrValueCons value rest)
      (compiler-backend-collect-value-list-collections
        (compiler-backend-collect-value-collections collections value)
        (box-get rest))]))

(define (compiler-backend-collect-call-args-array-collections
  [collections : CompilerBackendProgramCollections]
  [values : (Array CompilerIrValue)]
  [index : i64]) : CompilerBackendProgramCollections
  (if (>= index (array-length values))
    collections
    (compiler-backend-collect-call-args-array-collections
      (compiler-backend-collect-value-collections
        collections
        (array-ref values index))
      values
      (+ index 1))))

(define (compiler-backend-collect-call-args-collections
  [collections : CompilerBackendProgramCollections]
  [args : CompilerIrCallArgs]) : CompilerBackendProgramCollections
  (match args
    [(IrCallArgsNil) collections]
    [(IrCallArgsOne value)
      (compiler-backend-collect-value-collections collections value)]
    [(IrCallArgsTwo a b)
      (compiler-backend-collect-value-collections
        (compiler-backend-collect-value-collections collections a)
        b)]
    [(IrCallArgsArray values)
      (compiler-backend-collect-call-args-array-collections
        collections
        values
        0)]))

(define (compiler-backend-collect-phi-collections
  [collections : CompilerBackendProgramCollections]
  [inputs : CompilerIrPhiInputList]) : CompilerBackendProgramCollections
  (match inputs
    [(IrPhiInputNil) collections]
    [(IrPhiInputCons value _ rest)
      (compiler-backend-collect-phi-collections
        (compiler-backend-collect-value-collections collections value)
        (box-get rest))]))

(define (compiler-backend-collect-instr-collections
  [collections : CompilerBackendProgramCollections]
  [instr : CompilerIrInstr]) : CompilerBackendProgramCollections
  (match instr
    [(IrInstrMov _ src _)
      (compiler-backend-collect-value-collections collections src)]
    [(IrInstrBinOp _ _ lhs rhs _)
      (compiler-backend-collect-value-collections
        (compiler-backend-collect-value-collections collections lhs)
        rhs)]
    [(IrInstrUnOp _ op src ty)
      (let
        [with-src : CompilerBackendProgramCollections
          (compiler-backend-collect-value-collections collections src)]
        (match op
          [(IrUnNeg)
            (if (compiler-backend-f64-type? ty)
              (compiler-backend-program-collections-mark-f64-neg with-src)
              with-src)]
          [_ with-src]))]
    [(IrInstrCall _ _ args _)
      (compiler-backend-collect-call-args-collections collections args)]
    [(IrInstrCallIndirect _ func args _)
      (compiler-backend-collect-call-args-collections
        (compiler-backend-collect-value-collections collections func)
        args)]
    [(IrInstrCallIndirectC _ func args _)
      (compiler-backend-collect-call-args-collections
        (compiler-backend-collect-value-collections collections func)
        args)]
    [(IrInstrCallCAbiStoreResult base _ args _)
      (compiler-backend-collect-call-args-collections
        (compiler-backend-collect-value-collections collections base)
        args)]
    [(IrInstrCallIndirectCAbiStoreResult base func args _)
      (compiler-backend-collect-call-args-collections
        (compiler-backend-collect-value-collections
          (compiler-backend-collect-value-collections collections base)
          func)
        args)]
    [(IrInstrTailCall _ args _)
      (compiler-backend-collect-call-args-collections collections args)]
    [(IrInstrStore _ value _)
      (compiler-backend-collect-value-collections collections value)]
    [(IrInstrBranch cond _ _)
      (compiler-backend-collect-value-collections collections cond)]
    [(IrInstrReturn maybe)
      (compiler-backend-collect-maybe-value-collections collections maybe)]
    [(IrInstrPhi _ inputs _)
      (compiler-backend-collect-phi-collections collections inputs)]
    [(IrInstrGep _ base offset _)
      (compiler-backend-collect-value-collections
        (compiler-backend-collect-value-collections collections base)
        offset)]
    [(IrInstrLoad _ src _)
      (compiler-backend-collect-value-collections collections src)]
    [(IrInstrStorePtr dst src _)
      (compiler-backend-collect-value-collections
        (compiler-backend-collect-value-collections collections dst)
        src)]
    [(IrInstrCopyBytes dst src _)
      (compiler-backend-collect-value-collections
        (compiler-backend-collect-value-collections collections dst)
        src)]
    [(IrInstrBoundsCheck index length _)
      (compiler-backend-collect-value-collections
        (compiler-backend-collect-value-collections collections index)
        length)]
    [(IrInstrCast _ src _ _)
      (compiler-backend-collect-value-collections collections src)]
    [(IrInstrBitcast _ src _ _)
      (compiler-backend-collect-value-collections collections src)]
    [(IrInstrSplat _ value _ _)
      (compiler-backend-collect-value-collections collections value)]
    [(IrInstrVectorBinOp _ _ lhs rhs _ _)
      (compiler-backend-collect-value-collections
        (compiler-backend-collect-value-collections collections lhs)
        rhs)]
    [(IrInstrVectorReduce _ _ src _ _)
      (compiler-backend-collect-value-collections collections src)]
    [(IrInstrVectorCompare _ _ lhs rhs _ _)
      (compiler-backend-collect-value-collections
        (compiler-backend-collect-value-collections collections lhs)
        rhs)]
    [(IrInstrMaskBinOp _ _ lhs rhs _)
      (compiler-backend-collect-value-collections
        (compiler-backend-collect-value-collections collections lhs)
        rhs)]
    [(IrInstrMaskNot _ src _)
      (compiler-backend-collect-value-collections collections src)]
    [(IrInstrMaskReduce _ _ src _)
      (compiler-backend-collect-value-collections collections src)]
    [(IrInstrSelect _ mask on-true on-false _ _)
      (compiler-backend-collect-value-collections
        (compiler-backend-collect-value-collections
          (compiler-backend-collect-value-collections collections mask)
          on-true)
        on-false)]
    [(IrInstrVectorLoad _ base index _ _)
      (compiler-backend-collect-value-collections
        (compiler-backend-collect-value-collections collections base)
        index)]
    [(IrInstrVectorStore base index value _ _)
      (compiler-backend-collect-value-collections
        (compiler-backend-collect-value-collections
          (compiler-backend-collect-value-collections collections base)
          index)
        value)]
    [(IrInstrPredicatedStore base index value mask _ _)
      (compiler-backend-collect-value-collections
        (compiler-backend-collect-value-collections
          (compiler-backend-collect-value-collections
            (compiler-backend-collect-value-collections collections base)
            index)
          value)
        mask)]
    [(IrInstrPredicatedLoad _ base index mask _ _)
      (compiler-backend-collect-value-collections
        (compiler-backend-collect-value-collections
          (compiler-backend-collect-value-collections collections base)
          index)
        mask)]
    [(IrInstrTailMask _ index length _)
      (compiler-backend-collect-value-collections
        (compiler-backend-collect-value-collections collections index)
        length)]
    [(IrInstrCpuId _ leaf subleaf _)
      (compiler-backend-collect-value-collections
        (compiler-backend-collect-value-collections collections leaf)
        subleaf)]
    [(IrInstrXgetbv _ index)
      (compiler-backend-collect-value-collections collections index)]
    [(IrInstrSyscall _ args)
      (compiler-backend-collect-call-args-collections collections args)]
    [(IrInstrPack _ words _)
      (compiler-backend-collect-value-list-collections collections words)]
    [(IrInstrWord _ src _ _)
      (compiler-backend-collect-value-collections collections src)]
    [(IrInstrTailCallIndirect func args _)
      (compiler-backend-collect-call-args-collections
        (compiler-backend-collect-value-collections collections func)
        args)]
    [(IrInstrAlloc _ _) collections]
    [(IrInstrAddrOf _ _) collections]
    [(IrInstrLaneId _ _ _) collections]
    [(IrInstrEntryArgc _) collections]
    [(IrInstrEntryArgv _) collections]
    [(IrInstrEntryEnvp _) collections]
    [(IrInstrJump _) collections]))

(define (compiler-backend-collect-instr-seq-collections
  [collections : CompilerBackendProgramCollections]
  [instrs : CompilerIrInstrSeq]) : CompilerBackendProgramCollections
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [out : CompilerBackendProgramCollections collections]
    (begin
      (while (< index count)
        (begin
          (set!
            out
            (compiler-backend-collect-instr-collections
              out
              (array-ref slots index)))
          (set! index (+ index 1))))
      out)))

(define (compiler-backend-collect-block-collections
  [collections : CompilerBackendProgramCollections]
  [blocks : CompilerIrBlockList]) : CompilerBackendProgramCollections
  (match (compiler-backend-collect-blocks-shared
    (BackendCollectCollections collections)
    blocks)
    [(BackendCollectCollections out) out]
    [_ collections]))

(define (compiler-backend-collect-function-collections
  [collections : CompilerBackendProgramCollections]
  [functions : CompilerIrFunctionList]) : CompilerBackendProgramCollections
  (match (compiler-backend-collect-functions-shared
    (BackendCollectCollections collections)
    functions)
    [(BackendCollectCollections out) out]
    [_ collections]))

(define (compiler-backend-collect-global-collections
  [collections : CompilerBackendProgramCollections]
  [globals : CompilerIrGlobalList]) : CompilerBackendProgramCollections
  (match globals
    [(IrGlobalNil) collections]
    [(IrGlobalCons global rest)
      (match global
        [(IrGlobal _ _ value)
          (compiler-backend-collect-global-collections
            (compiler-backend-collect-value-collections collections value)
            (box-get rest))])]))

(define (compiler-backend-collect-program-collections
  [program : CompilerIrProgram]) : CompilerBackendProgramCollections
  (match program
    [(IrProgram globals functions _)
      (compiler-backend-collect-function-collections
        (compiler-backend-collect-global-collections
          (compiler-backend-program-collections-new)
          globals)
        functions)]))

(define (compiler-backend-emit-string-entry-into
  [text : String]
  [buf : TextBuf]) : TextBuf
  (let
    [suffix : String (compiler-backend-string-label-suffix text)]
    [data-label : String (string-append ".L_tl_str_data_" suffix)]
    [fat-label : String (string-append ".L_tl_str_" suffix)]
    [escaped : String (compiler-backend-escape-string text)]
    [len-text : String (int->string (string-length text))]
    (text-buf-append
      (text-buf-append
        (text-buf-append
          (text-buf-append
            (text-buf-append
              (text-buf-append
                (text-buf-append
                  (text-buf-append
                    (text-buf-append
                      (text-buf-append
                        (text-buf-append buf data-label)
                        ":\n    .string \"")
                      escaped)
                    "\"\n    .balign 8\n")
                  fat-label)
                ":\n    .quad ")
              data-label)
            "\n    .quad ")
          len-text)
        "\n")
      "")))

(define (compiler-backend-emit-string-entry [text : String]) : String
  (text-buf-render
    (compiler-backend-emit-string-entry-into text (text-buf-empty))))

(define (compiler-backend-emit-string-entries-into
  [strings : BackendStringList]
  [buf : TextBuf]) : TextBuf
  (match strings
    [(BackendStringNil) buf]
    [(BackendStringCons text rest)
      (compiler-backend-emit-string-entries-into
        (box-get rest)
        (compiler-backend-emit-string-entry-into text buf))]))

(define (compiler-backend-emit-string-entries [strings : BackendStringList]) : String
  (text-buf-render
    (compiler-backend-emit-string-entries-into strings (text-buf-empty))))

(define (compiler-backend-emit-string-rodata-into
  [strings : BackendStringList]
  [buf : TextBuf]) : TextBuf
  (match strings
    [(BackendStringNil) buf]
    [_
      (text-buf-append
        (compiler-backend-emit-string-entries-into
          strings
          (text-buf-append buf "    .section .rodata\n"))
        "\n")]))

(define (compiler-backend-emit-string-rodata [strings : BackendStringList]) : String
  (text-buf-render
    (compiler-backend-emit-string-rodata-into strings (text-buf-empty))))

(define (compiler-backend-emit-byte-directives-into
  [bytes : String]
  [buf : TextBuf]) : TextBuf
  (let
    [i : i64 0]
    [n : i64 (string-length bytes)]
    [col : i64 0]
    [out : TextBuf buf]
    (begin
      (if (= n 0)
        (set! out (text-buf-append out "    .byte 0\n"))
        (while (< i n)
          (begin
            (if (= col 0)
              (set! out (text-buf-append out "    .byte "))
              (set! out (text-buf-append out ",")))
            (set!
              out
              (text-buf-append
                out
                (int->string (compiler-backend-char-code (string-ref bytes i)))))
            (set! i (+ i 1))
            (set! col (+ col 1))
            (if (or (= col 16) (= i n))
              (begin
                (set! out (text-buf-append out "\n"))
                (set! col 0))
              unit))))
      out)))

(define (compiler-backend-emit-bytes-entry-into
  [bytes : String]
  [buf : TextBuf]) : TextBuf
  (let
    [data-label : String (compiler-backend-bytes-data-label bytes)]
    [fat-label : String (compiler-backend-bytes-fat-label bytes)]
    [len-text : String (int->string (string-length bytes))]
    [data-buf : TextBuf
      (compiler-backend-emit-byte-directives-into
        bytes
        (text-buf-append
          (text-buf-append buf "    .balign 8\n")
          (str-cat data-label ":\n" "")))]
    (text-buf-append
      (text-buf-append
        (text-buf-append
          (text-buf-append
            (text-buf-append
              (text-buf-append data-buf "    .balign 8\n")
              fat-label)
            ":\n    .quad ")
          data-label)
        "\n    .quad ")
      (string-append len-text "\n"))))

(define (compiler-backend-emit-bytes-entries-into
  [items : BackendStringList]
  [buf : TextBuf]) : TextBuf
  (match items
    [(BackendStringNil) buf]
    [(BackendStringCons bytes rest)
      (compiler-backend-emit-bytes-entries-into
        (box-get rest)
        (compiler-backend-emit-bytes-entry-into bytes buf))]))

(define (compiler-backend-emit-bytes-data-into
  [items : BackendStringList]
  [buf : TextBuf]) : TextBuf
  (match items
    [(BackendStringNil) buf]
    [_
      (text-buf-append
        (compiler-backend-emit-bytes-entries-into
          items
          (text-buf-append buf "    .data\n"))
        "\n")]))

(define (compiler-backend-emit-f64-entry [text : String]) : String
  (str-cat (compiler-backend-f64-label text) ":\n    .double " text "\n" ""))

(define (compiler-backend-emit-f64-entries-into
  [floats : BackendStringList]
  [buf : TextBuf]) : TextBuf
  (match floats
    [(BackendStringNil) buf]
    [(BackendStringCons text rest)
      (compiler-backend-emit-f64-entries-into
        (box-get rest)
        (text-buf-append buf (compiler-backend-emit-f64-entry text)))]))

(define (compiler-backend-emit-f64-entries [floats : BackendStringList]) : String
  (text-buf-render
    (compiler-backend-emit-f64-entries-into floats (text-buf-empty))))

(define (compiler-backend-emit-f64-rodata-into
  [floats : BackendStringList]
  [buf : TextBuf]) : TextBuf
  (match floats
    [(BackendStringNil) buf]
    [_
      (compiler-backend-emit-f64-entries-into
        floats
        (text-buf-append buf "    .section .rodata\n"))]))

(define (compiler-backend-emit-f64-rodata [floats : BackendStringList]) : String
  (text-buf-render
    (compiler-backend-emit-f64-rodata-into floats (text-buf-empty))))

(define (compiler-backend-emit-f64-sign-bit-rodata-into
  [enabled : bool]
  [buf : TextBuf]) : TextBuf
  (if enabled
    (text-buf-append
      (text-buf-append
        (text-buf-append buf "    .section .rodata\n    .balign 16\n")
        (compiler-backend-f64-sign-bit-label))
      ":\n    .quad 0x8000000000000000\n    .quad 0\n")
    buf))

(define (compiler-backend-global-value-asm
  [ty : AstType]
  [value : CompilerIrValue]
  [program-index : CompilerBackendProgramIndex]) : ResultCompilerBackend
  (match value
    ;; #2386: a register-group global stores its value inline (16 bytes), so its
    ;; startup-initialized slot reserves two words rather than one.
    [(IrValueUnit)
      (if (compiler-backend-group-type? program-index ty)
        (OkCompilerBackend "    .quad 0\n    .quad 0\n")
        (OkCompilerBackend "    .quad 0\n"))]
    [(IrValueI64 n)
      (OkCompilerBackend (str-cat "    .quad " (int->string n) "\n"))]
    [(IrValueBool b)
      (if b
        (OkCompilerBackend "    .quad 1\n")
        (OkCompilerBackend "    .quad 0\n"))]
    [(IrValueChar c)
      (OkCompilerBackend
        (str-cat "    .quad " (int->string (compiler-backend-char-code c)) "\n"))]
    [(IrValueF64 text)
      (if (compiler-backend-f64-type? ty)
        (OkCompilerBackend (str-cat "    .double " text "\n"))
        (OkCompilerBackend (str-cat "    .float " text "\n")))]
    [(IrValueGlobal name)
      (OkCompilerBackend
        (str-cat "    .quad " (compiler-backend-user-symbol name) "\n"))]
    [(IrValueGlobalAddr name)
      (OkCompilerBackend
        (str-cat "    .quad " (compiler-backend-user-symbol name) "\n"))]
    [(IrValueFunction name)
      (OkCompilerBackend
        (str-cat
          "    .quad "
          (compiler-backend-closure-descriptor-label name)
          "\n"))]
    [(IrValueString text)
      (OkCompilerBackend
        (str-cat "    .quad " (compiler-backend-string-fat-label text) "\n"))]
    [(IrValueBytes text)
      (OkCompilerBackend
        (str-cat "    .quad " (compiler-backend-bytes-fat-label text) "\n"))]
    [_
      (ErrCompilerBackend
        (compiler-diagnostic-at-start
          ""
          "backend: unsupported global initializer"))]))

(define (compiler-backend-runtime-global?
  [ty : AstType]
  [value : CompilerIrValue]) : bool
  (match value
    [(IrValueUnit)
      (match ty
        [(AstTyUnit) false]
        [_ true])]
    [_ false]))

(define (compiler-backend-emit-runtime-global
  [target : CompilerBackendTarget]
  [symbol : String]
  [size : i64]) : String
  (match target
    [(BackendTargetLinux)
      (str-cat "    .comm " symbol ", " (int->string size) ", 8\n")]
    [(BackendTargetWindows)
      (str-cat "    .comm " symbol ", " (int->string size) ", 3\n")]))

(define (compiler-backend-emit-global
  [target : CompilerBackendTarget]
  [global : CompilerIrGlobal]
  [program-index : CompilerBackendProgramIndex]) : ResultCompilerBackend
  (match global
    [(IrGlobal name ty value)
      (let
        [symbol : String (compiler-backend-user-symbol name)]
        (if (compiler-backend-runtime-global? ty value)
          (OkCompilerBackend
            (str-cat
              ".globl "
              symbol
              "\n"
              (compiler-backend-emit-runtime-global
                target
                symbol
                (if (compiler-backend-group-type? program-index ty)
                  16
                  8))
              ""))
          (match (compiler-backend-global-value-asm ty value program-index)
            [(OkCompilerBackend value-asm)
              (OkCompilerBackend
                (str-cat ".globl " symbol "\n" symbol ":\n" value-asm ""))]
            [(ErrCompilerBackend message) (ErrCompilerBackend message)])))]))

(define (compiler-backend-emit-globals-into
  [target : CompilerBackendTarget]
  [globals : CompilerIrGlobalList]
  [buf : TextBuf]
  [program-index : CompilerBackendProgramIndex]) : ResultCompilerBackend
  (match (compiler-backend-emit-globals-buffer-into
    target
    globals
    buf
    program-index)
    [(OkCompilerBackendBuffer out) (OkCompilerBackend (text-buf-render out))]
    [(ErrCompilerBackendBuffer message) (ErrCompilerBackend message)]))

(define (compiler-backend-emit-globals-buffer-into
  [target : CompilerBackendTarget]
  [globals : CompilerIrGlobalList]
  [buf : TextBuf]
  [program-index : CompilerBackendProgramIndex]) : ResultCompilerBackendBuffer
  (match globals
    [(IrGlobalNil) (OkCompilerBackendBuffer buf)]
    [(IrGlobalCons global rest)
      (match (compiler-backend-emit-global target global program-index)
        [(OkCompilerBackend head)
          (compiler-backend-emit-globals-buffer-into
            target
            (box-get rest)
            (text-buf-append buf head)
            program-index)]
        [(ErrCompilerBackend message) (ErrCompilerBackendBuffer message)])]))

(define (compiler-backend-emit-globals
  [target : CompilerBackendTarget]
  [globals : CompilerIrGlobalList]
  [program-index : CompilerBackendProgramIndex]) : ResultCompilerBackend
  (compiler-backend-emit-globals-into
    target
    globals
    (text-buf-empty)
    program-index))

(define (compiler-backend-global-init-name [global-name : String]) : String
  (string-append "__global_init_" global-name))

(define (compiler-backend-global-init-call
  [name : String]
  [ty : AstType]
  [program-index : CompilerBackendProgramIndex]) : String
  (let
    [symbol : String (compiler-backend-user-symbol name)]
    [init-symbol : String
      (compiler-backend-user-symbol (compiler-backend-global-init-name name))]
    (str-cat
      "    call "
      init-symbol
      "\n"
      (if (compiler-backend-group-type? program-index ty)
        ;; #2386: a register-group init returns word0:word1 in %rax:%rdx; store
        ;; both into the inline 16-byte global slot.
        (str-cat
          "    movq %rax, "
          symbol
          "(%rip)\n    movq %rdx, "
          symbol
          "+8(%rip)\n"
          "")
        (if (compiler-backend-float-type? ty)
          (str-cat
            "    "
            (compiler-backend-float-move ty)
            " %xmm0, "
            symbol
            "(%rip)\n")
          (str-cat "    movq %rax, " symbol "(%rip)\n")))
      "")))

(define (compiler-backend-global-initializers
  [globals : CompilerIrGlobalList]
  [program-index : CompilerBackendProgramIndex]) : String
  (match globals
    [(IrGlobalNil) ""]
    [(IrGlobalCons global rest)
      (match global
        [(IrGlobal name ty value)
          (string-append
            (if (compiler-backend-runtime-global? ty value)
              (compiler-backend-global-init-call name ty program-index)
              "")
            (compiler-backend-global-initializers (box-get rest) program-index))])]))

(define (compiler-backend-function-list-defines?
  [functions : CompilerIrFunctionList]
  [name : String]) : bool
  (match functions
    [(IrFunctionNil) false]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction func-name _ _ _ _)
          (if (string-eq func-name name)
            true
            (compiler-backend-function-list-defines? (box-get rest) name))])]
    [(IrFunctionArray seq)
      (compiler-backend-function-list-defines?
        (compiler-ir-function-seq-to-list seq)
        name)]))

(define (compiler-backend-extern-list-references?
  [externs : CompilerIrExternList]
  [name : String]) : bool
  (match externs
    [(IrExternNil) false]
    [(IrExternCons item rest)
      (match item
        [(IrExtern extern-name _ _ link-symbol _ _)
          (if (string-eq extern-name name)
            true
            (if (string-eq link-symbol name)
              true
              (compiler-backend-extern-list-references? (box-get rest) name)))])]))

(define (compiler-backend-extern-list-references-alias?
  [externs : CompilerIrExternList]
  [canonical : String]
  [alias : String]) : bool
  (or
    (compiler-backend-extern-list-references? externs canonical)
    (compiler-backend-extern-list-references? externs alias)))

(define (compiler-backend-extern-list-link-symbol
  [externs : CompilerIrExternList]
  [name : String]) : String
  (match externs
    [(IrExternNil) name]
    [(IrExternCons item rest)
      (match item
        [(IrExtern extern-name _ _ link-symbol _ _)
          (if (string-eq extern-name name)
            link-symbol
            (compiler-backend-extern-list-link-symbol (box-get rest) name))])]))

(define (compiler-backend-binop-needs-div-abort?
  [op : CompilerIrBinOp]
  [rhs : CompilerIrValue]
  [ty : AstType]) : bool
  (if (compiler-backend-float-type? ty)
    false
    (match op
      [(IrBinDiv) (not (compiler-backend-divmod-safe-literal? rhs ty))]
      [(IrBinMod) (not (compiler-backend-divmod-safe-literal? rhs ty))]
      [(IrBinSafeDiv) false]
      [(IrBinSafeMod) false]
      [_ false])))

(define (compiler-backend-binop-needs-shift-abort?
  [op : CompilerIrBinOp]
  [ty : AstType]) : bool
  (if (compiler-backend-float-type? ty)
    false
    (match op
      [(IrBinShl) true]
      [(IrBinShr) true]
      [_ false])))

(define (compiler-backend-runtime-index-empty) : CompilerBackendRuntimeIndex
  (CompilerBackendRuntimeIndex
    (string-i64-map-with-capacity 256)
    (string-i64-map-with-capacity 256)
    (string-i64-map-with-capacity 256)
    false
    false))

(define (compiler-backend-runtime-index-defines?
  [index : CompilerBackendRuntimeIndex]
  [name : String]) : bool
  (string-i64-map-contains? (struct-get index defines) name))

(define (compiler-backend-runtime-index-extern?
  [index : CompilerBackendRuntimeIndex]
  [name : String]) : bool
  (string-i64-map-contains? (struct-get index externs) name))

(define (compiler-backend-runtime-index-extern-alias?
  [index : CompilerBackendRuntimeIndex]
  [canonical : String]
  [alias : String]) : bool
  (or
    (compiler-backend-runtime-index-extern? index canonical)
    (compiler-backend-runtime-index-extern? index alias)))

(define (compiler-backend-runtime-index-calls?
  [index : CompilerBackendRuntimeIndex]
  [name : String]) : bool
  (string-i64-map-contains? (struct-get index calls) name))

(define (compiler-backend-runtime-index-needs-div-abort?
  [index : CompilerBackendRuntimeIndex]) : bool
  (struct-get index needs-div-abort))

(define (compiler-backend-runtime-index-needs-shift-abort?
  [index : CompilerBackendRuntimeIndex]) : bool
  (struct-get index needs-shift-abort))

(define (compiler-backend-runtime-index-add-define
  [index : CompilerBackendRuntimeIndex]
  [name : String]) : CompilerBackendRuntimeIndex
  (CompilerBackendRuntimeIndex
    (string-i64-map-put (struct-get index defines) name 1)
    (struct-get index externs)
    (struct-get index calls)
    (struct-get index needs-div-abort)
    (struct-get index needs-shift-abort)))

(define (compiler-backend-runtime-index-add-extern-name
  [index : CompilerBackendRuntimeIndex]
  [name : String]) : CompilerBackendRuntimeIndex
  (CompilerBackendRuntimeIndex
    (struct-get index defines)
    (string-i64-map-put (struct-get index externs) name 1)
    (struct-get index calls)
    (struct-get index needs-div-abort)
    (struct-get index needs-shift-abort)))

(define (compiler-backend-runtime-index-add-call
  [index : CompilerBackendRuntimeIndex]
  [name : String]) : CompilerBackendRuntimeIndex
  (CompilerBackendRuntimeIndex
    (struct-get index defines)
    (struct-get index externs)
    (string-i64-map-put (struct-get index calls) name 1)
    (struct-get index needs-div-abort)
    (struct-get index needs-shift-abort)))

(define (compiler-backend-runtime-index-with-div-abort
  [index : CompilerBackendRuntimeIndex]) : CompilerBackendRuntimeIndex
  (CompilerBackendRuntimeIndex
    (struct-get index defines)
    (struct-get index externs)
    (struct-get index calls)
    true
    (struct-get index needs-shift-abort)))

(define (compiler-backend-runtime-index-with-shift-abort
  [index : CompilerBackendRuntimeIndex]) : CompilerBackendRuntimeIndex
  (CompilerBackendRuntimeIndex
    (struct-get index defines)
    (struct-get index externs)
    (struct-get index calls)
    (struct-get index needs-div-abort)
    true))

(define (compiler-backend-runtime-index-instr
  [index : CompilerBackendRuntimeIndex]
  [instr : CompilerIrInstr]) : CompilerBackendRuntimeIndex
  (match instr
    [(IrInstrCall _ call-name _ _)
      (compiler-backend-runtime-index-add-call index call-name)]
    [(IrInstrCallCAbiStoreResult _ call-name _ _)
      (compiler-backend-runtime-index-add-call index call-name)]
    [(IrInstrTailCall call-name _ _)
      (compiler-backend-runtime-index-add-call index call-name)]
    [(IrInstrBoundsCheck _ _ _)
      (compiler-backend-runtime-index-add-call index "tl_oob_abort")]
    [(IrInstrBinOp _ op _ rhs ty)
      (let
        [with-div : CompilerBackendRuntimeIndex
          (if (compiler-backend-binop-needs-div-abort? op rhs ty)
            (compiler-backend-runtime-index-with-div-abort index)
            index)]
        (if (compiler-backend-binop-needs-shift-abort? op ty)
          (compiler-backend-runtime-index-with-shift-abort with-div)
          with-div))]
    [_ index]))

(define (compiler-backend-runtime-index-safe-literal-divmod-fusion?
  [instr : CompilerIrInstr]
  [next : CompilerIrInstr]) : bool
  (match instr
    [(IrInstrMov dst src _)
      (match next
        [(IrInstrBinOp _ op _ rhs bin-ty)
          (and
            (compiler-backend-divmod-op? op)
            (compiler-backend-branch-uses-var? rhs dst)
            (compiler-backend-divmod-safe-literal? src bin-ty))]
        [_ false])]
    [_ false]))

(define (compiler-backend-runtime-index-instr-seq
  [index : CompilerBackendRuntimeIndex]
  [instrs : CompilerIrInstrSeq]) : CompilerBackendRuntimeIndex
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [i : i64 0]
    [out : CompilerBackendRuntimeIndex index]
    (begin
      (while (< i count)
        (let
          [instr : CompilerIrInstr (array-ref slots i)]
          [advance : i64 1]
          (begin
            (if (and
              (< (+ i 1) count)
              (compiler-backend-runtime-index-safe-literal-divmod-fusion?
                instr
                (array-ref slots (+ i 1))))
              (set! advance 2)
              (set! out (compiler-backend-runtime-index-instr out instr)))
            (set! i (+ i advance)))))
      out)))

(define (compiler-backend-runtime-index-blocks
  [index : CompilerBackendRuntimeIndex]
  [blocks : CompilerIrBlockList]) : CompilerBackendRuntimeIndex
  (match blocks
    [(IrBlockNil) index]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (compiler-backend-runtime-index-blocks
            (compiler-backend-runtime-index-instr-seq index instrs)
            (box-get rest))])]
    [(IrBlockArray seq)
      (compiler-backend-runtime-index-blocks
        index
        (compiler-ir-block-seq-to-list seq))]))

(define (compiler-backend-runtime-index-functions
  [index : CompilerBackendRuntimeIndex]
  [functions : CompilerIrFunctionList]) : CompilerBackendRuntimeIndex
  (match functions
    [(IrFunctionNil) index]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction name _ _ _ blocks)
          (compiler-backend-runtime-index-functions
            (compiler-backend-runtime-index-blocks
              (compiler-backend-runtime-index-add-define index name)
              blocks)
            (box-get rest))])]
    [(IrFunctionArray seq)
      (compiler-backend-runtime-index-functions
        index
        (compiler-ir-function-seq-to-list seq))]))

(define (compiler-backend-runtime-index-externs
  [index : CompilerBackendRuntimeIndex]
  [externs : CompilerIrExternList]) : CompilerBackendRuntimeIndex
  (match externs
    [(IrExternNil) index]
    [(IrExternCons item rest)
      (match item
        [(IrExtern extern-name _ _ link-symbol _ provided)
          (if provided
            (compiler-backend-runtime-index-externs index (box-get rest))
            (compiler-backend-runtime-index-externs
              (compiler-backend-runtime-index-add-extern-name
                (compiler-backend-runtime-index-add-extern-name
                  index
                  extern-name)
                link-symbol)
              (box-get rest)))])]))

(define (compiler-backend-runtime-index
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]) : CompilerBackendRuntimeIndex
  (compiler-backend-runtime-index-functions
    (compiler-backend-runtime-index-externs
      (compiler-backend-runtime-index-empty)
      externs)
    functions))

;; Runtime helper ownership inventory (#2044). This is the backend's checked-in
;; boundary table for helper names accepted by `compiler-backend-plan-provides?`.
;; New runtime-plan symbols must be classified here before the plan can provide
;; them.
;; Every runtime-helper name below begins with 't' (tl_...), '.' (.L_tl_...), or
;; 'e' (env-...). The overwhelming majority of queried names are ordinary
;; compiler/user symbols that match none, so a single first-byte test lets them
;; bail before the dozen+ non-short-circuiting string-eq comparisons run.
(define (compiler-backend-runtime-helper-name-plausible? [name : String]) : bool
  (if (= (string-length name) 0)
    false
    (let
      [c : char (string-ref name 0)]
      (or (char-eq c #t') (char-eq c #.') (char-eq c #e')))))

(define (compiler-backend-runtime-helper-name-id [name : String]) : i64
  (if (not (compiler-backend-runtime-helper-name-plausible? name))
    -1
    (begin
      (compiler-builtin-refresh!)
      (compiler-backend-runtime-name-id name))))

(define (compiler-backend-runtime-helper-core-id? [name-id : i64]) : bool
  ;; The allocator/arena substrate is irreducible backend core runtime (#2314).
  ;; It bootstraps ordinary TypeLisp allocation, owns the single
  ;; `tl_current_arena` slot, and must remain import-free/allocation-free while
  ;; acquiring and releasing arena pages. Linux page ownership is the mmap/munmap
  ;; sequence in `tl_alloc`, `tl_arena_make`, `tl_arena_destroy`, and
  ;; `tl_region_reset`; Windows uses kernel32 VirtualAlloc/VirtualFree in the
  ;; same allocation/release paths. `tl_region_mark`, `tl_arena_current`,
  ;; `tl_arena_set`, and `tl_arena_poison_enable` only read or update this
  ;; backend runtime state.
  ;; tl_oob_abort / tl_div_abort / tl_shift_abort moved to the runtime prelude
  ;; (stdlib/runtime.tl) and are now provided by #2143 export-symbol, so they are
  ;; no longer backend-owned runtime helpers (keeping them here would make the
  ;; export collide with a "known runtime symbol").
  (compiler-builtin-backend-runtime-core-id? name-id))

(define (compiler-backend-runtime-helper-core? [name : String]) : bool
  (let
    [name-id : i64 (compiler-backend-runtime-helper-name-id name)]
    (and (>= name-id 0) (compiler-backend-runtime-helper-core-id? name-id))))

;; Current stdlib modules still depend on these backend runtime shims for
;; unavoidable profile operations.
(define (compiler-backend-runtime-helper-stdlib-ffi-id? [name-id : i64]) : bool
  (compiler-builtin-backend-runtime-stdlib-ffi-id? name-id))

(define (compiler-backend-runtime-helper-stdlib-ffi? [name : String]) : bool
  (let
    [name-id : i64 (compiler-backend-runtime-helper-name-id name)]
    (and
      (>= name-id 0)
      (compiler-backend-runtime-helper-stdlib-ffi-id? name-id))))

;; Runtime compatibility surfaces whose preferred ownership is TypeLisp stdlib:
;; string equality/parsing moved in #2036 and allocating string helpers moved in
;; #2037. Migrated IO/stdin/file/argv/print/env helpers are deliberately absent
;; here: those names are stdlib-owned and must remain external from the backend
;; runtime plan for normal source builds.
(define (compiler-backend-runtime-helper-stdlib-type-lisp-id? [name-id : i64]) : bool
  (compiler-builtin-backend-runtime-stdlib-type-lisp-id? name-id))

(define (compiler-backend-runtime-helper-stdlib-type-lisp? [name : String]) : bool
  (let
    [name-id : i64 (compiler-backend-runtime-helper-name-id name)]
    (and
      (>= name-id 0)
      (compiler-backend-runtime-helper-stdlib-type-lisp-id? name-id))))

(define (compiler-backend-runtime-helper-compatibility-alias-id?
  [name-id : i64]) : bool
  (compiler-builtin-backend-runtime-compatibility-alias-id? name-id))

(define (compiler-backend-runtime-helper-compatibility-alias? [name : String]) : bool
  (let
    [name-id : i64 (compiler-backend-runtime-helper-name-id name)]
    (and
      (>= name-id 0)
      (compiler-backend-runtime-helper-compatibility-alias-id? name-id))))

(define (compiler-backend-runtime-helper-deprecated-id? [_name-id : i64]) : bool
  false)

(define (compiler-backend-runtime-helper-deprecated? [_name : String]) : bool
  false)

(define (compiler-backend-runtime-helper-owner-id [name-id : i64]) : CompilerBackendRuntimeHelperOwner
  (cond
    [(compiler-backend-runtime-helper-core-id? name-id)
      (BackendRuntimeOwnerCore)]
    [(compiler-backend-runtime-helper-stdlib-ffi-id? name-id)
      (BackendRuntimeOwnerStdlibFfi)]
    [(compiler-backend-runtime-helper-stdlib-type-lisp-id? name-id)
      (BackendRuntimeOwnerStdlibTypeLisp)]
    [(compiler-backend-runtime-helper-compatibility-alias-id? name-id)
      (BackendRuntimeOwnerCompatibilityAlias)]
    [(compiler-backend-runtime-helper-deprecated-id? name-id)
      (BackendRuntimeOwnerDeprecated)]
    [else (BackendRuntimeOwnerUnknown)]))

(define (compiler-backend-runtime-helper-owner [name : String]) : CompilerBackendRuntimeHelperOwner
  (let
    [name-id : i64 (compiler-backend-runtime-helper-name-id name)]
    (if (>= name-id 0)
      (compiler-backend-runtime-helper-owner-id name-id)
      (BackendRuntimeOwnerUnknown))))

(define (compiler-backend-runtime-helper-known-id? [name-id : i64]) : bool
  (match (compiler-backend-runtime-helper-owner-id name-id)
    [(BackendRuntimeOwnerUnknown) false]
    [_ true]))

(define (compiler-backend-runtime-helper-known? [name : String]) : bool
  (let
    [name-id : i64 (compiler-backend-runtime-helper-name-id name)]
    (and (>= name-id 0) (compiler-backend-runtime-helper-known-id? name-id))))

(define (compiler-backend-provides-runtime-name?
  [name : String]
  [candidate : String]
  [enabled : bool]) : bool
  (let
    [name-id : i64 (compiler-backend-runtime-helper-name-id name)]
    [candidate-id : i64 (compiler-backend-runtime-helper-name-id candidate)]
    (and
      enabled
      (compiler-backend-runtime-helper-known-id? candidate-id)
      (= name-id candidate-id))))

(define (compiler-backend-runtime-concat-name? [name : String]) : bool
  (let
    [name-id : i64 (compiler-backend-runtime-helper-name-id name)]
    (and (>= name-id 0) (compiler-builtin-backend-runtime-concat-id? name-id))))

(define (compiler-backend-runtime-index-defines-concat?
  [index : CompilerBackendRuntimeIndex]) : bool
  (or
    (backend-or4
      (compiler-backend-runtime-index-defines? index "tl_string_concat")
      (compiler-backend-runtime-index-defines? index "tl_string_concat3")
      (compiler-backend-runtime-index-defines? index "tl_string_concat4")
      (compiler-backend-runtime-index-defines? index "tl_string_concat5"))
    false))

(define (compiler-backend-runtime-index-extern-concat?
  [index : CompilerBackendRuntimeIndex]) : bool
  (or
    (backend-or4
      (compiler-backend-runtime-index-extern? index "tl_string_concat")
      (compiler-backend-runtime-index-extern? index "tl_string_concat3")
      (compiler-backend-runtime-index-extern? index "tl_string_concat4")
      (compiler-backend-runtime-index-extern? index "tl_string_concat5"))
    false))

(define (compiler-backend-runtime-index-calls-concat?
  [index : CompilerBackendRuntimeIndex]) : bool
  (or
    (backend-or4
      (compiler-backend-runtime-index-calls? index "tl_string_concat")
      (compiler-backend-runtime-index-calls? index "tl_string_concat3")
      (compiler-backend-runtime-index-calls? index "tl_string_concat4")
      (compiler-backend-runtime-index-calls? index "tl_string_concat5"))
    false))

(define (compiler-backend-provides-runtime-alias?
  [name : String]
  [canonical : String]
  [alias : String]
  [enabled : bool]) : bool
  (let
    [name-id : i64 (compiler-backend-runtime-helper-name-id name)]
    [canonical-id : i64 (compiler-backend-runtime-helper-name-id canonical)]
    [alias-id : i64 (compiler-backend-runtime-helper-name-id alias)]
    (and
      enabled
      (compiler-backend-runtime-helper-known-id? canonical-id)
      (compiler-backend-runtime-helper-known-id? alias-id)
      (or (= name-id canonical-id) (= name-id alias-id)))))

(define (compiler-backend-provides-profile-runtime-name?
  [name : String]
  [enabled : bool]) : bool
  (let
    [name-id : i64 (compiler-backend-runtime-helper-name-id name)]
    (and
      enabled
      (>= name-id 0)
      (compiler-builtin-backend-runtime-profile-id? name-id))))

(define (compiler-backend-runtime-name-id [name : String]) : i64
  (match (intern-lookup name)
    [(InternLookupFound name-id) name-id]
    [(InternLookupMissing) -1]))

(define (compiler-backend-plan-provides-tail-id?
  [name-id : i64]
  [read-bytes : bool]
  [stdin-eof : bool]
  [flush-stdout : bool]
  [random-system-seed : bool]
  [env-var-exists : bool]
  [env-var-value : bool]
  [env-path-separator : bool]) : bool
  (let
    [_read-bytes : bool read-bytes]
    [_stdin-eof : bool stdin-eof]
    [_flush-stdout : bool flush-stdout]
    [_random-system-seed : bool random-system-seed]
    (or
      (and env-var-exists (compiler-builtin-backend-env-var-exists-id? name-id))
      (and env-var-value (compiler-builtin-backend-env-var-value-id? name-id))
      (and
        env-path-separator
        (compiler-builtin-backend-env-path-separator-id? name-id)))))

;; The first-class arena runtime helpers (#1633) and arena poison debug toggle
;; (#1690) are always emitted, so they are provided runtime symbols (resolve to
;; their raw names, not the mangled `_tl_tl_arena_*`).
(define (compiler-backend-plan-provides?
  [plan : CompilerBackendRuntimePlan]
  [name : String]) : bool
  (begin
    (compiler-builtin-refresh!)
    (let
      [name-id : i64 (compiler-backend-runtime-name-id name)]
      (if (>= name-id 0)
        (compiler-backend-plan-provides-id? plan name-id)
        false))))

(define (compiler-backend-plan-provides-id?
  [plan : CompilerBackendRuntimePlan]
  [name-id : i64]) : bool
  (or
    (compiler-builtin-backend-runtime-always-provided-id? name-id)
    (compiler-builtin-backend-runtime-always-provided-tail-id? name-id)
    (compiler-backend-plan-provides-rest-id? plan name-id)))

(define (compiler-backend-plan-provides-rest-id?
  [plan : CompilerBackendRuntimePlan]
  [name-id : i64]) : bool
  (match plan
    [(BackendRuntimePlan
        alloc
        oob
        substring
        str-view
        concat
        _
        _
        provides-int-to-string
        provides-abort
        _
        _
        _
        _
        _
        _
        _
        _
        _
        _
        _
        provides-fs
        _
        _
        _
        _
        _
        region-mark
        region-reset
        _
        provides-env-var-exists
        provides-env-var-value
        provides-env-path-separator
        provides-div-abort
        provides-shift-abort
        provides-tail)
      (let
        [_oob : bool oob]
        [_provides-abort : bool provides-abort]
        [_provides-fs : bool provides-fs]
        [_provides-div-abort : bool provides-div-abort]
        [_provides-shift-abort : bool provides-shift-abort]
        (or
          (backend-or8
            (and alloc (compiler-builtin-backend-tl-alloc-id? name-id))
            (and
              region-mark
              (compiler-builtin-backend-tl-region-mark-id? name-id))
            (and
              region-reset
              (compiler-builtin-backend-tl-region-reset-id? name-id))
            false
            (and substring (compiler-builtin-backend-tl-substring-id? name-id))
            (and str-view (compiler-builtin-backend-tl-str-view-id? name-id))
            (and concat (compiler-builtin-backend-runtime-concat-id? name-id))
            false)
          (backend-or8
            (and
              provides-int-to-string
              (compiler-builtin-backend-tl-int-to-string-id? name-id))
            false
            false
            false
            false
            false
            false
            false)
          (compiler-backend-plan-provides-tail-id?
            name-id
            false
            false
            false
            false
            provides-env-var-exists
            provides-env-var-value
            provides-env-path-separator)
          (backend-or4
            false
            false
            (and
              (compiler-backend-runtime-tail-profile? provides-tail)
              (compiler-builtin-backend-runtime-profile-id? name-id))
            false)))]))

(define (compiler-backend-runtime-plan-for
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]) : ResultBackendRuntimePlan
  (let
    [index : CompilerBackendRuntimeIndex
      (compiler-backend-runtime-index functions externs)]
    [defines-alloc : bool
      (compiler-backend-runtime-index-defines? index "tl_alloc")]
    [defines-oob : bool
      (compiler-backend-runtime-index-defines? index "tl_oob_abort")]
    [defines-div-abort : bool
      (compiler-backend-runtime-index-defines? index "tl_div_abort")]
    [defines-shift-abort : bool
      (compiler-backend-runtime-index-defines? index "tl_shift_abort")]
    [defines-substring : bool
      (compiler-backend-runtime-index-defines? index "tl_substring")]
    [defines-str-view : bool
      (compiler-backend-runtime-index-defines? index "tl_str_view")]
    [defines-concat : bool
      (compiler-backend-runtime-index-defines-concat? index)]
    [_defines-string-eq : bool
      (compiler-backend-runtime-index-defines? index "tl_string_eq")]
    [_defines-string-to-int : bool
      (compiler-backend-runtime-index-defines? index "tl_string_to_int")]
    [_defines-hash-string : bool
      (compiler-backend-runtime-index-defines? index "tl_hash_string")]
    [defines-int-to-string : bool
      (compiler-backend-runtime-index-defines? index "tl_int_to_string")]
    [_defines-print-err : bool
      (compiler-backend-runtime-index-defines? index "tl_print_err")]
    [_defines-print-str : bool
      (compiler-backend-runtime-index-defines? index "tl_print_str")]
    [_defines-print-string : bool
      (compiler-backend-runtime-index-defines? index "tl_print_string")]
    [_defines-print-char : bool
      (compiler-backend-runtime-index-defines? index "tl_print_char")]
    [_defines-print-f64 : bool
      (compiler-backend-runtime-index-defines? index "tl_print_f64")]
    [defines-region-mark : bool
      (compiler-backend-runtime-index-defines? index "tl_region_mark")]
    [defines-region-reset : bool
      (compiler-backend-runtime-index-defines? index "tl_region_reset")]
    [defines-env-var-exists : bool
      (compiler-backend-runtime-index-defines? index "tl_env_var_exists")]
    [defines-env-var-value : bool
      (compiler-backend-runtime-index-defines? index "tl_env_var_value")]
    [defines-env-path-separator : bool
      (compiler-backend-runtime-index-defines? index "env-path-separator")]
    [defines-profile-alloc-total : bool
      (compiler-backend-runtime-index-defines? index "tl_profile_alloc_total")]
    [defines-profile-alloc-live : bool
      (compiler-backend-runtime-index-defines? index "tl_profile_alloc_live")]
    [defines-profile-alloc-peak : bool
      (compiler-backend-runtime-index-defines? index "tl_profile_alloc_peak")]
    [defines-profile-alloc-reset-peak : bool
      (compiler-backend-runtime-index-defines?
        index
        "tl_profile_alloc_reset_peak")]
    [extern-alloc : bool
      (compiler-backend-runtime-index-extern? index "tl_alloc")]
    [extern-oob : bool
      (compiler-backend-runtime-index-extern? index "tl_oob_abort")]
    [extern-div-abort : bool
      (compiler-backend-runtime-index-extern? index "tl_div_abort")]
    [extern-shift-abort : bool
      (compiler-backend-runtime-index-extern? index "tl_shift_abort")]
    [extern-substring : bool
      (compiler-backend-runtime-index-extern? index "tl_substring")]
    [extern-str-view : bool
      (compiler-backend-runtime-index-extern? index "tl_str_view")]
    [extern-concat : bool (compiler-backend-runtime-index-extern-concat? index)]
    [_extern-string-eq : bool
      (compiler-backend-runtime-index-extern? index "tl_string_eq")]
    [_extern-string-to-int : bool
      (compiler-backend-runtime-index-extern? index "tl_string_to_int")]
    [_extern-hash-string : bool
      (compiler-backend-runtime-index-extern? index "tl_hash_string")]
    [extern-int-to-string : bool
      (compiler-backend-runtime-index-extern? index "tl_int_to_string")]
    [extern-abort : bool
      (compiler-backend-runtime-index-extern-alias?
        index
        ".L_tl_abort"
        "tl_abort_string")]
    [_extern-print-err : bool
      (compiler-backend-runtime-index-extern-alias?
        index
        "tl_print_err"
        "tl_print_error")]
    [_extern-print-str : bool
      (compiler-backend-runtime-index-extern-alias?
        index
        "tl_print_str"
        "tl_print_string")]
    [_extern-print-char : bool
      (compiler-backend-runtime-index-extern? index "tl_print_char")]
    [_extern-print-f64 : bool
      (compiler-backend-runtime-index-extern? index "tl_print_f64")]
    [_extern-arg-count : bool
      (compiler-backend-runtime-index-extern-alias?
        index
        ".L_tl_arg_count"
        "tl_arg_count")]
    [_extern-arg : bool
      (compiler-backend-runtime-index-extern-alias? index ".L_tl_arg" "tl_arg")]
    [_extern-read-file : bool
      (compiler-backend-runtime-index-extern? index ".L_tl_read_file")]
    [_extern-write-file : bool
      (compiler-backend-runtime-index-extern? index ".L_tl_write_file")]
    [_extern-file-exists : bool
      (compiler-backend-runtime-index-extern? index ".L_tl_file_exists")]
    [_extern-read-file-status : bool
      (compiler-backend-runtime-index-extern? index ".L_tl_read_file_status")]
    [_extern-write-file-status : bool
      (compiler-backend-runtime-index-extern? index ".L_tl_write_file_status")]
    [_extern-append-file-status : bool
      (compiler-backend-runtime-index-extern? index ".L_tl_append_file_status")]
    [_extern-file-exists-status : bool
      (compiler-backend-runtime-index-extern? index ".L_tl_file_exists_status")]
    [_extern-file-open-status : bool
      (compiler-backend-runtime-index-extern? index ".L_tl_file_open_status")]
    [_extern-file-close-status : bool
      (compiler-backend-runtime-index-extern? index ".L_tl_file_close_status")]
    [_extern-file-read-chunk-status : bool
      (compiler-backend-runtime-index-extern?
        index
        ".L_tl_file_read_chunk_status")]
    [_extern-file-write-status : bool
      (compiler-backend-runtime-index-extern? index ".L_tl_file_write_status")]
    [_extern-file-flush-status : bool
      (compiler-backend-runtime-index-extern? index ".L_tl_file_flush_status")]
    [_extern-file-read-chunk-bytes : bool
      (compiler-backend-runtime-index-extern?
        index
        ".L_tl_file_read_chunk_bytes")]
    [_extern-file-read-chunk-eof : bool
      (compiler-backend-runtime-index-extern? index ".L_tl_file_read_chunk_eof")]
    [_extern-fs-mkdir-status : bool
      (compiler-backend-runtime-index-extern? index ".L_tl_fs_mkdir_status")]
    [_extern-fs-remove-file-status : bool
      (compiler-backend-runtime-index-extern?
        index
        ".L_tl_fs_remove_file_status")]
    [_extern-fs-remove-dir-status : bool
      (compiler-backend-runtime-index-extern?
        index
        ".L_tl_fs_remove_dir_status")]
    [_extern-fs-rename-status : bool
      (compiler-backend-runtime-index-extern? index ".L_tl_fs_rename_status")]
    [_extern-fs-process-id : bool
      (compiler-backend-runtime-index-extern? index ".L_tl_fs_process_id")]
    [_extern-read-line : bool
      (compiler-backend-runtime-index-extern? index ".L_tl_read_stdin_line")]
    [_extern-read-bytes : bool
      (compiler-backend-runtime-index-extern? index ".L_tl_read_stdin_bytes")]
    [_extern-stdin-eof : bool
      (compiler-backend-runtime-index-extern? index ".L_tl_stdin_eof")]
    [_extern-flush-stdout : bool
      (compiler-backend-runtime-index-extern? index ".L_tl_flush_stdout")]
    [extern-region-mark : bool
      (compiler-backend-runtime-index-extern? index "tl_region_mark")]
    [extern-region-reset : bool
      (compiler-backend-runtime-index-extern? index "tl_region_reset")]
    [extern-env-var-exists : bool
      (compiler-backend-runtime-index-extern? index "tl_env_var_exists")]
    [extern-env-var-value : bool
      (compiler-backend-runtime-index-extern? index "tl_env_var_value")]
    [extern-env-path-separator : bool
      (compiler-backend-runtime-index-extern? index "env-path-separator")]
    [extern-profile-alloc-total : bool
      (compiler-backend-runtime-index-extern? index "tl_profile_alloc_total")]
    [extern-profile-alloc-live : bool
      (compiler-backend-runtime-index-extern? index "tl_profile_alloc_live")]
    [extern-profile-alloc-peak : bool
      (compiler-backend-runtime-index-extern? index "tl_profile_alloc_peak")]
    [extern-profile-alloc-reset-peak : bool
      (compiler-backend-runtime-index-extern?
        index
        "tl_profile_alloc_reset_peak")]
    [calls-alloc : bool
      (compiler-backend-runtime-index-calls? index "tl_alloc")]
    [calls-oob : bool
      (compiler-backend-runtime-index-calls? index "tl_oob_abort")]
    [calls-div-abort : bool
      (compiler-backend-runtime-index-calls? index "tl_div_abort")]
    [calls-shift-abort : bool
      (compiler-backend-runtime-index-calls? index "tl_shift_abort")]
    [calls-substring : bool
      (compiler-backend-runtime-index-calls? index "tl_substring")]
    [calls-str-view : bool
      (compiler-backend-runtime-index-calls? index "tl_str_view")]
    [calls-concat : bool (compiler-backend-runtime-index-calls-concat? index)]
    [_calls-string-eq : bool
      (compiler-backend-runtime-index-calls? index "tl_string_eq")]
    [_calls-string-to-int : bool
      (compiler-backend-runtime-index-calls? index "tl_string_to_int")]
    [_calls-hash-string : bool
      (compiler-backend-runtime-index-calls? index "tl_hash_string")]
    [calls-int-to-string : bool
      (compiler-backend-runtime-index-calls? index "tl_int_to_string")]
    [calls-abort : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_abort")]
    [_calls-print-err : bool
      (compiler-backend-runtime-index-calls? index "tl_print_err")]
    [_calls-print-str : bool
      (compiler-backend-runtime-index-calls? index "tl_print_str")]
    [_calls-print-string : bool
      (compiler-backend-runtime-index-calls? index "tl_print_string")]
    [_calls-print-char : bool
      (compiler-backend-runtime-index-calls? index "tl_print_char")]
    [_calls-print-f64 : bool
      (compiler-backend-runtime-index-calls? index "tl_print_f64")]
    [_calls-arg-count : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_arg_count")]
    [_calls-arg : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_arg")]
    [_calls-read-file : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_read_file")]
    [_calls-write-file : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_write_file")]
    [_calls-file-exists : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_file_exists")]
    [_calls-read-file-status : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_read_file_status")]
    [_calls-write-file-status : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_write_file_status")]
    [_calls-append-file-status : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_append_file_status")]
    [_calls-file-exists-status : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_file_exists_status")]
    [_calls-file-open-status : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_file_open_status")]
    [_calls-file-close-status : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_file_close_status")]
    [_calls-file-read-chunk-status : bool
      (compiler-backend-runtime-index-calls?
        index
        ".L_tl_file_read_chunk_status")]
    [_calls-file-write-status : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_file_write_status")]
    [_calls-file-flush-status : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_file_flush_status")]
    [_calls-file-read-chunk-bytes : bool
      (compiler-backend-runtime-index-calls?
        index
        ".L_tl_file_read_chunk_bytes")]
    [_calls-file-read-chunk-eof : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_file_read_chunk_eof")]
    [_calls-fs-mkdir-status : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_fs_mkdir_status")]
    [_calls-fs-remove-file-status : bool
      (compiler-backend-runtime-index-calls?
        index
        ".L_tl_fs_remove_file_status")]
    [_calls-fs-remove-dir-status : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_fs_remove_dir_status")]
    [_calls-fs-rename-status : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_fs_rename_status")]
    [_calls-fs-process-id : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_fs_process_id")]
    [_calls-read-line : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_read_stdin_line")]
    [_calls-read-bytes : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_read_stdin_bytes")]
    [_calls-stdin-eof : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_stdin_eof")]
    [_calls-flush-stdout : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_flush_stdout")]
    [calls-region-mark : bool
      (compiler-backend-runtime-index-calls? index "tl_region_mark")]
    [calls-region-reset : bool
      (compiler-backend-runtime-index-calls? index "tl_region_reset")]
    [calls-env-var-exists : bool
      (compiler-backend-runtime-index-calls? index "tl_env_var_exists")]
    [calls-env-var-value : bool
      (compiler-backend-runtime-index-calls? index "tl_env_var_value")]
    [calls-env-path-separator : bool
      (compiler-backend-runtime-index-calls? index "env-path-separator")]
    [calls-profile-alloc-total : bool
      (compiler-backend-runtime-index-calls? index "tl_profile_alloc_total")]
    [calls-profile-alloc-live : bool
      (compiler-backend-runtime-index-calls? index "tl_profile_alloc_live")]
    [calls-profile-alloc-peak : bool
      (compiler-backend-runtime-index-calls? index "tl_profile_alloc_peak")]
    [calls-profile-alloc-reset-peak : bool
      (compiler-backend-runtime-index-calls?
        index
        "tl_profile_alloc_reset_peak")]
    [needs-oob : bool (and (not defines-oob) (or extern-oob calls-oob))]
    [needs-div-abort : bool
      (or
        (compiler-backend-runtime-index-needs-div-abort? index)
        (and (not defines-div-abort) (or extern-div-abort calls-div-abort)))]
    [needs-shift-abort : bool
      (or
        (compiler-backend-runtime-index-needs-shift-abort? index)
        (and
          (not defines-shift-abort)
          (or extern-shift-abort calls-shift-abort)))]
    [needs-substring : bool
      (and (not defines-substring) (or extern-substring calls-substring))]
    [needs-str-view : bool
      (and (not defines-str-view) (or extern-str-view calls-str-view))]
    [needs-concat : bool
      (and (not defines-concat) (or extern-concat calls-concat))]
    [_needs-string-eq : bool false]
    [_needs-string-to-int : bool false]
    [_needs-hash-string : bool false]
    [needs-int-to-string : bool
      (and
        (not defines-int-to-string)
        (or extern-int-to-string calls-int-to-string))]
    [_direct-abort : bool false]
    [needs-print-err : bool false]
    [needs-print-str : bool false]
    [needs-print-char : bool false]
    [needs-print-f64 : bool false]
    [needs-arg-count : bool false]
    [needs-arg : bool false]
    [needs-read-file : bool false]
    [needs-write-file : bool false]
    [needs-file-exists : bool false]
    [needs-file-handle : bool false]
    [needs-file-read-chunk : bool false]
    [needs-fs-runtime : bool false]
    [needs-read-line : bool false]
    [needs-read-bytes : bool false]
    [needs-stdin-eof : bool false]
    [needs-flush-stdout : bool false]
    [needs-region-mark : bool
      (and (not defines-region-mark) (or extern-region-mark calls-region-mark))]
    [needs-region-reset : bool
      (and
        (not defines-region-reset)
        (or extern-region-reset calls-region-reset))]
    [needs-random-system-seed : bool false]
    [needs-env-var-exists : bool
      (and
        (not defines-env-var-exists)
        (or extern-env-var-exists calls-env-var-exists))]
    [needs-env-var-value : bool
      (and
        (not defines-env-var-value)
        (or extern-env-var-value calls-env-var-value))]
    [needs-env-path-separator : bool
      (and
        (not defines-env-path-separator)
        (or extern-env-path-separator calls-env-path-separator))]
    [direct-alloc : bool
      (and (not defines-alloc) (or extern-alloc calls-alloc))]
    [needs-abort : bool
      (or extern-abort calls-abort needs-arg needs-read-file needs-write-file)]
    [needs-alloc : bool
      (or
        (backend-or8
          direct-alloc
          needs-int-to-string
          needs-substring
          needs-str-view
          needs-arg
          needs-read-file
          needs-write-file
          needs-file-exists)
        (backend-or8
          needs-file-handle
          needs-file-read-chunk
          needs-fs-runtime
          false
          needs-read-line
          needs-read-bytes
          needs-random-system-seed
          false)
        (backend-or4
          needs-env-var-exists
          needs-env-var-value
          needs-env-path-separator
          false))]
    [needs-profile : bool
      (backend-or4
        (and
          (not defines-profile-alloc-total)
          (or extern-profile-alloc-total calls-profile-alloc-total))
        (and
          (not defines-profile-alloc-live)
          (or extern-profile-alloc-live calls-profile-alloc-live))
        (and
          (not defines-profile-alloc-peak)
          (or extern-profile-alloc-peak calls-profile-alloc-peak))
        (and
          (not defines-profile-alloc-reset-peak)
          (or extern-profile-alloc-reset-peak calls-profile-alloc-reset-peak)))]
    (OkBackendRuntimePlan
      (BackendRuntimePlan
        needs-alloc
        needs-oob
        needs-substring
        needs-str-view
        needs-concat
        false
        false
        needs-int-to-string
        needs-abort
        needs-print-err
        needs-print-str
        needs-print-char
        needs-print-f64
        needs-arg-count
        needs-arg
        needs-read-file
        needs-write-file
        needs-file-exists
        needs-file-handle
        needs-file-read-chunk
        needs-fs-runtime
        false
        needs-read-line
        needs-read-bytes
        needs-stdin-eof
        needs-flush-stdout
        needs-region-mark
        needs-region-reset
        needs-random-system-seed
        needs-env-var-exists
        needs-env-var-value
        needs-env-path-separator
        needs-div-abort
        needs-shift-abort
        (CompilerBackendRuntimeTailPlan needs-profile false)))))

(define (compiler-backend-runtime-plan [program : CompilerIrProgram]) : ResultBackendRuntimePlan
  (begin
    ;; Seed builtin/runtime ids before scratch-backed per-function emission. The
    ;; runtime-plan id predicates are then lookup-only in scratch arenas.
    (compiler-builtin-refresh!)
    (match program
      [(IrProgram _ functions externs)
        (compiler-backend-runtime-plan-for functions externs)])))

(define (compiler-backend-emit-externs
  [externs : CompilerIrExternList]
  [plan : CompilerBackendRuntimePlan]) : String
  (text-buf-render
    (compiler-backend-emit-externs-into externs plan (text-buf-empty))))

(define (compiler-backend-emit-externs-into
  [externs : CompilerIrExternList]
  [plan : CompilerBackendRuntimePlan]
  [buf : TextBuf]) : TextBuf
  (match externs
    [(IrExternNil) buf]
    [(IrExternCons item rest)
      (match item
        [(IrExtern name _ _ link-symbol _ provided)
          (if (not
            (compiler-backend-emits-extern-symbol?
              name
              link-symbol
              provided
              plan))
            (compiler-backend-emit-externs-into (box-get rest) plan buf)
            (compiler-backend-emit-externs-into
              (box-get rest)
              plan
              (text-buf-append
                (text-buf-append buf ".extern ")
                (str-cat
                  (compiler-backend-link-symbol link-symbol plan)
                  "\n"
                  ""))))])]))

;; The out-of-memory message moved to the runtime prelude (stdlib/runtime.tl as
;; `tl-runtime-oom-abort`, exported `tl_oom_abort` via #2221); the allocator's
;; abort paths now `jmp tl_oom_abort` instead of writing backend rodata, so the
;; allocator contributes no runtime data.
(define (compiler-backend-runtime-alloc-data-for-target
  [_target : CompilerBackendTarget]) : String
  "")

;; `tl_current_arena` is the live bump-arena pointer shared by tl_alloc, the
;; region runtime, and the first-class arena builtins (#1633). It is now a
;; per-thread active-arena slot (#2591): Linux uses local-exec ELF TLS; Windows
;; stores the pointer in the TEB arbitrary-user slot (GS:0x28). Like the arena
;; primitives, the runtime lives in exactly ONE object per executable (the entry
;; object, `emit-entry=true`); library/dependency objects (`emit-entry=false`)
;; emit none of the runtime and reference the Linux TLS slot as an extern.
(define (compiler-backend-runtime-arena-data-for-target
  [target : CompilerBackendTarget]) : String
  (match target
    [(BackendTargetLinux)
      "    .section .tbss,\"awT\",@nobits
    .balign 8
    .globl tl_current_arena
tl_current_arena:
    .zero 8

    .section .bss
    .balign 8
.L_tl_arena_poison_enabled:
    .zero 8

"]
    [(BackendTargetWindows)
      "    .section .bss
    .balign 8
.L_tl_arena_poison_enabled:
    .zero 8

"]))

(define (compiler-backend-current-arena-load
  [target : CompilerBackendTarget]
  [dst : String]) : String
  (if (compiler-backend-target-windows? target)
    (str-cat "    movq %gs:0x28, " dst "\n")
    (str-cat "    movq %fs:tl_current_arena@tpoff, " dst "\n")))

(define (compiler-backend-current-arena-store
  [target : CompilerBackendTarget]
  [src : String]) : String
  (if (compiler-backend-target-windows? target)
    (str-cat "    movq " src ", %gs:0x28\n")
    (str-cat "    movq " src ", %fs:tl_current_arena@tpoff\n")))

(define (compiler-backend-current-arena-clear [target : CompilerBackendTarget]) : String
  (if (compiler-backend-target-windows? target)
    "    movq $0, %gs:0x28\n"
    "    movq $0, %fs:tl_current_arena@tpoff\n"))

(define (compiler-backend-runtime-profile-data [profile : bool]) : String
  (if profile
    "    .section .bss
    .balign 8
tl_profile_alloc_total_bytes:
    .zero 8
tl_profile_alloc_live_bytes:
    .zero 8
tl_profile_alloc_peak_bytes:
    .zero 8

"
    ""))

(define (compiler-backend-runtime-region-reset-data) : String
  "    .section .rodata
.L_tl_region_reset_msg:
    .byte 116,108,58,32,105,110,118,97,108,105,100,32,114,101,103,105,111,110,32,109,97,114,107,10
    .set .L_tl_region_reset_msg_len, . - .L_tl_region_reset_msg

")

;; The oob/division/shift fault message data moved to the runtime prelude
;; (stdlib/runtime.tl) handlers (#2143); the backend no longer emits it.
(define (compiler-backend-runtime-argv-data) : String
  "    .data
    .balign 8
.L_tl_argc:
    .quad 0
.L_tl_argv:
    .quad 0

")

(define (compiler-backend-runtime-env-data
  [target : CompilerBackendTarget]
  [env-data : bool]) : String
  (let
    [_target : CompilerBackendTarget target]
    [_env-data : bool env-data]
    "    .data
    .balign 8
.L_tl_envp:
    .quad 0

"))

(define (compiler-backend-runtime-data-for-target
  [target : CompilerBackendTarget]
  [plan : CompilerBackendRuntimePlan]) : String
  (match plan
    [(BackendRuntimePlan
        alloc
        oob
        _
        _
        _
        _
        _
        _
        _
        _
        _
        _
        _
        _
        _
        _
        _
        _
        _
        _
        _
        _
        _
        _
        _
        _
        region-mark
        region-reset
        _
        env-var-exists
        env-var-value
        _
        div-abort
        shift-abort
        tail-plan)
      (string-append
        (string-append
          (compiler-backend-runtime-arena-data-for-target target)
          (string-append
            (compiler-backend-runtime-profile-data
              (compiler-backend-runtime-tail-profile? tail-plan))
            (if alloc
              (compiler-backend-runtime-alloc-data-for-target target)
              "")))
        (string-append
          ;; The oob/division/shift fault messages now live in the runtime
          ;; prelude (stdlib/runtime.tl) handlers, not backend rodata (#2143).
          ""
          (string-append
            (if region-reset
              (compiler-backend-runtime-region-reset-data)
              "")
            (string-append
              (compiler-backend-runtime-argv-data)
              (compiler-backend-runtime-env-data
                target
                (or env-var-exists env-var-value))))))]))

(define (compiler-backend-runtime-profile-alloc-account
  [size-reg : String]
  [done-label : String]
  [profile : bool]) : String
  (if profile
    (string-append
      (str-cat
        "    addq "
        size-reg
        ", tl_profile_alloc_total_bytes(%rip)\n    addq "
        size-reg
        ", tl_profile_alloc_live_bytes(%rip)\n")
      (str-cat
        "    movq tl_profile_alloc_live_bytes(%rip), %r10\n    cmpq tl_profile_alloc_peak_bytes(%rip), %r10\n    jbe "
        done-label
        "\n    movq %r10, tl_profile_alloc_peak_bytes(%rip)\n"
        done-label
        ":\n"))
    ""))

(define (compiler-backend-runtime-profile-live-sub
  [arena-reg : String]
  [used-reg : String]
  [profile : bool]) : String
  (if profile
    (str-cat
      "    movq 16("
      arena-reg
      "), "
      used-reg
      "\n    subq 8("
      arena-reg
      "), "
      used-reg
      "\n    subq "
      used-reg
      ", tl_profile_alloc_live_bytes(%rip)\n")
    ""))

(define (compiler-backend-runtime-profile-live-rewind
  [arena-reg : String]
  [mark-reg : String]
  [used-reg : String]
  [profile : bool]) : String
  (if profile
    (str-cat
      "    movq 16("
      arena-reg
      "), "
      used-reg
      "\n    subq "
      mark-reg
      ", "
      used-reg
      "\n    subq "
      used-reg
      ", tl_profile_alloc_live_bytes(%rip)\n")
    ""))

(define (compiler-backend-runtime-fast-alloc-function
  [target : CompilerBackendTarget]
  [size : i64]
  [size-reg : String]
  [next-reg : String]
  [profile : bool]) : String
  (let
    [size-text : String (int->string size)]
    [size-imm : String (string-append "$" size-text)]
    [label : String (compiler-backend-fast-alloc-label size)]
    [slow-label : String (string-append label "_slow")]
    [atomic-label : String (string-append label "_atomic")]
    [atomic-cas-label : String (string-append label "_atomic_cas")]
    [atomic-profile-label : String (string-append label "_atomic_profile_done")]
    [profile-label : String (string-append label "_profile_done")]
    [prologue : String
      (str-cat
        label
        ":\n"
        (compiler-backend-current-arena-load target "%r8")
        "    testq %r8, %r8\n    jz "
        slow-label
        "\n")]
    [ordinary-body-a : String
      (backend-cat4
        "    movq 40(%r8), %r9
    testq $1, 48(%r9)
    jnz "
        atomic-label
        "
    movq 16(%r8), %rax
    movq %rax, "
        next-reg)]
    [ordinary-body-b : String
      (backend-cat4 "\n    addq $" size-text ", " next-reg)]
    [ordinary-body-c : String
      (backend-cat4 "\n    jc " slow-label "\n    cmpq 24(%r8), " next-reg)]
    [ordinary-body-d : String
      (backend-cat4 "\n    ja " slow-label "\n    movq " next-reg)]
    [ordinary-body : String
      (backend-cat4
        ordinary-body-a
        ordinary-body-b
        ordinary-body-c
        (backend-cat3 ordinary-body-d ", 16(%r8)\n" ""))]
    [ordinary-profile : String
      (compiler-backend-runtime-profile-alloc-account
        size-imm
        profile-label
        profile)]
    [atomic-body-a : String
      (backend-cat4
        "    ret
"
        atomic-label
        ":
    movq 56(%r9), %r8
    movq 16(%r8), %rax
"
        atomic-cas-label)]
    [atomic-body-b : String
      (backend-cat4 ":\n    movq %rax, " next-reg "\n    addq $" size-text)]
    [atomic-body-c : String (backend-cat4 ", " next-reg "\n    jc " slow-label)]
    [atomic-body-d : String
      (backend-cat4 "\n    cmpq 24(%r8), " next-reg "\n    ja " slow-label)]
    [atomic-body-e : String
      (backend-cat4
        "\n    lock cmpxchgq "
        next-reg
        ", 16(%r8)\n    jne "
        atomic-cas-label)]
    [atomic-body : String
      (backend-cat4
        atomic-body-a
        atomic-body-b
        atomic-body-c
        (backend-cat3 atomic-body-d atomic-body-e "\n"))]
    [atomic-profile : String
      (compiler-backend-runtime-profile-alloc-account
        size-imm
        atomic-profile-label
        profile)]
    [slow-body : String
      (str-cat
        "    ret
"
        slow-label
        ":\n    movq $"
        size-text
        ", "
        size-reg
        "\n    jmp tl_alloc\n")]
    (string-append
      prologue
      (string-append
        ordinary-body
        (string-append
          ordinary-profile
          (string-append atomic-body (string-append atomic-profile slow-body)))))))

(define (compiler-backend-runtime-fast-alloc-functions
  [target : CompilerBackendTarget]
  [size-reg : String]
  [next-reg : String]
  [profile : bool]) : String
  (string-append
    (string-append
      (compiler-backend-runtime-fast-alloc-function
        target
        8
        size-reg
        next-reg
        profile)
      (compiler-backend-runtime-fast-alloc-function
        target
        16
        size-reg
        next-reg
        profile))
    (string-append
      (string-append
        (compiler-backend-runtime-fast-alloc-function
          target
          24
          size-reg
          next-reg
          profile)
        (compiler-backend-runtime-fast-alloc-function
          target
          32
          size-reg
          next-reg
          profile))
      (string-append
        (string-append
          (compiler-backend-runtime-fast-alloc-function
            target
            40
            size-reg
            next-reg
            profile)
          (compiler-backend-runtime-fast-alloc-function
            target
            48
            size-reg
            next-reg
            profile))
        (string-append
          (compiler-backend-runtime-fast-alloc-function
            target
            56
            size-reg
            next-reg
            profile)
          (compiler-backend-runtime-fast-alloc-function
            target
            64
            size-reg
            next-reg
            profile))))))

(define (compiler-backend-runtime-linux-alloc-functions [profile : bool]) : String
  (let
    [fast-profile : String
      (compiler-backend-runtime-profile-alloc-account
        "%rsi"
        ".L_tl_alloc_profile_fast_done"
        profile)]
    [atomic-fast-profile : String
      (compiler-backend-runtime-profile-alloc-account
        "%rsi"
        ".L_tl_alloc_profile_atomic_fast_done"
        profile)]
    [atomic-locked-profile : String
      (compiler-backend-runtime-profile-alloc-account
        "%rsi"
        ".L_tl_alloc_profile_atomic_locked_done"
        profile)]
    [atomic-new-profile : String
      (compiler-backend-runtime-profile-alloc-account
        "%rsi"
        ".L_tl_alloc_profile_atomic_new_done"
        profile)]
    [new-profile : String
      (compiler-backend-runtime-profile-alloc-account
        "%rsi"
        ".L_tl_alloc_profile_new_done"
        profile)]
    [prefix : String
      (str-cat
        (compiler-backend-runtime-fast-alloc-functions
          (BackendTargetLinux)
          "%rdi"
          "%rcx"
          profile)
        "    .globl tl_alloc
tl_alloc:
    addq $7, %rdi
    jc .L_tl_alloc_abort
    andq $-8, %rdi
    movq %rdi, %rsi
    movq %fs:tl_current_arena@tpoff, %r8
    testq %r8, %r8
    jz .L_tl_alloc_new_arena
    movq 40(%r8), %r9
    testq $1, 48(%r9)
    jnz .L_tl_alloc_atomic
    movq 16(%r8), %rax
    movq %rax, %rcx
    addq %rsi, %rcx
    jc .L_tl_alloc_abort
    cmpq 24(%r8), %rcx
    ja .L_tl_alloc_new_arena
    movq %rcx, 16(%r8)
"
        "")]
    [atomic-fast-asm : String
      "    ret
.L_tl_alloc_atomic:
    movq 56(%r9), %r8
    movq 16(%r8), %rax
.L_tl_alloc_atomic_cas:
    movq %rax, %rcx
    addq %rsi, %rcx
    jc .L_tl_alloc_abort
    cmpq 24(%r8), %rcx
    ja .L_tl_alloc_atomic_new_arena
    lock cmpxchgq %rcx, 16(%r8)
    jne .L_tl_alloc_atomic_cas
"]
    [atomic-lock-asm : String
      "    ret
.L_tl_alloc_atomic_new_arena:
    movq $1, %rax
    movq $3, %rcx
    lock cmpxchgq %rcx, 48(%r9)
    je .L_tl_alloc_atomic_locked
    pause
    jmp .L_tl_alloc_atomic_new_arena
.L_tl_alloc_atomic_locked:
    movq 56(%r9), %r8
    movq 16(%r8), %rax
.L_tl_alloc_atomic_locked_cas:
    movq %rax, %rcx
    addq %rsi, %rcx
    jc .L_tl_alloc_atomic_abort_locked
    cmpq 24(%r8), %rcx
    ja .L_tl_alloc_atomic_map
    lock cmpxchgq %rcx, 16(%r8)
    jne .L_tl_alloc_atomic_locked_cas
    movq $1, 48(%r9)
"]
    [atomic-map-asm : String
      "    ret
.L_tl_alloc_atomic_abort_locked:
    movq $1, 48(%r9)
    jmp .L_tl_alloc_abort
.L_tl_alloc_atomic_map:
    movq $0x4000000, %rdx
    movq %rsi, %rcx
    addq $64, %rcx
    jc .L_tl_alloc_abort
    cmpq %rdx, %rcx
    jbe .L_tl_alloc_atomic_len_ready
    movq %rcx, %rdx
.L_tl_alloc_atomic_len_ready:
    push %r9
    push %rdx
    push %rsi
    movq %rdx, %rsi
    xorq %rdi, %rdi
    movq $3, %rdx
    movq $0x22, %r10
    movq $-1, %r8
    xorq %r9, %r9
    movq $9, %rax
    syscall
    pop %rsi
    pop %rdx
    pop %r9
    testq %rax, %rax
    js .L_tl_alloc_abort
    movq %rax, %rcx
    addq %rdx, %rcx
    jc .L_tl_alloc_abort
    movq 56(%r9), %r8
    movq %r8, 0(%rax)
    movq $0, 32(%rax)
    movq %r9, 40(%rax)
    movq $1, 48(%rax)
    movq $0, 56(%rax)
    leaq 64(%rax), %r8
    movq %r8, 8(%rax)
    movq %rcx, 24(%rax)
    movq %r8, %rcx
    addq %rsi, %rcx
    movq %rcx, 16(%rax)
    movq %rax, 56(%r9)
    movq %rax, %fs:tl_current_arena@tpoff
    movq $1, 48(%r9)
    movq %r8, %rax
"]
    [ordinary-new-asm : String
      "    ret
.L_tl_alloc_new_arena:
    movq $0x4000000, %rdx
    movq %rsi, %rcx
    addq $64, %rcx
    jc .L_tl_alloc_abort
    cmpq %rdx, %rcx
    jbe .L_tl_alloc_len_ready
    movq %rcx, %rdx
.L_tl_alloc_len_ready:
    push %rdx
    push %rsi
    movq %rdx, %rsi
    xorq %rdi, %rdi
    movq $3, %rdx
    movq $0x22, %r10
    movq $-1, %r8
    xorq %r9, %r9
    movq $9, %rax
    syscall
    pop %rsi
    pop %rdx
    testq %rax, %rax
    js .L_tl_alloc_abort
    movq %rax, %rcx
    addq %rdx, %rcx
    jc .L_tl_alloc_abort
    movq %fs:tl_current_arena@tpoff, %r8
    movq %r8, 0(%rax)
    movq $0, 32(%rax)
    testq %r8, %r8
    jz .L_tl_alloc_root_self
    movq 40(%r8), %r10
    jmp .L_tl_alloc_root_ready
.L_tl_alloc_root_self:
    movq %rax, %r10
.L_tl_alloc_root_ready:
    movq %r10, 40(%rax)
    movq $0, 48(%rax)
    movq %rax, 56(%rax)
    leaq 64(%rax), %r8
    movq %r8, 8(%rax)
    movq %rcx, 24(%rax)
    movq %r8, %rcx
    addq %rsi, %rcx
    movq %rcx, 16(%rax)
    movq %rax, %fs:tl_current_arena@tpoff
    movq %r8, %rax
"]
    [tail-asm : String "    ret
.L_tl_alloc_abort:
    jmp tl_oom_abort

"]
    (string-append
      prefix
      (string-append
        fast-profile
        (string-append
          atomic-fast-asm
          (string-append
            atomic-fast-profile
            (string-append
              atomic-lock-asm
              (string-append
                atomic-locked-profile
                (string-append
                  atomic-map-asm
                  (string-append
                    atomic-new-profile
                    (string-append
                      ordinary-new-asm
                      (string-append new-profile tail-asm))))))))))))

(define (compiler-backend-runtime-region-mark-functions
  [target : CompilerBackendTarget]) : String
  (string-append
    "    .globl tl_region_mark
tl_region_mark:
"
    (string-append
      (compiler-backend-current-arena-load target "%rax")
      "    testq %rax, %rax
    jz .L_tl_region_mark_zero
.L_tl_region_mark_current:
    movq 40(%rax), %r8
    testq $1, 48(%r8)
    jz .L_tl_region_mark_read
    movq 56(%r8), %rax
.L_tl_region_mark_read:
    movq 16(%rax), %rax
    ret
.L_tl_region_mark_zero:
    xorq %rax, %rax
    ret

")))

;; Freestanding Linux runtime support (#no-libc). Most stdlib OS calls are raw
;; `syscall`s in TypeLisp bodies (io.tl/fs.tl/env.tl/runtime.tl). The
;; allocator/arena page calls are the deliberate backend-core exception (#2314).
;; The former `strlen`/`getenv`/`fflush` shims and private errno accessor have
;; moved into TypeLisp stdlib code, so the final link needs no `-lc` and no
;; dynamic loader.
(define (compiler-backend-runtime-linux-libc-shim-functions) : String
  "")

;; Windows freestanding runtime support (kernel32-only). Like the Linux side,
;; most OS-calling primitives now live in TypeLisp (io.tl/fs.tl/env.tl/
;; runtime.tl via direct kernel32 bindings). The allocator/arena VirtualAlloc/
;; VirtualFree page calls are the deliberate backend-core exception (#2314), and
;; this block retains the other genuinely backend-level pieces: `__chkstk`
;; (required by the MSVC ABI for large stack frames), and the program entry
;; (`tl_setup_argv` builds argv from
;; GetCommandLineA, `_tl_start` is the entry thunk). The former `_errno`,
;; `strlen`/`getenv`/`fflush` shims and the `.L_tl_win_write_abort` OOM helper
;; were removed (stdlib owns errno, env.tl walks GetEnvironmentStringsA itself;
;; tl_setup_argv now inlines its NUL scan; the OOM abort moved to the
;; `tl_oom_abort` prelude handler).
(define (compiler-backend-runtime-windows-libc-shim-functions) : String
  "    .globl __chkstk
__chkstk:
    pushq %rcx
    pushq %rax
    movq %rax, %rcx
    leaq 16(%rsp), %rax
.L_tl_ck_loop:
    cmpq $4096, %rcx
    jb .L_tl_ck_done
    subq $4096, %rax
    movb $0, (%rax)
    subq $4096, %rcx
    jmp .L_tl_ck_loop
.L_tl_ck_done:
    subq %rcx, %rax
    movb $0, (%rax)
    popq %rax
    popq %rcx
    ret

    .globl tl_setup_argv
tl_setup_argv:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    subq $40, %rsp
    call GetCommandLineA
    movq %rax, %rbx
    xorq %r12, %r12
.L_tl_argv_cmdlen:
    cmpb $0, (%rbx,%r12)
    je .L_tl_argv_cmdlen_done
    incq %r12
    jmp .L_tl_argv_cmdlen
.L_tl_argv_cmdlen_done:
    leaq 1(%r12), %rcx
    subq $32, %rsp
    call .L_tl_boot_alloc
    addq $32, %rsp
    movq %rax, %r13
    xorq %rcx, %rcx
.L_tl_argv_cp:
    cmpq %r12, %rcx
    jge .L_tl_argv_cpd
    movb (%rbx,%rcx), %al
    movb %al, (%r13,%rcx)
    incq %rcx
    jmp .L_tl_argv_cp
.L_tl_argv_cpd:
    movb $0, (%r13,%r12)
    movq $2056, %rcx
    subq $32, %rsp
    call .L_tl_boot_alloc
    addq $32, %rsp
    movq %rax, %r14
    xorq %r15, %r15
    movq %r13, %rbx
.L_tl_argv_scan:
    movb (%rbx), %al
    cmpb $0, %al
    je .L_tl_argv_done
    cmpb $0x20, %al
    jne .L_tl_argv_tokstart
    incq %rbx
    jmp .L_tl_argv_scan
.L_tl_argv_tokstart:
    cmpq $255, %r15
    jge .L_tl_argv_done
    movq %rbx, (%r14,%r15,8)
    incq %r15
    xorl %r9d, %r9d
.L_tl_argv_tok:
    movb (%rbx), %al
    cmpb $0, %al
    je .L_tl_argv_done
    cmpb $0x22, %al
    jne .L_tl_argv_notq
    xorl $1, %r9d
    movq %rbx, %rcx
.L_tl_argv_shift:
    movb 1(%rcx), %al
    movb %al, (%rcx)
    incq %rcx
    cmpb $0, %al
    jne .L_tl_argv_shift
    jmp .L_tl_argv_tok
.L_tl_argv_notq:
    cmpb $0x20, %al
    jne .L_tl_argv_adv
    testl %r9d, %r9d
    jnz .L_tl_argv_adv
    movb $0, (%rbx)
    incq %rbx
    jmp .L_tl_argv_scan
.L_tl_argv_adv:
    incq %rbx
    jmp .L_tl_argv_tok
.L_tl_argv_done:
    movq $0, (%r14,%r15,8)
    movq %r15, .L_tl_argc(%rip)
    movq %r14, .L_tl_argv(%rip)
    addq $40, %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret

.L_tl_boot_alloc:
    movq tl_boot_off(%rip), %rax
    leaq tl_boot_pool(%rip), %rdx
    addq %rdx, %rax
    addq %rcx, tl_boot_off(%rip)
    ret

    .globl _tl_start
_tl_start:
    subq $40, %rsp
    call tl_setup_argv
    movq $0, %gs:0x28
    movq .L_tl_argc(%rip), %rcx
    movq .L_tl_argv(%rip), %rdx
    call main
    movq %rax, %rcx
    call ExitProcess

    .bss
    .balign 8
tl_boot_off:
    .quad 0
tl_boot_pool:
    .space 524288
    .text

    .section .rsrc,\"dr\"
.L_tl_rsrc_base:
    .long 0
    .long 0
    .short 0
    .short 0
    .short 0
    .short 1
    .long 24
    .long 0x80000000 + (.L_tl_rsrc_type - .L_tl_rsrc_base)
.L_tl_rsrc_type:
    .long 0
    .long 0
    .short 0
    .short 0
    .short 0
    .short 1
    .long 1
    .long 0x80000000 + (.L_tl_rsrc_lang - .L_tl_rsrc_base)
.L_tl_rsrc_lang:
    .long 0
    .long 0
    .short 0
    .short 0
    .short 0
    .short 1
    .long 1033
    .long .L_tl_rsrc_data - .L_tl_rsrc_base
.L_tl_rsrc_data:
    .rva .L_tl_manifest
    .long .L_tl_manifest_end - .L_tl_manifest
    .long 0
    .long 0
    .balign 4
.L_tl_manifest:
    .byte 60,63,120,109,108,32,118,101,114,115,105,111,110,61,34,49
    .byte 46,48,34,32,101,110,99,111,100,105,110,103,61,34,85,84
    .byte 70,45,56,34,32,115,116,97,110,100,97,108,111,110,101,61
    .byte 34,121,101,115,34,63,62,13,10,60,97,115,115,101,109,98
    .byte 108,121,32,120,109,108,110,115,61,34,117,114,110,58,115,99
    .byte 104,101,109,97,115,45,109,105,99,114,111,115,111,102,116,45
    .byte 99,111,109,58,97,115,109,46,118,49,34,32,109,97,110,105
    .byte 102,101,115,116,86,101,114,115,105,111,110,61,34,49,46,48
    .byte 34,62,13,10,32,32,60,97,112,112,108,105,99,97,116,105
    .byte 111,110,32,120,109,108,110,115,61,34,117,114,110,58,115,99
    .byte 104,101,109,97,115,45,109,105,99,114,111,115,111,102,116,45
    .byte 99,111,109,58,97,115,109,46,118,51,34,62,13,10,32,32
    .byte 32,32,60,119,105,110,100,111,119,115,83,101,116,116,105,110
    .byte 103,115,62,13,10,32,32,32,32,32,32,60,97,99,116,105
    .byte 118,101,67,111,100,101,80,97,103,101,32,120,109,108,110,115
    .byte 61,34,104,116,116,112,58,47,47,115,99,104,101,109,97,115
    .byte 46,109,105,99,114,111,115,111,102,116,46,99,111,109,47,83
    .byte 77,73,47,50,48,49,57,47,87,105,110,100,111,119,115,83
    .byte 101,116,116,105,110,103,115,34,62,85,84,70,45,56,60,47
    .byte 97,99,116,105,118,101,67,111,100,101,80,97,103,101,62,13
    .byte 10,32,32,32,32,60,47,119,105,110,100,111,119,115,83,101
    .byte 116,116,105,110,103,115,62,13,10,32,32,60,47,97,112,112
    .byte 108,105,99,97,116,105,111,110,62,13,10,60,47,97,115,115
    .byte 101,109,98,108,121,62,13,10
.L_tl_manifest_end:
    .text

")

;; First-class arena runtime (#1633). `tl_arena_make` maps a fresh INDEPENDENT
;; 64 MiB arena chain (prev-link 0) and returns its header WITHOUT changing the
;; active arena. `tl_arena_current`/`tl_arena_set` read/write the active arena.
;; `tl_arena_destroy` releases an arena's whole active chain plus any retired
;; overflow chunks held by the chain root. Arena header is the same 64-byte
;; record as tl_alloc {0:prev, 8:base, 16:bump, 24:end, 32:retired, 40:root,
;; 48:kind/lock, 56:atomic-current}.
;; System V (mmap=9 / munmap=11) flavor.
;; These mmap/munmap calls are part of the checked backend-core page boundary
;; (#2314), not stdlib-owned OS helpers.
;;
;; These are `.globl` symbols. The runtime (arena primitives, tl_alloc, the
;; region runtime, and the `tl_current_arena` slot) is emitted in exactly ONE
;; object per executable Ã¢â‚¬â€ the entry/executable object (`emit-entry=true`).
;; Library/dependency objects (`emit-entry=false`) emit none of the runtime and
;; reference these symbols as externs, so a multi-object link (a package plus its
;; dependency .a archive) resolves every object's calls to the single definition
;; in the entry object Ã¢â‚¬â€ no `multiple definition` collision.
(define (compiler-backend-runtime-linux-arena-functions [profile : bool]) : String
  (string-append
    "    .globl tl_thread_init
tl_thread_init:
    movq $4096, %rsi
    xorq %rdi, %rdi
    movq $3, %rdx
    movq $0x22, %r10
    movq $-1, %r8
    xorq %r9, %r9
    movq $9, %rax
    syscall
    testq %rax, %rax
    js .L_tl_thread_init_abort
    movq $tl_current_arena@tpoff, %rdi
    subq %rdi, %rax
    movq %rax, %rsi
    movq $0x1002, %rdi
    movq $158, %rax
    syscall
    testq %rax, %rax
    js .L_tl_thread_init_abort
    ret
.L_tl_thread_init_abort:
    movq $60, %rax
    movq $134, %rdi
    syscall

    .globl tl_arena_current
tl_arena_current:
"
    (string-append
      (compiler-backend-current-arena-load (BackendTargetLinux) "%rax")
      (string-append
        "    ret

    .globl tl_arena_set
tl_arena_set:
"
        (string-append
          (compiler-backend-current-arena-store (BackendTargetLinux) "%rdi")
          (string-append
            "    ret

    .globl tl_arena_poison_enable
tl_arena_poison_enable:
    movq $1, .L_tl_arena_poison_enabled(%rip)
    ret

    .globl tl_arena_make
tl_arena_make:
    movq $0x4000000, %rsi
    xorq %rdi, %rdi
    movq $3, %rdx
    movq $0x22, %r10
    movq $-1, %r8
    xorq %r9, %r9
    movq $9, %rax
    syscall
    testq %rax, %rax
    js .L_tl_arena_make_abort
    movq $0, 0(%rax)
    movq $0, 32(%rax)
    movq %rax, 40(%rax)
    movq $0, 48(%rax)
    movq %rax, 56(%rax)
    leaq 64(%rax), %rcx
    movq %rcx, 8(%rax)
    movq %rcx, 16(%rax)
    movq %rax, %rcx
    addq $0x4000000, %rcx
    movq %rcx, 24(%rax)
    ret
.L_tl_arena_make_abort:
    movq $60, %rax
    movq $134, %rdi
    syscall

    .globl tl_arena_make_atomic
tl_arena_make_atomic:
    movq $0x4000000, %rsi
    xorq %rdi, %rdi
    movq $3, %rdx
    movq $0x22, %r10
    movq $-1, %r8
    xorq %r9, %r9
    movq $9, %rax
    syscall
    testq %rax, %rax
    js .L_tl_arena_make_atomic_abort
    movq $0, 0(%rax)
    movq $0, 32(%rax)
    movq %rax, 40(%rax)
    movq $1, 48(%rax)
    movq %rax, 56(%rax)
    leaq 64(%rax), %rcx
    movq %rcx, 8(%rax)
    movq %rcx, 16(%rax)
    movq %rax, %rcx
    addq $0x4000000, %rcx
    movq %rcx, 24(%rax)
    ret
.L_tl_arena_make_atomic_abort:
    movq $60, %rax
    movq $134, %rdi
    syscall

    .globl tl_arena_destroy
tl_arena_destroy:
    push %rbx
    push %r12
    movq %rdi, %rbx
    xorq %r12, %r12
    testq %rbx, %rbx
    jz .L_tl_arena_destroy_active_done
    movq 40(%rbx), %r12
    testq %r12, %r12
    jz .L_tl_arena_destroy_loop
    testq $1, 48(%r12)
    jz .L_tl_arena_destroy_retired_ready
    movq 56(%r12), %rbx
.L_tl_arena_destroy_retired_ready:
    movq 32(%r12), %r12
.L_tl_arena_destroy_loop:
    testq %rbx, %rbx
    jz .L_tl_arena_destroy_active_done
    movq 0(%rbx), %r8
"
            (string-append
              (compiler-backend-runtime-profile-live-sub "%rbx" "%r10" profile)
              "    push %r8
    cmpq $0, .L_tl_arena_poison_enabled(%rip)
    je .L_tl_arena_destroy_unmap
    movq 8(%rbx), %rdi
    movq 24(%rbx), %rcx
    subq %rdi, %rcx
    jbe .L_tl_arena_destroy_unmap
    movb $0xA5, %al
    rep stosb
.L_tl_arena_destroy_unmap:
    movq 24(%rbx), %rsi
    subq %rbx, %rsi
    movq %rbx, %rdi
    movq $11, %rax
    syscall
    pop %r8
    movq %r8, %rbx
    jmp .L_tl_arena_destroy_loop
.L_tl_arena_destroy_active_done:
    movq %r12, %rbx
.L_tl_arena_destroy_retired_loop:
    testq %rbx, %rbx
    jz .L_tl_arena_destroy_done
    movq 32(%rbx), %r8
    push %r8
    cmpq $0, .L_tl_arena_poison_enabled(%rip)
    je .L_tl_arena_destroy_retired_unmap
    movq 8(%rbx), %rdi
    movq 24(%rbx), %rcx
    subq %rdi, %rcx
    jbe .L_tl_arena_destroy_retired_unmap
    movb $0xA5, %al
    rep stosb
.L_tl_arena_destroy_retired_unmap:
    movq 24(%rbx), %rsi
    subq %rbx, %rsi
    movq %rbx, %rdi
    movq $11, %rax
    syscall
    pop %r8
    movq %r8, %rbx
    jmp .L_tl_arena_destroy_retired_loop
.L_tl_arena_destroy_done:
    pop %r12
    pop %rbx
    ret

")))))))

;; Windows flavor: VirtualAlloc/VirtualFree under the Win64 ABI. These calls are
;; part of the checked backend-core page boundary (#2314). The arg arrives in
;; %rcx; a 32-byte shadow space is reserved before each call. A mapping failure
;; traps via `ud2` (no libc dependency).
(define (compiler-backend-runtime-windows-arena-functions [profile : bool]) : String
  (string-append
    "    .globl tl_arena_current
tl_arena_current:
"
    (string-append
      (compiler-backend-current-arena-load (BackendTargetWindows) "%rax")
      (string-append
        "    ret

    .globl tl_arena_set
tl_arena_set:
"
        (string-append
          (compiler-backend-current-arena-store (BackendTargetWindows) "%rcx")
          (string-append
            "    ret

    .globl tl_arena_poison_enable
tl_arena_poison_enable:
    ret

    .globl tl_arena_make
tl_arena_make:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %rsi
    sub $32, %rsp
    xorq %rcx, %rcx
    movq $0x4000000, %rdx
    movq $0x3000, %r8
    movq $0x4, %r9
    call VirtualAlloc
    testq %rax, %rax
    jz .L_tl_arena_make_win_abort
    movq $0, 0(%rax)
    movq $0, 32(%rax)
    movq %rax, 40(%rax)
    movq $0, 48(%rax)
    movq %rax, 56(%rax)
    leaq 64(%rax), %rcx
    movq %rcx, 8(%rax)
    movq %rcx, 16(%rax)
    movq %rax, %rcx
    addq $0x4000000, %rcx
    movq %rcx, 24(%rax)
    add $32, %rsp
    popq %rsi
    popq %rbx
    popq %rbp
    ret
.L_tl_arena_make_win_abort:
    ud2

    .globl tl_arena_make_atomic
tl_arena_make_atomic:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %rsi
    sub $32, %rsp
    xorq %rcx, %rcx
    movq $0x4000000, %rdx
    movq $0x3000, %r8
    movq $0x4, %r9
    call VirtualAlloc
    testq %rax, %rax
    jz .L_tl_arena_make_atomic_win_abort
    movq $0, 0(%rax)
    movq $0, 32(%rax)
    movq %rax, 40(%rax)
    movq $1, 48(%rax)
    movq %rax, 56(%rax)
    leaq 64(%rax), %rcx
    movq %rcx, 8(%rax)
    movq %rcx, 16(%rax)
    movq %rax, %rcx
    addq $0x4000000, %rcx
    movq %rcx, 24(%rax)
    add $32, %rsp
    popq %rsi
    popq %rbx
    popq %rbp
    ret
.L_tl_arena_make_atomic_win_abort:
    ud2

    .globl tl_arena_destroy
tl_arena_destroy:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %rsi
    push %r12
    sub $40, %rsp
    movq %rcx, %rsi
    xorq %r12, %r12
    testq %rsi, %rsi
    jz .L_tl_arena_destroy_win_active_done
    movq 40(%rsi), %r12
    testq %r12, %r12
    jz .L_tl_arena_destroy_win_loop
    testq $1, 48(%r12)
    jz .L_tl_arena_destroy_win_retired_ready
    movq 56(%r12), %rsi
.L_tl_arena_destroy_win_retired_ready:
    movq 32(%r12), %r12
.L_tl_arena_destroy_win_loop:
    testq %rsi, %rsi
    jz .L_tl_arena_destroy_win_active_done
    movq 0(%rsi), %rbx
"
            (string-append
              (compiler-backend-runtime-profile-live-sub "%rsi" "%r10" profile)
              "    movq %rsi, %rcx
    xorq %rdx, %rdx
    movq $0x8000, %r8
    call VirtualFree
    movq %rbx, %rsi
    jmp .L_tl_arena_destroy_win_loop
.L_tl_arena_destroy_win_active_done:
    movq %r12, %rsi
.L_tl_arena_destroy_win_retired_loop:
    testq %rsi, %rsi
    jz .L_tl_arena_destroy_win_done
    movq 32(%rsi), %rbx
    movq %rsi, %rcx
    xorq %rdx, %rdx
    movq $0x8000, %r8
    call VirtualFree
    movq %rbx, %rsi
    jmp .L_tl_arena_destroy_win_retired_loop
.L_tl_arena_destroy_win_done:
    add $40, %rsp
    popq %r12
    popq %rsi
    popq %rbx
    popq %rbp
    ret

")))))))

(define (compiler-backend-runtime-region-reset-functions [profile : bool]) : String
  (string-append
    "    .globl tl_region_reset
tl_region_reset:
    push %rbx
    push %r12
    movq %rdi, %rbx
    testq %rbx, %rbx
    jz .L_tl_region_reset_all
    movq %fs:tl_current_arena@tpoff, %r8
    testq %r8, %r8
    jz .L_tl_region_reset_invalid
    movq 40(%r8), %r12
    testq $1, 48(%r12)
    jz .L_tl_region_reset_find
    movq 56(%r12), %r8
.L_tl_region_reset_find:
    movq 8(%r8), %r9
    cmpq %r9, %rbx
    jb .L_tl_region_reset_next
    movq 24(%r8), %r9
    cmpq %r9, %rbx
    jbe .L_tl_region_reset_found
.L_tl_region_reset_next:
    movq 0(%r8), %r8
    testq %r8, %r8
    jnz .L_tl_region_reset_find
    jmp .L_tl_region_reset_invalid
.L_tl_region_reset_found:
    movq 40(%r8), %r12
    movq %fs:tl_current_arena@tpoff, %r9
.L_tl_region_reset_drop_newer:
    cmpq %r8, %r9
    je .L_tl_region_reset_restore
    movq 0(%r9), %r10
"
    (string-append
      (compiler-backend-runtime-profile-live-sub "%r9" "%r11" profile)
      (string-append
        "    cmpq $0, .L_tl_arena_poison_enabled(%rip)
    je .L_tl_region_reset_drop_newer_retire
    movq 8(%r9), %rdi
    movq 24(%r9), %rcx
    subq %rdi, %rcx
    jbe .L_tl_region_reset_drop_newer_retire
    movb $0xA5, %al
    rep stosb
.L_tl_region_reset_drop_newer_retire:
    movq 32(%r12), %r11
    movq %r11, 32(%r9)
    movq $0, 0(%r9)
    movq %r9, 32(%r12)
    movq %r10, %r9
    jmp .L_tl_region_reset_drop_newer
.L_tl_region_reset_restore:
"
        (string-append
          (compiler-backend-runtime-profile-live-rewind
            "%r8"
            "%rbx"
            "%r10"
            profile)
          (string-append
            "    cmpq $0, .L_tl_arena_poison_enabled(%rip)
    je .L_tl_region_reset_restore_set
    movq 16(%r8), %rcx
    subq %rbx, %rcx
    jbe .L_tl_region_reset_restore_set
    movq %rbx, %rdi
    movb $0xA5, %al
    rep stosb
.L_tl_region_reset_restore_set:
    movq %rbx, 16(%r8)
    testq $1, 48(%r12)
    jz .L_tl_region_reset_restore_current_ready
    movq %r8, 56(%r12)
.L_tl_region_reset_restore_current_ready:
    movq %r8, %fs:tl_current_arena@tpoff
    pop %r12
    pop %rbx
    ret
.L_tl_region_reset_all:
    movq %fs:tl_current_arena@tpoff, %r8
    movq $0, %fs:tl_current_arena@tpoff
    xorq %rbx, %rbx
    testq %r8, %r8
    jz .L_tl_region_reset_done
    movq 40(%r8), %r10
    testq %r10, %r10
    jz .L_tl_region_reset_all_loop
    testq $1, 48(%r10)
    jz .L_tl_region_reset_all_retired_ready
    movq 56(%r10), %r8
.L_tl_region_reset_all_retired_ready:
    movq 32(%r10), %rbx
.L_tl_region_reset_all_loop:
    testq %r8, %r8
    jz .L_tl_region_reset_all_retired
    movq 0(%r8), %r9
"
            (string-append
              (compiler-backend-runtime-profile-live-sub "%r8" "%r10" profile)
              "    cmpq $0, .L_tl_arena_poison_enabled(%rip)
    je .L_tl_region_reset_all_unmap
    movq 8(%r8), %rdi
    movq 24(%r8), %rcx
    subq %rdi, %rcx
    jbe .L_tl_region_reset_all_unmap
    movb $0xA5, %al
    rep stosb
.L_tl_region_reset_all_unmap:
    movq 24(%r8), %rsi
    subq %r8, %rsi
    movq %r8, %rdi
    push %r9
    movq $11, %rax
    syscall
    pop %r8
    jmp .L_tl_region_reset_all_loop
.L_tl_region_reset_all_retired:
    movq %rbx, %r8
.L_tl_region_reset_all_retired_loop:
    testq %r8, %r8
    jz .L_tl_region_reset_done
    movq 32(%r8), %r9
    cmpq $0, .L_tl_arena_poison_enabled(%rip)
    je .L_tl_region_reset_all_retired_unmap
    movq 8(%r8), %rdi
    movq 24(%r8), %rcx
    subq %rdi, %rcx
    jbe .L_tl_region_reset_all_retired_unmap
    movb $0xA5, %al
    rep stosb
.L_tl_region_reset_all_retired_unmap:
    movq 24(%r8), %rsi
    subq %r8, %rsi
    movq %r8, %rdi
    push %r9
    movq $11, %rax
    syscall
    pop %r8
    jmp .L_tl_region_reset_all_retired_loop
.L_tl_region_reset_done:
    pop %r12
    pop %rbx
    ret
.L_tl_region_reset_invalid:
    jmp tl_region_abort

")))))))

(define (compiler-backend-runtime-windows-alloc-functions [profile : bool]) : String
  (let
    [fast-profile : String
      (compiler-backend-runtime-profile-alloc-account
        "%r11"
        ".L_tl_alloc_profile_win_fast_done"
        profile)]
    [atomic-fast-profile : String
      (compiler-backend-runtime-profile-alloc-account
        "%r11"
        ".L_tl_alloc_profile_win_atomic_fast_done"
        profile)]
    [atomic-locked-profile : String
      (compiler-backend-runtime-profile-alloc-account
        "%r11"
        ".L_tl_alloc_profile_win_atomic_locked_done"
        profile)]
    [atomic-new-profile : String
      (compiler-backend-runtime-profile-alloc-account
        "%r11"
        ".L_tl_alloc_profile_win_atomic_new_done"
        profile)]
    [new-profile : String
      (compiler-backend-runtime-profile-alloc-account
        "%r11"
        ".L_tl_alloc_profile_win_new_done"
        profile)]
    (str-cat
      (compiler-backend-runtime-fast-alloc-functions
        (BackendTargetWindows)
        "%rcx"
        "%r10"
        profile)
      "    .globl tl_alloc
tl_alloc:
    testq %rcx, %rcx
    jnz .L_tl_alloc_win_size_ready
    movq $1, %rcx
.L_tl_alloc_win_size_ready:
    addq $7, %rcx
    jc .L_tl_alloc_enter_abort
    andq $-8, %rcx
    movq %rcx, %r11
    movq %gs:0x28, %r8
    testq %r8, %r8
    jz .L_tl_alloc_new_arena_entry
    movq 40(%r8), %r9
    testq $1, 48(%r9)
    jnz .L_tl_alloc_win_atomic
    movq 16(%r8), %rax
    movq %rax, %r10
    addq %r11, %r10
    jc .L_tl_alloc_enter_abort
    cmpq 24(%r8), %r10
    ja .L_tl_alloc_new_arena_entry
    movq %r10, 16(%r8)
"
      fast-profile
      "    ret
.L_tl_alloc_win_atomic:
    movq 56(%r9), %r8
    movq 16(%r8), %rax
.L_tl_alloc_win_atomic_cas:
    movq %rax, %r10
    addq %r11, %r10
    jc .L_tl_alloc_enter_abort
    cmpq 24(%r8), %r10
    ja .L_tl_alloc_atomic_new_arena_entry
    lock cmpxchgq %r10, 16(%r8)
    jne .L_tl_alloc_win_atomic_cas
"
      atomic-fast-profile
      "    ret
.L_tl_alloc_atomic_new_arena_entry:
    push %rbp
    mov %rsp, %rbp
    sub $48, %rsp
    jmp .L_tl_alloc_atomic_new_arena
.L_tl_alloc_new_arena_entry:
    push %rbp
    mov %rsp, %rbp
    sub $48, %rsp
    jmp .L_tl_alloc_new_arena
.L_tl_alloc_enter_abort:
    push %rbp
    mov %rsp, %rbp
    sub $48, %rsp
    jmp .L_tl_alloc_abort
.L_tl_alloc_atomic_new_arena:
    movq %r9, -24(%rbp)
.L_tl_alloc_atomic_lock:
    movq -24(%rbp), %r9
    movq $1, %rax
    movq $3, %r10
    lock cmpxchgq %r10, 48(%r9)
    je .L_tl_alloc_atomic_locked
    pause
    jmp .L_tl_alloc_atomic_lock
.L_tl_alloc_atomic_locked:
    movq 56(%r9), %r8
    movq 16(%r8), %rax
.L_tl_alloc_atomic_locked_cas:
    movq %rax, %r10
    addq %r11, %r10
    jc .L_tl_alloc_atomic_abort_locked
    cmpq 24(%r8), %r10
    ja .L_tl_alloc_atomic_map
    lock cmpxchgq %r10, 16(%r8)
    jne .L_tl_alloc_atomic_locked_cas
    movq $1, 48(%r9)
"
      atomic-locked-profile
      "    mov %rbp, %rsp
    pop %rbp
    ret
.L_tl_alloc_atomic_abort_locked:
    movq $1, 48(%r9)
    jmp .L_tl_alloc_abort
.L_tl_alloc_atomic_map:
    movq %r11, -8(%rbp)
    movq $0x4000000, %rdx
    movq %r11, %rax
    addq $64, %rax
    jc .L_tl_alloc_abort
    cmpq %rdx, %rax
    jbe .L_tl_alloc_atomic_len_ready
    movq %rax, %rdx
.L_tl_alloc_atomic_len_ready:
    movq %rdx, -16(%rbp)
    xorq %rcx, %rcx
    movq $0x3000, %r8
    movq $4, %r9
    call VirtualAlloc
    testq %rax, %rax
    jz .L_tl_alloc_abort
    movq -24(%rbp), %r9
    movq -16(%rbp), %rdx
    movq -8(%rbp), %r11
    movq %rax, %rcx
    addq %rdx, %rcx
    jc .L_tl_alloc_abort
    movq 56(%r9), %r8
    movq %r8, 0(%rax)
    movq $0, 32(%rax)
    movq %r9, 40(%rax)
    movq $1, 48(%rax)
    movq $0, 56(%rax)
    leaq 64(%rax), %r8
    movq %r8, 8(%rax)
    movq %rcx, 24(%rax)
    movq %r8, %r10
    addq %r11, %r10
    jc .L_tl_alloc_abort
    movq %r10, 16(%rax)
    movq %rax, 56(%r9)
    movq %rax, %gs:0x28
    movq $1, 48(%r9)
    movq %r8, %rax
"
      atomic-new-profile
      "    mov %rbp, %rsp
    pop %rbp
    ret
.L_tl_alloc_new_arena:
    movq %r11, -8(%rbp)
    movq $0x4000000, %rdx
    movq %r11, %rax
    addq $64, %rax
    jc .L_tl_alloc_abort
    cmpq %rdx, %rax
    jbe .L_tl_alloc_len_ready
    movq %rax, %rdx
.L_tl_alloc_len_ready:
    movq %rdx, -16(%rbp)
    xorq %rcx, %rcx
    movq $0x3000, %r8
    movq $4, %r9
    call VirtualAlloc
    testq %rax, %rax
    jz .L_tl_alloc_abort
    movq -16(%rbp), %rdx
    movq -8(%rbp), %r11
    movq %rax, %rcx
    addq %rdx, %rcx
    jc .L_tl_alloc_abort
    movq %gs:0x28, %r8
    movq %r8, 0(%rax)
    movq $0, 32(%rax)
    testq %r8, %r8
    jz .L_tl_alloc_win_root_self
    movq 40(%r8), %r10
    jmp .L_tl_alloc_win_root_ready
.L_tl_alloc_win_root_self:
    movq %rax, %r10
.L_tl_alloc_win_root_ready:
    movq %r10, 40(%rax)
    movq $0, 48(%rax)
    movq %rax, 56(%rax)
    leaq 64(%rax), %r8
    movq %r8, 8(%rax)
    movq %rcx, 24(%rax)
    movq %r8, %r10
    addq %r11, %r10
    jc .L_tl_alloc_abort
    movq %r10, 16(%rax)
    movq %rax, %gs:0x28
    movq %r8, %rax
"
      new-profile
      "
    mov %rbp, %rsp
    pop %rbp
    ret
.L_tl_alloc_abort:
    sub $32, %rsp
    call tl_oom_abort

")))

;; The Linux out-of-bounds/division/shift abort handlers moved to the runtime
;; prelude (stdlib/runtime.tl as `tl-runtime-*-abort`, exported as the fixed
;; `tl_*_abort` symbols via #2143); the backend no longer emits them as asm.
;; `tl_abort_string` (the general panic handler) moved to the runtime prelude
;; (stdlib/runtime.tl as `tl-runtime-abort-string`, exported via #2143); the
;; backend no longer emits it as asm on either target.
(define (compiler-backend-runtime-abort-functions) : String
  "")

;; Environment lookups moved entirely into TypeLisp (stdlib/env.tl): the Linux
;; side walks the SysV stack-captured environment via the program-argv/argc
;; builtins, and the Windows side calls kernel32 GetEnvironmentStringsA directly,
;; with the name match and value copy done in TypeLisp. The backend therefore
;; emits no `tl_env_var_exists` / `tl_env_var_value` / `_tl_env_path_separator`
;; asm on either target (these were the last consumers of the removed `getenv`
;; and `strlen` libc shims). The generators are retained as empty strings so the
;; runtime-plan gating (which still tracks the now-never-set env call sites) does
;; not need a struct change.
(define (compiler-backend-runtime-env-var-exists-functions) : String
  "")

(define (compiler-backend-runtime-env-var-value-functions) : String
  "")

(define (compiler-backend-runtime-env-path-separator-functions) : String
  "")

(define (compiler-backend-runtime-windows-env-path-separator-functions) : String
  "")

(define (compiler-backend-runtime-windows-env-var-exists-functions) : String
  "")

(define (compiler-backend-runtime-windows-env-var-value-functions) : String
  "")

;; Windows variant of `tl_region_reset`. Identical arena-walk structure to the
;; Linux helper (offsets: 0=prev arena, 8=usable base, 16=bump pointer, 24=end,
;; 32=retired list link/head, 40=root, 48=kind/lock, 56=atomic-current; the arena header sits at the VirtualAlloc
;; base). Nonzero reset retires newer chunks; reset-all releases chunks with
;; `VirtualFree(lpAddress=arena, dwSize=0, dwFreeType=MEM_RELEASE=0x8000)` Ã¢â‚¬â€ the
;; arena node address is exactly the VirtualAlloc base, so MEM_RELEASE frees the
;; whole chunk. Arg (the mark) arrives in %rcx.
(define (compiler-backend-runtime-windows-region-reset-functions
  [profile : bool]) : String
  (string-append
    "    .globl tl_region_reset
tl_region_reset:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    movq %rcx, %r12
    testq %r12, %r12
    jz .L_tl_region_reset_win_all
    movq %gs:0x28, %r13
    testq %r13, %r13
    jz .L_tl_region_reset_win_invalid
    movq 40(%r13), %r11
    testq $1, 48(%r11)
    jz .L_tl_region_reset_win_find
    movq 56(%r11), %r13
.L_tl_region_reset_win_find:
    movq 8(%r13), %rax
    cmpq %rax, %r12
    jb .L_tl_region_reset_win_next
    movq 24(%r13), %rax
    cmpq %rax, %r12
    jbe .L_tl_region_reset_win_found
.L_tl_region_reset_win_next:
    movq 0(%r13), %r13
    testq %r13, %r13
    jnz .L_tl_region_reset_win_find
    jmp .L_tl_region_reset_win_invalid
.L_tl_region_reset_win_invalid:
    sub $32, %rsp
    call tl_region_abort
.L_tl_region_reset_win_found:
    movq 40(%r13), %r11
    movq %gs:0x28, %r14
.L_tl_region_reset_win_drop:
    cmpq %r13, %r14
    je .L_tl_region_reset_win_restore
    movq 0(%r14), %rbx
"
    (string-append
      (compiler-backend-runtime-profile-live-sub "%r14" "%rax" profile)
      (string-append
        "    movq 32(%r11), %rax
    movq %rax, 32(%r14)
    movq $0, 0(%r14)
    movq %r14, 32(%r11)
    movq %rbx, %r14
    jmp .L_tl_region_reset_win_drop
.L_tl_region_reset_win_restore:
"
        (string-append
          (compiler-backend-runtime-profile-live-rewind
            "%r13"
            "%r12"
            "%rax"
            profile)
          (string-append
            "    movq %r12, 16(%r13)
    testq $1, 48(%r11)
    jz .L_tl_region_reset_win_restore_current_ready
    movq %r13, 56(%r11)
.L_tl_region_reset_win_restore_current_ready:
    movq %r13, %gs:0x28
    jmp .L_tl_region_reset_win_done
.L_tl_region_reset_win_all:
    movq %gs:0x28, %r14
    movq $0, %gs:0x28
    xorq %r12, %r12
    testq %r14, %r14
    jz .L_tl_region_reset_win_done
    movq 40(%r14), %r12
    testq %r12, %r12
    jz .L_tl_region_reset_win_all_drop
    testq $1, 48(%r12)
    jz .L_tl_region_reset_win_all_retired_ready
    movq 56(%r12), %r14
.L_tl_region_reset_win_all_retired_ready:
    movq 32(%r12), %r12
.L_tl_region_reset_win_all_drop:
    testq %r14, %r14
    jz .L_tl_region_reset_win_all_retired
    movq 0(%r14), %rbx
"
            (string-append
              (compiler-backend-runtime-profile-live-sub "%r14" "%rax" profile)
              "    movq %r14, %rcx
    xorq %rdx, %rdx
    movq $0x8000, %r8
    sub $32, %rsp
    call VirtualFree
    add $32, %rsp
    movq %rbx, %r14
    jmp .L_tl_region_reset_win_all_drop
.L_tl_region_reset_win_all_retired:
    movq %r12, %r14
.L_tl_region_reset_win_all_retired_drop:
    testq %r14, %r14
    jz .L_tl_region_reset_win_done
    movq 32(%r14), %rbx
    movq %r14, %rcx
    xorq %rdx, %rdx
    movq $0x8000, %r8
    sub $32, %rsp
    call VirtualFree
    add $32, %rsp
    movq %rbx, %r14
    jmp .L_tl_region_reset_win_all_retired_drop
.L_tl_region_reset_win_done:
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")))))))

(define (compiler-backend-runtime-windows-thread-functions) : String
  "    .data
    .globl tl_thread_entry_ptr
    .balign 8
tl_thread_entry_ptr:
    .quad .L_tl_thread_entry

    .text
.L_tl_thread_entry:
    pushq %r12
    pushq %r13
    subq $40, %rsp
    movq $0, %gs:0x28
    movq (%rcx), %r11
    movq 8(%rcx), %rdx
    movq 16(%rcx), %r12
    movq 24(%rcx), %r13
    movl $1, (%r13)
    movq 8(%r11), %rcx
    call *(%r11)
    movq %rax, (%r12)
    addq $40, %rsp
    popq %r13
    popq %r12
    ret

")

(define (compiler-backend-runtime-profile-functions) : String
  "    .globl tl_profile_alloc_total
tl_profile_alloc_total:
    movq tl_profile_alloc_total_bytes(%rip), %rax
    ret

    .globl tl_profile_alloc_live
tl_profile_alloc_live:
    movq tl_profile_alloc_live_bytes(%rip), %rax
    ret

    .globl tl_profile_alloc_peak
tl_profile_alloc_peak:
    movq tl_profile_alloc_peak_bytes(%rip), %rax
    ret

    .globl tl_profile_alloc_reset_peak
tl_profile_alloc_reset_peak:
    movq tl_profile_alloc_live_bytes(%rip), %rax
    movq %rax, tl_profile_alloc_peak_bytes(%rip)
    xorq %rax, %rax
    ret

")

(define (compiler-backend-runtime-profile-functions-for-target
  [target : CompilerBackendTarget]
  [profile : bool]) : String
  (let
    [_target : CompilerBackendTarget target]
    (if profile
      (compiler-backend-runtime-profile-functions)
      "")))

(define (compiler-backend-runtime-fs-functions) : String
  "")

(define (compiler-backend-runtime-windows-fs-functions) : String
  "")

(define (compiler-backend-runtime-fs-functions-for-target
  [target : CompilerBackendTarget]) : String
  (if (compiler-backend-target-windows? target)
    (compiler-backend-runtime-windows-fs-functions)
    (compiler-backend-runtime-fs-functions)))

;; The Windows out-of-bounds/division/shift abort handlers (and their shared
;; fixed-abort emitter) moved to the runtime prelude (stdlib/runtime.tl),
;; exported as the fixed `tl_*_abort` symbols via #2143; the backend emits no
;; asm for them.
;; `tl_abort_string` moved to the runtime prelude (see
;; `compiler-backend-runtime-abort-functions`); the Windows target emits no asm
;; for it either.
(define (compiler-backend-runtime-windows-abort-functions) : String
  "")

(define (compiler-backend-runtime-int-to-string-functions) : String
  "    .globl tl_int_to_string
tl_int_to_string:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $72, %rsp
    movq %rdi, %rax
    leaq 72(%rsp), %r10
    movq $0, %rcx
    cmpq $0, %rax
    jne .L_tl_int_to_string_nonzero
    decq %r10
    movb $48, (%r10)
    incq %rcx
    jmp .L_tl_int_to_string_digits_done
.L_tl_int_to_string_nonzero:
    movq $0, %r8
    cmpq $0, %rax
    jge .L_tl_int_to_string_abs_ready
    negq %rax
    movq $1, %r8
.L_tl_int_to_string_abs_ready:
    movq $10, %r9
.L_tl_int_to_string_digit_loop:
    xorq %rdx, %rdx
    divq %r9
    addb $48, %dl
    decq %r10
    movb %dl, (%r10)
    incq %rcx
    testq %rax, %rax
    jne .L_tl_int_to_string_digit_loop
    testq %r8, %r8
    jz .L_tl_int_to_string_digits_done
    decq %r10
    movb $45, (%r10)
    incq %rcx
.L_tl_int_to_string_digits_done:
    movq %r10, %rbx
    movq %rcx, %r12
    movq %r12, %rdi
    call tl_alloc
    movq %rax, %r13
    movq $0, %rcx
.L_tl_int_to_string_copy_loop:
    cmpq %r12, %rcx
    jge .L_tl_int_to_string_copy_done
    movzbl (%rbx,%rcx), %edx
    movb %dl, (%r13,%rcx)
    incq %rcx
    jmp .L_tl_int_to_string_copy_loop
.L_tl_int_to_string_copy_done:
    call .L_tl_alloc16
    movq %r13, 0(%rax)
    movq %r12, 8(%rax)
    add $72, %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")

(define (compiler-backend-runtime-windows-int-to-string-functions) : String
  "    .globl tl_int_to_string
tl_int_to_string:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $72, %rsp
    movq %rcx, %rax
    leaq 72(%rsp), %r10
    movq $0, %rcx
    cmpq $0, %rax
    jne .L_tl_int_to_string_nonzero
    decq %r10
    movb $48, (%r10)
    incq %rcx
    jmp .L_tl_int_to_string_digits_done
.L_tl_int_to_string_nonzero:
    movq $0, %r8
    cmpq $0, %rax
    jge .L_tl_int_to_string_abs_ready
    negq %rax
    movq $1, %r8
.L_tl_int_to_string_abs_ready:
    movq $10, %r9
.L_tl_int_to_string_digit_loop:
    xorq %rdx, %rdx
    divq %r9
    addb $48, %dl
    decq %r10
    movb %dl, (%r10)
    incq %rcx
    testq %rax, %rax
    jne .L_tl_int_to_string_digit_loop
    testq %r8, %r8
    jz .L_tl_int_to_string_digits_done
    decq %r10
    movb $45, (%r10)
    incq %rcx
.L_tl_int_to_string_digits_done:
    movq %r10, %rbx
    movq %rcx, %r12
    movq %r12, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rax, %r13
    movq $0, %rcx
.L_tl_int_to_string_copy_loop:
    cmpq %r12, %rcx
    jge .L_tl_int_to_string_copy_done
    movzbl (%rbx,%rcx), %edx
    movb %dl, (%r13,%rcx)
    incq %rcx
    jmp .L_tl_int_to_string_copy_loop
.L_tl_int_to_string_copy_done:
    call .L_tl_alloc16
    movq %r13, 0(%rax)
    movq %r12, 8(%rax)
    add $72, %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")

(define (compiler-backend-runtime-substring-functions) : String
  "    .globl tl_substring
tl_substring:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $8, %rsp
    movq %rdi, %rbx
    addq %rsi, %rbx
    movq %rdx, %r12
    movq %r12, %rdi
    call tl_alloc
    movq %rax, %r13
    movq %r12, %rcx
    movq %rbx, %rsi
    movq %r13, %rdi
    rep movsb
    call .L_tl_alloc16
    movq %r13, 0(%rax)
    movq %r12, 8(%rax)
    add $8, %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")

(define (compiler-backend-runtime-windows-substring-functions) : String
  "    .globl tl_substring
tl_substring:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %rsi
    push %rdi
    sub $8, %rsp
    movq %rcx, %rbx
    addq %rdx, %rbx
    movq %r8, %r12
    movq %r12, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rax, %r13
    movq %r12, %rcx
    movq %rbx, %rsi
    movq %r13, %rdi
    rep movsb
    call .L_tl_alloc16
    movq %r13, 0(%rax)
    movq %r12, 8(%rax)
    add $8, %rsp
    pop %rdi
    pop %rsi
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")

(define (compiler-backend-runtime-str-view-functions) : String
  "    .section .bss
    .balign 8
.L_tl_str_view_arena:
    .zero 8

    .text
    .globl tl_str_view
tl_str_view:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    sub $8, %rsp
    movq 0(%rdi), %r12
    addq %rsi, %r12
    movq %rdx, %r13
    call tl_arena_current
    movq %rax, %r14
    movq .L_tl_str_view_arena(%rip), %r15
    testq %r15, %r15
    jnz .L_tl_str_view_arena_ready
    call tl_arena_make_atomic
    movq %rax, %r15
    movq %rax, .L_tl_str_view_arena(%rip)
.L_tl_str_view_arena_ready:
    movq %r15, %rdi
    call tl_arena_set
    movq $16, %rdi
    call tl_alloc
    movq %rax, %rbx
    movq %r14, %rdi
    call tl_arena_set
    movq %r12, 0(%rbx)
    movq %r13, 8(%rbx)
    movq %rbx, %rax
    add $8, %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")

(define (compiler-backend-runtime-windows-str-view-functions) : String
  "    .data
    .balign 8
.L_tl_str_view_arena:
    .quad 0

    .text
    .globl tl_str_view
tl_str_view:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    sub $40, %rsp
    movq 0(%rcx), %r12
    addq %rdx, %r12
    movq %r8, %r13
    call tl_arena_current
    movq %rax, %r14
    movq .L_tl_str_view_arena(%rip), %r15
    testq %r15, %r15
    jnz .L_tl_str_view_arena_ready
    call tl_arena_make_atomic
    movq %rax, %r15
    movq %rax, .L_tl_str_view_arena(%rip)
.L_tl_str_view_arena_ready:
    movq %r15, %rcx
    call tl_arena_set
    movq $16, %rcx
    call tl_alloc
    movq %rax, %rbx
    movq %r14, %rcx
    call tl_arena_set
    movq %r12, 0(%rbx)
    movq %r13, 8(%rbx)
    movq %rbx, %rax
    add $40, %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")

(define (compiler-backend-runtime-concat-functions) : String
  "    .globl tl_string_concat
tl_string_concat:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    sub $8, %rsp
    movq %rdi, %rbx
    movq %rsi, %r12
    movq %rdx, %r13
    movq %rcx, %r14
    movq %r12, %rdi
    addq %r14, %rdi
    call tl_alloc
    movq %rax, %r15
    movq %r12, %rcx
    movq %rbx, %rsi
    movq %r15, %rdi
    rep movsb
    movq %r14, %rcx
    movq %r13, %rsi
    movq %r15, %rdi
    addq %r12, %rdi
    rep movsb
    call .L_tl_alloc16
    movq %r15, 0(%rax)
    movq %r12, %rdx
    addq %r14, %rdx
    movq %rdx, 8(%rax)
    add $8, %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

    .globl tl_string_concat3
tl_string_concat3:
    push %rbp
    mov %rsp, %rbp
    sub $32, %rsp
    movq $0, 0(%rsp)
    movq $0, 8(%rsp)
    movq $0, 16(%rsp)
    movq $0, 24(%rsp)
    call tl_string_concat5
    leave
    ret

    .globl tl_string_concat4
tl_string_concat4:
    push %rbp
    mov %rsp, %rbp
    sub $32, %rsp
    movq 16(%rbp), %rax
    movq %rax, 0(%rsp)
    movq 24(%rbp), %rax
    movq %rax, 8(%rsp)
    movq $0, 16(%rsp)
    movq $0, 24(%rsp)
    call tl_string_concat5
    leave
    ret

    .globl tl_string_concat5
tl_string_concat5:
    push %rbp
    mov %rsp, %rbp
    sub $112, %rsp
    movq %rdi, -8(%rbp)
    movq %rsi, -16(%rbp)
    movq %rdx, -24(%rbp)
    movq %rcx, -32(%rbp)
    movq %r8, -40(%rbp)
    movq %r9, -48(%rbp)
    movq 16(%rbp), %rax
    movq %rax, -56(%rbp)
    movq 24(%rbp), %rax
    movq %rax, -64(%rbp)
    movq 32(%rbp), %rax
    movq %rax, -72(%rbp)
    movq 40(%rbp), %rax
    movq %rax, -80(%rbp)
    movq -16(%rbp), %rdi
    addq -32(%rbp), %rdi
    addq -48(%rbp), %rdi
    addq -64(%rbp), %rdi
    addq -80(%rbp), %rdi
    movq %rdi, -88(%rbp)
    call tl_alloc
    movq %rax, -96(%rbp)
    movq -96(%rbp), %rdi
    movq -8(%rbp), %rsi
    movq -16(%rbp), %rcx
    rep movsb
    movq -96(%rbp), %rdi
    addq -16(%rbp), %rdi
    movq -24(%rbp), %rsi
    movq -32(%rbp), %rcx
    rep movsb
    movq -96(%rbp), %rdi
    addq -16(%rbp), %rdi
    addq -32(%rbp), %rdi
    movq -40(%rbp), %rsi
    movq -48(%rbp), %rcx
    rep movsb
    movq -96(%rbp), %rdi
    addq -16(%rbp), %rdi
    addq -32(%rbp), %rdi
    addq -48(%rbp), %rdi
    movq -56(%rbp), %rsi
    movq -64(%rbp), %rcx
    rep movsb
    movq -96(%rbp), %rdi
    addq -16(%rbp), %rdi
    addq -32(%rbp), %rdi
    addq -48(%rbp), %rdi
    addq -64(%rbp), %rdi
    movq -72(%rbp), %rsi
    movq -80(%rbp), %rcx
    rep movsb
    call .L_tl_alloc16
    movq -96(%rbp), %rdx
    movq %rdx, 0(%rax)
    movq -88(%rbp), %rdx
    movq %rdx, 8(%rax)
    leave
    ret

")

(define (compiler-backend-runtime-windows-concat-functions) : String
  "    .globl tl_string_concat
tl_string_concat:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    push %rsi
    push %rdi
    sub $8, %rsp
    movq %rcx, %rbx
    movq %rdx, %r12
    movq %r8, %r13
    movq %r9, %r14
    movq %r12, %rcx
    addq %r14, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rax, %r15
    movq %r12, %rcx
    movq %rbx, %rsi
    movq %r15, %rdi
    rep movsb
    movq %r14, %rcx
    movq %r13, %rsi
    movq %r15, %rdi
    addq %r12, %rdi
    rep movsb
    call .L_tl_alloc16
    movq %r15, 0(%rax)
    movq %r12, %rdx
    addq %r14, %rdx
    movq %rdx, 8(%rax)
    add $8, %rsp
    pop %rdi
    pop %rsi
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

    .globl tl_string_concat3
tl_string_concat3:
    push %rbp
    mov %rsp, %rbp
    sub $80, %rsp
    movq 48(%rbp), %rax
    movq %rax, 32(%rsp)
    movq 56(%rbp), %rax
    movq %rax, 40(%rsp)
    movq $0, 48(%rsp)
    movq $0, 56(%rsp)
    movq $0, 64(%rsp)
    movq $0, 72(%rsp)
    call tl_string_concat5
    leave
    ret

    .globl tl_string_concat4
tl_string_concat4:
    push %rbp
    mov %rsp, %rbp
    sub $80, %rsp
    movq 48(%rbp), %rax
    movq %rax, 32(%rsp)
    movq 56(%rbp), %rax
    movq %rax, 40(%rsp)
    movq 64(%rbp), %rax
    movq %rax, 48(%rsp)
    movq 72(%rbp), %rax
    movq %rax, 56(%rsp)
    movq $0, 64(%rsp)
    movq $0, 72(%rsp)
    call tl_string_concat5
    leave
    ret

    .globl tl_string_concat5
tl_string_concat5:
    push %rbp
    mov %rsp, %rbp
    sub $128, %rsp
    movq %rsi, -8(%rbp)
    movq %rdi, -16(%rbp)
    movq %rcx, -24(%rbp)
    movq %rdx, -32(%rbp)
    movq %r8, -40(%rbp)
    movq %r9, -48(%rbp)
    movq 48(%rbp), %rax
    movq %rax, -56(%rbp)
    movq 56(%rbp), %rax
    movq %rax, -64(%rbp)
    movq 64(%rbp), %rax
    movq %rax, -72(%rbp)
    movq 72(%rbp), %rax
    movq %rax, -80(%rbp)
    movq 80(%rbp), %rax
    movq %rax, -88(%rbp)
    movq 88(%rbp), %rax
    movq %rax, -96(%rbp)
    movq -32(%rbp), %rcx
    addq -48(%rbp), %rcx
    addq -64(%rbp), %rcx
    addq -80(%rbp), %rcx
    addq -96(%rbp), %rcx
    movq %rcx, -104(%rbp)
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rax, -112(%rbp)
    movq -112(%rbp), %rdi
    movq -24(%rbp), %rsi
    movq -32(%rbp), %rcx
    rep movsb
    movq -112(%rbp), %rdi
    addq -32(%rbp), %rdi
    movq -40(%rbp), %rsi
    movq -48(%rbp), %rcx
    rep movsb
    movq -112(%rbp), %rdi
    addq -32(%rbp), %rdi
    addq -48(%rbp), %rdi
    movq -56(%rbp), %rsi
    movq -64(%rbp), %rcx
    rep movsb
    movq -112(%rbp), %rdi
    addq -32(%rbp), %rdi
    addq -48(%rbp), %rdi
    addq -64(%rbp), %rdi
    movq -72(%rbp), %rsi
    movq -80(%rbp), %rcx
    rep movsb
    movq -112(%rbp), %rdi
    addq -32(%rbp), %rdi
    addq -48(%rbp), %rdi
    addq -64(%rbp), %rdi
    addq -80(%rbp), %rdi
    movq -88(%rbp), %rsi
    movq -96(%rbp), %rcx
    rep movsb
    call .L_tl_alloc16
    movq -112(%rbp), %rdx
    movq %rdx, 0(%rax)
    movq -104(%rbp), %rdx
    movq %rdx, 8(%rax)
    movq -16(%rbp), %rdi
    movq -8(%rbp), %rsi
    leave
    ret

")

;; #2386: byte copy helper used by lower-emit-memcpy for large by-value aggregate
;; copies. Always emitted. Linux SysV args rdi=dst, rsi=src, rdx=len; rep movsb
;; consumes rdi/rsi/rcx (all caller-saved). Windows x64 args rcx=dst, rdx=src,
;; r8=len; rdi/rsi are NONvolatile there, so save/restore them around the copy.
;;
;; #2357: memmove semantics. The lowerer threads by-value aggregates through
;; sret buffers and back into operands they may alias (e.g. a cache value
;; rebuilt from itself across a recursion), so dst can overlap src from above;
;; a forward rep movsb then reads bytes it already overwrote and corrupts the
;; value. Copy backward (std) for the overlapping dst>src case; DF is restored
;; before returning per the ABI.
(define (compiler-backend-runtime-memcpy-functions
  [target : CompilerBackendTarget]) : String
  (if (compiler-backend-target-windows? target)
    "    .globl tl_memcpy
tl_memcpy:
    movq %rdi, %rax
    movq %rsi, %r10
    movq %rcx, %rdi
    movq %rdx, %rsi
    movq %r8, %rcx
    cmpq %rsi, %rdi
    jbe .Ltl_memcpy_fwd
    movq %rsi, %r9
    addq %rcx, %r9
    cmpq %r9, %rdi
    jae .Ltl_memcpy_fwd
    leaq -1(%rdi,%rcx), %rdi
    leaq -1(%rsi,%rcx), %rsi
    std
    rep movsb
    cld
    movq %rax, %rdi
    movq %r10, %rsi
    ret
.Ltl_memcpy_fwd:
    rep movsb
    movq %rax, %rdi
    movq %r10, %rsi
    ret
"
    "    .globl tl_memcpy
tl_memcpy:
    movq %rdx, %rcx
    cmpq %rsi, %rdi
    jbe .Ltl_memcpy_fwd
    movq %rsi, %rax
    addq %rcx, %rax
    cmpq %rax, %rdi
    jae .Ltl_memcpy_fwd
    leaq -1(%rdi,%rcx), %rdi
    leaq -1(%rsi,%rcx), %rsi
    std
    rep movsb
    cld
    ret
.Ltl_memcpy_fwd:
    rep movsb
    ret
"))

(define (compiler-backend-runtime-atomic-functions
  [target : CompilerBackendTarget]) : String
  (if (compiler-backend-target-windows? target)
    "    .globl tl_atomic_i64_load_ptr
tl_atomic_i64_load_ptr:
    movq (%rcx), %rax
    ret
    .globl tl_atomic_i64_store_ptr
tl_atomic_i64_store_ptr:
    xchgq %rdx, (%rcx)
    ret
    .globl tl_atomic_i64_add_ptr
tl_atomic_i64_add_ptr:
    lock addq %rdx, (%rcx)
    ret
    .globl tl_atomic_i64_fetch_add_ptr
tl_atomic_i64_fetch_add_ptr:
    movq %rdx, %rax
    lock xaddq %rax, (%rcx)
    ret
    .globl tl_atomic_i32_load_ptr
tl_atomic_i32_load_ptr:
    movl (%rcx), %eax
    ret
    .globl tl_atomic_i32_store_ptr
tl_atomic_i32_store_ptr:
    xchgl %edx, (%rcx)
    ret
    .globl tl_atomic_i32_add_ptr
tl_atomic_i32_add_ptr:
    lock addl %edx, (%rcx)
    ret
    .globl tl_atomic_i32_fetch_add_ptr
tl_atomic_i32_fetch_add_ptr:
    movl %edx, %eax
    lock xaddl %eax, (%rcx)
    ret
"
    "    .globl tl_atomic_i64_load_ptr
tl_atomic_i64_load_ptr:
    movq (%rdi), %rax
    ret
    .globl tl_atomic_i64_store_ptr
tl_atomic_i64_store_ptr:
    xchgq %rsi, (%rdi)
    ret
    .globl tl_atomic_i64_add_ptr
tl_atomic_i64_add_ptr:
    lock addq %rsi, (%rdi)
    ret
    .globl tl_atomic_i64_fetch_add_ptr
tl_atomic_i64_fetch_add_ptr:
    movq %rsi, %rax
    lock xaddq %rax, (%rdi)
    ret
    .globl tl_atomic_i32_load_ptr
tl_atomic_i32_load_ptr:
    movl (%rdi), %eax
    ret
    .globl tl_atomic_i32_store_ptr
tl_atomic_i32_store_ptr:
    xchgl %esi, (%rdi)
    ret
    .globl tl_atomic_i32_add_ptr
tl_atomic_i32_add_ptr:
    lock addl %esi, (%rdi)
    ret
    .globl tl_atomic_i32_fetch_add_ptr
tl_atomic_i32_fetch_add_ptr:
    movl %esi, %eax
    lock xaddl %eax, (%rdi)
    ret
"))

(define (compiler-backend-runtime-linux-only
  [target : CompilerBackendTarget]
  [enabled : bool]
  [asm : String]) : String
  (if enabled
    (if (compiler-backend-target-windows? target)
      ""
      asm)
    ""))

(define (compiler-backend-runtime-functions-for-target
  [target : CompilerBackendTarget]
  [plan : CompilerBackendRuntimePlan]) : String
  (match plan
    [(BackendRuntimePlan
        alloc
        oob
        substring
        str-view
        concat
        _
        _
        int-to-string
        abort
        _
        _
        _
        _
        _
        _
        _
        _
        _
        _
        _
        fs-runtime
        _
        _
        _
        _
        _
        region-mark
        region-reset
        _
        env-var-exists
        env-var-value
        env-path-separator
        div-abort
        shift-abort
        tail-plan)
      (let
        [profile : bool (compiler-backend-runtime-tail-profile? tail-plan)]
        [alloc-asm : String
          (if alloc
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-alloc-functions profile)
              (compiler-backend-runtime-linux-alloc-functions profile))
            "")]
        ;; The out-of-bounds/division/shift fault handlers now live in the
        ;; runtime prelude (stdlib/runtime.tl), exported via #2143; the backend
        ;; emits no asm for them. The plan flags are retained for the runtime
        ;; index (which still tracks the `tl_*_abort` call sites).
        [oob-asm : String
          (if oob
            ""
            "")]
        [div-abort-asm : String
          (if div-abort
            ""
            "")]
        [shift-abort-asm : String
          (if shift-abort
            ""
            "")]
        [substring-asm : String
          (if substring
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-substring-functions)
              (compiler-backend-runtime-substring-functions))
            "")]
        [str-view-asm : String
          (if str-view
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-str-view-functions)
              (compiler-backend-runtime-str-view-functions))
            "")]
        [concat-asm : String
          (if concat
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-concat-functions)
              (compiler-backend-runtime-concat-functions))
            "")]
        [int-to-string-asm : String
          (if int-to-string
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-int-to-string-functions)
              (compiler-backend-runtime-int-to-string-functions))
            "")]
        [abort-asm : String
          (if abort
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-abort-functions)
              (compiler-backend-runtime-abort-functions))
            "")]
        [fs-asm : String
          (if fs-runtime
            (compiler-backend-runtime-fs-functions-for-target target)
            "")]
        [region-mark-asm : String
          (if region-mark
            (compiler-backend-runtime-region-mark-functions target)
            "")]
        [region-reset-asm : String
          (if region-reset
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-region-reset-functions profile)
              (compiler-backend-runtime-region-reset-functions profile))
            "")]
        [arena-asm : String
          (if (compiler-backend-target-windows? target)
            (compiler-backend-runtime-windows-arena-functions profile)
            (compiler-backend-runtime-linux-arena-functions profile))]
        [profile-asm : String
          (compiler-backend-runtime-profile-functions-for-target target profile)]
        [memcpy-asm : String (compiler-backend-runtime-memcpy-functions target)]
        [atomic-asm : String (compiler-backend-runtime-atomic-functions target)]
        [runtime-front-asm : String
          (string-append
            memcpy-asm
            (string-append
              atomic-asm
              (string-append
                arena-asm
                (string-append
                  profile-asm
                  (str-cat
                    alloc-asm
                    region-mark-asm
                    region-reset-asm
                    oob-asm
                    div-abort-asm)))))]
        [runtime-string-asm : String
          (string-append
            (str-cat shift-abort-asm substring-asm str-view-asm concat-asm "")
            (string-append int-to-string-asm abort-asm))]
        [env-var-exists-asm : String
          (if env-var-exists
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-env-var-exists-functions)
              (compiler-backend-runtime-env-var-exists-functions))
            "")]
        [env-var-value-asm : String
          (if env-var-value
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-env-var-value-functions)
              (compiler-backend-runtime-env-var-value-functions))
            "")]
        [env-path-separator-asm : String
          (if env-path-separator
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-env-path-separator-functions)
              (compiler-backend-runtime-env-path-separator-functions))
            "")]
        [linux-libc-shims-asm : String
          (if (compiler-backend-target-windows? target)
            (compiler-backend-runtime-windows-libc-shim-functions)
            (compiler-backend-runtime-linux-libc-shim-functions))]
        [thread-asm : String
          (if (compiler-backend-target-windows? target)
            (compiler-backend-runtime-windows-thread-functions)
            "")]
        (str-cat
          runtime-front-asm
          runtime-string-asm
          fs-asm
          thread-asm
          env-var-exists-asm
          env-var-value-asm
          env-path-separator-asm
          linux-libc-shims-asm
          ""))]))

;; Argument register for call arg `idx` under the target's calling convention.
;; System V (Linux) uses rdi/rsi/rdx/rcx/r8/r9 via `compiler-backend-arg-reg`;
;; Windows x64 passes the first four integer/pointer args in rcx/rdx/r8/r9.
(define (compiler-backend-target-arg-reg
  [target : CompilerBackendTarget]
  [idx : i64]) : ResultBackendReg
  (match target
    [(BackendTargetLinux) (compiler-backend-arg-reg idx)]
    [(BackendTargetWindows)
      (cond
        [(= idx 0) (OkBackendReg "%rcx")]
        [(= idx 1) (OkBackendReg "%rdx")]
        [(= idx 2) (OkBackendReg "%r8")]
        [(= idx 3) (OkBackendReg "%r9")]
        [else (ErrBackendReg "backend: too many call args")])]))

(define (compiler-backend-target-float-arg-reg
  [target : CompilerBackendTarget]
  [idx : i64]) : ResultBackendReg
  (match target
    [(BackendTargetLinux) (compiler-backend-float-arg-reg idx)]
    [(BackendTargetWindows)
      (cond
        [(= idx 0) (OkBackendReg "%xmm0")]
        [(= idx 1) (OkBackendReg "%xmm1")]
        [(= idx 2) (OkBackendReg "%xmm2")]
        [(= idx 3) (OkBackendReg "%xmm3")]
        [else (ErrBackendReg "backend: too many call args")])]))

;; Caller-reserved outgoing shadow space in bytes: none on System V, 32 on
;; Windows x64.
(define (compiler-backend-outgoing-shadow-space
  [target : CompilerBackendTarget]) : i64
  (match target
    [(BackendTargetLinux) 0]
    [(BackendTargetWindows) 32]))

;; Program entry section and global symbol. Freestanding Linux links the
;; backend-owned `_tl_start`; CRT entry mode links `main` through the C runtime.
;; Windows links `main` through the CRT. (The Windows entry body is #647.)
(define (compiler-backend-target-linux? [target : CompilerBackendTarget]) : bool
  (match target
    [(BackendTargetLinux) true]
    [(BackendTargetWindows) false]))

(define (compiler-backend-target-entry-text-with-crt
  [target : CompilerBackendTarget]
  [emit-entry : bool]
  [crt-entry : bool]) : String
  (if emit-entry
    (match target
      [(BackendTargetLinux)
        (if crt-entry
          ".text\n.globl main\n"
          ".text\n.globl _tl_start\n")]
      [(BackendTargetWindows) ".text\n.globl main\n"])
    ".text\n"))

(define (compiler-backend-target-entry-text
  [target : CompilerBackendTarget]
  [emit-entry : bool]) : String
  (compiler-backend-target-entry-text-with-crt target emit-entry false))

;; Run main on a fresh 1 GiB mmap'd stack, then exit(main()). The compiler
;; recurses far deeper than the default 8 MiB stack rlimit allows Ã¢â‚¬â€ type-directed
;; `clone` of large IR values during arena escapes (#1633) is the worst case Ã¢â‚¬â€ so
;; a self-hosted compiler segfaults compiling a large program on the default
;; stack. argc/argv/envp are already captured into globals before this runs, so
;; switching %rsp is safe (main reads them from globals, not the stack). A failed
;; mmap (negative result) keeps the original stack; the unmapped page below the
;; region turns any overflow into a clean SIGSEGV rather than silent corruption.
(define (compiler-backend-entry-call-main) : String
  "    movq $0x40000000, %rsi
    xorq %rdi, %rdi
    movq $3, %rdx
    movq $0x22, %r10
    movq $-1, %r8
    xorq %r9, %r9
    movq $9, %rax
    syscall
    testq %rax, %rax
    js .L_tl_main_keep_stack
    addq $0x40000000, %rax
    andq $-16, %rax
    movq %rax, %rsp
.L_tl_main_keep_stack:
    call main
    movq %rax, %rdi
    movq $60, %rax
    syscall
")

(define (compiler-backend-entry
  [capture-argv : bool]
  [capture-env : bool]
  [global-inits : String]) : String
  (if (or capture-argv capture-env)
    (string-append
      "_tl_start:
    movq (%rsp), %rax
"
      (string-append
        (if capture-argv
          "    movq %rax, .L_tl_argc(%rip)
    leaq 8(%rsp), %rax
    movq %rax, .L_tl_argv(%rip)
"
          "")
        (string-append
          (if capture-env
            (string-append
              (if capture-argv
                "    movq (%rsp), %rax\n"
                "")
              "    leaq 16(%rsp,%rax,8), %rax
    movq %rax, .L_tl_envp(%rip)
")
            "")
          (string-append
            "    call tl_thread_init\n"
            (string-append global-inits (compiler-backend-entry-call-main))))))
    (string-append
      "_tl_start:\n"
      (string-append
        "    call tl_thread_init\n"
        (string-append global-inits (compiler-backend-entry-call-main))))))

(define (compiler-backend-entry-for-target-with-crt
  [target : CompilerBackendTarget]
  [plan : CompilerBackendRuntimePlan]
  [globals : CompilerIrGlobalList]
  [crt-entry : bool]
  [program-index : CompilerBackendProgramIndex]) : String
  (match target
    [(BackendTargetLinux)
      (if crt-entry
        ""
        (let
          [_ : CompilerBackendRuntimePlan plan]
          (compiler-backend-entry
            true
            true
            (compiler-backend-global-initializers globals program-index))))]
    [(BackendTargetWindows) ""]))

(define (compiler-backend-entry-for-target
  [target : CompilerBackendTarget]
  [plan : CompilerBackendRuntimePlan]
  [globals : CompilerIrGlobalList]
  [program-index : CompilerBackendProgramIndex]) : String
  (compiler-backend-entry-for-target-with-crt
    target
    plan
    globals
    false
    program-index))

(define (compiler-backend-target-windows? [target : CompilerBackendTarget]) : bool
  (match target
    [(BackendTargetLinux) false]
    [(BackendTargetWindows) true]))

(define (compiler-backend-runtime-plan-empty?
  [plan : CompilerBackendRuntimePlan]) : bool
  (match plan
    [(BackendRuntimePlan
        alloc
        oob
        substring
        str-view
        concat
        string-eq
        string-to-int
        int-to-string
        abort
        print-err
        print-str
        print-char
        print-f64
        arg-count
        arg
        read-file
        write-file
        file-exists
        file-handle
        file-read-chunk
        fs-runtime
        _
        read-line
        read-bytes
        stdin-eof
        flush-stdout
        region-mark
        region-reset
        _
        env-var-exists
        env-var-value
        env-path-separator
        div-abort
        shift-abort
        tail-plan)
      (let
        [front-runtime : bool
          (backend-or8
            alloc
            oob
            substring
            str-view
            concat
            string-eq
            string-to-int
            (or int-to-string abort))]
        [io-runtime : bool
          (backend-or8
            print-err
            print-str
            print-char
            print-f64
            arg-count
            arg
            read-file
            write-file)]
        [file-runtime : bool
          (backend-or8
            file-exists
            file-handle
            file-read-chunk
            fs-runtime
            false
            read-line
            read-bytes
            stdin-eof)]
        [tail-runtime : bool
          (backend-or8
            flush-stdout
            region-mark
            region-reset
            false
            env-var-exists
            env-var-value
            false
            false)]
        [extra-runtime : bool
          (backend-or4
            env-path-separator
            div-abort
            shift-abort
            (or
              (compiler-backend-runtime-tail-profile? tail-plan)
              (compiler-backend-runtime-tail-hash-string? tail-plan)))]
        (not
          (or front-runtime io-runtime file-runtime tail-runtime extra-runtime)))]))

;; All runtime helpers the backend can be asked to emit now have a Windows
;; variant (region mark/reset and the env-var/env-path helpers were the last
;; Windows-unsupported ones; see the *-windows-* runtime functions above), so no
;; plan is rejected on either target. The `plan` parameter is retained for the
;; signature shape and possible future target-specific gating.
(define (compiler-backend-target-runtime-ok?
  [target : CompilerBackendTarget]
  [plan : CompilerBackendRuntimePlan]) : bool
  (let
    [_ : CompilerBackendTarget target]
    [_plan : CompilerBackendRuntimePlan plan]
    true))

(define (compiler-backend-runtime-externs-for-target
  [target : CompilerBackendTarget]
  [plan : CompilerBackendRuntimePlan]) : String
  (if (compiler-backend-target-windows? target)
    (let
      [needs-write-exit : bool
        (or
          (compiler-backend-plan-provides? plan "tl_alloc")
          (compiler-backend-plan-provides? plan "tl_oob_abort")
          (compiler-backend-plan-provides? plan ".L_tl_abort")
          (compiler-backend-plan-provides? plan "tl_div_abort")
          (compiler-backend-plan-provides? plan "tl_shift_abort")
          (compiler-backend-plan-provides? plan "tl_region_reset"))]
      [needs-get-std-handle : bool needs-write-exit]
      (string-append
        "    .extern VirtualAlloc
    .extern VirtualFree
    .extern ExitProcess
"
        (string-append
          (if needs-write-exit
            "    .extern WriteFile
"
            "")
          (string-append
            (if needs-get-std-handle
              "    .extern GetStdHandle
"
              "")
            (string-append
              (if (compiler-backend-plan-provides? plan "tl_print_f64")
                "    .extern _snprintf
"
                "")
              "")))))
    ""))

;; Emit a full program for `target`. Windows x64 has ABI-correct user function
;; entry/calls and target-specific runtime helpers.
;; Backend entry points come in two flavors (#605): the original
;;
;; program-only variants (kept for existing call sites and smoke tests) supply
;;
;; an empty provenance table, so backend diagnostics fall back to `path:1:1`;
;;
;; the `-with-spans` variants thread the lowering provenance side table so
;;
;; backend errors report the offending function's real source location.
(define (compiler-backend-emit-program-for-target
  [program : CompilerIrProgram]
  [target : CompilerBackendTarget]) : ResultCompilerBackend
  (compiler-backend-emit-program-target
    program
    target
    (compiler-source-spans-empty)
    true))

(define (compiler-backend-emit-program-linux [program : CompilerIrProgram]) : ResultCompilerBackend
  (compiler-backend-emit-program-for-target program (BackendTargetLinux)))

(define (compiler-backend-emit-program-linux-with-spans
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]) : ResultCompilerBackend
  (compiler-backend-emit-program-target program (BackendTargetLinux) spans true))

(define (compiler-backend-emit-program-linux-with-spans-and-entry
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [emit-entry : bool]) : ResultCompilerBackend
  (compiler-backend-emit-program-target
    program
    (BackendTargetLinux)
    spans
    emit-entry))

(define (compiler-backend-emit-program-with-spans-for-target
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [target : CompilerBackendTarget]) : ResultCompilerBackend
  (compiler-backend-emit-program-target program target spans true))

(define (compiler-backend-emit-program-with-spans-for-target-and-entry
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [target : CompilerBackendTarget]
  [emit-entry : bool]) : ResultCompilerBackend
  (compiler-backend-emit-program-target program target spans emit-entry))

(define (compiler-backend-emit-program-target
  [program : CompilerIrProgram]
  [target : CompilerBackendTarget]
  [spans : CompilerSourceSpans]
  [emit-entry : bool]) : ResultCompilerBackend
  (compiler-backend-emit-program-target-with-mode
    program
    target
    (BackendModeScalar)
    spans
    emit-entry))

(define (compiler-backend-emit-program-target-with-mode-buffer
  [program : CompilerIrProgram]
  [target : CompilerBackendTarget]
  [mode : CompilerBackendMode]
  [spans : CompilerSourceSpans]
  [emit-entry : bool]) : ResultCompilerBackendBuffer
  (compiler-backend-emit-program-target-with-mode-buffer-and-crt
    program
    target
    mode
    spans
    emit-entry
    false))

(define (compiler-backend-emit-program-prefix-buffer
  [target : CompilerBackendTarget]
  [entry-functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [plan : CompilerBackendRuntimePlan]
  [program-index : CompilerBackendProgramIndex]
  [closure-names : BackendStringList]
  [strings : BackendStringList]
  [bytes : BackendStringList]
  [floats : BackendStringList]
  [uses-f64-neg : bool]
  [globals-buf : TextBuf]
  [emit-entry : bool]
  [crt-entry : bool]) : TextBuf
  (let
    [string-buf : TextBuf
      (compiler-backend-emit-string-rodata-into strings globals-buf)]
    (begin
      (cfg
        compile-profile
        (compiler-backend-profile-finish "compose.string_rodata"))
      (cfg compile-profile (compiler-backend-profile-start))
      (let
        [bytes-buf : TextBuf
          (compiler-backend-emit-bytes-data-into bytes string-buf)]
        (begin
          (cfg
            compile-profile
            (compiler-backend-profile-finish "compose.bytes_data"))
          (cfg compile-profile (compiler-backend-profile-start))
          (let
            [f64-literals-buf : TextBuf
              (compiler-backend-emit-f64-rodata-into floats bytes-buf)]
            [f64-buf : TextBuf
              (compiler-backend-emit-f64-sign-bit-rodata-into
                uses-f64-neg
                f64-literals-buf)]
            (begin
              (cfg
                compile-profile
                (compiler-backend-profile-finish "compose.f64_rodata"))
              (cfg compile-profile (compiler-backend-profile-start))
              (let
                [descriptor-buf : TextBuf
                  (compiler-backend-emit-closure-descriptors-into
                    closure-names
                    entry-functions
                    externs
                    program-index
                    f64-buf)]
                (begin
                  (cfg
                    compile-profile
                    (compiler-backend-profile-finish
                      "compose.closure_descriptors"))
                  (cfg compile-profile (compiler-backend-profile-start))
                  (let
                    [runtime-data-buf : TextBuf
                      (text-buf-append
                        descriptor-buf
                        (if emit-entry
                          (compiler-backend-runtime-data-for-target target plan)
                          ""))]
                    (begin
                      (cfg
                        compile-profile
                        (compiler-backend-profile-finish "compose.runtime_data"))
                      (cfg compile-profile (compiler-backend-profile-start))
                      (let
                        [externs-buf : TextBuf
                          (compiler-backend-emit-externs-into
                            externs
                            plan
                            runtime-data-buf)]
                        (begin
                          (cfg
                            compile-profile
                            (compiler-backend-profile-finish "compose.externs"))
                          (cfg compile-profile (compiler-backend-profile-start))
                          (let
                            [runtime-externs-buf : TextBuf
                              (text-buf-append
                                externs-buf
                                (if emit-entry
                                  (compiler-backend-runtime-externs-for-target
                                    target
                                    plan)
                                  ""))]
                            (begin
                              (cfg
                                compile-profile
                                (compiler-backend-profile-finish
                                  "compose.runtime_externs"))
                              (cfg
                                compile-profile
                                (compiler-backend-profile-start))
                              (let
                                [prefix-buf : TextBuf
                                  (text-buf-append
                                    runtime-externs-buf
                                    (compiler-backend-target-entry-text-with-crt
                                      target
                                      emit-entry
                                      crt-entry))]
                                (begin
                                  (cfg
                                    compile-profile
                                    (compiler-backend-profile-finish
                                      "compose.entry_text"))
                                  prefix-buf)))))))))))))))))

(define (compiler-backend-emit-program-buffer-after-index
  [program : CompilerIrProgram]
  [target : CompilerBackendTarget]
  [mode : CompilerBackendMode]
  [entry-functions : CompilerIrFunctionList]
  [globals : CompilerIrGlobalList]
  [externs : CompilerIrExternList]
  [plan : CompilerBackendRuntimePlan]
  [program-index : CompilerBackendProgramIndex]
  [spans : CompilerSourceSpans]
  [globals-buf : TextBuf]
  [emit-entry : bool]
  [crt-entry : bool]) : ResultCompilerBackendBuffer
  (let
    [collections : CompilerBackendProgramCollections
      (compiler-backend-collect-program-collections program)]
    [closure-names : BackendStringList
      (compiler-backend-program-collections-functions collections)]
    [strings : BackendStringList
      (compiler-backend-program-collections-strings collections)]
    [bytes : BackendStringList
      (compiler-backend-program-collections-bytes collections)]
    [floats : BackendStringList
      (compiler-backend-program-collections-floats collections)]
    [uses-f64-neg : bool
      (compiler-backend-program-collections-uses-f64-neg? collections)]
    [span-index : CompilerBackendSourceSpanIndex
      (compiler-backend-source-span-index-build spans)]
    [global-types : CompilerBackendGlobalTypeList
      (compiler-backend-global-types globals)]
    (begin
      (cfg compile-profile (compiler-backend-profile-finish "collect"))
      (cfg compile-profile (compiler-backend-profile-start))
      (let
        [prefix-buf : TextBuf
          (compiler-backend-emit-program-prefix-buffer
            target
            entry-functions
            externs
            plan
            program-index
            closure-names
            strings
            bytes
            floats
            uses-f64-neg
            globals-buf
            emit-entry
            crt-entry)]
        (begin
          ;; This window previously started at the "collect" finish and was
          ;; overwritten by the next start without ever being reported,
          ;; hiding the prefix composition from the phase breakdown.
          (cfg compile-profile (compiler-backend-profile-finish "prefix"))
          (cfg compile-profile (compiler-backend-profile-start))
          (match (compiler-backend-emit-functions-buffer-into
            target
            mode
            entry-functions
            entry-functions
            globals
            global-types
            externs
            plan
            program-index
            spans
            span-index
            emit-entry
            crt-entry
            prefix-buf)
            [(OkCompilerBackendBuffer with-functions)
              (begin
                (cfg
                  compile-profile
                  (compiler-backend-profile-finish "functions"))
                (cfg compile-profile (compiler-backend-profile-start))
                (match (compiler-backend-emit-closure-entry-adapters-buffer-into
                  target
                  closure-names
                  entry-functions
                  externs
                  plan
                  program-index
                  with-functions)
                  [(OkCompilerBackendBuffer with-adapters)
                    (begin
                      (cfg
                        compile-profile
                        (compiler-backend-profile-finish "adapters"))
                      (cfg compile-profile (compiler-backend-profile-start))
                      (let
                        [buf : TextBuf
                          (text-buf-append
                            (text-buf-append
                              with-adapters
                              (if emit-entry
                                (compiler-backend-runtime-functions-for-target
                                  target
                                  plan)
                                ""))
                            (if emit-entry
                              (compiler-backend-entry-for-target-with-crt
                                target
                                plan
                                globals
                                crt-entry
                                program-index)
                              ""))]
                        (begin
                          (cfg
                            compile-profile
                            (compiler-backend-profile-finish "compose_tail"))
                          (cfg
                            regalloc-census
                            (compiler-reg-call-span-census-print!))
                          (OkCompilerBackendBuffer buf))))]
                  [(ErrCompilerBackendBuffer message)
                    (begin
                      (cfg
                        compile-profile
                        (compiler-backend-profile-finish "adapters"))
                      (ErrCompilerBackendBuffer message))]))]
            [(ErrCompilerBackendBuffer message)
              (begin
                (cfg
                  compile-profile
                  (compiler-backend-profile-finish "functions"))
                (ErrCompilerBackendBuffer message))]))))))

(define (compiler-backend-emit-program-target-with-mode-buffer-and-crt
  [program : CompilerIrProgram]
  [target : CompilerBackendTarget]
  [mode : CompilerBackendMode]
  [spans : CompilerSourceSpans]
  [emit-entry : bool]
  [crt-entry : bool]) : ResultCompilerBackendBuffer
  (begin
    (compiler-backend-user-symbol-cache-reset!)
    (cfg regalloc-census (compiler-reg-call-span-census-reset!))
    (cfg compile-profile (compiler-backend-profile-start))
    (match (compiler-backend-runtime-plan program)
      [(OkBackendRuntimePlan plan)
        (begin
          (cfg compile-profile (compiler-backend-profile-finish "runtime_plan"))
          (cfg compile-profile (compiler-backend-profile-start))
          (if (compiler-backend-target-runtime-ok? target plan)
            (begin
              (cfg
                compile-profile
                (compiler-backend-profile-finish "target_check"))
              (cfg compile-profile (compiler-backend-profile-start))
              (match program
                [(IrProgram globals functions externs)
                  ;; Build the program index ONCE over the entry function list
                  ;; and share it with the globals emission: each build walks
                  ;; every function body for the register-group counts, so the
                  ;; former second build doubled both that walk and its ~120MB
                  ;; of transient allocation. The entry list is a superset of
                  ;; `functions` (at most the synthesized implicit main, which
                  ;; no global initializer can reference), so globals resolve
                  ;; identically against the shared index.
                  (let
                    [entry-functions : CompilerIrFunctionList
                      (compiler-backend-functions-with-implicit-main
                        functions
                        emit-entry)]
                    [program-index : CompilerBackendProgramIndex
                      (compiler-backend-program-index-build
                        entry-functions
                        externs)]
                    (begin
                      (cfg
                        compile-profile
                        (compiler-backend-profile-finish "index"))
                      (cfg compile-profile (compiler-backend-profile-start))
                      (match (compiler-backend-emit-globals-buffer-into
                        target
                        globals
                        (text-buf-append (text-buf-empty) ".data\n")
                        program-index)
                        [(OkCompilerBackendBuffer globals-buf)
                          (begin
                            (cfg
                              compile-profile
                              (compiler-backend-profile-finish "globals"))
                            (cfg
                              compile-profile
                              (compiler-backend-profile-start))
                            (match (compiler-backend-validate-function-symbols
                              globals
                              entry-functions
                              externs
                              plan
                              program-index)
                              [(OkCompilerBackendSymbolValidation _)
                                (compiler-backend-emit-program-buffer-after-index
                                  program
                                  target
                                  mode
                                  entry-functions
                                  globals
                                  externs
                                  plan
                                  program-index
                                  spans
                                  globals-buf
                                  emit-entry
                                  crt-entry)]
                              [(ErrCompilerBackendSymbolValidation message)
                                (ErrCompilerBackendBuffer message)]))]
                        [(ErrCompilerBackendBuffer message)
                          (begin
                            (cfg
                              compile-profile
                              (compiler-backend-profile-finish "globals"))
                            (ErrCompilerBackendBuffer message))])))]))
            (begin
              (cfg
                compile-profile
                (compiler-backend-profile-finish "target_check"))
              (ErrCompilerBackendBuffer
                (compiler-diagnostic-at-start
                  ""
                  "backend: internal target runtime rejection")))))]
      [(ErrBackendRuntimePlan message)
        (begin
          (cfg compile-profile (compiler-backend-profile-finish "runtime_plan"))
          (ErrCompilerBackendBuffer (compiler-diagnostic-at-start "" message)))])))

(defstruct CompilerBackendObjectParts
  (text CompilerObjectX64InstrList)
  (data CompilerObjectDataRecordList)
  (rodata CompilerObjectDataRecordList)
  (bss CompilerObjectDataRecordList)
  (pdata CompilerObjectDataRecordList)
  (xdata CompilerObjectDataRecordList)
  (symbols CompilerObjectSymbolList)
  (relocations CompilerObjectRelocationList))

(define (compiler-backend-object-parts-empty) : CompilerBackendObjectParts
  (CompilerBackendObjectParts
    ObjectInstrNil
    ObjectDataNil
    ObjectDataNil
    ObjectDataNil
    ObjectDataNil
    ObjectDataNil
    ObjectSymbolNil
    ObjectRelocationNil))

(define (compiler-backend-object-add-text
  [parts : CompilerBackendObjectParts]
  [instr : CompilerObjectX64Instr]) : CompilerBackendObjectParts
  (CompilerBackendObjectParts
    (compiler-object-instr-cons instr (struct-get parts text))
    (struct-get parts data)
    (struct-get parts rodata)
    (struct-get parts bss)
    (struct-get parts pdata)
    (struct-get parts xdata)
    (struct-get parts symbols)
    (struct-get parts relocations)))

(define (compiler-backend-object-add-data
  [parts : CompilerBackendObjectParts]
  [record : CompilerObjectDataRecord]) : CompilerBackendObjectParts
  (CompilerBackendObjectParts
    (struct-get parts text)
    (compiler-object-data-cons record (struct-get parts data))
    (struct-get parts rodata)
    (struct-get parts bss)
    (struct-get parts pdata)
    (struct-get parts xdata)
    (struct-get parts symbols)
    (struct-get parts relocations)))

(define (compiler-backend-object-add-rodata
  [parts : CompilerBackendObjectParts]
  [record : CompilerObjectDataRecord]) : CompilerBackendObjectParts
  (CompilerBackendObjectParts
    (struct-get parts text)
    (struct-get parts data)
    (compiler-object-data-cons record (struct-get parts rodata))
    (struct-get parts bss)
    (struct-get parts pdata)
    (struct-get parts xdata)
    (struct-get parts symbols)
    (struct-get parts relocations)))

(define (compiler-backend-object-add-bss
  [parts : CompilerBackendObjectParts]
  [record : CompilerObjectDataRecord]) : CompilerBackendObjectParts
  (CompilerBackendObjectParts
    (struct-get parts text)
    (struct-get parts data)
    (struct-get parts rodata)
    (compiler-object-data-cons record (struct-get parts bss))
    (struct-get parts pdata)
    (struct-get parts xdata)
    (struct-get parts symbols)
    (struct-get parts relocations)))

(define (compiler-backend-object-add-pdata
  [parts : CompilerBackendObjectParts]
  [record : CompilerObjectDataRecord]) : CompilerBackendObjectParts
  (CompilerBackendObjectParts
    (struct-get parts text)
    (struct-get parts data)
    (struct-get parts rodata)
    (struct-get parts bss)
    (compiler-object-data-cons record (struct-get parts pdata))
    (struct-get parts xdata)
    (struct-get parts symbols)
    (struct-get parts relocations)))

(define (compiler-backend-object-add-xdata
  [parts : CompilerBackendObjectParts]
  [record : CompilerObjectDataRecord]) : CompilerBackendObjectParts
  (CompilerBackendObjectParts
    (struct-get parts text)
    (struct-get parts data)
    (struct-get parts rodata)
    (struct-get parts bss)
    (struct-get parts pdata)
    (compiler-object-data-cons record (struct-get parts xdata))
    (struct-get parts symbols)
    (struct-get parts relocations)))

(define (compiler-backend-object-add-symbol
  [parts : CompilerBackendObjectParts]
  [name : String]
  [binding : CompilerObjectSymbolBinding]
  [kind : CompilerObjectSymbolKind]
  [section : CompilerObjectMaybeSection]) : CompilerBackendObjectParts
  (CompilerBackendObjectParts
    (struct-get parts text)
    (struct-get parts data)
    (struct-get parts rodata)
    (struct-get parts bss)
    (struct-get parts pdata)
    (struct-get parts xdata)
    (compiler-object-symbol-cons
      (ObjectSymbol name binding kind section)
      (struct-get parts symbols))
    (struct-get parts relocations)))

(define (compiler-backend-object-add-relocation
  [parts : CompilerBackendObjectParts]
  [section : CompilerObjectSectionKind]
  [site : String]
  [kind : CompilerObjectRelocationKind]
  [target : String]) : CompilerBackendObjectParts
  (CompilerBackendObjectParts
    (struct-get parts text)
    (struct-get parts data)
    (struct-get parts rodata)
    (struct-get parts bss)
    (struct-get parts pdata)
    (struct-get parts xdata)
    (struct-get parts symbols)
    (compiler-object-relocation-cons
      (ObjectRelocation section site kind target)
      (struct-get parts relocations))))

(define (compiler-backend-object-symbol-local-section
  [parts : CompilerBackendObjectParts]
  [name : String]
  [section : CompilerObjectSectionKind]
  [kind : CompilerObjectSymbolKind]) : CompilerBackendObjectParts
  (compiler-backend-object-add-symbol
    parts
    name
    (ObjectSymbolLocal)
    kind
    (ObjectSomeSection section)))

(define (compiler-backend-object-symbol-export-section
  [parts : CompilerBackendObjectParts]
  [name : String]
  [section : CompilerObjectSectionKind]
  [kind : CompilerObjectSymbolKind]) : CompilerBackendObjectParts
  (compiler-backend-object-add-symbol
    parts
    name
    (ObjectSymbolExport)
    kind
    (ObjectSomeSection section)))

(define (compiler-backend-object-symbol-extern
  [parts : CompilerBackendObjectParts]
  [name : String]
  [kind : CompilerObjectSymbolKind]) : CompilerBackendObjectParts
  (compiler-backend-object-add-symbol
    parts
    name
    (ObjectSymbolExtern)
    kind
    (ObjectNoSection)))

(define (compiler-backend-object-symbol-extern-once
  [parts : CompilerBackendObjectParts]
  [name : String]
  [kind : CompilerObjectSymbolKind]) : CompilerBackendObjectParts
  (if (compiler-object-symbol-list-contains?
    (struct-get parts symbols)
    name
    (ObjectSymbolExtern)
    kind)
    parts
    (compiler-backend-object-symbol-extern parts name kind)))

(define (compiler-backend-object-add-text-relocation
  [parts : CompilerBackendObjectParts]
  [site : String]
  [kind : CompilerObjectRelocationKind]
  [target : String]) : CompilerBackendObjectParts
  (compiler-backend-object-add-relocation
    parts
    (ObjectSectionText)
    site
    kind
    target))

(define (compiler-backend-object-add-data-relocation
  [parts : CompilerBackendObjectParts]
  [site : String]
  [kind : CompilerObjectRelocationKind]
  [target : String]) : CompilerBackendObjectParts
  (compiler-backend-object-add-relocation
    parts
    (ObjectSectionData)
    site
    kind
    target))

(define (compiler-backend-object-add-rodata-relocation
  [parts : CompilerBackendObjectParts]
  [site : String]
  [kind : CompilerObjectRelocationKind]
  [target : String]) : CompilerBackendObjectParts
  (compiler-backend-object-add-relocation
    parts
    (ObjectSectionRodata)
    site
    kind
    target))

(define (compiler-backend-object-add-pdata-relocation
  [parts : CompilerBackendObjectParts]
  [site : String]
  [kind : CompilerObjectRelocationKind]
  [target : String]) : CompilerBackendObjectParts
  (compiler-backend-object-add-relocation
    parts
    (ObjectSectionPdata)
    site
    kind
    target))

(define (compiler-backend-object-value-ref
  [parts : CompilerBackendObjectParts]
  [site : String]
  [value : CompilerIrValue]) : CompilerBackendObjectParts
  (match value
    [(IrValueGlobal name)
      (let
        [symbol : String (compiler-backend-user-symbol name)]
        (compiler-backend-object-add-text
          (compiler-backend-object-add-text-relocation
            parts
            site
            (ObjectRelocRipValue)
            symbol)
          (ObjectX64LoadRip symbol)))]
    [(IrValueGlobalAddr name)
      (let
        [symbol : String (compiler-backend-user-symbol name)]
        (compiler-backend-object-add-text
          (compiler-backend-object-add-text-relocation
            parts
            site
            (ObjectRelocRipAddress)
            symbol)
          (ObjectX64LoadRipAddress symbol)))]
    [(IrValueString text)
      (let
        [symbol : String (compiler-backend-string-fat-label text)]
        (compiler-backend-object-add-text
          (compiler-backend-object-add-text-relocation
            parts
            site
            (ObjectRelocRipAddress)
            symbol)
          (ObjectX64LoadRipAddress symbol)))]
    [(IrValueBytes text)
      (let
        [symbol : String (compiler-backend-bytes-fat-label text)]
        (compiler-backend-object-add-text
          (compiler-backend-object-add-text-relocation
            parts
            site
            (ObjectRelocRipAddress)
            symbol)
          (ObjectX64LoadRipAddress symbol)))]
    [(IrValueF64 text)
      (let
        [symbol : String (compiler-backend-f64-label text)]
        (compiler-backend-object-add-text
          (compiler-backend-object-add-text-relocation
            parts
            site
            (ObjectRelocRipValue)
            symbol)
          (ObjectX64LoadRip symbol)))]
    [(IrValueFunction name)
      (let
        [symbol : String (compiler-backend-closure-descriptor-label name)]
        (compiler-backend-object-add-text
          (compiler-backend-object-add-text-relocation
            parts
            site
            (ObjectRelocRipAddress)
            symbol)
          (ObjectX64LoadRipAddress symbol)))]
    [_ parts]))

(define (compiler-backend-object-call-args
  [parts : CompilerBackendObjectParts]
  [site : String]
  [args : CompilerIrCallArgs]
  [index : i64]) : CompilerBackendObjectParts
  (if (>= index (compiler-backend-call-args-count args))
    parts
    (compiler-backend-object-call-args
      (compiler-backend-object-value-ref
        parts
        site
        (compiler-backend-call-arg-at args index))
      site
      args
      (+ index 1))))

(define (compiler-backend-object-maybe-value-ref
  [parts : CompilerBackendObjectParts]
  [site : String]
  [value : CompilerIrMaybeValue]) : CompilerBackendObjectParts
  (match value
    [(IrNoValue) parts]
    [(IrSomeValue inner) (compiler-backend-object-value-ref parts site inner)]))

(define (compiler-backend-object-value-list-ref
  [parts : CompilerBackendObjectParts]
  [site : String]
  [values : CompilerIrValueList]) : CompilerBackendObjectParts
  (match values
    [(IrValueNil) parts]
    [(IrValueCons value rest)
      (compiler-backend-object-value-list-ref
        (compiler-backend-object-value-ref parts site value)
        site
        (box-get rest))]))

(define (compiler-backend-object-phi-inputs
  [parts : CompilerBackendObjectParts]
  [site : String]
  [inputs : CompilerIrPhiInputList]) : CompilerBackendObjectParts
  (match inputs
    [(IrPhiInputNil) parts]
    [(IrPhiInputCons value _ rest)
      (compiler-backend-object-phi-inputs
        (compiler-backend-object-value-ref parts site value)
        site
        (box-get rest))]))

(define (compiler-backend-object-byte [value : i64]) : u8
  (cast (bit-and value 0xff) : u8))

(define (compiler-backend-object-push-u8! [out : (Array u8)] [value : i64]) : unit
  (array-push! out (compiler-backend-object-byte value)))

(define (compiler-backend-object-push-u32! [out : (Array u8)] [value : i64]) : unit
  (begin
    (compiler-backend-object-push-u8! out value)
    (compiler-backend-object-push-u8! out (shr value 8))
    (compiler-backend-object-push-u8! out (shr value 16))
    (compiler-backend-object-push-u8! out (shr value 24))))

(define (compiler-backend-object-bytes-finish [out : (Array u8)]) : String
  (unsafe
    (string-from-bytes
      (ptr-cast (array-data out) : (Ptr u8))
      (array-length out))))

(define (compiler-backend-object-add-nonempty-bytes
  [parts : CompilerBackendObjectParts]
  [bytes : String]) : CompilerBackendObjectParts
  (if (= (string-length bytes) 0)
    parts
    (compiler-backend-object-add-text parts (ObjectX64Bytes bytes))))

(define (compiler-backend-object-reg-low-code [reg : String]) : i64
  (cond
    [(or (string-eq reg "%rax") (string-eq reg "%r8")) 0]
    [(or (string-eq reg "%rcx") (string-eq reg "%r9")) 1]
    [(or (string-eq reg "%rdx") (string-eq reg "%r10")) 2]
    [(or (string-eq reg "%rbx") (string-eq reg "%r11")) 3]
    [(or (string-eq reg "%rsp") (string-eq reg "%r12")) 4]
    [(or (string-eq reg "%rbp") (string-eq reg "%r13")) 5]
    [(or (string-eq reg "%rsi") (string-eq reg "%r14")) 6]
    [else 7]))

(define (compiler-backend-object-reg-high? [reg : String]) : bool
  (or
    (string-eq reg "%r8")
    (string-eq reg "%r9")
    (string-eq reg "%r10")
    (string-eq reg "%r11")
    (string-eq reg "%r12")
    (string-eq reg "%r13")
    (string-eq reg "%r14")
    (string-eq reg "%r15")))

(define (compiler-backend-object-slot-disp [var-id : i64]) : i64
  (- 0 (* 8 (+ var-id 1))))

(define (compiler-backend-object-disp8? [disp : i64]) : bool
  (and (>= disp -128) (<= disp 127)))

(define (compiler-backend-object-load-slot-bytes [var-id : i64] [reg : String]) : String
  (let
    [out : (Array u8) (make-array u8 0)]
    [disp : i64 (compiler-backend-object-slot-disp var-id)]
    [reg-code : i64 (compiler-backend-object-reg-low-code reg)]
    [rex : i64
      (+
        0x48
        (if (compiler-backend-object-reg-high? reg)
          4
          0))]
    (begin
      (compiler-backend-object-push-u8! out rex)
      (compiler-backend-object-push-u8! out 0x8b)
      (if (compiler-backend-object-disp8? disp)
        (begin
          (compiler-backend-object-push-u8! out (+ 0x45 (* reg-code 8)))
          (compiler-backend-object-push-u8! out disp))
        (begin
          (compiler-backend-object-push-u8! out (+ 0x85 (* reg-code 8)))
          (compiler-backend-object-push-u32! out disp)))
      (compiler-backend-object-bytes-finish out))))

(define (compiler-backend-object-store-slot-bytes [var-id : i64] [reg : String]) : String
  (let
    [out : (Array u8) (make-array u8 0)]
    [disp : i64 (compiler-backend-object-slot-disp var-id)]
    [reg-code : i64 (compiler-backend-object-reg-low-code reg)]
    [rex : i64
      (+
        0x48
        (if (compiler-backend-object-reg-high? reg)
          4
          0))]
    (begin
      (compiler-backend-object-push-u8! out rex)
      (compiler-backend-object-push-u8! out 0x89)
      (if (compiler-backend-object-disp8? disp)
        (begin
          (compiler-backend-object-push-u8! out (+ 0x45 (* reg-code 8)))
          (compiler-backend-object-push-u8! out disp))
        (begin
          (compiler-backend-object-push-u8! out (+ 0x85 (* reg-code 8)))
          (compiler-backend-object-push-u32! out disp)))
      (compiler-backend-object-bytes-finish out))))

(define (compiler-backend-object-mov-imm32-reg-bytes
  [value : i64]
  [reg : String]) : String
  (let
    [out : (Array u8) (make-array u8 0)]
    [reg-code : i64 (compiler-backend-object-reg-low-code reg)]
    [rex : i64
      (+
        0x48
        (if (compiler-backend-object-reg-high? reg)
          1
          0))]
    (begin
      (compiler-backend-object-push-u8! out rex)
      (compiler-backend-object-push-u8! out 0xc7)
      (compiler-backend-object-push-u8! out (+ 0xc0 reg-code))
      (compiler-backend-object-push-u32! out value)
      (compiler-backend-object-bytes-finish out))))

(define (compiler-backend-object-mov-reg-reg-bytes
  [src : String]
  [dst : String]) : String
  (if (string-eq src dst)
    ""
    (let
      [out : (Array u8) (make-array u8 0)]
      [src-code : i64 (compiler-backend-object-reg-low-code src)]
      [dst-code : i64 (compiler-backend-object-reg-low-code dst)]
      [rex : i64
        (+
          0x48
          (+
            (if (compiler-backend-object-reg-high? src)
              4
              0)
            (if (compiler-backend-object-reg-high? dst)
              1
              0)))]
      (begin
        (compiler-backend-object-push-u8! out rex)
        (compiler-backend-object-push-u8! out 0x89)
        (compiler-backend-object-push-u8!
          out
          (+ 0xc0 (+ (* src-code 8) dst-code)))
        (compiler-backend-object-bytes-finish out)))))

(define (compiler-backend-object-prologue-bytes [frame-size : i64]) : String
  (let
    [out : (Array u8) (make-array u8 0)]
    (begin
      (compiler-backend-object-push-u8! out 0x55)
      (compiler-backend-object-push-u8! out 0x48)
      (compiler-backend-object-push-u8! out 0x89)
      (compiler-backend-object-push-u8! out 0xe5)
      (if (= frame-size 0)
        unit
        (if (<= frame-size 127)
          (begin
            (compiler-backend-object-push-u8! out 0x48)
            (compiler-backend-object-push-u8! out 0x83)
            (compiler-backend-object-push-u8! out 0xec)
            (compiler-backend-object-push-u8! out frame-size))
          (begin
            (compiler-backend-object-push-u8! out 0x48)
            (compiler-backend-object-push-u8! out 0x81)
            (compiler-backend-object-push-u8! out 0xec)
            (compiler-backend-object-push-u32! out frame-size))))
      (compiler-backend-object-bytes-finish out))))

(define (compiler-backend-object-leave-ret-bytes) : String
  (compiler-backend-object-bytes-from-hex "c9c3"))

(define (compiler-backend-object-leave-bytes) : String
  (compiler-backend-object-bytes-from-hex "c9"))

(define (compiler-backend-object-load-value-to-reg
  [parts : CompilerBackendObjectParts]
  [site : String]
  [value : CompilerIrValue]
  [reg : String]) : CompilerBackendObjectParts
  (match value
    [(IrValueVar id)
      (compiler-backend-object-add-nonempty-bytes
        parts
        (compiler-backend-object-load-slot-bytes id reg))]
    [(IrValueI64 n)
      (compiler-backend-object-add-nonempty-bytes
        parts
        (compiler-backend-object-mov-imm32-reg-bytes n reg))]
    [(IrValueBool b)
      (compiler-backend-object-add-nonempty-bytes
        parts
        (compiler-backend-object-mov-imm32-reg-bytes
          (if b
            1
            0)
          reg))]
    [(IrValueChar c)
      (compiler-backend-object-add-nonempty-bytes
        parts
        (compiler-backend-object-mov-imm32-reg-bytes
          (compiler-backend-char-code c)
          reg))]
    [(IrValueUnit)
      (compiler-backend-object-add-nonempty-bytes
        parts
        (compiler-backend-object-mov-imm32-reg-bytes 0 reg))]
    [(IrValueGlobal _)
      (compiler-backend-object-add-nonempty-bytes
        (compiler-backend-object-value-ref parts site value)
        (compiler-backend-object-mov-reg-reg-bytes "%rax" reg))]
    [(IrValueGlobalAddr _)
      (compiler-backend-object-add-nonempty-bytes
        (compiler-backend-object-value-ref parts site value)
        (compiler-backend-object-mov-reg-reg-bytes "%rax" reg))]
    [(IrValueString _)
      (compiler-backend-object-add-nonempty-bytes
        (compiler-backend-object-value-ref parts site value)
        (compiler-backend-object-mov-reg-reg-bytes "%rax" reg))]
    [(IrValueBytes _)
      (compiler-backend-object-add-nonempty-bytes
        (compiler-backend-object-value-ref parts site value)
        (compiler-backend-object-mov-reg-reg-bytes "%rax" reg))]
    [(IrValueFunction _)
      (compiler-backend-object-add-nonempty-bytes
        (compiler-backend-object-value-ref parts site value)
        (compiler-backend-object-mov-reg-reg-bytes "%rax" reg))]
    [(IrValueF64 _)
      (compiler-backend-object-add-nonempty-bytes
        (compiler-backend-object-value-ref parts site value)
        (compiler-backend-object-mov-reg-reg-bytes "%rax" reg))]))

(define (compiler-backend-object-store-reg-to-var
  [parts : CompilerBackendObjectParts]
  [dst : i64]
  [reg : String]) : CompilerBackendObjectParts
  (compiler-backend-object-add-nonempty-bytes
    parts
    (compiler-backend-object-store-slot-bytes dst reg)))

(define (compiler-backend-object-move-value-to-var
  [parts : CompilerBackendObjectParts]
  [site : String]
  [dst : i64]
  [src : CompilerIrValue]) : CompilerBackendObjectParts
  (compiler-backend-object-store-reg-to-var
    (compiler-backend-object-load-value-to-reg parts site src "%rax")
    dst
    "%rax"))

(define (compiler-backend-object-binop-bytes [op : CompilerIrBinOp]) : String
  (match op
    [(IrBinAdd) (compiler-backend-object-bytes-from-hex "4c01c0")]
    [(IrBinSub) (compiler-backend-object-bytes-from-hex "4c29c0")]
    [(IrBinMul) (compiler-backend-object-bytes-from-hex "490fafc0")]
    [(IrBinEq) (compiler-backend-object-bytes-from-hex "4c39c00f94c0480fb6c0")]
    [(IrBinNe) (compiler-backend-object-bytes-from-hex "4c39c00f95c0480fb6c0")]
    [(IrBinLt) (compiler-backend-object-bytes-from-hex "4c39c00f9cc0480fb6c0")]
    [(IrBinLe) (compiler-backend-object-bytes-from-hex "4c39c00f9ec0480fb6c0")]
    [(IrBinGt) (compiler-backend-object-bytes-from-hex "4c39c00f9fc0480fb6c0")]
    [(IrBinGe) (compiler-backend-object-bytes-from-hex "4c39c00f9dc0480fb6c0")]
    [(IrBinAnd) (compiler-backend-object-bytes-from-hex "4c21c0")]
    [(IrBinOr) (compiler-backend-object-bytes-from-hex "4c09c0")]
    [(IrBinBitAnd) (compiler-backend-object-bytes-from-hex "4c21c0")]
    [(IrBinBitOr) (compiler-backend-object-bytes-from-hex "4c09c0")]
    [(IrBinBitXor) (compiler-backend-object-bytes-from-hex "4c31c0")]
    [_ ""]))

(define (compiler-backend-object-binop
  [parts : CompilerBackendObjectParts]
  [site : String]
  [dst : i64]
  [op : CompilerIrBinOp]
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [ty : AstType]) : CompilerBackendObjectParts
  (let
    [op-bytes : String (compiler-backend-object-binop-bytes op)]
    (if (or (= (string-length op-bytes) 0) (compiler-backend-float-type? ty))
      (compiler-backend-object-value-ref
        (compiler-backend-object-value-ref parts site lhs)
        site
        rhs)
      (compiler-backend-object-store-reg-to-var
        (compiler-backend-object-add-nonempty-bytes
          (compiler-backend-object-load-value-to-reg
            (compiler-backend-object-load-value-to-reg parts site lhs "%rax")
            site
            rhs
            "%r8")
          op-bytes)
        dst
        "%rax"))))

(define (compiler-backend-object-call-arg-reg [index : i64]) : String
  (match (compiler-backend-arg-reg index)
    [(OkBackendReg reg) reg]
    [(ErrBackendReg _) "%rax"]))

(define (compiler-backend-object-call-arg-moves
  [parts : CompilerBackendObjectParts]
  [site : String]
  [args : CompilerIrCallArgs]
  [index : i64]) : CompilerBackendObjectParts
  (if (>= index (compiler-backend-call-args-count args))
    parts
    (if (>= index 6)
      parts
      (compiler-backend-object-call-arg-moves
        (compiler-backend-object-load-value-to-reg
          parts
          site
          (compiler-backend-call-arg-at args index)
          (compiler-backend-object-call-arg-reg index))
        site
        args
        (+ index 1)))))

(define (compiler-backend-object-param-spills
  [parts : CompilerBackendObjectParts]
  [params : CompilerIrParamList]
  [int-index : i64]) : CompilerBackendObjectParts
  (match params
    [(IrParamNil) parts]
    [(IrParamCons param rest)
      (match param
        [(IrParam _ ty var-id)
          (if (compiler-backend-float-type? ty)
            (compiler-backend-object-param-spills
              parts
              (box-get rest)
              int-index)
            (if (>= int-index 6)
              (compiler-backend-object-param-spills
                parts
                (box-get rest)
                (+ int-index 1))
              (compiler-backend-object-param-spills
                (compiler-backend-object-store-reg-to-var
                  parts
                  var-id
                  (compiler-backend-object-call-arg-reg int-index))
                (box-get rest)
                (+ int-index 1))))])]))

(define (compiler-backend-object-instr
  [parts : CompilerBackendObjectParts]
  [function : String]
  [label-scope : String]
  [instr : CompilerIrInstr]
  [plan : CompilerBackendRuntimePlan]
  [program-index : CompilerBackendProgramIndex]) : CompilerBackendObjectParts
  (match instr
    [(IrInstrMov dst src _)
      (compiler-backend-object-move-value-to-var parts function dst src)]
    [(IrInstrBinOp dst op lhs rhs ty)
      (compiler-backend-object-binop parts function dst op lhs rhs ty)]
    [(IrInstrUnOp _ op src ty)
      (let
        [with-src : CompilerBackendObjectParts
          (compiler-backend-object-value-ref parts function src)]
        (match op
          [(IrUnNeg)
            (if (compiler-backend-f64-type? ty)
              (compiler-backend-object-add-rip-instr
                with-src
                function
                (ObjectRelocRipValue)
                (compiler-backend-f64-sign-bit-label)
                (ObjectX64XorpdRip (compiler-backend-f64-sign-bit-label)))
              with-src)]
          [_ with-src]))]
    [(IrInstrCall dst name args _)
      (let
        [target : String
          (compiler-backend-call-symbol-index name plan program-index)]
        (compiler-backend-object-store-reg-to-var
          (compiler-backend-object-add-text
            (compiler-backend-object-add-text-relocation
              (compiler-backend-object-call-arg-moves parts function args 0)
              function
              (ObjectRelocCall)
              target)
            (ObjectX64Call target))
          dst
          "%rax"))]
    [(IrInstrCallIndirect _ callee args _)
      (compiler-backend-object-call-args
        (compiler-backend-object-value-ref parts function callee)
        function
        args
        0)]
    [(IrInstrCallIndirectC _ callee args _)
      (compiler-backend-object-call-args
        (compiler-backend-object-value-ref parts function callee)
        function
        args
        0)]
    [(IrInstrCallCAbiStoreResult base name args _)
      (let
        [target : String
          (compiler-backend-call-symbol-index name plan program-index)]
        (compiler-backend-object-add-text
          (compiler-backend-object-add-text-relocation
            (compiler-backend-object-call-args
              (compiler-backend-object-value-ref parts function base)
              function
              args
              0)
            function
            (ObjectRelocCall)
            target)
          (ObjectX64Call target)))]
    [(IrInstrCallIndirectCAbiStoreResult base callee args _)
      (compiler-backend-object-call-args
        (compiler-backend-object-value-ref
          (compiler-backend-object-value-ref parts function base)
          function
          callee)
        function
        args
        0)]
    [(IrInstrTailCall name args _)
      (let
        [target : String
          (compiler-backend-call-symbol-index name plan program-index)]
        (compiler-backend-object-add-text
          (compiler-backend-object-add-text-relocation
            (compiler-backend-object-add-nonempty-bytes
              (compiler-backend-object-call-arg-moves parts function args 0)
              (compiler-backend-object-leave-bytes))
            function
            (ObjectRelocTailCall)
            target)
          (ObjectX64TailCall target)))]
    [(IrInstrStore name value _)
      (let
        [symbol : String (compiler-backend-user-symbol name)]
        (compiler-backend-object-add-text
          (compiler-backend-object-add-text-relocation
            (compiler-backend-object-value-ref parts function value)
            function
            (ObjectRelocRipAddress)
            symbol)
          (ObjectX64StoreRip symbol)))]
    [(IrInstrJump target)
      (let
        [symbol : String (compiler-backend-asm-label label-scope target)]
        (compiler-backend-object-add-text
          (compiler-backend-object-add-text-relocation
            parts
            function
            (ObjectRelocBranch)
            symbol)
          (ObjectX64Jump symbol)))]
    [(IrInstrBranch cond true-label false-label)
      (let
        [true-symbol : String
          (compiler-backend-asm-label label-scope true-label)]
        [false-symbol : String
          (compiler-backend-asm-label label-scope false-label)]
        (compiler-backend-object-add-text
          (compiler-backend-object-add-text-relocation
            (compiler-backend-object-add-text-relocation
              (compiler-backend-object-value-ref parts function cond)
              function
              (ObjectRelocBranch)
              true-symbol)
            function
            (ObjectRelocBranch)
            false-symbol)
          (ObjectX64Branch true-symbol false-symbol)))]
    [(IrInstrReturn value)
      (compiler-backend-object-add-nonempty-bytes
        (match value
          [(IrNoValue) parts]
          [(IrSomeValue inner)
            (compiler-backend-object-load-value-to-reg
              parts
              function
              inner
              "%rax")])
        (compiler-backend-object-leave-ret-bytes))]
    [(IrInstrPhi _ inputs _)
      (compiler-backend-object-phi-inputs parts function inputs)]
    [(IrInstrGep _ base offset _)
      (compiler-backend-object-value-ref
        (compiler-backend-object-value-ref parts function base)
        function
        offset)]
    [(IrInstrLoad _ src _)
      (compiler-backend-object-value-ref parts function src)]
    [(IrInstrStorePtr dst src _)
      (compiler-backend-object-value-ref
        (compiler-backend-object-value-ref parts function dst)
        function
        src)]
    [(IrInstrCopyBytes dst src _)
      (compiler-backend-object-value-ref
        (compiler-backend-object-value-ref parts function dst)
        function
        src)]
    [(IrInstrBoundsCheck index length _)
      (compiler-backend-object-value-ref
        (compiler-backend-object-value-ref parts function index)
        function
        length)]
    [(IrInstrCast _ src _ _)
      (compiler-backend-object-value-ref parts function src)]
    [(IrInstrBitcast _ src _ _)
      (compiler-backend-object-value-ref parts function src)]
    [(IrInstrSplat _ value _ _)
      (compiler-backend-object-value-ref parts function value)]
    [(IrInstrVectorBinOp _ _ lhs rhs _ _)
      (compiler-backend-object-value-ref
        (compiler-backend-object-value-ref parts function lhs)
        function
        rhs)]
    [(IrInstrVectorReduce _ _ src _ _)
      (compiler-backend-object-value-ref parts function src)]
    [(IrInstrVectorCompare _ _ lhs rhs _ _)
      (compiler-backend-object-value-ref
        (compiler-backend-object-value-ref parts function lhs)
        function
        rhs)]
    [(IrInstrMaskBinOp _ _ lhs rhs _)
      (compiler-backend-object-value-ref
        (compiler-backend-object-value-ref parts function lhs)
        function
        rhs)]
    [(IrInstrMaskNot _ src _)
      (compiler-backend-object-value-ref parts function src)]
    [(IrInstrMaskReduce _ _ src _)
      (compiler-backend-object-value-ref parts function src)]
    [(IrInstrSelect _ mask on-true on-false _ _)
      (compiler-backend-object-value-ref
        (compiler-backend-object-value-ref
          (compiler-backend-object-value-ref parts function mask)
          function
          on-true)
        function
        on-false)]
    [(IrInstrVectorLoad _ base index _ _)
      (compiler-backend-object-value-ref
        (compiler-backend-object-value-ref parts function base)
        function
        index)]
    [(IrInstrVectorStore base index value _ _)
      (compiler-backend-object-value-ref
        (compiler-backend-object-value-ref
          (compiler-backend-object-value-ref parts function base)
          function
          index)
        function
        value)]
    [(IrInstrPredicatedStore base index value mask _ _)
      (compiler-backend-object-value-ref
        (compiler-backend-object-value-ref
          (compiler-backend-object-value-ref
            (compiler-backend-object-value-ref parts function base)
            function
            index)
          function
          value)
        function
        mask)]
    [(IrInstrPredicatedLoad _ base index mask _ _)
      (compiler-backend-object-value-ref
        (compiler-backend-object-value-ref
          (compiler-backend-object-value-ref parts function base)
          function
          index)
        function
        mask)]
    [(IrInstrTailMask _ index length _)
      (compiler-backend-object-value-ref
        (compiler-backend-object-value-ref parts function index)
        function
        length)]
    [(IrInstrCpuId _ leaf subleaf _)
      (compiler-backend-object-value-ref
        (compiler-backend-object-value-ref parts function leaf)
        function
        subleaf)]
    [(IrInstrXgetbv _ index)
      (compiler-backend-object-value-ref parts function index)]
    [(IrInstrSyscall _ args)
      (compiler-backend-object-call-args parts function args 0)]
    [(IrInstrPack _ words _)
      (compiler-backend-object-value-list-ref parts function words)]
    [(IrInstrWord _ src _ _)
      (compiler-backend-object-value-ref parts function src)]
    [(IrInstrTailCallIndirect callee args _)
      (compiler-backend-object-call-args
        (compiler-backend-object-value-ref parts function callee)
        function
        args
        0)]
    ;; Operand-free instructions and raw address-of emit no object references.
    [(IrInstrAlloc _ _) parts]
    [(IrInstrAddrOf _ _) parts]
    [(IrInstrLaneId _ _ _) parts]
    [(IrInstrEntryArgc _) parts]
    [(IrInstrEntryArgv _) parts]
    [(IrInstrEntryEnvp _) parts]))

(define (compiler-backend-object-instr-seq
  [parts : CompilerBackendObjectParts]
  [function : String]
  [label-scope : String]
  [instrs : CompilerIrInstrSeq]
  [plan : CompilerBackendRuntimePlan]
  [program-index : CompilerBackendProgramIndex]
  [index : i64]) : CompilerBackendObjectParts
  (if (>= index (compiler-ir-instr-seq-count instrs))
    parts
    (compiler-backend-object-instr-seq
      (compiler-backend-object-instr
        parts
        function
        label-scope
        (compiler-ir-instr-seq-ref instrs index)
        plan
        program-index)
      function
      label-scope
      instrs
      plan
      program-index
      (+ index 1))))

(define (compiler-backend-object-blocks
  [parts : CompilerBackendObjectParts]
  [function-symbol : String]
  [label-scope : String]
  [blocks : CompilerIrBlockList]
  [plan : CompilerBackendRuntimePlan]
  [program-index : CompilerBackendProgramIndex]) : CompilerBackendObjectParts
  (match blocks
    [(IrBlockNil) parts]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label instrs)
          (let
            [block-label : String
              (compiler-backend-asm-label label-scope label)]
            (compiler-backend-object-blocks
              (compiler-backend-object-instr-seq
                (compiler-backend-object-add-text
                  (compiler-backend-object-symbol-local-section
                    parts
                    block-label
                    (ObjectSectionText)
                    (ObjectSymbolFunction))
                  (ObjectX64Label block-label))
                function-symbol
                label-scope
                instrs
                plan
                program-index
                0)
              function-symbol
              label-scope
              (box-get rest)
              plan
              program-index))])]
    [(IrBlockArray seq)
      (compiler-backend-object-blocks
        parts
        function-symbol
        label-scope
        (compiler-ir-block-seq-to-list seq)
        plan
        program-index)]))

(define (compiler-backend-object-functions
  [parts : CompilerBackendObjectParts]
  [functions : CompilerIrFunctionList]
  [plan : CompilerBackendRuntimePlan]
  [program-index : CompilerBackendProgramIndex]) : CompilerBackendObjectParts
  (match functions
    [(IrFunctionNil) parts]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction name params _ vars blocks)
          (let
            [symbol : String
              (compiler-backend-function-symbol-index program-index name)]
            [label-scope : String
              (compiler-backend-function-label-scope program-index name)]
            (compiler-backend-object-functions
              (compiler-backend-object-blocks
                (compiler-backend-object-param-spills
                  (compiler-backend-object-add-nonempty-bytes
                    (compiler-backend-object-add-text
                      (compiler-backend-object-symbol-export-section
                        parts
                        symbol
                        (ObjectSectionText)
                        (ObjectSymbolFunction))
                      (ObjectX64Label symbol))
                    (compiler-backend-object-prologue-bytes
                      (compiler-backend-frame-size vars)))
                  params
                  0)
                symbol
                label-scope
                blocks
                plan
                program-index)
              (box-get rest)
              plan
              program-index))])]
    [(IrFunctionArray seq)
      (compiler-backend-object-functions
        parts
        (compiler-ir-function-seq-to-list seq)
        plan
        program-index)]))

(define (compiler-backend-object-global-value
  [parts : CompilerBackendObjectParts]
  [site : String]
  [value : CompilerIrValue]) : CompilerBackendObjectParts
  (match value
    [(IrValueI64 n) (compiler-backend-object-add-data parts (ObjectDataI64 n))]
    [(IrValueBool b)
      (compiler-backend-object-add-data
        parts
        (ObjectDataI64
          (if b
            1
            0)))]
    [(IrValueChar c)
      (compiler-backend-object-add-data
        parts
        (ObjectDataI64 (compiler-backend-char-code c)))]
    [(IrValueUnit) (compiler-backend-object-add-data parts (ObjectDataI64 0))]
    [(IrValueF64 text)
      (compiler-backend-object-add-data parts (ObjectDataF64 text))]
    [(IrValueString text)
      (let
        [symbol : String (compiler-backend-string-fat-label text)]
        (compiler-backend-object-add-data
          (compiler-backend-object-add-data-relocation
            parts
            site
            (ObjectRelocAbs64)
            symbol)
          (ObjectDataSymbolAddress symbol)))]
    [(IrValueBytes text)
      (let
        [symbol : String (compiler-backend-bytes-fat-label text)]
        (compiler-backend-object-add-data
          (compiler-backend-object-add-data-relocation
            parts
            site
            (ObjectRelocAbs64)
            symbol)
          (ObjectDataSymbolAddress symbol)))]
    [(IrValueGlobal name)
      (let
        [symbol : String (compiler-backend-user-symbol name)]
        (compiler-backend-object-add-data
          (compiler-backend-object-add-data-relocation
            parts
            site
            (ObjectRelocAbs64)
            symbol)
          (ObjectDataSymbolAddress symbol)))]
    [(IrValueGlobalAddr name)
      (let
        [symbol : String (compiler-backend-user-symbol name)]
        (compiler-backend-object-add-data
          (compiler-backend-object-add-data-relocation
            parts
            site
            (ObjectRelocAbs64)
            symbol)
          (ObjectDataSymbolAddress symbol)))]
    [(IrValueFunction name)
      (let
        [symbol : String (compiler-backend-closure-descriptor-label name)]
        (compiler-backend-object-add-data
          (compiler-backend-object-add-data-relocation
            parts
            site
            (ObjectRelocAbs64)
            symbol)
          (ObjectDataSymbolAddress symbol)))]
    [_ parts]))

(define (compiler-backend-object-globals
  [parts : CompilerBackendObjectParts]
  [target : CompilerBackendTarget]
  [globals : CompilerIrGlobalList]) : CompilerBackendObjectParts
  (match globals
    [(IrGlobalNil) parts]
    [(IrGlobalCons global rest)
      (match global
        [(IrGlobal name ty value)
          (let
            [symbol : String (compiler-backend-user-symbol name)]
            (compiler-backend-object-globals
              (if (compiler-backend-runtime-global? ty value)
                (compiler-backend-object-add-bss
                  (compiler-backend-object-add-bss
                    (compiler-backend-object-symbol-export-section
                      parts
                      symbol
                      (ObjectSectionBss)
                      (ObjectSymbolData))
                    (ObjectDataLabel symbol))
                  (ObjectDataZero 8))
                (compiler-backend-object-global-value
                  (compiler-backend-object-add-data
                    (compiler-backend-object-symbol-export-section
                      parts
                      symbol
                      (ObjectSectionData)
                      (ObjectSymbolData))
                    (ObjectDataLabel symbol))
                  symbol
                  value))
              target
              (box-get rest)))])]))

(define (compiler-backend-object-strings
  [parts : CompilerBackendObjectParts]
  [strings : BackendStringList]) : CompilerBackendObjectParts
  (match strings
    [(BackendStringNil) parts]
    [(BackendStringCons text rest)
      (let
        [data-symbol : String (compiler-backend-string-data-label text)]
        [fat-symbol : String (compiler-backend-string-fat-label text)]
        (compiler-backend-object-strings
          (compiler-backend-object-add-rodata
            (compiler-backend-object-add-rodata
              (compiler-backend-object-add-rodata
                (compiler-backend-object-add-rodata-relocation
                  (compiler-backend-object-add-rodata
                    (compiler-backend-object-symbol-local-section
                      (compiler-backend-object-add-rodata
                        (compiler-backend-object-add-rodata
                          (compiler-backend-object-symbol-local-section
                            parts
                            data-symbol
                            (ObjectSectionRodata)
                            (ObjectSymbolData))
                          (ObjectDataLabel data-symbol))
                        (ObjectDataString text))
                      fat-symbol
                      (ObjectSectionRodata)
                      (ObjectSymbolData))
                    (ObjectDataAlign 8))
                  fat-symbol
                  (ObjectRelocAbs64)
                  data-symbol)
                (ObjectDataLabel fat-symbol))
              (ObjectDataSymbolAddress data-symbol))
            (ObjectDataI64 (string-length text)))
          (box-get rest)))]))

(define (compiler-backend-object-bytes
  [parts : CompilerBackendObjectParts]
  [items : BackendStringList]) : CompilerBackendObjectParts
  (match items
    [(BackendStringNil) parts]
    [(BackendStringCons bytes rest)
      (let
        [data-symbol : String (compiler-backend-bytes-data-label bytes)]
        [fat-symbol : String (compiler-backend-bytes-fat-label bytes)]
        (compiler-backend-object-bytes
          (compiler-backend-object-add-data
            (compiler-backend-object-add-data
              (compiler-backend-object-add-data
                (compiler-backend-object-add-data
                  (compiler-backend-object-add-data-relocation
                    (compiler-backend-object-add-data
                      (compiler-backend-object-add-data
                        (compiler-backend-object-add-data
                          (compiler-backend-object-symbol-local-section
                            (compiler-backend-object-symbol-local-section
                              parts
                              data-symbol
                              (ObjectSectionData)
                              (ObjectSymbolData))
                            fat-symbol
                            (ObjectSectionData)
                            (ObjectSymbolData))
                          (ObjectDataAlign 8))
                        (ObjectDataLabel data-symbol))
                      (if (= (string-length bytes) 0)
                        (ObjectDataZero 1)
                        (ObjectDataBytes bytes)))
                    fat-symbol
                    (ObjectRelocAbs64)
                    data-symbol)
                  (ObjectDataAlign 8))
                (ObjectDataLabel fat-symbol))
              (ObjectDataSymbolAddress data-symbol))
            (ObjectDataI64 (string-length bytes)))
          (box-get rest)))]))

(define (compiler-backend-object-floats
  [parts : CompilerBackendObjectParts]
  [floats : BackendStringList]) : CompilerBackendObjectParts
  (match floats
    [(BackendStringNil) parts]
    [(BackendStringCons text rest)
      (let
        [symbol : String (compiler-backend-f64-label text)]
        (compiler-backend-object-floats
          (compiler-backend-object-add-rodata
            (compiler-backend-object-add-rodata
              (compiler-backend-object-symbol-local-section
                parts
                symbol
                (ObjectSectionRodata)
                (ObjectSymbolData))
              (ObjectDataLabel symbol))
            (ObjectDataF64 text))
          (box-get rest)))]))

(define (compiler-backend-object-f64-sign-bit
  [parts : CompilerBackendObjectParts]
  [enabled : bool]) : CompilerBackendObjectParts
  (if enabled
    (let
      [symbol : String (compiler-backend-f64-sign-bit-label)]
      (compiler-backend-object-add-rodata
        (compiler-backend-object-add-rodata
          (compiler-backend-object-add-rodata
            (compiler-backend-object-add-rodata
              (compiler-backend-object-symbol-local-section
                parts
                symbol
                (ObjectSectionRodata)
                (ObjectSymbolData))
              (ObjectDataAlign 16))
            (ObjectDataLabel symbol))
          (ObjectDataI64 -9223372036854775808))
        (ObjectDataI64 0)))
    parts))

(define (compiler-backend-object-closure-descriptors
  [parts : CompilerBackendObjectParts]
  [names : BackendStringList]
  [program-index : CompilerBackendProgramIndex]) : CompilerBackendObjectParts
  (match names
    [(BackendStringNil) parts]
    [(BackendStringCons name rest)
      (let
        [descriptor : String (compiler-backend-closure-descriptor-label name)]
        [entry : String (compiler-backend-closure-entry-label name)]
        (compiler-backend-object-closure-descriptors
          (match (compiler-backend-index-signature program-index name)
            [(CompilerBackendSomeSignature _ _)
              (compiler-backend-object-add-rodata
                (compiler-backend-object-add-rodata
                  (compiler-backend-object-add-rodata-relocation
                    (compiler-backend-object-add-rodata
                      (compiler-backend-object-add-rodata
                        (compiler-backend-object-symbol-local-section
                          (compiler-backend-object-symbol-local-section
                            parts
                            descriptor
                            (ObjectSectionRodata)
                            (ObjectSymbolData))
                          entry
                          (ObjectSectionText)
                          (ObjectSymbolFunction))
                        (ObjectDataAlign 8))
                      (ObjectDataLabel descriptor))
                    descriptor
                    (ObjectRelocAbs64)
                    entry)
                  (ObjectDataSymbolAddress entry))
                (ObjectDataI64 0))]
            [(CompilerBackendNoSignature) parts])
          (box-get rest)
          program-index))]))

(define (compiler-backend-object-externs
  [parts : CompilerBackendObjectParts]
  [externs : CompilerIrExternList]
  [plan : CompilerBackendRuntimePlan]) : CompilerBackendObjectParts
  (match externs
    [(IrExternNil) parts]
    [(IrExternCons item rest)
      (match item
        [(IrExtern _ _ _ link-symbol _ provided)
          (compiler-backend-object-externs
            (if provided
              parts
              (compiler-backend-object-symbol-extern
                parts
                (compiler-backend-link-symbol link-symbol plan)
                (ObjectSymbolFunction)))
            (box-get rest)
            plan)])]))

(define (compiler-backend-object-runtime-symbols-list) : BackendStringList
  (let
    [symbols : BackendStringList BackendStringNil]
    (begin
      (set!
        symbols
        (compiler-backend-string-cons "tl_atomic_i32_fetch_add_ptr" symbols))
      (set!
        symbols
        (compiler-backend-string-cons "tl_atomic_i32_add_ptr" symbols))
      (set!
        symbols
        (compiler-backend-string-cons "tl_atomic_i32_store_ptr" symbols))
      (set!
        symbols
        (compiler-backend-string-cons "tl_atomic_i32_load_ptr" symbols))
      (set!
        symbols
        (compiler-backend-string-cons "tl_atomic_i64_fetch_add_ptr" symbols))
      (set!
        symbols
        (compiler-backend-string-cons "tl_atomic_i64_add_ptr" symbols))
      (set!
        symbols
        (compiler-backend-string-cons "tl_atomic_i64_store_ptr" symbols))
      (set!
        symbols
        (compiler-backend-string-cons "tl_atomic_i64_load_ptr" symbols))
      (set! symbols (compiler-backend-string-cons "tl_shift_abort" symbols))
      (set! symbols (compiler-backend-string-cons "tl_div_abort" symbols))
      (set! symbols (compiler-backend-string-cons "tl_region_reset" symbols))
      (set! symbols (compiler-backend-string-cons "tl_region_mark" symbols))
      (set! symbols (compiler-backend-string-cons "tl_alloc" symbols))
      symbols)))

(define (compiler-backend-object-runtime-symbols
  [parts : CompilerBackendObjectParts]
  [plan : CompilerBackendRuntimePlan]
  [names : BackendStringList]) : CompilerBackendObjectParts
  (match names
    [(BackendStringNil) parts]
    [(BackendStringCons name rest)
      (compiler-backend-object-runtime-symbols
        (if (compiler-backend-plan-provides? plan name)
          (compiler-backend-object-symbol-local-section
            parts
            name
            (ObjectSectionText)
            (ObjectSymbolRuntime))
          parts)
        plan
        (box-get rest))]))

(define (compiler-backend-object-hex-value [c : char]) : i64
  (cond
    [(and (>= c #0') (<= c #9')) (- (cast c : i64) (cast #0' : i64))]
    [(and (>= c #a') (<= c #f')) (+ 10 (- (cast c : i64) (cast #a' : i64)))]
    [(and (>= c #A') (<= c #F')) (+ 10 (- (cast c : i64) (cast #A' : i64)))]
    [else 0]))

(define (compiler-backend-object-bytes-from-hex [hex : String]) : String
  (let
    [out : (Array u8) (make-array u8 0)]
    [i : i64 0]
    [n : i64 (string-length hex)]
    (begin
      (while (< (+ i 1) n)
        (let
          [hi : i64 (compiler-backend-object-hex-value (string-ref hex i))]
          [lo : i64
            (compiler-backend-object-hex-value (string-ref hex (+ i 1)))]
          (begin
            (array-push! out (cast (+ (* hi 16) lo) : u8))
            (set! i (+ i 2)))))
      (unsafe
        (string-from-bytes
          (ptr-cast (array-data out) : (Ptr u8))
          (array-length out))))))

(define (compiler-backend-object-windows-chkstk-bytes) : String
  (compiler-backend-object-bytes-from-hex
    "51504889c1488d4424104881f9001000007212482d00100000c600004881e900100000ebe54829c8c600005859c3"))

(define (compiler-backend-object-windows-setup-pre-getcmd-bytes) : String
  (compiler-backend-object-bytes-from-hex "554889e55341544155415641574883ec28"))

(define (compiler-backend-object-windows-setup-after-getcmd-bytes) : String
  (compiler-backend-object-bytes-from-hex
    "4889c34d31e442803c2300740549ffc4ebf4498d4c24014883ec20"))

(define (compiler-backend-object-windows-setup-after-boot1-bytes) : String
  (compiler-backend-object-bytes-from-hex
    "4883c4204989c54831c94c39e17d0d8a040b4188440d0048ffc1ebee43c64425000048c7c1080800004883ec20"))

(define (compiler-backend-object-windows-setup-after-boot2-pre-store-bytes) : String
  (compiler-backend-object-bytes-from-hex
    "4883c4204989c64d31ff4c89eb8a033c0074513c20750548ffc3ebf14981ffff0000007d3f4b891cfe49ffc74531c98a033c00742f3c2275154183f1014889d98a4101880148ffc13c0075f4ebe13c20750d4585c97508c6030048ffc3ebae48ffc3ebcb4bc704fe00000000"))

(define (compiler-backend-object-windows-setup-epilogue-bytes) : String
  (compiler-backend-object-bytes-from-hex "4883c428415f415e415d415c5b5dc3"))

(define (compiler-backend-object-windows-add-rdx-rax-bytes) : String
  (compiler-backend-object-bytes-from-hex "4801d0"))

(define (compiler-backend-object-windows-ret-bytes) : String
  (compiler-backend-object-bytes-from-hex "c3"))

(define (compiler-backend-object-windows-entry-gs-clear-bytes) : String
  (compiler-backend-object-bytes-from-hex "6548c704252800000000000000"))

(define (compiler-backend-object-windows-entry-xdata-bytes) : String
  (let
    [out : (Array u8) (make-array u8 0)]
    (begin
      ;; UNWIND_INFO: version 1, 4-byte prolog, one UWOP_ALLOC_SMALL(40).
      (array-push! out (cast 0x01 : u8))
      (array-push! out (cast 0x04 : u8))
      (array-push! out (cast 0x01 : u8))
      (array-push! out (cast 0x00 : u8))
      (array-push! out (cast 0x04 : u8))
      (array-push! out (cast 0x42 : u8))
      (array-push! out (cast 0x00 : u8))
      (array-push! out (cast 0x00 : u8))
      (unsafe
        (string-from-bytes (ptr-cast (array-data out) : (Ptr u8)) 8)))))

(define compiler-backend-object-windows-manifest-label : String
  ".L_tl_manifest")
(define compiler-backend-object-windows-rsrc-data-label : String
  ".L_tl_rsrc_data")
(define compiler-backend-object-windows-utf8-manifest : String
  "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\r\n<assembly xmlns=\"urn:schemas-microsoft-com:asm.v1\" manifestVersion=\"1.0\">\r\n  <application xmlns=\"urn:schemas-microsoft-com:asm.v3\">\r\n    <windowsSettings>\r\n      <activeCodePage xmlns=\"http://schemas.microsoft.com/SMI/2019/WindowsSettings\">UTF-8</activeCodePage>\r\n    </windowsSettings>\r\n  </application>\r\n</assembly>\r\n")

(define (compiler-backend-object-windows-manifest-resource-records) : CompilerObjectDataRecordList
  (compiler-object-data-list-dense-reversed
    (compiler-object-data-cons
      (ObjectDataLabel ".L_tl_manifest_end")
      (compiler-object-data-cons
        (ObjectDataBytes compiler-backend-object-windows-utf8-manifest)
        (compiler-object-data-cons
          (ObjectDataLabel compiler-backend-object-windows-manifest-label)
          (compiler-object-data-cons
            (ObjectDataAlign 4)
            (compiler-object-data-cons
              ;; Manifest size is 376 bytes (0x178), followed by codepage/reserved zeros.
              (ObjectDataBytes
                (compiler-backend-object-bytes-from-hex
                  "780100000000000000000000"))
              (compiler-object-data-cons
                (ObjectDataSymbolRva32
                  compiler-backend-object-windows-manifest-label)
                (compiler-object-data-cons
                  (ObjectDataLabel
                    compiler-backend-object-windows-rsrc-data-label)
                  (compiler-object-data-cons
                    (ObjectDataBytes
                      (compiler-backend-object-bytes-from-hex
                        "000000000000000000000000000001001800000018000080000000000000000000000000000001000100000030000080000000000000000000000000000001000904000048000000"))
                    (compiler-object-data-cons
                      (ObjectDataLabel ".L_tl_rsrc_base")
                      ObjectDataNil)))))))))))

(define (compiler-backend-object-add-windows-entry-data
  [parts : CompilerBackendObjectParts]) : CompilerBackendObjectParts
  (let
    [with-argc-symbol : CompilerBackendObjectParts
      (compiler-backend-object-symbol-local-section
        parts
        ".L_tl_argc"
        (ObjectSectionData)
        (ObjectSymbolData))]
    [with-argc : CompilerBackendObjectParts
      (compiler-backend-object-add-data
        (compiler-backend-object-add-data
          with-argc-symbol
          (ObjectDataLabel ".L_tl_argc"))
        (ObjectDataI64 0))]
    [with-argv-symbol : CompilerBackendObjectParts
      (compiler-backend-object-symbol-local-section
        with-argc
        ".L_tl_argv"
        (ObjectSectionData)
        (ObjectSymbolData))]
    [with-argv : CompilerBackendObjectParts
      (compiler-backend-object-add-data
        (compiler-backend-object-add-data
          with-argv-symbol
          (ObjectDataLabel ".L_tl_argv"))
        (ObjectDataI64 0))]
    [with-boot-off-symbol : CompilerBackendObjectParts
      (compiler-backend-object-symbol-local-section
        with-argv
        "tl_boot_off"
        (ObjectSectionBss)
        (ObjectSymbolData))]
    [with-boot-off : CompilerBackendObjectParts
      (compiler-backend-object-add-bss
        (compiler-backend-object-add-bss
          (compiler-backend-object-add-bss
            with-boot-off-symbol
            (ObjectDataAlign 8))
          (ObjectDataLabel "tl_boot_off"))
        (ObjectDataZero 8))]
    [with-boot-pool-symbol : CompilerBackendObjectParts
      (compiler-backend-object-symbol-local-section
        with-boot-off
        "tl_boot_pool"
        (ObjectSectionBss)
        (ObjectSymbolData))]
    (compiler-backend-object-add-bss
      (compiler-backend-object-add-bss
        with-boot-pool-symbol
        (ObjectDataLabel "tl_boot_pool"))
      (ObjectDataZero 524288))))

(define (compiler-backend-object-add-text-bytes
  [parts : CompilerBackendObjectParts]
  [bytes : String]) : CompilerBackendObjectParts
  (compiler-backend-object-add-text parts (ObjectX64Bytes bytes)))

(define (compiler-backend-object-add-call-instr
  [parts : CompilerBackendObjectParts]
  [site : String]
  [target : String]) : CompilerBackendObjectParts
  (compiler-backend-object-add-text
    (compiler-backend-object-add-text-relocation
      parts
      site
      (ObjectRelocCall)
      target)
    (ObjectX64Call target)))

(define (compiler-backend-object-linux-exit-bytes) : String
  (compiler-backend-object-bytes-from-hex "4889c748c7c03c0000000f05"))

(define (compiler-backend-object-add-linux-entry
  [parts : CompilerBackendObjectParts]) : CompilerBackendObjectParts
  (let
    [entry : String "_tl_start"]
    [with-symbol : CompilerBackendObjectParts
      (compiler-backend-object-symbol-export-section
        parts
        entry
        (ObjectSectionText)
        (ObjectSymbolFunction))]
    [with-label : CompilerBackendObjectParts
      (compiler-backend-object-add-text with-symbol (ObjectX64Label entry))]
    [with-main-call : CompilerBackendObjectParts
      (compiler-backend-object-add-call-instr with-label entry "main")]
    (compiler-backend-object-add-text-bytes
      with-main-call
      (compiler-backend-object-linux-exit-bytes))))

(define (compiler-backend-object-add-rip-instr
  [parts : CompilerBackendObjectParts]
  [site : String]
  [kind : CompilerObjectRelocationKind]
  [target : String]
  [instr : CompilerObjectX64Instr]) : CompilerBackendObjectParts
  (compiler-backend-object-add-text
    (compiler-backend-object-add-text-relocation parts site kind target)
    instr))

(define (compiler-backend-object-add-windows-runtime-text
  [parts : CompilerBackendObjectParts]) : CompilerBackendObjectParts
  (let
    [with-symbols : CompilerBackendObjectParts
      (compiler-backend-object-symbol-extern-once
        (compiler-backend-object-symbol-local-section
          (compiler-backend-object-symbol-local-section
            (compiler-backend-object-symbol-local-section
              parts
              "__chkstk"
              (ObjectSectionText)
              (ObjectSymbolRuntime))
            "tl_setup_argv"
            (ObjectSectionText)
            (ObjectSymbolRuntime))
          ".L_tl_boot_alloc"
          (ObjectSectionText)
          (ObjectSymbolRuntime))
        "GetCommandLineA"
        (ObjectSymbolFunction))]
    [with-chkstk-label : CompilerBackendObjectParts
      (compiler-backend-object-add-text
        with-symbols
        (ObjectX64Label "__chkstk"))]
    [with-chkstk : CompilerBackendObjectParts
      (compiler-backend-object-add-text-bytes
        with-chkstk-label
        (compiler-backend-object-windows-chkstk-bytes))]
    [with-setup-label : CompilerBackendObjectParts
      (compiler-backend-object-add-text
        with-chkstk
        (ObjectX64Label "tl_setup_argv"))]
    [with-setup-pre : CompilerBackendObjectParts
      (compiler-backend-object-add-text-bytes
        with-setup-label
        (compiler-backend-object-windows-setup-pre-getcmd-bytes))]
    [with-getcmd-call : CompilerBackendObjectParts
      (compiler-backend-object-add-call-instr
        with-setup-pre
        "tl_setup_argv"
        "GetCommandLineA")]
    [with-after-getcmd : CompilerBackendObjectParts
      (compiler-backend-object-add-text-bytes
        with-getcmd-call
        (compiler-backend-object-windows-setup-after-getcmd-bytes))]
    [with-boot1-call : CompilerBackendObjectParts
      (compiler-backend-object-add-call-instr
        with-after-getcmd
        "tl_setup_argv"
        ".L_tl_boot_alloc")]
    [with-after-boot1 : CompilerBackendObjectParts
      (compiler-backend-object-add-text-bytes
        with-boot1-call
        (compiler-backend-object-windows-setup-after-boot1-bytes))]
    [with-boot2-call : CompilerBackendObjectParts
      (compiler-backend-object-add-call-instr
        with-after-boot1
        "tl_setup_argv"
        ".L_tl_boot_alloc")]
    [with-after-boot2 : CompilerBackendObjectParts
      (compiler-backend-object-add-text-bytes
        with-boot2-call
        (compiler-backend-object-windows-setup-after-boot2-pre-store-bytes))]
    [with-argc-store : CompilerBackendObjectParts
      (compiler-backend-object-add-rip-instr
        with-after-boot2
        "tl_setup_argv"
        (ObjectRelocRipAddress)
        ".L_tl_argc"
        (ObjectX64StoreR15Rip ".L_tl_argc"))]
    [with-argv-store : CompilerBackendObjectParts
      (compiler-backend-object-add-rip-instr
        with-argc-store
        "tl_setup_argv"
        (ObjectRelocRipAddress)
        ".L_tl_argv"
        (ObjectX64StoreR14Rip ".L_tl_argv"))]
    [with-setup-end : CompilerBackendObjectParts
      (compiler-backend-object-add-text-bytes
        with-argv-store
        (compiler-backend-object-windows-setup-epilogue-bytes))]
    [with-boot-label : CompilerBackendObjectParts
      (compiler-backend-object-add-text
        with-setup-end
        (ObjectX64Label ".L_tl_boot_alloc"))]
    [with-boot-off-load : CompilerBackendObjectParts
      (compiler-backend-object-add-rip-instr
        with-boot-label
        ".L_tl_boot_alloc"
        (ObjectRelocRipValue)
        "tl_boot_off"
        (ObjectX64LoadRip "tl_boot_off"))]
    [with-boot-pool-lea : CompilerBackendObjectParts
      (compiler-backend-object-add-rip-instr
        with-boot-off-load
        ".L_tl_boot_alloc"
        (ObjectRelocRipAddress)
        "tl_boot_pool"
        (ObjectX64LoadRipAddressRdx "tl_boot_pool"))]
    [with-add-base : CompilerBackendObjectParts
      (compiler-backend-object-add-text-bytes
        with-boot-pool-lea
        (compiler-backend-object-windows-add-rdx-rax-bytes))]
    [with-boot-off-add : CompilerBackendObjectParts
      (compiler-backend-object-add-rip-instr
        with-add-base
        ".L_tl_boot_alloc"
        (ObjectRelocRipAddress)
        "tl_boot_off"
        (ObjectX64AddRcxRip "tl_boot_off"))]
    (compiler-backend-object-add-text-bytes
      with-boot-off-add
      (compiler-backend-object-windows-ret-bytes))))

(define (compiler-backend-object-add-windows-entry-text
  [parts : CompilerBackendObjectParts]) : CompilerBackendObjectParts
  (let
    [entry : String "_tl_start"]
    [entry-end : String ".L_tl_start_end"]
    [with-symbols : CompilerBackendObjectParts
      (compiler-backend-object-symbol-extern-once
        (compiler-backend-object-symbol-local-section
          (compiler-backend-object-symbol-export-section
            parts
            entry
            (ObjectSectionText)
            (ObjectSymbolFunction))
          entry-end
          (ObjectSectionText)
          (ObjectSymbolFunction))
        "ExitProcess"
        (ObjectSymbolFunction))]
    [with-label : CompilerBackendObjectParts
      (compiler-backend-object-add-text with-symbols (ObjectX64Label entry))]
    [with-sub : CompilerBackendObjectParts
      (compiler-backend-object-add-text with-label (ObjectX64SubRspImm8 40))]
    [with-setup-call : CompilerBackendObjectParts
      (compiler-backend-object-add-text
        (compiler-backend-object-add-text-relocation
          with-sub
          entry
          (ObjectRelocCall)
          "tl_setup_argv")
        (ObjectX64Call "tl_setup_argv"))]
    [with-gs-clear : CompilerBackendObjectParts
      (compiler-backend-object-add-text-bytes
        with-setup-call
        (compiler-backend-object-windows-entry-gs-clear-bytes))]
    [with-argc : CompilerBackendObjectParts
      (compiler-backend-object-add-text
        (compiler-backend-object-add-text-relocation
          with-gs-clear
          entry
          (ObjectRelocRipValue)
          ".L_tl_argc")
        (ObjectX64MovRcxRip ".L_tl_argc"))]
    [with-argv : CompilerBackendObjectParts
      (compiler-backend-object-add-text
        (compiler-backend-object-add-text-relocation
          with-argc
          entry
          (ObjectRelocRipValue)
          ".L_tl_argv")
        (ObjectX64MovRdxRip ".L_tl_argv"))]
    [with-main-call : CompilerBackendObjectParts
      (compiler-backend-object-add-text
        (compiler-backend-object-add-text-relocation
          with-argv
          entry
          (ObjectRelocCall)
          "main")
        (ObjectX64Call "main"))]
    [with-move-exit-code : CompilerBackendObjectParts
      (compiler-backend-object-add-text with-main-call (ObjectX64MovRcxRax))]
    [with-exit-call : CompilerBackendObjectParts
      (compiler-backend-object-add-text
        (compiler-backend-object-add-text-relocation
          with-move-exit-code
          entry
          (ObjectRelocCall)
          "ExitProcess")
        (ObjectX64Call "ExitProcess"))]
    (compiler-backend-object-add-text with-exit-call (ObjectX64Label entry-end))))

(define (compiler-backend-object-add-windows-entry-unwind
  [parts : CompilerBackendObjectParts]) : CompilerBackendObjectParts
  (let
    [xdata-label : String ".L_tl_start_xdata"]
    [pdata-begin : String ".L_tl_start_pdata_begin"]
    [pdata-end : String ".L_tl_start_pdata_end"]
    [pdata-unwind : String ".L_tl_start_pdata_unwind"]
    [with-xdata-symbol : CompilerBackendObjectParts
      (compiler-backend-object-symbol-local-section
        parts
        xdata-label
        (ObjectSectionXdata)
        (ObjectSymbolData))]
    [with-xdata : CompilerBackendObjectParts
      (compiler-backend-object-add-xdata
        (compiler-backend-object-add-xdata
          with-xdata-symbol
          (ObjectDataLabel xdata-label))
        (ObjectDataBytes (compiler-backend-object-windows-entry-xdata-bytes)))]
    [with-pdata-begin : CompilerBackendObjectParts
      (compiler-backend-object-add-pdata
        (compiler-backend-object-add-pdata-relocation
          (compiler-backend-object-add-pdata
            with-xdata
            (ObjectDataLabel pdata-begin))
          pdata-begin
          (ObjectRelocAddr32Nb)
          "_tl_start")
        (ObjectDataSymbolRva32 "_tl_start"))]
    [with-pdata-end : CompilerBackendObjectParts
      (compiler-backend-object-add-pdata
        (compiler-backend-object-add-pdata-relocation
          (compiler-backend-object-add-pdata
            with-pdata-begin
            (ObjectDataLabel pdata-end))
          pdata-end
          (ObjectRelocAddr32Nb)
          ".L_tl_start_end")
        (ObjectDataSymbolRva32 ".L_tl_start_end"))]
    (compiler-backend-object-add-pdata
      (compiler-backend-object-add-pdata-relocation
        (compiler-backend-object-add-pdata
          with-pdata-end
          (ObjectDataLabel pdata-unwind))
        pdata-unwind
        (ObjectRelocAddr32Nb)
        xdata-label)
      (ObjectDataSymbolRva32 xdata-label))))

(define (compiler-backend-object-add-windows-entry
  [parts : CompilerBackendObjectParts]) : CompilerBackendObjectParts
  (compiler-backend-object-add-windows-entry-unwind
    (compiler-backend-object-add-windows-entry-text
      (compiler-backend-object-add-windows-runtime-text
        (compiler-backend-object-add-windows-entry-data parts)))))

(define (compiler-backend-object-entry-symbols
  [parts : CompilerBackendObjectParts]
  [target : CompilerBackendTarget]
  [emit-entry : bool]
  [crt-entry : bool]) : CompilerBackendObjectParts
  (if emit-entry
    (match target
      [(BackendTargetLinux)
        (if crt-entry
          parts
          (compiler-backend-object-add-linux-entry parts))]
      [(BackendTargetWindows)
        (if crt-entry
          parts
          (compiler-backend-object-add-windows-entry parts))])
    parts))

(define (compiler-backend-object-image-sections
  [parts : CompilerBackendObjectParts]
  [target : CompilerBackendTarget]
  [emit-entry : bool]
  [crt-entry : bool]) : CompilerObjectSectionList
  (let
    [empty-data : CompilerObjectDataRecordList
      (compiler-object-data-list-reverse ObjectDataNil)]
    [empty-instrs : CompilerObjectX64InstrList
      (compiler-object-instr-list-reverse ObjectInstrNil)]
    [base : CompilerObjectSectionList
      (compiler-object-section-cons
        (ObjectSection
          (ObjectSectionText)
          empty-data
          (compiler-object-instr-list-reverse (struct-get parts text)))
        (compiler-object-section-cons
          (ObjectSection
            (ObjectSectionData)
            (compiler-object-data-list-reverse (struct-get parts data))
            empty-instrs)
          (compiler-object-section-cons
            (ObjectSection
              (ObjectSectionRodata)
              (compiler-object-data-list-reverse (struct-get parts rodata))
              empty-instrs)
            (compiler-object-section-cons
              (ObjectSection
                (ObjectSectionBss)
                (compiler-object-data-list-reverse (struct-get parts bss))
                empty-instrs)
              ObjectSectionNil))))]
    (match target
      [(BackendTargetLinux) (compiler-object-section-list-dense base)]
      [(BackendTargetWindows)
        (compiler-object-section-list-dense
          (compiler-object-section-cons
            (ObjectSection
              (ObjectSectionText)
              empty-data
              (compiler-object-instr-list-reverse (struct-get parts text)))
            (compiler-object-section-cons
              (ObjectSection
                (ObjectSectionData)
                (compiler-object-data-list-reverse (struct-get parts data))
                empty-instrs)
              (compiler-object-section-cons
                (ObjectSection
                  (ObjectSectionRodata)
                  (compiler-object-data-list-reverse (struct-get parts rodata))
                  empty-instrs)
                (compiler-object-section-cons
                  (ObjectSection
                    (ObjectSectionBss)
                    (compiler-object-data-list-reverse (struct-get parts bss))
                    empty-instrs)
                  (compiler-object-section-cons
                    (ObjectSection
                      (ObjectSectionPdata)
                      (compiler-object-data-list-reverse
                        (struct-get parts pdata))
                      empty-instrs)
                    (compiler-object-section-cons
                      (ObjectSection
                        (ObjectSectionXdata)
                        (compiler-object-data-list-reverse
                          (struct-get parts xdata))
                        empty-instrs)
                      (compiler-object-section-cons
                        (ObjectSection
                          (ObjectSectionRsrc)
                          (if (and emit-entry (not crt-entry))
                            (compiler-backend-object-windows-manifest-resource-records)
                            empty-data)
                          empty-instrs)
                        ObjectSectionNil))))))))])))

(define (compiler-backend-object-image-symbols
  [parts : CompilerBackendObjectParts]
  [emit-manifest-resource : bool]) : CompilerObjectSymbolList
  (compiler-object-symbol-list-reverse
    (if emit-manifest-resource
      (compiler-object-symbol-cons
        (ObjectSymbol
          compiler-backend-object-windows-manifest-label
          (ObjectSymbolLocal)
          (ObjectSymbolData)
          (ObjectSomeSection (ObjectSectionRsrc)))
        (struct-get parts symbols))
      (struct-get parts symbols))))

(define (compiler-backend-object-image-relocations
  [parts : CompilerBackendObjectParts]
  [emit-manifest-resource : bool]) : CompilerObjectRelocationList
  (compiler-object-relocation-list-reverse
    (if emit-manifest-resource
      (compiler-object-relocation-cons
        (ObjectRelocation
          (ObjectSectionRsrc)
          compiler-backend-object-windows-rsrc-data-label
          (ObjectRelocAddr32Nb)
          compiler-backend-object-windows-manifest-label)
        (struct-get parts relocations))
      (struct-get parts relocations))))

(define (compiler-backend-object-image-from-parts
  [parts : CompilerBackendObjectParts]
  [target : CompilerBackendTarget]
  [emit-entry : bool]
  [crt-entry : bool]) : CompilerObjectImage
  (let
    [emit-manifest-resource : bool
      (and emit-entry (not crt-entry) (compiler-backend-target-windows? target))]
    (CompilerObjectImage
      (compiler-backend-object-image-sections parts target emit-entry crt-entry)
      (compiler-backend-object-image-symbols parts emit-manifest-resource)
      (compiler-backend-object-image-relocations parts emit-manifest-resource))))

(define (compiler-backend-object-image-after-index
  [program : CompilerIrProgram]
  [target : CompilerBackendTarget]
  [_mode : CompilerBackendMode]
  [entry-functions : CompilerIrFunctionList]
  [globals : CompilerIrGlobalList]
  [externs : CompilerIrExternList]
  [plan : CompilerBackendRuntimePlan]
  [program-index : CompilerBackendProgramIndex]
  [emit-entry : bool]
  [crt-entry : bool]) : CompilerObjectImage
  (let
    [collections : CompilerBackendProgramCollections
      (compiler-backend-collect-program-collections program)]
    [closure-names : BackendStringList
      (compiler-backend-program-collections-functions collections)]
    [strings : BackendStringList
      (compiler-backend-program-collections-strings collections)]
    [bytes : BackendStringList
      (compiler-backend-program-collections-bytes collections)]
    [floats : BackendStringList
      (compiler-backend-program-collections-floats collections)]
    [uses-f64-neg : bool
      (compiler-backend-program-collections-uses-f64-neg? collections)]
    [seed : CompilerBackendObjectParts
      (compiler-backend-object-entry-symbols
        (compiler-backend-object-runtime-symbols
          (compiler-backend-object-externs
            (compiler-backend-object-f64-sign-bit
              (compiler-backend-object-floats
                (compiler-backend-object-bytes
                  (compiler-backend-object-strings
                    (compiler-backend-object-closure-descriptors
                      (compiler-backend-object-globals
                        (compiler-backend-object-functions
                          (compiler-backend-object-parts-empty)
                          entry-functions
                          plan
                          program-index)
                        target
                        globals)
                      closure-names
                      program-index)
                    strings)
                  bytes)
                floats)
              uses-f64-neg)
            externs
            plan)
          plan
          (compiler-backend-object-runtime-symbols-list))
        target
        emit-entry
        crt-entry)]
    (compiler-backend-object-image-from-parts
      (compiler-backend-object-add-bss seed (ObjectDataZero 0))
      target
      emit-entry
      crt-entry)))

(define (compiler-backend-emit-program-object-image-target-with-mode-and-crt
  [program : CompilerIrProgram]
  [target : CompilerBackendTarget]
  [mode : CompilerBackendMode]
  [_spans : CompilerSourceSpans]
  [emit-entry : bool]
  [crt-entry : bool]) : ResultCompilerBackendObject
  (begin
    (compiler-backend-user-symbol-cache-reset!)
    (match (compiler-backend-runtime-plan program)
      [(OkBackendRuntimePlan plan)
        (if (compiler-backend-target-runtime-ok? target plan)
          (match program
            [(IrProgram globals functions externs)
              (let
                [entry-functions : CompilerIrFunctionList
                  (compiler-backend-functions-with-implicit-main
                    functions
                    emit-entry)]
                [program-index : CompilerBackendProgramIndex
                  (compiler-backend-program-index-build entry-functions externs)]
                (match (compiler-backend-validate-function-symbols
                  globals
                  entry-functions
                  externs
                  plan
                  program-index)
                  [(OkCompilerBackendSymbolValidation _)
                    (OkCompilerBackendObject
                      (compiler-backend-object-image-after-index
                        program
                        target
                        mode
                        entry-functions
                        globals
                        externs
                        plan
                        program-index
                        emit-entry
                        crt-entry))]
                  [(ErrCompilerBackendSymbolValidation message)
                    (ErrCompilerBackendObject message)]))])
          (ErrCompilerBackendObject
            (compiler-diagnostic-at-start
              ""
              "backend: internal target runtime rejection")))]
      [(ErrBackendRuntimePlan message)
        (ErrCompilerBackendObject (compiler-diagnostic-at-start "" message))])))

(define (compiler-backend-emit-program-object-image-target-with-mode
  [program : CompilerIrProgram]
  [target : CompilerBackendTarget]
  [mode : CompilerBackendMode]
  [spans : CompilerSourceSpans]
  [emit-entry : bool]) : ResultCompilerBackendObject
  (compiler-backend-emit-program-object-image-target-with-mode-and-crt
    program
    target
    mode
    spans
    emit-entry
    false))

(define (compiler-backend-emit-program-object-image-target
  [program : CompilerIrProgram]
  [target : CompilerBackendTarget]
  [spans : CompilerSourceSpans]
  [emit-entry : bool]) : ResultCompilerBackendObject
  (compiler-backend-emit-program-object-image-target-with-mode
    program
    target
    (BackendModeScalar)
    spans
    emit-entry))

(define (compiler-backend-emit-program-object-image-linux
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]) : ResultCompilerBackendObject
  (compiler-backend-emit-program-object-image-target
    program
    (BackendTargetLinux)
    spans
    true))

(define (compiler-backend-peephole-line-end
  [asm : String]
  [start : i64]
  [n : i64]) : i64
  (let
    [i : i64 start]
    [done : bool false]
    (begin
      (while (and (not done) (< i n))
        (if (= (string-ref asm i) #\newline')
          (set! done true)
          (set! i (+ i 1))))
      i)))

(define (compiler-backend-peephole-append-line
  [buf : TextBuf]
  [line : String]
  [newline : bool]) : TextBuf
  (let
    [with-line : TextBuf (text-buf-append buf line)]
    (if newline
      (text-buf-append with-line "\n")
      with-line)))

(define (compiler-backend-peephole-find-comma-space
  [line : String]
  [start : i64]) : i64
  (let
    [n : i64 (string-length line)]
    [i : i64 start]
    [found : i64 -1]
    [done : bool false]
    (begin
      (while (not done)
        (if (< (+ i 1) n)
          (if (and
            (= (string-ref line i) #,')
            (= (string-ref line (+ i 1)) #\space'))
            (begin
              (set! found i)
              (set! done true))
            (set! i (+ i 1)))
          (set! done true)))
      found)))

(define (compiler-backend-peephole-movq [line : String]) : CompilerBackendPeepholeMove
  (let
    [prefix : String "    movq "]
    [prefix-len : i64 (string-length prefix)]
    [n : i64 (string-length line)]
    (if (compiler-backend-string-prefix-at? line prefix 0)
      (let
        [comma : i64
          (compiler-backend-peephole-find-comma-space line prefix-len)]
        (if (and (> comma prefix-len) (< (+ comma 2) n))
          (CompilerBackendPeepholeMove
            (substring line prefix-len (- comma prefix-len))
            (substring line (+ comma 2) (- n (+ comma 2))))
          (CompilerBackendPeepholeNoMove)))
      (CompilerBackendPeepholeNoMove))))

(define (compiler-backend-peephole-register-operand? [operand : String]) : bool
  (and (> (string-length operand) 0) (= (string-ref operand 0) #%')))

(define (compiler-backend-peephole-stack-slot-operand? [operand : String]) : bool
  (compiler-backend-string-contains? operand "(%rbp)"))

(define (compiler-backend-peephole-local-frame-slot-operand? [operand : String]) : bool
  (and
    (> (string-length operand) 0)
    (= (string-ref operand 0) #-')
    (compiler-backend-peephole-stack-slot-operand? operand)))

(define (compiler-backend-peephole-local-move-operand? [operand : String]) : bool
  (or
    (compiler-backend-peephole-register-operand? operand)
    (compiler-backend-peephole-stack-slot-operand? operand)))

(define (compiler-backend-peephole-self-move-operands?
  [src : String]
  [dst : String]) : bool
  (and (string-eq src dst) (compiler-backend-peephole-local-move-operand? src)))

(define (compiler-backend-peephole-redundant-move-operands?
  [src : String]
  [dst : String]
  [next-src : String]
  [next-dst : String]) : bool
  (and
    (compiler-backend-peephole-local-move-operand? src)
    (compiler-backend-peephole-local-move-operand? dst)
    (compiler-backend-peephole-local-move-operand? next-src)
    (compiler-backend-peephole-local-move-operand? next-dst)
    (or
      (and (string-eq src next-src) (string-eq dst next-dst))
      (and (string-eq src next-dst) (string-eq dst next-src)))))

(define (compiler-backend-peephole-overwritten-frame-store-operands?
  [src : String]
  [dst : String]
  [next-src : String]
  [next-dst : String]) : bool
  (and
    (compiler-backend-peephole-register-operand? src)
    (compiler-backend-peephole-local-frame-slot-operand? dst)
    (compiler-backend-peephole-register-operand? next-src)
    (compiler-backend-peephole-local-frame-slot-operand? next-dst)
    (string-eq dst next-dst)))

(define (compiler-backend-peephole-forward-frame-load-operands?
  [src : String]
  [dst : String]
  [next-src : String]
  [next-dst : String]) : bool
  (and
    (compiler-backend-peephole-register-operand? src)
    (compiler-backend-peephole-local-frame-slot-operand? dst)
    (compiler-backend-peephole-local-frame-slot-operand? next-src)
    (compiler-backend-peephole-register-operand? next-dst)
    (string-eq dst next-src)))

(define (compiler-backend-peephole-forward-frame-load-line
  [pending : String]
  [next : String]) : String
  (match (compiler-backend-peephole-movq pending)
    [(CompilerBackendPeepholeMove src dst)
      (match (compiler-backend-peephole-movq next)
        [(CompilerBackendPeepholeMove next-src next-dst)
          (if (compiler-backend-peephole-forward-frame-load-operands?
            src
            dst
            next-src
            next-dst)
            (backend-cat4 "    movq " src ", " next-dst)
            next)]
        [(CompilerBackendPeepholeNoMove) next])]
    [(CompilerBackendPeepholeNoMove) next]))

(define (compiler-backend-peephole-self-move? [line : String]) : bool
  (match (compiler-backend-peephole-movq line)
    [(CompilerBackendPeepholeMove src dst)
      (compiler-backend-peephole-self-move-operands? src dst)]
    [(CompilerBackendPeepholeNoMove) false]))

;; Pair action: 0 emits pending, 1 drops pending, 2 keeps pending and skips next,
;; 3 emits pending and replaces next with a register-forwarded move.
(define (compiler-backend-peephole-pair-action
  [pending : String]
  [next : String]) : i64
  (match (compiler-backend-peephole-movq pending)
    [(CompilerBackendPeepholeMove src dst)
      (if (compiler-backend-peephole-self-move-operands? src dst)
        1
        (match (compiler-backend-peephole-movq next)
          [(CompilerBackendPeepholeMove next-src next-dst)
            (cond
              [(compiler-backend-peephole-overwritten-frame-store-operands?
                  src
                  dst
                  next-src
                  next-dst)
                1]
              [(compiler-backend-peephole-redundant-move-operands?
                  src
                  dst
                  next-src
                  next-dst)
                2]
              [(compiler-backend-peephole-forward-frame-load-operands?
                  src
                  dst
                  next-src
                  next-dst)
                3]
              [else 0])]
          [(CompilerBackendPeepholeNoMove) 0]))]
    [(CompilerBackendPeepholeNoMove) 0]))

(define (compiler-backend-peephole-asm-once [asm : String]) : String
  (let
    [n : i64 (string-length asm)]
    [i : i64 0]
    [out : TextBuf (text-buf-empty)]
    [has-pending : bool false]
    [pending-line : String ""]
    [pending-newline : bool false]
    [rax-owner : String ""]
    (begin
      (while (< i n)
        (let
          [end : i64 (compiler-backend-peephole-line-end asm i n)]
          [next-start : i64
            (if (< end n)
              (+ end 1)
              end)]
          [line-newline : bool (< end n)]
          [line : String (substring asm i (- end i))]
          (begin
            (if has-pending
              (let
                [action : i64
                  (compiler-backend-peephole-pair-action pending-line line)]
                (cond
                  [(= action 1)
                    (begin
                      (set! pending-line line)
                      (set! pending-newline line-newline))]
                  [(= action 2) unit]
                  [(= action 3)
                    (begin
                      (match (compiler-backend-peephole-movq pending-line)
                        [(CompilerBackendPeepholeMove src dst)
                          (begin
                            (if (and
                              (string-eq dst "%rax")
                              (string-eq src rax-owner)
                              (compiler-backend-peephole-stack-slot-operand?
                                src))
                              unit
                              (set!
                                out
                                (compiler-backend-peephole-append-line
                                  out
                                  pending-line
                                  pending-newline)))
                            (set!
                              rax-owner
                              (compiler-backend-peephole-rax-slot-next-owner
                                rax-owner
                                src
                                dst)))]
                        [(CompilerBackendPeepholeNoMove)
                          (begin
                            (set! rax-owner "")
                            (set!
                              out
                              (compiler-backend-peephole-append-line
                                out
                                pending-line
                                pending-newline)))])
                      (set!
                        pending-line
                        (compiler-backend-peephole-forward-frame-load-line
                          pending-line
                          line))
                      (set! pending-newline line-newline))]
                  [else
                    (begin
                      (match (compiler-backend-peephole-movq pending-line)
                        [(CompilerBackendPeepholeMove src dst)
                          (begin
                            (if (and
                              (string-eq dst "%rax")
                              (string-eq src rax-owner)
                              (compiler-backend-peephole-stack-slot-operand?
                                src))
                              unit
                              (set!
                                out
                                (compiler-backend-peephole-append-line
                                  out
                                  pending-line
                                  pending-newline)))
                            (set!
                              rax-owner
                              (compiler-backend-peephole-rax-slot-next-owner
                                rax-owner
                                src
                                dst)))]
                        [(CompilerBackendPeepholeNoMove)
                          (begin
                            (set! rax-owner "")
                            (set!
                              out
                              (compiler-backend-peephole-append-line
                                out
                                pending-line
                                pending-newline)))])
                      (set! pending-line line)
                      (set! pending-newline line-newline))]))
              (begin
                (set! has-pending true)
                (set! pending-line line)
                (set! pending-newline line-newline)))
            (set! i next-start))))
      (if (and
        has-pending
        (not (compiler-backend-peephole-self-move? pending-line)))
        (begin
          (match (compiler-backend-peephole-movq pending-line)
            [(CompilerBackendPeepholeMove src dst)
              (begin
                (if (and
                  (string-eq dst "%rax")
                  (string-eq src rax-owner)
                  (compiler-backend-peephole-stack-slot-operand? src))
                  unit
                  (set!
                    out
                    (compiler-backend-peephole-append-line
                      out
                      pending-line
                      pending-newline)))
                (set!
                  rax-owner
                  (compiler-backend-peephole-rax-slot-next-owner
                    rax-owner
                    src
                    dst)))]
            [(CompilerBackendPeepholeNoMove)
              (begin
                (set! rax-owner "")
                (set!
                  out
                  (compiler-backend-peephole-append-line
                    out
                    pending-line
                    pending-newline)))]))
        unit)
      (text-buf-render out))))

(define (compiler-backend-peephole-rax-slot-next-owner
  [owner : String]
  [src : String]
  [dst : String]) : String
  (if (string-eq dst "%rax")
    (if (compiler-backend-peephole-stack-slot-operand? src)
      src
      "")
    (if (and
      (not (string-eq owner ""))
      (string-eq dst owner)
      (not (string-eq src "%rax")))
      ""
      owner)))

(define (compiler-backend-peephole-asm [asm : String]) : String
  (compiler-backend-peephole-asm-once asm))

(define (compiler-backend-peephole-text-buf [buf : TextBuf]) : TextBuf
  (text-buf-append
    (text-buf-empty)
    (compiler-backend-peephole-asm (text-buf-render buf))))

(define (compiler-backend-emit-program-target-with-mode-and-crt
  [program : CompilerIrProgram]
  [target : CompilerBackendTarget]
  [mode : CompilerBackendMode]
  [spans : CompilerSourceSpans]
  [emit-entry : bool]
  [crt-entry : bool]) : ResultCompilerBackend
  (match (compiler-backend-emit-program-target-with-mode-buffer-and-crt
    program
    target
    mode
    spans
    emit-entry
    crt-entry)
    [(OkCompilerBackendBuffer buf)
      (OkCompilerBackend (compiler-backend-peephole-asm (text-buf-render buf)))]
    [(ErrCompilerBackendBuffer message) (ErrCompilerBackend message)]))

(define (compiler-backend-emit-program-target-with-mode
  [program : CompilerIrProgram]
  [target : CompilerBackendTarget]
  [mode : CompilerBackendMode]
  [spans : CompilerSourceSpans]
  [emit-entry : bool]) : ResultCompilerBackend
  (match (compiler-backend-emit-program-target-with-mode-buffer
    program
    target
    mode
    spans
    emit-entry)
    [(OkCompilerBackendBuffer buf)
      (OkCompilerBackend (compiler-backend-peephole-asm (text-buf-render buf)))]
    [(ErrCompilerBackendBuffer message) (ErrCompilerBackend message)]))

(define (compiler-backend-target-cfgs [target : CompilerBackendTarget]) : SymI64Env
  (match target
    [(BackendTargetLinux)
      (compiler-cfg-enable
        (compiler-cfg-enable
          (compiler-cfg-enable
            (compiler-cfg-enable (compiler-cfg-empty) "linux")
            "unix")
          "target-linux")
        "os-linux")]
    [(BackendTargetWindows)
      (compiler-cfg-enable
        (compiler-cfg-enable
          (compiler-cfg-enable (compiler-cfg-empty) "windows")
          "target-windows")
        "os-windows")]))

(define (compiler-backend-lower-mode-for-target
  [target : CompilerBackendTarget]
  [mode : CompilerBackendMode]) : CompilerLowerMode
  (match mode
    [(BackendModeAvx2)
      (match target
        [(BackendTargetLinux) (CompilerLowerLinuxAvx2)]
        [(BackendTargetWindows) (CompilerLowerWindowsAvx2)])]
    [(BackendModeAvx512)
      (match target
        [(BackendTargetLinux) (CompilerLowerLinuxAvx512)]
        [(BackendTargetWindows) (CompilerLowerWindowsAvx512)])]
    [_
      (match target
        [(BackendTargetLinux) (CompilerLowerLinuxScalar)]
        [(BackendTargetWindows) (CompilerLowerWindowsScalar)])]))

(define (compiler-backend-lower-source-for-target
  [src : String]
  [target : CompilerBackendTarget]) : ResultCompilerLower
  (begin
    (intern-reset!)
    (compiler-builtin-reset!)
    (match (parse-ast-source-diagnostic-with-cfg
      "<source>"
      src
      (compiler-backend-target-cfgs target))
      [(OkAstProgramDiagnostic program)
        (lower-compiler-program-with-path-mode
          "<source>"
          program
          (compiler-backend-lower-mode-for-target target (BackendModeScalar)))]
      [(ErrAstProgramDiagnostic diag) (ErrCompilerLower diag)])))

(define (compiler-backend-emit-source [src : String]) : ResultCompilerBackend
  (match (lower-compiler-source src)
    [(OkCompilerLower program spans)
      (compiler-backend-emit-program-linux-with-spans program spans)]
    [(ErrCompilerLower diag) (ErrCompilerBackend diag)]))

(define (compiler-backend-emit-source-for-target
  [src : String]
  [target : CompilerBackendTarget]) : ResultCompilerBackend
  (match (compiler-backend-lower-source-for-target src target)
    [(OkCompilerLower program spans)
      (compiler-backend-emit-program-with-spans-for-target program spans target)]
    [(ErrCompilerLower diag) (ErrCompilerBackend diag)]))

;; #2357: inline-by-value aggregates are the always-on default lowering, so
;; emitting "in inline-aggregates mode" is just the ordinary target emit. The
;; explicit name is retained for the #1867 backend self-tests (which the rebase
;; onto main reintroduced); the definition was dropped resolving the backend
;; merge conflict, so restore it as an alias.
(define (compiler-backend-emit-source-inline-aggregates-for-target
  [src : String]
  [target : CompilerBackendTarget]) : ResultCompilerBackend
  (compiler-backend-emit-source-for-target src target))

(define (compiler-backend-emit-source-object-image [src : String]) : ResultCompilerBackendObject
  (match (lower-compiler-source src)
    [(OkCompilerLower program spans)
      (compiler-backend-emit-program-object-image-linux program spans)]
    [(ErrCompilerLower diag) (ErrCompilerBackendObject diag)]))

(define (compiler-backend-emit-source-object-image-for-target
  [src : String]
  [target : CompilerBackendTarget]) : ResultCompilerBackendObject
  (match (compiler-backend-lower-source-for-target src target)
    [(OkCompilerLower program spans)
      (compiler-backend-emit-program-object-image-target
        program
        target
        spans
        true)]
    [(ErrCompilerLower diag) (ErrCompilerBackendObject diag)]))

(define (compiler-backend-string-prefix-at?
  [text : String]
  [prefix : String]
  [start : i64]) : bool
  (let
    [text-len : i64 (string-length text)]
    [prefix-len : i64 (string-length prefix)]
    (if (< start 0)
      false
      (if (> (+ start prefix-len) text-len)
        false
        (let
          [i : i64 0]
          [ok : bool true]
          (begin
            (while ok
              (if (< i prefix-len)
                (if (= (string-ref text (+ start i)) (string-ref prefix i))
                  (set! i (+ i 1))
                  (set! ok false))
                (set! ok false)))
            (= i prefix-len)))))))

(define (compiler-backend-string-contains? [text : String] [needle : String]) : bool
  (let
    [text-len : i64 (string-length text)]
    [needle-len : i64 (string-length needle)]
    (if (= needle-len 0)
      true
      (let
        [i : i64 0]
        [found : bool false]
        [done : bool false]
        (begin
          (while (not done)
            (if (<= (+ i needle-len) text-len)
              (if (compiler-backend-string-prefix-at? text needle i)
                (begin
                  (set! found true)
                  (set! done true))
                (set! i (+ i 1)))
              (set! done true)))
          found)))))

(define (compiler-backend-string-count [text : String] [needle : String]) : i64
  (let
    [text-len : i64 (string-length text)]
    [needle-len : i64 (string-length needle)]
    (if (= needle-len 0)
      0
      (let
        [i : i64 0]
        [count : i64 0]
        (begin
          (while (<= (+ i needle-len) text-len)
            (if (compiler-backend-string-prefix-at? text needle i)
              (begin
                (set! count (+ count 1))
                (set! i (+ i needle-len)))
              (set! i (+ i 1))))
          count)))))

(define compiler-backend-pic-image-base-label : String
  ".L_tl_pic_image_base")

(define (compiler-backend-string-find-from
  [text : String]
  [needle : String]
  [start : i64]) : i64
  (let
    [text-len : i64 (string-length text)]
    [needle-len : i64 (string-length needle)]
    (if (= needle-len 0)
      start
      (let
        [i : i64 start]
        [found : i64 -1]
        [done : bool false]
        (begin
          (while (not done)
            (if (<= (+ i needle-len) text-len)
              (if (compiler-backend-string-prefix-at? text needle i)
                (begin
                  (set! found i)
                  (set! done true))
                (set! i (+ i 1)))
              (set! done true)))
          found)))))

(define (compiler-backend-string-replace-all
  [text : String]
  [needle : String]
  [replacement : String]) : String
  (let
    [text-len : i64 (string-length text)]
    [needle-len : i64 (string-length needle)]
    (if (= needle-len 0)
      text
      (let
        [i : i64 0]
        [out : TextBuf (text-buf-empty)]
        [done : bool false]
        (begin
          (while (not done)
            (let
              [pos : i64 (compiler-backend-string-find-from text needle i)]
              (if (< pos 0)
                (begin
                  (if (< i text-len)
                    (set!
                      out
                      (text-buf-append out (substring text i (- text-len i))))
                    unit)
                  (set! done true))
                (begin
                  (if (> pos i)
                    (set!
                      out
                      (text-buf-append out (substring text i (- pos i))))
                    unit)
                  (set! out (text-buf-append out replacement))
                  (set! i (+ pos needle-len))))))
          (text-buf-render out))))))

(define (compiler-backend-pic-quad-pattern [target : String]) : String
  (str-cat "    .quad " target "\n"))

(define (compiler-backend-pic-quad-replacement [_target : String]) : String
  "    .quad 0\n")

(define (compiler-backend-pic-rewrite-target [asm : String] [target : String]) : String
  (compiler-backend-string-replace-all
    asm
    (compiler-backend-pic-quad-pattern target)
    (compiler-backend-pic-quad-replacement target)))

(define (compiler-backend-pic-rewrite-relocs
  [asm : String]
  [relocs : CompilerObjectRelocationList]) : String
  (let
    [count : i64 (compiler-object-relocation-list-count relocs)]
    [index : i64 0]
    [out : String asm]
    (begin
      (while (< index count)
        (begin
          (match (compiler-object-relocation-list-ref relocs index)
            [(ObjectRelocation _ _ kind target)
              (match kind
                [(ObjectRelocAbs64)
                  (set! out (compiler-backend-pic-rewrite-target out target))]
                [_ unit])])
          (set! index (+ index 1))))
      out)))

(define (compiler-backend-pic-align-offset [offset : i64] [align : i64]) : i64
  (if (<= align 1)
    offset
    (let
      [rem : i64 (% offset align)]
      (if (= rem 0)
        offset
        (+ offset (- align rem))))))

(define (compiler-backend-pic-data-record-end-offset
  [record : CompilerObjectDataRecord]
  [offset : i64]) : i64
  (match record
    [(ObjectDataLabel _) offset]
    [(ObjectDataAlign align) (compiler-backend-pic-align-offset offset align)]
    [(ObjectDataBytes bytes) (+ offset (string-length bytes))]
    [(ObjectDataString text) (+ offset (+ (string-length text) 1))]
    [(ObjectDataF64 _) (+ offset 8)]
    [(ObjectDataI64 _) (+ offset 8)]
    [(ObjectDataZero count) (+ offset count)]
    [(ObjectDataSymbolAddress _) (+ offset 8)]
    [(ObjectDataSymbolRva32 _) (+ offset 4)]))

(define (compiler-backend-pic-data-label-offset-from
  [records : CompilerObjectDataRecordList]
  [label : String]
  [offset : i64]) : i64
  (let
    [count : i64 (compiler-object-data-record-list-count records)]
    [index : i64 0]
    [cur-offset : i64 offset]
    [result : i64 -1]
    [done : bool false]
    (begin
      (while (and (not done) (< index count))
        (let
          [record : CompilerObjectDataRecord
            (compiler-object-data-record-list-ref records index)]
          (match record
            [(ObjectDataLabel found)
              (if (string-eq found label)
                (begin
                  (set! result cur-offset)
                  (set! done true))
                (set! index (+ index 1)))]
            [_
              (begin
                (set!
                  cur-offset
                  (compiler-backend-pic-data-record-end-offset
                    record
                    cur-offset))
                (set! index (+ index 1)))])))
      result)))

(define (compiler-backend-pic-section-label-offset
  [image : CompilerObjectImage]
  [kind : CompilerObjectSectionKind]
  [label : String]) : i64
  (match (compiler-object-section-list-find (struct-get image sections) kind)
    [(ObjectSection _ data _)
      (match kind
        [(ObjectSectionText) -1]
        [_ (compiler-backend-pic-data-label-offset-from data label 0)])]))

(define (compiler-backend-pic-section-name [kind : CompilerObjectSectionKind]) : String
  (match kind
    [(ObjectSectionText) "text"]
    [(ObjectSectionData) "data"]
    [(ObjectSectionRodata) "rodata"]
    [(ObjectSectionBss) "bss"]
    [(ObjectSectionPdata) "pdata"]
    [(ObjectSectionXdata) "xdata"]
    [(ObjectSectionRsrc) "rsrc"]))

(define (compiler-backend-pic-fixup-line
  [section : CompilerObjectSectionKind]
  [offset : i64]
  [site : String]
  [target : String]) : String
  (string-append
    (str-cat
      (compiler-backend-pic-section-name section)
      " "
      (int->string offset)
      " "
      site)
    (string-append " " (string-append target "\n"))))

(define (compiler-backend-pic-fixup-table-relocs
  [image : CompilerObjectImage]
  [relocs : CompilerObjectRelocationList]
  [buf : TextBuf]) : TextBuf
  (let
    [count : i64 (compiler-object-relocation-list-count relocs)]
    [index : i64 0]
    [out : TextBuf buf]
    (begin
      (while (< index count)
        (begin
          (match (compiler-object-relocation-list-ref relocs index)
            [(ObjectRelocation section site kind target)
              (match kind
                [(ObjectRelocAbs64)
                  (let
                    [offset : i64
                      (compiler-backend-pic-section-label-offset
                        image
                        section
                        site)]
                    (if (>= offset 0)
                      (set!
                        out
                        (text-buf-append
                          out
                          (compiler-backend-pic-fixup-line
                            section
                            offset
                            site
                            target)))
                      unit))]
                [_ unit])])
          (set! index (+ index 1))))
      out)))

(define (compiler-backend-pic-fixup-table [image : CompilerObjectImage]) : String
  (text-buf-render
    (compiler-backend-pic-fixup-table-relocs
      image
      (struct-get image relocations)
      (text-buf-append (text-buf-empty) "typelisp-pic-fixups v1\n"))))

(define (compiler-backend-pic-symbols-have-extern?
  [symbols : CompilerObjectSymbolList]) : bool
  (let
    [count : i64 (compiler-object-symbol-list-count symbols)]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (match (compiler-object-symbol-list-ref symbols index)
          [(ObjectSymbol _ binding _ _)
            (match binding
              [(ObjectSymbolExtern) (set! found true)]
              [_ (set! index (+ index 1))])]))
      found)))

(define (compiler-backend-pic-target-symbol-internal?
  [symbols : CompilerObjectSymbolList]
  [target : String]) : bool
  (let
    [count : i64 (compiler-object-symbol-list-count symbols)]
    [index : i64 0]
    [result : bool false]
    [done : bool false]
    (begin
      (while (and (not done) (< index count))
        (match (compiler-object-symbol-list-ref symbols index)
          [(ObjectSymbol name binding _ section)
            (if (string-eq name target)
              (begin
                (set!
                  result
                  (match binding
                    [(ObjectSymbolExtern) false]
                    [_
                      (match section
                        [(ObjectNoSection) false]
                        [_ true])]))
                (set! done true))
              (set! index (+ index 1)))]))
      result)))

(define (compiler-backend-pic-reloc-site-valid?
  [image : CompilerObjectImage]
  [reloc : CompilerObjectRelocation]) : bool
  (match reloc
    [(ObjectRelocation section site kind target)
      (match kind
        [(ObjectRelocAbs64)
          (and
            (compiler-backend-pic-target-symbol-internal?
              (struct-get image symbols)
              target)
            (match section
              [(ObjectSectionData)
                (let
                  [offset : i64
                    (compiler-backend-pic-section-label-offset
                      image
                      section
                      site)]
                  (and (>= offset 0) (= (% offset 8) 0)))]
              [(ObjectSectionRodata)
                (let
                  [offset : i64
                    (compiler-backend-pic-section-label-offset
                      image
                      section
                      site)]
                  (and (>= offset 0) (= (% offset 8) 0)))]
              [_ false]))]
        [_ true])]))

(define (compiler-backend-pic-relocs-valid?
  [image : CompilerObjectImage]
  [relocs : CompilerObjectRelocationList]) : bool
  (let
    [count : i64 (compiler-object-relocation-list-count relocs)]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (if (compiler-backend-pic-reloc-site-valid?
          image
          (compiler-object-relocation-list-ref relocs index))
          (set! index (+ index 1))
          (set! ok false)))
      ok)))

(define (compiler-backend-pic-asm [asm : String] [image : CompilerObjectImage]) : String
  (string-append
    (str-cat ".text\n" compiler-backend-pic-image-base-label ":\n")
    (compiler-backend-pic-rewrite-relocs asm (struct-get image relocations))))

(define (compiler-backend-emit-program-pic-target-with-mode-and-crt
  [program : CompilerIrProgram]
  [target : CompilerBackendTarget]
  [mode : CompilerBackendMode]
  [spans : CompilerSourceSpans]
  [emit-entry : bool]
  [crt-entry : bool]) : ResultCompilerBackendPic
  (match (compiler-backend-emit-program-target-with-mode-buffer-and-crt
    program
    target
    mode
    spans
    emit-entry
    crt-entry)
    [(OkCompilerBackendBuffer buf)
      (match (compiler-backend-emit-program-object-image-target-with-mode-and-crt
        program
        target
        mode
        spans
        emit-entry
        crt-entry)
        [(OkCompilerBackendObject image)
          (if (compiler-backend-pic-symbols-have-extern?
            (struct-get image symbols))
            (ErrCompilerBackendPic
              (compiler-diagnostic-at-start
                ""
                "backend: --pic supports only internal references; extern symbols are not supported"))
            (if (compiler-backend-pic-relocs-valid?
              image
              (struct-get image relocations))
              (OkCompilerBackendPic
                (CompilerBackendPicOutput
                  (compiler-backend-pic-asm
                    (compiler-backend-peephole-asm (text-buf-render buf))
                    image)
                  (compiler-backend-pic-fixup-table image)))
              (ErrCompilerBackendPic
                (compiler-diagnostic-at-start
                  ""
                  "backend: --pic could not map every absolute pointer fixup to an 8-byte data slot"))))]
        [(ErrCompilerBackendObject diag) (ErrCompilerBackendPic diag)])]
    [(ErrCompilerBackendBuffer diag) (ErrCompilerBackendPic diag)]))

(define (compiler-backend-emit-program-pic-target-with-mode
  [program : CompilerIrProgram]
  [target : CompilerBackendTarget]
  [mode : CompilerBackendMode]
  [spans : CompilerSourceSpans]
  [emit-entry : bool]) : ResultCompilerBackendPic
  (compiler-backend-emit-program-pic-target-with-mode-and-crt
    program
    target
    mode
    spans
    emit-entry
    false))

(define (compiler-backend-emit-source-pic-for-target
  [src : String]
  [target : CompilerBackendTarget]) : ResultCompilerBackendPic
  (match (compiler-backend-lower-source-for-target src target)
    [(OkCompilerLower program spans)
      (compiler-backend-emit-program-pic-target-with-mode
        program
        target
        (BackendModeScalar)
        spans
        true)]
    [(ErrCompilerLower diag) (ErrCompilerBackendPic diag)]))

(define (compiler-backend-emit-source-pic-linux [src : String]) : ResultCompilerBackendPic
  (compiler-backend-emit-source-pic-for-target src (BackendTargetLinux)))

(define (compiler-backend-runtime-helper-externs) : CompilerIrExternList
  (compiler-ir-extern-cons
    (compiler-ir-extern-default "tl_alloc" (AstTyI64))
    (compiler-ir-extern-cons
      (compiler-ir-extern-default "tl_substring" (AstTyI64))
      (compiler-ir-extern-cons
        (compiler-ir-extern-default "tl_string_concat" (AstTyI64))
        (compiler-ir-extern-cons
          (compiler-ir-extern-default "tl_int_to_string" (AstTyString))
          IrExternNil)))))

(define (compiler-backend-runtime-helper-program) : CompilerIrProgram
  (IrProgram
    IrGlobalNil
    (compiler-ir-function-cons
      (IrFunction
        "main"
        IrParamNil
        (AstTyI64)
        4
        (compiler-ir-block-cons
          (compiler-ir-block
            "entry"
            (compiler-ir-instr-cons
              (IrInstrCall
                0
                "tl_alloc"
                (IrCallArgsOne (IrValueI64 8))
                (AstTyI64))
              (compiler-ir-instr-cons
                (IrInstrCall
                  1
                  "tl_substring"
                  (compiler-ir-call-args-from-list
                    (compiler-ir-value-cons
                      (IrValueI64 0)
                      (compiler-ir-value-cons
                        (IrValueI64 0)
                        (compiler-ir-value-cons (IrValueI64 0) IrValueNil))))
                  (AstTyI64))
                (compiler-ir-instr-cons
                  (IrInstrCall
                    2
                    "tl_string_concat"
                    (compiler-ir-call-args-from-list
                      (compiler-ir-value-cons
                        (IrValueI64 0)
                        (compiler-ir-value-cons
                          (IrValueI64 0)
                          (compiler-ir-value-cons
                            (IrValueI64 0)
                            (compiler-ir-value-cons (IrValueI64 0) IrValueNil)))))
                    (AstTyI64))
                  (compiler-ir-instr-cons
                    (IrInstrReturn (IrSomeValue (IrValueI64 42)))
                    IrInstrNil)))))
          IrBlockNil))
      IrFunctionNil)
    (compiler-backend-runtime-helper-externs)))

(define (compiler-backend-runtime-helper-source) : String
  "(extern (tl_alloc [arg0 : i64]) : i64)
(extern (tl_substring [arg0 : i64] [arg1 : i64] [arg2 : i64]) : i64)
(extern (tl_string_concat [arg0 : i64] [arg1 : i64] [arg2 : i64] [arg3 : i64]) : i64)
(extern (tl_int_to_string [arg0 : i64]) : String)
(define (main) : i64
  (begin
    (tl_alloc 8)
    (tl_substring 0 0 0)
    (tl_string_concat 0 0 0 0)
    (tl_int_to_string 1)
    42))")

(define (compiler-backend-no-stdlib-forwarding-labels? [asm : String]) : bool
  (and
    (backend-and8
      (not (compiler-backend-string-contains? asm "tl_print_err:\n"))
      (not (compiler-backend-string-contains? asm "tl_print_string:\n"))
      (not (compiler-backend-string-contains? asm ".L_tl_arg_count:\n"))
      (not (compiler-backend-string-contains? asm ".L_tl_arg:\n"))
      (not (compiler-backend-string-contains? asm ".L_tl_read_file:\n"))
      (not (compiler-backend-string-contains? asm ".L_tl_write_file:\n"))
      (not (compiler-backend-string-contains? asm ".L_tl_file_exists:\n"))
      (not (compiler-backend-string-contains? asm ".L_tl_file_open_status:\n")))
    (backend-and8
      (not (compiler-backend-string-contains? asm ".L_tl_file_close_status:\n"))
      (not
        (compiler-backend-string-contains?
          asm
          ".L_tl_file_read_chunk_status:\n"))
      (not (compiler-backend-string-contains? asm ".L_tl_file_write_status:\n"))
      (not (compiler-backend-string-contains? asm ".L_tl_file_flush_status:\n"))
      (not
        (compiler-backend-string-contains? asm ".L_tl_file_read_chunk_bytes:\n"))
      (not
        (compiler-backend-string-contains? asm ".L_tl_file_read_chunk_eof:\n"))
      (not (compiler-backend-string-contains? asm ".L_tl_fs_mkdir_status:\n"))
      (not (compiler-backend-string-contains? asm ".L_tl_fs_process_id:\n")))
    (backend-and8
      (not (compiler-backend-string-contains? asm ".L_tl_read_stdin_line:\n"))
      (not (compiler-backend-string-contains? asm ".L_tl_read_stdin_bytes:\n"))
      (not (compiler-backend-string-contains? asm ".L_tl_stdin_eof:\n"))
      (not (compiler-backend-string-contains? asm ".L_tl_flush_stdout:\n"))
      (not (compiler-backend-string-contains? asm "tl_env_var_exists:\n"))
      (not (compiler-backend-string-contains? asm "tl_env_var_value:\n"))
      (not (compiler-backend-string-contains? asm "tl_cpuid_eax:\n"))
      (not (compiler-backend-string-contains? asm "tl_xgetbv:\n")))
    (backend-and4
      (not (compiler-backend-string-contains? asm "tl_print_char:\n"))
      (not (compiler-backend-string-contains? asm "tl_print_f64:\n"))
      (not
        (compiler-backend-string-contains? asm ".L_tl_fs_remove_file_status:\n"))
      (not
        (compiler-backend-string-contains? asm ".L_tl_fs_remove_dir_status:\n")))
    (not (compiler-backend-string-contains? asm ".L_tl_fs_rename_status:\n"))))

(define (compiler-backend-runtime-helper-asm-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-runtime-helper-source))
    [(OkCompilerBackend asm)
      (and
        (backend-and8
          (compiler-backend-string-contains? asm ".globl tl_alloc\n")
          (compiler-backend-string-contains? asm "tl_alloc:\n")
          (not (compiler-backend-string-contains? asm ".globl tl_oob_abort\n"))
          (not (compiler-backend-string-contains? asm "tl_oob_abort:\n"))
          (compiler-backend-string-contains? asm ".globl tl_substring\n")
          (compiler-backend-string-contains? asm "tl_substring:\n")
          (compiler-backend-string-contains? asm ".globl tl_string_concat\n")
          (compiler-backend-string-contains? asm "tl_string_concat:\n"))
        (backend-and8
          (compiler-backend-string-contains? asm ".globl tl_string_concat3\n")
          (compiler-backend-string-contains? asm "tl_string_concat3:\n")
          (compiler-backend-string-contains? asm ".globl tl_string_concat4\n")
          (compiler-backend-string-contains? asm "tl_string_concat4:\n")
          (compiler-backend-string-contains? asm ".globl tl_string_concat5\n")
          (compiler-backend-string-contains? asm "tl_string_concat5:\n")
          (compiler-backend-string-contains? asm "    call tl_string_concat5\n")
          (and
            (not (compiler-backend-string-contains? asm "getrandom:\n"))
            (not (compiler-backend-string-contains? asm "getcwd:\n"))))
        (backend-and8
          (not (compiler-backend-string-contains? asm ".globl tl_string_eq\n"))
          (not (compiler-backend-string-contains? asm "tl_string_eq:\n"))
          (not
            (compiler-backend-string-contains? asm ".globl tl_string_to_int\n"))
          (not (compiler-backend-string-contains? asm "tl_string_to_int:\n"))
          (compiler-backend-string-contains? asm ".globl tl_int_to_string\n")
          (compiler-backend-string-contains? asm "tl_int_to_string:\n")
          (not (compiler-backend-string-contains? asm "tl_process_output:\n"))
          (not
            (compiler-backend-string-contains? asm "tl_random_system_seed:\n")))
        (backend-and4
          (or
            (compiler-backend-string-contains? asm "    call .L_tl_alloc8\n")
            (compiler-backend-string-contains? asm "    call .L_tl_alloc16\n"))
          (not (compiler-backend-string-contains? asm ".extern tl_alloc\n"))
          (not
            (compiler-backend-string-contains?
              asm
              ".extern tl_process_output\n"))
          (not
            (compiler-backend-string-contains?
              asm
              ".extern tl_random_system_seed\n")))
        (backend-and4
          (not (compiler-backend-string-contains? asm "__errno_location:\n"))
          (not (compiler-backend-string-contains? asm "_errno:\n"))
          (not (compiler-backend-string-contains? asm "tl_errno:\n"))
          (compiler-backend-no-stdlib-forwarding-labels? asm)))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-str-view-helper-source) : String
  "(unsafe
  (extern (tl_str_view [text : (& text str)] [start : i64] [len : i64]) : (& text str)))
(define (view-length [text : (& text str)]) : i64
  (let
    [view : (& text str) (unsafe (tl_str_view text 1 2))]
    (string-length view)))
(define (main) : i64
  (let
    [text : String \"abcdef\"]
    (view-length (& text))))")

(define (compiler-backend-str-view-runtime-helper-asm-ok?) : bool
  (match (compiler-backend-emit-source
    (compiler-backend-str-view-helper-source))
    [(OkCompilerBackend asm)
      (and
        (backend-and8
          (compiler-backend-string-contains? asm ".globl tl_alloc\n")
          (compiler-backend-string-contains? asm "tl_alloc:\n")
          (compiler-backend-string-contains? asm ".globl tl_str_view\n")
          (compiler-backend-string-contains? asm "tl_str_view:\n")
          (compiler-backend-string-contains? asm ".L_tl_str_view_arena:\n")
          (compiler-backend-string-contains? asm "    call tl_str_view\n")
          (compiler-backend-string-contains?
            asm
            "    call tl_arena_make_atomic\n")
          (compiler-backend-string-contains? asm "    call tl_arena_set\n"))
        (backend-and4
          (not (compiler-backend-string-contains? asm ".extern tl_str_view\n"))
          (not (compiler-backend-string-contains? asm ".globl tl_substring\n"))
          (not (compiler-backend-string-contains? asm "tl_substring:\n"))
          (not (compiler-backend-string-contains? asm ".extern tl_substring\n"))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-file-handle-open-close-runtime-ok?) : bool
  (match (compiler-backend-emit-source
    "(extern (file-open-status [arg0 : String] [arg1 : i64]) : i64 (:symbol \"tl_file_open_status\"))
(extern (file-close-status [arg0 : i64]) : i64 (:symbol \"tl_file_close_status\"))
(define (main) : i64
  (let
    [handle : i64 (file-open-status \"input.txt\" 0)]
    (+ handle (file-close-status handle))))")
    [(OkCompilerBackend asm)
      (and
        (not
          (compiler-backend-string-contains? asm ".L_tl_file_open_status:\n"))
        (not
          (compiler-backend-string-contains? asm ".L_tl_file_close_status:\n"))
        (compiler-backend-string-contains? asm "    call tl_file_open_status\n")
        (compiler-backend-string-contains?
          asm
          "    call tl_file_close_status\n")
        (compiler-backend-string-contains? asm ".extern tl_file_open_status\n")
        (compiler-backend-string-contains? asm ".extern tl_file_close_status\n"))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-windows-driver-runtime-source) : String
  "(extern (arg-count) : i64 (:symbol \"tl_arg_count\"))
(extern (arg [arg0 : i64]) : String (:symbol \"tl_arg\"))
(extern (read-file [arg0 : String]) : String (:symbol \"tl_read_file\"))
(extern (write-file [arg0 : String] [arg1 : String]) : unit (:symbol \"tl_write_file\"))
(extern (file-exists? [arg0 : String]) : bool (:symbol \"tl_file_exists\"))
(extern (print-error [arg0 : String]) : unit (:symbol \"tl_print_err\"))
(extern (string-eq [arg0 : String] [arg1 : String]) : bool (:symbol \"tl_string_eq\"))
(extern (string->int [arg0 : String]) : i64 (:symbol \"tl_string_to_int\"))
(extern (int->string [arg0 : i64]) : String (:symbol \"tl_int_to_string\"))
(define (main) : i64
  (if (< (arg-count) 3)
    (begin
      (print-error \"runtime driver: expected input and output paths\")
      2)
    (let ([input : String (arg 1)]
          [output : String (arg 2)])
      (let ([content : String (read-file input)])
        (if (file-exists? input)
          (let ([n : i64 (string->int content)])
            (let ([rendered : String (int->string (+ n 1))])
              (begin
                (if (string-eq content \"41\")
                  (print-error \"ok\")
                  (print-error \"mismatch\"))
                (write-file output rendered)
                42)))
          3)))))")

(define (compiler-backend-windows-driver-runtime-ok?) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-windows-driver-runtime-source)
    (BackendTargetWindows))
    [(OkCompilerBackend asm)
      (and
        (backend-and8
          (compiler-backend-string-contains? asm ".extern tl_arg_count\n")
          (compiler-backend-string-contains? asm ".extern tl_arg\n")
          (compiler-backend-string-contains? asm ".extern tl_read_file\n")
          (compiler-backend-string-contains? asm ".extern tl_write_file\n")
          (compiler-backend-string-contains? asm ".extern tl_file_exists\n")
          (compiler-backend-string-contains? asm ".extern tl_print_err\n")
          (compiler-backend-string-contains? asm ".extern tl_string_eq\n")
          (compiler-backend-string-contains? asm ".extern tl_string_to_int\n"))
        (compiler-backend-string-contains? asm "tl_int_to_string:\n")
        (compiler-backend-string-contains?
          asm
          "    movq %rcx, .L_tl_argc(%rip)\n")
        (backend-and4
          (not (compiler-backend-string-contains? asm ".L_tl_arg_count:\n"))
          (not (compiler-backend-string-contains? asm ".L_tl_arg:\n"))
          (not (compiler-backend-string-contains? asm "tl_print_err:\n"))
          (not (compiler-backend-string-contains? asm ".L_tl_read_file:\n")))
        (not (compiler-backend-string-contains? asm ".L_tl_write_file:\n"))
        (not (compiler-backend-string-contains? asm ".L_tl_file_exists:\n"))
        (not (compiler-backend-string-contains? asm "tl_string_eq:\n"))
        (not (compiler-backend-string-contains? asm "tl_string_to_int:\n"))
        (not (compiler-backend-string-contains? asm "    call _open\n"))
        (not (compiler-backend-string-contains? asm "syscall\n")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-alloc-runtime-arena-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-runtime-helper-source))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains?
          asm
          ".section .tbss,\"awT\",@nobits\n")
        (compiler-backend-string-contains? asm "tl_current_arena:\n")
        (compiler-backend-string-contains? asm "tl_thread_init:\n")
        (compiler-backend-string-contains? asm "tl_arena_make_atomic:\n")
        (compiler-backend-string-contains?
          asm
          "    movq %fs:tl_current_arena@tpoff, %r8\n")
        (compiler-backend-string-contains? asm ".L_tl_alloc_new_arena:\n")
        (compiler-backend-string-contains? asm "    movq $0x4000000, %rdx\n")
        (compiler-backend-string-contains? asm "    addq $64, %rcx\n")
        (compiler-backend-string-contains? asm "    movq $0, 32(%rax)\n")
        (compiler-backend-string-contains? asm "    movq %r10, 40(%rax)\n")
        (compiler-backend-string-contains? asm "    movq $0, 48(%rax)\n")
        (compiler-backend-string-contains? asm "    leaq 64(%rax), %r8\n")
        (compiler-backend-string-contains? asm "    movq %rax, 40(%rax)\n")
        (compiler-backend-string-contains? asm "    movq $1, 48(%rax)\n")
        (compiler-backend-string-contains? asm "    leaq 64(%rax), %rcx\n")
        (compiler-backend-string-contains?
          asm
          "    movq %rax, %fs:tl_current_arena@tpoff\n")
        (not
          (compiler-backend-string-contains? asm ".L_tl_alloc_size_ready:\n")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-alloc-runtime-shape-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-runtime-helper-source))
    [(OkCompilerBackend asm)
      (and
        (backend-and8
          (compiler-backend-string-contains? asm "    addq $7, %rdi\n")
          (compiler-backend-string-contains? asm "    andq $-8, %rdi\n")
          (compiler-backend-string-contains? asm "    movq 16(%r8), %rax\n")
          (compiler-backend-string-contains? asm "    movq %rcx, 16(%r8)\n")
          (compiler-backend-string-contains? asm "    movq $9, %rax\n")
          (compiler-backend-string-contains? asm "    movq $0x22, %r10\n")
          (compiler-backend-string-contains? asm "    jc .L_tl_alloc_abort\n")
          (compiler-backend-string-contains? asm "    js .L_tl_alloc_abort\n"))
        (backend-and4
          (compiler-backend-string-contains? asm "    testq $1, 48(%r9)\n")
          (compiler-backend-string-contains?
            asm
            "    lock cmpxchgq %rcx, 16(%r8)\n")
          (compiler-backend-string-contains?
            asm
            "    lock cmpxchgq %rcx, 48(%r9)\n")
          (compiler-backend-string-contains? asm "    movq %rax, 56(%r9)\n"))
        (compiler-backend-string-contains? asm ".L_tl_alloc_abort:\n")
        (compiler-backend-string-contains? asm "    jmp tl_oom_abort\n"))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-user-helper-name-program) : CompilerIrProgram
  (IrProgram
    IrGlobalNil
    (compiler-ir-function-cons
      (IrFunction
        "tl_alloc"
        IrParamNil
        (AstTyI64)
        0
        (compiler-ir-block-cons
          (compiler-ir-block
            "entry"
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueI64 7)))
              IrInstrNil))
          IrBlockNil))
      (compiler-ir-function-cons
        (IrFunction
          "main"
          IrParamNil
          (AstTyI64)
          1
          (compiler-ir-block-cons
            (compiler-ir-block
              "entry"
              (compiler-ir-instr-cons
                (IrInstrCall 0 "tl_alloc" (IrCallArgsNil) (AstTyI64))
                (compiler-ir-instr-cons
                  (IrInstrReturn (IrSomeValue (IrValueVar 0)))
                  IrInstrNil)))
            IrBlockNil))
        IrFunctionNil))
    IrExternNil))

(define (compiler-backend-user-helper-name-ok?) : bool
  (match (compiler-backend-emit-program-linux
    (compiler-backend-user-helper-name-program))
    [(OkCompilerBackend asm)
      (and
        (or
          (compiler-backend-string-contains? asm ".globl _tl_tl_alloc")
          (compiler-backend-string-contains? asm ".globl _tl_f"))
        (or
          (compiler-backend-string-contains? asm "    call _tl_tl_alloc")
          (compiler-backend-string-contains? asm "    call _tl_f"))
        (not (compiler-backend-string-contains? asm ".L_tl_alloc_msg")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-runtime-coexist-program) : CompilerIrProgram
  (IrProgram
    IrGlobalNil
    (compiler-ir-function-cons
      (IrFunction
        "tl_alloc"
        IrParamNil
        (AstTyI64)
        0
        (compiler-ir-block-cons
          (compiler-ir-block
            "entry"
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueI64 7)))
              IrInstrNil))
          IrBlockNil))
      (compiler-ir-function-cons
        (IrFunction
          "main"
          IrParamNil
          (AstTyI64)
          2
          (compiler-ir-block-cons
            (compiler-ir-block
              "entry"
              (compiler-ir-instr-cons
                (IrInstrCall 0 "tl_alloc" (IrCallArgsNil) (AstTyI64))
                (compiler-ir-instr-cons
                  (IrInstrCall
                    1
                    "tl_substring"
                    (compiler-ir-call-args-from-list
                      (compiler-ir-value-cons
                        (IrValueI64 0)
                        (compiler-ir-value-cons
                          (IrValueI64 0)
                          (compiler-ir-value-cons (IrValueI64 0) IrValueNil))))
                    (AstTyI64))
                  (compiler-ir-instr-cons
                    (IrInstrReturn (IrSomeValue (IrValueVar 0)))
                    IrInstrNil))))
            IrBlockNil))
        IrFunctionNil))
    (compiler-ir-extern-cons
      (compiler-ir-extern-default "tl_substring" (AstTyI64))
      IrExternNil)))

(define (compiler-backend-runtime-coexist-ok?) : bool
  (match (compiler-backend-emit-program-linux
    (compiler-backend-runtime-coexist-program))
    [(OkCompilerBackend asm)
      (and
        (or
          (compiler-backend-string-contains? asm ".globl _tl_tl_alloc")
          (compiler-backend-string-contains? asm ".globl _tl_f"))
        (compiler-backend-string-contains? asm ".globl tl_alloc\n")
        (compiler-backend-string-contains? asm ".globl tl_substring\n")
        (or
          (compiler-backend-string-contains? asm "    call _tl_tl_alloc")
          (compiler-backend-string-contains? asm "    call _tl_f"))
        (compiler-backend-string-contains? asm "    call tl_substring\n")
        (not (compiler-backend-string-contains? asm ".extern tl_substring\n")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-module-symbol-program) : CompilerIrProgram
  (IrProgram
    IrGlobalNil
    (compiler-ir-function-cons
      (IrFunction
        "lib.tl::helper"
        IrParamNil
        (AstTyI64)
        0
        (compiler-ir-block-cons
          (compiler-ir-block
            "entry"
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueI64 7)))
              IrInstrNil))
          IrBlockNil))
      (compiler-ir-function-cons
        (IrFunction
          "main"
          IrParamNil
          (AstTyI64)
          1
          (compiler-ir-block-cons
            (compiler-ir-block
              "entry"
              (compiler-ir-instr-cons
                (IrInstrCall 0 "lib.tl::helper" (IrCallArgsNil) (AstTyI64))
                (compiler-ir-instr-cons
                  (IrInstrReturn (IrSomeValue (IrValueVar 0)))
                  IrInstrNil)))
            IrBlockNil))
        IrFunctionNil))
    IrExternNil))

(define (compiler-backend-module-symbol-ok?) : bool
  (match (compiler-backend-emit-program-linux
    (compiler-backend-module-symbol-program))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm ".globl _tl_lib_helper")
        (compiler-backend-string-contains? asm "    call _tl_lib_helper")
        (not (compiler-backend-string-contains? asm "_u2e"))
        (not (compiler-backend-string-contains? asm "_colon"))
        (not (compiler-backend-string-contains? asm "_slash")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-extern-metadata-source) : String
  "(extern (local-call [arg0 : i64]) : i64 (:abi c) (:symbol \"foreign_exact\"))
(define (normal) : i64 1)
(define (main) : i64 (+ (local-call 7) (normal)))")

(define (compiler-backend-extern-metadata-symbol-target-ok?
  [target : CompilerBackendTarget]) : bool
  (match (compiler-backend-emit-source-for-target
    (compiler-backend-extern-metadata-source)
    target)
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm ".extern foreign_exact\n")
        (compiler-backend-string-contains? asm "    call foreign_exact\n")
        (or
          (compiler-backend-string-contains? asm "    call _tl_normal")
          (compiler-backend-string-contains? asm "    call _tl_f"))
        (not (compiler-backend-string-contains? asm ".extern local-call\n"))
        (not (compiler-backend-string-contains? asm "    call local-call\n")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-extern-metadata-symbol-ok?) : bool
  (and
    (compiler-backend-extern-metadata-symbol-target-ok? (BackendTargetLinux))
    (compiler-backend-extern-metadata-symbol-target-ok? (BackendTargetWindows))))