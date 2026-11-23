(import compiler_backend_state as be_state)
(import stdlib.iterator)
(import stdlib.io)
(import compiler_ir_types)
(import compiler_ast_types)
(import compiler_builtin_ids as cbi)
(import compiler_diagnostic)
(import compiler_abi)
(import compiler_regalloc)
(import compiler_liveness)
(import stdlib.text_buf_borrowed)
(import compiler_machine_x64 as mx)
(import stdlib.arena)
(import stdlib.hash)
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as backend_i64_i64_map)
(import stdlib.string)
(import compiler_str_cat as str_cat)
(import stdlib.option)
(import (option.option i64) as option_i64)
(import compiler_owned_view as owned_view)

(define (compiler-backend-avx2-shape-ok?
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]
  [lanes : i64]) : bool
  (match elem-ty
    [(or (I64) (U64) (F64)) (= lanes 4)]
    [(or (F32) (I32) (U32)) (= lanes 8)]
    [(or (I16) (U16)) (= lanes 16)]
    [(or (I8) (U8)) (= lanes 32)]
    [_ false]))

(define (compiler-backend-avx2-shape-diagnostic
  [type-segment-bases : i64]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [elem-ty : compiler_ast_types.AstType]
  [lanes : i64]) : be_state.ResultCompilerBackend
  (be_state.compiler-backend-instr-error
    instr-diag
    (str_cat.str-cat
      "backend: unsupported AVX2 vector shape "
      (string.int->string lanes)
      " x "
      (compiler_ir_types.compiler-ir-type-name type-segment-bases (& elem-ty)))))

(define compiler-backend-xmm-family-xmm : (__tl_dyn-array String)
  (__tl_make-array
    "%xmm0"
    "%xmm1"
    "%xmm2"
    "%xmm3"
    "%xmm4"
    "%xmm5"
    "%xmm6"
    "%xmm7"
    "%xmm8"
    "%xmm9"
    "%xmm10"
    "%xmm11"
    "%xmm12"
    "%xmm13"
    "%xmm14"
    "%xmm15"
    "%xmm16"
    "%xmm17"
    "%xmm18"
    "%xmm19"
    "%xmm20"
    "%xmm21"
    "%xmm22"
    "%xmm23"
    "%xmm24"
    "%xmm25"
    "%xmm26"
    "%xmm27"
    "%xmm28"
    "%xmm29"
    "%xmm30"
    "%xmm31"))
(define compiler-backend-xmm-family-ymm : (__tl_dyn-array String)
  (__tl_make-array
    "%ymm0"
    "%ymm1"
    "%ymm2"
    "%ymm3"
    "%ymm4"
    "%ymm5"
    "%ymm6"
    "%ymm7"
    "%ymm8"
    "%ymm9"
    "%ymm10"
    "%ymm11"
    "%ymm12"
    "%ymm13"
    "%ymm14"
    "%ymm15"
    "%ymm16"
    "%ymm17"
    "%ymm18"
    "%ymm19"
    "%ymm20"
    "%ymm21"
    "%ymm22"
    "%ymm23"
    "%ymm24"
    "%ymm25"
    "%ymm26"
    "%ymm27"
    "%ymm28"
    "%ymm29"
    "%ymm30"
    "%ymm31"))
(define compiler-backend-xmm-family-zmm : (__tl_dyn-array String)
  (__tl_make-array
    "%zmm0"
    "%zmm1"
    "%zmm2"
    "%zmm3"
    "%zmm4"
    "%zmm5"
    "%zmm6"
    "%zmm7"
    "%zmm8"
    "%zmm9"
    "%zmm10"
    "%zmm11"
    "%zmm12"
    "%zmm13"
    "%zmm14"
    "%zmm15"
    "%zmm16"
    "%zmm17"
    "%zmm18"
    "%zmm19"
    "%zmm20"
    "%zmm21"
    "%zmm22"
    "%zmm23"
    "%zmm24"
    "%zmm25"
    "%zmm26"
    "%zmm27"
    "%zmm28"
    "%zmm29"
    "%zmm30"
    "%zmm31"))

(define (compiler-backend-xmm-family-register [home : i64] [width : String]) : String
  (let
    [index : i64 (compiler_regalloc.compiler-reg-xmm-family-index home)]
    (cond
      [(or (< index 0) (>= index 32)) ""]
      [(string.eq width "xmm")
        (be_state.compiler-backend-global-array-element-shared-view
          compiler-backend-xmm-family-xmm
          index)]
      [(string.eq width "zmm")
        (be_state.compiler-backend-global-array-element-shared-view
          compiler-backend-xmm-family-zmm
          index)]
      [(string.eq width "ymm")
        (be_state.compiler-backend-global-array-element-shared-view
          compiler-backend-xmm-family-ymm
          index)]
      [else ""])))

(define (compiler-backend-vector-home-to-ymm [home : i64]) : String
  (compiler-backend-xmm-family-register home "ymm"))

(define (compiler-backend-vector-home-to-xmm [home : i64]) : String
  (compiler-backend-xmm-family-register home "xmm"))

(define (compiler-backend-xmm-to-ymm [reg : String]) : String
  (compiler-backend-xmm-family-register
    (compiler_abi.compiler-abi-register-id-from-spelling reg)
    "ymm"))

(define (compiler-backend-xmm-spelling-family-register
  [reg : String]
  [width : String]) : String
  (compiler-backend-xmm-family-register
    (compiler_abi.compiler-abi-register-id-from-spelling reg)
    width))

(define (compiler-backend-vector-home-to-zmm [home : i64]) : String
  (compiler-backend-xmm-family-register home "zmm"))

(define (compiler-backend-vector-home-unavailable [role : String]) : String
  (str_cat.str-cat
    "backend: vector register home unavailable for "
    role
    "; unsupported spill, call, or ABI lifetime"))

(define (compiler-backend-vector-home-to-reg [home : i64] [width : String]) : String
  (if (string.eq width "xmm")
    (compiler-backend-vector-home-to-xmm home)
    (if (string.eq width "zmm")
      (compiler-backend-vector-home-to-zmm home)
      (compiler-backend-vector-home-to-ymm home))))

(define (compiler-backend-vector-home-valid? [home : i64]) : bool
  (let
    [index : i64 (compiler_regalloc.compiler-reg-xmm-family-index home)]
    (and (>= index 2) (<= index 15))))

(define (compiler-backend-emit-assignment-lookup
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [var : i64]) : compiler_regalloc.CompilerRegMaybeLocation
  (let
    [function-state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state backend-state)]
    [override0-var : i64
      (be_state.compiler-backend-function-state-i64
        function-state
        be_state.compiler-backend-function-i64-home-override0-var)]
    [override1-var : i64
      (be_state.compiler-backend-function-state-i64
        function-state
        be_state.compiler-backend-function-i64-home-override1-var)]
    [rax-override-var : i64
      (be_state.compiler-backend-function-state-i64
        function-state
        be_state.compiler-backend-function-i64-rax-override-var)]
    [assignment-index : compiler_regalloc.CompilerRegAssignmentTable
      (be_state.compiler-backend-function-state-assignment-index function-state)]
    (cond
      [(and (>= override0-var 0) (= var override0-var))
        (Some
          (Register
            (be_state.compiler-backend-function-state-i64
              function-state
              be_state.compiler-backend-function-i64-home-override0-reg)))]
      [(and (>= override1-var 0) (= var override1-var))
        (Some
          (Register
            (be_state.compiler-backend-function-state-i64
              function-state
              be_state.compiler-backend-function-i64-home-override1-reg)))]
      [(and (>= rax-override-var 0) (= var rax-override-var))
        (Some (Register compiler_abi.compiler-reg-id-rax))]
      [(be_state.compiler-backend-function-state-bool?
          function-state
          be_state.compiler-backend-function-bool-emit-assignment-index-active)
        (compiler_regalloc.compiler-reg-assignment-table-lookup
          assignment-index
          var)]
      [else (compiler_regalloc.compiler-reg-assignment-lookup assignments var)])))

(define (compiler-backend-vector-var-home
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [var : i64]
  [role : String]) : be_state.ResultBackendRegId
  (match (compiler-backend-emit-assignment-lookup backend-state assignments var)
    [(Some location)
      (match location
        [(Register home)
          (if (compiler-backend-vector-home-valid? home)
            (Ok home)
            (Err (compiler-backend-vector-home-unavailable role)))]
        [(Spill _)
          (Err
            (str_cat.str-cat
              "backend: vector spills are not implemented for "
              role))]
        ;; A rematerialised value is an i64-class constant/address, never a vector.
        [(or (RegisterPair _ _) (Remat _))
          (Err (compiler-backend-vector-home-unavailable role))])]
    [(No) (Err (compiler-backend-vector-home-unavailable role))]))

(define (compiler-backend-mask-home-unavailable [role : String]) : String
  (str_cat.str-cat
    "backend: mask register home unavailable for "
    role
    "; unsupported spill, call, or ABI lifetime"))

(define (compiler-backend-vector-var-reg
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [var : i64]
  [role : String]
  [width : String]) : be_state.ResultBackendReg
  (let
    [home
      (try
        (compiler-backend-vector-var-home
          backend-state
          assignments
          var
          (be_state.compiler-backend-global-shared-view role)))]
    [reg : String (compiler-backend-vector-home-to-reg home width)]
    (if (= (string.string-length reg) 0)
      (Err (compiler-backend-vector-home-unavailable role))
      (Ok reg))))

(define (compiler-backend-mask-var-reg
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [var : i64]
  [role : String]) : be_state.ResultBackendReg
  (match (compiler-backend-emit-assignment-lookup backend-state assignments var)
    [(Some location)
      (match location
        [(Register home)
          (if (compiler_regalloc.compiler-reg-id-seq-contains?
            (compiler_regalloc.compiler-reg-mask-registers)
            home)
            (Ok (compiler_abi.compiler-abi-register-spelling home))
            (Err (compiler-backend-mask-home-unavailable role)))]
        [(Spill _)
          (Err
            (str_cat.str-cat
              "backend: mask spills are not implemented for "
              role))]
        ;; A rematerialised value is i64-class, never a mask register.
        [(or (RegisterPair _ _) (Remat _))
          (Err (compiler-backend-mask-home-unavailable role))])]
    [(No) (Err (compiler-backend-mask-home-unavailable role))]))

(define (compiler-backend-mask-load-stack-asm
  [lanes : i64]
  [operand : String]
  [reg : (& reg str)]) : String
  (str_cat.str-cat
    "    "
    (compiler-backend-avx512-mask-move-mnemonic lanes)
    " "
    operand
    ", "
    reg
    "\n"))

(define (compiler-backend-avx512-mask-register-use
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]
  [role : String]
  [lanes : i64]
  [scratch : String]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultBackendMaskUse
  (match value
    [(Var var)
      (match (compiler-backend-vector-var-stack-operand
        assignments
        var
        backend-state)
        [(Some operand)
          (Ok
            (Use
              (compiler-backend-mask-load-stack-asm lanes operand scratch)
              scratch))]
        [(No)
          (let
            [reg
              (try
                (compiler-backend-mask-var-reg
                  backend-state
                  assignments
                  var
                  role))]
            (Ok (Use "" reg)))])]
    [_ (Err (str_cat.str-cat "backend: unsupported AVX-512 mask " role))]))

(define (compiler-backend-avx2-vector-move
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]) : String
  (match elem-ty
    [(F64) "vmovupd"]
    [(F32) "vmovups"]
    [_ "vmovdqu"]))

(define (compiler-backend-avx2-masked-move-mnemonic
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]) : String
  (match elem-ty
    [(or (I64) (U64)) "vpmaskmovq"]
    [(F64) "vmaskmovpd"]
    [(or (I32) (U32)) "vpmaskmovd"]
    [(F32) "vmaskmovps"]
    [_ ""]))

(define (compiler-backend-byte-vector-shift?
  [op : (& op compiler_ir_types.CompilerIrBinOp)]
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]) : bool
  (and
    (match elem-ty
      [(or (I8) (U8)) true]
      [_ false])
    (match op
      [(or (Shl _) (Shr _)) true]
      [_ false])))

(define (compiler-backend-word-vector-shift?
  [op : (& op compiler_ir_types.CompilerIrBinOp)]
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]) : bool
  (and
    (match elem-ty
      [(or (I16) (U16)) true]
      [_ false])
    (match op
      [(or (Shl _) (Shr _)) true]
      [_ false])))

(define (compiler-backend-avx2-vector-reduce-op-mnemonic
  [op : compiler_ir_types.CompilerIrVectorReduceOp]
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]) : String
  (match op
    [(Sum)
      (match elem-ty
        [(I64) "vpaddq"]
        [(I32) "vpaddd"]
        [(F32) "vaddps"]
        [(F64) "vaddpd"]
        [_ ""])]
    [(Min)
      (match elem-ty
        [(I32) "vpminsd"]
        [_ ""])]
    [(Max)
      (match elem-ty
        [(I32) "vpmaxsd"]
        [_ ""])]
    [(LastLane) ""]))

(define (compiler-backend-avx512-shape-ok?
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]
  [lanes : i64]) : bool
  (match elem-ty
    [(or (I64) (U64) (F64)) (= lanes 8)]
    [(or (F32) (I32) (U32)) (= lanes 16)]
    [(or (I16) (U16)) (= lanes 32)]
    [(or (I8) (U8)) (= lanes 64)]
    [_ false]))

(define (compiler-backend-avx512-shape-diagnostic
  [type-segment-bases : i64]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [elem-ty : compiler_ast_types.AstType]
  [lanes : i64]) : be_state.ResultCompilerBackend
  (be_state.compiler-backend-instr-error
    instr-diag
    (str_cat.str-cat
      "backend: unsupported AVX-512 vector shape "
      (string.int->string lanes)
      " x "
      (compiler_ir_types.compiler-ir-type-name type-segment-bases (& elem-ty)))))

(define (compiler-backend-avx512-vector-move
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]) : String
  (match elem-ty
    [(F64) "vmovupd"]
    [(F32) "vmovups"]
    [(or (I64) (U64)) "vmovdqu64"]
    [(or (I32) (U32)) "vmovdqu32"]
    [(or (I16) (U16)) "vmovdqu16"]
    [(or (I8) (U8)) "vmovdqu8"]
    [_ ""]))

;; The shared SIMD emitters take the vector ISA as a CompilerBackendMode: Avx2
;; works in ymm registers, Avx512 in zmm. A shape that fills a zmm is emitted
;; with AVX-512; every other shape goes to AVX2, which diagnoses the ones that
;; fit neither.
(define (compiler-backend-vector-mode
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]
  [lanes : i64]) : be_state.CompilerBackendMode
  (if (compiler-backend-avx512-shape-ok? elem-ty lanes)
    (Avx512)
    (Avx2)))

(define (compiler-backend-mode-shape-ok?
  [mode : be_state.CompilerBackendMode]
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]
  [lanes : i64]) : bool
  (match mode
    [(Avx512) (compiler-backend-avx512-shape-ok? elem-ty lanes)]
    [_ (compiler-backend-avx2-shape-ok? elem-ty lanes)]))

(define (compiler-backend-vector-move-for-width
  [width : (& width str)]
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]) : String
  (if (string.eq width "zmm")
    (compiler-backend-avx512-vector-move elem-ty)
    (compiler-backend-avx2-vector-move elem-ty)))

(define (compiler-backend-vector-spill-scratch
  [width : (& width str)]
  [index : i64]) : String
  (if (string.eq width "zmm")
    (if (= index 0)
      "%zmm14"
      "%zmm15")
    (if (= index 0)
      "%ymm14"
      "%ymm15")))

(define (compiler-backend-vector-reg-lower-ymm [reg : String]) : String
  (compiler-backend-xmm-spelling-family-register reg "ymm"))

(define (compiler-backend-vector-reg-lower-xmm [reg : String]) : String
  (compiler-backend-xmm-spelling-family-register reg "xmm"))

(define (compiler-backend-vector-unsupported-message
  [width : String]
  [role : String]) : String
  (let
    [prefix : String
      (if (string.eq width "zmm")
        "backend: unsupported AVX-512 vector "
        "backend: unsupported AVX2 vector ")]
    (str_cat.str-cat prefix role)))

(define (compiler-backend-vector-var-stack-operand
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [var : i64]
  [backend-state : be_state.CompilerBackendState]) : be_state.CompilerBackendMaybeStackOperand
  (match (compiler-backend-emit-assignment-lookup backend-state assignments var)
    [(Some location)
      (match location
        [(Spill offset)
          (Some
            (compiler-backend-frame-offset-with-backend-state
              backend-state
              offset))]
        [_ No])]
    [(No) (Some (compiler-backend-slot-with-backend-state backend-state var))]))

(define (compiler-backend-vector-load-stack-asm
  [move : String]
  [operand : String]
  [reg : (& reg str)]) : String
  (str_cat.str-cat "    " move " " operand ", " reg "\n"))

(define (compiler-backend-vector-register-use
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]
  [role : String]
  [width : String]
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]
  [scratch : String]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultBackendVectorUse
  (match value
    [(Var var)
      (match (compiler-backend-vector-var-stack-operand
        assignments
        var
        backend-state)
        [(Some operand)
          (Ok
            (Use
              (compiler-backend-vector-load-stack-asm
                (compiler-backend-vector-move-for-width width elem-ty)
                operand
                scratch)
              scratch))]
        [(No)
          (let
            [reg
              (try
                (compiler-backend-vector-var-reg
                  backend-state
                  assignments
                  var
                  role
                  width))]
            (Ok (Use "" reg)))])]
    [_ (Err (compiler-backend-vector-unsupported-message width role))]))

(define (compiler-backend-avx512-vector-reduce-op-mnemonic
  [op : compiler_ir_types.CompilerIrVectorReduceOp]
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]) : String
  (match op
    [(Min)
      (match elem-ty
        [(I64) "vpminsq"]
        [(I16) "vpminsw"]
        [(U16) "vpminuw"]
        [(I8) "vpminsb"]
        [(U8) "vpminub"]
        [_ (compiler-backend-avx2-vector-reduce-op-mnemonic op elem-ty)])]
    [(Max)
      (match elem-ty
        [(I64) "vpmaxsq"]
        [_ (compiler-backend-avx2-vector-reduce-op-mnemonic op elem-ty)])]
    [_ (compiler-backend-avx2-vector-reduce-op-mnemonic op elem-ty)]))

(define (compiler-backend-avx512-mask-op-suffix [lanes : i64]) : String
  (if (> lanes 32)
    "q"
    (if (> lanes 16)
      "d"
      "w")))

(define (compiler-backend-avx512-mask-move-mnemonic [lanes : i64]) : String
  (str_cat.str-cat "kmov" (compiler-backend-avx512-mask-op-suffix lanes)))

(define (compiler-backend-avx2-mask-shape-ok? [lanes : i64]) : bool
  (or (= lanes 4) (= lanes 8) (= lanes 16) (= lanes 32)))

(define (compiler-backend-avx2-gather-mnemonic
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]) : String
  (match elem-ty
    [(or (I32) (U32)) "vpgatherqd"]
    [(or (I64) (U64)) "vpgatherqq"]
    [(F32) "vgatherqps"]
    [(F64) "vgatherqpd"]
    [_ ""]))

(define (compiler-backend-avx512-gather-mnemonic
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]) : String
  (compiler-backend-avx2-gather-mnemonic elem-ty))

(define (compiler-backend-gather-dword-element?
  [elem-ty : compiler_ast_types.AstType]) : bool
  (match elem-ty
    [(or (I32) (U32) (F32)) true]
    [_ false]))

(define (compiler-backend-load-value-asm
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]
  [reg : String]
  [backend-state : be_state.CompilerBackendState]) : String
  (match (compiler-backend-emit-load-value assignments value reg backend-state)
    [(Ok asm) asm]
    [(Err _) ""]))

(define (compiler-backend-round-up-16 [n : i64]) : i64
  (if (= n 0)
    0
    (* (/ (+ n 15) 16) 16)))

;; Window size shared by the state-owned retained operand render caches.
;; Var-ids/offsets outside this window fall back to rendering fresh.
(define compiler-backend-slot-cache-capacity : i64
  16384)

;; "Does this function's plan home a value in register R" is a per-function,
;; per-REGISTER constant: the emitted assignment table is fixed before body
;; emission (every re-plan stage -- caller-save and slot
;; coloring -- is already folded into it, exactly as for the dense operand
;; view above). The prologue/epilogue, frame layout, callee-save and FPO paths
;; ask it tens of times per function, so rather than re-walk the whole table
;; through `compiler-reg-location-uses-register?` (two ownership-id folds per
;; populated entry) at each ask, fold the table ONCE per function into a
;; register bitmask.
;;
;; The bit index is the register's OWNERSHIP id (`compiler-abi-registers-overlap?`'s
;; equivalence class: a vec id folds onto its xmm sibling), so the mask answers
;; exactly what the walk answers, overlap included. Ownership ids live in
;; 0..15 (GP) and 32..63 (XMM family); mask registers (96..) fall outside the
;; word, so they are simply not recorded -- sound, because a location whose
;; ownership id is outside the word can never equal a query inside it, and a
;; query outside the word falls back to the walk.
;;
;; Ownership folding is the IDENTITY on every id the word covers -- GP ids are
;; their own class and an xmm id is its own class representative -- so ids
;; already inside 0..63 take the bit directly and only a vec id (64..95) pays
;; the fold onto its xmm sibling.
(define (compiler-backend-plan-reg-id-bit [reg : i64]) : i64
  (if (and (>= reg 0) (< reg 64))
    (shl 1 reg)
    (let
      [own : i64 (compiler_abi.compiler-abi-register-ownership-id reg)]
      (if (and (>= own 0) (< own 64))
        (shl 1 own)
        0))))

