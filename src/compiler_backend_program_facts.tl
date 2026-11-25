(import compiler_backend_operands as be_operand)
(import compiler_backend_state as be_state)
(import stdlib.iterator)
(import stdlib.io)
(import compiler_ir_types)
(import compiler_ast_types)
(import compiler_typecheck_core)
(import compiler_builtin_ids as cbi)
(import compiler_diagnostic)
(import compiler_abi)
(import compiler_regalloc)
(import compiler_liveness)
(import compiler_profile_state as profile_state)
(import compiler_backend_runtime_linux as runtime_linux)
(import compiler_backend_runtime_windows as runtime_windows)
(import stdlib.text_buf)
(import stdlib.hashmap)
(import (hashmap.hashmap String i64) as backend_string_i64_map)
(import (hashmap.hashmap i64 i64) as backend_i64_i64_map)
(import stdlib.string)
(import compiler_str_cat as str_cat)
(import compiler_owned_view as owned_view)

(define (compiler-backend-avx2-i64-lane-id-label) : String
  ".L_tl_lane_id_i64x4")

(define (compiler-backend-avx512-i64-lane-id-label) : String
  ".L_tl_lane_id_i64x8")

(define (compiler-backend-lane-id-avx512-i64-shape-ok?
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]
  [lanes : i64]) : bool
  (match elem-ty
    [(or (I64) (U64)) (= lanes 8)]
    [_ false]))

(define (compiler-backend-lane-id-avx2-i64-shape-ok?
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]
  [lanes : i64]) : bool
  (match elem-ty
    [(or (I64) (U64)) (= lanes 4)]
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
    .quad 8
    .quad 9
    .quad 10
    .quad 11
    .quad 12
    .quad 13
    .quad 14
    .quad 15
")

(define (compiler-backend-avx2-i64-lane-id-data) : String
  "    .quad 0
    .quad 1
    .quad 2
    .quad 3
    .quad 4
    .quad 5
    .quad 6
    .quad 7
")

(define (compiler-backend-emit-avx2-i64-lane-id-rodata-into
  [buf : text_buf.TextBuf]) : text_buf.TextBuf
  (text_buf.append
    (text_buf.append
      (text_buf.append
        (text_buf.append buf "    .section .rodata\n    .balign 32\n")
        (compiler-backend-avx2-i64-lane-id-label))
      ":\n")
    (compiler-backend-avx2-i64-lane-id-data)))

(define (compiler-backend-emit-avx512-i64-lane-id-rodata-into
  [buf : text_buf.TextBuf]) : text_buf.TextBuf
  (text_buf.append
    (text_buf.append
      (text_buf.append
        (text_buf.append buf "    .section .rodata\n    .balign 64\n")
        (compiler-backend-avx512-i64-lane-id-label))
      ":\n")
    (compiler-backend-avx512-i64-lane-id-data)))

(define (compiler-backend-emit-lane-id-rodata-into
  [uses-avx2-i64-lane-id : bool]
  [uses-avx512-i64-lane-id : bool]
  [buf : text_buf.TextBuf]) : text_buf.TextBuf
  (let
    [avx2-buf : text_buf.TextBuf
      (if uses-avx2-i64-lane-id
        (compiler-backend-emit-avx2-i64-lane-id-rodata-into buf)
        buf)]
    (if uses-avx512-i64-lane-id
      (compiler-backend-emit-avx512-i64-lane-id-rodata-into avx2-buf)
      avx2-buf)))

(define (compiler-backend-frame-size [vars : i64]) : i64
  (be_operand.compiler-backend-round-up-16 (* vars 8)))

;; Physical words of the lowered signature, including sret and both words of
;; register groups. Platform and Internal share positions; only positions 4/5
;; move from the incoming stack to registers, and later stack words shift.
(defstruct CompilerBackendCEntryPlan
  (float-words (__tl_dyn-array bool))
  (len i64)
  (frame i64))

(define (compiler-backend-c-entry-plan
  [type-segment-bases : i64]
  [index : be_state.CompilerBackendProgramIndex]
  [params : (& params compiler_ir_types.CompilerIrParamSeq)]) : CompilerBackendCEntryPlan
  (let
    [words : (__tl_dyn-array bool) (__tl_make-array bool (* params.len 2))]
    [len : i64 0]
    (for [i (iterator.range 0 params.len)]
      (match (compiler_ir_types.compiler-ir-param-seq-borrow params i)
        [(Param _ ty _)
          (if (compiler-backend-group-type? type-segment-bases index ty)
            (begin
              (set!
                (array-ref words len)
                (compiler-backend-group-word-sse? type-segment-bases index ty 0))
              (set!
                (array-ref words (+ len 1))
                (compiler-backend-group-word-sse? type-segment-bases index ty 1))
              (set! len (+ len 2)))
            (begin
              (set!
                (array-ref words len)
                (be_operand.compiler-backend-float-type? ty))
              (set! len (+ len 1))))]))
    (CompilerBackendCEntryPlan
      words
      len
      (-
        (be_operand.compiler-backend-round-up-16
          (+
            8
            (*
              8
              (if (> len 6)
                (- len 6)
                0))))
        8))))

(define (compiler-backend-c-entry-shared-needed?
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [index : be_state.CompilerBackendProgramIndex]
  [functions : (& functions compiler_ir_types.CompilerIrFunctionSeq)]) : bool
  (when
    (compiler_abi.compiler-abi-platform-entry-bridge?
      (be_state.compiler-backend-target-abi target))
    (for [slot
      (iterator.range
        0
        (compiler_ir_types.compiler-ir-function-seq-count functions))]
      (match (compiler_ir_types.compiler-ir-function-seq-borrow functions slot)
        [(Function name params _ _ _ _)
          (when
            (be_operand.compiler-backend-index-c-export? index name)
            (let
              [raw : String
                (be_operand.compiler-backend-index-extern-link-symbol
                  index
                  name)]
              (when
                (not (compiler-backend-inline-memory-call-name? (& raw)))
                (let
                  [plan : CompilerBackendCEntryPlan
                    (compiler-backend-c-entry-plan
                      type-segment-bases
                      index
                      params)]
                  (when (<= plan.len 4) (return true))))))])))
  false)

(define (compiler-backend-c-entry-incoming-offset
  [plan : (& plan CompilerBackendCEntryPlan)]
  [position : i64]) : i64
  ;; Return address plus the two saved GP registers precede the old home area.
  (+ plan.frame 24 (* position 8)))

(define (compiler-backend-state-slot-cache-epoch-bump!
  [state : be_state.CompilerBackendState]) : unit
  (let
    [data : (MutPtr be_state.CompilerBackendStateData)
      (be_state.compiler-backend-state-ptr state)]
    (unsafe
      (set! (deref data).slot-cache-epoch (+ (deref data).slot-cache-epoch 1)))))

(define (compiler-backend-state-slot-cache-reset!
  [state : be_state.CompilerBackendState]) : unit
  ;; Reset is intentionally epoch-only.  In particular, a fresh state reset
  ;; must not create its lazy arena or any fixed-capacity arrays.
  (compiler-backend-state-slot-cache-epoch-bump! state))

(define (compiler-backend-export-symbol-head-char? [c : char]) : bool
  (or (and (>= c 'A') (<= c 'Z')) (and (>= c 'a') (<= c 'z')) (= c '_')))

(define (compiler-backend-export-symbol-tail-char? [c : char]) : bool
  (or (compiler-backend-export-symbol-head-char? c) (and (>= c '0') (<= c '9'))))

(define (compiler-backend-valid-export-symbol? [name : (& name str)]) : bool
  (let
    [n : i64 (string.string-length name)]
    [i : i64 1]
    [valid : bool (> n 0)]
    (if valid
      (set!
        valid
        (compiler-backend-export-symbol-head-char? (string.string-ref name 0)))
      unit)
    (while (and valid (< i n))
      (if (compiler-backend-export-symbol-tail-char? (string.string-ref name i))
        unit
        (set! valid false))
      (+= i 1))
    valid))

(define (compiler-backend-closure-entry-label [name : String]) : String
  (str_cat.str-cat
    ".L_tl_fn_entry_"
    (be_operand.compiler-backend-asm-safe-symbol name)))

(define (compiler-backend-function-label-scope
  [index : be_state.CompilerBackendProgramIndex]
  [name : i64]) : String
  (match (be_operand.compiler-backend-index-function-slot index name)
    [(LookupFound slot) (str_cat.str-cat "f" (string.int->string slot) "")]
    [(LookupMissing)
      (be_state.compiler-backend-state-user-symbol-id index.backend-state name)]))

(define (compiler-backend-type-signed?
  [type-segment-bases : i64]
  [ty : (& ty compiler_ast_types.AstType)]) : bool
  (match ty
    [(or (I64) (I32) (I16) (I8)) true]
    ;; A region-tagged scalar has its inner type's signedness (#9688).
    [(or (Region _ inner) (Invalidate _ inner))
      (compiler-backend-type-signed?
        type-segment-bases
        (&
          (compiler_ast_types.ast-type-segment-bases-get
            type-segment-bases
            inner)))]
    [_ false]))

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
  (str_cat.str-cat
    "\\"
    (compiler-backend-octal-digit (/ n 64))
    (compiler-backend-octal-digit (% (/ n 8) 8))
    (compiler-backend-octal-digit (% n 8))))

(define (compiler-backend-escape-string-byte
  [text : (& text str)]
  [idx : i64]
  [c : char]) : String
  (cond
    [(= c '"') "\\\""]
    [(= c '\\') "\\\\"]
    [(= c '\n') "\\n"]
    [(= c '\t') "\\t"]
    [(= c '\r') "\\r"]
    [(and (>= c ' ') (<= c '~')) (string.substring text idx 1)]
    [else
      (compiler-backend-octal-escape (be_state.compiler-backend-char-code c))]))

(define (compiler-backend-string-byte-raw? [c : char]) : bool
  (cond
    [(= c '"') false]
    [(= c '\\') false]
    [(< c ' ') false]
    [(> c '~') false]
    [else true]))

(define (compiler-backend-escape-string [text : String]) : String
  (let
    [i : i64 0]
    [n : i64 (string.string-length text)]
    [buf : text_buf.TextBuf (text_buf.empty)]
    [start : i64 0]
    [escaped : bool false]
    (while (< i n)
      (let
        [c : char (string.string-ref text i)]
        (if (compiler-backend-string-byte-raw? c)
          (+= i 1)
          (begin
            (if (< start i)
              (set!
                buf
                (text_buf.append buf (string.substring text start (- i start))))
              unit)
            (set!
              buf
              (text_buf.append
                buf
                (compiler-backend-escape-string-byte text i c)))
            (+= i 1)
            (set! start i)
            (set! escaped true)))))
    (if escaped
      (begin
        (if (< start n)
          (set!
            buf
            (text_buf.append buf (string.substring text start (- n start))))
          unit)
        (text_buf.render buf))
      text)))

(define (compiler-backend-string-data-label [text : (& text str)]) : String
  (str_cat.str-cat
    ".L_tl_str_data_"
    (be_operand.compiler-backend-string-label-suffix text)))

(define (compiler-backend-bytes-data-label [text : (& text str)]) : String
  (str_cat.str-cat
    ".L_tl_bin_data_"
    (be_operand.compiler-backend-string-label-suffix text)))

(define (compiler-backend-f64-label [bits : u64]) : String
  (let
    [ty (compiler_ast_types.AstType.F64)]
    (be_operand.compiler-backend-float-label ty bits)))

(define (compiler-backend-f64-sign-bit-label) : String
  ".L_tl_f64_sign_bit")

(define (compiler-backend-f32-sign-bit-label) : String
  ".L_tl_f32_sign_bit")

;; GAP7: like address-base-filter but ADMITS a %rbp home as a direct base. Used
;; at the CONST-offset fused gep sites where the base occupies the memory
;; operand's BASE slot ALONE (no separate SIB index) -- there the %rbp base is
;; spelled `disp( %rbp)` (compiler-backend-mem-base-address). The
;; DYNAMIC-index sites keep address-base-filter: a %rbp base there would need
;; the SIB index slot (already taken by the gep index), so it stays staged.
(define (compiler-backend-address-base-filter-direct [home : String]) : String
  home)

(define (compiler-backend-state-set-emission-symbols!
  [state : be_state.CompilerBackendState]
  [symbols : be_state.CompilerBackendEmissionSymbols]) : unit
  (unsafe
    (set!
      (deref (be_state.compiler-backend-state-ptr state)).emission-symbols
      symbols)))

(define (compiler-backend-function-or-global-addr-symbol
  [program-index : be_state.CompilerBackendProgramIndex]
  [name : i64]) : String
  (if (be_operand.compiler-backend-index-function-defines? program-index name)
    (be_operand.compiler-backend-function-symbol-index program-index name)
    (be_operand.compiler-backend-global-symbol-index program-index name)))

(define (compiler-backend-global-type-lookup
  [types : be_state.CompilerBackendGlobalTypeTable]
  [name : i64]) : compiler_regalloc.CompilerRegMaybeType
  (match types
    [(Empty) (No)]
    [(Dense ids values)
      (match (backend_i64_i64_map.get
        (& ids)
        (compiler_ir_types.compiler-ir-symbol-id name))
        [(LookupFound index)
          (Some
            (be_state.compiler-backend-global-array-element-shared-view
              values
              index))]
        [(LookupMissing) (No)])]))

(define (compiler-backend-global-type-count
  [globals : compiler_ir_types.CompilerIrGlobalSeq]) : i64
  (compiler_ir_types.compiler-ir-global-seq-count globals))

(define (compiler-backend-global-types-fill
  [globals : compiler_ir_types.CompilerIrGlobalSeq]
  [ids : backend_i64_i64_map.Map]
  [values : (&mut values (__tl_dyn-array compiler_ast_types.AstType))]
  [index : i64]) : backend_i64_i64_map.Map
  (if (>= index globals.len)
    ids
    (match (compiler_ir_types.compiler-ir-global-seq-ref globals index)
      [(Global name ty _)
        (let
          [next-ids : backend_i64_i64_map.Map ids]
          (set! (array-ref values index) ty)
          (backend_i64_i64_map.insert-ref!
            (&mut next-ids)
            (compiler_ir_types.compiler-ir-symbol-id name)
            index)
          (compiler-backend-global-types-fill
            globals
            next-ids
            values
            (+ index 1)))])))

(define (compiler-backend-global-types
  [globals : compiler_ir_types.CompilerIrGlobalSeq]) : be_state.CompilerBackendGlobalTypeTable
  (let
    [count : i64
      (compiler-backend-global-type-count
        (be_state.compiler-backend-global-shared-view globals))]
    [values : (__tl_dyn-array compiler_ast_types.AstType)
      (__tl_make-array compiler_ast_types.AstType count)]
    (if (= count 0)
      Empty
      (Dense
        (compiler-backend-global-types-fill
          globals
          (backend_i64_i64_map.with-capacity (+ (* count 2) 16))
          (&mut values)
          0)
        values))))

(define (compiler-backend-value-type
  [types : compiler_regalloc.CompilerRegVarTypes]
  [global-types : be_state.CompilerBackendGlobalTypeTable]
  [value : compiler_ir_types.CompilerIrValue]) : compiler_regalloc.CompilerRegMaybeType
  (match value
    [(Var id) (compiler_regalloc.compiler-reg-var-types-lookup types id)]
    [(Global name) (compiler-backend-global-type-lookup global-types name)]
    [(or (GlobalAddr _) (Function _)) (Some (U64))]
    [(I64 _) (Some (I64))]
    [(Bool _) (Some (Bool))]
    [(Char _) (Some (Char))]
    [(F64 _) (Some (F64))]
    [(String _) (Some (String))]
    [(Bytes _) (Some (compiler_ast_types.ast-ty-dyn-array (& (U8))))]
    [_ (No)]))

(define (compiler-backend-bit-test-op?
  [op : (& op compiler_ir_types.CompilerIrBinOp)]) : bool
  (match op
    [(or (BitTestEq) (BitTestNe)) true]
    [_ false]))

(define (compiler-backend-compare-op?
  [op : (& op compiler_ir_types.CompilerIrBinOp)]) : bool
  (match op
    [(or (Eq) (Ne) (Lt) (Le) (Gt) (Ge) (BitTestEq) (BitTestNe)) true]
    [_ false]))

(define (compiler-backend-compare-uses-zero-test?
  [op : (& op compiler_ir_types.CompilerIrBinOp)]) : bool
  (and
    (compiler-backend-compare-op? op)
    (not (compiler-backend-bit-test-op? op))))

;; Minimal exclude for an addressing-base scavenge: the base register only holds
;; a pointer that is immediately dereferenced and dead after, so nothing extra
;; needs excluding, and it must not exclude the common caller-saved fallbacks.
(define (compiler-backend-addr-scavenge-exclude) : (__tl_dyn-array String)
  (__tl_make-array String 0))

(define (compiler-backend-copy-address [disp : i64] [reg : String]) : String
  (be_operand.compiler-backend-mem-base-address disp reg))

(define (compiler-backend-call-args-count
  [args : compiler_ir_types.CompilerIrCallArgs]) : i64
  (match args
    [(Nil) 0]
    [(One _) 1]
    [(Two _ _) 2]
    [(or (Array values) (Sret values _)) (array-length values)]))

(define (compiler-backend-call-arg-at
  [args : (& args compiler_ir_types.CompilerIrCallArgs)]
  [index : i64]) : compiler_ir_types.CompilerIrValue
  (let
    [args : compiler_ir_types.CompilerIrCallArgs
      (owned_view.compiler-owned-reference-shared-view args)]
    (match args
      [(Nil) (Unit)]
      [(One value)
        (if (= index 0)
          value
          (Unit))]
      [(Two a b)
        (if (= index 0)
          a
          (if (= index 1)
            b
            (Unit)))]
      [(or (Array values) (Sret values _))
        (owned_view.compiler-owned-element-view values index)])))

(define (compiler-backend-call-register-count
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]) : i64
  (compiler_abi.compiler-abi-gp-arg-register-count
    (be_state.compiler-backend-target-abi target)
    convention))

