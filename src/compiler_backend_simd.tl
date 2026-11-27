;; compiler_backend_simd.tl - AVX2 and AVX-512 vector instruction emission.
(import compiler_backend_operands as be_operand)
(import compiler_backend_program_facts as be_facts)
(import compiler_backend_state as be_state)
(import stdlib.iterator)
(import stdlib.io)
(import compiler_ir_types)
(import compiler_ast_types)
(import compiler_builtin_ids as cbi)
(import compiler_diagnostic)
(import compiler_optimize)
(import compiler_abi)
(import compiler_regalloc)
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as backend_i64_i64_map)
(import stdlib.string)
(import compiler_str_cat as str_cat)
(import compiler_owned_view as owned_view)

(define (compiler-backend-dispatch-avx2-prefix) : String
  "__tl_dispatch_variant_avx2_")

(define (compiler-backend-dispatch-avx512-prefix) : String
  "__tl_dispatch_variant_avx512_")

(define (compiler-backend-effective-mode-for-function-name
  [mode : be_state.CompilerBackendMode]
  [name : String]) : be_state.CompilerBackendMode
  (if (be_operand.compiler-backend-string-prefix-at?
    name
    (compiler-backend-dispatch-avx512-prefix)
    0)
    (Avx512)
    (if (be_operand.compiler-backend-string-prefix-at?
      name
      (compiler-backend-dispatch-avx2-prefix)
      0)
      (Avx2)
      mode)))

(define (compiler-backend-effective-function-mode
  [mode : be_state.CompilerBackendMode]
  [backend-state : be_state.CompilerBackendState]
  [func : compiler_ir_types.CompilerIrFunction]) : be_state.CompilerBackendMode
  (match func
    [(Function name _ _ _ _ _)
      (compiler-backend-effective-mode-for-function-name
        mode
        (be_state.compiler-backend-symbol-text-state backend-state name))]))

(define (compiler-backend-vector-temp-candidates) : (__tl_dyn-array i64)
  (__tl_make-array
    (compiler_abi.compiler-abi-vector-register-id 6)
    (compiler_abi.compiler-abi-vector-register-id 7)
    (compiler_abi.compiler-abi-vector-register-id 8)
    (compiler_abi.compiler-abi-vector-register-id 9)
    (compiler_abi.compiler-abi-vector-register-id 10)
    (compiler_abi.compiler-abi-vector-register-id 11)
    (compiler_abi.compiler-abi-vector-register-id 12)
    (compiler_abi.compiler-abi-vector-register-id 13)
    (compiler_abi.compiler-abi-vector-register-id 14)
    (compiler_abi.compiler-abi-vector-register-id 15)
    (compiler_abi.compiler-abi-vector-register-id 2)
    (compiler_abi.compiler-abi-vector-register-id 3)
    (compiler_abi.compiler-abi-vector-register-id 4)
    (compiler_abi.compiler-abi-vector-register-id 5)))

(define (compiler-backend-vector-temp-zmm-excluded?
  [reg : (& reg str)]
  [exclude0 : (& exclude0 str)]
  [exclude1 : (& exclude1 str)]
  [exclude2 : (& exclude2 str)]) : bool
  (or
    (string.eq reg exclude0)
    (string.eq reg exclude1)
    (string.eq reg exclude2)))

(define (compiler-backend-vector-temp-zmm-iter
  [backend-state : be_state.CompilerBackendState]
  [starts : (__tl_dyn-array i64)]
  [ends : (__tl_dyn-array i64)]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [vars : i64]
  [point : i64]
  [exclude0 : String]
  [exclude1 : String]
  [exclude2 : String]
  [role : String]
  [candidates : (__tl_dyn-array i64)]
  [i : i64]) : be_state.ResultBackendReg
  (if (>= i (array-length candidates))
    (Err (str_cat.str-cat "backend: no free AVX-512 vector temp for " role))
    (let
      [home : i64 (array-ref candidates i)]
      [reg : String (be_operand.compiler-backend-vector-home-to-zmm home)]
      (if (and
        (not
          (compiler-backend-vector-temp-zmm-excluded?
            reg
            exclude0
            exclude1
            exclude2))
        (not
          (be_operand.compiler-backend-plan-uses-reg?
            backend-state
            assignments
            home)))
        (Ok reg)
        (compiler-backend-vector-temp-zmm-iter
          backend-state
          starts
          ends
          assignments
          vars
          point
          exclude0
          exclude1
          exclude2
          role
          candidates
          (+ i 1))))))

(define (compiler-backend-vector-temp-zmm
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [exclude0 : String]
  [exclude1 : String]
  [exclude2 : String]
  [role : String]) : be_state.ResultBackendReg
  (compiler-backend-vector-temp-zmm-iter
    backend-state
    (be_state.compiler-backend-function-scratch-i64-array
      (be_state.compiler-backend-state-function-state backend-state)
      be_state.compiler-backend-scratch-i64-array-scavenge-starts)
    (be_state.compiler-backend-function-scratch-i64-array
      (be_state.compiler-backend-state-function-state backend-state)
      be_state.compiler-backend-scratch-i64-array-scavenge-ends)
    assignments
    0
    (be_state.compiler-backend-function-state-emission-point
      (be_state.compiler-backend-state-function-state backend-state))
    exclude0
    exclude1
    exclude2
    role
    (compiler-backend-vector-temp-candidates)
    0))

(define (compiler-backend-function-state-rax-forward-pending-var
  [backend-state : be_state.CompilerBackendState]) : i64
  (be_state.compiler-backend-function-state-i64
    (be_state.compiler-backend-state-function-state backend-state)
    be_state.compiler-backend-function-i64-rax-forward-pending-var))

(define (compiler-backend-mask-spill-scratch [_index : i64]) : String
  "%k7")

(define (compiler-backend-mask-store-stack-asm
  [lanes : i64]
  [reg : String]
  [operand : String]) : String
  (str_cat.str-cat
    "    "
    (be_operand.compiler-backend-avx512-mask-move-mnemonic lanes)
    " "
    reg
    ", "
    operand
    "\n"))

(define (compiler-backend-avx512-mask-dst-reg
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [role : String]
  [scratch : String]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultBackendReg
  (match (be_operand.compiler-backend-vector-var-stack-operand
    assignments
    dst
    backend-state)
    [(Some _) (Ok scratch)]
    [(No)
      (be_operand.compiler-backend-mask-var-reg
        backend-state
        assignments
        dst
        role)]))

(define (compiler-backend-avx512-mask-store-dst
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [lanes : i64]
  [reg : String]
  [backend-state : be_state.CompilerBackendState]) : String
  (match (be_operand.compiler-backend-vector-var-stack-operand
    assignments
    dst
    backend-state)
    [(Some operand) (compiler-backend-mask-store-stack-asm lanes reg operand)]
    [(No) ""]))

(define (compiler-backend-avx512-mask-source-into-gpr
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]
  [role : String]
  [lanes : i64]
  [gpr : String]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultBackendVectorUse
  (let
    [use
      (try
        (be_operand.compiler-backend-avx512-mask-register-use
          assignments
          value
          role
          lanes
          (compiler-backend-mask-spill-scratch 0)
          backend-state))]
    (match use
      [(Use load-asm mask-reg)
        (Ok
          (Use
            (str_cat.str-cat
              load-asm
              "    "
              (be_operand.compiler-backend-avx512-mask-move-mnemonic lanes)
              " "
              mask-reg
              ", "
              gpr
              "\n")
            gpr))])))

(define (compiler-backend-mask-gpr-binop-mnemonic
  [op : compiler_ir_types.CompilerIrMaskBinOp]
  [lanes : i64]) : String
  (match op
    [(And)
      (str_cat.str-cat "and" (compiler-backend-avx512-mask-int-suffix lanes))]
    [(Or)
      (str_cat.str-cat "or" (compiler-backend-avx512-mask-int-suffix lanes))]))

(define (compiler-backend-vector-binop-mnemonic
  [op : (& op compiler_ir_types.CompilerIrBinOp)]
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]
  [avx512? : bool]) : String
  (match op
    [(Add)
      (match elem-ty
        [(or (I64) (U64)) "vpaddq"]
        [(or (I32) (U32)) "vpaddd"]
        [(or (I16) (U16)) "vpaddw"]
        [(or (I8) (U8)) "vpaddb"]
        [(F64) "vaddpd"]
        [(F32) "vaddps"]
        [_ ""])]
    [(Sub)
      (match elem-ty
        [(or (I64) (U64)) "vpsubq"]
        [(or (I32) (U32)) "vpsubd"]
        [(or (I16) (U16)) "vpsubw"]
        [(or (I8) (U8)) "vpsubb"]
        [(F64) "vsubpd"]
        [(F32) "vsubps"]
        [_ ""])]
    [(Mul)
      (match elem-ty
        [(or (I64) (U64))
          (if avx512?
            "vpmullq"
            "")]
        [(or (I32) (U32)) "vpmulld"]
        [(or (I16) (U16)) "vpmullw"]
        [(F64) "vmulpd"]
        [(F32) "vmulps"]
        [_ ""])]
    [(Shl _)
      (match elem-ty
        [(or (I64) (U64)) "vpsllvq"]
        [(or (I32) (U32)) "vpsllvd"]
        [(or (I16) (U16))
          (if avx512?
            "vpsllvw"
            "")]
        [_ ""])]
    [(Shr _)
      (match elem-ty
        [(I64)
          (if avx512?
            "vpsravq"
            "")]
        [(U64) "vpsrlvq"]
        [(I32) "vpsravd"]
        [(U32) "vpsrlvd"]
        [(I16)
          (if avx512?
            "vpsravw"
            "")]
        [(U16)
          (if avx512?
            "vpsrlvw"
            "")]
        [_ ""])]
    [(BitAnd)
      (match elem-ty
        [(or (I64) (U64))
          (if avx512?
            "vpandq"
            "vpand")]
        [(or (I32) (U32) (I16) (U16) (I8) (U8))
          (if avx512?
            "vpandd"
            "vpand")]
        [_ ""])]
    [(BitOr)
      (match elem-ty
        [(or (I64) (U64))
          (if avx512?
            "vporq"
            "vpor")]
        [(or (I32) (U32) (I16) (U16) (I8) (U8))
          (if avx512?
            "vpord"
            "vpor")]
        [_ ""])]
    [(BitXor)
      (match elem-ty
        [(or (I64) (U64))
          (if avx512?
            "vpxorq"
            "vpxor")]
        [(or (I32) (U32) (I16) (U16) (I8) (U8))
          (if avx512?
            "vpxord"
            "vpxor")]
        [_ ""])]
    [_ ""]))

(define (compiler-backend-avx2-i64-vector-mul?
  [op : (& op compiler_ir_types.CompilerIrBinOp)]
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]) : bool
  (match op
    [(Mul)
      (match elem-ty
        [(or (I64) (U64)) true]
        [_ false])]
    [_ false]))

(define (compiler-backend-sse2-i32-vector-mul?
  [op : (& op compiler_ir_types.CompilerIrBinOp)]
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]) : bool
  (match op
    [(Mul)
      (match elem-ty
        [(or (I32) (U32)) true]
        [_ false])]
    [_ false]))

(define (compiler-backend-sse2-vector-binop-mnemonic
  [op : (& op compiler_ir_types.CompilerIrBinOp)]
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]) : String
  (match op
    [(Add)
      (match elem-ty
        [(or (I64) (U64)) "paddq"]
        [(or (I32) (U32)) "paddd"]
        [(or (I16) (U16)) "paddw"]
        [(or (I8) (U8)) "paddb"]
        [(F64) "addpd"]
        [(F32) "addps"]
        [_ ""])]
    [(Sub)
      (match elem-ty
        [(or (I64) (U64)) "psubq"]
        [(or (I32) (U32)) "psubd"]
        [(or (I16) (U16)) "psubw"]
        [(or (I8) (U8)) "psubb"]
        [(F64) "subpd"]
        [(F32) "subps"]
        [_ ""])]
    [(Mul)
      (match elem-ty
        [(or (I16) (U16)) "pmullw"]
        [(F64) "mulpd"]
        [(F32) "mulps"]
        [_ ""])]
    [(BitAnd)
      (match elem-ty
        [(or (I64) (U64) (I32) (U32) (I16) (U16) (I8) (U8)) "pand"]
        [_ ""])]
    [(BitOr)
      (match elem-ty
        [(or (I64) (U64) (I32) (U32) (I16) (U16) (I8) (U8)) "por"]
        [_ ""])]
    [(BitXor)
      (match elem-ty
        [(or (I64) (U64) (I32) (U32) (I16) (U16) (I8) (U8)) "pxor"]
        [_ ""])]
    [_ ""]))

(define (compiler-backend-sse2-reg-move
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]) : String
  (match elem-ty
    [(F64) "movapd"]
    [(F32) "movaps"]
    [_ "movdqa"]))

(define (compiler-backend-avx2-i64-vector-shr?
  [op : (& op compiler_ir_types.CompilerIrBinOp)]
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]) : bool
  (match op
    [(Shr _)
      (match elem-ty
        [(I64) true]
        [_ false])]
    [_ false]))

(define (compiler-backend-byte-vector-mul?
  [op : (& op compiler_ir_types.CompilerIrBinOp)]
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]) : bool
  (and
    (match elem-ty
      [(or (I8) (U8)) true]
      [_ false])
    (match op
      [(Mul) true]
      [_ false])))

(define (compiler-backend-narrow-vector-shift-mnemonic
  [op : compiler_ir_types.CompilerIrBinOp]
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]) : String
  (match op
    [(Shl _) "vpsllvd"]
    [(Shr _)
      (match elem-ty
        [(or (I16) (I8)) "vpsravd"]
        [(or (U16) (U8)) "vpsrlvd"]
        [_ ""])]
    [_ ""]))

(define (compiler-backend-narrow-vector-widen-mnemonic
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]) : String
  (match elem-ty
    [(I16) "vpmovsxwd"]
    [(U16) "vpmovzxwd"]
    [(I8) "vpmovsxbd"]
    [(U8) "vpmovzxbd"]
    [_ ""]))

;; AVX2 has no per-word variable shift. Widen the low and high 128-bit word
;; groups to dwords, use the native dword shift, mask each result to its exact
;; low 16 bits, then pack. `vpackusdw` interleaves its two inputs inside each
;; 128-bit sublane, so the final qword permutation restores source lane order.
(define (compiler-backend-emit-avx2-word-vector-shift
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [elem-ty : compiler_ast_types.AstType]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [vector-bytes : i64 32]
    [group-bytes : i64 16]
    [result-base : i64 64]
    [move : String
      (be_operand.compiler-backend-vector-move-for-width "ymm" elem-ty)]
    [dword-move : String
      (let
        [elem-ty (compiler_ast_types.AstType.I32)]
        (be_operand.compiler-backend-vector-move-for-width "ymm" elem-ty))]
    [widen : String (compiler-backend-narrow-vector-widen-mnemonic elem-ty)]
    [shift : String (compiler-backend-narrow-vector-shift-mnemonic op elem-ty)]
    [tmp0 : String "%ymm0"]
    [tmp1 : String "%ymm1"]
    (match (be_operand.compiler-backend-vector-register-use
      assignments
      lhs
      "word shift lhs"
      "ymm"
      elem-ty
      (be_operand.compiler-backend-vector-spill-scratch "ymm" 0)
      backend-state)
      [(Ok lhs-use)
        (match lhs-use
          [(Use lhs-asm lhs-reg)
            (match (be_operand.compiler-backend-vector-register-use
              assignments
              rhs
              "word shift rhs"
              "ymm"
              elem-ty
              (be_operand.compiler-backend-vector-spill-scratch "ymm" 1)
              backend-state)
              [(Ok rhs-use)
                (match rhs-use
                  [(Use rhs-asm rhs-reg)
                    (match (compiler-backend-vector-dst-reg
                      assignments
                      dst
                      "word shift dst"
                      "ymm"
                      (be_operand.compiler-backend-vector-spill-scratch "ymm" 0)
                      backend-state)
                      [(Ok dst-reg)
                        (let
                          [groups : String ""]
                          (for [group (iterator.range 0 2)]
                            (let
                              [word-offset : i64 (* group group-bytes)]
                              [result-offset : i64
                                (+ result-base (* group vector-bytes))]
                              (set!
                                groups
                                (str_cat.str-cat
                                  groups
                                  "    "
                                  widen
                                  " "
                                  (be_operand.compiler-backend-simd-scratch-address
                                    backend-state
                                    word-offset)
                                  ", "
                                  tmp0
                                  "\n    "
                                  widen
                                  " "
                                  (be_operand.compiler-backend-simd-scratch-address
                                    backend-state
                                    (+ vector-bytes word-offset))
                                  ", "
                                  tmp1
                                  "\n    "
                                  shift
                                  " "
                                  tmp1
                                  ", "
                                  tmp0
                                  ", "
                                  tmp0
                                  "\n    "
                                  dword-move
                                  " "
                                  tmp0
                                  ", "
                                  (be_operand.compiler-backend-simd-scratch-address
                                    backend-state
                                    result-offset)
                                  "\n"))))
                          (be_operand.compiler-backend-simd-scratch-checked
                            backend-state
                            instr-diag
                            be_operand.compiler-backend-simd-scratch-word-shift-bytes
                            (Ok
                              (str_cat.str-cat
                                lhs-asm
                                rhs-asm
                                "    "
                                move
                                " "
                                lhs-reg
                                ", "
                                (be_operand.compiler-backend-simd-scratch-address
                                  backend-state
                                  0)
                                "\n    "
                                move
                                " "
                                rhs-reg
                                ", "
                                (be_operand.compiler-backend-simd-scratch-address
                                  backend-state
                                  vector-bytes)
                                "\n"
                                groups
                                "    vpcmpeqd "
                                tmp0
                                ", "
                                tmp0
                                ", "
                                tmp0
                                "\n    vpsrld $16, "
                                tmp0
                                ", "
                                tmp0
                                "\n    "
                                dword-move
                                " "
                                (be_operand.compiler-backend-simd-scratch-address
                                  backend-state
                                  result-base)
                                ", "
                                tmp1
                                "\n    vpand "
                                tmp0
                                ", "
                                tmp1
                                ", "
                                tmp1
                                "\n    "
                                dword-move
                                " "
                                (be_operand.compiler-backend-simd-scratch-address
                                  backend-state
                                  (+ result-base vector-bytes))
                                ", "
                                dst-reg
                                "\n    vpand "
                                tmp0
                                ", "
                                dst-reg
                                ", "
                                dst-reg
                                "\n    vpackusdw "
                                dst-reg
                                ", "
                                tmp1
                                ", "
                                tmp1
                                "\n    vpermq $216, "
                                tmp1
                                ", "
                                dst-reg
                                "\n"
                                (compiler-backend-vector-store-dst
                                  assignments
                                  dst
                                  "ymm"
                                  elem-ty
                                  dst-reg
                                  backend-state)))))]
                      [(Err message)
                        (be_state.compiler-backend-instr-error
                          instr-diag
                          message)])])]
              [(Err message)
                (be_state.compiler-backend-instr-error instr-diag message)])])]
      [(Err message) (be_state.compiler-backend-instr-error instr-diag message)])))

;; x86 has no per-byte variable shift. Widen four byte groups to dwords, use
;; the native dword shift, then pack the low byte of every result. The pack is
;; exact rather than saturating because each dword is masked to 0..255 first.
;; A final dword permutation transposes the four 128-bit pack groups back to
;; source byte order across every 128-bit boundary.
(define (compiler-backend-emit-byte-vector-shift
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [elem-ty : compiler_ast_types.AstType]
  [width : String]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [avx512 : bool (string.eq width "zmm")]
    [vector-bytes : i64
      (if avx512
        64
        32)]
    [group-bytes : i64 (/ vector-bytes 4)]
    [group-base : i64 (* vector-bytes 2)]
    [index-offset : i64 (* vector-bytes 6)]
    [stack-bytes : i64
      (be_operand.compiler-backend-simd-scratch-byte-shift-bytes vector-bytes)]
    [move : String
      (be_operand.compiler-backend-vector-move-for-width width elem-ty)]
    [dword-move : String
      (let
        [elem-ty (compiler_ast_types.AstType.I32)]
        (be_operand.compiler-backend-vector-move-for-width width elem-ty))]
    [widen : String (compiler-backend-narrow-vector-widen-mnemonic elem-ty)]
    [shift : String (compiler-backend-narrow-vector-shift-mnemonic op elem-ty)]
    [tmp0 : String
      (if avx512
        "%zmm0"
        "%ymm0")]
    [tmp1 : String
      (if avx512
        "%zmm1"
        "%ymm1")]
    [bit-and : String
      (if avx512
        "vpandd"
        "vpand")]
    [bit-or : String
      (if avx512
        "vpord"
        "vpor")]
    (match (be_operand.compiler-backend-vector-register-use
      assignments
      lhs
      "byte shift lhs"
      (be_state.compiler-backend-global-shared-view width)
      elem-ty
      (be_operand.compiler-backend-vector-spill-scratch width 0)
      backend-state)
      [(Ok lhs-use)
        (match lhs-use
          [(Use lhs-asm lhs-reg)
            (match (be_operand.compiler-backend-vector-register-use
              assignments
              rhs
              "byte shift rhs"
              (be_state.compiler-backend-global-shared-view width)
              elem-ty
              (be_operand.compiler-backend-vector-spill-scratch width 1)
              backend-state)
              [(Ok rhs-use)
                (match rhs-use
                  [(Use rhs-asm rhs-reg)
                    (match (compiler-backend-vector-dst-reg
                      assignments
                      dst
                      "byte shift dst"
                      (be_state.compiler-backend-global-shared-view width)
                      (be_operand.compiler-backend-vector-spill-scratch width 0)
                      backend-state)
                      [(Ok dst-reg)
                        (let
                          [groups : String ""]
                          (for [group (iterator.range 0 4)]
                            (let
                              [byte-offset : i64 (* group group-bytes)]
                              [result-offset : i64
                                (+ group-base (* group vector-bytes))]
                              (set!
                                groups
                                (str_cat.str-cat
                                  groups
                                  "    "
                                  widen
                                  " "
                                  (be_operand.compiler-backend-simd-scratch-address
                                    backend-state
                                    byte-offset)
                                  ", "
                                  tmp0
                                  "\n    "
                                  widen
                                  " "
                                  (be_operand.compiler-backend-simd-scratch-address
                                    backend-state
                                    (+ vector-bytes byte-offset))
                                  ", "
                                  tmp1
                                  "\n    "
                                  shift
                                  " "
                                  tmp1
                                  ", "
                                  tmp0
                                  ", "
                                  tmp0
                                  "\n    "
                                  dword-move
                                  " "
                                  tmp0
                                  ", "
                                  (be_operand.compiler-backend-simd-scratch-address
                                    backend-state
                                    result-offset)
                                  "\n"))))
                          (be_operand.compiler-backend-simd-scratch-checked
                            backend-state
                            instr-diag
                            stack-bytes
                            (Ok
                              (str_cat.str-cat
                                lhs-asm
                                rhs-asm
                                "    "
                                move
                                " "
                                lhs-reg
                                ", "
                                (be_operand.compiler-backend-simd-scratch-address
                                  backend-state
                                  0)
                                "\n    "
                                move
                                " "
                                rhs-reg
                                ", "
                                (be_operand.compiler-backend-simd-scratch-address
                                  backend-state
                                  vector-bytes)
                                "\n"
                                groups
                                (if avx512
                                  (str_cat.str-cat
                                    "    vpternlogd $255, "
                                    tmp0
                                    ", "
                                    tmp0
                                    ", "
                                    tmp0
                                    "\n")
                                  (str_cat.str-cat
                                    "    vpcmpeqd "
                                    tmp0
                                    ", "
                                    tmp0
                                    ", "
                                    tmp0
                                    "\n"))
                                "    vpsrld $24, "
                                tmp0
                                ", "
                                tmp0
                                "\n    "
                                dword-move
                                " "
                                (be_operand.compiler-backend-simd-scratch-address
                                  backend-state
                                  group-base)
                                ", "
                                tmp1
                                "\n    "
                                bit-and
                                " "
                                tmp0
                                ", "
                                tmp1
                                ", "
                                tmp1
                                "\n    "
                                dword-move
                                " "
                                (be_operand.compiler-backend-simd-scratch-address
                                  backend-state
                                  (+ group-base vector-bytes))
                                ", "
                                dst-reg
                                "\n    "
                                bit-and
                                " "
                                tmp0
                                ", "
                                dst-reg
                                ", "
                                dst-reg
                                "\n    vpackusdw "
                                dst-reg
                                ", "
                                tmp1
                                ", "
                                tmp1
                                "\n    "
                                dword-move
                                " "
                                tmp1
                                ", "
                                (be_operand.compiler-backend-simd-scratch-address
                                  backend-state
                                  group-base)
                                "\n    "
                                dword-move
                                " "
                                (be_operand.compiler-backend-simd-scratch-address
                                  backend-state
                                  (+ group-base (* vector-bytes 2)))
                                ", "
                                tmp1
                                "\n    "
                                bit-and
                                " "
                                tmp0
                                ", "
                                tmp1
                                ", "
                                tmp1
                                "\n    "
                                dword-move
                                " "
                                (be_operand.compiler-backend-simd-scratch-address
                                  backend-state
                                  (+ group-base (* vector-bytes 3)))
                                ", "
                                dst-reg
                                "\n    "
                                bit-and
                                " "
                                tmp0
                                ", "
                                dst-reg
                                ", "
                                dst-reg
                                "\n    vpackusdw "
                                dst-reg
                                ", "
                                tmp1
                                ", "
                                tmp1
                                "\n    "
                                dword-move
                                " "
                                tmp1
                                ", "
                                (be_operand.compiler-backend-simd-scratch-address
                                  backend-state
                                  (+ group-base vector-bytes))
                                "\n    "
                                dword-move
                                " "
                                (be_operand.compiler-backend-simd-scratch-address
                                  backend-state
                                  group-base)
                                ", "
                                tmp1
                                "\n    "
                                dword-move
                                " "
                                (be_operand.compiler-backend-simd-scratch-address
                                  backend-state
                                  (+ group-base vector-bytes))
                                ", "
                                dst-reg
                                "\n    vpackuswb "
                                dst-reg
                                ", "
                                tmp1
                                ", "
                                tmp1
                                "\n    movl $50462976, "
                                (be_operand.compiler-backend-simd-scratch-address
                                  backend-state
                                  index-offset)
                                "\n    movl $117835012, "
                                (be_operand.compiler-backend-simd-scratch-address
                                  backend-state
                                  (+ index-offset 4))
                                (if avx512
                                  (str_cat.str-cat
                                    "\n    movl $185207048, "
                                    (be_operand.compiler-backend-simd-scratch-address
                                      backend-state
                                      (+ index-offset 8))
                                    "\n    movl $252579084, "
                                    (be_operand.compiler-backend-simd-scratch-address
                                      backend-state
                                      (+ index-offset 12)))
                                  "")
                                "\n    vpmovzxbd "
                                (be_operand.compiler-backend-simd-scratch-address
                                  backend-state
                                  index-offset)
                                ", "
                                tmp0
                                "\n    "
                                dword-move
                                " "
                                tmp0
                                ", "
                                dst-reg
                                "\n    vpsrld $"
                                (if avx512
                                  "2"
                                  "1")
                                ", "
                                tmp0
                                ", "
                                tmp0
                                "\n    vpslld $"
                                (if avx512
                                  "30"
                                  "31")
                                ", "
                                dst-reg
                                ", "
                                dst-reg
                                "\n    vpsrld $"
                                (if avx512
                                  "28"
                                  "29")
                                ", "
                                dst-reg
                                ", "
                                dst-reg
                                "\n    "
                                bit-or
                                " "
                                dst-reg
                                ", "
                                tmp0
                                ", "
                                tmp0
                                "\n    vpermd "
                                tmp1
                                ", "
                                tmp0
                                ", "
                                dst-reg
                                "\n"
                                (compiler-backend-vector-store-dst
                                  assignments
                                  dst
                                  width
                                  elem-ty
                                  dst-reg
                                  backend-state)))))]
                      [(Err message)
                        (be_state.compiler-backend-instr-error
                          instr-diag
                          message)])])]
              [(Err message)
                (be_state.compiler-backend-instr-error instr-diag message)])])]
      [(Err message) (be_state.compiler-backend-instr-error instr-diag message)])))

;; x86 has no packed byte multiply. Treat every adjacent byte pair as a word:
;; multiply the low bytes directly, multiply the high bytes after shifting them
;; down, discard each product's high byte, and stitch the two byte products back
;; together. Signed and unsigned multiplication have identical modulo-2^8 bits.
(define (compiler-backend-emit-byte-vector-mul
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [elem-ty : compiler_ast_types.AstType]
  [width : String]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [sse2? : bool (string.eq width "xmm")]
    [tmp0 : String
      (cond [(string.eq width "zmm") "%zmm0"] [sse2? "%xmm0"] [else "%ymm0"])]
    [tmp1 : String
      (cond [(string.eq width "zmm") "%zmm1"] [sse2? "%xmm1"] [else "%ymm1"])]
    [bit-or : String
      (if (string.eq width "zmm")
        "vpord"
        "vpor")]
    (match (be_operand.compiler-backend-vector-register-use
      assignments
      lhs
      "byte multiply lhs"
      (be_state.compiler-backend-global-shared-view width)
      elem-ty
      (be_operand.compiler-backend-vector-spill-scratch width 0)
      backend-state)
      [(Ok lhs-use)
        (match lhs-use
          [(Use lhs-asm lhs-reg)
            (match (be_operand.compiler-backend-vector-register-use
              assignments
              rhs
              "byte multiply rhs"
              (be_state.compiler-backend-global-shared-view width)
              elem-ty
              (be_operand.compiler-backend-vector-spill-scratch width 1)
              backend-state)
              [(Ok rhs-use)
                (match rhs-use
                  [(Use rhs-asm rhs-reg)
                    (match (compiler-backend-vector-dst-reg
                      assignments
                      dst
                      "byte multiply dst"
                      (be_state.compiler-backend-global-shared-view width)
                      (be_operand.compiler-backend-vector-spill-scratch width 0)
                      backend-state)
                      [(Ok dst-reg)
                        (Ok
                          (if sse2?
                            (str_cat.str-cat
                              lhs-asm
                              rhs-asm
                              "    movdqa "
                              lhs-reg
                              ", %xmm0\n    psrlw $8, %xmm0\n    movdqa "
                              rhs-reg
                              ", %xmm1\n    psrlw $8, %xmm1\n    pmullw %xmm1, %xmm0\n    psllw $8, %xmm0\n    movdqa "
                              lhs-reg
                              ", %xmm1\n    pmullw "
                              rhs-reg
                              ", %xmm1\n    psllw $8, %xmm1\n    psrlw $8, %xmm1\n    por %xmm1, %xmm0\n    movdqa %xmm0, "
                              dst-reg
                              "\n"
                              (compiler-backend-vector-store-dst
                                assignments
                                dst
                                width
                                elem-ty
                                dst-reg
                                backend-state))
                            (str_cat.str-cat
                              lhs-asm
                              rhs-asm
                              "    vpsrlw $8, "
                              lhs-reg
                              ", "
                              tmp0
                              "\n    vpsrlw $8, "
                              rhs-reg
                              ", "
                              tmp1
                              "\n    vpmullw "
                              tmp1
                              ", "
                              tmp0
                              ", "
                              tmp0
                              "\n    vpsllw $8, "
                              tmp0
                              ", "
                              tmp0
                              "\n    vpmullw "
                              rhs-reg
                              ", "
                              lhs-reg
                              ", "
                              dst-reg
                              "\n    vpsllw $8, "
                              dst-reg
                              ", "
                              dst-reg
                              "\n    vpsrlw $8, "
                              dst-reg
                              ", "
                              dst-reg
                              "\n    "
                              bit-or
                              " "
                              tmp0
                              ", "
                              dst-reg
                              ", "
                              dst-reg
                              "\n"
                              (compiler-backend-vector-store-dst
                                assignments
                                dst
                                width
                                elem-ty
                                dst-reg
                                backend-state))))]
                      [(Err message)
                        (be_state.compiler-backend-instr-error
                          instr-diag
                          message)])])]
              [(Err message)
                (be_state.compiler-backend-instr-error instr-diag message)])])]
      [(Err message) (be_state.compiler-backend-instr-error instr-diag message)])))

(define (compiler-backend-simd-offset-address [base-reg : String] [disp : i64]) : String
  ;; GAP7: route through the SIB-aware base formatter (inert unless a %rbp pool
  ;; value ever reaches here as a vector base).
  (be_operand.compiler-backend-mem-base-address disp base-reg))

(define (compiler-backend-simd-index-register-address
  [type-segment-bases : i64]
  [base-reg : String]
  [index-reg : String]
  [elem-ty : compiler_ast_types.AstType]) : String
  (str_cat.str-cat
    "("
    base-reg
    ","
    index-reg
    ","
    (string.int->string
      (be_operand.compiler-backend-type-size type-segment-bases elem-ty))
    ")"))

(define (compiler-backend-simd-base-home
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [base : compiler_ir_types.CompilerIrValue]) : String
  (match base
    [(Var id)
      (if (>=
        (be_operand.compiler-backend-forwarded-addr-of-src backend-state id)
        0)
        ""
        (match (be_operand.compiler-backend-emit-assignment-lookup
          backend-state
          assignments
          id)
          [(Some location)
            (match location
              [(Register home)
                (compiler_abi.compiler-abi-register-spelling home)]
              [_ ""])]
          [(No) ""]))]
    [_ ""]))

(define (compiler-backend-simd-index-home
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [index : compiler_ir_types.CompilerIrValue]) : String
  (match index
    [(Var id)
      (if (>=
        (be_operand.compiler-backend-forwarded-addr-of-src backend-state id)
        0)
        ""
        (match (be_operand.compiler-backend-emit-assignment-lookup
          backend-state
          assignments
          id)
          [(Some location)
            (match location
              [(Register home)
                (if (= home compiler_abi.compiler-reg-id-rsp)
                  ""
                  (compiler_abi.compiler-abi-register-spelling home))]
              [_ ""])]
          [(No) ""]))]
    [_ ""]))

(define (compiler-backend-emit-simd-base-data-pointer
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [base : compiler_ir_types.CompilerIrValue]
  [base-reg : String]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [home : String
      (compiler-backend-simd-base-home
        backend-state
        assignments
        (be_state.compiler-backend-global-shared-view base))]
    (if (string.eq home "")
      (be_operand.compiler-backend-emit-load-value
        assignments
        base
        base-reg
        backend-state)
      (if (string.eq home base-reg)
        (Ok "")
        (Ok (str_cat.str-cat "    movq " home ", " base-reg "\n"))))))

(define (compiler-backend-emit-simd-indexed-address
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [base : compiler_ir_types.CompilerIrValue]
  [index : compiler_ir_types.CompilerIrValue]
  [elem-ty : compiler_ast_types.AstType]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackendSimdIndexedAddress
  (let
    [base-home : String
      (compiler-backend-simd-base-home
        backend-state
        assignments
        (be_state.compiler-backend-global-shared-view base))]
    [addr-exclude : (__tl_dyn-array String)
      (be_operand.compiler-backend-scavenge-exclude-ops2
        backend-state
        assignments
        (be_state.compiler-backend-global-shared-view base)
        index)]
    [base-reg : String
      (if (string.eq base-home "")
        (be_operand.compiler-backend-scavenge-reg-here
          (be_state.compiler-backend-global-shared-view addr-exclude)
          7
          "%r8"
          backend-state)
        base-home)]
    (match (be_operand.compiler-backend-value-as-i64 index)
      [(Some n)
        (let
          [base-asm
            (try
              (compiler-backend-emit-simd-base-data-pointer
                assignments
                base
                (be_state.compiler-backend-global-shared-view base-reg)
                backend-state))]
          (Ok
            (be_state.CompilerBackendSimdIndexedAddress
              base-asm
              (compiler-backend-simd-offset-address
                base-reg
                (*
                  n
                  (be_operand.compiler-backend-type-size
                    type-segment-bases
                    elem-ty))))))]
      [(None)
        (let
          [index-home : String
            (compiler-backend-simd-index-home
              backend-state
              assignments
              (be_state.compiler-backend-global-shared-view index))]
          [index-exclude : (__tl_dyn-array String)
            (be_operand.compiler-backend-scavenge-exclude-append
              addr-exclude
              7
              (be_state.compiler-backend-global-shared-view base-reg))]
          [index-reg : String
            (if (string.eq index-home "")
              (be_operand.compiler-backend-scavenge-reg-here
                index-exclude
                8
                "%r9"
                backend-state)
              (owned_view.compiler-owned-shared-view index-home))]
          [base-asm
            (try
              (compiler-backend-emit-simd-base-data-pointer
                assignments
                base
                (be_state.compiler-backend-global-shared-view base-reg)
                backend-state))]
          (if (string.eq index-home "")
            (let
              [index-asm
                (try
                  (be_operand.compiler-backend-emit-load-value
                    assignments
                    index
                    (be_state.compiler-backend-global-shared-view index-reg)
                    backend-state))]
              (Ok
                (be_state.CompilerBackendSimdIndexedAddress
                  (str_cat.str-cat base-asm index-asm)
                  (compiler-backend-simd-index-register-address
                    type-segment-bases
                    base-reg
                    index-reg
                    elem-ty))))
            (Ok
              (be_state.CompilerBackendSimdIndexedAddress
                base-asm
                (compiler-backend-simd-index-register-address
                  type-segment-bases
                  base-reg
                  index-reg
                  elem-ty)))))])))

(define (compiler-backend-emit-vector-load
  [mode : be_state.CompilerBackendMode]
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [base : compiler_ir_types.CompilerIrValue]
  [index : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (be_operand.compiler-backend-mode-shape-ok? mode elem-ty lanes)
    (match (compiler-backend-vector-dst-reg
      assignments
      dst
      "load dst"
      (compiler-backend-mode-width mode)
      (be_operand.compiler-backend-vector-spill-scratch
        (compiler-backend-mode-width mode)
        0)
      backend-state)
      [(Ok dst-reg)
        (match (compiler-backend-emit-simd-indexed-address
          type-segment-bases
          assignments
          base
          index
          (be_state.compiler-backend-global-shared-view elem-ty)
          backend-state)
          [(Ok addr-plan)
            (let
              [addr-asm : String addr-plan.asm]
              [addr : String addr-plan.addr]
              (Ok
                (str_cat.str-cat
                  addr-asm
                  (str_cat.str-cat
                    "    "
                    (compiler-backend-mode-vector-move mode elem-ty)
                    " "
                    addr
                    ", ")
                  (str_cat.str-cat
                    dst-reg
                    "\n"
                    (compiler-backend-vector-store-dst
                      assignments
                      dst
                      (compiler-backend-mode-width mode)
                      elem-ty
                      dst-reg
                      backend-state)))))]
          [(Err message)
            (be_state.compiler-backend-instr-error-from instr-diag message)])]
      [(Err message) (be_state.compiler-backend-instr-error instr-diag message)])
    (compiler-backend-mode-shape-diagnostic
      mode
      type-segment-bases
      instr-diag
      elem-ty
      lanes)))

(define (compiler-backend-stack-memory-operand
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]
  [backend-state : be_state.CompilerBackendState]) : be_state.CompilerBackendMaybeStackOperand
  (match value
    [(Var var-id)
      (if (>=
        (be_operand.compiler-backend-forwarded-addr-of-src backend-state var-id)
        0)
        (No)
        (match (be_operand.compiler-backend-emit-assignment-lookup
          backend-state
          assignments
          var-id)
          [(Some location)
            (match location
              [(Spill offset)
                (Some
                  (be_operand.compiler-backend-frame-offset-with-backend-state
                    backend-state
                    offset))]
              [_ (No)])]
          [(No)
            (Some
              (be_operand.compiler-backend-slot-with-backend-state
                backend-state
                var-id))]))]
    [_ (No)]))

(define (compiler-backend-splat-memory-mnemonic
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]) : String
  (match elem-ty
    [(F64) "vbroadcastsd"]
    [(F32) "vbroadcastss"]
    [(or (I32) (U32)) "vpbroadcastd"]
    [(or (I16) (U16)) "vpbroadcastw"]
    [(or (I8) (U8)) "vpbroadcastb"]
    [_ "vpbroadcastq"]))

(define (compiler-backend-splat-memory-load
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]
  [backend-state : be_state.CompilerBackendState]) : be_state.CompilerBackendMaybeAsm
  (match (compiler-backend-stack-memory-operand assignments value backend-state)
    [(Some operand)
      (Some
        (str_cat.str-cat
          "    "
          (compiler-backend-splat-memory-mnemonic elem-ty)
          " "
          operand
          ", "))]
    [(No) (No)]))

;; AVX-512 broadcasts a GPR directly; AVX2 moves it into XMM first.
(define (compiler-backend-simd-splat-gpr-asm
  [mode : be_state.CompilerBackendMode]
  [asm : String]
  [move : String]
  [broadcast : String]
  [gp : String]
  [xmm : String]) : String
  (match mode
    [(Avx512) (str_cat.str-cat asm "    " broadcast " " gp ", ")]
    [_
      (str_cat.str-cat
        asm
        "    "
        move
        " "
        gp
        ", "
        xmm
        "\n    "
        broadcast
        " "
        xmm
        ", ")]))

(define (compiler-backend-simd-splat-load
  [mode : be_state.CompilerBackendMode]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [value : compiler_ir_types.CompilerIrValue]
  [elem-ty : compiler_ast_types.AstType]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (match (compiler-backend-splat-memory-load
    assignments
    (be_state.compiler-backend-global-shared-view value)
    elem-ty
    backend-state)
    [(Some asm) (Ok asm)]
    [(No)
      (let
        [no-exclude : (__tl_dyn-array String) (__tl_make-array String 0)]
        [gp-reg : String
          (be_operand.compiler-backend-scavenge-reg
            dst
            (be_state.compiler-backend-global-shared-view no-exclude)
            0
            "%r8"
            backend-state)]
        [gp32 : String
          (be_operand.compiler-backend-reg-part
            (be_state.compiler-backend-global-shared-view gp-reg)
            4)]
        [xmm-reg : String
          (be_operand.compiler-backend-scavenge-xmm-reg
            dst
            no-exclude
            0
            "%xmm2"
            backend-state)]
        (match (& elem-ty)
          [(F64)
            (let
              [asm
                (try
                  (be_operand.compiler-backend-emit-load-float-value
                    assignments
                    value
                    elem-ty
                    (be_state.compiler-backend-global-shared-view xmm-reg)
                    backend-state))]
              (Ok (str_cat.str-cat asm "    vbroadcastsd " xmm-reg ", ")))]
          [(F32)
            (let
              [asm
                (try
                  (be_operand.compiler-backend-emit-load-float-value
                    assignments
                    value
                    elem-ty
                    (be_state.compiler-backend-global-shared-view xmm-reg)
                    backend-state))]
              (Ok (str_cat.str-cat asm "    vbroadcastss " xmm-reg ", ")))]
          [(or (I32) (U32))
            (let
              [asm
                (try
                  (be_operand.compiler-backend-emit-load-value
                    assignments
                    value
                    gp-reg
                    backend-state))]
              (Ok
                (compiler-backend-simd-splat-gpr-asm
                  mode
                  asm
                  "vmovd"
                  "vpbroadcastd"
                  gp32
                  xmm-reg)))]
          [(or (I16) (U16))
            (let
              [asm
                (try
                  (be_operand.compiler-backend-emit-load-value
                    assignments
                    value
                    gp-reg
                    backend-state))]
              (Ok
                (str_cat.str-cat
                  asm
                  "    vmovd "
                  gp32
                  ", "
                  xmm-reg
                  "\n    vpbroadcastw "
                  xmm-reg
                  ", ")))]
          [(or (I8) (U8))
            (let
              [asm
                (try
                  (be_operand.compiler-backend-emit-load-value
                    assignments
                    value
                    gp-reg
                    backend-state))]
              (Ok
                (str_cat.str-cat
                  asm
                  "    vmovd "
                  gp32
                  ", "
                  xmm-reg
                  "\n    vpbroadcastb "
                  xmm-reg
                  ", ")))]
          [_
            (let
              [asm
                (try
                  (be_operand.compiler-backend-emit-load-value
                    assignments
                    value
                    (be_state.compiler-backend-global-shared-view gp-reg)
                    backend-state))]
              (Ok
                (compiler-backend-simd-splat-gpr-asm
                  mode
                  asm
                  "vmovq"
                  "vpbroadcastq"
                  gp-reg
                  xmm-reg)))]))]))

(define (compiler-backend-copy-prim-ast-type
  [ty : (& ty compiler_ast_types.AstType)]) : compiler_ast_types.AstType
  (match ty
    [(I8) (I8)]
    [(U8) (U8)]
    [(I16) (I16)]
    [(U16) (U16)]
    [(I32) (I32)]
    [(U32) (U32)]
    [(I64) (I64)]
    [(U64) (U64)]
    [(F32) (F32)]
    [(F64) (F64)]
    [(Bool) (Bool)]
    [_ (I64)]))

(define (compiler-backend-emit-sse2-splat-body
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [value : compiler_ir_types.CompilerIrValue]
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]
  [dst-reg : (& dst-reg str)]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (match elem-ty
    [(F64)
      (let
        [asm
          (try
            (be_operand.compiler-backend-emit-load-float-value
              assignments
              value
              elem-ty
              (string.copy dst-reg)
              backend-state))]
        (Ok (str_cat.str-cat asm "    unpcklpd " dst-reg ", " dst-reg "\n")))]
    [(F32)
      (let
        [asm
          (try
            (be_operand.compiler-backend-emit-load-float-value
              assignments
              value
              elem-ty
              (string.copy dst-reg)
              backend-state))]
        (Ok (str_cat.str-cat asm "    shufps $0, " dst-reg ", " dst-reg "\n")))]
    [_
      (match (be_operand.compiler-backend-value-as-i64 (& value))
        [(Some 0) (Ok (str_cat.str-cat "    pxor " dst-reg ", " dst-reg "\n"))]
        [(Some -1)
          (Ok (str_cat.str-cat "    pcmpeqd " dst-reg ", " dst-reg "\n"))]
        [_
          (let
            [no-exclude : (__tl_dyn-array String) (__tl_make-array String 0)]
            [gp-reg : String
              (be_operand.compiler-backend-scavenge-reg
                dst
                no-exclude
                0
                "%r8"
                backend-state)]
            [gp32 : String
              (be_operand.compiler-backend-reg-part (string.copy (& gp-reg)) 4)]
            (match elem-ty
              [(or (I32) (U32))
                (let
                  [asm
                    (try
                      (be_operand.compiler-backend-emit-load-value
                        assignments
                        value
                        gp-reg
                        backend-state))]
                  (Ok
                    (str_cat.str-cat
                      asm
                      "    movd "
                      gp32
                      ", "
                      dst-reg
                      "\n    pshufd $0, "
                      dst-reg
                      ", "
                      dst-reg
                      "\n")))]
              [(or (I16) (U16))
                (let
                  [asm
                    (try
                      (be_operand.compiler-backend-emit-load-value
                        assignments
                        value
                        gp-reg
                        backend-state))]
                  (Ok
                    (str_cat.str-cat
                      asm
                      "    movd "
                      gp32
                      ", "
                      dst-reg
                      "\n    punpcklwd "
                      dst-reg
                      ", "
                      dst-reg
                      "\n    pshufd $0, "
                      dst-reg
                      ", "
                      dst-reg
                      "\n")))]
              [(or (I8) (U8))
                (let
                  [asm
                    (try
                      (be_operand.compiler-backend-emit-load-value
                        assignments
                        value
                        gp-reg
                        backend-state))]
                  (Ok
                    (str_cat.str-cat
                      asm
                      "    movd "
                      gp32
                      ", "
                      dst-reg
                      "\n    punpcklbw "
                      dst-reg
                      ", "
                      dst-reg
                      "\n    punpcklwd "
                      dst-reg
                      ", "
                      dst-reg
                      "\n    pshufd $0, "
                      dst-reg
                      ", "
                      dst-reg
                      "\n")))]
              [_
                (match (compiler-backend-stack-memory-operand
                  assignments
                  (compiler-backend-simd-ir-value-copy (& value))
                  backend-state)
                  [(Some operand)
                    (Ok
                      (str_cat.str-cat
                        "    movq "
                        operand
                        ", "
                        dst-reg
                        "\n    punpcklqdq "
                        dst-reg
                        ", "
                        dst-reg
                        "\n"))]
                  [(No)
                    (let
                      [asm
                        (try
                          (be_operand.compiler-backend-emit-load-value
                            assignments
                            value
                            (string.copy (& gp-reg))
                            backend-state))]
                      (Ok
                        (str_cat.str-cat
                          asm
                          "    movq "
                          gp-reg
                          ", "
                          dst-reg
                          "\n    punpcklqdq "
                          dst-reg
                          ", "
                          dst-reg
                          "\n")))])]))])]))

(define (compiler-backend-emit-vector-splat
  [mode : be_state.CompilerBackendMode]
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [value : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (be_operand.compiler-backend-mode-shape-ok? mode elem-ty lanes)
    (match (compiler-backend-vector-dst-reg
      assignments
      dst
      "splat dst"
      (compiler-backend-mode-width mode)
      (be_operand.compiler-backend-vector-spill-scratch
        (compiler-backend-mode-width mode)
        0)
      backend-state)
      [(Ok dst-reg)
        (if (be_state.compiler-backend-mode-sse2? mode)
          (match (compiler-backend-emit-sse2-splat-body
            assignments
            dst
            value
            (& elem-ty)
            (& dst-reg)
            backend-state)
            [(Ok body-asm)
              (Ok
                (str_cat.str-cat
                  body-asm
                  (compiler-backend-vector-store-dst
                    assignments
                    dst
                    "xmm"
                    elem-ty
                    dst-reg
                    backend-state)))]
            [(Err message)
              (be_state.compiler-backend-instr-error-from instr-diag message)])
          (match (compiler-backend-simd-splat-load
            mode
            assignments
            dst
            value
            (be_state.compiler-backend-global-shared-view elem-ty)
            backend-state)
            [(Ok load-asm)
              (Ok
                (str_cat.str-cat
                  load-asm
                  dst-reg
                  "\n"
                  (compiler-backend-vector-store-dst
                    assignments
                    dst
                    (compiler-backend-mode-width mode)
                    elem-ty
                    dst-reg
                    backend-state)))]
            [(Err message)
              (be_state.compiler-backend-instr-error-from instr-diag message)]))]
      [(Err message) (be_state.compiler-backend-instr-error instr-diag message)])
    (compiler-backend-mode-shape-diagnostic
      mode
      type-segment-bases
      instr-diag
      elem-ty
      lanes)))

(define (compiler-backend-emit-sse2-i64-vector-mul
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (match (let
    [elem-ty (compiler_ast_types.AstType.I64)]
    (be_operand.compiler-backend-vector-register-use
      assignments
      lhs
      "lhs"
      "xmm"
      elem-ty
      (be_operand.compiler-backend-vector-spill-scratch "xmm" 0)
      backend-state))
    [(Ok lhs-use)
      (match lhs-use
        [(Use lhs-asm lhs-reg)
          (match (let
            [elem-ty (compiler_ast_types.AstType.I64)]
            (be_operand.compiler-backend-vector-register-use
              assignments
              rhs
              "rhs"
              "xmm"
              elem-ty
              (be_operand.compiler-backend-vector-spill-scratch "xmm" 1)
              backend-state))
            [(Ok rhs-use)
              (match rhs-use
                [(Use rhs-asm rhs-reg)
                  (match (compiler-backend-vector-dst-reg
                    assignments
                    dst
                    "binop dst"
                    "xmm"
                    (be_operand.compiler-backend-vector-spill-scratch "xmm" 0)
                    backend-state)
                    [(Ok dst-reg)
                      (let
                        [lo-asm : String
                          (cond
                            [(string.eq dst-reg lhs-reg)
                              (str_cat.str-cat
                                "    pmuludq "
                                rhs-reg
                                ", "
                                dst-reg
                                "\n    paddq %xmm0, "
                                dst-reg
                                "\n")]
                            [(string.eq dst-reg rhs-reg)
                              (str_cat.str-cat
                                "    pmuludq "
                                lhs-reg
                                ", "
                                dst-reg
                                "\n    paddq %xmm0, "
                                dst-reg
                                "\n")]
                            [else
                              (str_cat.str-cat
                                "    movdqa "
                                lhs-reg
                                ", "
                                dst-reg
                                "\n    pmuludq "
                                rhs-reg
                                ", "
                                dst-reg
                                "\n    paddq %xmm0, "
                                dst-reg
                                "\n")])]
                        (Ok
                          (str_cat.str-cat
                            lhs-asm
                            rhs-asm
                            "    movdqa "
                            lhs-reg
                            ", %xmm0\n    psrlq $32, %xmm0\n    pmuludq "
                            rhs-reg
                            ", %xmm0\n    movdqa "
                            rhs-reg
                            ", %xmm1\n    psrlq $32, %xmm1\n    pmuludq "
                            lhs-reg
                            ", %xmm1\n    paddq %xmm1, %xmm0\n    psllq $32, %xmm0\n"
                            lo-asm
                            (compiler-backend-vector-store-dst
                              assignments
                              dst
                              "xmm"
                              (I64)
                              dst-reg
                              backend-state))))]
                    [(Err message)
                      (be_state.compiler-backend-instr-error instr-diag message)])])]
            [(Err message)
              (be_state.compiler-backend-instr-error instr-diag message)])])]
    [(Err message) (be_state.compiler-backend-instr-error instr-diag message)]))

(define (compiler-backend-emit-sse2-i32-vector-mul
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (match (let
    [elem-ty (compiler_ast_types.AstType.I32)]
    (be_operand.compiler-backend-vector-register-use
      assignments
      lhs
      "lhs"
      "xmm"
      elem-ty
      (be_operand.compiler-backend-vector-spill-scratch "xmm" 0)
      backend-state))
    [(Ok lhs-use)
      (match lhs-use
        [(Use lhs-asm lhs-reg)
          (match (let
            [elem-ty (compiler_ast_types.AstType.I32)]
            (be_operand.compiler-backend-vector-register-use
              assignments
              rhs
              "rhs"
              "xmm"
              elem-ty
              (be_operand.compiler-backend-vector-spill-scratch "xmm" 1)
              backend-state))
            [(Ok rhs-use)
              (match rhs-use
                [(Use rhs-asm rhs-reg)
                  (match (compiler-backend-vector-dst-reg
                    assignments
                    dst
                    "binop dst"
                    "xmm"
                    (be_operand.compiler-backend-vector-spill-scratch "xmm" 0)
                    backend-state)
                    [(Ok dst-reg)
                      (Ok
                        (str_cat.str-cat
                          lhs-asm
                          rhs-asm
                          "    movdqa "
                          lhs-reg
                          ", %xmm0\n    pmuludq "
                          rhs-reg
                          ", %xmm0\n    pshufd $8, %xmm0, %xmm0\n    pshufd $245, "
                          lhs-reg
                          ", %xmm1\n    pshufd $245, "
                          rhs-reg
                          ", "
                          dst-reg
                          "\n    pmuludq %xmm1, "
                          dst-reg
                          "\n    pshufd $8, "
                          dst-reg
                          ", "
                          dst-reg
                          "\n    punpckldq "
                          dst-reg
                          ", %xmm0\n    movdqa %xmm0, "
                          dst-reg
                          "\n"
                          (compiler-backend-vector-store-dst
                            assignments
                            dst
                            "xmm"
                            (I32)
                            dst-reg
                            backend-state)))]
                    [(Err message)
                      (be_state.compiler-backend-instr-error instr-diag message)])])]
            [(Err message)
              (be_state.compiler-backend-instr-error instr-diag message)])])]
    [(Err message) (be_state.compiler-backend-instr-error instr-diag message)]))

(define (compiler-backend-emit-avx2-i64-vector-mul
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (match (let
    [elem-ty (compiler_ast_types.AstType.I64)]
    (be_operand.compiler-backend-vector-register-use
      assignments
      lhs
      "lhs"
      "ymm"
      elem-ty
      (be_operand.compiler-backend-vector-spill-scratch "ymm" 0)
      backend-state))
    [(Ok lhs-use)
      (match lhs-use
        [(Use lhs-asm lhs-reg)
          (match (let
            [elem-ty (compiler_ast_types.AstType.I64)]
            (be_operand.compiler-backend-vector-register-use
              assignments
              rhs
              "rhs"
              "ymm"
              elem-ty
              (be_operand.compiler-backend-vector-spill-scratch "ymm" 1)
              backend-state))
            [(Ok rhs-use)
              (match rhs-use
                [(Use rhs-asm rhs-reg)
                  (match (compiler-backend-vector-dst-reg
                    assignments
                    dst
                    "binop dst"
                    "ymm"
                    (be_operand.compiler-backend-vector-spill-scratch "ymm" 0)
                    backend-state)
                    [(Ok dst-reg)
                      (let
                        [body : String
                          (str_cat.str-cat
                            "    vpsrlq $32, "
                            lhs-reg
                            ", %ymm0\n    vpmuludq "
                            rhs-reg
                            ", %ymm0, %ymm0\n    vpsrlq $32, "
                            rhs-reg
                            ", %ymm1\n    vpmuludq "
                            lhs-reg
                            ", %ymm1, %ymm1\n    vpaddq %ymm1, %ymm0, %ymm0\n    vpsllq $32, %ymm0, %ymm0\n    vpmuludq "
                            rhs-reg
                            ", "
                            lhs-reg
                            ", "
                            dst-reg
                            "\n    vpaddq %ymm0, "
                            dst-reg
                            ", "
                            dst-reg
                            "\n")]
                        (Ok
                          (str_cat.str-cat
                            lhs-asm
                            rhs-asm
                            body
                            (compiler-backend-vector-store-dst
                              assignments
                              dst
                              "ymm"
                              (I64)
                              dst-reg
                              backend-state))))]
                    [(Err message)
                      (be_state.compiler-backend-instr-error instr-diag message)])])]
            [(Err message)
              (be_state.compiler-backend-instr-error instr-diag message)])])]
    [(Err message) (be_state.compiler-backend-instr-error instr-diag message)]))

(define (compiler-backend-emit-avx2-i64-vector-shr
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (match (let
    [elem-ty (compiler_ast_types.AstType.I64)]
    (be_operand.compiler-backend-vector-register-use
      assignments
      lhs
      "lhs"
      "ymm"
      elem-ty
      (be_operand.compiler-backend-vector-spill-scratch "ymm" 0)
      backend-state))
    [(Ok lhs-use)
      (match lhs-use
        [(Use lhs-asm lhs-reg)
          (match (let
            [elem-ty (compiler_ast_types.AstType.I64)]
            (be_operand.compiler-backend-vector-register-use
              assignments
              rhs
              "rhs"
              "ymm"
              elem-ty
              (be_operand.compiler-backend-vector-spill-scratch "ymm" 1)
              backend-state))
            [(Ok rhs-use)
              (match rhs-use
                [(Use rhs-asm rhs-reg)
                  (match (compiler-backend-vector-dst-reg
                    assignments
                    dst
                    "binop dst"
                    "ymm"
                    (be_operand.compiler-backend-vector-spill-scratch "ymm" 0)
                    backend-state)
                    [(Ok dst-reg)
                      (Ok
                        (str_cat.str-cat
                          lhs-asm
                          rhs-asm
                          "    vpxor %ymm1, %ymm1, %ymm1\n    vpcmpgtq "
                          lhs-reg
                          ", %ymm1, %ymm0\n    vpcmpeqd %ymm1, %ymm1, %ymm1\n    vpsllq $63, %ymm1, %ymm1\n    vpsrlq $57, %ymm1, %ymm1\n    vpsubq "
                          rhs-reg
                          ", %ymm1, %ymm1\n    vpsllvq %ymm1, %ymm0, %ymm0\n    vpsrlvq "
                          rhs-reg
                          ", "
                          lhs-reg
                          ", "
                          dst-reg
                          "\n    vpor %ymm0, "
                          dst-reg
                          ", "
                          dst-reg
                          "\n"
                          (compiler-backend-vector-store-dst
                            assignments
                            dst
                            "ymm"
                            (I64)
                            dst-reg
                            backend-state)))]
                    [(Err message)
                      (be_state.compiler-backend-instr-error instr-diag message)])])]
            [(Err message)
              (be_state.compiler-backend-instr-error instr-diag message)])])]
    [(Err message) (be_state.compiler-backend-instr-error instr-diag message)]))

(define (compiler-backend-emit-vector-binop
  [mode : be_state.CompilerBackendMode]
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (be_operand.compiler-backend-mode-shape-ok? mode elem-ty lanes)
    (let
      [mnemonic : String
        (compiler-backend-mode-vector-binop-mnemonic mode op elem-ty)]
      (cond
        [(and
            (be_state.compiler-backend-mode-avx2? mode)
            (be_operand.compiler-backend-word-vector-shift? op elem-ty))
          (compiler-backend-emit-avx2-word-vector-shift
            assignments
            dst
            op
            lhs
            rhs
            elem-ty
            instr-diag
            backend-state)]
        [(and
            (not (be_state.compiler-backend-mode-sse2? mode))
            (be_operand.compiler-backend-byte-vector-shift? op elem-ty))
          (compiler-backend-emit-byte-vector-shift
            assignments
            dst
            op
            lhs
            rhs
            elem-ty
            (compiler-backend-mode-width mode)
            instr-diag
            backend-state)]
        [(compiler-backend-byte-vector-mul? op elem-ty)
          (compiler-backend-emit-byte-vector-mul
            assignments
            dst
            lhs
            rhs
            elem-ty
            (compiler-backend-mode-width mode)
            instr-diag
            backend-state)]
        [(and
            (be_state.compiler-backend-mode-sse2? mode)
            (compiler-backend-avx2-i64-vector-mul? op elem-ty))
          (compiler-backend-emit-sse2-i64-vector-mul
            assignments
            dst
            lhs
            rhs
            instr-diag
            backend-state)]
        [(and
            (be_state.compiler-backend-mode-sse2? mode)
            (compiler-backend-sse2-i32-vector-mul? op elem-ty))
          (compiler-backend-emit-sse2-i32-vector-mul
            assignments
            dst
            lhs
            rhs
            instr-diag
            backend-state)]
        [(and
            (be_state.compiler-backend-mode-avx2? mode)
            (compiler-backend-avx2-i64-vector-mul? op elem-ty))
          (compiler-backend-emit-avx2-i64-vector-mul
            assignments
            dst
            lhs
            rhs
            instr-diag
            backend-state)]
        [(and
            (be_state.compiler-backend-mode-avx2? mode)
            (compiler-backend-avx2-i64-vector-shr? op elem-ty))
          (compiler-backend-emit-avx2-i64-vector-shr
            assignments
            dst
            lhs
            rhs
            instr-diag
            backend-state)]
        [(= (string.string-length mnemonic) 0)
          (be_state.compiler-backend-instr-error
            instr-diag
            (compiler-backend-mode-unsupported mode "vector binary op"))]
        [(be_state.compiler-backend-mode-sse2? mode)
          (match (be_operand.compiler-backend-vector-register-use
            assignments
            lhs
            "lhs"
            "xmm"
            elem-ty
            (be_operand.compiler-backend-vector-spill-scratch "xmm" 0)
            backend-state)
            [(Ok lhs-use)
              (match lhs-use
                [(Use lhs-asm lhs-reg)
                  (match (be_operand.compiler-backend-vector-register-use
                    assignments
                    rhs
                    "rhs"
                    "xmm"
                    elem-ty
                    (be_operand.compiler-backend-vector-spill-scratch "xmm" 1)
                    backend-state)
                    [(Ok rhs-use)
                      (match rhs-use
                        [(Use rhs-asm rhs-reg)
                          (match (compiler-backend-vector-dst-reg
                            assignments
                            dst
                            "binop dst"
                            "xmm"
                            (be_operand.compiler-backend-vector-spill-scratch
                              "xmm"
                              0)
                            backend-state)
                            [(Ok dst-reg)
                              (let
                                [reg-move : String
                                  (compiler-backend-sse2-reg-move (& elem-ty))]
                                [op-asm : String
                                  (cond
                                    [(string.eq dst-reg lhs-reg)
                                      (str_cat.str-cat
                                        "    "
                                        mnemonic
                                        " "
                                        rhs-reg
                                        ", "
                                        dst-reg
                                        "\n")]
                                    [(and
                                        (string.eq dst-reg rhs-reg)
                                        (be_operand.compiler-backend-commutative-binop?
                                          (& op)))
                                      (str_cat.str-cat
                                        "    "
                                        mnemonic
                                        " "
                                        lhs-reg
                                        ", "
                                        dst-reg
                                        "\n")]
                                    [(string.eq dst-reg rhs-reg)
                                      (str_cat.str-cat
                                        "    "
                                        reg-move
                                        " "
                                        lhs-reg
                                        ", %xmm0\n    "
                                        mnemonic
                                        " "
                                        rhs-reg
                                        ", %xmm0\n    "
                                        reg-move
                                        " %xmm0, "
                                        dst-reg
                                        "\n")]
                                    [else
                                      (str_cat.str-cat
                                        "    "
                                        reg-move
                                        " "
                                        lhs-reg
                                        ", "
                                        dst-reg
                                        "\n    "
                                        mnemonic
                                        " "
                                        rhs-reg
                                        ", "
                                        dst-reg
                                        "\n")])]
                                (Ok
                                  (str_cat.str-cat
                                    lhs-asm
                                    rhs-asm
                                    op-asm
                                    (compiler-backend-vector-store-dst
                                      assignments
                                      dst
                                      "xmm"
                                      elem-ty
                                      dst-reg
                                      backend-state))))]
                            [(Err message)
                              (be_state.compiler-backend-instr-error
                                instr-diag
                                message)])])]
                    [(Err message)
                      (be_state.compiler-backend-instr-error instr-diag message)])])]
            [(Err message)
              (be_state.compiler-backend-instr-error instr-diag message)])]
        [else
          (match (be_operand.compiler-backend-vector-register-use
            assignments
            lhs
            "lhs"
            (compiler-backend-mode-width mode)
            elem-ty
            (be_operand.compiler-backend-vector-spill-scratch
              (compiler-backend-mode-width mode)
              0)
            backend-state)
            [(Ok lhs-use)
              (match lhs-use
                [(Use lhs-asm lhs-reg)
                  (match (compiler-backend-vector-memory-or-register-use
                    assignments
                    rhs
                    "rhs"
                    (compiler-backend-mode-width mode)
                    elem-ty
                    backend-state)
                    [(Ok rhs-use)
                      (match rhs-use
                        [(Use rhs-asm rhs-op)
                          (match (compiler-backend-vector-dst-reg
                            assignments
                            dst
                            "binop dst"
                            (compiler-backend-mode-width mode)
                            (be_operand.compiler-backend-vector-spill-scratch
                              (compiler-backend-mode-width mode)
                              0)
                            backend-state)
                            [(Ok dst-reg)
                              (Ok
                                (str_cat.str-cat
                                  lhs-asm
                                  rhs-asm
                                  (str_cat.str-cat
                                    "    "
                                    mnemonic
                                    " "
                                    rhs-op
                                    ", "
                                    lhs-reg
                                    ", "
                                    dst-reg
                                    "\n"
                                    (compiler-backend-vector-store-dst
                                      assignments
                                      dst
                                      (compiler-backend-mode-width mode)
                                      elem-ty
                                      dst-reg
                                      backend-state))))]
                            [(Err message)
                              (be_state.compiler-backend-instr-error
                                instr-diag
                                message)])])]
                    [(Err message)
                      (be_state.compiler-backend-instr-error instr-diag message)])])]
            [(Err message)
              (be_state.compiler-backend-instr-error instr-diag message)])]))
    (compiler-backend-mode-shape-diagnostic
      mode
      type-segment-bases
      instr-diag
      elem-ty
      lanes)))

(define (compiler-backend-vector-binop-assoc-comm-int?
  [op : (& op compiler_ir_types.CompilerIrBinOp)]
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]) : bool
  (and
    (match op
      [(or (Add) (BitAnd) (BitOr) (BitXor)) true]
      [_ false])
    (match elem-ty
      [(or (I8) (U8) (I16) (U16) (I32) (U32) (I64) (U64)) true]
      [_ false])))

(define (compiler-backend-vector-binop-op-eq?
  [a : (& a compiler_ir_types.CompilerIrBinOp)]
  [b : (& b compiler_ir_types.CompilerIrBinOp)]) : bool
  (match a
    [(Add)
      (match b
        [(Add) true]
        [_ false])]
    [(BitAnd)
      (match b
        [(BitAnd) true]
        [_ false])]
    [(BitOr)
      (match b
        [(BitOr) true]
        [_ false])]
    [(BitXor)
      (match b
        [(BitXor) true]
        [_ false])]
    [_ false]))

(define (compiler-backend-copy-int-ast-type
  [ty : (& ty compiler_ast_types.AstType)]) : compiler_ast_types.AstType
  (match ty
    [(I8) (I8)]
    [(U8) (U8)]
    [(I16) (I16)]
    [(U16) (U16)]
    [(I32) (I32)]
    [(U32) (U32)]
    [(I64) (I64)]
    [(U64) (U64)]
    [_ (I64)]))

(define (compiler-backend-emit-vector-binop-dual-memory-source
  [mode : be_state.CompilerBackendMode]
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [op : compiler_ir_types.CompilerIrBinOp]
  [reg-value : compiler_ir_types.CompilerIrValue]
  [base1 : compiler_ir_types.CompilerIrValue]
  [index1 : compiler_ir_types.CompilerIrValue]
  [base2 : compiler_ir_types.CompilerIrValue]
  [index2 : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (be_operand.compiler-backend-mode-shape-ok? mode elem-ty lanes)
    (let
      [mnemonic : String
        (compiler-backend-mode-vector-binop-mnemonic mode op elem-ty)]
      (if (= (string.string-length mnemonic) 0)
        (be_state.compiler-backend-instr-error
          instr-diag
          (compiler-backend-mode-unsupported mode "vector binary op"))
        (match (be_operand.compiler-backend-vector-register-use
          assignments
          reg-value
          "dual memory binop register operand"
          (compiler-backend-mode-width mode)
          elem-ty
          (be_operand.compiler-backend-vector-spill-scratch
            (compiler-backend-mode-width mode)
            0)
          backend-state)
          [(Ok reg-use)
            (match reg-use
              [(Use reg-asm reg)
                (match (compiler-backend-vector-dst-reg
                  assignments
                  dst
                  "dual binop dst"
                  (compiler-backend-mode-width mode)
                  (be_operand.compiler-backend-vector-spill-scratch
                    (compiler-backend-mode-width mode)
                    0)
                  backend-state)
                  [(Ok dst-reg)
                    (match (compiler-backend-emit-simd-indexed-address
                      type-segment-bases
                      assignments
                      base1
                      index1
                      (compiler-backend-copy-int-ast-type (& elem-ty))
                      backend-state)
                      [(Ok addr1-plan)
                        (match (compiler-backend-emit-simd-indexed-address
                          type-segment-bases
                          assignments
                          base2
                          index2
                          (compiler-backend-copy-int-ast-type (& elem-ty))
                          backend-state)
                          [(Ok addr2-plan)
                            (Ok
                              (if (be_state.compiler-backend-mode-sse2? mode)
                                (let
                                  [load-op : String
                                    (compiler-backend-mode-vector-move
                                      mode
                                      (& elem-ty))]
                                  [first-asm : String
                                    (if (string.eq dst-reg reg)
                                      (str_cat.str-cat
                                        "    "
                                        load-op
                                        " "
                                        addr1-plan.addr
                                        ", %xmm0\n    "
                                        mnemonic
                                        " %xmm0, "
                                        dst-reg
                                        "\n")
                                      (str_cat.str-cat
                                        "    "
                                        load-op
                                        " "
                                        addr1-plan.addr
                                        ", "
                                        dst-reg
                                        "\n    "
                                        mnemonic
                                        " "
                                        reg
                                        ", "
                                        dst-reg
                                        "\n"))]
                                  (str_cat.str-cat
                                    reg-asm
                                    addr1-plan.asm
                                    first-asm
                                    addr2-plan.asm
                                    "    "
                                    load-op
                                    " "
                                    addr2-plan.addr
                                    ", %xmm0\n    "
                                    mnemonic
                                    " %xmm0, "
                                    dst-reg
                                    "\n"
                                    (compiler-backend-vector-store-dst
                                      assignments
                                      dst
                                      "xmm"
                                      elem-ty
                                      dst-reg
                                      backend-state)))
                                (str_cat.str-cat
                                  reg-asm
                                  addr1-plan.asm
                                  "    "
                                  mnemonic
                                  " "
                                  addr1-plan.addr
                                  ", "
                                  reg
                                  ", "
                                  dst-reg
                                  "\n"
                                  addr2-plan.asm
                                  "    "
                                  mnemonic
                                  " "
                                  addr2-plan.addr
                                  ", "
                                  dst-reg
                                  ", "
                                  dst-reg
                                  "\n"
                                  (compiler-backend-vector-store-dst
                                    assignments
                                    dst
                                    (compiler-backend-mode-width mode)
                                    elem-ty
                                    dst-reg
                                    backend-state))))]
                          [(Err message)
                            (be_state.compiler-backend-instr-error-from
                              instr-diag
                              message)])]
                      [(Err message)
                        (be_state.compiler-backend-instr-error-from
                          instr-diag
                          message)])]
                  [(Err message)
                    (be_state.compiler-backend-instr-error instr-diag message)])])]
          [(Err message)
            (be_state.compiler-backend-instr-error instr-diag message)])))
    (compiler-backend-mode-shape-diagnostic
      mode
      type-segment-bases
      instr-diag
      elem-ty
      lanes)))

(define (compiler-backend-emit-vector-binop-memory-source
  [mode : be_state.CompilerBackendMode]
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [op : compiler_ir_types.CompilerIrBinOp]
  [reg-value : compiler_ir_types.CompilerIrValue]
  [base : compiler_ir_types.CompilerIrValue]
  [index : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (be_operand.compiler-backend-mode-shape-ok? mode elem-ty lanes)
    (let
      [mnemonic : String
        (compiler-backend-mode-vector-binop-mnemonic mode op elem-ty)]
      (if (= (string.string-length mnemonic) 0)
        (be_state.compiler-backend-instr-error
          instr-diag
          (compiler-backend-mode-unsupported mode "vector binary op"))
        (match (be_operand.compiler-backend-vector-register-use
          assignments
          reg-value
          "memory binop register operand"
          (compiler-backend-mode-width mode)
          elem-ty
          (be_operand.compiler-backend-vector-spill-scratch
            (compiler-backend-mode-width mode)
            0)
          backend-state)
          [(Ok reg-use)
            (match reg-use
              [(Use reg-asm reg)
                (match (compiler-backend-vector-dst-reg
                  assignments
                  dst
                  "binop dst"
                  (compiler-backend-mode-width mode)
                  (be_operand.compiler-backend-vector-spill-scratch
                    (compiler-backend-mode-width mode)
                    0)
                  backend-state)
                  [(Ok dst-reg)
                    (match (compiler-backend-emit-simd-indexed-address
                      type-segment-bases
                      assignments
                      base
                      index
                      (be_state.compiler-backend-global-shared-view elem-ty)
                      backend-state)
                      [(Ok addr-plan)
                        (let
                          [addr-asm : String addr-plan.asm]
                          [addr : String addr-plan.addr]
                          (Ok
                            (if (be_state.compiler-backend-mode-sse2? mode)
                              (let
                                [load-op : String
                                  (compiler-backend-mode-vector-move
                                    mode
                                    (& elem-ty))]
                                [reg-move : String
                                  (compiler-backend-sse2-reg-move (& elem-ty))]
                                [op-asm : String
                                  (cond
                                    [(and
                                        (not (string.eq dst-reg reg))
                                        (be_operand.compiler-backend-commutative-binop?
                                          (& op)))
                                      (str_cat.str-cat
                                        "    "
                                        load-op
                                        " "
                                        addr
                                        ", "
                                        dst-reg
                                        "\n    "
                                        mnemonic
                                        " "
                                        reg
                                        ", "
                                        dst-reg
                                        "\n")]
                                    [(string.eq dst-reg reg)
                                      (str_cat.str-cat
                                        "    "
                                        load-op
                                        " "
                                        addr
                                        ", %xmm0\n    "
                                        mnemonic
                                        " %xmm0, "
                                        dst-reg
                                        "\n")]
                                    [else
                                      (str_cat.str-cat
                                        "    "
                                        reg-move
                                        " "
                                        reg
                                        ", "
                                        dst-reg
                                        "\n    "
                                        load-op
                                        " "
                                        addr
                                        ", %xmm0\n    "
                                        mnemonic
                                        " %xmm0, "
                                        dst-reg
                                        "\n")])]
                                (str_cat.str-cat
                                  reg-asm
                                  addr-asm
                                  op-asm
                                  (compiler-backend-vector-store-dst
                                    assignments
                                    dst
                                    "xmm"
                                    elem-ty
                                    dst-reg
                                    backend-state)))
                              (str_cat.str-cat
                                reg-asm
                                addr-asm
                                (str_cat.str-cat
                                  "    "
                                  mnemonic
                                  " "
                                  addr
                                  ", "
                                  reg
                                  ", "
                                  dst-reg
                                  "\n"
                                  (compiler-backend-vector-store-dst
                                    assignments
                                    dst
                                    (compiler-backend-mode-width mode)
                                    elem-ty
                                    dst-reg
                                    backend-state))))))]
                      [(Err message)
                        (be_state.compiler-backend-instr-error-from
                          instr-diag
                          message)])]
                  [(Err message)
                    (be_state.compiler-backend-instr-error instr-diag message)])])]
          [(Err message)
            (be_state.compiler-backend-instr-error instr-diag message)])))
    (compiler-backend-mode-shape-diagnostic
      mode
      type-segment-bases
      instr-diag
      elem-ty
      lanes)))

(define (compiler-backend-emit-vector-store
  [mode : be_state.CompilerBackendMode]
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [base : compiler_ir_types.CompilerIrValue]
  [index : compiler_ir_types.CompilerIrValue]
  [value : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (be_operand.compiler-backend-mode-shape-ok? mode elem-ty lanes)
    (match (be_operand.compiler-backend-vector-register-use
      assignments
      value
      "store value"
      (compiler-backend-mode-width mode)
      elem-ty
      (be_operand.compiler-backend-vector-spill-scratch
        (compiler-backend-mode-width mode)
        0)
      backend-state)
      [(Ok value-use)
        (match value-use
          [(Use value-asm value-reg)
            (match (compiler-backend-emit-simd-indexed-address
              type-segment-bases
              assignments
              base
              index
              (be_state.compiler-backend-global-shared-view elem-ty)
              backend-state)
              [(Ok addr-plan)
                (let
                  [addr-asm : String addr-plan.asm]
                  [addr : String addr-plan.addr]
                  (Ok
                    (str_cat.str-cat
                      value-asm
                      addr-asm
                      (str_cat.str-cat
                        "    "
                        (compiler-backend-mode-vector-move mode elem-ty)
                        " "
                        value-reg
                        ", ")
                      (str_cat.str-cat addr "\n"))))]
              [(Err message)
                (be_state.compiler-backend-instr-error-from instr-diag message)])])]
      [(Err message) (be_state.compiler-backend-instr-error instr-diag message)])
    (compiler-backend-mode-shape-diagnostic
      mode
      type-segment-bases
      instr-diag
      elem-ty
      lanes)))

(define (compiler-backend-avx512-mask-value-reg
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]
  [role : String]) : be_state.ResultBackendReg
  (match value
    [(Var var)
      (be_operand.compiler-backend-mask-var-reg
        backend-state
        assignments
        var
        role)]
    [_ (Err (str_cat.str-cat "backend: unsupported AVX-512 mask " role))]))

(define (compiler-backend-mode-width [mode : be_state.CompilerBackendMode]) : String
  (match mode
    [(Avx512) "zmm"]
    [(Sse2) "xmm"]
    [_ "ymm"]))

(define (compiler-backend-mode-shape-diagnostic
  [mode : be_state.CompilerBackendMode]
  [type-segment-bases : i64]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [elem-ty : compiler_ast_types.AstType]
  [lanes : i64]) : be_state.ResultCompilerBackend
  (match mode
    [(Avx512)
      (be_operand.compiler-backend-avx512-shape-diagnostic
        type-segment-bases
        instr-diag
        elem-ty
        lanes)]
    [(Sse2)
      (be_operand.compiler-backend-sse2-shape-diagnostic
        type-segment-bases
        instr-diag
        elem-ty
        lanes)]
    [_
      (be_operand.compiler-backend-avx2-shape-diagnostic
        type-segment-bases
        instr-diag
        elem-ty
        lanes)]))

(define (compiler-backend-mode-unsupported
  [mode : be_state.CompilerBackendMode]
  [what : String]) : String
  (str_cat.str-cat
    "backend: unsupported "
    (match mode
      [(Avx512) "AVX-512"]
      [(Sse2) "SSE2"]
      [_ "AVX2"])
    " "
    what))

(define (compiler-backend-mode-vector-move
  [mode : be_state.CompilerBackendMode]
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]) : String
  (match mode
    [(Avx512) (be_operand.compiler-backend-avx512-vector-move elem-ty)]
    [(Sse2) (be_operand.compiler-backend-sse2-vector-move elem-ty)]
    [_ (be_operand.compiler-backend-avx2-vector-move elem-ty)]))

(define (compiler-backend-mode-vector-binop-mnemonic
  [mode : be_state.CompilerBackendMode]
  [op : (& op compiler_ir_types.CompilerIrBinOp)]
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]) : String
  (match mode
    [(Avx512) (compiler-backend-vector-binop-mnemonic op elem-ty true)]
    [(Sse2) (compiler-backend-sse2-vector-binop-mnemonic op elem-ty)]
    [_ (compiler-backend-vector-binop-mnemonic op elem-ty false)]))

(define (compiler-backend-vector-value-stack-operand
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]
  [backend-state : be_state.CompilerBackendState]) : be_state.CompilerBackendMaybeStackOperand
  (match value
    [(Var var)
      (be_operand.compiler-backend-vector-var-stack-operand
        assignments
        var
        backend-state)]
    [_ No]))

(define (compiler-backend-vector-store-stack-asm
  [move : String]
  [reg : String]
  [operand : String]) : String
  (str_cat.str-cat "    " move " " reg ", " operand "\n"))

(define (compiler-backend-vector-memory-or-register-use
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]
  [role : String]
  [width : String]
  [_elem-ty : (& _elem-ty compiler_ast_types.AstType)]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultBackendVectorUse
  (match value
    [(Var var)
      (match (be_operand.compiler-backend-vector-var-stack-operand
        assignments
        var
        backend-state)
        [(Some operand) (Ok (Use "" operand))]
        [(No)
          (let
            [reg
              (try
                (be_operand.compiler-backend-vector-var-reg
                  backend-state
                  assignments
                  var
                  role
                  width))]
            (Ok (Use "" reg)))])]
    [_
      (Err (be_operand.compiler-backend-vector-unsupported-message width role))]))

(define (compiler-backend-vector-dst-reg
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [role : String]
  [width : String]
  [scratch : String]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultBackendReg
  (match (be_operand.compiler-backend-vector-var-stack-operand
    assignments
    dst
    backend-state)
    [(Some _)
      (when
        (and
          (string.eq width "xmm")
          (be_state.compiler-backend-current-fn-win64? backend-state)
          (or (string.eq scratch "%xmm14") (string.eq scratch "%xmm15")))
        (be_operand.compiler-backend-emergency-add!
          (be_state.compiler-backend-state-function-state backend-state)
          (string.copy (& scratch))))
      (Ok scratch)]
    [(No)
      (be_operand.compiler-backend-vector-var-reg
        backend-state
        assignments
        dst
        role
        width)]))

(define (compiler-backend-vector-store-dst
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [width : String]
  [elem-ty : compiler_ast_types.AstType]
  [reg : String]
  [backend-state : be_state.CompilerBackendState]) : String
  (match (be_operand.compiler-backend-vector-var-stack-operand
    assignments
    dst
    backend-state)
    [(Some operand)
      (compiler-backend-vector-store-stack-asm
        (be_operand.compiler-backend-vector-move-for-width width elem-ty)
        reg
        operand)]
    [(No) ""]))

;; A plain IR Mov can carry a SIMD identity after CSE/GVN. Recover its shape
;; from the direct definition at the root of the copy chain; the current
;; backend mode then selects YMM, ZMM, or k-register emission. Below opt2 a
;; variable can have several Mov definitions joined by loop back edges, so the
;; chains form a graph. Each query follows a variable at most once (`seen`,
;; keyed by variable id: backend-introduced copies may exceed the IR's
;; variable count), so its work is bounded by the variables it reaches times
;; the function's instructions and it terminates on cyclic chains; the depth
;; budget is a second guard. A
;; variable's shape is the first of its definitions, in block and instruction
;; order, that resolves to one: a definition that does not (a scalar source, or
;; a chain back into a variable already being followed) never hides a later
;; definition that does.
(defenum CompilerBackendSimdCopyShape
  (No)
  (Vector i64 compiler_ast_types.AstType)
  (Mask i64))

(define (compiler-backend-simd-copy-shape-follow
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [source : i64]
  [remaining : i64]
  [seen : (&mut seen backend_i64_i64_map.Map)]) : CompilerBackendSimdCopyShape
  (if (or (<= remaining 0) (backend_i64_i64_map.contains? seen source))
    (No)
    (begin
      (backend_i64_i64_map.insert-ref! seen source 1)
      (compiler-backend-simd-copy-shape-blocks
        (be_state.compiler-backend-global-shared-view blocks)
        blocks
        source
        (- remaining 1)
        seen))))

(define (compiler-backend-simd-copy-shape-seq
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [instrs : compiler_ir_types.CompilerIrInstrSeq]
  [var : i64]
  [remaining : i64]
  [seen : (&mut seen backend_i64_i64_map.Map)]) : CompilerBackendSimdCopyShape
  (for [index
    (iterator.range 0 (compiler_ir_types.compiler-ir-instr-seq-count instrs))]
    (match (compiler_ir_types.compiler-ir-instr-seq-ref instrs index)
      [(Splat dst _ lanes elem-ty)
        (when (= dst var) (return (Vector lanes elem-ty)))]
      [(VectorBinOp (box (fields dst lanes [elem-ty ty])))
        (when (= dst var) (return (Vector lanes elem-ty)))]
      [(VectorCompare (box (fields dst lanes)))
        (when (= dst var) (return (Mask lanes)))]
      [(Mov dst src _)
        (match (if (= dst var)
          (match src
            [(Var source)
              (compiler-backend-simd-copy-shape-follow
                (be_state.compiler-backend-global-shared-view blocks)
                source
                remaining
                seen)]
            [_ (CompilerBackendSimdCopyShape.No)])
          (CompilerBackendSimdCopyShape.No))
          ;; A definition that resolves to no shape does not end the scan:
          ;; another definition of `var`, even later in this block, may.
          [(No) unit]
          [(Vector lanes elem-ty) (return (Vector lanes elem-ty))]
          [(Mask lanes) (return (Mask lanes))])]
      [_ unit]))
  (No))

(define (compiler-backend-simd-copy-shape-block
  [all-blocks : compiler_ir_types.CompilerIrBlockList]
  [block : compiler_ir_types.CompilerIrBlock]
  [var : i64]
  [remaining : i64]
  [seen : (&mut seen backend_i64_i64_map.Map)]) : CompilerBackendSimdCopyShape
  (match block
    [(Block _ instrs)
      (compiler-backend-simd-copy-shape-seq
        all-blocks
        instrs
        var
        remaining
        seen)]))

;; An `Array` block list is walked in place: converting it to a list here would
;; allocate a copy of the function's block spine on every followed variable.
(define (compiler-backend-simd-copy-shape-block-seq
  [all-blocks : compiler_ir_types.CompilerIrBlockList]
  [seq : compiler_ir_types.CompilerIrBlockSeq]
  [var : i64]
  [remaining : i64]
  [seen : (&mut seen backend_i64_i64_map.Map)]) : CompilerBackendSimdCopyShape
  (for [index (iterator.range 0 seq.len)]
    (match (compiler-backend-simd-copy-shape-block
      (be_state.compiler-backend-global-shared-view all-blocks)
      (compiler_ir_types.compiler-ir-block-seq-ref seq index)
      var
      remaining
      seen)
      [(No) unit]
      [(Vector lanes elem-ty) (return (Vector lanes elem-ty))]
      [(Mask lanes) (return (Mask lanes))]))
  (No))

(define (compiler-backend-simd-copy-shape-blocks
  [all-blocks : compiler_ir_types.CompilerIrBlockList]
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [var : i64]
  [remaining : i64]
  [seen : (&mut seen backend_i64_i64_map.Map)]) : CompilerBackendSimdCopyShape
  (match blocks
    [(Array seq)
      (compiler-backend-simd-copy-shape-block-seq
        all-blocks
        seq
        var
        remaining
        seen)]))

(define (compiler-backend-simd-copy-shape
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [dst : i64]
  [vars : i64]) : CompilerBackendSimdCopyShape
  (let
    [seen : backend_i64_i64_map.Map (backend_i64_i64_map.with-capacity 16)]
    (backend_i64_i64_map.insert-ref! (&mut seen) dst 1)
    (compiler-backend-simd-copy-shape-blocks
      (be_state.compiler-backend-global-shared-view blocks)
      blocks
      dst
      (+ vars 1)
      (&mut seen))))

(define (compiler-backend-emit-vector-copy
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [src : compiler_ir_types.CompilerIrValue]
  [width : String]
  [elem-ty : compiler_ast_types.AstType]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [source-scratch : String
      (be_operand.compiler-backend-vector-spill-scratch width 0)]
    [dst-scratch : String
      (be_operand.compiler-backend-vector-spill-scratch width 1)]
    (match (be_operand.compiler-backend-vector-register-use
      assignments
      src
      "copy source"
      (be_state.compiler-backend-global-shared-view width)
      elem-ty
      source-scratch
      backend-state)
      [(Ok source-use)
        (match source-use
          [(Use load-asm source-reg)
            (match (compiler-backend-vector-dst-reg
              assignments
              dst
              "copy destination"
              (be_state.compiler-backend-global-shared-view width)
              dst-scratch
              backend-state)
              [(Ok dst-reg)
                (Ok
                  (str_cat.str-cat
                    (str_cat.str-cat
                      load-asm
                      (if (string.eq source-reg dst-reg)
                        ""
                        (str_cat.str-cat
                          (str_cat.str-cat
                            (str_cat.str-cat
                              (str_cat.str-cat
                                "    "
                                (be_operand.compiler-backend-vector-move-for-width
                                  width
                                  elem-ty))
                              " ")
                            source-reg)
                          (str_cat.str-cat ", " (str_cat.str-cat dst-reg "\n")))))
                    (compiler-backend-vector-store-dst
                      assignments
                      dst
                      width
                      elem-ty
                      dst-reg
                      backend-state)))]
              [(Err message)
                (Err
                  (box
                    (compiler_diagnostic.compiler-diagnostic-at-start
                      ""
                      message)))])])]
      [(Err message)
        (Err
          (box (compiler_diagnostic.compiler-diagnostic-at-start "" message)))])))

(define (compiler-backend-emit-avx512-mask-copy
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [src : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [scratch : String (compiler-backend-mask-spill-scratch 0)]
    (match (be_operand.compiler-backend-avx512-mask-register-use
      assignments
      src
      "copy source"
      lanes
      (be_state.compiler-backend-global-shared-view scratch)
      backend-state)
      [(Ok source-use)
        (match source-use
          [(Use load-asm source-reg)
            (match (compiler-backend-avx512-mask-dst-reg
              assignments
              dst
              "copy destination"
              scratch
              backend-state)
              [(Ok dst-reg)
                (Ok
                  (str_cat.str-cat
                    (str_cat.str-cat
                      load-asm
                      (if (string.eq source-reg dst-reg)
                        ""
                        (str_cat.str-cat
                          (str_cat.str-cat
                            (str_cat.str-cat
                              (str_cat.str-cat
                                "    "
                                (be_operand.compiler-backend-avx512-mask-move-mnemonic
                                  lanes))
                              " ")
                            source-reg)
                          (str_cat.str-cat ", " (str_cat.str-cat dst-reg "\n")))))
                    (compiler-backend-avx512-mask-store-dst
                      assignments
                      dst
                      lanes
                      dst-reg
                      backend-state)))]
              [(Err message)
                (Err
                  (box
                    (compiler_diagnostic.compiler-diagnostic-at-start
                      ""
                      message)))])])]
      [(Err message)
        (Err
          (box (compiler_diagnostic.compiler-diagnostic-at-start "" message)))])))

(define (compiler-backend-avx512-vector-compare-mnemonic
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]) : String
  (match elem-ty
    [(I64) "vpcmpq"]
    [(U64) "vpcmpuq"]
    [(I32) "vpcmpd"]
    [(U32) "vpcmpud"]
    [(I16) "vpcmpw"]
    [(U16) "vpcmpuw"]
    [(I8) "vpcmpb"]
    [(U8) "vpcmpub"]
    [(F64) "vcmppd"]
    [(F32) "vcmpps"]
    [_ ""]))

;; Integer NLT/NLE are GE/GT, but floating NLT/NLE also accept unordered
;; operands. Floating GE/GT must use ordered predicates; NE stays unordered.
(define (compiler-backend-vector-compare-predicate-separator
  [op : (& op compiler_ir_types.CompilerIrBinOp)]
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]) : String
  (match op
    [(Eq) " $0, "]
    [(Lt) " $1, "]
    [(Le) " $2, "]
    [(Ne) " $4, "]
    [(Ge)
      (if (be_operand.compiler-backend-float-type? elem-ty)
        " $13, "
        " $5, ")]
    [(Gt)
      (if (be_operand.compiler-backend-float-type? elem-ty)
        " $14, "
        " $6, ")]
    [_ ""]))

(define (compiler-backend-avx512-lane-mask [lanes : i64]) : i64
  (cond
    [(= lanes 8) 0xff]
    [(= lanes 16) 0xffff]
    [(= lanes 32) -1]
    [(= lanes 64) -1]
    [else 0]))

(define (compiler-backend-avx512-mask-int-suffix [lanes : i64]) : String
  (if (> lanes 32)
    "q"
    "l"))

(define (compiler-backend-avx512-mask-gpr-part [reg : String] [lanes : i64]) : String
  (if (> lanes 32)
    reg
    (be_operand.compiler-backend-reg-part reg 4)))

;; Extract any `%r*`/`%e*` register names inside the parenthesised addressing
;; portion of `addr` (e.g. `0(%r8)` or `(%r8,%r9,4)`) plus up to three extra
;; register names into a fresh exclude array for scavenging.
(define (compiler-backend-simd-addr-exclude
  [addr : (& str)]
  [extra0 : (& str)]
  [extra1 : (& str)]
  [extra2 : (& str)]) : (__tl_dyn-array String)
  (let
    [n : i64 (string.string-length addr)]
    [out : (__tl_dyn-array String) (__tl_make-array String 5)]
    [k : i64 0]
    [i : i64 0]
    (for [idx (iterator.range 0 5)]
      (set! (array-ref out idx) ""))
    (while (and (< i n) (< k 2))
      (if (= (string.string-ref addr i) '%')
        (let
          [j : i64 (+ i 1)]
          (while (and
            (< j n)
            (not (= (string.string-ref addr j) ','))
            (not (= (string.string-ref addr j) ')'))
            (not (= (string.string-ref addr j) ' ')))
            (+= j 1))
          (set! (array-ref out k) (string.substring addr i (- j i)))
          (+= k 1)
          (set! i j))
        (+= i 1)))
    (set! (array-ref out 2) (string.copy extra0))
    (set! (array-ref out 3) (string.copy extra1))
    (set! (array-ref out 4) (string.copy extra2))
    out))

(define (compiler-backend-avx512-mask-mov-imm-mnemonic [lanes : i64]) : String
  (str_cat.str-cat "mov" (compiler-backend-avx512-mask-int-suffix lanes)))

(define (compiler-backend-avx512-mask-not-full-width? [lanes : i64]) : bool
  (or (= lanes 16) (= lanes 32) (= lanes 64)))

(define (compiler-backend-avx512-mask-shl-mnemonic [lanes : i64]) : String
  (str_cat.str-cat "shl" (compiler-backend-avx512-mask-int-suffix lanes)))

(define (compiler-backend-avx512-mask-sub-mnemonic [lanes : i64]) : String
  (str_cat.str-cat "sub" (compiler-backend-avx512-mask-int-suffix lanes)))

(define (compiler-backend-avx512-mask-kxor-mnemonic [lanes : i64]) : String
  (str_cat.str-cat
    "kxor"
    (be_operand.compiler-backend-avx512-mask-op-suffix lanes)))

(define (compiler-backend-avx512-mask-kortest-mnemonic [lanes : i64]) : String
  (str_cat.str-cat
    "kortest"
    (be_operand.compiler-backend-avx512-mask-op-suffix lanes)))

(define (compiler-backend-avx512-mask-cmp-mnemonic [lanes : i64]) : String
  (str_cat.str-cat "cmp" (compiler-backend-avx512-mask-int-suffix lanes)))

(define (compiler-backend-avx512-mask-label
  [function : String]
  [current-label : i64]
  [dst : i64]
  [suffix : String]) : String
  (be_operand.compiler-backend-asm-label
    function
    (compiler_ir_types.compiler-ir-label
      (&
        (str_cat.str-cat
          "tail_mask_"
          (compiler_ir_types.compiler-ir-label-text current-label)
          "_v"
          (string.int->string dst)
          suffix)))))

(define (compiler-backend-emit-vector-lane-id
  [type-segment-bases : i64]
  [_function : String]
  [_current-label : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (cond
    [(be_facts.compiler-backend-lane-id-avx512-i64-shape-ok? elem-ty lanes)
      (match (compiler-backend-vector-dst-reg
        assignments
        dst
        "lane id dst"
        "zmm"
        (be_operand.compiler-backend-vector-spill-scratch "zmm" 0)
        backend-state)
        [(Ok dst-reg)
          (let
            [data-label : String
              (be_facts.compiler-backend-avx512-i64-lane-id-label)]
            (Ok
              (str_cat.str-cat
                "    vmovdqa64 "
                data-label
                "(%rip), "
                dst-reg
                "\n"
                (compiler-backend-vector-store-dst
                  assignments
                  dst
                  "zmm"
                  elem-ty
                  dst-reg
                  backend-state))))]
        [(Err message)
          (be_state.compiler-backend-instr-error instr-diag message)])]
    [(be_facts.compiler-backend-lane-id-avx2-i64-shape-ok? elem-ty lanes)
      (match (compiler-backend-vector-dst-reg
        assignments
        dst
        "lane id dst"
        "ymm"
        (be_operand.compiler-backend-vector-spill-scratch "ymm" 0)
        backend-state)
        [(Ok dst-reg)
          (let
            [data-label : String
              (be_facts.compiler-backend-avx2-i64-lane-id-label)]
            (Ok
              (str_cat.str-cat
                "    vmovdqa "
                data-label
                "(%rip), "
                dst-reg
                "\n"
                (compiler-backend-vector-store-dst
                  assignments
                  dst
                  "ymm"
                  elem-ty
                  dst-reg
                  backend-state))))]
        [(Err message)
          (be_state.compiler-backend-instr-error instr-diag message)])]
    [(be_facts.compiler-backend-lane-id-sse2-i64-shape-ok? elem-ty lanes)
      (match (compiler-backend-vector-dst-reg
        assignments
        dst
        "lane id dst"
        "xmm"
        (be_operand.compiler-backend-vector-spill-scratch "xmm" 0)
        backend-state)
        [(Ok dst-reg)
          (let
            [data-label : String
              (be_facts.compiler-backend-avx2-i64-lane-id-label)]
            (Ok
              (str_cat.str-cat
                "    movdqa "
                data-label
                "(%rip), "
                dst-reg
                "\n"
                (compiler-backend-vector-store-dst
                  assignments
                  dst
                  "xmm"
                  elem-ty
                  dst-reg
                  backend-state))))]
        [(Err message)
          (be_state.compiler-backend-instr-error instr-diag message)])]
    [else
      (be_operand.compiler-backend-avx512-shape-diagnostic
        type-segment-bases
        instr-diag
        elem-ty
        lanes)]))

(define (compiler-backend-emit-avx512-vector-compare
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (be_operand.compiler-backend-avx512-shape-ok? elem-ty lanes)
    (let
      [mnemonic : String
        (compiler-backend-avx512-vector-compare-mnemonic elem-ty)]
      [predicate-separator : String
        (compiler-backend-vector-compare-predicate-separator op elem-ty)]
      (if (or
        (= (string.string-length mnemonic) 0)
        (= (string.string-length predicate-separator) 0))
        (be_state.compiler-backend-instr-error
          instr-diag
          "backend: unsupported AVX-512 vector compare")
        (match (be_operand.compiler-backend-vector-register-use
          assignments
          lhs
          "cmp lhs"
          "zmm"
          elem-ty
          (be_operand.compiler-backend-vector-spill-scratch "zmm" 0)
          backend-state)
          [(Ok lhs-use)
            (match lhs-use
              [(Use lhs-asm lhs-reg)
                (match (compiler-backend-vector-memory-or-register-use
                  assignments
                  rhs
                  "cmp rhs"
                  "zmm"
                  elem-ty
                  backend-state)
                  [(Ok rhs-use)
                    (match rhs-use
                      [(Use rhs-asm rhs-op)
                        (match (compiler-backend-avx512-mask-dst-reg
                          assignments
                          dst
                          "cmp dst"
                          (compiler-backend-mask-spill-scratch 0)
                          backend-state)
                          [(Ok dst-reg)
                            (Ok
                              (str_cat.str-cat
                                lhs-asm
                                rhs-asm
                                "    "
                                mnemonic
                                predicate-separator
                                rhs-op
                                ", "
                                lhs-reg
                                ", "
                                dst-reg
                                "\n"
                                (compiler-backend-avx512-mask-store-dst
                                  assignments
                                  dst
                                  lanes
                                  dst-reg
                                  backend-state)))]
                          [(Err message)
                            (be_state.compiler-backend-instr-error
                              instr-diag
                              message)])])]
                  [(Err message)
                    (be_state.compiler-backend-instr-error instr-diag message)])])]
          [(Err message)
            (be_state.compiler-backend-instr-error instr-diag message)])))
    (be_operand.compiler-backend-avx512-shape-diagnostic
      type-segment-bases
      instr-diag
      elem-ty
      lanes)))

(define (compiler-backend-avx2-lane-bytes [lanes : i64]) : i64
  (if (> lanes 0)
    (/ 32 lanes)
    0))

(define (compiler-backend-avx2-int-compare-eq-mnemonic
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]) : String
  (match elem-ty
    [(or (I64) (U64)) "vpcmpeqq"]
    [(or (I32) (U32)) "vpcmpeqd"]
    [(or (I16) (U16)) "vpcmpeqw"]
    [(or (I8) (U8)) "vpcmpeqb"]
    [_ ""]))

(define (compiler-backend-avx2-int-compare-gt-mnemonic
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]) : String
  (match elem-ty
    [(or (I64) (U64)) "vpcmpgtq"]
    [(or (I32) (U32)) "vpcmpgtd"]
    [(or (I16) (U16)) "vpcmpgtw"]
    [(or (I8) (U8)) "vpcmpgtb"]
    [_ ""]))

(define (compiler-backend-avx2-unsigned-compare?
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]) : bool
  (match elem-ty
    [(or (U64) (U32) (U16) (U8)) true]
    [_ false]))

(define (compiler-backend-avx2-unsigned-sign-shift
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]) : i64
  (match elem-ty
    [(U64) 63]
    [(U32) 31]
    [(U16) 15]
    [(U8) 7]
    [_ 0]))

(define (compiler-backend-avx2-unsigned-sign-shift-mnemonic
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]) : String
  (match elem-ty
    [(U64) "vpsllq"]
    [(U32) "vpslld"]
    [(or (U16) (U8)) "vpsllw"]
    [_ ""]))

(define (compiler-backend-avx2-compare-invert-asm [reg : String] [tmp : String]) : String
  (str_cat.str-cat
    "    vpcmpeqd "
    tmp
    ", "
    tmp
    ", "
    tmp
    "\n    vpxor "
    tmp
    ", "
    reg
    ", "
    reg
    "\n"))

(define (compiler-backend-avx2-emit-signed-int-compare-asm
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs-reg : String]
  [rhs-reg : String]
  [dst-reg : String]
  [elem-ty : compiler_ast_types.AstType]) : String
  (let
    [eq-mnemonic : String
      (compiler-backend-avx2-int-compare-eq-mnemonic elem-ty)]
    [gt : String (compiler-backend-avx2-int-compare-gt-mnemonic elem-ty)]
    (match op
      [(Eq)
        (str_cat.str-cat
          "    "
          eq-mnemonic
          " "
          rhs-reg
          ", "
          lhs-reg
          ", "
          dst-reg
          "\n")]
      [(Ne)
        (str_cat.str-cat
          "    "
          eq-mnemonic
          " "
          rhs-reg
          ", "
          lhs-reg
          ", "
          dst-reg
          "\n"
          (compiler-backend-avx2-compare-invert-asm dst-reg "%ymm0"))]
      [(Gt)
        (str_cat.str-cat "    " gt " " rhs-reg ", " lhs-reg ", " dst-reg "\n")]
      [(Lt)
        (str_cat.str-cat "    " gt " " lhs-reg ", " rhs-reg ", " dst-reg "\n")]
      [(Ge)
        (str_cat.str-cat
          "    "
          gt
          " "
          lhs-reg
          ", "
          rhs-reg
          ", "
          dst-reg
          "\n"
          (compiler-backend-avx2-compare-invert-asm dst-reg "%ymm0"))]
      [(Le)
        (str_cat.str-cat
          "    "
          gt
          " "
          rhs-reg
          ", "
          lhs-reg
          ", "
          dst-reg
          "\n"
          (compiler-backend-avx2-compare-invert-asm dst-reg "%ymm0"))]
      [_ ""])))

(define (compiler-backend-avx2-emit-unsigned-int-compare-asm
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs-reg : String]
  [rhs-reg : String]
  [dst-reg : String]
  [elem-ty : compiler_ast_types.AstType]) : String
  (let
    [shift : i64 (compiler-backend-avx2-unsigned-sign-shift elem-ty)]
    [shift-op : String
      (compiler-backend-avx2-unsigned-sign-shift-mnemonic elem-ty)]
    [gt : String (compiler-backend-avx2-int-compare-gt-mnemonic elem-ty)]
    (if (or
      (= (string.string-length shift-op) 0)
      (= (string.string-length gt) 0)
      false)
      ""
      (let
        [bias-asm : String
          (str_cat.str-cat
            (match elem-ty
              [(U8)
                "    vpcmpeqd %ymm0, %ymm0, %ymm0\n    vpsrlw $15, %ymm0, %ymm0\n    vpsllw $7, %ymm0, %ymm0\n    vpackuswb %ymm0, %ymm0, %ymm0\n"]
              [_
                (str_cat.str-cat
                  "    vpcmpeqd %ymm0, %ymm0, %ymm0\n    "
                  shift-op
                  " $"
                  (string.int->string shift)
                  ", %ymm0, %ymm0\n")])
            "    vpxor %ymm0, "
            rhs-reg
            ", %ymm1\n    vpxor %ymm0, "
            lhs-reg
            ", "
            dst-reg
            "\n")]
        (match op
          [(Lt)
            (str_cat.str-cat
              bias-asm
              "    "
              gt
              " "
              dst-reg
              ", %ymm1, "
              dst-reg
              "\n")]
          [(Gt)
            (str_cat.str-cat
              bias-asm
              "    "
              gt
              " %ymm1, "
              dst-reg
              ", "
              dst-reg
              "\n")]
          [(Le)
            (str_cat.str-cat
              bias-asm
              "    "
              gt
              " %ymm1, "
              dst-reg
              ", "
              dst-reg
              "\n"
              (compiler-backend-avx2-compare-invert-asm dst-reg "%ymm0"))]
          [(Ge)
            (str_cat.str-cat
              bias-asm
              "    "
              gt
              " "
              dst-reg
              ", %ymm1, "
              dst-reg
              "\n"
              (compiler-backend-avx2-compare-invert-asm dst-reg "%ymm0"))]
          [_ ""])))))

(define (compiler-backend-avx2-emit-int-compare-asm
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs-reg : String]
  [rhs-reg : String]
  [dst-reg : String]
  [elem-ty : compiler_ast_types.AstType]) : String
  (match (& op)
    [(or (Eq) (Ne))
      (compiler-backend-avx2-emit-signed-int-compare-asm
        op
        lhs-reg
        rhs-reg
        dst-reg
        elem-ty)]
    [_
      (if (compiler-backend-avx2-unsigned-compare? elem-ty)
        (compiler-backend-avx2-emit-unsigned-int-compare-asm
          op
          lhs-reg
          rhs-reg
          dst-reg
          elem-ty)
        (compiler-backend-avx2-emit-signed-int-compare-asm
          op
          lhs-reg
          rhs-reg
          dst-reg
          elem-ty))]))

(define (compiler-backend-avx2-float-compare-mnemonic
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]) : String
  (match elem-ty
    [(F64) "vcmppd"]
    [(F32) "vcmpps"]
    [_ ""]))

(define (compiler-backend-emit-avx2-vector-compare
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (be_operand.compiler-backend-avx2-shape-ok? elem-ty lanes)
    (match (be_operand.compiler-backend-vector-register-use
      assignments
      lhs
      "cmp lhs"
      "ymm"
      elem-ty
      "%ymm14"
      backend-state)
      [(Ok lhs-use)
        (match lhs-use
          [(Use lhs-asm lhs-reg)
            (match (be_operand.compiler-backend-vector-register-use
              assignments
              rhs
              "cmp rhs"
              "ymm"
              elem-ty
              "%ymm15"
              backend-state)
              [(Ok rhs-use)
                (match rhs-use
                  [(Use rhs-asm rhs-reg)
                    (match (compiler-backend-vector-dst-reg
                      assignments
                      dst
                      "cmp dst"
                      "ymm"
                      "%ymm14"
                      backend-state)
                      [(Ok dst-reg)
                        (let
                          [float-mnemonic : String
                            (compiler-backend-avx2-float-compare-mnemonic
                              elem-ty)]
                          [predicate-separator : String
                            (compiler-backend-vector-compare-predicate-separator
                              op
                              elem-ty)]
                          [cmp-asm : String
                            (if (> (string.string-length float-mnemonic) 0)
                              (if (>
                                (string.string-length predicate-separator)
                                0)
                                (str_cat.str-cat
                                  "    "
                                  float-mnemonic
                                  predicate-separator
                                  rhs-reg
                                  ", "
                                  lhs-reg
                                  ", "
                                  dst-reg
                                  "\n")
                                "")
                              (compiler-backend-avx2-emit-int-compare-asm
                                op
                                lhs-reg
                                rhs-reg
                                (be_state.compiler-backend-global-shared-view
                                  dst-reg)
                                elem-ty))]
                          (if (= (string.string-length cmp-asm) 0)
                            (be_state.compiler-backend-instr-error
                              instr-diag
                              "backend: unsupported AVX2 vector compare")
                            (Ok
                              (str_cat.str-cat
                                lhs-asm
                                rhs-asm
                                cmp-asm
                                (compiler-backend-vector-store-dst
                                  assignments
                                  dst
                                  "ymm"
                                  (I8)
                                  dst-reg
                                  backend-state)))))]
                      [(Err message)
                        (be_state.compiler-backend-instr-error
                          instr-diag
                          message)])])]
              [(Err message)
                (be_state.compiler-backend-instr-error instr-diag message)])])]
      [(Err message) (be_state.compiler-backend-instr-error instr-diag message)])
    (be_operand.compiler-backend-avx2-shape-diagnostic
      type-segment-bases
      instr-diag
      elem-ty
      lanes)))

(define (compiler-backend-sse2-two-addr-op-asm
  [move-op : (& move-op str)]
  [op-mnemonic : (& op-mnemonic str)]
  [a-reg : (& a-reg str)]
  [b-reg : (& b-reg str)]
  [dst-reg : (& dst-reg str)]) : String
  (cond
    [(string.eq dst-reg a-reg)
      (str_cat.str-cat "    " op-mnemonic " " b-reg ", " dst-reg "\n")]
    [(string.eq dst-reg b-reg)
      (str_cat.str-cat
        "    "
        move-op
        " "
        a-reg
        ", %xmm0\n    "
        op-mnemonic
        " "
        b-reg
        ", %xmm0\n    "
        move-op
        " %xmm0, "
        dst-reg
        "\n")]
    [else
      (str_cat.str-cat
        "    "
        move-op
        " "
        a-reg
        ", "
        dst-reg
        "\n    "
        op-mnemonic
        " "
        b-reg
        ", "
        dst-reg
        "\n")]))

(define (compiler-backend-sse2-compare-invert-asm [dst-reg : (& dst-reg str)]) : String
  (str_cat.str-cat "    pcmpeqd %xmm0, %xmm0\n    pxor %xmm0, " dst-reg "\n"))

(define (compiler-backend-sse2-emit-i64-compare-asm
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs-reg : (& lhs-reg str)]
  [rhs-reg : (& rhs-reg str)]
  [dst-reg : (& dst-reg str)]
  [unsigned? : bool]) : String
  (match op
    [(or (Eq) (Ne))
      (let
        [invert-asm : String
          (match op
            [(Ne) "    pcmpeqd %xmm1, %xmm1\n    pxor %xmm1, %xmm0\n"]
            [_ ""])]
        (str_cat.str-cat
          "    movdqa "
          lhs-reg
          ", %xmm0\n    pcmpeqd "
          rhs-reg
          ", %xmm0\n    pshufd $177, %xmm0, %xmm1\n    pand %xmm1, %xmm0\n"
          invert-asm
          "    movdqa %xmm0, "
          dst-reg
          "\n"))]
    [(or (Gt) (Lt) (Ge) (Le))
      (let
        [swap? : bool
          (match op
            [(or (Lt) (Ge)) true]
            [_ false])]
        [invert? : bool
          (match op
            [(or (Le) (Ge)) true]
            [_ false])]
        [a-reg : String
          (if swap?
            (string.copy rhs-reg)
            (string.copy lhs-reg))]
        [b-reg : String
          (if swap?
            (string.copy lhs-reg)
            (string.copy rhs-reg))]
        [bias-asm : String
          (if unsigned?
            "    pcmpeqd %xmm0, %xmm0\n    pslld $31, %xmm0\n"
            "    pcmpeqd %xmm0, %xmm0\n    psrlq $63, %xmm0\n    psllq $31, %xmm0\n")]
        (str_cat.str-cat
          bias-asm
          "    movdqa %xmm0, %xmm1\n    pxor "
          a-reg
          ", %xmm0\n    pxor "
          b-reg
          ", %xmm1\n    movdqa %xmm0, "
          dst-reg
          "\n    pcmpgtd %xmm1, "
          dst-reg
          "\n    pcmpeqd %xmm1, %xmm0\n    pshufd $160, "
          dst-reg
          ", %xmm1\n    pand %xmm1, %xmm0\n    por %xmm0, "
          dst-reg
          "\n    pshufd $245, "
          dst-reg
          ", "
          dst-reg
          "\n"
          (if invert?
            (compiler-backend-sse2-compare-invert-asm dst-reg)
            "")))]
    [_ ""]))

(define (compiler-backend-sse2-emit-int-compare-asm
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs-reg : (& lhs-reg str)]
  [rhs-reg : (& rhs-reg str)]
  [dst-reg : (& dst-reg str)]
  [elem-ty : compiler_ast_types.AstType]) : String
  (match (& elem-ty)
    [(I64)
      (compiler-backend-sse2-emit-i64-compare-asm
        op
        lhs-reg
        rhs-reg
        dst-reg
        false)]
    [(U64)
      (compiler-backend-sse2-emit-i64-compare-asm
        op
        lhs-reg
        rhs-reg
        dst-reg
        true)]
    [_
      (let
        [eq-op : String
          (match (& elem-ty)
            [(or (I32) (U32)) "pcmpeqd"]
            [(or (I16) (U16)) "pcmpeqw"]
            [(or (I8) (U8)) "pcmpeqb"]
            [_ ""])]
        [gt-op : String
          (match (& elem-ty)
            [(or (I32) (U32)) "pcmpgtd"]
            [(or (I16) (U16)) "pcmpgtw"]
            [(or (I8) (U8)) "pcmpgtb"]
            [_ ""])]
        [unsigned? : bool (compiler-backend-avx2-unsigned-compare? (& elem-ty))]
        (if (or
          (= (string.string-length eq-op) 0)
          (= (string.string-length gt-op) 0))
          ""
          (match op
            [(Eq)
              (compiler-backend-sse2-two-addr-op-asm
                "movdqa"
                (& eq-op)
                lhs-reg
                rhs-reg
                dst-reg)]
            [(Ne)
              (str_cat.str-cat
                (compiler-backend-sse2-two-addr-op-asm
                  "movdqa"
                  (& eq-op)
                  lhs-reg
                  rhs-reg
                  dst-reg)
                (compiler-backend-sse2-compare-invert-asm dst-reg))]
            [_
              (if unsigned?
                (let
                  [bias-asm : String
                    (match (& elem-ty)
                      [(U32) "    pcmpeqd %xmm0, %xmm0\n    pslld $31, %xmm0\n"]
                      [(U16) "    pcmpeqd %xmm0, %xmm0\n    psllw $15, %xmm0\n"]
                      [(U8)
                        "    pcmpeqd %xmm0, %xmm0\n    psrlw $15, %xmm0\n    psllw $7, %xmm0\n    packuswb %xmm0, %xmm0\n"]
                      [_ ""])]
                  [setup : String
                    (str_cat.str-cat
                      bias-asm
                      "    movdqa %xmm0, %xmm1\n    pxor "
                      lhs-reg
                      ", %xmm0\n    pxor "
                      rhs-reg
                      ", %xmm1\n")]
                  (match op
                    [(Gt)
                      (str_cat.str-cat
                        setup
                        "    "
                        gt-op
                        " %xmm1, %xmm0\n    movdqa %xmm0, "
                        dst-reg
                        "\n")]
                    [(Lt)
                      (str_cat.str-cat
                        setup
                        "    "
                        gt-op
                        " %xmm0, %xmm1\n    movdqa %xmm1, "
                        dst-reg
                        "\n")]
                    [(Le)
                      (str_cat.str-cat
                        setup
                        "    "
                        gt-op
                        " %xmm1, %xmm0\n    pcmpeqd %xmm1, %xmm1\n    pxor %xmm1, %xmm0\n    movdqa %xmm0, "
                        dst-reg
                        "\n")]
                    [(Ge)
                      (str_cat.str-cat
                        setup
                        "    "
                        gt-op
                        " %xmm0, %xmm1\n    pcmpeqd %xmm0, %xmm0\n    pxor %xmm0, %xmm1\n    movdqa %xmm1, "
                        dst-reg
                        "\n")]
                    [_ ""]))
                (match op
                  [(Gt)
                    (compiler-backend-sse2-two-addr-op-asm
                      "movdqa"
                      (& gt-op)
                      lhs-reg
                      rhs-reg
                      dst-reg)]
                  [(Lt)
                    (compiler-backend-sse2-two-addr-op-asm
                      "movdqa"
                      (& gt-op)
                      rhs-reg
                      lhs-reg
                      dst-reg)]
                  [(Le)
                    (str_cat.str-cat
                      (compiler-backend-sse2-two-addr-op-asm
                        "movdqa"
                        (& gt-op)
                        lhs-reg
                        rhs-reg
                        dst-reg)
                      (compiler-backend-sse2-compare-invert-asm dst-reg))]
                  [(Ge)
                    (str_cat.str-cat
                      (compiler-backend-sse2-two-addr-op-asm
                        "movdqa"
                        (& gt-op)
                        rhs-reg
                        lhs-reg
                        dst-reg)
                      (compiler-backend-sse2-compare-invert-asm dst-reg))]
                  [_ ""]))])))]))

(define (compiler-backend-sse2-emit-float-compare-asm
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs-reg : (& lhs-reg str)]
  [rhs-reg : (& rhs-reg str)]
  [dst-reg : (& dst-reg str)]
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]) : String
  (let
    [cmp-op : String
      (match elem-ty
        [(F64) "cmppd"]
        [(F32) "cmpps"]
        [_ ""])]
    [move-op : String (compiler-backend-sse2-reg-move elem-ty)]
    [imm : String
      (match (& op)
        [(Eq) "$0"]
        [(or (Lt) (Gt)) "$1"]
        [(or (Le) (Ge)) "$2"]
        [(Ne) "$4"]
        [_ ""])]
    [swap? : bool
      (match (& op)
        [(or (Gt) (Ge)) true]
        [_ false])]
    (if (or
      (= (string.string-length cmp-op) 0)
      (= (string.string-length imm) 0))
      ""
      (let
        [a-reg : String
          (if swap?
            (string.copy rhs-reg)
            (string.copy lhs-reg))]
        [b-reg : String
          (if swap?
            (string.copy lhs-reg)
            (string.copy rhs-reg))]
        (cond
          [(string.eq dst-reg (& a-reg))
            (str_cat.str-cat "    " cmp-op " " imm ", " b-reg ", " dst-reg "\n")]
          [(string.eq dst-reg (& b-reg))
            (str_cat.str-cat
              "    "
              move-op
              " "
              a-reg
              ", %xmm0\n    "
              cmp-op
              " "
              imm
              ", "
              b-reg
              ", %xmm0\n    "
              move-op
              " %xmm0, "
              dst-reg
              "\n")]
          [else
            (str_cat.str-cat
              "    "
              move-op
              " "
              a-reg
              ", "
              dst-reg
              "\n    "
              cmp-op
              " "
              imm
              ", "
              b-reg
              ", "
              dst-reg
              "\n")])))))

(define (compiler-backend-emit-sse2-vector-compare
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (be_operand.compiler-backend-sse2-shape-ok? elem-ty lanes)
    (match (be_operand.compiler-backend-vector-register-use
      assignments
      lhs
      "cmp lhs"
      "xmm"
      elem-ty
      "%xmm14"
      backend-state)
      [(Ok lhs-use)
        (match lhs-use
          [(Use lhs-asm lhs-reg)
            (match (be_operand.compiler-backend-vector-register-use
              assignments
              rhs
              "cmp rhs"
              "xmm"
              elem-ty
              "%xmm15"
              backend-state)
              [(Ok rhs-use)
                (match rhs-use
                  [(Use rhs-asm rhs-reg)
                    (match (compiler-backend-vector-dst-reg
                      assignments
                      dst
                      "cmp dst"
                      "xmm"
                      "%xmm14"
                      backend-state)
                      [(Ok dst-reg)
                        (let
                          [cmp-asm : String
                            (if (be_operand.compiler-backend-float-type?
                              (& elem-ty))
                              (compiler-backend-sse2-emit-float-compare-asm
                                op
                                (& lhs-reg)
                                (& rhs-reg)
                                (& dst-reg)
                                (& elem-ty))
                              (compiler-backend-sse2-emit-int-compare-asm
                                op
                                (& lhs-reg)
                                (& rhs-reg)
                                (& dst-reg)
                                elem-ty))]
                          (if (= (string.string-length cmp-asm) 0)
                            (be_state.compiler-backend-instr-error
                              instr-diag
                              "backend: unsupported SSE2 vector compare")
                            (Ok
                              (str_cat.str-cat
                                lhs-asm
                                rhs-asm
                                cmp-asm
                                (compiler-backend-vector-store-dst
                                  assignments
                                  dst
                                  "xmm"
                                  (I8)
                                  dst-reg
                                  backend-state)))))]
                      [(Err message)
                        (be_state.compiler-backend-instr-error
                          instr-diag
                          message)])])]
              [(Err message)
                (be_state.compiler-backend-instr-error instr-diag message)])])]
      [(Err message) (be_state.compiler-backend-instr-error instr-diag message)])
    (be_operand.compiler-backend-sse2-shape-diagnostic
      type-segment-bases
      instr-diag
      elem-ty
      lanes)))

(define (compiler-backend-emit-vector-compare
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (cond
    [(be_state.compiler-backend-current-mode-avx2?
        (be_state.compiler-backend-state-function-state backend-state))
      (compiler-backend-emit-avx2-vector-compare
        type-segment-bases
        assignments
        dst
        op
        lhs
        rhs
        lanes
        elem-ty
        instr-diag
        backend-state)]
    [(be_state.compiler-backend-current-mode-sse2?
        (be_state.compiler-backend-state-function-state backend-state))
      (compiler-backend-emit-sse2-vector-compare
        type-segment-bases
        assignments
        dst
        op
        lhs
        rhs
        lanes
        elem-ty
        instr-diag
        backend-state)]
    [else
      (compiler-backend-emit-avx512-vector-compare
        type-segment-bases
        assignments
        dst
        op
        lhs
        rhs
        lanes
        elem-ty
        instr-diag
        backend-state)]))

(define (compiler-backend-avx2-gather-mask-reg [dst-reg : String]) : String
  (if (string.eq
    (be_operand.compiler-backend-vector-reg-lower-ymm dst-reg)
    "%ymm13")
    "%ymm12"
    "%ymm13"))

(define (compiler-backend-gather-address-index
  [index : compiler_ir_types.CompilerIrValue]
  [lane-offset : bool]) : compiler_ir_types.CompilerIrValue
  (if lane-offset
    (I64 0)
    index))

(define (compiler-backend-emit-simd-gather-adjustments
  [mode : be_state.CompilerBackendMode]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [logical-base : compiler_ir_types.CompilerIrValue]
  [lane-offset : bool]
  [dword : bool]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultBackendGatherAdjust
  (if (not lane-offset)
    (Ok (be_state.CompilerBackendGatherAdjust "" ""))
    (let
      [first-load
        (try
          (compiler-backend-simd-splat-load
            mode
            assignments
            dst
            (be_state.compiler-backend-global-shared-view logical-base)
            (I64)
            backend-state))]
      [second-load
        (try
          (compiler-backend-simd-splat-load
            mode
            assignments
            dst
            logical-base
            (I64)
            backend-state))]
      (Ok
        (be_state.CompilerBackendGatherAdjust
          (compiler-backend-gather-lane-add mode first-load "")
          (if dword
            (compiler-backend-gather-lane-add
              mode
              second-load
              (match mode
                [(Avx512) "+64"]
                [_ "+32"]))
            ""))))))

;; LOAD ends by broadcasting the logical base into v14; add the i64 lane ids at
;; OFFSET into the lane-id row and fold them into the v15 index vector.
(define (compiler-backend-gather-lane-add
  [mode : be_state.CompilerBackendMode]
  [load : String]
  [offset : String]) : String
  (let
    [w : String (compiler-backend-mode-width mode)]
    (str_cat.str-cat
      load
      "%"
      w
      "14\n    vpaddq "
      (match mode
        [(Avx512) (be_facts.compiler-backend-avx512-i64-lane-id-label)]
        [_ (be_facts.compiler-backend-avx2-i64-lane-id-label)])
      offset
      "(%rip), %"
      w
      "14, %"
      w
      "14\n    vpaddq %"
      w
      "14, %"
      w
      "15, %"
      w
      "15\n")))

(define (compiler-backend-emit-avx2-gather-load
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [base : compiler_ir_types.CompilerIrValue]
  [index-base : compiler_ir_types.CompilerIrValue]
  [index : compiler_ir_types.CompilerIrValue]
  [lane-offset : bool]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [mnemonic : String
      (be_operand.compiler-backend-avx2-gather-mnemonic elem-ty)]
    [dword : bool
      (be_operand.compiler-backend-gather-dword-element?
        (be_state.compiler-backend-global-shared-view elem-ty))]
    (if (or
      (string.eq mnemonic "")
      (if dword
        (not (= lanes 8))
        (not (= lanes 4))))
      (be_operand.compiler-backend-avx2-shape-diagnostic
        type-segment-bases
        instr-diag
        elem-ty
        lanes)
      (match (compiler-backend-vector-dst-reg
        assignments
        dst
        "gather dst"
        "ymm"
        (be_operand.compiler-backend-vector-spill-scratch "ymm" 0)
        backend-state)
        [(Ok dst-reg)
          (match (compiler-backend-emit-simd-indexed-address
            type-segment-bases
            assignments
            index-base
            (compiler-backend-gather-address-index
              (be_state.compiler-backend-global-shared-view index)
              lane-offset)
            (I64)
            backend-state)
            [(Ok index-plan)
              (let
                [index-asm : String index-plan.asm]
                [index-addr : String index-plan.addr]
                [base-reg : String
                  (be_operand.compiler-backend-scavenge-reg-here
                    (be_operand.compiler-backend-scavenge-exclude-ops2
                      backend-state
                      assignments
                      (be_state.compiler-backend-global-shared-view base)
                      base)
                    7
                    "%r8"
                    backend-state)]
                [mask-reg : String
                  (compiler-backend-avx2-gather-mask-reg
                    (be_state.compiler-backend-global-shared-view dst-reg))]
                [mask-xmm : String
                  (be_operand.compiler-backend-vector-reg-lower-xmm
                    (be_state.compiler-backend-global-shared-view mask-reg))]
                [dst-xmm : String
                  (be_operand.compiler-backend-vector-reg-lower-xmm
                    (be_state.compiler-backend-global-shared-view dst-reg))]
                [stack-bytes : i64
                  (be_operand.compiler-backend-simd-scratch-gather-bytes
                    true
                    dword)]
                [result-off : i64 96]
                (match (compiler-backend-emit-simd-base-data-pointer
                  assignments
                  base
                  (be_state.compiler-backend-global-shared-view base-reg)
                  backend-state)
                  [(Ok base-asm)
                    (let
                      [adjust
                        (try
                          (compiler-backend-emit-simd-gather-adjustments
                            (Avx2)
                            assignments
                            dst
                            index
                            lane-offset
                            dword
                            backend-state))]
                      (be_operand.compiler-backend-simd-scratch-checked
                        backend-state
                        instr-diag
                        stack-bytes
                        (Ok
                          (str_cat.str-cat
                            index-asm
                            "    vmovdqu "
                            index-addr
                            ", %ymm15\n"
                            (if dword
                              (str_cat.str-cat
                                "    vmovdqu 32"
                                index-addr
                                ", %ymm14\n")
                              "")
                            "    vmovdqu "
                            mask-reg
                            ", "
                            (be_operand.compiler-backend-simd-scratch-address
                              backend-state
                              0)
                            "\n"
                            (if dword
                              (str_cat.str-cat
                                "    vmovdqu %ymm14, "
                                (be_operand.compiler-backend-simd-scratch-address
                                  backend-state
                                  64)
                                "\n")
                              "")
                            adjust.first
                            base-asm
                            "    vpxor "
                            dst-reg
                            ", "
                            dst-reg
                            ", "
                            dst-reg
                            "\n    vpcmpeqd "
                            mask-reg
                            ", "
                            mask-reg
                            ", "
                            mask-reg
                            "\n    "
                            mnemonic
                            " "
                            (if dword
                              (owned_view.compiler-owned-shared-view mask-xmm)
                              (owned_view.compiler-owned-shared-view mask-reg))
                            ", ("
                            base-reg
                            ",%ymm15,"
                            (if dword
                              "4"
                              "8")
                            "), "
                            (if dword
                              (owned_view.compiler-owned-shared-view dst-xmm)
                              (owned_view.compiler-owned-shared-view dst-reg))
                            "\n"
                            (if dword
                              (str_cat.str-cat
                                "    vmovdqu "
                                dst-xmm
                                ", "
                                (be_operand.compiler-backend-simd-scratch-address
                                  backend-state
                                  result-off)
                                "\n    vpxor "
                                dst-reg
                                ", "
                                dst-reg
                                ", "
                                dst-reg
                                "\n    vpcmpeqd "
                                mask-reg
                                ", "
                                mask-reg
                                ", "
                                mask-reg
                                "\n    vmovdqu "
                                (be_operand.compiler-backend-simd-scratch-address
                                  backend-state
                                  64)
                                ", %ymm15\n"
                                adjust.second
                                base-asm
                                "    "
                                mnemonic
                                " "
                                mask-xmm
                                ", ("
                                base-reg
                                ",%ymm15,4), "
                                dst-xmm
                                "\n    vmovdqu "
                                dst-xmm
                                ", "
                                (be_operand.compiler-backend-simd-scratch-address
                                  backend-state
                                  (+ result-off 16))
                                "\n    vmovdqu "
                                (be_operand.compiler-backend-simd-scratch-address
                                  backend-state
                                  result-off)
                                ", "
                                dst-reg
                                "\n")
                              "")
                            "    vmovdqu "
                            (be_operand.compiler-backend-simd-scratch-address
                              backend-state
                              0)
                            ", "
                            mask-reg
                            "\n"
                            (compiler-backend-vector-store-dst
                              assignments
                              dst
                              "ymm"
                              elem-ty
                              dst-reg
                              backend-state)))))]
                  [(Err message)
                    (be_state.compiler-backend-instr-error-from
                      instr-diag
                      message)]))]
            [(Err message)
              (be_state.compiler-backend-instr-error-from instr-diag message)])]
        [(Err message)
          (be_state.compiler-backend-instr-error instr-diag message)]))))

(define (compiler-backend-emit-avx512-gather-load
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [base : compiler_ir_types.CompilerIrValue]
  [index-base : compiler_ir_types.CompilerIrValue]
  [index : compiler_ir_types.CompilerIrValue]
  [lane-offset : bool]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [mnemonic : String
      (be_operand.compiler-backend-avx512-gather-mnemonic elem-ty)]
    [dword : bool
      (be_operand.compiler-backend-gather-dword-element?
        (be_state.compiler-backend-global-shared-view elem-ty))]
    (if (or
      (string.eq mnemonic "")
      (if dword
        (not (= lanes 16))
        (not (= lanes 8))))
      (be_operand.compiler-backend-avx512-shape-diagnostic
        type-segment-bases
        instr-diag
        elem-ty
        lanes)
      (match (compiler-backend-vector-dst-reg
        assignments
        dst
        "gather dst"
        "zmm"
        (be_operand.compiler-backend-vector-spill-scratch "zmm" 0)
        backend-state)
        [(Ok dst-reg)
          (match (compiler-backend-emit-simd-indexed-address
            type-segment-bases
            assignments
            index-base
            (compiler-backend-gather-address-index
              (be_state.compiler-backend-global-shared-view index)
              lane-offset)
            (I64)
            backend-state)
            [(Ok index-plan)
              (let
                [index-asm : String index-plan.asm]
                [index-addr : String index-plan.addr]
                [base-reg : String
                  (be_operand.compiler-backend-scavenge-reg-here
                    (be_operand.compiler-backend-scavenge-exclude-ops2
                      backend-state
                      assignments
                      (be_state.compiler-backend-global-shared-view base)
                      base)
                    7
                    "%r8"
                    backend-state)]
                [dst-ymm : String
                  (be_operand.compiler-backend-vector-reg-lower-ymm
                    (be_state.compiler-backend-global-shared-view dst-reg))]
                (match (compiler-backend-emit-simd-base-data-pointer
                  assignments
                  base
                  (be_state.compiler-backend-global-shared-view base-reg)
                  backend-state)
                  [(Ok base-asm)
                    (let
                      [adjust
                        (try
                          (compiler-backend-emit-simd-gather-adjustments
                            (Avx512)
                            assignments
                            dst
                            index
                            lane-offset
                            dword
                            backend-state))]
                      (be_operand.compiler-backend-simd-scratch-checked
                        backend-state
                        instr-diag
                        (be_operand.compiler-backend-simd-scratch-gather-bytes
                          false
                          dword)
                        (Ok
                          (str_cat.str-cat
                            index-asm
                            "    vmovdqu64 "
                            index-addr
                            ", %zmm15\n"
                            (if dword
                              (str_cat.str-cat
                                "    vmovdqu64 64"
                                index-addr
                                ", %zmm14\n")
                              "")
                            (if dword
                              (str_cat.str-cat
                                "    vmovdqu64 %zmm14, "
                                (be_operand.compiler-backend-simd-scratch-address
                                  backend-state
                                  0)
                                "\n")
                              "")
                            adjust.first
                            base-asm
                            "    kxnorw %k7, %k7, %k7\n    vpxord "
                            dst-reg
                            ", "
                            dst-reg
                            ", "
                            dst-reg
                            "\n    "
                            mnemonic
                            " ("
                            base-reg
                            ",%zmm15,"
                            (if dword
                              "4"
                              "8")
                            "), "
                            (if dword
                              (owned_view.compiler-owned-shared-view dst-ymm)
                              (owned_view.compiler-owned-shared-view dst-reg))
                            "{%k7}\n"
                            (if dword
                              (str_cat.str-cat
                                "    vmovdqu32 "
                                dst-ymm
                                ", "
                                (be_operand.compiler-backend-simd-scratch-address
                                  backend-state
                                  64)
                                "\n    kxnorw %k7, %k7, %k7\n    vpxord "
                                dst-reg
                                ", "
                                dst-reg
                                ", "
                                dst-reg
                                "\n    vmovdqu64 "
                                (be_operand.compiler-backend-simd-scratch-address
                                  backend-state
                                  0)
                                ", %zmm15\n"
                                adjust.second
                                base-asm
                                "    "
                                mnemonic
                                " ("
                                base-reg
                                ",%zmm15,4), "
                                dst-ymm
                                "{%k7}\n    vmovdqu32 "
                                dst-ymm
                                ", "
                                (be_operand.compiler-backend-simd-scratch-address
                                  backend-state
                                  96)
                                "\n    vmovdqu32 "
                                (be_operand.compiler-backend-simd-scratch-address
                                  backend-state
                                  64)
                                ", "
                                dst-reg
                                "\n")
                              "")
                            (compiler-backend-vector-store-dst
                              assignments
                              dst
                              "zmm"
                              elem-ty
                              dst-reg
                              backend-state)))))]
                  [(Err message)
                    (be_state.compiler-backend-instr-error-from
                      instr-diag
                      message)]))]
            [(Err message)
              (be_state.compiler-backend-instr-error-from instr-diag message)])]
        [(Err message)
          (be_state.compiler-backend-instr-error instr-diag message)]))))

(define (compiler-backend-emit-gather-load
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [base : compiler_ir_types.CompilerIrValue]
  [index-base : compiler_ir_types.CompilerIrValue]
  [index : compiler_ir_types.CompilerIrValue]
  [lane-offset : bool]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (be_state.compiler-backend-current-mode-avx2?
    (be_state.compiler-backend-state-function-state backend-state))
    (compiler-backend-emit-avx2-gather-load
      type-segment-bases
      assignments
      dst
      base
      index-base
      index
      lane-offset
      lanes
      elem-ty
      instr-diag
      backend-state)
    (compiler-backend-emit-avx512-gather-load
      type-segment-bases
      assignments
      dst
      base
      index-base
      index
      lane-offset
      lanes
      elem-ty
      instr-diag
      backend-state)))

(define (compiler-backend-shuffle-label
  [function : String]
  [current-label : i64]
  [dst : i64]
  [suffix : String]) : String
  (be_operand.compiler-backend-asm-label
    function
    (compiler_ir_types.compiler-ir-label
      (&
        (str_cat.str-cat
          "vector_shuffle_"
          (compiler_ir_types.compiler-ir-label-text current-label)
          "_v"
          (string.int->string dst)
          suffix)))))

(define (compiler-backend-shuffle-selector-offset
  [lane : i64]
  [selector-lanes : i64]
  [width-bytes : i64]) : i64
  (if (< lane selector-lanes)
    (* lane 8)
    (+ width-bytes (* (- lane selector-lanes) 8))))

(define (compiler-backend-shuffle-index-lane-copy-asm
  [lane : i64]
  [lanes : i64]
  [selector-lanes : i64]
  [width-bytes : i64]
  [index-offset : i64]
  [dword : bool]
  [avx512 : bool]
  [value-reg : String]
  [backend-state : be_state.CompilerBackendState]) : String
  (if (>= lane lanes)
    ""
    (let
      [selector-slot : String
        (be_operand.compiler-backend-simd-scratch-address
          backend-state
          (compiler-backend-shuffle-selector-offset
            lane
            selector-lanes
            width-bytes))]
      [index-slot : String
        (be_operand.compiler-backend-simd-scratch-address
          backend-state
          (+
            index-offset
            (if dword
              (* lane 4)
              (* lane 8))))]
      [value-reg32 : String
        (be_operand.compiler-backend-reg-part
          (be_state.compiler-backend-global-shared-view value-reg)
          4)]
      [copy-asm : String
        (if dword
          (str_cat.str-cat "    movl " value-reg32 ", " index-slot "\n")
          (if avx512
            (str_cat.str-cat "    movq " value-reg ", " index-slot "\n")
            (str_cat.str-cat
              "    shll $1, "
              value-reg32
              "\n    movl "
              value-reg32
              ", "
              index-slot
              "\n    addl $1, "
              value-reg32
              "\n    movl "
              value-reg32
              ", "
              (be_operand.compiler-backend-simd-scratch-address
                backend-state
                (+ index-offset (* lane 8) 4))
              "\n")))]
      (str_cat.str-cat
        "    movq "
        selector-slot
        ", "
        value-reg
        "\n"
        copy-asm
        (compiler-backend-shuffle-index-lane-copy-asm
          (+ lane 1)
          lanes
          selector-lanes
          width-bytes
          index-offset
          dword
          avx512
          value-reg
          backend-state)))))

;; Validate every selector vector at once. Predicated lowering zeroes inactive
;; destination lanes, so zero is a harmless source selector for those slots.
;; AVX2 combines a signed upper-bound comparison with the selectors' sign bits;
;; AVX-512 can compare the i64 selectors as unsigned values directly. Both
;; paths reduce all low/high selector halves and issue one bounds-abort branch.
(define (compiler-backend-shuffle-vector-check-asm
  [avx512 : bool]
  [selector-count : i64]
  [low-slot : (& low-slot str)]
  [high-slot : (& high-slot str)]
  [active-reg : String]
  [value-reg : String]
  [abort-label : (& abort-label str)]) : String
  (let
    [active-reg32 : String
      (be_operand.compiler-backend-reg-part
        (be_state.compiler-backend-global-shared-view active-reg)
        4)]
    [value-reg32 : String
      (be_operand.compiler-backend-reg-part
        (be_state.compiler-backend-global-shared-view value-reg)
        4)]
    (if avx512
      (str_cat.str-cat
        "    leaq -1("
        active-reg
        "), "
        value-reg
        "\n    vpbroadcastq "
        value-reg
        ", %zmm0\n    vmovdqu64 "
        low-slot
        ", %zmm1\n    vpcmpuq $6, %zmm0, %zmm1, %k7\n    kmovw %k7, "
        value-reg32
        "\n"
        (if (> selector-count 1)
          (str_cat.str-cat
            "    vmovdqu64 "
            high-slot
            ", %zmm1\n    vpcmpuq $6, %zmm0, %zmm1, %k7\n    kmovw %k7, "
            active-reg32
            "\n    orl "
            active-reg32
            ", "
            value-reg32
            "\n")
          "")
        "    testl "
        value-reg32
        ", "
        value-reg32
        "\n    jne "
        abort-label
        "\n")
      (str_cat.str-cat
        "    leaq -1("
        active-reg
        "), "
        value-reg
        "\n    vmovq "
        value-reg
        ", %xmm0\n    vpbroadcastq %xmm0, %ymm0\n    vmovdqu "
        low-slot
        ", %ymm1\n    vpmovmskb %ymm1, "
        value-reg32
        "\n    vpcmpgtq %ymm0, %ymm1, %ymm1\n    vpmovmskb %ymm1, "
        active-reg32
        "\n    orl "
        active-reg32
        ", "
        value-reg32
        "\n"
        (if (> selector-count 1)
          (str_cat.str-cat
            "    vmovdqu "
            high-slot
            ", %ymm1\n    vpmovmskb %ymm1, "
            active-reg32
            "\n    orl "
            active-reg32
            ", "
            value-reg32
            "\n    vpcmpgtq %ymm0, %ymm1, %ymm1\n    vpmovmskb %ymm1, "
            active-reg32
            "\n    orl "
            active-reg32
            ", "
            value-reg32
            "\n")
          "")
        "    testl "
        value-reg32
        ", "
        value-reg32
        "\n    jne "
        abort-label
        "\n"))))

(define (compiler-backend-emit-vector-shuffle
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [function : String]
  [current-label : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [source : compiler_ir_types.CompilerIrValue]
  [selector-low : compiler_ir_types.CompilerIrValue]
  [selector-high : compiler_ir_types.CompilerIrMaybeValue]
  [active-lanes : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]
  [plan : be_state.CompilerBackendRuntimePlan]
  [program-index : be_state.CompilerBackendProgramIndex]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]) : be_state.ResultCompilerBackend
  (let
    [avx512 : bool (be_operand.compiler-backend-avx512-shape-ok? elem-ty lanes)]
    [shape-ok : bool
      (or avx512 (be_operand.compiler-backend-avx2-shape-ok? elem-ty lanes))]
    [width : String
      (if avx512
        "zmm"
        "ymm")]
    [width-bytes : i64
      (if avx512
        64
        32)]
    [selector-lanes : i64
      (if avx512
        8
        4)]
    [dword : bool
      (match (& elem-ty)
        [(or (I32) (U32) (F32)) true]
        [_ false])]
    [needs-high : bool (> lanes selector-lanes)]
    [active-home : String
      (be_operand.compiler-backend-value-scalar-register-home
        program-index.backend-state
        assignments
        (& active-lanes))]
    [active-reg : String
      (be_operand.compiler-backend-scavenge-reg-here
        (be_operand.compiler-backend-one-exclude (string.copy (& active-home)))
        1
        "%r10"
        program-index.backend-state)]
    [value-reg : String
      (be_operand.compiler-backend-scavenge-reg-here
        (be_operand.compiler-backend-two-exclude
          active-home
          (string.copy (& active-reg)))
        2
        "%r11"
        program-index.backend-state)]
    [index-reg : String
      (if avx512
        "%zmm0"
        "%ymm0")]
    [dst-scratch : String
      (if avx512
        "%zmm1"
        "%ymm1")]
    ;; Vector homes start at vec2, so vec0/vec1 are backend-owned scratch.
    ;; Operand spills reuse vec0 sequentially before it becomes the index.
    [source-scratch : String
      (if avx512
        "%zmm0"
        "%ymm0")]
    [selector-scratch : String
      (if avx512
        "%zmm0"
        "%ymm0")]
    [high-error : String
      (match (be_state.compiler-backend-global-shared-view selector-high)
        [(Some high-value)
          (match (let
            [elem-ty (compiler_ast_types.AstType.I64)]
            (be_operand.compiler-backend-vector-register-use
              assignments
              high-value
              "shuffle selector high"
              (be_state.compiler-backend-global-shared-view width)
              elem-ty
              (be_state.compiler-backend-global-shared-view selector-scratch)
              program-index.backend-state))
            [(Ok _) ""]
            [(Err message) message])]
        [(No) ""])]
    [selector-count : i64
      (if needs-high
        2
        1)]
    [index-offset : i64 (* selector-count width-bytes)]
    [source-offset : i64 (+ index-offset width-bytes)]
    [stack-bytes : i64
      (be_operand.compiler-backend-simd-scratch-shuffle-bytes
        width-bytes
        selector-count)]
    [abort-label : String
      (compiler-backend-shuffle-label
        (be_state.compiler-backend-global-shared-view function)
        current-label
        dst
        "_abort")]
    [permute-label : String
      (compiler-backend-shuffle-label function current-label dst "_permute")]
    [call-space : i64
      (let
        [args (compiler_ir_types.CompilerIrCallArgs.Nil)]
        [types (compiler_ast_types.ast-type-list-new)]
        (be_operand.compiler-backend-call-arg-space
          target
          args
          types
          false
          program-index))]
    (if (not shape-ok)
      (be_operand.compiler-backend-avx2-shape-diagnostic
        type-segment-bases
        instr-diag
        elem-ty
        lanes)
      (if (or
        (and
          needs-high
          (match (& selector-high)
            [(Some _) false]
            [(No) true]))
        (not (string.eq high-error "")))
        (be_state.compiler-backend-instr-error
          instr-diag
          (if (string.eq high-error "")
            "backend: 32-bit vector shuffle is missing its high selector half"
            high-error))
        (match (be_operand.compiler-backend-vector-register-use
          assignments
          source
          "shuffle source"
          (be_state.compiler-backend-global-shared-view width)
          elem-ty
          source-scratch
          program-index.backend-state)
          [(Ok source-use)
            (match source-use
              [(Use source-asm source-reg)
                (match (let
                  [elem-ty (compiler_ast_types.AstType.I64)]
                  (be_operand.compiler-backend-vector-register-use
                    assignments
                    selector-low
                    "shuffle selector low"
                    (be_state.compiler-backend-global-shared-view width)
                    elem-ty
                    (be_state.compiler-backend-global-shared-view
                      selector-scratch)
                    program-index.backend-state))
                  [(Ok low-use)
                    (match low-use
                      [(Use low-asm low-reg)
                        (match (compiler-backend-vector-dst-reg
                          assignments
                          dst
                          "shuffle dst"
                          (be_state.compiler-backend-global-shared-view width)
                          dst-scratch
                          program-index.backend-state)
                          [(Ok dst-reg)
                            (match (be_operand.compiler-backend-emit-load-value
                              assignments
                              active-lanes
                              (be_state.compiler-backend-global-shared-view
                                active-reg)
                              program-index.backend-state)
                              [(Ok active-asm)
                                (let
                                  [high-asm : String
                                    (match selector-high
                                      [(Some high-value)
                                        (match (let
                                          [elem-ty
                                            (compiler_ast_types.AstType.I64)]
                                          (be_operand.compiler-backend-vector-register-use
                                            assignments
                                            high-value
                                            "shuffle selector high"
                                            (be_state.compiler-backend-global-shared-view
                                              width)
                                            elem-ty
                                            selector-scratch
                                            program-index.backend-state))
                                          [(Ok high-use)
                                            (match high-use
                                              [(Use load-asm high-reg)
                                                (str_cat.str-cat
                                                  load-asm
                                                  "    "
                                                  (let
                                                    [elem-ty
                                                      (compiler_ast_types.AstType.I64)]
                                                    (be_operand.compiler-backend-vector-move-for-width
                                                      width
                                                      elem-ty))
                                                  " "
                                                  high-reg
                                                  ", "
                                                  (be_operand.compiler-backend-simd-scratch-address
                                                    program-index.backend-state
                                                    width-bytes)
                                                  "\n")])]
                                          [(Err _) ""])]
                                      [(No) ""])]
                                  [zero-index-asm : String
                                    (if avx512
                                      (str_cat.str-cat
                                        "    vpxord "
                                        index-reg
                                        ", "
                                        index-reg
                                        ", "
                                        index-reg
                                        "\n    vmovdqu64 "
                                        index-reg
                                        ", "
                                        (be_operand.compiler-backend-simd-scratch-address
                                          program-index.backend-state
                                          index-offset)
                                        "\n")
                                      (str_cat.str-cat
                                        "    vpxor "
                                        index-reg
                                        ", "
                                        index-reg
                                        ", "
                                        index-reg
                                        "\n    vmovdqu "
                                        index-reg
                                        ", "
                                        (be_operand.compiler-backend-simd-scratch-address
                                          program-index.backend-state
                                          index-offset)
                                        "\n"))]
                                  [permute : String
                                    (str_cat.str-cat
                                      "    "
                                      (if dword
                                        "vpermd"
                                        (if avx512
                                          "vpermq"
                                          "vpermd"))
                                      " "
                                      (be_operand.compiler-backend-simd-scratch-address
                                        program-index.backend-state
                                        source-offset)
                                      ", "
                                      index-reg
                                      ", "
                                      dst-reg
                                      "\n")]
                                  (be_operand.compiler-backend-simd-scratch-checked
                                    program-index.backend-state
                                    instr-diag
                                    stack-bytes
                                    (Ok
                                      (str_cat.str-cat
                                        source-asm
                                        active-asm
                                        "    "
                                        (be_operand.compiler-backend-vector-move-for-width
                                          width
                                          elem-ty)
                                        " "
                                        source-reg
                                        ", "
                                        (be_operand.compiler-backend-simd-scratch-address
                                          program-index.backend-state
                                          source-offset)
                                        "\n"
                                        low-asm
                                        "    "
                                        (let
                                          [elem-ty
                                            (compiler_ast_types.AstType.I64)]
                                          (be_operand.compiler-backend-vector-move-for-width
                                            width
                                            elem-ty))
                                        " "
                                        low-reg
                                        ", "
                                        (be_operand.compiler-backend-simd-scratch-address
                                          program-index.backend-state
                                          0)
                                        "\n"
                                        high-asm
                                        (compiler-backend-shuffle-vector-check-asm
                                          avx512
                                          selector-count
                                          (be_operand.compiler-backend-simd-scratch-address
                                            program-index.backend-state
                                            0)
                                          (be_operand.compiler-backend-simd-scratch-address
                                            program-index.backend-state
                                            width-bytes)
                                          active-reg
                                          (be_state.compiler-backend-global-shared-view
                                            value-reg)
                                          abort-label)
                                        zero-index-asm
                                        (compiler-backend-shuffle-index-lane-copy-asm
                                          0
                                          lanes
                                          selector-lanes
                                          width-bytes
                                          index-offset
                                          dword
                                          avx512
                                          value-reg
                                          program-index.backend-state)
                                        "    jmp "
                                        permute-label
                                        "\n"
                                        abort-label
                                        ":\n"
                                        (be_operand.compiler-backend-emit-call-space-sub
                                          call-space)
                                        "    call "
                                        (be_operand.compiler-backend-call-symbol-index
                                          cbi.compiler-builtin-id-tl-oob-abort
                                          plan
                                          program-index)
                                        "\n"
                                        (be_operand.compiler-backend-emit-call-space-add
                                          call-space)
                                        permute-label
                                        ":\n    "
                                        (let
                                          [elem-ty
                                            (compiler_ast_types.AstType.I64)]
                                          (be_operand.compiler-backend-vector-move-for-width
                                            width
                                            elem-ty))
                                        " "
                                        (be_operand.compiler-backend-simd-scratch-address
                                          program-index.backend-state
                                          index-offset)
                                        ", "
                                        index-reg
                                        "\n"
                                        permute
                                        (compiler-backend-vector-store-dst
                                          assignments
                                          dst
                                          width
                                          elem-ty
                                          dst-reg
                                          program-index.backend-state)))))]
                              [(Err message)
                                (be_state.compiler-backend-instr-error-from
                                  instr-diag
                                  message)])]
                          [(Err message)
                            (be_state.compiler-backend-instr-error
                              instr-diag
                              message)])])]
                  [(Err message)
                    (be_state.compiler-backend-instr-error instr-diag message)])])]
          [(Err message)
            (be_state.compiler-backend-instr-error instr-diag message)])))))

(define (compiler-backend-vector-binop-memory-source-supported?
  [op : (& op compiler_ir_types.CompilerIrBinOp)]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]) : bool
  (cond
    [(be_operand.compiler-backend-avx512-shape-ok? elem-ty lanes)
      (>
        (string.string-length
          (compiler-backend-vector-binop-mnemonic op elem-ty true))
        0)]
    [(be_operand.compiler-backend-sse2-shape-ok? elem-ty lanes)
      (>
        (string.string-length
          (compiler-backend-sse2-vector-binop-mnemonic op elem-ty))
        0)]
    [(be_operand.compiler-backend-avx2-shape-ok? elem-ty lanes)
      (>
        (string.string-length
          (compiler-backend-vector-binop-mnemonic op elem-ty false))
        0)]
    [else false]))

(define (compiler-backend-vector-load-binop-fold-value
  [load-dst : i64]
  [op : (& op compiler_ir_types.CompilerIrBinOp)]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]) : be_state.CompilerBackendVectorMemFold
  (if (be_operand.compiler-backend-branch-uses-var? rhs load-dst)
    (Some lhs)
    (if (and
      (be_operand.compiler-backend-branch-uses-var? lhs load-dst)
      (be_operand.compiler-backend-commutative-binop? op))
      (Some rhs)
      (No))))

(define (compiler-backend-vector-load-binop-foldable?
  [type-segment-bases : i64]
  [use-counts : (& use-counts (__tl_dyn-array i64))]
  [load-dst : i64]
  [load-lanes : i64]
  [load-elem-ty : compiler_ast_types.AstType]
  [op : (& op compiler_ir_types.CompilerIrBinOp)]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [bin-lanes : i64]
  [bin-elem-ty : compiler_ast_types.AstType]) : bool
  (and
    (compiler-backend-var-single-use? use-counts load-dst)
    (= load-lanes bin-lanes)
    (compiler_optimize.opt-type-eq
      type-segment-bases
      load-elem-ty
      (& bin-elem-ty))
    (compiler-backend-vector-binop-memory-source-supported?
      op
      bin-lanes
      bin-elem-ty)
    (match (compiler-backend-vector-load-binop-fold-value load-dst op lhs rhs)
      [(Some _) true]
      [(No) false])))

(define (compiler-backend-vector-prefix-bool-op?
  [op : compiler_ir_types.CompilerIrVectorPrefixOp]) : bool
  (match op
    [(or (All) (Any)) true]
    [_ false]))

(define (compiler-backend-avx2-vector-prefix-shape-ok?
  [op : compiler_ir_types.CompilerIrVectorPrefixOp]
  [lanes : i64]
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]) : bool
  (match elem-ty
    [(I32) (and (= lanes 8) (not (compiler-backend-vector-prefix-bool-op? op)))]
    [(I64) (and (= lanes 4) (not (compiler-backend-vector-prefix-bool-op? op)))]
    [(Bool) (and (= lanes 32) (compiler-backend-vector-prefix-bool-op? op))]
    [_ false]))

(define (compiler-backend-vector-prefix-work [xmm : String] [family : String]) : String
  (be_operand.compiler-backend-xmm-spelling-family-register xmm family))

(define (compiler-backend-avx2-vector-prefix-numeric-combine
  [op : compiler_ir_types.CompilerIrVectorPrefixOp]
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]
  [dst-reg : String]
  [blend-mask : i64]
  [work0-xmm : String]
  [work1-xmm : String]) : String
  (let
    [work0 : String (compiler-backend-vector-prefix-work work0-xmm "ymm")]
    [work1 : String (compiler-backend-vector-prefix-work work1-xmm "ymm")]
    [blend? : bool (>= blend-mask 0)]
    [out-reg : String
      (if blend?
        (owned_view.compiler-owned-shared-view work0)
        (owned_view.compiler-owned-shared-view dst-reg))]
    [combine : String
      (match op
        [(Sum)
          (str_cat.str-cat
            "    "
            (match elem-ty
              [(I32) "vpaddd"]
              [_ "vpaddq"])
            " "
            work0
            ", "
            dst-reg
            ", "
            out-reg
            "\n")]
        [(Min)
          (match elem-ty
            [(I32)
              (str_cat.str-cat
                "    vpminsd "
                work0
                ", "
                dst-reg
                ", "
                out-reg
                "\n")]
            [_
              (str_cat.str-cat
                "    vpcmpgtq "
                work0
                ", "
                dst-reg
                ", "
                work1
                "\n    vpand "
                work1
                ", "
                work0
                ", "
                work0
                "\n    vpandn "
                dst-reg
                ", "
                work1
                ", "
                work1
                "\n    vpor "
                work1
                ", "
                work0
                ", "
                work0
                "\n"
                (if blend?
                  ""
                  (str_cat.str-cat "    vmovdqu " work0 ", " dst-reg "\n")))])]
        [(Max)
          (match elem-ty
            [(I32)
              (str_cat.str-cat
                "    vpmaxsd "
                work0
                ", "
                dst-reg
                ", "
                out-reg
                "\n")]
            [_
              (str_cat.str-cat
                "    vpcmpgtq "
                dst-reg
                ", "
                work0
                ", "
                work1
                "\n    vpand "
                work1
                ", "
                work0
                ", "
                work0
                "\n    vpandn "
                dst-reg
                ", "
                work1
                ", "
                work1
                "\n    vpor "
                work1
                ", "
                work0
                ", "
                work0
                "\n"
                (if blend?
                  ""
                  (str_cat.str-cat "    vmovdqu " work0 ", " dst-reg "\n")))])]
        [_ ""])]
    (str_cat.str-cat
      combine
      (if blend?
        (str_cat.str-cat
          "    vpblendd $"
          (string.int->string blend-mask)
          ", "
          work0
          ", "
          dst-reg
          ", "
          dst-reg
          "\n")
        ""))))

(define (compiler-backend-avx2-vector-prefix-numeric-body
  [op : compiler_ir_types.CompilerIrVectorPrefixOp]
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]
  [dst-reg : String]
  [work0-xmm : String]
  [work1-xmm : String]) : String
  (let
    [work0 : String
      (compiler-backend-vector-prefix-work
        (be_state.compiler-backend-global-shared-view work0-xmm)
        "ymm")]
    (match elem-ty
      [(I32)
        (str_cat.str-cat
          "    vpslldq $4, "
          dst-reg
          ", "
          work0
          "\n"
          (compiler-backend-avx2-vector-prefix-numeric-combine
            op
            elem-ty
            (be_state.compiler-backend-global-shared-view dst-reg)
            (match op
              [(Sum) -1]
              [_ 238])
            (be_state.compiler-backend-global-shared-view work0-xmm)
            (be_state.compiler-backend-global-shared-view work1-xmm))
          "    vpslldq $8, "
          dst-reg
          ", "
          work0
          "\n"
          (compiler-backend-avx2-vector-prefix-numeric-combine
            op
            elem-ty
            (be_state.compiler-backend-global-shared-view dst-reg)
            (match op
              [(Sum) -1]
              [_ 204])
            (be_state.compiler-backend-global-shared-view work0-xmm)
            (be_state.compiler-backend-global-shared-view work1-xmm))
          (match op
            [(Sum) "    vperm2i128 $8, "]
            [_ "    vperm2i128 $0, "])
          dst-reg
          ", "
          dst-reg
          ", "
          work0
          "\n    vpshufd $255, "
          work0
          ", "
          work0
          "\n"
          (compiler-backend-avx2-vector-prefix-numeric-combine
            op
            elem-ty
            dst-reg
            (match op
              [(Sum) -1]
              [_ 240])
            (be_state.compiler-backend-global-shared-view work0-xmm)
            work1-xmm))]
      [_
        (str_cat.str-cat
          "    vpslldq $8, "
          dst-reg
          ", "
          work0
          "\n"
          (compiler-backend-avx2-vector-prefix-numeric-combine
            op
            elem-ty
            (be_state.compiler-backend-global-shared-view dst-reg)
            (match op
              [(Sum) -1]
              [_ 204])
            (be_state.compiler-backend-global-shared-view work0-xmm)
            (be_state.compiler-backend-global-shared-view work1-xmm))
          (match op
            [(Sum)
              (str_cat.str-cat
                "    vpunpckhqdq "
                dst-reg
                ", "
                dst-reg
                ", "
                work0
                "\n"
                "    vperm2i128 $8, "
                work0
                ", "
                work0
                ", "
                work0
                "\n")]
            [_
              (str_cat.str-cat
                "    vperm2i128 $0, "
                dst-reg
                ", "
                dst-reg
                ", "
                work0
                "\n"
                "    vpermq $85, "
                work0
                ", "
                work0
                "\n")])
          (compiler-backend-avx2-vector-prefix-numeric-combine
            op
            elem-ty
            dst-reg
            (match op
              [(Sum) -1]
              [_ 240])
            work0-xmm
            work1-xmm))])))

(define (compiler-backend-avx2-vector-prefix-bool-stage
  [op : compiler_ir_types.CompilerIrVectorPrefixOp]
  [dst-reg : (& dst-reg str)]
  [shift : i64]
  [work0-xmm : String]
  [work1-xmm : String]) : String
  (let
    [work0 : String (compiler-backend-vector-prefix-work work0-xmm "ymm")]
    [work1 : String (compiler-backend-vector-prefix-work work1-xmm "ymm")]
    (str_cat.str-cat
      "    vpslldq $"
      (string.int->string shift)
      ", "
      dst-reg
      ", "
      work0
      "\n"
      (match op
        [(Any)
          (str_cat.str-cat "    vpor " work0 ", " dst-reg ", " dst-reg "\n")]
        [_
          (str_cat.str-cat
            "    vpand "
            dst-reg
            ", "
            work0
            ", "
            work0
            "\n    vpcmpeqd "
            work1
            ", "
            work1
            ", "
            work1
            "\n    vpslldq $"
            (string.int->string shift)
            ", "
            work1
            ", "
            work1
            "\n    vpand "
            work1
            ", "
            work0
            ", "
            work0
            "\n    vpandn "
            dst-reg
            ", "
            work1
            ", "
            work1
            "\n    vpor "
            work1
            ", "
            work0
            ", "
            dst-reg
            "\n")]))))

(define (compiler-backend-avx2-vector-prefix-bool-body
  [op : compiler_ir_types.CompilerIrVectorPrefixOp]
  [dst-reg : (& dst-reg str)]
  [work0-xmm : String]
  [work1-xmm : String]) : String
  (let
    [work0 : String
      (compiler-backend-vector-prefix-work
        (be_state.compiler-backend-global-shared-view work0-xmm)
        "ymm")]
    (str_cat.str-cat
      (compiler-backend-avx2-vector-prefix-bool-stage
        op
        dst-reg
        1
        (be_state.compiler-backend-global-shared-view work0-xmm)
        (be_state.compiler-backend-global-shared-view work1-xmm))
      (compiler-backend-avx2-vector-prefix-bool-stage
        op
        dst-reg
        2
        (be_state.compiler-backend-global-shared-view work0-xmm)
        (be_state.compiler-backend-global-shared-view work1-xmm))
      (compiler-backend-avx2-vector-prefix-bool-stage
        op
        dst-reg
        4
        (be_state.compiler-backend-global-shared-view work0-xmm)
        (be_state.compiler-backend-global-shared-view work1-xmm))
      (compiler-backend-avx2-vector-prefix-bool-stage
        op
        dst-reg
        8
        (be_state.compiler-backend-global-shared-view work0-xmm)
        work1-xmm)
      "    vperm2i128 $0, "
      dst-reg
      ", "
      dst-reg
      ", "
      work0
      "\n    vpsrldq $15, "
      work0
      ", "
      work0
      "\n    vpbroadcastb "
      work0-xmm
      ", "
      work0
      "\n    "
      (match op
        [(Any) "vpor"]
        [_ "vpand"])
      " "
      work0
      ", "
      dst-reg
      ", "
      work0
      "\n    vpblendd $240, "
      work0
      ", "
      dst-reg
      ", "
      dst-reg
      "\n")))

(define (compiler-backend-avx512-vector-prefix-shape-ok?
  [op : compiler_ir_types.CompilerIrVectorPrefixOp]
  [lanes : i64]
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]) : bool
  (match elem-ty
    [(I32)
      (and (= lanes 16) (not (compiler-backend-vector-prefix-bool-op? op)))]
    [(I64) (and (= lanes 8) (not (compiler-backend-vector-prefix-bool-op? op)))]
    [(Bool) (and (= lanes 64) (compiler-backend-vector-prefix-bool-op? op))]
    [_ false]))

(define (compiler-backend-avx512-vector-prefix-numeric-mnemonic
  [op : compiler_ir_types.CompilerIrVectorPrefixOp]
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]) : String
  (match op
    [(Sum)
      (match elem-ty
        [(I32) "vpaddd"]
        [_ "vpaddq"])]
    [(Min)
      (match elem-ty
        [(I32) "vpminsd"]
        [_ "vpminsq"])]
    [(Max)
      (match elem-ty
        [(I32) "vpmaxsd"]
        [_ "vpmaxsq"])]
    [_ ""]))

(define (compiler-backend-avx512-vector-prefix-numeric-combine
  [op : compiler_ir_types.CompilerIrVectorPrefixOp]
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]
  [dst-reg : (& dst-reg str)]
  [offset : i64]
  [work0-xmm : String]) : String
  (let
    [work0 : String (compiler-backend-vector-prefix-work work0-xmm "zmm")]
    [masked? : bool
      (and
        (>= offset 0)
        (not
          (match op
            [(Sum) true]
            [_ false])))]
    (str_cat.str-cat
      (if masked?
        (str_cat.str-cat
          "    kxnorw %k7, %k7, %k7\n    kshiftlw $"
          (string.int->string offset)
          ", %k7, %k7\n")
        "")
      "    "
      (compiler-backend-avx512-vector-prefix-numeric-mnemonic op elem-ty)
      " "
      work0
      ", "
      dst-reg
      ", "
      dst-reg
      (if masked?
        "{%k7}"
        "")
      "\n")))

(define (compiler-backend-avx512-vector-prefix-numeric-stage
  [op : compiler_ir_types.CompilerIrVectorPrefixOp]
  [elem-ty : compiler_ast_types.AstType]
  [dst-reg : (& dst-reg str)]
  [offset : i64]
  [align : i64]
  [work0-xmm : String]
  [work1-xmm : String]) : String
  (let
    [work0 : String
      (compiler-backend-vector-prefix-work
        (be_state.compiler-backend-global-shared-view work0-xmm)
        "zmm")]
    [work1 : String (compiler-backend-vector-prefix-work work1-xmm "zmm")]
    (str_cat.str-cat
      "    "
      (match (& elem-ty)
        [(I32) "valignd"]
        [_ "valignq"])
      " $"
      (string.int->string align)
      ", "
      work1
      ", "
      dst-reg
      ", "
      work0
      "\n"
      (compiler-backend-avx512-vector-prefix-numeric-combine
        op
        elem-ty
        dst-reg
        offset
        work0-xmm))))

;; VALIGN with a zero high source shifts the current prefix toward higher lane
;; numbers. Doubling the offset after each combine covers the whole ZMM.
(define (compiler-backend-avx512-vector-prefix-numeric-body
  [op : compiler_ir_types.CompilerIrVectorPrefixOp]
  [elem-ty : compiler_ast_types.AstType]
  [dst-reg : (& dst-reg str)]
  [work0-xmm : String]
  [work1-xmm : String]) : String
  (let
    [work1 : String
      (compiler-backend-vector-prefix-work
        (be_state.compiler-backend-global-shared-view work1-xmm)
        "zmm")]
    (str_cat.str-cat
      "    vpxord "
      work1
      ", "
      work1
      ", "
      work1
      "\n"
      (match (& elem-ty)
        [(I32)
          (str_cat.str-cat
            (compiler-backend-avx512-vector-prefix-numeric-stage
              op
              (be_state.compiler-backend-global-shared-view elem-ty)
              dst-reg
              1
              15
              (be_state.compiler-backend-global-shared-view work0-xmm)
              (be_state.compiler-backend-global-shared-view work1-xmm))
            (compiler-backend-avx512-vector-prefix-numeric-stage
              op
              (be_state.compiler-backend-global-shared-view elem-ty)
              dst-reg
              2
              14
              (be_state.compiler-backend-global-shared-view work0-xmm)
              (be_state.compiler-backend-global-shared-view work1-xmm))
            (compiler-backend-avx512-vector-prefix-numeric-stage
              op
              (be_state.compiler-backend-global-shared-view elem-ty)
              dst-reg
              4
              12
              (be_state.compiler-backend-global-shared-view work0-xmm)
              (be_state.compiler-backend-global-shared-view work1-xmm))
            (compiler-backend-avx512-vector-prefix-numeric-stage
              op
              elem-ty
              dst-reg
              8
              8
              work0-xmm
              work1-xmm))]
        [_
          (str_cat.str-cat
            (compiler-backend-avx512-vector-prefix-numeric-stage
              op
              (be_state.compiler-backend-global-shared-view elem-ty)
              dst-reg
              1
              7
              (be_state.compiler-backend-global-shared-view work0-xmm)
              (be_state.compiler-backend-global-shared-view work1-xmm))
            (compiler-backend-avx512-vector-prefix-numeric-stage
              op
              (be_state.compiler-backend-global-shared-view elem-ty)
              dst-reg
              2
              6
              (be_state.compiler-backend-global-shared-view work0-xmm)
              (be_state.compiler-backend-global-shared-view work1-xmm))
            (compiler-backend-avx512-vector-prefix-numeric-stage
              op
              elem-ty
              dst-reg
              4
              4
              work0-xmm
              work1-xmm))]))))

(define (compiler-backend-avx512-vector-prefix-bool-stage
  [bits-gp : (& bits-gp str)]
  [temp-gp : (& temp-gp str)]
  [shift : i64]) : String
  (str_cat.str-cat
    "    movq "
    bits-gp
    ", "
    temp-gp
    "\n    shlq $"
    (string.int->string shift)
    ", "
    temp-gp
    "\n    orq "
    temp-gp
    ", "
    bits-gp
    "\n"))

;; AVX-512 bool lanes are already one bit per lane in an opmask. Shift/OR
;; propagates Any directly; All applies the same operation to the false bits.
(define (compiler-backend-avx512-vector-prefix-bool-body
  [op : compiler_ir_types.CompilerIrVectorPrefixOp]
  [bits-gp : (& bits-gp str)]
  [temp-gp : (& temp-gp str)]) : String
  (let
    [all? : bool
      (match op
        [(All) true]
        [_ false])]
    (str_cat.str-cat
      (if all?
        (str_cat.str-cat "    notq " bits-gp "\n")
        "")
      (compiler-backend-avx512-vector-prefix-bool-stage bits-gp temp-gp 1)
      (compiler-backend-avx512-vector-prefix-bool-stage bits-gp temp-gp 2)
      (compiler-backend-avx512-vector-prefix-bool-stage bits-gp temp-gp 4)
      (compiler-backend-avx512-vector-prefix-bool-stage bits-gp temp-gp 8)
      (compiler-backend-avx512-vector-prefix-bool-stage bits-gp temp-gp 16)
      (compiler-backend-avx512-vector-prefix-bool-stage bits-gp temp-gp 32)
      (if all?
        (str_cat.str-cat "    notq " bits-gp "\n")
        ""))))

(define (compiler-backend-avx512-vector-prefix-bool-result-asm
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [lanes : i64]
  [mask-move : String]
  [bits-gp : String]
  [dst-reg : String]
  [backend-state : be_state.CompilerBackendState]) : String
  (str_cat.str-cat
    "    "
    mask-move
    " "
    bits-gp
    ", "
    dst-reg
    "\n"
    (compiler-backend-avx512-mask-store-dst
      assignments
      dst
      lanes
      dst-reg
      backend-state)))

(define (compiler-backend-emit-avx512-vector-prefix-bool
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [op : compiler_ir_types.CompilerIrVectorPrefixOp]
  [src : compiler_ir_types.CompilerIrValue]
  [carry : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [exclude : (__tl_dyn-array String)
      (be_operand.compiler-backend-scavenge-exclude-ops2
        backend-state
        assignments
        (be_state.compiler-backend-global-shared-view src)
        carry)]
    [carry-gp : String
      (be_operand.compiler-backend-scavenge-reg
        -1
        (be_state.compiler-backend-global-shared-view exclude)
        7
        "%r10"
        backend-state)]
    [bits-exclude : (__tl_dyn-array String)
      (be_operand.compiler-backend-scavenge-exclude-append
        exclude
        7
        (be_state.compiler-backend-global-shared-view carry-gp))]
    [bits-gp : String
      (be_operand.compiler-backend-scavenge-reg
        -1
        bits-exclude
        8
        "%r11"
        backend-state)]
    [mask-move : String
      (be_operand.compiler-backend-avx512-mask-move-mnemonic lanes)]
    (match (be_operand.compiler-backend-avx512-mask-register-use
      assignments
      src
      "vector prefix source"
      lanes
      (compiler-backend-mask-spill-scratch 0)
      backend-state)
      [(Ok src-use)
        (match src-use
          [(Use src-asm src-reg)
            (match (compiler-backend-avx512-mask-dst-reg
              assignments
              dst
              "vector prefix dst"
              (compiler-backend-mask-spill-scratch 0)
              backend-state)
              [(Ok dst-reg)
                (match (be_operand.compiler-backend-avx512-mask-register-use
                  assignments
                  carry
                  "vector prefix carry"
                  lanes
                  (compiler-backend-mask-spill-scratch 1)
                  backend-state)
                  [(Ok (Use carry-asm carry-reg))
                    (Ok
                      (str_cat.str-cat
                        src-asm
                        "    "
                        mask-move
                        " "
                        src-reg
                        ", "
                        bits-gp
                        "\n"
                        (compiler-backend-avx512-vector-prefix-bool-body
                          op
                          bits-gp
                          carry-gp)
                        carry-asm
                        "    "
                        mask-move
                        " "
                        carry-reg
                        ", "
                        carry-gp
                        "\n"
                        "    sarq $63, "
                        carry-gp
                        "\n    "
                        (match op
                          [(Any) "orq"]
                          [_ "andq"])
                        " "
                        carry-gp
                        ", "
                        bits-gp
                        "\n"
                        (compiler-backend-avx512-vector-prefix-bool-result-asm
                          assignments
                          dst
                          lanes
                          mask-move
                          bits-gp
                          dst-reg
                          backend-state)))]
                  [(Err message)
                    (be_state.compiler-backend-instr-error instr-diag message)])]
              [(Err message)
                (be_state.compiler-backend-instr-error instr-diag message)])])]
      [(Err message) (be_state.compiler-backend-instr-error instr-diag message)])))

;; Read the carry before the current prefix overwrites its previous value.
(define (compiler-backend-vector-prefix-broadcast-last
  [avx2? : bool]
  [elem-ty : (& compiler_ast_types.AstType)]
  [lanes : i64]
  [src : (& str)]
  [work : (& str)]
  [work-xmm : (& str)]) : String
  (if avx2?
    (match elem-ty
      [(I64) (str_cat.str-cat "    vpermq $255, " src ", " work "\n")]
      [(I32)
        (str_cat.str-cat
          "    vperm2i128 $17, "
          src
          ", "
          src
          ", "
          work
          "\n"
          "    vpshufd $255, "
          work
          ", "
          work
          "\n")]
      [_
        (str_cat.str-cat
          "    vextracti128 $1, "
          src
          ", "
          work-xmm
          "\n"
          "    vpsrldq $15, "
          work-xmm
          ", "
          work-xmm
          "\n"
          "    vpbroadcastb "
          work-xmm
          ", "
          work
          "\n")])
    (let
      [dword? : bool
        (match elem-ty
          [(I32) true]
          [_ false])]
      (str_cat.str-cat
        (if dword?
          "    valignd $"
          "    valignq $")
        (string.int->string (- lanes 1))
        ", "
        src
        ", "
        src
        ", "
        work
        "\n"
        (if dword?
          "    vpbroadcastd "
          "    vpbroadcastq ")
        work-xmm
        ", "
        work
        "\n"))))

(define (compiler-backend-preserve-prefix-scratch!
  [backend-state : be_state.CompilerBackendState]
  [reg : String]) : unit
  (when
    (be_state.compiler-backend-current-fn-win64? backend-state)
    (be_operand.compiler-backend-emergency-add!
      (be_state.compiler-backend-state-function-state backend-state)
      reg)))

(define (compiler-backend-emit-vector-splat-last
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [src : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [avx2? : bool
      (be_operand.compiler-backend-avx2-shape-ok? (& elem-ty) lanes)]
    [width : String
      (if avx2?
        "ymm"
        "zmm")]
    (unless
      (and
        (match (& elem-ty)
          [(or (I32) (I64)) true]
          [_ false])
        (or
          avx2?
          (be_operand.compiler-backend-avx512-shape-ok? (& elem-ty) lanes)))
      (return
        (be_state.compiler-backend-instr-error
          instr-diag
          "backend: unsupported vector splat shape")))
    (match (compiler-backend-vector-dst-reg
      assignments
      dst
      "splat last lane destination"
      (string.copy (& width))
      (be_operand.compiler-backend-vector-spill-scratch (& width) 0)
      backend-state)
      [(Ok dst-reg)
        (when
          (or (string.eq dst-reg "%ymm14") (string.eq dst-reg "%zmm14"))
          (compiler-backend-preserve-prefix-scratch! backend-state "%xmm14"))
        (match (be_operand.compiler-backend-vector-register-use
          assignments
          src
          "splat last lane source"
          (string.copy (& width))
          (& elem-ty)
          (string.copy (& dst-reg))
          backend-state)
          [(Ok (Use load-asm src-reg))
            (Ok
              (str_cat.str-cat
                load-asm
                (compiler-backend-vector-prefix-broadcast-last
                  avx2?
                  (& elem-ty)
                  lanes
                  (& src-reg)
                  (& dst-reg)
                  (&
                    (be_operand.compiler-backend-vector-reg-lower-xmm
                      (string.copy (& dst-reg)))))
                (compiler-backend-vector-store-dst
                  assignments
                  dst
                  width
                  elem-ty
                  dst-reg
                  backend-state)))]
          [(Err message)
            (be_state.compiler-backend-instr-error instr-diag message)])]
      [(Err message) (be_state.compiler-backend-instr-error instr-diag message)])))

(define (compiler-backend-emit-vector-prefix
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [op : compiler_ir_types.CompilerIrVectorPrefixOp]
  [src : compiler_ir_types.CompilerIrValue]
  [carry : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [avx2? : bool
      (be_state.compiler-backend-current-mode-avx2?
        (be_state.compiler-backend-state-function-state backend-state))]
    [bool? : bool (compiler-backend-vector-prefix-bool-op? op)]
    [local? : bool
      (match (& carry)
        [(Unit) true]
        [_ false])]
    (when
      (match (& op)
        [(SplatLast) true]
        [_ false])
      (return
        (if local?
          (compiler-backend-emit-vector-splat-last
            assignments
            dst
            src
            lanes
            elem-ty
            instr-diag
            backend-state)
          (be_state.compiler-backend-instr-error
            instr-diag
            "backend: splat last lane does not take a carry"))))
    (when
      (and
        local?
        (not
          (match (& op)
            [(Sum) true]
            [_ false])))
      (return
        (be_state.compiler-backend-instr-error
          instr-diag
          "backend: prefix without a carry requires sum")))
    (unless
      (if avx2?
        (compiler-backend-avx2-vector-prefix-shape-ok? op lanes (& elem-ty))
        (compiler-backend-avx512-vector-prefix-shape-ok? op lanes (& elem-ty)))
      (return
        (be_state.compiler-backend-instr-error
          instr-diag
          "backend: unsupported vector prefix shape")))
    (when
      (and bool? (not avx2?))
      (return
        (compiler-backend-emit-avx512-vector-prefix-bool
          assignments
          dst
          op
          src
          carry
          lanes
          instr-diag
          backend-state)))
    (let
      [width : String
        (if avx2?
          "ymm"
          "zmm")]
      [register-ty : compiler_ast_types.AstType
        (if bool?
          (I8)
          (be_state.compiler-backend-global-shared-view elem-ty))]
      ;; The allocator reserves these SIMD families for backend temporaries.
      [work0 : String "%xmm0"]
      [work1 : String "%xmm1"]
      [carry-xmm : String "%xmm14"]
      [carry-work : String
        (compiler-backend-vector-prefix-work
          (be_state.compiler-backend-global-shared-view carry-xmm)
          (be_state.compiler-backend-global-shared-view width))]
      [dst-result
        (compiler-backend-vector-dst-reg
          assignments
          dst
          "prefix dst"
          (be_state.compiler-backend-global-shared-view width)
          (be_operand.compiler-backend-vector-spill-scratch (& width) 1)
          backend-state)]
      (match dst-result
        [(Ok dst-reg)
          (unless
            local?
            (compiler-backend-preserve-prefix-scratch! backend-state "%xmm14"))
          (when
            (or (string.eq dst-reg "%ymm15") (string.eq dst-reg "%zmm15"))
            (compiler-backend-preserve-prefix-scratch! backend-state "%xmm15"))
          (match (if local?
            (be_state.ResultBackendVectorUse.Ok
              (be_state.CompilerBackendVectorUse.Use "" ""))
            (be_operand.compiler-backend-vector-register-use
              assignments
              carry
              "prefix carry"
              (be_state.compiler-backend-global-shared-view width)
              (& register-ty)
              (be_state.compiler-backend-global-shared-view carry-work)
              backend-state))
            [(Ok (Use carry-load carry-reg))
              (match (be_operand.compiler-backend-vector-register-use
                assignments
                src
                "prefix source"
                (be_state.compiler-backend-global-shared-view width)
                (& register-ty)
                (be_state.compiler-backend-global-shared-view dst-reg)
                backend-state)
                [(Ok (Use src-load src-reg))
                  (let
                    [copy-asm : String
                      (if (string.eq src-reg dst-reg)
                        ""
                        (str_cat.str-cat
                          "    "
                          (if avx2?
                            "vmovdqu "
                            "vmovdqu64 ")
                          src-reg
                          ", "
                          dst-reg
                          "\n"))]
                    [prefix-asm : String
                      (cond
                        [bool?
                          (compiler-backend-avx2-vector-prefix-bool-body
                            op
                            (& dst-reg)
                            (be_state.compiler-backend-global-shared-view work0)
                            (be_state.compiler-backend-global-shared-view work1))]
                        [avx2?
                          (compiler-backend-avx2-vector-prefix-numeric-body
                            op
                            (& elem-ty)
                            (be_state.compiler-backend-global-shared-view
                              dst-reg)
                            (be_state.compiler-backend-global-shared-view work0)
                            (be_state.compiler-backend-global-shared-view work1))]
                        [else
                          (compiler-backend-avx512-vector-prefix-numeric-body
                            op
                            (be_state.compiler-backend-global-shared-view
                              elem-ty)
                            (& dst-reg)
                            (be_state.compiler-backend-global-shared-view work0)
                            (be_state.compiler-backend-global-shared-view work1))])]
                    [combine-asm : String
                      (cond
                        [local? ""]
                        [bool?
                          (str_cat.str-cat
                            "    "
                            (match op
                              [(Any) "vpor "]
                              [_ "vpand "])
                            carry-work
                            ", "
                            dst-reg
                            ", "
                            dst-reg
                            "\n")]
                        [avx2?
                          (compiler-backend-avx2-vector-prefix-numeric-combine
                            op
                            (& elem-ty)
                            (be_state.compiler-backend-global-shared-view
                              dst-reg)
                            -1
                            (be_state.compiler-backend-global-shared-view
                              carry-xmm)
                            (be_state.compiler-backend-global-shared-view work1))]
                        [else
                          (compiler-backend-avx512-vector-prefix-numeric-combine
                            op
                            (& elem-ty)
                            (& dst-reg)
                            -1
                            (be_state.compiler-backend-global-shared-view
                              carry-xmm))])]
                    (Ok
                      (str_cat.str-cat
                        carry-load
                        (if local?
                          ""
                          (compiler-backend-vector-prefix-broadcast-last
                            avx2?
                            (& elem-ty)
                            lanes
                            (& carry-reg)
                            (& carry-work)
                            (& carry-xmm)))
                        src-load
                        copy-asm
                        prefix-asm
                        combine-asm
                        (compiler-backend-vector-store-dst
                          assignments
                          dst
                          (be_state.compiler-backend-global-shared-view width)
                          register-ty
                          (be_state.compiler-backend-global-shared-view dst-reg)
                          backend-state))))]
                [(Err message)
                  (be_state.compiler-backend-instr-error instr-diag message)])]
            [(Err message)
              (be_state.compiler-backend-instr-error instr-diag message)])]
        [(Err message)
          (be_state.compiler-backend-instr-error instr-diag message)]))))

(define (compiler-backend-emit-vector-last-lane
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [src : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [avx512? : bool
      (be_operand.compiler-backend-avx512-shape-ok? (& elem-ty) lanes)]
    [sse2? : bool
      (be_operand.compiler-backend-sse2-shape-ok? (& elem-ty) lanes)]
    [shift : i64
      (match (& elem-ty)
        [(I32) 12]
        [(I64) 8]
        [_ 0])]
    [width : String (cond [avx512? "zmm"] [sse2? "xmm"] [else "ymm"])]
    [scratch : String "%xmm0"]
    (if (and
      (> shift 0)
      (or
        avx512?
        sse2?
        (be_operand.compiler-backend-avx2-shape-ok? (& elem-ty) lanes)))
      (match (be_operand.compiler-backend-vector-register-use
        assignments
        src
        "last lane source"
        (be_state.compiler-backend-global-shared-view width)
        (& elem-ty)
        (if sse2?
          "%xmm0"
          (compiler-backend-vector-prefix-work
            (be_state.compiler-backend-global-shared-view scratch)
            (be_state.compiler-backend-global-shared-view width)))
        backend-state)
        [(Ok (Use load-asm src-reg))
          (Ok
            (if sse2?
              (str_cat.str-cat
                load-asm
                (if (string.eq src-reg "%xmm0")
                  ""
                  (str_cat.str-cat "    movdqa " src-reg ", %xmm0\n"))
                "    psrldq $"
                (string.int->string shift)
                ", %xmm0\n"
                (be_operand.compiler-backend-vector-reduce-store-scalar
                  assignments
                  dst
                  elem-ty
                  "%xmm0"
                  backend-state))
              (str_cat.str-cat
                load-asm
                (if avx512?
                  "    vextracti32x4 $3, "
                  "    vextracti128 $1, ")
                src-reg
                ", "
                scratch
                "\n"
                "    vpsrldq $"
                (string.int->string shift)
                ", "
                scratch
                ", "
                scratch
                "\n"
                (be_operand.compiler-backend-vector-reduce-store-scalar
                  assignments
                  dst
                  elem-ty
                  scratch
                  backend-state))))]
        [(Err message)
          (be_state.compiler-backend-instr-error instr-diag message)])
      (be_state.compiler-backend-instr-error
        instr-diag
        "backend: unsupported vector last lane shape"))))

(define (compiler-backend-avx512-partial-mask [active-lanes : i64]) : i64
  (let
    [mask : i64 0]
    (for [i (iterator.range 0 active-lanes)]
      (set! mask (bit-or mask (shl 1 i))))
    mask))

(define (compiler-backend-avx512-tail-mask-immediate
  [index : i64]
  [end-value : i64]
  [lanes : i64]) : i64
  (let
    [active-lanes : i64 (- end-value index)]
    (cond
      [(<= active-lanes 0) 0]
      [(>= active-lanes lanes) (compiler-backend-avx512-lane-mask lanes)]
      [else (compiler-backend-avx512-partial-mask active-lanes)])))

(define (compiler-backend-emit-avx512-mask-immediate
  [dst-reg : (& dst-reg str)]
  [mask : i64]
  [lanes : i64]
  [backend-state : be_state.CompilerBackendState]) : String
  (if (= mask 0)
    (let
      [kxor : String (compiler-backend-avx512-mask-kxor-mnemonic lanes)]
      (str_cat.str-cat "    " kxor " " dst-reg ", " dst-reg ", " dst-reg "\n"))
    (let
      [tmp-reg : String
        (be_operand.compiler-backend-scavenge-reg-here
          (__tl_make-array String 0)
          0
          "%rax"
          backend-state)]
      [mask-gpr : String (compiler-backend-avx512-mask-gpr-part tmp-reg lanes)]
      [mask-move : String
        (be_operand.compiler-backend-avx512-mask-move-mnemonic lanes)]
      [mov-imm : String (compiler-backend-avx512-mask-mov-imm-mnemonic lanes)]
      (str_cat.str-cat
        "    "
        mov-imm
        " $"
        (string.int->string mask)
        ", "
        mask-gpr
        "\n    "
        mask-move
        " "
        mask-gpr
        ", "
        dst-reg
        "\n"))))

(define (compiler-backend-emit-avx512-tail-mask-dynamic
  [function : String]
  [current-label : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst-reg : (& dst-reg str)]
  [dst : i64]
  [index : compiler_ir_types.CompilerIrValue]
  [end-value : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [full-mask : i64 (compiler-backend-avx512-lane-mask lanes)]
    [count-reg : String
      (compiler-backend-scavenge-rcx-reg-here
        (__tl_make-array String 0)
        0
        backend-state)]
    [index-home : String
      (compiler-backend-simd-index-home
        backend-state
        assignments
        (be_state.compiler-backend-global-shared-view index))]
    [index-exclude : (__tl_dyn-array String)
      (be_operand.compiler-backend-scavenge-exclude-ops2
        backend-state
        assignments
        (be_state.compiler-backend-global-shared-view index)
        end-value)]
    [index-reg : String
      (if (and
        (not (string.eq index-home ""))
        (not (string.eq index-home count-reg)))
        (owned_view.compiler-owned-shared-view index-home)
        (be_operand.compiler-backend-scavenge-reg-here
          (be_state.compiler-backend-global-shared-view index-exclude)
          7
          "%r8"
          backend-state))]
    [mask-exclude : (__tl_dyn-array String)
      (be_operand.compiler-backend-scavenge-exclude-append
        index-exclude
        7
        (be_state.compiler-backend-global-shared-view index-reg))]
    [mask-reg : String
      (be_operand.compiler-backend-scavenge-reg-here
        mask-exclude
        8
        "%r9"
        backend-state)]
    [mask-gpr : String (compiler-backend-avx512-mask-gpr-part mask-reg lanes)]
    (match (if (string.eq index-reg index-home)
      (be_state.ResultCompilerBackend.Ok "")
      (be_operand.compiler-backend-emit-load-value
        assignments
        index
        (be_state.compiler-backend-global-shared-view index-reg)
        backend-state))
      [(Ok index-asm)
        (match (be_operand.compiler-backend-emit-load-value
          assignments
          end-value
          (be_state.compiler-backend-global-shared-view count-reg)
          backend-state)
          [(Ok end-asm)
            (let
              [full-label : String
                (compiler-backend-avx512-mask-label
                  (be_state.compiler-backend-global-shared-view function)
                  current-label
                  dst
                  "_full")]
              [zero-label : String
                (compiler-backend-avx512-mask-label
                  (be_state.compiler-backend-global-shared-view function)
                  current-label
                  dst
                  "_zero")]
              [done-label : String
                (compiler-backend-avx512-mask-label
                  function
                  current-label
                  dst
                  "_done")]
              [mask-move : String
                (be_operand.compiler-backend-avx512-mask-move-mnemonic lanes)]
              [mov-imm : String
                (compiler-backend-avx512-mask-mov-imm-mnemonic lanes)]
              [shift : String (compiler-backend-avx512-mask-shl-mnemonic lanes)]
              [sub : String (compiler-backend-avx512-mask-sub-mnemonic lanes)]
              [kxor : String (compiler-backend-avx512-mask-kxor-mnemonic lanes)]
              [body-range : String
                (str_cat.str-cat
                  "    subq "
                  index-reg
                  ", "
                  count-reg
                  "\n    cmpq $"
                  (string.int->string lanes)
                  ", "
                  count-reg
                  "\n    jge "
                  full-label
                  "\n")]
              [body-nonzero-a : String
                (str_cat.str-cat
                  "    testq "
                  count-reg
                  ", "
                  count-reg
                  "\n    jle "
                  zero-label
                  "\n    "
                  mov-imm
                  " $1, ")]
              [body-nonzero-b : String
                (str_cat.str-cat mask-gpr "\n    " shift " %cl, " mask-gpr "\n")]
              [body-mask-a : String
                (str_cat.str-cat "    " sub " $1, " mask-gpr "\n    ")]
              [body-mask-b : String
                (str_cat.str-cat mask-move " " mask-gpr ", " dst-reg)]
              [body-mask-c : String
                (str_cat.str-cat
                  "\n    jmp "
                  done-label
                  "\n"
                  full-label
                  ":\n    ")]
              [body-full-a : String
                (str_cat.str-cat
                  mov-imm
                  " $"
                  (string.int->string full-mask)
                  ", "
                  mask-gpr)]
              [body-full-b : String
                (str_cat.str-cat "\n    " mask-move " " mask-gpr ", ")]
              [body-full-c : String
                (str_cat.str-cat
                  dst-reg
                  "\n    jmp "
                  done-label
                  "\n"
                  zero-label
                  ":\n")]
              [body-zero : String
                (str_cat.str-cat
                  "    "
                  kxor
                  " "
                  dst-reg
                  ", "
                  dst-reg
                  ", "
                  dst-reg
                  "\n"
                  done-label
                  ":\n")]
              [body-asm : String
                (str_cat.str-cat
                  body-range
                  body-nonzero-a
                  body-nonzero-b
                  body-mask-a
                  body-mask-b
                  body-mask-c
                  body-full-a
                  body-full-b
                  body-full-c
                  body-zero)]
              (Ok (str_cat.str-cat index-asm end-asm body-asm)))]
          [(Err message)
            (be_state.compiler-backend-instr-error-from instr-diag message)])]
      [(Err message)
        (be_state.compiler-backend-instr-error-from instr-diag message)])))

(define (compiler-backend-emit-avx512-tail-mask
  [type-segment-bases : i64]
  [function : String]
  [current-label : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [index : compiler_ir_types.CompilerIrValue]
  [end-value : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (= (compiler-backend-avx512-lane-mask lanes) 0)
    (be_operand.compiler-backend-avx512-shape-diagnostic
      type-segment-bases
      instr-diag
      (I64)
      lanes)
    (match (compiler-backend-avx512-mask-dst-reg
      assignments
      dst
      "tail mask dst"
      (compiler-backend-mask-spill-scratch 0)
      backend-state)
      [(Ok dst-reg)
        (match (& index)
          [(I64 index-imm)
            (match (& end-value)
              [(I64 end-imm)
                (Ok
                  (str_cat.str-cat
                    (compiler-backend-emit-avx512-mask-immediate
                      dst-reg
                      (compiler-backend-avx512-tail-mask-immediate
                        index-imm
                        end-imm
                        lanes)
                      lanes
                      backend-state)
                    (compiler-backend-avx512-mask-store-dst
                      assignments
                      dst
                      lanes
                      dst-reg
                      backend-state)))]
              [_
                (let
                  [asm
                    (try
                      (compiler-backend-emit-avx512-tail-mask-dynamic
                        function
                        current-label
                        assignments
                        dst-reg
                        dst
                        index
                        end-value
                        lanes
                        instr-diag
                        backend-state))]
                  (Ok
                    (str_cat.str-cat
                      asm
                      (compiler-backend-avx512-mask-store-dst
                        assignments
                        dst
                        lanes
                        dst-reg
                        backend-state))))])]
          [_
            (let
              [asm
                (try
                  (compiler-backend-emit-avx512-tail-mask-dynamic
                    function
                    current-label
                    assignments
                    dst-reg
                    dst
                    index
                    end-value
                    lanes
                    instr-diag
                    backend-state))]
              (Ok
                (str_cat.str-cat
                  asm
                  (compiler-backend-avx512-mask-store-dst
                    assignments
                    dst
                    lanes
                    dst-reg
                    backend-state))))])]
      [(Err message) (be_state.compiler-backend-instr-error instr-diag message)])))

(define (compiler-backend-emit-avx512-predicated-load
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [base : compiler_ir_types.CompilerIrValue]
  [index : compiler_ir_types.CompilerIrValue]
  [mask : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (match (& elem-ty)
    [(Bool) true]
    [_ false])
    (compiler-backend-emit-avx512-mask-load
      type-segment-bases
      assignments
      dst
      base
      index
      mask
      lanes
      instr-diag
      backend-state)
    (if (be_operand.compiler-backend-avx512-shape-ok? elem-ty lanes)
      (match (be_operand.compiler-backend-avx512-mask-register-use
        assignments
        mask
        "load mask"
        lanes
        (compiler-backend-mask-spill-scratch 0)
        backend-state)
        [(Ok mask-use)
          (match mask-use
            [(Use mask-asm mask-reg)
              (match (compiler-backend-vector-dst-reg
                assignments
                dst
                "load dst"
                "zmm"
                (be_operand.compiler-backend-vector-spill-scratch "zmm" 0)
                backend-state)
                [(Ok dst-reg)
                  (match (compiler-backend-emit-simd-indexed-address
                    type-segment-bases
                    assignments
                    base
                    index
                    (be_state.compiler-backend-global-shared-view elem-ty)
                    backend-state)
                    [(Ok addr-plan)
                      (let
                        [addr-asm : String addr-plan.asm]
                        [addr : String addr-plan.addr]
                        (Ok
                          (str_cat.str-cat
                            mask-asm
                            addr-asm
                            "    "
                            (be_operand.compiler-backend-avx512-vector-move
                              elem-ty)
                            " "
                            addr
                            ", "
                            dst-reg
                            "{"
                            mask-reg
                            "}{z}\n"
                            (compiler-backend-vector-store-dst
                              assignments
                              dst
                              "zmm"
                              elem-ty
                              dst-reg
                              backend-state))))]
                    [(Err message)
                      (be_state.compiler-backend-instr-error-from
                        instr-diag
                        message)])]
                [(Err message)
                  (be_state.compiler-backend-instr-error instr-diag message)])])]
        [(Err message)
          (be_state.compiler-backend-instr-error instr-diag message)])
      (be_operand.compiler-backend-avx512-shape-diagnostic
        type-segment-bases
        instr-diag
        elem-ty
        lanes))))

(define (compiler-backend-emit-avx512-predicated-store
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [base : compiler_ir_types.CompilerIrValue]
  [index : compiler_ir_types.CompilerIrValue]
  [value : compiler_ir_types.CompilerIrValue]
  [mask : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (match (& elem-ty)
    [(Bool) true]
    [_ false])
    (compiler-backend-emit-avx512-mask-store
      type-segment-bases
      assignments
      base
      index
      value
      mask
      lanes
      instr-diag
      backend-state)
    (if (be_operand.compiler-backend-avx512-shape-ok? elem-ty lanes)
      (match (be_operand.compiler-backend-vector-register-use
        assignments
        value
        "store value"
        "zmm"
        elem-ty
        (be_operand.compiler-backend-vector-spill-scratch "zmm" 0)
        backend-state)
        [(Ok value-use)
          (match value-use
            [(Use value-asm value-reg)
              (match (be_operand.compiler-backend-avx512-mask-register-use
                assignments
                mask
                "store mask"
                lanes
                (compiler-backend-mask-spill-scratch 0)
                backend-state)
                [(Ok mask-use)
                  (match mask-use
                    [(Use mask-asm mask-reg)
                      (match (compiler-backend-emit-simd-indexed-address
                        type-segment-bases
                        assignments
                        base
                        index
                        (be_state.compiler-backend-global-shared-view elem-ty)
                        backend-state)
                        [(Ok addr-plan)
                          (let
                            [addr-asm : String addr-plan.asm]
                            [addr : String addr-plan.addr]
                            (Ok
                              (str_cat.str-cat
                                value-asm
                                mask-asm
                                addr-asm
                                "    "
                                (be_operand.compiler-backend-avx512-vector-move
                                  elem-ty)
                                " "
                                value-reg
                                ", "
                                addr
                                "{"
                                mask-reg
                                "}\n")))]
                        [(Err message)
                          (be_state.compiler-backend-instr-error-from
                            instr-diag
                            message)])])]
                [(Err message)
                  (be_state.compiler-backend-instr-error instr-diag message)])])]
        [(Err message)
          (be_state.compiler-backend-instr-error instr-diag message)])
      (be_operand.compiler-backend-avx512-shape-diagnostic
        type-segment-bases
        instr-diag
        elem-ty
        lanes))))

(define (compiler-backend-emit-avx512-mask-load
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [base : compiler_ir_types.CompilerIrValue]
  [index : compiler_ir_types.CompilerIrValue]
  [mask : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (= (compiler-backend-avx512-lane-mask lanes) 0)
    (be_operand.compiler-backend-avx512-shape-diagnostic
      type-segment-bases
      instr-diag
      (Bool)
      lanes)
    (match (compiler-backend-avx512-mask-dst-reg
      assignments
      dst
      "mask load dst"
      (compiler-backend-mask-spill-scratch 0)
      backend-state)
      [(Ok dst-reg)
        (match (be_operand.compiler-backend-avx512-mask-register-use
          assignments
          mask
          "mask load active mask"
          lanes
          (compiler-backend-mask-spill-scratch 0)
          backend-state)
          [(Ok mask-use)
            (match mask-use
              [(Use mask-asm mask-reg)
                (match (compiler-backend-emit-simd-indexed-address
                  type-segment-bases
                  assignments
                  base
                  index
                  (Bool)
                  backend-state)
                  [(Ok addr-plan)
                    (let
                      [addr-asm : String addr-plan.asm]
                      [addr : String addr-plan.addr]
                      (match (compiler-backend-vector-temp-zmm
                        backend-state
                        assignments
                        ""
                        ""
                        ""
                        "mask load bytes")
                        [(Ok bytes-reg)
                          (match (compiler-backend-vector-temp-zmm
                            backend-state
                            assignments
                            (be_state.compiler-backend-global-shared-view
                              bytes-reg)
                            ""
                            ""
                            "mask load zero")
                            [(Ok zero-reg)
                              (Ok
                                (str_cat.str-cat
                                  mask-asm
                                  addr-asm
                                  (str_cat.str-cat
                                    "    vmovdqu8 "
                                    addr
                                    ", "
                                    bytes-reg
                                    "{"
                                    mask-reg
                                    "}{z}\n"
                                    "    vpxord "
                                    zero-reg
                                    ", "
                                    zero-reg
                                    ", "
                                    zero-reg
                                    "\n"
                                    "    vpcmpub $4, "
                                    zero-reg
                                    ", "
                                    bytes-reg
                                    ", "
                                    dst-reg
                                    "\n"
                                    (compiler-backend-avx512-mask-store-dst
                                      assignments
                                      dst
                                      lanes
                                      dst-reg
                                      backend-state))))]
                            [(Err message)
                              (be_state.compiler-backend-instr-error
                                instr-diag
                                message)])]
                        [(Err message)
                          (be_state.compiler-backend-instr-error
                            instr-diag
                            message)]))]
                  [(Err message)
                    (be_state.compiler-backend-instr-error-from
                      instr-diag
                      message)])])]
          [(Err message)
            (be_state.compiler-backend-instr-error instr-diag message)])]
      [(Err message) (be_state.compiler-backend-instr-error instr-diag message)])))

;; The row of 1 bytes is built in registers: all ones from vpternlogd, then
;; vpabsb turns each 0xff byte into 1. It needs no stack motion (#7497), and
;; AVX-512BW is already required by the masked byte moves.
(define (compiler-backend-emit-avx512-mask-store
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [base : compiler_ir_types.CompilerIrValue]
  [index : compiler_ir_types.CompilerIrValue]
  [value : compiler_ir_types.CompilerIrValue]
  [mask : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (= (compiler-backend-avx512-lane-mask lanes) 0)
    (be_operand.compiler-backend-avx512-shape-diagnostic
      type-segment-bases
      instr-diag
      (Bool)
      lanes)
    (match (be_operand.compiler-backend-avx512-mask-register-use
      assignments
      value
      "mask store value"
      lanes
      (compiler-backend-mask-spill-scratch 0)
      backend-state)
      [(Ok value-use)
        (match value-use
          [(Use value-asm value-reg)
            (match (be_operand.compiler-backend-avx512-mask-register-use
              assignments
              mask
              "mask store active mask"
              lanes
              (compiler-backend-mask-spill-scratch 0)
              backend-state)
              [(Ok mask-use)
                (match mask-use
                  [(Use mask-asm mask-reg)
                    (match (compiler-backend-emit-simd-indexed-address
                      type-segment-bases
                      assignments
                      base
                      index
                      (Bool)
                      backend-state)
                      [(Ok addr-plan)
                        (let
                          [addr-asm : String addr-plan.asm]
                          [addr : String addr-plan.addr]
                          (match (compiler-backend-vector-temp-zmm
                            backend-state
                            assignments
                            ""
                            ""
                            ""
                            "mask store bytes")
                            [(Ok bytes-reg)
                              (match (compiler-backend-vector-temp-zmm
                                backend-state
                                assignments
                                (be_state.compiler-backend-global-shared-view
                                  bytes-reg)
                                ""
                                ""
                                "mask store ones")
                                [(Ok ones-reg)
                                  (Ok
                                    (str_cat.str-cat
                                      value-asm
                                      addr-asm
                                      (str_cat.str-cat
                                        "    vpxord "
                                        bytes-reg
                                        ", "
                                        bytes-reg
                                        ", "
                                        bytes-reg
                                        "\n"
                                        "    vpternlogd $255, "
                                        ones-reg
                                        ", "
                                        ones-reg
                                        ", "
                                        ones-reg
                                        "\n"
                                        "    vpabsb "
                                        ones-reg
                                        ", "
                                        ones-reg
                                        "\n"
                                        "    vmovdqu8 "
                                        ones-reg
                                        ", "
                                        bytes-reg
                                        "{"
                                        value-reg
                                        "}\n"
                                        mask-asm
                                        "    vmovdqu8 "
                                        bytes-reg
                                        ", "
                                        addr
                                        "{"
                                        mask-reg
                                        "}\n")))]
                                [(Err message)
                                  (be_state.compiler-backend-instr-error
                                    instr-diag
                                    message)])]
                            [(Err message)
                              (be_state.compiler-backend-instr-error
                                instr-diag
                                message)]))]
                      [(Err message)
                        (be_state.compiler-backend-instr-error-from
                          instr-diag
                          message)])])]
              [(Err message)
                (be_state.compiler-backend-instr-error instr-diag message)])])]
      [(Err message) (be_state.compiler-backend-instr-error instr-diag message)])))

(define (compiler-backend-mask-binop-mnemonic
  [op : compiler_ir_types.CompilerIrMaskBinOp]
  [lanes : i64]) : String
  (match op
    [(And)
      (str_cat.str-cat
        "kand"
        (be_operand.compiler-backend-avx512-mask-op-suffix lanes))]
    [(Or)
      (str_cat.str-cat
        "kor"
        (be_operand.compiler-backend-avx512-mask-op-suffix lanes))]))

(define (compiler-backend-mask-value-spilled?
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]
  [backend-state : be_state.CompilerBackendState]) : bool
  (match (compiler-backend-vector-value-stack-operand
    assignments
    value
    backend-state)
    [(Some _) true]
    [(No) false]))

(define (compiler-backend-mask-dst-spilled?
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [backend-state : be_state.CompilerBackendState]) : bool
  (match (be_operand.compiler-backend-vector-var-stack-operand
    assignments
    dst
    backend-state)
    [(Some _) true]
    [(No) false]))

(define (compiler-backend-emit-avx512-mask-binop-gpr
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [op : compiler_ir_types.CompilerIrMaskBinOp]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [lhs-tmp : String
      (be_operand.compiler-backend-scavenge-reg-here
        (__tl_make-array String 0)
        0
        "%rax"
        backend-state)]
    [rhs-tmp : String
      (be_operand.compiler-backend-scavenge-reg-here
        (be_operand.compiler-backend-one-exclude (string.copy (& lhs-tmp)))
        1
        "%r10"
        backend-state)]
    [lhs-gpr : String (compiler-backend-avx512-mask-gpr-part lhs-tmp lanes)]
    [rhs-gpr : String (compiler-backend-avx512-mask-gpr-part rhs-tmp lanes)]
    (match (compiler-backend-avx512-mask-source-into-gpr
      assignments
      lhs
      "lhs"
      lanes
      (be_state.compiler-backend-global-shared-view lhs-gpr)
      backend-state)
      [(Ok lhs-use)
        (match lhs-use
          [(Use lhs-asm _)
            (match (compiler-backend-avx512-mask-source-into-gpr
              assignments
              rhs
              "rhs"
              lanes
              (be_state.compiler-backend-global-shared-view rhs-gpr)
              backend-state)
              [(Ok rhs-use)
                (match rhs-use
                  [(Use rhs-asm _)
                    (match (compiler-backend-avx512-mask-dst-reg
                      assignments
                      dst
                      "mask binop dst"
                      (compiler-backend-mask-spill-scratch 0)
                      backend-state)
                      [(Ok dst-reg)
                        (Ok
                          (str_cat.str-cat
                            lhs-asm
                            rhs-asm
                            "    "
                            (compiler-backend-mask-gpr-binop-mnemonic op lanes)
                            " "
                            rhs-gpr
                            ", "
                            lhs-gpr
                            "\n    "
                            (be_operand.compiler-backend-avx512-mask-move-mnemonic
                              lanes)
                            " "
                            lhs-gpr
                            ", "
                            dst-reg
                            "\n"
                            (compiler-backend-avx512-mask-store-dst
                              assignments
                              dst
                              lanes
                              dst-reg
                              backend-state)))]
                      [(Err message)
                        (be_state.compiler-backend-instr-error
                          instr-diag
                          message)])])]
              [(Err message)
                (be_state.compiler-backend-instr-error instr-diag message)])])]
      [(Err message) (be_state.compiler-backend-instr-error instr-diag message)])))

(define (compiler-backend-emit-avx512-mask-binop
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [op : compiler_ir_types.CompilerIrMaskBinOp]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (= (compiler-backend-avx512-lane-mask lanes) 0)
    (be_operand.compiler-backend-avx512-shape-diagnostic
      type-segment-bases
      instr-diag
      (I64)
      lanes)
    (if (or
      (compiler-backend-mask-value-spilled?
        assignments
        (be_state.compiler-backend-global-shared-view lhs)
        backend-state)
      (compiler-backend-mask-value-spilled?
        assignments
        (be_state.compiler-backend-global-shared-view rhs)
        backend-state)
      (compiler-backend-mask-dst-spilled? assignments dst backend-state))
      (compiler-backend-emit-avx512-mask-binop-gpr
        assignments
        dst
        op
        lhs
        rhs
        lanes
        instr-diag
        backend-state)
      (match (compiler-backend-avx512-mask-value-reg
        backend-state
        assignments
        lhs
        "lhs")
        [(Ok lhs-reg)
          (match (compiler-backend-avx512-mask-value-reg
            backend-state
            assignments
            rhs
            "rhs")
            [(Ok rhs-reg)
              (match (be_operand.compiler-backend-mask-var-reg
                backend-state
                assignments
                dst
                "mask binop dst")
                [(Ok dst-reg)
                  (Ok
                    (if (string.eq lhs-reg rhs-reg)
                      (if (string.eq lhs-reg dst-reg)
                        ""
                        (str_cat.str-cat
                          "    "
                          (be_operand.compiler-backend-avx512-mask-move-mnemonic
                            lanes)
                          " "
                          lhs-reg
                          ", "
                          dst-reg
                          "\n"))
                      (str_cat.str-cat
                        "    "
                        (compiler-backend-mask-binop-mnemonic op lanes)
                        " "
                        rhs-reg
                        ", "
                        lhs-reg
                        ", "
                        dst-reg
                        "\n")))]
                [(Err message)
                  (be_state.compiler-backend-instr-error instr-diag message)])]
            [(Err message)
              (be_state.compiler-backend-instr-error instr-diag message)])]
        [(Err message)
          (be_state.compiler-backend-instr-error instr-diag message)]))))

(define (compiler-backend-emit-avx512-mask-not-gpr
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [src : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [full-mask : i64 (compiler-backend-avx512-lane-mask lanes)]
    [tmp-reg : String
      (be_operand.compiler-backend-scavenge-reg-here
        (__tl_make-array String 0)
        0
        "%rax"
        backend-state)]
    [mask-gpr : String (compiler-backend-avx512-mask-gpr-part tmp-reg lanes)]
    (match (compiler-backend-avx512-mask-source-into-gpr
      assignments
      src
      "not source"
      lanes
      (be_state.compiler-backend-global-shared-view mask-gpr)
      backend-state)
      [(Ok src-use)
        (match src-use
          [(Use src-asm _)
            (match (compiler-backend-avx512-mask-dst-reg
              assignments
              dst
              "mask not dst"
              (compiler-backend-mask-spill-scratch 0)
              backend-state)
              [(Ok dst-reg)
                (Ok
                  (str_cat.str-cat
                    src-asm
                    "    xor"
                    (compiler-backend-avx512-mask-int-suffix lanes)
                    " $"
                    (string.int->string full-mask)
                    ", "
                    mask-gpr
                    "\n    "
                    (be_operand.compiler-backend-avx512-mask-move-mnemonic
                      lanes)
                    " "
                    mask-gpr
                    ", "
                    dst-reg
                    "\n"
                    (compiler-backend-avx512-mask-store-dst
                      assignments
                      dst
                      lanes
                      dst-reg
                      backend-state)))]
              [(Err message)
                (be_state.compiler-backend-instr-error instr-diag message)])])]
      [(Err message) (be_state.compiler-backend-instr-error instr-diag message)])))

(define (compiler-backend-emit-avx512-mask-not
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [src : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [full-mask : i64 (compiler-backend-avx512-lane-mask lanes)]
    [mask-suffix : String
      (be_operand.compiler-backend-avx512-mask-op-suffix lanes)]
    [mask-move : String
      (be_operand.compiler-backend-avx512-mask-move-mnemonic lanes)]
    [mov-imm : String (compiler-backend-avx512-mask-mov-imm-mnemonic lanes)]
    (if (= full-mask 0)
      (be_operand.compiler-backend-avx512-shape-diagnostic
        type-segment-bases
        instr-diag
        (I64)
        lanes)
      (if (or
        (compiler-backend-mask-value-spilled?
          assignments
          (be_state.compiler-backend-global-shared-view src)
          backend-state)
        (compiler-backend-mask-dst-spilled? assignments dst backend-state))
        (compiler-backend-emit-avx512-mask-not-gpr
          assignments
          dst
          src
          lanes
          instr-diag
          backend-state)
        (match (compiler-backend-avx512-mask-value-reg
          backend-state
          assignments
          src
          "not source")
          [(Ok src-reg)
            (match (be_operand.compiler-backend-mask-var-reg
              backend-state
              assignments
              dst
              "mask not dst")
              [(Ok dst-reg)
                (Ok
                  (if (compiler-backend-avx512-mask-not-full-width? lanes)
                    (str_cat.str-cat
                      "    "
                      (str_cat.str-cat "knot" mask-suffix)
                      " "
                      src-reg
                      ", "
                      dst-reg
                      "\n")
                    (let
                      [tmp-reg : String
                        (be_operand.compiler-backend-scavenge-reg-here
                          (__tl_make-array String 0)
                          0
                          "%rax"
                          backend-state)]
                      [mask-gpr : String
                        (compiler-backend-avx512-mask-gpr-part tmp-reg lanes)]
                      (str_cat.str-cat
                        "    "
                        mov-imm
                        " $"
                        (string.int->string full-mask)
                        ", "
                        mask-gpr
                        "\n    "
                        mask-move
                        " "
                        mask-gpr
                        ", %k7\n    "
                        (str_cat.str-cat "kandn" mask-suffix)
                        " "
                        "%k7, "
                        src-reg
                        ", "
                        dst-reg
                        "\n"))))]
              [(Err message)
                (be_state.compiler-backend-instr-error instr-diag message)])]
          [(Err message)
            (be_state.compiler-backend-instr-error instr-diag message)])))))

(define (compiler-backend-emit-avx512-mask-reduce
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [op : compiler_ir_types.CompilerIrMaskReduceOp]
  [src : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [full-mask : i64 (compiler-backend-avx512-lane-mask lanes)]
    [mask-move : String
      (be_operand.compiler-backend-avx512-mask-move-mnemonic lanes)]
    [kortest-op : String (compiler-backend-avx512-mask-kortest-mnemonic lanes)]
    [cmp-op : String (compiler-backend-avx512-mask-cmp-mnemonic lanes)]
    (if (= full-mask 0)
      (be_operand.compiler-backend-avx512-shape-diagnostic
        type-segment-bases
        instr-diag
        (I64)
        lanes)
      (match (be_operand.compiler-backend-avx512-mask-register-use
        assignments
        src
        "reduce source"
        lanes
        (compiler-backend-mask-spill-scratch 0)
        backend-state)
        [(Ok src-use)
          (match src-use
            [(Use src-asm src-reg)
              (let
                [dst-home : String
                  (be_operand.compiler-backend-value-scalar-register-home
                    backend-state
                    assignments
                    (& (Var dst)))]
                [res-reg : String
                  (if (string.eq dst-home "")
                    (be_operand.compiler-backend-scavenge-reg
                      dst
                      (__tl_make-array String 0)
                      0
                      "%rax"
                      backend-state)
                    dst-home)]
                [res32 : String
                  (be_operand.compiler-backend-reg-part
                    (string.copy (& res-reg))
                    4)]
                [res8 : String
                  (be_operand.compiler-backend-reg-part
                    (string.copy (& res-reg))
                    1)]
                [mask-gpr : String
                  (compiler-backend-avx512-mask-gpr-part
                    (string.copy (& res-reg))
                    lanes)]
                [src-reg-copy : String (string.copy (& src-reg))]
                [mask-gpr-copy : String (string.copy (& mask-gpr))]
                [reduce-asm : String
                  (match op
                    [(Any)
                      (str_cat.str-cat
                        "    "
                        kortest-op
                        " "
                        (string.copy src-reg)
                        ", "
                        src-reg
                        "\n    setne "
                        res8
                        "\n")]
                    [(All)
                      (if (or (= full-mask 0xffff) (= full-mask -1))
                        (str_cat.str-cat
                          "    "
                          kortest-op
                          " "
                          (string.copy src-reg)
                          ", "
                          src-reg
                          "\n    setc "
                          res8
                          "\n")
                        (str_cat.str-cat
                          "    "
                          mask-move
                          " "
                          src-reg-copy
                          ", "
                          mask-gpr-copy
                          "\n    "
                          cmp-op
                          " $"
                          (string.int->string full-mask)
                          ", "
                          mask-gpr
                          "\n    sete "
                          res8
                          "\n"))])]
                [store-asm : String
                  (str_cat.str-cat
                    "    movzbl "
                    res8
                    ", "
                    res32
                    "\n"
                    (be_operand.compiler-backend-emit-store-var
                      assignments
                      dst
                      res-reg
                      backend-state))]
                (Ok (str_cat.str-cat src-asm reduce-asm store-asm)))])]
        [(Err message)
          (be_state.compiler-backend-instr-error instr-diag message)]))))

(define (compiler-backend-emit-avx512-select
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [mask : compiler_ir_types.CompilerIrValue]
  [on-true : compiler_ir_types.CompilerIrValue]
  [on-false : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (be_operand.compiler-backend-avx512-shape-ok? elem-ty lanes)
    (let
      [move : String (be_operand.compiler-backend-avx512-vector-move elem-ty)]
      [false-stack? : bool
        (match (compiler-backend-vector-value-stack-operand
          assignments
          (be_state.compiler-backend-global-shared-view on-false)
          backend-state)
          [(Some _) true]
          [(No) false])]
      [true-stack? : bool
        (match (compiler-backend-vector-value-stack-operand
          assignments
          (be_state.compiler-backend-global-shared-view on-true)
          backend-state)
          [(Some _) true]
          [(No) false])]
      (if (= (string.string-length move) 0)
        (be_state.compiler-backend-instr-error
          instr-diag
          "backend: unsupported AVX-512 select type")
        (match (be_operand.compiler-backend-vector-register-use
          assignments
          on-false
          "select false"
          "zmm"
          elem-ty
          (be_operand.compiler-backend-vector-spill-scratch "zmm" 0)
          backend-state)
          [(Ok false-use)
            (match false-use
              [(Use false-asm false-reg)
                (match (be_operand.compiler-backend-vector-register-use
                  assignments
                  on-true
                  "select true"
                  "zmm"
                  elem-ty
                  (be_operand.compiler-backend-vector-spill-scratch "zmm" 1)
                  backend-state)
                  [(Ok true-use)
                    (match true-use
                      [(Use true-asm true-reg)
                        (match (be_operand.compiler-backend-avx512-mask-register-use
                          assignments
                          mask
                          "select mask"
                          lanes
                          (compiler-backend-mask-spill-scratch 0)
                          backend-state)
                          [(Ok mask-use)
                            (match mask-use
                              [(Use mask-asm mask-reg)
                                (match (compiler-backend-vector-dst-reg
                                  assignments
                                  dst
                                  "select dst"
                                  "zmm"
                                  (be_operand.compiler-backend-vector-spill-scratch
                                    "zmm"
                                    0)
                                  backend-state)
                                  [(Ok dst-reg)
                                    (let
                                      [prefix-asm : String
                                        (str_cat.str-cat
                                          false-asm
                                          true-asm
                                          mask-asm)]
                                      [store-asm : String
                                        (compiler-backend-vector-store-dst
                                          assignments
                                          dst
                                          "zmm"
                                          elem-ty
                                          (be_state.compiler-backend-global-shared-view
                                            dst-reg)
                                          backend-state)]
                                      (if (and
                                        (string.eq (& dst-reg) (& true-reg))
                                        (not
                                          (string.eq (& true-reg) (& false-reg))))
                                        (match (if (or false-stack? true-stack?)
                                          (be_state.ResultBackendReg.Ok
                                            (be_operand.compiler-backend-vector-spill-scratch
                                              "zmm"
                                              1))
                                          (compiler-backend-vector-temp-zmm
                                            backend-state
                                            assignments
                                            (be_state.compiler-backend-global-shared-view
                                              dst-reg)
                                            (be_state.compiler-backend-global-shared-view
                                              true-reg)
                                            (be_state.compiler-backend-global-shared-view
                                              false-reg)
                                            "select true alias"))
                                          [(Ok temp-reg)
                                            (Ok
                                              (str_cat.str-cat
                                                prefix-asm
                                                "    "
                                                move
                                                " "
                                                true-reg
                                                ", "
                                                temp-reg
                                                "\n    "
                                                move
                                                " "
                                                false-reg
                                                ", "
                                                dst-reg
                                                "\n    "
                                                move
                                                " "
                                                temp-reg
                                                ", "
                                                dst-reg
                                                "{"
                                                mask-reg
                                                "}\n"
                                                store-asm))]
                                          [(Err message)
                                            (be_state.compiler-backend-instr-error
                                              instr-diag
                                              message)])
                                        (Ok
                                          (str_cat.str-cat
                                            prefix-asm
                                            (if (string.eq
                                              (& true-reg)
                                              (& false-reg))
                                              (if (string.eq
                                                (& dst-reg)
                                                (& false-reg))
                                                ""
                                                (str_cat.str-cat
                                                  "    "
                                                  move
                                                  " "
                                                  false-reg
                                                  ", "
                                                  dst-reg
                                                  "\n"))
                                              (str_cat.str-cat
                                                (if (string.eq
                                                  (& dst-reg)
                                                  (& false-reg))
                                                  ""
                                                  (str_cat.str-cat
                                                    "    "
                                                    move
                                                    " "
                                                    false-reg
                                                    ", "
                                                    dst-reg
                                                    "\n"))
                                                "    "
                                                move
                                                " "
                                                true-reg
                                                ", "
                                                dst-reg
                                                "{"
                                                mask-reg
                                                "}\n"))
                                            store-asm))))]
                                  [(Err message)
                                    (be_state.compiler-backend-instr-error
                                      instr-diag
                                      message)])])]
                          [(Err message)
                            (be_state.compiler-backend-instr-error
                              instr-diag
                              message)])])]
                  [(Err message)
                    (be_state.compiler-backend-instr-error instr-diag message)])])]
          [(Err message)
            (be_state.compiler-backend-instr-error instr-diag message)])))
    (be_operand.compiler-backend-avx512-shape-diagnostic
      type-segment-bases
      instr-diag
      elem-ty
      lanes)))

(define (compiler-backend-avx2-mask-binop-mnemonic
  [op : compiler_ir_types.CompilerIrMaskBinOp]) : String
  (match op
    [(And) "vpand"]
    [(Or) "vpor"]))

(define (compiler-backend-emit-avx2-mask-binop
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [op : compiler_ir_types.CompilerIrMaskBinOp]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [sse2? : bool
      (be_state.compiler-backend-current-mode-sse2?
        (be_state.compiler-backend-state-function-state backend-state))]
    (if (not
      (if sse2?
        (be_operand.compiler-backend-sse2-mask-shape-ok? lanes)
        (be_operand.compiler-backend-avx2-mask-shape-ok? lanes)))
      (if sse2?
        (be_operand.compiler-backend-sse2-shape-diagnostic
          type-segment-bases
          instr-diag
          (Bool)
          lanes)
        (be_operand.compiler-backend-avx2-shape-diagnostic
          type-segment-bases
          instr-diag
          (Bool)
          lanes))
      (match (let
        [elem-ty (compiler_ast_types.AstType.I8)]
        (be_operand.compiler-backend-vector-register-use
          assignments
          lhs
          "mask lhs"
          (if sse2?
            "xmm"
            "ymm")
          elem-ty
          (if sse2?
            "%xmm14"
            "%ymm14")
          backend-state))
        [(Ok lhs-use)
          (match lhs-use
            [(Use lhs-asm lhs-reg)
              (match (let
                [elem-ty (compiler_ast_types.AstType.I8)]
                (be_operand.compiler-backend-vector-register-use
                  assignments
                  rhs
                  "mask rhs"
                  (if sse2?
                    "xmm"
                    "ymm")
                  elem-ty
                  (if sse2?
                    "%xmm15"
                    "%ymm15")
                  backend-state))
                [(Ok rhs-use)
                  (match rhs-use
                    [(Use rhs-asm rhs-reg)
                      (match (compiler-backend-vector-dst-reg
                        assignments
                        dst
                        "mask binop dst"
                        (if sse2?
                          "xmm"
                          "ymm")
                        (if sse2?
                          "%xmm14"
                          "%ymm14")
                        backend-state)
                        [(Ok dst-reg)
                          (let
                            [op-asm : String
                              (if sse2?
                                (let
                                  [mnemonic : String
                                    (match op
                                      [(And) "pand"]
                                      [(Or) "por"])]
                                  (cond
                                    [(string.eq dst-reg lhs-reg)
                                      (str_cat.str-cat
                                        "    "
                                        mnemonic
                                        " "
                                        rhs-reg
                                        ", "
                                        dst-reg
                                        "\n")]
                                    [(string.eq dst-reg rhs-reg)
                                      (str_cat.str-cat
                                        "    "
                                        mnemonic
                                        " "
                                        lhs-reg
                                        ", "
                                        dst-reg
                                        "\n")]
                                    [else
                                      (str_cat.str-cat
                                        "    movdqa "
                                        lhs-reg
                                        ", "
                                        dst-reg
                                        "\n    "
                                        mnemonic
                                        " "
                                        rhs-reg
                                        ", "
                                        dst-reg
                                        "\n")]))
                                (str_cat.str-cat
                                  "    "
                                  (compiler-backend-avx2-mask-binop-mnemonic op)
                                  " "
                                  rhs-reg
                                  ", "
                                  lhs-reg
                                  ", "
                                  dst-reg
                                  "\n"))]
                            (Ok
                              (str_cat.str-cat
                                lhs-asm
                                rhs-asm
                                op-asm
                                (compiler-backend-vector-store-dst
                                  assignments
                                  dst
                                  (if sse2?
                                    "xmm"
                                    "ymm")
                                  (I8)
                                  dst-reg
                                  backend-state))))]
                        [(Err message)
                          (be_state.compiler-backend-instr-error
                            instr-diag
                            message)])])]
                [(Err message)
                  (be_state.compiler-backend-instr-error instr-diag message)])])]
        [(Err message)
          (be_state.compiler-backend-instr-error instr-diag message)]))))

(define (compiler-backend-emit-mask-binop
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [op : compiler_ir_types.CompilerIrMaskBinOp]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (or
    (be_state.compiler-backend-current-mode-avx2?
      (be_state.compiler-backend-state-function-state backend-state))
    (be_state.compiler-backend-current-mode-sse2?
      (be_state.compiler-backend-state-function-state backend-state)))
    (compiler-backend-emit-avx2-mask-binop
      type-segment-bases
      assignments
      dst
      op
      lhs
      rhs
      lanes
      instr-diag
      backend-state)
    (compiler-backend-emit-avx512-mask-binop
      type-segment-bases
      assignments
      dst
      op
      lhs
      rhs
      lanes
      instr-diag
      backend-state)))

(define (compiler-backend-emit-avx2-mask-not
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [src : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [sse2? : bool
      (be_state.compiler-backend-current-mode-sse2?
        (be_state.compiler-backend-state-function-state backend-state))]
    (if (not
      (if sse2?
        (be_operand.compiler-backend-sse2-mask-shape-ok? lanes)
        (be_operand.compiler-backend-avx2-mask-shape-ok? lanes)))
      (if sse2?
        (be_operand.compiler-backend-sse2-shape-diagnostic
          type-segment-bases
          instr-diag
          (Bool)
          lanes)
        (be_operand.compiler-backend-avx2-shape-diagnostic
          type-segment-bases
          instr-diag
          (Bool)
          lanes))
      (match (let
        [elem-ty (compiler_ast_types.AstType.I8)]
        (be_operand.compiler-backend-vector-register-use
          assignments
          src
          "mask not source"
          (if sse2?
            "xmm"
            "ymm")
          elem-ty
          (if sse2?
            "%xmm14"
            "%ymm14")
          backend-state))
        [(Ok src-use)
          (match src-use
            [(Use src-asm src-reg)
              (match (compiler-backend-vector-dst-reg
                assignments
                dst
                "mask not dst"
                (if sse2?
                  "xmm"
                  "ymm")
                (if sse2?
                  "%xmm14"
                  "%ymm14")
                backend-state)
                [(Ok dst-reg)
                  (let
                    [not-asm : String
                      (if sse2?
                        (if (string.eq dst-reg src-reg)
                          (str_cat.str-cat
                            "    pcmpeqd %xmm0, %xmm0\n    pxor %xmm0, "
                            dst-reg
                            "\n")
                          (str_cat.str-cat
                            "    pcmpeqd %xmm0, %xmm0\n    pxor "
                            src-reg
                            ", %xmm0\n    movdqa %xmm0, "
                            dst-reg
                            "\n"))
                        (str_cat.str-cat
                          "    vpcmpeqd %ymm0, %ymm0, %ymm0\n    vpxor "
                          src-reg
                          ", %ymm0, "
                          dst-reg
                          "\n"))]
                    (Ok
                      (str_cat.str-cat
                        src-asm
                        not-asm
                        (compiler-backend-vector-store-dst
                          assignments
                          dst
                          (if sse2?
                            "xmm"
                            "ymm")
                          (I8)
                          dst-reg
                          backend-state))))]
                [(Err message)
                  (be_state.compiler-backend-instr-error instr-diag message)])])]
        [(Err message)
          (be_state.compiler-backend-instr-error instr-diag message)]))))

(define (compiler-backend-emit-mask-not
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [src : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (or
    (be_state.compiler-backend-current-mode-avx2?
      (be_state.compiler-backend-state-function-state backend-state))
    (be_state.compiler-backend-current-mode-sse2?
      (be_state.compiler-backend-state-function-state backend-state)))
    (compiler-backend-emit-avx2-mask-not
      type-segment-bases
      assignments
      dst
      src
      lanes
      instr-diag
      backend-state)
    (compiler-backend-emit-avx512-mask-not
      type-segment-bases
      assignments
      dst
      src
      lanes
      instr-diag
      backend-state)))

(define (compiler-backend-emit-avx2-mask-reduce
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [op : compiler_ir_types.CompilerIrMaskReduceOp]
  [src : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [sse2? : bool
      (be_state.compiler-backend-current-mode-sse2?
        (be_state.compiler-backend-state-function-state backend-state))]
    (if (not
      (if sse2?
        (be_operand.compiler-backend-sse2-mask-shape-ok? lanes)
        (be_operand.compiler-backend-avx2-mask-shape-ok? lanes)))
      (if sse2?
        (be_operand.compiler-backend-sse2-shape-diagnostic
          type-segment-bases
          instr-diag
          (Bool)
          lanes)
        (be_operand.compiler-backend-avx2-shape-diagnostic
          type-segment-bases
          instr-diag
          (Bool)
          lanes))
      (match (let
        [elem-ty (compiler_ast_types.AstType.I8)]
        (be_operand.compiler-backend-vector-register-use
          assignments
          src
          "mask reduce source"
          (if sse2?
            "xmm"
            "ymm")
          elem-ty
          (if sse2?
            "%xmm14"
            "%ymm14")
          backend-state))
        [(Ok src-use)
          (match src-use
            [(Use src-asm src-reg)
              (let
                [dst-home : String
                  (be_operand.compiler-backend-value-scalar-register-home
                    backend-state
                    assignments
                    (& (Var dst)))]
                [res-reg : String
                  (if (string.eq dst-home "")
                    (be_operand.compiler-backend-scavenge-reg
                      dst
                      (__tl_make-array String 0)
                      0
                      "%rax"
                      backend-state)
                    dst-home)]
                [res32 : String
                  (be_operand.compiler-backend-reg-part
                    (string.copy (& res-reg))
                    4)]
                [res8 : String
                  (be_operand.compiler-backend-reg-part
                    (string.copy (& res-reg))
                    1)]
                [pmov : String
                  (if sse2?
                    "    pmovmskb "
                    "    vpmovmskb ")]
                [reduce-asm : String
                  (match op
                    [(Any)
                      (str_cat.str-cat
                        pmov
                        src-reg
                        ", "
                        res32
                        "\n    testl "
                        res32
                        ", "
                        res32
                        "\n    setne "
                        res8
                        "\n")]
                    [(All)
                      (str_cat.str-cat
                        pmov
                        src-reg
                        ", "
                        res32
                        "\n    cmpl "
                        (if sse2?
                          "$65535"
                          "$-1")
                        ", "
                        res32
                        "\n    sete "
                        res8
                        "\n")])]
                [store-asm : String
                  (str_cat.str-cat
                    "    movzbl "
                    res8
                    ", "
                    res32
                    "\n"
                    (be_operand.compiler-backend-emit-store-var
                      assignments
                      dst
                      res-reg
                      backend-state))]
                (Ok (str_cat.str-cat src-asm reduce-asm store-asm)))])]
        [(Err message)
          (be_state.compiler-backend-instr-error instr-diag message)]))))

(define (compiler-backend-emit-mask-reduce
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [op : compiler_ir_types.CompilerIrMaskReduceOp]
  [src : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (or
    (be_state.compiler-backend-current-mode-avx2?
      (be_state.compiler-backend-state-function-state backend-state))
    (be_state.compiler-backend-current-mode-sse2?
      (be_state.compiler-backend-state-function-state backend-state)))
    (compiler-backend-emit-avx2-mask-reduce
      type-segment-bases
      assignments
      dst
      op
      src
      lanes
      instr-diag
      backend-state)
    (compiler-backend-emit-avx512-mask-reduce
      type-segment-bases
      assignments
      dst
      op
      src
      lanes
      instr-diag
      backend-state)))

(defenum CompilerBackendSelectFactorResult
  (SelectFactorResult i64 compiler_ir_types.CompilerIrBlockList))

(define (compiler-backend-simd-int-type-tag
  [ty : (& ty compiler_ast_types.AstType)]) : i64
  (match ty
    [(I8) 1]
    [(U8) 2]
    [(I16) 3]
    [(U16) 4]
    [(I32) 5]
    [(U32) 6]
    [(I64) 7]
    [(U64) 8]
    [_ 0]))

(define (compiler-backend-simd-ir-value-copy
  [value : (& value compiler_ir_types.CompilerIrValue)]) : compiler_ir_types.CompilerIrValue
  (match value
    [(Var id) (Var id)]
    [(I64 n) (I64 n)]
    [(F64 bits) (F64 bits)]
    [(Bool b) (Bool b)]
    [(Char c) (Char c)]
    [(Unit) Unit]
    [_ Unit]))

(define (compiler-backend-simd-ir-value-eq?
  [a : (& a compiler_ir_types.CompilerIrValue)]
  [b : (& b compiler_ir_types.CompilerIrValue)]) : bool
  (match a
    [(Var aid)
      (match b
        [(Var bid) (= aid bid)]
        [_ false])]
    [(I64 av)
      (match b
        [(I64 bv) (= av bv)]
        [_ false])]
    [_ false]))

(define (compiler-backend-simd-select-factor-has-candidate?
  [blocks : (& blocks compiler_ir_types.CompilerIrBlockList)]) : bool
  (match blocks
    [(Array seq)
      (let
        [bcount : i64 (compiler_ir_types.compiler-ir-block-seq-count seq)]
        [b : i64 0]
        [found : bool false]
        (while (and (< b bcount) (not found))
          (match (compiler_ir_types.compiler-ir-block-seq-borrow seq b)
            [(Block _ instrs)
              (let
                [i : i64 0]
                [icount : i64 instrs.len]
                (while (and (< i icount) (not found))
                  (match (compiler_ir_types.compiler-ir-instr-seq-borrow
                    instrs
                    i)
                    [(Select sp)
                      (when
                        (> (compiler-backend-simd-int-type-tag (& sp.ty)) 0)
                        (set! found true))]
                    [_ unit])
                  (set! i (+ i 1))))])
          (set! b (+ b 1)))
        found)]))

(define (compiler-backend-simd-op-add-sub-code
  [op : (& op compiler_ir_types.CompilerIrBinOp)]) : i64
  (match op
    [(Add) 1]
    [(Sub) 2]
    [_ 0]))

;; The select-factor pass's per-var facts, one row of nine per var:
;; 0 defs, 1 uses (the backend's shared operand walk), 2 splat-ok, 3 splat-is-const, 4 splat-val (constant or
;; source var), 5 splat-lanes, 6 splat-ty-tag, 7 neg-splat-var,
;; 8 neg-scalar-var (-1 until allocated).
(define (compiler-backend-simd-select-factor-fact
  [facts : (& facts (__tl_dyn-array i64))]
  [var : i64]
  [field : i64]) : i64
  (array-ref facts (+ (* var 9) field)))

(define (compiler-backend-simd-select-factor-var?
  [facts : (& facts (__tl_dyn-array i64))]
  [var : i64]) : bool
  (and (>= var 0) (< var (/ (array-length facts) 9))))

;; VAR has one def and one use, so the factor pass may drop it.
(define (compiler-backend-simd-select-factor-single?
  [facts : (& facts (__tl_dyn-array i64))]
  [var : i64]) : bool
  (and
    (compiler-backend-simd-select-factor-var? facts var)
    (= (compiler-backend-simd-select-factor-fact facts var 0) 1)
    (= (compiler-backend-simd-select-factor-fact facts var 1) 1)))

(define (compiler-backend-simd-int-tag-type [tag : i64]) : compiler_ast_types.AstType
  (cond
    [(= tag 1) (I8)]
    [(= tag 2) (U8)]
    [(= tag 3) (I16)]
    [(= tag 4) (U16)]
    [(= tag 5) (I32)]
    [(= tag 6) (U32)]
    [(= tag 8) (U64)]
    [else (I64)]))

;; Pass 1 of the select-factor pass for one instruction: def counts and
;; single-def integer Splats.
(define (compiler-backend-simd-select-factor-scan-instr!
  [facts : (&mut facts (__tl_dyn-array i64))]
  [instrs : (& instrs compiler_ir_types.CompilerIrInstrSeq)]
  [i : i64]) : unit
  (let
    [vars : i64 (/ (array-length facts) 9)]
    [instr (compiler_ir_types.compiler-ir-instr-seq-borrow instrs i)]
    [dst : i64 (compiler_ir_types.compiler-ir-instr-dst instr)]
    (when
      (and (>= dst 0) (< dst vars))
      (set! (array-ref facts (* dst 9)) (+ (array-ref facts (* dst 9)) 1)))
    (match instr
      [(Splat sdst svalue slanes sty)
        (let
          [ttag : i64 (compiler-backend-simd-int-type-tag (& sty))]
          [val : i64
            (match (& svalue)
              [(I64 c) c]
              [(Var vid) vid]
              [_ -1])]
          [is-const : i64
            (match (& svalue)
              [(I64 _) 1]
              [_ 0])]
          (when
            (and
              (> ttag 0)
              (>= sdst 0)
              (< sdst vars)
              (or (= is-const 1) (and (>= val 0) (< val vars))))
            (set! (array-ref facts (+ (* sdst 9) 2)) 1)
            (set! (array-ref facts (+ (* sdst 9) 3)) is-const)
            (set! (array-ref facts (+ (* sdst 9) 4)) val)
            (set! (array-ref facts (+ (* sdst 9) 5)) slanes)
            (set! (array-ref facts (+ (* sdst 9) 6)) ttag)))]
      [_ unit])))

;; True when `var` is a single-def Splat whose negation can stand for it in a
;; factored `lanes`-wide select of integer type tag `tag`.
(define (compiler-backend-simd-select-factor-neg-splat?
  [facts : (& facts (__tl_dyn-array i64))]
  [var : i64]
  [lanes : i64]
  [tag : i64]) : bool
  (and
    (compiler-backend-simd-select-factor-var? facts var)
    (= (compiler-backend-simd-select-factor-fact facts var 0) 1)
    (= (compiler-backend-simd-select-factor-fact facts var 2) 1)
    (= (compiler-backend-simd-select-factor-fact facts var 5) lanes)
    (= (compiler-backend-simd-select-factor-fact facts var 6) tag)))

;; How `select(m, tl t-op tr, fl f-op fr)` factors, as kind * 4 + t-side * 2
;; + f-side (0 when it does not): kind 1 Add, 2 Sub, 3 Add with negated fr,
;; 4 Add with negated tr; a side names the operand (0 left, 1 right) shared
;; as the common `x`.
(define (compiler-backend-simd-select-factor-kind
  [facts : (& facts (__tl_dyn-array i64))]
  [t-op : i64]
  [f-op : i64]
  [tl : (& tl compiler_ir_types.CompilerIrValue)]
  [tr : (& tr compiler_ir_types.CompilerIrValue)]
  [fl : (& fl compiler_ir_types.CompilerIrValue)]
  [fr : (& fr compiler_ir_types.CompilerIrValue)]
  [lanes : i64]
  [tag : i64]) : i64
  (cond
    [(and (= t-op 1) (= f-op 1))
      (cond
        [(compiler-backend-simd-ir-value-eq? tl fl) 4]
        [(compiler-backend-simd-ir-value-eq? tl fr) 5]
        [(compiler-backend-simd-ir-value-eq? tr fl) 6]
        [(compiler-backend-simd-ir-value-eq? tr fr) 7]
        [else 0])]
    [(and (= t-op 2) (= f-op 2))
      (if (compiler-backend-simd-ir-value-eq? tl fl)
        8
        0)]
    [(and (= t-op 1) (= f-op 2))
      (cond
        [(not
            (compiler-backend-simd-select-factor-neg-splat?
              facts
              (compiler-backend-avx2-sign-bit-var-id fr)
              lanes
              tag))
          0]
        [(compiler-backend-simd-ir-value-eq? tl fl) 12]
        [(compiler-backend-simd-ir-value-eq? tr fl) 14]
        [else 0])]
    [(and (= t-op 2) (= f-op 1))
      (cond
        [(not
            (compiler-backend-simd-select-factor-neg-splat?
              facts
              (compiler-backend-avx2-sign-bit-var-id tr)
              lanes
              tag))
          0]
        [(compiler-backend-simd-ir-value-eq? tl fl) 16]
        [(compiler-backend-simd-ir-value-eq? tl fr) 17]
        [else 0])]
    [else 0]))

;; The negated-splat var shared by every factored select of `neg-id`,
;; allocated from `next-var` on first use. Returns the next free var.
(define (compiler-backend-simd-select-factor-neg-var!
  [facts : (&mut facts (__tl_dyn-array i64))]
  [neg-id : i64]
  [next-var : i64]) : i64
  (if (>= (array-ref facts (+ (* neg-id 9) 7)) 0)
    next-var
    (if (= (array-ref facts (+ (* neg-id 9) 3)) 0)
      (begin
        (set! (array-ref facts (+ (* neg-id 9) 8)) next-var)
        (set! (array-ref facts (+ (* neg-id 9) 7)) (+ next-var 1))
        (+ next-var 2))
      (begin
        (set! (array-ref facts (+ (* neg-id 9) 7)) next-var)
        (+ next-var 1)))))

;; Emit the factored `d1 = select(m, sel-t, sel-f); ds = common op d1` for
;; factor code `code` (see compiler-backend-simd-select-factor-kind). Returns
;; the next free var.
(define (compiler-backend-simd-select-factor-emit!
  [facts : (&mut facts (__tl_dyn-array i64))]
  [builder : (&mut builder compiler_ir_types.CompilerIrInstrBuilder)]
  [code : i64]
  [tl : compiler_ir_types.CompilerIrValue]
  [tr : compiler_ir_types.CompilerIrValue]
  [fl : compiler_ir_types.CompilerIrValue]
  [fr : compiler_ir_types.CompilerIrValue]
  [d1 : i64]
  [ds : i64]
  [mask : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [ty : (& ty compiler_ast_types.AstType)]
  [next-var : i64]) : i64
  (let
    [kind : i64 (/ code 4)]
    [t-side : i64 (bit-and (/ code 2) 1)]
    [f-side : i64 (bit-and code 1)]
    [neg-id : i64
      (cond
        [(= kind 3) (compiler-backend-avx2-sign-bit-var-id (& fr))]
        [(= kind 4) (compiler-backend-avx2-sign-bit-var-id (& tr))]
        [else -1])]
    [after : i64
      (if (>= neg-id 0)
        (compiler-backend-simd-select-factor-neg-var! facts neg-id next-var)
        next-var)]
    [common : compiler_ir_types.CompilerIrValue
      (compiler-backend-simd-ir-value-copy
        (if (= t-side 1)
          (& tr)
          (& tl)))]
    [sel-t : compiler_ir_types.CompilerIrValue
      (cond
        [(= kind 4) (Var (array-ref facts (+ (* neg-id 9) 7)))]
        [(= t-side 1) (compiler-backend-simd-ir-value-copy (& tl))]
        [else (compiler-backend-simd-ir-value-copy (& tr))])]
    [sel-f : compiler_ir_types.CompilerIrValue
      (cond
        [(= kind 3) (Var (array-ref facts (+ (* neg-id 9) 7)))]
        [(= f-side 1) (compiler-backend-simd-ir-value-copy (& fl))]
        [else (compiler-backend-simd-ir-value-copy (& fr))])]
    (compiler_ir_types.compiler-ir-instr-builder-push!
      builder
      (Select
        (box
          (compiler_ir_types.CompilerIrInstrSelectPayload
            d1
            mask
            sel-t
            sel-f
            lanes
            (compiler-backend-copy-int-ast-type ty)))))
    (compiler_ir_types.compiler-ir-instr-builder-push!
      builder
      (VectorBinOp
        (box
          (compiler_ir_types.CompilerIrInstrVectorBinOpPayload
            ds
            (if (= kind 2)
              (Sub)
              (Add))
            common
            (Var d1)
            lanes
            (compiler-backend-copy-int-ast-type ty)))))
    after))

;; Pass 2 of the select-factor pass at instruction `i`: when an adjacent
;; (VectorBinOp, VectorBinOp, Select) triple there factors, push its rewrite
;; and return the next free var; otherwise return -1 and push nothing.
(define (compiler-backend-simd-select-factor-try!
  [facts : (&mut facts (__tl_dyn-array i64))]
  [builder : (&mut builder compiler_ir_types.CompilerIrInstrBuilder)]
  [instrs : (& instrs compiler_ir_types.CompilerIrInstrSeq)]
  [i : i64]
  [next-var : i64]) : i64
  (if (> (+ i 2) (- instrs.len 1))
    -1
    (match (compiler_ir_types.compiler-ir-instr-seq-borrow instrs i)
      [(VectorBinOp p1)
        (match (compiler_ir_types.compiler-ir-instr-seq-borrow instrs (+ i 1))
          [(VectorBinOp p2)
            (match (compiler_ir_types.compiler-ir-instr-seq-borrow
              instrs
              (+ i 2))
              [(Select sp)
                (let
                  [d1 : i64 p1.dst]
                  [d2 : i64 p2.dst]
                  [tag : i64 (compiler-backend-simd-int-type-tag (& p1.ty))]
                  [tl-id : i64
                    (compiler-backend-avx2-sign-bit-var-id (& sp.on-true))]
                  [fl-id : i64
                    (compiler-backend-avx2-sign-bit-var-id (& sp.on-false))]
                  [direct? : bool (and (= tl-id d1) (= fl-id d2))]
                  [tp
                    (if direct?
                      p1
                      p2)]
                  [fp
                    (if direct?
                      p2
                      p1)]
                  [t-op : i64 (compiler-backend-simd-op-add-sub-code (& tp.op))]
                  [f-op : i64 (compiler-backend-simd-op-add-sub-code (& fp.op))]
                  [code : i64
                    (if (and
                      (> t-op 0)
                      (> f-op 0)
                      (> tag 0)
                      (= tag (compiler-backend-simd-int-type-tag (& p2.ty)))
                      (= tag (compiler-backend-simd-int-type-tag (& sp.ty)))
                      (= p1.lanes p2.lanes)
                      (= p1.lanes sp.lanes)
                      (!= d1 d2)
                      (!= sp.dst d1)
                      (!= sp.dst d2)
                      (compiler-backend-simd-select-factor-single? (& facts) d1)
                      (compiler-backend-simd-select-factor-single? (& facts) d2)
                      (or direct? (and (= tl-id d2) (= fl-id d1))))
                      (compiler-backend-simd-select-factor-kind
                        (& facts)
                        t-op
                        f-op
                        (& tp.lhs)
                        (& tp.rhs)
                        (& fp.lhs)
                        (& fp.rhs)
                        sp.lanes
                        tag)
                      0)]
                  (if (= code 0)
                    -1
                    (compiler-backend-simd-select-factor-emit!
                      facts
                      builder
                      code
                      (compiler-backend-simd-ir-value-copy (& tp.lhs))
                      (compiler-backend-simd-ir-value-copy (& tp.rhs))
                      (compiler-backend-simd-ir-value-copy (& fp.lhs))
                      (compiler-backend-simd-ir-value-copy (& fp.rhs))
                      d1
                      sp.dst
                      (compiler-backend-simd-ir-value-copy (& sp.mask))
                      sp.lanes
                      (& sp.ty)
                      next-var)))]
              [_ -1])]
          [_ -1])]
      [_ -1])))

;; Pass 3 of the select-factor pass for one instruction: copy it, and splice a
;; negated splat allocated for it right after it.
(define (compiler-backend-simd-select-factor-splice-instr!
  [facts : (& facts (__tl_dyn-array i64))]
  [builder : (&mut builder compiler_ir_types.CompilerIrInstrBuilder)]
  [instrs : (& instrs compiler_ir_types.CompilerIrInstrSeq)]
  [i : i64]) : unit
  (let
    [sdst : i64
      (match (compiler_ir_types.compiler-ir-instr-seq-borrow instrs i)
        [(Splat sdst _ _ _) sdst]
        [_ -1])]
    (compiler_ir_types.compiler-ir-instr-builder-push!
      builder
      (compiler_ir_types.compiler-ir-instr-seq-ref instrs i))
    (when
      (and
        (compiler-backend-simd-select-factor-var? facts sdst)
        (>= (compiler-backend-simd-select-factor-fact facts sdst 7) 0))
      (let
        [ns-var : i64 (compiler-backend-simd-select-factor-fact facts sdst 7)]
        [slanes : i64 (compiler-backend-simd-select-factor-fact facts sdst 5)]
        [val : i64 (compiler-backend-simd-select-factor-fact facts sdst 4)]
        [ttag : i64 (compiler-backend-simd-select-factor-fact facts sdst 6)]
        (if (= (compiler-backend-simd-select-factor-fact facts sdst 3) 1)
          (compiler_ir_types.compiler-ir-instr-builder-push!
            builder
            (Splat
              ns-var
              (I64 (- 0 val))
              slanes
              (compiler-backend-simd-int-tag-type ttag)))
          (let
            [nsc-var : i64
              (compiler-backend-simd-select-factor-fact facts sdst 8)]
            (compiler_ir_types.compiler-ir-instr-builder-push!
              builder
              (UnOp
                nsc-var
                (Neg)
                (Var val)
                (compiler-backend-simd-int-tag-type ttag)))
            (compiler_ir_types.compiler-ir-instr-builder-push!
              builder
              (Splat
                ns-var
                (Var nsc-var)
                slanes
                (compiler-backend-simd-int-tag-type ttag)))))))))

(define (compiler-backend-simd-select-factor-splice
  [facts : (& facts (__tl_dyn-array i64))]
  [rebuilt-seq : compiler_ir_types.CompilerIrBlockSeq]) : compiler_ir_types.CompilerIrBlockSeq
  (let
    [bcount : i64 (compiler_ir_types.compiler-ir-block-seq-count rebuilt-seq)]
    [final-blocks : (__tl_dyn-array compiler_ir_types.CompilerIrBlock)
      (__tl_make-array compiler_ir_types.CompilerIrBlock 0)]
    (for [b (iterator.range 0 bcount)]
      (match (compiler_ir_types.compiler-ir-block-seq-borrow rebuilt-seq b)
        [(Block label instrs)
          (let
            [builder : compiler_ir_types.CompilerIrInstrBuilder
              (compiler_ir_types.compiler-ir-instr-builder-with-capacity
                instrs.len)]
            (for [i (iterator.range 0 instrs.len)]
              (compiler-backend-simd-select-factor-splice-instr!
                facts
                (&mut builder)
                instrs
                i))
            (__tl_array-push!
              final-blocks
              (Block
                label
                (compiler_ir_types.compiler-ir-instr-builder-to-seq builder))))]))
    (compiler_ir_types.CompilerIrBlockSeq final-blocks bcount)))

;; Pre-regalloc SIMD algebraic select-add/sub factoring:
;;   select(m, x + a, x + b) -> x + select(m, a, b)
;;   select(m, x - a, x - b) -> x - select(m, a, b)
;;   select(m, x + a, x - b) -> x + select(m, a, -b)  when b is a single-def Splat
;;   select(m, x - a, x + b) -> x + select(m, -a, b)  when a is a single-def Splat
;; Negated splats are inserted right after the original Splat (so preheader
;; splats stay hoisted out of loops) and shared across unrolled copies.
;; `uses` holds the function's use counts; the caller runs this only when
;; vars > 0 and compiler-backend-simd-select-factor-has-candidate? holds.
(define (compiler-backend-simd-select-add-factor-blocks
  [vars : i64]
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [uses : (& uses (__tl_dyn-array i64))]) : CompilerBackendSelectFactorResult
  (match blocks
    [(Array seq)
      (let
        [bcount : i64 (compiler_ir_types.compiler-ir-block-seq-count seq)]
        [facts : (__tl_dyn-array i64) (__tl_make-array i64 (* vars 9))]
        [next-var : i64 vars]
        [changed : bool false]
        [rebuilt-blocks : (__tl_dyn-array compiler_ir_types.CompilerIrBlock)
          (__tl_make-array compiler_ir_types.CompilerIrBlock 0)]
        (for [v (iterator.range 0 vars)]
          (when
            (< v (array-length uses))
            (set! (array-ref facts (+ (* v 9) 1)) (array-ref uses v)))
          (set! (array-ref facts (+ (* v 9) 7)) -1)
          (set! (array-ref facts (+ (* v 9) 8)) -1))
        (for [b (iterator.range 0 bcount)]
          (match (compiler_ir_types.compiler-ir-block-seq-borrow seq b)
            [(Block _ instrs)
              (for [i (iterator.range 0 instrs.len)]
                (compiler-backend-simd-select-factor-scan-instr!
                  (&mut facts)
                  instrs
                  i))]))
        (for [b (iterator.range 0 bcount)]
          (match (compiler_ir_types.compiler-ir-block-seq-borrow seq b)
            [(Block label instrs)
              (let
                [builder : compiler_ir_types.CompilerIrInstrBuilder
                  (compiler_ir_types.compiler-ir-instr-builder-with-capacity
                    instrs.len)]
                [i : i64 0]
                (while (< i instrs.len)
                  (let
                    [after : i64
                      (compiler-backend-simd-select-factor-try!
                        (&mut facts)
                        (&mut builder)
                        instrs
                        i
                        next-var)]
                    (if (>= after 0)
                      (begin
                        (set! next-var after)
                        (set! changed true)
                        (set! i (+ i 3)))
                      (begin
                        (compiler_ir_types.compiler-ir-instr-builder-push!
                          (&mut builder)
                          (compiler_ir_types.compiler-ir-instr-seq-ref instrs i))
                        (set! i (+ i 1))))))
                (__tl_array-push!
                  rebuilt-blocks
                  (Block
                    label
                    (compiler_ir_types.compiler-ir-instr-builder-to-seq builder))))]))
        (cond
          [(not changed) (SelectFactorResult vars (Array seq))]
          [(= next-var vars)
            (SelectFactorResult
              next-var
              (Array
                (compiler_ir_types.CompilerIrBlockSeq rebuilt-blocks bcount)))]
          [else
            (SelectFactorResult
              next-var
              (Array
                (compiler-backend-simd-select-factor-splice
                  (& facts)
                  (compiler_ir_types.CompilerIrBlockSeq rebuilt-blocks bcount))))]))]))

(define (compiler-backend-avx2-single-bit-index [value : i64]) : i64
  (if (or (= value 0) (!= (bit-and value (- value 1)) 0))
    -1
    (if (< value 0)
      63
      (let
        [k : i64 0]
        [v : i64 value]
        (while (> v 1)
          (set! v (/ v 2))
          (set! k (+ k 1)))
        k))))

(define (compiler-backend-avx2-sign-bit-int64-ty?
  [ty : (& ty compiler_ast_types.AstType)]) : bool
  (match ty
    [(or (I64) (U64)) true]
    [_ false]))

(define (compiler-backend-avx2-sign-bit-select-ty?
  [ty : (& ty compiler_ast_types.AstType)]) : bool
  (match ty
    [(or (I64) (U64) (F64)) true]
    [_ false]))

;; The sign-bit plan's per-var facts, one row of five per var:
;; 0 defs, 1 has-splat, 2 splat-val, 3 select-only, 4 uses as the mask of a
;; 64-bit 4-lane Select.
(define (compiler-backend-avx2-sign-bit-fact
  [facts : (& facts (__tl_dyn-array i64))]
  [var : i64]
  [field : i64]) : i64
  (array-ref facts (+ (* var 5) field)))

;; A 64-bit Eq/Ne compare with `target-lanes` (4 in AVX2, 2 in SSE2), the only
;; kind the sign-bit plan rewrites.
(define (compiler-backend-avx2-sign-bit-compare?
  [p : (& p compiler_ir_types.CompilerIrInstrVectorComparePayload)]
  [target-lanes : i64]) : bool
  (and
    (= p.lanes target-lanes)
    (compiler-backend-avx2-sign-bit-int64-ty? (& p.ty))
    (match (& p.op)
      [(or (Eq) (Ne)) true]
      [_ false])))

(define (compiler-backend-avx2-sign-bit-single-def?
  [facts : (& facts (__tl_dyn-array i64))]
  [var : i64]) : bool
  (and
    (>= var 0)
    (< var (/ (array-length facts) 5))
    (= (array-ref facts (* var 5)) 1)))

(define (compiler-backend-avx2-sign-bit-single-bit-splat?
  [facts : (& facts (__tl_dyn-array i64))]
  [var : i64]) : bool
  (and
    (compiler-backend-avx2-sign-bit-single-def? facts var)
    (= (compiler-backend-avx2-sign-bit-fact facts var 1) 1)
    (>=
      (compiler-backend-avx2-single-bit-index
        (compiler-backend-avx2-sign-bit-fact facts var 2))
      0)))

;; Pass 1 of the sign-bit plan for one instruction: def counts, single-def
;; `target-lanes`-lane 64-bit constant splats, Eq/Ne compares, and mask uses by
;; 64-bit `target-lanes`-lane Selects.
(define (compiler-backend-avx2-sign-bit-scan-instr!
  [facts : (&mut facts (__tl_dyn-array i64))]
  [instrs : (& instrs compiler_ir_types.CompilerIrInstrSeq)]
  [i : i64]
  [target-lanes : i64]) : unit
  (let
    [var-count : i64 (/ (array-length facts) 5)]
    [instr (compiler_ir_types.compiler-ir-instr-seq-borrow instrs i)]
    [dst : i64 (compiler_ir_types.compiler-ir-instr-dst instr)]
    (when
      (and (>= dst 0) (< dst var-count))
      (set! (array-ref facts (* dst 5)) (+ (array-ref facts (* dst 5)) 1)))
    (match instr
      [(Splat sdst svalue slanes sty)
        (when
          (and
            (= slanes target-lanes)
            (>= sdst 0)
            (< sdst var-count)
            (compiler-backend-avx2-sign-bit-int64-ty? (& sty)))
          (match (& svalue)
            [(I64 c)
              (set! (array-ref facts (+ (* sdst 5) 1)) 1)
              (set! (array-ref facts (+ (* sdst 5) 2)) c)]
            [_ unit]))]
      [(VectorCompare p)
        (when
          (and
            (>= p.dst 0)
            (< p.dst var-count)
            (compiler-backend-avx2-sign-bit-compare? p target-lanes))
          (set! (array-ref facts (+ (* p.dst 5) 3)) 1))]
      [(Select p)
        (let
          [mask-id : i64 (compiler-backend-avx2-sign-bit-var-id (& p.mask))]
          (when
            (and
              (= p.lanes target-lanes)
              (compiler-backend-avx2-sign-bit-select-ty? (& p.ty))
              (>= mask-id 0)
              (< mask-id var-count))
            (set!
              (array-ref facts (+ (* mask-id 5) 4))
              (+ (array-ref facts (+ (* mask-id 5) 4)) 1))))]
      [_ unit])))

(define (compiler-backend-avx2-sign-bit-has-candidate?
  [blocks : (& blocks compiler_ir_types.CompilerIrBlockList)]
  [target-lanes : i64]) : bool
  (match blocks
    [(Array seq)
      (let
        [bcount : i64 (compiler_ir_types.compiler-ir-block-seq-count seq)]
        [b : i64 0]
        [found : bool false]
        (while (and (< b bcount) (not found))
          (match (compiler_ir_types.compiler-ir-block-seq-borrow seq b)
            [(Block _ instrs)
              (let
                [icount : i64 instrs.len]
                [i : i64 0]
                (while (and (< i icount) (not found))
                  (match (compiler_ir_types.compiler-ir-instr-seq-borrow
                    instrs
                    i)
                    [(VectorCompare p)
                      (when
                        (compiler-backend-avx2-sign-bit-compare? p target-lanes)
                        (set! found true))]
                    [_ unit])
                  (set! i (+ i 1))))])
          (set! b (+ b 1)))
        found)]))

(define (compiler-backend-avx2-sign-bit-var-id
  [value : (& value compiler_ir_types.CompilerIrValue)]) : i64
  (match value
    [(Var id) id]
    [_ -1]))

;; The sign-bit table entry for `and-dst = bit_and(lhs, rhs)` followed by
;; `cmp-dst = compare_{eq,ne}(cl, cr)` (cmp-op 1 Eq, 2 Ne), or 0 when the
;; pair does not qualify: polarity * 256 + lhs-is-splat * 64 + k.
(define (compiler-backend-avx2-sign-bit-pair-code
  [facts : (& facts (__tl_dyn-array i64))]
  [use-counts : (& use-counts (__tl_dyn-array i64))]
  [and-dst : i64]
  [lhs-id : i64]
  [rhs-id : i64]
  [cmp-dst : i64]
  [cl-id : i64]
  [cr-id : i64]
  [cmp-op : i64]) : i64
  (let
    [rhs-ok : bool
      (compiler-backend-avx2-sign-bit-single-bit-splat? facts rhs-id)]
    [lhs-ok : bool
      (and
        (not rhs-ok)
        (compiler-backend-avx2-sign-bit-single-bit-splat? facts lhs-id))]
    [other-id : i64
      (if (= cl-id and-dst)
        cr-id
        (if (= cr-id and-dst)
          cl-id
          -1))]
    (if (and
      (compiler-backend-avx2-sign-bit-single-def? facts and-dst)
      (compiler-backend-var-single-use? use-counts and-dst)
      (compiler-backend-avx2-sign-bit-single-def? facts cmp-dst)
      (= (compiler-backend-avx2-sign-bit-fact facts cmp-dst 3) 1)
      (< cmp-dst (array-length use-counts))
      (>= (array-ref use-counts cmp-dst) 1)
      ;; Every use of the compare is the mask of a 64-bit 4-lane Select.
      (=
        (array-ref use-counts cmp-dst)
        (compiler-backend-avx2-sign-bit-fact facts cmp-dst 4))
      (or rhs-ok lhs-ok)
      (compiler-backend-avx2-sign-bit-single-def? facts other-id)
      (= (compiler-backend-avx2-sign-bit-fact facts other-id 1) 1))
      (let
        [bit-const : i64
          (compiler-backend-avx2-sign-bit-fact
            facts
            (if rhs-ok
              rhs-id
              lhs-id)
            2)]
        [cmp-const : i64 (compiler-backend-avx2-sign-bit-fact facts other-id 2)]
        [polarity : i64
          (cond
            [(= cmp-op 1)
              (if (= cmp-const bit-const)
                1
                (if (= cmp-const 0)
                  2
                  0))]
            [(= cmp-op 2)
              (if (= cmp-const 0)
                1
                (if (= cmp-const bit-const)
                  2
                  0))]
            [else 0])]
        (if (> polarity 0)
          (+
            (+
              (* polarity 256)
              (if rhs-ok
                0
                64))
            (compiler-backend-avx2-single-bit-index bit-const))
          0))
      0)))

;; Pass 2 of the sign-bit plan for one block: record each qualifying adjacent
;; 64-bit `target-lanes`-lane (bit_and, compare) pair in `table`; true when one
;; was found.
(define (compiler-backend-avx2-sign-bit-plan-block!
  [table : (&mut table (__tl_dyn-array i64))]
  [facts : (& facts (__tl_dyn-array i64))]
  [use-counts : (& use-counts (__tl_dyn-array i64))]
  [instrs : (& instrs compiler_ir_types.CompilerIrInstrSeq)]
  [target-lanes : i64]) : bool
  (let
    [found : bool false]
    (for [i (iterator.range 0 (- instrs.len 1))]
      (match (compiler_ir_types.compiler-ir-instr-seq-borrow instrs i)
        [(VectorBinOp ap)
          (when
            (and
              (= ap.lanes target-lanes)
              (match (& ap.op)
                [(BitAnd) true]
                [_ false])
              (compiler-backend-avx2-sign-bit-int64-ty? (& ap.ty)))
            (match (compiler_ir_types.compiler-ir-instr-seq-borrow
              instrs
              (+ i 1))
              [(VectorCompare cp)
                (when
                  (and
                    (= cp.lanes target-lanes)
                    (compiler-backend-avx2-sign-bit-int64-ty? (& cp.ty)))
                  (let
                    [code : i64
                      (compiler-backend-avx2-sign-bit-pair-code
                        facts
                        use-counts
                        ap.dst
                        (compiler-backend-avx2-sign-bit-var-id (& ap.lhs))
                        (compiler-backend-avx2-sign-bit-var-id (& ap.rhs))
                        cp.dst
                        (compiler-backend-avx2-sign-bit-var-id (& cp.lhs))
                        (compiler-backend-avx2-sign-bit-var-id (& cp.rhs))
                        (match (& cp.op)
                          [(Eq) 1]
                          [(Ne) 2]
                          [_ 0]))]
                    (when
                      (> code 0)
                      (set! (array-ref table cp.dst) code)
                      (set! found true))))]
              [_ unit]))]
        [_ unit]))
    found))

;; Pre-pass over an AVX2 or SSE2 function's blocks: identify 64-bit single-bit
;; tests `vector_compare_{eq,ne}(vector_bit_and(x, splat(1<<k)), splat(1<<k|0))`
;; whose result is consumed strictly as the mask of 64-bit Select(s).
;; AVX2 only needs bit 63 set (`vpsllq` + `vblendvpd`); SSE2 smears the bit
;; across both dwords via `pshufd $0xA0/$0xF5; pslld; psrad $31`.
(define (compiler-backend-avx2-sign-bit-mask-plan!
  [function-state : be_state.CompilerBackendFunctionState]
  [vars : i64]
  [blocks : (& blocks compiler_ir_types.CompilerIrBlockList)]
  [use-counts : (& use-counts (__tl_dyn-array i64))]) : unit
  ;; Drop a previous function's table; an already empty one is kept.
  (when
    (>
      (array-length
        (be_state.compiler-backend-function-state-i64-array
          function-state
          be_state.compiler-backend-function-i64-array-avx2-sign-bit-masks))
      0)
    (be_state.compiler-backend-function-state-set-i64-array!
      function-state
      be_state.compiler-backend-function-i64-array-avx2-sign-bit-masks
      (__tl_make-array i64 0)))
  (let
    [use-len : i64 (array-length use-counts)]
    [var-count : i64
      (if (> use-len vars)
        use-len
        vars)]
    [sse2? : bool (be_state.compiler-backend-current-mode-sse2? function-state)]
    [avx2? : bool (be_state.compiler-backend-current-mode-avx2? function-state)]
    [target-lanes : i64
      (if sse2?
        2
        4)]
    (when
      (and
        (> var-count 0)
        (or avx2? sse2?)
        (compiler-backend-avx2-sign-bit-has-candidate? blocks target-lanes))
      (match blocks
        [(Array seq)
          (let
            [facts : (__tl_dyn-array i64) (__tl_make-array i64 (* var-count 5))]
            [table : (__tl_dyn-array i64) (__tl_make-array i64 var-count)]
            [any-found : bool false]
            [bcount : i64 (compiler_ir_types.compiler-ir-block-seq-count seq)]
            (for [b (iterator.range 0 bcount)]
              (match (compiler_ir_types.compiler-ir-block-seq-borrow seq b)
                [(Block _ instrs)
                  (for [i (iterator.range 0 instrs.len)]
                    (compiler-backend-avx2-sign-bit-scan-instr!
                      (&mut facts)
                      instrs
                      i
                      target-lanes))]))
            (for [b (iterator.range 0 bcount)]
              (match (compiler_ir_types.compiler-ir-block-seq-borrow seq b)
                [(Block _ instrs)
                  (when
                    (compiler-backend-avx2-sign-bit-plan-block!
                      (&mut table)
                      (& facts)
                      use-counts
                      instrs
                      target-lanes)
                    (set! any-found true))]))
            (when
              any-found
              (be_state.compiler-backend-function-state-set-i64-array!
                function-state
                be_state.compiler-backend-function-i64-array-avx2-sign-bit-masks
                table)))]))))

(define (compiler-backend-avx2-sign-bit-mask-mode-for-var
  [backend-state : be_state.CompilerBackendState]
  [var : i64]) : i64
  (let
    [table : (__tl_dyn-array i64)
      (be_state.compiler-backend-function-state-i64-array
        (be_state.compiler-backend-state-function-state backend-state)
        be_state.compiler-backend-function-i64-array-avx2-sign-bit-masks)]
    (if (and (>= var 0) (< var (array-length table)))
      (array-ref table var)
      0)))

(define (compiler-backend-avx2-sign-bit-mask-mode
  [backend-state : be_state.CompilerBackendState]
  [mask : (& mask compiler_ir_types.CompilerIrValue)]) : i64
  (match mask
    [(Var id)
      (compiler-backend-avx2-sign-bit-mask-mode-for-var backend-state id)]
    [_ 0]))

(define (compiler-backend-emit-avx2-sign-bit-mask
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [src : compiler_ir_types.CompilerIrValue]
  [bit-index : i64]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [sse2? : bool
      (be_state.compiler-backend-current-mode-sse2?
        (be_state.compiler-backend-state-function-state backend-state))]
    (if (if sse2?
      (be_operand.compiler-backend-sse2-shape-ok? elem-ty lanes)
      (be_operand.compiler-backend-avx2-shape-ok? elem-ty lanes))
      (match (be_operand.compiler-backend-vector-register-use
        assignments
        src
        "sign-bit mask src"
        (if sse2?
          "xmm"
          "ymm")
        elem-ty
        (if sse2?
          "%xmm14"
          "%ymm14")
        backend-state)
        [(Ok src-use)
          (match src-use
            [(Use src-asm src-reg)
              (match (compiler-backend-vector-dst-reg
                assignments
                dst
                "sign-bit mask dst"
                (if sse2?
                  "xmm"
                  "ymm")
                (if sse2?
                  "%xmm14"
                  "%ymm14")
                backend-state)
                [(Ok dst-reg)
                  (let
                    [body-asm : String
                      (if sse2?
                        (let
                          [hi? : bool (>= bit-index 32)]
                          [shuf-imm : String
                            (if hi?
                              "$245"
                              "$160")]
                          [shift : i64
                            (if hi?
                              (- 63 bit-index)
                              (- 31 bit-index))]
                          [shift-asm : String
                            (if (> shift 0)
                              (str_cat.str-cat
                                "    pslld $"
                                (string.int->string shift)
                                ", "
                                dst-reg
                                "\n")
                              "")]
                          (str_cat.str-cat
                            "    pshufd "
                            shuf-imm
                            ", "
                            src-reg
                            ", "
                            dst-reg
                            "\n"
                            shift-asm
                            "    psrad $31, "
                            dst-reg
                            "\n"))
                        (let
                          [shift : i64 (- 63 bit-index)]
                          (if (> shift 0)
                            (str_cat.str-cat
                              "    vpsllq $"
                              (string.int->string shift)
                              ", "
                              src-reg
                              ", "
                              dst-reg
                              "\n")
                            (if (string.eq src-reg dst-reg)
                              ""
                              (str_cat.str-cat
                                "    vmovdqa "
                                src-reg
                                ", "
                                dst-reg
                                "\n")))))]
                    (Ok
                      (str_cat.str-cat
                        src-asm
                        body-asm
                        (compiler-backend-vector-store-dst
                          assignments
                          dst
                          (if sse2?
                            "xmm"
                            "ymm")
                          (I8)
                          dst-reg
                          backend-state))))]
                [(Err message)
                  (be_state.compiler-backend-instr-error instr-diag message)])])]
        [(Err message)
          (be_state.compiler-backend-instr-error instr-diag message)])
      (if sse2?
        (be_operand.compiler-backend-sse2-shape-diagnostic
          type-segment-bases
          instr-diag
          elem-ty
          lanes)
        (be_operand.compiler-backend-avx2-shape-diagnostic
          type-segment-bases
          instr-diag
          elem-ty
          lanes)))))

(define (compiler-backend-emit-avx2-select
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [mask : compiler_ir_types.CompilerIrValue]
  [on-true : compiler_ir_types.CompilerIrValue]
  [on-false : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (compiler-backend-emit-avx2-blend
    type-segment-bases
    assignments
    dst
    false
    (/ (compiler-backend-avx2-sign-bit-mask-mode backend-state (& mask)) 256)
    mask
    on-true
    on-false
    lanes
    elem-ty
    instr-diag
    backend-state))

;; An AVX2 or SSE2 Select. POLARITY 0 blends bytes on a full-lane mask;
;; otherwise the mask's sign bits pick (swapped when 2). DIRECT? reads MASK
;; as the 64-bit sign-bit source itself instead of a byte mask.
(define (compiler-backend-emit-avx2-blend
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [direct? : bool]
  [polarity : i64]
  [mask : compiler_ir_types.CompilerIrValue]
  [on-true : compiler_ir_types.CompilerIrValue]
  [on-false : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [sse2? : bool
      (be_state.compiler-backend-current-mode-sse2?
        (be_state.compiler-backend-state-function-state backend-state))]
    (if (if sse2?
      (be_operand.compiler-backend-sse2-shape-ok? elem-ty lanes)
      (be_operand.compiler-backend-avx2-shape-ok? elem-ty lanes))
      (match (if direct?
        (be_operand.compiler-backend-vector-register-use
          assignments
          mask
          "sign-bit select src"
          (if sse2?
            "xmm"
            "ymm")
          elem-ty
          (if sse2?
            "%xmm0"
            "%ymm0")
          backend-state)
        (let
          [elem-ty (compiler_ast_types.AstType.I8)]
          (be_operand.compiler-backend-vector-register-use
            assignments
            mask
            "select mask"
            (if sse2?
              "xmm"
              "ymm")
            elem-ty
            (if sse2?
              "%xmm0"
              "%ymm0")
            backend-state)))
        [(Ok mask-use)
          (match mask-use
            [(Use mask-asm mask-reg)
              (match (be_operand.compiler-backend-vector-register-use
                assignments
                on-false
                "select false"
                (if sse2?
                  "xmm"
                  "ymm")
                elem-ty
                (if sse2?
                  "%xmm14"
                  "%ymm14")
                backend-state)
                [(Ok false-use)
                  (match false-use
                    [(Use false-asm false-reg)
                      (match (be_operand.compiler-backend-vector-register-use
                        assignments
                        on-true
                        "select true"
                        (if sse2?
                          "xmm"
                          "ymm")
                        elem-ty
                        (if sse2?
                          "%xmm15"
                          "%ymm15")
                        backend-state)
                        [(Ok true-use)
                          (match true-use
                            [(Use true-asm true-reg)
                              (match (compiler-backend-vector-dst-reg
                                assignments
                                dst
                                "select dst"
                                (if sse2?
                                  "xmm"
                                  "ymm")
                                (if sse2?
                                  "%xmm14"
                                  "%ymm14")
                                backend-state)
                                [(Ok dst-reg)
                                  (let
                                    [blend-asm : String
                                      (if sse2?
                                        (let
                                          [sel-true : String
                                            (if (= polarity 2)
                                              (string.copy (& false-reg))
                                              (string.copy (& true-reg)))]
                                          [sel-false : String
                                            (if (= polarity 2)
                                              (string.copy (& true-reg))
                                              (string.copy (& false-reg)))]
                                          [prep-mask : String
                                            (if (string.eq mask-reg "%xmm0")
                                              ""
                                              (str_cat.str-cat
                                                "    movdqa "
                                                mask-reg
                                                ", %xmm0\n"))]
                                          (cond
                                            [(and
                                                (string.eq mask-reg "%xmm0")
                                                (not
                                                  (string.eq
                                                    dst-reg
                                                    (& sel-false)))
                                                (not
                                                  (string.eq
                                                    dst-reg
                                                    (& sel-true))))
                                              (str_cat.str-cat
                                                "    movdqa %xmm0, "
                                                dst-reg
                                                "\n    pand "
                                                sel-true
                                                ", %xmm0\n    pandn "
                                                sel-false
                                                ", "
                                                dst-reg
                                                "\n    por %xmm0, "
                                                dst-reg
                                                "\n")]
                                            [(string.eq mask-reg "%xmm0")
                                              (str_cat.str-cat
                                                "    movdqa %xmm0, %xmm1\n    pand "
                                                sel-true
                                                ", %xmm0\n    pandn "
                                                sel-false
                                                ", %xmm1\n    por %xmm1, %xmm0\n    movdqa %xmm0, "
                                                dst-reg
                                                "\n")]
                                            [(string.eq dst-reg mask-reg)
                                              (str_cat.str-cat
                                                prep-mask
                                                "    pand "
                                                sel-true
                                                ", %xmm0\n    pandn "
                                                sel-false
                                                ", "
                                                dst-reg
                                                "\n    por %xmm0, "
                                                dst-reg
                                                "\n")]
                                            [(not
                                                (string.eq
                                                  dst-reg
                                                  (& sel-false)))
                                              (str_cat.str-cat
                                                prep-mask
                                                "    pand "
                                                sel-true
                                                ", %xmm0\n    movdqa "
                                                mask-reg
                                                ", "
                                                dst-reg
                                                "\n    pandn "
                                                sel-false
                                                ", "
                                                dst-reg
                                                "\n    por %xmm0, "
                                                dst-reg
                                                "\n")]
                                            [else
                                              (str_cat.str-cat
                                                prep-mask
                                                "    pand "
                                                sel-true
                                                ", %xmm0\n    movdqa "
                                                mask-reg
                                                ", %xmm1\n    pandn "
                                                sel-false
                                                ", %xmm1\n    por %xmm1, %xmm0\n    movdqa %xmm0, "
                                                dst-reg
                                                "\n")]))
                                        (str_cat.str-cat
                                          (if (> polarity 0)
                                            "    vblendvpd "
                                            "    vpblendvb ")
                                          mask-reg
                                          ", "
                                          (if (= polarity 2)
                                            (str_cat.str-cat
                                              false-reg
                                              ", "
                                              true-reg)
                                            (str_cat.str-cat
                                              true-reg
                                              ", "
                                              false-reg))
                                          ", "
                                          dst-reg
                                          "\n"))]
                                    (Ok
                                      (str_cat.str-cat
                                        mask-asm
                                        false-asm
                                        true-asm
                                        blend-asm
                                        (compiler-backend-vector-store-dst
                                          assignments
                                          dst
                                          (if sse2?
                                            "xmm"
                                            "ymm")
                                          elem-ty
                                          dst-reg
                                          backend-state))))]
                                [(Err message)
                                  (be_state.compiler-backend-instr-error
                                    instr-diag
                                    message)])])]
                        [(Err message)
                          (be_state.compiler-backend-instr-error
                            instr-diag
                            message)])])]
                [(Err message)
                  (be_state.compiler-backend-instr-error instr-diag message)])])]
        [(Err message)
          (be_state.compiler-backend-instr-error instr-diag message)])
      (if sse2?
        (be_operand.compiler-backend-sse2-shape-diagnostic
          type-segment-bases
          instr-diag
          elem-ty
          lanes)
        (be_operand.compiler-backend-avx2-shape-diagnostic
          type-segment-bases
          instr-diag
          elem-ty
          lanes)))))

(define (compiler-backend-emit-scalar-select
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [condition : compiler_ir_types.CompilerIrValue]
  [on-true : compiler_ir_types.CompilerIrValue]
  [on-false : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (not (be_operand.compiler-backend-intlike-scalar-type? ty))
    (be_state.compiler-backend-instr-error
      instr-diag
      "backend: unsupported scalar select type")
    (let
      [dst-home : String
        (be_operand.compiler-backend-value-scalar-register-home
          backend-state
          assignments
          (& (Var dst)))]
      [mask-home : String
        (be_operand.compiler-backend-value-scalar-register-home
          backend-state
          assignments
          condition)]
      [true-home : String
        (be_operand.compiler-backend-value-scalar-register-home
          backend-state
          assignments
          on-true)]
      [false-home : String
        (be_operand.compiler-backend-value-scalar-register-home
          backend-state
          assignments
          on-false)]
      ;; x86 conditional moves have no byte form.  Use the full GP home for
      ;; byte and Bool selects; all typed consumers observe the low byte.
      [cmov-ty : compiler_ast_types.AstType
        (if (= (be_operand.compiler-backend-type-size type-segment-bases ty) 1)
          (U64)
          ty)]
      [result-reg : String
        (if (and
          (not (string.eq dst-home ""))
          (not (string.eq dst-home mask-home))
          (not (string.eq dst-home true-home)))
          dst-home
          (be_operand.compiler-backend-scavenge-reg
            dst
            (be_operand.compiler-backend-three-exclude
              (be_state.compiler-backend-global-shared-view mask-home)
              (be_state.compiler-backend-global-shared-view true-home)
              (be_state.compiler-backend-global-shared-view false-home))
            3
            "%rax"
            backend-state))]
      [conditional-address : String
        (be_operand.compiler-backend-value-read-memory-operand
          assignments
          (be_state.compiler-backend-global-shared-view on-true)
          backend-state)]
      [conditional-direct? : bool
        (or
          (not (string.eq true-home ""))
          (not (string.eq conditional-address "")))]
      [conditional-reg : String
        (if conditional-direct?
          (owned_view.compiler-owned-shared-view true-home)
          (be_operand.compiler-backend-scavenge-reg
            dst
            (be_operand.compiler-backend-two-exclude
              (be_state.compiler-backend-global-shared-view result-reg)
              mask-home)
            2
            "%r8"
            backend-state))]
      [conditional-operand : String
        (if (not (string.eq true-home ""))
          (be_operand.compiler-backend-sized-reg
            type-segment-bases
            true-home
            (be_state.compiler-backend-global-shared-view cmov-ty))
          (if (not (string.eq conditional-address ""))
            conditional-address
            (be_operand.compiler-backend-sized-reg
              type-segment-bases
              (be_state.compiler-backend-global-shared-view conditional-reg)
              (be_state.compiler-backend-global-shared-view cmov-ty))))]
      ;; SS-P5(c): the `cmov` is a two-address move whose destination already
      ;; holds the false value whenever the allocator homed the result where
      ;; the false operand lives -- the base copy is then `movq %rX, %rX` and
      ;; is dropped outright rather than left to the load helper.
      [base-asm : String
        (if (and
          (not (string.eq false-home ""))
          (string.eq false-home result-reg))
          ""
          (be_operand.compiler-backend-load-value-asm
            assignments
            on-false
            (be_state.compiler-backend-global-shared-view result-reg)
            backend-state))]
      [conditional-asm : String
        (if conditional-direct?
          ""
          (be_operand.compiler-backend-load-value-asm
            assignments
            on-true
            (be_state.compiler-backend-global-shared-view conditional-reg)
            backend-state))]
      [var-test : String
        (match (& condition)
          [(Var var)
            (be_operand.compiler-backend-branch-test-var-asm
              assignments
              var
              backend-state)]
          [_ ""])]
      [test-reg : String
        (if (not (string.eq var-test ""))
          ""
          (be_operand.compiler-backend-scavenge-reg
            dst
            (be_operand.compiler-backend-two-exclude
              (be_state.compiler-backend-global-shared-view result-reg)
              conditional-reg)
            2
            "%r10"
            backend-state))]
      [test-load : String
        (if (not (string.eq var-test ""))
          ""
          (be_operand.compiler-backend-load-value-asm
            assignments
            condition
            (be_state.compiler-backend-global-shared-view test-reg)
            backend-state))]
      (Ok
        (str_cat.str-cat
          base-asm
          conditional-asm
          test-load
          (if (not (string.eq var-test ""))
            var-test
            (str_cat.str-cat "    testq " test-reg ", " test-reg "\n"))
          "    cmovne "
          conditional-operand
          ", "
          (be_operand.compiler-backend-sized-reg
            type-segment-bases
            (be_state.compiler-backend-global-shared-view result-reg)
            cmov-ty)
          "\n"
          (be_operand.compiler-backend-emit-store-var
            assignments
            dst
            result-reg
            backend-state))))))

;; True when a register a fused select may write is safe: it exists and is
;; neither of the two comparison operand homes whose values the `cmp` still has
;; to read.
(define (compiler-backend-flags-select-reg-ok?
  [reg : (& reg str)]
  [dest-reg : (& dest-reg str)]
  [guard-b : (& guard-b str)]) : bool
  (and
    (not (string.eq reg ""))
    (not (string.eq reg dest-reg))
    (not (string.eq reg guard-b))))

;; The fused select's register choice in its two forms. `peek?` is the PURE
;; twin used by the admission test (a non-committing
;; compiler-backend-scavenge-reg-pick is side-effect-free and returns what the
;; committing call will);
;; the committing form books the emergency save/restore exactly as
;; compiler-backend-scavenge-reg does.
(define (compiler-backend-flags-select-reg
  [peek? : bool]
  [dst : i64]
  [exclude : (__tl_dyn-array String)]
  [exclude-n : i64]
  [fallback : String]
  [backend-state : be_state.CompilerBackendState]) : String
  (be_operand.compiler-backend-scavenge-reg-pick
    dst
    exclude
    exclude-n
    fallback
    (not peek?)
    backend-state))

;; SS-P5(b) / VG-P-B: a scalar Select whose mask is the comparison IMMEDIATELY
;; in front of it and is wanted nowhere else. The mask never becomes a value:
;; the select's operands are staged first, the comparison then sets EFLAGS, and
;; a single `cmov<cc>` reads them --
;;
;;     cmpq %rcx, %rdx ; movq %rcx, %r15 ; cmovb %rdx, %r15
;;
;; where the materialising form spends seven instructions re-deriving the same
;; condition through a register:
;;
;;     movq %rdx, %rax ; cmpq %rcx, %rax ; setb %al ; movzbq %al, %rax ;
;;     movq %rcx, %r15 ; testq %rax, %rax ; cmovne %rdx, %r15
;;
;; CLOBBER SAFETY -- which is the whole of the admission test. Two things must
;; hold.
;;
;; (1) Nothing may write EFLAGS between the `cmp` and the `cmov`. This path
;;     emits NOTHING between them, so it holds structurally; there is no
;;     sequence to reason about.
;;
;; (2) Nothing emitted BEFORE the `cmp` may disturb the comparison's operands.
;;     The only instructions ahead of the `cmp` are the two operand stages, and
;;     the only registers they write are `result-reg` and (when the true
;;     operand needs staging at all) `conditional-reg`. Memory operands and
;;     immediates write nothing. So it suffices that neither register is a
;;     comparison operand home, and that is enforced twice over: both homes go
;;     into the scavenge exclusion set, AND the register that comes back is
;;     re-checked against them -- necessary because a PLANNED scratch ignores
;;     the exclusion set, and the allocator may legitimately hand out a
;;     comparison operand's register when that operand dies at the comparison.
;;
;; Both comparison operands must additionally be register-homed or immediates,
;; so the comparison stages nothing of its own and really is one instruction.
;; `result-reg` must also differ from the true operand's home, because the
;; false value is written into it before the `cmov` reads the true one; and the
;; two staging registers must differ from each other.
;;
;; Every failure returns `No` and the caller emits the ordinary materialising
;; form, so nothing is lost when the shape does not fit. The peeked (pure)
;; register queries mean a decline never leaves a booked emergency save behind.
(define (compiler-backend-emit-select-on-flags
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [on-true : compiler_ir_types.CompilerIrValue]
  [on-false : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [op : compiler_ir_types.CompilerIrBinOp]
  [cmp-lhs : compiler_ir_types.CompilerIrValue]
  [cmp-rhs : compiler_ir_types.CompilerIrValue]
  [cmp-ty : compiler_ast_types.AstType]
  [backend-state : be_state.CompilerBackendState]) : be_state.CompilerBackendMaybeAsm
  (if (not (be_operand.compiler-backend-intlike-scalar-type? ty))
    (No)
    (let
      [lhs-home : String
        (be_operand.compiler-backend-value-scalar-register-home
          backend-state
          assignments
          cmp-lhs)]
      [rhs-home : String
        (be_operand.compiler-backend-value-scalar-register-home
          backend-state
          assignments
          cmp-rhs)]
      [lhs-immediate : String
        (match (be_operand.compiler-backend-immediate-operand
          backend-state
          cmp-lhs)
          [(Some text) text]
          [(No) ""])]
      [rhs-immediate : String
        (match (be_operand.compiler-backend-immediate-operand
          backend-state
          cmp-rhs)
          [(Some text) text]
          [(No) ""])]
      ;; x86 spells the immediate as the SOURCE of `cmp`, so an immediate on
      ;; the IR's left is taken by reversing the predicate against the register
      ;; right -- the same exchange the compare/branch lowering performs.
      [swap? : bool
        (and
          (string.eq lhs-home "")
          (not (string.eq lhs-immediate ""))
          (not (string.eq rhs-home "")))]
      [cmov : String
        (be_operand.compiler-backend-compare-cmov
          type-segment-bases
          (if swap?
            (be_operand.compiler-backend-compare-swapped-op op)
            op)
          (be_state.compiler-backend-global-shared-view cmp-ty))]
      [dest-reg : String
        (if swap?
          (owned_view.compiler-owned-shared-view rhs-home)
          lhs-home)]
      [source-operand : String
        (if swap?
          lhs-immediate
          (if (not (string.eq rhs-home ""))
            (be_operand.compiler-backend-sized-reg
              type-segment-bases
              (be_state.compiler-backend-global-shared-view rhs-home)
              (be_state.compiler-backend-global-shared-view cmp-ty))
            rhs-immediate))]
      ;; The comparison's live operand homes are `dest-reg` (always a register)
      ;; and, when the source is not an immediate, the source register. A copy
      ;; is taken because the binding would otherwise move the home out of the
      ;; operand spellings above.
      [guard-b : String
        (if swap?
          ""
          (string.copy rhs-home))]
      [dst-home : String
        (be_operand.compiler-backend-value-scalar-register-home
          backend-state
          assignments
          (& (Var dst)))]
      [true-home : String
        (be_operand.compiler-backend-value-scalar-register-home
          backend-state
          assignments
          on-true)]
      [false-home : String
        (be_operand.compiler-backend-value-scalar-register-home
          backend-state
          assignments
          on-false)]
      ;; x86 conditional moves have no byte form. Use the full GP home for byte
      ;; and Bool selects; all typed consumers observe the low byte.
      [cmov-ty : compiler_ast_types.AstType
        (if (= (be_operand.compiler-backend-type-size type-segment-bases ty) 1)
          (U64)
          ty)]
      ;; The mask is gone, so the result may take its own home even where the
      ;; materialising form had to step around the mask's register. Taking
      ;; dst-home is also what makes SS-P5(c) reachable: when the allocator
      ;; homed the result where the false operand lives, the base copy is gone.
      ;;
      ;; That last case is also the one exception to the "not a comparison
      ;; operand home" rule, and it is not really an exception: when the result
      ;; register IS the false operand's home the base copy is elided, so
      ;; NOTHING is written ahead of the `cmp` and there is no clobber to
      ;; avoid. `min(a, b)` reaches this on every call -- the false arm and the
      ;; comparison's right operand are the same value.
      [use-dst-home? : bool
        (and
          (not (string.eq dst-home ""))
          (not (string.eq dst-home true-home))
          (or
            (and
              (not (string.eq false-home ""))
              (string.eq dst-home false-home))
            (and
              (not (string.eq dst-home dest-reg))
              (not (string.eq dst-home guard-b)))))]
      [result-exclude : (__tl_dyn-array String)
        (be_operand.compiler-backend-four-exclude
          (be_state.compiler-backend-global-shared-view true-home)
          (be_state.compiler-backend-global-shared-view false-home)
          (be_state.compiler-backend-global-shared-view dest-reg)
          (be_state.compiler-backend-global-shared-view guard-b))]
      [result-peek : String
        (if use-dst-home?
          (owned_view.compiler-owned-shared-view dst-home)
          (compiler-backend-flags-select-reg
            true
            dst
            (be_state.compiler-backend-global-shared-view result-exclude)
            4
            "%rax"
            backend-state))]
      [conditional-address : String
        (be_operand.compiler-backend-value-read-memory-operand
          assignments
          (be_state.compiler-backend-global-shared-view on-true)
          backend-state)]
      [conditional-direct? : bool
        (or
          (not (string.eq true-home ""))
          (not (string.eq conditional-address "")))]
      [conditional-exclude : (__tl_dyn-array String)
        (be_operand.compiler-backend-four-exclude
          (be_state.compiler-backend-global-shared-view result-peek)
          (be_state.compiler-backend-global-shared-view false-home)
          (be_state.compiler-backend-global-shared-view dest-reg)
          (be_state.compiler-backend-global-shared-view guard-b))]
      [conditional-peek : String
        (if conditional-direct?
          ""
          (compiler-backend-flags-select-reg
            true
            dst
            (be_state.compiler-backend-global-shared-view conditional-exclude)
            4
            "%r8"
            backend-state))]
      [admissible? : bool
        (and
          (not (string.eq cmov ""))
          (not (string.eq dest-reg ""))
          (not (string.eq source-operand ""))
          (or
            (and
              (not (string.eq result-peek ""))
              (not (string.eq false-home ""))
              (string.eq result-peek false-home))
            (compiler-backend-flags-select-reg-ok? result-peek dest-reg guard-b))
          (or
            conditional-direct?
            (and
              (compiler-backend-flags-select-reg-ok?
                conditional-peek
                dest-reg
                guard-b)
              (not (string.eq conditional-peek result-peek)))))]
      (if (not admissible?)
        (No)
        (let
          [result-reg : String
            (if use-dst-home?
              dst-home
              (compiler-backend-flags-select-reg
                false
                dst
                result-exclude
                4
                "%rax"
                backend-state))]
          [conditional-reg : String
            (if conditional-direct?
              ""
              (compiler-backend-flags-select-reg
                false
                dst
                conditional-exclude
                4
                "%r8"
                backend-state))]
          ;; The two register queries above are the committing twins of the
          ;; peeks the admission test read, so they must answer the same. The
          ;; only thing that runs between the peeks and the commits is the
          ;; result commit itself, and the emergency booking it may perform
          ;; touches the save SET, not the occupancy the pick reads. Assert it
          ;; rather than assume it: a divergence would mean the emission was
          ;; admitted on registers it did not get, which is precisely the
          ;; clobber this path exists to avoid, and it must never be silent.
          [_twin-check : unit
            (if (and
              (string.eq result-reg result-peek)
              (string.eq conditional-reg conditional-peek))
              unit
              (io.panic
                "backend: select-on-flags register peek/commit divergence"))]
          [conditional-operand : String
            (if (not (string.eq true-home ""))
              (be_operand.compiler-backend-sized-reg
                type-segment-bases
                true-home
                (be_state.compiler-backend-global-shared-view cmov-ty))
              (if (not (string.eq conditional-address ""))
                conditional-address
                (be_operand.compiler-backend-sized-reg
                  type-segment-bases
                  (be_state.compiler-backend-global-shared-view conditional-reg)
                  (be_state.compiler-backend-global-shared-view cmov-ty))))]
          ;; SS-P5(c).
          [base-asm : String
            (if (and
              (not (string.eq false-home ""))
              (string.eq false-home result-reg))
              ""
              (be_operand.compiler-backend-load-value-asm
                assignments
                on-false
                (be_state.compiler-backend-global-shared-view result-reg)
                backend-state))]
          [conditional-asm : String
            (if conditional-direct?
              ""
              (be_operand.compiler-backend-load-value-asm
                assignments
                on-true
                conditional-reg
                backend-state))]
          (Some
            (str_cat.str-cat
              base-asm
              conditional-asm
              (be_operand.compiler-backend-binop-cmp-reg-asm
                type-segment-bases
                (be_state.compiler-backend-global-shared-view cmp-ty)
                source-operand
                (be_operand.compiler-backend-sized-reg
                  type-segment-bases
                  dest-reg
                  cmp-ty))
              "    "
              cmov
              " "
              conditional-operand
              ", "
              (be_operand.compiler-backend-sized-reg
                type-segment-bases
                (be_state.compiler-backend-global-shared-view result-reg)
                cmov-ty)
              "\n"
              (be_operand.compiler-backend-emit-store-var
                assignments
                dst
                result-reg
                backend-state))))))))

(define (compiler-backend-emit-select
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [mask : compiler_ir_types.CompilerIrValue]
  [on-true : compiler_ir_types.CompilerIrValue]
  [on-false : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (= lanes 0)
    (compiler-backend-emit-scalar-select
      type-segment-bases
      assignments
      dst
      mask
      on-true
      on-false
      elem-ty
      instr-diag
      backend-state)
    (if (or
      (be_state.compiler-backend-current-mode-avx2?
        (be_state.compiler-backend-state-function-state backend-state))
      (be_state.compiler-backend-current-mode-sse2?
        (be_state.compiler-backend-state-function-state backend-state)))
      (compiler-backend-emit-avx2-select
        type-segment-bases
        assignments
        dst
        mask
        on-true
        on-false
        lanes
        elem-ty
        instr-diag
        backend-state)
      (compiler-backend-emit-avx512-select
        type-segment-bases
        assignments
        dst
        mask
        on-true
        on-false
        lanes
        elem-ty
        instr-diag
        backend-state))))

(define (compiler-backend-avx2-mask-label
  [function : String]
  [current-label : i64]
  [dst : i64]
  [suffix : String]) : String
  (be_operand.compiler-backend-asm-label
    function
    (compiler_ir_types.compiler-ir-label
      (&
        (str_cat.str-cat
          "avx2_mask_"
          (compiler_ir_types.compiler-ir-label-text current-label)
          "_v"
          (string.int->string dst)
          suffix)))))

(define (compiler-backend-address-add-byte-offset [addr : String] [disp : i64]) : String
  (if (= disp 0)
    addr
    (let
      [disp-text : String (string.int->string disp)]
      (if (and
        (> (string.string-length addr) 0)
        (= (string.string-ref addr 0) '('))
        (str_cat.str-cat disp-text addr)
        (str_cat.str-cat disp-text "+" addr)))))

(define (compiler-backend-avx2-scalar-move-mnemonic
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]) : String
  (match elem-ty
    [(or (I64) (U64) (F64)) "movq"]
    [(or (I32) (U32) (F32)) "movl"]
    [(or (I16) (U16)) "movw"]
    [(or (I8) (U8) (Bool)) "movb"]
    [_ ""]))

(define (compiler-backend-avx2-scalar-temp-reg
  [tmp-reg : (& str)]
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]) : String
  (match elem-ty
    [(or (I64) (U64) (F64)) (string.copy tmp-reg)]
    [(or (I32) (U32) (F32))
      (be_operand.compiler-backend-reg-part (string.copy tmp-reg) 4)]
    [(or (I16) (U16))
      (be_operand.compiler-backend-reg-part (string.copy tmp-reg) 2)]
    [(or (I8) (U8) (Bool))
      (be_operand.compiler-backend-reg-part (string.copy tmp-reg) 1)]
    [_ ""]))

(define (compiler-backend-avx2-lane-fill-mnemonic [lane-bytes : i64]) : String
  (cond
    [(= lane-bytes 8) "movq"]
    [(= lane-bytes 4) "movl"]
    [(= lane-bytes 2) "movw"]
    [(= lane-bytes 1) "movb"]
    [else ""]))

(define (compiler-backend-avx2-lane-stack-address
  [backend-state : be_state.CompilerBackendState]
  [lane : i64]
  [lane-bytes : i64]) : String
  (be_operand.compiler-backend-simd-scratch-address
    backend-state
    (* lane lane-bytes)))

(define (compiler-backend-avx2-lane-memory-address
  [addr : String]
  [lane : i64]
  [lane-bytes : i64]) : String
  (compiler-backend-address-add-byte-offset addr (* lane lane-bytes)))

(define (compiler-backend-avx2-mask-test-bit [lane : i64] [lane-bytes : i64]) : i64
  (shl 1 (* lane lane-bytes)))

(define (compiler-backend-avx2-predicated-load-lanes
  [function : String]
  [current-label : i64]
  [dst : i64]
  [addr : String]
  [mask-reg32 : (& str)]
  [tmp-reg : (& str)]
  [lane : i64]
  [lanes : i64]
  [lane-bytes : i64]
  [elem-ty : compiler_ast_types.AstType]
  [acc : String]
  [backend-state : be_state.CompilerBackendState]) : String
  (if (>= lane lanes)
    acc
    (let
      [bit : i64 (compiler-backend-avx2-mask-test-bit lane lane-bytes)]
      [skip-label : String
        (compiler-backend-avx2-mask-label
          (be_state.compiler-backend-global-shared-view function)
          current-label
          dst
          (str_cat.str-cat "_load_skip_" (string.int->string lane)))]
      [move : String (compiler-backend-avx2-scalar-move-mnemonic elem-ty)]
      [tmp : String (compiler-backend-avx2-scalar-temp-reg tmp-reg (& elem-ty))]
      [mem : String
        (compiler-backend-avx2-lane-memory-address
          (be_state.compiler-backend-global-shared-view addr)
          lane
          (if (match (& elem-ty)
            [(Bool) true]
            [_ false])
            1
            lane-bytes))]
      [slot : String
        (compiler-backend-avx2-lane-stack-address backend-state lane lane-bytes)]
      [lane-asm : String
        (if (match (& elem-ty)
          [(Bool) true]
          [_ false])
          (str_cat.str-cat
            "    testl $"
            (string.int->string bit)
            ", "
            mask-reg32
            "\n    je "
            skip-label
            "\n    cmpb $0, "
            mem
            "\n    je "
            skip-label
            "\n    "
            (compiler-backend-avx2-lane-fill-mnemonic lane-bytes)
            " $-1, "
            slot
            "\n"
            skip-label
            ":\n")
          (str_cat.str-cat
            "    testl $"
            (string.int->string bit)
            ", "
            mask-reg32
            "\n    je "
            skip-label
            "\n    "
            move
            " "
            mem
            ", "
            tmp
            "\n    "
            move
            " "
            tmp
            ", "
            slot
            "\n"
            skip-label
            ":\n"))]
      (compiler-backend-avx2-predicated-load-lanes
        function
        current-label
        dst
        addr
        mask-reg32
        tmp-reg
        (+ lane 1)
        lanes
        lane-bytes
        elem-ty
        (str_cat.str-cat acc lane-asm)
        backend-state))))

(define (compiler-backend-avx2-predicated-store-lanes
  [function : String]
  [current-label : i64]
  [dst-tag : i64]
  [addr : String]
  [mask-reg32 : (& str)]
  [tmp-reg : (& str)]
  [lane : i64]
  [lanes : i64]
  [lane-bytes : i64]
  [elem-ty : compiler_ast_types.AstType]
  [acc : String]
  [backend-state : be_state.CompilerBackendState]) : String
  (if (>= lane lanes)
    acc
    (let
      [bit : i64 (compiler-backend-avx2-mask-test-bit lane lane-bytes)]
      [skip-label : String
        (compiler-backend-avx2-mask-label
          (be_state.compiler-backend-global-shared-view function)
          current-label
          dst-tag
          (str_cat.str-cat "_store_skip_" (string.int->string lane)))]
      [move : String (compiler-backend-avx2-scalar-move-mnemonic elem-ty)]
      [tmp : String (compiler-backend-avx2-scalar-temp-reg tmp-reg (& elem-ty))]
      [mem : String
        (compiler-backend-avx2-lane-memory-address
          (be_state.compiler-backend-global-shared-view addr)
          lane
          lane-bytes)]
      [slot : String
        (compiler-backend-avx2-lane-stack-address backend-state lane lane-bytes)]
      [lane-asm : String
        (str_cat.str-cat
          "    testl $"
          (string.int->string bit)
          ", "
          mask-reg32
          "\n    je "
          skip-label
          "\n    "
          move
          " "
          slot
          ", "
          tmp
          "\n    "
          move
          " "
          tmp
          ", "
          mem
          "\n"
          skip-label
          ":\n")]
      (compiler-backend-avx2-predicated-store-lanes
        function
        current-label
        dst-tag
        addr
        mask-reg32
        tmp-reg
        (+ lane 1)
        lanes
        lane-bytes
        elem-ty
        (str_cat.str-cat acc lane-asm)
        backend-state))))

(define (compiler-backend-avx2-predicated-bool-store-lanes
  [function : String]
  [current-label : i64]
  [dst-tag : i64]
  [addr : String]
  [mask-reg32 : (& str)]
  [val-reg32 : (& str)]
  [bool-reg8 : (& str)]
  [lane : i64]
  [lanes : i64]
  [lane-bytes : i64]
  [acc : String]) : String
  (if (>= lane lanes)
    acc
    (let
      [bit : i64 (compiler-backend-avx2-mask-test-bit lane lane-bytes)]
      [skip-label : String
        (compiler-backend-avx2-mask-label
          (be_state.compiler-backend-global-shared-view function)
          current-label
          dst-tag
          (str_cat.str-cat "_bool_store_skip_" (string.int->string lane)))]
      [mem : String
        (compiler-backend-avx2-lane-memory-address
          (be_state.compiler-backend-global-shared-view addr)
          lane
          1)]
      [lane-asm : String
        (str_cat.str-cat
          "    testl $"
          (string.int->string bit)
          ", "
          mask-reg32
          "\n    je "
          skip-label
          "\n    movb $0, "
          bool-reg8
          "\n    testl $"
          (string.int->string bit)
          ", "
          val-reg32
          "\n    setne "
          bool-reg8
          "\n    movb "
          bool-reg8
          ", "
          mem
          "\n"
          skip-label
          ":\n")]
      (compiler-backend-avx2-predicated-bool-store-lanes
        function
        current-label
        dst-tag
        addr
        mask-reg32
        val-reg32
        bool-reg8
        (+ lane 1)
        lanes
        lane-bytes
        (str_cat.str-cat acc lane-asm)))))

(define (compiler-backend-emit-avx2-predicated-load
  [type-segment-bases : i64]
  [function : String]
  [current-label : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [base : compiler_ir_types.CompilerIrValue]
  [index : compiler_ir_types.CompilerIrValue]
  [mask : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [sse2? : bool
      (be_state.compiler-backend-current-mode-sse2?
        (be_state.compiler-backend-state-function-state backend-state))]
    (if (if (match (& elem-ty)
      [(Bool) true]
      [_ false])
      (if sse2?
        (be_operand.compiler-backend-sse2-mask-shape-ok? lanes)
        (be_operand.compiler-backend-avx2-mask-shape-ok? lanes))
      (if sse2?
        (be_operand.compiler-backend-sse2-shape-ok? elem-ty lanes)
        (be_operand.compiler-backend-avx2-shape-ok? elem-ty lanes)))
      (match (let
        [elem-ty (compiler_ast_types.AstType.I8)]
        (be_operand.compiler-backend-vector-register-use
          assignments
          mask
          "load mask"
          (if sse2?
            "xmm"
            "ymm")
          elem-ty
          (if sse2?
            "%xmm15"
            "%ymm15")
          backend-state))
        [(Ok mask-use)
          (match mask-use
            [(Use mask-asm mask-reg)
              (match (compiler-backend-vector-dst-reg
                assignments
                dst
                "predicated load dst"
                (if sse2?
                  "xmm"
                  "ymm")
                (if sse2?
                  "%xmm14"
                  "%ymm14")
                backend-state)
                [(Ok dst-reg)
                  (match (compiler-backend-emit-simd-indexed-address
                    type-segment-bases
                    assignments
                    base
                    index
                    (be_state.compiler-backend-global-shared-view elem-ty)
                    backend-state)
                    [(Ok addr-plan)
                      (let
                        [addr-asm : String addr-plan.asm]
                        [addr : String addr-plan.addr]
                        [masked-move : String
                          (if sse2?
                            ""
                            (be_operand.compiler-backend-avx2-masked-move-mnemonic
                              elem-ty))]
                        (if (string.eq masked-move "")
                          (let
                            [mask-gp : String
                              (be_operand.compiler-backend-scavenge-reg-here
                                (compiler-backend-simd-addr-exclude
                                  (& addr)
                                  ""
                                  ""
                                  "")
                                5
                                "%r11"
                                backend-state)]
                            [tmp-gp : String
                              (be_operand.compiler-backend-scavenge-reg-here
                                (compiler-backend-simd-addr-exclude
                                  (& addr)
                                  (& mask-gp)
                                  ""
                                  "")
                                5
                                "%r10"
                                backend-state)]
                            [mask-gp32 : String
                              (be_operand.compiler-backend-reg-part
                                (string.copy (& mask-gp))
                                4)]
                            [lane-bytes : i64
                              (if sse2?
                                (if (> lanes 0)
                                  (/ 16 lanes)
                                  0)
                                (compiler-backend-avx2-lane-bytes lanes))]
                            [lanes-asm : String
                              (compiler-backend-avx2-predicated-load-lanes
                                function
                                current-label
                                dst
                                addr
                                (& mask-gp32)
                                (& tmp-gp)
                                0
                                lanes
                                lane-bytes
                                elem-ty
                                ""
                                backend-state)]
                            (be_operand.compiler-backend-simd-scratch-checked
                              backend-state
                              instr-diag
                              (if sse2?
                                16
                                be_operand.compiler-backend-simd-scratch-lane-staging-bytes)
                              (Ok
                                (str_cat.str-cat
                                  mask-asm
                                  addr-asm
                                  (if sse2?
                                    "    pxor %xmm0, %xmm0\n    movdqu %xmm0, "
                                    "    vpxor %ymm0, %ymm0, %ymm0\n    vmovdqu %ymm0, ")
                                  (be_operand.compiler-backend-simd-scratch-address
                                    backend-state
                                    0)
                                  (if sse2?
                                    "\n    pmovmskb "
                                    "\n    vpmovmskb ")
                                  mask-reg
                                  ", "
                                  mask-gp32
                                  "\n"
                                  lanes-asm
                                  (if sse2?
                                    "    movdqu "
                                    "    vmovdqu ")
                                  (be_operand.compiler-backend-simd-scratch-address
                                    backend-state
                                    0)
                                  ", "
                                  dst-reg
                                  "\n"
                                  (compiler-backend-vector-store-dst
                                    assignments
                                    dst
                                    (if sse2?
                                      "xmm"
                                      "ymm")
                                    (I8)
                                    dst-reg
                                    backend-state)))))
                          (Ok
                            (str_cat.str-cat
                              mask-asm
                              addr-asm
                              "    "
                              masked-move
                              " "
                              addr
                              ", "
                              mask-reg
                              ", "
                              dst-reg
                              "\n"
                              (compiler-backend-vector-store-dst
                                assignments
                                dst
                                "ymm"
                                elem-ty
                                dst-reg
                                backend-state)))))]
                    [(Err message)
                      (be_state.compiler-backend-instr-error-from
                        instr-diag
                        message)])]
                [(Err message)
                  (be_state.compiler-backend-instr-error instr-diag message)])])]
        [(Err message)
          (be_state.compiler-backend-instr-error instr-diag message)])
      (if sse2?
        (be_operand.compiler-backend-sse2-shape-diagnostic
          type-segment-bases
          instr-diag
          elem-ty
          lanes)
        (be_operand.compiler-backend-avx2-shape-diagnostic
          type-segment-bases
          instr-diag
          elem-ty
          lanes)))))

(define (compiler-backend-emit-avx2-predicated-store
  [type-segment-bases : i64]
  [function : String]
  [current-label : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [base : compiler_ir_types.CompilerIrValue]
  [index : compiler_ir_types.CompilerIrValue]
  [value : compiler_ir_types.CompilerIrValue]
  [mask : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [sse2? : bool
      (be_state.compiler-backend-current-mode-sse2?
        (be_state.compiler-backend-state-function-state backend-state))]
    (if (if (match (& elem-ty)
      [(Bool) true]
      [_ false])
      (if sse2?
        (be_operand.compiler-backend-sse2-mask-shape-ok? lanes)
        (be_operand.compiler-backend-avx2-mask-shape-ok? lanes))
      (if sse2?
        (be_operand.compiler-backend-sse2-shape-ok? elem-ty lanes)
        (be_operand.compiler-backend-avx2-shape-ok? elem-ty lanes)))
      (match (let
        [elem-ty (compiler_ast_types.AstType.I8)]
        (be_operand.compiler-backend-vector-register-use
          assignments
          mask
          "store mask"
          (if sse2?
            "xmm"
            "ymm")
          elem-ty
          (if sse2?
            "%xmm15"
            "%ymm15")
          backend-state))
        [(Ok mask-use)
          (match mask-use
            [(Use mask-asm mask-reg)
              (match (compiler-backend-emit-simd-indexed-address
                type-segment-bases
                assignments
                base
                index
                (be_state.compiler-backend-global-shared-view elem-ty)
                backend-state)
                [(Ok addr-plan)
                  (let
                    [addr-asm : String addr-plan.asm]
                    [addr : String addr-plan.addr]
                    [lane-bytes : i64
                      (if sse2?
                        (if (> lanes 0)
                          (/ 16 lanes)
                          0)
                        (compiler-backend-avx2-lane-bytes lanes))]
                    [pmov : String
                      (if sse2?
                        "    pmovmskb "
                        "    vpmovmskb ")]
                    [bool-store? : bool
                      (match (& elem-ty)
                        [(Bool) true]
                        [_ false])]
                    (if bool-store?
                      (match (let
                        [elem-ty (compiler_ast_types.AstType.I8)]
                        (be_operand.compiler-backend-vector-register-use
                          assignments
                          value
                          "bool store value"
                          (if sse2?
                            "xmm"
                            "ymm")
                          elem-ty
                          (if sse2?
                            "%xmm14"
                            "%ymm14")
                          backend-state))
                        [(Ok value-use)
                          (match value-use
                            [(Use value-asm value-reg)
                              (let
                                [mask-gp : String
                                  (be_operand.compiler-backend-scavenge-reg-here
                                    (compiler-backend-simd-addr-exclude
                                      (& addr)
                                      ""
                                      ""
                                      "")
                                    5
                                    "%r11"
                                    backend-state)]
                                [val-gp : String
                                  (be_operand.compiler-backend-scavenge-reg-here
                                    (compiler-backend-simd-addr-exclude
                                      (& addr)
                                      (& mask-gp)
                                      ""
                                      "")
                                    5
                                    "%r10"
                                    backend-state)]
                                [bool-gp : String
                                  (be_operand.compiler-backend-scavenge-reg-here
                                    (compiler-backend-simd-addr-exclude
                                      (& addr)
                                      (& mask-gp)
                                      (& val-gp)
                                      "")
                                    5
                                    "%rax"
                                    backend-state)]
                                [mask-gp32 : String
                                  (be_operand.compiler-backend-reg-part
                                    (string.copy (& mask-gp))
                                    4)]
                                [val-gp32 : String
                                  (be_operand.compiler-backend-reg-part
                                    (string.copy (& val-gp))
                                    4)]
                                [bool-gp8 : String
                                  (be_operand.compiler-backend-reg-part
                                    (string.copy (& bool-gp))
                                    1)]
                                (Ok
                                  (str_cat.str-cat
                                    value-asm
                                    mask-asm
                                    addr-asm
                                    pmov
                                    mask-reg
                                    ", "
                                    mask-gp32
                                    "\n"
                                    pmov
                                    value-reg
                                    ", "
                                    val-gp32
                                    "\n"
                                    (compiler-backend-avx2-predicated-bool-store-lanes
                                      function
                                      current-label
                                      (/
                                        (be_state.compiler-backend-function-state-emission-point
                                          (be_state.compiler-backend-state-function-state
                                            backend-state))
                                        2)
                                      addr
                                      (& mask-gp32)
                                      (& val-gp32)
                                      (& bool-gp8)
                                      0
                                      lanes
                                      lane-bytes
                                      ""))))])]
                        [(Err message)
                          (be_state.compiler-backend-instr-error
                            instr-diag
                            message)])
                      (match (be_operand.compiler-backend-vector-register-use
                        assignments
                        value
                        "store value"
                        (if sse2?
                          "xmm"
                          "ymm")
                        elem-ty
                        (if sse2?
                          "%xmm14"
                          "%ymm14")
                        backend-state)
                        [(Ok value-use)
                          (match value-use
                            [(Use value-asm value-reg)
                              (let
                                [masked-move : String
                                  (if sse2?
                                    ""
                                    (be_operand.compiler-backend-avx2-masked-move-mnemonic
                                      elem-ty))]
                                (if (string.eq masked-move "")
                                  (let
                                    [mask-gp : String
                                      (be_operand.compiler-backend-scavenge-reg-here
                                        (compiler-backend-simd-addr-exclude
                                          (& addr)
                                          ""
                                          ""
                                          "")
                                        5
                                        "%r11"
                                        backend-state)]
                                    [tmp-gp : String
                                      (be_operand.compiler-backend-scavenge-reg-here
                                        (compiler-backend-simd-addr-exclude
                                          (& addr)
                                          (& mask-gp)
                                          ""
                                          "")
                                        5
                                        "%r10"
                                        backend-state)]
                                    [mask-gp32 : String
                                      (be_operand.compiler-backend-reg-part
                                        (string.copy (& mask-gp))
                                        4)]
                                    (be_operand.compiler-backend-simd-scratch-checked
                                      backend-state
                                      instr-diag
                                      (if sse2?
                                        16
                                        be_operand.compiler-backend-simd-scratch-lane-staging-bytes)
                                      (Ok
                                        (str_cat.str-cat
                                          value-asm
                                          mask-asm
                                          addr-asm
                                          (if sse2?
                                            "    movdqu "
                                            "    vmovdqu ")
                                          value-reg
                                          ", "
                                          (be_operand.compiler-backend-simd-scratch-address
                                            backend-state
                                            0)
                                          "\n"
                                          pmov
                                          mask-reg
                                          ", "
                                          mask-gp32
                                          "\n"
                                          (compiler-backend-avx2-predicated-store-lanes
                                            function
                                            current-label
                                            (/
                                              (be_state.compiler-backend-function-state-emission-point
                                                (be_state.compiler-backend-state-function-state
                                                  backend-state))
                                              2)
                                            addr
                                            (& mask-gp32)
                                            (& tmp-gp)
                                            0
                                            lanes
                                            lane-bytes
                                            elem-ty
                                            ""
                                            backend-state)))))
                                  (Ok
                                    (str_cat.str-cat
                                      value-asm
                                      mask-asm
                                      addr-asm
                                      "    "
                                      masked-move
                                      " "
                                      value-reg
                                      ", "
                                      mask-reg
                                      ", "
                                      addr
                                      "\n"))))])]
                        [(Err message)
                          (be_state.compiler-backend-instr-error
                            instr-diag
                            message)])))]
                [(Err message)
                  (be_state.compiler-backend-instr-error-from
                    instr-diag
                    message)])])]
        [(Err message)
          (be_state.compiler-backend-instr-error instr-diag message)])
      (if sse2?
        (be_operand.compiler-backend-sse2-shape-diagnostic
          type-segment-bases
          instr-diag
          elem-ty
          lanes)
        (be_operand.compiler-backend-avx2-shape-diagnostic
          type-segment-bases
          instr-diag
          elem-ty
          lanes)))))

(define (compiler-backend-emit-predicated-load
  [type-segment-bases : i64]
  [function : String]
  [current-label : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [base : compiler_ir_types.CompilerIrValue]
  [index : compiler_ir_types.CompilerIrValue]
  [mask : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (or
    (be_state.compiler-backend-current-mode-avx2?
      (be_state.compiler-backend-state-function-state backend-state))
    (be_state.compiler-backend-current-mode-sse2?
      (be_state.compiler-backend-state-function-state backend-state)))
    (compiler-backend-emit-avx2-predicated-load
      type-segment-bases
      function
      current-label
      assignments
      dst
      base
      index
      mask
      lanes
      elem-ty
      instr-diag
      backend-state)
    (compiler-backend-emit-avx512-predicated-load
      type-segment-bases
      assignments
      dst
      base
      index
      mask
      lanes
      elem-ty
      instr-diag
      backend-state)))

(define (compiler-backend-emit-predicated-store
  [type-segment-bases : i64]
  [function : String]
  [current-label : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [base : compiler_ir_types.CompilerIrValue]
  [index : compiler_ir_types.CompilerIrValue]
  [value : compiler_ir_types.CompilerIrValue]
  [mask : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (or
    (be_state.compiler-backend-current-mode-avx2?
      (be_state.compiler-backend-state-function-state backend-state))
    (be_state.compiler-backend-current-mode-sse2?
      (be_state.compiler-backend-state-function-state backend-state)))
    (compiler-backend-emit-avx2-predicated-store
      type-segment-bases
      function
      current-label
      assignments
      base
      index
      value
      mask
      lanes
      elem-ty
      instr-diag
      backend-state)
    (compiler-backend-emit-avx512-predicated-store
      type-segment-bases
      assignments
      base
      index
      value
      mask
      lanes
      elem-ty
      instr-diag
      backend-state)))

(define (compiler-backend-avx2-tail-mask-fill-lanes
  [function : String]
  [current-label : i64]
  [dst : i64]
  [index-reg : (& str)]
  [end-reg : (& str)]
  [lane-reg : (& str)]
  [lane : i64]
  [lanes : i64]
  [lane-bytes : i64]
  [acc : String]
  [backend-state : be_state.CompilerBackendState]) : String
  (if (>= lane lanes)
    acc
    (let
      [skip-label : String
        (compiler-backend-avx2-mask-label
          (be_state.compiler-backend-global-shared-view function)
          current-label
          dst
          (str_cat.str-cat "_tail_skip_" (string.int->string lane)))]
      [move : String
        (cond
          [(= lane-bytes 8) "movq"]
          [(= lane-bytes 4) "movl"]
          [(= lane-bytes 2) "movw"]
          [else "movb"])]
      [slot : String
        (compiler-backend-avx2-lane-stack-address backend-state lane lane-bytes)]
      [lane-asm : String
        (str_cat.str-cat
          "    leaq "
          (string.int->string lane)
          "("
          index-reg
          "), "
          lane-reg
          "\n    cmpq "
          end-reg
          ", "
          lane-reg
          "\n    jge "
          skip-label
          "\n    "
          move
          " $-1, "
          slot
          "\n"
          skip-label
          ":\n")]
      (compiler-backend-avx2-tail-mask-fill-lanes
        function
        current-label
        dst
        index-reg
        end-reg
        lane-reg
        (+ lane 1)
        lanes
        lane-bytes
        (str_cat.str-cat acc lane-asm)
        backend-state))))

(define (compiler-backend-avx2-qword-tail-mask-asm
  [index-reg : (& str)]
  [end-reg : (& str)]
  [dst-reg : (& dst-reg str)]) : String
  (str_cat.str-cat
    "    vmovq "
    index-reg
    ", %xmm0\n    vpbroadcastq %xmm0, %ymm0\n    vpaddq "
    (be_facts.compiler-backend-avx2-i64-lane-id-label)
    "(%rip), %ymm0, %ymm0\n    vmovq "
    end-reg
    ", %xmm1\n    vpbroadcastq %xmm1, %ymm1\n    vpcmpgtq %ymm0, %ymm1, "
    dst-reg
    "\n"))

(define (compiler-backend-emit-avx2-tail-mask
  [type-segment-bases : i64]
  [function : String]
  [current-label : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [index : compiler_ir_types.CompilerIrValue]
  [end-value : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [sse2? : bool
      (be_state.compiler-backend-current-mode-sse2?
        (be_state.compiler-backend-state-function-state backend-state))]
    (if (not
      (if sse2?
        (be_operand.compiler-backend-sse2-mask-shape-ok? lanes)
        (be_operand.compiler-backend-avx2-mask-shape-ok? lanes)))
      (if sse2?
        (be_operand.compiler-backend-sse2-shape-diagnostic
          type-segment-bases
          instr-diag
          (Bool)
          lanes)
        (be_operand.compiler-backend-avx2-shape-diagnostic
          type-segment-bases
          instr-diag
          (Bool)
          lanes))
      (match (compiler-backend-vector-dst-reg
        assignments
        dst
        "tail mask dst"
        (if sse2?
          "xmm"
          "ymm")
        (if sse2?
          "%xmm14"
          "%ymm14")
        backend-state)
        [(Ok dst-reg)
          (let
            [qword-fast? : bool (and (not sse2?) (= lanes 4))]
            [index-home : String
              (be_operand.compiler-backend-value-scalar-register-home
                backend-state
                assignments
                (& index))]
            [end-home : String
              (be_operand.compiler-backend-value-scalar-register-home
                backend-state
                assignments
                (& end-value))]
            [index-reg : String
              (if (string.eq index-home "")
                (be_operand.compiler-backend-scavenge-reg-here
                  (be_operand.compiler-backend-one-exclude
                    (string.copy (& end-home)))
                  1
                  "%r8"
                  backend-state)
                (string.copy (& index-home)))]
            [end-reg : String
              (if (string.eq end-home "")
                (be_operand.compiler-backend-scavenge-reg-here
                  (be_operand.compiler-backend-two-exclude
                    (string.copy (& index-home))
                    (string.copy (& index-reg)))
                  2
                  "%r9"
                  backend-state)
                (string.copy (& end-home)))]
            [lane-reg : String
              (if qword-fast?
                ""
                (be_operand.compiler-backend-scavenge-reg-here
                  (be_operand.compiler-backend-two-exclude
                    (string.copy (& index-reg))
                    (string.copy (& end-reg)))
                  2
                  "%r10"
                  backend-state))]
            [lane-bytes : i64
              (if sse2?
                (if (> lanes 0)
                  (/ 16 lanes)
                  0)
                (compiler-backend-avx2-lane-bytes lanes))]
            (match (if (string.eq index-home "")
              (be_operand.compiler-backend-emit-load-value
                assignments
                index
                (string.copy (& index-reg))
                backend-state)
              (be_state.ResultCompilerBackend.Ok ""))
              [(Ok index-asm)
                (match (if (string.eq end-home "")
                  (be_operand.compiler-backend-emit-load-value
                    assignments
                    end-value
                    (string.copy (& end-reg))
                    backend-state)
                  (be_state.ResultCompilerBackend.Ok ""))
                  [(Ok end-asm)
                    (be_operand.compiler-backend-simd-scratch-checked
                      backend-state
                      instr-diag
                      (if qword-fast?
                        0
                        (if sse2?
                          16
                          be_operand.compiler-backend-simd-scratch-lane-staging-bytes))
                      (Ok
                        (str_cat.str-cat
                          index-asm
                          end-asm
                          (if qword-fast?
                            (compiler-backend-avx2-qword-tail-mask-asm
                              (& index-reg)
                              (& end-reg)
                              dst-reg)
                            (str_cat.str-cat
                              (if sse2?
                                "    pxor %xmm0, %xmm0\n    movdqu %xmm0, "
                                "    vpxor %ymm0, %ymm0, %ymm0\n    vmovdqu %ymm0, ")
                              (be_operand.compiler-backend-simd-scratch-address
                                backend-state
                                0)
                              "\n"
                              (compiler-backend-avx2-tail-mask-fill-lanes
                                function
                                current-label
                                dst
                                (& index-reg)
                                (& end-reg)
                                (& lane-reg)
                                0
                                lanes
                                lane-bytes
                                ""
                                backend-state)
                              (if sse2?
                                "    movdqu "
                                "    vmovdqu ")
                              (be_operand.compiler-backend-simd-scratch-address
                                backend-state
                                0)
                              ", "
                              dst-reg
                              "\n"))
                          (compiler-backend-vector-store-dst
                            assignments
                            dst
                            (if sse2?
                              "xmm"
                              "ymm")
                            (I8)
                            dst-reg
                            backend-state))))]
                  [(Err message)
                    (be_state.compiler-backend-instr-error-from
                      instr-diag
                      message)])]
              [(Err message)
                (be_state.compiler-backend-instr-error-from instr-diag message)]))]
        [(Err message)
          (be_state.compiler-backend-instr-error instr-diag message)]))))

(define (compiler-backend-emit-tail-mask
  [type-segment-bases : i64]
  [function : String]
  [current-label : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [index : compiler_ir_types.CompilerIrValue]
  [end-value : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (or
    (be_state.compiler-backend-current-mode-avx2?
      (be_state.compiler-backend-state-function-state backend-state))
    (be_state.compiler-backend-current-mode-sse2?
      (be_state.compiler-backend-state-function-state backend-state)))
    (compiler-backend-emit-avx2-tail-mask
      type-segment-bases
      function
      current-label
      assignments
      dst
      index
      end-value
      lanes
      instr-diag
      backend-state)
    (compiler-backend-emit-avx512-tail-mask
      type-segment-bases
      function
      current-label
      assignments
      dst
      index
      end-value
      lanes
      instr-diag
      backend-state)))

(define (compiler-backend-var-single-use?
  [counts : (& counts (__tl_dyn-array i64))]
  [var : i64]) : bool
  (if (< var 0)
    false
    (if (>= var (array-length counts))
      false
      (= (array-ref counts var) 1))))

(define (compiler-backend-scavenge-rcx-candidates) : (__tl_dyn-array i64)
  (__tl_make-array compiler_abi.compiler-reg-id-rcx))

(define compiler-backend-scavenge-rcx-candidate-pool : (__tl_dyn-array i64)
  (compiler-backend-scavenge-rcx-candidates))

(define (compiler-backend-scavenge-rcx-reg-here
  [exclude : (__tl_dyn-array String)]
  [exclude-n : i64]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [function-state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state backend-state)]
    [point : i64
      (be_state.compiler-backend-function-state-emission-point function-state)]
    [cands : (__tl_dyn-array i64)
      (be_state.compiler-backend-i64-array-shared-view
        (& compiler-backend-scavenge-rcx-candidate-pool))]
    [reg : String
      (be_operand.compiler-backend-scavenge-pick-from-mask
        function-state
        (be_operand.compiler-backend-scavenge-occupied-mask-at-point
          function-state
          point)
        exclude
        exclude-n
        "%rcx"
        cands)]
    reg))