;; ---------------------------------------------------------------------------
;; RG-1: the registers the FINAL body can actually name.
;;
;; `compiler-backend-plan-reg-mask-of` answers "does the PLAN home a value
;; here", which is not the same question as "does an instruction of this
;; function mention that register". A value can lose every reference after it
;; was homed -- a coalesced member is folded away, for one -- and the
;; assignment survives in the table, so the prologue pushes a callee-saved
;; register the body never reads and the epilogue pops it back. That pair is
;; pure cost.
;;
;; The body mask is the union of the homes of every var some instruction of the
;; FINAL emitted IR mentions (the liveness walker's own use/def enumeration --
;; the same notion of "reference" the spill weight counts) plus the homes of
;; the PARAMETERS, whose entry copies the prologue emits from the parameter
;; list rather than from any instruction.
;; RG-1: the per-function `regalloc-csr|` line -- the callee-saved set the
;; prologue really saves against the set the body really names. The two differ
;; exactly where fix B applies.
(define (compiler-backend-trace-csr-name-at
  [_backend-state : be_state.CompilerBackendState]
  [idx : i64]) : i64
  (compiler-backend-callee-save-order-reg-id idx))

(define (compiler-backend-plan-uses-reg?
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [reg : i64]) : bool
  (let
    [function-state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state backend-state)]
    ;; An empty plan homes nothing, whatever the installed mask describes; this
    ;; keeps out-of-emission callers correct.
    (if (compiler_regalloc.compiler-reg-assignment-table-empty? assignments)
      false
      (if (be_state.compiler-backend-function-state-bool?
        function-state
        be_state.compiler-backend-function-bool-emit-plan-reg-mask-active)
        (let
          [bit : i64 (compiler-backend-plan-reg-id-bit reg)]
          (if (= bit 0)
            (compiler_regalloc.compiler-reg-assignments-use-register?
              assignments
              reg)
            (not
              (=
                (bit-and
                  (be_state.compiler-backend-function-state-i64
                    function-state
                    be_state.compiler-backend-function-i64-emit-plan-reg-mask)
                  bit)
                0))))
        (compiler_regalloc.compiler-reg-assignments-use-register?
          assignments
          reg)))))

(define (compiler-backend-plan-uses-callee-regs?
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [backend-state : be_state.CompilerBackendState]) : bool
  (or
    (compiler-backend-callee-needs-save?
      backend-state
      assignments
      compiler_abi.compiler-reg-id-rbx)
    (compiler-backend-callee-needs-save?
      backend-state
      assignments
      compiler_abi.compiler-reg-id-r12)
    (compiler-backend-callee-needs-save?
      backend-state
      assignments
      compiler_abi.compiler-reg-id-r13)
    (compiler-backend-callee-needs-save?
      backend-state
      assignments
      compiler_abi.compiler-reg-id-r14)
    (compiler-backend-callee-needs-save?
      backend-state
      assignments
      compiler_abi.compiler-reg-id-r15)
    ;; M-G3 stage 2: %rbp is the 6th pool CSR in FPO functions.
    (compiler-backend-callee-needs-save?
      backend-state
      assignments
      compiler_abi.compiler-reg-id-rbp)
    (and
      (be_state.compiler-backend-current-fn-win64? backend-state)
      (compiler-backend-plan-uses-win64-xmm-callee-regs?
        assignments
        backend-state))))

(define (compiler-backend-win64-xmm-callee-highest-at
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [highest : i64]) : i64
  (for [idx
    (iterator.range
      0
      (compiler_abi.compiler-abi-callee-saved-xmm-register-count
        (Windows)
        (Internal)))]
    (set!
      highest
      (if (compiler-backend-callee-needs-save?
        backend-state
        assignments
        (compiler_abi.compiler-abi-callee-saved-xmm-register-id
          (Windows)
          (Internal)
          idx))
        idx
        highest)))
  highest)

(define (compiler-backend-win64-xmm-callee-highest
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [backend-state : be_state.CompilerBackendState]) : i64
  (if (be_state.compiler-backend-current-fn-win64? backend-state)
    (compiler-backend-win64-xmm-callee-highest-at backend-state assignments -1)
    -1))

(define (compiler-backend-plan-uses-win64-xmm-callee-regs?
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [backend-state : be_state.CompilerBackendState]) : bool
  (>= (compiler-backend-win64-xmm-callee-highest assignments backend-state) 0))

(define (compiler-backend-round-up-even-slots [slots : i64]) : i64
  (if (= (% slots 2) 0)
    slots
    (+ slots 1)))

(define (compiler-backend-win64-gp-callee-save-prefix
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]) : i64
  (if (compiler-backend-callee-needs-save?
    backend-state
    assignments
    compiler_abi.compiler-reg-id-rbp)
    6
    5))

;; Both Internal conventions save r12..r15, rbx, then optional FPO-only rbp.
;; XMM slots begin after that prefix and retain their 16-byte alignment.
(define (compiler-backend-frame-slots
  [vars : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [backend-state : be_state.CompilerBackendState]) : i64
  (let
    [highest : i64
      (compiler-backend-win64-xmm-callee-highest assignments backend-state)]
    (if (>= highest 0)
      (+
        (compiler-backend-round-up-even-slots
          (+
            vars
            (compiler-backend-win64-gp-callee-save-prefix
              backend-state
              assignments)))
        (* 2 (+ highest 1)))
      (if (compiler-backend-plan-uses-callee-regs? assignments backend-state)
        (cond
          [(compiler-backend-callee-needs-save?
              backend-state
              assignments
              compiler_abi.compiler-reg-id-rbp)
            (+ vars 6)]
          [(compiler-backend-callee-needs-save?
              backend-state
              assignments
              compiler_abi.compiler-reg-id-rbx)
            (+ vars 5)]
          [else (+ vars 4)])
        vars))))

(define (compiler-backend-asm-label [function : String] [label : i64]) : String
  (str_cat.str-cat
    ".L"
    (compiler-backend-asm-safe-symbol function)
    "_"
    (compiler_ir_types.compiler-ir-label-text label)))

;; R11 may hold an indirect-call target at transient allocation sites. Save it
;; INSIDE the new allocation, then use it as the page-loop endpoint. The save
;; consumes eight of FRAME bytes; every following descent is at most 4096 and
;; is touched before the next descent. Numeric local labels are assembler-local
;; to this contiguous sequence, including when several probes share a function.
(define (compiler-backend-emit-stack-probe [frame : i64]) : String
  (let
    [remaining : i64 (- frame 8)]
    [tail : i64 (% remaining 4096)]
    [pages : i64 (- remaining tail)]
    (str_cat.str-cat
      "    pushq %r11\n"
      (if (> pages 0)
        (str_cat.str-cat
          "    leaq -"
          (string.int->string pages)
          "(%rsp), %r11\n997:\n"
          "    subq $4096, %rsp\n    testb $0, (%rsp)\n    cmpq %r11, %rsp\n    jne 997b\n")
        "")
      (if (> tail 0)
        (str_cat.str-cat
          "    subq $"
          (string.int->string tail)
          ", %rsp\n    testb $0, (%rsp)\n")
        "")
      "    movq "
      (string.int->string remaining)
      "(%rsp), %r11\n")))

;; ELF function symbols for the Linux text path.
;;
;; Without these two directives `as` records every code symbol this backend
;; emits as STT_NOTYPE with `st_size` 0, so nothing that resolves an address to
;; a name -- perf, valgrind/cachegrind, a debugger backtrace -- can attribute a
;; sample to a function, and profiling a selfhost build means post-processing
;; the generated `.s` first. Both directives are assembler metadata: they
;; describe the symbol table entry and contribute no bytes to `.text`, so the
;; emitted program is byte-identical with or without them.
;;
;; They belong to whole FUNCTIONS only. Data labels keep the assembler default
;; typing, the thread-local arena object must stay untyped (`as` rejects
;; `.type` on a TLS symbol), and block-local `.L` labels never reach the
;; object's symbol table at all. Windows COFF has no GNU-as spelling for
;; either, so the Windows text path emits nothing.
(define (compiler-backend-emit-function-type-directive
  [target : be_state.CompilerBackendTarget]
  [symbol : (& symbol str)]) : String
  (if (be_state.compiler-backend-target-elf? target)
    (str_cat.str-cat "    .type " symbol ",@function\n")
    ""))

;; `. - symbol` is evaluated where the directive sits, so this must close the
;; function after its last emitted byte and before the next function's `.type`.
(define (compiler-backend-emit-function-size-directive
  [target : be_state.CompilerBackendTarget]
  [symbol : (& symbol str)]) : String
  (if (be_state.compiler-backend-target-elf? target)
    (str_cat.str-cat "    .size " symbol ", . - " symbol "\n")
    ""))

(define (compiler-backend-float-type? [ty : (& ty compiler_ast_types.AstType)]) : bool
  (match ty
    [(or (F64) (F32)) true]
    [_ false]))

(define (compiler-backend-float-move [ty : (& ty compiler_ast_types.AstType)]) : String
  (match ty
    [(F32) "movss"]
    [_ "movsd"]))

(define (compiler-backend-float-type-name [ty : compiler_ast_types.AstType]) : String
  (match ty
    [(F32) "f32"]
    [_ "f64"]))

(define (compiler-backend-forwarded-addr-of-src
  [backend-state : be_state.CompilerBackendState]
  [var-id : i64]) : i64
  (let
    [function-state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state backend-state)]
    [sources : (__tl_dyn-array i64)
      (be_state.compiler-backend-function-state-i64-array
        function-state
        be_state.compiler-backend-function-i64-array-addr-of-forwarding-src)]
    (if (be_state.compiler-backend-function-state-bool?
      function-state
      be_state.compiler-backend-function-bool-addr-of-forwarding-enabled)
      (if (and (>= var-id 0) (< var-id (array-length sources)))
        (array-ref sources var-id)
        (- 0 1))
      (- 0 1))))

;; Copy register `home` into `reg`; nothing when they are one register.
(define (compiler-backend-emit-register-home-into!
  [out : (&mut out be_state.CompilerBackendAsmBuf)]
  [home : i64]
  [reg : String]) : unit
  (let
    [dst : i64
      (compiler-backend-machine-register
        (be_state.compiler-backend-global-shared-view reg))]
    (cond
      [(= dst home) unit]
      ;; An XMM home is MOVQ xmm, another instruction, and keeps its text.
      [(and
          (mx.compiler-machine-x64-gpr? dst)
          (mx.compiler-machine-x64-gpr? home))
        (compiler-backend-asm-append-machine!
          out
          (mx.MachineInstr.MovRR (W64) dst home))]
      [else
        (be_state.compiler-backend-asm-append5
          out
          "    movq "
          (compiler_abi.compiler-abi-register-spelling home)
          ", "
          reg
          "\n")])))

(define (compiler-backend-emit-load-var-into
  [out : (&mut out be_state.CompilerBackendAsmBuf)]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [var-id : i64]
  [reg : String]
  [backend-state : be_state.CompilerBackendState]) : unit
  (let
    [forward-src : i64
      (compiler-backend-forwarded-addr-of-src backend-state var-id)]
    (if (>= forward-src 0)
      (be_state.compiler-backend-asm-append5
        out
        "    leaq "
        (compiler-backend-addr-of-source-slot
          assignments
          forward-src
          backend-state)
        ", "
        reg
        "\n")
      (match (compiler-backend-emit-assignment-lookup
        backend-state
        assignments
        var-id)
        [(Some location)
          (match location
            ;; Loading a whole register-group var into one register is not a
            ;; scalar op; word extraction goes through CompilerIrInstr.Word.
            ;; Word0's home is the low register -- used only by the (unreached
            ;; here) group paths.
            [(or (Register home) (RegisterPair home _))
              (compiler-backend-emit-register-home-into! out home reg)]
            [(Spill offset)
              (be_state.compiler-backend-asm-append5
                out
                "    movq "
                (compiler-backend-frame-offset-with-backend-state
                  backend-state
                  offset)
                ", "
                reg
                "\n")]
            ;; Rematerialise: recompute the value into `reg` instead of reloading
            ;; from a slot. remat-recompute-value? guarantees this load succeeds.
            [(Remat value)
              (be_state.compiler-backend-asm-append
                out
                (compiler-backend-load-value-asm
                  (compiler_regalloc.compiler-reg-assignment-table-empty)
                  value
                  reg
                  backend-state))])]
        [(No)
          (be_state.compiler-backend-asm-append5
            out
            "    movq "
            (compiler-backend-slot-with-backend-state backend-state var-id)
            ", "
            reg
            "\n")]))))

(define (compiler-backend-emit-store-var-into
  [out : (&mut out be_state.CompilerBackendAsmBuf)]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [var-id : i64]
  [reg : String]
  [backend-state : be_state.CompilerBackendState]) : unit
  (match (compiler-backend-emit-assignment-lookup
    backend-state
    assignments
    var-id)
    [(Some location)
      (match location
        [(or (Register home) (RegisterPair home _))
          (let
            [home-name : String
              (compiler_abi.compiler-abi-register-spelling home)]
            (if (string.eq home-name reg)
              unit
              (be_state.compiler-backend-asm-append5
                out
                "    movq "
                reg
                ", "
                home-name
                "\n")))]
        [(Spill offset)
          (be_state.compiler-backend-asm-append5
            out
            "    movq "
            reg
            ", "
            (compiler-backend-frame-offset-with-backend-state
              backend-state
              offset)
            "\n")]
        ;; Rematerialised value: its single def store is dead (every use
        ;; recomputes), so emit nothing.
        [(Remat _) unit])]
    [(No)
      (be_state.compiler-backend-asm-append5
        out
        "    movq "
        reg
        ", "
        (compiler-backend-slot-with-backend-state backend-state var-id)
        "\n")]))

(define (compiler-backend-emit-store-var
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [var-id : i64]
  [reg : String]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [line : be_state.CompilerBackendAsmBuf
      (be_state.compiler-backend-asm-buf-with-capacity
        be_state.compiler-backend-asm-line-capacity)]
    (compiler-backend-emit-store-var-into
      (&mut line)
      assignments
      var-id
      reg
      backend-state)
    (be_state.compiler-backend-asm-buf-finish (& line))))

(define (compiler-backend-emit-load-float-var
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [var-id : i64]
  [ty : compiler_ast_types.AstType]
  [reg : String]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [mov : String (compiler-backend-float-move ty)]
    (match (compiler-backend-emit-assignment-lookup
      backend-state
      assignments
      var-id)
      [(Some location)
        (match location
          [(Register home)
            (let
              [home-name : String
                (compiler_abi.compiler-abi-register-spelling home)]
              (if (string.eq home-name reg)
                ""
                (str_cat.str-cat "    " mov " " home-name ", " reg "\n")))]
          [(Spill offset)
            (str_cat.str-cat
              "    "
              mov
              " "
              (compiler-backend-frame-offset-with-backend-state
                backend-state
                offset)
              ", "
              reg
              "\n")]
          ;; A register-group var is never float-class; unreachable.
          ;; A rematerialisable value is a constant/address (i64-class), never a
          ;; float; unreachable here.
          [(or (RegisterPair _ _) (Remat _)) ""])]
      [(No)
        (str_cat.str-cat
          "    "
          mov
          " "
          (compiler-backend-slot-with-backend-state backend-state var-id)
          ", "
          reg
          "\n")])))

(define (compiler-backend-emit-store-float-var
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [var-id : i64]
  [reg : String]
  [ty : (& compiler_ast_types.AstType)]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [mov : String (compiler-backend-float-move ty)]
    (match (compiler-backend-emit-assignment-lookup
      backend-state
      assignments
      var-id)
      [(Some location)
        (match location
          [(Register home)
            (let
              [home-name : String
                (compiler_abi.compiler-abi-register-spelling home)]
              (if (string.eq home-name reg)
                ""
                (str_cat.str-cat "    " mov " " reg ", " home-name "\n")))]
          [(Spill offset)
            (str_cat.str-cat
              "    "
              mov
              " "
              reg
              ", "
              (compiler-backend-frame-offset-with-backend-state
                backend-state
                offset)
              "\n")]
          ;; A register-group var is never float-class; unreachable.
          ;; A rematerialised value is never float-class; unreachable.
          [(or (RegisterPair _ _) (Remat _)) ""])]
      [(No)
        (str_cat.str-cat
          "    "
          mov
          " "
          reg
          ", "
          (compiler-backend-slot-with-backend-state backend-state var-id)
          "\n")])))

;; On-demand callee-save: the scavenge may use a FREE callee-saved register even
;; when the allocator did not home a value there. Record which callee-saved regs
;; it used during this function's body emission so the prologue/epilogue save and
;; restore them too. Reset per function in scavenge-install-ctx! (runs before the
;; body, and the body is emitted before the prologue str-cat reads the set).
;; Single source of truth for the callee-saved GP registers
;; {%r12,%r13,%r14,%r15,%rbx} = compiler-reg-sysv-integer-registers (built once).
;; The used-callee tracking array size, the index map, the reset, and the
;; membership predicate all derive from this list, so the set lives in one place
;; instead of being hardcoded in 4-5 spots. Behavior-identical: same registers,
;; same order, same indices (r12=0 .. rbx=4).
(define compiler-backend-scavenge-callee-list : compiler_regalloc.CompilerRegIdSeq
  (compiler_regalloc.compiler-reg-sysv-integer-registers))

;; ============================================================================
;; SIMD staging region (#7497).
;;
;; Some SIMD sequences stage vectors or lanes in memory:
;;   * the AVX2 word and the AVX2/AVX-512 byte variable-shift fallbacks;
;;   * gather reassembly and the AVX2 gather mask save;
;;   * shuffle selector, index and source staging;
;;   * the AVX2 narrow predicated load/store fallbacks;
;;   * AVX2 non-qword tail-mask staging.
;; Each used to open its own `subq/addq` window on %rsp: stack motion that no
;; frame record described, and that shuffle's abort edge called out of.
;;
;; Now the frame carries one region. It is sized before the body to the
;; largest request any instruction in the function will make. Every sequence
;; addresses it at the same fixed offset, spelled like any other frame slot, so
;; the rsp/FPO rebase and the red-zone anchor rewrite it with the rest of the
;; frame.
;;
;; Each request is live only inside one instruction's sequence, so the region
;; is the largest request, not their sum. Every access is an unaligned move, so
;; the frame's 16-byte alignment is enough; a sequence switched to aligned moves
;; must raise it.
;;
;; The census (`compiler-backend-simd-scratch-request`) and the emitters size
;; each route with the helpers below. Each emitted route claims its bytes; a
;; claim beyond the plan fails at the instruction, and after the body the
;; region the body used must equal the plan.
;; ============================================================================
;; AVX2 word shift: lhs, rhs and the two widened dword result groups.
(define compiler-backend-simd-scratch-word-shift-bytes : i64
  128)

;; Byte shift: lhs, rhs, the four widened dword result groups and the
;; permutation index row, one vector each.
(define (compiler-backend-simd-scratch-byte-shift-bytes [vector-bytes : i64]) : i64
  (* vector-bytes 7))

;; Gather: a dword gather stages its high index half and both result halves
;; (and AVX2 saves its destructive mask below them); an AVX2 qword gather saves
;; only the mask, and an AVX-512 qword gather stages nothing.
(define (compiler-backend-simd-scratch-gather-bytes
  [avx2 : bool]
  [dword : bool]) : i64
  (if dword
    128
    (if avx2
      32
      0)))

;; Shuffle: one vector per selector half, then the index and the source.
(define (compiler-backend-simd-scratch-shuffle-bytes
  [width-bytes : i64]
  [selector-count : i64]) : i64
  (* width-bytes (+ selector-count 2)))

;; AVX2 lane staging: one ymm of lanes for the predicated fallbacks and the
;; non-qword tail mask.
(define compiler-backend-simd-scratch-lane-staging-bytes : i64
  32)

;; Record that the body used the region's first BYTES bytes.
(define (compiler-backend-simd-scratch-use!
  [function-state : be_state.CompilerBackendFunctionState]
  [bytes : i64]) : unit
  (if (>
    bytes
    (be_state.compiler-backend-function-scratch-i64
      function-state
      be_state.compiler-backend-scratch-i64-simd-scratch-used-bytes))
    (be_state.compiler-backend-function-scratch-set-i64!
      function-state
      be_state.compiler-backend-scratch-i64-simd-scratch-used-bytes
      bytes)
    unit))

;; RESULT of a sequence that stages BYTES in the region. Records the largest
;; claim of the body for the check after it, and fails at the instruction when
;; the planned region cannot hold BYTES.
(define (compiler-backend-simd-scratch-checked
  [backend-state : be_state.CompilerBackendState]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [bytes : i64]
  [result : be_state.ResultCompilerBackend]) : be_state.ResultCompilerBackend
  (let
    [function-state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state backend-state)]
    [planned : i64
      (be_state.compiler-backend-function-scratch-i64
        function-state
        be_state.compiler-backend-scratch-i64-simd-scratch-bytes)]
    (compiler-backend-simd-scratch-use! function-state bytes)
    (if (<= bytes planned)
      result
      (be_state.compiler-backend-instr-error
        instr-diag
        (str_cat.str-cat
          "backend: SIMD staging needs "
          (string.int->string bytes)
          " bytes but the function planned "
          (string.int->string planned))))))

;; Byte OFFSET of the staging region, as a frame reference. A reference past
;; the plan counts as use, so the check after the body fails it.
(define (compiler-backend-simd-scratch-address
  [backend-state : be_state.CompilerBackendState]
  [offset : i64]) : String
  (let
    [function-state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state backend-state)]
    (if (>=
      offset
      (be_state.compiler-backend-function-scratch-i64
        function-state
        be_state.compiler-backend-scratch-i64-simd-scratch-bytes))
      (compiler-backend-simd-scratch-use! function-state (+ offset 1))
      unit)
    (compiler-backend-frame-offset-with-backend-state
      backend-state
      (+
        (be_state.compiler-backend-function-scratch-i64
          function-state
          be_state.compiler-backend-scratch-i64-simd-scratch-base-offset)
        offset))))