(define (compiler-backend-param-type-list-from
  [params : (& compiler_ir_types.CompilerIrParamSeq)]
  [position : i64]) : compiler_ast_types.AstTypeList
  (if (>= position params.len)
    (compiler_ast_types.ast-type-list-new)
    (match (compiler_ir_types.compiler-ir-param-seq-borrow params position)
      [(Param _ ty _)
        (compiler_ast_types.ast-type-cons
          (& ty)
          (& (compiler-backend-param-type-list-from params (+ position 1))))])))

(define (compiler-backend-param-type-list
  [params : compiler_ir_types.CompilerIrParamSeq]) : compiler_ast_types.AstTypeList
  (compiler-backend-param-type-list-from params 0))

(define (compiler-backend-type-list-count
  [types : (& types compiler_ast_types.AstTypeList)]) : i64
  (compiler_ast_types.ast-type-list-len (& types)))

(define (compiler-backend-function-seq-count
  [functions : (& functions compiler_ir_types.CompilerIrFunctionSeq)]) : i64
  functions.len)

(define (compiler-backend-extern-seq-count
  [externs : compiler_ir_types.CompilerIrExternSeq]) : i64
  (compiler_ir_types.compiler-ir-extern-seq-count externs))

(define (compiler-backend-program-index-bind-name
  [backend-state : be_state.CompilerBackendState]
  [ids : backend_i64_i64_map.Map]
  [name : i64]
  [index : i64]) : backend_i64_i64_map.Map
  (let
    [name-id : i64 (compiler_ir_types.compiler-ir-symbol-id name)]
    [out : backend_i64_i64_map.Map ids]
    (if (< name-id 0)
      (io.panic
        (str_cat.str-cat
          "backend: IR name has no pre-existing symbol id: "
          (be_state.compiler-backend-symbol-text-state backend-state name)))
      (begin
        (backend_i64_i64_map.insert-ref! (&mut out) name-id index)
        out))))

(define (compiler-backend-program-index-bind-extern-id
  [ids : backend_i64_i64_map.Map]
  [name-id : i64]
  [index : i64]) : backend_i64_i64_map.Map
  (let
    [out : backend_i64_i64_map.Map ids]
    (if (< name-id 0)
      (io.panic "backend: extern has no pre-existing symbol id")
      (begin
        (backend_i64_i64_map.insert-ref! (&mut out) name-id index)
        out))))

(define (compiler-backend-program-index-bind-extern-ids
  [ids : backend_i64_i64_map.Map]
  [name-id : i64]
  [source-name-id : i64]
  [index : i64]) : backend_i64_i64_map.Map
  (compiler-backend-program-index-bind-extern-id
    (compiler-backend-program-index-bind-extern-id ids name-id index)
    source-name-id
    index))

(define (compiler-backend-program-index-functions-into
  [backend-state : be_state.CompilerBackendState]
  [functions : compiler_ir_types.CompilerIrFunctionSeq]
  [ids : backend_i64_i64_map.Map]
  [names : (__tl_dyn-array String)]
  [signatures : (__tl_dyn-array be_state.CompilerBackendMaybeSignature)]
  [index : i64]) : backend_i64_i64_map.Map
  (compiler-backend-program-index-function-seq-into
    backend-state
    functions
    ids
    names
    signatures
    index
    0))

(define (compiler-backend-program-index-function-seq-into
  [backend-state : be_state.CompilerBackendState]
  [functions : compiler_ir_types.CompilerIrFunctionSeq]
  [ids : backend_i64_i64_map.Map]
  [names : (__tl_dyn-array String)]
  [signatures : (__tl_dyn-array be_state.CompilerBackendMaybeSignature)]
  [out-index : i64]
  [seq-index : i64]) : backend_i64_i64_map.Map
  (if (>=
    seq-index
    (compiler_ir_types.compiler-ir-function-seq-count functions))
    ids
    (match (owned_view.compiler-owned-element-view functions.slots seq-index)
      [(Function name params ret-ty _ _ _)
        (set!
          (array-ref names out-index)
          (be_state.compiler-backend-symbol-text-state backend-state name))
        (set!
          (array-ref signatures out-index)
          (be_state.CompilerBackendMaybeSignature.Some
            (compiler-backend-param-type-list params)
            ret-ty))
        (compiler-backend-program-index-function-seq-into
          backend-state
          functions
          (compiler-backend-program-index-bind-name
            backend-state
            ids
            name
            out-index)
          names
          signatures
          (+ out-index 1)
          (+ seq-index 1))])))

(define (compiler-backend-program-index-extern-signature
  [type-segment-bases : i64]
  [ty : compiler_ast_types.AstType]) : be_state.CompilerBackendMaybeSignature
  (match ty
    [(or (CFunc signature _) (Region _ signature))
      (compiler-backend-program-index-extern-signature
        type-segment-bases
        (compiler_ast_types.ast-type-segment-bases-get
          type-segment-bases
          signature))]
    [(Func args ret-ty)
      (Some
        (deref args)
        (compiler_ast_types.ast-type-segment-bases-get
          type-segment-bases
          ret-ty))]
    [_ (No)]))

(define (compiler-backend-program-index-extern-call-info
  [type-segment-bases : i64]
  [ty : compiler_ast_types.AstType]
  [abi : compiler_ast_types.AstExternAbi]) : i64
  (let
    [c-abi? : bool (compiler_ast_types.ast-extern-abi-c? (& abi))]
    [aggregate-params? : bool
      (if c-abi?
        (match (& ty)
          [(Func args _)
            (compiler-backend-type-list-has-aggregate?
              type-segment-bases
              (deref args))]
          [_ false])
        false)]
    [fixed-count : i64
      (if (compiler_ast_types.ast-extern-abi-c-varargs? (& abi))
        (match ty
          [(Func args _) (compiler-backend-type-list-count (deref args))]
          [_ -1])
        -1)]
    (+
      (+
        (if c-abi?
          1
          0)
        (if aggregate-params?
          2
          0))
      (* (+ fixed-count 1) 4))))

(define (compiler-backend-program-index-extern-signatures-into
  [type-segment-bases : i64]
  [externs : compiler_ir_types.CompilerIrExternSeq]
  [function-ids : (& backend_i64_i64_map.Map)]
  [signature-ids : backend_i64_i64_map.Map]
  [names : (__tl_dyn-array String)]
  [signatures : (__tl_dyn-array be_state.CompilerBackendMaybeSignature)]
  [call-infos : (__tl_dyn-array i64)]
  [index : i64]) : backend_i64_i64_map.Map
  (compiler-backend-program-index-extern-signature-seq-into
    type-segment-bases
    externs
    function-ids
    signature-ids
    names
    signatures
    call-infos
    index
    0))

(define (compiler-backend-program-index-extern-signature-seq-into
  [type-segment-bases : i64]
  [externs : compiler_ir_types.CompilerIrExternSeq]
  [function-ids : (& backend_i64_i64_map.Map)]
  [signature-ids : backend_i64_i64_map.Map]
  [names : (__tl_dyn-array String)]
  [signatures : (__tl_dyn-array be_state.CompilerBackendMaybeSignature)]
  [call-infos : (__tl_dyn-array i64)]
  [out-index : i64]
  [seq-index : i64]) : backend_i64_i64_map.Map
  (if (>= seq-index (compiler_ir_types.compiler-ir-extern-seq-count externs))
    signature-ids
    (match (compiler_ir_types.compiler-ir-extern-seq-ref externs seq-index)
      [(Extern
          extern-name-id
          source-name-id
          extern-name
          ty
          abi
          link-symbol-id
          _
          _
          _
          _)
        (let
          [call-info : i64
            (compiler-backend-program-index-extern-call-info
              type-segment-bases
              (be_state.compiler-backend-global-shared-view ty)
              abi)]
          (set! (array-ref names out-index) extern-name)
          (set!
            (array-ref signatures out-index)
            (compiler-backend-program-index-extern-signature
              type-segment-bases
              ty))
          (set! (array-ref call-infos out-index) call-info)
          (when
            (be_operand.compiler-backend-extern-call-info-c-abi? call-info)
            ;; Function definitions take precedence over extern link aliases.
            (unless
              (backend_i64_i64_map.contains?
                function-ids
                (compiler_ir_types.compiler-ir-symbol-id extern-name-id))
              (compiler_regalloc.compiler-reg-add-platform-call-name!
                extern-name-id))
            (unless
              (backend_i64_i64_map.contains?
                function-ids
                (compiler_ir_types.compiler-ir-symbol-id source-name-id))
              (compiler_regalloc.compiler-reg-add-platform-call-name!
                source-name-id))
            (unless
              (backend_i64_i64_map.contains?
                function-ids
                (compiler_ir_types.compiler-ir-symbol-id link-symbol-id))
              (compiler_regalloc.compiler-reg-add-platform-call-name!
                link-symbol-id)))
          (when
            (compiler-backend-extern-call-info-aggregate-params? call-info)
            (compiler_regalloc.compiler-reg-add-c-memory-call-name!
              extern-name-id)
            (compiler_regalloc.compiler-reg-add-c-memory-call-name!
              source-name-id))
          (compiler-backend-program-index-extern-signature-seq-into
            type-segment-bases
            externs
            function-ids
            (compiler-backend-program-index-bind-extern-ids
              signature-ids
              extern-name-id
              source-name-id
              out-index)
            names
            signatures
            call-infos
            (+ out-index 1)
            (+ seq-index 1)))])))

;; Link symbols have their own intern identity, distinct from source identity.
(define (compiler-backend-program-index-extern-links-into
  [externs : compiler_ir_types.CompilerIrExternSeq]
  [link-references : backend_i64_i64_map.Map]
  [link-symbols : (__tl_dyn-array i64)]
  [provideds : (__tl_dyn-array bool)]
  [index : i64]) : backend_i64_i64_map.Map
  (compiler-backend-program-index-extern-link-seq-into
    externs
    link-references
    link-symbols
    provideds
    index
    0))

(define (compiler-backend-program-index-extern-link-seq-into
  [externs : compiler_ir_types.CompilerIrExternSeq]
  [link-references : backend_i64_i64_map.Map]
  [link-symbols : (__tl_dyn-array i64)]
  [provideds : (__tl_dyn-array bool)]
  [out-index : i64]
  [seq-index : i64]) : backend_i64_i64_map.Map
  (if (>= seq-index (compiler_ir_types.compiler-ir-extern-seq-count externs))
    link-references
    (match (compiler_ir_types.compiler-ir-extern-seq-borrow externs seq-index)
      [(Extern _ _ _ _ _ link-symbol _ provided _ _)
        (let
          [next-link-references : backend_i64_i64_map.Map link-references]
          (set! (array-ref link-symbols out-index) link-symbol)
          (set! (array-ref provideds out-index) provided)
          (backend_i64_i64_map.insert-ref!
            (&mut next-link-references)
            link-symbol
            out-index)
          (compiler-backend-program-index-extern-link-seq-into
            externs
            next-link-references
            link-symbols
            provideds
            (+ out-index 1)
            (+ seq-index 1)))])))

;; Logical extern names carry parser/generated identities.
(define (compiler-backend-program-index-extern-reference-names-into
  [externs : compiler_ir_types.CompilerIrExternSeq]
  [reference-ids : backend_i64_i64_map.Map]
  [index : i64]) : backend_i64_i64_map.Map
  (compiler-backend-program-index-extern-reference-name-seq-into
    externs
    reference-ids
    index
    0))

(define (compiler-backend-program-index-extern-reference-name-seq-into
  [externs : compiler_ir_types.CompilerIrExternSeq]
  [reference-ids : backend_i64_i64_map.Map]
  [out-index : i64]
  [seq-index : i64]) : backend_i64_i64_map.Map
  (if (>= seq-index (compiler_ir_types.compiler-ir-extern-seq-count externs))
    reference-ids
    (match (compiler_ir_types.compiler-ir-extern-seq-borrow externs seq-index)
      [(Extern extern-name-id source-name-id _ _ _ _ _ _ _ _)
        (compiler-backend-program-index-extern-reference-name-seq-into
          externs
          (compiler-backend-program-index-bind-extern-ids
            reference-ids
            extern-name-id
            source-name-id
            out-index)
          (+ out-index 1)
          (+ seq-index 1))])))

;; The aggregate type name a register-group value carries (for the
;; type-name -> word-count map). Empty for non-aggregate types.
(define (compiler-backend-nominal-name-id-display [name-id : i64]) : String
  (if (compiler_ir_types.compiler-ir-symbol-owned? name-id)
    (compiler_ir_types.compiler-ir-symbol-text name-id)
    (compiler_typecheck_core.tc-nominal-name-id-display name-id)))

(define (compiler-backend-aggregate-type-name
  [type-segment-bases : i64]
  [ty : compiler_ast_types.AstType]) : String
  (match ty
    [(or (Struct name) (StructArgs name _) (Enum name) (EnumArgs name _))
      (compiler-backend-nominal-name-id-display name)]
    [(Region _ inner)
      (compiler-backend-aggregate-type-name
        type-segment-bases
        (compiler_ast_types.ast-type-segment-bases-get type-segment-bases inner))]
    [_ ""]))

;; Internal ABI transport types are nominal Struct/StructArgs values whose
;; display name carries the physical convention.  Keep recognition separate
;; from ordinary aggregate-name handling: user structs (and C marker
;; aggregates) must never become private transports merely because their names
;; share a prefix.  All numeric fields are parsed with a bounded digit walk so
;; malformed/overflowing names fail closed instead of trapping in integer
;; conversion.
(define compiler-backend-abi-memory-prefix : String
  "__tl_internal_abi_mem_s")

(define (compiler-backend-abi-name-prefix-at?
  [name : (& name str)]
  [prefix : String]) : bool
  (let
    [prefix-len : i64 (string.string-length prefix)]
    (and
      (>= (string.string-length name) prefix-len)
      (string.eq (string.substring name 0 prefix-len) prefix))))

