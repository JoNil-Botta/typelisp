;; compiler_backend_calls.tl - Call, argument-move, allocation and switch emission.
(import compiler_backend_scalar as be_scalar)
(import compiler_backend_peephole as be_peephole)
(import compiler_backend_simd as be_simd)
(import compiler_backend_operands as be_operand)
(import compiler_backend_program_facts as be_facts)
(import compiler_backend_state as be_state)
(import stdlib.iterator)
(import compiler_ir_types)
(import compiler_ast_types)
(import compiler_builtin_ids as cbi)
(import compiler_diagnostic)
(import compiler_abi)
(import compiler_regalloc)
(import compiler_liveness)
(import compiler_parallel_move as pmove)
(import compiler_backend_runtime_common as runtime_common)
(import stdlib.string)
(import compiler_str_cat as str_cat)
(import compiler_owned_view as owned_view)

;; Float argument loads stay on the String emitter (a cold family next to the
;; scalar loads); the sequence buffer takes their text in one append.
(define (compiler-backend-emit-load-float-value-into
  [out : (&mut out be_state.CompilerBackendAsmBuf)]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [reg : String]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [head
      (try
        (be_operand.compiler-backend-emit-load-float-value
          assignments
          value
          ty
          reg
          backend-state))]
    (be_state.compiler-backend-asm-append out head)
    (Ok "")))

(define (compiler-backend-emit-store-typed-var-into
  [out : (&mut out be_state.CompilerBackendAsmBuf)]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [var-id : i64]
  [reg : String]
  [ty : compiler_ast_types.AstType]
  [backend-state : be_state.CompilerBackendState]) : unit
  ;; The float store stays a String emitter (a cold family); the scalar store,
  ;; which is the hot one, appends its line straight into the caller's buffer.
  (if (be_operand.compiler-backend-float-type? ty)
    (be_state.compiler-backend-asm-append
      out
      (be_operand.compiler-backend-emit-store-float-var
        assignments
        var-id
        reg
        ty
        backend-state))
    (be_operand.compiler-backend-emit-store-var-into
      out
      assignments
      var-id
      reg
      backend-state)))

(define (compiler-backend-fast-alloc-size
  [args : compiler_ir_types.CompilerIrCallArgs]) : i64
  (match args
    [(One (I64 size))
      (if (or (<= size 0) (> size 64))
        0
        (* (/ (+ size 7) 8) 8))]
    [_ 0]))

(define (compiler-backend-fast-alloc-supported-size? [size : i64]) : bool
  (and (> size 0) (<= size 64) (= (% size 8) 0)))

(define (compiler-backend-fast-alloc-label [size : i64]) : String
  (str_cat.str-cat ".L_tl_alloc" (string.int->string size) "" ""))

(define (compiler-backend-inline-fast-alloc?
  [size : i64]
  [function-state : be_state.CompilerBackendFunctionState]
  [label : i64]) : bool
  (and
    (compiler-backend-fast-alloc-supported-size? size)
    (be_state.compiler-backend-function-loop-block? function-state label)))

(define (compiler-backend-fast-alloc-site-label
  [function : String]
  [current-label : i64]
  [site : i64]
  [dst : i64]
  [suffix : String]) : String
  (be_operand.compiler-backend-asm-label
    function
    (compiler_ir_types.compiler-ir-label
      (&
        (str_cat.str-cat
          "alloc"
          (compiler_ir_types.compiler-ir-label-text current-label)
          "_i"
          (str_cat.str-cat
            (string.int->string site)
            "_v"
            (string.int->string dst)
            suffix))))))

(define (compiler-backend-emit-inline-fast-alloc
  [target : be_state.CompilerBackendTarget]
  [function : String]
  [current-label : i64]
  [site : i64]
  [dst : i64]
  [size : i64]
  [profile : bool]
  [global-storage? : bool]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [size-text : String (string.int->string size)]
    [retry-label : String
      (if global-storage?
        (compiler-backend-fast-alloc-site-label
          (be_state.compiler-backend-global-shared-view function)
          current-label
          site
          dst
          "_retry")
        "")]
    [slow-label : String
      (compiler-backend-fast-alloc-site-label
        (be_state.compiler-backend-global-shared-view function)
        current-label
        site
        dst
        "_slow")]
    [done-label : String
      (compiler-backend-fast-alloc-site-label
        (be_state.compiler-backend-global-shared-view function)
        current-label
        site
        dst
        "_done")]
    [profile-label : String
      (compiler-backend-fast-alloc-site-label
        function
        current-label
        site
        dst
        "_profile_done")]
    [usable-end-offset : String
      (be_facts.compiler-backend-runtime-usable-end-offset target)]
    [scav : String
      (be_operand.compiler-backend-scavenge-reg
        dst
        (be_scalar.compiler-backend-binop-scavenge-exclude-build)
        5
        "%r8"
        backend-state)]
    ;; Keep the stable root in `scav` for the shared-arena flag check and use a
    ;; second proven-free scratch register for the physical current head.
    ;; `%rax` is the cursor/result register below, so exclude it from the head
    ;; pick as well. Once the head is loaded, the root scratch is dead and is
    ;; deliberately recycled as the next-cursor/profile scratch.
    [head-exclude : (__tl_dyn-array String)
      (be_operand.compiler-backend-scavenge-exclude-append
        (be_operand.compiler-backend-one-exclude
          (be_state.compiler-backend-global-shared-view scav))
        1
        "%rax")]
    [head-reg : String
      (be_operand.compiler-backend-scavenge-reg
        dst
        head-exclude
        2
        "%r9"
        backend-state)]
    ;; Ordinary storage uses a plain bump only after excluding shared arenas.
    ;; The private global root is always atomic; its segments are never freed,
    ;; so a CAS may finish on an older head even if another thread grows it.
    ;; The shared flag is bit 0 of the arena's flag word and only `jnz` reads
    ;; the result, so testing the flag word's low byte is exact; `testb` takes
    ;; an 8-bit immediate where `testq` on memory needs 32 bits. The slot is
    ;; never 0: with no arena it holds the null-arena sentinel, whose shared
    ;; bit sends this path to the helper (`compiler-backend-runtime-null-arena-data`).
    (str_cat.str-cat
      (if global-storage?
        (str_cat.str-cat
          "    movq .L_tl_global_aggregate_arena+56(%rip), "
          head-reg
          "\n    movq 16("
          head-reg
          "), %rax\n"
          retry-label
          ":\n")
        (str_cat.str-cat
          (be_facts.compiler-backend-current-arena-load
            target
            (be_state.compiler-backend-global-shared-view scav))
          "    testb $1, 48("
          scav
          ")\n    jnz "
          slow-label
          "\n    movq 56("
          scav
          "), "
          head-reg
          "\n    movq 16("
          head-reg
          "), %rax\n"))
      (str_cat.str-cat "    leaq " size-text "(%rax), " scav "\n")
      ;; No wrap guard: `size` is a fixed 8..64 byte literal (the
      ;; fast-alloc admission gate) and the bump cursor is a canonical
      ;; user-space arena address, so `cursor + size` cannot carry past
      ;; 2^64. Only the usable-end bound below can fail, and it routes to
      ;; the same slow path. The general variable-size `tl_alloc` keeps its
      ;; guard because its size argument is caller-supplied.
      (str_cat.str-cat
        "    cmpq "
        usable-end-offset
        "("
        head-reg
        "), "
        scav
        "\n")
      (str_cat.str-cat
        "    ja "
        slow-label
        (if global-storage?
          (str_cat.str-cat
            "\n    lock cmpxchgq "
            scav
            ", 16("
            head-reg
            ")\n    jne "
            retry-label
            "\n")
          (str_cat.str-cat "\n    movq " scav ", 16(" head-reg ")\n")))
      (let
        [size-reg (str_cat.str-cat "$" size-text)]
        (runtime_common.compiler-backend-runtime-profile-alloc-account-with-scratch
          size-reg
          profile-label
          profile
          scav))
      (str_cat.str-cat "    jmp " done-label "\n" slow-label ":\n")
      (str_cat.str-cat
        (if global-storage?
          (str_cat.str-cat
            (be_scalar.compiler-backend-emit-load-i64-immediate
              size
              (match target
                [(Linux) "%rdi"]
                [(Windows) "%rcx"]))
            "    call tl_alloc_global\n")
          (str_cat.str-cat
            "    call "
            (compiler-backend-fast-alloc-label size)
            "\n"))
        done-label
        ":\n"))))

(define (compiler-backend-param-list-from-types
  [type-segment-bases : i64]
  [types : (& types compiler_ast_types.AstTypeList)]
  [idx : i64]) : compiler_ir_types.CompilerIrParamSeq
  (let
    [builder : compiler_ir_types.CompilerIrParamBuilder
      (compiler_ir_types.compiler-ir-param-builder-with-capacity
        (- (compiler_ast_types.ast-type-list-len (& types)) idx))]
    (compiler-backend-param-list-from-types-into!
      type-segment-bases
      (& types)
      idx
      (&mut builder))
    (compiler_ir_types.compiler-ir-param-builder-to-seq builder)))

(define (compiler-backend-param-list-from-types-into!
  [type-segment-bases : i64]
  [types : (& types compiler_ast_types.AstTypeList)]
  [idx : i64]
  [builder : (&mut builder compiler_ir_types.CompilerIrParamBuilder)]) : unit
  (unless
    (>= idx (compiler_ast_types.ast-type-list-len types))
    (compiler_ir_types.compiler-ir-param-builder-push!
      builder
      (compiler_ir_types.CompilerIrParam.Param
        (str_cat.str-cat "arg" (string.int->string idx))
        (compiler_ast_types.ast-type-segment-bases-get
          type-segment-bases
          (compiler_ast_types.ast-type-list-get
            types
            idx
            (compiler_ast_types.ast-type-id-fallback)))
        idx))
    (compiler-backend-param-list-from-types-into!
      type-segment-bases
      types
      (+ idx 1)
      builder)))

(define (compiler-backend-addressable-group-vars-instr
  [groups : (& groups compiler_liveness.CompilerLiveI64Set)]
  [out : compiler_liveness.CompilerLiveI64Set]
  [instr : compiler_ir_types.CompilerIrInstr]) : compiler_liveness.CompilerLiveI64Set
  (match instr
    [(AddrOf _ src _storage-words)
      (if (compiler_liveness.compiler-live-set-contains? groups src)
        (compiler_liveness.compiler-live-set-insert out src)
        out)]
    [_ out]))

(define (compiler-backend-addressable-group-vars-seq
  [groups : compiler_liveness.CompilerLiveI64Set]
  [out : compiler_liveness.CompilerLiveI64Set]
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : compiler_liveness.CompilerLiveI64Set
  (let
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [count : i64 instrs.len]
    [next : compiler_liveness.CompilerLiveI64Set out]
    (for [index (iterator.range 0 count)]
      (set!
        next
        (compiler-backend-addressable-group-vars-instr
          groups
          next
          (be_state.compiler-backend-global-array-element-shared-view
            slots
            index))))
    next))

(define (compiler-backend-addressable-group-vars-blocks
  [groups : compiler_liveness.CompilerLiveI64Set]
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [out : compiler_liveness.CompilerLiveI64Set]) : compiler_liveness.CompilerLiveI64Set
  (match blocks
    [(Array seq)
      (compiler-backend-addressable-group-vars-block-seq groups seq out 0)]))

(define (compiler-backend-addressable-group-vars-block-seq
  [groups : compiler_liveness.CompilerLiveI64Set]
  [blocks : compiler_ir_types.CompilerIrBlockSeq]
  [out : compiler_liveness.CompilerLiveI64Set]
  [index : i64]) : compiler_liveness.CompilerLiveI64Set
  (if (>= index (compiler_ir_types.compiler-ir-block-seq-count blocks))
    out
    (match (compiler_ir_types.compiler-ir-block-seq-ref blocks index)
      [(Block _ instrs)
        (compiler-backend-addressable-group-vars-block-seq
          (be_state.compiler-backend-global-shared-view groups)
          blocks
          (compiler-backend-addressable-group-vars-seq groups out instrs)
          (+ index 1))])))

;; Late IR rewrites can introduce copies after the allocator's group-var set
;; was computed. Seed nominal two-word copies with the backend's canonical
;; program-wide classification, then let the allocator's bidirectional
;; Mov/Phi closure carry group provenance through the final emitted blocks.
(define (compiler-backend-late-group-vars-instr
  [type-segment-bases : i64]
  [index : be_state.CompilerBackendProgramIndex]
  [groups : compiler_liveness.CompilerLiveI64Set]
  [instr : (& compiler_ir_types.CompilerIrInstr)]) : compiler_liveness.CompilerLiveI64Set
  (match instr
    [(Mov dst src ty)
      (if (be_facts.compiler-backend-group-type? type-segment-bases index ty)
        (match src
          [(Var src-var)
            (compiler_liveness.compiler-live-set-insert
              (compiler_liveness.compiler-live-set-insert groups dst)
              src-var)]
          [_ (compiler_liveness.compiler-live-set-insert groups dst)])
        groups)]
    [_ groups]))

(define (compiler-backend-late-group-vars-seq
  [type-segment-bases : i64]
  [index : be_state.CompilerBackendProgramIndex]
  [groups : compiler_liveness.CompilerLiveI64Set]
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : compiler_liveness.CompilerLiveI64Set
  (let
    [count : i64 (compiler_ir_types.compiler-ir-instr-seq-count instrs)]
    [out : compiler_liveness.CompilerLiveI64Set groups]
    (for [i (iterator.range 0 count)]
      (set!
        out
        (compiler-backend-late-group-vars-instr
          type-segment-bases
          index
          out
          (compiler_ir_types.compiler-ir-instr-seq-borrow instrs i))))
    out))

(define (compiler-backend-late-group-vars-blocks
  [type-segment-bases : i64]
  [index : be_state.CompilerBackendProgramIndex]
  [groups : compiler_liveness.CompilerLiveI64Set]
  [blocks : compiler_ir_types.CompilerIrBlockList]) : compiler_liveness.CompilerLiveI64Set
  (match blocks
    [(Array seq)
      (let
        [count : i64 (compiler_ir_types.compiler-ir-block-seq-count seq)]
        [out : compiler_liveness.CompilerLiveI64Set groups]
        (for [i (iterator.range 0 count)]
          (match (compiler_ir_types.compiler-ir-block-seq-ref seq i)
            [(Block _ instrs)
              (set!
                out
                (compiler-backend-late-group-vars-seq
                  type-segment-bases
                  index
                  out
                  instrs))]))
        out)]))

;; System V assigns a two-eightbyte aggregate atomically. Test both required
;; register banks before consuming either one: if one word cannot be assigned,
;; the caller/callee must put both words on the stack and roll both cursors back.
(define (compiler-backend-linux-group-register-banks-fit?
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [program-index : be_state.CompilerBackendProgramIndex]
  [ty : compiler_ast_types.AstType]
  [int-idx : i64]
  [float-idx : i64]
  [position : i64]) : bool
  (let
    [w0-sse : bool
      (be_facts.compiler-backend-group-word-sse?
        type-segment-bases
        program-index
        ty
        0)]
    [int1 : i64
      (if w0-sse
        int-idx
        (+ int-idx 1))]
    [float1 : i64
      (if w0-sse
        (+ float-idx 1)
        float-idx)]
    [w1-sse : bool
      (be_facts.compiler-backend-group-word-sse?
        type-segment-bases
        program-index
        ty
        1)]
    (and
      (be_state.compiler-backend-target-sysv-aggregates? target convention)
      (not
        (be_scalar.compiler-backend-stack-call-arg-for-banks?
          target
          convention
          w0-sse
          int-idx
          float-idx
          position))
      (not
        (be_scalar.compiler-backend-stack-call-arg-for-banks?
          target
          convention
          w1-sse
          int1
          float1
          (+ position 1))))))

(define (compiler-backend-extern-call-info-fixed-count [info : i64]) : i64
  (- (/ info 4) 1))

(define (compiler-backend-runtime-param-types-id [name-id : i64]) : compiler_ast_types.AstTypeList
  (cond
    [(cbi.compiler-builtin-backend-tl-array-fill8-id? name-id)
      (compiler_ast_types.ast-type-cons
        (& (compiler_ast_types.ast-ty-mut-ptr (& (U8))))
        (&
          (compiler_ast_types.ast-type-cons
            (& (I64))
            (&
              (compiler_ast_types.ast-type-cons
                (& (U64))
                (& (compiler_ast_types.ast-type-list-new)))))))]
    [(cbi.compiler-builtin-backend-tl-array-zero-id? name-id)
      (compiler_ast_types.ast-type-cons
        (& (compiler_ast_types.ast-ty-mut-ptr (& (U8))))
        (&
          (compiler_ast_types.ast-type-cons
            (& (I64))
            (& (compiler_ast_types.ast-type-list-new)))))]
    [(cbi.compiler-builtin-backend-tl-mem-fill8-id? name-id)
      (compiler_ast_types.ast-type-cons
        (& (compiler_ast_types.ast-ty-mut-ptr (& (U8))))
        (&
          (compiler_ast_types.ast-type-cons
            (& (I64))
            (&
              (compiler_ast_types.ast-type-cons
                (& (U64))
                (& (compiler_ast_types.ast-type-list-new)))))))]
    [(cbi.compiler-builtin-backend-tl-mem-copy-fwd-id? name-id)
      (compiler_ast_types.ast-type-cons
        (& (compiler_ast_types.ast-ty-mut-ptr (& (U8))))
        (&
          (compiler_ast_types.ast-type-cons
            (& (compiler_ast_types.ast-ty-ptr (& (U8))))
            (&
              (compiler_ast_types.ast-type-cons
                (& (I64))
                (& (compiler_ast_types.ast-type-list-new)))))))]
    [(cbi.compiler-builtin-backend-tl-mem-copy8-fwd-id? name-id)
      (compiler_ast_types.ast-type-cons
        (& (compiler_ast_types.ast-ty-mut-ptr (& (U8))))
        (&
          (compiler_ast_types.ast-type-cons
            (& (compiler_ast_types.ast-ty-ptr (& (U8))))
            (&
              (compiler_ast_types.ast-type-cons
                (& (I64))
                (& (compiler_ast_types.ast-type-list-new)))))))]
    [else (compiler_ast_types.ast-type-list-new)]))

(define (compiler-backend-varargs-linux-vector-count
  [type-segment-bases : i64]
  [types : compiler_ast_types.AstTypeList]
  [float-idx : i64]
  [count : i64]) : i64
  (compiler-backend-varargs-linux-vector-count-at
    type-segment-bases
    (& types)
    float-idx
    count))

(define (compiler-backend-varargs-linux-vector-count-at
  [type-segment-bases : i64]
  [types : (& types compiler_ast_types.AstTypeList)]
  [float-idx : i64]
  [count : i64]) : i64
  (for [index (iterator.range 0 (compiler_ast_types.ast-type-list-len types))]
    (let
      [ty : compiler_ast_types.AstType
        (compiler_ast_types.ast-type-segment-bases-get
          type-segment-bases
          (compiler_ast_types.ast-type-list-get
            types
            index
            (compiler_ast_types.ast-type-id-fallback)))]
      [is-float : bool (be_operand.compiler-backend-float-type? ty)]
      [next-float : i64
        (if is-float
          (+ float-idx 1)
          float-idx)]
      [next-count : i64
        (if (and
          is-float
          (<
            float-idx
            (compiler_abi.compiler-abi-float-arg-register-count
              Linux
              (Platform))))
          (+ count 1)
          count)]
      (set! float-idx next-float)
      (set! count next-count)))
  count)

(define (compiler-backend-windows-vararg-int-reg [position : i64]) : String
  (compiler_abi.compiler-abi-gp-arg-register Windows (Platform) position))

(define (compiler-backend-windows-vararg-dup-asm
  [type-segment-bases : i64]
  [types : compiler_ast_types.AstTypeList]
  [fixed-count : i64]
  [position : i64]) : String
  (compiler-backend-windows-vararg-dup-asm-at
    type-segment-bases
    (& types)
    fixed-count
    position))

(define (compiler-backend-windows-vararg-dup-asm-at
  [type-segment-bases : i64]
  [types : (& types compiler_ast_types.AstTypeList)]
  [fixed-count : i64]
  [position : i64]) : String
  (if (>= position (compiler_ast_types.ast-type-list-len types))
    ""
    (let
      [ty : compiler_ast_types.AstType
        (compiler_ast_types.ast-type-segment-bases-get
          type-segment-bases
          (compiler_ast_types.ast-type-list-get
            types
            position
            (compiler_ast_types.ast-type-id-fallback)))]
      [tail : String
        (compiler-backend-windows-vararg-dup-asm-at
          type-segment-bases
          types
          fixed-count
          (+ position 1))]
      [reg : String (compiler-backend-windows-vararg-int-reg position)]
      (if (and
        (>= position fixed-count)
        (<
          position
          (compiler_abi.compiler-abi-gp-arg-register-count Windows (Platform)))
        (be_operand.compiler-backend-float-type? ty))
        (str_cat.str-cat
          "    movq %xmm"
          (string.int->string position)
          ", "
          reg
          (str_cat.str-cat "\n" tail))
        tail))))

(define (compiler-backend-varargs-pre-call
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [extern-call-info : i64]
  [param-types : compiler_ast_types.AstTypeList]) : String
  (let
    [fixed-count : i64
      (compiler-backend-extern-call-info-fixed-count extern-call-info)]
    (if (< fixed-count 0)
      ""
      (if (compiler_abi.compiler-abi-varargs-vector-count-in-al?
        (be_state.compiler-backend-target-abi target)
        (Platform))
        (str_cat.str-cat
          "    movb $"
          (string.int->string
            (compiler-backend-varargs-linux-vector-count
              type-segment-bases
              param-types
              0
              0))
          ", %al\n"
          ""
          "")
        (compiler-backend-windows-vararg-dup-asm
          type-segment-bases
          param-types
          fixed-count
          0)))))

(define (compiler-backend-call-param-types-index
  [name : i64]
  [index : be_state.CompilerBackendProgramIndex]) : compiler_ast_types.AstTypeList
  (match (be_facts.compiler-backend-index-signature index name)
    [(Some param-types _) param-types]
    [(No) (compiler-backend-runtime-param-types-id name)]))

(define (compiler-backend-call-actual-type
  [types : compiler_regalloc.CompilerRegVarTypes]
  [global-types : be_state.CompilerBackendGlobalTypeTable]
  [value : compiler_ir_types.CompilerIrValue]) : compiler_ast_types.AstType
  (match (be_facts.compiler-backend-value-type types global-types value)
    [(Some ty) ty]
    [(No) (I64)]))

(define (compiler-backend-call-actual-param-type-for-index
  [type-segment-bases : i64]
  [types : compiler_regalloc.CompilerRegVarTypes]
  [global-types : be_state.CompilerBackendGlobalTypeTable]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [fixed-types : (& fixed-types compiler_ast_types.AstTypeList)]
  [fixed-count : i64]
  [index : i64]) : compiler_ast_types.AstType
  (if (< index fixed-count)
    (if (< index (compiler_ast_types.ast-type-list-len (& fixed-types)))
      (compiler_ast_types.ast-type-segment-bases-get
        type-segment-bases
        (compiler_ast_types.ast-type-list-get
          (& fixed-types)
          index
          (compiler_ast_types.ast-type-id-fallback)))
      (compiler-backend-call-actual-type
        types
        global-types
        (be_facts.compiler-backend-call-arg-at args index)))
    (compiler-backend-call-actual-type
      types
      global-types
      (be_facts.compiler-backend-call-arg-at args index))))

(define (compiler-backend-call-actual-param-types-fill
  [type-segment-bases : i64]
  [out : (&mut out compiler_ast_types.AstTypeList)]
  [types : compiler_regalloc.CompilerRegVarTypes]
  [global-types : be_state.CompilerBackendGlobalTypeTable]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [fixed-types : compiler_ast_types.AstTypeList]
  [fixed-count : i64]
  [index : i64]) : unit
  (unless
    (>=
      index
      (be_facts.compiler-backend-call-args-count
        (be_state.compiler-backend-global-shared-view args)))
    (compiler_ast_types.ast-type-list-push
      out
      (compiler_ast_types.ast-node-pool-reader-type-push
        (&
          (compiler-backend-call-actual-param-type-for-index
            type-segment-bases
            types
            (be_state.compiler-backend-global-shared-view global-types)
            (be_state.compiler-backend-global-shared-view args)
            fixed-types
            fixed-count
            index))))
    (compiler-backend-call-actual-param-types-fill
      type-segment-bases
      out
      types
      global-types
      args
      fixed-types
      fixed-count
      (+ index 1))))

(define (compiler-backend-call-actual-param-types-from
  [type-segment-bases : i64]
  [types : compiler_regalloc.CompilerRegVarTypes]
  [global-types : be_state.CompilerBackendGlobalTypeTable]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [fixed-types : compiler_ast_types.AstTypeList]
  [fixed-count : i64]
  [index : i64]) : compiler_ast_types.AstTypeList
  (let
    [out : compiler_ast_types.AstTypeList
      (compiler_ast_types.ast-type-list-with-capacity
        (be_facts.compiler-backend-call-args-count
          (be_state.compiler-backend-global-shared-view args)))]
    (compiler-backend-call-actual-param-types-fill
      type-segment-bases
      (&mut out)
      types
      global-types
      args
      fixed-types
      fixed-count
      index)
    out))

(define (compiler-backend-call-c-abi-param-types-fill
  [type-segment-bases : i64]
  [out : (&mut out compiler_ast_types.AstTypeList)]
  [types : compiler_regalloc.CompilerRegVarTypes]
  [global-types : be_state.CompilerBackendGlobalTypeTable]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [declared-types : compiler_ast_types.AstTypeList]
  [decl-index : i64]
  [arg-index : i64]
  [program-index : be_state.CompilerBackendProgramIndex]) : unit
  (if (>=
    arg-index
    (be_facts.compiler-backend-call-args-count
      (be_state.compiler-backend-global-shared-view args)))
    unit
    (if (>=
      decl-index
      (compiler_ast_types.ast-type-list-len (& declared-types)))
      (compiler-backend-call-actual-param-types-fill
        type-segment-bases
        out
        types
        global-types
        args
        (compiler_ast_types.ast-type-list-new)
        0
        arg-index)
      (let
        [declared : i64
          (compiler_ast_types.ast-type-list-get
            (& declared-types)
            decl-index
            (compiler_ast_types.ast-type-id-fallback))]
        [declared-ty : compiler_ast_types.AstType
          (compiler_ast_types.ast-type-segment-bases-get
            type-segment-bases
            declared)]
        [memory-size : i64
          (compiler-backend-c-memory-aggregate-marker-size
            (be_state.compiler-backend-global-shared-view args)
            (+ arg-index 1))]
        [aggregate? : bool
          (not
            (string.eq
              (be_facts.compiler-backend-aggregate-type-name
                type-segment-bases
                (be_state.compiler-backend-global-shared-view declared-ty))
              ""))]
        (if (and (> memory-size 0) aggregate?)
          (begin
            (compiler_ast_types.ast-type-list-push
              out
              (compiler_ast_types.ast-node-pool-reader-type-push
                (& declared-ty)))
            (compiler_ast_types.ast-type-list-push
              out
              (compiler_ast_types.ast-node-pool-reader-type-push (& (I64))))
            (compiler_ast_types.ast-type-list-push
              out
              (compiler_ast_types.ast-node-pool-reader-type-push (& (Unit))))
            (compiler-backend-call-c-abi-param-types-fill
              type-segment-bases
              out
              types
              global-types
              args
              declared-types
              (+ decl-index 1)
              (+ arg-index 3)
              program-index))
          (if (and
            aggregate?
            (be_facts.compiler-backend-group-type?
              type-segment-bases
              program-index
              declared-ty)
            (<
              (+ arg-index 1)
              (be_facts.compiler-backend-call-args-count
                (be_state.compiler-backend-global-shared-view args))))
            (begin
              (compiler_ast_types.ast-type-list-push
                out
                (compiler_ast_types.ast-node-pool-reader-type-push
                  (&
                    (compiler-backend-call-actual-param-type-at
                      types
                      (be_state.compiler-backend-global-shared-view
                        global-types)
                      (be_state.compiler-backend-global-shared-view args)
                      arg-index))))
              (compiler_ast_types.ast-type-list-push
                out
                (compiler_ast_types.ast-node-pool-reader-type-push
                  (&
                    (compiler-backend-call-actual-param-type-at
                      types
                      (be_state.compiler-backend-global-shared-view
                        global-types)
                      (be_state.compiler-backend-global-shared-view args)
                      (+ arg-index 1)))))
              (compiler-backend-call-c-abi-param-types-fill
                type-segment-bases
                out
                types
                global-types
                args
                declared-types
                (+ decl-index 1)
                (+ arg-index 2)
                program-index))
            (begin
              (compiler_ast_types.ast-type-list-push
                out
                (compiler_ast_types.ast-node-pool-reader-type-push
                  (&
                    (compiler-backend-call-actual-param-type-at
                      types
                      (be_state.compiler-backend-global-shared-view
                        global-types)
                      (be_state.compiler-backend-global-shared-view args)
                      arg-index))))
              (compiler-backend-call-c-abi-param-types-fill
                type-segment-bases
                out
                types
                global-types
                args
                declared-types
                (+ decl-index 1)
                (+ arg-index 1)
                program-index))))))))

(define (compiler-backend-call-c-abi-param-types-from
  [type-segment-bases : i64]
  [types : compiler_regalloc.CompilerRegVarTypes]
  [global-types : be_state.CompilerBackendGlobalTypeTable]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [declared-types : compiler_ast_types.AstTypeList]
  [arg-index : i64]
  [program-index : be_state.CompilerBackendProgramIndex]) : compiler_ast_types.AstTypeList
  (let
    [out : compiler_ast_types.AstTypeList
      (compiler_ast_types.ast-type-list-with-capacity
        (be_facts.compiler-backend-call-args-count
          (be_state.compiler-backend-global-shared-view args)))]
    (compiler-backend-call-c-abi-param-types-fill
      type-segment-bases
      (&mut out)
      types
      global-types
      args
      declared-types
      0
      arg-index
      program-index)
    out))

(define (compiler-backend-call-actual-param-type-at
  [types : compiler_regalloc.CompilerRegVarTypes]
  [global-types : be_state.CompilerBackendGlobalTypeTable]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [index : i64]) : compiler_ast_types.AstType
  (if (<
    index
    (be_facts.compiler-backend-call-args-count
      (be_state.compiler-backend-global-shared-view args)))
    (compiler-backend-call-actual-type
      types
      global-types
      (be_facts.compiler-backend-call-arg-at args index))
    (I64)))

(define (compiler-backend-call-actual-param-types
  [type-segment-bases : i64]
  [types : compiler_regalloc.CompilerRegVarTypes]
  [global-types : be_state.CompilerBackendGlobalTypeTable]
  [args : compiler_ir_types.CompilerIrCallArgs]) : compiler_ast_types.AstTypeList
  (compiler-backend-call-actual-param-types-from
    type-segment-bases
    types
    global-types
    args
    (compiler_ast_types.ast-type-list-new)
    0
    0))

(define (compiler-backend-call-c-abi-param-types
  [type-segment-bases : i64]
  [types : compiler_regalloc.CompilerRegVarTypes]
  [global-types : be_state.CompilerBackendGlobalTypeTable]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [declared-types : compiler_ast_types.AstTypeList]
  [program-index : be_state.CompilerBackendProgramIndex]) : compiler_ast_types.AstTypeList
  (compiler-backend-call-c-abi-param-types-from
    type-segment-bases
    types
    global-types
    args
    declared-types
    0
    program-index))

(define (compiler-backend-call-param-types-for-call
  [type-segment-bases : i64]
  [name : i64]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [types : compiler_regalloc.CompilerRegVarTypes]
  [global-types : be_state.CompilerBackendGlobalTypeTable]
  [extern-call-info : i64]
  [index : be_state.CompilerBackendProgramIndex]) : compiler_ast_types.AstTypeList
  (let
    [param-types : compiler_ast_types.AstTypeList
      (compiler-backend-call-param-types-index name index)]
    [fixed-count : i64
      (compiler-backend-extern-call-info-fixed-count extern-call-info)]
    (if (be_facts.compiler-backend-extern-call-info-aggregate-params?
      extern-call-info)
      (compiler-backend-call-c-abi-param-types
        type-segment-bases
        types
        global-types
        args
        param-types
        index)
      (if (< fixed-count 0)
        (if (=
          (be_facts.compiler-backend-call-args-count
            (be_state.compiler-backend-global-shared-view args))
          (be_facts.compiler-backend-type-list-count param-types))
          param-types
          (compiler-backend-call-actual-param-types
            type-segment-bases
            types
            global-types
            args))
        (compiler-backend-call-actual-param-types-from
          type-segment-bases
          types
          global-types
          args
          param-types
          fixed-count
          0)))))

(define (compiler-backend-stack-slots-for-size [size : i64]) : i64
  (if (<= size 0)
    0
    (/ (+ size 7) 8)))

(define (compiler-backend-c-memory-aggregate-type?
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [c-abi? : bool]
  [ty : compiler_ast_types.AstType]) : bool
  (and
    c-abi?
    (be_state.compiler-backend-target-sysv-aggregates? target (Platform))
    (not
      (string.eq
        (be_facts.compiler-backend-aggregate-type-name type-segment-bases ty)
        ""))))

(define (compiler-backend-c-memory-aggregate-marker-size
  [args : compiler_ir_types.CompilerIrCallArgs]
  [index : i64]) : i64
  (if (<
    (+ index 1)
    (be_facts.compiler-backend-call-args-count
      (be_state.compiler-backend-global-shared-view args)))
    (match (be_facts.compiler-backend-call-arg-at args index)
      [(I64 size)
        (match (be_facts.compiler-backend-call-arg-at args (+ index 1))
          [(Unit) size]
          [_ 0])]
      [_ 0])
    0))

;; Count the OUTGOING arguments that must be passed on the stack. Walks
;; the args in order, tracking the integer/float/position banks exactly as
;; `compiler-backend-emit-call-args` does, and counts every arg whose bank is
;; already full.
(define (compiler-backend-call-stack-arg-count
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [types : (& types compiler_ast_types.AstTypeList)]
  [c-abi? : bool]
  [arg-index : i64]
  [int-idx : i64]
  [float-idx : i64]
  [position : i64]
  [stack-count : i64]
  [program-index : be_state.CompilerBackendProgramIndex]) : i64
  (if (>=
    arg-index
    (be_facts.compiler-backend-call-args-count
      (be_state.compiler-backend-global-shared-view args)))
    stack-count
    (let
      [arg-ty : compiler_ast_types.AstType
        (if (< arg-index (compiler_ast_types.ast-type-list-len (& types)))
          (compiler_ast_types.ast-type-segment-bases-get
            type-segment-bases
            (compiler_ast_types.ast-type-list-get
              (& types)
              arg-index
              (compiler_ast_types.ast-type-id-fallback)))
          (I64))]
      [is-float : bool (be_operand.compiler-backend-float-type? arg-ty)]
      [memory-aggregate? : bool
        (compiler-backend-c-memory-aggregate-type?
          type-segment-bases
          target
          c-abi?
          (be_state.compiler-backend-global-shared-view arg-ty))]
      [memory-size : i64
        (if memory-aggregate?
          (compiler-backend-c-memory-aggregate-marker-size
            (be_state.compiler-backend-global-shared-view args)
            (+ arg-index 1))
          0)]
      [private-memory-size : i64
        (if (not c-abi?)
          (be_facts.compiler-backend-abi-memory-size
            type-segment-bases
            (be_state.compiler-backend-global-shared-view arg-ty))
          0)]
      ;; A register-group arg occupies two ABI word positions and, when it does
      ;; not fit in the required register banks, two stack slots -- mirror exactly
      ;; what emit-call-args does so the reserved frame space matches. That
      ;; includes Windows: emit-call-args groups on BOTH targets (indexing by
      ;; `position` there), so counting a Windows group arg as one scalar slot
      ;; made tail-call stack accounting diverge from emission.
      (cond
        [(and
            (be_state.compiler-backend-target-sysv-aggregates?
              target
              convention)
            (> private-memory-size 0))
          (compiler-backend-call-stack-arg-count
            type-segment-bases
            target
            convention
            args
            types
            c-abi?
            (+ arg-index 1)
            int-idx
            float-idx
            (+ position 1)
            (+
              stack-count
              (compiler-backend-stack-slots-for-size private-memory-size))
            program-index)]
        [(> memory-size 0)
          (compiler-backend-call-stack-arg-count
            type-segment-bases
            target
            convention
            args
            types
            c-abi?
            (+ arg-index 3)
            int-idx
            float-idx
            (+ position 1)
            (+ stack-count (compiler-backend-stack-slots-for-size memory-size))
            program-index)]
        [(be_facts.compiler-backend-group-type?
            type-segment-bases
            program-index
            arg-ty)
          (let
            [linux-group-fits : bool
              (compiler-backend-linux-group-register-banks-fit?
                type-segment-bases
                target
                convention
                program-index
                (be_state.compiler-backend-global-shared-view arg-ty)
                int-idx
                float-idx
                position)]
            [w0-sse : bool
              (be_facts.compiler-backend-group-word-sse?
                type-segment-bases
                program-index
                arg-ty
                0)]
            [w0-stack : bool
              (be_scalar.compiler-backend-stack-call-arg-for-banks?
                target
                convention
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
              (be_facts.compiler-backend-group-word-sse?
                type-segment-bases
                program-index
                arg-ty
                1)]
            [w1-stack : bool
              (be_scalar.compiler-backend-stack-call-arg-for-banks?
                target
                convention
                w1-sse
                int1
                float1
                pos1)]
            (if (and
              (be_state.compiler-backend-target-sysv-aggregates?
                target
                convention)
              (not linux-group-fits))
              (compiler-backend-call-stack-arg-count
                type-segment-bases
                target
                convention
                args
                types
                c-abi?
                (+ arg-index 1)
                int-idx
                float-idx
                (+ position 2)
                (+ stack-count 2)
                program-index)
              (compiler-backend-call-stack-arg-count
                type-segment-bases
                target
                convention
                args
                types
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
                program-index)))]
        [else
          (compiler-backend-call-stack-arg-count
            type-segment-bases
            target
            convention
            args
            types
            c-abi?
            (+ arg-index 1)
            (if is-float
              int-idx
              (+ int-idx 1))
            (if is-float
              (+ float-idx 1)
              float-idx)
            (+ position 1)
            (if (be_scalar.compiler-backend-stack-call-arg-for-banks?
              target
              convention
              is-float
              int-idx
              float-idx
              position)
              (+ stack-count 1)
              stack-count)
            program-index)]))))

(define (compiler-backend-type-list-stack-arg-count
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [types : compiler_ast_types.AstTypeList]
  [int-idx : i64]
  [float-idx : i64]
  [position : i64]
  [stack-count : i64]
  [program-index : be_state.CompilerBackendProgramIndex]) : i64
  (compiler-backend-type-list-stack-arg-count-at
    type-segment-bases
    target
    convention
    (& types)
    0
    int-idx
    float-idx
    position
    stack-count
    program-index))

(define (compiler-backend-type-list-stack-arg-count-at
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [types : (& types compiler_ast_types.AstTypeList)]
  [type-index : i64]
  [int-idx : i64]
  [float-idx : i64]
  [position : i64]
  [stack-count : i64]
  [program-index : be_state.CompilerBackendProgramIndex]) : i64
  (if (>= type-index (compiler_ast_types.ast-type-list-len types))
    stack-count
    (let
      [arg-ty : compiler_ast_types.AstType
        (compiler_ast_types.ast-type-segment-bases-get
          type-segment-bases
          (compiler_ast_types.ast-type-list-get
            types
            type-index
            (compiler_ast_types.ast-type-id-fallback)))]
      [is-float : bool (be_operand.compiler-backend-float-type? arg-ty)]
      [next-int : i64
        (if is-float
          int-idx
          (+ int-idx 1))]
      [next-float : i64
        (if is-float
          (+ float-idx 1)
          float-idx)]
      [private-memory-size : i64
        (be_facts.compiler-backend-abi-memory-size
          type-segment-bases
          (be_state.compiler-backend-global-shared-view arg-ty))]
      (if (and
        (be_state.compiler-backend-target-sysv-aggregates? target convention)
        (> private-memory-size 0))
        (compiler-backend-type-list-stack-arg-count-at
          type-segment-bases
          target
          convention
          types
          (+ type-index 1)
          int-idx
          float-idx
          (+ position 1)
          (+
            stack-count
            (compiler-backend-stack-slots-for-size private-memory-size))
          program-index)
        (if (be_facts.compiler-backend-group-type?
          type-segment-bases
          program-index
          arg-ty)
          (let
            [linux-group-fits : bool
              (compiler-backend-linux-group-register-banks-fit?
                type-segment-bases
                target
                convention
                program-index
                (be_state.compiler-backend-global-shared-view arg-ty)
                int-idx
                float-idx
                position)]
            [w0-sse : bool
              (be_facts.compiler-backend-group-word-sse?
                type-segment-bases
                program-index
                arg-ty
                0)]
            [w0-stack : bool
              (be_scalar.compiler-backend-stack-call-arg-for-banks?
                target
                convention
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
              (be_facts.compiler-backend-group-word-sse?
                type-segment-bases
                program-index
                arg-ty
                1)]
            [w1-stack : bool
              (be_scalar.compiler-backend-stack-call-arg-for-banks?
                target
                convention
                w1-sse
                int1
                float1
                (+ position 1))]
            (if (and
              (be_state.compiler-backend-target-sysv-aggregates?
                target
                convention)
              (not linux-group-fits))
              (compiler-backend-type-list-stack-arg-count-at
                type-segment-bases
                target
                convention
                types
                (+ type-index 1)
                int-idx
                float-idx
                (+ position 2)
                (+ stack-count 2)
                program-index)
              (compiler-backend-type-list-stack-arg-count-at
                type-segment-bases
                target
                convention
                types
                (+ type-index 1)
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
                program-index)))
          (compiler-backend-type-list-stack-arg-count-at
            type-segment-bases
            target
            convention
            types
            (+ type-index 1)
            next-int
            next-float
            (+ position 1)
            (if (be_scalar.compiler-backend-stack-call-arg-for-banks?
              target
              convention
              is-float
              int-idx
              float-idx
              position)
              (+ stack-count 1)
              stack-count)
            program-index))))))

(define (compiler-backend-incoming-stack-arg-count
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [source-function : i64]
  [program-index : be_state.CompilerBackendProgramIndex]) : i64
  (compiler-backend-type-list-stack-arg-count
    type-segment-bases
    target
    (Internal)
    (compiler-backend-call-param-types-index source-function program-index)
    0
    0
    0
    0
    program-index))

;; True when any arg type is a 2-word register group.
(define (compiler-backend-type-list-has-group?
  [type-segment-bases : i64]
  [types : (& types compiler_ast_types.AstTypeList)]
  [program-index : be_state.CompilerBackendProgramIndex]) : bool
  (compiler-backend-type-list-has-group-at?
    type-segment-bases
    (& types)
    program-index))

(define (compiler-backend-type-list-has-group-at?
  [type-segment-bases : i64]
  [types : (& types compiler_ast_types.AstTypeList)]
  [program-index : be_state.CompilerBackendProgramIndex]) : bool
  (for [index (iterator.range 0 (compiler_ast_types.ast-type-list-len types))]
    (when
      (let
        [ty
          (compiler_ast_types.ast-type-segment-bases-get
            type-segment-bases
            (compiler_ast_types.ast-type-list-get
              types
              index
              (compiler_ast_types.ast-type-id-fallback)))]
        (be_facts.compiler-backend-group-type?
          type-segment-bases
          program-index
          ty))
      (return true)))
  false)

;; Build the synthetic var-id set used by closure-entry adapters. Unlike an
;; ordinary IR function, an adapter is emitted directly from its signature, so
;; it never passes through regalloc's function-group scan. Its parameter homes
;; still need the group classification: otherwise word 1 of parameter N falls
;; back to scalar slot N+1 and aliases word 0 of the following parameter.
(define (compiler-backend-type-list-group-vars-at
  [type-segment-bases : i64]
  [types : (& types compiler_ast_types.AstTypeList)]
  [program-index : be_state.CompilerBackendProgramIndex]
  [index : i64]
  [out : compiler_liveness.CompilerLiveI64Set]) : compiler_liveness.CompilerLiveI64Set
  (if (>= index (compiler_ast_types.ast-type-list-len types))
    out
    (compiler-backend-type-list-group-vars-at
      type-segment-bases
      types
      program-index
      (+ index 1)
      (if (let
        [ty
          (compiler_ast_types.ast-type-segment-bases-get
            type-segment-bases
            (compiler_ast_types.ast-type-list-get
              types
              index
              (compiler_ast_types.ast-type-id-fallback)))]
        (be_facts.compiler-backend-group-type?
          type-segment-bases
          program-index
          ty))
        (compiler_liveness.compiler-live-set-insert out index)
        out))))

(define (compiler-backend-type-list-group-vars
  [type-segment-bases : i64]
  [types : (& types compiler_ast_types.AstTypeList)]
  [program-index : be_state.CompilerBackendProgramIndex]) : compiler_liveness.CompilerLiveI64Set
  (compiler-backend-type-list-group-vars-at
    type-segment-bases
    (& types)
    program-index
    0
    (compiler_liveness.compiler-live-set-empty)))

(define (compiler-backend-direct-tail-call?
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [source-function : i64]
  [name : i64]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [types : (& types compiler_ast_types.AstTypeList)]
  [program-index : be_state.CompilerBackendProgramIndex]) : bool
  (let
    [convention : compiler_abi.CompilerCallConvention
      (compiler_regalloc.compiler-reg-direct-call-convention name)]
    [tail-stack : i64
      (compiler-backend-call-stack-arg-count
        type-segment-bases
        target
        convention
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
      (be_operand.compiler-backend-index-function-defines? program-index name)
      (<=
        tail-stack
        (compiler-backend-incoming-stack-arg-count
          type-segment-bases
          target
          source-function
          program-index))
      ;; The staged tail-call path stages each arg scalar-wise (one
      ;; 8-byte slot, word0 only), so a register-group arg that needs stack
      ;; staging would lose word1 and shift every later arg. Decline the
      ;; direct tail call and fall back to a plain call instead.
      (or
        (= tail-stack 0)
        (not
          (compiler-backend-type-list-has-group?
            type-segment-bases
            types
            program-index))))))

(define (compiler-backend-identity-tail-forwarder-type-ok?
  [type-segment-bases : i64]
  [program-index : be_state.CompilerBackendProgramIndex]
  [ty : compiler_ast_types.AstType]) : bool
  (and
    (= (be_operand.compiler-backend-type-size type-segment-bases ty) 8)
    (not (be_operand.compiler-backend-float-type? ty))
    (not
      (be_facts.compiler-backend-group-type?
        type-segment-bases
        program-index
        ty))))

;; Snapshot moves in a forwarder may be omitted together with parameter spills
;; only when each destination is fresh and each source is an unchanged incoming
;; word parameter. The final call must still preserve the incoming ABI order.
(define (compiler-backend-identity-tail-param?
  [type-segment-bases : i64]
  [program-index : be_state.CompilerBackendProgramIndex]
  [params : compiler_ir_types.CompilerIrParamSeq]
  [var-id : i64]
  [require-word? : bool]) : bool
  (let
    [index : i64 0]
    (while (< index params.len)
      (begin
        (match (compiler_ir_types.compiler-ir-param-seq-ref params index)
          [(compiler_ir_types.CompilerIrParam.Param _ ty param-id)
            (when
              (= var-id param-id)
              (return
                (or
                  (not require-word?)
                  (compiler-backend-identity-tail-forwarder-type-ok?
                    type-segment-bases
                    program-index
                    ty))))])
        (set! index (+ index 1))))
    false))

(define (compiler-backend-identity-tail-snapshot-source
  [instrs : compiler_ir_types.CompilerIrInstrSeq]
  [end : i64]
  [var-id : i64]) : i64
  (let
    [index : i64 0]
    (while (< index end)
      (begin
        (match (compiler_ir_types.compiler-ir-instr-seq-ref instrs index)
          [(compiler_ir_types.CompilerIrInstr.Mov
              dst
              (compiler_ir_types.CompilerIrValue.Var src)
              _)
            (when (= dst var-id) (return src))]
          [_ unit])
        (set! index (+ index 1))))
    var-id))

(define (compiler-backend-identity-tail-snapshots?
  [type-segment-bases : i64]
  [program-index : be_state.CompilerBackendProgramIndex]
  [params : compiler_ir_types.CompilerIrParamSeq]
  [instrs : compiler_ir_types.CompilerIrInstrSeq]
  [end : i64]) : bool
  (let
    [index : i64 0]
    (while (< index end)
      (begin
        (match (compiler_ir_types.compiler-ir-instr-seq-ref instrs index)
          [(compiler_ir_types.CompilerIrInstr.Mov
              dst
              (compiler_ir_types.CompilerIrValue.Var src)
              ty)
            (unless
              (and
                (>= dst 0)
                (compiler-backend-identity-tail-forwarder-type-ok?
                  type-segment-bases
                  program-index
                  ty)
                (compiler-backend-identity-tail-param?
                  type-segment-bases
                  program-index
                  (be_state.compiler-backend-global-shared-view params)
                  src
                  true)
                (not
                  (compiler-backend-identity-tail-param?
                    type-segment-bases
                    program-index
                    (be_state.compiler-backend-global-shared-view params)
                    dst
                    false))
                (=
                  dst
                  (compiler-backend-identity-tail-snapshot-source
                    (be_state.compiler-backend-global-shared-view instrs)
                    index
                    dst)))
              (return false))]
          [_ (return false)])
        (set! index (+ index 1))))
    true))

(define (compiler-backend-identity-tail-forwarder-args?
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [params : compiler_ir_types.CompilerIrParamSeq]
  [snapshots : compiler_ir_types.CompilerIrInstrSeq]
  [snapshot-count : i64]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [target-types : compiler_ast_types.AstTypeList]
  [arg-index : i64]
  [int-idx : i64]
  [float-idx : i64]
  [position : i64]
  [program-index : be_state.CompilerBackendProgramIndex]) : bool
  (if (>=
    arg-index
    (be_facts.compiler-backend-call-args-count
      (be_state.compiler-backend-global-shared-view args)))
    (and
      (>= arg-index params.len)
      (>= arg-index (compiler_ast_types.ast-type-list-len (& target-types))))
    (if (>= arg-index params.len)
      false
      (match (compiler_ir_types.compiler-ir-param-seq-ref params arg-index)
        [(Param _ source-ty var-id)
          (if (>=
            arg-index
            (compiler_ast_types.ast-type-list-len (& target-types)))
            false
            (let
              [callee-ty : compiler_ast_types.AstType
                (compiler_ast_types.ast-type-segment-bases-get
                  type-segment-bases
                  (compiler_ast_types.ast-type-list-get
                    (& target-types)
                    arg-index
                    (compiler_ast_types.ast-type-id-fallback)))]
              (match (be_facts.compiler-backend-call-arg-at args arg-index)
                [(Var arg-var)
                  (and
                    (=
                      (compiler-backend-identity-tail-snapshot-source
                        (be_state.compiler-backend-global-shared-view snapshots)
                        snapshot-count
                        arg-var)
                      var-id)
                    (compiler-backend-identity-tail-forwarder-type-ok?
                      type-segment-bases
                      program-index
                      source-ty)
                    (compiler-backend-identity-tail-forwarder-type-ok?
                      type-segment-bases
                      program-index
                      callee-ty)
                    (not
                      (be_scalar.compiler-backend-stack-call-arg-for-banks?
                        target
                        (Internal)
                        false
                        int-idx
                        float-idx
                        position))
                    (compiler-backend-identity-tail-forwarder-args?
                      type-segment-bases
                      target
                      params
                      snapshots
                      snapshot-count
                      args
                      target-types
                      (+ arg-index 1)
                      (+ int-idx 1)
                      float-idx
                      (+ position 1)
                      program-index))]
                [_ false])))]))))

(define (compiler-backend-identity-tail-forwarder-call?
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [_source-function : i64]
  [params : compiler_ir_types.CompilerIrParamSeq]
  [snapshots : compiler_ir_types.CompilerIrInstrSeq]
  [snapshot-count : i64]
  [name : i64]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [program-index : be_state.CompilerBackendProgramIndex]) : bool
  (if (be_operand.compiler-backend-index-function-defines? program-index name)
    (let
      [target-types : compiler_ast_types.AstTypeList
        (compiler-backend-call-param-types-index name program-index)]
      (compiler-backend-identity-tail-forwarder-args?
        type-segment-bases
        target
        params
        snapshots
        snapshot-count
        args
        target-types
        0
        0
        0
        0
        program-index))
    false))

(define (compiler-backend-identity-tail-forwarder-block?
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [source-function : i64]
  [params : compiler_ir_types.CompilerIrParamSeq]
  [block : (& compiler_ir_types.CompilerIrBlock)]
  [program-index : be_state.CompilerBackendProgramIndex]) : bool
  (match block
    [(Block _ instrs)
      (let
        [last : i64
          (- (compiler_ir_types.compiler-ir-instr-seq-count instrs) 1)]
        (if (and
          (>= last 0)
          (compiler-backend-identity-tail-snapshots?
            type-segment-bases
            program-index
            (be_state.compiler-backend-global-shared-view params)
            (owned_view.compiler-owned-reference-shared-view instrs)
            last))
          (match (compiler_ir_types.compiler-ir-instr-seq-ref instrs last)
            [(TailCall name args _)
              (compiler-backend-identity-tail-forwarder-call?
                type-segment-bases
                target
                source-function
                params
                (owned_view.compiler-owned-reference-shared-view instrs)
                last
                name
                args
                program-index)]
            [_ false])
          false))]))

(define (compiler-backend-identity-tail-forwarder?
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [source-function : i64]
  [params : compiler_ir_types.CompilerIrParamSeq]
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [program-index : be_state.CompilerBackendProgramIndex]) : bool
  (match blocks
    [(Array seq)
      (if (= (compiler_ir_types.compiler-ir-block-seq-count seq) 1)
        (compiler-backend-identity-tail-forwarder-block?
          type-segment-bases
          target
          source-function
          params
          (compiler_ir_types.compiler-ir-block-seq-borrow seq 0)
          program-index)
        false)]))

;; Stack-passed outgoing argument bytes for one call. This is the layout size,
;; not necessarily a per-call %rsp adjustment: Linux/Win64 reserve the maximum
;; needed outgoing area in the prologue frame.
(define (compiler-backend-call-stack-arg-space
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [types : compiler_ast_types.AstTypeList]
  [c-abi? : bool]
  [program-index : be_state.CompilerBackendProgramIndex]) : i64
  (let
    [stack-count : i64
      (compiler-backend-call-stack-arg-count
        type-segment-bases
        target
        convention
        args
        types
        c-abi?
        0
        0
        0
        0
        0
        program-index)]
    (if (= stack-count 0)
      0
      (be_operand.compiler-backend-round-up-16 (* stack-count 8)))))

;; Offset where a C-ABI sret base can be saved without clobbering outgoing args.
;; Windows must skip the callee shadow space as well as stack args because the
;; callee owns the shadow area during the call.
(define (compiler-backend-call-stack-arg-layout-space
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [types : compiler_ast_types.AstTypeList]
  [c-abi? : bool]
  [program-index : be_state.CompilerBackendProgramIndex]) : i64
  (+
    (be_facts.compiler-backend-outgoing-shadow-space target convention)
    (compiler-backend-call-stack-arg-space
      type-segment-bases
      target
      convention
      args
      types
      c-abi?
      program-index)))

(define (compiler-backend-windows-words-stack-space [stack-words : i64]) : i64
  (if (> stack-words 0)
    (be_operand.compiler-backend-round-up-16 (* stack-words 8))
    0))

;; The actual System V outgoing stack-arg space for a named non-C-ABI call.
;; Used to size the prologue frame's reserved outgoing region so calls need no
;; per-call %rsp dip. The closure (indirect) cases reuse
;; windows-closure-stack-arg-space, whose `1 + 2*args` word bound is an
;; ABI-generic upper bound.
(define (compiler-backend-linux-stack-arg-space
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [types : compiler_ast_types.AstTypeList]
  [program-index : be_state.CompilerBackendProgramIndex]) : i64
  (compiler-backend-call-stack-arg-space
    type-segment-bases
    target
    convention
    args
    types
    false
    program-index))

;; Private scalar SPMD calls carry the active mask before the source helper
;; parameters, and their hidden callee signature already records that complete
;; internal ABI. Size its stack-passed tail from the signature so the ordinary
;; per-function outgoing area covers these calls too. SIMD private calls make
;; their own aligned per-call adjustment for uniform stack args and private
;; vector/mask storage.
(define (compiler-backend-spmd-scalar-stack-arg-space
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [callee : i64]
  [program-index : be_state.CompilerBackendProgramIndex]) : i64
  (let
    [stack-count : i64
      (compiler-backend-type-list-stack-arg-count
        type-segment-bases
        target
        (Internal)
        (compiler-backend-call-param-types-index callee program-index)
        0
        0
        0
        0
        program-index)]
    (if (= stack-count 0)
      0
      (be_operand.compiler-backend-round-up-16 (* stack-count 8)))))

(define (compiler-backend-spmd-outgoing-stack-space
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [payload : compiler_ir_types.CompilerIrInstrSpmdCallPayload]
  [program-index : be_state.CompilerBackendProgramIndex]) : i64
  (match payload.backend
    [(Scalar)
      (compiler-backend-spmd-scalar-stack-arg-space
        type-segment-bases
        target
        payload.callee
        program-index)]
    [_ 0]))

;; Indirect (closure) calls carry no callee signature here, so size conservatively:
;; the leading environment pointer plus two stack words per argument is always an
;; upper bound on the real footprint.
(define (compiler-backend-windows-closure-stack-arg-space
  [args : compiler_ir_types.CompilerIrCallArgs]) : i64
  (compiler-backend-windows-words-stack-space
    (+ 1 (* 2 (be_facts.compiler-backend-call-args-count args)))))

(define (compiler-backend-linux-closure-stack-arg-space-actual-from
  [type-segment-bases : i64]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [types : compiler_regalloc.CompilerRegVarTypes]
  [program-index : be_state.CompilerBackendProgramIndex]
  [words : i64]) : i64
  (for [index
    (iterator.range
      0
      (be_facts.compiler-backend-call-args-count
        (be_state.compiler-backend-global-shared-view args)))]
    (let
      [arg-ty : compiler_ast_types.AstType
        (compiler-backend-call-actual-type
          types
          (Empty)
          (be_facts.compiler-backend-call-arg-at args index))]
      [memory-size : i64
        (be_facts.compiler-backend-abi-memory-size
          type-segment-bases
          (be_state.compiler-backend-global-shared-view arg-ty))]
      [arg-words : i64
        (if (> memory-size 0)
          (compiler-backend-stack-slots-for-size memory-size)
          (if (be_facts.compiler-backend-group-type?
            type-segment-bases
            program-index
            arg-ty)
            2
            1))]
      (set! words (+ words arg-words))))
  (compiler-backend-windows-words-stack-space words))

(define (compiler-backend-linux-closure-stack-arg-space-actual
  [type-segment-bases : i64]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [types : compiler_regalloc.CompilerRegVarTypes]
  [program-index : be_state.CompilerBackendProgramIndex]) : i64
  ;; Include the hidden closure environment pointer (one GP word) and then
  ;; every actual argument.  This is intentionally a rounded upper bound for
  ;; indirect calls: register placement is dynamic, while an encoded MEMORY
  ;; value may occupy any number of outgoing stack slots.
  (compiler-backend-linux-closure-stack-arg-space-actual-from
    type-segment-bases
    args
    types
    program-index
    1))

(define (compiler-backend-instr-needs-outgoing-space?
  [instr : (& instr compiler_ir_types.CompilerIrInstr)]) : bool
  (match instr
    [(or (Call _ _ _ _) (CallIndirect _ _ _ _) (CallIndirectC _ _ _ _)
         (CallCAbiStoreResult _) (CallIndirectCAbiStoreResult _) (SpmdCall _)
         (TailCall _ _ _) (TailCallIndirect _ _ _) (BoundsCheck _ _ _))
      true]
    [_ false]))

(define (compiler-backend-named-call-stack-arg-space
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [name : i64]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [types : compiler_regalloc.CompilerRegVarTypes]
  [global-types : be_state.CompilerBackendGlobalTypeTable]
  [program-index : be_state.CompilerBackendProgramIndex]) : i64
  (let
    [extern-call-info : i64
      (be_operand.compiler-backend-index-extern-call-info program-index name)]
    [param-types : compiler_ast_types.AstTypeList
      (compiler-backend-call-param-types-for-call
        type-segment-bases
        name
        (be_state.compiler-backend-global-shared-view args)
        types
        global-types
        extern-call-info
        program-index)]
    ;; Use the same expanded argument types and ABI classification as emission.
    ;; In particular, a C MEMORY aggregate contributes its complete byte extent,
    ;; not the three IR values carrying its address/size/marker transport.
    (compiler-backend-call-stack-arg-space
      type-segment-bases
      target
      convention
      args
      param-types
      (be_facts.compiler-backend-extern-call-info-aggregate-params?
        extern-call-info)
      program-index)))

(define (compiler-backend-c-abi-indirect-stack-arg-space
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [func : compiler_ir_types.CompilerIrValue]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [types : compiler_regalloc.CompilerRegVarTypes]
  [program-index : be_state.CompilerBackendProgramIndex]) : i64
  (compiler-backend-call-stack-arg-space
    type-segment-bases
    target
    (Platform)
    (be_state.compiler-backend-global-shared-view args)
    (compiler-backend-effective-c-abi-indirect-param-types
      type-segment-bases
      types
      func
      args
      program-index)
    true
    program-index))

(define (compiler-backend-instr-outgoing-stack-space
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [instr : compiler_ir_types.CompilerIrInstr]
  [types : compiler_regalloc.CompilerRegVarTypes]
  [global-types : be_state.CompilerBackendGlobalTypeTable]
  [program-index : be_state.CompilerBackendProgramIndex]) : i64
  (match instr
    [(compiler_ir_types.CompilerIrInstr.Call _ name args _)
      (compiler-backend-named-call-stack-arg-space
        type-segment-bases
        target
        (compiler_regalloc.compiler-reg-direct-call-convention name)
        name
        args
        types
        global-types
        program-index)]
    [(compiler_ir_types.CompilerIrInstr.TailCall name args _)
      (compiler-backend-named-call-stack-arg-space
        type-segment-bases
        target
        (compiler_regalloc.compiler-reg-direct-call-convention name)
        name
        args
        types
        global-types
        program-index)]
    [(compiler_ir_types.CompilerIrInstr.CallIndirect _ _ args _)
      (match target
        [(be_state.CompilerBackendTarget.Windows)
          (compiler-backend-windows-closure-stack-arg-space args)]
        [(be_state.CompilerBackendTarget.Linux)
          (compiler-backend-linux-closure-stack-arg-space-actual
            type-segment-bases
            args
            types
            program-index)])]
    [(compiler_ir_types.CompilerIrInstr.TailCallIndirect _ args _)
      (match target
        [(be_state.CompilerBackendTarget.Windows)
          (compiler-backend-windows-closure-stack-arg-space args)]
        [(be_state.CompilerBackendTarget.Linux)
          (compiler-backend-linux-closure-stack-arg-space-actual
            type-segment-bases
            args
            types
            program-index)])]
    [(compiler_ir_types.CompilerIrInstr.CallIndirectC _ func args _)
      (compiler-backend-c-abi-indirect-stack-arg-space
        type-segment-bases
        target
        func
        args
        types
        program-index)]
    ;; Emission saves the result base in another 16 bytes after these arguments.
    [(compiler_ir_types.CompilerIrInstr.CallCAbiStoreResult payload-box)
      (let
        [name
          (be_state.compiler-backend-box-field-shared-view payload-box name)]
        [args
          (be_state.compiler-backend-box-field-shared-view payload-box args)]
        (+
          (compiler-backend-named-call-stack-arg-space
            type-segment-bases
            target
            (Platform)
            name
            args
            types
            global-types
            program-index)
          16))]
    [(compiler_ir_types.CompilerIrInstr.CallIndirectCAbiStoreResult payload-box)
      (let
        [func
          (be_state.compiler-backend-box-field-shared-view payload-box callee)]
        [args
          (be_state.compiler-backend-box-field-shared-view payload-box args)]
        (+
          (compiler-backend-c-abi-indirect-stack-arg-space
            type-segment-bases
            target
            func
            args
            types
            program-index)
          16))]
    [(compiler_ir_types.CompilerIrInstr.SpmdCall payload-box)
      (compiler-backend-spmd-outgoing-stack-space
        type-segment-bases
        target
        (deref payload-box)
        program-index)]
    [_ 0]))

(defstruct CompilerBackendOutgoingFrameScan
  (needed bool)
  (max-space i64))

(define (compiler-backend-outgoing-frame-scan-instrs
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [instrs : compiler_ir_types.CompilerIrInstrSeq]
  [scan : CompilerBackendOutgoingFrameScan]
  [types : compiler_regalloc.CompilerRegVarTypes]
  [global-types : be_state.CompilerBackendGlobalTypeTable]
  [program-index : be_state.CompilerBackendProgramIndex]) : CompilerBackendOutgoingFrameScan
  (let
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [count : i64 instrs.len]
    [needed : bool scan.needed]
    [max-space : i64 scan.max-space]
    (for [index (iterator.range 0 count)]
      (let
        [instr : compiler_ir_types.CompilerIrInstr
          (be_state.compiler-backend-global-array-element-shared-view
            slots
            index)]
        (when
          (compiler-backend-instr-needs-outgoing-space? instr)
          (set! needed true)
          (set!
            max-space
            (compiler_regalloc.compiler-reg-max
              max-space
              (+
                (be_facts.compiler-backend-outgoing-shadow-space
                  target
                  (compiler_regalloc.compiler-reg-call-instr-convention
                    (& instr)))
                (compiler-backend-instr-outgoing-stack-space
                  type-segment-bases
                  target
                  instr
                  types
                  (be_state.compiler-backend-global-shared-view global-types)
                  program-index)))))))
    (CompilerBackendOutgoingFrameScan needed max-space)))

(define (compiler-backend-outgoing-frame-scan-blocks
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [scan : CompilerBackendOutgoingFrameScan]
  [types : compiler_regalloc.CompilerRegVarTypes]
  [global-types : be_state.CompilerBackendGlobalTypeTable]
  [program-index : be_state.CompilerBackendProgramIndex]) : CompilerBackendOutgoingFrameScan
  (match blocks
    [(Array seq)
      (compiler-backend-outgoing-frame-scan-block-seq
        type-segment-bases
        target
        seq
        0
        scan
        types
        global-types
        program-index)]))

(define (compiler-backend-outgoing-frame-scan-block-seq
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [blocks : compiler_ir_types.CompilerIrBlockSeq]
  [index : i64]
  [scan : CompilerBackendOutgoingFrameScan]
  [types : compiler_regalloc.CompilerRegVarTypes]
  [global-types : be_state.CompilerBackendGlobalTypeTable]
  [program-index : be_state.CompilerBackendProgramIndex]) : CompilerBackendOutgoingFrameScan
  (if (>= index (compiler_ir_types.compiler-ir-block-seq-count blocks))
    scan
    (match (compiler_ir_types.compiler-ir-block-seq-ref blocks index)
      [(Block _ instrs)
        (compiler-backend-outgoing-frame-scan-block-seq
          type-segment-bases
          target
          blocks
          (+ index 1)
          (compiler-backend-outgoing-frame-scan-instrs
            type-segment-bases
            target
            instrs
            scan
            types
            (be_state.compiler-backend-global-shared-view global-types)
            program-index)
          types
          global-types
          program-index)])))

(define (compiler-backend-outgoing-frame-space
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [types : compiler_regalloc.CompilerRegVarTypes]
  [global-types : be_state.CompilerBackendGlobalTypeTable]
  [program-index : be_state.CompilerBackendProgramIndex]) : i64
  (let
    [scan : CompilerBackendOutgoingFrameScan
      (compiler-backend-outgoing-frame-scan-blocks
        type-segment-bases
        target
        blocks
        (CompilerBackendOutgoingFrameScan false 0)
        types
        global-types
        program-index)]
    (if scan.needed
      ;; The scan includes each callee's shadow space with its stack arguments.
      (be_operand.compiler-backend-round-up-16 scan.max-space)
      0)))

(define (compiler-backend-emit-scalar-stack-call-arg-into
  [out : (&mut out be_state.CompilerBackendAsmBuf)]
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]
  [arg-ty : compiler_ast_types.AstType]
  [is-float : bool]
  [stack-idx : i64]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [slot : String
      (str_cat.str-cat
        (string.int->string
          (be_facts.compiler-backend-outgoing-stack-arg-offset
            target
            convention
            stack-idx))
        "(%rsp)\n"
        "")]
    (if is-float
      (let
        [scav : String
          (be_scalar.compiler-backend-stack-call-arg-stage backend-state)]
        [gp-part : String
          (be_scalar.compiler-backend-float-bits-gp-reg
            type-segment-bases
            (be_state.compiler-backend-global-shared-view scav)
            (be_state.compiler-backend-global-shared-view arg-ty))]
        [head
          (try
            (be_scalar.compiler-backend-emit-load-float-bits-to-gp
              type-segment-bases
              assignments
              value
              (be_state.compiler-backend-global-shared-view arg-ty)
              scav
              backend-state))]
        (be_state.compiler-backend-asm-append out head)
        (be_state.compiler-backend-asm-append5
          out
          "    "
          (be_scalar.compiler-backend-float-bits-load-mnemonic
            type-segment-bases
            arg-ty)
          " "
          gp-part
          ", ")
        (be_state.compiler-backend-asm-append out slot)
        (Ok ""))
      (match (be_operand.compiler-backend-immediate-operand backend-state value)
        [(Some imm)
          (be_state.compiler-backend-asm-append4 out "    movq " imm ", " slot)
          (Ok "")]
        [(No)
          (let
            [scav : String
              (be_scalar.compiler-backend-stack-call-arg-stage backend-state)]
            [_
              (try
                (be_operand.compiler-backend-emit-load-value-into
                  out
                  assignments
                  value
                  (be_state.compiler-backend-global-shared-view scav)
                  backend-state))]
            (be_state.compiler-backend-asm-append4
              out
              "    movq "
              scav
              ", "
              slot)
            (Ok ""))]))))

;; --- Sound register-arg parallel move (option b) ---------------------------
;; Direct/indirect call args can be register-eligible (regalloc only leaves them
;; eligible when every user arg is GP-register passed within that call shape's
;; target ABI arg-register window). Then one arg's source register can be another
;; arg's destination arg
;; register, so the naive ascending marshalling could clobber a source before it
;; is read. This emits the GP-register arg loads in a safe order, breaking cycles
;; through %r11 (the marshalling scratch, never an arg register). It runs ONLY
;; when a real source/dest conflict exists; the overwhelming common case
;; (self-moves / memory sources) falls through to the byte-identical naive path.
(defenum CompilerBackendArgMoveSource
  (BackendArgMoveValue compiler_ir_types.CompilerIrValue)
  ;; A float argument's value, bound for an XMM argument register; the flag
  ;; marks an f32. GP and XMM moves never share a register, so one move list
  ;; carries both classes and their moves stay independent.
  (BackendArgMoveFloatValue compiler_ir_types.CompilerIrValue bool)
  (BackendArgMoveReg i64)
  ;; The register-free cycle break: the move's source value was saved in the
  ;; reserved cycle-temp frame slot and is loaded into `dest` here. Behaves like
  ;; a memory source (source-reg invalid -- never blocks another move).
  (BackendArgMoveStackPop))

(defenum CompilerBackendArgMove
  (BackendArgMove i64 CompilerBackendArgMoveSource))

(defstruct CompilerBackendArgMoveSeq
  (slots (__tl_dyn-array CompilerBackendArgMove))
  (len i64))

(define (compiler-backend-arg-move-seq-with-capacity [capacity : i64]) : CompilerBackendArgMoveSeq
  (CompilerBackendArgMoveSeq
    (__tl_make-array CompilerBackendArgMove capacity)
    0))

(define (compiler-backend-arg-move-copy-range!
  [dst : (&mut dst (__tl_dyn-array CompilerBackendArgMove))]
  [src : (& src (__tl_dyn-array CompilerBackendArgMove))]
  [count : i64]) : unit
  (for [index (iterator.range 0 count)]
    (set!
      (array-ref dst index)
      (owned_view.compiler-owned-element-view src index))))

(define (compiler-backend-arg-move-push!
  [seq : (&mut seq CompilerBackendArgMoveSeq)]
  [move : CompilerBackendArgMove]) : unit
  (if (< seq.len (array-length seq.slots))
    unit
    (let
      [bigger : (__tl_dyn-array CompilerBackendArgMove)
        (__tl_make-array
          CompilerBackendArgMove
          (be_state.compiler-backend-seq-capacity (array-length seq.slots)))]
      (compiler-backend-arg-move-copy-range!
        (&mut bigger)
        (& seq.slots)
        seq.len)
      (set! seq.slots bigger)))
  (let
    [index : i64 seq.len]
    (set! (array-ref seq.slots index) move)
    (set! seq.len (+ index 1))))

(defenum CompilerBackendMaybeArgMove
  (BackendNoArgMove)
  (BackendSomeArgMove CompilerBackendArgMove))

(define (compiler-backend-arg-move-source-reg
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [source : CompilerBackendArgMoveSource]) : i64
  (match source
    [(BackendArgMoveReg r) r]
    [(BackendArgMoveStackPop) compiler_abi.compiler-reg-id-invalid]
    [(BackendArgMoveValue value)
      (compiler-backend-arg-value-source-reg backend-state assignments value)]
    [(BackendArgMoveFloatValue value _)
      (compiler-backend-arg-value-source-reg backend-state assignments value)]))

;; The register an argument value is read from (GP or XMM), or invalid for an
;; immediate, a memory home or a forwarded address.
(define (compiler-backend-arg-value-source-reg
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]) : i64
  (match value
    [(Var id)
      (if (>=
        (be_operand.compiler-backend-forwarded-addr-of-src backend-state id)
        0)
        compiler_abi.compiler-reg-id-invalid
        (match (be_operand.compiler-backend-emit-assignment-lookup
          backend-state
          assignments
          id)
          [(Some loc)
            (match loc
              [(Register home) home]
              [_ compiler_abi.compiler-reg-id-invalid])]
          [(No) compiler_abi.compiler-reg-id-invalid]))]
    [_ compiler_abi.compiler-reg-id-invalid]))

(define (compiler-backend-parallel-reg-id-resource [reg : i64]) : i64
  (if (= reg compiler_abi.compiler-reg-id-invalid)
    0
    (+ reg 1)))

(define (compiler-backend-parallel-spill-resource [offset : i64]) : i64
  (if (< offset 0)
    (+ 2000000 (- 0 offset))
    (+ 3000000 offset)))

(define (compiler-backend-parallel-move-missing [kind : String] [id : i64]) : be_state.ResultCompilerBackend
  (Err
    (box
      (compiler_diagnostic.compiler-diagnostic-at-start
        ""
        (str_cat.str-cat
          "backend: "
          kind
          " parallel-move decision id missing: "
          (string.int->string id))))))

(define (compiler-backend-arg-move-parallel-edge
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [move : CompilerBackendArgMove]) : pmove.CompilerParallelMoveEdge
  (match move
    [(BackendArgMove dest source)
      (ParallelMoveEdge
        (compiler-backend-parallel-reg-id-resource dest)
        (compiler-backend-parallel-reg-id-resource dest)
        0
        (compiler-backend-parallel-reg-id-resource
          (compiler-backend-arg-move-source-reg
            backend-state
            assignments
            source))
        0)]))

(define (compiler-backend-arg-move-parallel-edges
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [moves : CompilerBackendArgMoveSeq]
  [index : i64]) : pmove.CompilerParallelMoveEdgeSeq
  (let
    [count : i64 moves.len]
    [edges : pmove.CompilerParallelMoveEdgeSeq
      (pmove.compiler-parallel-move-edge-seq-with-capacity (- count index))]
    (for [cursor (iterator.range index count)]
      (pmove.compiler-parallel-move-edge-push!
        (&mut edges)
        (compiler-backend-arg-move-parallel-edge
          backend-state
          assignments
          (be_state.compiler-backend-global-array-element-shared-view
            moves.slots
            cursor))))
    edges))

(define (compiler-backend-arg-move-decision
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [moves : CompilerBackendArgMoveSeq]) : pmove.CompilerParallelMoveDecision
  (let
    [edges : pmove.CompilerParallelMoveEdgeSeq
      (compiler-backend-arg-move-parallel-edges
        backend-state
        assignments
        moves
        0)]
    (pmove.compiler-parallel-move-decision edges edges)))

;; Does some move of `moves` read a register another move of `moves` writes?
(define (compiler-backend-arg-moves-conflict?
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [moves : CompilerBackendArgMoveSeq]) : bool
  (let
    [edges : pmove.CompilerParallelMoveEdgeSeq
      (compiler-backend-arg-move-parallel-edges
        backend-state
        assignments
        moves
        0)]
    (pmove.compiler-parallel-move-seq-has-blocked?
      (be_state.compiler-backend-global-shared-view edges)
      edges)))

(define (compiler-backend-arg-move-list-find
  [moves : CompilerBackendArgMoveSeq]
  [want : i64]) : CompilerBackendMaybeArgMove
  (for [i (iterator.range 0 moves.len)]
    (match (be_state.compiler-backend-global-array-element-shared-view
      moves.slots
      i)
      [(BackendArgMove dest _)
        (when
          (= (compiler-backend-parallel-reg-id-resource dest) want)
          (return
            (BackendSomeArgMove
              (be_state.compiler-backend-global-array-element-shared-view
                moves.slots
                i))))]))
  BackendNoArgMove)

;; Drops the FIRST move with this dest (the cons form returned the untouched
;; tail on a match); any later same-dest move stays.
(define (compiler-backend-arg-move-list-remove
  [moves : CompilerBackendArgMoveSeq]
  [dest : i64]) : CompilerBackendArgMoveSeq
  (let
    [out : CompilerBackendArgMoveSeq
      (compiler-backend-arg-move-seq-with-capacity moves.len)]
    [removed : bool false]
    (for [i (iterator.range 0 moves.len)]
      (match (be_state.compiler-backend-global-array-element-shared-view
        moves.slots
        i)
        [(BackendArgMove d _)
          (if (and (not removed) (= d dest))
            (set! removed true)
            (compiler-backend-arg-move-push!
              (&mut out)
              (be_state.compiler-backend-global-array-element-shared-view
                moves.slots
                i)))]))
    out))

(define (compiler-backend-arg-move-list-redirect
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [moves : CompilerBackendArgMoveSeq]
  [oldreg : i64]
  [newreg : i64]) : CompilerBackendArgMoveSeq
  (let
    [out : CompilerBackendArgMoveSeq
      (compiler-backend-arg-move-seq-with-capacity moves.len)]
    (for [i (iterator.range 0 moves.len)]
      (let
        [move : CompilerBackendArgMove
          (be_state.compiler-backend-global-array-element-shared-view
            moves.slots
            i)]
        (match (be_state.compiler-backend-global-shared-view move)
          [(BackendArgMove dest source)
            (compiler-backend-arg-move-push!
              (&mut out)
              (if (=
                (compiler-backend-arg-move-source-reg
                  backend-state
                  assignments
                  source)
                oldreg)
                (BackendArgMove dest (BackendArgMoveReg newreg))
                move))])))
    out))

;; Redirect variant for the register-free (stack) cycle break: every move whose
;; source register is `oldreg` (exactly one in a permutation cycle) reads the
;; reserved frame temp instead. Mirrors arg-move-list-redirect but targets the
;; stack slot rather than a scavenged register.
(define (compiler-backend-arg-move-list-redirect-to-stack
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [moves : CompilerBackendArgMoveSeq]
  [oldreg : i64]) : CompilerBackendArgMoveSeq
  (let
    [out : CompilerBackendArgMoveSeq
      (compiler-backend-arg-move-seq-with-capacity moves.len)]
    (for [i (iterator.range 0 moves.len)]
      (let
        [move : CompilerBackendArgMove
          (be_state.compiler-backend-global-array-element-shared-view
            moves.slots
            i)]
        (match (be_state.compiler-backend-global-shared-view move)
          [(BackendArgMove dest source)
            (compiler-backend-arg-move-push!
              (&mut out)
              (if (=
                (compiler-backend-arg-move-source-reg
                  backend-state
                  assignments
                  source)
                oldreg)
                (BackendArgMove dest (BackendArgMoveStackPop))
                move))])))
    out))

(define (compiler-backend-emit-arg-move
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [move : CompilerBackendArgMove]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (match move
    [(BackendArgMove dest source)
      (match source
        [(BackendArgMoveReg r)
          (if (= r dest)
            (Ok "")
            (Ok
              (str_cat.str-cat
                (compiler-backend-arg-move-mnemonic dest)
                (compiler_abi.compiler-abi-register-spelling r)
                ", "
                (compiler_abi.compiler-abi-register-spelling dest)
                "\n")))]
        [(BackendArgMoveStackPop)
          (Ok
            (str_cat.str-cat
              (compiler-backend-arg-move-mnemonic dest)
              (be_scalar.compiler-backend-cycle-temp-slot-with-backend-state
                backend-state
                0)
              ", "
              (compiler_abi.compiler-abi-register-spelling dest)
              "\n"))]
        [(BackendArgMoveValue value)
          (be_operand.compiler-backend-emit-load-value
            assignments
            value
            (compiler_abi.compiler-abi-register-spelling dest)
            backend-state)]
        [(BackendArgMoveFloatValue value f32?)
          (be_operand.compiler-backend-emit-load-float-value
            assignments
            value
            (&
              (if f32?
                (F32)
                (F64)))
            (compiler_abi.compiler-abi-register-spelling dest)
            backend-state)])]))

;; A whole-register move of an argument register or of the cycle-break value:
;; `movq` for GP, `movsd` (the low 64 bits, which hold any f64 or f32 argument)
;; for XMM.
(define (compiler-backend-arg-move-mnemonic [reg : i64]) : String
  (if (compiler_abi.compiler-abi-xmm-register-id? reg)
    "    movsd "
    "    movq "))

(define (compiler-backend-emit-arg-cycle-temp-save
  [srcreg : i64]
  [backend-state : be_state.CompilerBackendState]) : String
  (str_cat.str-cat
    (compiler-backend-arg-move-mnemonic srcreg)
    (compiler_abi.compiler-abi-register-spelling srcreg)
    ", "
    (be_scalar.compiler-backend-cycle-temp-slot-with-backend-state
      backend-state
      0)
    "\n"))

;; Exclude-mask for the arg parallel-move cycle-break Temp: the pooled-register
;; bit of every pending move's dest arg-register AND source-register. The Temp
;; must be neither -- writing a dest would clobber a pending target, and reusing
;; a source would clobber a value a not-yet-emitted move (including a non-cycle
;; blocked `argreg <- %rN`) still needs to read. ABI-special registers contribute
;; ordinary scavenge bits, so placed/pending %rax/%rsi/%rdi moves are protected by
;; the same mask as the legacy candidate registers.
(define (compiler-backend-arg-move-list-exclude-mask
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [moves : CompilerBackendArgMoveSeq]) : i64
  (let
    [mask : i64 0]
    (for [i (iterator.range 0 moves.len)]
      (match (owned_view.compiler-owned-element-view moves.slots i)
        [(BackendArgMove dest source)
          (set!
            mask
            (bit-or
              mask
              (bit-or
                (be_operand.compiler-backend-scavenge-reg-id-bit dest)
                (be_operand.compiler-backend-scavenge-reg-id-bit
                  (compiler-backend-arg-move-source-reg
                    backend-state
                    assignments
                    source)))))]))
    mask))

;; Scavenge a GP register for the arg parallel-move cycle-break Temp rather than
;; hardcoding one that could hold a live value: free in the occupancy mask at
;; the call-setup point and not a dest/source of any pending arg move (mirrors
;; phi-temp-pick-reg). Invalid if none, in which case the caller breaks the
;; cycle through a reserved frame temp -- a sound register-free swap. In practice
;; the pool always has a free scratch here (%r10/%r11 are caller-saved and never
;; participate in a gp-parallel arg cycle nor hold a call-survivor), so invalid is
;; a saturation guard.
(define (compiler-backend-arg-temp-pick-reg
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [moves : CompilerBackendArgMoveSeq]
  [all : CompilerBackendArgMoveSeq]) : i64
  (let
    [function-state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state backend-state)]
    [point : i64
      (be_state.compiler-backend-function-state-emission-point function-state)]
    [occupied-mask : i64
      (be_operand.compiler-backend-scavenge-occupied-mask-at-point
        function-state
        point)]
    ;; The cycle-break Temp must avoid every register the marshalling still needs:
    ;; the sources/dests of the REMAINING moves (incl. redirect temps), AND every
    ;; destination of the ORIGINAL move list. An already-emitted move has placed a
    ;; final arg value into its dest register (live until the call), but that dest
    ;; is no longer in `moves`, so excluding only `moves` could pick it as the Temp
    ;; and clobber a placed argument. The occupancy mask reflects the
    ;; allocation, not these marshalling transients.
    [exclude-mask : i64
      (bit-or
        (compiler-backend-arg-move-list-exclude-mask
          backend-state
          assignments
          moves)
        (compiler-backend-arg-move-list-exclude-mask
          backend-state
          assignments
          all))]
    [cands : (__tl_dyn-array i64)
      (be_state.compiler-backend-i64-array-shared-view
        (& be_operand.compiler-backend-scavenge-candidate-pool))]
    (compiler-backend-phi-temp-pick-reg-iter
      function-state
      occupied-mask
      exclude-mask
      (be_state.compiler-backend-function-scratch-i64
        function-state
        be_state.compiler-backend-scratch-i64-scavenge-plan-reg-mask)
      cands
      (array-length cands))))

(define (compiler-backend-emit-arg-move-list
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [moves : CompilerBackendArgMoveSeq]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (compiler-backend-emit-arg-move-list-with-all
    assignments
    (be_state.compiler-backend-global-shared-view moves)
    moves
    backend-state))

;; `all` is the ORIGINAL (top-level) move list, carried unchanged through the
;; recursion so the cycle-break Temp pick can exclude every destination register
;; of the whole marshalling -- including those of already-emitted moves, which
;; still hold placed argument values that must survive to the call.
(define (compiler-backend-emit-arg-move-list-with-all
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [moves : CompilerBackendArgMoveSeq]
  [all : CompilerBackendArgMoveSeq]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (match (compiler-backend-arg-move-decision
    backend-state
    assignments
    (be_state.compiler-backend-global-shared-view moves))
    [(CompilerParallelMoveDone) (Ok "")]
    [(CompilerParallelMoveUnblocked move-id)
      (match (compiler-backend-arg-move-list-find
        (be_state.compiler-backend-global-shared-view moves)
        move-id)
        [(BackendSomeArgMove move)
          (match (be_state.compiler-backend-global-shared-view move)
            [(BackendArgMove dest _)
              (let
                [head
                  (try
                    (compiler-backend-emit-arg-move
                      assignments
                      move
                      backend-state))]
                [tail
                  (try
                    (compiler-backend-emit-arg-move-list-with-all
                      assignments
                      (compiler-backend-arg-move-list-remove moves dest)
                      all
                      backend-state))]
                (Ok (str_cat.str-cat head tail)))])]
        [(BackendNoArgMove)
          (compiler-backend-parallel-move-missing "arg" move-id)])]
    [(CompilerParallelMoveCycle move-id)
      (match (compiler-backend-arg-move-list-find
        (be_state.compiler-backend-global-shared-view moves)
        move-id)
        [(BackendSomeArgMove move)
          (match (be_state.compiler-backend-global-shared-view move)
            [(BackendArgMove dest source)
              (let
                [srcreg : i64
                  (compiler-backend-arg-move-source-reg
                    backend-state
                    assignments
                    source)]
                ;; Cycle decisions should name a register-sourced move; this
                ;; branch is defensive if a malformed graph reaches the emitter.
                (if (= srcreg compiler_abi.compiler-reg-id-invalid)
                  (let
                    [head
                      (try
                        (compiler-backend-emit-arg-move
                          assignments
                          move
                          backend-state))]
                    [tail
                      (try
                        (compiler-backend-emit-arg-move-list-with-all
                          assignments
                          (compiler-backend-arg-move-list-remove moves dest)
                          all
                          backend-state))]
                    (Ok (str_cat.str-cat head tail)))
                  (let
                    ;; An XMM cycle always breaks through the frame temp: the
                    ;; scratch pool is GP-only.
                    [picked : i64
                      (if (compiler_abi.compiler-abi-xmm-register-id? srcreg)
                        compiler_abi.compiler-reg-id-invalid
                        (compiler-backend-arg-temp-pick-reg
                          backend-state
                          assignments
                          (be_state.compiler-backend-global-shared-view moves)
                          (be_state.compiler-backend-global-shared-view all)))]
                    (if (= picked compiler_abi.compiler-reg-id-invalid)
                      ;; No free scratch register at saturation: break the cycle
                      ;; through the reserved frame temp. This saves `srcreg`
                      ;; before any move overwrites it, and its single consumer
                      ;; (each cycle register is read exactly once) reloads it from
                      ;; the temp slot.
                      (let
                        [tail
                          (try
                            (compiler-backend-emit-arg-move-list-with-all
                              assignments
                              (compiler-backend-arg-move-list-redirect-to-stack
                                backend-state
                                assignments
                                moves
                                srcreg)
                              all
                              backend-state))]
                        (Ok
                          (str_cat.str-cat
                            (compiler-backend-emit-arg-cycle-temp-save
                              srcreg
                              backend-state)
                            tail)))
                      (let
                        [tail
                          (try
                            (compiler-backend-emit-arg-move-list-with-all
                              assignments
                              (compiler-backend-arg-move-list-redirect
                                backend-state
                                assignments
                                moves
                                srcreg
                                picked)
                              all
                              backend-state))]
                        (Ok
                          (str_cat.str-cat
                            (str_cat.str-cat
                              "    movq "
                              (compiler_abi.compiler-abi-register-spelling
                                srcreg)
                              ", "
                              (compiler_abi.compiler-abi-register-spelling
                                picked)
                              "\n")
                            tail)))))))])]
        [(BackendNoArgMove)
          (compiler-backend-parallel-move-missing "arg" move-id)])]))

(define (compiler-backend-arg-moves-build-from
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [arg-index : i64]
  [count : i64]
  [int-idx : i64]
  [position : i64]) : CompilerBackendArgMoveSeq
  (let
    [out : CompilerBackendArgMoveSeq
      (compiler-backend-arg-move-seq-with-capacity 0)]
    [i : i64 arg-index]
    [ints : i64 int-idx]
    [pos : i64 position]
    (while (< i count)
      (let
        [reg : i64
          (compiler_abi.compiler-abi-gp-arg-register-id
            (be_state.compiler-backend-target-abi target)
            convention
            (be_facts.compiler-backend-call-bank-index
              target
              convention
              ints
              pos))]
        (if (= reg compiler_abi.compiler-reg-id-invalid)
          unit
          (compiler-backend-arg-move-push!
            (&mut out)
            (BackendArgMove
              reg
              (BackendArgMoveValue
                (be_facts.compiler-backend-call-arg-at args i))))))
      (+= i 1)
      (+= ints 1)
      (+= pos 1))
    out))

(define (compiler-backend-arg-moves-build-at
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [int-idx : i64]
  [position : i64]) : CompilerBackendArgMoveSeq
  (compiler-backend-arg-moves-build-from
    target
    convention
    (be_state.compiler-backend-global-shared-view args)
    0
    (be_facts.compiler-backend-call-args-count args)
    int-idx
    position))

(define (compiler-backend-call-args-gp-fit-from?
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [count : i64]
  [int-idx : i64]
  [position : i64]) : bool
  (for [index (iterator.range 0 count)]
    (unless
      (not
        (be_scalar.compiler-backend-stack-call-arg-for-banks?
          target
          convention
          false
          int-idx
          0
          position))
      (return false))
    (set! int-idx (+ int-idx 1))
    (set! position (+ position 1)))
  true)

(define (compiler-backend-call-args-gp-parallel-from?
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [types : (& types compiler_ast_types.AstTypeList)]
  [c-abi? : bool]
  [program-index : be_state.CompilerBackendProgramIndex]
  [int-idx : i64]
  [position : i64]) : bool
  (let
    [count : i64 (be_facts.compiler-backend-call-args-count args)]
    (and
      (> count 0)
      (compiler-backend-call-args-gp-fit-from?
        target
        convention
        count
        int-idx
        position)
      (compiler-backend-types-all-gp-int?
        type-segment-bases
        target
        types
        c-abi?
        program-index))))

(define (compiler-backend-types-all-gp-int-from?
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [types : (& types compiler_ast_types.AstTypeList)]
  [c-abi? : bool]
  [program-index : be_state.CompilerBackendProgramIndex]
  [count : i64]) : bool
  (for [index (iterator.range 0 count)]
    (let
      [ty : compiler_ast_types.AstType
        (compiler_ast_types.ast-type-segment-bases-get
          type-segment-bases
          (compiler_ast_types.ast-type-list-get
            types
            index
            (compiler_ast_types.ast-type-id-fallback)))]
      (when
        (or
          (be_operand.compiler-backend-float-type? ty)
          (be_facts.compiler-backend-group-type?
            type-segment-bases
            program-index
            ty)
          (compiler-backend-c-memory-aggregate-type?
            type-segment-bases
            target
            c-abi?
            ty))
        (return false))))
  true)

(define (compiler-backend-types-all-gp-int?
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [types : (& types compiler_ast_types.AstTypeList)]
  [c-abi? : bool]
  [program-index : be_state.CompilerBackendProgramIndex]) : bool
  (compiler-backend-types-all-gp-int-from?
    type-segment-bases
    target
    (& types)
    c-abi?
    program-index
    (compiler_ast_types.ast-type-list-len (& types))))

;; GP thresholds match compiler-reg-arg-reg-limit-for-abi: six for Internal,
;; six for SysV Platform and four for Win64 Platform.
;; The argument marshalling loop appends straight into the caller's sequence
;; buffer rather than building one String per argument and folding them with
;; `append`, which would re-copy the whole accumulated prefix at every step.
(define (compiler-backend-emit-call-args-with-assignments-into
  [out : (&mut out be_state.CompilerBackendAsmBuf)]
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [arg-assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [types : compiler_ast_types.AstTypeList]
  [c-abi? : bool]
  [arg-index : i64]
  [int-idx : i64]
  [float-idx : i64]
  [position : i64]
  [stack-idx : i64]
  [func-diag : compiler_diagnostic.CompilerDiagnostic]
  [program-index : be_state.CompilerBackendProgramIndex]
  [vars : i64]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (>=
    arg-index
    (be_facts.compiler-backend-call-args-count
      (be_state.compiler-backend-global-shared-view args)))
    (Ok "")
    (let
      [value : compiler_ir_types.CompilerIrValue
        (be_facts.compiler-backend-call-arg-at args arg-index)]
      [arg-ty : compiler_ast_types.AstType
        (if (< arg-index (compiler_ast_types.ast-type-list-len (& types)))
          (compiler_ast_types.ast-type-segment-bases-get
            type-segment-bases
            (compiler_ast_types.ast-type-list-get
              (& types)
              arg-index
              (compiler_ast_types.ast-type-id-fallback)))
          (I64))]
      [is-float : bool (be_operand.compiler-backend-float-type? arg-ty)]
      [next-int : i64
        (if is-float
          int-idx
          (+ int-idx 1))]
      [next-float : i64
        (if is-float
          (+ float-idx 1)
          float-idx)]
      [memory-aggregate? : bool
        (compiler-backend-c-memory-aggregate-type?
          type-segment-bases
          target
          c-abi?
          (be_state.compiler-backend-global-shared-view arg-ty))]
      [memory-size : i64
        (if memory-aggregate?
          (compiler-backend-c-memory-aggregate-marker-size
            (be_state.compiler-backend-global-shared-view args)
            (+ arg-index 1))
          0)]
      [private-memory-size : i64
        (if (not c-abi?)
          (be_facts.compiler-backend-abi-memory-size
            type-segment-bases
            (be_state.compiler-backend-global-shared-view arg-ty))
          0)]
      ;; A register-group argument occupies two eightbytes. Linux SysV assigns
      ;; each word from its INTEGER/SSE class bank and falls back atomically to
      ;; two stack slots when either bank cannot fit the whole group. Windows
      ;; retains the existing unified-position group convention.
      (cond
        [(and
            (be_state.compiler-backend-target-sysv-aggregates?
              target
              convention)
            (> private-memory-size 0))
          (let
            [head
              (try
                (be_scalar.compiler-backend-emit-c-memory-stack-arg
                  type-segment-bases
                  target
                  convention
                  arg-assignments
                  value
                  stack-idx
                  private-memory-size
                  backend-state))]
            (be_state.compiler-backend-asm-append out head)
            (compiler-backend-emit-call-args-with-assignments-into
              out
              type-segment-bases
              target
              convention
              arg-assignments
              args
              types
              c-abi?
              (+ arg-index 1)
              int-idx
              float-idx
              (+ position 1)
              (+
                stack-idx
                (compiler-backend-stack-slots-for-size private-memory-size))
              func-diag
              program-index
              vars
              backend-state))]
        [(> memory-size 0)
          (let
            [head
              (try
                (be_scalar.compiler-backend-emit-c-memory-stack-arg
                  type-segment-bases
                  target
                  convention
                  arg-assignments
                  value
                  stack-idx
                  memory-size
                  backend-state))]
            (be_state.compiler-backend-asm-append out head)
            (compiler-backend-emit-call-args-with-assignments-into
              out
              type-segment-bases
              target
              convention
              arg-assignments
              args
              types
              c-abi?
              (+ arg-index 3)
              int-idx
              float-idx
              (+ position 1)
              (+ stack-idx (compiler-backend-stack-slots-for-size memory-size))
              func-diag
              program-index
              vars
              backend-state))]
        [(be_facts.compiler-backend-group-type?
            type-segment-bases
            program-index
            arg-ty)
          (let
            [linux-group-fits : bool
              (compiler-backend-linux-group-register-banks-fit?
                type-segment-bases
                target
                convention
                program-index
                (be_state.compiler-backend-global-shared-view arg-ty)
                int-idx
                float-idx
                position)]
            [w0-sse : bool
              (be_facts.compiler-backend-group-word-sse?
                type-segment-bases
                program-index
                arg-ty
                0)]
            [w0-stack : bool
              (be_scalar.compiler-backend-stack-call-arg-for-banks?
                target
                convention
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
              (be_facts.compiler-backend-group-word-sse?
                type-segment-bases
                program-index
                arg-ty
                1)]
            [w1-stack : bool
              (be_scalar.compiler-backend-stack-call-arg-for-banks?
                target
                convention
                w1-sse
                int1
                float1
                (+ position 1))]
            (if (and
              (be_state.compiler-backend-target-sysv-aggregates?
                target
                convention)
              (not linux-group-fits))
              (let
                [head
                  (try
                    (be_scalar.compiler-backend-emit-group-stack-arg
                      target
                      convention
                      arg-assignments
                      value
                      stack-idx
                      vars
                      (be_state.compiler-backend-global-shared-view arg-ty)
                      program-index
                      backend-state))]
                (be_state.compiler-backend-asm-append out head)
                (compiler-backend-emit-call-args-with-assignments-into
                  out
                  type-segment-bases
                  target
                  convention
                  arg-assignments
                  args
                  types
                  c-abi?
                  (+ arg-index 1)
                  int-idx
                  float-idx
                  (+ position 2)
                  (+ stack-idx 2)
                  func-diag
                  program-index
                  vars
                  backend-state))
              (let
                [head0
                  (try
                    (be_scalar.compiler-backend-emit-group-word-call-arg
                      type-segment-bases
                      target
                      convention
                      arg-assignments
                      (be_state.compiler-backend-global-shared-view value)
                      0
                      int-idx
                      float-idx
                      position
                      stack-idx
                      vars
                      (be_state.compiler-backend-global-shared-view arg-ty)
                      program-index
                      (be_state.compiler-backend-global-shared-view func-diag)
                      backend-state))]
                [head1
                  (try
                    (be_scalar.compiler-backend-emit-group-word-call-arg
                      type-segment-bases
                      target
                      convention
                      arg-assignments
                      value
                      1
                      int1
                      float1
                      (+ position 1)
                      stack1
                      vars
                      arg-ty
                      program-index
                      (be_state.compiler-backend-global-shared-view func-diag)
                      backend-state))]
                (be_state.compiler-backend-asm-append2 out head0 head1)
                (compiler-backend-emit-call-args-with-assignments-into
                  out
                  type-segment-bases
                  target
                  convention
                  arg-assignments
                  args
                  types
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
                  vars
                  backend-state))))]
        [(be_scalar.compiler-backend-stack-call-arg-for-banks?
            target
            convention
            is-float
            int-idx
            float-idx
            position)
          (let
            [_
              (try
                (compiler-backend-emit-scalar-stack-call-arg-into
                  out
                  type-segment-bases
                  target
                  convention
                  arg-assignments
                  value
                  arg-ty
                  is-float
                  stack-idx
                  backend-state))]
            (compiler-backend-emit-call-args-with-assignments-into
              out
              type-segment-bases
              target
              convention
              arg-assignments
              args
              types
              c-abi?
              (+ arg-index 1)
              next-int
              next-float
              (+ position 1)
              (+ stack-idx 1)
              func-diag
              program-index
              vars
              backend-state))]
        [else
          (match (if is-float
            (be_facts.compiler-backend-target-float-arg-reg-for-banks
              target
              convention
              float-idx
              position)
            (be_facts.compiler-backend-target-arg-reg-for-banks
              target
              convention
              int-idx
              position))
            [(Ok reg)
              (let
                [_
                  (try
                    (if is-float
                      (compiler-backend-emit-load-float-value-into
                        out
                        arg-assignments
                        value
                        arg-ty
                        reg
                        backend-state)
                      (be_operand.compiler-backend-emit-load-value-into
                        out
                        arg-assignments
                        value
                        reg
                        backend-state)))]
                (compiler-backend-emit-call-args-with-assignments-into
                  out
                  type-segment-bases
                  target
                  convention
                  arg-assignments
                  args
                  types
                  c-abi?
                  (+ arg-index 1)
                  next-int
                  next-float
                  (+ position 1)
                  stack-idx
                  func-diag
                  program-index
                  vars
                  backend-state))]
            [(Err message)
              (be_state.compiler-backend-instr-error func-diag message)])]))))

;; --- Any-arity GP argument marshalling (stack-first) -----------------------
;; A call whose arguments are ALL single-GP-register class can still overflow
;; the ABI's argument registers; everything past the register prefix is stored
;; into the outgoing stack area. The naive ascending emitter is sound only while
;; no argument SOURCE can be overwritten before it is read, which memory-homed
;; arg vars guarantee. Once such a call's args may stay register-homed, two
;; orders go wrong: a cycle inside the register
;; prefix, and a STACK argument read out of a register the prefix has already
;; overwritten.
;;
;; Both are answered by the same observation: an outgoing stack slot is never
;; the SOURCE of another argument (arg sources are register homes, frame slots,
;; immediates, globals and forwarded addr-of leas), so a stack store has no
;; incoming dependency and may be emitted FIRST. This path emits, in order,
;;   1. the stack stores whose source is a register home -- a plain
;;      `movq %home, off(%rsp)` issued before any argument register is written,
;;      and needing no staging scratch at all;
;;   2. the register prefix, through the existing sound parallel move
;;      (compiler-backend-emit-arg-move-list), which breaks prefix cycles;
;;   3. the remaining stack stores, whose sources are immediates or memory and
;;      so cannot have been clobbered by anything step 2 wrote. Their staging
;;      scratch is scavenged exactly as the naive path scavenges it, with every
;;      argument register already excluded by the c-abi stage mask -- and by
;;      then no register source is left to protect, which is what keeps the
;;      "a source dying at the call may read as free" scavenge hazard out of
;;      this path.
;; The invariant is that no argument source is overwritten before it is read.
;; Mirrored in regalloc by compiler-reg-call-gp-overflow-from?; only the call
;; kinds whose emitter reaches this path may use that rule.
;; How many leading arguments of an all-GP-int call are passed in GP ARGUMENT
;; REGISTERS from the caller's current bank position. Every argument is one GP
;; register wide here, so the split is a prefix: once the bank is full it stays
;; full, and the remaining args take one outgoing stack slot each.
(define (compiler-backend-call-args-gp-register-prefix
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [count : i64]
  [int-idx : i64]
  [position : i64]) : i64
  (let
    [index : i64 0]
    [done : bool false]
    (while (and (< index count) (not done))
      (if (be_scalar.compiler-backend-stack-call-arg-for-banks?
        target
        convention
        false
        (+ int-idx index)
        0
        (+ position index))
        (set! done true)
        (+= index 1)))
    index))

;; The argument type at `index`, read exactly as the naive marshalling loop
;; reads it: past the declared parameter list (a vararg tail) an argument is
;; i64-class.
(define (compiler-backend-call-arg-type-at
  [type-segment-bases : i64]
  [types : (& types compiler_ast_types.AstTypeList)]
  [index : i64]) : compiler_ast_types.AstType
  (if (< index (compiler_ast_types.ast-type-list-len (& types)))
    (compiler_ast_types.ast-type-segment-bases-get
      type-segment-bases
      (compiler_ast_types.ast-type-list-get
        (& types)
        index
        (compiler_ast_types.ast-type-id-fallback)))
    (I64)))

;; An all-GP-int call that does NOT fit its ABI's argument registers from the
;; caller's current bank position -- the shape the stack-first order exists for.
;; Deliberately the complement of compiler-backend-call-args-gp-parallel-from?'s
;; fit test, so exactly one of the two paths can claim a call.
(define (compiler-backend-call-args-gp-overflow-from?
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [types : (& types compiler_ast_types.AstTypeList)]
  [c-abi? : bool]
  [program-index : be_state.CompilerBackendProgramIndex]
  [int-idx : i64]
  [position : i64]) : bool
  (let
    [count : i64 (be_facts.compiler-backend-call-args-count args)]
    (and
      (> count 0)
      (not
        (compiler-backend-call-args-gp-fit-from?
          target
          convention
          count
          int-idx
          position))
      (compiler-backend-types-all-gp-int?
        type-segment-bases
        target
        types
        c-abi?
        program-index))))

;; Does any STACK-passed argument read a register home? Those are exactly the
;; sources the register prefix -- and a staging scratch scavenged after it --
;; can destroy, so their presence is what makes the stack-first order necessary.
;; With every arg var memory-homed (the pre-existing rule for an over-arity
;; call) this is false, no prefix move has a register source either, and the
;; call keeps the byte-identical naive path.
(define (compiler-backend-call-stack-args-register-sourced?
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [prefix : i64]
  [count : i64]) : bool
  (let
    [index : i64 prefix]
    [found : bool false]
    (while (and (< index count) (not found))
      (if (=
        (compiler-backend-arg-move-source-reg
          backend-state
          assignments
          (BackendArgMoveValue
            (be_facts.compiler-backend-call-arg-at args index)))
        compiler_abi.compiler-reg-id-invalid)
        unit
        (set! found true))
      (+= index 1))
    found))

;; Does this over-arity all-GP call need the stack-first order? Either the
;; register prefix has a real source/dest conflict, or a stack argument is read
;; out of a register. Neither can hold while the args are memory-homed, so the
;; pre-existing emission of every such call is untouched.
(define (compiler-backend-call-args-gp-stack-first?
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [types : (& types compiler_ast_types.AstTypeList)]
  [c-abi? : bool]
  [program-index : be_state.CompilerBackendProgramIndex]
  [int-idx : i64]
  [position : i64]
  [backend-state : be_state.CompilerBackendState]) : bool
  (and
    (compiler-backend-call-args-gp-overflow-from?
      type-segment-bases
      target
      convention
      (be_state.compiler-backend-global-shared-view args)
      types
      c-abi?
      program-index
      int-idx
      position)
    (let
      [count : i64
        (be_facts.compiler-backend-call-args-count
          (be_state.compiler-backend-global-shared-view args))]
      [prefix : i64
        (compiler-backend-call-args-gp-register-prefix
          target
          convention
          count
          int-idx
          position)]
      (or
        (compiler-backend-arg-moves-conflict?
          backend-state
          assignments
          (compiler-backend-arg-moves-build-from
            target
            convention
            (be_state.compiler-backend-global-shared-view args)
            0
            prefix
            int-idx
            position))
        (compiler-backend-call-stack-args-register-sourced?
          backend-state
          assignments
          args
          prefix
          count)))))

;; --- Parallel argument marshalling for all-scalar calls ---------------------
;; Where a call's stack arguments go: the outgoing area of an ordinary call, or
;; the caller's own incoming area for a direct tail call, whose callee reads the
;; same slots the caller received.
(defenum CompilerBackendStackArgArea
  (OutgoingStackArgArea)
  (IncomingStackArgArea))

(define (compiler-backend-stack-arg-area-slot
  [area : CompilerBackendStackArgArea]
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [stack-idx : i64]
  [backend-state : be_state.CompilerBackendState]) : String
  (match area
    [(OutgoingStackArgArea)
      (str_cat.str-cat
        (string.int->string
          (be_facts.compiler-backend-outgoing-stack-arg-offset
            target
            convention
            stack-idx))
        "(%rsp)")]
    [(IncomingStackArgArea)
      (compiler-backend-tail-final-stack-slot target stack-idx backend-state)]))

;; Argument classes in a scalar argument plan.
(define compiler-backend-scalar-arg-gp : i64
  0)
(define compiler-backend-scalar-arg-f64 : i64
  1)
(define compiler-backend-scalar-arg-f32 : i64
  2)

;; Where each argument of an all-scalar call goes and where it is read from,
;; resolved once so every step below partitions the same arguments:
;; - `dests`: the argument register (GP or XMM id), or invalid when the
;;   argument is stack-passed;
;; - `stack-slots`: the stack index of a stack-passed argument, -1 otherwise;
;; - `classes`: GP, f64 or f32;
;; - `sources`: the register the value is read from, or invalid for an
;;   immediate or a memory home.
(defstruct CompilerBackendScalarArgPlan
  (dests (__tl_dyn-array i64))
  (stack-slots (__tl_dyn-array i64))
  (classes (__tl_dyn-array i64))
  (sources (__tl_dyn-array i64)))

(define (compiler-backend-scalar-arg-plan
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [args : (& args compiler_ir_types.CompilerIrCallArgs)]
  [types : (& types compiler_ast_types.AstTypeList)]
  [int-idx : i64]
  [float-idx : i64]
  [position : i64]
  [stack-idx : i64]
  [backend-state : be_state.CompilerBackendState]) : CompilerBackendScalarArgPlan
  (let
    [count : i64 (compiler_ir_types.compiler-ir-call-args-count args)]
    [dests : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [stack-slots : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [classes : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [sources : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [ints : i64 int-idx]
    [floats : i64 float-idx]
    [pos : i64 position]
    [stack : i64 stack-idx]
    [index : i64 0]
    (while (< index count)
      (let
        [ty : compiler_ast_types.AstType
          (compiler-backend-call-arg-type-at type-segment-bases types index)]
        [is-float : bool (be_operand.compiler-backend-float-type? (& ty))]
        (set!
          (array-ref classes index)
          (match ty
            [(F32) compiler-backend-scalar-arg-f32]
            [(F64) compiler-backend-scalar-arg-f64]
            [_ compiler-backend-scalar-arg-gp]))
        (set!
          (array-ref sources index)
          (compiler-backend-arg-value-source-reg
            backend-state
            assignments
            (be_facts.compiler-backend-call-arg-at args index)))
        (if (be_scalar.compiler-backend-stack-call-arg-for-banks?
          target
          convention
          is-float
          ints
          floats
          pos)
          (begin
            (set! (array-ref dests index) compiler_abi.compiler-reg-id-invalid)
            (set! (array-ref stack-slots index) stack)
            (set! stack (+ stack 1)))
          (begin
            (set!
              (array-ref dests index)
              (if is-float
                (compiler_abi.compiler-abi-float-arg-register-id
                  (be_state.compiler-backend-target-abi target)
                  convention
                  (be_facts.compiler-backend-call-bank-index
                    target
                    convention
                    floats
                    pos))
                (compiler_abi.compiler-abi-gp-arg-register-id
                  (be_state.compiler-backend-target-abi target)
                  convention
                  (be_facts.compiler-backend-call-bank-index
                    target
                    convention
                    ints
                    pos))))
            (set! (array-ref stack-slots index) -1)))
        (if is-float
          (set! floats (+ floats 1))
          (set! ints (+ ints 1)))
        (set! pos (+ pos 1)))
      (set! index (+ index 1)))
    (CompilerBackendScalarArgPlan dests stack-slots classes sources)))

;; The register moves of a plan, GP and XMM alike, in argument order.
(define (compiler-backend-scalar-arg-plan-moves
  [args : (& args compiler_ir_types.CompilerIrCallArgs)]
  [plan : (& plan CompilerBackendScalarArgPlan)]) : CompilerBackendArgMoveSeq
  (let
    [out : CompilerBackendArgMoveSeq
      (compiler-backend-arg-move-seq-with-capacity 0)]
    [index : i64 0]
    (while (< index (array-length plan.dests))
      (let
        [dest : i64 (array-ref plan.dests index)]
        [class : i64 (array-ref plan.classes index)]
        (if (= dest compiler_abi.compiler-reg-id-invalid)
          unit
          (compiler-backend-arg-move-push!
            (&mut out)
            (BackendArgMove
              dest
              (if (= class compiler-backend-scalar-arg-gp)
                (BackendArgMoveValue
                  (be_facts.compiler-backend-call-arg-at args index))
                (BackendArgMoveFloatValue
                  (be_facts.compiler-backend-call-arg-at args index)
                  (= class compiler-backend-scalar-arg-f32)))))))
      (set! index (+ index 1)))
    out))

;; Does the sequential marshalling risk reading a source it already
;; overwrote? Either an argument register is another argument's source, or a
;; stack argument is read out of a register, which the sequential path stores
;; only after it has written the registers before it.
(define (compiler-backend-scalar-arg-plan-hazard?
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [args : (& args compiler_ir_types.CompilerIrCallArgs)]
  [plan : (& plan CompilerBackendScalarArgPlan)]) : bool
  (let
    [register-sourced-stack? : bool false]
    [index : i64 0]
    (while (< index (array-length plan.dests))
      (if (and
        (>= (array-ref plan.stack-slots index) 0)
        (not
          (=
            (array-ref plan.sources index)
            compiler_abi.compiler-reg-id-invalid)))
        (set! register-sourced-stack? true)
        unit)
      (set! index (+ index 1)))
    (or
      register-sourced-stack?
      (compiler-backend-arg-moves-conflict?
        backend-state
        assignments
        (compiler-backend-scalar-arg-plan-moves args plan)))))

;; Is every argument one scalar: a float, or a GP-class value that is neither
;; a register group nor passed in memory? The parallel marshalling handles
;; exactly these calls.
(define (compiler-backend-call-args-all-scalar?
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [args : (& args compiler_ir_types.CompilerIrCallArgs)]
  [types : (& types compiler_ast_types.AstTypeList)]
  [c-abi? : bool]
  [program-index : be_state.CompilerBackendProgramIndex]) : bool
  (let
    [count : i64 (compiler_ir_types.compiler-ir-call-args-count args)]
    [ok : bool true]
    [index : i64 0]
    (while (and ok (< index count))
      (let
        [ty : compiler_ast_types.AstType
          (compiler-backend-call-arg-type-at type-segment-bases types index)]
        (if (or
          (be_operand.compiler-backend-float-type? (& ty))
          (and
            (not
              (be_facts.compiler-backend-group-type?
                type-segment-bases
                program-index
                (& ty)))
            (=
              (be_facts.compiler-backend-abi-memory-size
                type-segment-bases
                (compiler-backend-call-arg-type-at
                  type-segment-bases
                  types
                  index))
              0)
            (not
              (compiler-backend-c-memory-aggregate-type?
                type-segment-bases
                target
                c-abi?
                ty))))
          unit
          (set! ok false)))
      (set! index (+ index 1)))
    ok))

(define (compiler-backend-call-args-any-register-sourced?
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [args : (& args compiler_ir_types.CompilerIrCallArgs)]) : bool
  (let
    [count : i64 (compiler_ir_types.compiler-ir-call-args-count args)]
    [found : bool false]
    [index : i64 0]
    (while (and (not found) (< index count))
      (if (=
        (compiler-backend-arg-value-source-reg
          backend-state
          assignments
          (be_facts.compiler-backend-call-arg-at args index))
        compiler_abi.compiler-reg-id-invalid)
        unit
        (set! found true))
      (set! index (+ index 1)))
    found))

(define (compiler-backend-call-args-any-float?
  [type-segment-bases : i64]
  [args : (& args compiler_ir_types.CompilerIrCallArgs)]
  [types : (& types compiler_ast_types.AstTypeList)]) : bool
  (let
    [count : i64 (compiler_ir_types.compiler-ir-call-args-count args)]
    [found : bool false]
    [index : i64 0]
    (while (and (not found) (< index count))
      (if (be_operand.compiler-backend-float-type?
        (& (compiler-backend-call-arg-type-at type-segment-bases types index)))
        (set! found true)
        unit)
      (set! index (+ index 1)))
    found))

;; A direct tail call whose arguments are all scalars and whose sequential
;; marshalling would read an overwritten source. Regalloc keeps a parameter in
;; its incoming argument register across a tail call (control never returns
;; past one), so a permuted forward of the caller's parameters -- of either
;; register class, with or without stack arguments -- needs the parallel move.
(define (compiler-backend-tail-call-args-parallel?
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [args : (& args compiler_ir_types.CompilerIrCallArgs)]
  [types : (& types compiler_ast_types.AstTypeList)]
  [c-abi? : bool]
  [program-index : be_state.CompilerBackendProgramIndex]
  [stack-count : i64]
  [backend-state : be_state.CompilerBackendState]) : bool
  (and
    (> (compiler_ir_types.compiler-ir-call-args-count args) 0)
    ;; A register-only all-GP call already gets the parallel move from
    ;; compiler-backend-emit-call-args; checking it here would only repeat
    ;; that work on the most common tail call.
    (or
      (> stack-count 0)
      (compiler-backend-call-args-any-float? type-segment-bases args types))
    ;; Without a register source nothing can be overwritten before it is read.
    (compiler-backend-call-args-any-register-sourced?
      backend-state
      assignments
      args)
    (compiler-backend-call-args-all-scalar?
      type-segment-bases
      target
      args
      types
      c-abi?
      program-index)
    (compiler-backend-scalar-arg-plan-hazard?
      backend-state
      assignments
      args
      (&
        (compiler-backend-scalar-arg-plan
          type-segment-bases
          target
          convention
          assignments
          args
          types
          0
          0
          0
          0
          backend-state)))))

;; One stack argument whose source is an immediate or memory, through the
;; emitter of its area.
(define (compiler-backend-emit-stack-arg-to-area-into
  [out : (&mut out be_state.CompilerBackendAsmBuf)]
  [area : CompilerBackendStackArgArea]
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]
  [arg-ty : compiler_ast_types.AstType]
  [is-float : bool]
  [stack-idx : i64]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (match area
    [(OutgoingStackArgArea)
      (compiler-backend-emit-scalar-stack-call-arg-into
        out
        type-segment-bases
        target
        convention
        assignments
        value
        arg-ty
        is-float
        stack-idx
        backend-state)]
    [(IncomingStackArgArea)
      (let
        [store
          (try
            (compiler-backend-emit-direct-tail-stack-call-arg
              type-segment-bases
              target
              assignments
              value
              arg-ty
              is-float
              stack-idx
              backend-state))]
        (be_state.compiler-backend-asm-append out store)
        (Ok ""))]))

;; Step 3: the stack arguments whose source is an immediate or memory, in
;; argument order. The registers are already placed, so the staging scratch
;; only has to avoid the argument registers and whatever the occupancy mask
;; reports live -- the sequential path's own conditions.
(define (compiler-backend-emit-memory-sourced-stack-args-into
  [out : (&mut out be_state.CompilerBackendAsmBuf)]
  [area : CompilerBackendStackArgArea]
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [args : (& args compiler_ir_types.CompilerIrCallArgs)]
  [types : (& types compiler_ast_types.AstTypeList)]
  [plan : (& plan CompilerBackendScalarArgPlan)]
  [index : i64]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (cond
    [(>= index (array-length plan.dests)) (Ok "")]
    [(or
        (< (array-ref plan.stack-slots index) 0)
        (not
          (=
            (array-ref plan.sources index)
            compiler_abi.compiler-reg-id-invalid)))
      (compiler-backend-emit-memory-sourced-stack-args-into
        out
        area
        type-segment-bases
        target
        convention
        assignments
        args
        types
        plan
        (+ index 1)
        backend-state)]
    [else
      (let
        [_
          (try
            (compiler-backend-emit-stack-arg-to-area-into
              out
              area
              type-segment-bases
              target
              convention
              assignments
              (be_facts.compiler-backend-call-arg-at args index)
              (compiler-backend-call-arg-type-at type-segment-bases types index)
              (not
                (=
                  (array-ref plan.classes index)
                  compiler-backend-scalar-arg-gp))
              (array-ref plan.stack-slots index)
              backend-state))]
        (compiler-backend-emit-memory-sourced-stack-args-into
          out
          area
          type-segment-bases
          target
          convention
          assignments
          args
          types
          plan
          (+ index 1)
          backend-state))]))

;; Argument marshalling as one parallel move, for a call whose arguments are
;; all scalars. An argument register can hold another argument's source (a
;; parameter kept in its incoming register, or a value regalloc left in an
;; argument register), so no register is written while a pending argument
;; still reads it:
;;   1. the stack arguments read out of a register are stored first, before
;;      any register is written: `movq` from a GP source, `movsd`/`movss` from
;;      an XMM one;
;;   2. every argument register, GP and XMM, is filled by one parallel move
;;      (compiler-backend-emit-arg-move-list). The two classes share no
;;      register, so their moves never block each other. A GP cycle breaks
;;      through a scavenged scratch register, an XMM cycle through the
;;      reserved cycle-temp slot;
;;   3. the stack arguments whose source is an immediate or memory are stored
;;      last.
;; `area` names where the stack arguments go. For a direct tail call that is
;; the caller's incoming area: the caller copied its own stack parameters into
;; their homes at entry, so no source lives in the area these stores overwrite.
(define (compiler-backend-emit-call-args-parallel-into
  [out : (&mut out be_state.CompilerBackendAsmBuf)]
  [area : CompilerBackendStackArgArea]
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [args : (& args compiler_ir_types.CompilerIrCallArgs)]
  [types : (& types compiler_ast_types.AstTypeList)]
  [int-idx : i64]
  [float-idx : i64]
  [position : i64]
  [stack-idx : i64]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [plan : CompilerBackendScalarArgPlan
      (compiler-backend-scalar-arg-plan
        type-segment-bases
        target
        convention
        assignments
        args
        types
        int-idx
        float-idx
        position
        stack-idx
        backend-state)]
    [index : i64 0]
    (while (< index (array-length plan.dests))
      (let
        [slot : i64 (array-ref plan.stack-slots index)]
        [source : i64 (array-ref plan.sources index)]
        [class : i64 (array-ref plan.classes index)]
        (if (or (< slot 0) (= source compiler_abi.compiler-reg-id-invalid))
          unit
          (be_state.compiler-backend-asm-append5
            out
            (cond
              [(not (compiler_abi.compiler-abi-xmm-register-id? source))
                "    movq "]
              [(= class compiler-backend-scalar-arg-f32) "    movss "]
              [(= class compiler-backend-scalar-arg-f64) "    movsd "]
              [else "    movq "])
            (compiler_abi.compiler-abi-register-spelling source)
            ", "
            (compiler-backend-stack-arg-area-slot
              area
              target
              convention
              slot
              backend-state)
            "\n")))
      (set! index (+ index 1)))
    (let
      [moves
        (try
          (compiler-backend-emit-arg-move-list
            assignments
            (compiler-backend-scalar-arg-plan-moves args (& plan))
            backend-state))]
      (be_state.compiler-backend-asm-append out moves)
      (compiler-backend-emit-memory-sourced-stack-args-into
        out
        area
        type-segment-bases
        target
        convention
        assignments
        args
        types
        (& plan)
        0
        backend-state))))

;; String-returning shim for the direct tail call, whose arguments are emitted
;; as text.
(define (compiler-backend-emit-direct-tail-call-args-parallel
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [args : (& args compiler_ir_types.CompilerIrCallArgs)]
  [types : (& types compiler_ast_types.AstTypeList)]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [out : be_state.CompilerBackendAsmBuf
      (be_state.compiler-backend-asm-buf-with-capacity
        be_state.compiler-backend-asm-seq-capacity)]
    [_
      (try
        (compiler-backend-emit-call-args-parallel-into
          (&mut out)
          (IncomingStackArgArea)
          type-segment-bases
          target
          convention
          assignments
          args
          types
          0
          0
          0
          0
          backend-state))]
    (Ok (be_state.compiler-backend-asm-buf-finish (& out)))))

(define (compiler-backend-emit-call-args-into
  [out : (&mut out be_state.CompilerBackendAsmBuf)]
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [types : compiler_ast_types.AstTypeList]
  [c-abi? : bool]
  [arg-index : i64]
  [int-idx : i64]
  [float-idx : i64]
  [position : i64]
  [stack-idx : i64]
  [func-diag : compiler_diagnostic.CompilerDiagnostic]
  [program-index : be_state.CompilerBackendProgramIndex]
  [vars : i64]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  ;; Intercept only a fresh (arg-index 0) call whose args are all GP
  ;; register-passed scalars from the caller's current ABI bank position AND that
  ;; has a real register source/dest conflict; emit those via the sound parallel
  ;; move. Every other call (including the conflict-free common case) delegates
  ;; to the byte-identical naive path.
  (let
    [parallel? : bool
      (and
        (= arg-index 0)
        (compiler-backend-call-args-gp-parallel-from?
          type-segment-bases
          target
          convention
          (be_state.compiler-backend-global-shared-view args)
          types
          c-abi?
          program-index
          int-idx
          position))]
    ;; Built once: the conflict test and the parallel emission read the same
    ;; moves.
    [arg-moves : CompilerBackendArgMoveSeq
      (if parallel?
        (compiler-backend-arg-moves-build-at
          target
          convention
          (be_state.compiler-backend-global-shared-view args)
          int-idx
          position)
        (compiler-backend-arg-move-seq-with-capacity 0))]
    (if (and
      parallel?
      (compiler-backend-arg-moves-conflict?
        backend-state
        assignments
        (be_state.compiler-backend-global-shared-view arg-moves)))
      (let
        [moves
          (try
            (compiler-backend-emit-arg-move-list
              assignments
              arg-moves
              backend-state))]
        (be_state.compiler-backend-asm-append out moves)
        (Ok ""))
      ;; The same interception one arity up: an all-GP call that OVERFLOWS its
      ;; argument registers and whose stack args or register prefix read a
      ;; register. Its overflow is stored before any argument register is written
      ;; (compiler-backend-emit-call-args-parallel-into).
      (if (and
        (= arg-index 0)
        (compiler-backend-call-args-gp-stack-first?
          type-segment-bases
          target
          convention
          assignments
          (be_state.compiler-backend-global-shared-view args)
          types
          c-abi?
          program-index
          int-idx
          position
          backend-state))
        (compiler-backend-emit-call-args-parallel-into
          out
          (OutgoingStackArgArea)
          type-segment-bases
          target
          convention
          assignments
          (& args)
          (& types)
          int-idx
          float-idx
          position
          stack-idx
          backend-state)
        (compiler-backend-emit-call-args-with-assignments-into
          out
          type-segment-bases
          target
          convention
          assignments
          args
          types
          c-abi?
          arg-index
          int-idx
          float-idx
          position
          stack-idx
          func-diag
          program-index
          vars
          backend-state)))))

;; String-returning shim for the call emitters that still hand their argument
;; block back as text: one sequence buffer for the whole marshalling block
;; instead of one String per argument plus a re-copying append fold.
(define (compiler-backend-emit-call-args
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [types : compiler_ast_types.AstTypeList]
  [c-abi? : bool]
  [arg-index : i64]
  [int-idx : i64]
  [float-idx : i64]
  [position : i64]
  [stack-idx : i64]
  [func-diag : (& func-diag compiler_diagnostic.CompilerDiagnostic)]
  [program-index : be_state.CompilerBackendProgramIndex]
  [vars : i64]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [func-diag : compiler_diagnostic.CompilerDiagnostic
      (owned_view.compiler-owned-reference-shared-view func-diag)]
    [seq : be_state.CompilerBackendAsmBuf
      (be_state.compiler-backend-asm-buf-with-capacity
        be_state.compiler-backend-asm-seq-capacity)]
    [_
      (try
        (compiler-backend-emit-call-args-into
          (&mut seq)
          type-segment-bases
          target
          convention
          assignments
          args
          types
          c-abi?
          arg-index
          int-idx
          float-idx
          position
          stack-idx
          func-diag
          program-index
          vars
          backend-state))]
    (Ok (be_state.compiler-backend-asm-buf-finish (& seq)))))

;; Call compiler-backend-emit-call-args with the rax override engaged for
;; exactly the dynamic extent of arg emission. The override is authoritative
;; for both the dense per-function view and the context-table fallback. Reset
;; on both result paths so the main emission spine always observes -1.
(define (compiler-backend-emit-call-args-with-override-into
  [out : (&mut out be_state.CompilerBackendAsmBuf)]
  [type-segment-bases : i64]
  [override-var : i64]
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [types : compiler_ast_types.AstTypeList]
  [c-abi? : bool]
  [arg-index : i64]
  [int-idx : i64]
  [float-idx : i64]
  [position : i64]
  [stack-idx : i64]
  [func-diag : compiler_diagnostic.CompilerDiagnostic]
  [program-index : be_state.CompilerBackendProgramIndex]
  [vars : i64]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [function-state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state backend-state)]
    [result : be_state.ResultCompilerBackend
      (begin
        (be_state.compiler-backend-function-state-set-i64!
          function-state
          be_state.compiler-backend-function-i64-rax-override-var
          override-var)
        (compiler-backend-emit-call-args-into
          out
          type-segment-bases
          target
          convention
          assignments
          args
          types
          c-abi?
          arg-index
          int-idx
          float-idx
          position
          stack-idx
          func-diag
          program-index
          vars
          backend-state))]
    (be_state.compiler-backend-function-state-set-i64!
      function-state
      be_state.compiler-backend-function-i64-rax-override-var
      -1)
    result))

(define (compiler-backend-emit-call-args-with-override
  [type-segment-bases : i64]
  [override-var : i64]
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [types : compiler_ast_types.AstTypeList]
  [c-abi? : bool]
  [arg-index : i64]
  [int-idx : i64]
  [float-idx : i64]
  [position : i64]
  [stack-idx : i64]
  [func-diag : compiler_diagnostic.CompilerDiagnostic]
  [program-index : be_state.CompilerBackendProgramIndex]
  [vars : i64]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [seq : be_state.CompilerBackendAsmBuf
      (be_state.compiler-backend-asm-buf-with-capacity
        be_state.compiler-backend-asm-seq-capacity)]
    [_
      (try
        (compiler-backend-emit-call-args-with-override-into
          (&mut seq)
          type-segment-bases
          override-var
          target
          convention
          assignments
          args
          types
          c-abi?
          arg-index
          int-idx
          float-idx
          position
          stack-idx
          func-diag
          program-index
          vars
          backend-state))]
    (Ok (be_state.compiler-backend-asm-buf-finish (& seq)))))

(define (compiler-backend-declared-first-call-arg-accepts-rax-forward?
  [type-segment-bases : i64]
  [program-index : be_state.CompilerBackendProgramIndex]
  [declared-types : (& declared-types compiler_ast_types.AstTypeList)]) : bool
  (if (> (compiler_ast_types.ast-type-list-len (& declared-types)) 0)
    (not
      (let
        [ty
          (compiler_ast_types.ast-type-segment-bases-get
            type-segment-bases
            (compiler_ast_types.ast-type-list-get
              (& declared-types)
              0
              (compiler_ast_types.ast-type-id-fallback)))]
        (be_facts.compiler-backend-group-type?
          type-segment-bases
          program-index
          ty)))
    true))

(define (compiler-backend-tail-final-stack-slot
  [target : be_state.CompilerBackendTarget]
  [stack-idx : i64]
  [backend-state : be_state.CompilerBackendState]) : String
  (be_operand.compiler-backend-frame-offset-with-backend-state
    backend-state
    (be_facts.compiler-backend-incoming-stack-arg-offset target stack-idx)))

(define (compiler-backend-emit-direct-tail-stack-call-arg
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]
  [arg-ty : compiler_ast_types.AstType]
  [is-float : bool]
  [stack-idx : i64]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [slot : String
      (compiler-backend-tail-final-stack-slot target stack-idx backend-state)]
    (if is-float
      (let
        [scav : String
          (be_scalar.compiler-backend-stack-call-arg-stage backend-state)]
        [gp-part : String
          (be_scalar.compiler-backend-float-bits-gp-reg
            type-segment-bases
            (be_state.compiler-backend-global-shared-view scav)
            (be_state.compiler-backend-global-shared-view arg-ty))]
        [head
          (try
            (be_scalar.compiler-backend-emit-load-float-bits-to-gp
              type-segment-bases
              assignments
              value
              (be_state.compiler-backend-global-shared-view arg-ty)
              scav
              backend-state))]
        (Ok
          (str_cat.str-cat
            head
            "    "
            (be_scalar.compiler-backend-float-bits-load-mnemonic
              type-segment-bases
              arg-ty)
            " "
            gp-part
            ", "
            (str_cat.str-cat slot "\n"))))
      (match (be_operand.compiler-backend-immediate-operand backend-state value)
        [(Some imm) (Ok (str_cat.str-cat "    movq " imm ", " slot "\n"))]
        [(No)
          (let
            [scav : String
              (be_scalar.compiler-backend-stack-call-arg-stage backend-state)]
            [head
              (try
                (be_operand.compiler-backend-emit-load-value
                  assignments
                  value
                  (be_state.compiler-backend-global-shared-view scav)
                  backend-state))]
            (Ok (str_cat.str-cat head "    movq " scav ", " slot "\n" "")))]))))

(define (compiler-backend-emit-direct-tail-call-args-from
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [types : compiler_ast_types.AstTypeList]
  [arg-index : i64]
  [int-idx : i64]
  [float-idx : i64]
  [position : i64]
  [stack-idx : i64]
  [func-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (>=
    arg-index
    (be_facts.compiler-backend-call-args-count
      (be_state.compiler-backend-global-shared-view args)))
    (Ok "")
    (let
      [value : compiler_ir_types.CompilerIrValue
        (be_facts.compiler-backend-call-arg-at args arg-index)]
      [arg-ty : compiler_ast_types.AstType
        (if (< arg-index (compiler_ast_types.ast-type-list-len (& types)))
          (compiler_ast_types.ast-type-segment-bases-get
            type-segment-bases
            (compiler_ast_types.ast-type-list-get
              (& types)
              arg-index
              (compiler_ast_types.ast-type-id-fallback)))
          (I64))]
      [is-float : bool (be_operand.compiler-backend-float-type? arg-ty)]
      [next-int : i64
        (if is-float
          int-idx
          (+ int-idx 1))]
      [next-float : i64
        (if is-float
          (+ float-idx 1)
          float-idx)]
      (if (be_scalar.compiler-backend-stack-call-arg-for-banks?
        target
        convention
        is-float
        int-idx
        float-idx
        position)
        (let
          [head
            (try
              (compiler-backend-emit-direct-tail-stack-call-arg
                type-segment-bases
                target
                assignments
                value
                arg-ty
                is-float
                stack-idx
                backend-state))]
          [tail
            (try
              (compiler-backend-emit-direct-tail-call-args-from
                type-segment-bases
                target
                convention
                assignments
                args
                types
                (+ arg-index 1)
                next-int
                next-float
                (+ position 1)
                (+ stack-idx 1)
                func-diag
                backend-state))]
          (Ok (str_cat.str-cat head tail)))
        (match (if is-float
          (be_facts.compiler-backend-target-float-arg-reg-for-banks
            target
            convention
            float-idx
            position)
          (be_facts.compiler-backend-target-arg-reg-for-banks
            target
            convention
            int-idx
            position))
          [(Ok reg)
            (let
              [head
                (try
                  (if is-float
                    (be_operand.compiler-backend-emit-load-float-value
                      assignments
                      value
                      arg-ty
                      reg
                      backend-state)
                    (be_operand.compiler-backend-emit-load-value
                      assignments
                      value
                      reg
                      backend-state)))]
              [tail
                (try
                  (compiler-backend-emit-direct-tail-call-args-from
                    type-segment-bases
                    target
                    convention
                    assignments
                    args
                    types
                    (+ arg-index 1)
                    next-int
                    next-float
                    (+ position 1)
                    stack-idx
                    func-diag
                    backend-state))]
              (Ok (str_cat.str-cat head tail)))]
          [(Err message)
            (be_state.compiler-backend-instr-error func-diag message)])))))

(define (compiler-backend-emit-direct-tail-call-args
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [types : compiler_ast_types.AstTypeList]
  [func-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (compiler-backend-emit-direct-tail-call-args-from
    type-segment-bases
    target
    convention
    assignments
    args
    types
    0
    0
    0
    0
    0
    func-diag
    backend-state))

(define (compiler-backend-phi-same-home?
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [value : compiler_ir_types.CompilerIrValue]) : bool
  (be_scalar.compiler-backend-value-same-home?
    backend-state
    assignments
    dst
    value))

(define (compiler-backend-phi-source-uses-home?
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [source : be_state.CompilerBackendPhiSource]
  [dst : i64]) : bool
  (match source
    [(Value value)
      (match value
        [(Var found)
          (be_scalar.compiler-backend-value-same-home?
            backend-state
            assignments
            dst
            (Var found))]
        [_ false])]
    [(Temp _) false]))

(define (compiler-backend-phi-copy-source-uses-home?
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [phi-copy : be_state.CompilerBackendPhiCopy]
  [dst : i64]) : bool
  (match phi-copy
    [(Copy _ source _)
      (compiler-backend-phi-source-uses-home?
        backend-state
        assignments
        source
        dst)]))

(define (compiler-backend-var-parallel-resource0
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [var : i64]) : i64
  (match (be_operand.compiler-backend-emit-assignment-lookup
    backend-state
    assignments
    var)
    [(Some location)
      (match location
        [(or (Register reg) (RegisterPair reg _))
          (compiler-backend-parallel-reg-id-resource reg)]
        [(Spill offset) (compiler-backend-parallel-spill-resource offset)]
        [(Remat _) 0])]
    [(No) (+ 1000000 var)]))

(define (compiler-backend-var-parallel-resource1
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [var : i64]) : i64
  (match (be_operand.compiler-backend-emit-assignment-lookup
    backend-state
    assignments
    var)
    [(Some location)
      (match location
        [(RegisterPair _ second)
          (compiler-backend-parallel-reg-id-resource second)]
        [_ 0])]
    [(No) 0]))

(define (compiler-backend-phi-source-parallel-resource0
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [source : be_state.CompilerBackendPhiSource]) : i64
  (match source
    [(Value value)
      (match value
        [(Var found)
          ;; Materializing an address reads no contents of its nominal home.
          (if (>=
            (be_operand.compiler-backend-forwarded-addr-of-src
              backend-state
              found)
            0)
            0
            (compiler-backend-var-parallel-resource0
              backend-state
              assignments
              found))]
        [_ 0])]
    [(Temp _) 0]))

(define (compiler-backend-phi-source-parallel-resource1
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [source : be_state.CompilerBackendPhiSource]) : i64
  (match source
    [(Value value)
      (match value
        [(Var found)
          (if (>=
            (be_operand.compiler-backend-forwarded-addr-of-src
              backend-state
              found)
            0)
            0
            (compiler-backend-var-parallel-resource1
              backend-state
              assignments
              found))]
        [_ 0])]
    [(Temp _) 0]))

(define (compiler-backend-phi-copy-parallel-edge
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [phi-copy : be_state.CompilerBackendPhiCopy]) : pmove.CompilerParallelMoveEdge
  (match phi-copy
    [(Copy dst source _)
      (ParallelMoveEdge
        dst
        (compiler-backend-var-parallel-resource0 backend-state assignments dst)
        (compiler-backend-var-parallel-resource1 backend-state assignments dst)
        (compiler-backend-phi-source-parallel-resource0
          backend-state
          assignments
          (be_state.compiler-backend-global-shared-view source))
        (compiler-backend-phi-source-parallel-resource1
          backend-state
          assignments
          source))]))

(define (compiler-backend-phi-copy-list-parallel-edges
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [copies : be_state.CompilerBackendPhiCopySeq]
  [index : i64]) : pmove.CompilerParallelMoveEdgeSeq
  (let
    [count : i64 copies.len]
    [edges : pmove.CompilerParallelMoveEdgeSeq
      (pmove.compiler-parallel-move-edge-seq-with-capacity (- count index))]
    (for [cursor (iterator.range index count)]
      (pmove.compiler-parallel-move-edge-push!
        (&mut edges)
        (compiler-backend-phi-copy-parallel-edge
          backend-state
          assignments
          (be_state.compiler-backend-global-array-element-shared-view
            copies.slots
            cursor))))
    edges))

(define (compiler-backend-phi-copy-list-decision
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [copies : be_state.CompilerBackendPhiCopySeq]) : pmove.CompilerParallelMoveDecision
  (let
    [edges : pmove.CompilerParallelMoveEdgeSeq
      (compiler-backend-phi-copy-list-parallel-edges
        backend-state
        assignments
        copies
        0)]
    (pmove.compiler-parallel-move-decision edges edges)))

(define (compiler-backend-phi-copy-list-find-id
  [copies : be_state.CompilerBackendPhiCopySeq]
  [want : i64]) : be_state.CompilerBackendMaybePhiCopy
  (for [i (iterator.range 0 copies.len)]
    (match (be_state.compiler-backend-global-array-element-shared-view
      copies.slots
      i)
      [(Copy dst _ _)
        (when
          (= dst want)
          (return
            (Some
              (be_state.compiler-backend-global-array-element-shared-view
                copies.slots
                i))))]))
  No)

(define (compiler-backend-phi-copy-list-remove-dst
  [copies : be_state.CompilerBackendPhiCopySeq]
  [dst : i64]) : be_state.CompilerBackendPhiCopySeq
  (let
    [out : be_state.CompilerBackendPhiCopySeq
      (be_state.compiler-backend-phi-copy-seq-with-capacity copies.len)]
    (for [i (iterator.range 0 copies.len)]
      (match (be_state.compiler-backend-global-array-element-shared-view
        copies.slots
        i)
        [(Copy found-dst _ _)
          (if (= found-dst dst)
            unit
            (be_state.compiler-backend-phi-copy-push!
              (&mut out)
              (be_state.compiler-backend-global-array-element-shared-view
                copies.slots
                i)))]))
    out))

;; `loc` is the staging location threaded into the Temp this break creates:
;; invalid for the stack, or a canonical register ID for an outermost break.
(define (compiler-backend-phi-source-replace-home
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [source : be_state.CompilerBackendPhiSource]
  [dst : i64]
  [loc : i64]) : be_state.CompilerBackendPhiSource
  (match (& source)
    [(Value value)
      (match value
        [(Var found)
          (if (be_scalar.compiler-backend-value-same-home?
            backend-state
            assignments
            dst
            (Var found))
            (Temp loc)
            source)]
        [_ source])]
    [(Temp _) source]))

(define (compiler-backend-phi-copy-list-replace-source-home
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [copies : be_state.CompilerBackendPhiCopySeq]
  [dst-home-var : i64]
  [loc : i64]) : be_state.CompilerBackendPhiCopySeq
  (let
    [out : be_state.CompilerBackendPhiCopySeq
      (be_state.compiler-backend-phi-copy-seq-with-capacity copies.len)]
    (for [i (iterator.range 0 copies.len)]
      (match (owned_view.compiler-owned-element-view copies.slots i)
        [(Copy dst source ty)
          (be_state.compiler-backend-phi-copy-push!
            (&mut out)
            (Copy
              dst
              (compiler-backend-phi-source-replace-home
                backend-state
                assignments
                source
                dst-home-var
                loc)
              ty))]))
    out))

(define (compiler-backend-phi-source-is-var?
  [source : be_state.CompilerBackendPhiSource]
  [var : i64]) : bool
  (match source
    [(Value value)
      (match value
        [(Var id) (= id var)]
        [_ false])]
    [(Temp _) false]))

(define (compiler-backend-phi-source-replace-var
  [source : be_state.CompilerBackendPhiSource]
  [var : i64]
  [replacement : compiler_ir_types.CompilerIrValue]) : be_state.CompilerBackendPhiSource
  (if (compiler-backend-phi-source-is-var?
    (be_state.compiler-backend-global-shared-view source)
    var)
    (Value replacement)
    source))

(define (compiler-backend-phi-copy-list-has-source-var?
  [copies : be_state.CompilerBackendPhiCopySeq]
  [var : i64]) : bool
  (for [i (iterator.range 0 copies.len)]
    (match (owned_view.compiler-owned-element-view copies.slots i)
      [(Copy _ source _)
        (when (compiler-backend-phi-source-is-var? source var) (return true))]))
  false)

;; #orphan-push: drop copies whose source is homed at their OWN dst home. The
;; build-time filter (leading-phi-copies' phi-same-home? check) guarantees no
;; such copy enters a list, but replace-source-var (the fused Mov+Jump edge)
;; substitutes a NEW source afterwards -- when the substituted source shares the
;; dst's home (coalesced same-value class) the copy is a no-op that SELF-BLOCKS
;; find-unblocked (its own source reads its dst home), mis-triggering the cycle
;; break: the temp save is emitted, the copy itself elides as same-home, and
;; replace-source-home finds no consumer in the remaining list. Re-applying the
;; build-time invariant after substitution removes both the dead temp save and
;; the spurious block. `phi-copy-source-uses-home?` is the exact predicate the
;; blocked check uses, so everything it would self-block is dropped here.
(define (compiler-backend-phi-copy-list-drop-same-home
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [copies : be_state.CompilerBackendPhiCopySeq]) : be_state.CompilerBackendPhiCopySeq
  (let
    [out : be_state.CompilerBackendPhiCopySeq
      (be_state.compiler-backend-phi-copy-seq-with-capacity copies.len)]
    (for [i (iterator.range 0 copies.len)]
      (let
        [phi-copy : be_state.CompilerBackendPhiCopy
          (be_state.compiler-backend-global-array-element-shared-view
            copies.slots
            i)]
        (match (& phi-copy)
          [(Copy dst _ _)
            (if (compiler-backend-phi-copy-source-uses-home?
              backend-state
              assignments
              (be_state.compiler-backend-global-shared-view phi-copy)
              dst)
              unit
              (be_state.compiler-backend-phi-copy-push! (&mut out) phi-copy))])))
    out))

(define (compiler-backend-phi-copy-list-replace-source-var
  [copies : be_state.CompilerBackendPhiCopySeq]
  [var : i64]
  [replacement : compiler_ir_types.CompilerIrValue]) : be_state.CompilerBackendPhiCopySeq
  (let
    [out : be_state.CompilerBackendPhiCopySeq
      (be_state.compiler-backend-phi-copy-seq-with-capacity copies.len)]
    (for [i (iterator.range 0 copies.len)]
      (match (owned_view.compiler-owned-element-view copies.slots i)
        [(Copy dst source ty)
          (be_state.compiler-backend-phi-copy-push!
            (&mut out)
            (Copy
              dst
              (compiler-backend-phi-source-replace-var
                source
                var
                (be_state.compiler-backend-global-shared-view replacement))
              ty))]))
    out))

;; #phi-staged-copy: program point (2 x global instruction index -- the scavenge
;; coordinate) of the FIRST instruction of the phi edge's TARGET block, or -1
;; when no edge scan has established one. The edge scan already walks the block
;; list to find the target block, so accumulating the prefix sum of block
;; instruction counts on the way costs one add per skipped block and lands in
;; exactly the coordinate emit-instr-post-base builds (both walk the same list in
;; the same order, adding the same per-block instruction count).
(define (compiler-backend-function-state-current-phi-target-point
  [backend-state : be_state.CompilerBackendState]) : i64
  (be_state.compiler-backend-function-state-i64
    (be_state.compiler-backend-state-function-state backend-state)
    be_state.compiler-backend-function-i64-current-phi-target-point))

(define (compiler-backend-function-state-set-current-phi-target-point!
  [backend-state : be_state.CompilerBackendState]
  [point : i64]) : unit
  (be_state.compiler-backend-function-state-set-i64!
    (be_state.compiler-backend-state-function-state backend-state)
    be_state.compiler-backend-function-i64-current-phi-target-point
    point))

;; Pooled-register-home bit mask of every destination in the ORIGINAL raw Phi
;; list of the edge being marshalled. -1 (every bit set) is the conservative
;; default: with no list installed nothing can be proven free. Unlike the
;; filtered copy list, the raw list includes same-home Phis whose destination
;; already contains its final value. An already-drained emitted copy likewise
;; leaves a final value in its destination. Allocator occupancy models neither
;; kind of transient edge-marshalling value.
(define (compiler-backend-function-state-current-phi-dst-home-mask
  [backend-state : be_state.CompilerBackendState]) : i64
  (be_state.compiler-backend-function-state-i64
    (be_state.compiler-backend-state-function-state backend-state)
    be_state.compiler-backend-function-i64-current-phi-dst-home-mask))

(define (compiler-backend-function-state-set-current-phi-dst-home-mask!
  [backend-state : be_state.CompilerBackendState]
  [mask : i64]) : unit
  (be_state.compiler-backend-function-state-set-i64!
    (be_state.compiler-backend-state-function-state backend-state)
    be_state.compiler-backend-function-i64-current-phi-dst-home-mask
    mask))

;; #phi-staged-copy: may the spilled-dst phi copy stage through `reg` WITHOUT the
;; pushq/popq bracket? Three obligations, all discharged from state the emitter
;; already holds:
;;   (1) `reg` is a pooled register -- a spelling with no scavenge bit (%rbp,
;;       %rsp) cannot be tested at all and is refused;
;;   (2) `reg` is FREE over the scavenge staging window at this point AND at the
;;       TARGET block's entry. The window query is the same one the scavenge
;;       itself ran, re-asked so an EMERGENCY pick (which returns an OCCUPIED
;;       register plus a pending save) keeps its bracket. The target-entry query
;;       is what catches a value carried around a loop whose next use is the next
;;       iteration's phi: a point-local query at the bottom of the body can fail
;;       to see it, and the header entry point is where it is guaranteed
;;       occupied.
;;
;;       The target-entry query is asked on EVERY edge. Asking it only when
;;       `target <= point`, reading that EMISSION-POINT comparison as "this is
;;       a back edge", holds only while lowering's source order is what the
;;       backend emits. A block layout pass that rotates a loop puts the latch
;;       ABOVE the header, so the genuine back edge runs FORWARD in emission
;;       order (`target > point`) and would take the cheap path, dropping the
;;       bracket on a register holding a loop-carried value. Asking on every
;;       edge is the layout-independent phrasing of the same obligation, and it
;;       loses nothing on a genuine forward edge: that edge's target entry is
;;       covered by the interval of every value live into it (the def dominates
;;       the edge and the use is ahead), so the query answers the same as the
;;       point-local one.
;;   (3) `reg` is not the home of ANY raw Phi destination on this edge, so no
;;       drained copy or filtered same-home Phi has placed its final value there.
;; With all three the value in `reg` at this point is dead, so the bracket saves
;; and restores a dead value. Dropping it leaves `movq SRC,%rX` / `movq %rX,DST`:
;; two instructions and two memory ops in a load->store chain, strictly fewer
;; memory operations AND a shorter dependency chain than the bracketed four.
(define (compiler-backend-phi-staged-copy-proven?
  [backend-state : be_state.CompilerBackendState]
  [reg : (& reg str)]) : bool
  (let
    [function-state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state backend-state)]
    [bit : i64 (be_operand.compiler-backend-scavenge-reg-bit reg)]
    [point : i64
      (be_state.compiler-backend-function-state-emission-point function-state)]
    [target : i64
      (compiler-backend-function-state-current-phi-target-point backend-state)]
    (and
      (not (= bit 0))
      (>= target 0)
      (=
        (bit-and
          (compiler-backend-function-state-current-phi-dst-home-mask
            backend-state)
          bit)
        0)
      (=
        (bit-and
          (be_operand.compiler-backend-scavenge-occupied-mask-over-range
            function-state
            point
            (+ point be_operand.compiler-backend-scavenge-staging-window))
          bit)
        0)
      (=
        (bit-and
          (be_operand.compiler-backend-scavenge-occupied-mask-at-point
            function-state
            target)
          bit)
        0))))

(define (compiler-backend-phi-temp-home-operand
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [var-id : i64]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (>=
    (be_operand.compiler-backend-forwarded-addr-of-src backend-state var-id)
    0)
    (Err
      (box
        (compiler_diagnostic.compiler-diagnostic-at-start
          ""
          "backend: phi temp save of forwarded addr-of dst (unexpected)")))
    (match (be_operand.compiler-backend-emit-assignment-lookup
      backend-state
      assignments
      var-id)
      [(Some location)
        (match location
          [(or (Register home) (RegisterPair home _))
            (Ok (compiler_abi.compiler-abi-register-spelling home))]
          [(Spill offset)
            (Ok
              (be_operand.compiler-backend-frame-offset-with-backend-state
                backend-state
                offset))]
          [(Remat _)
            (Err
              (box
                (compiler_diagnostic.compiler-diagnostic-at-start
                  ""
                  "backend: phi temp save of rematerialised dst (unexpected)")))])]
      [(No)
        (Ok
          (be_operand.compiler-backend-slot-with-backend-state
            backend-state
            var-id))])))

(define (compiler-backend-emit-phi-temp-slot-move-reg
  [operand : String]
  [mnemonic : String]
  [slot-index : i64]
  [restore? : bool]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [slot : String
      (be_scalar.compiler-backend-cycle-temp-slot-with-backend-state
        backend-state
        slot-index)]
    (if restore?
      (str_cat.str-cat "    " mnemonic " " slot ", " operand "\n")
      (str_cat.str-cat "    " mnemonic " " operand ", " slot "\n"))))

(define (compiler-backend-phi-temp-gp-scratch
  [backend-state : be_state.CompilerBackendState]) : String
  (be_operand.compiler-backend-scavenge-reg-here
    (be_operand.compiler-backend-one-exclude "%rbp")
    1
    "%r10"
    backend-state))

(define (compiler-backend-emit-phi-temp-slot-move-gp
  [operand : String]
  [slot-index : i64]
  [restore? : bool]
  [backend-state : be_state.CompilerBackendState]) : String
  (if (be_operand.compiler-backend-peephole-register-operand? operand)
    (compiler-backend-emit-phi-temp-slot-move-reg
      operand
      "movq"
      slot-index
      restore?
      backend-state)
    (let
      [scratch : String (compiler-backend-phi-temp-gp-scratch backend-state)]
      [slot : String
        (be_scalar.compiler-backend-cycle-temp-slot-with-backend-state
          backend-state
          slot-index)]
      (be_scalar.compiler-backend-emergency-wrap
        (if restore?
          (str_cat.str-cat
            "    movq "
            slot
            ", "
            scratch
            "\n    movq "
            scratch
            ", "
            operand
            "\n")
          (str_cat.str-cat
            "    movq "
            operand
            ", "
            scratch
            "\n    movq "
            scratch
            ", "
            slot
            "\n"))
        backend-state))))

(define (compiler-backend-phi-float-temp-scratch
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [no-exclude : (__tl_dyn-array String) (__tl_make-array String 0)]
    (be_operand.compiler-backend-scavenge-xmm-reg
      -1
      no-exclude
      0
      "%xmm2"
      backend-state)))

(define (compiler-backend-emit-phi-float-temp-move
  [operand : String]
  [ty : compiler_ast_types.AstType]
  [restore? : bool]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [mnemonic : String (be_operand.compiler-backend-float-move ty)]
    (if (be_operand.compiler-backend-peephole-register-operand? operand)
      (compiler-backend-emit-phi-temp-slot-move-reg
        operand
        mnemonic
        0
        restore?
        backend-state)
      (let
        [scratch : String
          (compiler-backend-phi-float-temp-scratch backend-state)]
        [slot : String
          (be_scalar.compiler-backend-cycle-temp-slot-with-backend-state
            backend-state
            0)]
        (if restore?
          (str_cat.str-cat
            "    "
            mnemonic
            " "
            slot
            ", "
            scratch
            "\n    "
            mnemonic
            " "
            scratch
            ", "
            operand
            "\n")
          (str_cat.str-cat
            "    "
            mnemonic
            " "
            operand
            ", "
            scratch
            "\n    "
            mnemonic
            " "
            scratch
            ", "
            slot
            "\n"))))))

(define (compiler-backend-emit-phi-group-word-move
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [var : i64]
  [index : i64]
  [vars : i64]
  [ty : compiler_ast_types.AstType]
  [program-index : be_state.CompilerBackendProgramIndex]
  [restore? : bool]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [operand
      (try
        (be_scalar.compiler-backend-group-word-operand-with-backend-state
          assignments
          var
          index
          vars
          backend-state))]
    (Ok
      (if (be_facts.compiler-backend-group-word-sse?
        type-segment-bases
        program-index
        ty
        index)
        (if (be_operand.compiler-backend-peephole-register-operand? operand)
          (compiler-backend-emit-phi-temp-slot-move-reg
            operand
            "movq"
            index
            restore?
            backend-state)
          (compiler-backend-emit-phi-temp-slot-move-gp
            operand
            index
            restore?
            backend-state))
        (compiler-backend-emit-phi-temp-slot-move-gp
          operand
          index
          restore?
          backend-state)))))

(define (compiler-backend-emit-phi-temp-save
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [ty : compiler_ast_types.AstType]
  [program-index : be_state.CompilerBackendProgramIndex]
  [vars : i64]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (or
    (be_facts.compiler-backend-group-type? type-segment-bases program-index ty)
    (be_facts.compiler-backend-group-var? backend-state dst))
    (let
      [w0
        (try
          (compiler-backend-emit-phi-group-word-move
            type-segment-bases
            assignments
            dst
            0
            vars
            (be_state.compiler-backend-global-shared-view ty)
            program-index
            false
            backend-state))]
      [w1
        (try
          (compiler-backend-emit-phi-group-word-move
            type-segment-bases
            assignments
            dst
            1
            vars
            ty
            program-index
            false
            backend-state))]
      (Ok (str_cat.str-cat w0 w1)))
    (let
      [operand
        (try
          (compiler-backend-phi-temp-home-operand assignments dst backend-state))]
      (Ok
        (if (be_operand.compiler-backend-float-type? ty)
          (compiler-backend-emit-phi-float-temp-move
            operand
            ty
            false
            backend-state)
          (compiler-backend-emit-phi-temp-slot-move-gp
            operand
            0
            false
            backend-state))))))

;; Restore reverses the word order (word1 then word0), using fixed frame slots
;; rather than %rsp pushes.
(define (compiler-backend-emit-phi-temp-restore
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [ty : compiler_ast_types.AstType]
  [program-index : be_state.CompilerBackendProgramIndex]
  [vars : i64]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (or
    (be_facts.compiler-backend-group-type? type-segment-bases program-index ty)
    (be_facts.compiler-backend-group-var? backend-state dst))
    (let
      [w1
        (try
          (compiler-backend-emit-phi-group-word-move
            type-segment-bases
            assignments
            dst
            1
            vars
            (be_state.compiler-backend-global-shared-view ty)
            program-index
            true
            backend-state))]
      [w0
        (try
          (compiler-backend-emit-phi-group-word-move
            type-segment-bases
            assignments
            dst
            0
            vars
            ty
            program-index
            true
            backend-state))]
      (Ok (str_cat.str-cat w1 w0)))
    (let
      [operand
        (try
          (compiler-backend-phi-temp-home-operand assignments dst backend-state))]
      (Ok
        (if (be_operand.compiler-backend-float-type? ty)
          (compiler-backend-emit-phi-float-temp-move
            operand
            ty
            true
            backend-state)
          (compiler-backend-emit-phi-temp-slot-move-gp
            operand
            0
            true
            backend-state))))))

;; #phi-temp-reg save/restore: stage the cycle-entry dst's old value in a free GP
;; register instead of on the stack. `reg` is guaranteed (by phi-temp-pick-reg)
;; to home no live value and to be no copy's dst-home, so the bracketed
;; `movq dst-home, reg` ... `movq reg, consumer-home` is sound across the cycle.
(define (compiler-backend-emit-phi-temp-save-reg
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [reg : (& reg str)]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [operand
      (try
        (compiler-backend-phi-temp-home-operand assignments dst backend-state))]
    (Ok (str_cat.str-cat "    movq " operand ", " reg "\n"))))

(define (compiler-backend-emit-phi-temp-restore-reg
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [reg : String]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [operand
      (try
        (compiler-backend-phi-temp-home-operand assignments dst backend-state))]
    (Ok (str_cat.str-cat "    movq " reg ", " operand "\n"))))

(define (compiler-backend-emit-phi-temp-restore-xmm
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [reg : String]
  [ty : compiler_ast_types.AstType]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [operand
      (try
        (compiler-backend-phi-temp-home-operand assignments dst backend-state))]
    (Ok
      (str_cat.str-cat
        "    "
        (be_operand.compiler-backend-float-move ty)
        " "
        reg
        ", "
        operand
        "\n"))))

;; OR the pooled-register-home bits of one phi destination into a mask. A spill
;; contributes 0. Register pairs contribute BOTH physical homes; a later scalar
;; stage must not clobber either half of an already-placed group value.
(define (compiler-backend-phi-dst-home-mask-for-var
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]) : i64
  (match (be_operand.compiler-backend-emit-assignment-lookup
    backend-state
    assignments
    dst)
    [(Some location)
      (match location
        [(Register home)
          (be_operand.compiler-backend-scavenge-reg-bit
            (compiler_abi.compiler-abi-register-spelling home))]
        [(RegisterPair lo hi)
          (bit-or
            (be_operand.compiler-backend-scavenge-reg-bit
              (compiler_abi.compiler-abi-register-spelling lo))
            (be_operand.compiler-backend-scavenge-reg-bit
              (compiler_abi.compiler-abi-register-spelling hi)))]
        [_ 0])]
    [(No) 0]))

;; OR the pooled-register-home bit of every copy's dst into a mask. A spilled dst
;; contributes 0; every register-homed dst, including ABI-special %rax/%rsi/%rdi,
;; contributes its ordinary scavenge bit and cannot be picked as the temp.
(define (compiler-backend-phi-copy-list-dst-home-mask
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [copies : be_state.CompilerBackendPhiCopySeq]) : i64
  (let
    [mask : i64 0]
    (for [i (iterator.range 0 copies.len)]
      (match (owned_view.compiler-owned-element-view copies.slots i)
        [(Copy dst _ _)
          (set!
            mask
            (bit-or
              mask
              (be_operand.compiler-backend-scavenge-reg-bit
                (be_scalar.compiler-backend-var-register-home
                  backend-state
                  assignments
                  dst))))]))
    mask))

;; Compute the destination-home mask from every leading raw Phi, including
;; same-home phis that leading-phi-copies-seq-from filters out before
;; marshalling. The instruction sequence is shared by list and dense blocks and
;; by ordinary and fused Mov+Jump edges.
(define (compiler-backend-phi-leading-dst-home-mask-seq-from
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [instrs : compiler_ir_types.CompilerIrInstrSeq]
  [index : i64]) : i64
  (let
    [mask : i64 0]
    [i : i64 index]
    [n : i64 (compiler_ir_types.compiler-ir-instr-seq-count instrs)]
    (while (< i n)
      (match (compiler_ir_types.compiler-ir-instr-seq-borrow instrs i)
        [(Phi dst _ _)
          (set!
            mask
            (bit-or
              mask
              (compiler-backend-phi-dst-home-mask-for-var
                backend-state
                assignments
                dst)))
          (+= i 1)]
        [_ (set! i n)]))
    mask))

(define (compiler-backend-phi-leading-dst-home-mask-seq
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : i64
  (compiler-backend-phi-leading-dst-home-mask-seq-from
    backend-state
    assignments
    instrs
    0))

(define (compiler-backend-phi-temp-pick-reg-iter
  [function-state : be_state.CompilerBackendFunctionState]
  [occupied-mask : i64]
  [exclude-mask : i64]
  [plan-mask : i64]
  [cands : (& cands (__tl_dyn-array i64))]
  [n : i64]) : i64
  (for [i (iterator.range 0 n)]
    (when
      (be_operand.compiler-backend-scavenge-candidate-ok?
        function-state
        occupied-mask
        exclude-mask
        plan-mask
        (array-ref cands i))
      (return (array-ref cands i))))
  compiler_abi.compiler-reg-id-invalid)

;; Scavenge a GP register usable as the cycle-break Temp staging slot, or "" if
;; none. candidate-ok? certifies the register is free in the occupancy mask at the
;; phi-copy emit point (homes no live-through value) and is callee-save-sound; the
;; dst-home mask additionally rules out any register a copy would overwrite. This
;; is the same occupancy query the float phi-temp scratch already uses here, so
;; the emit position is a valid scavenge point.
(define (compiler-backend-phi-temp-pick-reg
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [copies : be_state.CompilerBackendPhiCopySeq]
  [all : be_state.CompilerBackendPhiCopySeq]) : String
  (let
    [function-state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state backend-state)]
    [point : i64
      (be_state.compiler-backend-function-state-emission-point function-state)]
    [occupied-mask : i64
      (be_operand.compiler-backend-scavenge-occupied-mask-at-point
        function-state
        point)]
    ;; The cycle-break Temp must avoid every register the phi marshalling still
    ;; needs: the dst homes of the REMAINING copies, AND every dst home of the
    ;; ORIGINAL copy list. An already-emitted (drained) copy has placed a final
    ;; phi value into its dst register (live to the merge block entry), but that
    ;; dst is no longer in `copies`, so excluding only `copies` could pick it as
    ;; the Temp and clobber a placed phi value -- the same hazard as in the
    ;; arg-move cycle break. The occupancy mask reflects the allocation, not
    ;; these transient marshalling values.
    [exclude-mask : i64
      (bit-or
        (compiler-backend-phi-copy-list-dst-home-mask
          backend-state
          assignments
          copies)
        (compiler-backend-phi-copy-list-dst-home-mask
          backend-state
          assignments
          all))]
    [cands : (__tl_dyn-array i64)
      (be_state.compiler-backend-i64-array-shared-view
        (& be_operand.compiler-backend-scavenge-candidate-pool))]
    [reg-id : i64
      (compiler-backend-phi-temp-pick-reg-iter
        function-state
        occupied-mask
        exclude-mask
        (be_state.compiler-backend-function-scratch-i64
          function-state
          be_state.compiler-backend-scratch-i64-scavenge-plan-reg-mask)
        cands
        (array-length cands))]
    [reg : String (compiler_abi.compiler-abi-register-spelling reg-id)]
    reg))

;; A copy is "register-swappable" when emitting it scavenges NO register: it is a
;; scalar-int copy (no float/group word staging) whose dst is register-homed and
;; whose source is a register-homed var. emit-phi-var-source-direct's dst-register
;; branch then emits a single direct `movq src, dst` with no scratch. A break list
;; in which EVERY copy is register-swappable can stage its Temp in a scavenged
;; register: nothing in the cycle body ever touches that register, so it survives
;; intact from the save `movq` to the consumer's restore `movq` -- exactly as the
;; reserved frame temp did. Spilled (mem->mem), float, group, immediate, or remat
;; copies can scavenge a bounce register and so keep using the frame temp.
(define (compiler-backend-phi-copy-reg-swappable?
  [backend-state : be_state.CompilerBackendState]
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [phi-copy : be_state.CompilerBackendPhiCopy]
  [program-index : be_state.CompilerBackendProgramIndex]) : bool
  (match phi-copy
    [(Copy dst source ty)
      (and
        (not (be_operand.compiler-backend-float-type? ty))
        (not
          (or
            (be_facts.compiler-backend-group-type?
              type-segment-bases
              program-index
              ty)
            (be_facts.compiler-backend-group-var?
              program-index.backend-state
              dst)))
        (not
          (string.eq
            (be_scalar.compiler-backend-var-register-home
              backend-state
              assignments
              dst)
            ""))
        (match source
          [(Value value)
            (match value
              [(Var v)
                (not
                  (string.eq
                    (be_scalar.compiler-backend-var-register-home
                      backend-state
                      assignments
                      v)
                    ""))]
              [_ false])]
          [(Temp _) true]))]))

(define (compiler-backend-phi-copy-list-reg-swappable?
  [backend-state : be_state.CompilerBackendState]
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [copies : be_state.CompilerBackendPhiCopySeq]
  [program-index : be_state.CompilerBackendProgramIndex]) : bool
  (for [i (iterator.range 0 copies.len)]
    (unless
      (compiler-backend-phi-copy-reg-swappable?
        backend-state
        type-segment-bases
        assignments
        (be_state.compiler-backend-global-array-element-shared-view
          copies.slots
          i)
        program-index)
      (return false)))
  true)

(define (compiler-backend-emit-phi-source-load-store
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [value : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [program-index : be_state.CompilerBackendProgramIndex]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [dst-home : String
      (be_scalar.compiler-backend-var-register-home
        backend-state
        assignments
        dst)]
    [src-home : String
      (if (be_operand.compiler-backend-float-type? ty)
        (be_scalar.compiler-backend-float-value-register
          backend-state
          assignments
          value)
        (be_operand.compiler-backend-value-scalar-register
          backend-state
          assignments
          value))]
    [exclude : (__tl_dyn-array String)
      (if (string.eq src-home "")
        (__tl_make-array String 0)
        (be_operand.compiler-backend-one-exclude
          (be_state.compiler-backend-global-shared-view src-home)))]
    [exclude-n : i64
      (if (string.eq src-home "")
        0
        1)]
    [reg : String
      (if (string.eq dst-home "")
        (if (be_operand.compiler-backend-float-type? ty)
          (be_operand.compiler-backend-scavenge-xmm-reg
            dst
            exclude
            exclude-n
            "%xmm2"
            backend-state)
          (be_operand.compiler-backend-scavenge-reg
            dst
            exclude
            exclude-n
            "%r8"
            backend-state))
        (owned_view.compiler-owned-shared-view dst-home))]
    ;; The scavenged staging register may host a value live through the edge even
    ;; when the point-local occupancy mask reads it free. Back edges hit this
    ;; when a loop-carried value's next use is in the next iteration; a drained
    ;; copy of this same edge may also have placed a phi value in it, which the
    ;; occupancy mask (a model of the ALLOCATION, not of edge marshalling) never
    ;; shows. Bracket spilled-dst scalar GP phi copies so the occupant survives
    ;; the edge marshalling. Homes are frame-relative at emission, so the
    ;; transient %rsp shift cannot skew the operands, and the FPO audit tracks
    ;; push/pop deltas.
    ;;
    ;; A function-wide "is this register a plan home at all?" test does NOT
    ;; un-bracket this: the allocator homes short-lived temporaries in %r8 (the
    ;; preferred staging fallback) in essentially every function that also has a
    ;; spilled phi dst, so the mask is set even though nothing is live in %r8
    ;; across the edge, and practically no site un-brackets that way.
    ;; #phi-staged-copy discharges the real obligations instead -- per-EDGE
    ;; occupancy (point-local, unioned with the TARGET block entry, which is
    ;; asked on every edge because no emission-order comparison survives a
    ;; block layout pass) plus the edge's dst-home mask -- and drops the bracket
    ;; when they hold, leaving the 2-instruction register-staged copy. See
    ;; compiler-backend-phi-staged-copy-proven?.
    [load
      (try
        (be_scalar.compiler-backend-emit-load-typed-value-to-reg
          type-segment-bases
          assignments
          value
          ty
          (be_state.compiler-backend-global-shared-view reg)
          program-index))]
    (Ok
      (if (string.eq dst-home "")
        (if (be_operand.compiler-backend-float-type? ty)
          (let
            [copy : String
              (str_cat.str-cat
                load
                (be_operand.compiler-backend-emit-store-typed-var
                  assignments
                  dst
                  (be_state.compiler-backend-global-shared-view reg)
                  ty
                  backend-state))]
            (if (or
              (string.eq load "")
              (compiler-backend-phi-staged-copy-proven? backend-state reg))
              copy
              (be_scalar.compiler-backend-phi-xmm-local-preserve-asm
                reg
                copy
                backend-state)))
          ;; P34 #phi-empty-load: an EMPTY load means the loader elided a
          ;; same-register move -- the source value is ALREADY in `reg`. The
          ;; pair is then just the store, which reads `reg` and writes
          ;; memory: nothing between the bracket's push and pop can modify
          ;; `reg`, so there is no occupant to preserve and the bracket saves
          ;; and restores the very value it is storing. Dropping it removes
          ;; two instructions AND two memory accesses; the remaining
          ;; (clobbering) loads keep the bracket for the reason above.
          (if (or
            (string.eq load "")
            (compiler-backend-phi-staged-copy-proven? backend-state reg))
            (str_cat.str-cat
              load
              (be_operand.compiler-backend-emit-store-typed-var
                assignments
                dst
                reg
                ty
                backend-state))
            (let
              [copy : String
                (str_cat.str-cat
                  load
                  (be_operand.compiler-backend-emit-store-typed-var
                    assignments
                    dst
                    (be_state.compiler-backend-global-shared-view reg)
                    ty
                    backend-state))]
              (str_cat.str-cat "    pushq " reg "\n" copy "    popq " reg "\n"))))
        load))))

(define (compiler-backend-emit-phi-var-source-direct
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [src-id : i64]
  [backend-state : be_state.CompilerBackendState]) : be_state.CompilerBackendMaybeAsm
  (if (>=
    (be_operand.compiler-backend-forwarded-addr-of-src backend-state src-id)
    0)
    (No)
    (match (be_operand.compiler-backend-emit-assignment-lookup
      backend-state
      assignments
      dst)
      [(Some dst-location)
        (match dst-location
          [(Register dst-home)
            (match (be_operand.compiler-backend-emit-assignment-lookup
              backend-state
              assignments
              src-id)
              [(Some src-location)
                (match src-location
                  [(Register src-home)
                    (Some
                      (if (= src-home dst-home)
                        ""
                        (str_cat.str-cat
                          "    movq "
                          (compiler_abi.compiler-abi-register-spelling src-home)
                          ", "
                          (compiler_abi.compiler-abi-register-spelling dst-home)
                          "\n")))]
                  [(Spill src-offset)
                    (Some
                      (str_cat.str-cat
                        "    movq "
                        (be_operand.compiler-backend-frame-offset-with-backend-state
                          backend-state
                          src-offset)
                        ", "
                        (compiler_abi.compiler-abi-register-spelling dst-home)
                        "\n"))]
                  ;; Remat src: no slot/register to copy from -> defer to the
                  ;; load-store fallback, which recomputes it.
                  [(or (RegisterPair _ _) (Remat _)) (No)])]
              [(No)
                (Some
                  (str_cat.str-cat
                    "    movq "
                    (be_operand.compiler-backend-slot-with-backend-state
                      backend-state
                      src-id)
                    ", "
                    (compiler_abi.compiler-abi-register-spelling dst-home)
                    "\n"))])]
          [(RegisterPair dst-lo dst-hi)
            (match (be_operand.compiler-backend-emit-assignment-lookup
              backend-state
              assignments
              src-id)
              [(Some src-location)
                (match src-location
                  [(RegisterPair src-lo src-hi)
                    ;; GAP2b overlap guard: lo is copied FIRST, so an emitted
                    ;; lo copy whose dst is the src pair's HI half would
                    ;; clobber it before the hi copy reads it -- fall back to
                    ;; the rax:rdx staging path (both reads before both
                    ;; writes, swap-safe). dst-hi == src-lo is fine: src-lo
                    ;; is read by the first copy before the second writes.
                    (if (and (not (= src-lo dst-lo)) (= dst-lo src-hi))
                      (No)
                      (Some
                        (let
                          [lo-move : String
                            (if (= src-lo dst-lo)
                              ""
                              (str_cat.str-cat
                                "    movq "
                                (compiler_abi.compiler-abi-register-spelling
                                  src-lo)
                                ", "
                                (compiler_abi.compiler-abi-register-spelling
                                  dst-lo)
                                "\n"))]
                          [hi-move : String
                            (if (= src-hi dst-hi)
                              ""
                              (str_cat.str-cat
                                "    movq "
                                (compiler_abi.compiler-abi-register-spelling
                                  src-hi)
                                ", "
                                (compiler_abi.compiler-abi-register-spelling
                                  dst-hi)
                                "\n"))]
                          (str_cat.str-cat lo-move hi-move))))]
                  [_ (No)])]
              [(No) (No)])]
          [(Remat _) (No)]
          [(Spill dst-offset)
            (match (be_operand.compiler-backend-emit-assignment-lookup
              backend-state
              assignments
              src-id)
              [(Some src-location)
                (match src-location
                  [(Register src-home)
                    (Some
                      (str_cat.str-cat
                        "    movq "
                        (compiler_abi.compiler-abi-register-spelling src-home)
                        ", "
                        (be_operand.compiler-backend-frame-offset-with-backend-state
                          backend-state
                          dst-offset)
                        "\n"))]
                  [_ (No)])]
              [(No) (No)])])]
      [(No)
        (match (be_operand.compiler-backend-emit-assignment-lookup
          backend-state
          assignments
          src-id)
          [(Some src-location)
            (match src-location
              [(Register src-home)
                (Some
                  (str_cat.str-cat
                    "    movq "
                    (compiler_abi.compiler-abi-register-spelling src-home)
                    ", "
                    (be_operand.compiler-backend-slot-with-backend-state
                      backend-state
                      dst)
                    "\n"))]
              [_ (No)])]
          [(No) (No)])])))

(define (compiler-backend-emit-phi-source-immediate-or-load-store
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [value : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [program-index : be_state.CompilerBackendProgramIndex]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (match (be_scalar.compiler-backend-emit-store-immediate-to-var-home
    assignments
    dst
    (be_state.compiler-backend-global-shared-view value)
    backend-state)
    [(Some asm) (Ok asm)]
    [(No)
      (compiler-backend-emit-phi-source-load-store
        type-segment-bases
        assignments
        dst
        value
        ty
        program-index
        backend-state)]))

(define (compiler-backend-emit-phi-source-scalar-to-var
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [value : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [program-index : be_state.CompilerBackendProgramIndex]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (be_operand.compiler-backend-float-type? ty)
    (compiler-backend-emit-phi-source-load-store
      type-segment-bases
      assignments
      dst
      value
      ty
      program-index
      backend-state)
    (match (& value)
      [(Var src-id)
        (match (compiler-backend-emit-phi-var-source-direct
          assignments
          dst
          src-id
          backend-state)
          [(Some asm) (Ok asm)]
          [(No)
            (compiler-backend-emit-phi-source-immediate-or-load-store
              type-segment-bases
              assignments
              dst
              value
              ty
              program-index
              backend-state)])]
      [_
        (compiler-backend-emit-phi-source-immediate-or-load-store
          type-segment-bases
          assignments
          dst
          value
          ty
          program-index
          backend-state)])))

(define (compiler-backend-emit-phi-source-to-var
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [source : be_state.CompilerBackendPhiSource]
  [ty : compiler_ast_types.AstType]
  [program-index : be_state.CompilerBackendProgramIndex]
  [vars : i64]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (match source
    [(Temp loc)
      (if (= loc compiler_abi.compiler-reg-id-invalid)
        (compiler-backend-emit-phi-temp-restore
          type-segment-bases
          assignments
          dst
          ty
          program-index
          vars
          backend-state)
        (let
          [reg : String (compiler_abi.compiler-abi-register-spelling loc)]
          (if (be_operand.compiler-backend-float-type? ty)
            (compiler-backend-emit-phi-temp-restore-xmm
              assignments
              dst
              reg
              ty
              program-index.backend-state)
            (compiler-backend-emit-phi-temp-restore-reg
              assignments
              dst
              reg
              program-index.backend-state))))]
    [(Value value)
      (if (compiler-backend-phi-same-home?
        backend-state
        assignments
        dst
        (be_state.compiler-backend-global-shared-view value))
        (Ok "")
        ;; A register-group phi value carries two words. Keep the direct-home
        ;; fast path, then use the same non-ABI copy path as an ordinary Mov.
        (if (be_facts.compiler-backend-copy-group?
          type-segment-bases
          program-index
          (be_state.compiler-backend-global-shared-view ty)
          dst
          (be_state.compiler-backend-global-shared-view value))
          (match (& value)
            [(Var src-id)
              (match (compiler-backend-emit-phi-var-source-direct
                assignments
                dst
                src-id
                backend-state)
                [(Some asm) (Ok asm)]
                [(No)
                  (be_scalar.compiler-backend-emit-group-copy
                    type-segment-bases
                    assignments
                    (& (Var dst))
                    value
                    vars
                    ty
                    program-index
                    backend-state)])]
            [_
              (be_scalar.compiler-backend-emit-group-copy
                type-segment-bases
                assignments
                (& (Var dst))
                value
                vars
                ty
                program-index
                backend-state)])
          (compiler-backend-emit-phi-source-scalar-to-var
            type-segment-bases
            assignments
            dst
            value
            ty
            program-index
            backend-state)))]))

(define (compiler-backend-emit-phi-copy-item
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [phi-copy : be_state.CompilerBackendPhiCopy]
  [program-index : be_state.CompilerBackendProgramIndex]
  [vars : i64]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (match phi-copy
    [(Copy dst source ty)
      (compiler-backend-emit-phi-source-to-var
        type-segment-bases
        assignments
        dst
        source
        ty
        program-index
        vars
        backend-state)]))

;; `outer-active` is true once an outer register-or-stack cycle break is in
;; progress, gating nested breaks to the stack (see #phi-temp-reg). The unblocked
;; drain threads it through unchanged (a save may still be outstanding); each
;; break sets it true for the rest of the edge.
(define (compiler-backend-emit-phi-copy-list
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [copies : be_state.CompilerBackendPhiCopySeq]
  [dst-home-mask : i64]
  [program-index : be_state.CompilerBackendProgramIndex]
  [vars : i64]
  [outer-active : bool]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  ;; #phi-staged-copy: install the ORIGINAL raw-Phi destination-home mask once
  ;; at the single entry to marshalling recursion. It includes same-home Phis
  ;; filtered from `copies`; the recursion re-enters -with-all, never here.
  (compiler-backend-function-state-set-current-phi-dst-home-mask!
    backend-state
    dst-home-mask)
  (compiler-backend-emit-phi-copy-list-with-all
    type-segment-bases
    assignments
    (be_state.compiler-backend-global-shared-view copies)
    copies
    program-index
    vars
    outer-active
    backend-state))

;; `all` is the ORIGINAL (top-level) phi-copy list, carried unchanged through the
;; recursion so the cycle-break Temp pick can exclude every dst register of the
;; whole marshalling -- including those of already-emitted (drained) copies, which
;; still hold placed phi values that must survive to the merge block entry.
(define (compiler-backend-emit-phi-copy-list-with-all
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [copies : be_state.CompilerBackendPhiCopySeq]
  [all : be_state.CompilerBackendPhiCopySeq]
  [program-index : be_state.CompilerBackendProgramIndex]
  [vars : i64]
  [outer-active : bool]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (match (compiler-backend-phi-copy-list-decision
    backend-state
    assignments
    (be_state.compiler-backend-global-shared-view copies))
    [(CompilerParallelMoveDone) (Ok "")]
    [(CompilerParallelMoveUnblocked copy-id)
      (match (compiler-backend-phi-copy-list-find-id
        (be_state.compiler-backend-global-shared-view copies)
        copy-id)
        [(Some phi-copy)
          (match (& phi-copy)
            [(Copy dst _ _)
              (let
                [head
                  (try
                    (compiler-backend-emit-phi-copy-item
                      type-segment-bases
                      assignments
                      phi-copy
                      program-index
                      vars
                      backend-state))]
                [tail
                  (try
                    (compiler-backend-emit-phi-copy-list-with-all
                      type-segment-bases
                      assignments
                      (compiler-backend-phi-copy-list-remove-dst copies dst)
                      all
                      program-index
                      vars
                      outer-active
                      backend-state))]
                (Ok (str_cat.str-cat head tail)))])]
        [(No) (compiler-backend-parallel-move-missing "phi" copy-id)])]
    [(CompilerParallelMoveCycle copy-id)
      (match (compiler-backend-phi-copy-list-find-id
        (be_state.compiler-backend-global-shared-view copies)
        copy-id)
        [(Some phi-copy)
          (match phi-copy
            [(Copy dst source ty)
              ;; Only the OUTERMOST break may use an allocator-owned register.
              ;; Every copy must be a direct move in the same bank, so no cycle
              ;; move can scavenge a scratch that clobbers the outstanding Temp.
              ;; Nested breaks and spill/group/immediate shapes stay on the
              ;; untouchable frame slot.
              (let
                [reg : String
                  (if (and
                    (not outer-active)
                    (compiler-backend-phi-copy-list-reg-swappable?
                      backend-state
                      type-segment-bases
                      assignments
                      (be_state.compiler-backend-global-shared-view copies)
                      program-index))
                    (compiler-backend-phi-temp-pick-reg
                      backend-state
                      assignments
                      (be_state.compiler-backend-global-shared-view copies)
                      (be_state.compiler-backend-global-shared-view all))
                    "")]
                [save
                  (try
                    (if (string.eq reg "")
                      (compiler-backend-emit-phi-temp-save
                        type-segment-bases
                        assignments
                        dst
                        (be_state.compiler-backend-global-shared-view ty)
                        program-index
                        vars
                        backend-state)
                      (compiler-backend-emit-phi-temp-save-reg
                        assignments
                        dst
                        reg
                        backend-state)))]
                [head
                  (try
                    (compiler-backend-emit-phi-source-to-var
                      type-segment-bases
                      assignments
                      dst
                      source
                      ty
                      program-index
                      vars
                      backend-state))]
                [tail
                  (try
                    (compiler-backend-emit-phi-copy-list-with-all
                      type-segment-bases
                      assignments
                      (compiler-backend-phi-copy-list-replace-source-home
                        backend-state
                        assignments
                        (compiler-backend-phi-copy-list-remove-dst copies dst)
                        dst
                        (compiler_abi.compiler-abi-register-id-from-spelling
                          reg))
                      all
                      program-index
                      vars
                      true
                      backend-state))]
                (Ok (str_cat.str-cat save head tail)))])]
        [(No) (compiler-backend-parallel-move-missing "phi" copy-id)])]))

(define (compiler-backend-leading-phi-copies-seq-from
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [instrs : compiler_ir_types.CompilerIrInstrSeq]
  [index : i64]
  [from-label : i64]) : be_state.ResultBackendPhiCopies
  (let
    [out : be_state.CompilerBackendPhiCopySeq
      (be_state.compiler-backend-phi-copy-seq-with-capacity 0)]
    [i : i64 index]
    [n : i64 (compiler_ir_types.compiler-ir-instr-seq-count instrs)]
    [message : String ""]
    [failed : bool false]
    (while (< i n)
      (match (compiler_ir_types.compiler-ir-instr-seq-ref instrs i)
        [(Phi dst inputs ty)
          (match (be_facts.compiler-backend-phi-input-value inputs from-label)
            [(Ok value)
              (if (compiler-backend-phi-same-home?
                backend-state
                assignments
                dst
                (be_state.compiler-backend-global-shared-view value))
                unit
                (be_state.compiler-backend-phi-copy-push!
                  (&mut out)
                  (Copy dst (Value value) ty)))
              (+= i 1)]
            [(Err text)
              (set! failed true)
              (set! message text)
              (set! i n)])]
        [_ (set! i n)]))
    (if failed
      (Err message)
      (Ok out))))

(define (compiler-backend-leading-phi-copies-seq
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [instrs : compiler_ir_types.CompilerIrInstrSeq]
  [from-label : i64]) : be_state.ResultBackendPhiCopies
  (compiler-backend-leading-phi-copies-seq-from
    backend-state
    assignments
    instrs
    0
    from-label))

(define (compiler-backend-emit-leading-phi-copies
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [instrs : compiler_ir_types.CompilerIrInstrSeq]
  [from-label : i64]
  [program-index : be_state.CompilerBackendProgramIndex]
  [vars : i64]) : be_state.ResultCompilerBackend
  (match (compiler-backend-leading-phi-copies-seq
    program-index.backend-state
    assignments
    (be_state.compiler-backend-global-shared-view instrs)
    from-label)
    [(Ok copies)
      (compiler-backend-emit-phi-copy-list
        type-segment-bases
        assignments
        copies
        (compiler-backend-phi-leading-dst-home-mask-seq
          program-index.backend-state
          assignments
          instrs)
        program-index
        vars
        false
        program-index.backend-state)]
    [(Err message)
      (Err (box (compiler_diagnostic.compiler-diagnostic-at-start "" message)))]))

(define (compiler-backend-emit-phi-edge-copies
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [target-label : i64]
  [from-label : i64]
  [program-index : be_state.CompilerBackendProgramIndex]
  [vars : i64]) : be_state.ResultCompilerBackend
  ;; #phi-staged-copy: cleared on entry so a scan that never reaches the target
  ;; leaves no previous edge's point behind; the scan below sets it.
  (compiler-backend-function-state-set-current-phi-target-point!
    program-index.backend-state
    -1)
  (compiler-backend-emit-phi-edge-copies-scan
    type-segment-bases
    assignments
    blocks
    target-label
    from-label
    program-index
    vars
    0))

;; `point` is the running prefix sum of block instruction counts in scavenge
;; coordinates (2 per instruction) over the blocks already skipped -- the target
;; block's entry point once the label matches. See #phi-staged-copy.
(define (compiler-backend-emit-phi-edge-copies-scan
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [target-label : i64]
  [from-label : i64]
  [program-index : be_state.CompilerBackendProgramIndex]
  [vars : i64]
  [point : i64]) : be_state.ResultCompilerBackend
  (match blocks
    [(Array seq)
      (compiler-backend-emit-phi-edge-copies-scan-seq
        type-segment-bases
        assignments
        seq
        target-label
        from-label
        program-index
        vars
        point)]))

(define (compiler-backend-emit-phi-edge-copies-scan-seq
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [blocks : compiler_ir_types.CompilerIrBlockSeq]
  [target-label : i64]
  [from-label : i64]
  [program-index : be_state.CompilerBackendProgramIndex]
  [vars : i64]
  [point : i64]) : be_state.ResultCompilerBackend
  ;; The edge index answers the first block labelled `target-label` in O(1)
  ;; (compiler-backend-edge-index-ensure!).
  (let
    [edge-index : (__tl_dyn-array i64)
      (compiler-backend-edge-index-ensure!
        program-index.backend-state
        (be_state.compiler-backend-global-shared-view blocks))]
    [found : i64 (compiler-backend-edge-index-find (& edge-index) target-label)]
    (if (< found 0)
      (Err
        (box
          (compiler_diagnostic.compiler-diagnostic-at-start
            ""
            (str_cat.str-cat
              "backend: unknown block "
              (compiler_ir_types.compiler-ir-label-text target-label)))))
      (match (compiler_ir_types.compiler-ir-block-seq-ref blocks found)
        [(Block _ instrs)
          (compiler-backend-function-state-set-current-phi-target-point!
            program-index.backend-state
            (+ point (compiler-backend-edge-index-point (& edge-index) found)))
          (compiler-backend-emit-leading-phi-copies
            type-segment-bases
            assignments
            instrs
            from-label
            program-index
            vars)]))))

(define (compiler-backend-emit-mov-phi-copy-edge
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [target-label : i64]
  [from-label : i64]
  [moved-dst : i64]
  [moved-src : compiler_ir_types.CompilerIrValue]
  [program-index : be_state.CompilerBackendProgramIndex]
  [vars : i64]) : be_state.ResultCompilerBackend
  ;; #phi-staged-copy: see emit-phi-edge-copies.
  (compiler-backend-function-state-set-current-phi-target-point!
    program-index.backend-state
    -1)
  (compiler-backend-emit-mov-phi-copy-edge-scan
    type-segment-bases
    assignments
    blocks
    target-label
    from-label
    moved-dst
    moved-src
    program-index
    vars
    0))

(define (compiler-backend-emit-mov-phi-copy-edge-scan
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [target-label : i64]
  [from-label : i64]
  [moved-dst : i64]
  [moved-src : compiler_ir_types.CompilerIrValue]
  [program-index : be_state.CompilerBackendProgramIndex]
  [vars : i64]
  [point : i64]) : be_state.ResultCompilerBackend
  (match blocks
    [(Array seq)
      (compiler-backend-emit-mov-phi-copy-edge-scan-seq
        type-segment-bases
        assignments
        seq
        target-label
        from-label
        moved-dst
        moved-src
        program-index
        vars
        point)]))

(define (compiler-backend-emit-mov-phi-copy-edge-scan-seq
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [blocks : compiler_ir_types.CompilerIrBlockSeq]
  [target-label : i64]
  [from-label : i64]
  [moved-dst : i64]
  [moved-src : compiler_ir_types.CompilerIrValue]
  [program-index : be_state.CompilerBackendProgramIndex]
  [vars : i64]
  [point : i64]) : be_state.ResultCompilerBackend
  ;; The edge index answers the first block labelled `target-label` in O(1)
  ;; (compiler-backend-edge-index-ensure!).
  (let
    [edge-index : (__tl_dyn-array i64)
      (compiler-backend-edge-index-ensure!
        program-index.backend-state
        (be_state.compiler-backend-global-shared-view blocks))]
    [found : i64 (compiler-backend-edge-index-find (& edge-index) target-label)]
    (if (< found 0)
      (Err
        (box
          (compiler_diagnostic.compiler-diagnostic-at-start
            ""
            (str_cat.str-cat
              "backend: unknown block "
              (compiler_ir_types.compiler-ir-label-text target-label)))))
      (match (compiler_ir_types.compiler-ir-block-seq-ref blocks found)
        [(Block _ instrs)
          (match (compiler-backend-leading-phi-copies-seq
            program-index.backend-state
            assignments
            (be_state.compiler-backend-global-shared-view instrs)
            from-label)
            [(Ok copies)
              (if (compiler-backend-phi-copy-list-has-source-var?
                (be_state.compiler-backend-global-shared-view copies)
                moved-dst)
                (begin
                  (compiler-backend-function-state-set-current-phi-target-point!
                    program-index.backend-state
                    (+
                      point
                      (compiler-backend-edge-index-point (& edge-index) found)))
                  (compiler-backend-emit-phi-copy-list
                    type-segment-bases
                    assignments
                    (compiler-backend-phi-copy-list-drop-same-home
                      program-index.backend-state
                      assignments
                      (compiler-backend-phi-copy-list-replace-source-var
                        copies
                        moved-dst
                        moved-src))
                    (compiler-backend-phi-leading-dst-home-mask-seq
                      program-index.backend-state
                      assignments
                      instrs)
                    program-index
                    vars
                    false
                    program-index.backend-state))
                (Ok ""))]
            [(Err message)
              (Err
                (box
                  (compiler_diagnostic.compiler-diagnostic-at-start "" message)))])]))))

;; #jump-forward. A block "emits nothing but one jmp" when every instruction
;; ahead of its terminator is a Phi (those emit no code of their own; the
;; incoming values are marshalled on the edges INTO the block) and the
;; terminator is `Jump M` whose own emission reduces to that one jump. Three
;; further conditions decide the latter, all readable before emission:
;;
;;   * no loop-constant hoist is injected at the block's label (const-hoist is
;;     built per function, ahead of emit-blocks, so its table is already final);
;;   * M does not end in a Return -- a returning target turns the edge into an
;;     inline return tail rather than a jump;
;;   * the M-phi copies for THIS predecessor all coalesce away, i.e. the copy
;;     list `compiler-backend-leading-phi-copies-seq` builds -- the very list
;;     the emitter renders -- comes out empty.
;;
;; Traversing such a block does nothing but arrive at M, so a jump aimed at it
;; may name M instead. The block itself is still emitted unchanged; only jump
;; operands move, so every label, span and switch-table entry stays valid.
(define (compiler-backend-jump-only-leading-phis?
  [instrs : compiler_ir_types.CompilerIrInstrSeq]
  [limit : i64]) : bool
  (let
    [i : i64 0]
    [ok : bool true]
    (while (< i limit)
      (match (compiler_ir_types.compiler-ir-instr-seq-borrow instrs i)
        [(Phi _ _ _) unit]
        [_
          (set! ok false)
          (set! i limit)])
      (+= i 1))
    ok))

(define (compiler-backend-jump-only-edge-clean?
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [blocks : compiler_ir_types.CompilerIrBlockSeq]
  [target : i64]
  [from-label : i64]) : bool
  (let
    [n : i64 (compiler_ir_types.compiler-ir-block-seq-count blocks)]
    [i : i64 0]
    [clean : bool false]
    (while (< i n)
      (match (compiler_ir_types.compiler-ir-block-seq-ref blocks i)
        [(Block block-label instrs)
          (if (= block-label target)
            (begin
              (set!
                clean
                (and
                  (not
                    (compiler-backend-instr-seq-ends-in-return?
                      (be_state.compiler-backend-global-shared-view instrs)))
                  (match (compiler-backend-leading-phi-copies-seq
                    backend-state
                    assignments
                    instrs
                    from-label)
                    [(Ok copies) (= copies.len 0)]
                    [(Err _) false])))
              (set! i n))
            (+= i 1))]))
    clean))

(define (compiler-backend-instr-seq-ends-in-return?
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : bool
  (let
    [count : i64 (compiler_ir_types.compiler-ir-instr-seq-count instrs)]
    (if (< count 1)
      false
      (match (compiler_ir_types.compiler-ir-instr-seq-borrow instrs (- count 1))
        [(Return _) true]
        [_ false]))))

(define (compiler-backend-jump-only-target
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [blocks : compiler_ir_types.CompilerIrBlockSeq]
  [index : i64]) : i64
  (match (compiler_ir_types.compiler-ir-block-seq-ref blocks index)
    [(Block label instrs)
      (let
        [function-state : be_state.CompilerBackendFunctionState
          (be_state.compiler-backend-state-function-state backend-state)]
        [count : i64 (compiler_ir_types.compiler-ir-instr-seq-count instrs)]
        [target : i64
          (if (< count 1)
            (compiler_ir_types.compiler-ir-label-none)
            (match (compiler_ir_types.compiler-ir-instr-seq-ref
              instrs
              (- count 1))
              [(Jump next) next]
              [_ (compiler_ir_types.compiler-ir-label-none)]))]
        (if (or
          (= target (compiler_ir_types.compiler-ir-label-none))
          (= target label)
          (not (compiler-backend-jump-only-leading-phis? instrs (- count 1)))
          (not
            (string.eq
              (be_scalar.compiler-backend-const-hoist-injection-for
                function-state
                label
                true)
              ""))
          (not
            (string.eq
              (be_scalar.compiler-backend-const-hoist-injection-for
                function-state
                label
                false)
              "")))
          (compiler_ir_types.compiler-ir-label-none)
          (if (compiler-backend-jump-only-edge-clean?
            backend-state
            assignments
            blocks
            target
            label)
            target
            (compiler_ir_types.compiler-ir-label-none))))]))

;; Follow each raw (from -> immediate target) hop to the end of its chain.
;; `fuel` bounds the walk, so a jump-only cycle -- `while (true) {}` lowered to
;; a pair of empty blocks -- terminates instead of spinning; a chain that walks
;; back onto its own start is dropped so a self-loop keeps its jump.
(define (compiler-backend-jump-forward-resolve!
  [pairs : (__tl_dyn-array i64)]
  [used : i64]) : i64
  (let
    [count : i64 0]
    (for [i (iterator.range 0 used)]
      (let
        [from : i64 (array-ref pairs (* 2 i))]
        [to : i64 (array-ref pairs (+ (* 2 i) 1))]
        [fuel : i64 used]
        (while (and (> fuel 0) (not (= to from)))
          (let
            [next : i64
              (be_scalar.compiler-backend-jump-forward-pair-lookup
                pairs
                used
                to)]
            (if (= next to)
              (set! fuel 0)
              (begin
                (set! to next)
                (-= fuel 1)))))
        (unless
          (= to from)
          (set! (array-ref pairs (* 2 count)) from)
          (set! (array-ref pairs (+ (* 2 count) 1)) to)
          (+= count 1))))
    count))

(define (compiler-backend-jump-forward-build
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [blocks : compiler_ir_types.CompilerIrBlockList]) : (__tl_dyn-array i64)
  (let
    ;; Normalised to a seq: after stack colouring and the call-save rewrite the
    ;; emitted block list is not always the array form.
    [seq : compiler_ir_types.CompilerIrBlockSeq
      (compiler_liveness.compiler-live-ir-block-list-to-seq (& blocks))]
    [n : i64 (compiler_ir_types.compiler-ir-block-seq-count seq)]
    [raw : (__tl_dyn-array i64) (__tl_make-array i64 (* 2 n))]
    [used : i64 0]
    ;; The shrink-wrap guard prefix and the saving block it branches to are off
    ;; limits: the guard is re-rendered as a splice needle before this table
    ;; exists, and forwarding past the saving block would step over the
    ;; prologue spliced in at its label.
    [guard-prefix : i64
      (compiler_regalloc.compiler-reg-early-exit-prefix-count-current)]
    [saving-label : i64
      (compiler_regalloc.compiler-reg-early-exit-saving-label-current)]
    ;; SW-1: the general placement's saving block is off limits for the same
    ;; reason -- its label is where the prologue is spliced in.
    [swb-saving-label : i64
      (be_state.compiler-backend-function-state-i64
        (be_state.compiler-backend-state-function-state backend-state)
        be_state.compiler-backend-function-i64-swb-saving-label)]
    (for [i (iterator.range guard-prefix n)]
      (let
        [label : i64
          (be_scalar.compiler-backend-const-hoist-block-label
            (compiler_ir_types.compiler-ir-block-seq-borrow seq i))]
        [target : i64
          (if (or (= label saving-label) (= label swb-saving-label))
            (compiler_ir_types.compiler-ir-label-none)
            (compiler-backend-jump-only-target
              backend-state
              assignments
              (be_state.compiler-backend-global-shared-view seq)
              i))]
        (unless
          (= target (compiler_ir_types.compiler-ir-label-none))
          (set! (array-ref raw (* 2 used)) label)
          (set! (array-ref raw (+ (* 2 used) 1)) target)
          (+= used 1))))
    (compiler-backend-jump-forward-pack
      (be_state.compiler-backend-global-shared-view raw)
      (compiler-backend-jump-forward-resolve! raw used))))

(define (compiler-backend-jump-forward-pack
  [raw : (__tl_dyn-array i64)]
  [count : i64]) : (__tl_dyn-array i64)
  (let
    [out : (__tl_dyn-array i64) (__tl_make-array i64 (* 2 count))]
    (for [i (iterator.range 0 (* 2 count))]
      (set! (array-ref out i) (array-ref raw i)))
    out))

(define (compiler-backend-branch-edge-label
  [current-label : i64]
  [suffix : String]) : i64
  (compiler_ir_types.compiler-ir-label
    (&
      (str_cat.str-cat
        (compiler_ir_types.compiler-ir-label-text current-label)
        "_branch_"
        suffix))))

(define (compiler-backend-branch-edge-target
  [edge-label : i64]
  [target-label : i64]
  [copies : (& copies str)]) : i64
  (if (string.eq copies "")
    target-label
    edge-label))

(define (compiler-backend-branch-edge-fallthrough
  [current-label : i64]
  [true-copies : (& true-copies str)]
  [false-copies : (& false-copies str)]
  [fallthrough : be_state.CompilerBackendMaybeLabel]) : be_state.CompilerBackendMaybeLabel
  (if (not (string.eq true-copies ""))
    (Some (compiler-backend-branch-edge-label current-label "true"))
    (if (not (string.eq false-copies ""))
      (Some (compiler-backend-branch-edge-label current-label "false"))
      fallthrough)))

;; `edge-next` is what physically follows this edge block: the other edge block
;; when one is still to come, else the next IR block. It lets an edge block
;; drop a trailing `jmp` to the very next address.
(define (compiler-backend-emit-branch-edge-block
  [backend-state : be_state.CompilerBackendState]
  [function : String]
  [edge-label : i64]
  [target-label : i64]
  [copies : (& copies str)]
  [edge-next : be_state.CompilerBackendMaybeLabel]) : String
  (if (string.eq copies "")
    ""
    (let
      [taken : i64
        (be_scalar.compiler-backend-jump-resolve-target
          backend-state
          target-label
          edge-next)]
      (str_cat.str-cat
        (be_operand.compiler-backend-asm-label
          (be_state.compiler-backend-global-shared-view function)
          edge-label)
        ":\n"
        copies
        (if (be_scalar.compiler-backend-jump-target-is-fallthrough?
          taken
          edge-next)
          ""
          (be_scalar.compiler-backend-jump-label function taken))
        ""))))

(define (compiler-backend-emit-branch-edges
  [backend-state : be_state.CompilerBackendState]
  [function : String]
  [current-label : i64]
  [true-label : i64]
  [false-label : i64]
  [true-copies : (& true-copies str)]
  [false-copies : (& false-copies str)]
  [fallthrough : be_state.CompilerBackendMaybeLabel]
  [branch-asm : String]) : String
  (let
    [true-edge : i64 (compiler-backend-branch-edge-label current-label "true")]
    [false-edge : i64
      (compiler-backend-branch-edge-label current-label "false")]
    (str_cat.str-cat
      branch-asm
      (compiler-backend-emit-branch-edge-block
        backend-state
        (be_state.compiler-backend-global-shared-view function)
        true-edge
        true-label
        true-copies
        (if (string.eq false-copies "")
          fallthrough
          (Some false-edge)))
      (compiler-backend-emit-branch-edge-block
        backend-state
        function
        false-edge
        false-label
        false-copies
        fallthrough))))

;; A branch's own flag-setting step, or none at all. An empty `true-jcc` is the
;; ordinary branch: load/test the condition and jump on ZF. A non-empty one is a
;; caller that already proved EFLAGS holds the condition -- a materialized
;; comparison's own flags, still live across its flag-preserving
;; `setcc`/`movzb` -- so only the jumps are emitted and `cond`, which names the
;; boolean those flags were set from, needs no instruction of its own.
(define (compiler-backend-emit-branch-test-or-jcc
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [function : String]
  [cond : compiler_ir_types.CompilerIrValue]
  [true-label : i64]
  [false-label : i64]
  [fallthrough : be_state.CompilerBackendMaybeLabel]
  [true-jcc : String]
  [false-jcc : String]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (string.eq true-jcc "")
    (be_scalar.compiler-backend-emit-branch
      assignments
      function
      cond
      true-label
      false-label
      fallthrough
      backend-state)
    (Ok
      (be_scalar.compiler-backend-emit-compare-branch-jumps
        function
        true-label
        false-label
        fallthrough
        true-jcc
        false-jcc
        backend-state))))

;; The phi copies a two-way branch owes each successor, and the labels it
;; jumps to so they run: a side with copies goes through an edge block of its
;; own, emitted after the branch by compiler-backend-emit-branch-edges.
(defstruct CompilerBackendBranchEdges
  (true-copies String)
  (false-copies String)
  (true-target i64)
  (false-target i64)
  (fallthrough be_state.CompilerBackendMaybeLabel))

(defenum ResultCompilerBackendBranchEdges
  (Ok CompilerBackendBranchEdges)
  (Err (Box compiler_diagnostic.CompilerDiagnostic)))

(define (compiler-backend-branch-phi-edges
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [current-label : i64]
  [true-label : i64]
  [false-label : i64]
  [fallthrough : be_state.CompilerBackendMaybeLabel]
  [program-index : be_state.CompilerBackendProgramIndex]
  [vars : i64]) : ResultCompilerBackendBranchEdges
  (let
    [true-copies
      (try
        (compiler-backend-emit-phi-edge-copies
          type-segment-bases
          assignments
          (be_state.compiler-backend-global-shared-view blocks)
          true-label
          current-label
          program-index
          vars))]
    [false-copies
      (try
        (compiler-backend-emit-phi-edge-copies
          type-segment-bases
          assignments
          blocks
          false-label
          current-label
          program-index
          vars))]
    [true-edge : i64 (compiler-backend-branch-edge-label current-label "true")]
    [false-edge : i64
      (compiler-backend-branch-edge-label current-label "false")]
    [true-target : i64
      (compiler-backend-branch-edge-target true-edge true-label true-copies)]
    [false-target : i64
      (compiler-backend-branch-edge-target false-edge false-label false-copies)]
    [edge-fallthrough : be_state.CompilerBackendMaybeLabel
      (compiler-backend-branch-edge-fallthrough
        current-label
        true-copies
        false-copies
        fallthrough)]
    (Ok
      (CompilerBackendBranchEdges
        true-copies
        false-copies
        true-target
        false-target
        edge-fallthrough))))

(define (compiler-backend-emit-branch-with-phi-copies
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [function : String]
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [current-label : i64]
  [cond : compiler_ir_types.CompilerIrValue]
  [true-label : i64]
  [false-label : i64]
  [fallthrough : be_state.CompilerBackendMaybeLabel]
  [program-index : be_state.CompilerBackendProgramIndex]
  [vars : i64]
  [true-jcc : String]
  [false-jcc : String]) : be_state.ResultCompilerBackend
  (if (not
    (be_peephole.compiler-backend-branch-needs-phi-copies?
      (be_state.compiler-backend-state-function-state
        program-index.backend-state)
      true-label
      false-label))
    (compiler-backend-emit-branch-test-or-jcc
      assignments
      function
      cond
      true-label
      false-label
      fallthrough
      true-jcc
      false-jcc
      program-index.backend-state)
    (let
      [edges
        (try
          (compiler-backend-branch-phi-edges
            type-segment-bases
            assignments
            blocks
            current-label
            true-label
            false-label
            fallthrough
            program-index
            vars))]
      [branch-asm
        (try
          (compiler-backend-emit-branch-test-or-jcc
            assignments
            (be_state.compiler-backend-global-shared-view function)
            cond
            edges.true-target
            edges.false-target
            edges.fallthrough
            true-jcc
            false-jcc
            program-index.backend-state))]
      (Ok
        (compiler-backend-emit-branch-edges
          program-index.backend-state
          function
          current-label
          true-label
          false-label
          edges.true-copies
          edges.false-copies
          fallthrough
          branch-asm)))))

(define (compiler-backend-emit-compare-branch-with-phi-copies
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [function : String]
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [current-label : i64]
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [true-label : i64]
  [false-label : i64]
  [fallthrough : be_state.CompilerBackendMaybeLabel]
  [program-index : be_state.CompilerBackendProgramIndex]
  [vars : i64]) : be_state.ResultCompilerBackend
  (if (not
    (be_peephole.compiler-backend-branch-needs-phi-copies?
      (be_state.compiler-backend-state-function-state
        program-index.backend-state)
      true-label
      false-label))
    (be_scalar.compiler-backend-emit-compare-branch
      type-segment-bases
      assignments
      function
      op
      lhs
      rhs
      ty
      true-label
      false-label
      fallthrough
      program-index.backend-state)
    (let
      [edges
        (try
          (compiler-backend-branch-phi-edges
            type-segment-bases
            assignments
            blocks
            current-label
            true-label
            false-label
            fallthrough
            program-index
            vars))]
      [branch-asm
        (try
          (be_scalar.compiler-backend-emit-compare-branch
            type-segment-bases
            assignments
            (be_state.compiler-backend-global-shared-view function)
            op
            lhs
            rhs
            ty
            edges.true-target
            edges.false-target
            edges.fallthrough
            program-index.backend-state))]
      (Ok
        (compiler-backend-emit-branch-edges
          program-index.backend-state
          function
          current-label
          true-label
          false-label
          edges.true-copies
          edges.false-copies
          fallthrough
          branch-asm)))))

(define (compiler-backend-emit-load-compare-branch-with-phi-copies
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [function : String]
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [current-label : i64]
  [ptr : compiler_ir_types.CompilerIrValue]
  [op : (& compiler_ir_types.CompilerIrBinOp)]
  [rhs : (& compiler_ir_types.CompilerIrValue)]
  [ty : compiler_ast_types.AstType]
  [true-label : i64]
  [false-label : i64]
  [fallthrough : be_state.CompilerBackendMaybeLabel]
  [program-index : be_state.CompilerBackendProgramIndex]
  [vars : i64]) : be_state.ResultCompilerBackend
  (if (not
    (be_peephole.compiler-backend-branch-needs-phi-copies?
      (be_state.compiler-backend-state-function-state
        program-index.backend-state)
      true-label
      false-label))
    (be_scalar.compiler-backend-emit-load-compare-branch
      type-segment-bases
      assignments
      function
      ptr
      op
      rhs
      ty
      true-label
      false-label
      fallthrough
      program-index.backend-state)
    (let
      [edges
        (try
          (compiler-backend-branch-phi-edges
            type-segment-bases
            assignments
            blocks
            current-label
            true-label
            false-label
            fallthrough
            program-index
            vars))]
      [branch-asm
        (try
          (be_scalar.compiler-backend-emit-load-compare-branch
            type-segment-bases
            assignments
            (be_state.compiler-backend-global-shared-view function)
            ptr
            op
            rhs
            ty
            edges.true-target
            edges.false-target
            edges.fallthrough
            program-index.backend-state))]
      (Ok
        (compiler-backend-emit-branch-edges
          program-index.backend-state
          function
          current-label
          true-label
          false-label
          edges.true-copies
          edges.false-copies
          fallthrough
          branch-asm)))))

(define (compiler-backend-emit-gep-load-compare-branch-with-phi-copies
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [function : String]
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [current-label : i64]
  [base : compiler_ir_types.CompilerIrValue]
  [offset : compiler_ir_types.CompilerIrValue]
  [elem-ty : compiler_ast_types.AstType]
  [op : (& compiler_ir_types.CompilerIrBinOp)]
  [rhs : (& compiler_ir_types.CompilerIrValue)]
  [ty : (& compiler_ast_types.AstType)]
  [true-label : i64]
  [false-label : i64]
  [fallthrough : be_state.CompilerBackendMaybeLabel]
  [program-index : be_state.CompilerBackendProgramIndex]
  [vars : i64]) : be_state.ResultCompilerBackend
  (if (not
    (be_peephole.compiler-backend-branch-needs-phi-copies?
      (be_state.compiler-backend-state-function-state
        program-index.backend-state)
      true-label
      false-label))
    (be_scalar.compiler-backend-emit-gep-load-compare-branch
      type-segment-bases
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
      fallthrough
      program-index.backend-state)
    (let
      [edges
        (try
          (compiler-backend-branch-phi-edges
            type-segment-bases
            assignments
            blocks
            current-label
            true-label
            false-label
            fallthrough
            program-index
            vars))]
      [branch-asm
        (try
          (be_scalar.compiler-backend-emit-gep-load-compare-branch
            type-segment-bases
            assignments
            (be_state.compiler-backend-global-shared-view function)
            base
            offset
            elem-ty
            op
            rhs
            ty
            edges.true-target
            edges.false-target
            edges.fallthrough
            program-index.backend-state))]
      (Ok
        (compiler-backend-emit-branch-edges
          program-index.backend-state
          function
          current-label
          true-label
          false-label
          edges.true-copies
          edges.false-copies
          fallthrough
          branch-asm)))))

(define (compiler-backend-tail-call-return-normalize
  [type-segment-bases : i64]
  [ty : compiler_ast_types.AstType]) : String
  (if (= (be_operand.compiler-backend-type-size type-segment-bases ty) 0)
    "    movl $0, %eax\n"
    ""))

;; The edge index (compiler-backend-function-i64-array-edge-index) of one
;; dense block sequence: [0] the address of the block storage it was built
;; from, [1] its block count n, [2] a power-of-two hash capacity c >= 2n, then
;; c label keys, c values (block index + 1; 0 marks an empty slot), n + 1
;; scavenge entry points (the entry point of block i is the sum of 2 x the
;; instruction count of every earlier block) and n + 1 shared-return suffix
;; counts (block i's count is the compiler-backend-shared-return-block-count sum
;; over blocks i..n-1). A label that repeats keeps its first block, exactly as a
;; linear scan from the start finds it. Edge lookups then cost O(1) instead of a
;; walk over the sequence plus a recount of every later block's returns.
(define compiler-backend-edge-index-header : i64
  3)

(define (compiler-backend-edge-index-blocks-address
  [blocks : (& blocks compiler_ir_types.CompilerIrBlockSeq)]) : i64
  (cast
    (unsafe
      (ptr->int (ptr-cast (__tl_array-data blocks.slots) : (Ptr u8))))
    : i64))

(define (compiler-backend-edge-index-current?
  [index : (& index (__tl_dyn-array i64))]
  [blocks : (& blocks compiler_ir_types.CompilerIrBlockSeq)]) : bool
  (and
    (>= (array-length index) compiler-backend-edge-index-header)
    (= (array-ref index 0) (compiler-backend-edge-index-blocks-address blocks))
    (=
      (array-ref index 1)
      (compiler_ir_types.compiler-ir-block-seq-count blocks))))

(define (compiler-backend-edge-index-slot [label : i64] [capacity : i64]) : i64
  (bit-and (* label 1048573) (- capacity 1)))

;; Record `label` -> `block` unless the label already has a block.
(define (compiler-backend-edge-index-insert!
  [index : (&mut index (__tl_dyn-array i64))]
  [capacity : i64]
  [label : i64]
  [block : i64]) : unit
  (let
    [keys-at : i64 compiler-backend-edge-index-header]
    [values-at : i64 (+ compiler-backend-edge-index-header capacity)]
    [slot : i64 (compiler-backend-edge-index-slot label capacity)]
    [done : bool false]
    (while (not done)
      (cond
        [(= (array-ref index (+ values-at slot)) 0)
          (set! (array-ref index (+ keys-at slot)) label)
          (set! (array-ref index (+ values-at slot)) (+ block 1))
          (set! done true)]
        [(= (array-ref index (+ keys-at slot)) label) (set! done true)]
        [else (set! slot (bit-and (+ slot 1) (- capacity 1)))]))))

;; The index of the first block labelled `label`, or -1.
(define (compiler-backend-edge-index-find
  [index : (& index (__tl_dyn-array i64))]
  [label : i64]) : i64
  (let
    [capacity : i64 (array-ref index 2)]
    [keys-at : i64 compiler-backend-edge-index-header]
    [values-at : i64 (+ compiler-backend-edge-index-header capacity)]
    [slot : i64 (compiler-backend-edge-index-slot label capacity)]
    (for [steps (iterator.range 0 capacity)]
      (let
        [value : i64 (array-ref index (+ values-at slot))]
        (cond
          [(= value 0) (return -1)]
          [(= (array-ref index (+ keys-at slot)) label) (return (- value 1))]
          [else
            (set! slot (bit-and (+ slot 1) (- capacity 1)))
            unit])))
    -1))

(define (compiler-backend-edge-index-point
  [index : (& index (__tl_dyn-array i64))]
  [block : i64]) : i64
  (array-ref
    index
    (+ compiler-backend-edge-index-header (* 2 (array-ref index 2)) block)))

(define (compiler-backend-edge-index-returns-from
  [index : (& index (__tl_dyn-array i64))]
  [block : i64]) : i64
  (array-ref
    index
    (+
      compiler-backend-edge-index-header
      (* 2 (array-ref index 2))
      (+ (array-ref index 1) 1)
      block)))

(define (compiler-backend-edge-index-build
  [backend-state : be_state.CompilerBackendState]
  [blocks : compiler_ir_types.CompilerIrBlockSeq]) : (__tl_dyn-array i64)
  (let
    [count : i64 (compiler_ir_types.compiler-ir-block-seq-count blocks)]
    [capacity : i64 2]
    [_capacity : unit
      (while (< capacity (* 2 count))
        (set! capacity (* capacity 2)))]
    [points-at : i64 (+ compiler-backend-edge-index-header (* 2 capacity))]
    [returns-at : i64 (+ points-at (+ count 1))]
    [index : (__tl_dyn-array i64)
      (__tl_make-array i64 (+ returns-at (+ count 1)))]
    [i : i64 0]
    [point : i64 0]
    (set!
      (array-ref index 0)
      (compiler-backend-edge-index-blocks-address (& blocks)))
    (set! (array-ref index 1) count)
    (set! (array-ref index 2) capacity)
    (while (< i count)
      (match (compiler_ir_types.compiler-ir-block-seq-borrow blocks i)
        [(Block label instrs)
          (set! (array-ref index (+ points-at i)) point)
          (+= point (* 2 instrs.len))
          (compiler-backend-edge-index-insert! (&mut index) capacity label i)
          (+= i 1)]))
    (set! (array-ref index (+ points-at count)) point)
    (set! (array-ref index (+ returns-at count)) 0)
    (set! i (- count 1))
    (while (>= i 0)
      (match (compiler_ir_types.compiler-ir-block-seq-ref blocks i)
        [(Block label instrs)
          (set!
            (array-ref index (+ returns-at i))
            (+
              (array-ref index (+ returns-at (+ i 1)))
              (be_scalar.compiler-backend-shared-return-block-count
                backend-state
                label
                instrs)))
          (-= i 1)]))
    index))

;; The edge index for `blocks`, rebuilt when the current function's index was
;; built from other storage (emit-blocks clears it on entry).
(define (compiler-backend-edge-index-ensure!
  [backend-state : be_state.CompilerBackendState]
  [blocks : compiler_ir_types.CompilerIrBlockSeq]) : (__tl_dyn-array i64)
  (let
    [state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state backend-state)]
    [current : (__tl_dyn-array i64)
      (be_state.compiler-backend-function-state-i64-array
        state
        be_state.compiler-backend-function-i64-array-edge-index)]
    (if (compiler-backend-edge-index-current? (& current) (& blocks))
      current
      (begin
        (be_state.compiler-backend-function-state-set-i64-array!
          state
          be_state.compiler-backend-function-i64-array-edge-index
          (compiler-backend-edge-index-build backend-state blocks))
        (be_state.compiler-backend-function-state-i64-array
          state
          be_state.compiler-backend-function-i64-array-edge-index)))))

(define (compiler-backend-use-shared-return?
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [blocks : compiler_ir_types.CompilerIrBlockList]) : bool
  (be_scalar.compiler-backend-use-shared-return-count?
    backend-state
    assignments
    (be_scalar.compiler-backend-shared-return-count
      backend-state
      assignments
      blocks)))

(define (compiler-backend-return-epilogue
  [backend-state : be_state.CompilerBackendState]
  [source-function : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [vars : i64]
  [blocks : compiler_ir_types.CompilerIrBlockList]) : String
  (if (compiler-backend-use-shared-return? backend-state assignments blocks)
    (str_cat.str-cat
      (be_scalar.compiler-backend-return-label backend-state source-function)
      ":\n"
      (be_scalar.compiler-backend-inline-return-tail
        assignments
        vars
        backend-state)
      "")
    ""))

;; compiler-ir-blocks-expose-frame-at? for a tail transfer in the function
;; being emitted, whose `blocks` are fixed while emit-blocks runs. The
;; whole-function half is computed at the first site and kept in the function
;; state, so a function with several tail calls pays for it once.
(define (compiler-backend-blocks-expose-frame-at?
  [backend-state : be_state.CompilerBackendState]
  [blocks : (& blocks compiler_ir_types.CompilerIrBlockList)]
  [label : i64]) : bool
  (let
    [function-state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state backend-state)]
    [known : i64
      (be_state.compiler-backend-function-state-i64
        function-state
        be_state.compiler-backend-function-i64-frame-may-escape)]
    [may-escape? : bool
      (if (= known 0)
        (let
          [computed : bool
            (compiler_ir_types.compiler-ir-blocks-frame-may-escape? blocks)]
          (be_state.compiler-backend-function-state-set-i64!
            function-state
            be_state.compiler-backend-function-i64-frame-may-escape
            (if computed
              2
              1))
          computed)
        (= known 2))]
    (compiler_ir_types.compiler-ir-blocks-expose-frame-at-given?
      blocks
      may-escape?
      label)))

(define (compiler-backend-emit-tail-call
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [source-function : i64]
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [current-label : i64]
  [name : i64]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [ty : compiler_ast_types.AstType]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [types : compiler_regalloc.CompilerRegVarTypes]
  [global-types : be_state.CompilerBackendGlobalTypeTable]
  [vars : i64]
  [plan : be_state.CompilerBackendRuntimePlan]
  [_functions : compiler_ir_types.CompilerIrFunctionSeq]
  [_externs : compiler_ir_types.CompilerIrExternSeq]
  [program-index : be_state.CompilerBackendProgramIndex]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [convention : compiler_abi.CompilerCallConvention
      (compiler_regalloc.compiler-reg-direct-call-convention name)]
    [extern-call-info : i64
      (be_operand.compiler-backend-index-extern-call-info program-index name)]
    [param-types : compiler_ast_types.AstTypeList
      (compiler-backend-call-param-types-for-call
        type-segment-bases
        name
        (be_state.compiler-backend-global-shared-view args)
        types
        global-types
        extern-call-info
        program-index)]
    [c-abi? : bool
      (be_facts.compiler-backend-extern-call-info-aggregate-params?
        extern-call-info)]
    [call-space : i64
      (be_operand.compiler-backend-call-arg-space
        target
        args
        param-types
        c-abi?
        program-index)]
    [tail-stack-count : i64
      (compiler-backend-call-stack-arg-count
        type-segment-bases
        target
        convention
        (be_state.compiler-backend-global-shared-view args)
        param-types
        c-abi?
        0
        0
        0
        0
        0
        program-index)]
    [target-symbol : String
      (be_operand.compiler-backend-call-symbol-index name plan program-index)]
    [return-normalize : String
      (compiler-backend-tail-call-return-normalize type-segment-bases ty)]
    [varargs-pre-call : String
      (compiler-backend-varargs-pre-call
        type-segment-bases
        target
        extern-call-info
        (be_state.compiler-backend-global-shared-view param-types))]
    ;; Both jump paths below retire this frame. A register-only argument can
    ;; still point into it, including through casts, projections or stored
    ;; aliases, so ABI register placement is not a lifetime proof. Whether a
    ;; frame address can exist here is a property of this block's paths.
    [frame-safe : bool
      (not
        (compiler-backend-blocks-expose-frame-at?
          backend-state
          (& blocks)
          current-label))]
    (if (and
      frame-safe
      (compiler-backend-direct-tail-call?
        type-segment-bases
        target
        source-function
        name
        (be_state.compiler-backend-global-shared-view args)
        param-types
        program-index))
      (let
        [args-asm
          (try
            (cond
              [(be_state.compiler-backend-function-state-bool?
                  (be_state.compiler-backend-state-function-state backend-state)
                  be_state.compiler-backend-function-bool-identity-tail-forwarder-active)
                (be_state.ResultCompilerBackend.Ok "")]
              [(compiler-backend-tail-call-args-parallel?
                  type-segment-bases
                  target
                  convention
                  assignments
                  (& args)
                  (& param-types)
                  c-abi?
                  program-index
                  tail-stack-count
                  backend-state)
                (compiler-backend-emit-direct-tail-call-args-parallel
                  type-segment-bases
                  target
                  convention
                  assignments
                  (& args)
                  (& param-types)
                  backend-state)]
              [(= tail-stack-count 0)
                (compiler-backend-emit-call-args
                  type-segment-bases
                  target
                  convention
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
                  vars
                  backend-state)]
              [else
                (compiler-backend-emit-direct-tail-call-args
                  type-segment-bases
                  target
                  convention
                  assignments
                  args
                  param-types
                  instr-diag
                  backend-state)]))]
        (Ok
          (str_cat.str-cat
            args-asm
            (be_scalar.compiler-backend-tail-jump-tail
              assignments
              vars
              target-symbol
              backend-state))))
      (let
        [args-asm
          (try
            (compiler-backend-emit-call-args
              type-segment-bases
              target
              convention
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
              vars
              backend-state))]
        (if (and
          frame-safe
          (= call-space 0)
          (= tail-stack-count 0)
          (string.eq return-normalize ""))
          (Ok
            (str_cat.str-cat
              args-asm
              varargs-pre-call
              (be_scalar.compiler-backend-tail-jump-tail
                assignments
                vars
                target-symbol
                backend-state)))
          (Ok
            (str_cat.str-cat
              (be_operand.compiler-backend-emit-call-space-sub call-space)
              args-asm
              varargs-pre-call
              (str_cat.str-cat
                "    call "
                target-symbol
                "\n"
                (str_cat.str-cat
                  (be_operand.compiler-backend-emit-call-space-add call-space)
                  return-normalize
                  (be_scalar.compiler-backend-return-tail
                    program-index.backend-state
                    source-function
                    assignments
                    vars
                    blocks))
                ""))))))))

(define (compiler-backend-trivial-phi-return-find
  [instrs : (& compiler_ir_types.CompilerIrInstrSeq)]
  [from-label : i64]
  [returned-dst : i64]
  [index : i64]
  [last-index : i64]
  [found : be_state.CompilerBackendPhiReturnMatch]) : be_state.ResultBackendPhiReturnMatch
  (if (>= index last-index)
    (Ok found)
    (match (compiler_ir_types.compiler-ir-instr-seq-ref instrs index)
      [(Phi dst inputs _)
        (let
          [incoming
            (try (be_facts.compiler-backend-phi-input-value inputs from-label))]
          (compiler-backend-trivial-phi-return-find
            instrs
            from-label
            returned-dst
            (+ index 1)
            last-index
            (if (= dst returned-dst)
              (Some incoming)
              found)))]
      [_ (Ok (No))])))

(define (compiler-backend-emit-trivial-phi-return-edge-instrs
  [type-segment-bases : i64]
  [source-function : i64]
  [return-count : i64]
  [instrs : (& compiler_ir_types.CompilerIrInstrSeq)]
  [from-label : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [vars : i64]
  [ret-ty : compiler_ast_types.AstType]
  [program-index : be_state.CompilerBackendProgramIndex]) : be_state.ResultCompilerBackend
  (if (< (compiler_ir_types.compiler-ir-instr-seq-count instrs) 2)
    (Ok "")
    (let
      [last-index : i64
        (- (compiler_ir_types.compiler-ir-instr-seq-count instrs) 1)]
      [last (compiler_ir_types.compiler-ir-instr-seq-ref instrs last-index)]
      (match last
        [(Return maybe)
          (match maybe
            [(Some value)
              (match value
                [(Var returned-dst)
                  (match (compiler-backend-trivial-phi-return-find
                    instrs
                    from-label
                    returned-dst
                    0
                    last-index
                    (No))
                    [(Ok found)
                      (match found
                        [(Some incoming)
                          ;; The real program-index must reach emit-return here:
                          ;; an empty index makes the register-group return check
                          ;; always false, so a 16-byte group return would load
                          ;; only word0.
                          (be_scalar.compiler-backend-emit-return-with-return-count
                            type-segment-bases
                            source-function
                            return-count
                            (Some incoming)
                            assignments
                            vars
                            ret-ty
                            program-index)]
                        [(No) (Ok "")])]
                    [(Err message)
                      (Err
                        (box
                          (compiler_diagnostic.compiler-diagnostic-at-start
                            ""
                            message)))])]
                [_ (Ok "")])]
            [(No) (Ok "")])]
        [_ (Ok "")]))))

(define (compiler-backend-emit-trivial-phi-return-edge
  [type-segment-bases : i64]
  [source-function : i64]
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [target-label : i64]
  [from-label : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [vars : i64]
  [ret-ty : compiler_ast_types.AstType]
  [program-index : be_state.CompilerBackendProgramIndex]) : be_state.ResultCompilerBackend
  (match (be_state.compiler-backend-global-shared-view blocks)
    [(Array seq)
      (compiler-backend-emit-trivial-phi-return-edge-seq
        type-segment-bases
        source-function
        seq
        target-label
        from-label
        assignments
        vars
        ret-ty
        program-index)]))

(define (compiler-backend-emit-trivial-phi-return-edge-seq
  [type-segment-bases : i64]
  [source-function : i64]
  [blocks : compiler_ir_types.CompilerIrBlockSeq]
  [target-label : i64]
  [from-label : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [vars : i64]
  [ret-ty : compiler_ast_types.AstType]
  [program-index : be_state.CompilerBackendProgramIndex]) : be_state.ResultCompilerBackend
  ;; The edge index answers the first block labelled `target-label` in O(1)
  ;; (compiler-backend-edge-index-ensure!).
  (let
    [edge-index : (__tl_dyn-array i64)
      (compiler-backend-edge-index-ensure!
        program-index.backend-state
        (be_state.compiler-backend-global-shared-view blocks))]
    [found : i64 (compiler-backend-edge-index-find (& edge-index) target-label)]
    (if (< found 0)
      (Ok "")
      (match (compiler_ir_types.compiler-ir-block-seq-ref blocks found)
        [(Block _ instrs)
          (compiler-backend-emit-trivial-phi-return-edge-instrs
            type-segment-bases
            source-function
            (compiler-backend-edge-index-returns-from (& edge-index) found)
            instrs
            from-label
            assignments
            vars
            ret-ty
            program-index)]))))

(define (compiler-backend-emit-mov-trivial-phi-return-edge-instrs
  [type-segment-bases : i64]
  [source-function : i64]
  [return-count : i64]
  [instrs : (& compiler_ir_types.CompilerIrInstrSeq)]
  [from-label : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [vars : i64]
  [ret-ty : compiler_ast_types.AstType]
  [moved-dst : i64]
  [moved-src : compiler_ir_types.CompilerIrValue]
  [program-index : be_state.CompilerBackendProgramIndex]) : be_state.ResultCompilerBackend
  (if (< (compiler_ir_types.compiler-ir-instr-seq-count instrs) 2)
    (Ok "")
    (let
      [last-index : i64
        (- (compiler_ir_types.compiler-ir-instr-seq-count instrs) 1)]
      [last (compiler_ir_types.compiler-ir-instr-seq-ref instrs last-index)]
      (match last
        [(Return maybe)
          (match maybe
            [(Some value)
              (match value
                [(Var returned-dst)
                  (match (compiler-backend-trivial-phi-return-find
                    instrs
                    from-label
                    returned-dst
                    0
                    last-index
                    (No))
                    [(Ok found)
                      (match found
                        [(Some incoming)
                          (if (be_operand.compiler-backend-branch-uses-var?
                            incoming
                            moved-dst)
                            ;; Same word1-drop hazard as the plain trivial
                            ;; phi return edge: emit-return needs the real
                            ;; program-index to spot register-group returns.
                            (be_scalar.compiler-backend-emit-return-with-return-count
                              type-segment-bases
                              source-function
                              return-count
                              (Some moved-src)
                              assignments
                              vars
                              ret-ty
                              program-index)
                            (Ok ""))]
                        [(No) (Ok "")])]
                    [(Err message)
                      (Err
                        (box
                          (compiler_diagnostic.compiler-diagnostic-at-start
                            ""
                            message)))])]
                [_ (Ok "")])]
            [(No) (Ok "")])]
        [_ (Ok "")]))))

(define (compiler-backend-emit-mov-trivial-phi-return-edge
  [type-segment-bases : i64]
  [source-function : i64]
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [target-label : i64]
  [from-label : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [vars : i64]
  [ret-ty : compiler_ast_types.AstType]
  [moved-dst : i64]
  [moved-src : compiler_ir_types.CompilerIrValue]
  [program-index : be_state.CompilerBackendProgramIndex]) : be_state.ResultCompilerBackend
  (match (be_state.compiler-backend-global-shared-view blocks)
    [(Array seq)
      (compiler-backend-emit-mov-trivial-phi-return-edge-seq
        type-segment-bases
        source-function
        seq
        target-label
        from-label
        assignments
        vars
        ret-ty
        moved-dst
        moved-src
        program-index)]))

(define (compiler-backend-emit-mov-trivial-phi-return-edge-seq
  [type-segment-bases : i64]
  [source-function : i64]
  [blocks : compiler_ir_types.CompilerIrBlockSeq]
  [target-label : i64]
  [from-label : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [vars : i64]
  [ret-ty : compiler_ast_types.AstType]
  [moved-dst : i64]
  [moved-src : compiler_ir_types.CompilerIrValue]
  [program-index : be_state.CompilerBackendProgramIndex]) : be_state.ResultCompilerBackend
  ;; The edge index answers the first block labelled `target-label` in O(1)
  ;; (compiler-backend-edge-index-ensure!).
  (let
    [edge-index : (__tl_dyn-array i64)
      (compiler-backend-edge-index-ensure!
        program-index.backend-state
        (be_state.compiler-backend-global-shared-view blocks))]
    [found : i64 (compiler-backend-edge-index-find (& edge-index) target-label)]
    (if (< found 0)
      (Ok "")
      (match (compiler_ir_types.compiler-ir-block-seq-ref blocks found)
        [(Block _ instrs)
          (compiler-backend-emit-mov-trivial-phi-return-edge-instrs
            type-segment-bases
            source-function
            (compiler-backend-edge-index-returns-from (& edge-index) found)
            instrs
            from-label
            assignments
            vars
            ret-ty
            moved-dst
            moved-src
            program-index)]))))

(define (compiler-backend-emit-class-correct-mov
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [dst : i64]
  [src : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [program-index : be_state.CompilerBackendProgramIndex]
  [vars : i64]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [function-state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state backend-state)]
    [mode : be_state.CompilerBackendMode
      (be_state.compiler-backend-function-state-current-mode function-state)]
    (if (or
      (be_state.compiler-backend-mode-scalar? mode)
      (be_scalar.compiler-backend-value-same-home?
        backend-state
        assignments
        dst
        (be_state.compiler-backend-global-shared-view src)))
      (compiler-backend-emit-mov
        type-segment-bases
        assignments
        dst
        src
        ty
        program-index
        vars
        backend-state)
      (match (be_simd.compiler-backend-simd-copy-shape blocks dst vars)
        [(No)
          (compiler-backend-emit-mov
            type-segment-bases
            assignments
            dst
            src
            ty
            program-index
            vars
            backend-state)]
        [(Vector _ elem-ty)
          (be_simd.compiler-backend-emit-vector-copy
            assignments
            dst
            src
            (if (be_state.compiler-backend-mode-avx2? mode)
              "ymm"
              "zmm")
            elem-ty
            backend-state)]
        [(Mask lanes)
          (if (be_state.compiler-backend-mode-avx2? mode)
            (be_simd.compiler-backend-emit-vector-copy
              assignments
              dst
              src
              "ymm"
              (Bool)
              backend-state)
            (be_simd.compiler-backend-emit-avx512-mask-copy
              assignments
              dst
              src
              lanes
              backend-state))]))))

(define (compiler-backend-emit-mov
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [src : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [program-index : be_state.CompilerBackendProgramIndex]
  [vars : i64]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (cond
    ;; M-B: a group mov whose src and dst share a home (the coloring's
    ;; group-mov slot aliasing merges their ids, so both formula word slots
    ;; coincide; a register-pair dst can also equal its src's pair) copies a
    ;; value onto itself -- emit nothing instead of round-tripping both words
    ;; through the group-return register pair.
    [(and
        (be_facts.compiler-backend-copy-group?
          type-segment-bases
          program-index
          (be_state.compiler-backend-global-shared-view ty)
          dst
          (be_state.compiler-backend-global-shared-view src))
        (be_scalar.compiler-backend-value-same-home?
          backend-state
          assignments
          dst
          (be_state.compiler-backend-global-shared-view src)))
      (Ok "")]
    [(be_facts.compiler-backend-copy-group?
        type-segment-bases
        program-index
        (be_state.compiler-backend-global-shared-view ty)
        dst
        (be_state.compiler-backend-global-shared-view src))
      (be_scalar.compiler-backend-emit-group-copy
        type-segment-bases
        assignments
        (& (Var dst))
        (be_state.compiler-backend-global-shared-view src)
        vars
        ty
        program-index
        backend-state)]
    [(be_scalar.compiler-backend-value-same-home?
        backend-state
        assignments
        dst
        (be_state.compiler-backend-global-shared-view src))
      (Ok "")]
    ;; R5: a rematerialised destination has no storage and no live use of this
    ;; definition -- every use recomputes -- so the whole `mov` is dead.
    [(be_scalar.compiler-backend-var-remat-home? backend-state assignments dst)
      (Ok "")]
    [(be_operand.compiler-backend-float-type? ty)
      (let
        [dst-home : String
          (be_scalar.compiler-backend-var-register-home
            backend-state
            assignments
            dst)]
        [src-home : String
          (be_scalar.compiler-backend-float-value-register
            backend-state
            assignments
            src)]
        [exclude : (__tl_dyn-array String)
          (if (string.eq src-home "")
            (__tl_make-array String 0)
            (be_operand.compiler-backend-one-exclude
              (be_state.compiler-backend-global-shared-view src-home)))]
        [exclude-n : i64
          (if (string.eq src-home "")
            0
            1)]
        [reg : String
          (if (string.eq dst-home "")
            (be_operand.compiler-backend-scavenge-xmm-reg
              dst
              exclude
              exclude-n
              "%xmm2"
              backend-state)
            (owned_view.compiler-owned-shared-view dst-home))]
        [load
          (try
            (be_scalar.compiler-backend-emit-load-typed-value-to-reg
              type-segment-bases
              assignments
              src
              ty
              (be_state.compiler-backend-global-shared-view reg)
              program-index))]
        (Ok
          (if (string.eq dst-home "")
            (str_cat.str-cat
              load
              (be_operand.compiler-backend-emit-store-typed-var
                assignments
                dst
                reg
                ty
                backend-state))
            load)))]
    [else
      (match (be_scalar.compiler-backend-emit-store-immediate-to-var-home
        assignments
        dst
        (be_state.compiler-backend-global-shared-view src)
        backend-state)
        [(Some asm) (Ok asm)]
        [(No)
          (let
            [dst-home : String
              (be_scalar.compiler-backend-var-register-home
                backend-state
                assignments
                dst)]
            ;; Load src straight into the destination register home (a plain movq
            ;; / leaq), skipping the %rax staging store. emit-load-value
            ;; handles var/global/global-addr sources and elides the move when src
            ;; already lives in dst's home.
            ;;
            ;; A var source can always take this path regardless of `ty`
            ;; width. Register and spill homes always hold the full normalized
            ;; 64-bit value (emit-store-var stores every scalar with a
            ;; bare `movq`, and narrowing/extension happens when the value is first
            ;; produced), so a `movq src-home, dst-home` copy needs no per-type
            ;; reload. Non-var sources (globals/global-addr loaded from memory)
            ;; still require the typed narrowing path unless they are 8 bytes.
            (if (if (string.eq dst-home "")
              false
              (match (& src)
                [(Var _) true]
                [_
                  (=
                    (be_operand.compiler-backend-type-size
                      type-segment-bases
                      ty)
                    8)]))
              (be_operand.compiler-backend-emit-load-value
                assignments
                src
                dst-home
                backend-state)
              (let
                [src-home : String
                  (be_operand.compiler-backend-value-scalar-register
                    backend-state
                    assignments
                    src)]
                ;; The mirror image of the load above, and the reason it is
                ;; worth its own arm: a register-homed source moving to a
                ;; MEMORY-homed destination is a single `movq %src, N(%rsp)`.
                ;; Routing it through the scratch instead costs an extra
                ;; instruction per store, and the P3/P7 call-hole carriers are
                ;; made of exactly this move -- their carrier is forced to a
                ;; frame slot by construction, so every crossing paid
                ;; `movq %reg, %r8 ; movq %r8, N(%rsp)` for a store x86 does in
                ;; one. The width argument is the load's, unchanged: a var's
                ;; register home already holds the normalized 64-bit value, so
                ;; the store needs no per-type narrowing -- and the narrowing
                ;; the scratch path did emit went into the SCRATCH, which is
                ;; why it could not simply be dropped there.
                ;;
                ;; `compiler-backend-value-scalar-register` answers non-empty
                ;; only for a var with a plain Register home (never a pair,
                ;; never a forwarded AddrOf), so this arm needs no scratch at
                ;; all and asks the scavenger for none: strictly fewer
                ;; registers are touched than the plan reserved.
                (if (and (string.eq dst-home "") (not (string.eq src-home "")))
                  (Ok
                    (be_operand.compiler-backend-emit-store-typed-var
                      assignments
                      dst
                      src-home
                      ty
                      backend-state))
                  (let
                    [exclude : (__tl_dyn-array String)
                      (if (string.eq src-home "")
                        (__tl_make-array String 0)
                        (be_operand.compiler-backend-one-exclude
                          (be_state.compiler-backend-global-shared-view
                            src-home)))]
                    [exclude-n : i64
                      (if (string.eq src-home "")
                        0
                        1)]
                    [reg : String
                      (be_operand.compiler-backend-scavenge-reg
                        dst
                        exclude
                        exclude-n
                        "%r8"
                        backend-state)]
                    [load
                      (try
                        (be_scalar.compiler-backend-emit-load-typed-value-to-reg
                          type-segment-bases
                          assignments
                          src
                          ty
                          (be_state.compiler-backend-global-shared-view reg)
                          program-index))]
                    (Ok
                      (str_cat.str-cat
                        load
                        (be_operand.compiler-backend-emit-store-typed-var
                          assignments
                          dst
                          reg
                          ty
                          backend-state))))))))])]))

;; Dead result-store elision (M-B): a call must be emitted for its effects, but
;; when its dst var is slot-homed (no register/pair home) AND never read in the
;; final IR (compiler-backend-var-never-used?), the store of the return
;; register(s) into the frame slot(s) is dead -- nothing reloads the slot, no
;; AddrOf aliases it, and no runtime walk observes frames. Register-homed dsts
;; keep their store: the scavenge occupancy model may treat the home register
;; as holding the value across its (empty) interval, so leave those untouched.
(define (compiler-backend-call-result-store-dead?
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]) : bool
  (and
    (compiler-backend-var-never-used? backend-state dst)
    (match (be_operand.compiler-backend-emit-assignment-lookup
      backend-state
      assignments
      dst)
      [(Some location)
        (match location
          [(Spill _) true]
          [_ false])]
      [(No) true])))

;; Scalar/float call-result store through the dead-elision gate: the syscall
;; and C-ABI indirect-call paths store %rax/%xmm0 inline rather than via
;; emit-call-result-store; route their stores through the same deadness check.
(define (compiler-backend-emit-call-result-store-reg-normalize
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [reg : String]
  [ty : compiler_ast_types.AstType]
  [normalize? : bool]
  [backend-state : be_state.CompilerBackendState]) : String
  (if (compiler-backend-call-result-store-dead? backend-state assignments dst)
    ""
    (str_cat.str-cat
      (compiler-backend-call-result-normalize normalize? reg ty)
      (be_operand.compiler-backend-emit-store-typed-var
        assignments
        dst
        reg
        ty
        backend-state))))

(define (compiler-backend-emit-call-result-store-reg
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [reg : String]
  [ty : compiler_ast_types.AstType]
  [backend-state : be_state.CompilerBackendState]) : String
  (compiler-backend-emit-call-result-store-reg-normalize
    assignments
    dst
    reg
    ty
    false
    backend-state))

(define (compiler-backend-emit-c-abi-call-result-store-reg
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [reg : String]
  [ty : compiler_ast_types.AstType]
  [backend-state : be_state.CompilerBackendState]) : String
  (compiler-backend-emit-call-result-store-reg-normalize
    assignments
    dst
    reg
    ty
    true
    backend-state))

(define (compiler-backend-call-result-normalize
  [normalize? : bool]
  [reg : (& reg str)]
  [ty : (& ty compiler_ast_types.AstType)]) : String
  (if (and normalize? (string.eq reg "%rax"))
    (match ty
      [(Bool) "    movzbl %al, %eax\n"]
      [_ ""])
    ""))

(define (compiler-backend-emit-call-result-store
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [ty : compiler_ast_types.AstType]
  [vars : i64]
  [program-index : be_state.CompilerBackendProgramIndex]) : be_state.ResultCompilerBackend
  (compiler-backend-emit-call-result-store-normalize
    type-segment-bases
    assignments
    dst
    ty
    vars
    program-index
    false))

(define (compiler-backend-emit-call-result-store-normalize
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [ty : compiler_ast_types.AstType]
  [vars : i64]
  [program-index : be_state.CompilerBackendProgramIndex]
  [normalize? : bool]) : be_state.ResultCompilerBackend
  (if (compiler-backend-call-result-store-dead?
    program-index.backend-state
    assignments
    dst)
    (Ok "")
    (compiler-backend-emit-call-result-store-live
      type-segment-bases
      assignments
      dst
      ty
      vars
      program-index
      normalize?)))

(define (compiler-backend-emit-call-result-store-live
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [ty : compiler_ast_types.AstType]
  [vars : i64]
  [program-index : be_state.CompilerBackendProgramIndex]
  [normalize? : bool]) : be_state.ResultCompilerBackend
  (if (be_facts.compiler-backend-group-type?
    type-segment-bases
    program-index
    ty)
    (be_scalar.compiler-backend-emit-group-store
      type-segment-bases
      assignments
      dst
      (be_scalar.compiler-backend-group-return-reg
        type-segment-bases
        program-index
        (be_state.compiler-backend-global-shared-view ty)
        0)
      (be_scalar.compiler-backend-group-return-reg
        type-segment-bases
        program-index
        (be_state.compiler-backend-global-shared-view ty)
        1)
      vars
      ty
      program-index
      program-index.backend-state)
    (Ok
      (let
        [reg : String
          (if (be_operand.compiler-backend-float-type? ty)
            "%xmm0"
            "%rax")]
        (str_cat.str-cat
          (compiler-backend-call-result-normalize normalize? reg ty)
          (be_operand.compiler-backend-emit-store-typed-var
            assignments
            dst
            reg
            ty
            program-index.backend-state))))))

;; Append-form of the result store for callers that already own a sequence
;; buffer (the direct/indirect call emitters). The group store keeps the String
;; emitter -- it is a cold two-word path -- and its text goes in with one
;; append.
(define (compiler-backend-emit-call-result-store-normalize-into
  [out : (&mut out be_state.CompilerBackendAsmBuf)]
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [ty : compiler_ast_types.AstType]
  [vars : i64]
  [program-index : be_state.CompilerBackendProgramIndex]
  [normalize? : bool]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (compiler-backend-call-result-store-dead? backend-state assignments dst)
    (Ok "")
    (if (be_facts.compiler-backend-group-type?
      type-segment-bases
      program-index
      ty)
      (let
        [store
          (try
            (be_scalar.compiler-backend-emit-group-store
              type-segment-bases
              assignments
              dst
              (be_scalar.compiler-backend-group-return-reg
                type-segment-bases
                program-index
                (be_state.compiler-backend-global-shared-view ty)
                0)
              (be_scalar.compiler-backend-group-return-reg
                type-segment-bases
                program-index
                (be_state.compiler-backend-global-shared-view ty)
                1)
              vars
              ty
              program-index
              backend-state))]
        (be_state.compiler-backend-asm-append out store)
        (Ok ""))
      (let
        [reg : String
          (if (be_operand.compiler-backend-float-type? ty)
            "%xmm0"
            "%rax")]
        (be_state.compiler-backend-asm-append
          out
          (compiler-backend-call-result-normalize normalize? reg ty))
        (compiler-backend-emit-store-typed-var-into
          out
          assignments
          dst
          reg
          ty
          backend-state)
        (Ok "")))))

(define (compiler-backend-tls-current-arena-call-id? [name-id : i64]) : bool
  (cbi.compiler-builtin-backend-tls-current-arena-call-id? name-id))

;; The intrinsics keep their contract of 0 for "no arena" while the slot holds
;; the null-arena sentinel instead: a load reports the sentinel as 0 (by moving
;; in the sentinel's own zero first word) and a store of 0 installs it. They
;; stand in for a call, so %r11 is free.
(define (compiler-backend-tls-current-arena-inline-asm
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [name-id : i64]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]) : be_state.ResultCompilerBackend
  (cond
    [(cbi.compiler-builtin-backend-tls-current-arena-load-id? name-id)
      (Ok
        (str_cat.str-cat
          (be_facts.compiler-backend-current-arena-load target "%rax")
          "    testb $16, 48(%rax)
    cmovnzq .L_tl_null_arena(%rip), %rax
"))]
    [(cbi.compiler-builtin-backend-tls-current-arena-store-id? name-id)
      (match (be_facts.compiler-backend-target-arg-reg target convention 0)
        [(Ok reg)
          (Ok
            (str_cat.str-cat
              "    leaq .L_tl_null_arena(%rip), %r11\n    testq "
              reg
              ", "
              reg
              "\n    cmovzq %r11, "
              reg
              "\n"
              (be_facts.compiler-backend-current-arena-store target reg)))]
        [(Err message)
          (be_state.compiler-backend-instr-error instr-diag message)])]
    [else
      (be_state.compiler-backend-instr-error
        instr-diag
        "backend: unknown tls current arena helper")]))

(define (compiler-backend-emit-inline-tls-current-arena-call-with-arg-assignments
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [arg-assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [name : i64]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [ty : compiler_ast_types.AstType]
  [types : compiler_regalloc.CompilerRegVarTypes]
  [global-types : be_state.CompilerBackendGlobalTypeTable]
  [_externs : compiler_ir_types.CompilerIrExternSeq]
  [program-index : be_state.CompilerBackendProgramIndex]
  [vars : i64]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [extern-call-info : i64
      (be_operand.compiler-backend-index-extern-call-info program-index name)]
    [param-types : compiler_ast_types.AstTypeList
      (compiler-backend-call-param-types-for-call
        type-segment-bases
        name
        (be_state.compiler-backend-global-shared-view args)
        types
        global-types
        extern-call-info
        program-index)]
    [c-abi? : bool
      (be_facts.compiler-backend-extern-call-info-aggregate-params?
        extern-call-info)]
    [call-space : i64
      (be_operand.compiler-backend-call-arg-space
        target
        args
        param-types
        c-abi?
        program-index)]
    (match (compiler-backend-emit-call-args-with-override
      type-segment-bases
      (be_simd.compiler-backend-function-state-rax-forward-pending-var
        backend-state)
      target
      convention
      arg-assignments
      args
      param-types
      c-abi?
      0
      0
      0
      0
      0
      (be_state.compiler-backend-global-shared-view instr-diag)
      program-index
      vars
      backend-state)
      [(Ok args-asm)
        (match (compiler-backend-emit-call-result-store
          type-segment-bases
          assignments
          dst
          ty
          vars
          program-index)
          [(Ok result-store)
            (match (compiler-backend-tls-current-arena-inline-asm
              target
              convention
              name
              (be_state.compiler-backend-global-shared-view instr-diag))
              [(Ok inline-asm)
                (Ok
                  (str_cat.str-cat
                    (be_operand.compiler-backend-emit-call-space-sub call-space)
                    args-asm
                    inline-asm
                    (be_operand.compiler-backend-emit-call-space-add call-space)
                    result-store))]
              [(Err message)
                (be_state.compiler-backend-instr-error-from instr-diag message)])]
          [(Err message)
            (be_state.compiler-backend-instr-error-from instr-diag message)])]
      [(Err message)
        (be_state.compiler-backend-instr-error-from instr-diag message)])))

(define (compiler-backend-atomic-i32-call? [name : (& name str)]) : bool
  (or
    (string.eq name "tl_atomic_i32_load_ptr")
    (string.eq name "tl_atomic_i32_store_ptr")
    (string.eq name "tl_atomic_i32_add_ptr")
    (string.eq name "tl_atomic_i32_fetch_add_ptr")
    (string.eq name "tl_atomic_i32_cas_ptr")))

(define (compiler-backend-atomic-op-load? [name : (& name str)]) : bool
  (or
    (string.eq name "tl_atomic_i64_load_ptr")
    (string.eq name "tl_atomic_i32_load_ptr")))

(define (compiler-backend-atomic-op-store? [name : (& name str)]) : bool
  (or
    (string.eq name "tl_atomic_i64_store_ptr")
    (string.eq name "tl_atomic_i32_store_ptr")))

(define (compiler-backend-atomic-op-add? [name : (& name str)]) : bool
  (or
    (string.eq name "tl_atomic_i64_add_ptr")
    (string.eq name "tl_atomic_i32_add_ptr")))

(define (compiler-backend-atomic-op-fetch-add? [name : String]) : bool
  (or
    (string.eq name "tl_atomic_i64_fetch_add_ptr")
    (string.eq name "tl_atomic_i32_fetch_add_ptr")))

(define (compiler-backend-atomic-ptr-reg
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]) : String
  (compiler_abi.compiler-abi-gp-arg-register
    (be_state.compiler-backend-target-abi target)
    convention
    0))

(define (compiler-backend-atomic-value-reg
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [i32? : bool]) : String
  (compiler-backend-atomic-arg-reg target convention 1 i32?))

(define (compiler-backend-atomic-new-reg
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [i32? : bool]) : String
  (compiler-backend-atomic-arg-reg target convention 2 i32?))

;; An atomic builtin's operands arrive in the target ABI's integer argument
;; registers, narrowed to their 32-bit names for the i32 forms.
(define (compiler-backend-atomic-arg-reg
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [index : i64]
  [i32? : bool]) : String
  (let
    [reg : String
      (compiler_abi.compiler-abi-gp-arg-register
        (be_state.compiler-backend-target-abi target)
        convention
        index)]
    (if i32?
      (be_operand.compiler-backend-reg-part reg 4)
      reg)))

(define (compiler-backend-atomic-rax [i32? : bool]) : String
  (if i32?
    "%eax"
    "%rax"))

(define (compiler-backend-atomic-width-suffix [i32? : bool]) : String
  (if i32?
    "l"
    "q"))

(define (compiler-backend-atomic-inline-asm
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [name : String]) : String
  (let
    [i32? : bool (compiler-backend-atomic-i32-call? name)]
    [ptr : String (compiler-backend-atomic-ptr-reg target convention)]
    [value : String (compiler-backend-atomic-value-reg target convention i32?)]
    [new-value : String
      (compiler-backend-atomic-new-reg target convention i32?)]
    [rax : String (compiler-backend-atomic-rax i32?)]
    [suffix : String (compiler-backend-atomic-width-suffix i32?)]
    (cond
      [(compiler-backend-atomic-op-load? name)
        (str_cat.str-cat "    mov" suffix " (" ptr "), " rax "\n")]
      [(compiler-backend-atomic-op-store? name)
        (str_cat.str-cat "    xchg" suffix " " value ", (" ptr ")\n")]
      [(compiler-backend-atomic-op-add? name)
        (str_cat.str-cat "    lock add" suffix " " value ", (" ptr ")\n")]
      [(compiler-backend-atomic-op-fetch-add? name)
        (str_cat.str-cat
          "    mov"
          suffix
          " "
          value
          ", "
          rax
          "\n    lock xadd"
          suffix
          " "
          rax
          ", ("
          ptr
          ")\n")]
      [else
        (str_cat.str-cat
          "    mov"
          suffix
          " "
          value
          ", "
          rax
          "\n    lock cmpxchg"
          suffix
          " "
          new-value
          ", ("
          ptr
          ")\n")])))

(define (compiler-backend-volatile-i32-call? [name : (& name str)]) : bool
  (or
    (string.eq name "tl_volatile_i32_load_ptr")
    (string.eq name "tl_volatile_i32_store_ptr")))

(define (compiler-backend-volatile-op-load? [name : String]) : bool
  (or
    (string.eq name "tl_volatile_i64_load_ptr")
    (string.eq name "tl_volatile_i32_load_ptr")))

(define (compiler-backend-volatile-inline-asm
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [name : String]) : String
  (let
    [i32? : bool (compiler-backend-volatile-i32-call? name)]
    [ptr : String (compiler-backend-atomic-ptr-reg target convention)]
    [value : String (compiler-backend-atomic-value-reg target convention i32?)]
    [rax : String (compiler-backend-atomic-rax i32?)]
    [suffix : String (compiler-backend-atomic-width-suffix i32?)]
    (if (compiler-backend-volatile-op-load? name)
      (str_cat.str-cat "    mov" suffix " (" ptr "), " rax "\n")
      (str_cat.str-cat "    mov" suffix " " value ", (" ptr ")\n"))))

(define (compiler-backend-inline-memory-call-target
  [name : String]
  [call-symbol : String]) : String
  (if (be_facts.compiler-backend-inline-memory-call-name? name)
    name
    call-symbol))

(define (compiler-backend-inline-memory-call-asm
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [name : String]) : String
  (if (be_facts.compiler-backend-atomic-call-name? name)
    (compiler-backend-atomic-inline-asm target convention name)
    (compiler-backend-volatile-inline-asm target convention name)))

(define (compiler-backend-emit-inline-memory-helper-function
  [target : be_state.CompilerBackendTarget]
  [symbol : String]
  [inline-name : String]) : String
  (str_cat.str-cat
    ;; These finite atomic/volatile leaves use at most three shared GP argument
    ;; slots and common volatile registers. Both ABIs can enter the same bytes;
    ;; in particular, Windows RSI/RDI are untouched and no bridge is needed.
    (if (string.eq (& symbol) (& inline-name))
      ""
      (str_cat.str-cat ".globl " inline-name "\n" inline-name ":\n"))
    ".globl "
    symbol
    "\n"
    (be_operand.compiler-backend-emit-function-type-directive target symbol)
    symbol
    ":\n"
    (compiler-backend-inline-memory-call-asm target (Internal) inline-name)
    "    ret\n"
    (be_operand.compiler-backend-emit-function-size-directive target symbol)))

(define (compiler-backend-emit-inline-memory-call-with-arg-assignments
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [arg-assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [name : i64]
  [inline-name : String]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [ty : compiler_ast_types.AstType]
  [types : compiler_regalloc.CompilerRegVarTypes]
  [global-types : be_state.CompilerBackendGlobalTypeTable]
  [_externs : compiler_ir_types.CompilerIrExternSeq]
  [program-index : be_state.CompilerBackendProgramIndex]
  [vars : i64]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [extern-call-info : i64
      (be_operand.compiler-backend-index-extern-call-info program-index name)]
    [param-types : compiler_ast_types.AstTypeList
      (compiler-backend-call-param-types-for-call
        type-segment-bases
        name
        (be_state.compiler-backend-global-shared-view args)
        types
        global-types
        extern-call-info
        program-index)]
    [c-abi? : bool
      (be_facts.compiler-backend-extern-call-info-aggregate-params?
        extern-call-info)]
    [call-space : i64
      (be_operand.compiler-backend-call-arg-space
        target
        args
        param-types
        c-abi?
        program-index)]
    (match (compiler-backend-emit-call-args-with-override
      type-segment-bases
      (be_simd.compiler-backend-function-state-rax-forward-pending-var
        backend-state)
      target
      convention
      arg-assignments
      args
      param-types
      c-abi?
      0
      0
      0
      0
      0
      (be_state.compiler-backend-global-shared-view instr-diag)
      program-index
      vars
      backend-state)
      [(Ok args-asm)
        (match (compiler-backend-emit-call-result-store
          type-segment-bases
          assignments
          dst
          ty
          vars
          program-index)
          [(Ok result-store)
            (Ok
              (str_cat.str-cat
                (be_operand.compiler-backend-emit-call-space-sub call-space)
                args-asm
                (compiler-backend-inline-memory-call-asm
                  target
                  convention
                  inline-name)
                (be_operand.compiler-backend-emit-call-space-add call-space)
                result-store))]
          [(Err message)
            (be_state.compiler-backend-instr-error-from instr-diag message)])]
      [(Err message)
        (be_state.compiler-backend-instr-error-from instr-diag message)])))

(define (compiler-backend-emit-direct-call-with-arg-assignments
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [function : String]
  [current-label : i64]
  [current-site : i64]
  [dst : i64]
  [name : i64]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [ty : compiler_ast_types.AstType]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [arg-assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [types : compiler_regalloc.CompilerRegVarTypes]
  [global-types : be_state.CompilerBackendGlobalTypeTable]
  [plan : be_state.CompilerBackendRuntimePlan]
  [externs : compiler_ir_types.CompilerIrExternSeq]
  [program-index : be_state.CompilerBackendProgramIndex]
  [vars : i64]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [convention : compiler_abi.CompilerCallConvention
      (compiler_regalloc.compiler-reg-direct-call-convention name)]
    [fast-alloc-size : i64
      (compiler-backend-fast-alloc-size
        (be_state.compiler-backend-global-shared-view args))]
    [call-symbol : String
      (be_operand.compiler-backend-call-symbol-index name plan program-index)]
    [inline-memory-name : String
      (if (and
        (be_state.compiler-backend-state-emission-target-policy backend-state).windows
        (be_operand.compiler-backend-index-c-export? program-index name))
        (be_operand.compiler-backend-index-extern-link-symbol
          program-index
          name)
        (compiler-backend-inline-memory-call-target
          (be_state.compiler-backend-symbol-text-index program-index name)
          (be_state.compiler-backend-global-shared-view call-symbol)))]
    (cond
      [(and
          (> fast-alloc-size 0)
          ;; An extern alias with a pointer result uses the same register ABI.
          ;; Its resolved symbol and the runtime plan below must still prove
          ;; that this is our allocator, including its shared-arena slow path.
          (or
            (cbi.compiler-builtin-backend-tl-alloc-id? name)
            (match (& ty)
              [(MutPtr _) true]
              [_ false]))
          (be_operand.compiler-backend-plan-provides-id?
            plan
            cbi.compiler-builtin-id-tl-alloc)
          (or
            (string.eq call-symbol "tl_alloc")
            (and
              (= name cbi.compiler-builtin-id-tl-alloc-global)
              (string.eq call-symbol "tl_alloc_global")
              (not
                (be_state.compiler-backend-state-optimize-for-size?
                  backend-state)))))
        (Ok
          (str_cat.str-cat
            (if (or
              (= name cbi.compiler-builtin-id-tl-alloc-global)
              (and
                (not
                  (be_state.compiler-backend-state-optimize-for-size?
                    backend-state))
                (compiler-backend-inline-fast-alloc?
                  fast-alloc-size
                  (be_state.compiler-backend-state-function-state backend-state)
                  current-label)))
              (compiler-backend-emit-inline-fast-alloc
                target
                function
                current-label
                current-site
                dst
                fast-alloc-size
                (be_operand.compiler-backend-plan-provides-id?
                  plan
                  cbi.compiler-builtin-id-tl-profile-alloc-total)
                (= name cbi.compiler-builtin-id-tl-alloc-global)
                backend-state)
              (str_cat.str-cat
                "    call "
                (compiler-backend-fast-alloc-label fast-alloc-size)
                "\n"
                ""
                ""))
            (be_operand.compiler-backend-emit-store-typed-var
              assignments
              dst
              "%rax"
              ty
              backend-state)))]
      [(and
          (compiler-backend-tls-current-arena-call-id? name)
          (not
            (be_operand.compiler-backend-index-function-defines?
              program-index
              name)))
        (compiler-backend-emit-inline-tls-current-arena-call-with-arg-assignments
          type-segment-bases
          target
          convention
          assignments
          arg-assignments
          dst
          name
          args
          ty
          types
          global-types
          externs
          program-index
          vars
          instr-diag
          backend-state)]
      [(be_facts.compiler-backend-inline-memory-call-name? inline-memory-name)
        (compiler-backend-emit-inline-memory-call-with-arg-assignments
          type-segment-bases
          target
          convention
          assignments
          arg-assignments
          dst
          name
          inline-memory-name
          args
          ty
          types
          global-types
          externs
          program-index
          vars
          instr-diag
          backend-state)]
      [else
        (let
          [extern-call-info : i64
            (be_operand.compiler-backend-index-extern-call-info
              program-index
              name)]
          [param-types : compiler_ast_types.AstTypeList
            (compiler-backend-call-param-types-for-call
              type-segment-bases
              name
              (be_state.compiler-backend-global-shared-view args)
              types
              global-types
              extern-call-info
              program-index)]
          [effective-arg-assignments : compiler_regalloc.CompilerRegAssignmentTable
            (if (compiler-backend-declared-first-call-arg-accepts-rax-forward?
              type-segment-bases
              program-index
              param-types)
              arg-assignments
              assignments)]
          ;; Dense-index override mirroring effective-arg-assignments: the
          ;; rax-forward insert reaches the arg emitters exactly when the
          ;; declared first arg accepts the forward.
          [effective-arg-override : i64
            (if (compiler-backend-declared-first-call-arg-accepts-rax-forward?
              type-segment-bases
              program-index
              param-types)
              (be_simd.compiler-backend-function-state-rax-forward-pending-var
                backend-state)
              -1)]
          [c-abi? : bool
            (be_facts.compiler-backend-extern-call-info-aggregate-params?
              extern-call-info)]
          [c-return? : bool
            (be_operand.compiler-backend-extern-call-info-c-abi?
              extern-call-info)]
          [call-space : i64
            (be_operand.compiler-backend-call-arg-space
              target
              args
              param-types
              c-abi?
              program-index)]
          ;; Route the non-tail direct call through the parallel-move wrapper (not
          ;; the raw naive emitter): a register-homed arg's source register can be
          ;; another arg's destination arg register (e.g. once mixed scalar+handle
          ;; calls leave their scalar args register-eligible), so the naive ascending
          ;; marshalling could clobber a source before it is read. The wrapper resolves
          ;; only real GP source/dest conflicts via a sound parallel move and otherwise
          ;; delegates to the byte-identical naive path (so conflict-free calls -- the
          ;; overwhelming common case -- are unchanged). Mirrors the tail-call path.
          ;; The whole call sequence (space sub, marshalled args, varargs
          ;; prologue, the call, space add, result store) goes into one
          ;; sequence buffer. `emit-call-space-sub` is a pure formatter, so
          ;; appending it before the argument emitters run leaves both the
          ;; emitted bytes and the emitters' order untouched.
          [seq : be_state.CompilerBackendAsmBuf
            (be_state.compiler-backend-asm-buf-with-capacity
              be_state.compiler-backend-asm-seq-capacity)]
          (be_state.compiler-backend-asm-append
            (&mut seq)
            (be_operand.compiler-backend-emit-call-space-sub call-space))
          (match (compiler-backend-emit-call-args-with-override-into
            (&mut seq)
            type-segment-bases
            effective-arg-override
            target
            convention
            effective-arg-assignments
            args
            (be_state.compiler-backend-global-shared-view param-types)
            c-abi?
            0
            0
            0
            0
            0
            (be_state.compiler-backend-global-shared-view instr-diag)
            program-index
            vars
            backend-state)
            [(Ok _)
              ;; `varargs-pre-call`, `emit-call-space-add` and the call line
              ;; are pure formatters over already-computed state, so emitting
              ;; them before the result store leaves the result store's own
              ;; (scavenging) emitters in the same relative order they had
              ;; against the argument emitters.
              (be_state.compiler-backend-asm-append
                (&mut seq)
                (compiler-backend-varargs-pre-call
                  type-segment-bases
                  target
                  extern-call-info
                  param-types))
              (be_state.compiler-backend-asm-append4
                (&mut seq)
                "    call "
                call-symbol
                "\n"
                (be_operand.compiler-backend-emit-call-space-add call-space))
              (match (compiler-backend-emit-call-result-store-normalize-into
                (&mut seq)
                type-segment-bases
                assignments
                dst
                ty
                vars
                program-index
                c-return?
                backend-state)
                [(Ok _) (Ok (be_state.compiler-backend-asm-buf-finish (& seq)))]
                [(Err message)
                  (be_state.compiler-backend-instr-error-from
                    instr-diag
                    message)])]
            [(Err message)
              (be_state.compiler-backend-instr-error-from instr-diag message)]))])))

(define (compiler-backend-spmd-call-arg-at
  [args : (& args compiler_ir_types.CompilerIrSpmdCallArgSeq)]
  [index : i64]) : compiler_ir_types.CompilerIrSpmdCallArg
  (if (and (>= index 0) (< index args.len))
    (owned_view.compiler-owned-element-view (& args.slots) index)
    (Arg (Uniform) Unit (Unit))))

(define (compiler-backend-spmd-class-uniform?
  [class : compiler_ir_types.CompilerIrSpmdValueClass]) : bool
  (match class
    [(Uniform) true]
    [_ false]))

(define (compiler-backend-spmd-class-varying?
  [class : compiler_ir_types.CompilerIrSpmdValueClass]) : bool
  (match class
    [(Varying) true]
    [_ false]))

(define (compiler-backend-spmd-class-mask?
  [class : compiler_ir_types.CompilerIrSpmdValueClass]) : bool
  (match class
    [(Mask) true]
    [_ false]))

(define (compiler-backend-spmd-call-values-into!
  [args : compiler_ir_types.CompilerIrSpmdCallArgSeq]
  [uniform-only : bool]
  [builder : (&mut builder compiler_ir_types.CompilerIrValueBuilder)]) : unit
  (for [index
    (iterator.range
      0
      (compiler_ir_types.compiler-ir-spmd-call-arg-seq-count args))]
    (match (compiler-backend-spmd-call-arg-at args index)
      [(Arg class value _)
        (if (or (not uniform-only) (compiler-backend-spmd-class-uniform? class))
          (compiler_ir_types.compiler-ir-value-builder-push! builder value)
          unit)
        unit])))

(define (compiler-backend-spmd-call-values
  [args : compiler_ir_types.CompilerIrSpmdCallArgSeq]
  [uniform-only : bool]) : compiler_ir_types.CompilerIrValueSeq
  (let
    [builder : compiler_ir_types.CompilerIrValueBuilder
      (compiler_ir_types.compiler-ir-value-builder-with-capacity args.len)]
    (compiler-backend-spmd-call-values-into! args uniform-only (&mut builder))
    (compiler_ir_types.compiler-ir-value-builder-to-seq builder)))

(define (compiler-backend-spmd-call-types-from
  [args : compiler_ir_types.CompilerIrSpmdCallArgSeq]
  [index : i64]
  [uniform-only : bool]) : compiler_ast_types.AstTypeList
  (if (>= index (compiler_ir_types.compiler-ir-spmd-call-arg-seq-count args))
    (compiler_ast_types.ast-type-list-new)
    (match (compiler-backend-spmd-call-arg-at args index)
      [(Arg class _ ty)
        (let
          [rest : compiler_ast_types.AstTypeList
            (compiler-backend-spmd-call-types-from
              args
              (+ index 1)
              uniform-only)]
          (if (or
            (not uniform-only)
            (compiler-backend-spmd-class-uniform? class))
            (compiler_ast_types.ast-type-cons (& ty) (& rest))
            rest))])))

(define (compiler-backend-spmd-call-class-count
  [args : compiler_ir_types.CompilerIrSpmdCallArgSeq]
  [index : i64]
  [want-mask : bool]) : i64
  (if (>= index (compiler_ir_types.compiler-ir-spmd-call-arg-seq-count args))
    0
    (match (compiler-backend-spmd-call-arg-at args index)
      [(Arg class _ _)
        (+
          (if (if want-mask
            (compiler-backend-spmd-class-mask? class)
            (compiler-backend-spmd-class-varying? class))
            1
            0)
          (compiler-backend-spmd-call-class-count args (+ index 1) want-mask))])))

(define (compiler-backend-spmd-avx2-special-count
  [args : compiler_ir_types.CompilerIrSpmdCallArgSeq]) : i64
  (+
    1
    (+
      (compiler-backend-spmd-call-class-count
        (be_state.compiler-backend-global-shared-view args)
        0
        false)
      (compiler-backend-spmd-call-class-count args 0 true))))

(define (compiler-backend-spmd-avx2-save-value
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]
  [elem-ty : compiler_ast_types.AstType]
  [mask? : bool]
  [lanes : i64]
  [offset : i64]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (if mask?
    (be_operand.compiler-backend-avx2-mask-shape-ok? lanes)
    (be_operand.compiler-backend-avx2-shape-ok? elem-ty lanes))
    (let
      [storage-ty : compiler_ast_types.AstType
        (if mask?
          (I8)
          elem-ty)]
      (match (be_operand.compiler-backend-vector-register-use
        assignments
        value
        "private AVX2 SPMD call argument"
        "ymm"
        storage-ty
        "%ymm14"
        backend-state)
        [(Ok use)
          (match use
            [(Use load-asm src)
              (Ok
                (str_cat.str-cat
                  load-asm
                  "    vmovdqu "
                  src
                  ", "
                  (string.int->string offset)
                  "(%rsp)\n"))])]
        [(Err message)
          (be_state.compiler-backend-instr-error instr-diag message)]))
    (be_operand.compiler-backend-avx2-shape-diagnostic
      type-segment-bases
      instr-diag
      (if mask?
        (Bool)
        elem-ty)
      lanes)))

(define (compiler-backend-spmd-avx2-save-args
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [args : compiler_ir_types.CompilerIrSpmdCallArgSeq]
  [index : i64]
  [special-index : i64]
  [lanes : i64]
  [base-offset : i64]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (>= index (compiler_ir_types.compiler-ir-spmd-call-arg-seq-count args))
    (Ok "")
    (match (compiler-backend-spmd-call-arg-at args index)
      [(Arg class value ty)
        (if (compiler-backend-spmd-class-uniform? class)
          (compiler-backend-spmd-avx2-save-args
            type-segment-bases
            assignments
            args
            (+ index 1)
            special-index
            lanes
            base-offset
            instr-diag
            backend-state)
          (let
            [mask? : bool (compiler-backend-spmd-class-mask? class)]
            [head
              (try
                (compiler-backend-spmd-avx2-save-value
                  type-segment-bases
                  assignments
                  value
                  ty
                  mask?
                  lanes
                  (+ base-offset (* 32 special-index))
                  (be_state.compiler-backend-global-shared-view instr-diag)
                  backend-state))]
            [tail
              (try
                (compiler-backend-spmd-avx2-save-args
                  type-segment-bases
                  assignments
                  args
                  (+ index 1)
                  (+ special-index 1)
                  lanes
                  base-offset
                  instr-diag
                  backend-state))]
            (Ok (str_cat.str-cat head tail))))])))

(define (compiler-backend-spmd-avx2-result-store
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [result : compiler_ir_types.CompilerIrSpmdCallResult]
  [vars : i64]
  [program-index : be_state.CompilerBackendProgramIndex]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (match result
    [(Unit) (Ok "")]
    [(Value dst class ty)
      (if (compiler-backend-spmd-class-uniform? class)
        (compiler-backend-emit-call-result-store
          type-segment-bases
          assignments
          dst
          ty
          vars
          program-index)
        (let
          [storage-ty : compiler_ast_types.AstType
            (if (compiler-backend-spmd-class-mask? class)
              (I8)
              ty)]
          (match (be_simd.compiler-backend-vector-dst-reg
            assignments
            dst
            "private AVX2 SPMD call result"
            "ymm"
            "%ymm14"
            backend-state)
            [(Ok home)
              (Ok
                (str_cat.str-cat
                  (if (string.eq home "%ymm0")
                    ""
                    (str_cat.str-cat "    vmovdqu %ymm0, " home "\n" ""))
                  (be_simd.compiler-backend-vector-store-dst
                    assignments
                    dst
                    "ymm"
                    storage-ty
                    home
                    backend-state)))]
            [(Err message)
              (be_state.compiler-backend-instr-error instr-diag message)])))]))

(define (compiler-backend-spmd-private-vector-args-asm
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [args : compiler_ir_types.CompilerIrSpmdCallArgSeq]
  [index : i64]
  [vector-index : i64]
  [lanes : i64]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (>= index (compiler_ir_types.compiler-ir-spmd-call-arg-seq-count args))
    (Ok "")
    (match (compiler-backend-spmd-call-arg-at args index)
      [(Arg class value ty)
        (if (compiler-backend-spmd-class-varying? class)
          (let
            [dst : String
              (compiler-backend-spmd-private-vector-arg-reg vector-index)]
            (if (= (string.string-length dst) 0)
              (be_state.compiler-backend-instr-error
                instr-diag
                "backend: private AVX-512 SPMD call supports at most 8 varying value arguments")
              (if (not (be_operand.compiler-backend-avx512-shape-ok? ty lanes))
                (be_operand.compiler-backend-avx512-shape-diagnostic
                  type-segment-bases
                  instr-diag
                  ty
                  lanes)
                (match (be_operand.compiler-backend-vector-register-use
                  assignments
                  value
                  "private SPMD call argument"
                  "zmm"
                  ty
                  "%zmm14"
                  backend-state)
                  [(Ok use)
                    (match use
                      [(Use load-asm src)
                        (let
                          [tail
                            (try
                              (compiler-backend-spmd-private-vector-args-asm
                                type-segment-bases
                                assignments
                                args
                                (+ index 1)
                                (+ vector-index 1)
                                lanes
                                instr-diag
                                backend-state))]
                          (Ok
                            (str_cat.str-cat
                              load-asm
                              (if (string.eq src dst)
                                ""
                                (str_cat.str-cat
                                  "    "
                                  (be_operand.compiler-backend-avx512-vector-move
                                    ty)
                                  " "
                                  src
                                  ", "
                                  dst
                                  "\n"))
                              tail)))])]
                  [(Err message)
                    (be_state.compiler-backend-instr-error instr-diag message)]))))
          (compiler-backend-spmd-private-vector-args-asm
            type-segment-bases
            assignments
            args
            (+ index 1)
            vector-index
            lanes
            instr-diag
            backend-state))])))

(define (compiler-backend-spmd-private-save-mask-value
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]
  [lanes : i64]
  [offset : i64]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (match (be_simd.compiler-backend-avx512-mask-source-into-gpr
    assignments
    value
    "private SPMD call mask"
    lanes
    (be_simd.compiler-backend-avx512-mask-gpr-part "%rax" lanes)
    backend-state)
    [(Ok use)
      (match use
        [(Use load-asm _)
          (Ok
            (str_cat.str-cat
              load-asm
              "    movq %rax, "
              (string.int->string offset)
              "(%rsp)\n"
              ""))])]
    [(Err message) (be_state.compiler-backend-instr-error instr-diag message)]))

(define (compiler-backend-spmd-private-save-mask-args
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [args : compiler_ir_types.CompilerIrSpmdCallArgSeq]
  [index : i64]
  [mask-index : i64]
  [lanes : i64]
  [base-offset : i64]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (>= index (compiler_ir_types.compiler-ir-spmd-call-arg-seq-count args))
    (Ok "")
    (match (compiler-backend-spmd-call-arg-at args index)
      [(Arg class value _)
        (if (compiler-backend-spmd-class-mask? class)
          (if (>= mask-index 5)
            (be_state.compiler-backend-instr-error
              instr-diag
              "backend: private AVX-512 SPMD call supports at most 5 varying bool arguments")
            (let
              [head
                (try
                  (compiler-backend-spmd-private-save-mask-value
                    assignments
                    value
                    lanes
                    (+ base-offset (* 8 (+ mask-index 1)))
                    (be_state.compiler-backend-global-shared-view instr-diag)
                    backend-state))]
              [tail
                (try
                  (compiler-backend-spmd-private-save-mask-args
                    assignments
                    args
                    (+ index 1)
                    (+ mask-index 1)
                    lanes
                    base-offset
                    instr-diag
                    backend-state))]
              (Ok (str_cat.str-cat head tail))))
          (compiler-backend-spmd-private-save-mask-args
            assignments
            args
            (+ index 1)
            mask-index
            lanes
            base-offset
            instr-diag
            backend-state))])))

(define (compiler-backend-spmd-private-load-mask-args
  [mask-count : i64]
  [mask-index : i64]
  [base-offset : i64]) : String
  (if (>= mask-index mask-count)
    ""
    (str_cat.str-cat
      "    kmovq "
      (string.int->string (+ base-offset (* 8 (+ mask-index 1))))
      "(%rsp), "
      (compiler-backend-spmd-private-mask-arg-reg mask-index)
      "\n"
      (compiler-backend-spmd-private-load-mask-args
        mask-count
        (+ mask-index 1)
        base-offset))))

(define (compiler-backend-spmd-private-result-store
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [result : compiler_ir_types.CompilerIrSpmdCallResult]
  [vars : i64]
  [program-index : be_state.CompilerBackendProgramIndex]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (match result
    [(Unit) (Ok "")]
    [(Value dst class ty)
      (match class
        [(Uniform)
          (compiler-backend-emit-call-result-store
            type-segment-bases
            assignments
            dst
            ty
            vars
            program-index)]
        [(Varying)
          (match (be_simd.compiler-backend-vector-dst-reg
            assignments
            dst
            "private SPMD call result"
            "zmm"
            "%zmm14"
            backend-state)
            [(Ok home)
              (Ok
                (str_cat.str-cat
                  (if (string.eq home "%zmm16")
                    ""
                    (str_cat.str-cat
                      "    "
                      (be_operand.compiler-backend-avx512-vector-move ty)
                      " %zmm16, "
                      home
                      "\n"))
                  (be_simd.compiler-backend-vector-store-dst
                    assignments
                    dst
                    "zmm"
                    ty
                    home
                    backend-state)))]
            [(Err message)
              (be_state.compiler-backend-instr-error instr-diag message)])]
        [(Mask)
          (match (be_simd.compiler-backend-avx512-mask-dst-reg
            assignments
            dst
            "private SPMD call mask result"
            "%k7"
            backend-state)
            [(Ok home)
              (Ok
                (str_cat.str-cat
                  (if (string.eq home "%k1")
                    ""
                    (str_cat.str-cat "    kmovq %k1, " home "\n" ""))
                  (be_simd.compiler-backend-avx512-mask-store-dst
                    assignments
                    dst
                    64
                    home
                    backend-state)
                  ""))]
            [(Err message)
              (be_state.compiler-backend-instr-error instr-diag message)])])]))

(define (compiler-backend-emit-spmd-call-scalar
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [name : i64]
  [active-mask : compiler_ir_types.CompilerIrValue]
  [args : compiler_ir_types.CompilerIrSpmdCallArgSeq]
  [result : compiler_ir_types.CompilerIrSpmdCallResult]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [plan : be_state.CompilerBackendRuntimePlan]
  [program-index : be_state.CompilerBackendProgramIndex]
  [vars : i64]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [values : compiler_ir_types.CompilerIrValueSeq
      (compiler_ir_types.compiler-ir-value-seq-prepend
        (& active-mask)
        (&
          (compiler-backend-spmd-call-values
            (be_state.compiler-backend-global-shared-view args)
            false)))]
    [call-args : compiler_ir_types.CompilerIrCallArgs
      (compiler_ir_types.compiler-ir-call-args-from-seq (& values))]
    [param-types : compiler_ast_types.AstTypeList
      (compiler_ast_types.ast-type-cons
        (& (Bool))
        (& (compiler-backend-spmd-call-types-from args 0 false)))]
    [call-space : i64
      (be_operand.compiler-backend-call-arg-space
        target
        call-args
        param-types
        false
        program-index)]
    [args-asm
      (try
        (compiler-backend-emit-call-args
          type-segment-bases
          target
          (Internal)
          assignments
          call-args
          param-types
          false
          0
          0
          0
          0
          0
          instr-diag
          program-index
          vars
          backend-state))]
    [result-asm
      (try
        (match result
          [(Unit) (be_state.ResultCompilerBackend.Ok "")]
          [(Value dst _ ty)
            (compiler-backend-emit-call-result-store
              type-segment-bases
              assignments
              dst
              ty
              vars
              program-index)]))]
    (Ok
      (str_cat.str-cat
        (be_operand.compiler-backend-emit-call-space-sub call-space)
        args-asm
        "    call "
        (be_operand.compiler-backend-call-symbol-index name plan program-index)
        "\n"
        (be_operand.compiler-backend-emit-call-space-add call-space)
        result-asm))))

(define (compiler-backend-emit-spmd-call-avx512
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [name : i64]
  [lanes : i64]
  [active-mask : compiler_ir_types.CompilerIrValue]
  [args : compiler_ir_types.CompilerIrSpmdCallArgSeq]
  [result : compiler_ir_types.CompilerIrSpmdCallResult]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [plan : be_state.CompilerBackendRuntimePlan]
  [program-index : be_state.CompilerBackendProgramIndex]
  [vars : i64]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [uniform-values : compiler_ir_types.CompilerIrValueSeq
      (compiler-backend-spmd-call-values
        (be_state.compiler-backend-global-shared-view args)
        true)]
    [uniform-args : compiler_ir_types.CompilerIrCallArgs
      (compiler_ir_types.compiler-ir-call-args-from-seq (& uniform-values))]
    [uniform-types : compiler_ast_types.AstTypeList
      (compiler-backend-spmd-call-types-from
        (be_state.compiler-backend-global-shared-view args)
        0
        true)]
    ;; The private mask block lives below the ordinary outgoing call layout.
    ;; This includes Win64's callee-owned shadow space and every stack-passed
    ;; uniform argument, so neither the callee nor emit-call-args can overwrite
    ;; masks while the call is active.
    [call-space : i64
      (compiler-backend-call-stack-arg-layout-space
        type-segment-bases
        target
        (Internal)
        (be_state.compiler-backend-global-shared-view uniform-args)
        (be_state.compiler-backend-global-shared-view uniform-types)
        false
        program-index)]
    [mask-count : i64
      (compiler-backend-spmd-call-class-count
        (be_state.compiler-backend-global-shared-view args)
        0
        true)]
    [mask-bytes : i64 (* 8 (+ mask-count 1))]
    [mask-space : i64 (* 16 (/ (+ mask-bytes 15) 16))]
    [total-space : i64 (+ call-space mask-space)]
    [uniform-asm
      (try
        (compiler-backend-emit-call-args
          type-segment-bases
          target
          (Internal)
          assignments
          uniform-args
          uniform-types
          false
          0
          0
          0
          0
          0
          instr-diag
          program-index
          vars
          program-index.backend-state))]
    [vector-asm
      (try
        (compiler-backend-spmd-private-vector-args-asm
          type-segment-bases
          assignments
          (be_state.compiler-backend-global-shared-view args)
          0
          0
          lanes
          (be_state.compiler-backend-global-shared-view instr-diag)
          backend-state))]
    [active-save
      (try
        (compiler-backend-spmd-private-save-mask-value
          assignments
          active-mask
          lanes
          call-space
          (be_state.compiler-backend-global-shared-view instr-diag)
          backend-state))]
    [mask-saves
      (try
        (compiler-backend-spmd-private-save-mask-args
          assignments
          args
          0
          0
          lanes
          call-space
          (be_state.compiler-backend-global-shared-view instr-diag)
          backend-state))]
    [result-asm
      (try
        (compiler-backend-spmd-private-result-store
          type-segment-bases
          assignments
          result
          vars
          program-index
          instr-diag
          backend-state))]
    (Ok
      (str_cat.str-cat
        (be_operand.compiler-backend-emit-call-space-sub total-space)
        active-save
        mask-saves
        "    kmovq "
        (string.int->string call-space)
        "(%rsp), %k1\n"
        (compiler-backend-spmd-private-load-mask-args mask-count 0 call-space)
        uniform-asm
        vector-asm
        "    call "
        (be_operand.compiler-backend-call-symbol-index name plan program-index)
        "\n"
        (be_operand.compiler-backend-emit-call-space-add total-space)
        result-asm))))

(define (compiler-backend-emit-spmd-call-avx2
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [name : i64]
  [lanes : i64]
  [active-mask : compiler_ir_types.CompilerIrValue]
  [args : compiler_ir_types.CompilerIrSpmdCallArgSeq]
  [result : compiler_ir_types.CompilerIrSpmdCallResult]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [plan : be_state.CompilerBackendRuntimePlan]
  [program-index : be_state.CompilerBackendProgramIndex]
  [vars : i64]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [uniform-values : compiler_ir_types.CompilerIrValueSeq
      (compiler-backend-spmd-call-values
        (be_state.compiler-backend-global-shared-view args)
        true)]
    [uniform-args : compiler_ir_types.CompilerIrCallArgs
      (compiler_ir_types.compiler-ir-call-args-from-seq (& uniform-values))]
    [uniform-types : compiler_ast_types.AstTypeList
      (compiler-backend-spmd-call-types-from
        (be_state.compiler-backend-global-shared-view args)
        0
        true)]
    ;; Keep the private vector block disjoint from ordinary outgoing storage.
    ;; Win64 callees own the first 32 bytes at %rsp, and uniform arguments on
    ;; either ABI may occupy stack slots beyond their register banks.
    [call-space : i64
      (compiler-backend-call-stack-arg-layout-space
        type-segment-bases
        target
        (Internal)
        (be_state.compiler-backend-global-shared-view uniform-args)
        (be_state.compiler-backend-global-shared-view uniform-types)
        false
        program-index)]
    [special-space : i64
      (*
        32
        (compiler-backend-spmd-avx2-special-count
          (be_state.compiler-backend-global-shared-view args)))]
    [total-space : i64 (+ call-space special-space)]
    [uniform-asm
      (try
        (compiler-backend-emit-call-args
          type-segment-bases
          target
          (Internal)
          assignments
          uniform-args
          uniform-types
          false
          0
          0
          0
          0
          0
          instr-diag
          program-index
          vars
          program-index.backend-state))]
    [active-save
      (try
        (compiler-backend-spmd-avx2-save-value
          type-segment-bases
          assignments
          active-mask
          (I8)
          true
          lanes
          call-space
          (be_state.compiler-backend-global-shared-view instr-diag)
          backend-state))]
    [arg-saves
      (try
        (compiler-backend-spmd-avx2-save-args
          type-segment-bases
          assignments
          args
          0
          1
          lanes
          call-space
          (be_state.compiler-backend-global-shared-view instr-diag)
          backend-state))]
    [result-asm
      (try
        (compiler-backend-spmd-avx2-result-store
          type-segment-bases
          assignments
          result
          vars
          program-index
          instr-diag
          backend-state))]
    (Ok
      (str_cat.str-cat
        (be_operand.compiler-backend-emit-call-space-sub total-space)
        active-save
        arg-saves
        uniform-asm
        "    leaq "
        (string.int->string call-space)
        "(%rsp), %r10\n    call "
        (be_operand.compiler-backend-call-symbol-index name plan program-index)
        "\n"
        (be_operand.compiler-backend-emit-call-space-add total-space)
        result-asm))))

(define (compiler-backend-emit-spmd-call
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [name : i64]
  [backend : compiler_ir_types.CompilerIrSpmdBackend]
  [lanes : i64]
  [active-mask : compiler_ir_types.CompilerIrValue]
  [args : compiler_ir_types.CompilerIrSpmdCallArgSeq]
  [result : compiler_ir_types.CompilerIrSpmdCallResult]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [plan : be_state.CompilerBackendRuntimePlan]
  [program-index : be_state.CompilerBackendProgramIndex]
  [vars : i64]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (match backend
    [(Scalar)
      (compiler-backend-emit-spmd-call-scalar
        type-segment-bases
        target
        name
        active-mask
        args
        result
        assignments
        plan
        program-index
        vars
        instr-diag
        backend-state)]
    [(Avx512)
      (compiler-backend-emit-spmd-call-avx512
        type-segment-bases
        target
        name
        lanes
        active-mask
        args
        result
        assignments
        plan
        program-index
        vars
        instr-diag
        backend-state)]
    [(Avx2)
      (compiler-backend-emit-spmd-call-avx2
        type-segment-bases
        target
        name
        lanes
        active-mask
        args
        result
        assignments
        plan
        program-index
        vars
        instr-diag
        backend-state)]))

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
  (str_cat.str-cat (string.int->string offset) "(" base-reg ")"))

(define (compiler-backend-emit-c-abi-return-slot-store
  [type-segment-bases : i64]
  [base-reg : String]
  [slot : compiler_ir_types.CompilerIrCAbiReturnSlot]
  [int-idx : i64]
  [sse-idx : i64]) : String
  (match slot
    [(Slot ty offset)
      (let
        [sse? : bool (be_operand.compiler-backend-float-type? ty)]
        [reg : String
          (if sse?
            (compiler-backend-c-abi-return-sse-reg sse-idx)
            (compiler-backend-c-abi-return-int-reg int-idx))]
        [addr : String
          (compiler-backend-c-abi-return-slot-addr base-reg offset)]
        (if sse?
          (be_scalar.compiler-backend-emit-store-xmm-to-memory addr reg ty)
          (be_scalar.compiler-backend-emit-store-reg-to-memory
            type-segment-bases
            addr
            reg
            ty)))]))

(define (compiler-backend-emit-c-abi-return-slot-stores
  [type-segment-bases : i64]
  [base-reg : String]
  [slots : compiler_ir_types.CompilerIrCAbiReturnSlotSeq]
  [int-idx : i64]
  [sse-idx : i64]) : String
  (compiler-backend-emit-c-abi-return-slot-stores-array
    type-segment-bases
    base-reg
    slots.slots
    0
    slots.len
    int-idx
    sse-idx))

(define (compiler-backend-emit-c-abi-return-slot-stores-array
  [type-segment-bases : i64]
  [base-reg : String]
  [slots : (__tl_dyn-array compiler_ir_types.CompilerIrCAbiReturnSlot)]
  [index : i64]
  [count : i64]
  [int-idx : i64]
  [sse-idx : i64]) : String
  (if (>= index count)
    ""
    (let
      [slot : compiler_ir_types.CompilerIrCAbiReturnSlot
        (be_state.compiler-backend-global-array-element-shared-view slots index)]
      (match (be_state.compiler-backend-global-shared-view slot)
        [(Slot ty _)
          (let
            [sse? : bool (be_operand.compiler-backend-float-type? ty)]
            (str_cat.str-cat
              (compiler-backend-emit-c-abi-return-slot-store
                type-segment-bases
                (be_state.compiler-backend-global-shared-view base-reg)
                slot
                int-idx
                sse-idx)
              (compiler-backend-emit-c-abi-return-slot-stores-array
                type-segment-bases
                base-reg
                slots
                (+ index 1)
                count
                (if sse?
                  int-idx
                  (+ int-idx 1))
                (if sse?
                  (+ sse-idx 1)
                  sse-idx))))]))))

(define (compiler-backend-scavenge-c-abi-return-base-save-reg
  [backend-state : be_state.CompilerBackendState]) : String
  (be_operand.compiler-backend-scavenge-reg-here
    (be_scalar.compiler-backend-c-abi-stage-exclude-with "%r11")
    be_scalar.compiler-backend-c-abi-stage-exclude-count
    "%r10"
    backend-state))

(define (compiler-backend-emit-c-abi-return-base-save
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [base : compiler_ir_types.CompilerIrValue]
  [save-offset : i64]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [base-reg : String
      (compiler-backend-scavenge-c-abi-return-base-save-reg backend-state)]
    [base-asm
      (try
        (be_operand.compiler-backend-emit-load-value
          assignments
          base
          (be_state.compiler-backend-global-shared-view base-reg)
          backend-state))]
    (Ok
      (str_cat.str-cat
        base-asm
        (str_cat.str-cat
          "    movq "
          base-reg
          ", "
          (string.int->string save-offset)
          "(%rsp)\n")))))

(define (compiler-backend-c-abi-return-store-base-exclude) : (__tl_dyn-array
    String)
  (__tl_make-array "%rax" "%rdx"))

(define (compiler-backend-scavenge-c-abi-return-store-base-reg
  [backend-state : be_state.CompilerBackendState]) : String
  (be_operand.compiler-backend-scavenge-reg-here
    (compiler-backend-c-abi-return-store-base-exclude)
    2
    "%r11"
    backend-state))

(define (compiler-backend-emit-c-abi-return-stores
  [type-segment-bases : i64]
  [save-offset : i64]
  [slots : compiler_ir_types.CompilerIrCAbiReturnSlotSeq]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [base-reg : String
      (compiler-backend-scavenge-c-abi-return-store-base-reg backend-state)]
    (str_cat.str-cat
      (str_cat.str-cat
        "    movq "
        (string.int->string save-offset)
        "(%rsp), "
        base-reg
        "\n")
      (compiler-backend-emit-c-abi-return-slot-stores
        type-segment-bases
        base-reg
        slots
        0
        0))))

(define (compiler-backend-assignments-use-reg?
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [reg : String]) : bool
  (compiler_regalloc.compiler-reg-assignments-use-register?
    assignments
    (compiler_abi.compiler-abi-register-id-from-spelling reg)))

(define (compiler-backend-emit-entry-load
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [label : i64]
  [ty : compiler_ast_types.AstType]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [r11-occupied : bool
      (compiler-backend-assignments-use-reg? assignments "%r11")]
    [exclude : (__tl_dyn-array String)
      (if r11-occupied
        (be_operand.compiler-backend-scavenge-exclude-append
          (be_scalar.compiler-backend-scavenge-exclude-with "%r8")
          6
          "%r11")
        (compiler-backend-c-abi-return-store-base-exclude))]
    [exclude-n : i64
      (if r11-occupied
        7
        2)]
    [scratch-reg : String
      (be_operand.compiler-backend-scavenge-reg
        dst
        exclude
        exclude-n
        "%r11"
        backend-state)]
    [scratch-asm : String
      (str_cat.str-cat
        (str_cat.str-cat
          "    movq "
          (compiler_ir_types.compiler-ir-label-text label)
          "(%rip), "
          scratch-reg
          "\n")
        (be_operand.compiler-backend-emit-store-typed-var
          assignments
          dst
          scratch-reg
          ty
          backend-state))]
    (match (be_operand.compiler-backend-emit-assignment-lookup
      backend-state
      assignments
      dst)
      [(Some location)
        (match location
          ;; Entry loads produce one pointer-sized word; aggregate register-pair
          ;; homes stay on the scratch fallback.
          [(Register home)
            (Ok
              (str_cat.str-cat
                "    movq "
                (compiler_ir_types.compiler-ir-label-text label)
                "(%rip), "
                (compiler_abi.compiler-abi-register-spelling home)
                "\n"))]
          [_ (Ok scratch-asm)])]
      [(No) (Ok scratch-asm)])))

(define (compiler-backend-cpuid-result-move [reg-index : i64]) : String
  (cond
    [(= reg-index 0) ""]
    [(= reg-index 1) "    movl %ebx, %eax\n"]
    [(= reg-index 2) "    movl %ecx, %eax\n"]
    [(= reg-index 3) "    movl %edx, %eax\n"]
    [else "    xorq %rax, %rax\n"]))

(define (compiler-backend-cpuid-operand-moves
  [leaf : compiler_ir_types.CompilerIrValue]
  [subleaf : compiler_ir_types.CompilerIrValue]) : CompilerBackendArgMoveSeq
  (let
    [out : CompilerBackendArgMoveSeq
      (compiler-backend-arg-move-seq-with-capacity 2)]
    (compiler-backend-arg-move-push!
      (&mut out)
      (BackendArgMove
        compiler_abi.compiler-reg-id-rcx
        (BackendArgMoveValue subleaf)))
    (compiler-backend-arg-move-push!
      (&mut out)
      (BackendArgMove
        compiler_abi.compiler-reg-id-rax
        (BackendArgMoveValue leaf)))
    out))

(define (compiler-backend-emit-cpuid
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [leaf : compiler_ir_types.CompilerIrValue]
  [subleaf : compiler_ir_types.CompilerIrValue]
  [reg-index : i64]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  ;; The two operand registers are allocator-pooled, so the leaf can be homed in
  ;; %rcx (every non-inlined Win64 wrapper: it is the first argument register)
  ;; or the subleaf in %rax. Two independent loads would overwrite one of them
  ;; before it is read -- `movq %rdx, %rcx; movq %rcx, %rax` runs cpuid with
  ;; the subleaf as its leaf. The call path's parallel-move solver orders the
  ;; moves and breaks a true cycle through a temp; a conflict-free site emits
  ;; the subleaf-first list as given.
  (let
    [operand-asm
      (try
        (compiler-backend-emit-arg-move-list
          assignments
          (compiler-backend-cpuid-operand-moves leaf subleaf)
          backend-state))]
    [ex : (__tl_dyn-array String) (__tl_make-array String 3)]
    (set! (array-ref ex 0) "%rcx")
    (set! (array-ref ex 1) "%rdx")
    (set! (array-ref ex 2) "%rbx")
    (let
      ;; cpuid clobbers rax/rbx/rcx/rdx; preserve the caller's %rbx in a
      ;; scavenged free reg instead of pushq/popq (the no-stack-staging
      ;; goal). rax/rsi/rdi aren't scavenge candidates, so excluding
      ;; rcx/rdx/rbx leaves the temp in {r8-r15}, none of which cpuid
      ;; touches. Falls back to %r8 / the emergency wrap if none free.
      [scav : String
        (be_operand.compiler-backend-scavenge-reg-here ex 3 "%r8" backend-state)]
      (Ok
        (str_cat.str-cat
          operand-asm
          (str_cat.str-cat "    movq %rbx, " scav "\n    cpuid\n")
          (compiler-backend-cpuid-result-move reg-index)
          (str_cat.str-cat "    movq " scav ", %rbx\n")
          (be_operand.compiler-backend-emit-store-typed-var
            assignments
            dst
            "%rax"
            (I64)
            backend-state))))))

;; Linux syscall argument register for operand position: 0=number, 1..6=args.
(define (compiler-backend-syscall-reg [pos : i64]) : i64
  (cond
    [(= pos 0) compiler_abi.compiler-reg-id-rax]
    [(= pos 1) compiler_abi.compiler-reg-id-rdi]
    [(= pos 2) compiler_abi.compiler-reg-id-rsi]
    [(= pos 3) compiler_abi.compiler-reg-id-rdx]
    [(= pos 4) compiler_abi.compiler-reg-id-r10]
    [(= pos 5) compiler_abi.compiler-reg-id-r8]
    [(= pos 6) compiler_abi.compiler-reg-id-r9]
    [else compiler_abi.compiler-reg-id-rax]))

;; Build the syscall operand -> kernel-arg-register parallel move list. The Linux
;; syscall registers (%rdi/%rsi/%rdx/%r10/%r8/%r9 for args, %rax for the number)
;; are allocator-pooled, so a source operand can already live in a kernel register
;; that a DIFFERENT operand must be moved into. Reuse the call path's BackendArgMove
;; representation so the same sound parallel-move solver
;; (compiler-backend-emit-arg-move-list) resolves any source/dest conflict. The arg
;; positions (1..n) come FIRST and the number (position 0 -> %rax) LAST: with no
;; register source/dest conflict the solver emits the moves in this list order
;; through emit-load-value.
(define (compiler-backend-syscall-arg-moves-build-from
  [args : compiler_ir_types.CompilerIrCallArgs]
  [index : i64]
  [count : i64]) : CompilerBackendArgMoveSeq
  (let
    [out : CompilerBackendArgMoveSeq
      (compiler-backend-arg-move-seq-with-capacity 0)]
    (for [i (iterator.range index count)]
      (compiler-backend-arg-move-push!
        (&mut out)
        (BackendArgMove
          (compiler-backend-syscall-reg i)
          (BackendArgMoveValue (be_facts.compiler-backend-call-arg-at args i)))))
    ;; Number-last: position 0 -> %rax is the final move in the list.
    (compiler-backend-arg-move-push!
      (&mut out)
      (BackendArgMove
        (compiler-backend-syscall-reg 0)
        (BackendArgMoveValue (be_facts.compiler-backend-call-arg-at args 0))))
    out))

(define (compiler-backend-syscall-arg-moves-build
  [args : compiler_ir_types.CompilerIrCallArgs]
  [count : i64]) : CompilerBackendArgMoveSeq
  (compiler-backend-syscall-arg-moves-build-from args 1 count))

;; `syscall` clobbers %rcx/%r11 and uses Linux syscall arg registers. The primary
;; integer pool is callee-saved, and the scalar caller-saved extension rejects
;; intervals spanning syscall points, so no live register home can be lost; the
;; raw kernel result lands in %rax -> dst. The raw `syscall` instruction and its
;; register ABI are Linux x86_64 only; emitting it for any other target would
;; silently miscompile, so reject it instead.
;;
;; The operand -> kernel-register setup goes through the SAME parallel-move solver
;; the call path uses. Now that the kernel arg registers are pooled, an operand can
;; be homed in a kernel register that is another operand's destination (incl. the
;; number's %rax). A naive ascending emit could clobber such a source before it is
;; read (the same aliasing/overwrite hazard fixed for call args); the solver
;; emits the moves in a safe order and breaks true cycles
;; with a scavenged temp. Conflict-free sites stay byte-identical (see the builder).
(define (compiler-backend-emit-syscall
  [target-policy : be_state.CompilerBackendTargetPolicy]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (not target-policy.linux-syscall)
    (Err
      (box
        (compiler_diagnostic.compiler-diagnostic-at-start
          ""
          (be_state.compiler-backend-raw-syscall-diagnostic))))
    (let
      [count : i64
        (be_facts.compiler-backend-call-args-count
          (be_state.compiler-backend-global-shared-view args))]
      [setup-asm
        (try
          (compiler-backend-emit-arg-move-list
            assignments
            (compiler-backend-syscall-arg-moves-build args count)
            backend-state))]
      (Ok
        (str_cat.str-cat
          setup-asm
          "    syscall\n"
          (compiler-backend-emit-call-result-store-reg
            assignments
            dst
            "%rax"
            (I64)
            backend-state))))))

(define (compiler-backend-total-switch-trap-instrs?
  [instrs : compiler_ir_types.CompilerIrInstrSeq]
  [label : i64]) : bool
  (and
    (= (compiler_ir_types.compiler-ir-instr-seq-count instrs) 2)
    (match (compiler_ir_types.compiler-ir-instr-seq-borrow instrs 0)
      [(Call _ name _ _) (cbi.compiler-builtin-backend-tl-oob-abort-id? name)]
      [_ false])
    (match (compiler_ir_types.compiler-ir-instr-seq-borrow instrs 1)
      [(Jump target) (= target label)]
      [_ false])))

(define (compiler-backend-total-switch-trap-block-from?
  [all-blocks : compiler_ir_types.CompilerIrBlockList]
  [cursor : (& cursor (Slice compiler_ir_types.CompilerIrBlock))]
  [label : i64]
  [trap-label : i64]
  [fuel : i64]) : bool
  (if (<= fuel 0)
    false
    (match cursor
      [(slice) false]
      [(slice block & rest)
        (match (owned_view.compiler-owned-reference-shared-view block)
          [(Block block-label instrs)
            (if (= block-label label)
              (if (= label trap-label)
                (compiler-backend-total-switch-trap-instrs? instrs label)
                ;; Loop canonicalization may retarget the default through a
                ;; jump-only preheader. The separately carried trap label is
                ;; the authority; display text is never consulted.
                (and
                  (= (compiler_ir_types.compiler-ir-instr-seq-count instrs) 1)
                  (match (compiler_ir_types.compiler-ir-instr-seq-borrow
                    instrs
                    0)
                    [(Jump target)
                      (and
                        (not (= target label))
                        (compiler-backend-total-switch-trap-block-from?
                          (be_state.compiler-backend-global-shared-view
                            all-blocks)
                          (compiler_ir_types.compiler-ir-block-list-view
                            all-blocks)
                          target
                          trap-label
                          (- fuel 1)))]
                    [_ false])))
              (compiler-backend-total-switch-trap-block-from?
                all-blocks
                rest
                label
                trap-label
                fuel))])])))

(define (compiler-backend-total-switch-trap-block?
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [label : i64]
  [trap-label : i64]) : bool
  (and
    (!= trap-label (compiler_ir_types.compiler-ir-label-none))
    (compiler-backend-total-switch-trap-block-from?
      (be_state.compiler-backend-global-shared-view blocks)
      (compiler_ir_types.compiler-ir-block-list-view blocks)
      label
      trap-label
      8)))

(define (compiler-backend-total-switch?
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [base : i64]
  [cases : (& cases compiler_ir_types.CompilerIrSwitchCaseSeq)]
  [default-label : i64]
  [trap-label : i64]) : bool
  (and
    (= base 0)
    (> (be_facts.compiler-backend-switch-case-count cases) 0)
    (be_facts.compiler-backend-switch-cases-contiguous-from? cases 0)
    (compiler-backend-total-switch-trap-block? blocks default-label trap-label)))

(define (compiler-backend-switch-default-edge-label [current-label : i64]) : i64
  (compiler_ir_types.compiler-ir-label
    (&
      (str_cat.str-cat
        (compiler_ir_types.compiler-ir-label-text current-label)
        "_switch_default"))))

(define (compiler-backend-emit-switch-edge-block
  [function : String]
  [edge-label : i64]
  [target-label : i64]
  [copies : String]) : String
  (str_cat.str-cat
    (be_operand.compiler-backend-asm-label
      (be_state.compiler-backend-global-shared-view function)
      edge-label)
    ":\n"
    (str_cat.str-cat
      copies
      (be_scalar.compiler-backend-jump-label function target-label)
      "")))

(define (compiler-backend-emit-switch-case-edge-blocks-from
  [type-segment-bases : i64]
  [function : String]
  [current-label : i64]
  [cases : compiler_ir_types.CompilerIrSwitchCaseSeq]
  [index : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [program-index : be_state.CompilerBackendProgramIndex]
  [vars : i64]) : be_state.ResultCompilerBackend
  (if (>= index cases.len)
    (Ok "")
    (let
      [targets : be_state.BackendSymbolSeq
        (be_state.compiler-backend-function-state-phi-targets
          (be_state.compiler-backend-state-function-state
            program-index.backend-state))]
      (match (compiler_ir_types.compiler-ir-switch-case-seq-borrow cases index)
        [(Case tag label)
          (if (be_state.compiler-backend-symbol-list-contains-id? targets label)
            (let
              [copies
                (try
                  (compiler-backend-emit-phi-edge-copies
                    type-segment-bases
                    assignments
                    (be_state.compiler-backend-global-shared-view blocks)
                    label
                    current-label
                    program-index
                    vars))]
              [rest-blocks
                (try
                  (compiler-backend-emit-switch-case-edge-blocks-from
                    type-segment-bases
                    (be_state.compiler-backend-global-shared-view function)
                    current-label
                    cases
                    (+ index 1)
                    assignments
                    blocks
                    program-index
                    vars))]
              (Ok
                (str_cat.str-cat
                  (compiler-backend-emit-switch-edge-block
                    function
                    (be_facts.compiler-backend-switch-case-edge-label
                      current-label
                      tag)
                    label
                    copies)
                  rest-blocks)))
            (compiler-backend-emit-switch-case-edge-blocks-from
              type-segment-bases
              function
              current-label
              cases
              (+ index 1)
              assignments
              blocks
              program-index
              vars))]))))

(define (compiler-backend-emit-switch-case-edge-blocks
  [type-segment-bases : i64]
  [function : String]
  [current-label : i64]
  [cases : compiler_ir_types.CompilerIrSwitchCaseSeq]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [program-index : be_state.CompilerBackendProgramIndex]
  [vars : i64]) : be_state.ResultCompilerBackend
  (compiler-backend-emit-switch-case-edge-blocks-from
    type-segment-bases
    function
    current-label
    cases
    0
    assignments
    blocks
    program-index
    vars))

;; The case address for INDEX-REG: TABLE-REG holds the rip-relative table base
;; and TARGET-REG the sign-extended 4-byte difference, or, for a non-PIC ELF
;; image, TARGET-REG alone receives the entry's 32-bit absolute address.
(define (compiler-backend-emit-switch-table-lookup
  [function : String]
  [current-label : i64]
  [index-reg : String]
  [table-reg : String]
  [target-reg : String]
  [absolute : bool]) : String
  (if absolute
    (str_cat.str-cat
      "    movl "
      (be_facts.compiler-backend-switch-table-label function current-label)
      "(,"
      index-reg
      ",4), "
      (be_operand.compiler-backend-reg-part target-reg 4)
      "\n")
    (str_cat.str-cat
      "    leaq "
      (be_facts.compiler-backend-switch-table-label function current-label)
      "(%rip), "
      table-reg
      "\n    movslq ("
      table-reg
      ","
      index-reg
      ",4), "
      target-reg
      "\n    addq "
      table-reg
      ", "
      target-reg
      "\n")))

;; Sound emergency-scavenge dispatch (GAP2b-v2). When the register pool is
;; saturated at a switch dispatch, one or both of the index / jump-table-base
;; scratches is EMERGENCY-borrowed from a live occupant. The enclosing
;; emergency-wrap saves that occupant BEFORE this head and would normally
;; restore it AFTER -- but the borrowed register is consumed by the indirect
;; `jmp *`, a control transfer, so a trailing restore lands on UNREACHABLE code
;; (dead on every taken arm AND on the `ja default` edge). The occupant would
;; then arrive in the successor blocks holding the jump-table / arm address.
;; Fix: compute the FINAL target block address (an arm's, or the default block's
;; when out of range) into table-reg, STASH it into a dedicated frame slot,
;; restore every borrowed occupant INLINE (emergency-restore-before-jumps, which
;; sets restore-suppressed so the wrap omits its now-redundant trailing
;; restore), then jump SLOT-INDIRECT through the stash. Both borrowed registers
;; are dead by the stash, so every occupant is restored on the single path that
;; reaches the transfer; the provisional `leaq default` folds the out-of-range
;; edge into the same restore+jump so the default path is covered too. The
;; target slot sits one past the borrowed emergency slots (at index
;; emergency-pending-count); used-count is bumped so the frame reserves it.
;; The rsp-rebase (FPO) pass rewrites the `-K(%rbp)` stash-store and
;; `jmp *-K(%rbp)` like any other frame reference (delta 0, no rsp motion).
(define (compiler-backend-emit-switch-dispatch-emergency
  [function : String]
  [current-label : i64]
  [default-label : i64]
  [total-switch : bool]
  [case-count : i64]
  [base : i64]
  [index-reg : String]
  [table-reg : String]
  [target-reg : String]
  [absolute : bool]
  [load-index : String]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [function-state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state backend-state)]
    [target-idx : i64
      (be_state.compiler-backend-function-scratch-i64
        function-state
        be_state.compiler-backend-scratch-i64-emergency-pending-count)]
    [target-slot : String
      (be_operand.compiler-backend-frame-offset-with-backend-state
        backend-state
        (be_scalar.compiler-backend-emergency-reg-offset
          function-state
          target-idx))]
    [_reserve-target-slot : unit
      (begin
        ;; T1-6 (b): this dedicated stash slot is a REAL frame slot even when
        ;; every borrowed register is XMM-parked, so the emergency frame region
        ;; must be reserved for it explicitly.
        (be_state.compiler-backend-function-scratch-set-bool!
          function-state
          be_state.compiler-backend-scratch-bool-emergency-used
          true)
        (if (<
          (be_state.compiler-backend-function-scratch-i64
            function-state
            be_state.compiler-backend-scratch-i64-emergency-used-count)
          (+ target-idx 1))
          (be_state.compiler-backend-function-scratch-set-i64!
            function-state
            be_state.compiler-backend-scratch-i64-emergency-used-count
            (+ target-idx 1))
          unit))]
    [done-label : String
      (be_operand.compiler-backend-asm-label
        (be_state.compiler-backend-global-shared-view function)
        (compiler_ir_types.compiler-ir-label
          (&
            (str_cat.str-cat
              (compiler_ir_types.compiler-ir-label-text current-label)
              "_disp_j"
              ""))))]
    [default-stub-label : String
      (be_operand.compiler-backend-asm-label
        (be_state.compiler-backend-global-shared-view function)
        (compiler_ir_types.compiler-ir-label
          (&
            (str_cat.str-cat
              (compiler_ir_types.compiler-ir-label-text current-label)
              "_disp_d"
              ""))))]
    ;; The target is computed in the index register itself whenever that copy is
    ;; a dead scratch: only then can the range check not run first, because the
    ;; index must survive the load.
    [shares-index : bool (string.eq target-reg index-reg)]
    ;; Emits the borrowed-occupant restores here (before the transfer) and
    ;; suppresses the wrap's trailing restore. Must be spliced AFTER the target
    ;; stash and BEFORE the indirect jump.
    [restore : String
      (be_scalar.compiler-backend-emergency-restore-before-jumps backend-state)]
    (str_cat.str-cat
      load-index
      (if (= base 0)
        ""
        (str_cat.str-cat
          "    subq $"
          (string.int->string base)
          ", "
          index-reg
          "\n"
          ""))
      (if (or total-switch shares-index)
        ""
        (str_cat.str-cat
          "    leaq "
          (be_operand.compiler-backend-asm-label
            (be_state.compiler-backend-global-shared-view function)
            default-label)
          "(%rip), "
          target-reg
          "\n"))
      (if total-switch
        ""
        (str_cat.str-cat
          "    cmpq $"
          (string.int->string (- case-count 1))
          ", "
          index-reg
          "\n    ja "
          (if shares-index
            default-stub-label
            done-label)
          "\n"))
      (compiler-backend-emit-switch-table-lookup
        function
        current-label
        index-reg
        table-reg
        target-reg
        absolute)
      (if (or total-switch (not shares-index))
        ""
        (str_cat.str-cat
          "    jmp "
          done-label
          "\n"
          default-stub-label
          ":\n    leaq "
          (be_operand.compiler-backend-asm-label
            (be_state.compiler-backend-global-shared-view function)
            default-label)
          "(%rip), "
          target-reg
          "\n"))
      (if total-switch
        ""
        (str_cat.str-cat done-label ":\n"))
      "    movq "
      target-reg
      ", "
      target-slot
      "\n"
      restore
      "    jmp *"
      target-slot
      "\n")))

(define (compiler-backend-emit-switch-dispatch
  [backend-state : be_state.CompilerBackendState]
  [function : String]
  [current-label : i64]
  [index : compiler_ir_types.CompilerIrValue]
  [base : i64]
  [case-count : i64]
  [default-label : i64]
  [total-switch : bool]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]) : be_state.ResultCompilerBackend
  (let
    [index-home : String
      (be_operand.compiler-backend-value-scalar-register
        backend-state
        assignments
        index)]
    [need-index-scratch : bool (or (not (= base 0)) (string.eq index-home ""))]
    [index-exclude : (__tl_dyn-array String)
      (if (and need-index-scratch (not (string.eq index-home "")))
        (be_operand.compiler-backend-one-exclude
          (be_state.compiler-backend-global-shared-view index-home))
        (__tl_make-array String 0))]
    [index-exclude-n : i64
      (if (and need-index-scratch (not (string.eq index-home "")))
        1
        0)]
    [index-reg : String
      (if need-index-scratch
        (be_operand.compiler-backend-scavenge-reg-here
          index-exclude
          index-exclude-n
          "%r8"
          backend-state)
        index-home)]
    [absolute : bool
      (be_state.compiler-backend-state-absolute-switch-ok? backend-state)]
    [table-exclude : (__tl_dyn-array String)
      (be_operand.compiler-backend-one-exclude
        (be_state.compiler-backend-global-shared-view index-reg))]
    ;; A relative entry is an offset from the table base, so that code model
    ;; always needs a base register. A 32-bit absolute entry is the address
    ;; itself, so the non-PIC form addresses the table directly.
    [table-reg : String
      (if absolute
        ""
        (be_operand.compiler-backend-scavenge-reg-here
          table-exclude
          1
          "%r9"
          backend-state))]
    ;; The target address is computed in a scratch that is dead at the transfer.
    ;; The index copy is that scratch when the index had to be loaded into one;
    ;; otherwise the index home is still live here (a successor block can read
    ;; it), so the target takes a second scratch.
    [target-exclude : (__tl_dyn-array String)
      (be_operand.compiler-backend-two-exclude
        (be_state.compiler-backend-global-shared-view index-reg)
        (be_state.compiler-backend-global-shared-view table-reg))]
    [target-exclude-n : i64 2]
    [target-reg : String
      (if (and (not absolute) need-index-scratch)
        (string.copy (& index-reg))
        (be_operand.compiler-backend-scavenge-reg-here
          target-exclude
          target-exclude-n
          "%r10"
          backend-state))]
    [index-load : be_state.ResultCompilerBackend
      (if need-index-scratch
        (be_operand.compiler-backend-emit-load-value
          assignments
          index
          (be_state.compiler-backend-global-shared-view index-reg)
          backend-state)
        (Ok ""))]
    [load-index (try index-load)]
    (Ok
      (if (be_state.compiler-backend-function-scratch-bool?
        (be_state.compiler-backend-state-function-state backend-state)
        be_state.compiler-backend-scratch-bool-emergency-pending)
        ;; GAP2b-v2: a scratch was emergency-borrowed from a live occupant, and
        ;; a restore after the transfer would be unreachable, so the target goes
        ;; through the dedicated slot and the restores run before the jump.
        (compiler-backend-emit-switch-dispatch-emergency
          function
          current-label
          default-label
          total-switch
          case-count
          base
          index-reg
          table-reg
          target-reg
          absolute
          load-index
          backend-state)
        (compiler-backend-emit-switch-dispatch-direct
          function
          current-label
          default-label
          total-switch
          case-count
          base
          index-reg
          table-reg
          target-reg
          absolute
          load-index)))))

;; The plain dispatch: the final target block address is computed into a scratch
;; that is dead at the transfer, so the jump stays register-indirect and no frame
;; slot is needed. An out-of-range key branches straight to the default block.
(define (compiler-backend-emit-switch-dispatch-direct
  [function : String]
  [current-label : i64]
  [default-label : i64]
  [total-switch : bool]
  [case-count : i64]
  [base : i64]
  [index-reg : String]
  [table-reg : String]
  [target-reg : String]
  [absolute : bool]
  [load-index : String]) : String
  (str_cat.str-cat
    load-index
    (if (= base 0)
      ""
      (str_cat.str-cat
        "    subq $"
        (string.int->string base)
        ", "
        index-reg
        "\n"
        ""))
    (if total-switch
      ""
      (str_cat.str-cat
        "    cmpq $"
        (string.int->string (- case-count 1))
        ", "
        index-reg
        "\n    ja "
        (be_operand.compiler-backend-asm-label
          (be_state.compiler-backend-global-shared-view function)
          default-label)
        "\n"))
    (compiler-backend-emit-switch-table-lookup
      function
      current-label
      index-reg
      table-reg
      target-reg
      absolute)
    "    jmp *"
    target-reg
    "\n"))

(define (compiler-backend-emit-switch
  [type-segment-bases : i64]
  [function : String]
  [current-label : i64]
  [index : compiler_ir_types.CompilerIrValue]
  [base : i64]
  [cases : compiler_ir_types.CompilerIrSwitchCaseSeq]
  [default-label : i64]
  [trap-label : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [program-index : be_state.CompilerBackendProgramIndex]
  [vars : i64]) : be_state.ResultCompilerBackend
  (let
    [case-count : i64 (be_facts.compiler-backend-switch-case-count cases)]
    [total-switch : bool
      (compiler-backend-total-switch?
        (be_state.compiler-backend-global-shared-view blocks)
        base
        cases
        default-label
        trap-label)]
    (cond
      [(= case-count 0)
        (Err
          (box
            (compiler_diagnostic.compiler-diagnostic-at-start
              ""
              (be_facts.compiler-backend-switch-shape-message))))]
      [(not
          (be_facts.compiler-backend-switch-cases-contiguous-from? cases base))
        (Err
          (box
            (compiler_diagnostic.compiler-diagnostic-at-start
              ""
              (be_facts.compiler-backend-switch-shape-message))))]
      [(be_facts.compiler-backend-switch-target-phi?
          (be_state.compiler-backend-function-state-phi-targets
            (be_state.compiler-backend-state-function-state
              program-index.backend-state))
          cases
          default-label)
        (let
          [case-blocks
            (try
              (compiler-backend-emit-switch-case-edge-blocks
                type-segment-bases
                (be_state.compiler-backend-global-shared-view function)
                current-label
                cases
                assignments
                (be_state.compiler-backend-global-shared-view blocks)
                program-index
                vars))]
          [default-needs-edge : bool
            (let
              [items
                (be_state.compiler-backend-function-state-phi-targets
                  (be_state.compiler-backend-state-function-state
                    program-index.backend-state))]
              (be_state.compiler-backend-symbol-list-contains-id?
                items
                default-label))]
          [default-block
            (try
              (if default-needs-edge
                (match (compiler-backend-emit-phi-edge-copies
                  type-segment-bases
                  assignments
                  blocks
                  default-label
                  current-label
                  program-index
                  vars)
                  [(Ok copies)
                    (be_state.ResultCompilerBackend.Ok
                      (compiler-backend-emit-switch-edge-block
                        (be_state.compiler-backend-global-shared-view function)
                        (compiler-backend-switch-default-edge-label
                          current-label)
                        default-label
                        copies))]
                  [(Err message) (be_state.ResultCompilerBackend.Err message)])
                (be_state.ResultCompilerBackend.Ok "")))]
          [dispatch
            (try
              (compiler-backend-emit-switch-dispatch
                program-index.backend-state
                function
                current-label
                index
                base
                case-count
                (if default-needs-edge
                  (compiler-backend-switch-default-edge-label current-label)
                  default-label)
                total-switch
                assignments))]
          (Ok (str_cat.str-cat dispatch case-blocks default-block)))]
      [else
        (Ok
          (try
            (compiler-backend-emit-switch-dispatch
              program-index.backend-state
              function
              current-label
              index
              base
              case-count
              default-label
              total-switch
              assignments)))])))

;; Dead result-store elision: true when `var` is read by NO instruction in the
;; final emitted IR (use count 0 over emit-blocks-list, the post-rewrite
;; post-coloring blocks the emitter walks). Every operand read counts as a use,
;; including AddrOf's raw var id (compiler-backend-count-instr-uses), so
;; a never-used var's frame slot is unobservable: no reload, no address-taken
;; alias, no Pack/Word read. The runtime has no GC/stack-root walk and the
;; backend emits no per-slot unwind metadata, so skipping the slot store of such
;; a var (a call result whose value is ignored -- DCE cannot drop the call) is
;; behavior-preserving. Reads the per-function array installed by
;; compiler-backend-fuse-need-enable!; conservatively false when unset.
(define (compiler-backend-var-never-used?
  [backend-state : be_state.CompilerBackendState]
  [var : i64]) : bool
  (let
    [function-state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state backend-state)]
    [use-counts : (__tl_dyn-array i64)
      (be_state.compiler-backend-function-state-i64-array
        function-state
        be_state.compiler-backend-function-i64-array-fuse-use-counts)]
    (cond
      [(not
          (be_state.compiler-backend-function-state-bool?
            function-state
            be_state.compiler-backend-function-bool-fuse-need-ready))
        false]
      [(< var 0) false]
      [(>= var (array-length use-counts)) false]
      [else (= (array-ref use-counts var) 0)])))

(define (compiler-backend-indirect-call-param-types
  [type-segment-bases : i64]
  [types : compiler_regalloc.CompilerRegVarTypes]
  [func : compiler_ir_types.CompilerIrValue]
  [program-index : be_state.CompilerBackendProgramIndex]) : compiler_ast_types.AstTypeList
  (match (& func)
    [(Function name)
      (match (be_facts.compiler-backend-index-signature program-index name)
        [(Some param-types _) param-types]
        [(No) (compiler_ast_types.ast-type-list-new)])]
    [_
      (match (be_facts.compiler-backend-value-type types (Empty) func)
        [(Some ty)
          (match (be_facts.compiler-backend-program-index-extern-signature
            type-segment-bases
            ty)
            [(Some param-types _) param-types]
            [(No) (compiler_ast_types.ast-type-list-new)])]
        [(No) (compiler_ast_types.ast-type-list-new)])]))

(define (compiler-backend-effective-c-abi-indirect-param-types
  [type-segment-bases : i64]
  [types : compiler_regalloc.CompilerRegVarTypes]
  [func : compiler_ir_types.CompilerIrValue]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [program-index : be_state.CompilerBackendProgramIndex]) : compiler_ast_types.AstTypeList
  (let
    [declared-param-types : compiler_ast_types.AstTypeList
      (compiler-backend-indirect-call-param-types
        type-segment-bases
        types
        func
        program-index)]
    (if (be_facts.compiler-backend-type-list-has-aggregate?
      type-segment-bases
      declared-param-types)
      (compiler-backend-call-c-abi-param-types
        type-segment-bases
        types
        (be_state.CompilerBackendGlobalTypeTable.Empty)
        args
        declared-param-types
        program-index)
      (if (=
        (be_facts.compiler-backend-call-args-count
          (be_state.compiler-backend-global-shared-view args))
        (be_facts.compiler-backend-type-list-count declared-param-types))
        declared-param-types
        (compiler-backend-call-actual-param-types
          type-segment-bases
          types
          (be_state.CompilerBackendGlobalTypeTable.Empty)
          args)))))

(define (compiler-backend-spmd-private-vector-arg-reg [index : i64]) : String
  (if (and (>= index 0) (< index 8))
    (str_cat.str-cat "%zmm" (string.int->string (+ 17 index)))
    ""))

(define (compiler-backend-spmd-private-mask-arg-reg [index : i64]) : String
  (if (and (>= index 0) (< index 5))
    (str_cat.str-cat "%k" (string.int->string (+ 2 index)))
    ""))