;; "Undecided" park location: the entry exists but the bracketed text has not
;; been seen yet, so neither an XMM park nor a frame slot has been charged for
;; it. Every emitter of a save or a restore commits first.
(define compiler-backend-emergency-loc-undecided : i64
  -4611686018427387904)

;; "Elided": the bracketed text turned out never to touch the borrowed
;; register, so there is nothing to preserve and the wrap emits no save and no
;; restore at all. See compiler-backend-emergency-reg-untouched-by-text?.
(define compiler-backend-emergency-loc-elided : i64
  -4611686018427387903)

;; The park location recorded for pending entry `index`.
(define (compiler-backend-emergency-save-loc
  [function-state : be_state.CompilerBackendFunctionState]
  [index : i64]) : i64
  (let
    [locs : (__tl_dyn-array i64)
      (be_state.compiler-backend-function-scratch-i64-array
        function-state
        be_state.compiler-backend-scratch-i64-array-emergency-save-locs)]
    (if (< index (array-length locs))
      (array-ref locs index)
      compiler-backend-emergency-loc-undecided)))

(define (compiler-backend-emergency-loc-slot-form? [loc : i64]) : bool
  (and
    (< loc 0)
    (not (= loc compiler-backend-emergency-loc-undecided))
    (not (= loc compiler-backend-emergency-loc-elided))))

(define (compiler-backend-emergency-index
  [function-state : be_state.CompilerBackendFunctionState]
  [reg : i64]) : i64
  (let
    [index : i64 0]
    [found : i64 -1]
    [count : i64
      (be_state.compiler-backend-function-scratch-i64
        function-state
        be_state.compiler-backend-scratch-i64-emergency-pending-count)]
    [regs : (__tl_dyn-array i64)
      (be_state.compiler-backend-function-scratch-i64-array
        function-state
        be_state.compiler-backend-scratch-i64-array-emergency-regs)]
    (while (and (< index count) (< found 0))
      (if (= (array-ref regs index) reg)
        (set! found index)
        unit)
      (+= index 1))
    found))

(define (compiler-backend-emergency-regs-push
  [regs : (__tl_dyn-array i64)]
  [count : i64]
  [reg : i64]) : (__tl_dyn-array i64)
  (if (< count (array-length regs))
    (begin
      (set! (array-ref regs count) reg)
      regs)
    (let
      [old-cap : i64 (array-length regs)]
      [new-cap : i64
        (if (= old-cap 0)
          4
          (* old-cap 2))]
      [grown : (__tl_dyn-array i64) (__tl_make-array i64 new-cap)]
      (for [index (iterator.range 0 count)]
        (set! (array-ref grown index) (array-ref regs index)))
      (set! (array-ref grown count) reg)
      grown)))

(define (compiler-backend-emergency-add-id!
  [function-state : be_state.CompilerBackendFunctionState]
  [reg : i64]) : unit
  (let
    [existing : i64 (compiler-backend-emergency-index function-state reg)]
    [count : i64
      (be_state.compiler-backend-function-scratch-i64
        function-state
        be_state.compiler-backend-scratch-i64-emergency-pending-count)]
    (be_state.compiler-backend-function-scratch-set-i64!
      function-state
      be_state.compiler-backend-scratch-i64-emergency-reg
      reg)
    (if (>= existing 0)
      (begin
        (be_state.compiler-backend-function-scratch-set-bool!
          function-state
          be_state.compiler-backend-scratch-bool-emergency-pending
          true)
        ;; `emergency-used` is the "this function needs the frame's emergency
        ;; region" fact; an XMM-parked save does not.
        (if (compiler-backend-emergency-loc-slot-form?
          (compiler-backend-emergency-save-loc function-state existing))
          (be_state.compiler-backend-function-scratch-set-bool!
            function-state
            be_state.compiler-backend-scratch-bool-emergency-used
            true)
          unit))
      (let
        ;; T1-6 (b): the park location is decided when the bracketed text is
        ;; known (compiler-backend-emergency-commit-locs!), not here.
        [loc : i64 compiler-backend-emergency-loc-undecided]
        [next-count : i64 (+ count 1)]
        [regs : (__tl_dyn-array i64)
          (compiler-backend-emergency-regs-push
            (be_state.compiler-backend-function-scratch-i64-array
              function-state
              be_state.compiler-backend-scratch-i64-array-emergency-regs)
            count
            reg)]
        [locs : (__tl_dyn-array i64)
          (compiler-backend-emergency-regs-push
            (be_state.compiler-backend-function-scratch-i64-array
              function-state
              be_state.compiler-backend-scratch-i64-array-emergency-save-locs)
            count
            loc)]
        (be_state.compiler-backend-function-scratch-set-i64-array!
          function-state
          be_state.compiler-backend-scratch-i64-array-emergency-regs
          regs)
        (be_state.compiler-backend-function-scratch-set-i64-array!
          function-state
          be_state.compiler-backend-scratch-i64-array-emergency-save-locs
          locs)
        (be_state.compiler-backend-function-scratch-set-i64!
          function-state
          be_state.compiler-backend-scratch-i64-emergency-pending-count
          next-count)
        (be_state.compiler-backend-function-scratch-set-bool!
          function-state
          be_state.compiler-backend-scratch-bool-emergency-pending
          true)))))

(define (compiler-backend-emergency-add!
  [function-state : be_state.CompilerBackendFunctionState]
  [reg : String]) : unit
  (compiler-backend-emergency-add-id!
    function-state
    (compiler_abi.compiler-abi-register-id-from-spelling reg)))

;; A callee-saved reg must be saved by the prologue iff the allocator plan homes a
;; value there. Scavenge picks of callee-saved registers are restricted to the
;; plan-saved set (scavenge-candidate-ok?'s plan-mask clause) or emergency-wrapped
;; locally, so no dynamic callee-save tracking is needed -- and it would be unsound:
;; the prologue SAVE is emitted post-body (final set) while every RESTORE is emitted
;; inline during the body, so an early return would restore a partial set.
;; Callers select from the common Internal GP CSR order or the Win64 XMM CSR
;; bank before querying this plan. Platform bridges preserve RSI/RDI separately;
;; their general ABI eligibility is not recomputed for every Internal save.
(define (compiler-backend-callee-needs-save?
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [reg : i64]) : bool
  (or
    (compiler-backend-plan-uses-reg? backend-state assignments reg)
    (compiler-backend-const-hoist-uses-reg?
      (be_state.compiler-backend-state-function-state backend-state)
      reg)))

(define (compiler-backend-callee-save-order-reg-id [k : i64]) : i64
  (cond
    [(= k 0) compiler_abi.compiler-reg-id-r12]
    [(= k 1) compiler_abi.compiler-reg-id-r13]
    [(= k 2) compiler_abi.compiler-reg-id-r14]
    [(= k 3) compiler_abi.compiler-reg-id-r15]
    [(= k 4) compiler_abi.compiler-reg-id-rbx]
    [(= k 5) compiler_abi.compiler-reg-id-rbp]
    [else compiler_abi.compiler-reg-id-invalid]))

(define (compiler-backend-imm32? [n : i64]) : bool
  (and (>= n (- 0 2147483648)) (<= n 2147483647)))

(define (compiler-backend-asm-append-machine!
  [out : (&mut out be_state.CompilerBackendAsmBuf)]
  [instr : mx.MachineInstr]) : unit
  (let
    [parts : mx.MachineAsmParts
      (mx.compiler-machine-x64-asm-parts
        (mx.compiler-machine-x64-checked instr))]
    (be_state.compiler-backend-asm-append5
      out
      parts.head
      parts.source
      ", "
      parts.destination
      "\n")))

(define (compiler-backend-machine-register [spelling : String]) : i64
  (compiler_abi.compiler-abi-register-id-from-spelling spelling))

(define (compiler-backend-state-slot-frame-cache-storage-ensure!
  [state : be_state.CompilerBackendState]) : unit
  (let
    [data : (MutPtr be_state.CompilerBackendStateData)
      (be_state.compiler-backend-state-ptr state)]
    (unsafe
      (if (and
        (=
          (array-length (deref data).slot-cache-values)
          compiler-backend-slot-cache-capacity)
        (=
          (array-length (deref data).slot-cache-epochs)
          compiler-backend-slot-cache-capacity)
        (=
          (array-length (deref data).frame-offset-cache-values)
          compiler-backend-slot-cache-capacity)
        (=
          (array-length (deref data).frame-offset-cache-epochs)
          compiler-backend-slot-cache-capacity))
        unit
        (let
          [owner : arena.Arena
            (be_state.compiler-backend-state-lazy-table-arena-ensure! state)]
          (in-arena
            owner
            (let
              [slot-values : (__tl_dyn-array String)
                (__tl_make-array String compiler-backend-slot-cache-capacity)]
              [slot-epochs : (__tl_dyn-array i64)
                (__tl_make-array i64 compiler-backend-slot-cache-capacity)]
              [frame-values : (__tl_dyn-array String)
                (__tl_make-array String compiler-backend-slot-cache-capacity)]
              [frame-epochs : (__tl_dyn-array i64)
                (__tl_make-array i64 compiler-backend-slot-cache-capacity)]
              (set! (deref data).slot-cache-values slot-values)
              (set! (deref data).slot-cache-epochs slot-epochs)
              (set! (deref data).frame-offset-cache-values frame-values)
              (set! (deref data).frame-offset-cache-epochs frame-epochs))))))))

(define (compiler-backend-state-immediate-cache-storage-ensure!
  [state : be_state.CompilerBackendState]) : unit
  (let
    [data : (MutPtr be_state.CompilerBackendStateData)
      (be_state.compiler-backend-state-ptr state)]
    (unsafe
      (if (and
        (= (array-length (deref data).immediate-cache-values) 8192)
        (= (array-length (deref data).immediate-cache-epochs) 8192))
        unit
        (let
          [owner : arena.Arena
            (be_state.compiler-backend-state-lazy-table-arena-ensure! state)]
          (in-arena
            owner
            (let
              [values : (__tl_dyn-array String) (__tl_make-array String 8192)]
              [epochs : (__tl_dyn-array i64) (__tl_make-array i64 8192)]
              (set! (deref data).immediate-cache-values values)
              (set! (deref data).immediate-cache-epochs epochs))))))))

(define (compiler-backend-slot-with-backend-state
  [state : be_state.CompilerBackendState]
  [var-id : i64]) : String
  (be_state.compiler-backend-function-state-set-bool!
    (be_state.compiler-backend-state-function-state state)
    be_state.compiler-backend-function-bool-frame-slot-referenced
    true)
  (be_state.compiler-backend-function-state-set-bool!
    (be_state.compiler-backend-state-function-state state)
    be_state.compiler-backend-function-bool-nonsave-frame-slot-referenced
    true)
  (if (and (>= var-id 0) (< var-id compiler-backend-slot-cache-capacity))
    (begin
      (compiler-backend-state-slot-frame-cache-storage-ensure! state)
      (unsafe
        (let
          [data : (Ptr be_state.CompilerBackendStateData)
            (be_state.compiler-backend-state-view state)]
          [epoch : i64 (deref data).slot-cache-epoch]
          [epochs : (__tl_dyn-array i64) (deref data).slot-cache-epochs]
          [values : (__tl_dyn-array String) (deref data).slot-cache-values]
          (if (= (array-ref epochs var-id) epoch)
            (owned_view.compiler-owned-element-view values var-id)
            (let
              [text : String
                (in-arena
                  (be_state.compiler-backend-state-lazy-table-arena-ensure!
                    state)
                  (str_cat.str-cat
                    (string.int->string (- 0 (* 8 (+ var-id 1))))
                    "(%rbp)"))]
              (set!
                (array-ref values var-id)
                (be_state.compiler-backend-global-shared-view text))
              (set! (array-ref epochs var-id) epoch)
              text)))))
    (str_cat.str-cat (string.int->string (- 0 (* 8 (+ var-id 1)))) "(%rbp)")))

;; The rendering alone. Both wrappers below record the reference first; nothing
;; else may call this, or the frame would be sized as if the slot were dead.
(define (compiler-backend-frame-offset-render
  [state : be_state.CompilerBackendState]
  [offset : i64]) : String
  (let
    [magnitude : i64 (- 0 offset)]
    (if (and
      (> magnitude 0)
      (= (% magnitude 8) 0)
      (<= magnitude (* 8 compiler-backend-slot-cache-capacity)))
      (let
        [idx : i64 (- (/ magnitude 8) 1)]
        (compiler-backend-state-slot-frame-cache-storage-ensure! state)
        (unsafe
          (let
            [data : (Ptr be_state.CompilerBackendStateData)
              (be_state.compiler-backend-state-view state)]
            [epoch : i64 (deref data).slot-cache-epoch]
            [epochs : (__tl_dyn-array i64)
              (deref data).frame-offset-cache-epochs]
            [values : (__tl_dyn-array String)
              (deref data).frame-offset-cache-values]
            (if (= (array-ref epochs idx) epoch)
              (owned_view.compiler-owned-element-view values idx)
              (let
                [text : String
                  (in-arena
                    (be_state.compiler-backend-state-lazy-table-arena-ensure!
                      state)
                    (str_cat.str-cat (string.int->string offset) "(%rbp)"))]
                (set!
                  (array-ref values idx)
                  (be_state.compiler-backend-global-shared-view text))
                (set! (array-ref epochs idx) epoch)
                text)))))
      (str_cat.str-cat (string.int->string offset) "(%rbp)"))))

(define (compiler-backend-frame-offset-with-backend-state
  [state : be_state.CompilerBackendState]
  [offset : i64]) : String
  (be_state.compiler-backend-function-state-set-bool!
    (be_state.compiler-backend-state-function-state state)
    be_state.compiler-backend-function-bool-frame-slot-referenced
    true)
  (be_state.compiler-backend-function-state-set-bool!
    (be_state.compiler-backend-state-function-state state)
    be_state.compiler-backend-function-bool-nonsave-frame-slot-referenced
    true)
  (compiler-backend-frame-offset-render state offset))

(define (compiler-backend-state-immediate-render
  [state : be_state.CompilerBackendState]
  [n : i64]) : String
  (if (and (>= n -4096) (< n 4096))
    (begin
      (compiler-backend-state-immediate-cache-storage-ensure! state)
      (unsafe
        (let
          [idx : i64 (+ n 4096)]
          [data : (Ptr be_state.CompilerBackendStateData)
            (be_state.compiler-backend-state-view state)]
          [epoch : i64 (deref data).slot-cache-epoch]
          [epochs : (__tl_dyn-array i64) (deref data).immediate-cache-epochs]
          [values : (__tl_dyn-array String) (deref data).immediate-cache-values]
          (if (= (array-ref epochs idx) epoch)
            (owned_view.compiler-owned-element-view values idx)
            (let
              [text : String
                (in-arena
                  (be_state.compiler-backend-state-lazy-table-arena-ensure!
                    state)
                  (str_cat.str-cat "$" (string.int->string n)))]
              (set!
                (array-ref values idx)
                (be_state.compiler-backend-global-shared-view text))
              (set! (array-ref epochs idx) epoch)
              text)))))
    (str_cat.str-cat "$" (string.int->string n))))

(define (compiler-backend-immediate-i64
  [state : be_state.CompilerBackendState]
  [n : i64]) : be_state.CompilerBackendMaybeImmediate
  (if (compiler-backend-imm32? n)
    (Some (compiler-backend-state-immediate-render state n))
    (No)))

(define (compiler-backend-immediate-operand
  [state : be_state.CompilerBackendState]
  [value : (& value compiler_ir_types.CompilerIrValue)]) : be_state.CompilerBackendMaybeImmediate
  (let
    [value : compiler_ir_types.CompilerIrValue
      (owned_view.compiler-owned-reference-shared-view value)]
    (match value
      [(I64 n) (compiler-backend-immediate-i64 state n)]
      [(Bool b)
        (if b
          (Some "$1")
          (Some "$0"))]
      [(Char c)
        (Some
          (compiler-backend-state-immediate-render
            state
            (be_state.compiler-backend-char-code c)))]
      [(Unit) (Some "$0")]
      [_ (No)])))

(define (compiler-backend-value-as-i64
  [value : (& value compiler_ir_types.CompilerIrValue)]) : option_i64.Option
  (let
    [value : compiler_ir_types.CompilerIrValue
      (owned_view.compiler-owned-reference-shared-view value)]
    (match value
      [(I64 n) (Some n)]
      [(Bool b)
        (if b
          (Some 1)
          (Some 0))]
      [(Char c) (Some (be_state.compiler-backend-char-code c))]
      [(Unit) (Some 0)]
      [_ (None)])))

(define (compiler-backend-asm-safe-symbol [name : String]) : String
  (let
    [i : i64 0]
    [n : i64 (string.string-length name)]
    [start : i64 0]
    [changed : bool false]
    [buf : (text_buf_borrowed.TextBufBorrowed name)
      (text_buf_borrowed.empty-like (& name))]
    (while (< i n)
      (let
        [c : char (string.string-ref name i)]
        (if (be_state.compiler-backend-symbol-safe-char? c)
          (+= i 1)
          (begin
            (set! changed true)
            (set!
              buf
              (be_state.compiler-backend-asm-safe-symbol-flush-run
                name
                start
                i
                buf))
            (set!
              buf
              (text_buf_borrowed.append-owned
                buf
                (be_state.compiler-backend-symbol-char name i c)))
            (+= i 1)
            (set! start i)))))
    (if changed
      (text_buf_borrowed.render
        (be_state.compiler-backend-asm-safe-symbol-flush-run name start n buf))
      name)))

;; The text after the last `/` or `:`. Found from the end, so only the leaf is
;; scanned rather than the whole qualified name.
(define (compiler-backend-symbol-leaf [name : (& name str)]) : String
  (let
    [n : i64 (string.string-length name)]
    [start : i64 n]
    (while (and
      (> start 0)
      (not (= (string.string-ref name (- start 1)) '/'))
      (not (= (string.string-ref name (- start 1)) ':')))
      (-= start 1))
    (string.substring name start (- n start))))

(define (compiler-backend-public-function-symbol? [name : (& name str)]) : bool
  (let
    [i : i64 0]
    [n : i64 (string.string-length name)]
    [found : bool false]
    (while (and (< i n) (not found))
      (if (= (string.string-ref name i) ':')
        (set! found true)
        unit)
      (+= i 1))
    found))

(define (compiler-backend-stdlib-runtime-function-name? [name : (& name str)]) : bool
  (or
    (compiler-backend-string-contains? name "stdlib/runtime.tl::")
    (compiler-backend-string-contains? name "stdlib\\runtime.tl::")
    (compiler-backend-string-contains? name "stdlib.runtime/")))

(define (compiler-backend-runtime-prelude-string-helper-symbol-for-leaf
  [leaf : String]) : String
  (cond
    [(string.eq leaf "int-to-string") "tl_int_to_string"]
    [(string.eq leaf "substring") "tl_substring"]
    [(string.eq leaf "str-view") "tl_str_view"]
    [(string.eq leaf "string-concat") "tl_string_concat"]
    [(string.eq leaf "string-concat3") "tl_string_concat3"]
    [(string.eq leaf "string-concat4") "tl_string_concat4"]
    [(string.eq leaf "string-concat5") "tl_string_concat5"]
    [(string.eq leaf "atomic-i64-load-ptr") "tl_atomic_i64_load_ptr"]
    [(string.eq leaf "atomic-i64-store-ptr!") "tl_atomic_i64_store_ptr"]
    [(string.eq leaf "atomic-i64-add-ptr!") "tl_atomic_i64_add_ptr"]
    [(string.eq leaf "atomic-i64-fetch-add-ptr!") "tl_atomic_i64_fetch_add_ptr"]
    [(string.eq leaf "atomic-i64-cas-ptr!") "tl_atomic_i64_cas_ptr"]
    [(string.eq leaf "atomic-i32-load-ptr") "tl_atomic_i32_load_ptr"]
    [(string.eq leaf "atomic-i32-store-ptr!") "tl_atomic_i32_store_ptr"]
    [(string.eq leaf "atomic-i32-add-ptr!") "tl_atomic_i32_add_ptr"]
    [(string.eq leaf "atomic-i32-fetch-add-ptr!") "tl_atomic_i32_fetch_add_ptr"]
    [(string.eq leaf "atomic-i32-cas-ptr!") "tl_atomic_i32_cas_ptr"]
    [else ""]))

(define (compiler-backend-runtime-prelude-string-helper-symbol [name : String]) : String
  (let
    [symbol : String
      (compiler-backend-runtime-prelude-string-helper-symbol-for-leaf
        (compiler-backend-symbol-leaf name))]
    (if (and
      (not (string.eq symbol ""))
      (compiler-backend-stdlib-runtime-function-name? name))
      symbol
      "")))

(define (compiler-backend-compact-function-symbol? [name : (& name str)]) : bool
  (and
    (> (string.string-length name) 16)
    (not (string.eq name "main"))
    (not (compiler-backend-string-prefix-at? name "__global_init_" 0))
    (not (compiler-backend-string-prefix-at? name "__tl_spmd_pkg_" 0))
    (not
      (compiler-backend-string-prefix-at?
        name
        "__tl_spmd_ret_uniform___tl_spmd_pkg_"
        0))
    (not
      (compiler-backend-string-prefix-at?
        name
        "__tl_spmd_ret_varying___tl_spmd_pkg_"
        0))
    (not
      (compiler-backend-string-prefix-at?
        name
        "__tl_spmd_ret_mask___tl_spmd_pkg_"
        0))
    (not (compiler-backend-public-function-symbol? name))))

(define (compiler-backend-function-symbol-index
  [index : be_state.CompilerBackendProgramIndex]
  [name : i64]) : String
  (if (compiler-backend-index-extern-provided? index name)
    (if (and
      (be_state.compiler-backend-state-emission-target-policy
        index.backend-state).windows
      (compiler-backend-index-c-export? index name))
      (compiler_abi.compiler-abi-internal-link-symbol
        (be_state.compiler-backend-state-emission-target-policy
          index.backend-state).abi
        (compiler_abi.compiler-abi-c-export-body-symbol
          (compiler-backend-index-extern-link-symbol index name)))
      (compiler-backend-index-extern-link-symbol index name))
    (let
      [name-text : String
        (be_state.compiler-backend-symbol-text-index index name)]
      [runtime-symbol : String
        (compiler-backend-runtime-prelude-string-helper-symbol name-text)]
      (if (not (string.eq runtime-symbol ""))
        runtime-symbol
        (match (compiler-backend-index-function-slot index name)
          [(LookupFound slot)
            (let
              [tables : (& index be_state.CompilerBackendProgramTables)
                (be_state.compiler-backend-program-tables index)]
              [indexed-name : String
                (be_state.compiler-backend-global-array-element-shared-view
                  tables.function-names
                  slot)]
              (if (compiler-backend-compact-function-symbol? indexed-name)
                (str_cat.str-cat "_tl_f" (string.int->string slot) "")
                (be_state.compiler-backend-state-user-symbol-id
                  index.backend-state
                  name)))]
          [(LookupMissing)
            (be_state.compiler-backend-state-user-symbol-id
              index.backend-state
              name)])))))

(define (compiler-backend-closure-descriptor-label [name : String]) : String
  (str_cat.str-cat ".L_tl_fn_desc_" (compiler-backend-asm-safe-symbol name)))

(define (compiler-backend-fixed-fault-symbol-id?
  [backend-state : be_state.CompilerBackendState]
  [name-id : i64]) : bool
  (or
    (cbi.compiler-builtin-backend-fixed-fault-id? name-id)
    (let
      [name : String
        (be_state.compiler-backend-symbol-text-state backend-state name-id)]
      (or
        (string.eq name "tl_memcpy")
        (string.eq name "tl_memcpy_fresh")
        (string.eq name "tl_memchr")
        (string.eq name "tl_array_zero")
        (string.eq name "tl_mem_fill8")
        (string.eq name "tl_mem_copy_fwd")
        (string.eq name "tl_mem_copy8_fwd")
        (string.eq name "tl_abort_string")
        (string.eq name "tl_arena_sanitize_enable")
        (string.eq name "tl_tlci_call_image_entry")
        (string.eq name "tl_tlci_call_macro_entry")))))

(define (compiler-backend-call-raw-symbol-id?
  [plan : be_state.CompilerBackendRuntimePlan]
  [backend-state : be_state.CompilerBackendState]
  [name-id : i64]) : bool
  (or
    (compiler-backend-plan-provides-id? plan name-id)
    (compiler-backend-fixed-fault-symbol-id? backend-state name-id)))

(define (compiler-backend-link-symbol-id
  [name-id : i64]
  [plan : be_state.CompilerBackendRuntimePlan]
  [backend-state : be_state.CompilerBackendState]
  [c-abi? : bool]) : String
  ;; Resolve the reserved package-body identity before linking. C ABI names
  ;; retain their raw-symbol/encoding policy and never take this mapping.
  (if (not c-abi?)
    (compiler_abi.compiler-abi-internal-link-symbol
      (be_state.compiler-backend-state-emission-target-policy backend-state).abi
      (be_state.compiler-backend-symbol-text-state backend-state name-id))
    (if (compiler-backend-call-raw-symbol-id? plan backend-state name-id)
      (be_state.compiler-backend-symbol-text-state backend-state name-id)
      (compiler-backend-asm-safe-symbol
        (be_state.compiler-backend-symbol-text-state backend-state name-id)))))

(define (compiler-backend-call-symbol-index
  [name : i64]
  [plan : be_state.CompilerBackendRuntimePlan]
  [index : be_state.CompilerBackendProgramIndex]) : String
  (let
    [name-text : String
      (be_state.compiler-backend-symbol-text-index index name)]
    (cond
      [(compiler-backend-index-extern-provided? index name)
        (compiler-backend-function-symbol-index index name)]
      [(compiler-backend-index-extern-references? index name)
        (let
          [link-symbol-id : i64
            (compiler-backend-index-extern-link-symbol-id index name)]
          (if (and
            (= link-symbol-id name)
            (compiler-backend-call-raw-symbol-id? plan index.backend-state name)
            (not (compiler-backend-index-function-defines? index name)))
            name-text
            (compiler-backend-link-symbol-id
              link-symbol-id
              plan
              index.backend-state
              (compiler-backend-extern-call-info-c-abi?
                (compiler-backend-index-extern-call-info index name)))))]
      [(and
          (compiler-backend-call-raw-symbol-id? plan index.backend-state name)
          (not (compiler-backend-index-function-defines? index name)))
        name-text]
      [else (compiler-backend-function-symbol-index index name)])))

(define (compiler-backend-type-size
  [type-segment-bases : i64]
  [ty : (& ty compiler_ast_types.AstType)]) : i64
  (let
    [ty : compiler_ast_types.AstType
      (owned_view.compiler-owned-reference-shared-view ty)]
    (match ty
      [(or (I32) (U32) (F32)) 4]
      [(or (I16) (U16)) 2]
      [(or (I8) (U8) (Bool) (Char)) 1]
      ;; A bare slice has no runtime value layout.
      [(or (Unit) (Never) (Expr) (ExprList) (Slice _)) 0]
      [(or (Ref _ inner) (MutRef _ inner))
        (if (compiler_ast_types.ast-type-segment-bases-fat-referent?
          type-segment-bases
          inner)
          16
          8)]
      [(or (Region _ inner) (Invalidate _ inner))
        (let
          [ty
            (compiler_ast_types.ast-type-segment-bases-get
              type-segment-bases
              inner)]
          (compiler-backend-type-size type-segment-bases ty))]
      [(or (I64) (U64) (F64) (CFunc _ _) (Func _ _) (Tuple _) (Array _ _)
           (DynArray _) (Box _) (Ptr _) (MutPtr _) (Enum _) (EnumArgs _ _)
           (Struct _) (StructArgs _ _) (String) (Str) (Bytes) (Var _)
           (VarArgs _ _))
        8])))

(define (compiler-backend-intlike-scalar-type?
  [ty : (& ty compiler_ast_types.AstType)]) : bool
  (match ty
    [(or (I64) (U64) (I32) (U32) (I16) (U16) (I8) (U8) (Bool) (Char)) true]
    [_ false]))

(define (compiler-backend-string-label-suffix [text : (& text str)]) : String
  (let
    [n : i64 (string.string-length text)]
    (if (= n 0)
      "empty"
      (str_cat.str-cat
        "l"
        (string.int->string n)
        "_"
        (string.int->string (compiler-backend-string-label-forward-hash text))
        (str_cat.str-cat
          "_"
          (string.int->string (compiler-backend-string-label-reverse-hash text)))))))

(define (compiler-backend-string-label-forward-hash [key : (& key str)]) : i64
  (hash.string-key (& key)))

(define (compiler-backend-string-label-reverse-hash [text : (& text str)]) : i64
  (let
    [i : i64 (- (string.string-length text) 1)]
    [hash : i64 0]
    (while (>= i 0)
      (let
        [next : i64
          (+
            (+
              (* hash 131)
              (be_state.compiler-backend-char-code (string.string-ref text i)))
            1)]
        [reduced : i64 (+ (bit-and next 0x7fffffff) (shr next 31))]
        (set!
          hash
          (if (>= reduced 0x7fffffff)
            (- reduced 0x7fffffff)
            reduced))
        (-= i 1)))
    hash))

(define (compiler-backend-string-fat-label [text : (& text str)]) : String
  (str_cat.str-cat ".L_tl_str_" (compiler-backend-string-label-suffix text)))

(define (compiler-backend-bytes-fat-label [text : (& text str)]) : String
  (str_cat.str-cat ".L_tl_bin_" (compiler-backend-string-label-suffix text)))

(define (compiler-backend-float-label
  [ty : (& ty compiler_ast_types.AstType)]
  [bits : u64]) : String
  (str_cat.str-cat
    ".L_tl_"
    (match ty
      [(F32) "f32_"]
      [_ "f64_"])
    (compiler-backend-string-label-suffix
      (be_state.compiler-backend-float-key ty bits))))

(define (compiler-backend-emit-load-float-value
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : (& compiler_ir_types.CompilerIrValue)]
  [ty : (& ty compiler_ast_types.AstType)]
  [reg : String]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [ty : compiler_ast_types.AstType
      (owned_view.compiler-owned-reference-shared-view ty)]
    [mov : String (compiler-backend-float-move ty)]
    (match value
      [(Var id)
        (Ok
          (compiler-backend-emit-load-float-var
            assignments
            id
            ty
            reg
            backend-state))]
      [(Global name)
        (Ok
          (str_cat.str-cat
            "    "
            mov
            " "
            (compiler-backend-state-global-symbol-id backend-state name)
            "(%rip), "
            reg
            "\n"))]
      [(F64 bits)
        (if (be_state.compiler-backend-f64-type? ty)
          (Ok
            (str_cat.str-cat
              "    movsd "
              (compiler-backend-float-label ty bits)
              "(%rip), "
              reg
              "\n"))
          (Ok
            (str_cat.str-cat
              "    movss "
              (compiler-backend-float-label ty bits)
              "(%rip), "
              reg
              "\n")))]
      [_
        (Err
          (box
            (compiler_diagnostic.compiler-diagnostic-at-start
              ""
              (str_cat.str-cat
                "backend: expected "
                (compiler-backend-float-type-name ty)
                " value"))))])))