(define (compiler-backend-abi-memory-size-from-name [name : String]) : i64
  (let
    [prefix-len : i64 (string.string-length compiler-backend-abi-memory-prefix)]
    (if (not
      (compiler-backend-abi-name-prefix-at?
        name
        (be_state.compiler-backend-string-shared-view
          (& compiler-backend-abi-memory-prefix))))
      0
      (let
        [n : i64 (string.string-length name)]
        [i : i64 prefix-len]
        [value : i64 0]
        [digits : i64 0]
        [valid : bool true]
        [max-i64 : i64 9223372036854775807]
        ;; The size terminates at the required double-underscore delimiter.
        ;; Reject any other non-digit, missing digits, leading delimiter, or
        ;; arithmetic overflow before multiplying by ten.
        (while (and valid (< i n))
          (let
            [digit : i64 (cast (string.string-ref name i) : i64)]
            (if (and (>= digit 48) (<= digit 57))
              (let
                [d : i64 (- digit 48)]
                (if (or (> value (/ (- max-i64 d) 10)) (>= (+ i 1) n))
                  (set! valid false)
                  (begin
                    (set! value (+ (* value 10) d))
                    (+= digits 1)
                    (+= i 1))))
              (if (and
                (= digit 95)
                (< (+ i 1) n)
                (= (cast (string.string-ref name (+ i 1)) : i64) 95))
                (set! i n)
                (set! valid false)))))
        (if (and
          valid
          (> digits 0)
          (> value 0)
          ;; `i` reaches n only for a delimiter immediately followed by a
          ;; non-empty canonical key; the final suffix check below rejects a
          ;; bare prefix or a delimiter with no key.
          (< (+ prefix-len digits 2) n)
          (= (cast (string.string-ref name (+ prefix-len digits)) : i64) 95)
          (= (cast (string.string-ref name (+ prefix-len digits 1)) : i64) 95))
          value
          0)))))

(define (compiler-backend-abi-memory-size-ref
  [type-segment-bases : i64]
  [ty : (& ty compiler_ast_types.AstType)]) : i64
  (match ty
    [(or (Struct name) (StructArgs name _))
      (if (compiler_ir_types.compiler-ir-symbol-owned? name)
        (compiler-backend-abi-memory-size-from-name
          (compiler_ir_types.compiler-ir-symbol-text name))
        0)]
    [(Region _ inner)
      (compiler-backend-abi-memory-size-ref
        type-segment-bases
        (&
          (compiler_ast_types.ast-type-segment-bases-get
            type-segment-bases
            inner)))]
    [_ 0]))

(define (compiler-backend-abi-memory-size
  [type-segment-bases : i64]
  [ty : compiler_ast_types.AstType]) : i64
  (compiler-backend-abi-memory-size-ref type-segment-bases (& ty)))

;; Share the function/block traversal while keeping each instruction
;; sequence leaf direct, avoiding a callback or tagged dispatch per instruction.
(define (compiler-backend-collect-block-shared
  [state : be_state.CompilerBackendCollectState]
  [block : compiler_ir_types.CompilerIrBlock]) : be_state.CompilerBackendCollectState
  (match block
    [(Block _ instrs)
      (match state
        [(Collections collections)
          (Collections
            (compiler-backend-collect-instr-seq-collections collections instrs))])]))

(define (compiler-backend-collect-block-seq-shared
  [state : be_state.CompilerBackendCollectState]
  [seq : compiler_ir_types.CompilerIrBlockSeq]
  [index : i64]) : be_state.CompilerBackendCollectState
  (if (>= index (compiler_ir_types.compiler-ir-block-seq-count seq))
    state
    (compiler-backend-collect-block-seq-shared
      (compiler-backend-collect-block-shared
        state
        (compiler_ir_types.compiler-ir-block-seq-ref seq index))
      seq
      (+ index 1))))

(define (compiler-backend-collect-blocks-shared
  [state : be_state.CompilerBackendCollectState]
  [blocks : compiler_ir_types.CompilerIrBlockList]) : be_state.CompilerBackendCollectState
  (match blocks
    [(Array seq) (compiler-backend-collect-block-seq-shared state seq 0)]))

(define (compiler-backend-collect-function-shared
  [state : be_state.CompilerBackendCollectState]
  [func : compiler_ir_types.CompilerIrFunction]) : be_state.CompilerBackendCollectState
  (match func
    [(Function _ _ _ _ blocks _)
      (compiler-backend-collect-blocks-shared state blocks)]))

(define (compiler-backend-collect-function-seq-shared
  [state : be_state.CompilerBackendCollectState]
  [seq : compiler_ir_types.CompilerIrFunctionSeq]
  [index : i64]) : be_state.CompilerBackendCollectState
  (if (>= index (compiler_ir_types.compiler-ir-function-seq-count seq))
    state
    (compiler-backend-collect-function-seq-shared
      (compiler-backend-collect-function-shared
        (compiler-backend-collect-state-enter-function! state index)
        (be_state.compiler-backend-global-array-element-shared-view
          seq.slots
          index))
      seq
      (+ index 1))))

;; IAG-1: the function slot the shared walk is inside. `index` is the position
;; in the SAME sequence the program index was built from, so it is that
;; function's program-index slot.
(define (compiler-backend-collect-state-enter-function!
  [state : be_state.CompilerBackendCollectState]
  [slot : i64]) : be_state.CompilerBackendCollectState
  (match state
    [(Collections collections)
      (compiler-backend-iag-enter-function! collections.iag slot)
      (Collections collections)]))

(define (compiler-backend-collect-functions-shared
  [state : be_state.CompilerBackendCollectState]
  [functions : compiler_ir_types.CompilerIrFunctionSeq]) : be_state.CompilerBackendCollectState
  (compiler-backend-collect-function-seq-shared state functions 0))

(define (compiler-backend-param-seq-has-private-memory-from?
  [type-segment-bases : i64]
  [params : compiler_ir_types.CompilerIrParamSeq]) : bool
  (for [position (iterator.range 0 params.len)]
    (match (compiler_ir_types.compiler-ir-param-seq-ref params position)
      [(Param _ ty _)
        (when
          (> (compiler-backend-abi-memory-size type-segment-bases ty) 0)
          (return true))
        unit]))
  false)

(define (compiler-backend-param-seq-has-private-memory?
  [type-segment-bases : i64]
  [params : compiler_ir_types.CompilerIrParamSeq]) : bool
  (compiler-backend-param-seq-has-private-memory-from?
    type-segment-bases
    params))

(define (compiler-backend-seed-private-memory-call-names
  [type-segment-bases : i64]
  [functions : compiler_ir_types.CompilerIrFunctionSeq]) : unit
  (compiler-backend-seed-private-memory-call-names-seq
    type-segment-bases
    functions
    0))

(define (compiler-backend-seed-private-memory-call-names-seq
  [type-segment-bases : i64]
  [functions : compiler_ir_types.CompilerIrFunctionSeq]
  [index : i64]) : unit
  (unless
    (>= index (compiler_ir_types.compiler-ir-function-seq-count functions))
    (match (owned_view.compiler-owned-element-view functions.slots index)
      [(Function name params _ _ _ _)
        (if (compiler-backend-param-seq-has-private-memory?
          type-segment-bases
          params)
          (compiler_regalloc.compiler-reg-add-c-memory-call-name! name)
          unit)])
    (compiler-backend-seed-private-memory-call-names-seq
      type-segment-bases
      functions
      (+ index 1))))

;; Helpers the backend emits keep the platform contract whether or not the
;; program declares an extern alias for them. As for aliases, a function
;; definition of the same name takes precedence. Builtin ids name nothing in an
;; intern table they were not loaded for.
(define (compiler-backend-seed-runtime-platform-call-names
  [function-ids : (& function-ids backend_i64_i64_map.Map)]) : unit
  (when
    (cbi.compiler-builtin-table-current?)
    ;; The facts own their storage; the captured table is scratch.
    (with-scratch
      (let
        [state : cbi.CompilerBuiltinIdsState (cbi.state-capture)]
        (for [slot (iterator.range 0 (array-length state.ids))]
          (let
            [id : i64 (array-ref state.ids slot)]
            (when
              (and
                (>= id 0)
                (cbi.compiler-builtin-backend-runtime-platform-id? id)
                (not
                  (backend_i64_i64_map.contains?
                    function-ids
                    (compiler_ir_types.compiler-ir-symbol-id id))))
              (compiler_regalloc.compiler-reg-add-platform-call-name! id))))))))

(define (compiler-backend-program-index-build-with-backend-state-and-profile-state
  [backend-state : be_state.CompilerBackendState]
  [type-segment-bases : i64]
  [functions : compiler_ir_types.CompilerIrFunctionSeq]
  [externs : compiler_ir_types.CompilerIrExternSeq]
  [profile-state : profile_state.CompilerProfileState]) : be_state.CompilerBackendProgramIndex
  (let
    [_clear-c-memory-calls : unit
      (compiler_regalloc.compiler-reg-clear-c-memory-call-names!)]
    ;; W3(c): drop the previous program's frozen-global answer here, so a
    ;; second program emitted in the same process can never read a stale one.
    ;; The whole-program walk below re-seeds and re-publishes it.
    [_reset-frozen-globals : unit
      (compiler_regalloc.compiler-reg-frozen-globals-begin!)]
    [function-count : i64 (compiler-backend-function-seq-count functions)]
    [extern-count : i64
      (compiler-backend-extern-seq-count
        (be_state.compiler-backend-global-shared-view externs))]
    [function-names : (__tl_dyn-array String)
      (__tl_make-array String function-count)]
    [function-signatures : (__tl_dyn-array
      be_state.CompilerBackendMaybeSignature)
      (__tl_make-array be_state.CompilerBackendMaybeSignature function-count)]
    [extern-names : (__tl_dyn-array String)
      (__tl_make-array String extern-count)]
    [extern-signatures : (__tl_dyn-array be_state.CompilerBackendMaybeSignature)
      (__tl_make-array be_state.CompilerBackendMaybeSignature extern-count)]
    [extern-call-infos : (__tl_dyn-array i64)
      (__tl_make-array i64 extern-count)]
    [extern-link-symbols : (__tl_dyn-array i64)
      (__tl_make-array i64 extern-count)]
    [extern-provided : (__tl_dyn-array bool)
      (__tl_make-array bool extern-count)]
    [function-ids : backend_i64_i64_map.Map
      (compiler-backend-program-index-functions-into
        backend-state
        (be_state.compiler-backend-global-shared-view functions)
        (backend_i64_i64_map.with-capacity (+ (* function-count 2) 1))
        (owned_view.compiler-owned-shared-view function-names)
        (owned_view.compiler-owned-shared-view function-signatures)
        0)]
    [_seed-private-memory-calls : unit
      (compiler-backend-seed-private-memory-call-names
        type-segment-bases
        (be_state.compiler-backend-global-shared-view functions))]
    [_seed-runtime-platform-calls : unit
      (compiler-backend-seed-runtime-platform-call-names (& function-ids))]
    [extern-signature-ids : backend_i64_i64_map.Map
      (compiler-backend-program-index-extern-signatures-into
        type-segment-bases
        (be_state.compiler-backend-global-shared-view externs)
        (& function-ids)
        (backend_i64_i64_map.with-capacity (+ (* extern-count 2) 1))
        (owned_view.compiler-owned-shared-view extern-names)
        (owned_view.compiler-owned-shared-view extern-signatures)
        (owned_view.compiler-owned-shared-view extern-call-infos)
        0)]
    [extern-reference-ids : backend_i64_i64_map.Map
      (compiler-backend-program-index-extern-reference-names-into
        (be_state.compiler-backend-global-shared-view externs)
        (backend_i64_i64_map.with-capacity (+ (* extern-count 2) 1))
        0)]
    [extern-link-references : backend_i64_i64_map.Map
      (compiler-backend-program-index-extern-links-into
        (be_state.compiler-backend-global-shared-view externs)
        (backend_i64_i64_map.with-capacity (+ (* extern-count 2) 1))
        (owned_view.compiler-owned-shared-view extern-link-symbols)
        (owned_view.compiler-owned-shared-view extern-provided)
        0)]
    [representations : compiler_ir_types.CompilerIrRepresentationIndex
      (be_state.compiler-backend-state-representations
        backend-state
        type-segment-bases
        functions
        externs)]
    [tables : (Box be_state.CompilerBackendProgramTables)
      (box
        (be_state.CompilerBackendProgramTables
          0
          representations
          function-ids
          function-names
          function-signatures
          extern-signature-ids
          extern-signatures
          extern-call-infos
          extern-reference-ids
          extern-link-references
          extern-link-symbols
          extern-provided))]
    [address : u64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of tables) : (Ptr u64))))]
    (unsafe
      (ptr-write! (int->ptr address : (MutPtr u64)) address))
    (let
      [index : be_state.CompilerBackendProgramIndex
        (be_state.CompilerBackendProgramIndex
          address
          type-segment-bases
          profile-state
          backend-state)]
      (compiler-backend-state-set-emission-symbols!
        backend-state
        (be_state.CompilerBackendEmissionSymbols.Program index))
      index)))

;; Machine-word count for a value's type -- 2 (or more) for a
;; register-group aggregate constructed somewhere in the program, else 1.
(define (compiler-backend-group-word-count
  [type-segment-bases : i64]
  [index : be_state.CompilerBackendProgramIndex]
  [ty : compiler_ast_types.AstType]) : i64
  (match (& ty)
    [(or (Ref _ inner) (MutRef _ inner))
      (if (compiler_ast_types.ast-type-segment-bases-fat-referent?
        type-segment-bases
        inner)
        2
        1)]
    [_
      (let
        [tables : (& index be_state.CompilerBackendProgramTables)
          (be_state.compiler-backend-program-tables index)]
        (match (compiler_ir_types.compiler-ir-representation-index-kind
          type-segment-bases
          tables.representations
          (& ty))
          [(RegisterGroup count _) count]
          ;; TypeLisp externs require known facts at program admission. Other
          ;; IR retains the one-slot fallback without exposing an optimizer proof.
          [_ 1]))]))

(define (compiler-backend-group-type?
  [type-segment-bases : i64]
  [index : be_state.CompilerBackendProgramIndex]
  [ty : (& ty compiler_ast_types.AstType)]) : bool
  (let
    [ty : compiler_ast_types.AstType
      (owned_view.compiler-owned-reference-shared-view ty)]
    (> (compiler-backend-group-word-count type-segment-bases index ty) 1)))

(define (compiler-backend-group-vars-enable!
  [backend-state : be_state.CompilerBackendState]
  [vars : compiler_liveness.CompilerLiveI64Set]
  [addressable : compiler_liveness.CompilerLiveI64Set]) : unit
  (let
    [function-state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state backend-state)]
    ;; The dense pair index: rank(var) counts the group vars below var in
    ;; ascending id order, so the pair region holds exactly one (or two) words
    ;; per group var instead of two per var. Sized past the highest group bit
    ;; so a lookup is total; an id without a pair reads -1.
    [slot-vars : i64
      (be_state.compiler-backend-function-state-i64
        function-state
        be_state.compiler-backend-function-i64-current-slot-vars)]
    [rank-slots : i64
      (let
        [set-bits : i64
          (*
            (compiler_liveness.compiler-live-set-word-count vars)
            (compiler_liveness.compiler-live-set-word-bits))]
        (if (> set-bits slot-vars)
          set-bits
          slot-vars))]
    [group-count : i64 (compiler_liveness.compiler-live-set-count vars)]
    ;; Only a function that HAS a group var pays for the rank table; every other
    ;; function keeps the state's empty array, so the table costs nothing in the
    ;; common case.
    [ranks : (__tl_dyn-array i64)
      (if (> group-count 0)
        (__tl_make-array i64 rank-slots)
        (be_state.compiler-backend-function-state-i64-array
          function-state
          be_state.compiler-backend-function-i64-array-group-ranks))]
    [ranked : i64 0]
    [_ranks : unit
      (if (> group-count 0)
        (for [var (iterator.range 0 rank-slots)]
          (if (compiler_liveness.compiler-live-set-contains? vars var)
            (begin
              (set! (array-ref ranks var) ranked)
              (set! ranked (+ ranked 1)))
            (set! (array-ref ranks var) (- 0 1))))
        unit)]
    [_install : unit
      (begin
        (be_state.compiler-backend-function-state-set-i64-array!
          function-state
          be_state.compiler-backend-function-i64-array-group-ranks
          ranks)
        (be_state.compiler-backend-function-state-set-i64!
          function-state
          be_state.compiler-backend-function-i64-group-pair-reserve
          (if (> (compiler_liveness.compiler-live-set-count addressable) 0)
            (* 2 group-count)
            group-count)))]
    (be_state.compiler-backend-function-state-set-live-set!
      function-state
      be_state.compiler-backend-function-live-set-group-vars
      vars)
    (be_state.compiler-backend-function-state-set-live-set!
      function-state
      be_state.compiler-backend-function-live-set-addressable-group-vars
      addressable)
    (be_state.compiler-backend-function-state-set-bool!
      function-state
      be_state.compiler-backend-function-bool-group-vars-enabled
      true)))

