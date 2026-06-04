;; compiler_backend.tl - First selfhost CompilerIrProgram -> x86_64 .s emitter (#447).
(import "../stdlib/io.tl")

(import "../stdlib/arena.tl")

(import "compiler_lower.tl")

(import "compiler_diagnostic.tl")

(import "compiler_optimize.tl")

(import "compiler_regalloc.tl")

(import "../stdlib/text_buf.tl")

(import "stdlib/hashmap.tl")

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

(defenum CompilerBackendMaybeImmediate
  (CompilerBackendNoImmediate)
  (CompilerBackendSomeImmediate String))

(defenum CompilerBackendMaybeAsm
  (CompilerBackendNoAsm)
  (CompilerBackendSomeAsm String))

(defenum CompilerBackendMaybeI64
  (CompilerBackendNoI64)
  (CompilerBackendSomeI64 i64))

(defenum CompilerBackendMaybeLabel
  (CompilerBackendNoLabel)
  (CompilerBackendSomeLabel String))

(defenum CompilerBackendMaybeSignature
  (CompilerBackendNoSignature)
  (CompilerBackendSomeSignature AstTypeList AstType))

(defenum CompilerBackendGlobalTypeList
  (CompilerBackendGlobalTypeNil)
  (CompilerBackendGlobalTypeCons String AstType CompilerBackendGlobalTypeList))

(defenum ResultCompilerBackend
  (OkCompilerBackend String)
  (ErrCompilerBackend CompilerDiagnostic))

(defstruct CompilerBackendRuntimeTailPlan
  (fs-current-dir bool)
  (profile bool))

(defenum ResultCompilerBackendBuffer
  (OkCompilerBackendBuffer TextBuf)
  (ErrCompilerBackendBuffer CompilerDiagnostic))

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
    bool
    CompilerBackendRuntimeTailPlan))

(defstruct CompilerBackendRuntimeIndex
  (defines StringI64Map)
  (externs StringI64Map)
  (calls StringI64Map)
  (needs-div-abort bool)
  (needs-shift-abort bool))

(defstruct CompilerBackendProgramIndex
  (functions StringI64Map)
  (function-signatures (Array CompilerBackendMaybeSignature))
  (extern-signatures StringI64Map)
  (extern-signature-values (Array CompilerBackendMaybeSignature))
  (extern-references StringI64Map)
  (extern-link-symbols (Array String)))

(defstruct CompilerBackendSourceSpanIndex
  (entries StringI64Map)
  (values (Array CompilerMaybeSourceSpan)))

(define (compiler-backend-runtime-tail-fs-current-dir?
  [tail : CompilerBackendRuntimeTailPlan]) : bool
  (struct-get tail fs-current-dir))

(define (compiler-backend-runtime-tail-profile?
  [tail : CompilerBackendRuntimeTailPlan]) : bool
  (struct-get tail profile))

;; Backend code-generation target (#646). Linux/System V and Windows x64 are
;; both modeled here; target-specific runtime helpers are emitted below.
(defenum CompilerBackendTarget
  (BackendTargetLinux)
  (BackendTargetWindows))

(defenum CompilerBackendMode
  (BackendModeScalar)
  (BackendModeAvx2)
  (BackendModeAvx512))

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

(define (backend-cat3 [a : String] [b : String] [c : String]) : String
  (string-append a (string-append b c)))

(define (backend-cat4 [a : String] [b : String] [c : String] [d : String]) : String
  (string-append a (string-append b (string-append c d))))

(define (backend-cat5
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]) : String
  (string-append a (string-append b (string-append c (string-append d e)))))

(define (backend-and4 [a : bool] [b : bool] [c : bool] [d : bool]) : bool
  (and a (and b (and c d))))

(define (backend-or4 [a : bool] [b : bool] [c : bool] [d : bool]) : bool
  (or a (or b (or c d))))

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
            (compiler-backend-source-span-index-add rest map values index)
            (match (string-i64-map-insert map name index)
              [(StringI64MapInsertOk next-map)
                (begin
                  (array-set! values index (CompilerSomeSourceSpan span))
                  (compiler-backend-source-span-index-add
                    rest
                    next-map
                    values
                    (+ index 1)))]
              [(StringI64MapInsertFull next-map) next-map]))])]))

(define (compiler-backend-source-span-index-build
  [spans : CompilerSourceSpans]) : CompilerBackendSourceSpanIndex
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

(define (compiler-backend-avx2-shape-ok? [elem-ty : AstType] [lanes : i64]) : bool
  (match elem-ty
    [(AstTyI64) (= lanes 4)]
    [(AstTyU64) (= lanes 4)]
    [(AstTyF64) (= lanes 4)]
    [(AstTyI32) (= lanes 8)]
    [(AstTyU32) (= lanes 8)]
    [_ false]))

(define (compiler-backend-avx2-shape-diagnostic
  [instr-diag : CompilerDiagnostic]
  [elem-ty : AstType]
  [lanes : i64]) : ResultCompilerBackend
  (ErrCompilerBackend
    (compiler-diagnostic-with-message
      instr-diag
      (backend-cat5
        "backend: unsupported AVX2 vector shape "
        (int->string lanes)
        " x "
        (compiler-ir-type-name elem-ty)
        ""))))

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
  (backend-cat3
    "backend: vector register home unavailable for "
    role
    "; unsupported spill, call, or ABI lifetime"))

(define (compiler-backend-mask-home-unavailable [role : String]) : String
  (backend-cat3
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
              (cond
                [(string-eq width "xmm")
                  (compiler-backend-vector-home-to-xmm home)]
                [(string-eq width "zmm")
                  (compiler-backend-vector-home-to-zmm home)]
                [else (compiler-backend-vector-home-to-ymm home)])]
            (if (= (string-length reg) 0)
              (ErrBackendReg (compiler-backend-vector-home-unavailable role))
              (OkBackendReg reg)))]
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
        [(AstTyF64) "vaddpd"]
        [_ ""])]
    [_ ""]))

(define (compiler-backend-avx2-vector-reduce-op-mnemonic
  [op : CompilerIrVectorReduceOp]
  [elem-ty : AstType]) : String
  (match op
    [(IrVectorReduceSum)
      (match elem-ty
        [(AstTyI64) "vpaddq"]
        [(AstTyI32) "vpaddd"]
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
  (backend-cat5
    "(%rax,%rcx,"
    (int->string (compiler-backend-type-size elem-ty))
    ")"
    ""
    ""))

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
                (backend-cat5
                  "    "
                  (compiler-backend-avx2-vector-move elem-ty)
                  " "
                  (compiler-backend-avx2-indexed-addr elem-ty)
                  (backend-cat5 ", " dst-reg "\n" "" ""))))]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(ErrBackendReg message)
        (ErrCompilerBackend
          (compiler-diagnostic-with-message instr-diag message))])
    (compiler-backend-avx2-shape-diagnostic instr-diag elem-ty lanes)))

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
                      (backend-cat5
                        "    "
                        mnemonic
                        " "
                        rhs-reg
                        (backend-cat5 ", " lhs-reg ", " dst-reg "\n")))]
                  [(ErrBackendReg message)
                    (ErrCompilerBackend
                      (compiler-diagnostic-with-message instr-diag message))])]
              [(ErrBackendReg message)
                (ErrCompilerBackend
                  (compiler-diagnostic-with-message instr-diag message))])]
          [(ErrBackendReg message)
            (ErrCompilerBackend
              (compiler-diagnostic-with-message instr-diag message))])))
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
                (backend-cat5
                  "    "
                  (compiler-backend-avx2-vector-move elem-ty)
                  " "
                  value-reg
                  (backend-cat5
                    ", "
                    (compiler-backend-avx2-indexed-addr elem-ty)
                    "\n"
                    ""
                    ""))))]
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
    [(AstTyI32) (= lanes 16)]
    [(AstTyU32) (= lanes 16)]
    [_ false]))

(define (compiler-backend-avx512-shape-diagnostic
  [instr-diag : CompilerDiagnostic]
  [elem-ty : AstType]
  [lanes : i64]) : ResultCompilerBackend
  (ErrCompilerBackend
    (compiler-diagnostic-with-message
      instr-diag
      (backend-cat5
        "backend: unsupported AVX-512 vector shape "
        (int->string lanes)
        " x "
        (compiler-ir-type-name elem-ty)
        ""))))

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
    [(AstTyI64) "vmovdqu64"]
    [(AstTyU64) "vmovdqu64"]
    [(AstTyI32) "vmovdqu32"]
    [(AstTyU32) "vmovdqu32"]
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
        [(AstTyF64) "vaddpd"]
        [_ ""])]
    [_ ""]))

(define (compiler-backend-avx512-vector-reduce-op-mnemonic
  [op : CompilerIrVectorReduceOp]
  [elem-ty : AstType]) : String
  (compiler-backend-avx2-vector-reduce-op-mnemonic op elem-ty))

(define (compiler-backend-avx512-lane-mask [lanes : i64]) : i64
  (cond [(= lanes 8) 255] [(= lanes 16) 65535] [else 0]))

(define (compiler-backend-avx512-mask-label
  [function : String]
  [current-label : String]
  [dst : i64]
  [suffix : String]) : String
  (compiler-backend-asm-label
    function
    (backend-cat5 "tail_mask_" current-label "_v" (int->string dst) suffix)))

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
                (backend-cat5
                  "    "
                  (compiler-backend-avx512-vector-move elem-ty)
                  " "
                  (compiler-backend-avx2-indexed-addr elem-ty)
                  (backend-cat5 ", " dst-reg "\n" "" ""))))]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(ErrBackendReg message)
        (ErrCompilerBackend
          (compiler-diagnostic-with-message instr-diag message))])
    (compiler-backend-avx512-shape-diagnostic instr-diag elem-ty lanes)))

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
                      (backend-cat5
                        "    "
                        mnemonic
                        " "
                        rhs-reg
                        (backend-cat5 ", " lhs-reg ", " dst-reg "\n")))]
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
                (backend-cat5
                  "    "
                  (compiler-backend-avx512-vector-move elem-ty)
                  " "
                  value-reg
                  (backend-cat5
                    ", "
                    (compiler-backend-avx2-indexed-addr elem-ty)
                    "\n"
                    ""
                    ""))))]
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
                    [body-asm : String
                      (string-append
                        (backend-cat5
                          "    subq %rax, %rcx\n    cmpq $"
                          (int->string lanes)
                          ", %rcx\n    jge "
                          full-label
                          "\n")
                        (string-append
                          (backend-cat4
                            "    testq %rcx, %rcx\n    jle "
                            zero-label
                            "\n    movl $1, %eax\n    shll %cl, %eax\n"
                            "")
                          (string-append
                            (backend-cat5
                              "    subl $1, %eax\n    kmovw %eax, "
                              dst-reg
                              "\n    jmp "
                              done-label
                              "\n")
                            (string-append
                              (backend-cat5
                                full-label
                                ":\n    movl $"
                                (int->string full-mask)
                                ", %eax\n    kmovw %eax, "
                                dst-reg)
                              (string-append
                                (backend-cat5
                                  "\n    jmp "
                                  done-label
                                  "\n"
                                  zero-label
                                  ":\n")
                                (backend-cat5
                                  "    xorl %eax, %eax\n    kmovw %eax, "
                                  dst-reg
                                  "\n"
                                  done-label
                                  ":\n"))))))]
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
  (if (compiler-backend-avx512-shape-ok? elem-ty lanes)
    (match (compiler-backend-avx512-mask-value-reg assignments mask "load mask")
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
                    (backend-cat5
                      "    "
                      (compiler-backend-avx512-vector-move elem-ty)
                      " "
                      (compiler-backend-avx2-indexed-addr elem-ty)
                      (backend-cat5
                        ", "
                        dst-reg
                        (backend-cat3 "{" mask-reg "}{z}\n")
                        ""
                        ""))))]
              [(ErrCompilerBackend message)
                (ErrCompilerBackend
                  (compiler-backend-apply-instr-diagnostic message instr-diag))])]
          [(ErrBackendReg message)
            (ErrCompilerBackend
              (compiler-diagnostic-with-message instr-diag message))])]
      [(ErrBackendReg message)
        (ErrCompilerBackend
          (compiler-diagnostic-with-message instr-diag message))])
    (compiler-backend-avx512-shape-diagnostic instr-diag elem-ty lanes)))

(define (compiler-backend-emit-avx512-predicated-store
  [assignments : CompilerRegAssignmentList]
  [base : CompilerIrValue]
  [index : CompilerIrValue]
  [value : CompilerIrValue]
  [mask : CompilerIrValue]
  [lanes : i64]
  [elem-ty : AstType]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
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
                    (backend-cat5
                      "    "
                      (compiler-backend-avx512-vector-move elem-ty)
                      " "
                      value-reg
                      (backend-cat5
                        ", "
                        (compiler-backend-avx2-indexed-addr elem-ty)
                        (backend-cat3 "{" mask-reg "}\n")
                        ""
                        ""))))]
              [(ErrCompilerBackend message)
                (ErrCompilerBackend
                  (compiler-backend-apply-instr-diagnostic message instr-diag))])]
          [(ErrBackendReg message)
            (ErrCompilerBackend
              (compiler-diagnostic-with-message instr-diag message))])]
      [(ErrBackendReg message)
        (ErrCompilerBackend
          (compiler-diagnostic-with-message instr-diag message))])
    (compiler-backend-avx512-shape-diagnostic instr-diag elem-ty lanes)))

(define (compiler-backend-mask-binop-mnemonic [op : CompilerIrMaskBinOp]) : String
  (match op
    [(IrMaskAnd) "kandw"]
    [(IrMaskOr) "korw"]))

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
                  (backend-cat5
                    "    "
                    (compiler-backend-mask-binop-mnemonic op)
                    " "
                    rhs-reg
                    (backend-cat5 ", " lhs-reg ", " dst-reg "\n")))]
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
                  (backend-cat5 "    knotw " src-reg ", " dst-reg "\n")
                  (backend-cat5
                    "    movl $"
                    (int->string full-mask)
                    ", %eax\n    kmovw %eax, %k7\n    kandw %k7, "
                    dst-reg
                    (backend-cat3 ", " dst-reg "\n"))))]
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
    (if (= full-mask 0)
      (compiler-backend-avx512-shape-diagnostic instr-diag (AstTyI64) lanes)
      (match (compiler-backend-avx512-mask-value-reg
        assignments
        src
        "reduce source")
        [(OkBackendReg src-reg)
          (OkCompilerBackend
            (string-append
              (backend-cat5
                "    kmovw "
                src-reg
                ", %eax\n"
                (match op
                  [(IrMaskReduceAny) "    testl %eax, %eax\n    setne %al\n"]
                  [(IrMaskReduceAll)
                    (backend-cat5
                      "    andl $"
                      (int->string full-mask)
                      ", %eax\n    cmpl $"
                      (int->string full-mask)
                      ", %eax\n    sete %al\n")])
                "    movzbq %al, %rax\n")
              (compiler-backend-emit-store-var-with-plan assignments dst "%rax")))]
        [(ErrBackendReg message)
          (ErrCompilerBackend
            (compiler-diagnostic-with-message instr-diag message))]))))

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
            [_ (compiler-backend-plan-uses-reg? (box-get rest) reg)])])]))

(define (compiler-backend-plan-uses-callee-regs?
  [assignments : CompilerRegAssignmentList]) : bool
  (or
    (compiler-backend-plan-uses-reg? assignments "%r12")
    (or
      (compiler-backend-plan-uses-reg? assignments "%r13")
      (or
        (compiler-backend-plan-uses-reg? assignments "%r14")
        (compiler-backend-plan-uses-reg? assignments "%r15")))))

(define (compiler-backend-frame-slots
  [vars : i64]
  [assignments : CompilerRegAssignmentList]) : i64
  (if (compiler-backend-plan-uses-callee-regs? assignments)
    (+ vars 4)
    vars))

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
  (backend-cat4 ".L" (compiler-backend-asm-safe-symbol function) "_" label))

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
          (backend-cat5
            "    movl $"
            (int->string frame)
            ", %eax\n    callq __chkstk\n    subq %rax, %rsp\n"
            ""
            "")
          (backend-cat4 "    subq $" (int->string frame) ", %rsp\n" ""))]
      [(BackendTargetLinux)
        (backend-cat4 "    subq $" (int->string frame) ", %rsp\n" "")])))

(define (compiler-backend-emit-store-var [var-id : i64] [reg : String]) : String
  (backend-cat5 "    movq " reg ", " (compiler-backend-slot var-id) "\n"))

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
    (backend-cat5 "    " (compiler-backend-float-move ty) " " reg ", ")
    (string-append (compiler-backend-slot var-id) "\n")))

(define (compiler-backend-emit-store-xmm-var [var-id : i64] [reg : String]) : String
  (compiler-backend-emit-store-float-var var-id reg (AstTyF64)))

(define (compiler-backend-emit-load-var-with-plan
  [assignments : CompilerRegAssignmentList]
  [var-id : i64]
  [reg : String]) : String
  (match (compiler-reg-assignment-lookup assignments var-id)
    [(CompilerRegSomeLocation location)
      (match location
        [(CompilerRegRegister home)
          (if (string-eq home reg)
            ""
            (backend-cat5 "    movq " home ", " reg "\n"))]
        [(CompilerRegSpill offset)
          (backend-cat5
            "    movq "
            (compiler-backend-frame-offset offset)
            ", "
            reg
            "\n")])]
    [(CompilerRegNoLocation)
      (backend-cat5 "    movq " (compiler-backend-slot var-id) ", " reg "\n")]))

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
            (backend-cat5 "    movq " reg ", " home "\n"))]
        [(CompilerRegSpill offset)
          (backend-cat5
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
              (backend-cat5 "    " mov (backend-cat3 " " home ", ") reg "\n"))]
          [(CompilerRegSpill offset)
            (backend-cat5
              "    "
              mov
              (backend-cat3 " " (compiler-backend-frame-offset offset) ", ")
              reg
              "\n")])]
      [(CompilerRegNoLocation)
        (backend-cat5
          "    "
          mov
          (backend-cat3 " " (compiler-backend-slot var-id) ", ")
          reg
          "\n")])))

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
              (backend-cat5 "    " mov (backend-cat3 " " reg ", ") home "\n"))]
          [(CompilerRegSpill offset)
            (backend-cat5
              "    "
              mov
              (backend-cat3 " " reg ", ")
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
    (backend-cat5
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
    (backend-cat5
      "    movq "
      (compiler-backend-callee-save-slot vars idx)
      ", "
      reg
      "\n")
    ""))

(define (compiler-backend-emit-save-callee-regs
  [assignments : CompilerRegAssignmentList]
  [vars : i64]) : String
  (string-append
    (compiler-backend-emit-save-callee-reg assignments vars "%r12" 0)
    (string-append
      (compiler-backend-emit-save-callee-reg assignments vars "%r13" 1)
      (string-append
        (compiler-backend-emit-save-callee-reg assignments vars "%r14" 2)
        (compiler-backend-emit-save-callee-reg assignments vars "%r15" 3)))))

(define (compiler-backend-emit-restore-callee-regs
  [assignments : CompilerRegAssignmentList]
  [vars : i64]) : String
  (string-append
    (compiler-backend-emit-restore-callee-reg assignments vars "%r15" 3)
    (string-append
      (compiler-backend-emit-restore-callee-reg assignments vars "%r14" 2)
      (string-append
        (compiler-backend-emit-restore-callee-reg assignments vars "%r13" 1)
        (compiler-backend-emit-restore-callee-reg assignments vars "%r12" 0)))))

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
        (or
          (and (>= c #a') (<= c #z'))
          (or (and (>= c #0') (<= c #9')) (= c #_'))))
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

(define (compiler-backend-asm-safe-symbol [name : String]) : String
  (let
    [i : i64 0]
    [n : i64 (string-length name)]
    [out : String ""]
    (begin
      (while (< i n)
        (let
          [c : char (string-ref name i)]
          (begin
            (set!
              out
              (string-append out (compiler-backend-symbol-char name i c)))
            (set! i (+ i 1)))))
      out)))

(define (compiler-backend-user-symbol [name : String]) : String
  (if (string-eq name "main")
    "main"
    (string-append "_tl_" (compiler-backend-asm-safe-symbol name))))

(define (compiler-backend-closure-descriptor-label [name : String]) : String
  (string-append ".L_tl_fn_desc_" (compiler-backend-asm-safe-symbol name)))

(define (compiler-backend-closure-entry-label [name : String]) : String
  (string-append ".L_tl_fn_entry_" (compiler-backend-asm-safe-symbol name)))

(define (compiler-backend-runtime-user-symbol? [name : String]) : bool
  (string-eq name "env-path-separator"))

(define (compiler-backend-link-symbol
  [name : String]
  [plan : CompilerBackendRuntimePlan]) : String
  (if (compiler-backend-plan-provides? plan name)
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
        (and
          (string-eq link-symbol name)
          (compiler-backend-plan-provides? plan name))
        (not (compiler-backend-function-list-defines? functions name)))
        (if (compiler-backend-runtime-user-symbol? name)
          (compiler-backend-user-symbol name)
          name)
        (compiler-backend-link-symbol link-symbol plan)))
    (if (and
      (compiler-backend-plan-provides? plan name)
      (not (compiler-backend-function-list-defines? functions name)))
      (if (compiler-backend-runtime-user-symbol? name)
        (compiler-backend-user-symbol name)
        name)
      (compiler-backend-user-symbol name))))

(define (compiler-backend-call-symbol-index
  [name : String]
  [plan : CompilerBackendRuntimePlan]
  [index : CompilerBackendProgramIndex]) : String
  (if (compiler-backend-index-extern-references? index name)
    (let
      [link-symbol : String (compiler-backend-index-extern-link-symbol index name)]
      (if (and
        (and
          (string-eq link-symbol name)
          (compiler-backend-plan-provides? plan name))
        (not (compiler-backend-index-function-defines? index name)))
        (if (compiler-backend-runtime-user-symbol? name)
          (compiler-backend-user-symbol name)
          name)
        (compiler-backend-asm-safe-symbol link-symbol)))
      (if (and
        (compiler-backend-plan-provides? plan name)
        (not (compiler-backend-index-function-defines? index name)))
      (if (compiler-backend-runtime-user-symbol? name)
        (compiler-backend-user-symbol name)
        name)
      (compiler-backend-user-symbol name))))

(define (compiler-backend-function-label-scope
  [index : CompilerBackendProgramIndex]
  [name : String]) : String
  (match (string-i64-map-get (struct-get index functions) name)
    [(StringI64MapFound slot) (backend-cat3 "f" (int->string slot) "")]
    [(StringI64MapMissing) (compiler-backend-user-symbol name)]))

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
    [(AstTyRegion _ inner) (compiler-backend-type-size (box-get inner))]
    [(AstTyEnum _) 8]
    [(AstTyEnumArgs _ _) 8]
    [(AstTyStruct _) 8]
    [(AstTyStructArgs _ _) 8]
    [(AstTyString) 8]
    [(AstTyStr) 8]
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

(define (compiler-backend-escape-string [text : String]) : String
  (let
    [i : i64 0]
    [n : i64 (string-length text)]
    [buf : TextBuf (text-buf-empty)]
    (begin
      (while (< i n)
        (let
          [c : char (string-ref text i)]
          (begin
            (set!
              buf
              (text-buf-append
                buf
                (compiler-backend-escape-string-byte text i c)))
            (set! i (+ i 1)))))
      (text-buf-render buf))))

(define (compiler-backend-quoted-gas-string [text : String]) : String
  (string-append
    "\""
    (string-append (compiler-backend-escape-string text) "\"")))

(define (compiler-backend-string-label-suffix [text : String]) : String
  (let
    [i : i64 0]
    [n : i64 (string-length text)]
    [buf : TextBuf (text-buf-empty)]
    (begin
      (while (< i n)
        (begin
          (set!
            buf
            (text-buf-append
              buf
              (compiler-backend-hex-byte
                (compiler-backend-char-code (string-ref text i)))))
          (set! i (+ i 1))))
      (if (= n 0)
        "empty"
        (text-buf-render buf)))))

(define (compiler-backend-string-data-label [text : String]) : String
  (string-append ".L_tl_str_data_" (compiler-backend-string-label-suffix text)))

(define (compiler-backend-string-fat-label [text : String]) : String
  (string-append ".L_tl_str_" (compiler-backend-string-label-suffix text)))

(define (compiler-backend-f64-label [text : String]) : String
  (string-append ".L_tl_f64_" (compiler-backend-string-label-suffix text)))

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
          (backend-cat5
            "    "
            mov
            (backend-cat3 " " (compiler-backend-user-symbol name) "(%rip), ")
            reg
            "\n"))]
      [(IrValueF64 text)
        (if (compiler-backend-f64-type? ty)
          (OkCompilerBackend
            (backend-cat5
              "    movsd "
              (compiler-backend-f64-label text)
              "(%rip), "
              reg
              "\n"))
          (OkCompilerBackend
            (string-append
              (backend-cat5
                "    movsd "
                (compiler-backend-f64-label text)
                "(%rip), "
                reg
                "\n")
              (backend-cat5 "    cvtsd2ss " reg ", " reg "\n"))))]
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

(define (compiler-backend-emit-load-i64-immediate [n : i64] [reg : String]) : String
  (if (= n 0)
    (backend-cat5 "    xorq " reg ", " reg "\n")
    (backend-cat5 "    movq $" (int->string n) ", " reg "\n")))

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
        (backend-cat5
          "    movq "
          (compiler-backend-user-symbol name)
          "(%rip), "
          reg
          "\n"))]
    [(IrValueGlobalAddr name)
      (OkCompilerBackend
        (backend-cat5
          "    leaq "
          (compiler-backend-user-symbol name)
          "(%rip), "
          reg
          "\n"))]
    [(IrValueFunction name)
      (OkCompilerBackend
        (backend-cat5
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
        (backend-cat5
          "    leaq "
          (compiler-backend-string-fat-label text)
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

(define (compiler-backend-emit-load-memory [addr : String] [ty : AstType]) : String
  (let
    [size : i64 (compiler-backend-type-size ty)]
    (cond
      [(= size 8) (backend-cat3 "    movq " addr ", %rax\n")]
      [(= size 4)
        (if (compiler-backend-type-signed? ty)
          (backend-cat3 "    movslq " addr ", %rax\n")
          (backend-cat3 "    movl " addr ", %eax\n"))]
      [(= size 2)
        (if (compiler-backend-type-signed? ty)
          (backend-cat3 "    movswq " addr ", %rax\n")
          (backend-cat3 "    movzwq " addr ", %rax\n"))]
      [(= size 1)
        (if (compiler-backend-type-signed? ty)
          (backend-cat3 "    movsbq " addr ", %rax\n")
          (backend-cat3 "    movzbq " addr ", %rax\n"))]
      [else ""])))

(define (compiler-backend-emit-load-float-memory
  [addr : String]
  [reg : String]
  [ty : AstType]) : String
  (backend-cat5
    "    "
    (compiler-backend-float-move ty)
    (backend-cat3 " " addr ", ")
    reg
    "\n"))

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
    [(= size 4) "%r15d"]
    [(= size 2) "%r15w"]
    [else "%r15b"]))

(define (compiler-backend-emit-load-register [reg : String] [ty : AstType]) : String
  (let
    [size : i64 (compiler-backend-type-size ty)]
    (cond
      [(= size 8) (backend-cat3 "    movq " reg ", %rax\n")]
      [(= size 4)
        (if (compiler-backend-type-signed? ty)
          (backend-cat3
            "    movslq "
            (compiler-backend-reg-part reg size)
            ", %rax\n")
          (backend-cat3
            "    movl "
            (compiler-backend-reg-part reg size)
            ", %eax\n"))]
      [(= size 2)
        (if (compiler-backend-type-signed? ty)
          (backend-cat3
            "    movswq "
            (compiler-backend-reg-part reg size)
            ", %rax\n")
          (backend-cat3
            "    movzwq "
            (compiler-backend-reg-part reg size)
            ", %rax\n"))]
      [(= size 1)
        (if (compiler-backend-type-signed? ty)
          (backend-cat3
            "    movsbq "
            (compiler-backend-reg-part reg size)
            ", %rax\n")
          (backend-cat3
            "    movzbq "
            (compiler-backend-reg-part reg size)
            ", %rax\n"))]
      [else ""])))

(define (compiler-backend-emit-store-rax-to-memory
  [addr : String]
  [ty : AstType]) : String
  (let
    [size : i64 (compiler-backend-type-size ty)]
    (cond
      [(= size 8) (backend-cat3 "    movq %rax, " addr "\n")]
      [(= size 4) (backend-cat3 "    movl %eax, " addr "\n")]
      [(= size 2) (backend-cat3 "    movw %ax, " addr "\n")]
      [(= size 1) (backend-cat3 "    movb %al, " addr "\n")]
      [else ""])))

(define (compiler-backend-emit-store-xmm-to-memory
  [addr : String]
  [reg : String]
  [ty : AstType]) : String
  (backend-cat5
    "    "
    (compiler-backend-float-move ty)
    (backend-cat3 " " reg ", ")
    addr
    "\n"))

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
              (backend-cat5
                "    "
                mnemonic
                " "
                imm
                (backend-cat3 ", " addr "\n")))))]
      [(CompilerBackendNoImmediate) (CompilerBackendNoAsm)])))

(define (compiler-backend-avx2-vector-reduce-move-scalar [elem-ty : AstType]) : String
  (match elem-ty
    [(AstTyI32) "    vmovd %xmm0, %eax\n"]
    [_ "    vmovq %xmm0, %rax\n"]))

(define (compiler-backend-avx2-vector-reduce-horizontal-asm
  [mnemonic : String]
  [ymm : String]
  [xmm : String]
  [elem-ty : AstType]) : String
  (match elem-ty
    [(AstTyI64)
      (string-append
        (backend-cat5
          "    vextracti128 $1, "
          ymm
          ", %xmm0\n    "
          mnemonic
          (backend-cat3 " %xmm0, " xmm ", %xmm0\n"))
        (backend-cat4
          "    vpsrldq $8, %xmm0, %xmm1\n    "
          mnemonic
          " %xmm1, %xmm0, %xmm0\n"
          ""))]
    [(AstTyI32)
      (string-append
        (backend-cat5
          "    vextracti128 $1, "
          ymm
          ", %xmm0\n    "
          mnemonic
          (backend-cat3 " %xmm0, " xmm ", %xmm0\n"))
        (string-append
          (backend-cat4
            "    vpsrldq $8, %xmm0, %xmm1\n    "
            mnemonic
            " %xmm1, %xmm0, %xmm0\n"
            "")
          (backend-cat4
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
                            "%rax"
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
    [(AstTyI64)
      (string-append
        (string-append
          (backend-cat5
            "    vextracti64x4 $1, "
            zmm
            ", %ymm0\n    "
            mnemonic
            (backend-cat3 " %ymm0, " ymm ", %ymm0\n"))
          (backend-cat4
            "    vextracti128 $1, %ymm0, %xmm1\n    "
            mnemonic
            " %xmm1, %xmm0, %xmm0\n"
            ""))
        (backend-cat4
          "    vpsrldq $8, %xmm0, %xmm1\n    "
          mnemonic
          " %xmm1, %xmm0, %xmm0\n"
          ""))]
    [(AstTyI32)
      (string-append
        (string-append
          (string-append
            (backend-cat5
              "    vextracti64x4 $1, "
              zmm
              ", %ymm0\n    "
              mnemonic
              (backend-cat3 " %ymm0, " ymm ", %ymm0\n"))
            (backend-cat4
              "    vextracti128 $1, %ymm0, %xmm1\n    "
              mnemonic
              " %xmm1, %xmm0, %xmm0\n"
              ""))
          (backend-cat4
            "    vpsrldq $8, %xmm0, %xmm1\n    "
            mnemonic
            " %xmm1, %xmm0, %xmm0\n"
            ""))
        (backend-cat4
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
                            "%rax"
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

(define (compiler-backend-emit-load-typed-value-with-plan
  [assignments : CompilerRegAssignmentList]
  [value : CompilerIrValue]
  [ty : AstType]) : ResultCompilerBackend
  (if (compiler-backend-float-type? ty)
    (compiler-backend-emit-load-float-value-with-plan
      assignments
      value
      ty
      "%xmm0")
    (match value
      [(IrValueVar id)
        (match (compiler-reg-assignment-lookup assignments id)
          [(CompilerRegSomeLocation location)
            (match location
              [(CompilerRegRegister home)
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
            (backend-cat3 (compiler-backend-user-symbol name) "(%rip)" "")
            ty))]
      [(IrValueGlobalAddr name)
        (OkCompilerBackend
          (backend-cat5
            "    leaq "
            (compiler-backend-user-symbol name)
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
    ty))

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
        (compiler-backend-global-type-lookup rest name))]))

(define (compiler-backend-global-types [globals : CompilerIrGlobalList]) : CompilerBackendGlobalTypeList
  (match globals
    [(IrGlobalNil) (CompilerBackendGlobalTypeNil)]
    [(IrGlobalCons global rest)
      (match global
        [(IrGlobal name ty _)
          (CompilerBackendGlobalTypeCons
            name
            ty
            (compiler-backend-global-types (box-get rest)))])]))

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
    (backend-cat5
      "    "
      mnemonic
      (compiler-backend-int-instruction-suffix ty)
      " "
      rhs)
    (backend-cat3 ", " lhs "\n")))

(define (compiler-backend-binop-cmp-set-asm
  [ty : AstType]
  [rhs : String]
  [lhs : String]
  [setcc : String]) : String
  (string-append
    (backend-cat5
      "    cmp"
      (compiler-backend-int-instruction-suffix ty)
      " "
      rhs
      ", ")
    (string-append
      lhs
      (backend-cat4 "\n    " setcc " %al\n    movzbl %al, %eax\n" ""))))

(define (compiler-backend-binop-cmp-reg-asm
  [ty : AstType]
  [rhs : String]
  [lhs : String]) : String
  (string-append
    (backend-cat5
      "    cmp"
      (compiler-backend-int-instruction-suffix ty)
      " "
      rhs
      ", ")
    (string-append lhs "\n")))

(define (compiler-backend-emit-load-i64-absolute [n : i64] [reg : String]) : String
  (backend-cat5 "    movabsq $" (int->string n) ", " reg "\n"))

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
    [rhs : String (compiler-backend-sized-reg "%rbx" ty)]
    (string-append
      (compiler-backend-binop-reg-asm "test" ty rhs rhs)
      "    jne 1f\n    call tl_div_abort\n1:\n")))

(define (compiler-backend-div-overflow-guard-asm [ty : AstType]) : String
  (if (compiler-backend-type-signed? ty)
    (let
      [lhs : String (compiler-backend-sized-reg "%rax" ty)]
      [rhs : String (compiler-backend-sized-reg "%rbx" ty)]
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

(define (compiler-backend-binop-divmod-asm
  [ty : AstType]
  [want-remainder : bool]) : String
  (let
    [size : i64 (compiler-backend-type-size ty)]
    [signed : bool (compiler-backend-type-signed? ty)]
    (string-append
      (compiler-backend-divmod-guard-asm ty)
      (cond
        [(= size 1)
          (string-append
            (if signed
              "    cbw\n    idivb %bl\n"
              "    andw $0x00ff, %ax\n    divb %bl\n")
            (if want-remainder
              "    movb %ah, %al\n"
              ""))]
        [(= size 2)
          (string-append
            (if signed
              "    cwd\n    idivw %bx\n"
              "    xorw %dx, %dx\n    divw %bx\n")
            (if want-remainder
              "    movw %dx, %ax\n"
              ""))]
        [(= size 4)
          (string-append
            (if signed
              "    cdq\n    idivl %ebx\n"
              "    xorl %edx, %edx\n    divl %ebx\n")
            (if want-remainder
              "    movl %edx, %eax\n"
              ""))]
        [else
          (string-append
            (if signed
              "    cqto\n    idivq %rbx\n"
              "    xorq %rdx, %rdx\n    divq %rbx\n")
            (if want-remainder
              "    movq %rdx, %rax\n"
              ""))]))))

(define (compiler-backend-shift-count-width [ty : AstType]) : i64
  (* (compiler-backend-type-size ty) 8))

(define (compiler-backend-shift-count-valid? [count : i64] [ty : AstType]) : bool
  (and (>= count 0) (< count (compiler-backend-shift-count-width ty))))

(define (compiler-backend-shift-guard-asm [ty : AstType]) : String
  (string-append
    "    testq %rbx, %rbx\n    jge 1f\n    call tl_shift_abort\n1:\n"
    (backend-cat5
      "    cmpq $"
      (int->string (compiler-backend-shift-count-width ty))
      ", %rbx\n    jb 1f\n    call tl_shift_abort\n1:\n"
      ""
      "")))

(define (compiler-backend-binop-shift-asm
  [mnemonic : String]
  [ty : AstType]
  [lhs : String]) : String
  (string-append
    (compiler-backend-shift-guard-asm ty)
    (string-append
      "    movq %rbx, %rcx\n"
      (backend-cat5
        "    "
        mnemonic
        (compiler-backend-int-instruction-suffix ty)
        " %cl, "
        (backend-cat3 lhs "\n" "")))))

(define (compiler-backend-binop-asm [op : CompilerIrBinOp] [ty : AstType]) : String
  (let
    [lhs : String (compiler-backend-sized-reg "%rax" ty)]
    [rhs : String (compiler-backend-sized-reg "%rbx" ty)]
    [suffix : String (compiler-backend-int-instruction-suffix ty)]
    (match op
      [(IrBinAdd) (compiler-backend-binop-reg-asm "add" ty rhs lhs)]
      [(IrBinSub) (compiler-backend-binop-reg-asm "sub" ty rhs lhs)]
      [(IrBinMul)
        (if (= (compiler-backend-type-size ty) 1)
          "    imulq %rbx, %rax\n"
          (compiler-backend-binop-reg-asm "imul" ty rhs lhs))]
      [(IrBinDiv) (compiler-backend-binop-divmod-asm ty false)]
      [(IrBinMod) (compiler-backend-binop-divmod-asm ty true)]
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
      (backend-cat4 "    " setcc " %al\n    movzbl %al, %eax\n" ""))))

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
          (backend-cat5
            "    "
            mnemonic
            (compiler-backend-int-instruction-suffix ty)
            " "
            imm)
          (backend-cat3 ", " (compiler-backend-sized-reg "%rax" ty) "\n")))
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
          (backend-cat3 "    imulq " imm ", %rax\n")
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
    [(IrUnNot) "    testq %rax, %rax\n    sete %al\n    movzbl %al, %eax\n"]
    [(IrUnBitNot) "    notq %rax\n"]))

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
        "    movabsq $0x8000000000000000, %rax\n    movq %rax, %xmm1\n    xorpd %xmm1, %xmm0\n")]
    [_
      (ErrCompilerBackend
        (compiler-diagnostic-at-start "" "backend: unsupported f64 unary op"))]))

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
      (match (compiler-backend-emit-load-value-with-plan assignments lhs "%rax")
        [(OkCompilerBackend lhs-asm)
          (match (compiler-backend-immediate-operand rhs)
            [(CompilerBackendSomeImmediate imm)
              (match (compiler-backend-binop-immediate-asm op imm operand-ty)
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
                    "%rbx")
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
                    [(ErrCompilerBackend message) (ErrCompilerBackend message)])])]
            [(CompilerBackendNoImmediate)
              (match (compiler-backend-emit-load-value-with-plan
                assignments
                rhs
                "%rbx")
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
                [(ErrCompilerBackend message) (ErrCompilerBackend message)])])]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)]))))

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
            (match (compiler-backend-immediate-operand rhs)
              [(CompilerBackendSomeImmediate imm)
                (match (compiler-backend-binop-immediate-asm op imm operand-ty)
                  [(CompilerBackendSomeAsm op-asm)
                    (OkCompilerBackend
                      (string-append lhs-asm (string-append op-asm return-tail)))]
                  [(CompilerBackendNoAsm)
                    (match (compiler-backend-emit-load-value-with-plan
                      assignments
                      rhs
                      "%rbx")
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
                  "%rbx")
                  [(OkCompilerBackend rhs-asm)
                    (OkCompilerBackend
                      (string-append
                        lhs-asm
                        (string-append
                          rhs-asm
                          (string-append
                            (compiler-backend-binop-asm op operand-ty)
                            return-tail))))]
                  [(ErrCompilerBackend message) (ErrCompilerBackend message)])])]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)])))))

(define (compiler-backend-jump-label [function : String] [label : String]) : String
  (backend-cat4 "    jmp " (compiler-backend-asm-label function label) "\n" ""))

(define (compiler-backend-jump-target-is-fallthrough?
  [target : String]
  [fallthrough : CompilerBackendMaybeLabel]) : bool
  (match fallthrough
    [(CompilerBackendSomeLabel label) (string-eq target label)]
    [(CompilerBackendNoLabel) false]))

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
                  (backend-cat4
                    "    jne "
                    (compiler-backend-asm-label function true-label)
                    "\n"
                    "")
                  (if (compiler-backend-jump-target-is-fallthrough?
                    true-label
                    fallthrough)
                    (backend-cat4
                      "    je "
                      (compiler-backend-asm-label function false-label)
                      "\n"
                      "")
                    (backend-cat5
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
  (backend-cat5 "    " jcc " " (compiler-backend-asm-label function label) "\n"))

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
      (backend-cat5
        "    cmp"
        (compiler-backend-int-instruction-suffix ty)
        " "
        rhs
        ", ")
      (backend-cat3 (compiler-backend-sized-reg "%rax" ty) "\n" ""))))

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
              (match (compiler-backend-emit-load-value-with-plan
                assignments
                rhs
                "%rbx")
                [(OkCompilerBackend rhs-asm)
                  (OkCompilerBackend
                    (string-append
                      lhs-asm
                      (string-append
                        rhs-asm
                        (string-append
                          (compiler-backend-emit-compare-flags
                            op
                            (compiler-backend-sized-reg "%rbx" ty)
                            ty)
                          (compiler-backend-emit-compare-branch-jumps
                            function
                            true-label
                            false-label
                            fallthrough
                            true-jcc
                            false-jcc)))))]
                [(ErrCompilerBackend message) (ErrCompilerBackend message)])])]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)]))))

(define (compiler-backend-load-compare-type? [ty : AstType]) : bool
  (and
    (not (compiler-backend-float-type? ty))
    (= (compiler-backend-type-size ty) 8)))

(define (compiler-backend-emit-compare-memory-address-flags
  [rhs : String]
  [addr : String]) : String
  (backend-cat5 "    cmpq " rhs ", " addr "\n"))

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
                "%rbx")
                [(OkCompilerBackend rhs-asm)
                  (OkCompilerBackend
                    (string-append
                      ptr-asm
                      (string-append
                        rhs-asm
                        (string-append
                          (compiler-backend-emit-compare-memory-flags "%rbx")
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
                      "%rbx")
                      [(OkCompilerBackend rhs-asm)
                        (OkCompilerBackend
                          (string-append
                            base-asm
                            (string-append
                              rhs-asm
                              (string-append
                                (compiler-backend-emit-compare-memory-address-flags
                                  "%rbx"
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

(define (compiler-backend-emit-bounds-check
  [target : CompilerBackendTarget]
  [function : String]
  [assignments : CompilerRegAssignmentList]
  [index : CompilerIrValue]
  [length : CompilerIrValue]
  [ok-label : String]
  [plan : CompilerBackendRuntimePlan]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [program-index : CompilerBackendProgramIndex]) : ResultCompilerBackend
  (match (compiler-backend-emit-load-value-with-plan assignments index "%rax")
    [(OkCompilerBackend index-asm)
      (match (compiler-backend-emit-load-value-with-plan
        assignments
        length
        "%r11")
        [(OkCompilerBackend length-asm)
          (let
            [call-space : i64
              (compiler-backend-call-arg-space
                target
                (IrCallArgsNil)
                AstTypeNil)]
            [ok-symbol : String (compiler-backend-asm-label function ok-label)]
            (OkCompilerBackend
              (string-append
                index-asm
                (string-append
                  length-asm
                  (string-append
                    (backend-cat4
                      "    cmpq %r11, %rax\n    jb "
                      ok-symbol
                      "\n"
                      "")
                    (string-append
                      (compiler-backend-emit-call-space-sub call-space)
                      (backend-cat5
                        "    call "
                        (compiler-backend-call-symbol-index
                          "tl_oob_abort"
                          plan
                          program-index)
                        "\n"
                        (string-append
                          (compiler-backend-emit-call-space-add call-space)
                          (backend-cat4 ok-symbol ":\n" "" ""))
                        "")))))))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
    [(ErrCompilerBackend message) (ErrCompilerBackend message)]))

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
    (match (compiler-backend-emit-load-value-with-plan assignments src "%rax")
      [(OkCompilerBackend src-asm)
        (OkCompilerBackend
          (string-append
            src-asm
            (string-append
              (compiler-backend-unop-asm op)
              (compiler-backend-emit-store-var-with-plan assignments dst "%rax"))))]
      [(ErrCompilerBackend message) (ErrCompilerBackend message)])))

(define (compiler-backend-emit-addr-of
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [src : i64]) : ResultCompilerBackend
  (OkCompilerBackend
    (string-append
      (backend-cat5 "    leaq " (compiler-backend-slot src) ", " "%rax" "\n")
      (compiler-backend-emit-store-var-with-plan assignments dst "%rax"))))

(define (compiler-backend-gep-index-asm [scale : i64]) : String
  (if (= scale 1)
    "    addq %rbx, %rax\n"
    (if (or (= scale 2) (or (= scale 4) (= scale 8)))
      (backend-cat4 "    leaq (%rax,%rbx," (int->string scale) "), %rax\n" "")
      (string-append
        (backend-cat5 "    imulq $" (int->string scale) ", " "%rbx" "\n")
        "    addq %rbx, %rax\n"))))

(define (compiler-backend-gep-immediate-asm [disp : i64]) : CompilerBackendMaybeAsm
  (if (= disp 0)
    (CompilerBackendSomeAsm "")
    (if (compiler-backend-imm32? disp)
      (CompilerBackendSomeAsm
        (backend-cat4 "    addq $" (int->string disp) ", %rax\n" ""))
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
                  "%rbx")
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
              "%rbx")
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
    (backend-cat4 (int->string disp) "(%r10)" "" "")))

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
      (ErrCompilerBackend
        (compiler-diagnostic-at-start
          ""
          "backend: non-immediate fused gep load"))]))

(define (compiler-backend-emit-store-ptr
  [assignments : CompilerRegAssignmentList]
  [dst : CompilerIrValue]
  [src : CompilerIrValue]
  [ty : AstType]) : ResultCompilerBackend
  (match (compiler-backend-emit-load-value-with-plan assignments dst "%r10")
    [(OkCompilerBackend ptr-asm)
      (match (compiler-backend-emit-store-immediate-to-memory src "(%r10)" ty)
        [(CompilerBackendSomeAsm store-asm)
          (OkCompilerBackend (string-append ptr-asm store-asm))]
        [(CompilerBackendNoAsm)
          (match (compiler-backend-emit-load-typed-value-with-plan
            assignments
            src
            ty)
            [(OkCompilerBackend src-asm)
              (OkCompilerBackend
                (string-append
                  ptr-asm
                  (string-append
                    src-asm
                    (if (compiler-backend-float-type? ty)
                      (compiler-backend-emit-store-xmm-to-memory
                        "(%r10)"
                        "%xmm0"
                        ty)
                      (compiler-backend-emit-store-rax-to-memory "(%r10)" ty)))))]
            [(ErrCompilerBackend message) (ErrCompilerBackend message)])])]
    [(ErrCompilerBackend message) (ErrCompilerBackend message)]))

(define (compiler-backend-emit-store-to-gep
  [assignments : CompilerRegAssignmentList]
  [base : CompilerIrValue]
  [offset : CompilerIrValue]
  [elem-ty : AstType]
  [value : CompilerIrValue]
  [store-ty : AstType]) : ResultCompilerBackend
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
            (match (compiler-backend-emit-store-immediate-to-memory
              value
              addr
              store-ty)
              [(CompilerBackendSomeAsm store-asm)
                (OkCompilerBackend (string-append base-asm store-asm))]
              [(CompilerBackendNoAsm)
                (match (compiler-backend-emit-load-typed-value-with-plan
                  assignments
                  value
                  store-ty)
                  [(OkCompilerBackend value-asm)
                    (OkCompilerBackend
                      (string-append
                        base-asm
                        (string-append
                          value-asm
                          (if (compiler-backend-float-type? store-ty)
                            (compiler-backend-emit-store-xmm-to-memory
                              addr
                              "%xmm0"
                              store-ty)
                            (compiler-backend-emit-store-rax-to-memory
                              addr
                              store-ty)))))]
                  [(ErrCompilerBackend message) (ErrCompilerBackend message)])])]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)]))]
    [(CompilerBackendNoI64)
      (ErrCompilerBackend
        (compiler-diagnostic-at-start
          ""
          "backend: non-immediate fused gep store"))]))

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
  (backend-cat5 "cast_u64_float_" current-label "_v" (int->string dst) suffix))

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
        (backend-cat5 "    js " high-symbol "\n    cvtsi2" op "q %rax, %xmm0\n")
        (string-append
          (backend-cat3 "    jmp " done-symbol "\n")
          (string-append
            (backend-cat3 high-symbol ":\n" "")
            (string-append
              "    movq %rax, %r11\n    andq $1, %r11\n    shrq $1, %rax\n    orq %r11, %rax\n"
              (string-append
                (backend-cat5
                  "    cvtsi2"
                  op
                  "q %rax, %xmm0\n    add"
                  op
                  " %xmm0, %xmm0\n")
                (backend-cat3 done-symbol ":\n" "")))))))))

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
  [to-ty : AstType]) : ResultCompilerBackend
  (match (compiler-backend-emit-load-typed-value-with-plan
    assignments
    src
    from-ty)
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
  [to-ty : AstType]) : ResultCompilerBackend
  (cond
    [(and
        (opt-type-eq from-ty to-ty)
        (compiler-backend-value-same-home? assignments dst src))
      (OkCompilerBackend "")]
    [(and
        (compiler-backend-float-type? from-ty)
        (compiler-backend-float-type? to-ty))
      (compiler-backend-emit-float-to-float-cast
        assignments
        dst
        src
        from-ty
        to-ty)]
    [(and
        (not (compiler-backend-float-type? from-ty))
        (compiler-backend-float-type? to-ty))
      (compiler-backend-emit-int-to-float-cast
        function
        current-label
        assignments
        dst
        src
        from-ty
        to-ty)]
    [(and
        (compiler-backend-float-type? from-ty)
        (not (compiler-backend-float-type? to-ty)))
      (compiler-backend-emit-float-to-int-cast
        assignments
        dst
        src
        from-ty
        to-ty)]
    [else
      (match (compiler-backend-emit-load-typed-value-with-plan
        assignments
        src
        from-ty)
        [(OkCompilerBackend load)
          (OkCompilerBackend
            (string-append
              load
              (compiler-backend-emit-store-typed-var-with-plan
                assignments
                dst
                (if (compiler-backend-float-type? to-ty)
                  "%xmm0"
                  "%rax")
                to-ty)))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]))

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
    (backend-cat4 "    subq $" (int->string space) ", %rsp\n" "")))

(define (compiler-backend-emit-call-space-add [space : i64]) : String
  (if (= space 0)
    ""
    (backend-cat4 "    addq $" (int->string space) ", %rsp\n" "")))

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
            (compiler-backend-function-param-types (box-get rest) name))])]))

(define (compiler-backend-extern-param-types
  [externs : CompilerIrExternList]
  [name : String]) : AstTypeList
  (match externs
    [(IrExternNil) AstTypeNil]
    [(IrExternCons item rest)
      (match item
        [(IrExtern extern-name ty _ _ _)
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
            (compiler-backend-function-signature (box-get rest) name))])]))

(define (compiler-backend-extern-signature
  [externs : CompilerIrExternList]
  [name : String]) : CompilerBackendMaybeSignature
  (match externs
    [(IrExternNil) (CompilerBackendNoSignature)]
    [(IrExternCons item rest)
      (match item
        [(IrExtern extern-name ty _ _ _)
          (if (string-eq extern-name name)
            (match ty
              [(AstTyFunc args ret-ty)
                (CompilerBackendSomeSignature args (box-get ret-ty))]
              [_ (CompilerBackendNoSignature)])
            (compiler-backend-extern-signature (box-get rest) name))])]))

(define (compiler-backend-function-list-count
  [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(IrFunctionNil) 0]
    [(IrFunctionCons _ rest) (+ 1 (compiler-backend-function-list-count (box-get rest)))]))

(define (compiler-backend-extern-list-count [externs : CompilerIrExternList]) : i64
  (match externs
    [(IrExternNil) 0]
    [(IrExternCons _ rest) (+ 1 (compiler-backend-extern-list-count (box-get rest)))]))

(define (compiler-backend-program-index-functions-into
  [functions : CompilerIrFunctionList]
  [ids : StringI64Map]
  [signatures : (Array CompilerBackendMaybeSignature)]
  [index : i64]) : StringI64Map
  (match functions
    [(IrFunctionNil) ids]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction name params ret-ty _ _)
          (begin
            (array-set!
              signatures
              index
              (CompilerBackendSomeSignature
                (compiler-backend-param-type-list params)
                ret-ty))
            (compiler-backend-program-index-functions-into
              (box-get rest)
              (string-i64-map-put ids name index)
              signatures
              (+ index 1)))])]))

(define (compiler-backend-program-index-extern-signature [ty : AstType]) : CompilerBackendMaybeSignature
  (match ty
    [(AstTyFunc args ret-ty) (CompilerBackendSomeSignature args ret-ty)]
    [_ (CompilerBackendNoSignature)]))

(define (compiler-backend-program-index-extern-signatures-into
  [externs : CompilerIrExternList]
  [signature-ids : StringI64Map]
  [signatures : (Array CompilerBackendMaybeSignature)]
  [index : i64]) : StringI64Map
  (match externs
    [(IrExternNil) signature-ids]
    [(IrExternCons item rest)
      (match item
        [(IrExtern extern-name ty _ _ _)
          (begin
            (array-set!
              signatures
              index
              (compiler-backend-program-index-extern-signature ty))
            (compiler-backend-program-index-extern-signatures-into
              (box-get rest)
              (string-i64-map-put signature-ids extern-name index)
              signatures
              (+ index 1)))])]))

(define (compiler-backend-program-index-extern-references-into
  [externs : CompilerIrExternList]
  [reference-ids : StringI64Map]
  [link-symbols : (Array String)]
  [index : i64]) : StringI64Map
  (match externs
    [(IrExternNil) reference-ids]
    [(IrExternCons item rest)
      (match item
        [(IrExtern extern-name _ _ link-symbol _)
          (begin
            (array-set! link-symbols index link-symbol)
            (compiler-backend-program-index-extern-references-into
              (box-get rest)
              (string-i64-map-put
                (string-i64-map-put reference-ids extern-name index)
                link-symbol
                index)
              link-symbols
              (+ index 1)))])]))

(define (compiler-backend-program-index-build
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]) : CompilerBackendProgramIndex
  (let
    [function-count : i64 (compiler-backend-function-list-count functions)]
    [extern-count : i64 (compiler-backend-extern-list-count externs)]
    [function-signatures : (Array CompilerBackendMaybeSignature)
      (make-array CompilerBackendMaybeSignature function-count)]
    [extern-signatures : (Array CompilerBackendMaybeSignature)
      (make-array CompilerBackendMaybeSignature extern-count)]
    [extern-link-symbols : (Array String) (make-array String extern-count)]
    [function-ids : StringI64Map
      (compiler-backend-program-index-functions-into
        functions
        (string-i64-map-with-capacity (+ (* function-count 2) 1))
        function-signatures
        0)]
    [extern-signature-ids : StringI64Map
      (compiler-backend-program-index-extern-signatures-into
        externs
        (string-i64-map-with-capacity (+ (* extern-count 2) 1))
        extern-signatures
        0)]
    [extern-reference-ids : StringI64Map
      (compiler-backend-program-index-extern-references-into
        externs
        (string-i64-map-with-capacity (+ (* extern-count 4) 1))
        extern-link-symbols
        0)]
    (CompilerBackendProgramIndex
      function-ids
      function-signatures
      extern-signature-ids
      extern-signatures
      extern-reference-ids
      extern-link-symbols)))

(define (compiler-backend-index-function-signature
  [index : CompilerBackendProgramIndex]
  [name : String]) : CompilerBackendMaybeSignature
  (match (string-i64-map-get (struct-get index functions) name)
    [(StringI64MapFound slot)
      (array-ref (struct-get index function-signatures) slot)]
    [(StringI64MapMissing) (CompilerBackendNoSignature)]))

(define (compiler-backend-index-extern-signature
  [index : CompilerBackendProgramIndex]
  [name : String]) : CompilerBackendMaybeSignature
  (match (string-i64-map-get (struct-get index extern-signatures) name)
    [(StringI64MapFound slot)
      (array-ref (struct-get index extern-signature-values) slot)]
    [(StringI64MapMissing) (CompilerBackendNoSignature)]))

(define (compiler-backend-index-signature
  [index : CompilerBackendProgramIndex]
  [name : String]) : CompilerBackendMaybeSignature
  (match (compiler-backend-index-function-signature index name)
    [(CompilerBackendSomeSignature args ret-ty)
      (CompilerBackendSomeSignature args ret-ty)]
    [(CompilerBackendNoSignature)
      (compiler-backend-index-extern-signature index name)]))

(define (compiler-backend-index-function-defines?
  [index : CompilerBackendProgramIndex]
  [name : String]) : bool
  (string-i64-map-contains? (struct-get index functions) name))

(define (compiler-backend-index-extern-references?
  [index : CompilerBackendProgramIndex]
  [name : String]) : bool
  (string-i64-map-contains? (struct-get index extern-references) name))

(define (compiler-backend-index-extern-link-symbol
  [index : CompilerBackendProgramIndex]
  [name : String]) : String
  (match (string-i64-map-get (struct-get index extern-references) name)
    [(StringI64MapFound slot)
      (array-ref (struct-get index extern-link-symbols) slot)]
    [(StringI64MapMissing) name]))

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
  (cond
    [(string-eq name "tl_print_char") (ast-type-cons (AstTyChar) AstTypeNil)]
    [(string-eq name "tl_print_f64") (ast-type-cons (AstTyF64) AstTypeNil)]
    [else AstTypeNil]))

(define (compiler-backend-call-param-types
  [name : String]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]) : AstTypeList
  (match (compiler-backend-signature functions externs name)
    [(CompilerBackendSomeSignature param-types _) param-types]
    [(CompilerBackendNoSignature) (compiler-backend-runtime-param-types name)]))

(define (compiler-backend-extern-varargs-fixed-count
  [externs : CompilerIrExternList]
  [name : String]) : i64
  (match externs
    [(IrExternNil) -1]
    [(IrExternCons item rest)
      (match item
        [(IrExtern extern-name _ abi link-symbol _)
          (if (or (string-eq name extern-name) (string-eq name link-symbol))
            (match abi
              [(AstExternAbiCVarargs fixed-count) fixed-count]
              [_ -1])
            (compiler-backend-extern-varargs-fixed-count (box-get rest) name))])]))

(define (compiler-backend-varargs-linux-vector-count
  [types : AstTypeList]
  [float-idx : i64]
  [count : i64]) : i64
  (match types
    [(AstTypeNil) count]
    [(AstTypeCons ty rest)
      (let
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
        [rest : AstTypeList (box-get rest)]
        [tail : String
          (compiler-backend-windows-vararg-dup-asm
            rest
            fixed-count
            (+ position 1))]
        [reg : String (compiler-backend-windows-vararg-int-reg position)]
        (if (and
          (and (>= position fixed-count) (< position 4))
          (compiler-backend-float-type? ty))
          (backend-cat5
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
      (compiler-backend-extern-varargs-fixed-count externs name)]
    (if (< fixed-count 0)
      ""
      (match target
        [(BackendTargetLinux)
          (backend-cat5
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

;; Count the OUTGOING arguments that must be passed on the stack (#750). Walks
;; the args in order, tracking the integer/float/position banks exactly as
;; `compiler-backend-emit-call-args` does, and counts every arg whose bank is
;; already full.
(define (compiler-backend-call-stack-arg-count
  [target : CompilerBackendTarget]
  [args : CompilerIrCallArgs]
  [types : AstTypeList]
  [arg-index : i64]
  [int-idx : i64]
  [float-idx : i64]
  [position : i64]
  [stack-count : i64]) : i64
  (if (>= arg-index (compiler-backend-call-args-count args))
    stack-count
    (let
      [arg-ty : AstType
        (match types
          [(AstTypeCons ty _) ty]
          [(AstTypeNil) (AstTyI64)])]
      [rest-types : AstTypeList
        (match types
          [(AstTypeCons _ tail)
            (let
              [tail : AstTypeList (box-get tail)]
              tail)]
          [(AstTypeNil) AstTypeNil])]
      [is-float : bool (compiler-backend-float-type? arg-ty)]
      (compiler-backend-call-stack-arg-count
        target
        args
        rest-types
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
          stack-count)))))

;; Total %rsp adjustment reserved for a call's stack-passed args (#750):
;; `roundup16(shadow + stack-arg-count * 8)`. System V has no shadow space, so
;; this is 0 whenever every arg fits in registers.
(define (compiler-backend-call-arg-space
  [target : CompilerBackendTarget]
  [args : CompilerIrCallArgs]
  [types : AstTypeList]) : i64
  (compiler-backend-call-arg-space-from target args types 0 0 0 0))

(define (compiler-backend-call-arg-space-from
  [target : CompilerBackendTarget]
  [args : CompilerIrCallArgs]
  [types : AstTypeList]
  [arg-index : i64]
  [int-idx : i64]
  [float-idx : i64]
  [position : i64]) : i64
  (let
    [stack-count : i64
      (compiler-backend-call-stack-arg-count
        target
        args
        types
        arg-index
        int-idx
        float-idx
        position
        0)]
    (match target
      [(BackendTargetWindows) 0]
      [(BackendTargetLinux)
        (if (= stack-count 0)
          0
          (compiler-backend-round-up-16 (* stack-count 8)))])))

(define (compiler-backend-closure-call-arg-space
  [target : CompilerBackendTarget]
  [args : CompilerIrCallArgs]
  [types : AstTypeList]) : i64
  (compiler-backend-call-arg-space-from target args types 0 1 0 1))

(define (compiler-backend-windows-stack-arg-space [args : CompilerIrCallArgs]) : i64
  (let
    [arg-count : i64 (compiler-backend-call-args-count args)]
    (if (> arg-count 4)
      (compiler-backend-round-up-16 (* (- arg-count 4) 8))
      0)))

(define (compiler-backend-windows-closure-stack-arg-space
  [args : CompilerIrCallArgs]) : i64
  (let
    [arg-count : i64 (+ 1 (compiler-backend-call-args-count args))]
    (if (> arg-count 4)
      (compiler-backend-round-up-16 (* (- arg-count 4) 8))
      0)))

(define (compiler-backend-instr-needs-outgoing-space? [instr : CompilerIrInstr]) : bool
  (match instr
    [(IrInstrCall _ _ _ _) true]
    [(IrInstrCallIndirect _ _ _ _) true]
    [(IrInstrBoundsCheck _ _ _) true]
    [_ false]))

(define (compiler-backend-instrs-need-outgoing-space?
  [instrs : CompilerIrInstrList]) : bool
  (match instrs
    [(IrInstrNil) false]
    [(IrInstrCons instr rest)
      (if (compiler-backend-instr-needs-outgoing-space? instr)
        true
        (compiler-backend-instrs-need-outgoing-space? (box-get rest)))]))

(define (compiler-backend-blocks-need-outgoing-space?
  [blocks : CompilerIrBlockList]) : bool
  (match blocks
    [(IrBlockNil) false]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (if (compiler-backend-instrs-need-outgoing-space? instrs)
            true
            (compiler-backend-blocks-need-outgoing-space? (box-get rest)))])]))

(define (compiler-backend-instr-outgoing-stack-space [instr : CompilerIrInstr]) : i64
  (match instr
    [(IrInstrCall _ _ args _) (compiler-backend-windows-stack-arg-space args)]
    [(IrInstrCallIndirect _ _ args _)
      (compiler-backend-windows-closure-stack-arg-space args)]
    [_ 0]))

(define (compiler-backend-instrs-outgoing-stack-space
  [instrs : CompilerIrInstrList]
  [max-space : i64]) : i64
  (match instrs
    [(IrInstrNil) max-space]
    [(IrInstrCons instr rest)
      (compiler-backend-instrs-outgoing-stack-space
        (box-get rest)
        (compiler-reg-max
          max-space
          (compiler-backend-instr-outgoing-stack-space instr)))]))

(define (compiler-backend-blocks-outgoing-stack-space
  [blocks : CompilerIrBlockList]
  [max-space : i64]) : i64
  (match blocks
    [(IrBlockNil) max-space]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (compiler-backend-blocks-outgoing-stack-space
            (box-get rest)
            (compiler-backend-instrs-outgoing-stack-space instrs max-space))])]))

(define (compiler-backend-outgoing-frame-space
  [target : CompilerBackendTarget]
  [blocks : CompilerIrBlockList]) : i64
  (if (compiler-backend-blocks-need-outgoing-space? blocks)
    (match target
      [(BackendTargetWindows)
        (compiler-backend-round-up-16
          (+
            (compiler-backend-outgoing-shadow-space target)
            (compiler-backend-blocks-outgoing-stack-space blocks 0)))]
      [(BackendTargetLinux) (compiler-backend-outgoing-shadow-space target)])
    0))

(define (compiler-backend-emit-call-args
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
          [(AstTypeCons ty _) ty]
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
        ;; Stack-passed arg: load into a scratch register that no other
        ;; call arg uses (%xmm15 / %r11, matching the legacy backend) so an
        ;; earlier register arg in xmm0/%rax is never clobbered, then
        ;; store it at its %rsp offset.
        (match (if is-float
          (compiler-backend-emit-load-float-value-with-plan
            assignments
            value
            arg-ty
            "%xmm15")
          (compiler-backend-emit-load-value-with-plan assignments value "%r11"))
          [(OkCompilerBackend head)
            (match (compiler-backend-emit-call-args
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
                (OkCompilerBackend
                  (backend-cat5
                    head
                    (if is-float
                      (backend-cat4
                        "    "
                        (compiler-backend-float-move arg-ty)
                        " %xmm15, "
                        "")
                      "    movq %r11, ")
                    (int->string
                      (compiler-backend-outgoing-stack-arg-offset
                        target
                        stack-idx))
                    "(%rsp)\n"
                    tail))]
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
                (match (compiler-backend-emit-call-args
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

(define (compiler-backend-emit-phi-source-to-var
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [source : CompilerBackendPhiSource]
  [ty : AstType]) : ResultCompilerBackend
  (match source
    [(BackendPhiSourceTemp)
      (OkCompilerBackend
        (compiler-backend-emit-store-var-with-plan assignments dst "%r11"))]
    [(BackendPhiSourceValue value)
      (if (compiler-backend-phi-same-home? assignments dst value)
        (OkCompilerBackend "")
        (match (compiler-backend-emit-load-typed-value-with-plan
          assignments
          value
          ty)
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
          [(ErrCompilerBackend message) (ErrCompilerBackend message)]))]))

(define (compiler-backend-emit-phi-copy-item
  [assignments : CompilerRegAssignmentList]
  [copy : CompilerBackendPhiCopy]) : ResultCompilerBackend
  (match copy
    [(BackendPhiCopy dst source ty)
      (compiler-backend-emit-phi-source-to-var assignments dst source ty)]))

(define (compiler-backend-emit-phi-copy-list
  [assignments : CompilerRegAssignmentList]
  [copies : CompilerBackendPhiCopyList]) : ResultCompilerBackend
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
              (match (compiler-backend-emit-phi-copy-item assignments copy)
                [(OkCompilerBackend head)
                  (match (compiler-backend-emit-phi-copy-list
                    assignments
                    (compiler-backend-phi-copy-list-remove-dst copies dst))
                    [(OkCompilerBackend tail)
                      (OkCompilerBackend (string-append head tail))]
                    [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
                [(ErrCompilerBackend message) (ErrCompilerBackend message)])])]
        [(BackendNoPhiCopy)
          (match first
            [(BackendPhiCopy dst source ty)
              (let
                [save : String
                  (compiler-backend-emit-load-var-with-plan
                    assignments
                    dst
                    "%r11")]
                (match (compiler-backend-emit-phi-source-to-var
                  assignments
                  dst
                  source
                  ty)
                  [(OkCompilerBackend head)
                    (match (compiler-backend-emit-phi-copy-list
                      assignments
                      (compiler-backend-phi-copy-list-replace-source-home
                        assignments
                        (compiler-backend-phi-copy-list-remove-dst copies dst)
                        dst))
                      [(OkCompilerBackend tail)
                        (OkCompilerBackend
                          (string-append save (string-append head tail)))]
                      [(ErrCompilerBackend message)
                        (ErrCompilerBackend message)])]
                  [(ErrCompilerBackend message) (ErrCompilerBackend message)]))])])]))

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

(define (compiler-backend-emit-leading-phi-copies
  [assignments : CompilerRegAssignmentList]
  [instrs : CompilerIrInstrList]
  [from-label : String]) : ResultCompilerBackend
  (match (compiler-backend-leading-phi-copies assignments instrs from-label)
    [(OkBackendPhiCopies copies)
      (compiler-backend-emit-phi-copy-list assignments copies)]
    [(ErrBackendPhiCopies message)
      (ErrCompilerBackend (compiler-diagnostic-at-start "" message))]))

(define (compiler-backend-emit-phi-edge-copies
  [assignments : CompilerRegAssignmentList]
  [blocks : CompilerIrBlockList]
  [target-label : String]
  [from-label : String]) : ResultCompilerBackend
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
              from-label)
            (compiler-backend-emit-phi-edge-copies
              assignments
              (box-get rest)
              target-label
              from-label))])]))

(define (compiler-backend-tail-call-return-normalize [ty : AstType]) : String
  (if (= (compiler-backend-type-size ty) 0)
    "    movq $0, %rax\n"
    ""))

(define (compiler-backend-instr-return-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(IrInstrReturn _) 1]
    [_ 0]))

(define (compiler-backend-instr-list-return-count
  [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (compiler-backend-instr-return-count instr)
        (compiler-backend-instr-list-return-count (box-get rest)))]))

(define (compiler-backend-block-list-return-count
  [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (compiler-backend-instr-list-return-count instrs)
            (compiler-backend-block-list-return-count (box-get rest)))])]))

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
    (backend-cat4
      "    jmp "
      (compiler-backend-return-label source-function)
      "\n"
      "")
    (compiler-backend-inline-return-tail assignments vars)))

(define (compiler-backend-return-epilogue
  [source-function : String]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [blocks : CompilerIrBlockList]) : String
  (if (compiler-backend-use-shared-return? assignments blocks)
    (backend-cat4
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
  [ret-ty : AstType]) : ResultCompilerBackend
  (match value
    [(IrNoValue)
      (OkCompilerBackend
        (string-append
          (if (string-eq source-function "main")
            "    xorl %eax, %eax\n"
            "")
          (compiler-backend-return-tail source-function assignments vars blocks)))]
    [(IrSomeValue v)
      (match (compiler-backend-emit-load-typed-value-with-plan
        assignments
        v
        ret-ty)
        [(OkCompilerBackend load)
          (OkCompilerBackend
            (string-append
              load
              (compiler-backend-return-tail
                source-function
                assignments
                vars
                blocks)))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]))

(define (compiler-backend-emit-tail-call
  [target : CompilerBackendTarget]
  [source-function : String]
  [blocks : CompilerIrBlockList]
  [name : String]
  [args : CompilerIrCallArgs]
  [ty : AstType]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [plan : CompilerBackendRuntimePlan]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [program-index : CompilerBackendProgramIndex]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (let
    [param-types : AstTypeList
      (compiler-backend-call-param-types-index name program-index)]
    [call-space : i64 (compiler-backend-call-arg-space target args param-types)]
    (match (compiler-backend-emit-call-args
      target
      assignments
      args
      param-types
      0
      0
      0
      0
      0
      instr-diag)
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
                (backend-cat5
                  "    call "
                  (compiler-backend-call-symbol-index name plan program-index)
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
      [(ErrCompilerBackend message) (ErrCompilerBackend message)])))

(define (compiler-backend-emit-trivial-phi-return-edge-instrs
  [source-function : String]
  [blocks : CompilerIrBlockList]
  [instrs : CompilerIrInstrList]
  [from-label : String]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [ret-ty : AstType]) : ResultCompilerBackend
  (match instrs
    [(IrInstrCons instr rest)
      (match instr
        [(IrInstrPhi dst inputs _)
          (match (box-get rest)
            [(IrInstrCons next after-return)
              (match next
                [(IrInstrReturn maybe)
                  (match (box-get after-return)
                    [(IrInstrNil)
                      (match maybe
                        [(IrSomeValue value)
                          (if (compiler-backend-branch-uses-var? value dst)
                            (match (compiler-backend-phi-input-value
                              inputs
                              from-label)
                              [(OkBackendValue incoming)
                                (compiler-backend-emit-return
                                  source-function
                                  blocks
                                  (IrSomeValue incoming)
                                  assignments
                                  vars
                                  ret-ty)]
                              [(ErrBackendValue message)
                                (ErrCompilerBackend
                                  (compiler-diagnostic-at-start "" message))])
                            (OkCompilerBackend ""))]
                        [(IrNoValue) (OkCompilerBackend "")])]
                    [_ (OkCompilerBackend "")])]
                [_ (OkCompilerBackend "")])]
            [_ (OkCompilerBackend "")])]
        [_ (OkCompilerBackend "")])]
    [_ (OkCompilerBackend "")]))

(define (compiler-backend-emit-trivial-phi-return-edge
  [source-function : String]
  [blocks : CompilerIrBlockList]
  [target-label : String]
  [from-label : String]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [ret-ty : AstType]) : ResultCompilerBackend
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
              ret-ty)
            (compiler-backend-emit-trivial-phi-return-edge
              source-function
              (box-get rest)
              target-label
              from-label
              assignments
              vars
              ret-ty))])]))

(define (compiler-backend-emit-mov-trivial-phi-return-edge-instrs
  [source-function : String]
  [blocks : CompilerIrBlockList]
  [instrs : CompilerIrInstrList]
  [from-label : String]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [ret-ty : AstType]
  [moved-dst : i64]
  [moved-src : CompilerIrValue]) : ResultCompilerBackend
  (match instrs
    [(IrInstrCons instr rest)
      (match instr
        [(IrInstrPhi dst inputs _)
          (match (box-get rest)
            [(IrInstrCons next after-return)
              (match next
                [(IrInstrReturn maybe)
                  (match (box-get after-return)
                    [(IrInstrNil)
                      (match maybe
                        [(IrSomeValue value)
                          (if (compiler-backend-branch-uses-var? value dst)
                            (match (compiler-backend-phi-input-value
                              inputs
                              from-label)
                              [(OkBackendValue incoming)
                                (if (compiler-backend-branch-uses-var?
                                  incoming
                                  moved-dst)
                                  (compiler-backend-emit-return
                                    source-function
                                    blocks
                                    (IrSomeValue moved-src)
                                    assignments
                                    vars
                                    ret-ty)
                                  (OkCompilerBackend ""))]
                              [(ErrBackendValue message)
                                (ErrCompilerBackend
                                  (compiler-diagnostic-at-start "" message))])
                            (OkCompilerBackend ""))]
                        [(IrNoValue) (OkCompilerBackend "")])]
                    [_ (OkCompilerBackend "")])]
                [_ (OkCompilerBackend "")])]
            [_ (OkCompilerBackend "")])]
        [_ (OkCompilerBackend "")])]
    [_ (OkCompilerBackend "")]))

(define (compiler-backend-emit-mov-trivial-phi-return-edge
  [source-function : String]
  [blocks : CompilerIrBlockList]
  [target-label : String]
  [from-label : String]
  [assignments : CompilerRegAssignmentList]
  [vars : i64]
  [ret-ty : AstType]
  [moved-dst : i64]
  [moved-src : CompilerIrValue]) : ResultCompilerBackend
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
              moved-src)
            (compiler-backend-emit-mov-trivial-phi-return-edge
              source-function
              (box-get rest)
              target-label
              from-label
              assignments
              vars
              ret-ty
              moved-dst
              moved-src))])]))

(define (compiler-backend-emit-mov
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [src : CompilerIrValue]
  [ty : AstType]) : ResultCompilerBackend
  (if (compiler-backend-value-same-home? assignments dst src)
    (OkCompilerBackend "")
    (match (compiler-backend-emit-load-typed-value-with-plan assignments src ty)
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
      [(ErrCompilerBackend message) (ErrCompilerBackend message)])))

(define (compiler-backend-emit-entry-load
  [assignments : CompilerRegAssignmentList]
  [dst : i64]
  [label : String]
  [ty : AstType]) : ResultCompilerBackend
  (OkCompilerBackend
    (string-append
      (backend-cat5 "    movq " label "(%rip), %rax\n" "" "")
      (compiler-backend-emit-store-typed-var-with-plan
        assignments
        dst
        "%rax"
        ty))))

(define (compiler-backend-cpuid-result-move [reg-index : i64]) : String
  (cond
    [(= reg-index 0) "    movl %eax, %eax\n"]
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
  (match (compiler-backend-emit-load-value-with-plan assignments subleaf "%r11")
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
                  "    movl %r11d, %ecx\n    pushq %rbx\n    cpuid\n"
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
        (match (compiler-backend-emit-mov assignments dst src ty)
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
        (match (compiler-backend-emit-store-ptr assignments dst src ty)
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
          to-ty)
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
      [(IrInstrLaneId _ _ _)
        (compiler-backend-vector-mask-unimplemented instr-diag)]
      [(IrInstrSplat _ _ _ _)
        (compiler-backend-vector-mask-unimplemented instr-diag)]
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
      [(IrInstrVectorCompare _ _ _ _ _ _)
        (compiler-backend-vector-mask-unimplemented instr-diag)]
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
      [(IrInstrSelect _ _ _ _ _ _)
        (compiler-backend-vector-mask-unimplemented instr-diag)]
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
      [(IrInstrCall dst name args ty)
        (let
          [param-types : AstTypeList
            (compiler-backend-call-param-types-index name program-index)]
          [call-space : i64
            (compiler-backend-call-arg-space target args param-types)]
          (match (compiler-backend-emit-call-args
            target
            assignments
            args
            param-types
            0
            0
            0
            0
            0
            instr-diag)
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
                      (backend-cat5
                        "    call "
                        (compiler-backend-call-symbol-index
                          name
                          plan
                          program-index)
                        "\n"
                        (string-append
                          (compiler-backend-emit-call-space-add call-space)
                          (compiler-backend-emit-store-typed-var-with-plan
                            assignments
                            dst
                            (if (compiler-backend-float-type? ty)
                              "%xmm0"
                              "%rax")
                            ty))
                        "")))))]
            [(ErrCompilerBackend message)
              (ErrCompilerBackend
                (compiler-backend-apply-instr-diagnostic message instr-diag))]))]
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
            (backend-cat3 (compiler-backend-user-symbol name) "(%rip)" "")]
          (match (compiler-backend-emit-store-immediate-to-memory value addr ty)
            [(CompilerBackendSomeAsm store-asm) (OkCompilerBackend store-asm)]
            [(CompilerBackendNoAsm)
              (match (compiler-backend-emit-load-typed-value-with-plan
                assignments
                value
                ty)
                [(OkCompilerBackend load)
                  (OkCompilerBackend
                    (string-append
                      load
                      (if (compiler-backend-float-type? ty)
                        (backend-cat5
                          "    "
                          (compiler-backend-float-move ty)
                          " %xmm0, "
                          (compiler-backend-user-symbol name)
                          "(%rip)\n")
                        (backend-cat4
                          "    movq %rax, "
                          (compiler-backend-user-symbol name)
                          "(%rip)\n"
                          ""))))]
                [(ErrCompilerBackend message)
                  (ErrCompilerBackend
                    (compiler-backend-apply-instr-diagnostic message instr-diag))])]))]
      [(IrInstrJump target)
        (match (compiler-backend-emit-trivial-phi-return-edge
          source-function
          blocks
          target
          current-label
          assignments
          vars
          ret-ty)
          [(OkCompilerBackend direct-return)
            (if (string-eq direct-return "")
              (match (compiler-backend-emit-phi-edge-copies
                assignments
                blocks
                target
                current-label)
                [(OkCompilerBackend copies)
                  (OkCompilerBackend
                    (string-append
                      copies
                      (if (compiler-backend-jump-target-is-fallthrough?
                        target
                        fallthrough)
                        ""
                        (backend-cat4
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
        (match (compiler-backend-emit-branch
          assignments
          function
          cond
          true-label
          false-label
          fallthrough)
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
          ret-ty)
          [(OkCompilerBackend asm) (OkCompilerBackend asm)]
          [(ErrCompilerBackend message)
            (ErrCompilerBackend
              (compiler-backend-apply-instr-diagnostic message instr-diag))])]
      [(IrInstrPhi _ _ _) (OkCompilerBackend "")])))

(define (compiler-backend-use-counts-fill
  [counts : (Array i64)]
  [index : i64]
  [value : i64]) : unit
  (if (>= index (array-length counts))
    unit
    (begin
      (array-set! counts index value)
      (compiler-backend-use-counts-fill counts (+ index 1) value))))

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
    [(IrInstrBoundsCheck index length _)
      (begin
        (compiler-backend-count-value-use counts index)
        (compiler-backend-count-value-use counts length))]
    [(IrInstrCast _ src _ _) (compiler-backend-count-value-use counts src)]
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
    [(IrInstrCall _ _ args _)
      (compiler-backend-count-call-args-uses counts args)]
    [(IrInstrStore _ value _) (compiler-backend-count-value-use counts value)]
    [(IrInstrBranch cond _ _) (compiler-backend-count-value-use counts cond)]
    [(IrInstrReturn maybe)
      (match maybe
        [(IrNoValue) unit]
        [(IrSomeValue value) (compiler-backend-count-value-use counts value)])]
    [(IrInstrPhi _ inputs _)
      (compiler-backend-count-phi-input-uses counts inputs)]
    [_ unit]))

(define (compiler-backend-count-instr-list-uses
  [counts : (Array i64)]
  [instrs : CompilerIrInstrList]) : unit
  (match instrs
    [(IrInstrNil) unit]
    [(IrInstrCons instr rest)
      (begin
        (compiler-backend-count-instr-uses counts instr)
        (compiler-backend-count-instr-list-uses counts (box-get rest)))]))

(define (compiler-backend-count-block-uses
  [counts : (Array i64)]
  [blocks : CompilerIrBlockList]) : unit
  (match blocks
    [(IrBlockNil) unit]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (begin
            (compiler-backend-count-instr-list-uses counts instrs)
            (compiler-backend-count-block-uses counts (box-get rest)))])]))

(define (compiler-backend-function-use-counts
  [vars : i64]
  [blocks : CompilerIrBlockList]) : (Array i64)
  (let
    [counts : (Array i64) (make-array i64 vars)]
    (begin
      (compiler-backend-use-counts-fill counts 0 0)
      (compiler-backend-count-block-uses counts blocks)
      counts)))

(define (compiler-backend-var-single-use? [counts : (Array i64)] [var : i64]) : bool
  (if (< var 0)
    false
    (if (>= var (array-length counts))
      false
      (= (array-ref counts var) 1))))

(define (compiler-backend-branch-uses-var? [cond : CompilerIrValue] [var : i64]) : bool
  (match cond
    [(IrValueVar id) (= id var)]
    [_ false]))

(define (compiler-backend-fused-compare-fallthrough
  [rest : CompilerIrInstrList]
  [fallthrough : CompilerBackendMaybeLabel]) : CompilerBackendMaybeLabel
  (match rest
    [(IrInstrNil) fallthrough]
    [_ (CompilerBackendNoLabel)]))

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
  [use-counts : (Array i64)]) : ResultCompilerBackend
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
      (match (compiler-backend-emit-instrs
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
        use-counts)
        [(OkCompilerBackend tail) (OkCompilerBackend (string-append head tail))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
    [(ErrCompilerBackend message) (ErrCompilerBackend message)]))

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
  [use-counts : (Array i64)]) : ResultCompilerBackend
  (match (compiler-backend-emit-compare-branch
    assignments
    function
    op
    lhs
    rhs
    (compiler-backend-binop-operand-ty types global-types op lhs rhs ty)
    true-label
    false-label
    (compiler-backend-fused-compare-fallthrough rest fallthrough))
    [(OkCompilerBackend head)
      (match (compiler-backend-emit-instrs
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
        use-counts)
        [(OkCompilerBackend tail) (OkCompilerBackend (string-append head tail))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
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
  [cmp-dst : i64]
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
  [use-counts : (Array i64)]) : ResultCompilerBackend
  (match (compiler-backend-emit-load-compare-branch
    assignments
    function
    ptr
    op
    rhs
    cmp-ty
    true-label
    false-label
    (compiler-backend-fused-compare-fallthrough rest fallthrough))
    [(OkCompilerBackend head)
      (match (compiler-backend-emit-instrs
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
        use-counts)
        [(OkCompilerBackend tail) (OkCompilerBackend (string-append head tail))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
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
  [load-dst : i64]
  [load-ty : AstType]
  [cmp-dst : i64]
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
  [use-counts : (Array i64)]) : ResultCompilerBackend
  (match (compiler-backend-emit-gep-load-compare-branch
    assignments
    function
    base
    offset
    elem-ty
    op
    rhs
    cmp-ty
    true-label
    false-label
    (compiler-backend-fused-compare-fallthrough rest fallthrough))
    [(OkCompilerBackend head)
      (match (compiler-backend-emit-instrs
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
        use-counts)
        [(OkCompilerBackend tail) (OkCompilerBackend (string-append head tail))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
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
  [gep-dst : i64]
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
  [use-counts : (Array i64)]) : ResultCompilerBackend
  (match (compiler-backend-emit-load-from-gep
    assignments
    load-dst
    base
    offset
    elem-ty
    load-ty)
    [(OkCompilerBackend head)
      (match (compiler-backend-emit-instrs
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
        use-counts)
        [(OkCompilerBackend tail) (OkCompilerBackend (string-append head tail))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
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
  [use-counts : (Array i64)]) : ResultCompilerBackend
  (match (compiler-backend-emit-store-to-gep
    assignments
    base
    offset
    elem-ty
    value
    store-ty)
    [(OkCompilerBackend head)
      (match (compiler-backend-emit-instrs
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
        use-counts)
        [(OkCompilerBackend tail) (OkCompilerBackend (string-append head tail))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
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
  [use-counts : (Array i64)]) : ResultCompilerBackend
  (match (compiler-backend-emit-mov-trivial-phi-return-edge
    source-function
    blocks
    target-label
    current-label
    assignments
    vars
    ret-ty
    dst
    src)
    [(OkCompilerBackend direct-return)
      (if (string-eq direct-return "")
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
          use-counts)
        (match (compiler-backend-emit-instrs
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
          use-counts)
          [(OkCompilerBackend tail)
            (OkCompilerBackend (string-append direct-return tail))]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)]))]
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
  [vars : i64]
  [plan : CompilerBackendRuntimePlan]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [program-index : CompilerBackendProgramIndex]
  [instr-diag : CompilerDiagnostic]) : ResultCompilerBackend
  (let
    [param-types : AstTypeList
      (compiler-backend-call-param-types-index name program-index)]
    [call-space : i64 (compiler-backend-call-arg-space target args param-types)]
    (match (compiler-backend-emit-call-args
      target
      assignments
      args
      param-types
      0
      0
      0
      0
      0
      instr-diag)
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
                (backend-cat5
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
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
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
      (compiler-backend-closure-call-arg-space target args param-types)]
    (match (compiler-backend-emit-call-args
      target
      assignments
      args
      param-types
      0
      1
      0
      1
      0
      instr-diag)
      [(OkCompilerBackend args-asm)
        (match (compiler-backend-emit-load-value-with-plan
          assignments
          func
          "%r11")
          [(OkCompilerBackend func-asm)
            (match (compiler-backend-target-arg-reg target 0)
              [(OkBackendReg env-reg)
                (OkCompilerBackend
                  (string-append
                    (compiler-backend-emit-call-space-sub call-space)
                    (string-append
                      args-asm
                      (string-append
                        func-asm
                        (backend-cat5
                          "    movq 8(%r11), "
                          env-reg
                          "\n    movq (%r11), %rax\n    call *%rax\n"
                          (string-append
                            (compiler-backend-emit-call-space-add call-space)
                            (compiler-backend-emit-store-typed-var-with-plan
                              assignments
                              dst
                              (if (compiler-backend-float-type? ty)
                                "%xmm0"
                                "%rax")
                              ty))
                          "")))))]
              [(ErrBackendReg message)
                (ErrCompilerBackend
                  (compiler-diagnostic-with-message instr-diag message))])]
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
  [use-counts : (Array i64)]) : ResultCompilerBackend
  (match instrs
    [(IrInstrNil) (OkCompilerBackend "")]
    [(IrInstrCons instr rest)
      (match instr
        [(IrInstrMov dst src ty)
          (match (box-get rest)
            [(IrInstrCons next after-jump)
              (match next
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
                    use-counts)]
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
                              ret-ty)
                              [(OkCompilerBackend asm) (OkCompilerBackend asm)]
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
                              use-counts))]
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
                            use-counts)])]
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
                        use-counts)])]
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
                    use-counts)])]
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
                use-counts)])]
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
                            (compiler-backend-emit-call-return
                              target
                              source-function
                              blocks
                              name
                              args
                              assignments
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
                              use-counts))]
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
                            use-counts)])]
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
                        use-counts)])]
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
                    use-counts)])]
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
                use-counts)])]
        [(IrInstrGep gep-dst base offset elem-ty)
          (if (compiler-backend-var-single-use? use-counts gep-dst)
            (match (compiler-backend-value-as-i64 offset)
              [(CompilerBackendSomeI64 _)
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
                                      (and
                                        (compiler-backend-branch-uses-var?
                                          lhs
                                          load-dst)
                                        (and
                                          (compiler-backend-var-single-use?
                                            use-counts
                                            cmp-dst)
                                          (not
                                            (compiler-backend-binop-f64?
                                              types
                                              global-types
                                              lhs
                                              rhs
                                              cmp-ty)))))
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
                                                  use-counts)
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
                                                  use-counts))]
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
                                                use-counts)])]
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
                                            use-counts)])
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
                                        use-counts))]
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
                                      use-counts)])]
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
                                  use-counts)])
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
                              use-counts))
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
                            use-counts))]
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
                            use-counts)
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
                            use-counts))]
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
                          use-counts)])]
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
                      use-counts)])]
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
                  use-counts)])
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
              use-counts))]
        [(IrInstrLoad load-dst ptr load-ty)
          (if (and
            (compiler-backend-load-compare-type? load-ty)
            (compiler-backend-var-single-use? use-counts load-dst))
            (match (box-get rest)
              [(IrInstrCons next after-cmp)
                (match next
                  [(IrInstrBinOp cmp-dst op lhs rhs cmp-ty)
                    (if (and
                      (compiler-backend-compare-op? op)
                      (and
                        (compiler-backend-branch-uses-var? lhs load-dst)
                        (and
                          (compiler-backend-var-single-use? use-counts cmp-dst)
                          (not
                            (compiler-backend-binop-f64?
                              types
                              global-types
                              lhs
                              rhs
                              cmp-ty)))))
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
                                  use-counts)
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
                                  use-counts))]
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
                                use-counts)])]
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
                            use-counts)])
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
                        use-counts))]
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
                      use-counts)])]
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
                  use-counts)])
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
              use-counts))]
        [(IrInstrBinOp dst op lhs rhs ty)
          (if (and
            (compiler-backend-compare-op? op)
            (and
              (compiler-backend-var-single-use? use-counts dst)
              (not (compiler-backend-binop-f64? types global-types lhs rhs ty))))
            (match (box-get rest)
              [(IrInstrCons next after-branch)
                (match next
                  [(IrInstrReturn maybe)
                    (match (box-get after-branch)
                      [(IrInstrNil)
                        (match maybe
                          [(IrSomeValue value)
                            (if (compiler-backend-branch-uses-var? value dst)
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
                                use-counts))]
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
                              use-counts)])]
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
                          use-counts)])]
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
                        use-counts)
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
                        use-counts))]
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
                      use-counts)])]
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
                  use-counts)])
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
              use-counts))]
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
            use-counts)])]))

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
        use-counts)
        [(OkCompilerBackend body)
          (OkCompilerBackend
            (backend-cat4
              (compiler-backend-asm-label function label)
              ":\n"
              body
              ""))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]))

(define (compiler-backend-next-block-label [blocks : CompilerIrBlockList]) : CompilerBackendMaybeLabel
  (match blocks
    [(IrBlockNil) (CompilerBackendNoLabel)]
    [(IrBlockCons block _)
      (match block
        [(IrBlock label _) (CompilerBackendSomeLabel label)])]))

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
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]))

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
  [stack-idx : i64]) : ResultCompilerBackend
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
                (+ stack-idx 1))
                [(OkCompilerBackend tail)
                  (OkCompilerBackend
                    (string-append
                      (if is-float
                        (backend-cat5
                          "    "
                          (compiler-backend-float-move ty)
                          " "
                          (int->string
                            (compiler-backend-incoming-stack-arg-offset
                              target
                              stack-idx))
                          "(%rbp), %xmm0\n")
                        (backend-cat4
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
                    stack-idx)
                    [(OkCompilerBackend tail)
                      (OkCompilerBackend
                        (string-append
                          (compiler-backend-emit-store-typed-var-with-plan
                            assignments
                            var-id
                            reg
                            ty)
                          tail))]
                    [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
                [(ErrBackendReg _)
                  (ErrCompilerBackend
                    (compiler-diagnostic-at-start "" "backend: too many params"))])))])]))

(define (compiler-backend-emit-windows-main-argv-capture
  [target : CompilerBackendTarget]
  [name : String]
  [plan : CompilerBackendRuntimePlan]) : String
  (if (and (compiler-backend-target-windows? target) (string-eq name "main"))
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
    (and crt-entry (compiler-backend-target-linux? target))
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
  [externs : CompilerIrExternList]
  [plan : CompilerBackendRuntimePlan]
  [program-index : CompilerBackendProgramIndex]
  [spans : CompilerSourceSpans]
  [span-index : CompilerBackendSourceSpanIndex]
  [crt-entry : bool]) : ResultCompilerBackend
  (match func
    [(IrFunction name params ret-ty vars blocks)
      ;; The provenance fallback diagnostic for this function (#605): backend
      ;; errors raised while emitting its body stamp this function's source span
      ;; (or `1:1` when none was recorded) rather than always `1:1`.
      (let
        [func-diag : CompilerDiagnostic
          (compiler-backend-function-diagnostic-index span-index name "")]
        [reg-plan : CompilerRegPlan (compiler-reg-plan-function func)]
        [raw-assignments : CompilerRegAssignmentList
          (compiler-reg-plan-assignments reg-plan)]
        [assignments : CompilerRegAssignmentList raw-assignments]
        [types : CompilerRegVarTypeList (compiler-reg-function-var-types func)]
        [global-types : CompilerBackendGlobalTypeList
          (compiler-backend-global-types globals)]
        [use-counts : (Array i64)
          (compiler-backend-function-use-counts vars blocks)]
        (match (compiler-backend-emit-param-spills
          target
          assignments
          params
          0
          0
          0
          0)
          [(OkCompilerBackend spills)
            (let
              [symbol : String (compiler-backend-user-symbol name)]
              [label-scope : String
                (compiler-backend-function-label-scope program-index name)]
              (match (compiler-backend-emit-blocks
                target
                label-scope
                name
                blocks
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
                use-counts)
                [(OkCompilerBackend body)
                  (let
                    [frame : i64
                      (+
                        (compiler-backend-frame-size
                          (compiler-backend-frame-slots vars assignments))
                        (compiler-backend-outgoing-frame-space target blocks))]
                    (OkCompilerBackend
                      (backend-cat5
                        ".globl "
                        symbol
                        "\n"
                        (backend-cat5
                          symbol
                          ":\n    pushq %rbp\n    movq %rsp, %rbp\n"
                          (compiler-backend-emit-stack-sub target frame)
                          (string-append
                            (compiler-backend-mode-prologue mode)
                            (string-append
                              (compiler-backend-emit-save-callee-regs
                                assignments
                                vars)
                              (string-append
                                (compiler-backend-emit-windows-main-argv-capture
                                  target
                                  name
                                  plan)
                                (string-append
                                  (compiler-backend-emit-linux-crt-main-argv-capture
                                    target
                                    name
                                    crt-entry
                                    plan)
                                  (string-append
                                    (if (and
                                      (string-eq name "main")
                                      (or
                                        (compiler-backend-target-windows?
                                          target)
                                        (and
                                          crt-entry
                                          (compiler-backend-target-linux?
                                            target))))
                                      (compiler-backend-global-initializers
                                        globals)
                                      "")
                                    (string-append
                                      spills
                                      (string-append
                                        body
                                        (compiler-backend-return-epilogue
                                          name
                                          assignments
                                          vars
                                          blocks))))))))
                          "\n")
                        "")))]
                [(ErrCompilerBackend message) (ErrCompilerBackend message)]))]
          [(ErrCompilerBackend message) (ErrCompilerBackend message)]))]))

;; Per-function arena escape for the backend (#1633). Emitting one function's
;; assembly allocates per-instruction transient strings (right-associative
;; string-append) that the bump allocator never frees â€” the ~5 GB the backend
;; phase adds. We emit each function inside its own scratch arena, deep-`clone`
;; ONLY the resulting assembly String into the enclosing arena, then destroy the
;; scratch â€” reclaiming the per-function transient. `clone` of a String copies
;; the same bytes, so the assembled program text is byte-identical.
(define (compiler-backend-emit-function-escaping
  [target : CompilerBackendTarget]
  [mode : CompilerBackendMode]
  [func : CompilerIrFunction]
  [all-functions : CompilerIrFunctionList]
  [globals : CompilerIrGlobalList]
  [externs : CompilerIrExternList]
  [plan : CompilerBackendRuntimePlan]
  [program-index : CompilerBackendProgramIndex]
  [spans : CompilerSourceSpans]
  [span-index : CompilerBackendSourceSpanIndex]
  [crt-entry : bool]) : ResultCompilerBackend
  (let
    [enclosing : i64 (arena-current)]
    [scratch : i64 (arena-make)]
    (begin
      (unsafe
        (arena-set! scratch))
      (match (compiler-backend-emit-function
        target
        mode
        func
        all-functions
        globals
        externs
        plan
        program-index
        spans
        span-index
        crt-entry)
        [(OkCompilerBackend asm)
          (let
            [scratch-head : i64 (arena-current)]
            (begin
              (unsafe
                (arena-set! enclosing))
              (let
                [escaped : String (clone asm)]
                (begin
                  (unsafe
                    (arena-destroy scratch-head))
                  (OkCompilerBackend escaped)))))]
        [(ErrCompilerBackend message)
          (let
            [scratch-head : i64 (arena-current)]
            (begin
              (unsafe
                (arena-set! enclosing))
              (let
                [escaped : CompilerDiagnostic (clone message)]
                (begin
                  (unsafe
                    (arena-destroy scratch-head))
                  (ErrCompilerBackend escaped)))))]))))

(define (compiler-backend-emit-functions-into
  [target : CompilerBackendTarget]
  [mode : CompilerBackendMode]
  [functions : CompilerIrFunctionList]
  [all-functions : CompilerIrFunctionList]
  [globals : CompilerIrGlobalList]
  [externs : CompilerIrExternList]
  [plan : CompilerBackendRuntimePlan]
  [program-index : CompilerBackendProgramIndex]
  [spans : CompilerSourceSpans]
  [span-index : CompilerBackendSourceSpanIndex]
  [crt-entry : bool]
  [buf : TextBuf]) : ResultCompilerBackend
  (match functions
    [(IrFunctionNil) (OkCompilerBackend (text-buf-render buf))]
    [(IrFunctionCons func rest)
      (match (compiler-backend-emit-function-escaping
        target
        mode
        func
        all-functions
        globals
        externs
        plan
        program-index
        spans
        span-index
        crt-entry)
        [(OkCompilerBackend head)
          (compiler-backend-emit-functions-into
            target
            mode
            (box-get rest)
            all-functions
            globals
            externs
            plan
            program-index
            spans
            span-index
            crt-entry
            (text-buf-append buf head))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]))

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
  [crt-entry : bool]) : ResultCompilerBackend
  (let
    [span-index : CompilerBackendSourceSpanIndex
      (compiler-backend-source-span-index-build spans)]
    (compiler-backend-emit-functions-into
      target
      mode
      functions
      all-functions
      globals
      externs
      plan
      program-index
      spans
      span-index
      crt-entry
      (text-buf-empty))))

(define (compiler-backend-implicit-main-function) : CompilerIrFunction
  (IrFunction
    "main"
    IrParamNil
    (AstTyI64)
    1
    (compiler-ir-block-cons
      (IrBlock
        "entry"
        (compiler-ir-instr-cons
          (IrInstrReturn (IrSomeValue (IrValueI64 0)))
          IrInstrNil))
      IrBlockNil)))

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
  [externs : CompilerIrExternList]
  [plan : CompilerBackendRuntimePlan]
  [program-index : CompilerBackendProgramIndex]
  [spans : CompilerSourceSpans]
  [span-index : CompilerBackendSourceSpanIndex]
  [crt-entry : bool]
  [buf : TextBuf]) : ResultCompilerBackendBuffer
  (match functions
    [(IrFunctionNil) (OkCompilerBackendBuffer buf)]
    [(IrFunctionCons func rest)
      (match (compiler-backend-emit-function-escaping
        target
        mode
        func
        all-functions
        globals
        externs
        plan
        program-index
        spans
        span-index
        crt-entry)
        [(OkCompilerBackend head)
          (compiler-backend-emit-functions-buffer-into
            target
            mode
            (box-get rest)
            all-functions
            globals
            externs
            plan
            program-index
            spans
            span-index
            crt-entry
            (text-buf-append buf head))]
        [(ErrCompilerBackend message) (ErrCompilerBackendBuffer message)])]))

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
  [crt-entry : bool]) : ResultCompilerBackendBuffer
  (let
    [span-index : CompilerBackendSourceSpanIndex
      (compiler-backend-source-span-index-build spans)]
    (compiler-backend-emit-functions-buffer-into
      target
      mode
      functions
      all-functions
      globals
      externs
      plan
      program-index
      spans
      span-index
      crt-entry
      (text-buf-empty))))

(define (compiler-backend-emit-closure-descriptor-entry [name : String]) : String
  (backend-cat5
    (compiler-backend-closure-descriptor-label name)
    ":\n    .quad "
    (compiler-backend-closure-entry-label name)
    "\n    .quad 0\n"
    ""))

(define (compiler-backend-emit-closure-descriptor-entry-into
  [name : String]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
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
  (match names
    [(BackendStringNil) ""]
    [_
      (text-buf-render
        (compiler-backend-emit-closure-descriptor-entries-into
          names
          functions
          externs
          program-index
          (text-buf-append
            (text-buf-empty)
            "    .section .rodata\n    .balign 8\n")))]))

(define (compiler-backend-closure-adapter-outgoing-frame-space
  [target : CompilerBackendTarget]
  [args : CompilerIrCallArgs]) : i64
  (match target
    [(BackendTargetLinux) 0]
    [(BackendTargetWindows)
      (compiler-backend-round-up-16
        (+
          (compiler-backend-outgoing-shadow-space target)
          (compiler-backend-windows-stack-arg-space args)))]))

(define (compiler-backend-emit-closure-entry-adapter
  [target : CompilerBackendTarget]
  [name : String]
  [param-types : AstTypeList]
  [ret-ty : AstType]
  [plan : CompilerBackendRuntimePlan]
  [functions : CompilerIrFunctionList]
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
          (compiler-backend-frame-slots vars CompilerRegAssignmentNil))
        (compiler-backend-closure-adapter-outgoing-frame-space target args))]
    [call-space : i64 (compiler-backend-call-arg-space target args param-types)]
    [diag : CompilerDiagnostic (compiler-diagnostic-at-start "" "")]
    (match (compiler-backend-emit-param-spills
      target
      CompilerRegAssignmentNil
      params
      1
      0
      1
      0)
      [(OkCompilerBackend spills)
        (match (compiler-backend-emit-call-args
          target
          CompilerRegAssignmentNil
          args
          param-types
          0
          0
          0
          0
          0
          diag)
          [(OkCompilerBackend args-asm)
            (OkCompilerBackend
              (backend-cat5
                (compiler-backend-closure-entry-label name)
                ":\n    pushq %rbp\n    movq %rsp, %rbp\n"
                (compiler-backend-emit-stack-sub target frame)
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
                        (backend-cat5
                          "    call "
                          (compiler-backend-call-symbol-index
                            name
                            plan
                            program-index)
                          "\n"
                          (string-append
                            (compiler-backend-emit-call-space-add call-space)
                            "    movq %rbp, %rsp\n    popq %rbp\n    ret\n\n")
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
  (match names
    [(BackendStringNil) (OkCompilerBackend (text-buf-render buf))]
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
              (compiler-backend-emit-closure-entry-adapters-into
                target
                (box-get rest)
                functions
                externs
                plan
                program-index
                (text-buf-append buf head))]
            [(ErrCompilerBackend message) (ErrCompilerBackend message)])]
        [(CompilerBackendNoSignature)
          (compiler-backend-emit-closure-entry-adapters-into
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

(define (compiler-backend-string-list-contains?
  [strings : BackendStringList]
  [text : String]) : bool
  (match strings
    [(BackendStringNil) false]
    [(BackendStringCons head rest)
      (if (string-eq head text)
        true
        (compiler-backend-string-list-contains? (box-get rest) text))]))

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

(define (compiler-backend-string-list-add
  [strings : BackendStringList]
  [text : String]) : BackendStringList
  (if (compiler-backend-string-list-contains? strings text)
    strings
    (compiler-backend-string-cons text strings)))

(define (compiler-backend-collect-value-function
  [functions : BackendStringList]
  [value : CompilerIrValue]) : BackendStringList
  (match value
    [(IrValueFunction name) (compiler-backend-string-list-add functions name)]
    [_ functions]))

(define (compiler-backend-collect-value-list-functions
  [functions : BackendStringList]
  [values : CompilerIrValueList]) : BackendStringList
  (match values
    [(IrValueNil) functions]
    [(IrValueCons value rest)
      (compiler-backend-collect-value-list-functions
        (compiler-backend-collect-value-function functions value)
        (box-get rest))]))

(define (compiler-backend-collect-call-args-array-functions
  [functions : BackendStringList]
  [values : (Array CompilerIrValue)]
  [index : i64]) : BackendStringList
  (if (>= index (array-length values))
    functions
    (compiler-backend-collect-call-args-array-functions
      (compiler-backend-collect-value-function
        functions
        (array-ref values index))
      values
      (+ index 1))))

(define (compiler-backend-collect-call-args-functions
  [functions : BackendStringList]
  [args : CompilerIrCallArgs]) : BackendStringList
  (match args
    [(IrCallArgsNil) functions]
    [(IrCallArgsOne value)
      (compiler-backend-collect-value-function functions value)]
    [(IrCallArgsTwo a b)
      (compiler-backend-collect-value-function
        (compiler-backend-collect-value-function functions a)
        b)]
    [(IrCallArgsArray values)
      (compiler-backend-collect-call-args-array-functions functions values 0)]))

(define (compiler-backend-collect-phi-functions
  [functions : BackendStringList]
  [inputs : CompilerIrPhiInputList]) : BackendStringList
  (match inputs
    [(IrPhiInputNil) functions]
    [(IrPhiInputCons value _ rest)
      (compiler-backend-collect-phi-functions
        (compiler-backend-collect-value-function functions value)
        (box-get rest))]))

(define (compiler-backend-collect-instr-functions
  [functions : BackendStringList]
  [instr : CompilerIrInstr]) : BackendStringList
  (match instr
    [(IrInstrMov _ src _)
      (compiler-backend-collect-value-function functions src)]
    [(IrInstrBinOp _ _ lhs rhs _)
      (compiler-backend-collect-value-function
        (compiler-backend-collect-value-function functions lhs)
        rhs)]
    [(IrInstrUnOp _ _ src _)
      (compiler-backend-collect-value-function functions src)]
    [(IrInstrCall _ _ args _)
      (compiler-backend-collect-call-args-functions functions args)]
    [(IrInstrCallIndirect _ func args _)
      (compiler-backend-collect-call-args-functions
        (compiler-backend-collect-value-function functions func)
        args)]
    [(IrInstrTailCall _ args _)
      (compiler-backend-collect-call-args-functions functions args)]
    [(IrInstrBranch cond _ _)
      (compiler-backend-collect-value-function functions cond)]
    [(IrInstrReturn maybe)
      (match maybe
        [(IrNoValue) functions]
        [(IrSomeValue value)
          (compiler-backend-collect-value-function functions value)])]
    [(IrInstrPhi _ inputs _)
      (compiler-backend-collect-phi-functions functions inputs)]
    [(IrInstrGep _ base offset _)
      (compiler-backend-collect-value-function
        (compiler-backend-collect-value-function functions base)
        offset)]
    [(IrInstrLoad _ src _)
      (compiler-backend-collect-value-function functions src)]
    [(IrInstrStore _ src _)
      (compiler-backend-collect-value-function functions src)]
    [(IrInstrStorePtr dst src _)
      (compiler-backend-collect-value-function
        (compiler-backend-collect-value-function functions dst)
        src)]
    [(IrInstrCast _ src _ _)
      (compiler-backend-collect-value-function functions src)]
    [(IrInstrBoundsCheck index len _)
      (compiler-backend-collect-value-function
        (compiler-backend-collect-value-function functions index)
        len)]
    [(IrInstrVectorBinOp _ _ lhs rhs _ _)
      (compiler-backend-collect-value-function
        (compiler-backend-collect-value-function functions lhs)
        rhs)]
    [(IrInstrVectorReduce _ _ src _ _)
      (compiler-backend-collect-value-function functions src)]
    [(IrInstrVectorCompare _ _ lhs rhs _ _)
      (compiler-backend-collect-value-function
        (compiler-backend-collect-value-function functions lhs)
        rhs)]
    [(IrInstrMaskBinOp _ _ lhs rhs _)
      (compiler-backend-collect-value-function
        (compiler-backend-collect-value-function functions lhs)
        rhs)]
    [(IrInstrMaskNot _ src _)
      (compiler-backend-collect-value-function functions src)]
    [(IrInstrMaskReduce _ _ src _)
      (compiler-backend-collect-value-function functions src)]
    [(IrInstrSelect _ mask on-true on-false _ _)
      (compiler-backend-collect-value-function
        (compiler-backend-collect-value-function
          (compiler-backend-collect-value-function functions mask)
          on-true)
        on-false)]
    [(IrInstrVectorLoad _ base index _ _)
      (compiler-backend-collect-value-function
        (compiler-backend-collect-value-function functions base)
        index)]
    [(IrInstrVectorStore base index value _ _)
      (compiler-backend-collect-value-function
        (compiler-backend-collect-value-function
          (compiler-backend-collect-value-function functions base)
          index)
        value)]
    [(IrInstrPredicatedStore base index value mask _ _)
      (compiler-backend-collect-value-function
        (compiler-backend-collect-value-function
          (compiler-backend-collect-value-function
            (compiler-backend-collect-value-function functions base)
            index)
          value)
        mask)]
    [(IrInstrPredicatedLoad _ base index mask _ _)
      (compiler-backend-collect-value-function
        (compiler-backend-collect-value-function
          (compiler-backend-collect-value-function functions base)
          index)
        mask)]
    [(IrInstrTailMask _ index len _)
      (compiler-backend-collect-value-function
        (compiler-backend-collect-value-function functions index)
        len)]
    [(IrInstrEntryArgc _) functions]
    [(IrInstrEntryArgv _) functions]
    [(IrInstrEntryEnvp _) functions]
    [(IrInstrCpuId _ leaf subleaf _)
      (compiler-backend-collect-value-function
        (compiler-backend-collect-value-function functions leaf)
        subleaf)]
    [(IrInstrXgetbv _ index)
      (compiler-backend-collect-value-function functions index)]
    [_ functions]))

(define (compiler-backend-collect-instr-list-functions
  [functions : BackendStringList]
  [instrs : CompilerIrInstrList]) : BackendStringList
  (match instrs
    [(IrInstrNil) functions]
    [(IrInstrCons instr rest)
      (compiler-backend-collect-instr-list-functions
        (compiler-backend-collect-instr-functions functions instr)
        (box-get rest))]))

(define (compiler-backend-collect-block-functions
  [functions : BackendStringList]
  [blocks : CompilerIrBlockList]) : BackendStringList
  (match blocks
    [(IrBlockNil) functions]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (compiler-backend-collect-block-functions
            (compiler-backend-collect-instr-list-functions functions instrs)
            (box-get rest))])]))

(define (compiler-backend-collect-function-functions
  [names : BackendStringList]
  [functions : CompilerIrFunctionList]) : BackendStringList
  (match functions
    [(IrFunctionNil) names]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction _ _ _ _ blocks)
          (compiler-backend-collect-function-functions
            (compiler-backend-collect-block-functions names blocks)
            (box-get rest))])]))

(define (compiler-backend-collect-global-functions
  [names : BackendStringList]
  [globals : CompilerIrGlobalList]) : BackendStringList
  (match globals
    [(IrGlobalNil) names]
    [(IrGlobalCons global rest)
      (match global
        [(IrGlobal _ _ value)
          (compiler-backend-collect-global-functions
            (compiler-backend-collect-value-function names value)
            (box-get rest))])]))

(define (compiler-backend-collect-program-functions
  [program : CompilerIrProgram]) : BackendStringList
  (match program
    [(IrProgram globals functions _)
      (compiler-backend-string-list-reverse
        (compiler-backend-collect-function-functions
          (compiler-backend-collect-global-functions BackendStringNil globals)
          functions))]))

(define (compiler-backend-collect-value-string
  [strings : BackendStringList]
  [value : CompilerIrValue]) : BackendStringList
  (match value
    [(IrValueString text) (compiler-backend-string-list-add strings text)]
    [_ strings]))

(define (compiler-backend-collect-value-list-strings
  [strings : BackendStringList]
  [values : CompilerIrValueList]) : BackendStringList
  (match values
    [(IrValueNil) strings]
    [(IrValueCons value rest)
      (compiler-backend-collect-value-list-strings
        (compiler-backend-collect-value-string strings value)
        (box-get rest))]))

(define (compiler-backend-collect-call-args-array-strings
  [strings : BackendStringList]
  [values : (Array CompilerIrValue)]
  [index : i64]) : BackendStringList
  (if (>= index (array-length values))
    strings
    (compiler-backend-collect-call-args-array-strings
      (compiler-backend-collect-value-string strings (array-ref values index))
      values
      (+ index 1))))

(define (compiler-backend-collect-call-args-strings
  [strings : BackendStringList]
  [args : CompilerIrCallArgs]) : BackendStringList
  (match args
    [(IrCallArgsNil) strings]
    [(IrCallArgsOne value)
      (compiler-backend-collect-value-string strings value)]
    [(IrCallArgsTwo a b)
      (compiler-backend-collect-value-string
        (compiler-backend-collect-value-string strings a)
        b)]
    [(IrCallArgsArray values)
      (compiler-backend-collect-call-args-array-strings strings values 0)]))

(define (compiler-backend-collect-phi-strings
  [strings : BackendStringList]
  [inputs : CompilerIrPhiInputList]) : BackendStringList
  (match inputs
    [(IrPhiInputNil) strings]
    [(IrPhiInputCons value _ rest)
      (compiler-backend-collect-phi-strings
        (compiler-backend-collect-value-string strings value)
        (box-get rest))]))

(define (compiler-backend-collect-instr-strings
  [strings : BackendStringList]
  [instr : CompilerIrInstr]) : BackendStringList
  (match instr
    [(IrInstrMov _ src _) (compiler-backend-collect-value-string strings src)]
    [(IrInstrBinOp _ _ lhs rhs _)
      (compiler-backend-collect-value-string
        (compiler-backend-collect-value-string strings lhs)
        rhs)]
    [(IrInstrUnOp _ _ src _)
      (compiler-backend-collect-value-string strings src)]
    [(IrInstrCall _ _ args _)
      (compiler-backend-collect-call-args-strings strings args)]
    [(IrInstrTailCall _ args _)
      (compiler-backend-collect-call-args-strings strings args)]
    [(IrInstrStore _ value _)
      (compiler-backend-collect-value-string strings value)]
    [(IrInstrBranch cond _ _)
      (compiler-backend-collect-value-string strings cond)]
    [(IrInstrReturn maybe)
      (match maybe
        [(IrNoValue) strings]
        [(IrSomeValue value)
          (compiler-backend-collect-value-string strings value)])]
    [(IrInstrPhi _ inputs _)
      (compiler-backend-collect-phi-strings strings inputs)]
    [(IrInstrGep _ base offset _)
      (compiler-backend-collect-value-string
        (compiler-backend-collect-value-string strings base)
        offset)]
    [(IrInstrLoad _ src _) (compiler-backend-collect-value-string strings src)]
    [(IrInstrStorePtr dst src _)
      (compiler-backend-collect-value-string
        (compiler-backend-collect-value-string strings dst)
        src)]
    [(IrInstrBoundsCheck index length _)
      (compiler-backend-collect-value-string
        (compiler-backend-collect-value-string strings index)
        length)]
    [(IrInstrCast _ src _ _)
      (compiler-backend-collect-value-string strings src)]
    [(IrInstrSplat _ value _ _)
      (compiler-backend-collect-value-string strings value)]
    [(IrInstrVectorBinOp _ _ lhs rhs _ _)
      (compiler-backend-collect-value-string
        (compiler-backend-collect-value-string strings lhs)
        rhs)]
    [(IrInstrVectorReduce _ _ src _ _)
      (compiler-backend-collect-value-string strings src)]
    [(IrInstrVectorCompare _ _ lhs rhs _ _)
      (compiler-backend-collect-value-string
        (compiler-backend-collect-value-string strings lhs)
        rhs)]
    [(IrInstrMaskBinOp _ _ lhs rhs _)
      (compiler-backend-collect-value-string
        (compiler-backend-collect-value-string strings lhs)
        rhs)]
    [(IrInstrMaskNot _ src _)
      (compiler-backend-collect-value-string strings src)]
    [(IrInstrMaskReduce _ _ src _)
      (compiler-backend-collect-value-string strings src)]
    [(IrInstrSelect _ mask on-true on-false _ _)
      (compiler-backend-collect-value-string
        (compiler-backend-collect-value-string
          (compiler-backend-collect-value-string strings mask)
          on-true)
        on-false)]
    [(IrInstrVectorLoad _ base index _ _)
      (compiler-backend-collect-value-string
        (compiler-backend-collect-value-string strings base)
        index)]
    [(IrInstrVectorStore base index value _ _)
      (compiler-backend-collect-value-string
        (compiler-backend-collect-value-string
          (compiler-backend-collect-value-string strings base)
          index)
        value)]
    [(IrInstrPredicatedStore base index value mask _ _)
      (compiler-backend-collect-value-string
        (compiler-backend-collect-value-string
          (compiler-backend-collect-value-string
            (compiler-backend-collect-value-string strings base)
            index)
          value)
        mask)]
    [(IrInstrPredicatedLoad _ base index mask _ _)
      (compiler-backend-collect-value-string
        (compiler-backend-collect-value-string
          (compiler-backend-collect-value-string strings base)
          index)
        mask)]
    [(IrInstrTailMask _ index length _)
      (compiler-backend-collect-value-string
        (compiler-backend-collect-value-string strings index)
        length)]
    [(IrInstrEntryArgc _) strings]
    [(IrInstrEntryArgv _) strings]
    [(IrInstrEntryEnvp _) strings]
    [(IrInstrCpuId _ leaf subleaf _)
      (compiler-backend-collect-value-string
        (compiler-backend-collect-value-string strings leaf)
        subleaf)]
    [(IrInstrXgetbv _ index)
      (compiler-backend-collect-value-string strings index)]
    [_ strings]))

(define (compiler-backend-collect-instr-list-strings
  [strings : BackendStringList]
  [instrs : CompilerIrInstrList]) : BackendStringList
  (match instrs
    [(IrInstrNil) strings]
    [(IrInstrCons instr rest)
      (compiler-backend-collect-instr-list-strings
        (compiler-backend-collect-instr-strings strings instr)
        (box-get rest))]))

(define (compiler-backend-collect-block-strings
  [strings : BackendStringList]
  [blocks : CompilerIrBlockList]) : BackendStringList
  (match blocks
    [(IrBlockNil) strings]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (compiler-backend-collect-block-strings
            (compiler-backend-collect-instr-list-strings strings instrs)
            (box-get rest))])]))

(define (compiler-backend-collect-function-strings
  [strings : BackendStringList]
  [functions : CompilerIrFunctionList]) : BackendStringList
  (match functions
    [(IrFunctionNil) strings]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction _ _ _ _ blocks)
          (compiler-backend-collect-function-strings
            (compiler-backend-collect-block-strings strings blocks)
            (box-get rest))])]))

(define (compiler-backend-collect-global-strings
  [strings : BackendStringList]
  [globals : CompilerIrGlobalList]) : BackendStringList
  (match globals
    [(IrGlobalNil) strings]
    [(IrGlobalCons global rest)
      (match global
        [(IrGlobal _ _ value)
          (compiler-backend-collect-global-strings
            (compiler-backend-collect-value-string strings value)
            (box-get rest))])]))

(define (compiler-backend-collect-program-strings [program : CompilerIrProgram]) : BackendStringList
  (match program
    [(IrProgram globals functions _)
      (compiler-backend-string-list-reverse
        (compiler-backend-collect-function-strings
          (compiler-backend-collect-global-strings BackendStringNil globals)
          functions))]))

(define (compiler-backend-collect-value-f64
  [floats : BackendStringList]
  [value : CompilerIrValue]) : BackendStringList
  (match value
    [(IrValueF64 text) (compiler-backend-string-list-add floats text)]
    [_ floats]))

(define (compiler-backend-collect-value-list-f64s
  [floats : BackendStringList]
  [values : CompilerIrValueList]) : BackendStringList
  (match values
    [(IrValueNil) floats]
    [(IrValueCons value rest)
      (compiler-backend-collect-value-list-f64s
        (compiler-backend-collect-value-f64 floats value)
        (box-get rest))]))

(define (compiler-backend-collect-call-args-array-f64s
  [floats : BackendStringList]
  [values : (Array CompilerIrValue)]
  [index : i64]) : BackendStringList
  (if (>= index (array-length values))
    floats
    (compiler-backend-collect-call-args-array-f64s
      (compiler-backend-collect-value-f64 floats (array-ref values index))
      values
      (+ index 1))))

(define (compiler-backend-collect-call-args-f64s
  [floats : BackendStringList]
  [args : CompilerIrCallArgs]) : BackendStringList
  (match args
    [(IrCallArgsNil) floats]
    [(IrCallArgsOne value) (compiler-backend-collect-value-f64 floats value)]
    [(IrCallArgsTwo a b)
      (compiler-backend-collect-value-f64
        (compiler-backend-collect-value-f64 floats a)
        b)]
    [(IrCallArgsArray values)
      (compiler-backend-collect-call-args-array-f64s floats values 0)]))

(define (compiler-backend-collect-phi-f64s
  [floats : BackendStringList]
  [inputs : CompilerIrPhiInputList]) : BackendStringList
  (match inputs
    [(IrPhiInputNil) floats]
    [(IrPhiInputCons value _ rest)
      (compiler-backend-collect-phi-f64s
        (compiler-backend-collect-value-f64 floats value)
        (box-get rest))]))

(define (compiler-backend-collect-instr-f64s
  [floats : BackendStringList]
  [instr : CompilerIrInstr]) : BackendStringList
  (match instr
    [(IrInstrMov _ src _) (compiler-backend-collect-value-f64 floats src)]
    [(IrInstrBinOp _ _ lhs rhs _)
      (compiler-backend-collect-value-f64
        (compiler-backend-collect-value-f64 floats lhs)
        rhs)]
    [(IrInstrUnOp _ _ src _) (compiler-backend-collect-value-f64 floats src)]
    [(IrInstrCall _ _ args _)
      (compiler-backend-collect-call-args-f64s floats args)]
    [(IrInstrTailCall _ args _)
      (compiler-backend-collect-call-args-f64s floats args)]
    [(IrInstrStore _ value _) (compiler-backend-collect-value-f64 floats value)]
    [(IrInstrBranch cond _ _) (compiler-backend-collect-value-f64 floats cond)]
    [(IrInstrReturn maybe)
      (match maybe
        [(IrNoValue) floats]
        [(IrSomeValue value) (compiler-backend-collect-value-f64 floats value)])]
    [(IrInstrPhi _ inputs _) (compiler-backend-collect-phi-f64s floats inputs)]
    [(IrInstrGep _ base offset _)
      (compiler-backend-collect-value-f64
        (compiler-backend-collect-value-f64 floats base)
        offset)]
    [(IrInstrLoad _ src _) (compiler-backend-collect-value-f64 floats src)]
    [(IrInstrStorePtr dst src _)
      (compiler-backend-collect-value-f64
        (compiler-backend-collect-value-f64 floats dst)
        src)]
    [(IrInstrBoundsCheck index length _)
      (compiler-backend-collect-value-f64
        (compiler-backend-collect-value-f64 floats index)
        length)]
    [(IrInstrCast _ src _ _) (compiler-backend-collect-value-f64 floats src)]
    [(IrInstrSplat _ value _ _)
      (compiler-backend-collect-value-f64 floats value)]
    [(IrInstrVectorBinOp _ _ lhs rhs _ _)
      (compiler-backend-collect-value-f64
        (compiler-backend-collect-value-f64 floats lhs)
        rhs)]
    [(IrInstrVectorReduce _ _ src _ _)
      (compiler-backend-collect-value-f64 floats src)]
    [(IrInstrVectorCompare _ _ lhs rhs _ _)
      (compiler-backend-collect-value-f64
        (compiler-backend-collect-value-f64 floats lhs)
        rhs)]
    [(IrInstrMaskBinOp _ _ lhs rhs _)
      (compiler-backend-collect-value-f64
        (compiler-backend-collect-value-f64 floats lhs)
        rhs)]
    [(IrInstrMaskNot _ src _) (compiler-backend-collect-value-f64 floats src)]
    [(IrInstrMaskReduce _ _ src _)
      (compiler-backend-collect-value-f64 floats src)]
    [(IrInstrSelect _ mask on-true on-false _ _)
      (compiler-backend-collect-value-f64
        (compiler-backend-collect-value-f64
          (compiler-backend-collect-value-f64 floats mask)
          on-true)
        on-false)]
    [(IrInstrVectorLoad _ base index _ _)
      (compiler-backend-collect-value-f64
        (compiler-backend-collect-value-f64 floats base)
        index)]
    [(IrInstrVectorStore base index value _ _)
      (compiler-backend-collect-value-f64
        (compiler-backend-collect-value-f64
          (compiler-backend-collect-value-f64 floats base)
          index)
        value)]
    [(IrInstrPredicatedStore base index value mask _ _)
      (compiler-backend-collect-value-f64
        (compiler-backend-collect-value-f64
          (compiler-backend-collect-value-f64
            (compiler-backend-collect-value-f64 floats base)
            index)
          value)
        mask)]
    [(IrInstrPredicatedLoad _ base index mask _ _)
      (compiler-backend-collect-value-f64
        (compiler-backend-collect-value-f64
          (compiler-backend-collect-value-f64 floats base)
          index)
        mask)]
    [(IrInstrTailMask _ index length _)
      (compiler-backend-collect-value-f64
        (compiler-backend-collect-value-f64 floats index)
        length)]
    [(IrInstrEntryArgc _) floats]
    [(IrInstrEntryArgv _) floats]
    [(IrInstrEntryEnvp _) floats]
    [(IrInstrCpuId _ leaf subleaf _)
      (compiler-backend-collect-value-f64
        (compiler-backend-collect-value-f64 floats leaf)
        subleaf)]
    [(IrInstrXgetbv _ index) (compiler-backend-collect-value-f64 floats index)]
    [_ floats]))

(define (compiler-backend-collect-instr-list-f64s
  [floats : BackendStringList]
  [instrs : CompilerIrInstrList]) : BackendStringList
  (match instrs
    [(IrInstrNil) floats]
    [(IrInstrCons instr rest)
      (compiler-backend-collect-instr-list-f64s
        (compiler-backend-collect-instr-f64s floats instr)
        (box-get rest))]))

(define (compiler-backend-collect-block-f64s
  [floats : BackendStringList]
  [blocks : CompilerIrBlockList]) : BackendStringList
  (match blocks
    [(IrBlockNil) floats]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (compiler-backend-collect-block-f64s
            (compiler-backend-collect-instr-list-f64s floats instrs)
            (box-get rest))])]))

(define (compiler-backend-collect-function-f64s
  [floats : BackendStringList]
  [functions : CompilerIrFunctionList]) : BackendStringList
  (match functions
    [(IrFunctionNil) floats]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction _ _ _ _ blocks)
          (compiler-backend-collect-function-f64s
            (compiler-backend-collect-block-f64s floats blocks)
            (box-get rest))])]))

(define (compiler-backend-collect-global-f64s
  [floats : BackendStringList]
  [globals : CompilerIrGlobalList]) : BackendStringList
  (match globals
    [(IrGlobalNil) floats]
    [(IrGlobalCons global rest)
      (match global
        [(IrGlobal _ _ value)
          (compiler-backend-collect-global-f64s
            (compiler-backend-collect-value-f64 floats value)
            (box-get rest))])]))

(define (compiler-backend-collect-program-f64s [program : CompilerIrProgram]) : BackendStringList
  (match program
    [(IrProgram globals functions _)
      (compiler-backend-string-list-reverse
        (compiler-backend-collect-function-f64s
          (compiler-backend-collect-global-f64s BackendStringNil globals)
          functions))]))

(define (compiler-backend-emit-string-entry [text : String]) : String
  (backend-cat5
    (compiler-backend-string-data-label text)
    ":\n    .string "
    (compiler-backend-quoted-gas-string text)
    "\n    .balign 8\n"
    (backend-cat5
      (compiler-backend-string-fat-label text)
      ":\n    .quad "
      (compiler-backend-string-data-label text)
      "\n    .quad "
      (backend-cat3 (int->string (string-length text)) "\n" ""))))

(define (compiler-backend-emit-string-entries-into
  [strings : BackendStringList]
  [buf : TextBuf]) : TextBuf
  (match strings
    [(BackendStringNil) buf]
    [(BackendStringCons text rest)
      (compiler-backend-emit-string-entries-into
        (box-get rest)
        (text-buf-append buf (compiler-backend-emit-string-entry text)))]))

(define (compiler-backend-emit-string-entries [strings : BackendStringList]) : String
  (text-buf-render
    (compiler-backend-emit-string-entries-into strings (text-buf-empty))))

(define (compiler-backend-emit-string-rodata [strings : BackendStringList]) : String
  (match strings
    [(BackendStringNil) ""]
    [_
      (string-append
        "    .section .rodata\n"
        (string-append (compiler-backend-emit-string-entries strings) "\n"))]))

(define (compiler-backend-emit-f64-entry [text : String]) : String
  (backend-cat5
    (compiler-backend-f64-label text)
    ":\n    .double "
    text
    "\n"
    ""))

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

(define (compiler-backend-emit-f64-rodata [floats : BackendStringList]) : String
  (match floats
    [(BackendStringNil) ""]
    [_
      (string-append
        "    .section .rodata\n"
        (compiler-backend-emit-f64-entries floats))]))

(define (compiler-backend-global-value-asm
  [ty : AstType]
  [value : CompilerIrValue]) : ResultCompilerBackend
  (match value
    [(IrValueI64 n)
      (OkCompilerBackend (backend-cat3 "    .quad " (int->string n) "\n"))]
    [(IrValueBool b)
      (if b
        (OkCompilerBackend "    .quad 1\n")
        (OkCompilerBackend "    .quad 0\n"))]
    [(IrValueChar c)
      (OkCompilerBackend
        (backend-cat3
          "    .quad "
          (int->string (compiler-backend-char-code c))
          "\n"))]
    [(IrValueUnit) (OkCompilerBackend "    .quad 0\n")]
    [(IrValueF64 text)
      (if (compiler-backend-f64-type? ty)
        (OkCompilerBackend (backend-cat3 "    .double " text "\n"))
        (OkCompilerBackend (backend-cat3 "    .float " text "\n")))]
    [(IrValueGlobal name)
      (OkCompilerBackend
        (backend-cat3 "    .quad " (compiler-backend-user-symbol name) "\n"))]
    [(IrValueGlobalAddr name)
      (OkCompilerBackend
        (backend-cat3 "    .quad " (compiler-backend-user-symbol name) "\n"))]
    [(IrValueFunction name)
      (OkCompilerBackend
        (backend-cat3
          "    .quad "
          (compiler-backend-closure-descriptor-label name)
          "\n"))]
    [(IrValueString text)
      (OkCompilerBackend
        (backend-cat3
          "    .quad "
          (compiler-backend-string-fat-label text)
          "\n"))]
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
  [symbol : String]) : String
  (match target
    [(BackendTargetLinux) (backend-cat3 "    .comm " symbol ", 8, 8\n")]
    [(BackendTargetWindows) (backend-cat3 "    .comm " symbol ", 8, 3\n")]))

(define (compiler-backend-emit-global
  [target : CompilerBackendTarget]
  [global : CompilerIrGlobal]) : ResultCompilerBackend
  (match global
    [(IrGlobal name ty value)
      (let
        [symbol : String (compiler-backend-user-symbol name)]
        (if (compiler-backend-runtime-global? ty value)
          (OkCompilerBackend
            (backend-cat5
              ".globl "
              symbol
              "\n"
              (compiler-backend-emit-runtime-global target symbol)
              ""))
          (match (compiler-backend-global-value-asm ty value)
            [(OkCompilerBackend value-asm)
              (OkCompilerBackend
                (backend-cat5
                  ".globl "
                  symbol
                  "\n"
                  (backend-cat3 symbol ":\n" value-asm)
                  ""))]
            [(ErrCompilerBackend message) (ErrCompilerBackend message)])))]))

(define (compiler-backend-emit-globals-into
  [target : CompilerBackendTarget]
  [globals : CompilerIrGlobalList]
  [buf : TextBuf]) : ResultCompilerBackend
  (match globals
    [(IrGlobalNil) (OkCompilerBackend (text-buf-render buf))]
    [(IrGlobalCons global rest)
      (match (compiler-backend-emit-global target global)
        [(OkCompilerBackend head)
          (compiler-backend-emit-globals-into
            target
            (box-get rest)
            (text-buf-append buf head))]
        [(ErrCompilerBackend message) (ErrCompilerBackend message)])]))

(define (compiler-backend-emit-globals
  [target : CompilerBackendTarget]
  [globals : CompilerIrGlobalList]) : ResultCompilerBackend
  (compiler-backend-emit-globals-into target globals (text-buf-empty)))

(define (compiler-backend-global-init-name [global-name : String]) : String
  (string-append "__global_init_" global-name))

(define (compiler-backend-global-init-call [name : String] [ty : AstType]) : String
  (let
    [symbol : String (compiler-backend-user-symbol name)]
    [init-symbol : String
      (compiler-backend-user-symbol (compiler-backend-global-init-name name))]
    (backend-cat5
      "    call "
      init-symbol
      "\n"
      (if (compiler-backend-float-type? ty)
        (backend-cat5
          "    "
          (compiler-backend-float-move ty)
          " %xmm0, "
          symbol
          "(%rip)\n")
        (backend-cat3 "    movq %rax, " symbol "(%rip)\n"))
      "")))

(define (compiler-backend-global-initializers [globals : CompilerIrGlobalList]) : String
  (match globals
    [(IrGlobalNil) ""]
    [(IrGlobalCons global rest)
      (match global
        [(IrGlobal name ty value)
          (string-append
            (if (compiler-backend-runtime-global? ty value)
              (compiler-backend-global-init-call name ty)
              "")
            (compiler-backend-global-initializers (box-get rest)))])]))

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
            (compiler-backend-function-list-defines? (box-get rest) name))])]))

(define (compiler-backend-extern-list-references?
  [externs : CompilerIrExternList]
  [name : String]) : bool
  (match externs
    [(IrExternNil) false]
    [(IrExternCons item rest)
      (match item
        [(IrExtern extern-name _ _ link-symbol _)
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
        [(IrExtern extern-name _ _ link-symbol _)
          (if (string-eq extern-name name)
            link-symbol
            (compiler-backend-extern-list-link-symbol (box-get rest) name))])]))

(define (compiler-backend-instr-calls?
  [instr : CompilerIrInstr]
  [name : String]) : bool
  (match instr
    [(IrInstrCall _ call-name _ _) (string-eq call-name name)]
    [(IrInstrTailCall call-name _ _) (string-eq call-name name)]
    [(IrInstrBoundsCheck _ _ _) (string-eq name "tl_oob_abort")]
    [_ false]))

(define (compiler-backend-instr-list-calls?
  [instrs : CompilerIrInstrList]
  [name : String]) : bool
  (match instrs
    [(IrInstrNil) false]
    [(IrInstrCons instr rest)
      (if (compiler-backend-instr-calls? instr name)
        true
        (compiler-backend-instr-list-calls? (box-get rest) name))]))

(define (compiler-backend-block-list-calls?
  [blocks : CompilerIrBlockList]
  [name : String]) : bool
  (match blocks
    [(IrBlockNil) false]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (if (compiler-backend-instr-list-calls? instrs name)
            true
            (compiler-backend-block-list-calls? (box-get rest) name))])]))

(define (compiler-backend-function-list-calls?
  [functions : CompilerIrFunctionList]
  [name : String]) : bool
  (match functions
    [(IrFunctionNil) false]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction _ _ _ _ blocks)
          (if (compiler-backend-block-list-calls? blocks name)
            true
            (compiler-backend-function-list-calls? (box-get rest) name))])]))

(define (compiler-backend-binop-needs-div-abort?
  [op : CompilerIrBinOp]
  [ty : AstType]) : bool
  (if (compiler-backend-float-type? ty)
    false
    (match op
      [(IrBinDiv) true]
      [(IrBinMod) true]
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

(define (compiler-backend-instr-needs-div-abort? [instr : CompilerIrInstr]) : bool
  (match instr
    [(IrInstrBinOp _ op _ _ ty) (compiler-backend-binop-needs-div-abort? op ty)]
    [_ false]))

(define (compiler-backend-instr-needs-shift-abort? [instr : CompilerIrInstr]) : bool
  (match instr
    [(IrInstrBinOp _ op _ _ ty)
      (compiler-backend-binop-needs-shift-abort? op ty)]
    [_ false]))

(define (compiler-backend-instr-list-needs-div-abort?
  [instrs : CompilerIrInstrList]) : bool
  (match instrs
    [(IrInstrNil) false]
    [(IrInstrCons instr rest)
      (if (compiler-backend-instr-needs-div-abort? instr)
        true
        (compiler-backend-instr-list-needs-div-abort? (box-get rest)))]))

(define (compiler-backend-instr-list-needs-shift-abort?
  [instrs : CompilerIrInstrList]) : bool
  (match instrs
    [(IrInstrNil) false]
    [(IrInstrCons instr rest)
      (if (compiler-backend-instr-needs-shift-abort? instr)
        true
        (compiler-backend-instr-list-needs-shift-abort? (box-get rest)))]))

(define (compiler-backend-block-list-needs-div-abort?
  [blocks : CompilerIrBlockList]) : bool
  (match blocks
    [(IrBlockNil) false]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (if (compiler-backend-instr-list-needs-div-abort? instrs)
            true
            (compiler-backend-block-list-needs-div-abort? (box-get rest)))])]))

(define (compiler-backend-block-list-needs-shift-abort?
  [blocks : CompilerIrBlockList]) : bool
  (match blocks
    [(IrBlockNil) false]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (if (compiler-backend-instr-list-needs-shift-abort? instrs)
            true
            (compiler-backend-block-list-needs-shift-abort? (box-get rest)))])]))

(define (compiler-backend-function-list-needs-div-abort?
  [functions : CompilerIrFunctionList]) : bool
  (match functions
    [(IrFunctionNil) false]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction _ _ _ _ blocks)
          (if (compiler-backend-block-list-needs-div-abort? blocks)
            true
            (compiler-backend-function-list-needs-div-abort? (box-get rest)))])]))

(define (compiler-backend-function-list-needs-shift-abort?
  [functions : CompilerIrFunctionList]) : bool
  (match functions
    [(IrFunctionNil) false]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction _ _ _ _ blocks)
          (if (compiler-backend-block-list-needs-shift-abort? blocks)
            true
            (compiler-backend-function-list-needs-shift-abort? (box-get rest)))])]))

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
    [(IrInstrTailCall call-name _ _)
      (compiler-backend-runtime-index-add-call index call-name)]
    [(IrInstrBoundsCheck _ _ _)
      (compiler-backend-runtime-index-add-call index "tl_oob_abort")]
    [(IrInstrBinOp _ op _ _ ty)
      (let
        [with-div : CompilerBackendRuntimeIndex
          (if (compiler-backend-binop-needs-div-abort? op ty)
            (compiler-backend-runtime-index-with-div-abort index)
            index)]
        (if (compiler-backend-binop-needs-shift-abort? op ty)
          (compiler-backend-runtime-index-with-shift-abort with-div)
          with-div))]
    [_ index]))

(define (compiler-backend-runtime-index-instrs
  [index : CompilerBackendRuntimeIndex]
  [instrs : CompilerIrInstrList]) : CompilerBackendRuntimeIndex
  (match instrs
    [(IrInstrNil) index]
    [(IrInstrCons instr rest)
      (compiler-backend-runtime-index-instrs
        (compiler-backend-runtime-index-instr index instr)
        (box-get rest))]))

(define (compiler-backend-runtime-index-blocks
  [index : CompilerBackendRuntimeIndex]
  [blocks : CompilerIrBlockList]) : CompilerBackendRuntimeIndex
  (match blocks
    [(IrBlockNil) index]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (compiler-backend-runtime-index-blocks
            (compiler-backend-runtime-index-instrs index instrs)
            (box-get rest))])]))

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
            (box-get rest))])]))

(define (compiler-backend-runtime-index-externs
  [index : CompilerBackendRuntimeIndex]
  [externs : CompilerIrExternList]) : CompilerBackendRuntimeIndex
  (match externs
    [(IrExternNil) index]
    [(IrExternCons item rest)
      (match item
        [(IrExtern extern-name _ _ link-symbol _)
          (compiler-backend-runtime-index-externs
            (compiler-backend-runtime-index-add-extern-name
              (compiler-backend-runtime-index-add-extern-name
                index
                extern-name)
              link-symbol)
            (box-get rest))])]))

(define (compiler-backend-runtime-index
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]) : CompilerBackendRuntimeIndex
  (compiler-backend-runtime-index-functions
    (compiler-backend-runtime-index-externs
      (compiler-backend-runtime-index-empty)
      externs)
    functions))

(define (compiler-backend-provides-runtime-name?
  [name : String]
  [candidate : String]
  [enabled : bool]) : bool
  (and (string-eq name candidate) enabled))

(define (compiler-backend-provides-runtime-alias?
  [name : String]
  [canonical : String]
  [alias : String]
  [enabled : bool]) : bool
  (and enabled (or (string-eq name canonical) (string-eq name alias))))

(define (compiler-backend-provides-profile-runtime-name?
  [name : String]
  [enabled : bool]) : bool
  (and
    enabled
    (or
      (backend-or4
        (string-eq name "tl_profile_now_ms")
        (string-eq name "tl_profile_alloc_total")
        (string-eq name "tl_profile_alloc_live")
        (string-eq name "tl_profile_alloc_peak"))
      (string-eq name "tl_profile_alloc_reset_peak"))))

(define (compiler-backend-plan-provides-tail?
  [name : String]
  [read-bytes : bool]
  [stdin-eof : bool]
  [flush-stdout : bool]
  [random-system-seed : bool]
  [windows-setup-instances : bool]
  [windows-sdk-registry-install : bool]
  [env-var-exists : bool]
  [env-var-value : bool]
  [env-path-separator : bool]) : bool
  (let
    [_read-bytes : bool read-bytes]
    [_stdin-eof : bool stdin-eof]
    [_flush-stdout : bool flush-stdout]
    (or
      (backend-or4
        (compiler-backend-provides-runtime-name?
          name
          "tl_random_system_seed"
          random-system-seed)
        (compiler-backend-provides-runtime-name?
          name
          "tl_windows_setup_instances"
          windows-setup-instances)
        (compiler-backend-provides-runtime-name?
          name
          "tl_windows_sdk_registry_install"
          windows-sdk-registry-install)
        (compiler-backend-provides-runtime-name?
          name
          "tl_env_var_exists"
          env-var-exists))
      (or
        (compiler-backend-provides-runtime-name?
          name
          "tl_env_var_value"
          env-var-value)
        (compiler-backend-provides-runtime-name?
          name
          "env-path-separator"
          env-path-separator)))))

;; The first-class arena runtime helpers (#1633) and arena poison debug toggle
;; (#1690) are always emitted, so they are provided runtime symbols (resolve to
;; their raw names, not the mangled `_tl_tl_arena_*`).
(define (compiler-backend-plan-provides?
  [plan : CompilerBackendRuntimePlan]
  [name : String]) : bool
  (or
    (or
      (string-eq name "tl_arena_poison_enable")
      (backend-or4
        (string-eq name "tl_arena_make")
        (string-eq name "tl_arena_current")
        (string-eq name "tl_arena_set")
        (string-eq name "tl_arena_destroy")))
    (compiler-backend-plan-provides-rest? plan name)))

(define (compiler-backend-plan-provides-rest?
  [plan : CompilerBackendRuntimePlan]
  [name : String]) : bool
  (match plan
    [(BackendRuntimePlan
        alloc
        oob
        substring
        concat
        provides-string-eq
        provides-string-to-int
        provides-int-to-string
        provides-abort
        provides-print-err
        provides-print-str
        provides-print-char
        provides-print-f64
        provides-arg-count
        provides-arg
        provides-read-file
        provides-write-file
        provides-file-exists
        provides-file-handle
        provides-file-read-chunk
        provides-fs
        provides-process-output
        read-line
        read-bytes
        stdin-eof
        flush-stdout
        region-mark
        region-reset
        random-system-seed
        windows-setup-instances
        windows-sdk-registry-install
        provides-env-var-exists
        provides-env-var-value
        provides-env-path-separator
        provides-div-abort
        provides-shift-abort
        provides-tail)
      (or
        (backend-or8
          (compiler-backend-provides-runtime-name? name "tl_alloc" alloc)
          (compiler-backend-provides-runtime-name?
            name
            "tl_region_mark"
            region-mark)
          (compiler-backend-provides-runtime-name?
            name
            "tl_region_reset"
            region-reset)
          (compiler-backend-provides-runtime-name? name "tl_oob_abort" oob)
          (compiler-backend-provides-runtime-name?
            name
            "tl_substring"
            substring)
          (compiler-backend-provides-runtime-name?
            name
            "tl_string_concat"
            concat)
          (compiler-backend-provides-runtime-name?
            name
            "tl_string_eq"
            provides-string-eq)
          (compiler-backend-provides-runtime-name?
            name
            "tl_string_to_int"
            provides-string-to-int))
        (or
          (backend-or8
            (compiler-backend-provides-runtime-name?
              name
              "tl_int_to_string"
              provides-int-to-string)
            (compiler-backend-provides-runtime-name?
              name
              ".L_tl_abort"
              provides-abort)
            (compiler-backend-provides-runtime-name?
              name
              "tl_print_err"
              provides-print-err)
            (compiler-backend-provides-runtime-name?
              name
              ".L_tl_arg_count"
              provides-arg-count)
            (compiler-backend-provides-runtime-name?
              name
              ".L_tl_arg"
              provides-arg)
            (compiler-backend-provides-runtime-name?
              name
              ".L_tl_read_file"
              provides-read-file)
            (compiler-backend-provides-runtime-name?
              name
              ".L_tl_write_file"
              provides-write-file)
            (compiler-backend-provides-runtime-name?
              name
              ".L_tl_file_exists"
              provides-file-exists))
          (or
            (backend-or4
              (compiler-backend-provides-runtime-name?
                name
                "tl_print_str"
                provides-print-str)
              (compiler-backend-provides-runtime-name?
                name
                "tl_print_string"
                provides-print-str)
              (compiler-backend-provides-runtime-name?
                name
                "tl_print_char"
                provides-print-char)
              (compiler-backend-provides-runtime-name?
                name
                "tl_print_f64"
                provides-print-f64))
            (or
              (backend-or8
                (or
                  (compiler-backend-provides-runtime-name?
                    name
                    "tl_process_output"
                    provides-process-output)
                  (or
                    (compiler-backend-provides-runtime-name?
                      name
                      "tl_process_start"
                      provides-process-output)
                    (compiler-backend-provides-runtime-name?
                      name
                      "tl_process_wait"
                      provides-process-output)))
                (compiler-backend-provides-runtime-name?
                  name
                  ".L_tl_read_file_status"
                  provides-read-file)
                (compiler-backend-provides-runtime-name?
                  name
                  ".L_tl_write_file_status"
                  provides-write-file)
                (compiler-backend-provides-runtime-name?
                  name
                  ".L_tl_append_file_status"
                  provides-write-file)
                (compiler-backend-provides-runtime-name?
                  name
                  ".L_tl_file_exists_status"
                  provides-file-exists)
                (compiler-backend-provides-runtime-name?
                  name
                  ".L_tl_file_open_status"
                  provides-file-handle)
                (compiler-backend-provides-runtime-name?
                  name
                  ".L_tl_file_close_status"
                  provides-file-handle)
                (compiler-backend-provides-runtime-name?
                  name
                  ".L_tl_file_read_chunk_status"
                  provides-file-read-chunk))
              (or
                (backend-or4
                  (compiler-backend-provides-runtime-name?
                    name
                    ".L_tl_file_write_status"
                    provides-file-handle)
                  (compiler-backend-provides-runtime-name?
                    name
                    ".L_tl_file_flush_status"
                    provides-file-handle)
                  (compiler-backend-provides-runtime-name?
                    name
                    ".L_tl_file_read_chunk_bytes"
                    provides-file-read-chunk)
                  (compiler-backend-provides-runtime-name?
                    name
                    ".L_tl_file_read_chunk_eof"
                    provides-file-read-chunk))
                (or
                  (backend-or8
                    (compiler-backend-provides-runtime-alias?
                      name
                      ".L_tl_fs_mkdir_status"
                      "tl_fs_mkdir_status"
                      provides-fs)
                    (compiler-backend-provides-runtime-alias?
                      name
                      ".L_tl_fs_remove_file_status"
                      "tl_fs_remove_file_status"
                      provides-fs)
                    (compiler-backend-provides-runtime-alias?
                      name
                      ".L_tl_fs_remove_dir_status"
                      "tl_fs_remove_dir_status"
                      provides-fs)
                    (compiler-backend-provides-runtime-alias?
                      name
                      ".L_tl_fs_rename_status"
                      "tl_fs_rename_status"
                      provides-fs)
                    (compiler-backend-provides-runtime-alias?
                      name
                      ".L_tl_fs_process_id"
                      "tl_fs_process_id"
                      provides-fs)
                    (compiler-backend-provides-runtime-name?
                      name
                      ".L_tl_fs_read_dir_status"
                      provides-fs)
                    (compiler-backend-provides-runtime-name?
                      name
                      ".L_tl_fs_read_dir"
                      provides-fs)
                    (or
                      (compiler-backend-provides-runtime-name?
                        name
                        ".L_tl_fs_file_kind_status"
                        provides-fs)
                      (or
                        (compiler-backend-provides-runtime-name?
                          name
                          ".L_tl_fs_file_size_status"
                          provides-fs)
                        (or
                          (compiler-backend-provides-runtime-name?
                            name
                            ".L_tl_fs_file_size"
                            provides-fs)
                          (or
                            (compiler-backend-provides-runtime-name?
                              name
                              "tl_fs_current_dir_status"
                              (compiler-backend-runtime-tail-fs-current-dir?
                                provides-tail))
                            (compiler-backend-provides-runtime-name?
                              name
                              "tl_fs_current_dir"
                              (compiler-backend-runtime-tail-fs-current-dir?
                                provides-tail)))))))
                  (or
                    (compiler-backend-provides-runtime-name?
                      name
                      ".L_tl_read_stdin_line"
                      read-line)
                    (or
                      (backend-or4
                        (compiler-backend-provides-runtime-name?
                          name
                          ".L_tl_read_stdin_bytes"
                          read-bytes)
                        (compiler-backend-provides-runtime-name?
                          name
                          ".L_tl_stdin_eof"
                          stdin-eof)
                        (compiler-backend-provides-runtime-name?
                          name
                          ".L_tl_flush_stdout"
                          flush-stdout)
                        (compiler-backend-provides-runtime-name?
                          name
                          "tl_random_system_seed"
                          random-system-seed))
                      (or
                        (compiler-backend-plan-provides-tail?
                          name
                          read-bytes
                          stdin-eof
                          flush-stdout
                          random-system-seed
                          windows-setup-instances
                          windows-sdk-registry-install
                          provides-env-var-exists
                          provides-env-var-value
                          provides-env-path-separator)
                        (backend-or4
                          (compiler-backend-provides-runtime-name?
                            name
                            "tl_div_abort"
                            provides-div-abort)
                          (compiler-backend-provides-runtime-name?
                            name
                            "tl_shift_abort"
                            provides-shift-abort)
                          (compiler-backend-provides-profile-runtime-name?
                            name
                            (compiler-backend-runtime-tail-profile?
                              provides-tail))
                          false))))))))))]))

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
    [defines-concat : bool
      (compiler-backend-runtime-index-defines? index "tl_string_concat")]
    [defines-string-eq : bool
      (compiler-backend-runtime-index-defines? index "tl_string_eq")]
    [defines-string-to-int : bool
      (compiler-backend-runtime-index-defines? index "tl_string_to_int")]
    [defines-int-to-string : bool
      (compiler-backend-runtime-index-defines? index "tl_int_to_string")]
    [defines-print-err : bool
      (compiler-backend-runtime-index-defines? index "tl_print_err")]
    [defines-print-str : bool
      (compiler-backend-runtime-index-defines? index "tl_print_str")]
    [defines-print-string : bool
      (compiler-backend-runtime-index-defines? index "tl_print_string")]
    [defines-print-char : bool
      (compiler-backend-runtime-index-defines? index "tl_print_char")]
    [defines-print-f64 : bool
      (compiler-backend-runtime-index-defines? index "tl_print_f64")]
    [defines-region-mark : bool
      (compiler-backend-runtime-index-defines? index "tl_region_mark")]
    [defines-region-reset : bool
      (compiler-backend-runtime-index-defines? index "tl_region_reset")]
    [defines-process-output : bool
      (compiler-backend-runtime-index-defines? index "tl_process_output")]
    [defines-process-start : bool
      (compiler-backend-runtime-index-defines? index "tl_process_start")]
    [defines-process-wait : bool
      (compiler-backend-runtime-index-defines? index "tl_process_wait")]
    [defines-random-system-seed : bool
      (compiler-backend-runtime-index-defines? index "tl_random_system_seed")]
    [defines-windows-setup-instances : bool
      (compiler-backend-runtime-index-defines? index "tl_windows_setup_instances")]
    [defines-windows-sdk-registry-install : bool
      (compiler-backend-runtime-index-defines? index "tl_windows_sdk_registry_install")]
    [defines-env-var-exists : bool
      (compiler-backend-runtime-index-defines? index "tl_env_var_exists")]
    [defines-env-var-value : bool
      (compiler-backend-runtime-index-defines? index "tl_env_var_value")]
    [defines-env-path-separator : bool
      (compiler-backend-runtime-index-defines? index "env-path-separator")]
    [defines-profile-now-ms : bool
      (compiler-backend-runtime-index-defines? index "tl_profile_now_ms")]
    [defines-profile-alloc-total : bool
      (compiler-backend-runtime-index-defines? index "tl_profile_alloc_total")]
    [defines-profile-alloc-live : bool
      (compiler-backend-runtime-index-defines? index "tl_profile_alloc_live")]
    [defines-profile-alloc-peak : bool
      (compiler-backend-runtime-index-defines? index "tl_profile_alloc_peak")]
    [defines-profile-alloc-reset-peak : bool
      (compiler-backend-runtime-index-defines? index "tl_profile_alloc_reset_peak")]
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
    [extern-concat : bool
      (compiler-backend-runtime-index-extern? index "tl_string_concat")]
    [extern-string-eq : bool
      (compiler-backend-runtime-index-extern? index "tl_string_eq")]
    [extern-string-to-int : bool
      (compiler-backend-runtime-index-extern? index "tl_string_to_int")]
    [extern-int-to-string : bool
      (compiler-backend-runtime-index-extern? index "tl_int_to_string")]
    [extern-abort : bool
      (compiler-backend-runtime-index-extern-alias?
        index
        ".L_tl_abort"
        "tl_abort_string")]
    [extern-print-err : bool
      (compiler-backend-runtime-index-extern-alias?
        index
        "tl_print_err"
        "tl_print_error")]
    [extern-print-str : bool
      (compiler-backend-runtime-index-extern-alias?
        index
        "tl_print_str"
        "tl_print_string")]
    [extern-print-char : bool
      (compiler-backend-runtime-index-extern? index "tl_print_char")]
    [extern-print-f64 : bool
      (compiler-backend-runtime-index-extern? index "tl_print_f64")]
    [extern-arg-count : bool
      (compiler-backend-runtime-index-extern-alias?
        index
        ".L_tl_arg_count"
        "tl_arg_count")]
    [extern-arg : bool
      (compiler-backend-runtime-index-extern-alias?
        index
        ".L_tl_arg"
        "tl_arg")]
    [extern-read-file : bool
      (compiler-backend-runtime-index-extern-alias?
        index
        ".L_tl_read_file"
        "tl_read_file")]
    [extern-write-file : bool
      (compiler-backend-runtime-index-extern-alias?
        index
        ".L_tl_write_file"
        "tl_write_file")]
    [extern-file-exists : bool
      (compiler-backend-runtime-index-extern-alias?
        index
        ".L_tl_file_exists"
        "tl_file_exists")]
    [extern-read-file-status : bool
      (compiler-backend-runtime-index-extern-alias?
        index
        ".L_tl_read_file_status"
        "tl_read_file_status")]
    [extern-write-file-status : bool
      (compiler-backend-runtime-index-extern-alias?
        index
        ".L_tl_write_file_status"
        "tl_write_file_status")]
    [extern-append-file-status : bool
      (compiler-backend-runtime-index-extern-alias?
        index
        ".L_tl_append_file_status"
        "tl_append_file_status")]
    [extern-file-exists-status : bool
      (compiler-backend-runtime-index-extern-alias?
        index
        ".L_tl_file_exists_status"
        "tl_file_exists_status")]
    [extern-file-open-status : bool
      (compiler-backend-runtime-index-extern-alias?
        index
        ".L_tl_file_open_status"
        "tl_file_open_status")]
    [extern-file-close-status : bool
      (compiler-backend-runtime-index-extern-alias?
        index
        ".L_tl_file_close_status"
        "tl_file_close_status")]
    [extern-file-read-chunk-status : bool
      (compiler-backend-runtime-index-extern-alias?
        index
        ".L_tl_file_read_chunk_status"
        "tl_file_read_chunk_status")]
    [extern-file-write-status : bool
      (compiler-backend-runtime-index-extern-alias?
        index
        ".L_tl_file_write_status"
        "tl_file_write_status")]
    [extern-file-flush-status : bool
      (compiler-backend-runtime-index-extern-alias?
        index
        ".L_tl_file_flush_status"
        "tl_file_flush_status")]
    [extern-file-read-chunk-bytes : bool
      (compiler-backend-runtime-index-extern-alias?
        index
        ".L_tl_file_read_chunk_bytes"
        "tl_file_read_chunk_bytes")]
    [extern-file-read-chunk-eof : bool
      (compiler-backend-runtime-index-extern-alias?
        index
        ".L_tl_file_read_chunk_eof"
        "tl_file_read_chunk_eof")]
    [extern-fs-mkdir-status : bool
      (compiler-backend-runtime-index-extern-alias?
        index
        ".L_tl_fs_mkdir_status"
        "tl_fs_mkdir_status")]
    [extern-fs-remove-file-status : bool
      (compiler-backend-runtime-index-extern-alias?
        index
        ".L_tl_fs_remove_file_status"
        "tl_fs_remove_file_status")]
    [extern-fs-remove-dir-status : bool
      (compiler-backend-runtime-index-extern-alias?
        index
        ".L_tl_fs_remove_dir_status"
        "tl_fs_remove_dir_status")]
    [extern-fs-rename-status : bool
      (compiler-backend-runtime-index-extern-alias?
        index
        ".L_tl_fs_rename_status"
        "tl_fs_rename_status")]
    [extern-fs-file-kind-status : bool
      (compiler-backend-runtime-index-extern? index ".L_tl_fs_file_kind_status")]
    [extern-fs-file-size-status : bool
      (compiler-backend-runtime-index-extern? index ".L_tl_fs_file_size_status")]
    [extern-fs-file-size : bool
      (compiler-backend-runtime-index-extern? index ".L_tl_fs_file_size")]
    [extern-fs-process-id : bool
      (compiler-backend-runtime-index-extern-alias?
        index
        ".L_tl_fs_process_id"
        "tl_fs_process_id")]
    [extern-fs-read-dir-status : bool
      (compiler-backend-runtime-index-extern? index ".L_tl_fs_read_dir_status")]
    [extern-fs-read-dir : bool
      (compiler-backend-runtime-index-extern? index ".L_tl_fs_read_dir")]
    [extern-fs-current-dir-status : bool
      (compiler-backend-runtime-index-extern? index "tl_fs_current_dir_status")]
    [extern-fs-current-dir : bool
      (compiler-backend-runtime-index-extern? index "tl_fs_current_dir")]
    [extern-read-line : bool
      (compiler-backend-runtime-index-extern-alias?
        index
        ".L_tl_read_stdin_line"
        "tl_read_stdin_line")]
    [extern-read-bytes : bool
      (compiler-backend-runtime-index-extern-alias?
        index
        ".L_tl_read_stdin_bytes"
        "tl_read_stdin_bytes")]
    [extern-stdin-eof : bool
      (compiler-backend-runtime-index-extern-alias?
        index
        ".L_tl_stdin_eof"
        "tl_stdin_eof")]
    [extern-flush-stdout : bool
      (compiler-backend-runtime-index-extern-alias?
        index
        ".L_tl_flush_stdout"
        "tl_flush_stdout")]
    [extern-process-output : bool
      (compiler-backend-runtime-index-extern? index "tl_process_output")]
    [extern-process-start : bool
      (compiler-backend-runtime-index-extern? index "tl_process_start")]
    [extern-process-wait : bool
      (compiler-backend-runtime-index-extern? index "tl_process_wait")]
    [extern-region-mark : bool
      (compiler-backend-runtime-index-extern? index "tl_region_mark")]
    [extern-region-reset : bool
      (compiler-backend-runtime-index-extern? index "tl_region_reset")]
    [extern-random-system-seed : bool
      (compiler-backend-runtime-index-extern? index "tl_random_system_seed")]
    [extern-windows-setup-instances : bool
      (compiler-backend-runtime-index-extern? index "tl_windows_setup_instances")]
    [extern-windows-sdk-registry-install : bool
      (compiler-backend-runtime-index-extern? index "tl_windows_sdk_registry_install")]
    [extern-env-var-exists : bool
      (compiler-backend-runtime-index-extern? index "tl_env_var_exists")]
    [extern-env-var-value : bool
      (compiler-backend-runtime-index-extern? index "tl_env_var_value")]
    [extern-env-path-separator : bool
      (compiler-backend-runtime-index-extern? index "env-path-separator")]
    [extern-profile-now-ms : bool
      (compiler-backend-runtime-index-extern? index "tl_profile_now_ms")]
    [extern-profile-alloc-total : bool
      (compiler-backend-runtime-index-extern? index "tl_profile_alloc_total")]
    [extern-profile-alloc-live : bool
      (compiler-backend-runtime-index-extern? index "tl_profile_alloc_live")]
    [extern-profile-alloc-peak : bool
      (compiler-backend-runtime-index-extern? index "tl_profile_alloc_peak")]
    [extern-profile-alloc-reset-peak : bool
      (compiler-backend-runtime-index-extern? index "tl_profile_alloc_reset_peak")]
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
    [calls-concat : bool
      (compiler-backend-runtime-index-calls? index "tl_string_concat")]
    [calls-string-eq : bool
      (compiler-backend-runtime-index-calls? index "tl_string_eq")]
    [calls-string-to-int : bool
      (compiler-backend-runtime-index-calls? index "tl_string_to_int")]
    [calls-int-to-string : bool
      (compiler-backend-runtime-index-calls? index "tl_int_to_string")]
    [calls-abort : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_abort")]
    [calls-print-err : bool
      (compiler-backend-runtime-index-calls? index "tl_print_err")]
    [calls-print-str : bool
      (compiler-backend-runtime-index-calls? index "tl_print_str")]
    [calls-print-string : bool
      (compiler-backend-runtime-index-calls? index "tl_print_string")]
    [calls-print-char : bool
      (compiler-backend-runtime-index-calls? index "tl_print_char")]
    [calls-print-f64 : bool
      (compiler-backend-runtime-index-calls? index "tl_print_f64")]
    [calls-arg-count : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_arg_count")]
    [calls-arg : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_arg")]
    [calls-read-file : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_read_file")]
    [calls-write-file : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_write_file")]
    [calls-file-exists : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_file_exists")]
    [calls-read-file-status : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_read_file_status")]
    [calls-write-file-status : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_write_file_status")]
    [calls-append-file-status : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_append_file_status")]
    [calls-file-exists-status : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_file_exists_status")]
    [calls-file-open-status : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_file_open_status")]
    [calls-file-close-status : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_file_close_status")]
    [calls-file-read-chunk-status : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_file_read_chunk_status")]
    [calls-file-write-status : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_file_write_status")]
    [calls-file-flush-status : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_file_flush_status")]
    [calls-file-read-chunk-bytes : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_file_read_chunk_bytes")]
    [calls-file-read-chunk-eof : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_file_read_chunk_eof")]
    [calls-fs-mkdir-status : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_fs_mkdir_status")]
    [calls-fs-remove-file-status : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_fs_remove_file_status")]
    [calls-fs-remove-dir-status : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_fs_remove_dir_status")]
    [calls-fs-rename-status : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_fs_rename_status")]
    [calls-fs-file-kind-status : bool
      (compiler-backend-runtime-index-calls?
        index
        ".L_tl_fs_file_kind_status")]
    [calls-fs-file-size-status : bool
      (compiler-backend-function-list-calls?
        functions
        ".L_tl_fs_file_size_status")]
    [calls-fs-file-size : bool
      (compiler-backend-function-list-calls? functions ".L_tl_fs_file_size")]
    [calls-fs-process-id : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_fs_process_id")]
    [calls-fs-read-dir-status : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_fs_read_dir_status")]
    [calls-fs-read-dir : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_fs_read_dir")]
    [calls-fs-current-dir-status : bool
      (compiler-backend-runtime-index-calls? index "tl_fs_current_dir_status")]
    [calls-fs-current-dir : bool
      (compiler-backend-runtime-index-calls? index "tl_fs_current_dir")]
    [calls-read-line : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_read_stdin_line")]
    [calls-read-bytes : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_read_stdin_bytes")]
    [calls-stdin-eof : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_stdin_eof")]
    [calls-flush-stdout : bool
      (compiler-backend-runtime-index-calls? index ".L_tl_flush_stdout")]
    [calls-process-output : bool
      (compiler-backend-runtime-index-calls? index "tl_process_output")]
    [calls-process-start : bool
      (compiler-backend-runtime-index-calls? index "tl_process_start")]
    [calls-process-wait : bool
      (compiler-backend-runtime-index-calls? index "tl_process_wait")]
    [calls-region-mark : bool
      (compiler-backend-runtime-index-calls? index "tl_region_mark")]
    [calls-region-reset : bool
      (compiler-backend-runtime-index-calls? index "tl_region_reset")]
    [calls-random-system-seed : bool
      (compiler-backend-runtime-index-calls? index "tl_random_system_seed")]
    [calls-windows-setup-instances : bool
      (compiler-backend-runtime-index-calls? index "tl_windows_setup_instances")]
    [calls-windows-sdk-registry-install : bool
      (compiler-backend-runtime-index-calls? index "tl_windows_sdk_registry_install")]
    [calls-env-var-exists : bool
      (compiler-backend-runtime-index-calls? index "tl_env_var_exists")]
    [calls-env-var-value : bool
      (compiler-backend-runtime-index-calls? index "tl_env_var_value")]
    [calls-env-path-separator : bool
      (compiler-backend-runtime-index-calls? index "env-path-separator")]
    [calls-profile-now-ms : bool
      (compiler-backend-runtime-index-calls? index "tl_profile_now_ms")]
    [calls-profile-alloc-total : bool
      (compiler-backend-runtime-index-calls? index "tl_profile_alloc_total")]
    [calls-profile-alloc-live : bool
      (compiler-backend-runtime-index-calls? index "tl_profile_alloc_live")]
    [calls-profile-alloc-peak : bool
      (compiler-backend-runtime-index-calls? index "tl_profile_alloc_peak")]
    [calls-profile-alloc-reset-peak : bool
      (compiler-backend-runtime-index-calls? index "tl_profile_alloc_reset_peak")]
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
    [needs-concat : bool
      (and (not defines-concat) (or extern-concat calls-concat))]
    [needs-string-eq : bool
      (and (not defines-string-eq) (or extern-string-eq calls-string-eq))]
    [needs-string-to-int : bool
      (and
        (not defines-string-to-int)
        (or extern-string-to-int calls-string-to-int))]
    [needs-int-to-string : bool
      (and
        (not defines-int-to-string)
        (or extern-int-to-string calls-int-to-string))]
    [direct-abort : bool false]
    [needs-print-err : bool
      (and (not defines-print-err) (or extern-print-err calls-print-err))]
    [needs-print-str : bool
      (and
        (not (or defines-print-str defines-print-string))
        (or extern-print-str (or calls-print-str calls-print-string)))]
    [needs-print-char : bool
      (and (not defines-print-char) (or extern-print-char calls-print-char))]
    [needs-print-f64 : bool
      (and (not defines-print-f64) (or extern-print-f64 calls-print-f64))]
    [needs-arg-count : bool (or extern-arg-count calls-arg-count)]
    [needs-arg : bool (or extern-arg calls-arg)]
    [needs-read-file : bool
      (or
        (or extern-read-file calls-read-file)
        (or extern-read-file-status calls-read-file-status))]
    [needs-write-file : bool
      (or
        (or extern-write-file calls-write-file)
        (or
          (or extern-write-file-status calls-write-file-status)
          (or extern-append-file-status calls-append-file-status)))]
    [needs-file-exists : bool
      (or
        (or extern-file-exists calls-file-exists)
        (or extern-file-exists-status calls-file-exists-status))]
    [needs-file-handle : bool
      (or
        (or
          (or extern-file-open-status calls-file-open-status)
          (or extern-file-close-status calls-file-close-status))
        (or
          (or extern-file-write-status calls-file-write-status)
          (or extern-file-flush-status calls-file-flush-status)))]
    [needs-file-read-chunk : bool
      (or
        (or extern-file-read-chunk-status calls-file-read-chunk-status)
        (or
          extern-file-read-chunk-bytes
          (or
            calls-file-read-chunk-bytes
            (or extern-file-read-chunk-eof calls-file-read-chunk-eof))))]
    [needs-fs-runtime : bool
      (or
        (or
          (backend-or8
            extern-fs-mkdir-status
            extern-fs-remove-file-status
            extern-fs-remove-dir-status
            extern-fs-rename-status
            extern-fs-process-id
            extern-fs-read-dir-status
            extern-fs-read-dir
            extern-fs-file-kind-status)
          (or extern-fs-file-size-status extern-fs-file-size))
        (or
          (backend-or8
            calls-fs-mkdir-status
            calls-fs-remove-file-status
            calls-fs-remove-dir-status
            calls-fs-rename-status
            calls-fs-process-id
            calls-fs-read-dir-status
            calls-fs-read-dir
            calls-fs-file-kind-status)
          (or calls-fs-file-size-status calls-fs-file-size)))]
    [needs-fs-current-dir : bool
      (or
        (or extern-fs-current-dir-status extern-fs-current-dir)
        (or calls-fs-current-dir-status calls-fs-current-dir))]
    [needs-read-line : bool (or extern-read-line calls-read-line)]
    [needs-read-bytes : bool (or extern-read-bytes calls-read-bytes)]
    [needs-stdin-eof : bool (or extern-stdin-eof calls-stdin-eof)]
    [needs-flush-stdout : bool (or extern-flush-stdout calls-flush-stdout)]
    [needs-process-output : bool
      (or
        (and
          (not defines-process-output)
          (or extern-process-output calls-process-output))
        (or
          (and
            (not defines-process-start)
            (or extern-process-start calls-process-start))
          (and
            (not defines-process-wait)
            (or extern-process-wait calls-process-wait))))]
    [needs-region-mark : bool
      (and (not defines-region-mark) (or extern-region-mark calls-region-mark))]
    [needs-region-reset : bool
      (and
        (not defines-region-reset)
        (or extern-region-reset calls-region-reset))]
    [needs-random-system-seed : bool
      (and
        (not defines-random-system-seed)
        (or extern-random-system-seed calls-random-system-seed))]
    [needs-windows-setup-instances : bool
      (and
        (not defines-windows-setup-instances)
        (or extern-windows-setup-instances calls-windows-setup-instances))]
    [needs-windows-sdk-registry-install : bool
      (and
        (not defines-windows-sdk-registry-install)
        (or
          extern-windows-sdk-registry-install
          calls-windows-sdk-registry-install))]
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
      (or
        extern-abort
        (or calls-abort (or needs-arg (or needs-read-file needs-write-file))))]
    [needs-alloc : bool
      (or
        (backend-or8
          direct-alloc
          needs-int-to-string
          needs-substring
          needs-concat
          needs-arg
          needs-read-file
          needs-write-file
          needs-file-exists)
        (or
          (backend-or8
            needs-file-handle
            needs-file-read-chunk
            needs-fs-runtime
            needs-fs-current-dir
            needs-process-output
            needs-read-line
            needs-read-bytes
            needs-random-system-seed)
          (or
            needs-windows-setup-instances
            (backend-or4
              needs-windows-sdk-registry-install
              needs-env-var-exists
              needs-env-var-value
              needs-env-path-separator))))]
    [needs-profile : bool
      (or
        (backend-or4
          (and
            (not defines-profile-now-ms)
            (or extern-profile-now-ms calls-profile-now-ms))
          (and
            (not defines-profile-alloc-total)
            (or extern-profile-alloc-total calls-profile-alloc-total))
          (and
            (not defines-profile-alloc-live)
            (or extern-profile-alloc-live calls-profile-alloc-live))
          (and
            (not defines-profile-alloc-peak)
            (or extern-profile-alloc-peak calls-profile-alloc-peak)))
        (and
          (not defines-profile-alloc-reset-peak)
          (or extern-profile-alloc-reset-peak calls-profile-alloc-reset-peak)))]
    (OkBackendRuntimePlan
      (BackendRuntimePlan
        needs-alloc
        needs-oob
        needs-substring
        needs-concat
        needs-string-eq
        needs-string-to-int
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
        needs-process-output
        needs-read-line
        needs-read-bytes
        needs-stdin-eof
        needs-flush-stdout
        needs-region-mark
        needs-region-reset
        needs-random-system-seed
        needs-windows-setup-instances
        needs-windows-sdk-registry-install
        needs-env-var-exists
        needs-env-var-value
        needs-env-path-separator
        needs-div-abort
        needs-shift-abort
        (CompilerBackendRuntimeTailPlan needs-fs-current-dir needs-profile)))))

(define (compiler-backend-runtime-plan [program : CompilerIrProgram]) : ResultBackendRuntimePlan
  (match program
    [(IrProgram _ functions externs)
      (compiler-backend-runtime-plan-for functions externs)]))

(define (compiler-backend-emit-externs
  [externs : CompilerIrExternList]
  [plan : CompilerBackendRuntimePlan]) : String
  (match externs
    [(IrExternNil) ""]
    [(IrExternCons item rest)
      (match item
        [(IrExtern name _ _ link-symbol _)
          (if (or
            (and
              (string-eq name link-symbol)
              (compiler-backend-plan-provides? plan name))
            (compiler-backend-plan-provides? plan link-symbol))
            (compiler-backend-emit-externs (box-get rest) plan)
            (backend-cat4
              ".extern "
              (compiler-backend-link-symbol link-symbol plan)
              "\n"
              (compiler-backend-emit-externs (box-get rest) plan)))])]))

(define (compiler-backend-runtime-alloc-data-for-target
  [target : CompilerBackendTarget]) : String
  "    .section .rodata
.L_tl_alloc_msg:
    .byte 116,108,58,32,97,108,108,111,99,97,116,105,111,110,32,102,97,105,108,101,100,10
    .set .L_tl_alloc_msg_len, . - .L_tl_alloc_msg

")

;; `tl_current_arena` is the live bump-arena pointer shared by tl_alloc, the
;; region runtime, and the first-class arena builtins (#1633). It is the
;; program's SINGLE active-arena slot, emitted as a single `.globl` bss
;; definition for both targets. Like the arena primitives, the runtime lives in
;; exactly ONE object per executable (the entry object, `emit-entry=true`);
;; library/dependency objects (`emit-entry=false`) emit none of the runtime and
;; reference this slot as an extern, so a multi-object link (a package plus its
;; dependency .a archive) resolves to the single shared slot â€” no duplicate
;; definition.
(define (compiler-backend-runtime-arena-data-for-target
  [target : CompilerBackendTarget]) : String
  "    .globl tl_current_arena
    .section .bss
    .balign 8
tl_current_arena:
    .zero 8
    .balign 8
.L_tl_arena_poison_enabled:
    .zero 8

")

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

(define (compiler-backend-runtime-oob-data) : String
  "    .section .rodata
.L_tl_oob_msg:
    .byte 116,108,58,32,97,114,114,97,121,32,105,110,100,101,120,32,111,117,116,32,111,102,32,98,111,117,110,100,115,10
    .set .L_tl_oob_msg_len, . - .L_tl_oob_msg

")

(define (compiler-backend-runtime-div-data [div-abort : bool]) : String
  (if div-abort
    "    .section .rodata
.L_tl_div_msg:
    .ascii \"tl: integer division or remainder error\\n\"
    .set .L_tl_div_msg_len, . - .L_tl_div_msg

"
    ""))

(define (compiler-backend-runtime-shift-data [shift-abort : bool]) : String
  (if shift-abort
    "    .section .rodata
.L_tl_shift_msg:
    .ascii \"tl: shift count out of range\\n\"
    .set .L_tl_shift_msg_len, . - .L_tl_shift_msg

"
    ""))

(define (compiler-backend-runtime-stdio-data
  [read-line : bool]
  [read-bytes : bool]
  [stdin-eof : bool]) : String
  (if (or read-line (or read-bytes stdin-eof))
    (string-append
      "    .data
    .balign 8
.L_tl_stdin_eof_flag:
    .quad 0

"
      (if (or read-line read-bytes)
        "    .section .rodata
.L_tl_stdin_error_msg:
    .ascii \"tl: stdin failed\\n\"
    .set .L_tl_stdin_error_msg_len, . - .L_tl_stdin_error_msg

"
        ""))
    ""))

(define (compiler-backend-runtime-argv-data [arg-count : bool] [arg : bool]) : String
  (let
    [_arg-count : bool arg-count]
    (string-append
      "    .data
    .balign 8
.L_tl_argc:
    .quad 0
.L_tl_argv:
    .quad 0

"
      (if arg
        "    .section .rodata
.L_tl_arg_oob_msg:
    .ascii \"tl: argv index out of bounds\\n\"
    .set .L_tl_arg_oob_msg_len, . - .L_tl_arg_oob_msg

"
        ""))))

(define (compiler-backend-runtime-read-file-data [read-file : bool]) : String
  (if read-file
    "    .section .rodata
.L_tl_read_file_error_msg:
    .ascii \"tl: read-file failed\\n\"
    .set .L_tl_read_file_error_msg_len, . - .L_tl_read_file_error_msg

"
    ""))

(define (compiler-backend-runtime-write-file-data [write-file : bool]) : String
  (if write-file
    "    .section .rodata
.L_tl_write_file_error_msg:
    .ascii \"tl: write-file failed\\n\"
    .set .L_tl_write_file_error_msg_len, . - .L_tl_write_file_error_msg

"
    ""))

(define (compiler-backend-runtime-file-exists-data [file-exists : bool]) : String
  (if file-exists
    "    .section .rodata
.L_tl_file_exists_error_msg:
    .ascii \"tl: file-exists? failed\\n\"
    .set .L_tl_file_exists_error_msg_len, . - .L_tl_file_exists_error_msg

"
    ""))

(define (compiler-backend-runtime-file-handle-data
  [target : CompilerBackendTarget]
  [file-handle : bool]
  [file-read-chunk : bool]) : String
  (if (and
    (or file-handle file-read-chunk)
    (not (compiler-backend-target-windows? target)))
    "    .data
    .balign 8
.L_tl_file_handle_next:
    .quad 1
    .section .bss
    .balign 8
.L_tl_file_handle_fds:
    .zero 8192
.L_tl_file_handle_modes:
    .zero 8192
.L_tl_file_handle_states:
    .zero 8192
.L_tl_file_handle_eofs:
    .zero 8192
.L_tl_file_handle_last_ptrs:
    .zero 8192
.L_tl_file_handle_last_lens:
    .zero 8192
.L_tl_file_handle_last_eofs:
    .zero 8192

"
    ""))

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

(define (compiler-backend-runtime-data [plan : CompilerBackendRuntimePlan]) : String
  (compiler-backend-runtime-data-for-target (BackendTargetLinux) plan))

(define (compiler-backend-runtime-flush-stdout-data
  [target : CompilerBackendTarget]
  [flush-stdout : bool]) : String
  (if (and (compiler-backend-target-windows? target) flush-stdout)
    "    .section .rodata
.L_tl_flush_stdout_error_msg:
    .ascii \"tl: flush-stdout failed\\n\"
    .set .L_tl_flush_stdout_error_msg_len, . - .L_tl_flush_stdout_error_msg

"
    ""))

(define (compiler-backend-runtime-process-output-data
  [target : CompilerBackendTarget]
  [process-output : bool]) : String
  (if process-output
    (string-append
      ""
      "    .section .rodata
.L_tl_process_unsupported_msg:
    .ascii \"process: runtime execution is not supported on this target\"
    .set .L_tl_process_unsupported_msg_len, . - .L_tl_process_unsupported_msg
.L_tl_process_async_unsupported_msg:
    .ascii \"process: async child handles are not supported by this runtime\"
    .set .L_tl_process_async_unsupported_msg_len, . - .L_tl_process_async_unsupported_msg
.L_tl_process_spawn_msg:
    .ascii \"process: spawn failed\"
    .set .L_tl_process_spawn_msg_len, . - .L_tl_process_spawn_msg
.L_tl_process_wait_msg:
    .ascii \"process: wait failed\"
    .set .L_tl_process_wait_msg_len, . - .L_tl_process_wait_msg
.L_tl_process_exec_marker:
    .ascii \"exec\"
    .set .L_tl_process_exec_marker_len, . - .L_tl_process_exec_marker
.L_tl_process_stdout_name:
    .ascii \"typelisp-process-stdout\"
    .byte 0
.L_tl_process_stderr_name:
    .ascii \"typelisp-process-stderr\"
    .byte 0

")
    ""))

(define (compiler-backend-runtime-random-system-seed-data
  [random-system-seed : bool]) : String
  (if random-system-seed
    "    .section .rodata
.L_tl_random_system_seed_err_msg:
    .ascii \"random: system entropy unavailable\"
    .set .L_tl_random_system_seed_err_msg_len, . - .L_tl_random_system_seed_err_msg

"
    ""))

(define (compiler-backend-runtime-windows-setup-instances-data
  [windows-setup-instances : bool]) : String
  (if windows-setup-instances
    "    .section .rodata
.L_tl_windows_setup_unsupported_msg:
    .ascii \"windows setup: SetupConfiguration is only supported on windows-x86_64 targets\"
    .set .L_tl_windows_setup_unsupported_msg_len, . - .L_tl_windows_setup_unsupported_msg
.L_tl_windows_setup_unavailable_msg:
    .ascii \"windows setup: SetupConfiguration COM server is unavailable\"
    .set .L_tl_windows_setup_unavailable_msg_len, . - .L_tl_windows_setup_unavailable_msg

"
    ""))

(define (compiler-backend-runtime-windows-sdk-registry-install-data
  [windows-sdk-registry-install : bool]) : String
  (if windows-sdk-registry-install
    "    .section .rodata
.L_tl_windows_registry_unsupported_msg:
    .ascii \"windows registry: unsupported on non-Windows targets\"
    .set .L_tl_windows_registry_unsupported_msg_len, . - .L_tl_windows_registry_unsupported_msg

"
    ""))

(define (compiler-backend-runtime-print-f64-data [print-f64 : bool]) : String
  (if print-f64
    "    .section .rodata
.L_tl_print_f64_fmt:
    .asciz \"%.17g\\n\"

"
    ""))

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
        print-f64
        arg-count
        arg
        read-file
        write-file
        file-exists
        file-handle
        file-read-chunk
        _
        process-output
        read-line
        read-bytes
        stdin-eof
        flush-stdout
        region-mark
        region-reset
        random-system-seed
        windows-setup-instances
        windows-sdk-registry-install
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
          (if oob
            (compiler-backend-runtime-oob-data)
            "")
          (string-append
            (string-append
              (compiler-backend-runtime-div-data div-abort)
              (compiler-backend-runtime-shift-data shift-abort))
            (string-append
              (if region-reset
                (compiler-backend-runtime-region-reset-data)
                "")
              (string-append
                (string-append
                  (compiler-backend-runtime-print-f64-data print-f64)
                  (compiler-backend-runtime-argv-data arg-count arg))
                (string-append
                  (compiler-backend-runtime-read-file-data read-file)
                  (string-append
                    (compiler-backend-runtime-write-file-data write-file)
                    (string-append
                      (compiler-backend-runtime-file-exists-data file-exists)
                      (string-append
                        (compiler-backend-runtime-file-handle-data
                          target
                          file-handle
                          file-read-chunk)
                        (string-append
                          (compiler-backend-runtime-env-data
                            target
                            (or
                              process-output
                              (or env-var-exists env-var-value)))
                          (string-append
                            (compiler-backend-runtime-process-output-data
                              target
                              process-output)
                            (string-append
                              (compiler-backend-runtime-stdio-data
                                read-line
                                read-bytes
                                stdin-eof)
                              (string-append
                                (compiler-backend-runtime-flush-stdout-data
                                  target
                                  flush-stdout)
                                (string-append
                                  (compiler-backend-runtime-random-system-seed-data
                                    random-system-seed)
                                  (string-append
                                    (compiler-backend-runtime-windows-setup-instances-data
                                      windows-setup-instances)
                                    (compiler-backend-runtime-windows-sdk-registry-install-data
                                      windows-sdk-registry-install))))))))))))))))]))

(define (compiler-backend-runtime-profile-alloc-account
  [size-reg : String]
  [done-label : String]
  [profile : bool]) : String
  (if profile
    (string-append
      (backend-cat5
        "    addq "
        size-reg
        ", tl_profile_alloc_total_bytes(%rip)\n    addq "
        size-reg
        ", tl_profile_alloc_live_bytes(%rip)\n")
      (backend-cat5
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
    (backend-cat5
      "    movq 16("
      arena-reg
      "), "
      used-reg
      (backend-cat5
        "\n    subq 8("
        arena-reg
        "), "
        used-reg
        (backend-cat3
          "\n    subq "
          used-reg
          ", tl_profile_alloc_live_bytes(%rip)\n")))
    ""))

(define (compiler-backend-runtime-profile-live-rewind
  [arena-reg : String]
  [mark-reg : String]
  [used-reg : String]
  [profile : bool]) : String
  (if profile
    (backend-cat5
      "    movq 16("
      arena-reg
      "), "
      used-reg
      (backend-cat5
        "\n    subq "
        mark-reg
        ", "
        used-reg
        (backend-cat3
          "\n    subq "
          used-reg
          ", tl_profile_alloc_live_bytes(%rip)\n")))
    ""))

(define (compiler-backend-runtime-alloc-functions [profile : bool]) : String
  (string-append
    "    .globl tl_alloc
tl_alloc:
    addq $7, %rdi
    jc .L_tl_alloc_abort
    andq $-8, %rdi
    movq %rdi, %rsi
    movq tl_current_arena(%rip), %r8
    testq %r8, %r8
    jz .L_tl_alloc_new_arena
    movq 16(%r8), %rax
    movq %rax, %rcx
    addq %rsi, %rcx
    jc .L_tl_alloc_abort
    cmpq 24(%r8), %rcx
    ja .L_tl_alloc_new_arena
    movq %rcx, 16(%r8)
"
    (string-append
      (string-append
        (compiler-backend-runtime-profile-alloc-account
          "%rsi"
          ".L_tl_alloc_profile_fast_done"
          profile)
        "    ret
.L_tl_alloc_new_arena:
    movq $0x4000000, %rdx
    movq %rsi, %rcx
    addq $32, %rcx
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
    movq tl_current_arena(%rip), %r8
    movq %r8, 0(%rax)
    leaq 32(%rax), %r8
    movq %r8, 8(%rax)
    movq %rcx, 24(%rax)
    movq %r8, %rcx
    addq %rsi, %rcx
    movq %rcx, 16(%rax)
    movq %rax, tl_current_arena(%rip)
    movq %r8, %rax
")
      (string-append
        (compiler-backend-runtime-profile-alloc-account
          "%rsi"
          ".L_tl_alloc_profile_new_done"
          profile)
        "    ret
.L_tl_alloc_abort:
    movq $1, %rax
    movq $2, %rdi
    leaq .L_tl_alloc_msg(%rip), %rsi
    movq $.L_tl_alloc_msg_len, %rdx
    syscall
    movq $60, %rax
    movq $134, %rdi
    syscall

"))))

(define (compiler-backend-runtime-region-mark-functions) : String
  "    .globl tl_region_mark
tl_region_mark:
    movq tl_current_arena(%rip), %rax
    testq %rax, %rax
    jz .L_tl_region_mark_zero
    movq 16(%rax), %rax
    ret
.L_tl_region_mark_zero:
    xorq %rax, %rax
    ret

")

;; First-class arena runtime (#1633). `tl_arena_make` maps a fresh INDEPENDENT
;; 64 MiB arena chain (prev-link 0) and returns its header WITHOUT changing the
;; active arena. `tl_arena_current`/`tl_arena_set` read/write the active arena.
;; `tl_arena_destroy` releases an arena's whole chain (prev-links to 0). Arena
;; header is the same 32-byte record as tl_alloc {0:prev, 8:base, 16:bump,
;; 24:end}. System V (mmap=9 / munmap=11) flavor.
;;
;; These are `.globl` symbols. The runtime (arena primitives, tl_alloc, the
;; region runtime, and the `tl_current_arena` slot) is emitted in exactly ONE
;; object per executable â€” the entry/executable object (`emit-entry=true`).
;; Library/dependency objects (`emit-entry=false`) emit none of the runtime and
;; reference these symbols as externs, so a multi-object link (a package plus its
;; dependency .a archive) resolves every object's calls to the single definition
;; in the entry object â€” no `multiple definition` collision.
(define (compiler-backend-runtime-arena-functions [profile : bool]) : String
  (string-append
    "    .globl tl_arena_current
tl_arena_current:
    movq tl_current_arena(%rip), %rax
    ret

    .globl tl_arena_set
tl_arena_set:
    movq %rdi, tl_current_arena(%rip)
    ret

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
    leaq 32(%rax), %rcx
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

    .globl tl_arena_destroy
tl_arena_destroy:
    push %rbx
    movq %rdi, %rbx
.L_tl_arena_destroy_loop:
    testq %rbx, %rbx
    jz .L_tl_arena_destroy_done
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
.L_tl_arena_destroy_done:
    pop %rbx
    ret

")))

;; Windows flavor: VirtualAlloc/VirtualFree under the Win64 ABI. The arg arrives
;; in %rcx; a 32-byte shadow space is reserved before each call. A mapping
;; failure traps via `ud2` (no libc dependency).
(define (compiler-backend-runtime-windows-arena-functions [profile : bool]) : String
  (string-append
    "    .globl tl_arena_current
tl_arena_current:
    movq tl_current_arena(%rip), %rax
    ret

    .globl tl_arena_set
tl_arena_set:
    movq %rcx, tl_current_arena(%rip)
    ret

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
    leaq 32(%rax), %rcx
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

    .globl tl_arena_destroy
tl_arena_destroy:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %rsi
    sub $32, %rsp
    movq %rcx, %rsi
.L_tl_arena_destroy_win_loop:
    testq %rsi, %rsi
    jz .L_tl_arena_destroy_win_done
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
.L_tl_arena_destroy_win_done:
    add $32, %rsp
    popq %rsi
    popq %rbx
    popq %rbp
    ret

")))

(define (compiler-backend-runtime-region-reset-functions [profile : bool]) : String
  (string-append
    "    .globl tl_region_reset
tl_region_reset:
    push %rbx
    movq %rdi, %rbx
    testq %rbx, %rbx
    jz .L_tl_region_reset_all
    movq tl_current_arena(%rip), %r8
    testq %r8, %r8
    jz .L_tl_region_reset_invalid
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
    movq tl_current_arena(%rip), %r9
.L_tl_region_reset_drop_newer:
    cmpq %r8, %r9
    je .L_tl_region_reset_restore
    movq 0(%r9), %r10
"
    (string-append
      (compiler-backend-runtime-profile-live-sub "%r9" "%r11" profile)
      (string-append
        "    cmpq $0, .L_tl_arena_poison_enabled(%rip)
    je .L_tl_region_reset_drop_newer_unmap
    movq 8(%r9), %rdi
    movq 24(%r9), %rcx
    subq %rdi, %rcx
    jbe .L_tl_region_reset_drop_newer_unmap
    movb $0xA5, %al
    rep stosb
.L_tl_region_reset_drop_newer_unmap:
    movq 24(%r9), %rsi
    subq %r9, %rsi
    movq %r9, %rdi
    push %r8
    push %r10
    movq $11, %rax
    syscall
    pop %r10
    pop %r8
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
    movq %r8, tl_current_arena(%rip)
    pop %rbx
    ret
.L_tl_region_reset_all:
    movq tl_current_arena(%rip), %r8
    movq $0, tl_current_arena(%rip)
.L_tl_region_reset_all_loop:
    testq %r8, %r8
    jz .L_tl_region_reset_done
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
.L_tl_region_reset_done:
    pop %rbx
    ret
.L_tl_region_reset_invalid:
    movq $1, %rax
    movq $2, %rdi
    leaq .L_tl_region_reset_msg(%rip), %rsi
    movq $.L_tl_region_reset_msg_len, %rdx
    syscall
    movq $60, %rax
    movq $134, %rdi
    syscall

")))))))

(define (compiler-backend-runtime-windows-alloc-functions [profile : bool]) : String
  (string-append
    "    .globl tl_alloc
tl_alloc:
    testq %rcx, %rcx
    jg .L_tl_alloc_win_size_ready
    movq $1, %rcx
.L_tl_alloc_win_size_ready:
    addq $7, %rcx
    jc .L_tl_alloc_enter_abort
    andq $-8, %rcx
    movq %rcx, %r11
    movq tl_current_arena(%rip), %r8
    testq %r8, %r8
    jz .L_tl_alloc_new_arena_entry
    movq 16(%r8), %rax
    movq %rax, %r10
    addq %r11, %r10
    jc .L_tl_alloc_enter_abort
    cmpq 24(%r8), %r10
    ja .L_tl_alloc_new_arena_entry
    movq %r10, 16(%r8)
"
    (string-append
      (string-append
        (compiler-backend-runtime-profile-alloc-account
          "%r11"
          ".L_tl_alloc_profile_win_fast_done"
          profile)
        "    ret
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
.L_tl_alloc_new_arena:
    movq %r11, -8(%rbp)
    movq $0x4000000, %rdx
    movq %r11, %rax
    addq $32, %rax
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
    movq tl_current_arena(%rip), %r8
    movq %r8, 0(%rax)
    leaq 32(%rax), %r8
    movq %r8, 8(%rax)
    movq %rcx, 24(%rax)
    movq %r8, %r10
    addq %r11, %r10
    jc .L_tl_alloc_abort
    movq %r10, 16(%rax)
    movq %rax, tl_current_arena(%rip)
    movq %r8, %rax
")
      (string-append
        (compiler-backend-runtime-profile-alloc-account
          "%r11"
          ".L_tl_alloc_profile_win_new_done"
          profile)
        "
    mov %rbp, %rsp
    pop %rbp
    ret
.L_tl_alloc_abort:
    movq $2, %rcx
    leaq .L_tl_alloc_msg(%rip), %rdx
    movq $.L_tl_alloc_msg_len, %r8
    call _write
    movq $134, %rcx
    call exit

"))))

(define (compiler-backend-runtime-oob-functions) : String
  "    .globl tl_oob_abort
tl_oob_abort:
    movq $1, %rax
    movq $2, %rdi
    leaq .L_tl_oob_msg(%rip), %rsi
    movq $.L_tl_oob_msg_len, %rdx
    syscall
    movq $60, %rax
    movq $134, %rdi
    syscall

")

(define (compiler-backend-runtime-div-functions) : String
  "    .globl tl_div_abort
tl_div_abort:
    movq $1, %rax
    movq $2, %rdi
    leaq .L_tl_div_msg(%rip), %rsi
    movq $.L_tl_div_msg_len, %rdx
    syscall
    movq $60, %rax
    movq $135, %rdi
    syscall

")

(define (compiler-backend-runtime-shift-functions) : String
  "    .globl tl_shift_abort
tl_shift_abort:
    movq $1, %rax
    movq $2, %rdi
    leaq .L_tl_shift_msg(%rip), %rsi
    movq $.L_tl_shift_msg_len, %rdx
    syscall
    movq $60, %rax
    movq $129, %rdi
    syscall

")

(define (compiler-backend-runtime-abort-functions) : String
  "    .globl tl_abort_string
tl_abort_string:
    movq 8(%rdi), %rsi
    movq 0(%rdi), %rdi
    jmp .L_tl_abort
.L_tl_abort:
    movq %rsi, %rdx
    movq %rdi, %rsi
    movq $2, %rdi
    movq $1, %rax
    syscall
    movq $60, %rax
    movq $134, %rdi
    syscall

")

(define (compiler-backend-runtime-print-err-functions) : String
  "    .globl tl_print_error
tl_print_error:
    movq 8(%rdi), %rdx
    movq 0(%rdi), %rsi
    movq $2, %rdi
    movq $1, %rax
    syscall
    ret

    .globl tl_print_err
tl_print_err:
    movq %rsi, %rdx
    movq %rdi, %rsi
    movq $2, %rdi
    movq $1, %rax
    syscall
    ret

")

(define (compiler-backend-runtime-print-str-functions) : String
  "    .globl tl_print_string
tl_print_string:
    movq 8(%rdi), %rdx
    movq 0(%rdi), %rsi
    movq $1, %rdi
    movq $1, %rax
    syscall
    ret

    .globl tl_print_str
tl_print_str:
    movq %rsi, %rdx
    movq %rdi, %rsi
    movq $1, %rdi
    movq $1, %rax
    syscall
    ret

")

(define (compiler-backend-runtime-print-char-functions) : String
  "    .globl tl_print_char
tl_print_char:
    subq $8, %rsp
    movb %dil, (%rsp)
    movq %rsp, %rsi
    movq $1, %rdx
    movq $1, %rdi
    movq $1, %rax
    syscall
    addq $8, %rsp
    ret

")

(define (compiler-backend-runtime-print-f64-functions) : String
  "    .globl tl_print_f64
tl_print_f64:
    push %rbp
    mov %rsp, %rbp
    subq $128, %rsp
    leaq -128(%rbp), %rdi
    movq $128, %rsi
    leaq .L_tl_print_f64_fmt(%rip), %rdx
    movb $1, %al
    call snprintf
    movq %rax, %rdx
    cmpq $0, %rdx
    jl .L_tl_print_f64_done
    cmpq $128, %rdx
    jl .L_tl_print_f64_len_ready
    movq $127, %rdx
.L_tl_print_f64_len_ready:
    leaq -128(%rbp), %rsi
    movq $1, %rdi
    movq $1, %rax
    syscall
.L_tl_print_f64_done:
    mov %rbp, %rsp
    pop %rbp
    ret

")

(define (compiler-backend-runtime-arg-count-functions) : String
  "    .globl tl_arg_count
tl_arg_count:
.L_tl_arg_count:
    movq .L_tl_argc(%rip), %rax
    ret

")

(define (compiler-backend-runtime-arg-functions) : String
  "    .globl tl_arg
tl_arg:
.L_tl_arg:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $8, %rsp
    movq %rdi, %rbx
    cmpq $0, %rbx
    jl .L_tl_arg_oob
    movq .L_tl_argc(%rip), %rax
    cmpq %rax, %rbx
    jge .L_tl_arg_oob
    movq .L_tl_argv(%rip), %rax
    movq (%rax,%rbx,8), %rbx
    xorq %r12, %r12
.L_tl_arg_len_loop:
    cmpb $0, (%rbx,%r12)
    je .L_tl_arg_len_done
    incq %r12
    jmp .L_tl_arg_len_loop
.L_tl_arg_len_done:
    movq %r12, %rdi
    call tl_alloc
    movq %rax, %r13
    xorq %rcx, %rcx
.L_tl_arg_copy_loop:
    cmpq %r12, %rcx
    jge .L_tl_arg_copy_done
    movzbl (%rbx,%rcx), %edx
    movb %dl, (%r13,%rcx)
    incq %rcx
    jmp .L_tl_arg_copy_loop
.L_tl_arg_copy_done:
    movq $16, %rdi
    call tl_alloc
    movq %r13, 0(%rax)
    movq %r12, 8(%rax)
    add $8, %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
.L_tl_arg_oob:
    leaq .L_tl_arg_oob_msg(%rip), %rdi
    movq $.L_tl_arg_oob_msg_len, %rsi
    call .L_tl_abort

")

(define (compiler-backend-runtime-env-var-exists-functions) : String
  "    .globl tl_env_var_exists
tl_env_var_exists:
    .globl _tl_env_var_exists_question
_tl_env_var_exists_question:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    movq 0(%rdi), %rbx
    movq 8(%rdi), %r12
    cmpq $0, %r12
    jl .L_tl_env_var_exists_false
    movq .L_tl_envp(%rip), %r13
.L_tl_env_var_exists_next:
    movq (%r13), %r14
    testq %r14, %r14
    jz .L_tl_env_var_exists_false
    xorq %r15, %r15
.L_tl_env_var_exists_name_loop:
    cmpq %r12, %r15
    jge .L_tl_env_var_exists_name_done
    movzbl (%rbx,%r15), %eax
    cmpb %al, (%r14,%r15)
    jne .L_tl_env_var_exists_advance
    incq %r15
    jmp .L_tl_env_var_exists_name_loop
.L_tl_env_var_exists_name_done:
    cmpb $61, (%r14,%r12)
    je .L_tl_env_var_exists_true
.L_tl_env_var_exists_advance:
    addq $8, %r13
    jmp .L_tl_env_var_exists_next
.L_tl_env_var_exists_true:
    movq $1, %rax
    jmp .L_tl_env_var_exists_return
.L_tl_env_var_exists_false:
    xorq %rax, %rax
.L_tl_env_var_exists_return:
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")

(define (compiler-backend-runtime-env-var-value-functions) : String
  "    .globl tl_env_var_value
tl_env_var_value:
    .globl _tl_env_var_value
_tl_env_var_value:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    sub $8, %rsp
    movq 0(%rdi), %rbx
    movq 8(%rdi), %r12
    cmpq $0, %r12
    jl .L_tl_env_var_value_empty
    movq .L_tl_envp(%rip), %r13
.L_tl_env_var_value_next:
    movq (%r13), %r14
    testq %r14, %r14
    jz .L_tl_env_var_value_empty
    xorq %r15, %r15
.L_tl_env_var_value_name_loop:
    cmpq %r12, %r15
    jge .L_tl_env_var_value_name_done
    movzbl (%rbx,%r15), %eax
    cmpb %al, (%r14,%r15)
    jne .L_tl_env_var_value_advance
    incq %r15
    jmp .L_tl_env_var_value_name_loop
.L_tl_env_var_value_name_done:
    cmpb $61, (%r14,%r12)
    je .L_tl_env_var_value_found
.L_tl_env_var_value_advance:
    addq $8, %r13
    jmp .L_tl_env_var_value_next
.L_tl_env_var_value_found:
    leaq 1(%r14,%r12), %rbx
    xorq %r12, %r12
.L_tl_env_var_value_len_loop:
    cmpb $0, (%rbx,%r12)
    je .L_tl_env_var_value_len_done
    incq %r12
    jmp .L_tl_env_var_value_len_loop
.L_tl_env_var_value_len_done:
    movq %r12, %rdi
    call tl_alloc
    movq %rax, %r13
    xorq %rcx, %rcx
.L_tl_env_var_value_copy_loop:
    cmpq %r12, %rcx
    jge .L_tl_env_var_value_fat
    movzbl (%rbx,%rcx), %edx
    movb %dl, (%r13,%rcx)
    incq %rcx
    jmp .L_tl_env_var_value_copy_loop
.L_tl_env_var_value_empty:
    xorq %r12, %r12
    xorq %r13, %r13
.L_tl_env_var_value_fat:
    movq $16, %rdi
    call tl_alloc
    movq %r13, 0(%rax)
    movq %r12, 8(%rax)
    add $8, %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")

(define (compiler-backend-runtime-env-path-separator-functions) : String
  "    .globl _tl_env_path_separator
_tl_env_path_separator:
    push %rbp
    mov %rsp, %rbp
    push %r12
    sub $8, %rsp
    movq $1, %rdi
    call tl_alloc
    movq %rax, %r12
    movb $58, (%r12)
    movq $16, %rdi
    call tl_alloc
    movq %r12, 0(%rax)
    movq $1, 8(%rax)
    add $8, %rsp
    pop %r12
    pop %rbp
    ret

")

;; Windows variant of `_tl_env_path_separator`: builds the 1-char `;` String
;; (Windows PATH separator, byte 59) instead of `:`. Win64 ABI: tl_alloc takes
;; the size in %rcx and needs 32-byte shadow space at each call (its slow path
;; calls VirtualAlloc). Returns a String fat-value {ptr@0, len@8} in %rax.
(define (compiler-backend-runtime-windows-env-path-separator-functions) : String
  "    .globl _tl_env_path_separator
_tl_env_path_separator:
    push %rbp
    mov %rsp, %rbp
    push %r12
    sub $8, %rsp
    movq $1, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rax, %r12
    movb $59, (%r12)
    movq $16, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %r12, 0(%rax)
    movq $1, 8(%rax)
    add $8, %rsp
    pop %r12
    pop %rbp
    ret

")

;; Windows variant of `_tl_env_var_exists_question`. The Linux helper walks the
;; SysV stack-captured environment array (.L_tl_envp), which is never populated
;; on Windows, so this uses the CRT `getenv`. ABI: the String argument arrives
;; as a pointer to a {ptr,len} fat-value in %rcx (dereferenced 0(%rcx)/8(%rcx),
;; mirroring the Linux helper's 0(%rdi)/8(%rdi)). Copies the name into a fresh
;; NUL-terminated buffer, calls getenv, and returns bool (i64 0/1) in %rax.
(define (compiler-backend-runtime-windows-env-var-exists-functions) : String
  "    .globl tl_env_var_exists
tl_env_var_exists:
    .globl _tl_env_var_exists_question
_tl_env_var_exists_question:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $8, %rsp
    movq 0(%rcx), %rbx
    movq 8(%rcx), %r12
    cmpq $0, %r12
    jl .L_tl_env_var_exists_win_false
    movq %r12, %rax
    addq $1, %rax
    js .L_tl_env_var_exists_win_false
    movq %rax, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rax, %r13
    xorq %r10, %r10
.L_tl_env_var_exists_win_name_copy_loop:
    cmpq %r12, %r10
    jge .L_tl_env_var_exists_win_name_copy_done
    movzbl (%rbx,%r10), %edx
    movb %dl, (%r13,%r10)
    incq %r10
    jmp .L_tl_env_var_exists_win_name_copy_loop
.L_tl_env_var_exists_win_name_copy_done:
    movb $0, (%r13,%r12)
    movq %r13, %rcx
    sub $32, %rsp
    call getenv
    add $32, %rsp
    testq %rax, %rax
    setne %al
    movzbq %al, %rax
    jmp .L_tl_env_var_exists_win_return
.L_tl_env_var_exists_win_false:
    xorq %rax, %rax
.L_tl_env_var_exists_win_return:
    add $8, %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")

;; Windows variant of `_tl_env_var_value`. Like env-var-exists, uses the CRT
;; `getenv` (the Linux `.L_tl_envp` walk is unavailable on Windows). The String
;; name arrives as a pointer to a {ptr,len} fat-value in %rcx. Copies the name
;; into a NUL-terminated buffer, getenv -> char* (NULL if unset), strlen, copies
;; the value into a fresh buffer, and returns a String fat-value {ptr,len} in
;; %rax (the empty String {0,0} when unset), matching the Linux helper.
(define (compiler-backend-runtime-windows-env-var-value-functions) : String
  "    .globl tl_env_var_value
tl_env_var_value:
    .globl _tl_env_var_value
_tl_env_var_value:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $8, %rsp
    movq 0(%rcx), %rbx
    movq 8(%rcx), %r12
    cmpq $0, %r12
    jl .L_tl_env_var_value_win_empty
    movq %r12, %rcx
    addq $1, %rcx
    js .L_tl_env_var_value_win_empty
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rax, %r13
    xorq %rcx, %rcx
.L_tl_env_var_value_win_name_copy_loop:
    cmpq %r12, %rcx
    jge .L_tl_env_var_value_win_name_copy_done
    movzbl (%rbx,%rcx), %edx
    movb %dl, (%r13,%rcx)
    incq %rcx
    jmp .L_tl_env_var_value_win_name_copy_loop
.L_tl_env_var_value_win_name_copy_done:
    movb $0, (%r13,%r12)
    movq %r13, %rcx
    sub $32, %rsp
    call getenv
    add $32, %rsp
    testq %rax, %rax
    jz .L_tl_env_var_value_win_empty
    movq %rax, %rbx
    movq %rbx, %rcx
    sub $32, %rsp
    call strlen
    add $32, %rsp
    movq %rax, %r12
    movq %r12, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rax, %r13
    xorq %rcx, %rcx
.L_tl_env_var_value_win_copy_loop:
    cmpq %r12, %rcx
    jge .L_tl_env_var_value_win_fat
    movzbl (%rbx,%rcx), %edx
    movb %dl, (%r13,%rcx)
    incq %rcx
    jmp .L_tl_env_var_value_win_copy_loop
.L_tl_env_var_value_win_empty:
    xorq %r12, %r12
    xorq %r13, %r13
.L_tl_env_var_value_win_fat:
    movq $16, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %r13, 0(%rax)
    movq %r12, 8(%rax)
    add $8, %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")

;; Windows variant of `tl_region_reset`. Identical arena-walk structure to the
;; Linux helper (offsets: 0=prev arena, 8=usable base, 16=bump pointer, 24=end;
;; the arena header sits at the VirtualAlloc base). The only difference is how
;; newer arenas are released: Linux uses `munmap`, Windows uses
;; `VirtualFree(lpAddress=arena, dwSize=0, dwFreeType=MEM_RELEASE=0x8000)` â€” the
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
    sub $8, %rsp
    movq %rcx, %r12
    testq %r12, %r12
    jz .L_tl_region_reset_win_all
    movq tl_current_arena(%rip), %r13
    testq %r13, %r13
    jz .L_tl_region_reset_win_invalid
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
    movq $2, %rcx
    leaq .L_tl_region_reset_msg(%rip), %rdx
    movq $.L_tl_region_reset_msg_len, %r8
    sub $32, %rsp
    call _write
    add $32, %rsp
    movq $134, %rcx
    sub $32, %rsp
    call exit
.L_tl_region_reset_win_found:
    movq tl_current_arena(%rip), %r14
.L_tl_region_reset_win_drop:
    cmpq %r13, %r14
    je .L_tl_region_reset_win_restore
    movq 0(%r14), %rbx
"
    (string-append
      (compiler-backend-runtime-profile-live-sub "%r14" "%rax" profile)
      (string-append
        "    movq %r14, %rcx
    xorq %rdx, %rdx
    movq $0x8000, %r8
    sub $32, %rsp
    call VirtualFree
    add $32, %rsp
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
    movq %r13, tl_current_arena(%rip)
    jmp .L_tl_region_reset_win_done
.L_tl_region_reset_win_all:
    movq tl_current_arena(%rip), %r14
    movq $0, tl_current_arena(%rip)
.L_tl_region_reset_win_all_drop:
    testq %r14, %r14
    jz .L_tl_region_reset_win_done
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
.L_tl_region_reset_win_done:
    add $8, %rsp
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")))))))

(define (compiler-backend-runtime-profile-functions) : String
  "    .globl tl_profile_now_ms
tl_profile_now_ms:
    subq $16, %rsp
    movq $1, %rdi
    movq %rsp, %rsi
    movq $228, %rax
    syscall
    testq %rax, %rax
    js .L_tl_profile_now_zero
    movq 0(%rsp), %r8
    imulq $1000, %r8, %r8
    movq 8(%rsp), %rax
    xorq %rdx, %rdx
    movq $1000000, %rcx
    divq %rcx
    addq %r8, %rax
    addq $16, %rsp
    ret
.L_tl_profile_now_zero:
    xorq %rax, %rax
    addq $16, %rsp
    ret

    .globl tl_profile_alloc_total
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

(define (compiler-backend-runtime-windows-profile-functions) : String
  "    .globl tl_profile_now_ms
tl_profile_now_ms:
    push %rbp
    mov %rsp, %rbp
    sub $32, %rsp
    call GetTickCount64
    mov %rbp, %rsp
    pop %rbp
    ret

    .globl tl_profile_alloc_total
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
  (if profile
    (if (compiler-backend-target-windows? target)
      (compiler-backend-runtime-windows-profile-functions)
      (compiler-backend-runtime-profile-functions))
    ""))

(define (compiler-backend-runtime-read-file-functions) : String
  "    .globl tl_read_file
tl_read_file:
    movq 0(%rdi), %rax
    movq 8(%rdi), %rsi
    movq %rax, %rdi
    jmp .L_tl_read_file
.L_tl_read_file:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $8, %rsp
    movq %rdi, %rbx
    movq %rsi, %r12
    cmpq $0, %r12
    jl .L_tl_read_file_error
    movq %r12, %rdi
    addq $1, %rdi
    js .L_tl_read_file_error
    call tl_alloc
    movq %rax, %r13
    movq %r12, %rcx
    movq %rbx, %rsi
    movq %r13, %rdi
    rep movsb
    movb $0, (%r13,%r12)
    movq $257, %rax
    movq $-100, %rdi
    movq %r13, %rsi
    xorq %rdx, %rdx
    xorq %r10, %r10
    syscall
    testq %rax, %rax
    js .L_tl_read_file_error
    movq %rax, %rbx
    movq $8, %rax
    movq %rbx, %rdi
    xorq %rsi, %rsi
    movq $2, %rdx
    syscall
    testq %rax, %rax
    js .L_tl_read_file_close_error
    movq %rax, %r12
    movq $8, %rax
    movq %rbx, %rdi
    xorq %rsi, %rsi
    xorq %rdx, %rdx
    syscall
    testq %rax, %rax
    js .L_tl_read_file_close_error
    movq %r12, %rdi
    call tl_alloc
    movq %rax, %r13
    xorq %rax, %rax
    movq %rbx, %rdi
    movq %r13, %rsi
    movq %r12, %rdx
    syscall
    testq %rax, %rax
    js .L_tl_read_file_close_error
    cmpq %r12, %rax
    jne .L_tl_read_file_close_error
    movq $3, %rax
    movq %rbx, %rdi
    syscall
    testq %rax, %rax
    js .L_tl_read_file_error
    movq $16, %rdi
    call tl_alloc
    movq %r13, 0(%rax)
    movq %r12, 8(%rax)
    add $8, %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
.L_tl_read_file_close_error:
    movq $3, %rax
    movq %rbx, %rdi
    syscall
.L_tl_read_file_error:
    leaq .L_tl_read_file_error_msg(%rip), %rdi
    movq $.L_tl_read_file_error_msg_len, %rsi
    call .L_tl_abort

")

(define (compiler-backend-runtime-write-file-functions) : String
  "    .globl tl_write_file
tl_write_file:
    movq %rsi, %r8
    movq 0(%rdi), %r9
    movq 8(%rdi), %rsi
    movq 0(%r8), %rdx
    movq 8(%r8), %rcx
    movq %r9, %rdi
    jmp .L_tl_write_file
.L_tl_write_file:
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
    cmpq $0, %r12
    jl .L_tl_write_file_error
    cmpq $0, %r14
    jl .L_tl_write_file_error
    movq %r12, %rdi
    addq $1, %rdi
    js .L_tl_write_file_error
    call tl_alloc
    movq %rax, %r15
    movq %r12, %rcx
    movq %rbx, %rsi
    movq %r15, %rdi
    rep movsb
    movb $0, (%r15,%r12)
    movq $257, %rax
    movq $-100, %rdi
    movq %r15, %rsi
    movq $577, %rdx
    movq $438, %r10
    syscall
    testq %rax, %rax
    js .L_tl_write_file_error
    movq %rax, %r15
    movq $1, %rax
    movq %r15, %rdi
    movq %r13, %rsi
    movq %r14, %rdx
    syscall
    testq %rax, %rax
    js .L_tl_write_file_close_error
    cmpq %r14, %rax
    jne .L_tl_write_file_close_error
    movq $3, %rax
    movq %r15, %rdi
    syscall
    testq %rax, %rax
    js .L_tl_write_file_error
    xorq %rax, %rax
    add $8, %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
.L_tl_write_file_close_error:
    movq $3, %rax
    movq %r15, %rdi
    syscall
.L_tl_write_file_error:
    leaq .L_tl_write_file_error_msg(%rip), %rdi
    movq $.L_tl_write_file_error_msg_len, %rsi
    call .L_tl_abort

")

(define (compiler-backend-runtime-file-exists-functions) : String
  "    .globl tl_file_exists
tl_file_exists:
    movq 0(%rdi), %rax
    movq 8(%rdi), %rsi
    movq %rax, %rdi
    jmp .L_tl_file_exists
.L_tl_file_exists:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $8, %rsp
    movq %rdi, %rbx
    movq %rsi, %r12
    cmpq $0, %r12
    jl .L_tl_file_exists_error
    movq %r12, %rdi
    addq $1, %rdi
    js .L_tl_file_exists_error
    call tl_alloc
    movq %rax, %r13
    movq %r12, %rcx
    movq %rbx, %rsi
    movq %r13, %rdi
    rep movsb
    movb $0, (%r13,%r12)
    movq $21, %rax
    movq %r13, %rdi
    xorq %rsi, %rsi
    syscall
    testq %rax, %rax
    jz .L_tl_file_exists_true
    cmpq $-2, %rax
    je .L_tl_file_exists_false
    jmp .L_tl_file_exists_error
.L_tl_file_exists_true:
    movq $1, %rax
    jmp .L_tl_file_exists_return
.L_tl_file_exists_false:
    xorq %rax, %rax
.L_tl_file_exists_return:
    add $8, %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
.L_tl_file_exists_error:
    leaq .L_tl_file_exists_error_msg(%rip), %rdi
    movq $.L_tl_file_exists_error_msg_len, %rsi
    call .L_tl_abort

")

(define (compiler-backend-runtime-read-file-status-functions) : String
  "    .globl tl_read_file_status
tl_read_file_status:
    movq 0(%rdi), %rax
    movq 8(%rdi), %rsi
    movq %rax, %rdi
    jmp .L_tl_read_file_status
.L_tl_read_file_status:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $8, %rsp
    movq %rdi, %rbx
    movq %rsi, %r12
    cmpq $0, %r12
    jl .L_tl_read_file_status_invalid
    movq %r12, %rdi
    addq $1, %rdi
    js .L_tl_read_file_status_invalid
    call tl_alloc
    movq %rax, %r13
    movq %r12, %rcx
    movq %rbx, %rsi
    movq %r13, %rdi
    rep movsb
    movb $0, (%r13,%r12)
    movq $257, %rax
    movq $-100, %rdi
    movq %r13, %rsi
    xorq %rdx, %rdx
    xorq %r10, %r10
    syscall
    testq %rax, %rax
    js .L_tl_read_file_status_error_from_rax
    movq %rax, %rbx
    movq $8, %rax
    movq %rbx, %rdi
    xorq %rsi, %rsi
    movq $2, %rdx
    syscall
    testq %rax, %rax
    js .L_tl_read_file_status_close_error_from_rax
    movq %rax, %r13
    movq $8, %rax
    movq %rbx, %rdi
    xorq %rsi, %rsi
    xorq %rdx, %rdx
    syscall
    testq %rax, %rax
    js .L_tl_read_file_status_close_error_from_rax
    cmpq $0, %r13
    je .L_tl_read_file_status_close_success
    xorq %rax, %rax
    movq %rbx, %rdi
    leaq -32(%rbp), %rsi
    movq $1, %rdx
    syscall
    testq %rax, %rax
    js .L_tl_read_file_status_close_error_from_rax
.L_tl_read_file_status_close_success:
    movq $3, %rax
    movq %rbx, %rdi
    syscall
    testq %rax, %rax
    js .L_tl_read_file_status_error_from_rax
    xorq %rax, %rax
    jmp .L_tl_read_file_status_return
.L_tl_read_file_status_close_error_from_rax:
    negq %rax
    movq %rax, %r12
    movq $3, %rax
    movq %rbx, %rdi
    syscall
    movq %r12, %rax
    jmp .L_tl_read_file_status_return
.L_tl_read_file_status_error_from_rax:
    negq %rax
    jmp .L_tl_read_file_status_return
.L_tl_read_file_status_invalid:
    movq $22, %rax
.L_tl_read_file_status_return:
    add $8, %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")

(define (compiler-backend-runtime-write-file-status-functions) : String
  "    .globl tl_write_file_status
tl_write_file_status:
    movq %rsi, %r8
    movq 0(%rdi), %r9
    movq 8(%rdi), %rsi
    movq 0(%r8), %rdx
    movq 8(%r8), %rcx
    movq %r9, %rdi
    jmp .L_tl_write_file_status
.L_tl_write_file_status:
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
    cmpq $0, %r12
    jl .L_tl_write_file_status_invalid
    cmpq $0, %r14
    jl .L_tl_write_file_status_invalid
    movq %r12, %rdi
    addq $1, %rdi
    js .L_tl_write_file_status_invalid
    call tl_alloc
    movq %rax, %r15
    movq %r12, %rcx
    movq %rbx, %rsi
    movq %r15, %rdi
    rep movsb
    movb $0, (%r15,%r12)
    movq $257, %rax
    movq $-100, %rdi
    movq %r15, %rsi
    movq $577, %rdx
    movq $438, %r10
    syscall
    testq %rax, %rax
    js .L_tl_write_file_status_error_from_rax
    movq %rax, %r15
    movq $1, %rax
    movq %r15, %rdi
    movq %r13, %rsi
    movq %r14, %rdx
    syscall
    testq %rax, %rax
    js .L_tl_write_file_status_close_error_from_rax
    cmpq %r14, %rax
    jne .L_tl_write_file_status_short_write
    movq $3, %rax
    movq %r15, %rdi
    syscall
    testq %rax, %rax
    js .L_tl_write_file_status_error_from_rax
    xorq %rax, %rax
    jmp .L_tl_write_file_status_return
.L_tl_write_file_status_short_write:
    movq $5, %r12
    movq $3, %rax
    movq %r15, %rdi
    syscall
    movq %r12, %rax
    jmp .L_tl_write_file_status_return
.L_tl_write_file_status_close_error_from_rax:
    negq %rax
    movq %rax, %r12
    movq $3, %rax
    movq %r15, %rdi
    syscall
    movq %r12, %rax
    jmp .L_tl_write_file_status_return
.L_tl_write_file_status_error_from_rax:
    negq %rax
    jmp .L_tl_write_file_status_return
.L_tl_write_file_status_invalid:
    movq $22, %rax
.L_tl_write_file_status_return:
    add $8, %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")

(define (compiler-backend-runtime-append-file-status-functions) : String
  "    .globl tl_append_file_status
tl_append_file_status:
    movq %rsi, %r8
    movq 0(%rdi), %r9
    movq 8(%rdi), %rsi
    movq 0(%r8), %rdx
    movq 8(%r8), %rcx
    movq %r9, %rdi
    jmp .L_tl_append_file_status
.L_tl_append_file_status:
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
    cmpq $0, %r12
    jl .L_tl_append_file_status_invalid
    cmpq $0, %r14
    jl .L_tl_append_file_status_invalid
    movq %r12, %rdi
    addq $1, %rdi
    js .L_tl_append_file_status_invalid
    call tl_alloc
    movq %rax, %r15
    movq %r12, %rcx
    movq %rbx, %rsi
    movq %r15, %rdi
    rep movsb
    movb $0, (%r15,%r12)
    movq $257, %rax
    movq $-100, %rdi
    movq %r15, %rsi
    movq $1089, %rdx
    movq $438, %r10
    syscall
    testq %rax, %rax
    js .L_tl_append_file_status_error_from_rax
    movq %rax, %r15
    movq $1, %rax
    movq %r15, %rdi
    movq %r13, %rsi
    movq %r14, %rdx
    syscall
    testq %rax, %rax
    js .L_tl_append_file_status_close_error_from_rax
    cmpq %r14, %rax
    jne .L_tl_append_file_status_short_write
    movq $3, %rax
    movq %r15, %rdi
    syscall
    testq %rax, %rax
    js .L_tl_append_file_status_error_from_rax
    xorq %rax, %rax
    jmp .L_tl_append_file_status_return
.L_tl_append_file_status_short_write:
    movq $5, %r12
    movq $3, %rax
    movq %r15, %rdi
    syscall
    movq %r12, %rax
    jmp .L_tl_append_file_status_return
.L_tl_append_file_status_close_error_from_rax:
    negq %rax
    movq %rax, %r12
    movq $3, %rax
    movq %r15, %rdi
    syscall
    movq %r12, %rax
    jmp .L_tl_append_file_status_return
.L_tl_append_file_status_error_from_rax:
    negq %rax
    jmp .L_tl_append_file_status_return
.L_tl_append_file_status_invalid:
    movq $22, %rax
.L_tl_append_file_status_return:
    add $8, %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")

(define (compiler-backend-runtime-file-exists-status-functions) : String
  "    .globl tl_file_exists_status
tl_file_exists_status:
    movq 0(%rdi), %rax
    movq 8(%rdi), %rsi
    movq %rax, %rdi
    jmp .L_tl_file_exists_status
.L_tl_file_exists_status:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $8, %rsp
    movq %rdi, %rbx
    movq %rsi, %r12
    cmpq $0, %r12
    jl .L_tl_file_exists_status_invalid
    movq %r12, %rdi
    addq $1, %rdi
    js .L_tl_file_exists_status_invalid
    call tl_alloc
    movq %rax, %r13
    movq %r12, %rcx
    movq %rbx, %rsi
    movq %r13, %rdi
    rep movsb
    movb $0, (%r13,%r12)
    movq $21, %rax
    movq %r13, %rdi
    xorq %rsi, %rsi
    syscall
    testq %rax, %rax
    jz .L_tl_file_exists_status_return
    negq %rax
    jmp .L_tl_file_exists_status_return
.L_tl_file_exists_status_invalid:
    movq $22, %rax
.L_tl_file_exists_status_return:
    add $8, %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")

(define (compiler-backend-runtime-file-open-status-functions) : String
  "    .globl tl_file_open_status
tl_file_open_status:
    movq %rsi, %rdx
    movq 8(%rdi), %rsi
    movq 0(%rdi), %rdi
    jmp .L_tl_file_open_status
.L_tl_file_open_status:
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
    movq %rdx, %r14
    cmpq $0, %r12
    jle .L_tl_file_open_status_invalid
    movq %r12, %rdi
    addq $1, %rdi
    js .L_tl_file_open_status_invalid
    call tl_alloc
    movq %rax, %r13
    movq %r12, %rcx
    movq %rbx, %rsi
    movq %r13, %rdi
    rep movsb
    movb $0, (%r13,%r12)
    cmpq $0, %r14
    je .L_tl_file_open_status_mode_read
    cmpq $1, %r14
    je .L_tl_file_open_status_mode_truncate
    cmpq $2, %r14
    je .L_tl_file_open_status_mode_append
    jmp .L_tl_file_open_status_invalid
.L_tl_file_open_status_mode_read:
    xorq %rdx, %rdx
    xorq %r10, %r10
    jmp .L_tl_file_open_status_open
.L_tl_file_open_status_mode_truncate:
    movq $577, %rdx
    movq $438, %r10
    jmp .L_tl_file_open_status_open
.L_tl_file_open_status_mode_append:
    movq $1089, %rdx
    movq $438, %r10
.L_tl_file_open_status_open:
    movq $257, %rax
    movq $-100, %rdi
    movq %r13, %rsi
    syscall
    testq %rax, %rax
    js .L_tl_file_open_status_return
    movq %rax, %r15
    movq .L_tl_file_handle_next(%rip), %rax
    cmpq $1024, %rax
    jge .L_tl_file_open_status_table_full
    leaq .L_tl_file_handle_fds(%rip), %rcx
    movq %r15, (%rcx,%rax,8)
    leaq .L_tl_file_handle_modes(%rip), %rcx
    movq %r14, (%rcx,%rax,8)
    leaq .L_tl_file_handle_states(%rip), %rcx
    movq $1, (%rcx,%rax,8)
    leaq .L_tl_file_handle_eofs(%rip), %rcx
    movq $0, (%rcx,%rax,8)
    leaq .L_tl_file_handle_last_ptrs(%rip), %rcx
    movq $0, (%rcx,%rax,8)
    leaq .L_tl_file_handle_last_lens(%rip), %rcx
    movq $0, (%rcx,%rax,8)
    leaq .L_tl_file_handle_last_eofs(%rip), %rcx
    movq $0, (%rcx,%rax,8)
    leaq 1(%rax), %rcx
    movq %rcx, .L_tl_file_handle_next(%rip)
    jmp .L_tl_file_open_status_return
.L_tl_file_open_status_table_full:
    movq $3, %rax
    movq %r15, %rdi
    syscall
    movq $-38, %rax
    jmp .L_tl_file_open_status_return
.L_tl_file_open_status_invalid:
    movq $-22, %rax
.L_tl_file_open_status_return:
    add $8, %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")

(define (compiler-backend-runtime-file-close-status-functions) : String
  "    .globl tl_file_close_status
tl_file_close_status:
.L_tl_file_close_status:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    movq %rdi, %rbx
    cmpq $1, %rbx
    jl .L_tl_file_close_status_unsupported
    cmpq $1024, %rbx
    jge .L_tl_file_close_status_unsupported
    leaq .L_tl_file_handle_states(%rip), %rcx
    movq (%rcx,%rbx,8), %rax
    cmpq $1, %rax
    jne .L_tl_file_close_status_unsupported
    leaq .L_tl_file_handle_fds(%rip), %rcx
    movq (%rcx,%rbx,8), %rdi
    movq $3, %rax
    syscall
    testq %rax, %rax
    js .L_tl_file_close_status_error_from_rax
    leaq .L_tl_file_handle_states(%rip), %rcx
    movq $2, (%rcx,%rbx,8)
    xorq %rax, %rax
    jmp .L_tl_file_close_status_return
.L_tl_file_close_status_error_from_rax:
    negq %rax
    jmp .L_tl_file_close_status_return
.L_tl_file_close_status_unsupported:
    movq $38, %rax
.L_tl_file_close_status_return:
    pop %rbx
    pop %rbp
    ret

")

(define (compiler-backend-runtime-file-write-status-functions) : String
  "    .globl tl_file_write_status
tl_file_write_status:
    movq 8(%rsi), %rdx
    movq 0(%rsi), %rsi
    jmp .L_tl_file_write_status
.L_tl_file_write_status:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    movq %rdi, %rbx
    movq %rsi, %r12
    movq %rdx, %r13
    cmpq $0, %r13
    jl .L_tl_file_write_status_invalid
    cmpq $1, %rbx
    jl .L_tl_file_write_status_unsupported
    cmpq $1024, %rbx
    jge .L_tl_file_write_status_unsupported
    leaq .L_tl_file_handle_states(%rip), %rcx
    movq (%rcx,%rbx,8), %rax
    cmpq $1, %rax
    jne .L_tl_file_write_status_unsupported
    leaq .L_tl_file_handle_modes(%rip), %rcx
    movq (%rcx,%rbx,8), %rax
    cmpq $0, %rax
    je .L_tl_file_write_status_unsupported
    testq %r13, %r13
    jz .L_tl_file_write_status_ok
    leaq .L_tl_file_handle_fds(%rip), %rcx
    movq (%rcx,%rbx,8), %r14
    xorq %r15, %r15
.L_tl_file_write_status_loop:
    cmpq %r13, %r15
    jge .L_tl_file_write_status_ok
    movq $1, %rax
    movq %r14, %rdi
    leaq (%r12,%r15), %rsi
    movq %r13, %rdx
    subq %r15, %rdx
    syscall
    testq %rax, %rax
    js .L_tl_file_write_status_error_from_rax
    testq %rax, %rax
    jz .L_tl_file_write_status_io_error
    addq %rax, %r15
    jmp .L_tl_file_write_status_loop
.L_tl_file_write_status_ok:
    xorq %rax, %rax
    jmp .L_tl_file_write_status_return
.L_tl_file_write_status_error_from_rax:
    negq %rax
    jmp .L_tl_file_write_status_return
.L_tl_file_write_status_invalid:
    movq $22, %rax
    jmp .L_tl_file_write_status_return
.L_tl_file_write_status_io_error:
    movq $5, %rax
    jmp .L_tl_file_write_status_return
.L_tl_file_write_status_unsupported:
    movq $38, %rax
.L_tl_file_write_status_return:
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")

(define (compiler-backend-runtime-file-flush-status-functions) : String
  "    .globl tl_file_flush_status
tl_file_flush_status:
.L_tl_file_flush_status:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    movq %rdi, %rbx
    cmpq $1, %rbx
    jl .L_tl_file_flush_status_unsupported
    cmpq $1024, %rbx
    jge .L_tl_file_flush_status_unsupported
    leaq .L_tl_file_handle_states(%rip), %rcx
    movq (%rcx,%rbx,8), %rax
    cmpq $1, %rax
    jne .L_tl_file_flush_status_unsupported
    leaq .L_tl_file_handle_modes(%rip), %rcx
    movq (%rcx,%rbx,8), %rax
    cmpq $0, %rax
    je .L_tl_file_flush_status_unsupported
    leaq .L_tl_file_handle_fds(%rip), %rcx
    movq (%rcx,%rbx,8), %rdi
    movq $74, %rax
    syscall
    testq %rax, %rax
    js .L_tl_file_flush_status_error_from_rax
    xorq %rax, %rax
    jmp .L_tl_file_flush_status_return
.L_tl_file_flush_status_error_from_rax:
    negq %rax
    jmp .L_tl_file_flush_status_return
.L_tl_file_flush_status_unsupported:
    movq $38, %rax
.L_tl_file_flush_status_return:
    pop %rbx
    pop %rbp
    ret

")

(define (compiler-backend-runtime-windows-file-handle-functions) : String
  "    .globl tl_file_open_status
tl_file_open_status:
.L_tl_file_open_status:
    movq $-38, %rax
    ret

    .globl tl_file_close_status
tl_file_close_status:
.L_tl_file_close_status:
    movq $38, %rax
    ret

    .globl tl_file_write_status
tl_file_write_status:
.L_tl_file_write_status:
    movq $38, %rax
    ret

    .globl tl_file_flush_status
tl_file_flush_status:
.L_tl_file_flush_status:
    movq $38, %rax
    ret

")

(define (compiler-backend-runtime-file-handle-functions
  [target : CompilerBackendTarget]) : String
  (if (compiler-backend-target-windows? target)
    (compiler-backend-runtime-windows-file-handle-functions)
    (backend-cat4
      (compiler-backend-runtime-file-open-status-functions)
      (compiler-backend-runtime-file-close-status-functions)
      (compiler-backend-runtime-file-write-status-functions)
      (compiler-backend-runtime-file-flush-status-functions))))

(define (compiler-backend-runtime-file-read-chunk-status-functions) : String
  "    .globl tl_file_read_chunk_status
tl_file_read_chunk_status:
.L_tl_file_read_chunk_status:
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
    cmpq $0, %r12
    jl .L_tl_file_read_chunk_status_invalid
    cmpq $1, %rbx
    jl .L_tl_file_read_chunk_status_unsupported
    cmpq $1024, %rbx
    jge .L_tl_file_read_chunk_status_unsupported
    leaq .L_tl_file_handle_states(%rip), %rcx
    movq (%rcx,%rbx,8), %rax
    cmpq $1, %rax
    jne .L_tl_file_read_chunk_status_unsupported
    leaq .L_tl_file_handle_modes(%rip), %rcx
    movq (%rcx,%rbx,8), %rax
    cmpq $0, %rax
    jne .L_tl_file_read_chunk_status_unsupported
    movq %r12, %rdi
    cmpq $0, %rdi
    jg .L_tl_file_read_chunk_status_alloc_ready
    movq $1, %rdi
.L_tl_file_read_chunk_status_alloc_ready:
    call tl_alloc
    movq %rax, %r14
    testq %r12, %r12
    jz .L_tl_file_read_chunk_status_zero
    leaq .L_tl_file_handle_fds(%rip), %rcx
    movq (%rcx,%rbx,8), %rdi
    movq %r14, %rsi
    movq %r12, %rdx
    xorq %rax, %rax
    syscall
    testq %rax, %rax
    js .L_tl_file_read_chunk_status_error_from_rax
    movq %rax, %r15
    leaq .L_tl_file_handle_last_ptrs(%rip), %rcx
    movq %r14, (%rcx,%rbx,8)
    leaq .L_tl_file_handle_last_lens(%rip), %rcx
    movq %r15, (%rcx,%rbx,8)
    testq %r15, %r15
    jz .L_tl_file_read_chunk_status_eof
    leaq .L_tl_file_handle_eofs(%rip), %rcx
    movq (%rcx,%rbx,8), %rax
    leaq .L_tl_file_handle_last_eofs(%rip), %rcx
    movq %rax, (%rcx,%rbx,8)
    xorq %rax, %rax
    jmp .L_tl_file_read_chunk_status_return
.L_tl_file_read_chunk_status_zero:
    leaq .L_tl_file_handle_last_ptrs(%rip), %rcx
    movq %r14, (%rcx,%rbx,8)
    leaq .L_tl_file_handle_last_lens(%rip), %rcx
    movq $0, (%rcx,%rbx,8)
    leaq .L_tl_file_handle_eofs(%rip), %rcx
    movq (%rcx,%rbx,8), %rax
    leaq .L_tl_file_handle_last_eofs(%rip), %rcx
    movq %rax, (%rcx,%rbx,8)
    xorq %rax, %rax
    jmp .L_tl_file_read_chunk_status_return
.L_tl_file_read_chunk_status_eof:
    leaq .L_tl_file_handle_eofs(%rip), %rcx
    movq $1, (%rcx,%rbx,8)
    leaq .L_tl_file_handle_last_eofs(%rip), %rcx
    movq $1, (%rcx,%rbx,8)
    xorq %rax, %rax
    jmp .L_tl_file_read_chunk_status_return
.L_tl_file_read_chunk_status_error_from_rax:
    negq %rax
    jmp .L_tl_file_read_chunk_status_return
.L_tl_file_read_chunk_status_invalid:
    movq $22, %rax
    jmp .L_tl_file_read_chunk_status_return
.L_tl_file_read_chunk_status_unsupported:
    movq $38, %rax
.L_tl_file_read_chunk_status_return:
    add $8, %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")

(define (compiler-backend-runtime-file-read-chunk-bytes-functions) : String
  "    .globl tl_file_read_chunk_bytes
tl_file_read_chunk_bytes:
.L_tl_file_read_chunk_bytes:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $8, %rsp
    movq %rdi, %rbx
    xorq %r12, %r12
    xorq %r13, %r13
    cmpq $1, %rbx
    jl .L_tl_file_read_chunk_bytes_alloc
    cmpq $1024, %rbx
    jge .L_tl_file_read_chunk_bytes_alloc
    leaq .L_tl_file_handle_last_ptrs(%rip), %rcx
    movq (%rcx,%rbx,8), %r12
    leaq .L_tl_file_handle_last_lens(%rip), %rcx
    movq (%rcx,%rbx,8), %r13
.L_tl_file_read_chunk_bytes_alloc:
    movq $16, %rdi
    call tl_alloc
    movq %r12, 0(%rax)
    movq %r13, 8(%rax)
    add $8, %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")

(define (compiler-backend-runtime-file-read-chunk-eof-functions) : String
  "    .globl tl_file_read_chunk_eof
tl_file_read_chunk_eof:
.L_tl_file_read_chunk_eof:
    movq $1, %rax
    cmpq $1, %rdi
    jl .L_tl_file_read_chunk_eof_return
    cmpq $1024, %rdi
    jge .L_tl_file_read_chunk_eof_return
    leaq .L_tl_file_handle_last_eofs(%rip), %rcx
    movq (%rcx,%rdi,8), %rax
.L_tl_file_read_chunk_eof_return:
    ret

")

(define (compiler-backend-runtime-windows-file-read-chunk-functions) : String
  "    .globl tl_file_read_chunk_status
tl_file_read_chunk_status:
.L_tl_file_read_chunk_status:
    movq $38, %rax
    ret

    .globl tl_file_read_chunk_bytes
tl_file_read_chunk_bytes:
.L_tl_file_read_chunk_bytes:
    push %rbp
    mov %rsp, %rbp
    push %r12
    sub $40, %rsp
    movq $1, %rcx
    call tl_alloc
    movq %rax, %r12
    movq $16, %rcx
    call tl_alloc
    movq %r12, 0(%rax)
    movq $0, 8(%rax)
    add $40, %rsp
    pop %r12
    pop %rbp
    ret

    .globl tl_file_read_chunk_eof
tl_file_read_chunk_eof:
.L_tl_file_read_chunk_eof:
    movq $1, %rax
    ret

")

(define (compiler-backend-runtime-file-read-chunk-functions
  [target : CompilerBackendTarget]) : String
  (if (compiler-backend-target-windows? target)
    (compiler-backend-runtime-windows-file-read-chunk-functions)
    (string-append
      (compiler-backend-runtime-file-read-chunk-status-functions)
      (string-append
        (compiler-backend-runtime-file-read-chunk-bytes-functions)
        (compiler-backend-runtime-file-read-chunk-eof-functions)))))

(define (compiler-backend-runtime-fs-functions) : String
  "    .globl tl_fs_mkdir_status
tl_fs_mkdir_status:
    movq 0(%rdi), %rax
    movq 8(%rdi), %rsi
    movq %rax, %rdi
    jmp .L_tl_fs_mkdir_status
.L_tl_fs_mkdir_status:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $8, %rsp
    movq %rdi, %rbx
    movq %rsi, %r12
    cmpq $0, %r12
    jl .L_tl_fs_mkdir_status_invalid
    movq %r12, %rdi
    addq $1, %rdi
    js .L_tl_fs_mkdir_status_invalid
    call tl_alloc
    movq %rax, %r13
    xorq %rcx, %rcx
.L_tl_fs_mkdir_status_path_copy_loop:
    cmpq %r12, %rcx
    jge .L_tl_fs_mkdir_status_path_copy_done
    movzbl (%rbx,%rcx), %edx
    movb %dl, (%r13,%rcx)
    incq %rcx
    jmp .L_tl_fs_mkdir_status_path_copy_loop
.L_tl_fs_mkdir_status_path_copy_done:
    movb $0, (%r13,%r12)
    movq $83, %rax
    movq %r13, %rdi
    movq $448, %rsi
    syscall
    testq %rax, %rax
    js .L_tl_fs_mkdir_status_error_from_rax
    xorq %rax, %rax
    jmp .L_tl_fs_mkdir_status_return
.L_tl_fs_mkdir_status_error_from_rax:
    negq %rax
    jmp .L_tl_fs_mkdir_status_return
.L_tl_fs_mkdir_status_invalid:
    movq $22, %rax
.L_tl_fs_mkdir_status_return:
    add $8, %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

    .globl tl_fs_remove_file_status
tl_fs_remove_file_status:
    movq 0(%rdi), %rax
    movq 8(%rdi), %rsi
    movq %rax, %rdi
    jmp .L_tl_fs_remove_file_status
.L_tl_fs_remove_file_status:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $8, %rsp
    movq %rdi, %rbx
    movq %rsi, %r12
    cmpq $0, %r12
    jl .L_tl_fs_remove_file_status_invalid
    movq %r12, %rdi
    addq $1, %rdi
    js .L_tl_fs_remove_file_status_invalid
    call tl_alloc
    movq %rax, %r13
    xorq %rcx, %rcx
.L_tl_fs_remove_file_status_path_copy_loop:
    cmpq %r12, %rcx
    jge .L_tl_fs_remove_file_status_path_copy_done
    movzbl (%rbx,%rcx), %edx
    movb %dl, (%r13,%rcx)
    incq %rcx
    jmp .L_tl_fs_remove_file_status_path_copy_loop
.L_tl_fs_remove_file_status_path_copy_done:
    movb $0, (%r13,%r12)
    movq $87, %rax
    movq %r13, %rdi
    syscall
    testq %rax, %rax
    js .L_tl_fs_remove_file_status_error_from_rax
    xorq %rax, %rax
    jmp .L_tl_fs_remove_file_status_return
.L_tl_fs_remove_file_status_error_from_rax:
    negq %rax
    jmp .L_tl_fs_remove_file_status_return
.L_tl_fs_remove_file_status_invalid:
    movq $22, %rax
.L_tl_fs_remove_file_status_return:
    add $8, %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

    .globl tl_fs_remove_dir_status
tl_fs_remove_dir_status:
    movq 0(%rdi), %rax
    movq 8(%rdi), %rsi
    movq %rax, %rdi
    jmp .L_tl_fs_remove_dir_status
.L_tl_fs_remove_dir_status:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $8, %rsp
    movq %rdi, %rbx
    movq %rsi, %r12
    cmpq $0, %r12
    jl .L_tl_fs_remove_dir_status_invalid
    movq %r12, %rdi
    addq $1, %rdi
    js .L_tl_fs_remove_dir_status_invalid
    call tl_alloc
    movq %rax, %r13
    xorq %rcx, %rcx
.L_tl_fs_remove_dir_status_path_copy_loop:
    cmpq %r12, %rcx
    jge .L_tl_fs_remove_dir_status_path_copy_done
    movzbl (%rbx,%rcx), %edx
    movb %dl, (%r13,%rcx)
    incq %rcx
    jmp .L_tl_fs_remove_dir_status_path_copy_loop
.L_tl_fs_remove_dir_status_path_copy_done:
    movb $0, (%r13,%r12)
    movq $84, %rax
    movq %r13, %rdi
    syscall
    testq %rax, %rax
    js .L_tl_fs_remove_dir_status_error_from_rax
    xorq %rax, %rax
    jmp .L_tl_fs_remove_dir_status_return
.L_tl_fs_remove_dir_status_error_from_rax:
    negq %rax
    jmp .L_tl_fs_remove_dir_status_return
.L_tl_fs_remove_dir_status_invalid:
    movq $22, %rax
.L_tl_fs_remove_dir_status_return:
    add $8, %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

    .globl tl_fs_rename_status
tl_fs_rename_status:
    movq %rsi, %r8
    movq 0(%rdi), %r9
    movq 8(%rdi), %rsi
    movq 0(%r8), %rdx
    movq 8(%r8), %rcx
    movq %r9, %rdi
    jmp .L_tl_fs_rename_status
.L_tl_fs_rename_status:
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
    cmpq $0, %r12
    jl .L_tl_fs_rename_status_invalid
    cmpq $0, %r14
    jl .L_tl_fs_rename_status_invalid
    movq %r12, %rdi
    addq $1, %rdi
    js .L_tl_fs_rename_status_invalid
    call tl_alloc
    movq %rax, %r15
    xorq %rcx, %rcx
.L_tl_fs_rename_status_source_copy_loop:
    cmpq %r12, %rcx
    jge .L_tl_fs_rename_status_source_copy_done
    movzbl (%rbx,%rcx), %edx
    movb %dl, (%r15,%rcx)
    incq %rcx
    jmp .L_tl_fs_rename_status_source_copy_loop
.L_tl_fs_rename_status_source_copy_done:
    movb $0, (%r15,%r12)
    movq %r14, %rdi
    addq $1, %rdi
    js .L_tl_fs_rename_status_invalid
    call tl_alloc
    movq %rax, %r10
    xorq %rcx, %rcx
.L_tl_fs_rename_status_destination_copy_loop:
    cmpq %r14, %rcx
    jge .L_tl_fs_rename_status_destination_copy_done
    movzbl (%r13,%rcx), %edx
    movb %dl, (%r10,%rcx)
    incq %rcx
    jmp .L_tl_fs_rename_status_destination_copy_loop
.L_tl_fs_rename_status_destination_copy_done:
    movb $0, (%r10,%r14)
    movq $82, %rax
    movq %r15, %rdi
    movq %r10, %rsi
    syscall
    testq %rax, %rax
    js .L_tl_fs_rename_status_error_from_rax
    xorq %rax, %rax
    jmp .L_tl_fs_rename_status_return
.L_tl_fs_rename_status_error_from_rax:
    negq %rax
    jmp .L_tl_fs_rename_status_return
.L_tl_fs_rename_status_invalid:
    movq $22, %rax
.L_tl_fs_rename_status_return:
    add $8, %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

.L_tl_fs_read_dir_status:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $8, %rsp
    movq %rdi, %rbx
    movq %rsi, %r12
    cmpq $0, %r12
    jl .L_tl_fs_read_dir_status_invalid
    movq %r12, %rdi
    addq $1, %rdi
    js .L_tl_fs_read_dir_status_invalid
    call tl_alloc
    movq %rax, %r13
    xorq %rcx, %rcx
.L_tl_fs_read_dir_status_path_copy_loop:
    cmpq %r12, %rcx
    jge .L_tl_fs_read_dir_status_path_copy_done
    movzbl (%rbx,%rcx), %edx
    movb %dl, (%r13,%rcx)
    incq %rcx
    jmp .L_tl_fs_read_dir_status_path_copy_loop
.L_tl_fs_read_dir_status_path_copy_done:
    movb $0, (%r13,%r12)
    movq $257, %rax
    movq $-100, %rdi
    movq %r13, %rsi
    movq $65536, %rdx
    xorq %r10, %r10
    syscall
    testq %rax, %rax
    js .L_tl_fs_read_dir_status_error_from_rax
    movq %rax, %rbx
    movq $3, %rax
    movq %rbx, %rdi
    syscall
    testq %rax, %rax
    js .L_tl_fs_read_dir_status_error_from_rax
    xorq %rax, %rax
    jmp .L_tl_fs_read_dir_status_return
.L_tl_fs_read_dir_status_error_from_rax:
    negq %rax
    jmp .L_tl_fs_read_dir_status_return
.L_tl_fs_read_dir_status_invalid:
    movq $22, %rax
.L_tl_fs_read_dir_status_return:
    add $8, %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

.L_tl_fs_read_dir:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    sub $24, %rsp
    movq %rdi, %rbx
    movq %rsi, %r12
    cmpq $0, %r12
    jl .L_tl_fs_read_dir_empty
    movq %r12, %rdi
    addq $1, %rdi
    js .L_tl_fs_read_dir_empty
    call tl_alloc
    movq %rax, %r13
    xorq %rcx, %rcx
.L_tl_fs_read_dir_path_copy_loop:
    cmpq %r12, %rcx
    jge .L_tl_fs_read_dir_path_copy_done
    movzbl (%rbx,%rcx), %edx
    movb %dl, (%r13,%rcx)
    incq %rcx
    jmp .L_tl_fs_read_dir_path_copy_loop
.L_tl_fs_read_dir_path_copy_done:
    movb $0, (%r13,%r12)
    movq $257, %rax
    movq $-100, %rdi
    movq %r13, %rsi
    movq $65536, %rdx
    xorq %r10, %r10
    syscall
    testq %rax, %rax
    js .L_tl_fs_read_dir_empty
    movq %rax, %rbx
    movq $32768, %rdi
    call tl_alloc
    movq %rax, %r14
    xorq %r15, %r15
.L_tl_fs_read_dir_first_getdents:
    movq $217, %rax
    movq %rbx, %rdi
    movq %r14, %rsi
    movq $32768, %rdx
    syscall
    testq %rax, %rax
    js .L_tl_fs_read_dir_close_empty
    cmpq $0, %rax
    je .L_tl_fs_read_dir_first_done
    movq %rax, -16(%rbp)
    xorq %rcx, %rcx
.L_tl_fs_read_dir_first_entry:
    cmpq -16(%rbp), %rcx
    jge .L_tl_fs_read_dir_first_getdents
    movzwq 16(%r14,%rcx), %r8
    testq %r8, %r8
    jz .L_tl_fs_read_dir_first_done
    leaq 19(%r14,%rcx), %rsi
    movzbl (%rsi), %edx
    cmpb $46, %dl
    jne .L_tl_fs_read_dir_first_count_name
    movzbl 1(%rsi), %edx
    testb %dl, %dl
    je .L_tl_fs_read_dir_first_next
    cmpb $46, %dl
    jne .L_tl_fs_read_dir_first_count_name
    movzbl 2(%rsi), %edx
    testb %dl, %dl
    je .L_tl_fs_read_dir_first_next
.L_tl_fs_read_dir_first_count_name:
    xorq %r9, %r9
.L_tl_fs_read_dir_first_len_loop:
    movzbl (%rsi,%r9), %edx
    testb %dl, %dl
    je .L_tl_fs_read_dir_first_len_done
    incq %r9
    jmp .L_tl_fs_read_dir_first_len_loop
.L_tl_fs_read_dir_first_len_done:
    addq %r9, %r15
    incq %r15
.L_tl_fs_read_dir_first_next:
    addq %r8, %rcx
    jmp .L_tl_fs_read_dir_first_entry
.L_tl_fs_read_dir_first_done:
    movq $3, %rax
    movq %rbx, %rdi
    syscall
    movq %r15, %rdi
    cmpq $0, %rdi
    jne .L_tl_fs_read_dir_alloc_output
    movq $1, %rdi
.L_tl_fs_read_dir_alloc_output:
    call tl_alloc
    movq %rax, %r12
    cmpq $0, %r15
    je .L_tl_fs_read_dir_return_string
    movq $257, %rax
    movq $-100, %rdi
    movq %r13, %rsi
    movq $65536, %rdx
    xorq %r10, %r10
    syscall
    testq %rax, %rax
    js .L_tl_fs_read_dir_empty
    movq %rax, %rbx
    movq $0, -8(%rbp)
.L_tl_fs_read_dir_second_getdents:
    movq $217, %rax
    movq %rbx, %rdi
    movq %r14, %rsi
    movq $32768, %rdx
    syscall
    testq %rax, %rax
    js .L_tl_fs_read_dir_close_empty
    cmpq $0, %rax
    je .L_tl_fs_read_dir_second_done
    movq %rax, -16(%rbp)
    xorq %rcx, %rcx
.L_tl_fs_read_dir_second_entry:
    cmpq -16(%rbp), %rcx
    jge .L_tl_fs_read_dir_second_getdents
    movzwq 16(%r14,%rcx), %r8
    testq %r8, %r8
    jz .L_tl_fs_read_dir_second_done
    movq %r8, -24(%rbp)
    leaq 19(%r14,%rcx), %rsi
    movzbl (%rsi), %edx
    cmpb $46, %dl
    jne .L_tl_fs_read_dir_second_count_name
    movzbl 1(%rsi), %edx
    testb %dl, %dl
    je .L_tl_fs_read_dir_second_next
    cmpb $46, %dl
    jne .L_tl_fs_read_dir_second_count_name
    movzbl 2(%rsi), %edx
    testb %dl, %dl
    je .L_tl_fs_read_dir_second_next
.L_tl_fs_read_dir_second_count_name:
    xorq %r9, %r9
.L_tl_fs_read_dir_second_len_loop:
    movzbl (%rsi,%r9), %edx
    testb %dl, %dl
    je .L_tl_fs_read_dir_second_len_done
    incq %r9
    jmp .L_tl_fs_read_dir_second_len_loop
.L_tl_fs_read_dir_second_len_done:
    movq -8(%rbp), %r8
    xorq %r10, %r10
.L_tl_fs_read_dir_second_copy_loop:
    cmpq %r9, %r10
    jge .L_tl_fs_read_dir_second_copy_done
    movzbl (%rsi,%r10), %edx
    movb %dl, (%r12,%r8)
    incq %r10
    incq %r8
    jmp .L_tl_fs_read_dir_second_copy_loop
.L_tl_fs_read_dir_second_copy_done:
    movb $10, (%r12,%r8)
    incq %r8
    movq %r8, -8(%rbp)
.L_tl_fs_read_dir_second_next:
    addq -24(%rbp), %rcx
    jmp .L_tl_fs_read_dir_second_entry
.L_tl_fs_read_dir_second_done:
    movq $3, %rax
    movq %rbx, %rdi
    syscall
    jmp .L_tl_fs_read_dir_return_string
.L_tl_fs_read_dir_close_empty:
    movq $3, %rax
    movq %rbx, %rdi
    syscall
.L_tl_fs_read_dir_empty:
    movq $1, %rdi
    call tl_alloc
    movq %rax, %r12
    xorq %r15, %r15
.L_tl_fs_read_dir_return_string:
    movq $16, %rdi
    call tl_alloc
    movq %r12, 0(%rax)
    movq %r15, 8(%rax)
    add $24, %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

.L_tl_fs_file_kind_status:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    sub $160, %rsp
    movq %rdi, %rbx
    movq %rsi, %r12
    cmpq $0, %r12
    jl .L_tl_fs_file_kind_status_invalid
    movq %r12, %rdi
    addq $1, %rdi
    js .L_tl_fs_file_kind_status_invalid
    call tl_alloc
    movq %rax, %r13
    xorq %rcx, %rcx
.L_tl_fs_file_kind_status_path_copy_loop:
    cmpq %r12, %rcx
    jge .L_tl_fs_file_kind_status_path_copy_done
    movzbl (%rbx,%rcx), %edx
    movb %dl, (%r13,%rcx)
    incq %rcx
    jmp .L_tl_fs_file_kind_status_path_copy_loop
.L_tl_fs_file_kind_status_path_copy_done:
    movb $0, (%r13,%r12)
    movq $262, %rax
    movq $-100, %rdi
    movq %r13, %rsi
    movq %rsp, %rdx
    xorq %r10, %r10
    syscall
    testq %rax, %rax
    js .L_tl_fs_file_kind_status_error_from_rax
    movl 24(%rsp), %eax
    andl $61440, %eax
    cmpl $32768, %eax
    je .L_tl_fs_file_kind_status_regular
    cmpl $16384, %eax
    je .L_tl_fs_file_kind_status_directory
    movq $-3, %rax
    jmp .L_tl_fs_file_kind_status_return
.L_tl_fs_file_kind_status_regular:
    movq $-1, %rax
    jmp .L_tl_fs_file_kind_status_return
.L_tl_fs_file_kind_status_directory:
    movq $-2, %rax
    jmp .L_tl_fs_file_kind_status_return
.L_tl_fs_file_kind_status_error_from_rax:
    negq %rax
    jmp .L_tl_fs_file_kind_status_return
.L_tl_fs_file_kind_status_invalid:
    movq $22, %rax
.L_tl_fs_file_kind_status_return:
    add $160, %rsp
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

.L_tl_fs_file_size_status:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    sub $160, %rsp
    movq %rdi, %rbx
    movq %rsi, %r12
    cmpq $0, %r12
    jl .L_tl_fs_file_size_status_invalid
    movq %r12, %rdi
    addq $1, %rdi
    js .L_tl_fs_file_size_status_invalid
    call tl_alloc
    movq %rax, %r13
    xorq %rcx, %rcx
.L_tl_fs_file_size_status_path_copy_loop:
    cmpq %r12, %rcx
    jge .L_tl_fs_file_size_status_path_copy_done
    movzbl (%rbx,%rcx), %edx
    movb %dl, (%r13,%rcx)
    incq %rcx
    jmp .L_tl_fs_file_size_status_path_copy_loop
.L_tl_fs_file_size_status_path_copy_done:
    movb $0, (%r13,%r12)
    movq $262, %rax
    movq $-100, %rdi
    movq %r13, %rsi
    movq %rsp, %rdx
    xorq %r10, %r10
    syscall
    testq %rax, %rax
    js .L_tl_fs_file_size_status_error_from_rax
    xorq %rax, %rax
    jmp .L_tl_fs_file_size_status_return
.L_tl_fs_file_size_status_error_from_rax:
    negq %rax
    jmp .L_tl_fs_file_size_status_return
.L_tl_fs_file_size_status_invalid:
    movq $22, %rax
.L_tl_fs_file_size_status_return:
    add $160, %rsp
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

.L_tl_fs_file_size:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    sub $160, %rsp
    movq %rdi, %rbx
    movq %rsi, %r12
    cmpq $0, %r12
    jl .L_tl_fs_file_size_zero
    movq %r12, %rdi
    addq $1, %rdi
    js .L_tl_fs_file_size_zero
    call tl_alloc
    movq %rax, %r13
    xorq %rcx, %rcx
.L_tl_fs_file_size_path_copy_loop:
    cmpq %r12, %rcx
    jge .L_tl_fs_file_size_path_copy_done
    movzbl (%rbx,%rcx), %edx
    movb %dl, (%r13,%rcx)
    incq %rcx
    jmp .L_tl_fs_file_size_path_copy_loop
.L_tl_fs_file_size_path_copy_done:
    movb $0, (%r13,%r12)
    movq $262, %rax
    movq $-100, %rdi
    movq %r13, %rsi
    movq %rsp, %rdx
    xorq %r10, %r10
    syscall
    testq %rax, %rax
    js .L_tl_fs_file_size_zero
    movq 48(%rsp), %rax
    jmp .L_tl_fs_file_size_return
.L_tl_fs_file_size_zero:
    xorq %rax, %rax
.L_tl_fs_file_size_return:
    add $160, %rsp
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

    .globl tl_fs_process_id
tl_fs_process_id:
.L_tl_fs_process_id:
    movq $39, %rax
    syscall
    ret

")

(define (compiler-backend-runtime-fs-current-dir-functions) : String
  "tl_fs_current_dir_status:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    sub $8, %rsp
    movq $4096, %rdi
    call tl_alloc
    movq %rax, %rbx
    movq $79, %rax
    movq %rbx, %rdi
    movq $4096, %rsi
    syscall
    testq %rax, %rax
    js .L_tl_fs_current_dir_status_error_from_rax
    xorq %rax, %rax
    jmp .L_tl_fs_current_dir_status_return
.L_tl_fs_current_dir_status_error_from_rax:
    negq %rax
.L_tl_fs_current_dir_status_return:
    add $8, %rsp
    pop %rbx
    pop %rbp
    ret

tl_fs_current_dir:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $8, %rsp
    movq $4096, %rdi
    call tl_alloc
    movq %rax, %rbx
    movq $79, %rax
    movq %rbx, %rdi
    movq $4096, %rsi
    syscall
    testq %rax, %rax
    js .L_tl_fs_current_dir_empty
    decq %rax
    movq %rax, %r12
    jmp .L_tl_fs_current_dir_alloc_result
.L_tl_fs_current_dir_empty:
    xorq %r12, %r12
.L_tl_fs_current_dir_alloc_result:
    movq $16, %rdi
    call tl_alloc
    movq %rbx, 0(%rax)
    movq %r12, 8(%rax)
    add $8, %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")

(define (compiler-backend-runtime-windows-fs-mkdir-status-functions) : String
  "    .globl tl_fs_mkdir_status
tl_fs_mkdir_status:
    movq 8(%rcx), %rdx
    movq 0(%rcx), %rcx
    jmp .L_tl_fs_mkdir_status
.L_tl_fs_mkdir_status:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $8, %rsp
    movq %rcx, %rbx
    movq %rdx, %r12
    cmpq $0, %r12
    jl .L_tl_fs_mkdir_status_win_invalid
    movq %r12, %rcx
    addq $1, %rcx
    js .L_tl_fs_mkdir_status_win_invalid
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rax, %r13
    xorq %r10, %r10
.L_tl_fs_mkdir_status_win_path_copy_loop:
    cmpq %r12, %r10
    jge .L_tl_fs_mkdir_status_win_path_copy_done
    movzbl (%rbx,%r10), %edx
    movb %dl, (%r13,%r10)
    incq %r10
    jmp .L_tl_fs_mkdir_status_win_path_copy_loop
.L_tl_fs_mkdir_status_win_path_copy_done:
    movb $0, (%r13,%r12)
    movq %r13, %rcx
    sub $32, %rsp
    call _mkdir
    add $32, %rsp
    testl %eax, %eax
    js .L_tl_fs_mkdir_status_win_errno
    xorq %rax, %rax
    jmp .L_tl_fs_mkdir_status_win_return
.L_tl_fs_mkdir_status_win_errno:
    sub $32, %rsp
    call _errno
    add $32, %rsp
    movslq (%rax), %rax
    testq %rax, %rax
    jne .L_tl_fs_mkdir_status_win_return
    movq $1, %rax
    jmp .L_tl_fs_mkdir_status_win_return
.L_tl_fs_mkdir_status_win_invalid:
    movq $22, %rax
.L_tl_fs_mkdir_status_win_return:
    add $8, %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")

(define (compiler-backend-runtime-windows-fs-remove-file-status-functions) : String
  "    .globl tl_fs_remove_file_status
tl_fs_remove_file_status:
    movq 8(%rcx), %rdx
    movq 0(%rcx), %rcx
    jmp .L_tl_fs_remove_file_status
.L_tl_fs_remove_file_status:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $8, %rsp
    movq %rcx, %rbx
    movq %rdx, %r12
    cmpq $0, %r12
    jl .L_tl_fs_remove_file_status_win_invalid
    movq %r12, %rcx
    addq $1, %rcx
    js .L_tl_fs_remove_file_status_win_invalid
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rax, %r13
    xorq %r10, %r10
.L_tl_fs_remove_file_status_win_path_copy_loop:
    cmpq %r12, %r10
    jge .L_tl_fs_remove_file_status_win_path_copy_done
    movzbl (%rbx,%r10), %edx
    movb %dl, (%r13,%r10)
    incq %r10
    jmp .L_tl_fs_remove_file_status_win_path_copy_loop
.L_tl_fs_remove_file_status_win_path_copy_done:
    movb $0, (%r13,%r12)
    movq %r13, %rcx
    sub $32, %rsp
    call _unlink
    add $32, %rsp
    testl %eax, %eax
    js .L_tl_fs_remove_file_status_win_errno
    xorq %rax, %rax
    jmp .L_tl_fs_remove_file_status_win_return
.L_tl_fs_remove_file_status_win_errno:
    sub $32, %rsp
    call _errno
    add $32, %rsp
    movslq (%rax), %rax
    testq %rax, %rax
    jne .L_tl_fs_remove_file_status_win_return
    movq $1, %rax
    jmp .L_tl_fs_remove_file_status_win_return
.L_tl_fs_remove_file_status_win_invalid:
    movq $22, %rax
.L_tl_fs_remove_file_status_win_return:
    add $8, %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")

(define (compiler-backend-runtime-windows-fs-remove-dir-status-functions) : String
  "    .globl tl_fs_remove_dir_status
tl_fs_remove_dir_status:
    movq 8(%rcx), %rdx
    movq 0(%rcx), %rcx
    jmp .L_tl_fs_remove_dir_status
.L_tl_fs_remove_dir_status:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $8, %rsp
    movq %rcx, %rbx
    movq %rdx, %r12
    cmpq $0, %r12
    jl .L_tl_fs_remove_dir_status_win_invalid
    movq %r12, %rcx
    addq $1, %rcx
    js .L_tl_fs_remove_dir_status_win_invalid
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rax, %r13
    xorq %r10, %r10
.L_tl_fs_remove_dir_status_win_path_copy_loop:
    cmpq %r12, %r10
    jge .L_tl_fs_remove_dir_status_win_path_copy_done
    movzbl (%rbx,%r10), %edx
    movb %dl, (%r13,%r10)
    incq %r10
    jmp .L_tl_fs_remove_dir_status_win_path_copy_loop
.L_tl_fs_remove_dir_status_win_path_copy_done:
    movb $0, (%r13,%r12)
    movq %r13, %rcx
    sub $32, %rsp
    call _rmdir
    add $32, %rsp
    testl %eax, %eax
    js .L_tl_fs_remove_dir_status_win_errno
    xorq %rax, %rax
    jmp .L_tl_fs_remove_dir_status_win_return
.L_tl_fs_remove_dir_status_win_errno:
    sub $32, %rsp
    call _errno
    add $32, %rsp
    movslq (%rax), %rax
    testq %rax, %rax
    jne .L_tl_fs_remove_dir_status_win_return
    movq $1, %rax
    jmp .L_tl_fs_remove_dir_status_win_return
.L_tl_fs_remove_dir_status_win_invalid:
    movq $22, %rax
.L_tl_fs_remove_dir_status_win_return:
    add $8, %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")

(define (compiler-backend-runtime-windows-fs-functions) : String
  (string-append
    (string-append
      (compiler-backend-runtime-windows-fs-mkdir-status-functions)
      (string-append
        (compiler-backend-runtime-windows-fs-remove-file-status-functions)
        (compiler-backend-runtime-windows-fs-remove-dir-status-functions)))
    "    .globl tl_fs_rename_status
tl_fs_rename_status:
.L_tl_fs_rename_status:
    movq $38, %rax
    ret

.L_tl_fs_read_dir_status:
    movq $38, %rax
    ret

.L_tl_fs_read_dir:
    push %rbp
    mov %rsp, %rbp
    sub $48, %rsp
    movq $1, %rcx
    call tl_alloc
    movq %rax, -8(%rbp)
    movq $16, %rcx
    call tl_alloc
    movq -8(%rbp), %r8
    movq %r8, 0(%rax)
    movq $0, 8(%rax)
    add $48, %rsp
    pop %rbp
    ret

.L_tl_fs_file_kind_status:
    movq $38, %rax
    ret

.L_tl_fs_file_size_status:
    movq $38, %rax
    ret

.L_tl_fs_file_size:
    xorq %rax, %rax
    ret

    .globl tl_fs_process_id
tl_fs_process_id:
.L_tl_fs_process_id:
    push %rbp
    mov %rsp, %rbp
    sub $32, %rsp
    call GetCurrentProcessId
    add $32, %rsp
    movl %eax, %eax
    pop %rbp
    ret

"))

(define (compiler-backend-runtime-windows-fs-current-dir-functions) : String
  "tl_fs_current_dir_status:
    movq $38, %rax
    ret

tl_fs_current_dir:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    sub $40, %rsp
    xorq %rcx, %rcx
    call tl_alloc
    movq %rax, %rbx
    movq $16, %rcx
    call tl_alloc
    movq %rbx, 0(%rax)
    movq $0, 8(%rax)
    add $40, %rsp
    pop %rbx
    pop %rbp
    ret

")

(define (compiler-backend-runtime-fs-current-dir-functions-for-target
  [target : CompilerBackendTarget]) : String
  (if (compiler-backend-target-windows? target)
    (compiler-backend-runtime-windows-fs-current-dir-functions)
    (compiler-backend-runtime-fs-current-dir-functions)))

(define (compiler-backend-runtime-fs-functions-for-target
  [target : CompilerBackendTarget]) : String
  (if (compiler-backend-target-windows? target)
    (compiler-backend-runtime-windows-fs-functions)
    (compiler-backend-runtime-fs-functions)))

(define (compiler-backend-runtime-windows-read-file-functions) : String
  "    .globl tl_read_file
tl_read_file:
    movq 8(%rcx), %rdx
    movq 0(%rcx), %rcx
    jmp .L_tl_read_file
.L_tl_read_file:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %rsi
    push %rdi
    sub $8, %rsp
    movq %rcx, %rbx
    movq %rdx, %r12
    cmpq $0, %r12
    jl .L_tl_read_file_error
    movq %r12, %rcx
    addq $1, %rcx
    js .L_tl_read_file_error
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rax, %r13
    movq %r12, %rcx
    movq %rbx, %rsi
    movq %r13, %rdi
    rep movsb
    movb $0, (%r13,%r12)
    movq %r13, %rcx
    movq $0x8000, %rdx
    xorq %r8, %r8
    sub $32, %rsp
    call _open
    add $32, %rsp
    testl %eax, %eax
    js .L_tl_read_file_error
    movslq %eax, %rbx
    movq %rbx, %rcx
    xorq %rdx, %rdx
    movq $2, %r8
    sub $32, %rsp
    call _lseeki64
    add $32, %rsp
    cmpq $0, %rax
    jl .L_tl_read_file_close_error
    movq %rax, %r12
    movq %rbx, %rcx
    xorq %rdx, %rdx
    xorq %r8, %r8
    sub $32, %rsp
    call _lseeki64
    add $32, %rsp
    cmpq $0, %rax
    jl .L_tl_read_file_close_error
    movq %r12, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rax, %r13
    movq %rbx, %rcx
    movq %r13, %rdx
    movq %r12, %r8
    sub $32, %rsp
    call _read
    add $32, %rsp
    movslq %eax, %rax
    cmpq %r12, %rax
    jne .L_tl_read_file_close_error
    movq %rbx, %rcx
    sub $32, %rsp
    call _close
    add $32, %rsp
    testl %eax, %eax
    js .L_tl_read_file_error
    movq $16, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
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
.L_tl_read_file_close_error:
    movq %rbx, %rcx
    sub $32, %rsp
    call _close
    add $32, %rsp
.L_tl_read_file_error:
    leaq .L_tl_read_file_error_msg(%rip), %rcx
    movq $.L_tl_read_file_error_msg_len, %rdx
    sub $32, %rsp
    call .L_tl_abort

")

(define (compiler-backend-runtime-windows-write-file-functions) : String
  "    .globl tl_write_file
tl_write_file:
    movq %rdx, %r10
    movq 0(%rcx), %r11
    movq 8(%rcx), %rdx
    movq 0(%r10), %r8
    movq 8(%r10), %r9
    movq %r11, %rcx
    jmp .L_tl_write_file
.L_tl_write_file:
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
    cmpq $0, %r12
    jl .L_tl_write_file_error
    cmpq $0, %r14
    jl .L_tl_write_file_error
    movq %r12, %rcx
    addq $1, %rcx
    js .L_tl_write_file_error
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rax, %r15
    movq %r12, %rcx
    movq %rbx, %rsi
    movq %r15, %rdi
    rep movsb
    movb $0, (%r15,%r12)
    movq %r15, %rcx
    movq $0x8301, %rdx
    movq $0x180, %r8
    sub $32, %rsp
    call _open
    add $32, %rsp
    testl %eax, %eax
    js .L_tl_write_file_error
    movslq %eax, %r15
    movq %r15, %rcx
    movq %r13, %rdx
    movq %r14, %r8
    sub $32, %rsp
    call _write
    add $32, %rsp
    movslq %eax, %rax
    cmpq %r14, %rax
    jne .L_tl_write_file_close_error
    movq %r15, %rcx
    sub $32, %rsp
    call _close
    add $32, %rsp
    testl %eax, %eax
    js .L_tl_write_file_error
    xorq %rax, %rax
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
.L_tl_write_file_close_error:
    movq %r15, %rcx
    sub $32, %rsp
    call _close
    add $32, %rsp
.L_tl_write_file_error:
    leaq .L_tl_write_file_error_msg(%rip), %rcx
    movq $.L_tl_write_file_error_msg_len, %rdx
    sub $32, %rsp
    call .L_tl_abort

")

(define (compiler-backend-runtime-windows-file-exists-functions) : String
  "    .globl tl_file_exists
tl_file_exists:
    movq 8(%rcx), %rdx
    movq 0(%rcx), %rcx
    jmp .L_tl_file_exists
.L_tl_file_exists:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %rsi
    push %rdi
    sub $8, %rsp
    movq %rcx, %rbx
    movq %rdx, %r12
    cmpq $0, %r12
    jl .L_tl_file_exists_error
    movq %r12, %rcx
    addq $1, %rcx
    js .L_tl_file_exists_error
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rax, %r13
    movq %r12, %rcx
    movq %rbx, %rsi
    movq %r13, %rdi
    rep movsb
    movb $0, (%r13,%r12)
    movq %r13, %rcx
    xorq %rdx, %rdx
    sub $32, %rsp
    call _access
    add $32, %rsp
    testl %eax, %eax
    jz .L_tl_file_exists_true
    xorq %rax, %rax
    jmp .L_tl_file_exists_return
.L_tl_file_exists_true:
    movq $1, %rax
.L_tl_file_exists_return:
    add $8, %rsp
    pop %rdi
    pop %rsi
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
.L_tl_file_exists_error:
    leaq .L_tl_file_exists_error_msg(%rip), %rcx
    movq $.L_tl_file_exists_error_msg_len, %rdx
    sub $32, %rsp
    call .L_tl_abort

")

(define (compiler-backend-runtime-windows-read-file-status-functions) : String
  "    .globl tl_read_file_status
tl_read_file_status:
    movq 8(%rcx), %rdx
    movq 0(%rcx), %rcx
    jmp .L_tl_read_file_status
.L_tl_read_file_status:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %rsi
    push %rdi
    sub $8, %rsp
    movq %rcx, %rbx
    movq %rdx, %r12
    cmpq $0, %r12
    jl .L_tl_read_file_status_win_invalid
    movq %r12, %rcx
    addq $1, %rcx
    js .L_tl_read_file_status_win_invalid
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rax, %r13
    movq %r12, %rcx
    movq %rbx, %rsi
    movq %r13, %rdi
    rep movsb
    movb $0, (%r13,%r12)
    movq %r13, %rcx
    movq $0x8000, %rdx
    xorq %r8, %r8
    sub $32, %rsp
    call _open
    add $32, %rsp
    testl %eax, %eax
    js .L_tl_read_file_status_win_errno
    movslq %eax, %rbx
    movq %rbx, %rcx
    leaq -32(%rbp), %rdx
    movq $1, %r8
    sub $32, %rsp
    call _read
    add $32, %rsp
    testl %eax, %eax
    js .L_tl_read_file_status_win_close_errno
    movq %rbx, %rcx
    sub $32, %rsp
    call _close
    add $32, %rsp
    testl %eax, %eax
    js .L_tl_read_file_status_win_errno
    xorq %rax, %rax
    jmp .L_tl_read_file_status_win_return
.L_tl_read_file_status_win_close_errno:
    sub $32, %rsp
    call _errno
    add $32, %rsp
    movslq (%rax), %r12
    testq %r12, %r12
    jne .L_tl_read_file_status_win_close_saved
    movq $1, %r12
.L_tl_read_file_status_win_close_saved:
    movq %rbx, %rcx
    sub $32, %rsp
    call _close
    add $32, %rsp
    movq %r12, %rax
    jmp .L_tl_read_file_status_win_return
.L_tl_read_file_status_win_errno:
    sub $32, %rsp
    call _errno
    add $32, %rsp
    movslq (%rax), %rax
    testq %rax, %rax
    jne .L_tl_read_file_status_win_return
    movq $1, %rax
    jmp .L_tl_read_file_status_win_return
.L_tl_read_file_status_win_invalid:
    movq $22, %rax
.L_tl_read_file_status_win_return:
    add $8, %rsp
    pop %rdi
    pop %rsi
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")

(define (compiler-backend-runtime-windows-write-file-status-functions) : String
  "    .globl tl_write_file_status
tl_write_file_status:
    movq %rdx, %r10
    movq 0(%rcx), %r11
    movq 8(%rcx), %rdx
    movq 0(%r10), %r8
    movq 8(%r10), %r9
    movq %r11, %rcx
    jmp .L_tl_write_file_status
.L_tl_write_file_status:
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
    cmpq $0, %r12
    jl .L_tl_write_file_status_win_invalid
    cmpq $0, %r14
    jl .L_tl_write_file_status_win_invalid
    movq %r12, %rcx
    addq $1, %rcx
    js .L_tl_write_file_status_win_invalid
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rax, %r15
    movq %r12, %rcx
    movq %rbx, %rsi
    movq %r15, %rdi
    rep movsb
    movb $0, (%r15,%r12)
    movq %r15, %rcx
    movq $0x8301, %rdx
    movq $0x180, %r8
    sub $32, %rsp
    call _open
    add $32, %rsp
    testl %eax, %eax
    js .L_tl_write_file_status_win_errno
    movslq %eax, %r15
    movq %r15, %rcx
    movq %r13, %rdx
    movq %r14, %r8
    sub $32, %rsp
    call _write
    add $32, %rsp
    testl %eax, %eax
    js .L_tl_write_file_status_win_close_errno
    movslq %eax, %rax
    cmpq %r14, %rax
    jne .L_tl_write_file_status_win_short_write
    movq %r15, %rcx
    sub $32, %rsp
    call _close
    add $32, %rsp
    testl %eax, %eax
    js .L_tl_write_file_status_win_errno
    xorq %rax, %rax
    jmp .L_tl_write_file_status_win_return
.L_tl_write_file_status_win_short_write:
    movq $5, %r12
    movq %r15, %rcx
    sub $32, %rsp
    call _close
    add $32, %rsp
    movq %r12, %rax
    jmp .L_tl_write_file_status_win_return
.L_tl_write_file_status_win_close_errno:
    sub $32, %rsp
    call _errno
    add $32, %rsp
    movslq (%rax), %r12
    testq %r12, %r12
    jne .L_tl_write_file_status_win_close_saved
    movq $1, %r12
.L_tl_write_file_status_win_close_saved:
    movq %r15, %rcx
    sub $32, %rsp
    call _close
    add $32, %rsp
    movq %r12, %rax
    jmp .L_tl_write_file_status_win_return
.L_tl_write_file_status_win_errno:
    sub $32, %rsp
    call _errno
    add $32, %rsp
    movslq (%rax), %rax
    testq %rax, %rax
    jne .L_tl_write_file_status_win_return
    movq $1, %rax
    jmp .L_tl_write_file_status_win_return
.L_tl_write_file_status_win_invalid:
    movq $22, %rax
.L_tl_write_file_status_win_return:
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

")

(define (compiler-backend-runtime-windows-append-file-status-functions) : String
  "    .globl tl_append_file_status
tl_append_file_status:
    movq %rdx, %r10
    movq 0(%rcx), %r11
    movq 8(%rcx), %rdx
    movq 0(%r10), %r8
    movq 8(%r10), %r9
    movq %r11, %rcx
    jmp .L_tl_append_file_status
.L_tl_append_file_status:
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
    cmpq $0, %r12
    jl .L_tl_append_file_status_win_invalid
    cmpq $0, %r14
    jl .L_tl_append_file_status_win_invalid
    movq %r12, %rcx
    addq $1, %rcx
    js .L_tl_append_file_status_win_invalid
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rax, %r15
    movq %r12, %rcx
    movq %rbx, %rsi
    movq %r15, %rdi
    rep movsb
    movb $0, (%r15,%r12)
    movq %r15, %rcx
    movq $0x8109, %rdx
    movq $0x180, %r8
    sub $32, %rsp
    call _open
    add $32, %rsp
    testl %eax, %eax
    js .L_tl_append_file_status_win_errno
    movslq %eax, %r15
    movq %r15, %rcx
    movq %r13, %rdx
    movq %r14, %r8
    sub $32, %rsp
    call _write
    add $32, %rsp
    testl %eax, %eax
    js .L_tl_append_file_status_win_close_errno
    movslq %eax, %rax
    cmpq %r14, %rax
    jne .L_tl_append_file_status_win_short_write
    movq %r15, %rcx
    sub $32, %rsp
    call _close
    add $32, %rsp
    testl %eax, %eax
    js .L_tl_append_file_status_win_errno
    xorq %rax, %rax
    jmp .L_tl_append_file_status_win_return
.L_tl_append_file_status_win_short_write:
    movq $5, %r12
    movq %r15, %rcx
    sub $32, %rsp
    call _close
    add $32, %rsp
    movq %r12, %rax
    jmp .L_tl_append_file_status_win_return
.L_tl_append_file_status_win_close_errno:
    sub $32, %rsp
    call _errno
    add $32, %rsp
    movslq (%rax), %r12
    testq %r12, %r12
    jne .L_tl_append_file_status_win_close_saved
    movq $1, %r12
.L_tl_append_file_status_win_close_saved:
    movq %r15, %rcx
    sub $32, %rsp
    call _close
    add $32, %rsp
    movq %r12, %rax
    jmp .L_tl_append_file_status_win_return
.L_tl_append_file_status_win_errno:
    sub $32, %rsp
    call _errno
    add $32, %rsp
    movslq (%rax), %rax
    testq %rax, %rax
    jne .L_tl_append_file_status_win_return
    movq $1, %rax
    jmp .L_tl_append_file_status_win_return
.L_tl_append_file_status_win_invalid:
    movq $22, %rax
.L_tl_append_file_status_win_return:
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

")

(define (compiler-backend-runtime-windows-file-exists-status-functions) : String
  "    .globl tl_file_exists_status
tl_file_exists_status:
    movq 8(%rcx), %rdx
    movq 0(%rcx), %rcx
    jmp .L_tl_file_exists_status
.L_tl_file_exists_status:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %rsi
    push %rdi
    sub $8, %rsp
    movq %rcx, %rbx
    movq %rdx, %r12
    cmpq $0, %r12
    jl .L_tl_file_exists_status_win_invalid
    movq %r12, %rcx
    addq $1, %rcx
    js .L_tl_file_exists_status_win_invalid
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rax, %r13
    movq %r12, %rcx
    movq %rbx, %rsi
    movq %r13, %rdi
    rep movsb
    movb $0, (%r13,%r12)
    movq %r13, %rcx
    xorq %rdx, %rdx
    sub $32, %rsp
    call _access
    add $32, %rsp
    testl %eax, %eax
    jz .L_tl_file_exists_status_win_success
    sub $32, %rsp
    call _errno
    add $32, %rsp
    movslq (%rax), %rax
    testq %rax, %rax
    jne .L_tl_file_exists_status_win_return
    movq $1, %rax
    jmp .L_tl_file_exists_status_win_return
.L_tl_file_exists_status_win_success:
    xorq %rax, %rax
    jmp .L_tl_file_exists_status_win_return
.L_tl_file_exists_status_win_invalid:
    movq $22, %rax
.L_tl_file_exists_status_win_return:
    add $8, %rsp
    pop %rdi
    pop %rsi
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")

(define (compiler-backend-runtime-windows-fixed-abort-functions
  [symbol : String]
  [msg-label : String]
  [len-label : String]
  [status : i64]) : String
  (backend-cat5
    "    .globl "
    symbol
    "\n"
    (backend-cat4
      symbol
      ":\n    push %rbp\n    mov %rsp, %rbp\n    movq $2, %rcx\n    leaq "
      msg-label
      "(%rip), %rdx\n")
    (backend-cat5
      "    movq $"
      len-label
      ", %r8\n    sub $32, %rsp\n    call _write\n    add $32, %rsp\n    movq $"
      (int->string status)
      ", %rcx\n    sub $32, %rsp\n    call exit\n\n")))

(define (compiler-backend-runtime-windows-oob-functions) : String
  (compiler-backend-runtime-windows-fixed-abort-functions
    "tl_oob_abort"
    ".L_tl_oob_msg"
    ".L_tl_oob_msg_len"
    134))

(define (compiler-backend-runtime-windows-div-functions) : String
  (compiler-backend-runtime-windows-fixed-abort-functions
    "tl_div_abort"
    ".L_tl_div_msg"
    ".L_tl_div_msg_len"
    135))

(define (compiler-backend-runtime-windows-shift-functions) : String
  (compiler-backend-runtime-windows-fixed-abort-functions
    "tl_shift_abort"
    ".L_tl_shift_msg"
    ".L_tl_shift_msg_len"
    129))

(define (compiler-backend-runtime-windows-abort-functions) : String
  "    .globl tl_abort_string
tl_abort_string:
    movq 8(%rcx), %rdx
    movq 0(%rcx), %rcx
    jmp .L_tl_abort
.L_tl_abort:
    push %rbp
    mov %rsp, %rbp
    movq %rdx, %r8
    movq %rcx, %rdx
    movq $2, %rcx
    sub $32, %rsp
    call _write
    add $32, %rsp
    movq $134, %rcx
    sub $32, %rsp
    call exit

")

(define (compiler-backend-runtime-windows-print-err-functions) : String
  "    .globl tl_print_error
tl_print_error:
    push %rbp
    mov %rsp, %rbp
    movq 8(%rcx), %r8
    movq 0(%rcx), %rdx
    movq $2, %rcx
    sub $32, %rsp
    call _write
    add $32, %rsp
    mov %rbp, %rsp
    pop %rbp
    ret

    .globl tl_print_err
tl_print_err:
    push %rbp
    mov %rsp, %rbp
    movq %rdx, %r8
    movq %rcx, %rdx
    movq $2, %rcx
    sub $32, %rsp
    call _write
    add $32, %rsp
    mov %rbp, %rsp
    pop %rbp
    ret

")

(define (compiler-backend-runtime-windows-print-str-functions) : String
  "    .globl tl_print_string
tl_print_string:
    push %rbp
    mov %rsp, %rbp
    movq 8(%rcx), %r8
    movq 0(%rcx), %rdx
    movq $1, %rcx
    sub $32, %rsp
    call _write
    add $32, %rsp
    mov %rbp, %rsp
    pop %rbp
    ret

    .globl tl_print_str
tl_print_str:
    push %rbp
    mov %rsp, %rbp
    movq %rdx, %r8
    movq %rcx, %rdx
    movq $1, %rcx
    sub $32, %rsp
    call _write
    add $32, %rsp
    mov %rbp, %rsp
    pop %rbp
    ret

")

(define (compiler-backend-runtime-windows-print-char-functions) : String
  "    .globl tl_print_char
tl_print_char:
    push %rbp
    mov %rsp, %rbp
    sub $40, %rsp
    movb %cl, 32(%rsp)
    movq $1, %rcx
    leaq 32(%rsp), %rdx
    movq $1, %r8
    call _write
    add $40, %rsp
    mov %rbp, %rsp
    pop %rbp
    ret

")

(define (compiler-backend-runtime-windows-print-f64-functions) : String
  "    .globl tl_print_f64
tl_print_f64:
    push %rbp
    mov %rsp, %rbp
    sub $160, %rsp
    leaq -128(%rbp), %rcx
    movq $128, %rdx
    leaq .L_tl_print_f64_fmt(%rip), %r8
    movapd %xmm0, %xmm3
    movq %xmm0, %r9
    call _snprintf
    movslq %eax, %rax
    cmpq $0, %rax
    jl .L_tl_print_f64_done
    cmpq $128, %rax
    jl .L_tl_print_f64_len_ready
    movq $127, %rax
.L_tl_print_f64_len_ready:
    movq %rax, %r8
    movq $1, %rcx
    leaq -128(%rbp), %rdx
    call _write
.L_tl_print_f64_done:
    add $160, %rsp
    mov %rbp, %rsp
    pop %rbp
    ret

")

(define (compiler-backend-runtime-windows-arg-count-functions) : String
  "    .globl tl_arg_count
tl_arg_count:
.L_tl_arg_count:
    movq .L_tl_argc(%rip), %rax
    ret

")

(define (compiler-backend-runtime-windows-arg-functions) : String
  "    .globl tl_arg
tl_arg:
.L_tl_arg:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $8, %rsp
    movq %rcx, %rbx
    cmpq $0, %rbx
    jl .L_tl_arg_oob
    movq .L_tl_argc(%rip), %rax
    cmpq %rax, %rbx
    jge .L_tl_arg_oob
    movq .L_tl_argv(%rip), %rax
    movq (%rax,%rbx,8), %rbx
    xorq %r12, %r12
.L_tl_arg_len_loop:
    cmpb $0, (%rbx,%r12)
    je .L_tl_arg_len_done
    incq %r12
    jmp .L_tl_arg_len_loop
.L_tl_arg_len_done:
    movq %r12, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rax, %r13
    xorq %rcx, %rcx
.L_tl_arg_copy_loop:
    cmpq %r12, %rcx
    jge .L_tl_arg_copy_done
    movzbl (%rbx,%rcx), %edx
    movb %dl, (%r13,%rcx)
    incq %rcx
    jmp .L_tl_arg_copy_loop
.L_tl_arg_copy_done:
    movq $16, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %r13, 0(%rax)
    movq %r12, 8(%rax)
    add $8, %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
.L_tl_arg_oob:
    leaq .L_tl_arg_oob_msg(%rip), %rcx
    movq $.L_tl_arg_oob_msg_len, %rdx
    sub $32, %rsp
    call .L_tl_abort

")

(define (compiler-backend-runtime-string-eq-functions) : String
  "    .globl tl_string_eq
tl_string_eq:
    cmpq %rcx, %rsi
    jne .L_tl_string_eq_false
    movq %rsi, %r8
    shrq $3, %r8
    jz .L_tl_string_eq_tail
.L_tl_string_eq_word_loop:
    movq (%rdi), %rax
    cmpq (%rdx), %rax
    jne .L_tl_string_eq_false
    addq $8, %rdi
    addq $8, %rdx
    decq %r8
    jne .L_tl_string_eq_word_loop
.L_tl_string_eq_tail:
    andq $7, %rsi
    jz .L_tl_string_eq_true
.L_tl_string_eq_tail_loop:
    movzbl (%rdi), %eax
    movzbl (%rdx), %r8d
    cmpb %r8b, %al
    jne .L_tl_string_eq_false
    incq %rdi
    incq %rdx
    decq %rsi
    jne .L_tl_string_eq_tail_loop
.L_tl_string_eq_true:
    movq $1, %rax
    ret
.L_tl_string_eq_false:
    xorq %rax, %rax
    ret

")

(define (compiler-backend-runtime-string-to-int-functions) : String
  "    .globl tl_string_to_int
tl_string_to_int:
    xorq %rax, %rax
    xorq %r8, %r8
    testq %rsi, %rsi
    jz .L_tl_string_to_int_done
    movzbl (%rdi), %ecx
    cmpb $45, %cl
    jne .L_tl_string_to_int_loop
    movq $1, %r8
    incq %rdi
    decq %rsi
.L_tl_string_to_int_loop:
    testq %rsi, %rsi
    jz .L_tl_string_to_int_apply_sign
    imulq $10, %rax, %rax
    movzbl (%rdi), %ecx
    subq $48, %rcx
    addq %rcx, %rax
    incq %rdi
    decq %rsi
    jmp .L_tl_string_to_int_loop
.L_tl_string_to_int_apply_sign:
    testq %r8, %r8
    jz .L_tl_string_to_int_done
    negq %rax
.L_tl_string_to_int_done:
    ret

")

(define (compiler-backend-runtime-windows-string-eq-functions) : String
  "    .globl tl_string_eq
tl_string_eq:
    cmpq %r9, %rdx
    jne .L_tl_string_eq_false
    movq %rdx, %r10
    shrq $3, %r10
    jz .L_tl_string_eq_tail
.L_tl_string_eq_word_loop:
    movq (%rcx), %rax
    cmpq (%r8), %rax
    jne .L_tl_string_eq_false
    addq $8, %rcx
    addq $8, %r8
    decq %r10
    jne .L_tl_string_eq_word_loop
.L_tl_string_eq_tail:
    andq $7, %rdx
    jz .L_tl_string_eq_true
.L_tl_string_eq_tail_loop:
    movzbl (%rcx), %eax
    movzbl (%r8), %r10d
    cmpb %r10b, %al
    jne .L_tl_string_eq_false
    incq %rcx
    incq %r8
    decq %rdx
    jne .L_tl_string_eq_tail_loop
.L_tl_string_eq_true:
    movq $1, %rax
    ret
.L_tl_string_eq_false:
    xorq %rax, %rax
    ret

")

(define (compiler-backend-runtime-windows-string-to-int-functions) : String
  "    .globl tl_string_to_int
tl_string_to_int:
    movq %rcx, %r10
    xorq %rax, %rax
    xorq %r8, %r8
    testq %rdx, %rdx
    jz .L_tl_string_to_int_done
    movzbl (%r10), %ecx
    cmpb $45, %cl
    jne .L_tl_string_to_int_loop
    movq $1, %r8
    incq %r10
    decq %rdx
.L_tl_string_to_int_loop:
    testq %rdx, %rdx
    jz .L_tl_string_to_int_apply_sign
    imulq $10, %rax, %rax
    movzbl (%r10), %ecx
    subq $48, %rcx
    addq %rcx, %rax
    incq %r10
    decq %rdx
    jmp .L_tl_string_to_int_loop
.L_tl_string_to_int_apply_sign:
    testq %r8, %r8
    jz .L_tl_string_to_int_done
    negq %rax
.L_tl_string_to_int_done:
    ret

")

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
    movq $16, %rdi
    call tl_alloc
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
    movq $16, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
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
    movq $16, %rdi
    call tl_alloc
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
    movq $16, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
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
    movq $16, %rdi
    call tl_alloc
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
    movq $16, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
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

")

(define (compiler-backend-runtime-windows-process-output-functions) : String
  "tl_process_start:
    push %rbp
    mov %rsp, %rbp
    movq $3, %rcx
    leaq .L_tl_process_async_unsupported_msg(%rip), %rdx
    movq $.L_tl_process_async_unsupported_msg_len, %r8
    sub $32, %rsp
    call .L_tl_process_error_result
    add $32, %rsp
    pop %rbp
    ret

tl_process_wait:
    push %rbp
    mov %rsp, %rbp
    movq $3, %rcx
    leaq .L_tl_process_async_unsupported_msg(%rip), %rdx
    movq $.L_tl_process_async_unsupported_msg_len, %r8
    sub $32, %rsp
    call .L_tl_process_error_result
    add $32, %rsp
    pop %rbp
    ret

tl_process_output:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    sub $168, %rsp
    movq %rcx, %rbx
    movq $0, -48(%rbp)
    movq $0, -56(%rbp)
    movq $0, -64(%rbp)
    movq $0, -72(%rbp)
    movq $-1, -80(%rbp)
    movq $-1, -88(%rbp)
    movq 0(%rbx), %rcx
    sub $32, %rsp
    call .L_tl_process_copy_c_string
    add $32, %rsp
    movq %rax, %r12
    movq $1, %r13
    movq 8(%rbx), %r14
.L_tl_process_count_argv:
    testq %r14, %r14
    jz .L_tl_process_count_argv_done
    cmpq $1, 0(%r14)
    jne .L_tl_process_count_argv_done
    incq %r13
    movq 16(%r14), %r14
    jmp .L_tl_process_count_argv
.L_tl_process_count_argv_done:
    movq %r13, %rcx
    incq %rcx
    shlq $3, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rax, %r14
    movq 0(%rbx), %rcx
    sub $32, %rsp
    call .L_tl_process_copy_c_string_quoted
    add $32, %rsp
    movq %rax, 0(%r14)
    movq 8(%rbx), %r13
    movq $1, %r15
.L_tl_process_fill_argv:
    testq %r13, %r13
    jz .L_tl_process_fill_argv_done
    cmpq $1, 0(%r13)
    jne .L_tl_process_fill_argv_done
    movq 8(%r13), %rcx
    sub $32, %rsp
    call .L_tl_process_copy_c_string_quoted
    add $32, %rsp
    movq %rax, (%r14,%r15,8)
    incq %r15
    movq 16(%r13), %r13
    jmp .L_tl_process_fill_argv
.L_tl_process_fill_argv_done:
    movq $0, (%r14,%r15,8)
    movq %r14, -96(%rbp)
    movq 24(%rbx), %rcx
    sub $32, %rsp
    call .L_tl_process_win_envp_from_overrides
    add $32, %rsp
    movq %rax, -104(%rbp)
    movq -96(%rbp), %r14
    sub $32, %rsp
    call tmpfile
    add $32, %rsp
    testq %rax, %rax
    jz .L_tl_process_output_wait_failed_close
    movq %rax, -48(%rbp)
    movq %rax, %rcx
    sub $32, %rsp
    call _fileno
    add $32, %rsp
    testl %eax, %eax
    js .L_tl_process_output_wait_failed_close
    movslq %eax, %rax
    movq %rax, -56(%rbp)
    sub $32, %rsp
    call tmpfile
    add $32, %rsp
    testq %rax, %rax
    jz .L_tl_process_output_wait_failed_close
    movq %rax, -64(%rbp)
    movq %rax, %rcx
    sub $32, %rsp
    call _fileno
    add $32, %rsp
    testl %eax, %eax
    js .L_tl_process_output_wait_failed_close
    movslq %eax, %rax
    movq %rax, -72(%rbp)
    movq -56(%rbp), %rcx
    sub $32, %rsp
    call _get_osfhandle
    add $32, %rsp
    movq %rax, -112(%rbp)
    movq -72(%rbp), %rcx
    sub $32, %rsp
    call _get_osfhandle
    add $32, %rsp
    movq %rax, -120(%rbp)
    movq -112(%rbp), %rcx
    movq $1, %rdx
    movq $1, %r8
    sub $32, %rsp
    call SetHandleInformation
    add $32, %rsp
    movq -120(%rbp), %rcx
    movq $1, %rdx
    movq $1, %r8
    sub $32, %rsp
    call SetHandleInformation
    add $32, %rsp
    movq -104(%rbp), %rcx
    sub $32, %rsp
    call .L_tl_process_envp_to_block
    add $32, %rsp
    movq %rax, -128(%rbp)
    movq -96(%rbp), %rcx
    sub $32, %rsp
    call .L_tl_process_argv_to_cmdline
    add $32, %rsp
    movq %rax, -136(%rbp)
    movq %r12, %rcx
    movq -136(%rbp), %rdx
    movq -128(%rbp), %r8
    movq -112(%rbp), %r9
    movq -120(%rbp), %r10
    sub $32, %rsp
    call .L_tl_process_create_and_wait
    add $32, %rsp
    movq %rax, %r15
    cmpq $0, %r15
    jl .L_tl_process_output_spawn_failed_close
    movq -56(%rbp), %rcx
    sub $32, %rsp
    call .L_tl_process_read_fd_to_string
    add $32, %rsp
    testq %rax, %rax
    jz .L_tl_process_output_wait_failed_close
    movq %rax, -96(%rbp)
    movq -72(%rbp), %rcx
    sub $32, %rsp
    call .L_tl_process_read_fd_to_string
    add $32, %rsp
    testq %rax, %rax
    jz .L_tl_process_output_wait_failed_close
    movq %rax, -104(%rbp)
    call .L_tl_process_close_temp_files
    movq $24, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %r15, 0(%rax)
    movq -96(%rbp), %rdx
    movq %rdx, 8(%rax)
    movq -104(%rbp), %rdx
    movq %rdx, 16(%rax)
    movq %rax, %r12
    movq $16, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq $0, 0(%rax)
    movq %r12, 8(%rax)
    jmp .L_tl_process_output_epilogue
.L_tl_process_output_spawn_failed_close:
    call .L_tl_process_close_temp_files
    movq $1, %rcx
    leaq .L_tl_process_spawn_msg(%rip), %rdx
    movq $.L_tl_process_spawn_msg_len, %r8
    sub $32, %rsp
    call .L_tl_process_error_result
    add $32, %rsp
    jmp .L_tl_process_output_epilogue
.L_tl_process_output_wait_failed_close:
    call .L_tl_process_close_temp_files
    movq $2, %rcx
    leaq .L_tl_process_wait_msg(%rip), %rdx
    movq $.L_tl_process_wait_msg_len, %r8
    sub $32, %rsp
    call .L_tl_process_error_result
    add $32, %rsp
    jmp .L_tl_process_output_epilogue
.L_tl_process_output_epilogue:
    add $168, %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

.L_tl_process_envp_to_block:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    sub $32, %rsp
    testq %rcx, %rcx
    jz .L_tl_etb_null
    movq %rcx, %rbx
    movq $1, %r12
    movq %rbx, %r13
.L_tl_etb_size_loop:
    movq (%r13), %r8
    testq %r8, %r8
    jz .L_tl_etb_size_done
    xorq %r9, %r9
.L_tl_etb_size_strlen:
    cmpb $0, (%r8,%r9)
    je .L_tl_etb_size_strlen_done
    incq %r9
    jmp .L_tl_etb_size_strlen
.L_tl_etb_size_strlen_done:
    incq %r9
    addq %r9, %r12
    addq $8, %r13
    jmp .L_tl_etb_size_loop
.L_tl_etb_size_done:
    movq %r12, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rax, %r14
    movq %rbx, %r13
    xorq %r12, %r12
.L_tl_etb_copy_loop:
    movq (%r13), %r8
    testq %r8, %r8
    jz .L_tl_etb_copy_done
    xorq %r9, %r9
.L_tl_etb_copy_bytes:
    movzbl (%r8,%r9), %eax
    movb %al, (%r14,%r12)
    incq %r12
    testb %al, %al
    jz .L_tl_etb_copy_entry_done
    incq %r9
    jmp .L_tl_etb_copy_bytes
.L_tl_etb_copy_entry_done:
    addq $8, %r13
    jmp .L_tl_etb_copy_loop
.L_tl_etb_copy_done:
    movb $0, (%r14,%r12)
    movq %r14, %rax
    jmp .L_tl_etb_ret
.L_tl_etb_null:
    xorq %rax, %rax
.L_tl_etb_ret:
    add $32, %rsp
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

.L_tl_process_argv_to_cmdline:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    sub $32, %rsp
    movq %rcx, %rbx
    movq $1, %r12
    movq %rbx, %r13
.L_tl_atc_size_loop:
    movq (%r13), %r8
    testq %r8, %r8
    jz .L_tl_atc_size_done
    xorq %r9, %r9
.L_tl_atc_size_strlen:
    cmpb $0, (%r8,%r9)
    je .L_tl_atc_size_strlen_done
    incq %r9
    jmp .L_tl_atc_size_strlen
.L_tl_atc_size_strlen_done:
    incq %r9
    addq %r9, %r12
    addq $8, %r13
    jmp .L_tl_atc_size_loop
.L_tl_atc_size_done:
    movq %r12, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rax, %r14
    movq %rbx, %r13
    xorq %r12, %r12
.L_tl_atc_copy_loop:
    movq (%r13), %r8
    testq %r8, %r8
    jz .L_tl_atc_copy_done
    testq %r12, %r12
    jz .L_tl_atc_copy_nospace
    movb $0x20, (%r14,%r12)
    incq %r12
.L_tl_atc_copy_nospace:
    xorq %r9, %r9
.L_tl_atc_copy_bytes:
    movzbl (%r8,%r9), %eax
    testb %al, %al
    jz .L_tl_atc_copy_entry_done
    movb %al, (%r14,%r12)
    incq %r12
    incq %r9
    jmp .L_tl_atc_copy_bytes
.L_tl_atc_copy_entry_done:
    addq $8, %r13
    jmp .L_tl_atc_copy_loop
.L_tl_atc_copy_done:
    movb $0, (%r14,%r12)
    movq %r14, %rax
    add $32, %rsp
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

.L_tl_process_create_and_wait:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    sub $264, %rsp
    movq %rcx, %rbx
    movq %rdx, %r12
    movq %r8, %r13
    movq %r9, %r14
    movq %r10, %r15
    leaq -160(%rbp), %rax
    movq $13, %rcx
.L_tl_cpw_zero:
    movq $0, (%rax)
    addq $8, %rax
    decq %rcx
    jnz .L_tl_cpw_zero
    movl $104, -160(%rbp)
    movl $256, -100(%rbp)
    movq $-10, %rcx
    sub $32, %rsp
    call GetStdHandle
    add $32, %rsp
    movq %rax, -80(%rbp)
    movq %r14, -72(%rbp)
    movq %r15, -64(%rbp)
    movq $0, -184(%rbp)
    movq $0, -176(%rbp)
    movq $0, -168(%rbp)
    movq %rbx, %rcx
    movq %r12, %rdx
    xorq %r8, %r8
    xorq %r9, %r9
    movq $1, 32(%rsp)
    movq $0, 40(%rsp)
    movq %r13, 48(%rsp)
    movq $0, 56(%rsp)
    leaq -160(%rbp), %rax
    movq %rax, 64(%rsp)
    leaq -184(%rbp), %rax
    movq %rax, 72(%rsp)
    call CreateProcessA
    testl %eax, %eax
    jz .L_tl_cpw_fail
    movq -184(%rbp), %rcx
    movq $-1, %rdx
    sub $32, %rsp
    call WaitForSingleObject
    add $32, %rsp
    movq $0, -192(%rbp)
    movq -184(%rbp), %rcx
    leaq -192(%rbp), %rdx
    sub $32, %rsp
    call GetExitCodeProcess
    add $32, %rsp
    movq -184(%rbp), %rcx
    sub $32, %rsp
    call CloseHandle
    add $32, %rsp
    movq -176(%rbp), %rcx
    sub $32, %rsp
    call CloseHandle
    add $32, %rsp
    movl -192(%rbp), %eax
    movslq %eax, %rax
    jmp .L_tl_cpw_done
.L_tl_cpw_fail:
    movq $-1, %rax
.L_tl_cpw_done:
    add $264, %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

.L_tl_process_copy_c_string:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $8, %rsp
    movq 0(%rcx), %rbx
    movq 8(%rcx), %r12
    movq %r12, %rcx
    incq %rcx
    call tl_alloc
    movq %rax, %r13
    xorq %r10, %r10
.L_tl_process_copy_c_string_loop:
    cmpq %r12, %r10
    jge .L_tl_process_copy_c_string_done
    movzbl (%rbx,%r10), %edx
    movb %dl, (%r13,%r10)
    incq %r10
    jmp .L_tl_process_copy_c_string_loop
.L_tl_process_copy_c_string_done:
    movb $0, (%r13,%r12)
    movq %r13, %rax
    add $8, %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

.L_tl_process_copy_c_string_quoted:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    sub $8, %rsp
    movq 0(%rcx), %rbx
    movq 8(%rcx), %r12
    xorq %r14, %r14
    xorq %r10, %r10
.L_tl_process_quote_scan:
    cmpq %r12, %r10
    jge .L_tl_process_quote_scan_done
    cmpb $0x20, (%rbx,%r10)
    jne .L_tl_process_quote_scan_next
    movq $1, %r14
    jmp .L_tl_process_quote_scan_done
.L_tl_process_quote_scan_next:
    incq %r10
    jmp .L_tl_process_quote_scan
.L_tl_process_quote_scan_done:
    movq %r12, %rcx
    incq %rcx
    testq %r14, %r14
    jz .L_tl_process_quote_alloc
    addq $2, %rcx
.L_tl_process_quote_alloc:
    call tl_alloc
    movq %rax, %r13
    xorq %r10, %r10
    testq %r14, %r14
    jz .L_tl_process_quote_body
    movb $0x22, (%r13)
    movq $1, %r10
.L_tl_process_quote_body:
    xorq %r11, %r11
.L_tl_process_quote_body_loop:
    cmpq %r12, %r11
    jge .L_tl_process_quote_body_done
    movzbl (%rbx,%r11), %edx
    movb %dl, (%r13,%r10)
    incq %r10
    incq %r11
    jmp .L_tl_process_quote_body_loop
.L_tl_process_quote_body_done:
    testq %r14, %r14
    jz .L_tl_process_quote_terminate
    movb $0x22, (%r13,%r10)
    incq %r10
.L_tl_process_quote_terminate:
    movb $0, (%r13,%r10)
    movq %r13, %rax
    add $8, %rsp
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

.L_tl_process_win_env_entry_matches:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    sub $8, %rsp
    movq %rcx, %rbx
    movq %rdx, %r12
.L_tl_process_win_env_match_loop:
    testq %r12, %r12
    jz .L_tl_process_win_env_match_false
    cmpq $1, 0(%r12)
    jne .L_tl_process_win_env_match_false
    movq 8(%r12), %rax
    movq 0(%rax), %r13
    movq 8(%rax), %r14
    xorq %r15, %r15
.L_tl_process_win_env_match_char:
    cmpq %r14, %r15
    jge .L_tl_process_win_env_match_check_eq
    movzbl (%r13,%r15), %eax
    movzbl (%rbx,%r15), %ecx
    cmpb %cl, %al
    jne .L_tl_process_win_env_match_next
    incq %r15
    jmp .L_tl_process_win_env_match_char
.L_tl_process_win_env_match_check_eq:
    movzbl (%rbx,%r14), %eax
    cmpb $61, %al
    jne .L_tl_process_win_env_match_next
    movq $1, %rax
    jmp .L_tl_process_win_env_match_return
.L_tl_process_win_env_match_next:
    movq 24(%r12), %r12
    jmp .L_tl_process_win_env_match_loop
.L_tl_process_win_env_match_false:
    xorq %rax, %rax
.L_tl_process_win_env_match_return:
    add $8, %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

.L_tl_process_win_env_cstring:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    sub $8, %rsp
    movq 0(%rcx), %r12
    movq 8(%rcx), %rbx
    movq 0(%rdx), %r14
    movq 8(%rdx), %r13
    movq %rbx, %rcx
    addq %r13, %rcx
    addq $2, %rcx
    call tl_alloc
    movq %rax, %r15
    xorq %rcx, %rcx
.L_tl_process_win_env_cs_name:
    cmpq %rbx, %rcx
    jge .L_tl_process_win_env_cs_name_done
    movzbl (%r12,%rcx), %eax
    movb %al, (%r15,%rcx)
    incq %rcx
    jmp .L_tl_process_win_env_cs_name
.L_tl_process_win_env_cs_name_done:
    movb $61, (%r15,%rbx)
    xorq %rcx, %rcx
.L_tl_process_win_env_cs_value:
    cmpq %r13, %rcx
    jge .L_tl_process_win_env_cs_value_done
    movzbl (%r14,%rcx), %eax
    leaq 1(%rbx,%rcx), %rdx
    movb %al, (%r15,%rdx)
    incq %rcx
    jmp .L_tl_process_win_env_cs_value
.L_tl_process_win_env_cs_value_done:
    leaq 1(%rbx,%r13), %rdx
    movb $0, (%r15,%rdx)
    movq %r15, %rax
    add $8, %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

.L_tl_process_win_envp_from_overrides:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    sub $40, %rsp
    movq %rcx, %r12
    testq %r12, %r12
    jz .L_tl_process_win_envp_null
    cmpq $1, 0(%r12)
    jne .L_tl_process_win_envp_null
    call __p__environ
    movq (%rax), %rbx
    xorq %r13, %r13
    testq %rbx, %rbx
    jz .L_tl_process_win_envp_count_overrides
.L_tl_process_win_envp_count_inh:
    movq (%rbx,%r13,8), %rax
    testq %rax, %rax
    jz .L_tl_process_win_envp_count_overrides
    incq %r13
    jmp .L_tl_process_win_envp_count_inh
.L_tl_process_win_envp_count_overrides:
    xorq %r14, %r14
    movq %r12, %r15
.L_tl_process_win_envp_count_ov:
    testq %r15, %r15
    jz .L_tl_process_win_envp_alloc
    cmpq $1, 0(%r15)
    jne .L_tl_process_win_envp_alloc
    incq %r14
    movq 24(%r15), %r15
    jmp .L_tl_process_win_envp_count_ov
.L_tl_process_win_envp_alloc:
    movq %r13, %rcx
    addq %r14, %rcx
    incq %rcx
    shlq $3, %rcx
    call tl_alloc
    movq %rax, %r15
    xorq %r14, %r14
    testq %rbx, %rbx
    jz .L_tl_process_win_envp_copy_ov_start
.L_tl_process_win_envp_copy_inh:
    movq (%rbx), %rcx
    testq %rcx, %rcx
    jz .L_tl_process_win_envp_copy_ov_start
    movq %r12, %rdx
    call .L_tl_process_win_env_entry_matches
    testq %rax, %rax
    jne .L_tl_process_win_envp_skip_inh
    movq (%rbx), %rax
    movq %rax, (%r15,%r14,8)
    incq %r14
.L_tl_process_win_envp_skip_inh:
    addq $8, %rbx
    jmp .L_tl_process_win_envp_copy_inh
.L_tl_process_win_envp_copy_ov_start:
    movq %r12, %rbx
.L_tl_process_win_envp_copy_ov:
    testq %rbx, %rbx
    jz .L_tl_process_win_envp_done
    cmpq $1, 0(%rbx)
    jne .L_tl_process_win_envp_done
    movq 8(%rbx), %rcx
    movq 16(%rbx), %rdx
    call .L_tl_process_win_env_cstring
    movq %rax, (%r15,%r14,8)
    incq %r14
    movq 24(%rbx), %rbx
    jmp .L_tl_process_win_envp_copy_ov
.L_tl_process_win_envp_done:
    movq $0, (%r15,%r14,8)
    movq %r15, %rax
    jmp .L_tl_process_win_envp_return
.L_tl_process_win_envp_null:
    xorq %rax, %rax
.L_tl_process_win_envp_return:
    add $40, %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

.L_tl_process_read_fd_to_string:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    sub $32, %rsp
    movq %rcx, %rbx
    movq %rbx, %rcx
    xorq %rdx, %rdx
    movq $2, %r8
    call _lseeki64
    cmpq $0, %rax
    jl .L_tl_process_read_fd_to_string_error
    movq %rax, %r12
    movq %rbx, %rcx
    xorq %rdx, %rdx
    xorq %r8, %r8
    call _lseeki64
    cmpq $0, %rax
    jl .L_tl_process_read_fd_to_string_error
    movq %r12, %rcx
    call tl_alloc
    movq %rax, %r13
    xorq %r14, %r14
.L_tl_process_read_fd_to_string_loop:
    cmpq %r12, %r14
    jge .L_tl_process_read_fd_to_string_fat
    movq %rbx, %rcx
    leaq (%r13,%r14), %rdx
    movq %r12, %r8
    subq %r14, %r8
    call _read
    testl %eax, %eax
    js .L_tl_process_read_fd_to_string_error
    jz .L_tl_process_read_fd_to_string_fat
    movslq %eax, %rax
    addq %rax, %r14
    jmp .L_tl_process_read_fd_to_string_loop
.L_tl_process_read_fd_to_string_fat:
    movq $16, %rcx
    call tl_alloc
    movq %r13, 0(%rax)
    movq %r14, 8(%rax)
    jmp .L_tl_process_read_fd_to_string_done
.L_tl_process_read_fd_to_string_error:
    xorq %rax, %rax
.L_tl_process_read_fd_to_string_done:
    add $32, %rsp
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

.L_tl_process_error_result:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    sub $8, %rsp
    movq %rcx, %rbx
    movq %rdx, %r12
    movq %r8, %r13
    movq $16, %rcx
    call tl_alloc
    movq %r12, 0(%rax)
    movq %r13, 8(%rax)
    movq %rax, %r14
    movq $16, %rcx
    call tl_alloc
    movq %rbx, 0(%rax)
    movq %r14, 8(%rax)
    movq %rax, %r15
    movq $16, %rcx
    call tl_alloc
    movq $1, 0(%rax)
    movq %r15, 8(%rax)
    add $8, %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

.L_tl_process_close_temp_files:
    sub $40, %rsp
    movq -48(%rbp), %rcx
    testq %rcx, %rcx
    jz .L_tl_process_close_temp_stderr
    call fclose
    movq $0, -48(%rbp)
.L_tl_process_close_temp_stderr:
    movq -64(%rbp), %rcx
    testq %rcx, %rcx
    jz .L_tl_process_close_temp_done
    call fclose
    movq $0, -64(%rbp)
.L_tl_process_close_temp_done:
    movq -80(%rbp), %rcx
    cmpq $0, %rcx
    jl .L_tl_process_close_saved_stderr
    call _close
    movq $-1, -80(%rbp)
.L_tl_process_close_saved_stderr:
    movq -88(%rbp), %rcx
    cmpq $0, %rcx
    jl .L_tl_process_close_all_done
    call _close
    movq $-1, -88(%rbp)
.L_tl_process_close_all_done:
    add $40, %rsp
    ret
")

(define (compiler-backend-runtime-process-output-functions) : String
  "tl_process_start:
    push %rbp
    movq %rsp, %rbp
    leaq .L_tl_process_async_unsupported_msg(%rip), %rdi
    movq $.L_tl_process_async_unsupported_msg_len, %rsi
    movq $3, %rdx
    call .L_tl_process_make_error
    movq %rbp, %rsp
    pop %rbp
    ret

tl_process_wait:
    push %rbp
    movq %rsp, %rbp
    leaq .L_tl_process_async_unsupported_msg(%rip), %rdi
    movq $.L_tl_process_async_unsupported_msg_len, %rsi
    movq $3, %rdx
    call .L_tl_process_make_error
    movq %rbp, %rsp
    pop %rbp
    ret

tl_process_output:
    push %rbp
    movq %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    subq $280, %rsp
    movq %rdi, -8(%rbp)
    movq 0(%rdi), %rdi
    call .L_tl_process_cstring_from_string
    movq %rax, -16(%rbp)
    movq -8(%rbp), %rax
    movq 8(%rax), %r12
    xorq %r13, %r13
.L_tl_process_count_args:
    cmpq $0, 0(%r12)
    je .L_tl_process_count_args_done
    incq %r13
    movq 16(%r12), %r12
    jmp .L_tl_process_count_args
.L_tl_process_count_args_done:
    movq %r13, -24(%rbp)
    leaq 2(%r13), %rdi
    shlq $3, %rdi
    call tl_alloc
    movq %rax, -32(%rbp)
    movq -16(%rbp), %r10
    movq %r10, 0(%rax)
    movq -8(%rbp), %r10
    movq 8(%r10), %r12
    movq -32(%rbp), %r14
    movq $1, %r15
.L_tl_process_fill_argv:
    cmpq $0, 0(%r12)
    je .L_tl_process_fill_argv_done
    movq 8(%r12), %rdi
    call .L_tl_process_cstring_from_string
    movq %rax, (%r14,%r15,8)
    incq %r15
    movq 16(%r12), %r12
    jmp .L_tl_process_fill_argv
.L_tl_process_fill_argv_done:
    movq $0, (%r14,%r15,8)
    movq $0, -120(%rbp)
    movq -8(%rbp), %rax
    movq 16(%rax), %r12
    cmpq $1, 0(%r12)
    jne .L_tl_process_cwd_done
    movq 8(%r12), %rdi
    call .L_tl_process_cstring_from_string
    movq %rax, -120(%rbp)
.L_tl_process_cwd_done:
    movq -8(%rbp), %rax
    movq 24(%rax), %rdi
    call .L_tl_process_envp_from_overrides
    movq %rax, -128(%rbp)
    movq $0, -136(%rbp)
    movq $0, -144(%rbp)
    movq $-1, -152(%rbp)
    movq $-1, -160(%rbp)
    movq -8(%rbp), %rax
    movq 32(%rax), %r12
    cmpq $1, 0(%r12)
    jne .L_tl_process_stdin_done
    movq 8(%r12), %r12
    movq 0(%r12), %rax
    movq %rax, -136(%rbp)
    movq 8(%r12), %rax
    movq %rax, -144(%rbp)
    leaq -192(%rbp), %rdi
    movq $524288, %rsi
    movq $293, %rax
    syscall
    testq %rax, %rax
    js .L_tl_process_spawn_failed
    movslq -192(%rbp), %rax
    movq %rax, -152(%rbp)
    movslq -188(%rbp), %rax
    movq %rax, -160(%rbp)
.L_tl_process_stdin_done:
    leaq .L_tl_process_stdout_name(%rip), %rdi
    xorq %rsi, %rsi
    movq $319, %rax
    syscall
    testq %rax, %rax
    js .L_tl_process_spawn_failed
    movq %rax, -40(%rbp)
    leaq .L_tl_process_stderr_name(%rip), %rdi
    xorq %rsi, %rsi
    movq $319, %rax
    syscall
    testq %rax, %rax
    js .L_tl_process_spawn_failed
    movq %rax, -56(%rbp)
    leaq -176(%rbp), %rdi
    movq $524288, %rsi
    movq $293, %rax
    syscall
    testq %rax, %rax
    js .L_tl_process_spawn_failed
    movslq -176(%rbp), %rax
    movq %rax, -72(%rbp)
    movslq -172(%rbp), %rax
    movq %rax, -80(%rbp)
    movq $57, %rax
    syscall
    testq %rax, %rax
    js .L_tl_process_spawn_failed
    jz .L_tl_process_child
    movq %rax, -88(%rbp)
    movq -80(%rbp), %rdi
    call .L_tl_process_close_fd
    movq $-1, -80(%rbp)
    movq -152(%rbp), %rdi
    cmpq $0, %rdi
    jl .L_tl_process_parent_stdin_done
    call .L_tl_process_close_fd
    movq $-1, -152(%rbp)
    movq $1, -224(%rbp)
    movq $0, -216(%rbp)
    movq $0, -208(%rbp)
    movq $0, -200(%rbp)
    movq $13, %rdi
    leaq -224(%rbp), %rsi
    leaq -264(%rbp), %rdx
    movq $8, %r10
    movq $13, %rax
    syscall
    movq -160(%rbp), %rdi
    movq -136(%rbp), %rsi
    movq -144(%rbp), %rdx
    call .L_tl_process_write_all
    movq %rax, %r12
    movq -160(%rbp), %rdi
    call .L_tl_process_close_fd
    movq $-1, -160(%rbp)
    movq $13, %rdi
    leaq -264(%rbp), %rsi
    xorq %rdx, %rdx
    movq $8, %r10
    movq $13, %rax
    syscall
    testq %r12, %r12
    jns .L_tl_process_parent_stdin_done
    cmpq $-32, %r12
    je .L_tl_process_parent_stdin_done
    jmp .L_tl_process_wait_failed
.L_tl_process_parent_stdin_done:
    movq -88(%rbp), %rdi
    leaq -184(%rbp), %rsi
    xorq %rdx, %rdx
    xorq %r10, %r10
    movq $61, %rax
    syscall
    testq %rax, %rax
    js .L_tl_process_wait_failed
    movq -72(%rbp), %rdi
    call .L_tl_process_read_all
    movq %rax, -112(%rbp)
    movq -72(%rbp), %rdi
    call .L_tl_process_close_fd
    movq -112(%rbp), %rax
    cmpq $0, 8(%rax)
    jne .L_tl_process_spawn_failed
    movq -40(%rbp), %rdi
    call .L_tl_process_seek_start
    testq %rax, %rax
    js .L_tl_process_wait_failed
    movq -40(%rbp), %rdi
    call .L_tl_process_read_all
    movq %rax, -96(%rbp)
    movq -40(%rbp), %rdi
    call .L_tl_process_close_fd
    movq -56(%rbp), %rdi
    call .L_tl_process_seek_start
    testq %rax, %rax
    js .L_tl_process_wait_failed
    movq -56(%rbp), %rdi
    call .L_tl_process_read_all
    movq %rax, -104(%rbp)
    movq -56(%rbp), %rdi
    call .L_tl_process_close_fd
    movl -184(%rbp), %eax
    movl %eax, %ecx
    andl $127, %ecx
    cmpl $0, %ecx
    jne .L_tl_process_status_signal
    shrl $8, %eax
    andl $255, %eax
    jmp .L_tl_process_status_ready
.L_tl_process_status_signal:
    movl %ecx, %eax
    addl $128, %eax
.L_tl_process_status_ready:
    movslq %eax, %rdi
    movq -96(%rbp), %rsi
    movq -104(%rbp), %rdx
    call .L_tl_process_make_ok
    jmp .L_tl_process_return
.L_tl_process_child:
    movq -72(%rbp), %rdi
    call .L_tl_process_close_fd
    movq -160(%rbp), %rdi
    cmpq $0, %rdi
    jl .L_tl_process_child_stdin_dup_done
    call .L_tl_process_close_fd
    movq -152(%rbp), %rdi
    movq $0, %rsi
    movq $33, %rax
    syscall
    testq %rax, %rax
    js .L_tl_process_child_exec_failed
    movq -152(%rbp), %rdi
    call .L_tl_process_close_fd
.L_tl_process_child_stdin_dup_done:
    movq -40(%rbp), %rdi
    movq $1, %rsi
    movq $33, %rax
    syscall
    movq -56(%rbp), %rdi
    movq $2, %rsi
    movq $33, %rax
    syscall
    movq -40(%rbp), %rdi
    call .L_tl_process_close_fd
    movq -56(%rbp), %rdi
    call .L_tl_process_close_fd
    movq -120(%rbp), %rdi
    testq %rdi, %rdi
    jz .L_tl_process_child_cwd_done
    movq $80, %rax
    syscall
    testq %rax, %rax
    js .L_tl_process_child_exec_failed
.L_tl_process_child_cwd_done:
    movq -16(%rbp), %rdi
    movq -32(%rbp), %rsi
    movq -128(%rbp), %rdx
    movq $59, %rax
    syscall
.L_tl_process_child_exec_failed:
    movq $1, %rax
    movq -80(%rbp), %rdi
    leaq .L_tl_process_exec_marker(%rip), %rsi
    movq $.L_tl_process_exec_marker_len, %rdx
    syscall
    movq $60, %rax
    movq $127, %rdi
    syscall
.L_tl_process_spawn_failed:
    leaq .L_tl_process_spawn_msg(%rip), %rdi
    movq $.L_tl_process_spawn_msg_len, %rsi
    movq $1, %rdx
    call .L_tl_process_make_error
    jmp .L_tl_process_return
.L_tl_process_wait_failed:
    leaq .L_tl_process_wait_msg(%rip), %rdi
    movq $.L_tl_process_wait_msg_len, %rsi
    movq $2, %rdx
    call .L_tl_process_make_error
.L_tl_process_return:
    addq $280, %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    movq %rbp, %rsp
    pop %rbp
    ret

.L_tl_process_close_fd:
    movq $3, %rax
    syscall
    ret

.L_tl_process_write_all:
    push %rbp
    movq %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    movq %rdi, %rbx
    movq %rsi, %r12
    movq %rdx, %r13
    xorq %r14, %r14
.L_tl_process_write_all_loop:
    cmpq %r13, %r14
    jge .L_tl_process_write_all_ok
    movq $1, %rax
    movq %rbx, %rdi
    leaq (%r12,%r14), %rsi
    movq %r13, %rdx
    subq %r14, %rdx
    syscall
    testq %rax, %rax
    jl .L_tl_process_write_all_return
    jz .L_tl_process_write_all_fail
    addq %rax, %r14
    jmp .L_tl_process_write_all_loop
.L_tl_process_write_all_ok:
    xorq %rax, %rax
    jmp .L_tl_process_write_all_return
.L_tl_process_write_all_fail:
    movq $-1, %rax
.L_tl_process_write_all_return:
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    movq %rbp, %rsp
    pop %rbp
    ret

.L_tl_process_seek_start:
    xorq %rsi, %rsi
    xorq %rdx, %rdx
    movq $8, %rax
    syscall
    ret

.L_tl_process_cstring_from_string:
    push %rbp
    movq %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    movq %rdi, %r12
    movq 0(%r12), %r13
    movq 8(%r12), %rbx
    leaq 1(%rbx), %rdi
    call tl_alloc
    movq %rax, %r14
    xorq %rcx, %rcx
.L_tl_process_cstring_copy:
    cmpq %rbx, %rcx
    jge .L_tl_process_cstring_done
    movzbl (%r13,%rcx), %edx
    movb %dl, (%r14,%rcx)
    incq %rcx
    jmp .L_tl_process_cstring_copy
.L_tl_process_cstring_done:
    movb $0, (%r14,%rbx)
    movq %r14, %rax
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    movq %rbp, %rsp
    pop %rbp
    ret

.L_tl_process_env_entry_matches:
    push %rbp
    movq %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    push %rdi
    subq $8, %rsp
    movq %rdi, %rbx
    movq %rsi, %r12
.L_tl_process_env_match_loop:
    cmpq $1, 0(%r12)
    jne .L_tl_process_env_match_false
    movq 8(%r12), %rax
    movq 0(%rax), %r13
    movq 8(%rax), %r14
    xorq %r15, %r15
.L_tl_process_env_match_char:
    cmpq %r14, %r15
    jge .L_tl_process_env_match_eq
    movzbl (%r13,%r15), %eax
    movzbl (%rbx,%r15), %ecx
    cmpb %cl, %al
    jne .L_tl_process_env_match_next
    incq %r15
    jmp .L_tl_process_env_match_char
.L_tl_process_env_match_eq:
    movzbl (%rbx,%r14), %eax
    cmpb $61, %al
    jne .L_tl_process_env_match_next
    movq $1, %rax
    jmp .L_tl_process_env_match_return
.L_tl_process_env_match_next:
    movq 24(%r12), %r12
    jmp .L_tl_process_env_match_loop
.L_tl_process_env_match_false:
    xorq %rax, %rax
.L_tl_process_env_match_return:
    addq $8, %rsp
    pop %rdi
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    movq %rbp, %rsp
    pop %rbp
    ret

.L_tl_process_env_cstring:
    push %rbp
    movq %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    subq $8, %rsp
    movq 0(%rdi), %r12
    movq 8(%rdi), %rbx
    movq 0(%rsi), %r14
    movq 8(%rsi), %r13
    movq %rbx, %rdi
    addq %r13, %rdi
    addq $2, %rdi
    call tl_alloc
    movq %rax, %r15
    xorq %rcx, %rcx
.L_tl_process_env_cs_name:
    cmpq %rbx, %rcx
    jge .L_tl_process_env_cs_name_done
    movzbl (%r12,%rcx), %eax
    movb %al, (%r15,%rcx)
    incq %rcx
    jmp .L_tl_process_env_cs_name
.L_tl_process_env_cs_name_done:
    movb $61, (%r15,%rbx)
    xorq %rcx, %rcx
.L_tl_process_env_cs_value:
    cmpq %r13, %rcx
    jge .L_tl_process_env_cs_value_done
    movzbl (%r14,%rcx), %eax
    leaq 1(%rbx,%rcx), %rdx
    movb %al, (%r15,%rdx)
    incq %rcx
    jmp .L_tl_process_env_cs_value
.L_tl_process_env_cs_value_done:
    leaq 1(%rbx,%r13), %rdx
    movb $0, (%r15,%rdx)
    movq %r15, %rax
    addq $8, %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    movq %rbp, %rsp
    pop %rbp
    ret

.L_tl_process_envp_from_overrides:
    push %rbp
    movq %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    subq $8, %rsp
    movq %rdi, %r12
    cmpq $1, 0(%r12)
    jne .L_tl_process_envp_inherited
    movq .L_tl_envp(%rip), %rbx
    xorq %r13, %r13
.L_tl_process_envp_count_inh:
    movq (%rbx), %rdi
    testq %rdi, %rdi
    jz .L_tl_process_envp_count_overrides
    movq %r12, %rsi
    call .L_tl_process_env_entry_matches
    testq %rax, %rax
    jne .L_tl_process_envp_count_inh_next
    incq %r13
.L_tl_process_envp_count_inh_next:
    addq $8, %rbx
    jmp .L_tl_process_envp_count_inh
.L_tl_process_envp_count_overrides:
    xorq %r14, %r14
    movq %r12, %r15
.L_tl_process_envp_count_ov:
    cmpq $1, 0(%r15)
    jne .L_tl_process_envp_alloc
    incq %r14
    movq 24(%r15), %r15
    jmp .L_tl_process_envp_count_ov
.L_tl_process_envp_alloc:
    movq %r13, %rdi
    addq %r14, %rdi
    incq %rdi
    shlq $3, %rdi
    call tl_alloc
    movq %rax, %r15
    movq .L_tl_envp(%rip), %rbx
    xorq %r14, %r14
.L_tl_process_envp_copy_inh:
    movq (%rbx), %rdi
    testq %rdi, %rdi
    jz .L_tl_process_envp_copy_ov_start
    movq %r12, %rsi
    call .L_tl_process_env_entry_matches
    testq %rax, %rax
    jne .L_tl_process_envp_copy_inh_next
    movq (%rbx), %rax
    movq %rax, (%r15,%r14,8)
    incq %r14
.L_tl_process_envp_copy_inh_next:
    addq $8, %rbx
    jmp .L_tl_process_envp_copy_inh
.L_tl_process_envp_copy_ov_start:
    movq %r12, %rbx
.L_tl_process_envp_copy_ov:
    cmpq $1, 0(%rbx)
    jne .L_tl_process_envp_done
    movq 8(%rbx), %rdi
    movq 16(%rbx), %rsi
    call .L_tl_process_env_cstring
    movq %rax, (%r15,%r14,8)
    incq %r14
    movq 24(%rbx), %rbx
    jmp .L_tl_process_envp_copy_ov
.L_tl_process_envp_done:
    movq $0, (%r15,%r14,8)
    movq %r15, %rax
    jmp .L_tl_process_envp_return
.L_tl_process_envp_inherited:
    movq .L_tl_envp(%rip), %rax
.L_tl_process_envp_return:
    addq $8, %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    movq %rbp, %rsp
    pop %rbp
    ret

.L_tl_process_read_all:
    push %rbp
    movq %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    subq $8, %rsp
    movq %rdi, %r12
    movq $4096, %r13
    movq %r13, %rdi
    call tl_alloc
    movq %rax, %r14
    xorq %r15, %r15
.L_tl_process_read_loop:
    movq %r13, %rdx
    subq %r15, %rdx
    cmpq $1024, %rdx
    jl .L_tl_process_read_grow
    movq $0, %rax
    movq %r12, %rdi
    leaq (%r14,%r15), %rsi
    syscall
    testq %rax, %rax
    js .L_tl_process_read_done
    jz .L_tl_process_read_done
    addq %rax, %r15
    jmp .L_tl_process_read_loop
.L_tl_process_read_grow:
    movq %r13, %rdi
    shlq $1, %rdi
    movq %rdi, %r13
    call tl_alloc
    movq %rax, %r10
    xorq %rbx, %rbx
.L_tl_process_read_copy:
    cmpq %r15, %rbx
    jge .L_tl_process_read_copy_done
    movzbl (%r14,%rbx), %eax
    movb %al, (%r10,%rbx)
    incq %rbx
    jmp .L_tl_process_read_copy
.L_tl_process_read_copy_done:
    movq %r10, %r14
    jmp .L_tl_process_read_loop
.L_tl_process_read_done:
    movq $16, %rdi
    call tl_alloc
    movq %r14, 0(%rax)
    movq %r15, 8(%rax)
    addq $8, %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    movq %rbp, %rsp
    pop %rbp
    ret

.L_tl_process_make_ok:
    push %rbp
    movq %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    subq $8, %rsp
    movq %rdi, %rbx
    movq %rsi, %r12
    movq %rdx, %r13
    movq $24, %rdi
    call tl_alloc
    movq %rbx, 0(%rax)
    movq %r12, 8(%rax)
    movq %r13, 16(%rax)
    movq %rax, %r12
    movq $16, %rdi
    call tl_alloc
    movq $0, 0(%rax)
    movq %r12, 8(%rax)
    addq $8, %rsp
    pop %r13
    pop %r12
    pop %rbx
    movq %rbp, %rsp
    pop %rbp
    ret

.L_tl_process_make_error:
    push %rbp
    movq %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    movq %rdi, %r12
    movq %rsi, %r13
    movq %rdx, %r14
    movq $16, %rdi
    call tl_alloc
    movq %r12, 0(%rax)
    movq %r13, 8(%rax)
    movq %rax, %r12
    movq $16, %rdi
    call tl_alloc
    movq %r14, 0(%rax)
    movq %r12, 8(%rax)
    movq %rax, %r12
    movq $16, %rdi
    call tl_alloc
    movq $1, 0(%rax)
    movq %r12, 8(%rax)
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    movq %rbp, %rsp
    pop %rbp
    ret

")

(define (compiler-backend-runtime-stdin-abort) : String
  "    movq $1, %rax
    movq $2, %rdi
    leaq .L_tl_stdin_error_msg(%rip), %rsi
    movq $.L_tl_stdin_error_msg_len, %rdx
    syscall
    movq $60, %rax
    movq $134, %rdi
    syscall
")

(define (compiler-backend-runtime-windows-stdin-abort) : String
  "    movq $2, %rcx
    leaq .L_tl_stdin_error_msg(%rip), %rdx
    movq $.L_tl_stdin_error_msg_len, %r8
    sub $32, %rsp
    call _write
    add $32, %rsp
    movq $134, %rcx
    sub $32, %rsp
    call exit
")

(define (compiler-backend-runtime-read-stdin-line-functions) : String
  (string-append
    "    .globl tl_read_stdin_line
tl_read_stdin_line:
.L_tl_read_stdin_line:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    sub $16, %rsp
    movq $64, %r13
    movq %r13, %rdi
    call tl_alloc
    movq %rax, %rbx
    xorq %r12, %r12
.L_tl_read_stdin_line_loop:
    xorq %rax, %rax
    xorq %rdi, %rdi
    leaq -40(%rbp), %rsi
    movq $1, %rdx
    syscall
    testq %rax, %rax
    js .L_tl_read_stdin_line_error
    jz .L_tl_read_stdin_line_eof
    cmpb $10, -40(%rbp)
    je .L_tl_read_stdin_line_done
    cmpq %r13, %r12
    jb .L_tl_read_stdin_line_store
    movq %r13, %rdi
    addq %r13, %rdi
    js .L_tl_read_stdin_line_error
    movq %rdi, %r14
    call tl_alloc
    xorq %rcx, %rcx
.L_tl_read_stdin_line_copy_loop:
    cmpq %r12, %rcx
    jge .L_tl_read_stdin_line_copy_done
    movzbl (%rbx,%rcx), %edx
    movb %dl, (%rax,%rcx)
    incq %rcx
    jmp .L_tl_read_stdin_line_copy_loop
.L_tl_read_stdin_line_copy_done:
    movq %rax, %rbx
    movq %r14, %r13
.L_tl_read_stdin_line_store:
    movzbl -40(%rbp), %eax
    movb %al, (%rbx,%r12)
    incq %r12
    jmp .L_tl_read_stdin_line_loop
.L_tl_read_stdin_line_eof:
    movq $1, .L_tl_stdin_eof_flag(%rip)
    jmp .L_tl_read_stdin_line_return
.L_tl_read_stdin_line_done:
    movq $0, .L_tl_stdin_eof_flag(%rip)
.L_tl_read_stdin_line_return:
    movq $16, %rdi
    call tl_alloc
    movq %rbx, 0(%rax)
    movq %r12, 8(%rax)
    add $16, %rsp
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
.L_tl_read_stdin_line_error:
"
    (string-append (compiler-backend-runtime-stdin-abort) "\n")))

(define (compiler-backend-runtime-windows-read-stdin-line-functions) : String
  (string-append
    "    .globl tl_read_stdin_line
tl_read_stdin_line:
.L_tl_read_stdin_line:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    sub $16, %rsp
    movq $64, %r13
    movq %r13, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rax, %rbx
    xorq %r12, %r12
.L_tl_read_stdin_line_loop:
    xorq %rcx, %rcx
    leaq -40(%rbp), %rdx
    movq $1, %r8
    sub $32, %rsp
    call _read
    add $32, %rsp
    movslq %eax, %rax
    testq %rax, %rax
    js .L_tl_read_stdin_line_error
    jz .L_tl_read_stdin_line_eof
    cmpb $10, -40(%rbp)
    je .L_tl_read_stdin_line_done
    cmpq %r13, %r12
    jb .L_tl_read_stdin_line_store
    movq %r13, %rcx
    addq %r13, %rcx
    js .L_tl_read_stdin_line_error
    movq %rcx, %r14
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    xorq %r10, %r10
.L_tl_read_stdin_line_copy_loop:
    cmpq %r12, %r10
    jge .L_tl_read_stdin_line_copy_done
    movzbl (%rbx,%r10), %edx
    movb %dl, (%rax,%r10)
    incq %r10
    jmp .L_tl_read_stdin_line_copy_loop
.L_tl_read_stdin_line_copy_done:
    movq %rax, %rbx
    movq %r14, %r13
.L_tl_read_stdin_line_store:
    movzbl -40(%rbp), %eax
    movb %al, (%rbx,%r12)
    incq %r12
    jmp .L_tl_read_stdin_line_loop
.L_tl_read_stdin_line_eof:
    movq $1, .L_tl_stdin_eof_flag(%rip)
    jmp .L_tl_read_stdin_line_return
.L_tl_read_stdin_line_done:
    movq $0, .L_tl_stdin_eof_flag(%rip)
.L_tl_read_stdin_line_return:
    movq $16, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rbx, 0(%rax)
    movq %r12, 8(%rax)
    add $16, %rsp
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
.L_tl_read_stdin_line_error:
"
    (string-append (compiler-backend-runtime-windows-stdin-abort) "\n")))

(define (compiler-backend-runtime-read-stdin-bytes-functions) : String
  (string-append
    "    .globl tl_read_stdin_bytes
tl_read_stdin_bytes:
.L_tl_read_stdin_bytes:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $8, %rsp
    movq %rdi, %r12
    cmpq $0, %r12
    jl .L_tl_read_stdin_bytes_error
    movq %r12, %rdi
    cmpq $0, %rdi
    jg .L_tl_read_stdin_bytes_alloc_ready
    movq $1, %rdi
.L_tl_read_stdin_bytes_alloc_ready:
    call tl_alloc
    movq %rax, %rbx
    xorq %r13, %r13
    testq %r12, %r12
    jz .L_tl_read_stdin_bytes_return
.L_tl_read_stdin_bytes_loop:
    cmpq %r12, %r13
    jge .L_tl_read_stdin_bytes_full
    movq %r12, %rdx
    subq %r13, %rdx
    xorq %rax, %rax
    xorq %rdi, %rdi
    leaq (%rbx,%r13), %rsi
    syscall
    testq %rax, %rax
    js .L_tl_read_stdin_bytes_error
    jz .L_tl_read_stdin_bytes_eof
    addq %rax, %r13
    jmp .L_tl_read_stdin_bytes_loop
.L_tl_read_stdin_bytes_full:
    movq $0, .L_tl_stdin_eof_flag(%rip)
    jmp .L_tl_read_stdin_bytes_return
.L_tl_read_stdin_bytes_eof:
    movq $1, .L_tl_stdin_eof_flag(%rip)
.L_tl_read_stdin_bytes_return:
    movq $16, %rdi
    call tl_alloc
    movq %rbx, 0(%rax)
    movq %r13, 8(%rax)
    add $8, %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
.L_tl_read_stdin_bytes_error:
"
    (string-append (compiler-backend-runtime-stdin-abort) "\n")))

(define (compiler-backend-runtime-windows-read-stdin-bytes-functions) : String
  (string-append
    "    .globl tl_read_stdin_bytes
tl_read_stdin_bytes:
.L_tl_read_stdin_bytes:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $8, %rsp
    movq %rcx, %r12
    cmpq $0, %r12
    jl .L_tl_read_stdin_bytes_error
    movq %r12, %rcx
    cmpq $0, %rcx
    jg .L_tl_read_stdin_bytes_alloc_ready
    movq $1, %rcx
.L_tl_read_stdin_bytes_alloc_ready:
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rax, %rbx
    xorq %r13, %r13
    testq %r12, %r12
    jz .L_tl_read_stdin_bytes_return
.L_tl_read_stdin_bytes_loop:
    cmpq %r12, %r13
    jge .L_tl_read_stdin_bytes_full
    xorq %rcx, %rcx
    leaq (%rbx,%r13), %rdx
    movq %r12, %r8
    subq %r13, %r8
    sub $32, %rsp
    call _read
    add $32, %rsp
    movslq %eax, %rax
    testq %rax, %rax
    js .L_tl_read_stdin_bytes_error
    jz .L_tl_read_stdin_bytes_eof
    addq %rax, %r13
    jmp .L_tl_read_stdin_bytes_loop
.L_tl_read_stdin_bytes_full:
    movq $0, .L_tl_stdin_eof_flag(%rip)
    jmp .L_tl_read_stdin_bytes_return
.L_tl_read_stdin_bytes_eof:
    movq $1, .L_tl_stdin_eof_flag(%rip)
.L_tl_read_stdin_bytes_return:
    movq $16, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %rbx, 0(%rax)
    movq %r13, 8(%rax)
    add $8, %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
.L_tl_read_stdin_bytes_error:
"
    (string-append (compiler-backend-runtime-windows-stdin-abort) "\n")))

(define (compiler-backend-runtime-stdin-eof-functions) : String
  "    .globl tl_stdin_eof
tl_stdin_eof:
.L_tl_stdin_eof:
    movq .L_tl_stdin_eof_flag(%rip), %rax
    ret

")

(define (compiler-backend-runtime-flush-stdout-functions) : String
  "    .globl tl_flush_stdout
tl_flush_stdout:
.L_tl_flush_stdout:
    ret

")

(define (compiler-backend-runtime-windows-flush-stdout-functions) : String
  "    .globl tl_flush_stdout
tl_flush_stdout:
.L_tl_flush_stdout:
    push %rbp
    mov %rsp, %rbp
    xorq %rcx, %rcx
    sub $32, %rsp
    call fflush
    add $32, %rsp
    testl %eax, %eax
    jne .L_tl_flush_stdout_error
    mov %rbp, %rsp
    pop %rbp
    ret
.L_tl_flush_stdout_error:
    movq $2, %rcx
    leaq .L_tl_flush_stdout_error_msg(%rip), %rdx
    movq $.L_tl_flush_stdout_error_msg_len, %r8
    sub $32, %rsp
    call _write
    add $32, %rsp
    movq $134, %rcx
    sub $32, %rsp
    call exit

")

(define (compiler-backend-runtime-random-system-seed-functions) : String
  "    .globl tl_random_system_seed
tl_random_system_seed:
    push %rbp
    movq %rsp, %rbp
    push %r12
    push %r13
    sub $16, %rsp
    leaq (%rsp), %rdi
    movq $8, %rsi
    xorq %rdx, %rdx
    movq $318, %rax
    syscall
    testq %rax, %rax
    js .L_tl_random_system_seed_err
    cmpq $8, %rax
    jne .L_tl_random_system_seed_err
    movq (%rsp), %r12
    movq $16, %rdi
    call tl_alloc
    movq $0, 0(%rax)
    movq %r12, 8(%rax)
    add $16, %rsp
    pop %r13
    pop %r12
    pop %rbp
    ret
.L_tl_random_system_seed_err:
    leaq .L_tl_random_system_seed_err_msg(%rip), %r12
    movq $.L_tl_random_system_seed_err_msg_len, %r13
    movq $16, %rdi
    call tl_alloc
    movq %r12, 0(%rax)
    movq %r13, 8(%rax)
    movq %rax, %r12
    movq $16, %rdi
    call tl_alloc
    movq $0, 0(%rax)
    movq %r12, 8(%rax)
    movq %rax, %r12
    movq $16, %rdi
    call tl_alloc
    movq $1, 0(%rax)
    movq %r12, 8(%rax)
    movq %rax, %r12
    movq $16, %rdi
    call tl_alloc
    movq $1, 0(%rax)
    movq %r12, 8(%rax)
    add $16, %rsp
    pop %r13
    pop %r12
    pop %rbp
    ret

")

(define (compiler-backend-runtime-windows-random-system-seed-functions) : String
  "    .globl tl_random_system_seed
tl_random_system_seed:
    push %rbp
    mov %rsp, %rbp
    push %r12
    push %r13
    sub $16, %rsp
    leaq (%rsp), %rcx
    movl $8, %edx
    sub $32, %rsp
    call SystemFunction036
    add $32, %rsp
    testb %al, %al
    jz .L_tl_random_system_seed_err
    movq (%rsp), %r12
    movq $16, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq $0, 0(%rax)
    movq %r12, 8(%rax)
    add $16, %rsp
    pop %r13
    pop %r12
    pop %rbp
    ret
.L_tl_random_system_seed_err:
    leaq .L_tl_random_system_seed_err_msg(%rip), %r12
    movq $.L_tl_random_system_seed_err_msg_len, %r13
    movq $16, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %r12, 0(%rax)
    movq %r13, 8(%rax)
    movq %rax, %r12
    movq $16, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq $0, 0(%rax)
    movq %r12, 8(%rax)
    movq %rax, %r12
    movq $16, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq $1, 0(%rax)
    movq %r12, 8(%rax)
    movq %rax, %r12
    movq $16, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq $1, 0(%rax)
    movq %r12, 8(%rax)
    add $16, %rsp
    pop %r13
    pop %r12
    pop %rbp
    ret

")

(define (compiler-backend-runtime-windows-setup-instances-functions
  [target : CompilerBackendTarget]) : String
  (if (compiler-backend-target-windows? target)
    "    .globl tl_windows_setup_instances
tl_windows_setup_instances:
    push %rbp
    mov %rsp, %rbp
    push %r12
    push %r13
    leaq .L_tl_windows_setup_unavailable_msg(%rip), %r12
    movq $.L_tl_windows_setup_unavailable_msg_len, %r13
    movq $16, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %r12, 0(%rax)
    movq %r13, 8(%rax)
    movq %rax, %r12
    movq $16, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq $1, 0(%rax)
    movq %r12, 8(%rax)
    movq %rax, %r12
    movq $16, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq $1, 0(%rax)
    movq %r12, 8(%rax)
    pop %r13
    pop %r12
    pop %rbp
    ret

"
    "    .globl tl_windows_setup_instances
tl_windows_setup_instances:
    push %rbp
    mov %rsp, %rbp
    push %r12
    push %r13
    leaq .L_tl_windows_setup_unsupported_msg(%rip), %r12
    movq $.L_tl_windows_setup_unsupported_msg_len, %r13
    movq $16, %rdi
    call tl_alloc
    movq %r12, 0(%rax)
    movq %r13, 8(%rax)
    movq %rax, %r12
    movq $16, %rdi
    call tl_alloc
    movq $0, 0(%rax)
    movq %r12, 8(%rax)
    movq %rax, %r12
    movq $16, %rdi
    call tl_alloc
    movq $1, 0(%rax)
    movq %r12, 8(%rax)
    pop %r13
    pop %r12
    pop %rbp
    ret

"))

(define (compiler-backend-runtime-windows-sdk-registry-install-functions
  [target : CompilerBackendTarget]) : String
  (if (compiler-backend-target-windows? target)
    "    .globl tl_windows_sdk_registry_install
tl_windows_sdk_registry_install:
    push %rbp
    mov %rsp, %rbp
    push %r12
    push %r13
    push %r14
    sub $8, %rsp
    movq $0, %r12
    leaq .L_tl_windows_registry_unsupported_msg(%rip), %r13
    movq $.L_tl_windows_registry_unsupported_msg_len, %r14
    movq $16, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %r13, 0(%rax)
    movq %r14, 8(%rax)
    movq %rax, %r13
    movq $16, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq %r12, 0(%rax)
    movq %r13, 8(%rax)
    movq %rax, %r13
    movq $16, %rcx
    sub $32, %rsp
    call tl_alloc
    add $32, %rsp
    movq $1, 0(%rax)
    movq %r13, 8(%rax)
    add $8, %rsp
    pop %r14
    pop %r13
    pop %r12
    pop %rbp
    ret

"
    "    .globl tl_windows_sdk_registry_install
tl_windows_sdk_registry_install:
    push %rbp
    mov %rsp, %rbp
    push %r12
    push %r13
    push %r14
    sub $8, %rsp
    movq $0, %r12
    leaq .L_tl_windows_registry_unsupported_msg(%rip), %r13
    movq $.L_tl_windows_registry_unsupported_msg_len, %r14
    movq $16, %rdi
    call tl_alloc
    movq %r13, 0(%rax)
    movq %r14, 8(%rax)
    movq %rax, %r13
    movq $16, %rdi
    call tl_alloc
    movq %r12, 0(%rax)
    movq %r13, 8(%rax)
    movq %rax, %r13
    movq $16, %rdi
    call tl_alloc
    movq $1, 0(%rax)
    movq %r13, 8(%rax)
    add $8, %rsp
    pop %r14
    pop %r13
    pop %r12
    pop %rbp
    ret

"))

(define (compiler-backend-runtime-functions [plan : CompilerBackendRuntimePlan]) : String
  (compiler-backend-runtime-functions-for-target (BackendTargetLinux) plan))

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
        process-output
        read-line
        read-bytes
        stdin-eof
        flush-stdout
        region-mark
        region-reset
        random-system-seed
        windows-setup-instances
        windows-sdk-registry-install
        env-var-exists
        env-var-value
        env-path-separator
        div-abort
        shift-abort
        tail-plan)
      (let
        [fs-current-dir : bool
          (compiler-backend-runtime-tail-fs-current-dir? tail-plan)]
        [profile : bool (compiler-backend-runtime-tail-profile? tail-plan)]
        [alloc-asm : String
          (if alloc
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-alloc-functions profile)
              (compiler-backend-runtime-alloc-functions profile))
            "")]
        [oob-asm : String
          (if oob
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-oob-functions)
              (compiler-backend-runtime-oob-functions))
            "")]
        [div-abort-asm : String
          (if div-abort
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-div-functions)
              (compiler-backend-runtime-div-functions))
            "")]
        [shift-abort-asm : String
          (if shift-abort
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-shift-functions)
              (compiler-backend-runtime-shift-functions))
            "")]
        [substring-asm : String
          (if substring
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-substring-functions)
              (compiler-backend-runtime-substring-functions))
            "")]
        [concat-asm : String
          (if concat
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-concat-functions)
              (compiler-backend-runtime-concat-functions))
            "")]
        [string-eq-asm : String
          (if string-eq
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-string-eq-functions)
              (compiler-backend-runtime-string-eq-functions))
            "")]
        [string-to-int-asm : String
          (if string-to-int
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-string-to-int-functions)
              (compiler-backend-runtime-string-to-int-functions))
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
        [print-err-asm : String
          (if print-err
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-print-err-functions)
              (compiler-backend-runtime-print-err-functions))
            "")]
        [print-str-asm : String
          (if print-str
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-print-str-functions)
              (compiler-backend-runtime-print-str-functions))
            "")]
        [print-char-asm : String
          (if print-char
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-print-char-functions)
              (compiler-backend-runtime-print-char-functions))
            "")]
        [print-f64-asm : String
          (if print-f64
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-print-f64-functions)
              (compiler-backend-runtime-print-f64-functions))
            "")]
        [arg-count-asm : String
          (if arg-count
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-arg-count-functions)
              (compiler-backend-runtime-arg-count-functions))
            "")]
        [arg-asm : String
          (if arg
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-arg-functions)
              (compiler-backend-runtime-arg-functions))
            "")]
        [read-file-asm : String
          (if read-file
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-read-file-functions)
              (compiler-backend-runtime-read-file-functions))
            "")]
        [read-file-status-asm : String
          (if read-file
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-read-file-status-functions)
              (compiler-backend-runtime-read-file-status-functions))
            "")]
        [write-file-asm : String
          (if write-file
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-write-file-functions)
              (compiler-backend-runtime-write-file-functions))
            "")]
        [write-file-status-asm : String
          (if write-file
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-write-file-status-functions)
              (compiler-backend-runtime-write-file-status-functions))
            "")]
        [append-file-status-asm : String
          (if write-file
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-append-file-status-functions)
              (compiler-backend-runtime-append-file-status-functions))
            "")]
        [file-exists-asm : String
          (if file-exists
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-file-exists-functions)
              (compiler-backend-runtime-file-exists-functions))
            "")]
        [file-exists-status-asm : String
          (if file-exists
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-file-exists-status-functions)
              (compiler-backend-runtime-file-exists-status-functions))
            "")]
        [file-handle-asm : String
          (if file-handle
            (compiler-backend-runtime-file-handle-functions target)
            "")]
        [file-read-chunk-asm : String
          (if file-read-chunk
            (compiler-backend-runtime-file-read-chunk-functions target)
            "")]
        [fs-asm : String
          (if fs-runtime
            (compiler-backend-runtime-fs-functions-for-target target)
            "")]
        [fs-current-dir-asm : String
          (if fs-current-dir
            (compiler-backend-runtime-fs-current-dir-functions-for-target
              target)
            "")]
        [process-output-asm : String
          (if process-output
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-process-output-functions)
              (compiler-backend-runtime-process-output-functions))
            "")]
        [read-line-asm : String
          (if read-line
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-read-stdin-line-functions)
              (compiler-backend-runtime-read-stdin-line-functions))
            "")]
        [read-bytes-asm : String
          (if read-bytes
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-read-stdin-bytes-functions)
              (compiler-backend-runtime-read-stdin-bytes-functions))
            "")]
        [stdin-eof-asm : String
          (if stdin-eof
            (compiler-backend-runtime-stdin-eof-functions)
            "")]
        [flush-stdout-asm : String
          (if flush-stdout
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-flush-stdout-functions)
              (compiler-backend-runtime-flush-stdout-functions))
            "")]
        [region-mark-asm : String
          (if region-mark
            (compiler-backend-runtime-region-mark-functions)
            "")]
        [region-reset-asm : String
          (if region-reset
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-region-reset-functions profile)
              (compiler-backend-runtime-region-reset-functions profile))
            "")]
        [random-system-seed-asm : String
          (if random-system-seed
            (if (compiler-backend-target-windows? target)
              (compiler-backend-runtime-windows-random-system-seed-functions)
              (compiler-backend-runtime-random-system-seed-functions))
            "")]
        [windows-setup-instances-asm : String
          (if windows-setup-instances
            (compiler-backend-runtime-windows-setup-instances-functions target)
            "")]
        [windows-sdk-registry-install-asm : String
          (if windows-sdk-registry-install
            (compiler-backend-runtime-windows-sdk-registry-install-functions
              target)
            "")]
        [arena-asm : String
          (if (compiler-backend-target-windows? target)
            (compiler-backend-runtime-windows-arena-functions profile)
            (compiler-backend-runtime-arena-functions profile))]
        [profile-asm : String
          (compiler-backend-runtime-profile-functions-for-target target profile)]
        [runtime-front-asm : String
          (string-append
            arena-asm
            (string-append
              profile-asm
              (backend-cat5
                alloc-asm
                region-mark-asm
                region-reset-asm
                oob-asm
                div-abort-asm)))]
        [runtime-string-asm : String
          (string-append
            (backend-cat5
              shift-abort-asm
              substring-asm
              concat-asm
              string-eq-asm
              string-to-int-asm)
            (string-append int-to-string-asm abort-asm))]
        [runtime-io-asm : String
          (string-append
            (backend-cat5
              print-err-asm
              print-str-asm
              print-char-asm
              print-f64-asm
              arg-count-asm)
            (string-append
              arg-asm
              (string-append read-file-asm read-file-status-asm)))]
        [runtime-file-asm : String
          (backend-cat5
            write-file-asm
            write-file-status-asm
            append-file-status-asm
            file-exists-asm
            file-exists-status-asm)]
        [runtime-tail-asm : String
          (backend-cat5
            process-output-asm
            read-line-asm
            read-bytes-asm
            stdin-eof-asm
            flush-stdout-asm)]
        [random-and-windows-asm : String
          (string-append
            random-system-seed-asm
            (string-append
              windows-setup-instances-asm
              windows-sdk-registry-install-asm))]
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
        (backend-cat5
          runtime-front-asm
          runtime-string-asm
          runtime-io-asm
          runtime-file-asm
          (backend-cat5
            file-handle-asm
            file-read-chunk-asm
            (string-append fs-asm fs-current-dir-asm)
            runtime-tail-asm
            (backend-cat5
              random-and-windows-asm
              env-var-exists-asm
              env-var-value-asm
              env-path-separator-asm
              ""))))]))

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

;; Program entry section and global symbol. Linux normally links the bare
;; `_start`; CRT entry mode links `main` through the C runtime. Windows links
;; `main` through the CRT. (The Windows entry body is #647.)
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
          ".text\n.globl _start\n")]
      [(BackendTargetWindows) ".text\n.globl main\n"])
    ".text\n"))

(define (compiler-backend-target-entry-text
  [target : CompilerBackendTarget]
  [emit-entry : bool]) : String
  (compiler-backend-target-entry-text-with-crt target emit-entry false))

;; Run main on a fresh 1 GiB mmap'd stack, then exit(main()). The compiler
;; recurses far deeper than the default 8 MiB stack rlimit allows â€” type-directed
;; `clone` of large IR values during arena escapes (#1633) is the worst case â€” so
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
      "_start:
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
          (string-append global-inits (compiler-backend-entry-call-main)))))
    (string-append
      "_start:\n"
      (string-append global-inits (compiler-backend-entry-call-main)))))

(define (compiler-backend-entry-for-target-with-crt
  [target : CompilerBackendTarget]
  [plan : CompilerBackendRuntimePlan]
  [globals : CompilerIrGlobalList]
  [crt-entry : bool]) : String
  (match target
    [(BackendTargetLinux)
      (if crt-entry
        ""
        (let
          [_ : CompilerBackendRuntimePlan plan]
          (compiler-backend-entry
            true
            true
            (compiler-backend-global-initializers globals))))]
    [(BackendTargetWindows) ""]))

(define (compiler-backend-entry-for-target
  [target : CompilerBackendTarget]
  [plan : CompilerBackendRuntimePlan]
  [globals : CompilerIrGlobalList]) : String
  (compiler-backend-entry-for-target-with-crt target plan globals false))

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
        process-output
        read-line
        read-bytes
        stdin-eof
        flush-stdout
        region-mark
        region-reset
        random-system-seed
        windows-setup-instances
        windows-sdk-registry-install
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
            concat
            string-eq
            string-to-int
            int-to-string
            abort)]
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
            process-output
            read-line
            read-bytes
            stdin-eof)]
        [tail-runtime : bool
          (backend-or8
            flush-stdout
            region-mark
            region-reset
            random-system-seed
            windows-setup-instances
            windows-sdk-registry-install
            env-var-exists
            env-var-value)]
        [extra-runtime : bool
          (backend-or4
            env-path-separator
            div-abort
            shift-abort
            (or
              (compiler-backend-runtime-tail-fs-current-dir? tail-plan)
              (compiler-backend-runtime-tail-profile? tail-plan)))]
        (not
          (or
            front-runtime
            (or io-runtime (or file-runtime (or tail-runtime extra-runtime))))))]))

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
          (or
            (compiler-backend-plan-provides? plan "tl_oob_abort")
            (or
              (compiler-backend-plan-provides? plan ".L_tl_abort")
              (or
                (compiler-backend-plan-provides? plan "tl_div_abort")
                (or
                  (compiler-backend-plan-provides? plan "tl_shift_abort")
                  (compiler-backend-plan-provides? plan "tl_region_reset"))))))]
      (string-append
        "    .extern VirtualAlloc
    .extern VirtualFree
"
        (string-append
          (if (compiler-backend-plan-provides? plan ".L_tl_fs_mkdir_status")
            "    .extern _mkdir
    .extern _unlink
    .extern _rmdir
    .extern _errno
    .extern GetCurrentProcessId
"
            "")
          (string-append
            (if needs-write-exit
              "    .extern _write
    .extern exit
"
              "")
            (string-append
              (if (compiler-backend-plan-provides? plan "tl_random_system_seed")
                "    .extern SystemFunction036
"
                "")
              (string-append
                (if (compiler-backend-plan-provides? plan "tl_print_f64")
                  "    .extern _snprintf
"
                  "")
                (string-append
                  (if (compiler-backend-plan-provides? plan "tl_profile_now_ms")
                    "    .extern GetTickCount64
"
                    "")
                  ;; The Windows tl_process_output spawns the child via CreateProcessA
                  ;; with a constructed contiguous env block (__p__environ above) and
                  ;; captures stdout/stderr through CRT temp files made inheritable
                  ;; (tmpfile/_fileno/_get_osfhandle/SetHandleInformation), waiting via
                  ;; WaitForSingleObject/GetExitCodeProcess/CloseHandle. The Linux
                  ;; variant uses raw syscalls instead.
                  (if (compiler-backend-plan-provides? plan "tl_process_output")
                    "    .extern __p__environ
    .extern tmpfile
    .extern fclose
    .extern _fileno
    .extern _get_osfhandle
    .extern _lseeki64
    .extern _read
    .extern _close
    .extern SetHandleInformation
    .extern CreateProcessA
    .extern WaitForSingleObject
    .extern GetExitCodeProcess
    .extern CloseHandle
    .extern GetStdHandle
"
                    ""))))))))
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

(define (compiler-backend-emit-program [program : CompilerIrProgram]) : ResultCompilerBackend
  (compiler-backend-emit-program-for-target program (BackendTargetLinux)))

(define (compiler-backend-emit-program-linux [program : CompilerIrProgram]) : ResultCompilerBackend
  (compiler-backend-emit-program-for-target program (BackendTargetLinux)))

(define (compiler-backend-emit-program-with-spans
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]) : ResultCompilerBackend
  (compiler-backend-emit-program-target program (BackendTargetLinux) spans true))

(define (compiler-backend-emit-program-with-spans-and-entry
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

(define (compiler-backend-emit-program-target-with-mode-buffer-and-crt
  [program : CompilerIrProgram]
  [target : CompilerBackendTarget]
  [mode : CompilerBackendMode]
  [spans : CompilerSourceSpans]
  [emit-entry : bool]
  [crt-entry : bool]) : ResultCompilerBackendBuffer
  (match (compiler-backend-runtime-plan program)
      [(OkBackendRuntimePlan plan)
        (if (compiler-backend-target-runtime-ok? target plan)
          (match program
            [(IrProgram globals functions externs)
              (match (compiler-backend-emit-globals target globals)
                [(OkCompilerBackend globals-asm)
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
                      (cfg compile-profile (compiler-backend-profile-start))
                    (match (compiler-backend-emit-functions-buffer
                      target
                      mode
                      entry-functions
                      globals
                      entry-functions
                      externs
                      plan
                      program-index
                      spans
                      crt-entry)
                      [(OkCompilerBackendBuffer functions-buf)
                        (begin
                          (cfg
                            compile-profile
                            (compiler-backend-profile-finish "functions"))
                          (let
                            [closure-names : BackendStringList
                              (compiler-backend-collect-program-functions
                                program)]
                            (match (compiler-backend-emit-closure-entry-adapters
                              target
                              closure-names
                              entry-functions
                              externs
                              plan
                              program-index)
                              [(OkCompilerBackend closure-adapters-asm)
                                (let
                                  [strings : BackendStringList
                                    (compiler-backend-collect-program-strings
                                      program)]
                                  [floats : BackendStringList
                                    (compiler-backend-collect-program-f64s
                                      program)]
                                  [prefix-buf : TextBuf
                                (text-buf-append
                                  (text-buf-append
                                    (text-buf-append
                                      (text-buf-append
                                        (text-buf-append
                                          (text-buf-append
                                            (text-buf-append
                                              (text-buf-append
                                                (text-buf-append
                                                  (text-buf-empty)
                                                  ".data\n")
                                                globals-asm)
                                              (compiler-backend-emit-string-rodata
                                                strings))
                                            (compiler-backend-emit-f64-rodata
                                              floats))
                                          (compiler-backend-emit-closure-descriptors
                                            closure-names
                                            entry-functions
                                            externs
                                            program-index))
                                        (if emit-entry
                                          (compiler-backend-runtime-data-for-target
                                            target
                                            plan)
                                          ""))
                                      (compiler-backend-emit-externs
                                        externs
                                        plan))
                                    (compiler-backend-runtime-externs-for-target
                                      target
                                      plan))
                                  (compiler-backend-target-entry-text-with-crt
                                    target
                                    emit-entry
                                    crt-entry))]
                              [with-functions : TextBuf
                                (text-buf-append-buffer
                                  prefix-buf
                                  functions-buf)]
                              [buf : TextBuf
                                (text-buf-append
                                  (text-buf-append
                                    (text-buf-append
                                      with-functions
                                      closure-adapters-asm)
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
                                      crt-entry)
                                    ""))]
                              (OkCompilerBackendBuffer buf))]
                          [(ErrCompilerBackend message)
                            (ErrCompilerBackendBuffer message)])))]
                    [(ErrCompilerBackendBuffer message)
                      (begin
                        (cfg
                          compile-profile
                          (compiler-backend-profile-finish "functions"))
                        (ErrCompilerBackendBuffer message))])))]
                [(ErrCompilerBackend message) (ErrCompilerBackendBuffer message)])])
          (ErrCompilerBackendBuffer
            (compiler-diagnostic-at-start
              ""
              "backend: internal target runtime rejection")))]
      [(ErrBackendRuntimePlan message)
        (ErrCompilerBackendBuffer (compiler-diagnostic-at-start "" message))]))

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
    [(OkCompilerBackendBuffer buf) (OkCompilerBackend (text-buf-render buf))]
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
    [(OkCompilerBackendBuffer buf) (OkCompilerBackend (text-buf-render buf))]
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
        [(BackendTargetWindows) (CompilerLowerAvx2)])]
    [(BackendModeAvx512)
      (match target
        [(BackendTargetLinux) (CompilerLowerLinuxAvx512)]
        [(BackendTargetWindows) (CompilerLowerAvx512)])]
    [_
      (match target
        [(BackendTargetLinux) (CompilerLowerLinuxScalar)]
        [(BackendTargetWindows) (CompilerLowerScalar)])]))

(define (compiler-backend-lower-source-for-target
  [src : String]
  [target : CompilerBackendTarget]) : ResultCompilerLower
  (match (parse-ast-source-diagnostic-with-cfg
    "<source>"
    src
    (compiler-backend-target-cfgs target))
    [(OkAstProgramDiagnostic program)
      (lower-compiler-program-with-path-mode
        "<source>"
        program
        (compiler-backend-lower-mode-for-target target (BackendModeScalar)))]
    [(ErrAstProgramDiagnostic diag) (ErrCompilerLower diag)]))

(define (compiler-backend-emit-source [src : String]) : ResultCompilerBackend
  (match (lower-compiler-source src)
    [(OkCompilerLower program spans)
      (compiler-backend-emit-program-with-spans program spans)]
    [(ErrCompilerLower diag) (ErrCompilerBackend diag)]))

(define (compiler-backend-emit-source-for-target
  [src : String]
  [target : CompilerBackendTarget]) : ResultCompilerBackend
  (match (compiler-backend-lower-source-for-target src target)
    [(OkCompilerLower program spans)
      (compiler-backend-emit-program-with-spans-for-target program spans target)]
    [(ErrCompilerLower diag) (ErrCompilerBackend diag)]))

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

(define (compiler-backend-runtime-helper-externs) : CompilerIrExternList
  (compiler-ir-extern-cons
    (compiler-ir-extern-default "tl_alloc" (AstTyI64))
    (compiler-ir-extern-cons
      (compiler-ir-extern-default "tl_oob_abort" (AstTyUnit))
      (compiler-ir-extern-cons
        (compiler-ir-extern-default "tl_substring" (AstTyI64))
        (compiler-ir-extern-cons
          (compiler-ir-extern-default "tl_string_concat" (AstTyI64))
          (compiler-ir-extern-cons
            (compiler-ir-extern-default "tl_string_eq" (AstTyBool))
            (compiler-ir-extern-cons
              (compiler-ir-extern-default "tl_string_to_int" (AstTyI64))
              (compiler-ir-extern-cons
                (compiler-ir-extern-default "tl_int_to_string" (AstTyString))
                (compiler-ir-extern-cons
                  (compiler-ir-extern-default
                    "tl_process_output"
                    (ast-ty-func
                      (ast-type-cons (AstTyI64) AstTypeNil)
                      (AstTyI64)))
                  (compiler-ir-extern-cons
                    (compiler-ir-extern-default
                      "tl_random_system_seed"
                      (AstTyI64))
                    IrExternNil))))))))))

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
          (IrBlock
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
                    (IrInstrCall
                      3
                      "tl_random_system_seed"
                      (IrCallArgsNil)
                      (AstTyI64))
                    (compiler-ir-instr-cons
                      (IrInstrReturn (IrSomeValue (IrValueI64 42)))
                      IrInstrNil))))))
          IrBlockNil))
      IrFunctionNil)
    (compiler-backend-runtime-helper-externs)))

(define (compiler-backend-runtime-helper-source) : String
  "(extern tl_alloc : (-> i64 i64))
(extern tl_oob_abort : (-> unit))
(extern tl_substring : (-> i64 i64 i64 i64))
(extern tl_string_concat : (-> i64 i64 i64 i64 i64))
(extern tl_string_eq : (-> String String bool))
(extern tl_string_to_int : (-> String i64))
(extern tl_int_to_string : (-> i64 String))
(extern tl_process_output : (-> i64 i64))
(extern tl_random_system_seed : (-> i64))
(define (main) : i64
  (begin
    (tl_alloc 8)
    (tl_substring 0 0 0)
    (tl_string_concat 0 0 0 0)
    (tl_string_eq \"\" \"\")
    (tl_string_to_int \"1\")
    (tl_int_to_string 1)
    (tl_process_output 0)
    (tl_random_system_seed)))")

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
    (and
      (backend-and8
        (not
          (compiler-backend-string-contains? asm ".L_tl_file_close_status:\n"))
        (not
          (compiler-backend-string-contains?
            asm
            ".L_tl_file_read_chunk_status:\n"))
        (not
          (compiler-backend-string-contains? asm ".L_tl_file_write_status:\n"))
        (not
          (compiler-backend-string-contains? asm ".L_tl_file_flush_status:\n"))
        (not
          (compiler-backend-string-contains?
            asm
            ".L_tl_file_read_chunk_bytes:\n"))
        (not
          (compiler-backend-string-contains? asm ".L_tl_file_read_chunk_eof:\n"))
        (not (compiler-backend-string-contains? asm ".L_tl_fs_mkdir_status:\n"))
        (not (compiler-backend-string-contains? asm ".L_tl_fs_process_id:\n")))
      (backend-and8
        (not (compiler-backend-string-contains? asm ".L_tl_read_stdin_line:\n"))
        (not
          (compiler-backend-string-contains? asm ".L_tl_read_stdin_bytes:\n"))
        (not (compiler-backend-string-contains? asm ".L_tl_stdin_eof:\n"))
        (not (compiler-backend-string-contains? asm ".L_tl_flush_stdout:\n"))
        (not (compiler-backend-string-contains? asm "tl_env_var_exists:\n"))
        (not (compiler-backend-string-contains? asm "tl_env_var_value:\n"))
        (not (compiler-backend-string-contains? asm "tl_cpuid_eax:\n"))
        (not (compiler-backend-string-contains? asm "tl_xgetbv:\n"))))))

(define (compiler-backend-runtime-helper-asm-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-runtime-helper-source))
    [(OkCompilerBackend asm)
      (and
        (backend-and8
          (compiler-backend-string-contains? asm ".globl tl_alloc\n")
          (compiler-backend-string-contains? asm "tl_alloc:\n")
          (compiler-backend-string-contains? asm ".globl tl_oob_abort\n")
          (compiler-backend-string-contains? asm "tl_oob_abort:\n")
          (compiler-backend-string-contains? asm ".globl tl_substring\n")
          (compiler-backend-string-contains? asm "tl_substring:\n")
          (compiler-backend-string-contains? asm ".globl tl_string_concat\n")
          (compiler-backend-string-contains? asm "tl_string_concat:\n"))
        (and
          (backend-and8
            (compiler-backend-string-contains? asm ".globl tl_string_eq\n")
            (compiler-backend-string-contains? asm "tl_string_eq:\n")
            (compiler-backend-string-contains? asm ".globl tl_string_to_int\n")
            (compiler-backend-string-contains? asm "tl_string_to_int:\n")
            (compiler-backend-string-contains? asm ".globl tl_int_to_string\n")
            (compiler-backend-string-contains? asm "tl_int_to_string:\n")
            (compiler-backend-string-contains? asm "tl_process_output:\n")
            (compiler-backend-string-contains? asm "tl_random_system_seed:\n"))
          (and
            (backend-and4
              (compiler-backend-string-contains? asm "    call tl_alloc\n")
              (not (compiler-backend-string-contains? asm ".extern tl_alloc\n"))
              (not
                (compiler-backend-string-contains?
                  asm
                  ".extern tl_process_output\n"))
              (not
                (compiler-backend-string-contains?
                  asm
                  ".extern tl_random_system_seed\n")))
            (compiler-backend-no-stdlib-forwarding-labels? asm))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-file-handle-open-close-runtime-ok?) : bool
  (match (compiler-backend-emit-source
    "(extern os-open (:symbol \"open\") : (-> (Ptr u8) i32 i32 i32))
(extern os-close (:symbol \"close\") : (-> i32 i32))
(define (file-open-status [path : String] [mode : i64]) : i64
  (cast
    (os-open (unsafe (string-data path)) (cast mode : i32) (cast 384 : i32))
    : i64))
(define (file-close-status [handle : i64]) : i64
  (cast (os-close (cast handle : i32)) : i64))
(define (main) : i64
  (let [handle : i64 (file-open-status \"input.txt\" 0)]
    (+ handle (file-close-status handle))))")
    [(OkCompilerBackend asm)
      (and
        (and
          (compiler-backend-string-contains? asm "    call open\n")
          (compiler-backend-string-contains? asm "    call close\n"))
        (and
          (not
            (compiler-backend-string-contains? asm ".L_tl_file_open_status:\n"))
          (and
            (not
              (compiler-backend-string-contains?
                asm
                ".L_tl_file_close_status:\n"))
            (not
              (compiler-backend-string-contains?
                asm
                ".extern .L_tl_file_open_status\n")))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-windows-driver-runtime-source) : String
  "(extern win-open (:symbol \"_open\") : (-> (Ptr u8) i32 i32 i32))
(extern win-read (:symbol \"_read\") : (-> i32 (MutPtr u8) i32 i32))
(extern win-write (:symbol \"_write\") : (-> i32 (Ptr u8) i32 i32))
(extern win-close (:symbol \"_close\") : (-> i32 i32))
(extern win-access (:symbol \"_access\") : (-> (Ptr u8) i32 i32))
(extern win-strlen (:symbol \"strlen\") : (-> (Ptr u8) i64))
(define (arg-count) : i64
  (program-argc))
(define (arg [index : i64]) : String
  (let
    [argv : (Ptr (Ptr u8)) (unsafe (program-argv))]
    [raw : (Ptr u8) (unsafe (ptr-read (ptr-offset argv index)))]
    (unsafe (string-from-bytes raw (win-strlen raw)))))
(define (print-error [text : String]) : unit
  (begin
    (win-write
      (cast 2 : i32)
      (unsafe (string-data text))
      (cast (string-length text) : i32))
    unit))
(define (read-file [path : String]) : String
  (let
    [buf : (Array u8) (make-array u8 16)]
    [fd : i32
      (win-open
        (unsafe (string-data path))
        (cast 32768 : i32)
        (cast 0 : i32))]
    [n : i32 (win-read fd (unsafe (array-data buf)) (cast 16 : i32))]
    (begin
      (win-close fd)
      (unsafe
        (string-from-bytes
          (ptr-cast (array-data buf) : (Ptr u8))
          (cast n : i64))))))
(define (write-file [path : String] [text : String]) : unit
  (let
    [fd : i32
      (win-open
        (unsafe (string-data path))
        (cast 33537 : i32)
        (cast 384 : i32))]
    (begin
      (win-write fd (unsafe (string-data text)) (cast (string-length text) : i32))
      (win-close fd)
      unit)))
(define (file-exists? [path : String]) : bool
  (= (win-access (unsafe (string-data path)) (cast 0 : i32)) (cast 0 : i32)))
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
          (not (compiler-backend-string-contains? asm ".L_tl_arg_count:\n"))
          (not (compiler-backend-string-contains? asm ".L_tl_arg:\n"))
          (not (compiler-backend-string-contains? asm ".L_tl_read_file:\n"))
          (not (compiler-backend-string-contains? asm ".L_tl_write_file:\n"))
          (not (compiler-backend-string-contains? asm ".L_tl_file_exists:\n"))
          (not (compiler-backend-string-contains? asm "tl_print_err:\n"))
          (compiler-backend-string-contains? asm "tl_string_eq:\n")
          (compiler-backend-string-contains? asm "tl_string_to_int:\n"))
        (and
          (compiler-backend-string-contains? asm "tl_int_to_string:\n")
          (and
            (compiler-backend-string-contains?
              asm
              "    movq %rcx, .L_tl_argc(%rip)\n")
            (and
              (compiler-backend-string-contains? asm "    call _open\n")
              (and
                (compiler-backend-string-contains? asm "    call _read\n")
                (and
                  (compiler-backend-string-contains? asm "    call _close\n")
                  (and
                    (compiler-backend-string-contains? asm "    call _access\n")
                    (not (compiler-backend-string-contains? asm "syscall\n")))))))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-alloc-runtime-arena-ok?) : bool
  (match (compiler-backend-emit-source (compiler-backend-runtime-helper-source))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm "tl_current_arena:\n")
        (and
          (compiler-backend-string-contains?
            asm
            "    movq tl_current_arena(%rip), %r8\n")
          (and
            (compiler-backend-string-contains? asm ".L_tl_alloc_new_arena:\n")
            (and
              (compiler-backend-string-contains?
                asm
                "    movq $0x4000000, %rdx\n")
              (and
                (compiler-backend-string-contains?
                  asm
                  "    movq %rax, tl_current_arena(%rip)\n")
                (not
                  (compiler-backend-string-contains?
                    asm
                    ".L_tl_alloc_size_ready:\n")))))))]
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
        (and
          (compiler-backend-string-contains? asm ".L_tl_alloc_abort:\n")
          (compiler-backend-string-contains?
            asm
            "    leaq .L_tl_alloc_msg(%rip), %rsi\n")))]
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
          (IrBlock
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
            (IrBlock
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
  (match (compiler-backend-emit-program
    (compiler-backend-user-helper-name-program))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm ".globl _tl_tl_alloc\n")
        (and
          (compiler-backend-string-contains? asm "    call _tl_tl_alloc\n")
          (not (compiler-backend-string-contains? asm ".L_tl_alloc_msg"))))]
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
          (IrBlock
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
            (IrBlock
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
  (match (compiler-backend-emit-program
    (compiler-backend-runtime-coexist-program))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains? asm ".globl _tl_tl_alloc\n")
        (and
          (compiler-backend-string-contains? asm ".globl tl_alloc\n")
          (and
            (compiler-backend-string-contains? asm ".globl tl_substring\n")
            (and
              (compiler-backend-string-contains? asm "    call _tl_tl_alloc\n")
              (and
                (compiler-backend-string-contains?
                  asm
                  "    call tl_substring\n")
                (not
                  (compiler-backend-string-contains?
                    asm
                    ".extern tl_substring\n")))))))]
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
          (IrBlock
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
            (IrBlock
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
  (match (compiler-backend-emit-program
    (compiler-backend-module-symbol-program))
    [(OkCompilerBackend asm)
      (and
        (compiler-backend-string-contains?
          asm
          ".globl _tl_lib_u2etl_colon_colonhelper\n")
        (and
          (compiler-backend-string-contains?
            asm
            "_tl_lib_u2etl_colon_colonhelper:\n")
          (compiler-backend-string-contains?
            asm
            "    call _tl_lib_u2etl_colon_colonhelper\n")))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-extern-metadata-source) : String
  "(extern local-call (:abi c) (:symbol \"foreign_exact\") : (-> i64 i64))
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
        (and
          (compiler-backend-string-contains? asm "    call foreign_exact\n")
          (and
            (compiler-backend-string-contains? asm "    call _tl_normal\n")
            (and
              (not
                (compiler-backend-string-contains? asm ".extern local-call\n"))
              (not
                (compiler-backend-string-contains? asm "    call local-call\n"))))))]
    [(ErrCompilerBackend _) false]))

(define (compiler-backend-extern-metadata-symbol-ok?) : bool
  (and
    (compiler-backend-extern-metadata-symbol-target-ok? (BackendTargetLinux))
    (compiler-backend-extern-metadata-symbol-target-ok? (BackendTargetWindows))))