;; A 32-bit destination zero-extends the full unsigned imm32 range. Negative
;; signed imm32 values use the sign-extending 64-bit form.
(define (compiler-backend-emit-load-i64-immediate-into
  [out : (&mut out be_state.CompilerBackendAsmBuf)]
  [n : i64]
  [reg : String]) : unit
  (if (= n 0)
    (let
      [reg32 : String (compiler-backend-reg-part reg 4)]
      (be_state.compiler-backend-asm-append5
        out
        "    xorl "
        (be_state.compiler-backend-global-shared-view reg32)
        ", "
        reg32
        "\n"))
    (if (and (>= n (- 0 2147483648)) (<= n 4294967295))
      ;; `movl` zero-extends a positive imm32, `movq` sign-extends a negative.
      (compiler-backend-asm-append-machine!
        out
        (mx.MachineInstr.MovRI
          (if (> n 0)
            (W32)
            (W64))
          (compiler-backend-machine-register reg)
          n))
      (be_state.compiler-backend-asm-append5
        out
        "    movq $"
        (string.int->string n)
        ", "
        reg
        "\n"))))

(define (compiler-backend-emit-load-value-into
  [out : (&mut out be_state.CompilerBackendAsmBuf)]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : (& compiler_ir_types.CompilerIrValue)]
  [reg : String]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (match value
    [(Var id)
      (compiler-backend-emit-load-var-into out assignments id reg backend-state)
      (Ok "")]
    [(Global name)
      (be_state.compiler-backend-asm-append5
        out
        ;; IAG-1: an inline aggregate global's cell IS the aggregate, so the
        ;; value of `Global g` -- "the address of the struct" -- is the
        ;; symbol's own link-time constant address, not a load of the cell.
        (if (be_state.compiler-backend-inline-aggregate-global?
          backend-state
          name)
          "    leaq "
          "    movq ")
        (compiler-backend-state-global-symbol-id backend-state name)
        "(%rip), "
        reg
        "\n")
      (Ok "")]
    [(GlobalAddr name)
      (be_state.compiler-backend-asm-append5
        out
        "    leaq "
        (compiler-backend-state-global-symbol-id backend-state name)
        "(%rip), "
        reg
        "\n")
      (Ok "")]
    [(Function name)
      (be_state.compiler-backend-asm-append5
        out
        "    leaq "
        (compiler-backend-closure-descriptor-label
          (be_state.compiler-backend-symbol-text-state backend-state name))
        "(%rip), "
        reg
        "\n")
      (Ok "")]
    [(I64 n)
      (compiler-backend-emit-load-i64-immediate-into out n reg)
      (Ok "")]
    [(Bool b)
      (compiler-backend-emit-load-i64-immediate-into
        out
        (if b
          1
          0)
        reg)
      (Ok "")]
    [(Char c)
      (compiler-backend-emit-load-i64-immediate-into
        out
        (be_state.compiler-backend-char-code c)
        reg)
      (Ok "")]
    [(Unit)
      (compiler-backend-emit-load-i64-immediate-into out 0 reg)
      (Ok "")]
    [(F64 _)
      (Err
        (box
          (compiler_diagnostic.compiler-diagnostic-at-start
            ""
            "backend: f64 values are not supported yet")))]
    [(String text)
      (be_state.compiler-backend-asm-append5
        out
        "    leaq "
        (compiler-backend-string-fat-label text)
        "(%rip), "
        reg
        "\n")
      (Ok "")]
    [(Bytes text)
      (be_state.compiler-backend-asm-append5
        out
        "    leaq "
        (compiler-backend-bytes-fat-label text)
        "(%rip), "
        reg
        "\n")
      (Ok "")]
    ;; `RuntimeGlobal` and `StaticArray` only initialize globals.
    [_
      (Err
        (box
          (compiler_diagnostic.compiler-diagnostic-at-start
            ""
            "backend: global initializer marker used as an instruction value")))]))

;; String-returning shim for the emitters that still hand their text back to a
;; caller instead of appending. One scalar load is one line, so the line buffer
;; is sized for it and `finish` publishes it with no copy: a single allocation.
(define (compiler-backend-emit-load-value
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : (& compiler_ir_types.CompilerIrValue)]
  [reg : String]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [line : be_state.CompilerBackendAsmBuf
      (be_state.compiler-backend-asm-buf-with-capacity
        be_state.compiler-backend-asm-line-capacity)]
    [_
      (try
        (compiler-backend-emit-load-value-into
          (&mut line)
          assignments
          value
          reg
          backend-state))]
    (Ok (be_state.compiler-backend-asm-buf-finish (& line)))))

(define (compiler-backend-reg-part-by-size
  [reg64 : String]
  [reg32 : String]
  [reg16 : String]
  [reg8 : String]
  [size : i64]) : String
  (cond
    [(= size 8) reg64]
    [(= size 4) reg32]
    [(= size 2) reg16]
    [(= size 1) reg8]
    [else
      (io.panic
        (str_cat.str-cat
          "backend: unsupported register part size "
          (string.int->string size)))]))

(define (compiler-backend-reg-part [reg : String] [size : i64]) : String
  (cond
    [(string.eq reg "%rax")
      (compiler-backend-reg-part-by-size reg "%eax" "%ax" "%al" size)]
    [(string.eq reg "%rbx")
      (compiler-backend-reg-part-by-size reg "%ebx" "%bx" "%bl" size)]
    [(string.eq reg "%rcx")
      (compiler-backend-reg-part-by-size reg "%ecx" "%cx" "%cl" size)]
    [(string.eq reg "%rdx")
      (compiler-backend-reg-part-by-size reg "%edx" "%dx" "%dl" size)]
    [(string.eq reg "%rdi")
      (compiler-backend-reg-part-by-size reg "%edi" "%di" "%dil" size)]
    [(string.eq reg "%rsi")
      (compiler-backend-reg-part-by-size reg "%esi" "%si" "%sil" size)]
    [(string.eq reg "%r12")
      (compiler-backend-reg-part-by-size reg "%r12d" "%r12w" "%r12b" size)]
    [(string.eq reg "%r13")
      (compiler-backend-reg-part-by-size reg "%r13d" "%r13w" "%r13b" size)]
    [(string.eq reg "%r14")
      (compiler-backend-reg-part-by-size reg "%r14d" "%r14w" "%r14b" size)]
    [(string.eq reg "%r15")
      (compiler-backend-reg-part-by-size reg "%r15d" "%r15w" "%r15b" size)]
    [(string.eq reg "%r8")
      (compiler-backend-reg-part-by-size reg "%r8d" "%r8w" "%r8b" size)]
    [(string.eq reg "%r9")
      (compiler-backend-reg-part-by-size reg "%r9d" "%r9w" "%r9b" size)]
    [(string.eq reg "%r10")
      (compiler-backend-reg-part-by-size reg "%r10d" "%r10w" "%r10b" size)]
    [(string.eq reg "%r11")
      (compiler-backend-reg-part-by-size reg "%r11d" "%r11w" "%r11b" size)]
    ;; M-G3 stage 2: %rbp is a pool register in FPO functions; without this arm
    ;; the else-fallback would silently substitute %r15 parts (miscompile).
    [(string.eq reg "%rbp")
      (compiler-backend-reg-part-by-size reg "%ebp" "%bp" "%bpl" size)]
    [else
      (io.panic (str_cat.str-cat "backend: unsupported register part " reg))]))

(define (compiler-backend-avx2-vector-reduce-move-scalar
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]
  [xmm-reg : String]
  [gp-reg : String]) : String
  (match elem-ty
    [(or (I32) (U32))
      (str_cat.str-cat
        "    vmovd "
        xmm-reg
        ", "
        (compiler-backend-reg-part gp-reg 4)
        "\n")]
    [(F64) ""]
    [_ (str_cat.str-cat "    vmovq " xmm-reg ", " gp-reg "\n")]))

(define (compiler-backend-i64-u64-type?
  [ty : (& ty compiler_ast_types.AstType)]) : bool
  (match ty
    [(or (I64) (U64)) true]
    [_ false]))

(define (compiler-backend-emit-vmovq-xmm-to-var
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [var-id : i64]
  [xmm-reg : String]
  [backend-state : be_state.CompilerBackendState]) : String
  (match (compiler-backend-emit-assignment-lookup
    backend-state
    assignments
    var-id)
    [(Some location)
      (match location
        [(or (Register home) (RegisterPair home _))
          (str_cat.str-cat
            "    vmovq "
            xmm-reg
            ", "
            (compiler_abi.compiler-abi-register-spelling home)
            "\n")]
        [(Spill offset)
          (str_cat.str-cat
            "    vmovq "
            xmm-reg
            ", "
            (compiler-backend-frame-offset-with-backend-state
              backend-state
              offset)
            "\n")]
        ;; Rematerialised values are static scalar/address defs, never vector
        ;; reduction destinations.
        [(Remat _) ""])]
    [(No)
      (str_cat.str-cat
        "    vmovq "
        xmm-reg
        ", "
        (compiler-backend-slot-with-backend-state backend-state var-id)
        "\n")]))

(define (compiler-backend-vector-reduce-store-scalar
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [elem-ty : compiler_ast_types.AstType]
  [xmm-reg : String]
  [backend-state : be_state.CompilerBackendState]) : String
  (if (compiler-backend-i64-u64-type? elem-ty)
    (compiler-backend-emit-vmovq-xmm-to-var
      assignments
      dst
      xmm-reg
      backend-state)
    (if (compiler-backend-float-type? elem-ty)
      (compiler-backend-emit-store-typed-var
        assignments
        dst
        xmm-reg
        elem-ty
        backend-state)
      (let
        [no-exclude : (__tl_dyn-array String) (__tl_make-array String 0)]
        [gp-reg : String
          (compiler-backend-scavenge-reg dst no-exclude 0 "%r8" backend-state)]
        (str_cat.str-cat
          (compiler-backend-avx2-vector-reduce-move-scalar
            elem-ty
            xmm-reg
            (be_state.compiler-backend-global-shared-view gp-reg))
          (compiler-backend-emit-store-typed-var
            assignments
            dst
            gp-reg
            elem-ty
            backend-state))))))