(define (compiler-backend-group-vars-disable!
  [backend-state : be_state.CompilerBackendState]) : unit
  (let
    [function-state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state backend-state)]
    (be_state.compiler-backend-function-state-set-bool!
      function-state
      be_state.compiler-backend-function-bool-group-vars-enabled
      false)
    (be_state.compiler-backend-function-state-set-i64!
      function-state
      be_state.compiler-backend-function-i64-current-slot-vars
      0)))

(define (compiler-backend-current-slot-vars-set!
  [backend-state : be_state.CompilerBackendState]
  [vars : i64]) : unit
  (be_state.compiler-backend-function-state-set-i64!
    (be_state.compiler-backend-state-function-state backend-state)
    be_state.compiler-backend-function-i64-current-slot-vars
    vars))

(define (compiler-backend-group-var?
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
            be_state.compiler-backend-function-live-set-group-vars)]
        (compiler_liveness.compiler-live-set-contains?
          function-state-live-set
          var)))))

(define (compiler-backend-value-group-var?
  [backend-state : be_state.CompilerBackendState]
  [value : compiler_ir_types.CompilerIrValue]) : bool
  (match value
    [(Var var) (compiler-backend-group-var? backend-state var)]
    [_ false]))

;; Internal structural groups (including descriptor pairs) deliberately retain
;; their one-word source handle type as provenance. Copies must therefore use
;; the per-function group-var set, while calls, returns, globals, and parameters
;; continue to use nominal type classification and preserve the source ABI.
(define (compiler-backend-copy-group?
  [type-segment-bases : i64]
  [index : be_state.CompilerBackendProgramIndex]
  [ty : compiler_ast_types.AstType]
  [dst : i64]
  [src : compiler_ir_types.CompilerIrValue]) : bool
  (or
    (compiler-backend-group-type? type-segment-bases index ty)
    (compiler-backend-group-var? index.backend-state dst)
    (compiler-backend-value-group-var? index.backend-state src)))

(define (compiler-backend-group-word-class-mask
  [type-segment-bases : i64]
  [index : be_state.CompilerBackendProgramIndex]
  [ty : compiler_ast_types.AstType]) : i64
  (match (& ty)
    [(or (Ref _ _) (MutRef _ _)) 0]
    [_
      (let
        [tables : (& index be_state.CompilerBackendProgramTables)
          (be_state.compiler-backend-program-tables index)]
        (match (compiler_ir_types.compiler-ir-representation-index-kind
          type-segment-bases
          tables.representations
          (& ty))
          [(RegisterGroup _ mask) mask]
          [_ 0]))]))

(define (compiler-backend-group-word-sse-bit [index : i64]) : i64
  (if (= index 0)
    1
    2))

(define (compiler-backend-group-word-sse?
  [type-segment-bases : i64]
  [index : be_state.CompilerBackendProgramIndex]
  [ty : (& ty compiler_ast_types.AstType)]
  [word-index : i64]) : bool
  (let
    [ty : compiler_ast_types.AstType
      (owned_view.compiler-owned-reference-shared-view ty)]
    (not
      (=
        (bit-and
          (compiler-backend-group-word-class-mask type-segment-bases index ty)
          (compiler-backend-group-word-sse-bit word-index))
        0))))

(define (compiler-backend-extern-call-info-aggregate-params? [info : i64]) : bool
  (>= (% info 4) 2))

(define (compiler-backend-index-function-signature
  [index : be_state.CompilerBackendProgramIndex]
  [name : i64]) : be_state.CompilerBackendMaybeSignature
  (let
    [tables : (& index be_state.CompilerBackendProgramTables)
      (be_state.compiler-backend-program-tables index)]
    (match (be_operand.compiler-backend-index-function-slot index name)
      ;; A shallow view: the tables keep owning the signature.
      [(LookupFound slot)
        (owned_view.compiler-owned-element-view
          (& tables.function-signatures)
          slot)]
      [(LookupMissing) (No)])))

(define (compiler-backend-index-extern-signature
  [index : be_state.CompilerBackendProgramIndex]
  [name : i64]) : be_state.CompilerBackendMaybeSignature
  (let
    [tables : (& index be_state.CompilerBackendProgramTables)
      (be_state.compiler-backend-program-tables index)]
    (match (be_operand.compiler-backend-index-extern-signature-slot index name)
      ;; A shallow view: the tables keep owning the signature.
      [(LookupFound slot)
        (owned_view.compiler-owned-element-view
          (& tables.extern-signature-values)
          slot)]
      [(LookupMissing) (No)])))

(define (compiler-backend-index-signature
  [index : be_state.CompilerBackendProgramIndex]
  [name : i64]) : be_state.CompilerBackendMaybeSignature
  (match (compiler-backend-index-function-signature index name)
    [(Some args ret-ty) (Some args ret-ty)]
    [(No) (compiler-backend-index-extern-signature index name)]))

(define (compiler-backend-symbol-validation-error [message : String]) : be_state.ResultCompilerBackendSymbolValidation
  (Err (box (compiler_diagnostic.compiler-diagnostic-at-start "" message))))

(define (compiler-backend-emits-extern-symbol?
  [backend-state : be_state.CompilerBackendState]
  [name-id : i64]
  [link-symbol-id : i64]
  [provided : bool]
  [plan : be_state.CompilerBackendRuntimePlan]) : bool
  (not
    (or
      provided
      (be_operand.compiler-backend-fixed-fault-symbol-id?
        backend-state
        link-symbol-id)
      (and
        (= name-id link-symbol-id)
        (be_operand.compiler-backend-plan-provides-id? plan name-id))
      (be_operand.compiler-backend-plan-provides-id? plan link-symbol-id))))

(define (compiler-backend-validate-global-symbols-from
  [backend-state : be_state.CompilerBackendState]
  [globals : compiler_ir_types.CompilerIrGlobalSeq]
  [seen : backend_string_i64_map.Map]
  [index : i64]) : be_state.ResultCompilerBackendSymbolValidation
  (if (>= index globals.len)
    (Ok seen)
    (match (compiler_ir_types.compiler-ir-global-seq-borrow globals index)
      [(Global name _ _)
        (let
          [symbol : String
            (be_state.compiler-backend-state-user-symbol-id backend-state name)]
          (if (backend_string_i64_map.contains?
            (& seen)
            (be_state.compiler-backend-global-shared-view symbol))
            (compiler-backend-symbol-validation-error
              (str_cat.str-cat
                "backend: duplicate emitted global symbol "
                symbol))
            (let
              [next-seen : backend_string_i64_map.Map seen]
              (backend_string_i64_map.insert-ref! (&mut next-seen) symbol 1)
              (compiler-backend-validate-global-symbols-from
                backend-state
                globals
                next-seen
                (+ index 1)))))])))

(define (compiler-backend-validate-global-symbols-into
  [backend-state : be_state.CompilerBackendState]
  [globals : compiler_ir_types.CompilerIrGlobalSeq]
  [seen : backend_string_i64_map.Map]) : be_state.ResultCompilerBackendSymbolValidation
  (compiler-backend-validate-global-symbols-from backend-state globals seen 0))

(define (compiler-backend-runtime-prelude-string-helper-export?
  [backend-state : be_state.CompilerBackendState]
  [name-id : i64]
  [symbol-id : i64]) : bool
  (let
    [prelude-symbol : String
      (be_operand.compiler-backend-runtime-prelude-string-helper-symbol
        (be_state.compiler-backend-symbol-text-state backend-state name-id))]
    (and
      (string.eq
        prelude-symbol
        (be_state.compiler-backend-symbol-text-state backend-state symbol-id))
      (or
        (cbi.compiler-builtin-backend-tl-substring-id? symbol-id)
        (cbi.compiler-builtin-backend-tl-str-view-id? symbol-id)
        (cbi.compiler-builtin-backend-runtime-concat-id? symbol-id)
        (cbi.compiler-builtin-backend-runtime-atomic-id? symbol-id)
        (cbi.compiler-builtin-backend-tl-int-to-string-id? symbol-id)))))

(define (compiler-backend-validate-function-symbols-into
  [functions : compiler_ir_types.CompilerIrFunctionSeq]
  [_plan : be_state.CompilerBackendRuntimePlan]
  [index : be_state.CompilerBackendProgramIndex]
  [seen : backend_string_i64_map.Map]) : be_state.ResultCompilerBackendSymbolValidation
  (compiler-backend-validate-function-symbol-seq-into
    functions
    _plan
    index
    seen
    0))

(define (compiler-backend-validate-function-symbol-seq-into
  [functions : compiler_ir_types.CompilerIrFunctionSeq]
  [_plan : be_state.CompilerBackendRuntimePlan]
  [index : be_state.CompilerBackendProgramIndex]
  [seen : backend_string_i64_map.Map]
  [seq-index : i64]) : be_state.ResultCompilerBackendSymbolValidation
  (if (>=
    seq-index
    (compiler_ir_types.compiler-ir-function-seq-count functions))
    (Ok seen)
    (match (owned_view.compiler-owned-element-view functions.slots seq-index)
      [(Function name _ _ _ _ _)
        (let
          [provided? : bool
            (be_operand.compiler-backend-index-extern-provided? index name)]
          [symbol : String
            (if provided?
              (be_operand.compiler-backend-index-extern-link-symbol index name)
              (be_operand.compiler-backend-function-symbol-index index name))]
          ;; Only a provided extern can have a distinct Platform entry and body.
          [body : String
            (if provided?
              (be_operand.compiler-backend-function-symbol-index index name)
              "")]
          [distinct-body? : bool
            (and
              (> (string.string-length body) 0)
              (not (string.eq body symbol)))]
          (cond
            [(and
                (string.eq
                  (be_state.compiler-backend-symbol-text-index index name)
                  "main")
                provided?)
              (compiler-backend-symbol-validation-error
                "backend: main cannot use :export-symbol")]
            [(backend_string_i64_map.contains-borrowed? (& seen) (& symbol))
              (compiler-backend-symbol-validation-error
                (str_cat.str-cat
                  "backend: duplicate emitted function symbol "
                  symbol))]
            [(and
                distinct-body?
                (backend_string_i64_map.contains-borrowed? (& seen) (& body)))
              (compiler-backend-symbol-validation-error
                (str_cat.str-cat
                  "backend: duplicate emitted function symbol "
                  body))]
            [(and
                provided?
                (not (compiler-backend-valid-export-symbol? symbol)))
              (compiler-backend-symbol-validation-error
                (str_cat.str-cat
                  "backend: invalid exported function symbol "
                  symbol))]
            [(and
                provided?
                (compiler-backend-runtime-helper-known-id?
                  (be_operand.compiler-backend-index-extern-link-symbol-id
                    index
                    name))
                (not
                  (compiler-backend-runtime-prelude-string-helper-export?
                    index.backend-state
                    name
                    (be_operand.compiler-backend-index-extern-link-symbol-id
                      index
                      name))))
              (compiler-backend-symbol-validation-error
                (str_cat.str-cat
                  "backend: exported function symbol collides with runtime symbol "
                  symbol))]
            [else
              (let
                [out : backend_string_i64_map.Map seen]
                ;; A data extern may take the address of a provided C entry.
                ;; Ordinary bodies and globals remain collision-protected.
                (backend_string_i64_map.insert-ref!
                  (&mut out)
                  symbol
                  (if (and
                    provided?
                    (be_operand.compiler-backend-index-c-export? index name))
                    2
                    1))
                (when
                  distinct-body?
                  (backend_string_i64_map.insert-ref! (&mut out) body 1))
                (compiler-backend-validate-function-symbol-seq-into
                  functions
                  _plan
                  index
                  out
                  (+ seq-index 1)))]))])))

(define (compiler-backend-validate-extern-symbols-into
  [backend-state : be_state.CompilerBackendState]
  [externs : compiler_ir_types.CompilerIrExternSeq]
  [plan : be_state.CompilerBackendRuntimePlan]
  [seen : backend_string_i64_map.Map]) : be_state.ResultCompilerBackendSymbolValidation
  (compiler-backend-validate-extern-symbol-seq-into
    backend-state
    externs
    plan
    seen))

(define (compiler-backend-validate-extern-symbol-seq-into
  [backend-state : be_state.CompilerBackendState]
  [externs : compiler_ir_types.CompilerIrExternSeq]
  [plan : be_state.CompilerBackendRuntimePlan]
  [seen : backend_string_i64_map.Map]) : be_state.ResultCompilerBackendSymbolValidation
  (for [seq-index
    (iterator.range 0 (compiler_ir_types.compiler-ir-extern-seq-count externs))]
    (match (compiler_ir_types.compiler-ir-extern-seq-borrow externs seq-index)
      [(Extern name-id _ _ ty abi link-symbol-id _ provided _ _)
        (if (compiler-backend-emits-extern-symbol?
          backend-state
          name-id
          link-symbol-id
          provided
          plan)
          (let
            [symbol : String
              (be_operand.compiler-backend-link-symbol-id
                link-symbol-id
                plan
                backend-state
                (compiler_ast_types.ast-extern-abi-c? abi))]
            (when
              (match (backend_string_i64_map.get-borrowed (& seen) (& symbol))
                [(LookupMissing) false]
                [(LookupFound kind)
                  (not
                    (and
                      (= kind 2)
                      (compiler_ast_types.ast-extern-abi-c? abi)
                      (match ty
                        [(Func _ _) false]
                        [_ true])))])
              (return
                (compiler-backend-symbol-validation-error
                  (str_cat.str-cat
                    "backend: extern symbol collides with emitted symbol "
                    symbol)))))
          unit)]))
  (Ok seen))

(define (compiler-backend-validate-function-symbols
  [globals : compiler_ir_types.CompilerIrGlobalSeq]
  [functions : compiler_ir_types.CompilerIrFunctionSeq]
  [externs : compiler_ir_types.CompilerIrExternSeq]
  [plan : be_state.CompilerBackendRuntimePlan]
  [index : be_state.CompilerBackendProgramIndex]) : be_state.ResultCompilerBackendSymbolValidation
  (let
    [seen
      (try
        (compiler-backend-validate-global-symbols-into
          index.backend-state
          (be_state.compiler-backend-global-shared-view globals)
          (backend_string_i64_map.with-capacity
            (+
              (*
                (+
                  (compiler_ir_types.compiler-ir-global-seq-count globals)
                  (compiler-backend-function-seq-count functions))
                2)
              1))))]
    [function-seen
      (try
        (compiler-backend-validate-function-symbols-into
          functions
          plan
          index
          seen))]
    (compiler-backend-validate-extern-symbols-into
      index.backend-state
      externs
      plan
      function-seen)))