(define (compiler-backend-avx2-vector-reduce-horizontal-asm
  [op : compiler_ir_types.CompilerIrVectorReduceOp]
  [mnemonic : String]
  [ymm : String]
  [xmm : String]
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]
  [acc-xmm : String]
  [scratch-xmm : String]
  [mask-xmm : String]) : String
  (match elem-ty
    [(F32)
      (str_cat.str-cat
        (str_cat.str-cat
          "    vextractf128 $1, "
          ymm
          ", "
          acc-xmm
          "\n    "
          mnemonic
          " "
          acc-xmm
          ", "
          xmm
          ", "
          acc-xmm
          "\n")
        (str_cat.str-cat
          "    vshufps $78, "
          acc-xmm
          ", "
          acc-xmm
          ", "
          scratch-xmm
          "\n    "
          mnemonic
          " "
          scratch-xmm
          ", "
          acc-xmm
          ", "
          acc-xmm
          "\n"
          "")
        (str_cat.str-cat
          "    vshufps $177, "
          acc-xmm
          ", "
          acc-xmm
          ", "
          scratch-xmm
          "\n    vaddss "
          scratch-xmm
          ", "
          acc-xmm
          ", "
          acc-xmm
          "\n"))]
    [(F64)
      (str_cat.str-cat
        (str_cat.str-cat
          "    vextractf128 $1, "
          ymm
          ", "
          acc-xmm
          "\n    "
          mnemonic
          " "
          acc-xmm
          ", "
          xmm
          ", "
          acc-xmm
          "\n")
        (str_cat.str-cat
          "    vunpckhpd "
          acc-xmm
          ", "
          acc-xmm
          ", "
          scratch-xmm
          "\n    vaddsd "
          scratch-xmm
          ", "
          acc-xmm
          ", "
          acc-xmm
          "\n"))]
    [(I64)
      (match op
        [(Sum)
          (str_cat.str-cat
            (str_cat.str-cat
              "    vextracti128 $1, "
              ymm
              ", "
              acc-xmm
              "\n    "
              mnemonic
              " "
              acc-xmm
              ", "
              xmm
              ", "
              acc-xmm
              "\n")
            (str_cat.str-cat
              "    vpsrldq $8, "
              acc-xmm
              ", "
              scratch-xmm
              "\n    "
              mnemonic
              " "
              scratch-xmm
              ", "
              acc-xmm
              ", "
              acc-xmm
              "\n"
              ""))]
        [_
          (let
            [high-compare-left : String
              (match op
                [(Min) (owned_view.compiler-owned-shared-view acc-xmm)]
                [_ (owned_view.compiler-owned-shared-view xmm)])]
            [high-compare-right : String
              (match op
                [(Min) (owned_view.compiler-owned-shared-view xmm)]
                [_ (owned_view.compiler-owned-shared-view acc-xmm)])]
            [lane-compare-left : String
              (match op
                [(Min) (owned_view.compiler-owned-shared-view scratch-xmm)]
                [_ (owned_view.compiler-owned-shared-view acc-xmm)])]
            [lane-compare-right : String
              (match op
                [(Min) (owned_view.compiler-owned-shared-view acc-xmm)]
                [_ (owned_view.compiler-owned-shared-view scratch-xmm)])]
            (str_cat.str-cat
              "    vextracti128 $1, "
              ymm
              ", "
              acc-xmm
              "\n    vpcmpgtq "
              high-compare-left
              ", "
              high-compare-right
              ", "
              scratch-xmm
              "\n    vpblendvb "
              scratch-xmm
              ", "
              acc-xmm
              ", "
              xmm
              ", "
              acc-xmm
              "\n    vpsrldq $8, "
              acc-xmm
              ", "
              scratch-xmm
              "\n    vpcmpgtq "
              lane-compare-left
              ", "
              lane-compare-right
              ", "
              mask-xmm
              "\n    vpblendvb "
              mask-xmm
              ", "
              scratch-xmm
              ", "
              acc-xmm
              ", "
              acc-xmm
              "\n"
              ""))])]
    [(I32)
      (str_cat.str-cat
        (str_cat.str-cat
          "    vextracti128 $1, "
          ymm
          ", "
          acc-xmm
          "\n    "
          mnemonic
          " "
          acc-xmm
          ", "
          xmm
          ", "
          acc-xmm
          "\n")
        (str_cat.str-cat
          "    vpsrldq $8, "
          acc-xmm
          ", "
          scratch-xmm
          "\n    "
          mnemonic
          " "
          scratch-xmm
          ", "
          acc-xmm
          ", "
          acc-xmm
          "\n"
          "")
        (str_cat.str-cat
          "    vpsrldq $4, "
          acc-xmm
          ", "
          scratch-xmm
          "\n    "
          mnemonic
          " "
          scratch-xmm
          ", "
          acc-xmm
          ", "
          acc-xmm
          "\n"
          ""))]
    [_ ""]))

(define (compiler-backend-avx512-vector-reduce-horizontal-asm
  [mnemonic : String]
  [zmm : String]
  [ymm : String]
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]
  [acc-xmm : (& acc-xmm str)]
  [acc-ymm : String]
  [scratch-xmm : String]) : String
  (match elem-ty
    [(F32)
      (str_cat.str-cat
        (str_cat.str-cat
          "    vextractf32x8 $1, "
          zmm
          ", "
          acc-ymm
          "\n    "
          mnemonic
          " "
          acc-ymm
          ", "
          ymm
          ", "
          acc-ymm
          "\n")
        (str_cat.str-cat
          "    vextractf128 $1, "
          acc-ymm
          ", "
          scratch-xmm
          "\n    "
          mnemonic
          " "
          scratch-xmm
          ", "
          acc-xmm
          ", "
          acc-xmm
          "\n"
          "")
        (str_cat.str-cat
          "    vshufps $78, "
          acc-xmm
          ", "
          acc-xmm
          ", "
          scratch-xmm
          "\n    "
          mnemonic
          " "
          scratch-xmm
          ", "
          acc-xmm
          ", "
          acc-xmm
          "\n"
          "")
        (str_cat.str-cat
          "    vshufps $177, "
          acc-xmm
          ", "
          acc-xmm
          ", "
          scratch-xmm
          "\n    vaddss "
          scratch-xmm
          ", "
          acc-xmm
          ", "
          acc-xmm
          "\n"))]
    [(F64)
      (str_cat.str-cat
        (str_cat.str-cat
          "    vextractf64x4 $1, "
          zmm
          ", "
          acc-ymm
          "\n    "
          mnemonic
          " "
          acc-ymm
          ", "
          ymm
          ", "
          acc-ymm
          "\n")
        (str_cat.str-cat
          "    vextractf128 $1, "
          acc-ymm
          ", "
          scratch-xmm
          "\n    "
          mnemonic
          " "
          scratch-xmm
          ", "
          acc-xmm
          ", "
          acc-xmm
          "\n"
          "")
        (str_cat.str-cat
          "    vunpckhpd "
          acc-xmm
          ", "
          acc-xmm
          ", "
          scratch-xmm
          "\n    vaddsd "
          scratch-xmm
          ", "
          acc-xmm
          ", "
          acc-xmm
          "\n"))]
    [(I64)
      (str_cat.str-cat
        (str_cat.str-cat
          "    vextracti64x4 $1, "
          zmm
          ", "
          acc-ymm
          "\n    "
          mnemonic
          " "
          acc-ymm
          ", "
          ymm
          ", "
          acc-ymm
          "\n")
        (str_cat.str-cat
          "    vextracti128 $1, "
          acc-ymm
          ", "
          scratch-xmm
          "\n    "
          mnemonic
          " "
          scratch-xmm
          ", "
          acc-xmm
          ", "
          acc-xmm
          "\n"
          "")
        (str_cat.str-cat
          "    vpsrldq $8, "
          acc-xmm
          ", "
          scratch-xmm
          "\n    "
          mnemonic
          " "
          scratch-xmm
          ", "
          acc-xmm
          ", "
          acc-xmm
          "\n"
          ""))]
    [(I32)
      (str_cat.str-cat
        (str_cat.str-cat
          "    vextracti64x4 $1, "
          zmm
          ", "
          acc-ymm
          "\n    "
          mnemonic
          " "
          acc-ymm
          ", "
          ymm
          ", "
          acc-ymm
          "\n")
        (str_cat.str-cat
          "    vextracti128 $1, "
          acc-ymm
          ", "
          scratch-xmm
          "\n    "
          mnemonic
          " "
          scratch-xmm
          ", "
          acc-xmm
          ", "
          acc-xmm
          "\n"
          "")
        (str_cat.str-cat
          "    vpsrldq $8, "
          acc-xmm
          ", "
          scratch-xmm
          "\n    "
          mnemonic
          " "
          scratch-xmm
          ", "
          acc-xmm
          ", "
          acc-xmm
          "\n"
          "")
        (str_cat.str-cat
          "    vpsrldq $4, "
          acc-xmm
          ", "
          scratch-xmm
          "\n    "
          mnemonic
          " "
          scratch-xmm
          ", "
          acc-xmm
          ", "
          acc-xmm
          "\n"
          ""))]
    [(or (I16) (U16) (I8) (U8))
      (compiler-backend-avx512-vector-reduce-narrow-horizontal-asm
        mnemonic
        zmm
        ymm
        elem-ty
        acc-xmm
        acc-ymm
        scratch-xmm)]
    [_ ""]))

(define (compiler-backend-emit-avx2-vector-reduce
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [op : compiler_ir_types.CompilerIrVectorReduceOp]
  [src : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (compiler-backend-avx2-shape-ok? elem-ty lanes)
    (let
      [mnemonic : String
        (compiler-backend-avx2-vector-reduce-op-mnemonic op elem-ty)]
      (if (and
        (= (string.string-length mnemonic) 0)
        (not
          (and
            (match (& elem-ty)
              [(I64) true]
              [_ false])
            (match op
              [(or (Min) (Max)) true]
              [_ false]))))
        (be_state.compiler-backend-instr-error
          instr-diag
          "backend: unsupported AVX2 vector reduction")
        (match (compiler-backend-vector-register-use
          assignments
          src
          "reduce source"
          "ymm"
          elem-ty
          (compiler-backend-vector-spill-scratch "ymm" 0)
          backend-state)
          [(Ok src-use)
            (match src-use
              [(Use src-asm ymm)
                (let
                  [xmm : String
                    (compiler-backend-vector-reg-lower-xmm
                      (be_state.compiler-backend-global-shared-view ymm))]
                  [acc-xmm : String
                    (compiler-backend-scavenge-xmm-reg
                      dst
                      (compiler-backend-three-exclude
                        (be_state.compiler-backend-global-shared-view xmm)
                        ""
                        "")
                      3
                      "%xmm2"
                      backend-state)]
                  [scratch-xmm : String
                    (compiler-backend-scavenge-xmm-reg
                      dst
                      (compiler-backend-three-exclude
                        (be_state.compiler-backend-global-shared-view xmm)
                        ""
                        (be_state.compiler-backend-global-shared-view acc-xmm))
                      3
                      "%xmm3"
                      backend-state)]
                  [mask-xmm : String
                    (if (compiler_regalloc.compiler-reg-vector-reduce-mask-scratch?
                      op
                      lanes
                      (& elem-ty))
                      (compiler-backend-scavenge-xmm-reg
                        dst
                        (compiler-backend-three-exclude
                          (be_state.compiler-backend-global-shared-view xmm)
                          (be_state.compiler-backend-global-shared-view acc-xmm)
                          (be_state.compiler-backend-global-shared-view
                            scratch-xmm))
                        3
                        "%xmm4"
                        backend-state)
                      "")]
                  (if (= (string.string-length xmm) 0)
                    (be_state.compiler-backend-instr-error
                      instr-diag
                      (compiler-backend-vector-home-unavailable "reduce source"))
                    (Ok
                      (str_cat.str-cat
                        src-asm
                        (compiler-backend-avx2-vector-reduce-horizontal-asm
                          op
                          mnemonic
                          ymm
                          xmm
                          elem-ty
                          (be_state.compiler-backend-global-shared-view acc-xmm)
                          scratch-xmm
                          mask-xmm)
                        (compiler-backend-vector-reduce-store-scalar
                          assignments
                          dst
                          (be_state.compiler-backend-global-shared-view elem-ty)
                          acc-xmm
                          backend-state)))))])]
          [(Err message)
            (be_state.compiler-backend-instr-error instr-diag message)])))
    (compiler-backend-avx2-shape-diagnostic
      type-segment-bases
      instr-diag
      elem-ty
      lanes)))

(define (compiler-backend-vector-reduce-byte-shift-asm
  [mnemonic : (& mnemonic str)]
  [bytes : i64]
  [acc-xmm : (& acc-xmm str)]
  [scratch-xmm : (& scratch-xmm str)]) : String
  (str_cat.str-cat
    "    vpsrldq $"
    (string.int->string bytes)
    ", "
    acc-xmm
    ", "
    scratch-xmm
    "\n    "
    mnemonic
    " "
    scratch-xmm
    ", "
    acc-xmm
    ", "
    acc-xmm
    "\n"))

(define (compiler-backend-avx512-vector-reduce-narrow-horizontal-asm
  [mnemonic : String]
  [zmm : String]
  [ymm : String]
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]
  [acc-xmm : (& acc-xmm str)]
  [acc-ymm : (& acc-ymm str)]
  [scratch-xmm : (& scratch-xmm str)]) : String
  (str_cat.str-cat
    "    vextracti64x4 $1, "
    zmm
    ", "
    acc-ymm
    "\n    "
    mnemonic
    " "
    acc-ymm
    ", "
    ymm
    ", "
    acc-ymm
    "\n    vextracti128 $1, "
    acc-ymm
    ", "
    scratch-xmm
    "\n    "
    mnemonic
    " "
    scratch-xmm
    ", "
    acc-xmm
    ", "
    acc-xmm
    "\n"
    (compiler-backend-vector-reduce-byte-shift-asm
      mnemonic
      8
      acc-xmm
      scratch-xmm)
    (compiler-backend-vector-reduce-byte-shift-asm
      mnemonic
      4
      acc-xmm
      scratch-xmm)
    (compiler-backend-vector-reduce-byte-shift-asm
      mnemonic
      2
      acc-xmm
      scratch-xmm)
    (match elem-ty
      [(or (I8) (U8))
        (compiler-backend-vector-reduce-byte-shift-asm
          mnemonic
          1
          acc-xmm
          scratch-xmm)]
      [_ ""])))

(define (compiler-backend-emit-avx512-vector-reduce
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [op : compiler_ir_types.CompilerIrVectorReduceOp]
  [src : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (compiler-backend-avx512-shape-ok? elem-ty lanes)
    (let
      [mnemonic : String
        (compiler-backend-avx512-vector-reduce-op-mnemonic op elem-ty)]
      (if (= (string.string-length mnemonic) 0)
        (be_state.compiler-backend-instr-error
          instr-diag
          "backend: unsupported AVX-512 vector reduction")
        (match (compiler-backend-vector-register-use
          assignments
          src
          "reduce source"
          "zmm"
          elem-ty
          (compiler-backend-vector-spill-scratch "zmm" 0)
          backend-state)
          [(Ok src-use)
            (match src-use
              [(Use src-asm zmm)
                (let
                  [ymm : String
                    (compiler-backend-vector-reg-lower-ymm
                      (be_state.compiler-backend-global-shared-view zmm))]
                  [acc-xmm : String
                    (compiler-backend-scavenge-xmm-reg
                      dst
                      (compiler-backend-one-exclude "")
                      1
                      "%xmm2"
                      backend-state)]
                  [scratch-xmm : String
                    (compiler-backend-scavenge-xmm-reg
                      dst
                      (compiler-backend-one-exclude
                        (be_state.compiler-backend-global-shared-view acc-xmm))
                      1
                      "%xmm3"
                      backend-state)]
                  [acc-ymm : String
                    (compiler-backend-xmm-to-ymm
                      (be_state.compiler-backend-global-shared-view acc-xmm))]
                  (if (or
                    (= (string.string-length ymm) 0)
                    (= (string.string-length acc-ymm) 0))
                    (be_state.compiler-backend-instr-error
                      instr-diag
                      (compiler-backend-vector-home-unavailable "reduce source"))
                    (Ok
                      (str_cat.str-cat
                        src-asm
                        (compiler-backend-avx512-vector-reduce-horizontal-asm
                          mnemonic
                          zmm
                          ymm
                          elem-ty
                          acc-xmm
                          acc-ymm
                          scratch-xmm)
                        (compiler-backend-vector-reduce-store-scalar
                          assignments
                          dst
                          elem-ty
                          acc-xmm
                          backend-state)))))])]
          [(Err message)
            (be_state.compiler-backend-instr-error instr-diag message)])))
    (compiler-backend-avx512-shape-diagnostic
      type-segment-bases
      instr-diag
      elem-ty
      lanes)))

(define (compiler-backend-emit-store-typed-var
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [var-id : i64]
  [reg : String]
  [ty : compiler_ast_types.AstType]
  [backend-state : be_state.CompilerBackendState]) : String
  (if (compiler-backend-float-type? ty)
    (compiler-backend-emit-store-float-var
      assignments
      var-id
      reg
      ty
      backend-state)
    (compiler-backend-emit-store-var assignments var-id reg backend-state)))

;; Canonical pair offsets for a group var without a register home. In functions
;; with exposed groups, both storage modes use word1; exposed values also use
;; word0 here.
;; The pair lives in a dedicated contiguous region below the
;; ordinary var/callee-save region so `AddrOf group-var` plus `Gep 8` reaches
;; word1. `frame-slots` depends only on the allocator plan, so this base is
;; stable across body emission.
(define (compiler-backend-group-word0-slot
  [var : i64]
  [vars : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [backend-state : be_state.CompilerBackendState]) : i64
  (-
    0
    (*
      8
      (+
        (compiler-backend-frame-slots vars assignments backend-state)
        (+ (* 2 (compiler-backend-group-rank backend-state var)) 2)))))

;; The rbp-relative slot offset of the object an `AddrOf` names, mirroring
;; `compiler-backend-addr-of-source-slot` numerically: the group-word0 slot
;; for an addressable group, the assigned spill offset, else the canonical
;; slot for the var. The sweep turns it into a delta-0 canonical offset with
;; `canonical = (hi + 8) + rbp-offset`.
(define (compiler-backend-addr-of-source-rbp-offset
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [src : i64]
  [backend-state : be_state.CompilerBackendState]) : i64
  (if (compiler-backend-addressable-group-var? backend-state src)
    (compiler-backend-group-word0-slot
      src
      (be_state.compiler-backend-function-state-i64
        (be_state.compiler-backend-state-function-state backend-state)
        be_state.compiler-backend-function-i64-current-slot-vars)
      assignments
      backend-state)
    (match (compiler-backend-emit-assignment-lookup
      backend-state
      assignments
      src)
      [(Some location)
        (match location
          [(Spill offset) offset]
          [_ (- 0 (* 8 (+ src 1)))])]
      [(No) (- 0 (* 8 (+ src 1)))])))

;; True when the addressed object has a frame slot home this pass renders
;; through the frame-offset formatter: an addressable group, or a spilled var.
;; A register-homed or uncolored var goes through `slot-with-backend-state`,
;; which records the slot reference for frame sizing.
(define (compiler-backend-addr-of-source-frame-homed?
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [src : i64]
  [backend-state : be_state.CompilerBackendState]) : bool
  (or
    (compiler-backend-addressable-group-var? backend-state src)
    (match (compiler-backend-emit-assignment-lookup
      backend-state
      assignments
      src)
      [(Some location)
        (match location
          [(Spill _) true]
          [_ false])]
      [(No) false])))

(define (compiler-backend-addr-of-source-slot
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [src : i64]
  [backend-state : be_state.CompilerBackendState]) : String
  (if (compiler-backend-addr-of-source-frame-homed?
    assignments
    src
    backend-state)
    (compiler-backend-frame-offset-with-backend-state
      backend-state
      (compiler-backend-addr-of-source-rbp-offset assignments src backend-state))
    (compiler-backend-slot-with-backend-state backend-state src)))

(define (compiler-backend-state-global-symbol-id
  [state : be_state.CompilerBackendState]
  [name : i64]) : String
  (unsafe
    (match (deref (be_state.compiler-backend-state-view state)).emission-symbols
      [(be_state.CompilerBackendEmissionSymbols.Program index)
        (compiler-backend-global-symbol-index index name)]
      [(be_state.CompilerBackendEmissionSymbols.None)
        (be_state.compiler-backend-state-user-symbol-id state name)])))

(define (compiler-backend-global-symbol-index
  [program-index : be_state.CompilerBackendProgramIndex]
  [name : i64]) : String
  (if (compiler-backend-index-extern-references? program-index name)
    (compiler-backend-asm-safe-symbol
      (compiler-backend-index-extern-link-symbol program-index name))
    (be_state.compiler-backend-state-user-symbol-id
      program-index.backend-state
      name)))

(define (compiler-backend-unsigned-rel-ty?
  [type-segment-bases : i64]
  [ty : (& compiler_ast_types.AstType)]) : bool
  (match ty
    [(or (U64) (U32) (U16) (U8) (Char)) true]
    ;; Comparison IR keeps the operand's region tag; order by the inner type
    ;; (#9688).
    [(or (Region _ inner) (Invalidate _ inner))
      (compiler-backend-unsigned-rel-ty?
        type-segment-bases
        (&
          (compiler_ast_types.ast-type-segment-bases-get
            type-segment-bases
            inner)))]
    [_ false]))

(define (compiler-backend-int-instruction-suffix
  [type-segment-bases : i64]
  [ty : compiler_ast_types.AstType]) : String
  (let
    [size : i64 (compiler-backend-type-size type-segment-bases ty)]
    (cond [(= size 1) "b"] [(= size 2) "w"] [(= size 4) "l"] [else "q"])))

(define (compiler-backend-sized-reg
  [type-segment-bases : i64]
  [reg : String]
  [ty : compiler_ast_types.AstType]) : String
  (compiler-backend-reg-part
    reg
    (compiler-backend-type-size type-segment-bases ty)))

(define (compiler-backend-binop-cmp-reg-asm
  [type-segment-bases : i64]
  [ty : compiler_ast_types.AstType]
  [rhs : String]
  [lhs : String]) : String
  (str_cat.str-cat
    (str_cat.str-cat
      "    cmp"
      (compiler-backend-int-instruction-suffix type-segment-bases ty)
      " "
      rhs
      ", ")
    lhs
    "\n"))

(define (compiler-backend-const-hoist-uses-reg-id-from?
  [function-state : be_state.CompilerBackendFunctionState]
  [reg : i64]
  [i : i64]) : bool
  (if (>=
    i
    (be_state.compiler-backend-function-scratch-i64
      function-state
      be_state.compiler-backend-scratch-i64-const-hoist-site-count))
    false
    (or
      (=
        (array-ref
          (be_state.compiler-backend-function-scratch-i64-array
            function-state
            be_state.compiler-backend-scratch-i64-array-const-hoist-site-regs)
          i)
        reg)
      (compiler-backend-const-hoist-uses-reg-id-from?
        function-state
        reg
        (+ i 1)))))

(define (compiler-backend-const-hoist-uses-reg?
  [function-state : be_state.CompilerBackendFunctionState]
  [reg : i64]) : bool
  (or
    (compiler-backend-const-hoist-uses-reg-id-from? function-state reg 0)
    (and
      (be_state.compiler-backend-function-scratch-bool?
        function-state
        be_state.compiler-backend-scratch-bool-const-hoist-frame-rbx)
      (= reg compiler_abi.compiler-reg-id-rbx))))

;; The scalar register home of a value if it is a var the
;; allocator placed in a single GP register, else "". Used by the direct binop
;; path to source an operand straight from its home register instead of staging
;; it through %r8 (`movq %r13,%r8 ; addq %r8,%r12` -> `addq %r13,%r12`). Only a
;; plain CompilerRegLocation.Register qualifies; group register-pairs are aggregates and
;; never appear as scalar binop operands.
(define (compiler-backend-value-scalar-register
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : (& value compiler_ir_types.CompilerIrValue)]) : String
  (let
    [value : compiler_ir_types.CompilerIrValue
      (owned_view.compiler-owned-reference-shared-view value)]
    (match value
      [(Var id)
        (if (>= (compiler-backend-forwarded-addr-of-src backend-state id) 0)
          ""
          (match (compiler-backend-emit-assignment-lookup
            backend-state
            assignments
            id)
            [(Some location)
              (match location
                [(Register r) (compiler_abi.compiler-abi-register-spelling r)]
                [_ ""])]
            [(No) ""]))]
      [_ ""])))

;; Stack address of a scalar variable value that can be used as an instruction
;; source operand. Forwarded addr-of values are not stack loads and must fall
;; back to the ordinary load path.
(define (compiler-backend-value-stack-address
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]
  [backend-state : be_state.CompilerBackendState]) : String
  (match value
    [(Var id)
      (if (>= (compiler-backend-forwarded-addr-of-src backend-state id) 0)
        ""
        (match (compiler-backend-emit-assignment-lookup
          backend-state
          assignments
          id)
          [(Some location)
            (match location
              [(Spill offset)
                (compiler-backend-frame-offset-with-backend-state
                  backend-state
                  offset)]
              [_ ""])]
          [(No) (compiler-backend-slot-with-backend-state backend-state id)]))]
    [_ ""]))

;; The memory operand a compare may spell for `value` at width `ty`: this
;; function's own frame slot for a spilled var, or the rip-relative cell for a
;; scalar global read. Exactly one side of a compare may use it.
;; W3(c): the value a var's plan home RECOMPUTES, or Unit when it has a real
;; home. A rematerialised frozen global read owns no slot, but the cell it
;; recomputes from is itself a legal memory operand, so the M6-I fold applies to
;; it exactly as it does to a direct `Global` operand: `cmpq g(%rip), %r` is the
;; whole of the remat plus the compare.
(define (compiler-backend-var-remat-value
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]
  [backend-state : be_state.CompilerBackendState]) : compiler_ir_types.CompilerIrValue
  (match value
    [(Var id)
      (match (compiler-backend-emit-assignment-lookup
        backend-state
        assignments
        id)
        [(Some location)
          (match location
            [(Remat inner) inner]
            [_ (Unit)])]
        [(No) (Unit)])]
    [_ (Unit)]))

(define (compiler-backend-remat-global-cell-operand
  [backend-state : be_state.CompilerBackendState]
  [value : compiler_ir_types.CompilerIrValue]) : String
  (match value
    [(Global name)
      (if (be_state.compiler-backend-inline-aggregate-global?
        backend-state
        name)
        ;; IAG-1: an inline aggregate read is not a cell read at all.
        ""
        (let
          [symbol : String
            (compiler-backend-state-global-symbol-id backend-state name)]
          (if (string.eq symbol "")
            ""
            (str_cat.str-cat symbol "(%rip)"))))]
    [_ ""]))

;; W3(c): the memory operand a READ of `value` may spell -- this function's own
;; frame slot for a spilled var, or the rip-relative CELL for a var whose plan
;; home rematerialises a frozen global read. `off(%rsp)` and `sym(%rip)` are
;; both single ModRM memory operands, so wherever the slot spelling was legal
;; the cell spelling is too, and it is the whole of the materialising
;; `movq g(%rip), %scratch` the remat would otherwise emit in front of the
;; instruction. This is LLVM's fold-first step for a rematerialised load
;; (InlineSpiller.cpp:753-760, `foldMemoryOperand` / `++NumFoldedLoads`), and
;; without it widening the remat set turns a folded operand such as
;; `andq mask(%rip)` back into two instructions.
;;
;; Every caller spells the result as a COMPLETE source operand (a binop or cmov
;; source, a compare operand, a bounds-check length), never as an addressing
;; base, which is the one thing rip-relative cannot be.
(define (compiler-backend-value-read-memory-operand
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [stack : String
      (compiler-backend-value-stack-address
        assignments
        (be_state.compiler-backend-global-shared-view value)
        backend-state)]
    (if (string.eq stack "")
      (compiler-backend-remat-global-cell-operand
        backend-state
        (compiler-backend-var-remat-value assignments value backend-state))
      stack)))

(define (compiler-backend-commutative-binop?
  [op : (& op compiler_ir_types.CompilerIrBinOp)]) : bool
  (match op
    [(or (Add) (Mul) (And) (Or) (BitAnd) (BitOr) (BitXor)) true]
    [_ false]))

(define (compiler-backend-branch-test-var-asm
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [var-id : i64]
  [backend-state : be_state.CompilerBackendState]) : String
  (if (>= (compiler-backend-forwarded-addr-of-src backend-state var-id) 0)
    ""
    (match (compiler-backend-emit-assignment-lookup
      backend-state
      assignments
      var-id)
      [(Some location)
        (match location
          [(Register home)
            (let
              [home-name : String
                (compiler_abi.compiler-abi-register-spelling home)]
              (str_cat.str-cat "    testq " home-name ", " home-name "\n"))]
          [(RegisterPair _ _) ""]
          [(Spill offset)
            (str_cat.str-cat
              "    cmpq $0, "
              (compiler-backend-frame-offset-with-backend-state
                backend-state
                offset)
              "\n")]
          ;; Rematerialise into %rax, then test it (constant branch conditions are
          ;; normally folded away, so this is rare but must stay correct).
          [(Remat value)
            (str_cat.str-cat
              (compiler-backend-load-value-asm
                (compiler_regalloc.compiler-reg-assignment-table-empty)
                value
                "%rax"
                backend-state)
              "    testq %rax, %rax\n")])]
      [(No)
        (str_cat.str-cat
          "    cmpq $0, "
          (compiler-backend-slot-with-backend-state backend-state var-id)
          "\n")])))

;; SS-P5(b) / VG-P-B: the `cmov` mnemonic that reads a comparison's own flags.
;; `cmov<cc>` and `j<cc>` name the SAME condition codes, so this is the branch
;; table above with the mnemonic prefix exchanged and it inherits its
;; signed/unsigned split unchanged -- an unsigned `lt` is `jb`/`cmovb`, a signed
;; one `jl`/`cmovl`. The two bit-test predicates are deliberately absent: their
;; flags come from `bt`/`test`, not from the `cmp` the select-on-flags path
;; emits, and "" is that path's decline.
(define (compiler-backend-compare-cmov
  [type-segment-bases : i64]
  [op : compiler_ir_types.CompilerIrBinOp]
  [ty : compiler_ast_types.AstType]) : String
  (match op
    [(Eq) "cmove"]
    [(Ne) "cmovne"]
    [(Lt)
      (if (compiler-backend-unsigned-rel-ty? type-segment-bases ty)
        "cmovb"
        "cmovl")]
    [(Le)
      (if (compiler-backend-unsigned-rel-ty? type-segment-bases ty)
        "cmovbe"
        "cmovle")]
    [(Gt)
      (if (compiler-backend-unsigned-rel-ty? type-segment-bases ty)
        "cmova"
        "cmovg")]
    [(Ge)
      (if (compiler-backend-unsigned-rel-ty? type-segment-bases ty)
        "cmovae"
        "cmovge")]
    [_ ""]))

;; x86 encodes an immediate only as the source of cmp.  When the IR puts the
;; immediate on the LHS, reverse the predicate and compare it directly against
;; the register RHS instead of materialising it in a scavenged register.
(define (compiler-backend-compare-swapped-op
  [op : compiler_ir_types.CompilerIrBinOp]) : compiler_ir_types.CompilerIrBinOp
  (match (& op)
    [(Eq) (Eq)]
    [(Ne) (Ne)]
    [(Lt) (Gt)]
    [(Le) (Ge)]
    [(Gt) (Lt)]
    [(Ge) (Le)]
    [(BitTestEq) (BitTestEq)]
    [(BitTestNe) (BitTestNe)]
    [_ op]))

;; Byte offset just past the last newline strictly before `limit`: the start of
;; the assembly line whose terminating newline sits at `limit`. Zero when the
;; text holds no earlier newline (the line is the first one).
(define (compiler-backend-asm-prev-line-start [data : (Ptr u8)] [limit : i64]) : i64
  (let
    [i : i64 limit]
    [start : i64 0]
    [done : bool false]
    (while (and (not done) (> i 0))
      (if (= (be_state.compiler-backend-peephole-byte-at data (- i 1)) 10)
        (begin
          (set! start i)
          (set! done true))
        (-= i 1)))
    start))

;; A scalar register-homed var IS its own cmp operand, so comparisons can emit
;; `cmp <rhs>, <home>` directly instead of staging either side through a fixed
;; scratch. Returns "" for register groups/pairs and addr-of-forwarded vars (whose
;; value is a computed address, not the contents of the home register).
(define (compiler-backend-value-scalar-register-home
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : (& compiler_ir_types.CompilerIrValue)]) : String
  (match value
    [(Var id)
      (if (>= (compiler-backend-forwarded-addr-of-src backend-state id) 0)
        ""
        (match (compiler-backend-emit-assignment-lookup
          backend-state
          assignments
          id)
          [(Some location)
            (match location
              [(Register r) (compiler_abi.compiler-abi-register-spelling r)]
              [_ ""])]
          [_ ""]))]
    [_ ""]))

;; Keep the space before a pool %rbp. The rebase and slot scanners match
;; "(%rbp" for frame operands, and the CSR census counts %rbp after a space
;; as a value read. GAS and the COFF assembler encode both spellings as the
;; same base operand. Indexed addressing keeps its own base/index syntax.
(define (compiler-backend-value-base-prefix [base : (& base str)]) : String
  (if (string.eq base "%rbp")
    "( "
    "("))

(define (compiler-backend-mem-base-address [disp : i64] [base : String]) : String
  (str_cat.str-cat
    (if (= disp 0)
      ""
      (string.int->string disp))
    (compiler-backend-value-base-prefix base)
    base
    ")"))

;; Exclude an already-chosen register R (so a second scavenge at the same point
;; cannot collide with it).
(define (compiler-backend-one-exclude [r : String]) : (__tl_dyn-array String)
  (__tl_make-array r))

;; Exclude two already-chosen registers without excluding unrelated pool
;; registers. Used for address operands that must survive a load temp.
(define (compiler-backend-two-exclude [r1 : String] [r2 : String]) : (__tl_dyn-array
    String)
  (let
    [a : (__tl_dyn-array String) (__tl_make-array String 2)]
    (set! (array-ref a 0) r1)
    (set! (array-ref a 1) r2)
    a))

;; Exclude three already-chosen or live-through registers without excluding
;; unrelated pool registers.
(define (compiler-backend-three-exclude
  [r1 : String]
  [r2 : String]
  [r3 : String]) : (__tl_dyn-array String)
  (__tl_make-array r1 r2 r3))

;; Four live-through registers to keep a scavenge off. The select-on-flags path
;; needs both select operand homes AND both compare operand homes excluded at
;; once; "" entries are inert (no register spells as the empty string).
(define (compiler-backend-four-exclude
  [r1 : String]
  [r2 : String]
  [r3 : String]
  [r4 : String]) : (__tl_dyn-array String)
  (__tl_make-array r1 r2 r3 r4))

(define (compiler-backend-emit-call-space-sub [space : i64]) : String
  (if (= space 0)
    ""
    (str_cat.str-cat "    subq $" (string.int->string space) ", %rsp\n" "")))

(define (compiler-backend-emit-call-space-add [space : i64]) : String
  (if (= space 0)
    ""
    (str_cat.str-cat "    addq $" (string.int->string space) ", %rsp\n" "")))

;; Dense pair index of a group var inside the group-pair region, -1 when the id
;; carries no pair (no caller spells a group slot for such an id).
(define (compiler-backend-group-rank
  [backend-state : be_state.CompilerBackendState]
  [var : i64]) : i64
  (let
    [ranks : (__tl_dyn-array i64)
      (be_state.compiler-backend-function-state-i64-array
        (be_state.compiler-backend-state-function-state backend-state)
        be_state.compiler-backend-function-i64-array-group-ranks)]
    (if (and (>= var 0) (< var (array-length ranks)))
      (array-ref ranks var)
      (- 0 1))))

(define (compiler-backend-addressable-group-var?
  [backend-state : be_state.CompilerBackendState]
  [var : i64]) : bool
  (let
    [function-state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state backend-state)]
    (and
      (be_state.compiler-backend-function-state-bool?
        function-state
        be_state.compiler-backend-function-bool-group-vars-enabled)
      (let
        [function-state-live-set
          (be_state.compiler-backend-function-state-live-set
            function-state
            be_state.compiler-backend-function-live-set-addressable-group-vars)]
        (compiler_liveness.compiler-live-set-contains?
          function-state-live-set
          var)))))

;; Logical IR names have ids before index construction. Extern link symbols are
;; probed separately as exact ABI Strings.
(define (compiler-backend-index-function-slot
  [index : be_state.CompilerBackendProgramIndex]
  [name : i64]) : backend_i64_i64_map.Lookup
  (let
    [tables : (& index be_state.CompilerBackendProgramTables)
      (be_state.compiler-backend-program-tables index)]
    [name-id : i64 (compiler_ir_types.compiler-ir-symbol-id name)]
    [slot : i64
      (if (< name-id 0)
        -1
        (backend_i64_i64_map.get-value-or (& tables.functions) name-id -1))]
    (if (< slot 0)
      (LookupMissing)
      (LookupFound slot))))

(define (compiler-backend-index-extern-signature-slot
  [index : be_state.CompilerBackendProgramIndex]
  [name : i64]) : backend_i64_i64_map.Lookup
  (let
    [tables : (& index be_state.CompilerBackendProgramTables)
      (be_state.compiler-backend-program-tables index)]
    [name-id : i64 (compiler_ir_types.compiler-ir-symbol-id name)]
    [slot : i64
      (if (< name-id 0)
        -1
        (backend_i64_i64_map.get-value-or
          (& tables.extern-signatures)
          name-id
          -1))]
    (if (< slot 0)
      (LookupMissing)
      (LookupFound slot))))

(define (compiler-backend-index-extern-reference-slot
  [index : be_state.CompilerBackendProgramIndex]
  [name : i64]) : backend_i64_i64_map.Lookup
  (let
    [tables : (& index be_state.CompilerBackendProgramTables)
      (be_state.compiler-backend-program-tables index)]
    [name-id : i64 (compiler_ir_types.compiler-ir-symbol-id name)]
    [logical-slot : i64
      (if (< name-id 0)
        -1
        (backend_i64_i64_map.get-value-or
          (& tables.extern-references)
          name-id
          -1))]
    (if (>= logical-slot 0)
      (LookupFound logical-slot)
      (match (backend_i64_i64_map.get (& tables.extern-link-references) name-id)
        [(LookupFound slot) (LookupFound slot)]
        [(LookupMissing) (LookupMissing)]))))

(define (compiler-backend-index-extern-call-info
  [index : be_state.CompilerBackendProgramIndex]
  [name : i64]) : i64
  (let
    [tables : (& index be_state.CompilerBackendProgramTables)
      (be_state.compiler-backend-program-tables index)]
    (match (compiler-backend-index-extern-reference-slot index name)
      [(LookupFound slot) (array-ref tables.extern-call-infos slot)]
      [(LookupMissing) 0])))

(define (compiler-backend-extern-call-info-c-abi? [info : i64]) : bool
  (= (% info 2) 1))

(define (compiler-backend-index-function-defines?
  [index : be_state.CompilerBackendProgramIndex]
  [name : i64]) : bool
  (match (compiler-backend-index-function-slot index name)
    [(LookupFound _) true]
    [(LookupMissing) false]))

(define (compiler-backend-index-extern-references?
  [index : be_state.CompilerBackendProgramIndex]
  [name : i64]) : bool
  (match (compiler-backend-index-extern-reference-slot index name)
    [(LookupFound _) true]
    [(LookupMissing) false]))

(define (compiler-backend-index-extern-link-symbol-id
  [index : be_state.CompilerBackendProgramIndex]
  [name-id : i64]) : i64
  (let
    [tables : (& index be_state.CompilerBackendProgramTables)
      (be_state.compiler-backend-program-tables index)]
    (match (backend_i64_i64_map.get (& tables.extern-references) name-id)
      [(LookupFound slot) (array-ref tables.extern-link-symbols slot)]
      [(LookupMissing) name-id])))

(define (compiler-backend-index-extern-link-symbol
  [index : be_state.CompilerBackendProgramIndex]
  [name : i64]) : String
  (be_state.compiler-backend-symbol-text-index
    index
    (compiler-backend-index-extern-link-symbol-id index name)))

(define (compiler-backend-index-extern-provided?
  [index : be_state.CompilerBackendProgramIndex]
  [name : i64]) : bool
  (let
    [tables : (& index be_state.CompilerBackendProgramTables)
      (be_state.compiler-backend-program-tables index)]
    (match (compiler-backend-index-extern-signature-slot index name)
      [(LookupFound slot) (array-ref tables.extern-provided slot)]
      [(LookupMissing) false])))

(define (compiler-backend-index-c-export?
  [index : be_state.CompilerBackendProgramIndex]
  [name : i64]) : bool
  (and
    (compiler-backend-index-extern-provided? index name)
    (compiler-backend-extern-call-info-c-abi?
      (compiler-backend-index-extern-call-info index name))))

;; Per-call %rsp adjustment. Outgoing stack-arg space is folded into the function
;; frame, so normal text emission should see a zero dip.
(define (compiler-backend-call-arg-space
  [target : be_state.CompilerBackendTarget]
  [_args : (& _args compiler_ir_types.CompilerIrCallArgs)]
  [_types : (& _types compiler_ast_types.AstTypeList)]
  [_c-abi? : bool]
  [_program-index : be_state.CompilerBackendProgramIndex]) : i64
  (compiler-backend-call-arg-space-from target))

(define (compiler-backend-call-arg-space-from
  [_target : be_state.CompilerBackendTarget]) : i64
  0)

(define (compiler-backend-branch-uses-var?
  [cond : (& compiler_ir_types.CompilerIrValue)]
  [var : i64]) : bool
  (match cond
    [(Var id) (= id var)]
    [_ false]))

;; The remaining `BinOp` fusion cluster of
;; `compiler-backend-emit-instrs-step`.
;; It owns the shared lookahead for RAX forwarding and compare consumers
;; (return, direct/total-enum branches, and comparison-plus-not branches).
;; `((mask >>u d) & 1) != 0` over a literal mask, feeding a branch, is `bt` plus
;; its jump. Lowered as a real shift it costs an order of magnitude more: x86
;; pins a variable count to `%cl`, so whatever lives there spills and reloads
;; around the shift, and the count still pays the shift-count guard. The
;; optimizer's bit_test pass emits exactly this triple for a classifier chain,
;; and any hand-written `(!= (bit-and (shr MASK d) 1) 0)` gets the same
;; treatment.
;;
;; The guard stays wherever the count could be out of range: `bt` reads its
;; offset modulo 64 where the language aborts, so dropping it there would change
;; what an out-of-range count does. It goes away where the count is spelled
;; `(bit-and c 63)`: six bits cannot name an out-of-range shift, the abort is
;; unreachable, and `bt` already reads its offset modulo 64 -- so the mask is
;; exactly `bt`'s own behavior and both it and the guard fold into the one
;; instruction. That is the shape the optimizer's bit_test pass emits
;; (opt-bit-test-mask-block); a bare count keeps the guard, which is the only
;; cost that then survives on the taken path.
;; A literal mask still has to be materialized, so it needs a register the count
;; does not occupy; a mask already in a var is only READ by `bt` and needs
;; nothing beyond its own home. The optimizer emits the second form, and the
;; first covers a mask a later fold pushed back into the shift operand.
(defenum CompilerBackendBitTestMask
  (No)
  (Literal i64)
  (Var i64))

;; ============================================================================
;; Register scavenger -- per-instruction occupied-register masks computed on the
;; FINAL post-rewrite IR (emit-blocks-list + assignments + slot-vars). The
;; backend uses this query to pick allocator-owned scratch registers.
;;
;; Point space matches compiler-reg-live-intervals EXACTLY: the global I-th
;; emitted instruction (block-list order, then instr-seq order) lives at point
;; = 2*I.
;; Does var v occupy `reg` (the register itself, or either half of a pair)?
;; Character-dispatch register-name -> scavenge bit. The scavenger queries
;; this per emitted operand; the eq-mnemonic ladder paid up to eighteen string
;; compares per call. Length plus three character reads decide every case.
(define (compiler-backend-scavenge-vector-family-bit [family : i64]) : i64
  (cond
    [(and (>= family 2) (<= family 5)) (shl 1 (+ family 9))]
    [(and (>= family 0) (< family 2)) (shl 1 (+ family 18))]
    [(and (>= family 6) (< family 16)) (shl 1 (+ family 14))]
    [else 0]))