;; Package nominal signatures need positive layout/signature evidence. The
;; representation builder preserves missing extern layouts as Unknown.
;; Physical structural transports instead carry their representation in the
;; lowered signature; references do not require the referent's value layout.
(define (compiler-backend-typelisp-extern-layout-known?
  [index : be_state.CompilerBackendProgramIndex]
  [ty : (& compiler_ast_types.AstType)]) : bool
  (match ty
    [(Func args ret)
      (for [position
        (iterator.range
          0
          (compiler_ast_types.ast-type-list-len (& (deref args))))]
        (unless
          (compiler-backend-typelisp-extern-layout-known?
            index
            (&
              (compiler_ast_types.ast-type-segment-bases-get
                index.type-segment-bases
                (compiler_ast_types.ast-type-list-get
                  (& (deref args))
                  position
                  (compiler_ast_types.ast-type-id-fallback)))))
          (return false)))
      (compiler-backend-typelisp-extern-layout-known?
        index
        (&
          (compiler_ast_types.ast-type-segment-bases-get
            index.type-segment-bases
            ret)))]
    [(or (Region _ inner) (Invalidate _ inner))
      (compiler-backend-typelisp-extern-layout-known?
        index
        (&
          (compiler_ast_types.ast-type-segment-bases-get
            index.type-segment-bases
            inner)))]
    [(or (Struct _) (StructArgs _ _) (Enum _) (EnumArgs _ _))
      (let
        [tables : (& index be_state.CompilerBackendProgramTables)
          (be_state.compiler-backend-program-tables index)]
        [transport-mask : i64
          (compiler_ir_types.compiler-ir-representation-abi-group-mask
            index.type-segment-bases
            ty)]
        (or
          (let
            [name : i64
              (compiler_ir_types.compiler-ir-representation-owned-aggregate-name
                index.type-segment-bases
                ty)]
            (and
              (>= name 0)
              (>
                (compiler-backend-abi-memory-size-from-name
                  (compiler_ir_types.compiler-ir-symbol-text name))
                0)))
          (match (compiler_ir_types.compiler-ir-representation-index-kind
            index.type-segment-bases
            tables.representations
            ty)
            [(KnownOneWord) (< transport-mask 0)]
            [(RegisterGroup count mask)
              (and
                (= count 2)
                (>= mask 0)
                (<= mask 3)
                (or (< transport-mask 0) (= mask transport-mask)))]
            [(Unknown) false])))]
    [_ true]))