;; Unknown names map to 0.
(define (compiler-backend-scavenge-reg-bit [reg : (& reg str)]) : i64
  (let
    [n : i64 (string.string-length reg)]
    (cond
      [(or (< n 3) (> n 6)) 0]
      [(not (= (string.string-ref reg 0) '%')) 0]
      [(= n 3)
        (if (= (string.string-ref reg 1) 'r')
          (cond
            [(= (string.string-ref reg 2) '9') 1]
            [(= (string.string-ref reg 2) '8') 32]
            [else 0])
          0)]
      [(= n 4)
        (if (= (string.string-ref reg 1) 'r')
          (let
            [c2 : char (string.string-ref reg 2)]
            [c3 : char (string.string-ref reg 3)]
            (cond
              [(= c2 'c')
                (if (= c3 'x')
                  2
                  0)]
              [(= c2 'd') (cond [(= c3 'x') 4] [(= c3 'i') 131072] [else 0])]
              [(= c2 'a')
                (if (= c3 'x')
                  32768
                  0)]
              [(= c2 's')
                (if (= c3 'i')
                  65536
                  0)]
              [(= c2 'b')
                (if (= c3 'x')
                  1024
                  0)]
              [(= c2 '1')
                (cond
                  [(= c3 '0') 8]
                  [(= c3 '1') 16]
                  [(= c3 '2') 64]
                  [(= c3 '3') 128]
                  [(= c3 '4') 256]
                  [(= c3 '5') 512]
                  [else 0])]
              [else 0]))
          0)]
      [else
        (let
          [c1 : char (string.string-ref reg 1)]
          [c2 : char (string.string-ref reg 2)]
          [c3 : char (string.string-ref reg 3)]
          (if (or
            (and (or (= c1 'x') (= c1 'y') (= c1 'z')) (= c2 'm') (= c3 'm'))
            (and (= c1 'v') (= c2 'e') (= c3 'c')))
            (compiler-backend-scavenge-vector-family-bit
              (compiler_abi.compiler-abi-register-decimal-suffix
                (string.copy reg)
                4
                15))
            0))])))

(define (compiler-backend-scavenge-emergency-reg-supported? [reg : (& reg str)]) : bool
  (or
    (string.eq reg "%rax")
    (not (= (compiler-backend-scavenge-reg-bit reg) 0))))

(define (compiler-backend-scavenge-reg-id-bit [reg : i64]) : i64
  (cond
    [(= reg compiler_abi.compiler-reg-id-r9) 1]
    [(= reg compiler_abi.compiler-reg-id-rcx) 2]
    [(= reg compiler_abi.compiler-reg-id-rdx) 4]
    [(= reg compiler_abi.compiler-reg-id-r10) 8]
    [(= reg compiler_abi.compiler-reg-id-r11) 16]
    [(= reg compiler_abi.compiler-reg-id-r8) 32]
    [(= reg compiler_abi.compiler-reg-id-r12) 64]
    [(= reg compiler_abi.compiler-reg-id-r13) 128]
    [(= reg compiler_abi.compiler-reg-id-r14) 256]
    [(= reg compiler_abi.compiler-reg-id-r15) 512]
    [(= reg compiler_abi.compiler-reg-id-rbx) 1024]
    [(= reg compiler_abi.compiler-reg-id-rax) 32768]
    [(= reg compiler_abi.compiler-reg-id-rsi) 65536]
    [(= reg compiler_abi.compiler-reg-id-rdi) 131072]
    [else
      (compiler-backend-scavenge-vector-family-bit
        (compiler_abi.compiler-abi-register-vector-family-index reg))]))

(define (compiler-backend-scavenge-exclude-mask
  [exclude : (& exclude (__tl_dyn-array String))]
  [n : i64]) : i64
  (let
    [mask : i64 0]
    (for [i (iterator.range 0 n)]
      (set!
        mask
        (bit-or mask (compiler-backend-scavenge-reg-bit (array-ref exclude i)))))
    mask))

(define (compiler-backend-scavenge-reg-free-in-mask?
  [occupied-mask : i64]
  [reg : (& reg str)]) : bool
  (= (bit-and occupied-mask (compiler-backend-scavenge-reg-bit reg)) 0))

(define (compiler-backend-var-register-home-index
  [assignment-index : compiler_regalloc.CompilerRegAssignmentTable]
  [var : i64]) : String
  (compiler_abi.compiler-abi-register-spelling
    (compiler_regalloc.compiler-reg-assignment-table-primary-register-home
      assignment-index
      var)))

;; Forward span (in point units; each instruction step is +2) that a scavenged
;; STAGING register is queried across, beyond its emit position. Loads sharing a
;; base register fuse into one emit step but the lowering numbers their def points
;; in REVERSE offset order, so a register-homed sibling carries an interval point
;; AHEAD of a spilled sibling's staging that is nonetheless emitted into its home
;; BEFORE it. Covering point + 2*(K-1) for the deepest K-field aggregate the
;; compiler binds-and-loads in one arm keeps every reordered sibling OCCUPIED in
;; the query so the staging scratch never clobbers it. See
;; compiler-backend-scavenge-reg.
(define compiler-backend-scavenge-staging-window : i64
  16)

(define (compiler-backend-scavenge-occupied-mask-at-point
  [function-state : be_state.CompilerBackendFunctionState]
  [point : i64]) : i64
  (let
    [occupied-masks : (__tl_dyn-array i64)
      (be_state.compiler-backend-function-scratch-i64-array
        function-state
        be_state.compiler-backend-scratch-i64-array-scavenge-occupied-masks)]
    [idx : i64
      (if (< point 0)
        -1
        (/ point 2))]
    (if (and (>= idx 0) (< idx (array-length occupied-masks)))
      (array-ref occupied-masks idx)
      0)))

;; Union the occupancy masks across every instruction event in [lo, hi] (point
;; coordinates; each event is point/2). A scavenge's staging scratch register
;; (e.g. a spilled load: `mov addr,scratch` then `mov scratch,spill`) is live not
;; only at the emit position but through the immediately following emission. A
;; FUSED destructure loads its fields in offset order while the lowering assigns
;; their interval points in the REVERSE order, so a register-homed sibling field
;; is emitted into its home one step BEFORE a spilled field's staging load yet
;; carries the HIGHER interval point (point+2). A single-point query at the emit
;; position would read that register "free" and the scratch would clobber the
;; just-loaded sibling. ORing [point, point+2] keeps the emit-position endpoint
;; (so a gep operand live only at the instruction start is still protected) and
;; adds the next-step endpoint (so the reordered fused sibling is too).
(define (compiler-backend-scavenge-occupied-mask-over-range
  [function-state : be_state.CompilerBackendFunctionState]
  [lo : i64]
  [hi : i64]) : i64
  (let
    [occupied-masks : (__tl_dyn-array i64)
      (be_state.compiler-backend-function-scratch-i64-array
        function-state
        be_state.compiler-backend-scratch-i64-array-scavenge-occupied-masks)]
    [count : i64 (array-length occupied-masks)]
    [lo-idx : i64
      (if (< lo 0)
        0
        (/ lo 2))]
    [hi-idx : i64
      (if (< hi 0)
        0
        (/ hi 2))]
    [acc : i64 0]
    (for [i (iterator.range lo-idx (+ hi-idx 1))]
      (if (and (>= i 0) (< i count))
        (set! acc (bit-or acc (array-ref occupied-masks i)))
        unit))
    acc))

(define (compiler-backend-scavenge-excluded?
  [exclude : (& exclude (__tl_dyn-array String))]
  [n : i64]
  [reg : (& reg str)]) : bool
  (let
    [i : i64 0]
    [hit : bool false]
    (while (and (< i n) (not hit))
      (if (string.eq (array-ref exclude i) reg)
        (set! hit true)
        unit)
      (+= i 1))
    hit))

;; Append one register to an exclude array (returns a fresh size-(n+1) array).
(define (compiler-backend-scavenge-exclude-append
  [exclude : (__tl_dyn-array String)]
  [n : i64]
  [extra : String]) : (__tl_dyn-array String)
  (let
    [a : (__tl_dyn-array String) (__tl_make-array String (+ n 1))]
    (for [i (iterator.range 0 n)]
      (set! (array-ref a i) (owned_view.compiler-owned-element-view exclude i)))
    (set! (array-ref a n) extra)
    a))

;; Exclude set = the HW-fixed regs PLUS the home registers of two source operands.
;; Robustly prevents a scavenged scratch from clobbering an operand whose value is
;; needed by THIS instruction (e.g. a loop-invariant base/src whose register the
;; liveness query may not see occupied at the scavenge point). Non-register-homed
;; operands map to the zero-bit empty-string sentinel. Pooled scratch registers
;; such as r10/r11 stay available unless one is an operand home. n = 7.
(define (compiler-backend-scavenge-exclude-ops2
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [v1 : compiler_ir_types.CompilerIrValue]
  [v2 : (& compiler_ir_types.CompilerIrValue)]) : (__tl_dyn-array String)
  (let
    [h1 : String
      (compiler-backend-value-scalar-register backend-state assignments v1)]
    [h2 : String
      (compiler-backend-value-scalar-register backend-state assignments v2)]
    (__tl_make-array
      "%rax"
      "%rdx"
      "%rcx"
      ""
      ""
      (if (string.eq h1 "")
        ""
        h1)
      (if (string.eq h2 "")
        ""
        h2))))

;; Scavenge candidate pool. The first 11 entries are the general pool; ABI-special
;; %rsi/%rdi/%rax come last so they are only used when that pool is occupied
;; and the point-local occupancy/exclude masks prove them free.
(define (compiler-backend-scavenge-candidates) : (__tl_dyn-array i64)
  (__tl_make-array
    compiler_abi.compiler-reg-id-r9
    compiler_abi.compiler-reg-id-rcx
    compiler_abi.compiler-reg-id-rdx
    compiler_abi.compiler-reg-id-r10
    compiler_abi.compiler-reg-id-r11
    compiler_abi.compiler-reg-id-r8
    compiler_abi.compiler-reg-id-r12
    compiler_abi.compiler-reg-id-r13
    compiler_abi.compiler-reg-id-r14
    compiler_abi.compiler-reg-id-r15
    compiler_abi.compiler-reg-id-rbx
    compiler_abi.compiler-reg-id-rsi
    compiler_abi.compiler-reg-id-rdi
    compiler_abi.compiler-reg-id-rax))

(define compiler-backend-scavenge-candidate-pool : (__tl_dyn-array i64)
  (compiler-backend-scavenge-candidates))

(define (compiler-backend-scavenge-xmm-candidates) : (__tl_dyn-array i64)
  (__tl_make-array
    (compiler_abi.compiler-abi-xmm-register-id 2)
    (compiler_abi.compiler-abi-xmm-register-id 3)
    (compiler_abi.compiler-abi-xmm-register-id 4)
    (compiler_abi.compiler-abi-xmm-register-id 5)))

(define compiler-backend-scavenge-xmm-candidate-pool : (__tl_dyn-array i64)
  (compiler-backend-scavenge-xmm-candidates))

(define (compiler-backend-callee-saved-reg? [_plan-mask : i64] [reg : i64]) : bool
  (>=
    (compiler_regalloc.compiler-reg-id-seq-index-of
      (be_state.compiler-backend-global-shared-view
        compiler-backend-scavenge-callee-list)
      reg
      0)
    0))

(define (compiler-backend-scavenge-candidate-ok?
  [function-state : be_state.CompilerBackendFunctionState]
  [occupied-mask : i64]
  [exclude-mask : i64]
  [plan-mask : i64]
  [reg : i64]) : bool
  (let
    [bit : i64 (compiler-backend-scavenge-reg-id-bit reg)]
    (and
      (not (= bit 0))
      (=
        (bit-and
          (bit-or
            exclude-mask
            (be_state.compiler-backend-function-scratch-i64
              function-state
              be_state.compiler-backend-scratch-i64-current-instr-reserved-mask))
          bit)
        0)
      (or
        (not (compiler-backend-callee-saved-reg? plan-mask reg))
        (not (= (bit-and plan-mask bit) 0))
        ;; A frame-home divmod hoist makes %rbx part of the same immutable
        ;; function plan: the prologue saves it, but no synthetic interval owns
        ;; it after the preheader store, so sites may use it as their one copy.
        (and
          (be_state.compiler-backend-function-scratch-bool?
            function-state
            be_state.compiler-backend-scratch-bool-const-hoist-frame-rbx)
          (= reg compiler_abi.compiler-reg-id-rbx)))
      (= (bit-and occupied-mask bit) 0))))

;; Emergency scratch register when no candidate is free. Soundness rule: the
;; chosen reg's held value must NOT be an operand of the instruction -- emergency-
;; wrap preserves the value ACROSS but not DURING, so an operand-home reg would be
;; read as the scratch mid-instruction. Prefer the fallback (the site's reserved
;; scratch) when it is FREE at this point: free => no var homes it => not an
;; operand home, so it is sound AND nothing needs preserving. If the fallback is
;; OCCUPIED (a pooled reg now homing a value,
;; possibly an operand), use the first NON-EXCLUDED candidate: non-excluded =>
;; not an operand home AND not a template-fixed superset reg, so emergency-
;; wrapping it is sound (even a callee-saved or non-operand-occupied reg -- the
;; wrap restores it). All-excluded is pathological/unreachable (exclude is
;; superset(5)+a few operand homes vs candidate count) -> fallback last resort.
;; Returns the first non-excluded candidate index, or -1 = "use the fallback".
(define (compiler-backend-scavenge-emergency-fallback-free?
  [function-state : be_state.CompilerBackendFunctionState]
  [exclude : (__tl_dyn-array String)]
  [exclude-n : i64]
  [occupied-mask : i64]
  [fallback : String]) : bool
  (and
    (not (compiler-backend-scavenge-excluded? exclude exclude-n fallback))
    (compiler-backend-scavenge-reg-free-in-mask? occupied-mask fallback)
    (=
      (bit-and
        (be_state.compiler-backend-function-scratch-i64
          function-state
          be_state.compiler-backend-scratch-i64-current-instr-reserved-mask)
        (compiler-backend-scavenge-reg-bit fallback))
      0)))

(define (compiler-backend-scavenge-emergency-cand-index
  [function-state : be_state.CompilerBackendFunctionState]
  [exclude : (__tl_dyn-array String)]
  [exclude-n : i64]
  [exclude-mask : i64]
  [occupied-mask : i64]
  [fallback : String]
  [cands : (& cands (__tl_dyn-array i64))]
  [n : i64]) : i64
  (if (compiler-backend-scavenge-emergency-fallback-free?
    function-state
    exclude
    exclude-n
    occupied-mask
    fallback)
    -1
    (let
      [i : i64 0]
      [found : i64 -1]
      (while (and (< i n) (< found 0))
        (if (and
          (or
            (not
              (be_state.compiler-backend-function-scratch-bool?
                function-state
                be_state.compiler-backend-scratch-bool-divmod-src-emergency-avoid-r10))
            (not (= (array-ref cands i) compiler_abi.compiler-reg-id-r10)))
          (=
            (bit-and
              (bit-or
                exclude-mask
                (be_state.compiler-backend-function-scratch-i64
                  function-state
                  be_state.compiler-backend-scratch-i64-current-instr-reserved-mask))
              (compiler-backend-scavenge-reg-id-bit (array-ref cands i)))
            0))
          (set! found i)
          unit)
        (+= i 1))
      found)))

;; R4-B: index of the first candidate usable under `mask`, or -1. Same admission
;; test the main walk uses; only the occupancy mask differs.
(define (compiler-backend-scavenge-first-ok-index
  [function-state : be_state.CompilerBackendFunctionState]
  [mask : i64]
  [exclude-mask : i64]
  [plan-mask : i64]
  [cands : (& cands (__tl_dyn-array i64))]
  [n : i64]) : i64
  (let
    [i : i64 0]
    [found : i64 -1]
    (while (and (< i n) (< found 0))
      (when
        (compiler-backend-scavenge-candidate-ok?
          function-state
          mask
          exclude-mask
          plan-mask
          (array-ref cands i))
        (set! found i))
      (+= i 1))
    found))

;; R4-B: the narrow last-resort tier. Reached only when every candidate is
;; refused under the wide staging window, i.e. immediately before the emergency
;; tier borrows an occupied register and wraps the step in a save/restore pair.
;; `narrow-mask` is the SAME occupancy query at the emit point alone, so a
;; register it reports free holds no live value while the staging register is
;; live; the only thing the wide window adds is protection against a fused
;; load group's reordered siblings, and the caller passes a narrower mask only
;; for instructions whose emission reorders nothing
;; (compiler-backend-instr-staging-narrow-ok?). Callers with nothing to gain
;; pass their own occupied mask, which makes this a no-op.
(define (compiler-backend-scavenge-narrow-index
  [function-state : be_state.CompilerBackendFunctionState]
  [occupied-mask : i64]
  [narrow-mask : i64]
  [exclude-mask : i64]
  [plan-mask : i64]
  [cands : (& cands (__tl_dyn-array i64))]
  [n : i64]) : i64
  (if (= narrow-mask occupied-mask)
    -1
    (compiler-backend-scavenge-first-ok-index
      function-state
      narrow-mask
      exclude-mask
      plan-mask
      cands
      n)))

(define (compiler-backend-scavenge-pick-iter
  [function-state : be_state.CompilerBackendFunctionState]
  ;; false for a peek: the same pick, without booking an emergency save.
  [commit : bool]
  [exclude : (__tl_dyn-array String)]
  [exclude-n : i64]
  [exclude-mask : i64]
  [occupied-mask : i64]
  [narrow-mask : i64]
  [plan-mask : i64]
  [fallback : String]
  [cands : (& cands (__tl_dyn-array i64))]
  [n : i64]) : String
  (for [i (iterator.range 0 n)]
    (when
      (compiler-backend-scavenge-candidate-ok?
        function-state
        occupied-mask
        exclude-mask
        plan-mask
        (array-ref cands i))
      ;; A picked callee-saved register is, by candidate-ok?, one the plan already
      ;; saves -- so the prologue/epilogue (driven by the stable plan set) already
      ;; preserve it for the caller. No dynamic save-set growth (that was unsound:
      ;; post-body save vs inline partial-set restores).
      (return (compiler_abi.compiler-abi-register-spelling (array-ref cands i)))))
  (let
    [nidx : i64
      (compiler-backend-scavenge-narrow-index
        function-state
        occupied-mask
        narrow-mask
        exclude-mask
        plan-mask
        cands
        n)]
    [emidx : i64
      (if (>= nidx 0)
        -2
        (compiler-backend-scavenge-emergency-cand-index
          function-state
          exclude
          exclude-n
          exclude-mask
          occupied-mask
          (be_state.compiler-backend-global-shared-view fallback)
          cands
          n))]
    (if (>= nidx 0)
      (compiler_abi.compiler-abi-register-spelling (array-ref cands nidx))
      (if (< emidx 0)
        (begin
          (when
            commit
            (if (compiler-backend-scavenge-emergency-reg-supported? fallback)
              (compiler-backend-emergency-add!
                function-state
                (string.copy fallback))
              (io.panic
                (str_cat.str-cat
                  "backend: unsupported scavenge emergency fallback register "
                  fallback))))
          fallback)
        (begin
          (when
            commit
            (compiler-backend-emergency-add-id!
              function-state
              (array-ref cands emidx)))
          (compiler_abi.compiler-abi-register-spelling (array-ref cands emidx)))))))

;; Pick a register free at `point`: prefer `fallback`, else the first usable
;; pool candidate, else `fallback` (degraded -- a no-free-register case).
(define (compiler-backend-scavenge-pick-with-mask
  [function-state : be_state.CompilerBackendFunctionState]
  [commit : bool]
  [occupied-mask : i64]
  [narrow-mask : i64]
  [exclude : (__tl_dyn-array String)]
  [exclude-n : i64]
  [fallback : String]) : String
  (let
    [exclude-mask : i64
      (compiler-backend-scavenge-exclude-mask (& exclude) exclude-n)]
    [cands : (__tl_dyn-array i64)
      (be_state.compiler-backend-i64-array-shared-view
        (& compiler-backend-scavenge-candidate-pool))]
    (if (and
      (not (compiler-backend-scavenge-excluded? exclude exclude-n fallback))
      (compiler-backend-scavenge-reg-free-in-mask? occupied-mask fallback))
      fallback
      (compiler-backend-scavenge-pick-iter
        function-state
        commit
        exclude
        exclude-n
        exclude-mask
        occupied-mask
        narrow-mask
        (be_state.compiler-backend-function-scratch-i64
          function-state
          be_state.compiler-backend-scratch-i64-scavenge-plan-reg-mask)
        fallback
        cands
        (array-length cands)))))

(define (compiler-backend-scavenge-pick-from-mask
  [function-state : be_state.CompilerBackendFunctionState]
  [occupied-mask : i64]
  [exclude : (__tl_dyn-array String)]
  [exclude-n : i64]
  [fallback : String]
  [cands : (& cands (__tl_dyn-array i64))]) : String
  (let
    [exclude-mask : i64
      (compiler-backend-scavenge-exclude-mask (& exclude) exclude-n)]
    (if (and
      (not (compiler-backend-scavenge-excluded? exclude exclude-n fallback))
      (compiler-backend-scavenge-reg-free-in-mask? occupied-mask fallback))
      fallback
      (compiler-backend-scavenge-pick-iter
        function-state
        true
        exclude
        exclude-n
        exclude-mask
        occupied-mask
        occupied-mask
        (be_state.compiler-backend-function-scratch-i64
          function-state
          be_state.compiler-backend-scratch-i64-scavenge-plan-reg-mask)
        fallback
        cands
        (array-length cands)))))

(define (compiler-backend-scavenge-extra-xmm
  [function-state : be_state.CompilerBackendFunctionState]
  [occupied-mask : i64]
  [exclude-mask : i64]
  [fallback : (& fallback str)]
  [limit : i64]
  [cands : (& cands (__tl_dyn-array i64))]) : String
  (let
    [fallback-bit : i64 (compiler-backend-scavenge-reg-bit fallback)]
    [plan-mask : i64
      (be_state.compiler-backend-function-scratch-i64
        function-state
        be_state.compiler-backend-scratch-i64-scavenge-plan-reg-mask)]
    (when
      (or
        (and
          (= (bit-and (bit-or occupied-mask exclude-mask) fallback-bit) 0)
          (compiler-backend-scavenge-reg-free-in-mask?
            (be_state.compiler-backend-function-scratch-i64
              function-state
              be_state.compiler-backend-scratch-i64-current-instr-reserved-mask)
            fallback))
        (>=
          (compiler-backend-scavenge-first-ok-index
            function-state
            occupied-mask
            exclude-mask
            plan-mask
            cands
            (array-length cands))
          0))
      (return ""))
    ;; These volatile homes are usable when free. Emergency saves keep using
    ;; the ordinary XMM2–XMM5 pool.
    (for [i (iterator.range 0 limit)]
      (when
        (or (< i 2) (>= i 6))
        (let
          [reg : i64 (compiler_abi.compiler-abi-xmm-register-id i)]
          (when
            (compiler-backend-scavenge-candidate-ok?
              function-state
              occupied-mask
              exclude-mask
              plan-mask
              reg)
            (return (compiler_abi.compiler-abi-register-spelling reg))))))
    ""))

(define (compiler-backend-scavenge-xmm-reg
  [dst-var : i64]
  [exclude : (__tl_dyn-array String)]
  [exclude-n : i64]
  [fallback : String]
  [backend-state : be_state.CompilerBackendState]) : String
  (compiler-backend-scavenge-xmm-reg-for-staging
    dst-var
    exclude
    exclude-n
    fallback
    false
    backend-state))

(define (compiler-backend-scavenge-xmm-reg-for-staging
  [dst-var : i64]
  [exclude : (__tl_dyn-array String)]
  [exclude-n : i64]
  [fallback : String]
  [scalar-compute? : bool]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [function-state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state backend-state)]
    [vars : i64
      (be_state.compiler-backend-function-scratch-i64
        function-state
        be_state.compiler-backend-scratch-i64-scavenge-vars)]
    [assignment-index : compiler_regalloc.CompilerRegAssignmentTable
      (be_state.compiler-backend-function-scratch-assignment-index
        function-state)]
    ;; See compiler-backend-scavenge-reg: query the staging register's forward live
    ;; span so a fused/destructure float load cannot clobber a reordered sibling
    ;; field emitted into its home before it.
    [point : i64
      (be_state.compiler-backend-function-state-emission-point function-state)]
    [hi-point : i64 (+ point compiler-backend-scavenge-staging-window)]
    [dst-home : String
      (if (and (>= dst-var 0) (< dst-var vars))
        (compiler-backend-var-register-home-index assignment-index dst-var)
        "")]
    [ex : (__tl_dyn-array String)
      (if (string.eq dst-home "")
        exclude
        (compiler-backend-scavenge-exclude-append
          exclude
          exclude-n
          (be_state.compiler-backend-global-shared-view dst-home)))]
    [ex-n : i64
      (if (string.eq dst-home "")
        exclude-n
        (+ exclude-n 1))]
    [cands : (__tl_dyn-array i64)
      (be_state.compiler-backend-i64-array-shared-view
        (& compiler-backend-scavenge-xmm-candidate-pool))]
    [occupied : i64
      (compiler-backend-scavenge-occupied-mask-over-range
        function-state
        point
        hi-point)]
    [extra : String
      (if scalar-compute?
        (compiler-backend-scavenge-extra-xmm
          function-state
          occupied
          (compiler-backend-scavenge-exclude-mask (& ex) ex-n)
          (& fallback)
          (if (be_state.compiler-backend-current-fn-win64? backend-state)
            6
            16)
          cands)
        "")]
    (if (string.eq extra "")
      (compiler-backend-scavenge-pick-from-mask
        function-state
        occupied
        ex
        ex-n
        fallback
        cands)
      extra)))

;; Side-effect-free twin of the GP picker for fusion admission.  It predicts the
;; exact register the ordinary scavenger will return, including its emergency
;; tier, without adding a pending save that would leak when the fusion rejects.
;; R4-C: may this staging pick retry against the [point, point+2] window
;; before the emergency tier? Yes for the scalar compute family (R4-B's
;; admission, set per instruction by compiler-backend-instr-reserved-home-mask)
;; and for ANY instruction outside the sibling-reordering load families (the
;; pair-emission flag): there nothing has been written ahead of its point, so
;; the at-point occupancy is exact. Inside those families the wide window
;; stands, whatever the instruction.
(define (compiler-backend-scavenge-narrow-window?
  [function-state : be_state.CompilerBackendFunctionState]) : bool
  (or
    (be_state.compiler-backend-function-scratch-bool?
      function-state
      be_state.compiler-backend-scratch-bool-instr-staging-narrow-ok)
    (not
      (be_state.compiler-backend-function-scratch-bool?
        function-state
        be_state.compiler-backend-scratch-bool-pair-emission))))

;; Return a register free at dst-var's def point (via the proven query),
;; excluding `exclude`, preferring `fallback`. If the preferred register is
;; occupied, pick another free pooled candidate or use the emergency wrapper.
(define (compiler-backend-scavenge-reg-pick
  [dst-var : i64]
  [exclude : (__tl_dyn-array String)]
  [exclude-n : i64]
  [fallback : String]
  ;; false for a peek: the same pick, without booking an emergency save.
  [commit : bool]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [function-state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state backend-state)]
    [vars : i64
      (be_state.compiler-backend-function-scratch-i64
        function-state
        be_state.compiler-backend-scratch-i64-scavenge-vars)]
    [assignment-index : compiler_regalloc.CompilerRegAssignmentTable
      (be_state.compiler-backend-function-scratch-assignment-index
        function-state)]
    ;; Query the occupancy across the staging register's live span, not just the
    ;; single emit POSITION. Loads sharing a base (a destructure's fields, fused by
    ;; emit-load-from-gep-pair / emit-load-load / emit-fused-gep-load-rest) are
    ;; emitted in OFFSET order while the lowering assigns their def points in the
    ;; REVERSE order, so a register-homed sibling (e.g. a String key in %r9) is
    ;; emitted into its home BEFORE a spilled sibling's staging load yet carries a
    ;; HIGHER interval point. Querying only `point` read that register "free" and
    ;; the scratch clobbered the just-loaded sibling (intern-lookup's slot-id load
    ;; picking %r9 over the live slot-key). A spilled field at offset position j in
    ;; a K-field group is preceded by j siblings at point+2..point+2j, so the
    ;; staging register's true upper coordinate is point + 2*(K-1); the window
    ;; below covers the deepest fully-bound aggregates the compiler destructures.
    ;; For a standalone def with nothing reordered ahead these forward events are
    ;; the next instructions' (whose registers the result must avoid anyway), so
    ;; this never under-protects. Exclude the dst home (not live yet) so the
    ;; scratch never overwrites the result register.
    [point : i64
      (be_state.compiler-backend-function-state-emission-point function-state)]
    [hi-point : i64 (+ point compiler-backend-scavenge-staging-window)]
    [dst-home : String
      (if (and (>= dst-var 0) (< dst-var vars))
        (compiler-backend-var-register-home-index assignment-index dst-var)
        "")]
    [ex : (__tl_dyn-array String)
      (if (string.eq dst-home "")
        exclude
        (compiler-backend-scavenge-exclude-append
          exclude
          exclude-n
          (be_state.compiler-backend-global-shared-view dst-home)))]
    [ex-n : i64
      (if (string.eq dst-home "")
        exclude-n
        (+ exclude-n 1))]
    ;; R4-B: the last-resort narrow window. The wide query above is the one that
    ;; decides; this second mask is consulted only when it leaves nothing, and
    ;; only for instructions whose emission reorders nothing
    ;; (compiler-backend-instr-staging-narrow-ok?, set once per instruction next
    ;; to the reserved-home mask). Passing the wide mask itself disables the tier
    ;; -- compiler-backend-scavenge-narrow-index returns -1 on equality -- so the
    ;; load-fusion families keep today's behaviour exactly.
    ;; R4-C: the narrow window is also right for any staging pick made
    ;; outside the sibling-reordering load families (the pair-emission flag),
    ;; a lone gep/load/store included: nothing was written ahead of its
    ;; point, so the at-point occupancy is exact.
    [narrow-mask : i64
      (if (compiler-backend-scavenge-narrow-window? function-state)
        (compiler-backend-scavenge-occupied-mask-over-range
          function-state
          point
          (+ point 2))
        (compiler-backend-scavenge-occupied-mask-over-range
          function-state
          point
          hi-point))]
    [reg : String
      (compiler-backend-scavenge-pick-with-mask
        function-state
        commit
        (compiler-backend-scavenge-occupied-mask-over-range
          function-state
          point
          hi-point)
        narrow-mask
        ex
        ex-n
        fallback)]
    reg))

(define (compiler-backend-scavenge-reg
  [dst-var : i64]
  [exclude : (__tl_dyn-array String)]
  [exclude-n : i64]
  [fallback : String]
  [backend-state : be_state.CompilerBackendState]) : String
  (compiler-backend-scavenge-reg-pick
    dst-var
    exclude
    exclude-n
    fallback
    true
    backend-state))

;; No-dst scavenge: same as scavenge-reg but the point comes from the drift-proof
;; per-instruction position (post-base - length(current-instrs)) instead of a dst
;; var's def point -- for instructions that define no variable (compare-branch,
;; GEP store/copy, etc.). Returns `fallback` until the fallback register is pooled.
(define (compiler-backend-scavenge-reg-here
  [exclude : (__tl_dyn-array String)]
  [exclude-n : i64]
  [fallback : String]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [function-state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state backend-state)]
    [point : i64
      (be_state.compiler-backend-function-state-emission-point function-state)]
    [reg : String
      (compiler-backend-scavenge-pick-with-mask
        function-state
        true
        (compiler-backend-scavenge-occupied-mask-at-point function-state point)
        (compiler-backend-scavenge-occupied-mask-at-point function-state point)
        exclude
        exclude-n
        fallback)]
    reg))

;; Packed control-mnemonic classification shared by the RSP rebase audit and
;; the dead-frame-store sweep, so neither asks the generic byte-range
;; comparator about the same small fixed set repeatedly for every assembly
;; line. Values are deliberately scalar so callers can derive all predicates
;; from one classification without allocating a token object.
(define compiler-backend-control-mnemonic-none : i64
  0)
(define compiler-backend-control-mnemonic-movq : i64
  1)
(define compiler-backend-control-mnemonic-leaq : i64
  2)
(define compiler-backend-control-mnemonic-push : i64
  3)
(define compiler-backend-control-mnemonic-pop : i64
  4)
(define compiler-backend-control-mnemonic-leave : i64
  5)
(define compiler-backend-control-mnemonic-ret : i64
  6)
(define compiler-backend-control-mnemonic-jmp : i64
  7)
(define compiler-backend-control-mnemonic-subq : i64
  8)
(define compiler-backend-control-mnemonic-addq : i64
  9)
(define compiler-backend-control-mnemonic-syscall : i64
  10)

(define (compiler-backend-control-mnemonic-kind
  [data : (Ptr u8)]
  [start : i64]
  [len : i64]) : i64
  (if (< len 3)
    compiler-backend-control-mnemonic-none
    (let
      [b0 : i64 (be_state.compiler-backend-peephole-byte-at data start)]
      [b1 : i64 (be_state.compiler-backend-peephole-byte-at data (+ start 1))]
      [b2 : i64 (be_state.compiler-backend-peephole-byte-at data (+ start 2))]
      [key3 : i64 (+ b0 (+ (* b1 256) (* b2 65536)))]
      (cond
        [(= len 3)
          (cond
            [(= key3 7368560) compiler-backend-control-mnemonic-pop]
            [(= key3 7628146) compiler-backend-control-mnemonic-ret]
            [(= key3 7368042) compiler-backend-control-mnemonic-jmp]
            [else compiler-backend-control-mnemonic-none])]
        [(>= len 4)
          (let
            [b3 : i64
              (be_state.compiler-backend-peephole-byte-at data (+ start 3))]
            [key4 : i64 (+ key3 (* b3 16777216))]
            (cond
              [(= len 4)
                (cond
                  [(= key4 1903587181) compiler-backend-control-mnemonic-movq]
                  [(= key4 1902208364) compiler-backend-control-mnemonic-leaq]
                  [(= key4 1752397168) compiler-backend-control-mnemonic-push]
                  [(= key4 1903193968) compiler-backend-control-mnemonic-pop]
                  [(= key4 1902278003) compiler-backend-control-mnemonic-subq]
                  [(= key4 1902404705) compiler-backend-control-mnemonic-addq]
                  [else compiler-backend-control-mnemonic-none])]
              [(= len 5)
                (let
                  [b4 : i64
                    (be_state.compiler-backend-peephole-byte-at
                      data
                      (+ start 4))]
                  (cond
                    [(and (= key4 1752397168) (= b4 113))
                      compiler-backend-control-mnemonic-push]
                    [(and (= key4 1986094444) (= b4 101))
                      compiler-backend-control-mnemonic-leave]
                    [else compiler-backend-control-mnemonic-none]))]
              [(= len 7)
                (if (and
                  (= key4 1668512115)
                  (=
                    (be_state.compiler-backend-peephole-byte-at
                      data
                      (+ start 4))
                    97)
                  (=
                    (be_state.compiler-backend-peephole-byte-at
                      data
                      (+ start 5))
                    108)
                  (=
                    (be_state.compiler-backend-peephole-byte-at
                      data
                      (+ start 6))
                    108))
                  compiler-backend-control-mnemonic-syscall
                  compiler-backend-control-mnemonic-none)]
              [else compiler-backend-control-mnemonic-none]))]
        [else compiler-backend-control-mnemonic-none]))))

(define (compiler-backend-red-zone?
  [backend-state : be_state.CompilerBackendState]) : bool
  (be_state.compiler-backend-function-state-bool?
    (be_state.compiler-backend-state-function-state backend-state)
    be_state.compiler-backend-function-bool-red-zone))

(define (compiler-backend-rsp-rebase-push-sub
  [backend-state : be_state.CompilerBackendState]
  [frame : i64]
  [push-count : i64]) : i64
  (if (or
    (compiler-backend-red-zone? backend-state)
    (and
      (be_state.compiler-backend-function-state-bool?
        (be_state.compiler-backend-state-function-state backend-state)
        be_state.compiler-backend-function-bool-fpo-bare-frame)
      (= push-count 0)))
    0
    (+
      frame
      (if (or
        (= (bit-and push-count 1) 1)
        (and
          (= frame 0)
          (not
            (be_state.compiler-backend-function-state-bool?
              (be_state.compiler-backend-state-function-state backend-state)
              be_state.compiler-backend-function-bool-call-align-needed))))
        0
        8))))

;; First-class arena runtime helpers and the arena poison debug toggle
;; are always emitted, so they are provided runtime symbols (resolve to
;; their raw names, not the mangled `_tl_tl_arena_*`).
(define (compiler-backend-plan-provides-id?
  [plan : be_state.CompilerBackendRuntimePlan]
  [name-id : i64]) : bool
  (or
    (cbi.compiler-builtin-backend-runtime-always-provided-id? name-id)
    (cbi.compiler-builtin-backend-runtime-always-provided-tail-id? name-id)
    (compiler-backend-plan-provides-rest-id? plan name-id)))

(define (compiler-backend-plan-provides-rest-id?
  [plan : be_state.CompilerBackendRuntimePlan]
  [name-id : i64]) : bool
  (match plan
    [(Plan
        alloc
        substring
        str-view
        concat
        provides-int-to-string
        region-mark
        region-reset
        provides-tail)
      (or
        (be_state.backend-or8
          (and alloc (cbi.compiler-builtin-backend-tl-alloc-id? name-id))
          (and
            region-mark
            (cbi.compiler-builtin-backend-tl-region-mark-id? name-id))
          (and
            region-reset
            (cbi.compiler-builtin-backend-tl-region-reset-id? name-id))
          (and
            substring
            (cbi.compiler-builtin-backend-tl-substring-id? name-id))
          (and str-view (cbi.compiler-builtin-backend-tl-str-view-id? name-id))
          (and concat (cbi.compiler-builtin-backend-runtime-concat-id? name-id))
          (and
            provides-int-to-string
            (cbi.compiler-builtin-backend-tl-int-to-string-id? name-id))
          (and
            (be_state.compiler-backend-runtime-tail-profile? provides-tail)
            (cbi.compiler-builtin-backend-runtime-profile-id? name-id)))
        (and
          (be_state.compiler-backend-runtime-tail-arena-debug? provides-tail)
          (cbi.compiler-builtin-backend-runtime-arena-debug-id? name-id)))]))

;; First index of `target` in [start, end), or `end` when the byte is absent.
;;
;; Every pass over emitted assembly asks this question of the same bytes: where
;; is the next line end, token end, `%` or `(`? Keep this scan inline so the
;; assembly walks need no runtime call for each delimiter.
;;
;; `end` is the not-found answer (not -1) because that is what the line walk
;; wants -- an unterminated last line ends at the text end -- and every other
;; caller already carries the same bound it passed in, so it tests `>= stop`.
;;
;; `(x - ones) & ~x & highs` is non-zero exactly when some byte of `x` is zero,
;; so xoring the word with the broadcast target turns "byte equals target" into
;; "byte is zero". The word loop stops eight bytes short of `end` and the tail
;; runs byte-wise, so no load ever reaches past the caller's range. Both loops
;; read only bytes the byte-at-a-time scan would have read.
;;
;; The hit position needs no second scan: the lowest set bit of the mask sits at
;; bit 8k+7 of the first matching byte k, and multiplying that isolated bit
;; (shifted down to 2^8k, masked because the arithmetic shift of the k=7 case
;; smears the sign) by the descending byte-index table 0x0001020304050607 lifts
;; that table's byte 7-k -- which holds exactly k -- into the product's top byte.
(define (compiler-backend-peephole-scan-byte-range
  [data : (Ptr u8)]
  [start : i64]
  [end : i64]
  [target : i64]) : i64
  (let
    ;; 0x0101010101010101, 0x8080808080808080, 2^57-1, 0x0001020304050607
    [ones : i64 72340172838076673]
    [highs : i64 -9187201950435737472]
    [low-bit-mask : i64 144115188075855871]
    [byte-index : i64 283686952306183]
    [broadcast : i64 (* target ones)]
    [limit : i64 (- end 8)]
    [i : i64 start]
    (while (<= i limit)
      (let
        [word : i64
          (unsafe
            (ptr-read (ptr-cast (ptr-offset data i) : (Ptr i64))))]
        [x : i64 (bit-xor word broadcast)]
        [hits : i64 (bit-and (bit-and (- x ones) (bit-xor x -1)) highs)]
        (when
          (not (= hits 0))
          (return
            (+
              i
              (shr
                (*
                  (bit-and (shr (bit-and hits (- 0 hits)) 7) low-bit-mask)
                  byte-index)
                56))))
        (+= i 8)))
    (while (< i end)
      (if (= (be_state.compiler-backend-peephole-byte-at data i) target)
        (return i)
        (+= i 1)))
    end))

(define (compiler-backend-peephole-register-operand?
  [operand : (& operand str)]) : bool
  (and
    (> (string.string-length operand) 0)
    (= (string.string-ref operand 0) '%')))

;; True iff the byte range [s,e) of `data` equals the literal `lit` exactly.
(define (compiler-backend-peephole-range-eq?
  [data : (Ptr u8)]
  [s : i64]
  [e : i64]
  [lit : (& lit str)]) : bool
  (let
    [ln : i64 (string.string-length lit)]
    (if (not (= (- e s) ln))
      false
      (let
        [ld : (Ptr u8)
          (unsafe
            (string-data lit))]
        [k : i64 0]
        [ok : bool true]
        (while (and ok (< k ln))
          (if (=
            (be_state.compiler-backend-peephole-byte-at data (+ s k))
            (be_state.compiler-backend-peephole-byte-at ld k))
            unit
            (set! ok false))
          (+= k 1))
        ok))))

(define (compiler-backend-peephole-ranges-eq?
  [left : (Ptr u8)]
  [ls : i64]
  [le : i64]
  [right : (Ptr u8)]
  [rs : i64]
  [re : i64]) : bool
  (let
    [len : i64 (- le ls)]
    (if (not (= len (- re rs)))
      false
      (let
        [i : i64 0]
        [same : bool true]
        (while (and same (< i len))
          (if (=
            (be_state.compiler-backend-peephole-byte-at left (+ ls i))
            (be_state.compiler-backend-peephole-byte-at right (+ rs i)))
            unit
            (set! same false))
          (+= i 1))
        same))))

(define (compiler-backend-string-prefix-at?
  [text : (& text str)]
  [prefix : (& prefix str)]
  [start : i64]) : bool
  (let
    [text-len : i64 (string.string-length text)]
    [prefix-len : i64 (string.string-length prefix)]
    (if (< start 0)
      false
      (if (> (+ start prefix-len) text-len)
        false
        (let
          [i : i64 0]
          [ok : bool true]
          (while ok
            (if (< i prefix-len)
              (if (=
                (string.string-ref text (+ start i))
                (string.string-ref prefix i))
                (+= i 1)
                (set! ok false))
              (set! ok false)))
          (= i prefix-len))))))

(define (compiler-backend-string-contains?
  [text : (& text str)]
  [needle : (& needle str)]) : bool
  (let
    [text-len : i64 (string.string-length text)]
    [needle-len : i64 (string.string-length needle)]
    (if (= needle-len 0)
      true
      (let
        [i : i64 0]
        [found : bool false]
        [done : bool false]
        (while (not done)
          (if (<= (+ i needle-len) text-len)
            (if (compiler-backend-string-prefix-at? text needle i)
              (begin
                (set! found true)
                (set! done true))
              (+= i 1))
            (set! done true)))
        found))))