;; Program admission before any emission: every same-program private SPMD
;; helper and call must satisfy its explicit ABI descriptor (#7405), then the
;; symbol tables must be consistent. Both the assembly and object paths admit a
;; program only through here. An executable (`emit-entry`) must define `main`:
;; nothing synthesizes one, so a program without it is rejected before any
;; code is emitted rather than linked against a missing symbol.
(define (compiler-backend-extern-symbol-referenced?
  [runtime-index : (& runtime-index be_state.CompilerBackendRuntimeIndex)]
  [referenced-functions : (& referenced-functions be_state.BackendSymbolSeq)]
  [extern-name-id : i64]
  [source-name-id : i64]
  [link-symbol-id : i64]) : bool
  (or
    (be_state.backend-or4
      (backend_i64_i64_map.contains? (& runtime-index.calls) extern-name-id)
      (backend_i64_i64_map.contains? (& runtime-index.calls) source-name-id)
      (backend_i64_i64_map.contains? (& runtime-index.calls) link-symbol-id)
      (be_state.compiler-backend-symbol-list-contains-id?
        referenced-functions
        extern-name-id))
    (be_state.compiler-backend-symbol-list-contains-id?
      referenced-functions
      source-name-id)
    (be_state.compiler-backend-symbol-list-contains-id?
      referenced-functions
      link-symbol-id)))

(define (compiler-backend-validate-program
  [globals : compiler_ir_types.CompilerIrGlobalSeq]
  [functions : compiler_ir_types.CompilerIrFunctionSeq]
  [externs : compiler_ir_types.CompilerIrExternSeq]
  [plan : be_state.CompilerBackendRuntimePlan]
  [index : be_state.CompilerBackendProgramIndex]
  [runtime-index : (& be_state.CompilerBackendRuntimeIndex)]
  [referenced : (& be_state.BackendSymbolSeq)]
  [emit-entry : bool]) : be_state.ResultCompilerBackendSymbolValidation
  (for [position (iterator.range 0 externs.len)]
    (match (compiler_ir_types.compiler-ir-extern-seq-borrow externs position)
      [(Extern id source name ty abi link _ _ _ _)
        (match abi
          [(TypeLisp)
            (when
              (and
                (compiler-backend-extern-symbol-referenced?
                  runtime-index
                  referenced
                  id
                  source
                  link)
                (not
                  (compiler-backend-typelisp-extern-layout-known? index (& ty))))
              (return
                (compiler-backend-symbol-validation-error
                  (str_cat.str-cat
                    "backend: missing or conflicting aggregate layout for TypeLisp extern "
                    name))))]
          [_ unit])]))
  (let
    [spmd-abi-error : String
      (compiler_ir_types.compiler-ir-spmd-private-abi-program-error functions)]
    (cond
      [(> (string.string-length spmd-abi-error) 0)
        (Err
          (box
            (compiler_diagnostic.compiler-diagnostic-at-start "" spmd-abi-error)))]
      [(and
          emit-entry
          (not
            (compiler-backend-function-seq-defines?
              (be_state.compiler-backend-global-shared-view functions)
              cbi.compiler-builtin-id-fix-main)))
        (Err
          (box
            (compiler_diagnostic.compiler-diagnostic-at-start
              ""
              "executable has no `main`: define `(define (main) : i64 ...)` as its entry point, or emit library code without one (a `staticlib` package or `typelisp compile --no-entry`)")))]
      [else
        (compiler-backend-validate-function-symbols
          globals
          functions
          externs
          plan
          index)])))

(define (compiler-backend-type-list-has-aggregate?
  [type-segment-bases : i64]
  [types : (& types compiler_ast_types.AstTypeList)]) : bool
  (compiler-backend-type-list-has-aggregate-at? type-segment-bases (& types)))

(define (compiler-backend-type-list-has-aggregate-at?
  [type-segment-bases : i64]
  [types : (& types compiler_ast_types.AstTypeList)]) : bool
  (for [index (iterator.range 0 (compiler_ast_types.ast-type-list-len types))]
    (when
      (not
        (string.eq
          (compiler-backend-aggregate-type-name
            type-segment-bases
            (compiler_ast_types.ast-type-segment-bases-get
              type-segment-bases
              (compiler_ast_types.ast-type-list-get
                types
                index
                (compiler_ast_types.ast-type-id-fallback))))
          ""))
      (return true))
    unit)
  false)

;; Byte offset from %rsp where the `stack-idx`-th stack-passed OUTGOING argument
;; is stored. Stack args are numbered sequentially in argument order (0,
;; 1, ...) independent of which register bank overflowed. System V and Windows
;; Internal calls pack them at 0,8,16,...; Windows Platform calls pack them
;; after the 32-byte shadow space.
(define (compiler-backend-outgoing-stack-arg-offset
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [stack-idx : i64]) : i64
  (+ (compiler-backend-outgoing-shadow-space target convention) (* stack-idx 8)))

;; Byte offset from %rbp where the `stack-idx`-th INCOMING stack argument lives.
;; Internal functions reserve no shadow space on either target, so the first
;; stack arg sits at 16(%rbp) (saved %rbp + return address).
(define (compiler-backend-incoming-stack-arg-offset
  [target : be_state.CompilerBackendTarget]
  [stack-idx : i64]) : i64
  (+
    (+ 16 (compiler-backend-outgoing-shadow-space target (Internal)))
    (* stack-idx 8)))

(define (compiler-backend-phi-input-value
  [inputs : compiler_ir_types.CompilerIrPhiInputSeq]
  [from-label : i64]) : be_state.ResultBackendValue
  (let
    [phi-inputs-at-45535-3 : compiler_ir_types.CompilerIrPhiInputSeq inputs]
    (if (<= phi-inputs-at-45535-3.len 0)
      (Err
        (str_cat.str-cat
          "backend: missing phi input from "
          (compiler_ir_types.compiler-ir-label-text from-label)))
      (let
        [phi-input-at-45535-3
          (compiler_ir_types.compiler-ir-phi-input-seq-ref
            phi-inputs-at-45535-3
            0)]
        [value : compiler_ir_types.CompilerIrValue phi-input-at-45535-3.value]
        [label : i64 phi-input-at-45535-3.label]
        [rest : compiler_ir_types.CompilerIrPhiInputSeq
          (compiler_ir_types.CompilerIrPhiInputSeq
            phi-inputs-at-45535-3.slots
            (+ phi-inputs-at-45535-3.start 1)
            (- phi-inputs-at-45535-3.len 1))]
        (if (= label from-label)
          (Ok value)
          (compiler-backend-phi-input-value rest from-label))))))

(define (compiler-backend-instr-seq-starts-with-phi?
  [instrs : (& compiler_ir_types.CompilerIrInstrSeq)]) : bool
  (if (= (compiler_ir_types.compiler-ir-instr-seq-count instrs) 0)
    false
    (match (compiler_ir_types.compiler-ir-instr-seq-borrow instrs 0)
      [(Phi _ _ _) true]
      [_ false])))

(define (compiler-backend-phi-target-labels-add
  [out : be_state.BackendSymbolSeq]
  [label : i64]) : be_state.BackendSymbolSeq
  (let
    [acc : be_state.BackendSymbolSeq out]
    (be_state.compiler-backend-symbol-push! (&mut acc) label)
    acc))

(define (compiler-backend-phi-target-labels
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [out : be_state.BackendSymbolSeq]) : be_state.BackendSymbolSeq
  (match blocks
    [(Array seq) (compiler-backend-phi-target-labels-seq seq 0 out)]))

(define (compiler-backend-phi-target-labels-seq
  [blocks : (& compiler_ir_types.CompilerIrBlockSeq)]
  [index : i64]
  [out : be_state.BackendSymbolSeq]) : be_state.BackendSymbolSeq
  (if (>= index (compiler_ir_types.compiler-ir-block-seq-count blocks))
    out
    (match (compiler_ir_types.compiler-ir-block-seq-ref blocks index)
      [(Block label instrs)
        (compiler-backend-phi-target-labels-seq
          blocks
          (+ index 1)
          (if (compiler-backend-instr-seq-starts-with-phi? instrs)
            (compiler-backend-phi-target-labels-add out label)
            out))])))

(define (compiler-backend-phi-target-labels-for-blocks
  [blocks : compiler_ir_types.CompilerIrBlockList]) : be_state.BackendSymbolSeq
  (compiler-backend-phi-target-labels
    blocks
    (be_state.compiler-backend-empty-label-seq)))

(define (compiler-backend-function-state-install-phi-targets!
  [function-state : be_state.CompilerBackendFunctionState]
  [targets : be_state.BackendSymbolSeq]) : unit
  (be_state.compiler-backend-function-state-set-i64!
    function-state
    be_state.compiler-backend-function-i64-current-phi-target-count
    targets.len)
  (be_state.compiler-backend-function-state-set-phi-targets!
    function-state
    targets))

(define (compiler-backend-value-register-home
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : (& value compiler_ir_types.CompilerIrValue)]) : String
  (let
    [value : compiler_ir_types.CompilerIrValue
      (owned_view.compiler-owned-reference-shared-view value)]
    (match value
      [(Var id)
        ;; A single-use AddrOf definition is suppressed by forwarding. Its
        ;; allocator home therefore never receives the address; consumers must
        ;; materialize the source slot address through the ordinary load path.
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
      [_ ""])))

(define (compiler-backend-atomic-call-name? [name : (& name str)]) : bool
  (or
    (string.eq name "tl_atomic_i64_load_ptr")
    (string.eq name "tl_atomic_i64_store_ptr")
    (string.eq name "tl_atomic_i64_add_ptr")
    (string.eq name "tl_atomic_i64_fetch_add_ptr")
    (string.eq name "tl_atomic_i64_cas_ptr")
    (string.eq name "tl_atomic_i32_load_ptr")
    (string.eq name "tl_atomic_i32_store_ptr")
    (string.eq name "tl_atomic_i32_add_ptr")
    (string.eq name "tl_atomic_i32_fetch_add_ptr")
    (string.eq name "tl_atomic_i32_cas_ptr")))

(define (compiler-backend-volatile-call-name? [name : (& name str)]) : bool
  (or
    (string.eq name "tl_volatile_i64_load_ptr")
    (string.eq name "tl_volatile_i64_store_ptr")
    (string.eq name "tl_volatile_i32_load_ptr")
    (string.eq name "tl_volatile_i32_store_ptr")))

(define (compiler-backend-inline-memory-call-name? [name : (& name str)]) : bool
  (or
    (compiler-backend-atomic-call-name? name)
    (compiler-backend-volatile-call-name? name)))

(define (compiler-backend-switch-phi-target-message) : String
  "backend: CompilerIrInstr.Switch target requires unsupported phi edge copies")

(define (compiler-backend-switch-shape-message) : String
  "backend: CompilerIrInstr.Switch requires non-empty contiguous ordered cases")

(define (compiler-backend-switch-case-count
  [cases : (& cases compiler_ir_types.CompilerIrSwitchCaseSeq)]) : i64
  (compiler_ir_types.compiler-ir-switch-case-seq-count cases))

(define (compiler-backend-switch-cases-contiguous-from?
  [cases : (& cases compiler_ir_types.CompilerIrSwitchCaseSeq)]
  [expected : i64]) : bool
  (for [index (iterator.range 0 cases.len)]
    (match (compiler_ir_types.compiler-ir-switch-case-seq-borrow cases index)
      [(Case tag _) (unless (= tag (+ expected index)) (return false))]))
  true)

(define (compiler-backend-object-total-switch?
  [base : i64]
  [cases : (& cases compiler_ir_types.CompilerIrSwitchCaseSeq)]
  [trap-label : i64]) : bool
  (and
    (= base 0)
    (> (compiler-backend-switch-case-count cases) 0)
    (compiler-backend-switch-cases-contiguous-from? cases 0)
    ;; Direct-object emission consumes the explicit switch variant and trap
    ;; provenance. Source assembly additionally validates the abort block.
    (!= trap-label (compiler_ir_types.compiler-ir-label-none))))

(define (compiler-backend-switch-cases-target-phi?
  [targets : be_state.BackendSymbolSeq]
  [cases : (& cases compiler_ir_types.CompilerIrSwitchCaseSeq)]) : bool
  (for [index (iterator.range 0 cases.len)]
    (match (compiler_ir_types.compiler-ir-switch-case-seq-borrow cases index)
      [(Case _ label)
        (when
          (be_state.compiler-backend-symbol-list-contains-id? targets label)
          (return true))]))
  false)

(define (compiler-backend-switch-target-phi?
  [targets : be_state.BackendSymbolSeq]
  [cases : (& cases compiler_ir_types.CompilerIrSwitchCaseSeq)]
  [default-label : i64]) : bool
  (if (= targets.len 0)
    false
    (or
      (be_state.compiler-backend-symbol-list-contains-id? targets default-label)
      (compiler-backend-switch-cases-target-phi? targets cases))))

;; A switch case value spells part of the edge block's label, and a case value
;; may be NEGATIVE: a dense switch is built from whatever integers the arms
;; carry, and folding or inlining can leave a table whose lowest case is below
;; zero (the emitted base is then subtracted, `subq $-109, %reg`). `-` is an
;; operator in the assembler's expression grammar and not a symbol character,
;; so a label spelled `..._switch_case_-105:` is not read as a label at all --
;; `as` sees a line starting with `.` and reports `unknown pseudo-op`. Spell a
;; negative tag with a leading `m` instead. The mapping stays injective because
;; a decimal tag never contains `m`, and the common non-negative tag pays
;; nothing for it.
(define (compiler-backend-switch-case-tag-text [tag : i64]) : String
  (let
    [digits : String (string.int->string tag)]
    (if (< tag 0)
      (string.replace digits "-" "m")
      digits)))

(define (compiler-backend-switch-case-edge-label
  [current-label : i64]
  [tag : i64]) : i64
  (compiler_ir_types.compiler-ir-label
    (&
      (str_cat.str-cat
        (compiler_ir_types.compiler-ir-label-text current-label)
        "_switch_case_"
        (compiler-backend-switch-case-tag-text tag)))))

(define (compiler-backend-switch-table-label
  [function : String]
  [current-label : i64]) : String
  (be_operand.compiler-backend-asm-label
    function
    (compiler_ir_types.compiler-ir-label
      (&
        (str_cat.str-cat
          (compiler_ir_types.compiler-ir-label-text current-label)
          "_switch_table"
          "")))))

(define (compiler-backend-emit-switch-table-cases-into
  [function : String]
  [current-label : i64]
  [retarget-phi-edges : bool]
  [targets : be_state.BackendSymbolSeq]
  [cases : compiler_ir_types.CompilerIrSwitchCaseSeq]
  [absolute : bool]
  [buf : text_buf.TextBuf]) : text_buf.TextBuf
  (let
    [out : text_buf.TextBuf buf]
    [table-label : String
      (compiler-backend-switch-table-label function current-label)]
    (for [index (iterator.range 0 cases.len)]
      (match (compiler_ir_types.compiler-ir-switch-case-seq-borrow cases index)
        [(Case tag label)
          (set!
            out
            (text_buf.append
              (text_buf.append
                (text_buf.append
                  (text_buf.append
                    (text_buf.append out "    .long ")
                    (be_operand.compiler-backend-asm-label
                      (be_state.compiler-backend-global-shared-view function)
                      (if (and
                        retarget-phi-edges
                        (be_state.compiler-backend-symbol-list-contains-id?
                          targets
                          label))
                        (compiler-backend-switch-case-edge-label
                          current-label
                          tag)
                        label)))
                  (if absolute
                    ""
                    " - "))
                (if absolute
                  ""
                  (string.copy (& table-label))))
              "\n"))]))
    out))

;; One switch table: `cases.len` four-byte entries. A non-PIC ELF image takes
;; the case address itself, which the linker fills through a 32-bit absolute
;; relocation; every other code model takes the difference between the case
;; label and the table label, which the assembler resolves to a constant, so
;; those tables need no relocation at all. The caller emits the section
;; directive for the whole run of tables.
(define (compiler-backend-emit-switch-table
  [function : String]
  [current-label : i64]
  [cases : compiler_ir_types.CompilerIrSwitchCaseSeq]
  [retarget-phi-edges : bool]
  [targets : be_state.BackendSymbolSeq]
  [absolute : bool]) : String
  (text_buf.render
    (compiler-backend-emit-switch-table-cases-into
      (be_state.compiler-backend-global-shared-view function)
      current-label
      retarget-phi-edges
      targets
      cases
      absolute
      (text_buf.append
        (text_buf.append
          (text_buf.append (text_buf.empty) "    .balign 4\n")
          (compiler-backend-switch-table-label function current-label))
        ":\n"))))

(define (compiler-backend-emit-switch-tables-instr-seq-into
  [function : String]
  [current-label : i64]
  [targets : be_state.BackendSymbolSeq]
  [absolute : bool]
  [instrs : (& compiler_ir_types.CompilerIrInstrSeq)]
  [index : i64]
  [buf : text_buf.TextBuf]) : text_buf.TextBuf
  (if (>= index (compiler_ir_types.compiler-ir-instr-seq-count instrs))
    buf
    (compiler-backend-emit-switch-tables-instr-seq-into
      (be_state.compiler-backend-global-shared-view function)
      current-label
      (be_state.compiler-backend-global-shared-view targets)
      absolute
      instrs
      (+ index 1)
      (match (compiler_ir_types.compiler-ir-instr-seq-ref instrs index)
        [(or (Switch _ _ cases default-label)
             (TotalEnumSwitch _ _ cases default-label _))
          (text_buf.append
            buf
            (compiler-backend-emit-switch-table
              function
              current-label
              (be_state.compiler-backend-global-shared-view cases)
              (compiler-backend-switch-target-phi?
                (be_state.compiler-backend-global-shared-view targets)
                cases
                default-label)
              targets
              absolute))]
        [_ buf]))))

(define (compiler-backend-emit-switch-tables-seq-into
  [function : String]
  [targets : be_state.BackendSymbolSeq]
  [absolute : bool]
  [blocks : (& compiler_ir_types.CompilerIrBlockSeq)]
  [index : i64]
  [buf : text_buf.TextBuf]) : text_buf.TextBuf
  (if (>= index (compiler_ir_types.compiler-ir-block-seq-count blocks))
    buf
    (match (compiler_ir_types.compiler-ir-block-seq-ref blocks index)
      [(Block label instrs)
        (compiler-backend-emit-switch-tables-seq-into
          (be_state.compiler-backend-global-shared-view function)
          (be_state.compiler-backend-global-shared-view targets)
          absolute
          blocks
          (+ index 1)
          (compiler-backend-emit-switch-tables-instr-seq-into
            function
            label
            targets
            absolute
            instrs
            0
            buf))])))

;; Executables share a section for their switch tables. Library objects
;; split the tables so a linker can collect each function independently.
(define (compiler-backend-emit-switch-tables-functions-into
  [target : be_state.CompilerBackendTarget]
  [functions : compiler_ir_types.CompilerIrFunctionSeq]
  [program-index : be_state.CompilerBackendProgramIndex]
  [absolute : bool]
  [buf : text_buf.TextBuf]) : text_buf.TextBuf
  (let
    [sectioned? : bool
      (be_state.compiler-backend-state-library-object?
        program-index.backend-state)]
    (compiler-backend-emit-switch-tables-function-seq-into
      target
      functions
      program-index
      absolute
      sectioned?
      0
      (if sectioned?
        buf
        (text_buf.append
          buf
          (if absolute
            "    .section .rodata\n"
            "    .text\n"))))))

(define (compiler-backend-emit-switch-tables-function-seq-into
  [target : be_state.CompilerBackendTarget]
  [functions : compiler_ir_types.CompilerIrFunctionSeq]
  [program-index : be_state.CompilerBackendProgramIndex]
  [absolute : bool]
  [sectioned? : bool]
  [index : i64]
  [buf : text_buf.TextBuf]) : text_buf.TextBuf
  (if (>= index (compiler_ir_types.compiler-ir-function-seq-count functions))
    buf
    (match (owned_view.compiler-owned-element-view functions.slots index)
      [(Function name _ _ _ blocks _)
        (let
          [_phi-targets : unit
            (compiler-backend-function-state-install-phi-targets!
              (be_state.compiler-backend-state-function-state
                program-index.backend-state)
              (compiler-backend-phi-target-labels-for-blocks
                (be_state.compiler-backend-global-shared-view blocks)))]
          (compiler-backend-emit-switch-tables-function-seq-into
            target
            functions
            program-index
            absolute
            sectioned?
            (+ index 1)
            (match (be_state.compiler-backend-global-shared-view blocks)
              [(Array seq)
                (let
                  [scope
                    (compiler-backend-function-label-scope program-index name)]
                  [targets
                    (be_state.compiler-backend-function-state-phi-targets
                      (be_state.compiler-backend-state-function-state
                        program-index.backend-state))]
                  (if sectioned?
                    (let
                      [tables
                        (compiler-backend-emit-switch-tables-seq-into
                          scope
                          targets
                          absolute
                          seq
                          0
                          (text_buf.empty))]
                      (if (text_buf.empty? (& tables))
                        buf
                        (let
                          [symbol
                            (be_operand.compiler-backend-function-symbol-index
                              program-index
                              name)]
                          [section
                            (if absolute
                              (be_operand.compiler-backend-elf-symbol-section
                                ".rodata"
                                (& symbol)
                                "\"a\",@progbits")
                              ;; COFF case-minus-table expressions stay inside
                              ;; the same COMDAT as the function body.
                              (be_operand.compiler-backend-function-section
                                target
                                (& symbol)))]
                          (text_buf.append
                            (text_buf.append buf section)
                            (text_buf.render tables)))))
                    (compiler-backend-emit-switch-tables-seq-into
                      scope
                      targets
                      absolute
                      seq
                      0
                      buf)))])))])))

(define (compiler-backend-switch-validate-one
  [targets : be_state.BackendSymbolSeq]
  [base : i64]
  [cases : compiler_ir_types.CompilerIrSwitchCaseSeq]
  [default-label : i64]) : be_state.CompilerBackendSwitchValidation
  (let
    [case-count : i64 (compiler-backend-switch-case-count cases)]
    (cond
      [(= case-count 0) (Err (compiler-backend-switch-shape-message))]
      [(not (compiler-backend-switch-cases-contiguous-from? cases base))
        (Err (compiler-backend-switch-shape-message))]
      [(compiler-backend-switch-target-phi? targets cases default-label)
        (Err (compiler-backend-switch-phi-target-message))]
      [else (Ok)])))

(define (compiler-backend-switch-validate-instr
  [targets : be_state.BackendSymbolSeq]
  [instr : compiler_ir_types.CompilerIrInstr]) : be_state.CompilerBackendSwitchValidation
  (match instr
    [(or (Switch _ base cases default-label)
         (TotalEnumSwitch _ base cases default-label _))
      (compiler-backend-switch-validate-one targets base cases default-label)]
    [_ (Ok)]))

(define (compiler-backend-switch-validate-instr-seq
  [targets : be_state.BackendSymbolSeq]
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : be_state.CompilerBackendSwitchValidation
  (for [index
    (iterator.range 0 (compiler_ir_types.compiler-ir-instr-seq-count instrs))]
    (let
      [_
        (try
          (compiler-backend-switch-validate-instr
            (be_state.compiler-backend-global-shared-view targets)
            (compiler_ir_types.compiler-ir-instr-seq-ref instrs index)))]
      unit))
  (Ok))

(define (compiler-backend-switch-validate-blocks
  [targets : be_state.BackendSymbolSeq]
  [blocks : compiler_ir_types.CompilerIrBlockList]) : be_state.CompilerBackendSwitchValidation
  (match blocks
    [(Array seq) (compiler-backend-switch-validate-block-seq targets seq)]))

(define (compiler-backend-switch-validate-block-seq
  [targets : be_state.BackendSymbolSeq]
  [blocks : compiler_ir_types.CompilerIrBlockSeq]) : be_state.CompilerBackendSwitchValidation
  (for [index
    (iterator.range 0 (compiler_ir_types.compiler-ir-block-seq-count blocks))]
    (match (compiler_ir_types.compiler-ir-block-seq-ref blocks index)
      [(Block _ instrs)
        (let
          [_
            (try
              (compiler-backend-switch-validate-instr-seq
                (be_state.compiler-backend-global-shared-view targets)
                instrs))]
          unit)]))
  (Ok))

(define (compiler-backend-switch-validate-functions
  [functions : compiler_ir_types.CompilerIrFunctionSeq]) : be_state.CompilerBackendSwitchValidation
  (compiler-backend-switch-validate-function-seq functions))

(define (compiler-backend-switch-validate-function-seq
  [functions : compiler_ir_types.CompilerIrFunctionSeq]) : be_state.CompilerBackendSwitchValidation
  (for [index
    (iterator.range
      0
      (compiler_ir_types.compiler-ir-function-seq-count functions))]
    (match (owned_view.compiler-owned-element-view functions.slots index)
      [(Function _ _ _ _ blocks _)
        (let
          [targets : be_state.BackendSymbolSeq
            (compiler-backend-phi-target-labels-for-blocks
              (be_state.compiler-backend-global-shared-view blocks))]
          [_ (try (compiler-backend-switch-validate-blocks targets blocks))]
          unit)]))
  (Ok))

(define (compiler-backend-clear-function-owned-state!
  [backend-state : be_state.CompilerBackendState]) : unit
  (let
    [function-state-address : i64
      (unsafe
        (deref (be_state.compiler-backend-state-view backend-state)).function-state-address)]
    (when
      (not (= function-state-address 0))
      (be_state.compiler-backend-function-state-reset!
        (be_state.CompilerBackendFunctionState function-state-address)))))

(define (compiler-backend-emit-closure-descriptor-entry [name : String]) : String
  (str_cat.str-cat
    (be_operand.compiler-backend-closure-descriptor-label
      (be_state.compiler-backend-global-shared-view name))
    ":\n    .quad "
    (compiler-backend-closure-entry-label name)
    "\n    .quad 0\n"
    ""))

(define (compiler-backend-emit-closure-descriptor-entry-into
  [name : i64]
  [_functions : compiler_ir_types.CompilerIrFunctionSeq]
  [_externs : compiler_ir_types.CompilerIrExternSeq]
  [program-index : be_state.CompilerBackendProgramIndex]
  [buf : text_buf.TextBuf]) : text_buf.TextBuf
  (match (compiler-backend-index-signature program-index name)
    [(Some _ _)
      (text_buf.append
        buf
        (compiler-backend-emit-closure-descriptor-entry
          (be_state.compiler-backend-symbol-text-index program-index name)))]
    [(No) buf]))

(define (compiler-backend-emit-closure-descriptor-entries-into
  [names : (& names be_state.BackendSymbolSeq)]
  [index : i64]
  [functions : compiler_ir_types.CompilerIrFunctionSeq]
  [externs : compiler_ir_types.CompilerIrExternSeq]
  [program-index : be_state.CompilerBackendProgramIndex]
  [buf : text_buf.TextBuf]) : text_buf.TextBuf
  (if (>= index names.len)
    buf
    (compiler-backend-emit-closure-descriptor-entries-into
      names
      (+ index 1)
      (be_state.compiler-backend-global-shared-view functions)
      (be_state.compiler-backend-global-shared-view externs)
      program-index
      (compiler-backend-emit-closure-descriptor-entry-into
        (array-ref names.slots index)
        functions
        externs
        program-index
        buf))))

(define (compiler-backend-emit-closure-descriptors-into
  [names : be_state.BackendSymbolSeq]
  [functions : compiler_ir_types.CompilerIrFunctionSeq]
  [externs : compiler_ir_types.CompilerIrExternSeq]
  [program-index : be_state.CompilerBackendProgramIndex]
  [buf : text_buf.TextBuf]) : text_buf.TextBuf
  (if (= names.len 0)
    buf
    (compiler-backend-emit-closure-descriptor-entries-into
      names
      0
      functions
      externs
      program-index
      (text_buf.append buf "    .section .rodata\n    .balign 8\n"))))

(define (compiler-backend-collect-float-both-collections
  [collections : be_state.CompilerBackendProgramCollections]
  [bits : u64]) : be_state.CompilerBackendProgramCollections
  (be_state.compiler-backend-program-collections-add-float
    (be_state.compiler-backend-program-collections-add-float
      collections
      (F64)
      bits)
    (F32)
    bits))

(define (compiler-backend-collect-lane-id-collections
  [collections : be_state.CompilerBackendProgramCollections]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]) : be_state.CompilerBackendProgramCollections
  (if (compiler-backend-lane-id-avx512-i64-shape-ok? elem-ty lanes)
    (be_state.compiler-backend-program-collections-mark-avx512-i64-lane-id
      collections)
    (if (compiler-backend-lane-id-avx2-i64-shape-ok? elem-ty lanes)
      (be_state.compiler-backend-program-collections-mark-avx2-i64-lane-id
        collections)
      collections)))

(define (compiler-backend-collect-lane-offset-gather-collections
  [collections : be_state.CompilerBackendProgramCollections]
  [lanes : i64]
  [elem-ty : compiler_ast_types.AstType]) : be_state.CompilerBackendProgramCollections
  (cond
    [(and
        (be_operand.compiler-backend-gather-dword-element?
          (be_state.compiler-backend-global-shared-view elem-ty))
        (= lanes 8))
      (be_state.compiler-backend-program-collections-mark-avx2-i64-lane-id
        collections)]
    [(and
        (be_operand.compiler-backend-gather-dword-element?
          (be_state.compiler-backend-global-shared-view elem-ty))
        (= lanes 16))
      (be_state.compiler-backend-program-collections-mark-avx512-i64-lane-id
        collections)]
    [(and
        (not
          (be_operand.compiler-backend-gather-dword-element?
            (be_state.compiler-backend-global-shared-view elem-ty)))
        (= lanes 4))
      (be_state.compiler-backend-program-collections-mark-avx2-i64-lane-id
        collections)]
    [(and
        (not (be_operand.compiler-backend-gather-dword-element? elem-ty))
        (= lanes 8))
      (be_state.compiler-backend-program-collections-mark-avx512-i64-lane-id
        collections)]
    [else collections]))

(define (compiler-backend-collect-value-collections
  [collections : be_state.CompilerBackendProgramCollections]
  [value : compiler_ir_types.CompilerIrValue]) : be_state.CompilerBackendProgramCollections
  (match value
    [(Function name)
      (be_state.compiler-backend-program-collections-add-function
        collections
        name)]
    [(Global name)
      ;; IAG-1: this operand is a READ of the cell by the function being
      ;; walked. Same argument as W3(c) below: record it here rather than
      ;; paying a second traversal for the same answer.
      (compiler-backend-iag-note-mention! collections.iag name)
      (be_state.compiler-backend-program-collections-add-reference
        collections
        name)]
    [(GlobalAddr name)
      ;; W3(c): `(& g)` exists, so a `StorePtr` could reach cell(g). Record it
      ;; on the walk that already visits every operand of every instruction
      ;; rather than paying a second traversal for the same answer.
      (compiler_regalloc.compiler-reg-add-nonfrozen-global!
        (compiler_ir_types.compiler-ir-symbol-id name))
      (compiler-backend-iag-note-mention! collections.iag name)
      (be_state.compiler-backend-program-collections-add-reference
        collections
        name)]
    [(String text)
      (be_state.compiler-backend-program-collections-add-string
        collections
        text)]
    [(F64 bits)
      (compiler-backend-collect-float-both-collections collections bits)]
    [(Bytes text)
      (be_state.compiler-backend-program-collections-add-bytes collections text)]
    [_ collections]))

(define (compiler-backend-collect-maybe-value-collections
  [collections : be_state.CompilerBackendProgramCollections]
  [value : compiler_ir_types.CompilerIrMaybeValue]) : be_state.CompilerBackendProgramCollections
  (match value
    [(No) collections]
    [(Some inner)
      (compiler-backend-collect-value-collections collections inner)]))

(define (compiler-backend-collect-value-seq-collections-from
  [collections : be_state.CompilerBackendProgramCollections]
  [values : compiler_ir_types.CompilerIrValueSeq]
  [index : i64]) : be_state.CompilerBackendProgramCollections
  (if (>= index values.len)
    collections
    (compiler-backend-collect-value-seq-collections-from
      (compiler-backend-collect-value-collections
        collections
        (compiler_ir_types.compiler-ir-value-seq-ref values index))
      values
      (+ index 1))))

(define (compiler-backend-collect-value-seq-collections
  [collections : be_state.CompilerBackendProgramCollections]
  [values : compiler_ir_types.CompilerIrValueSeq]) : be_state.CompilerBackendProgramCollections
  (compiler-backend-collect-value-seq-collections-from collections values 0))

(define (compiler-backend-collect-call-args-array-collections
  [collections : be_state.CompilerBackendProgramCollections]
  [values : (__tl_dyn-array compiler_ir_types.CompilerIrValue)]
  [index : i64]) : be_state.CompilerBackendProgramCollections
  (if (>= index (array-length values))
    collections
    (compiler-backend-collect-call-args-array-collections
      (compiler-backend-collect-value-collections
        collections
        (be_state.compiler-backend-global-array-element-shared-view
          values
          index))
      values
      (+ index 1))))

(define (compiler-backend-collect-call-args-collections
  [collections : be_state.CompilerBackendProgramCollections]
  [args : compiler_ir_types.CompilerIrCallArgs]) : be_state.CompilerBackendProgramCollections
  (match args
    [(Nil) collections]
    [(One value) (compiler-backend-collect-value-collections collections value)]
    [(Two a b)
      (compiler-backend-collect-value-collections
        (compiler-backend-collect-value-collections collections a)
        b)]
    [(or (Array values) (Sret values _))
      (compiler-backend-collect-call-args-array-collections
        collections
        values
        0)]))

(define (compiler-backend-collect-spmd-call-args-collections
  [collections : be_state.CompilerBackendProgramCollections]
  [args : compiler_ir_types.CompilerIrSpmdCallArgSeq]) : be_state.CompilerBackendProgramCollections
  (let
    [out : be_state.CompilerBackendProgramCollections collections]
    (for [i (iterator.range 0 args.len)]
      (match (owned_view.compiler-owned-element-view args.slots i)
        [(Arg _ value _)
          (set! out (compiler-backend-collect-value-collections out value))]))
    out))

(define (compiler-backend-collect-phi-collections
  [collections : be_state.CompilerBackendProgramCollections]
  [inputs : compiler_ir_types.CompilerIrPhiInputSeq]) : be_state.CompilerBackendProgramCollections
  (let
    [phi-inputs-at-80548-3 : compiler_ir_types.CompilerIrPhiInputSeq inputs]
    (if (<= phi-inputs-at-80548-3.len 0)
      collections
      (let
        [phi-input-at-80548-3
          (compiler_ir_types.compiler-ir-phi-input-seq-ref
            phi-inputs-at-80548-3
            0)]
        [value : compiler_ir_types.CompilerIrValue phi-input-at-80548-3.value]
        [rest : compiler_ir_types.CompilerIrPhiInputSeq
          (compiler_ir_types.CompilerIrPhiInputSeq
            phi-inputs-at-80548-3.slots
            (+ phi-inputs-at-80548-3.start 1)
            (- phi-inputs-at-80548-3.len 1))]
        (compiler-backend-collect-phi-collections
          (compiler-backend-collect-value-collections collections value)
          rest)))))

(define (compiler-backend-collect-instr-collections
  [collections : be_state.CompilerBackendProgramCollections]
  [instr : compiler_ir_types.CompilerIrInstr]) : be_state.CompilerBackendProgramCollections
  (match instr
    [(or (BinOp _ _ lhs rhs _) (Gep _ lhs rhs _) (StorePtr lhs rhs _)
         (StoreOwned lhs rhs _) (CopyBytes lhs rhs _) (BoundsCheck lhs rhs _)
         (MaskBinOp _ _ lhs rhs _) (VectorLoad _ lhs rhs _ _)
         (CpuId _ lhs rhs _))
      (compiler-backend-collect-value-collections
        (compiler-backend-collect-value-collections collections lhs)
        rhs)]
    [(UnOp _ op src ty)
      (let
        [with-src : be_state.CompilerBackendProgramCollections
          (compiler-backend-collect-value-collections collections src)]
        (match op
          [(Neg)
            (if (be_state.compiler-backend-f64-type? ty)
              (be_state.compiler-backend-program-collections-mark-f64-neg
                with-src)
              (if (be_operand.compiler-backend-float-type? ty)
                (be_state.compiler-backend-program-collections-mark-f32-neg
                  with-src)
                with-src))]
          [_ with-src]))]
    [(or (Call _ name args _) (TailCall name args _))
      ;; IAG-1: one direct call-graph edge.
      (compiler-backend-iag-note-callee!
        (be_state.compiler-backend-global-shared-view collections.iag)
        name)
      (compiler-backend-collect-call-args-collections collections args)]
    [(or (CallIndirect _ func args _) (CallIndirectC _ func args _)
         (TailCallIndirect func args _))
      ;; IAG-1: a call through a value; this function's callee set is not
      ;; enumerable, so it can reach any rebind.
      (compiler-backend-iag-note-indirect! collections.iag)
      (compiler-backend-collect-call-args-collections
        (compiler-backend-collect-value-collections collections func)
        args)]
    [(CallCAbiStoreResult payload-box)
      (let
        [base
          (be_state.compiler-backend-box-field-shared-view payload-box base)]
        [args
          (be_state.compiler-backend-box-field-shared-view payload-box args)]
        [name (deref payload-box).name]
        (compiler-backend-iag-note-callee!
          (be_state.compiler-backend-global-shared-view collections.iag)
          name)
        (compiler-backend-collect-call-args-collections
          (compiler-backend-collect-value-collections collections base)
          args))]
    [(CallIndirectCAbiStoreResult (box (fields base [func callee] args)))
      (compiler-backend-iag-note-indirect! collections.iag)
      (compiler-backend-collect-call-args-collections
        (compiler-backend-collect-value-collections
          (compiler-backend-collect-value-collections collections base)
          func)
        args)]
    [(SpmdCall payload-box)
      (let
        [active-mask
          (be_state.compiler-backend-box-field-shared-view
            payload-box
            active-mask)]
        [args
          (be_state.compiler-backend-box-field-shared-view payload-box args)]
        [callee (deref payload-box).callee]
        (compiler-backend-iag-note-callee!
          (be_state.compiler-backend-global-shared-view collections.iag)
          callee)
        (compiler-backend-collect-spmd-call-args-collections
          (compiler-backend-collect-value-collections collections active-mask)
          args))]
    [(Store name value _)
      ;; W3(c): the lowering of `(set! g ...)`, the one direct cell writer.
      ;; IAG-1 keys its R(g) on the same instruction.
      (compiler_regalloc.compiler-reg-add-nonfrozen-global!
        (compiler_ir_types.compiler-ir-symbol-id name))
      (compiler-backend-iag-note-write! collections.iag name)
      (compiler-backend-collect-value-collections collections value)]
    [(Return maybe)
      (compiler-backend-collect-maybe-value-collections collections maybe)]
    [(Phi _ inputs _)
      (compiler-backend-collect-phi-collections collections inputs)]
    [(Cast _ src from-ty to-ty)
      (let
        [with-source : be_state.CompilerBackendProgramCollections
          (compiler-backend-collect-value-collections collections src)]
        (match to-ty
          [(U64)
            (if (be_operand.compiler-backend-float-type? from-ty)
              (be_state.compiler-backend-program-collections-add-float
                with-source
                (be_state.compiler-backend-global-shared-view from-ty)
                (be_state.compiler-backend-float-to-u64-threshold-bits from-ty))
              with-source)]
          [_ with-source]))]
    [(VectorBinOp (box (fields lhs rhs)))
      (compiler-backend-collect-value-collections
        (compiler-backend-collect-value-collections collections lhs)
        rhs)]
    [(VectorPrefix (box (fields src carry)))
      (compiler-backend-collect-value-collections
        (compiler-backend-collect-value-collections collections src)
        carry)]
    [(VectorCompare (box (fields lhs rhs)))
      (compiler-backend-collect-value-collections
        (compiler-backend-collect-value-collections collections lhs)
        rhs)]
    [(Select (box (fields mask on-true on-false)))
      (compiler-backend-collect-value-collections
        (compiler-backend-collect-value-collections
          (compiler-backend-collect-value-collections collections mask)
          on-true)
        on-false)]
    [(VectorStore (box (fields base index value)))
      (compiler-backend-collect-value-collections
        (compiler-backend-collect-value-collections
          (compiler-backend-collect-value-collections collections base)
          index)
        value)]
    [(PredicatedStore (box (fields base index value mask)))
      (compiler-backend-collect-value-collections
        (compiler-backend-collect-value-collections
          (compiler-backend-collect-value-collections
            (compiler-backend-collect-value-collections collections base)
            index)
          value)
        mask)]
    [(PredicatedLoad (box (fields base index mask)))
      (compiler-backend-collect-value-collections
        (compiler-backend-collect-value-collections
          (compiler-backend-collect-value-collections collections base)
          index)
        mask)]
    [(GatherLoad payload-box)
      (let
        [base
          (be_state.compiler-backend-box-field-shared-view payload-box base)]
        [index-base
          (be_state.compiler-backend-box-field-shared-view
            payload-box
            index-base)]
        [index
          (be_state.compiler-backend-box-field-shared-view payload-box index)]
        [lane-offset (deref payload-box).lane-offset]
        [lanes (deref payload-box).lanes]
        [elem-ty
          (be_state.compiler-backend-box-field-shared-view payload-box ty)]
        [values : be_state.CompilerBackendProgramCollections
          (compiler-backend-collect-value-collections
            (compiler-backend-collect-value-collections
              (compiler-backend-collect-value-collections collections base)
              index-base)
            index)]
        (if lane-offset
          (compiler-backend-collect-lane-offset-gather-collections
            values
            lanes
            elem-ty)
          values))]
    [(VectorShuffle
        (box (fields source selector-low selector-high active-lanes)))
      (compiler-backend-collect-value-collections
        (compiler-backend-collect-maybe-value-collections
          (compiler-backend-collect-value-collections
            (compiler-backend-collect-value-collections collections source)
            selector-low)
          selector-high)
        active-lanes)]
    [(TailMask _ index length lanes)
      (let
        [values : be_state.CompilerBackendProgramCollections
          (compiler-backend-collect-value-collections
            (compiler-backend-collect-value-collections collections index)
            length)]
        (if (= lanes 4)
          (be_state.compiler-backend-program-collections-mark-avx2-i64-lane-id
            values)
          values))]
    [(Syscall _ args)
      (compiler-backend-collect-call-args-collections collections args)]
    [(Pack _ words _)
      (compiler-backend-collect-value-seq-collections collections words)]
    [(or (Alloc _ _) (AddrOf _ _ _) (EntryArgc _) (EntryArgv _) (EntryEnvp _)
         (Jump _))
      collections]
    [(LaneId _ lanes elem-ty)
      (compiler-backend-collect-lane-id-collections collections lanes elem-ty)]
    [(or (Mov _ index _) (Branch index _ _) (TotalEnumBranch index _ _)
         (Load _ index _) (Bitcast _ index _ _) (Splat _ index _ _)
         (VectorReduce _ _ index _ _) (MaskNot _ index _)
         (MaskReduce _ _ index _) (Xgetbv _ index) (Word _ index _ _)
         (Switch index _ _ _) (TotalEnumSwitch index _ _ _ _))
      (compiler-backend-collect-value-collections collections index)]))

(define (compiler-backend-collect-instr-seq-collections
  [collections : be_state.CompilerBackendProgramCollections]
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : be_state.CompilerBackendProgramCollections
  (let
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [count : i64 instrs.len]
    [out : be_state.CompilerBackendProgramCollections collections]
    (for [index (iterator.range 0 count)]
      (set!
        out
        (compiler-backend-collect-instr-collections
          out
          (be_state.compiler-backend-global-array-element-shared-view
            slots
            index))))
    out))

(define (compiler-backend-iag-bit-word [bit : i64]) : i64
  (shr bit 6))

(define (compiler-backend-iag-bit-mask [bit : i64]) : i64
  (shl 1 (bit-and bit 63)))

(define (compiler-backend-iag-bit-set!
  [words : (__tl_dyn-array i64)]
  [base : i64]
  [bit : i64]) : unit
  (let
    [slot : i64 (+ base (compiler-backend-iag-bit-word bit))]
    (set!
      (array-ref words slot)
      (bit-or (array-ref words slot) (compiler-backend-iag-bit-mask bit)))))

;; ---------------------------------------------------------------------------
;; Census recording.
;;
;; These are the hooks the shared whole-program collections walk
;; (`compiler-backend-collect-instr-collections` /
;; `-value-collections`) calls as it already visits every operand of every
;; instruction of every function -- the same walk that seeds the W3(c)
;; nonfrozen-global answer. IAG-1 therefore adds no traversal of its own: it
;; adds one predictable compare per operand and a map probe only on the
;; `Global`/`GlobalAddr`/`Store`/call shapes it actually records.
;;
;; `state` carries the only two threaded scalars -- [0] the function slot being
;; walked (-1 while the walk is in global initializers) and [1] the edge
;; cursor -- in a shared two-cell array, so the census travels by value.
;; ---------------------------------------------------------------------------
(define compiler-backend-iag-state-function : i64
  0)
(define compiler-backend-iag-state-cursor : i64
  1)

(define (compiler-backend-iag-active?
  [census : be_state.CompilerBackendIagCensus]) : bool
  (> census.count 0))

;; A borrowed view of the held census: no copy, so the hooks stay a compare.
(defmacro (compiler-backend-iag-census-of [cell : Expr]) : Expr
  `(be_state.compiler-backend-global-array-element-shared-view
    (__tl-project-field-name ,cell "slots")
    0))

(define (compiler-backend-iag-cell-active?
  [cell : (& cell be_state.CompilerBackendIagCensusCell)]) : bool
  (compiler-backend-iag-active? (compiler-backend-iag-census-of cell)))

;; The walk enters a function body; -1 restores the "outside any function"
;; state the global-initializer part of the walk runs in.
(define (compiler-backend-iag-enter-function!
  [cell : (& cell be_state.CompilerBackendIagCensusCell)]
  [slot : i64]) : unit
  (if (compiler-backend-iag-cell-active? cell)
    (let
      [census : be_state.CompilerBackendIagCensus
        (compiler-backend-iag-census-of cell)]
      (set! (array-ref census.state compiler-backend-iag-state-function) slot))
    unit))

(define (compiler-backend-iag-current-function
  [census : (& census be_state.CompilerBackendIagCensus)]) : i64
  (array-ref census.state compiler-backend-iag-state-function))

(define (compiler-backend-iag-candidate-slot
  [census : (& census be_state.CompilerBackendIagCensus)]
  [name : i64]) : i64
  (backend_i64_i64_map.get-value-or
    (& census.slots)
    (compiler_ir_types.compiler-ir-symbol-id name)
    -1))

;; `Global g` / `GlobalAddr g` appeared as an operand of the function being
;; walked: that function READS the cell.
(define (compiler-backend-iag-note-mention!
  [cell : (& cell be_state.CompilerBackendIagCensusCell)]
  [name : i64]) : unit
  (if (not (compiler-backend-iag-cell-active? cell))
    unit
    (let
      [census : be_state.CompilerBackendIagCensus
        (compiler-backend-iag-census-of cell)]
      [func : i64 (compiler-backend-iag-current-function census)]
      (if (< func 0)
        unit
        (let
          [candidate : i64 (compiler-backend-iag-candidate-slot census name)]
          (if (< candidate 0)
            unit
            (compiler-backend-iag-bit-set!
              census.mentions
              (* func census.words)
              candidate)))))))

;; `CompilerIrInstr.Store g _ _`: the one direct cell writer.
(define (compiler-backend-iag-note-write!
  [cell : (& cell be_state.CompilerBackendIagCensusCell)]
  [name : i64]) : unit
  (if (not (compiler-backend-iag-cell-active? cell))
    unit
    (let
      [census : be_state.CompilerBackendIagCensus
        (compiler-backend-iag-census-of cell)]
      [func : i64 (compiler-backend-iag-current-function census)]
      (if (< func 0)
        unit
        (let
          [candidate : i64 (compiler-backend-iag-candidate-slot census name)]
          (unless
            (< candidate 0)
            (compiler-backend-iag-bit-set!
              census.writes
              (* func census.words)
              candidate)
            (compiler-backend-iag-bit-set! census.written 0 candidate)))))))

;; Double the edge arrays in place in the cell. Amortized O(1) per edge, and
;; the peak allocation follows the real call count rather than the
;; instruction count.
(define (compiler-backend-iag-grow-edges!
  [cell : be_state.CompilerBackendIagCensusCell]
  [census : be_state.CompilerBackendIagCensus]) : be_state.CompilerBackendIagCensus
  (let
    [capacity : i64 (* census.edge-capacity 2)]
    [src : (__tl_dyn-array i64) (__tl_make-array i64 capacity)]
    [dst : (__tl_dyn-array i64) (__tl_make-array i64 capacity)]
    [grown : be_state.CompilerBackendIagCensus
      (be_state.CompilerBackendIagCensus
        census.count
        census.words
        census.ids
        census.sizes
        census.reasons
        census.slots
        census.function-count
        census.mentions
        census.writes
        census.reach
        census.callee-reach
        census.indirect
        census.written
        capacity
        (be_state.compiler-backend-global-shared-view src)
        (be_state.compiler-backend-global-shared-view dst)
        census.state
        census.functions)]
    (for [index (iterator.range 0 census.edge-capacity)]
      (set! (array-ref src index) (array-ref census.edge-src index))
      (set! (array-ref dst index) (array-ref census.edge-dst index)))
    (set! (array-ref cell.slots 0) grown)
    (compiler-backend-iag-census-of cell)))

;; A direct call: one call-graph edge.
(define (compiler-backend-iag-note-callee!
  [cell : be_state.CompilerBackendIagCensusCell]
  [name : i64]) : unit
  (if (not (compiler-backend-iag-cell-active? cell))
    unit
    (let
      [probe : be_state.CompilerBackendIagCensus
        (compiler-backend-iag-census-of cell)]
      [func : i64 (compiler-backend-iag-current-function probe)]
      (if (< func 0)
        unit
        (let
          [slot : i64
            (backend_i64_i64_map.get-value-or
              (& probe.functions)
              (compiler_ir_types.compiler-ir-symbol-id name)
              -1)]
          (if (< slot 0)
            unit
            (let
              [cursor : i64
                (array-ref probe.state compiler-backend-iag-state-cursor)]
              [census : be_state.CompilerBackendIagCensus
                (if (< cursor probe.edge-capacity)
                  probe
                  (compiler-backend-iag-grow-edges! cell probe))]
              (set! (array-ref census.edge-src cursor) func)
              (set! (array-ref census.edge-dst cursor) slot)
              (set!
                (array-ref census.state compiler-backend-iag-state-cursor)
                (+ cursor 1)))))))))

;; A call through a value: this function's callee set is not enumerable.
(define (compiler-backend-iag-note-indirect!
  [cell : (& cell be_state.CompilerBackendIagCensusCell)]) : unit
  (if (not (compiler-backend-iag-cell-active? cell))
    unit
    (let
      [census : be_state.CompilerBackendIagCensus
        (compiler-backend-iag-census-of cell)]
      [func : i64 (compiler-backend-iag-current-function census)]
      (if (< func 0)
        unit
        (set! (array-ref census.indirect func) true)))))

(define (compiler-backend-function-seq-defines?
  [functions : compiler_ir_types.CompilerIrFunctionSeq]
  [name : i64]) : bool
  (compiler-backend-function-seq-defines-from? functions name))

(define (compiler-backend-function-seq-defines-from?
  [functions : compiler_ir_types.CompilerIrFunctionSeq]
  [name : i64]) : bool
  (for [index
    (iterator.range
      0
      (compiler_ir_types.compiler-ir-function-seq-count functions))]
    (match (owned_view.compiler-owned-element-view functions.slots index)
      [(Function func-name _ _ _ _ _)
        (when
          (compiler_ir_types.compiler-ir-symbol-eq? func-name name)
          (return true))]))
  false)

(define (compiler-backend-runtime-helper-core-id? [name-id : i64]) : bool
  ;; The allocator/arena/TLS substrate is irreducible backend core runtime.
  ;; It bootstraps ordinary TypeLisp allocation, owns the
  ;; `tl_current_arena` slot, and must remain import-free/allocation-free while
  ;; acquiring and releasing arena pages. Linux page ownership is the
  ;; mmap/munmap sequence in `tl_alloc`, `tl_arena_make`, `tl_arena_destroy`,
  ;; and `tl_region_reset`; Windows uses kernel32 VirtualAlloc/VirtualFree in
  ;; the same allocation/release paths. `tl_region_mark`, `tl_arena_current`,
  ;; `tl_arena_set`, `tl_arena_poison_enable`, and the thread entry helpers
  ;; read or update backend runtime TLS state.
  ;; tl_oob_abort / tl_div_abort / tl_shift_abort live in the runtime prelude
  ;; (stdlib/runtime.tl) and are provided by export-symbol, so they are not
  ;; backend-owned runtime helpers (keeping them here would make the export
  ;; collide with a "known runtime symbol").
  (cbi.compiler-builtin-backend-runtime-core-id? name-id))

;; Stdlib modules depend on these backend runtime shims for
;; unavoidable profile operations.
(define (compiler-backend-runtime-helper-stdlib-ffi-id? [name-id : i64]) : bool
  (cbi.compiler-builtin-backend-runtime-stdlib-ffi-id? name-id))

;; Runtime helpers whose implementation and fixed export symbols are owned by
;; the TypeLisp stdlib prelude.
(define (compiler-backend-runtime-helper-stdlib-type-lisp-id? [name-id : i64]) : bool
  (cbi.compiler-builtin-backend-runtime-stdlib-type-lisp-id? name-id))

(define (compiler-backend-runtime-helper-owner-id [name-id : i64]) : be_state.CompilerBackendRuntimeHelperOwner
  (cond
    [(compiler-backend-runtime-helper-core-id? name-id) (Core)]
    [(compiler-backend-runtime-helper-stdlib-ffi-id? name-id) (StdlibFfi)]
    [(compiler-backend-runtime-helper-stdlib-type-lisp-id? name-id)
      (StdlibTypeLisp)]
    [else (Unknown)]))

(define (compiler-backend-runtime-helper-known-id? [name-id : i64]) : bool
  (match (compiler-backend-runtime-helper-owner-id name-id)
    [(Unknown) false]
    [_ true]))

(define (compiler-backend-current-arena-load
  [target : be_state.CompilerBackendTarget]
  [dst : String]) : String
  (match target
    [(be_state.CompilerBackendTarget.Linux)
      (runtime_linux.compiler-backend-current-arena-load dst)]
    [(be_state.CompilerBackendTarget.Windows)
      (runtime_windows.compiler-backend-current-arena-load dst)]))

(define (compiler-backend-runtime-usable-end-offset
  [target : be_state.CompilerBackendTarget]) : String
  (match target
    [(be_state.CompilerBackendTarget.Linux)
      (runtime_linux.compiler-backend-runtime-usable-end-offset)]
    [(be_state.CompilerBackendTarget.Windows)
      (runtime_windows.compiler-backend-runtime-usable-end-offset)]))

(define (compiler-backend-current-arena-store
  [target : be_state.CompilerBackendTarget]
  [src : String]) : String
  (match target
    [(be_state.CompilerBackendTarget.Linux)
      (runtime_linux.compiler-backend-current-arena-store src)]
    [(be_state.CompilerBackendTarget.Windows)
      (runtime_windows.compiler-backend-current-arena-store src)]))

;; Argument register for call arg `idx` under the target's calling convention.
;; System V (Linux) uses rdi/rsi/rdx/rcx/r8/r9;
;; Windows x64 passes the first four integer/pointer args in rcx/rdx/r8/r9.
(define (compiler-backend-target-arg-reg
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [idx : i64]) : be_state.ResultBackendReg
  (be_state.compiler-backend-result-reg
    (compiler_abi.compiler-abi-gp-arg-register
      (be_state.compiler-backend-target-abi target)
      convention
      idx)
    "backend: too many call args"))

(define (compiler-backend-target-float-arg-reg
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [idx : i64]) : be_state.ResultBackendReg
  (be_state.compiler-backend-result-reg
    (compiler_abi.compiler-abi-float-arg-register
      (be_state.compiler-backend-target-abi target)
      convention
      idx)
    "backend: too many call args"))

(define (compiler-backend-call-bank-index
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [bank-idx : i64]
  [position : i64]) : i64
  (if (compiler_abi.compiler-abi-arg-banks-independent?
    (be_state.compiler-backend-target-abi target)
    convention)
    bank-idx
    position))

(define (compiler-backend-target-arg-reg-for-banks
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [int-idx : i64]
  [position : i64]) : be_state.ResultBackendReg
  (compiler-backend-target-arg-reg
    target
    convention
    (compiler-backend-call-bank-index target convention int-idx position)))

(define (compiler-backend-target-float-arg-reg-for-banks
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [float-idx : i64]
  [position : i64]) : be_state.ResultBackendReg
  (compiler-backend-target-float-arg-reg
    target
    convention
    (compiler-backend-call-bank-index target convention float-idx position)))

;; Caller-reserved outgoing shadow space in bytes: none on System V or Windows
;; Internal calls, 32 on Windows Platform calls.
(define (compiler-backend-outgoing-shadow-space
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]) : i64
  (compiler_abi.compiler-abi-outgoing-shadow-space
    (be_state.compiler-backend-target-abi target)
    convention))

;; True when a direct call targets a compiler/runtime-owned helper that takes
;; at most four register arguments, never touches the caller's Win64 home area,
;; and allocates its own frame before any OS/Win32 call. These helpers keep the
;; Platform register convention (preserving RSI/RDI) without forcing every
;; caller to reserve 32 bytes of shadow space.
(define (compiler-backend-direct-call-shadow-free-runtime?
  [program-index : be_state.CompilerBackendProgramIndex]
  [name : i64]) : bool
  (let
    [link-id : i64
      (be_operand.compiler-backend-index-extern-link-symbol-id
        program-index
        name)]
    (or
      (cbi.compiler-builtin-backend-runtime-platform-id? name)
      (cbi.compiler-builtin-backend-runtime-platform-id? link-id)
      (let
        [sym : String
          (be_state.compiler-backend-symbol-text-index program-index link-id)]
        (or
          (string.eq sym "tl_memchr")
          (string.eq sym "tl_array_fill8")
          (string.eq sym "tl_oob_abort")
          (string.eq sym "tl_div_abort")
          (string.eq sym "tl_shift_abort")
          (string.eq sym "tl_abort_string")
          (string.eq sym "tl_oob_abort_at")
          (string.eq sym "tl_div_abort_at")
          (string.eq sym "tl_shift_abort_at")
          (string.eq sym "tl_panic_at"))))))

(define (compiler-backend-direct-call-outgoing-shadow-space
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [program-index : be_state.CompilerBackendProgramIndex]
  [name : i64]) : i64
  (let
    [shadow : i64 (compiler-backend-outgoing-shadow-space target convention)]
    (if (and
      (> shadow 0)
      (not
        (compiler-backend-direct-call-shadow-free-runtime? program-index name)))
      shadow
      0)))

(define (compiler-backend-call-instr-outgoing-shadow-space
  [target : be_state.CompilerBackendTarget]
  [instr : (& instr compiler_ir_types.CompilerIrInstr)]
  [program-index : be_state.CompilerBackendProgramIndex]) : i64
  (if (= (compiler-backend-outgoing-shadow-space target (Platform)) 0)
    0
    (match instr
      [(or (Call _ name _ _) (TailCall name _ _))
        (compiler-backend-direct-call-outgoing-shadow-space
          target
          (compiler_regalloc.compiler-reg-direct-call-convention name)
          program-index
          name)]
      [(or (CallIndirect _ _ _ _) (TailCallIndirect _ _ _) (SpmdCall _)
           (BoundsCheck _ _ _))
        0]
      [_ (compiler-backend-outgoing-shadow-space target (Platform))])))

(define (compiler-backend-target-linux?
  [target : be_state.CompilerBackendTarget]) : bool
  (match target
    [(be_state.CompilerBackendTarget.Linux) true]
    [(be_state.CompilerBackendTarget.Windows) false]))

(define (compiler-backend-target-windows?
  [target : be_state.CompilerBackendTarget]) : bool
  (match target
    [(be_state.CompilerBackendTarget.Linux) false]
    [(be_state.CompilerBackendTarget.Windows) true]))

(define (compiler-backend-assembly-stream-active?
  [stream : be_state.CompilerBackendStreamState]) : bool
  (unsafe
    (deref (be_state.compiler-backend-stream-state-view stream)).assembly-active))