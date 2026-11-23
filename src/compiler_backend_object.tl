;; compiler_backend_object.tl - Object emission: encoded instructions, symbols and sections.
(import compiler_backend_program_data as be_data)
(import compiler_backend_operands as be_operand)
(import compiler_backend_program_facts as be_facts)
(import compiler_backend_state as be_state)
(import compiler_backend_scalar as be_scalar)
(import stdlib.iterator)
(import compiler_ir_types)
(import compiler_ast_types)
(import compiler_builtin_ids as cbi)
(import compiler_diagnostic)
(import compiler_optimize)
(import compiler_abi)
(import compiler_regalloc)
(import compiler_liveness)
(import compiler_profile_state as profile_state)
(import compiler_backend_object_target as object_target)
(import compiler_backend_object_target_linux as object_linux)
(import compiler_backend_object_target_windows as object_windows)
(import compiler_object as cobj)
(import compiler_machine_x64 as mx)
(import compiler_intern as ci)
(import compiler_abort as abort)
(import stdlib.arena)
(import stdlib.string)
(import stdlib.byte_buf_core)
(import compiler_str_cat as str_cat)
(import compiler_owned_view as owned_view)

(define (compiler-backend-object-literal-address
  [parts : object_target.CompilerBackendObjectTargetParts]
  [site : String]
  [symbol : String]
  [backend-state : be_state.CompilerBackendState]) : object_target.CompilerBackendObjectTargetParts
  (let
    [absolute? : bool
      (be_state.compiler-backend-state-absolute-literal-ok? backend-state)]
    (object_target.compiler-backend-object-add-text
      (object_target.compiler-backend-object-add-text-relocation
        parts
        site
        (if absolute?
          (Abs32)
          (RipAddress))
        (be_state.compiler-backend-global-shared-view symbol))
      (if absolute?
        (LoadAbsAddress symbol)
        (LoadRipAddress symbol)))))

(define (compiler-backend-object-value-ref
  [parts : object_target.CompilerBackendObjectTargetParts]
  [site : String]
  [value : (& compiler_ir_types.CompilerIrValue)]
  [program-index : be_state.CompilerBackendProgramIndex]) : object_target.CompilerBackendObjectTargetParts
  (match value
    [(Global name)
      (let
        [symbol : String
          (be_operand.compiler-backend-global-symbol-index program-index name)]
        ;; IAG-1: an inline aggregate global's value is its own address.
        [inline? : bool
          (be_state.compiler-backend-inline-aggregate-global?
            program-index.backend-state
            name)]
        (object_target.compiler-backend-object-add-text
          (object_target.compiler-backend-object-add-text-relocation
            parts
            site
            (if inline?
              (RipAddress)
              (RipValue))
            (be_state.compiler-backend-global-shared-view symbol))
          (if inline?
            (LoadRipAddress symbol)
            (LoadRip symbol))))]
    [(GlobalAddr name)
      (let
        [symbol : String
          (be_facts.compiler-backend-function-or-global-addr-symbol
            program-index
            name)]
        (object_target.compiler-backend-object-add-text
          (object_target.compiler-backend-object-add-text-relocation
            parts
            site
            (RipAddress)
            (be_state.compiler-backend-global-shared-view symbol))
          (LoadRipAddress symbol)))]
    [(String text)
      (compiler-backend-object-literal-address
        parts
        site
        (be_operand.compiler-backend-string-fat-label text)
        program-index.backend-state)]
    [(Bytes text)
      (compiler-backend-object-literal-address
        parts
        site
        (be_operand.compiler-backend-bytes-fat-label text)
        program-index.backend-state)]
    [(F64 bits)
      (let
        [symbol : String (be_facts.compiler-backend-f64-label bits)]
        (object_target.compiler-backend-object-add-text
          (object_target.compiler-backend-object-add-text-relocation
            parts
            site
            (RipValue)
            (be_state.compiler-backend-global-shared-view symbol))
          (LoadRip symbol)))]
    [(Function name)
      (let
        [symbol : String
          (be_operand.compiler-backend-closure-descriptor-label
            (be_state.compiler-backend-symbol-text-index program-index name))]
        (object_target.compiler-backend-object-add-text
          (object_target.compiler-backend-object-add-text-relocation
            parts
            site
            (RipAddress)
            (be_state.compiler-backend-global-shared-view symbol))
          (LoadRipAddress symbol)))]
    [_ parts]))

(define (compiler-backend-object-value-ref-with-type
  [parts : object_target.CompilerBackendObjectTargetParts]
  [site : String]
  [value : compiler_ir_types.CompilerIrValue]
  [ty : (& ty compiler_ast_types.AstType)]
  [program-index : be_state.CompilerBackendProgramIndex]) : object_target.CompilerBackendObjectTargetParts
  (match (& value)
    [(F64 bits)
      (let
        [symbol : String (be_operand.compiler-backend-float-label ty bits)]
        (object_target.compiler-backend-object-add-text
          (object_target.compiler-backend-object-add-text-relocation
            parts
            site
            (RipValue)
            (be_state.compiler-backend-global-shared-view symbol))
          (LoadRip symbol)))]
    [_ (compiler-backend-object-value-ref parts site (& value) program-index)]))

(define (compiler-backend-object-value-seq-ref-from
  [parts : object_target.CompilerBackendObjectTargetParts]
  [site : String]
  [values : compiler_ir_types.CompilerIrValueSeq]
  [program-index : be_state.CompilerBackendProgramIndex]
  [index : i64]) : object_target.CompilerBackendObjectTargetParts
  (if (>= index values.len)
    parts
    (compiler-backend-object-value-seq-ref-from
      (compiler-backend-object-value-ref
        parts
        (be_state.compiler-backend-global-shared-view site)
        (compiler_ir_types.compiler-ir-value-seq-borrow values index)
        program-index)
      site
      values
      program-index
      (+ index 1))))

(define (compiler-backend-object-value-seq-ref
  [parts : object_target.CompilerBackendObjectTargetParts]
  [site : String]
  [values : compiler_ir_types.CompilerIrValueSeq]
  [program-index : be_state.CompilerBackendProgramIndex]) : object_target.CompilerBackendObjectTargetParts
  (compiler-backend-object-value-seq-ref-from parts site values program-index 0))

(define (compiler-backend-object-byte [value : i64]) : u8
  (cast (bit-and value 0xff) : u8))

;; Private hot object-code fragments use the narrow append-only ByteBuf core.
(define (compiler-backend-object-push-u8!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (byte_buf_core.byte-buf-builder-push out (compiler-backend-object-byte value)))

(define (compiler-backend-object-push-u32!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (compiler-backend-object-push-u8! out value)
  (compiler-backend-object-push-u8! out (shr value 8))
  (compiler-backend-object-push-u8! out (shr value 16))
  (compiler-backend-object-push-u8! out (shr value 24)))

(define (compiler-backend-object-push-u64!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (compiler-backend-object-push-u32! out value)
  (compiler-backend-object-push-u32! out (shr value 32)))

(define (compiler-backend-object-bytes-finish
  [out : (& out byte_buf_core.ByteBufBuilder)]) : String
  (byte_buf_core.byte-buf-builder-finish-string out))

(define (compiler-backend-object-add-nonempty-bytes
  [parts : object_target.CompilerBackendObjectTargetParts]
  [bytes : String]) : object_target.CompilerBackendObjectTargetParts
  (if (= (string.string-length bytes) 0)
    parts
    (object_target.compiler-backend-object-add-text parts (Bytes bytes))))

(define (compiler-backend-object-add-machine
  [parts : object_target.CompilerBackendObjectTargetParts]
  [instr : mx.MachineInstr]) : object_target.CompilerBackendObjectTargetParts
  (object_target.compiler-backend-object-add-text
    parts
    (Machine (mx.compiler-machine-x64-checked instr))))

;; `movq $value, %reg` in its sign-extending imm32 form.
(define (compiler-backend-object-add-mov-imm32
  [parts : object_target.CompilerBackendObjectTargetParts]
  [value : i64]
  [reg : String]) : object_target.CompilerBackendObjectTargetParts
  (compiler-backend-object-add-machine
    parts
    (mx.MachineInstr.MovRI
      (W64)
      (be_operand.compiler-backend-machine-register reg)
      value)))

;; `movq %rax, %reg`; nothing when `reg` is `%rax`.
(define (compiler-backend-object-add-mov-from-rax
  [parts : object_target.CompilerBackendObjectTargetParts]
  [reg : String]) : object_target.CompilerBackendObjectTargetParts
  (let
    [dst : i64 (be_operand.compiler-backend-machine-register reg)]
    (if (= dst compiler_abi.compiler-reg-id-rax)
      parts
      (compiler-backend-object-add-machine
        parts
        (mx.MachineInstr.MovRR (W64) dst compiler_abi.compiler-reg-id-rax)))))

(define (compiler-backend-object-reg-low-code [reg : (& reg str)]) : i64
  (cond
    [(or (string.eq reg "%rax") (string.eq reg "%r8")) 0]
    [(or (string.eq reg "%rcx") (string.eq reg "%r9")) 1]
    [(or (string.eq reg "%rdx") (string.eq reg "%r10")) 2]
    [(or (string.eq reg "%rbx") (string.eq reg "%r11")) 3]
    [(or (string.eq reg "%rsp") (string.eq reg "%r12")) 4]
    [(or (string.eq reg "%rbp") (string.eq reg "%r13")) 5]
    [(or (string.eq reg "%rsi") (string.eq reg "%r14")) 6]
    [else 7]))

(define (compiler-backend-object-reg-high? [reg : String]) : bool
  (or
    (string.eq reg "%r8")
    (string.eq reg "%r9")
    (string.eq reg "%r10")
    (string.eq reg "%r11")
    (string.eq reg "%r12")
    (string.eq reg "%r13")
    (string.eq reg "%r14")
    (string.eq reg "%r15")))

(define (compiler-backend-object-slot-disp [var-id : i64]) : i64
  (- 0 (* 8 (+ var-id 1))))

(define (compiler-backend-object-disp8? [disp : i64]) : bool
  (and (>= disp -128) (<= disp 127)))

(define (compiler-backend-object-load-rbp-disp-bytes
  [disp : i64]
  [reg : String]) : String
  (let
    [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    [reg-code : i64 (compiler-backend-object-reg-low-code reg)]
    [rex : i64
      (+
        0x48
        (if (compiler-backend-object-reg-high? reg)
          4
          0))]
    (compiler-backend-object-push-u8! (&mut out) rex)
    (compiler-backend-object-push-u8! (&mut out) 0x8b)
    (if (compiler-backend-object-disp8? disp)
      (begin
        (compiler-backend-object-push-u8! (&mut out) (+ 0x45 (* reg-code 8)))
        (compiler-backend-object-push-u8! (&mut out) disp))
      (begin
        (compiler-backend-object-push-u8! (&mut out) (+ 0x85 (* reg-code 8)))
        (compiler-backend-object-push-u32! (&mut out) disp)))
    (compiler-backend-object-bytes-finish (& out))))

(define (compiler-backend-object-lea-rbp-disp-bytes [disp : i64] [reg : String]) : String
  (let
    [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    [reg-code : i64 (compiler-backend-object-reg-low-code reg)]
    [rex : i64
      (+
        0x48
        (if (compiler-backend-object-reg-high? reg)
          4
          0))]
    (compiler-backend-object-push-u8! (&mut out) rex)
    (compiler-backend-object-push-u8! (&mut out) 0x8d)
    (if (compiler-backend-object-disp8? disp)
      (begin
        (compiler-backend-object-push-u8! (&mut out) (+ 0x45 (* reg-code 8)))
        (compiler-backend-object-push-u8! (&mut out) disp))
      (begin
        (compiler-backend-object-push-u8! (&mut out) (+ 0x85 (* reg-code 8)))
        (compiler-backend-object-push-u32! (&mut out) disp)))
    (compiler-backend-object-bytes-finish (& out))))

(define (compiler-backend-object-store-slot-bytes [var-id : i64] [reg : String]) : String
  (let
    [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    [disp : i64 (compiler-backend-object-slot-disp var-id)]
    [reg-code : i64 (compiler-backend-object-reg-low-code reg)]
    [rex : i64
      (+
        0x48
        (if (compiler-backend-object-reg-high? reg)
          4
          0))]
    (compiler-backend-object-push-u8! (&mut out) rex)
    (compiler-backend-object-push-u8! (&mut out) 0x89)
    (if (compiler-backend-object-disp8? disp)
      (begin
        (compiler-backend-object-push-u8! (&mut out) (+ 0x45 (* reg-code 8)))
        (compiler-backend-object-push-u8! (&mut out) disp))
      (begin
        (compiler-backend-object-push-u8! (&mut out) (+ 0x85 (* reg-code 8)))
        (compiler-backend-object-push-u32! (&mut out) disp)))
    (compiler-backend-object-bytes-finish (& out))))

;; `movabsq $value, %reg` (`REX.W + B8+r imm64`) for a value no imm32 form
;; represents. Native TLCI entries pass source integer literals through here,
;; so truncating one would change the AST the next bootstrap stage produces.
(define (compiler-backend-object-mov-wide-reg-bytes
  [value : i64]
  [reg : String]) : String
  (let
    [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    [reg-code : i64 (compiler-backend-object-reg-low-code reg)]
    [rex : i64
      (+
        0x48
        (if (compiler-backend-object-reg-high? reg)
          1
          0))]
    (compiler-backend-object-push-u8! (&mut out) rex)
    (compiler-backend-object-push-u8! (&mut out) (+ 0xb8 reg-code))
    (compiler-backend-object-push-u64! (&mut out) value)
    (compiler-backend-object-bytes-finish (& out))))

;; `REX.W + C7 /0` sign-extends its imm32 payload, so a value outside it takes
;; the wide form.
(define (compiler-backend-object-add-mov-i64
  [parts : object_target.CompilerBackendObjectTargetParts]
  [value : i64]
  [reg : String]) : object_target.CompilerBackendObjectTargetParts
  (if (be_operand.compiler-backend-imm32? value)
    (compiler-backend-object-add-mov-imm32 parts value reg)
    (compiler-backend-object-add-nonempty-bytes
      parts
      (compiler-backend-object-mov-wide-reg-bytes value reg))))

(define (compiler-backend-object-push-sub-rsp!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [amount : i64]) : unit
  (if (<= amount 127)
    (begin
      (compiler-backend-object-push-u8! out 0x48)
      (compiler-backend-object-push-u8! out 0x83)
      (compiler-backend-object-push-u8! out 0xec)
      (compiler-backend-object-push-u8! out amount))
    (begin
      (compiler-backend-object-push-u8! out 0x48)
      (compiler-backend-object-push-u8! out 0x81)
      (compiler-backend-object-push-u8! out 0xec)
      (compiler-backend-object-push-u32! out amount))))

;; The byte equivalent of emit-stack-probe, including preservation of a live
;; transient R11 target. The backward edge has fixed displacement -16.
(define (compiler-backend-object-stack-probe-bytes [frame : i64]) : String
  (let
    [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    [remaining : i64 (- frame 8)]
    [tail : i64 (% remaining 4096)]
    [pages : i64 (- remaining tail)]
    (byte_buf_core.byte-buf-builder-append-string
      (&mut out)
      (object_target.compiler-backend-object-bytes-from-hex "4153"))
    (when
      (> pages 0)
      (byte_buf_core.byte-buf-builder-append-string
        (&mut out)
        (object_target.compiler-backend-object-bytes-from-hex "4c8d9c24"))
      (compiler-backend-object-push-u32! (&mut out) (- 0 pages))
      (byte_buf_core.byte-buf-builder-append-string
        (&mut out)
        (object_target.compiler-backend-object-bytes-from-hex
          "4881ec00100000f60424004c39dc75f0")))
    (when
      (> tail 0)
      (compiler-backend-object-push-sub-rsp! (&mut out) tail)
      (byte_buf_core.byte-buf-builder-append-string
        (&mut out)
        (object_target.compiler-backend-object-bytes-from-hex "f6042400")))
    (byte_buf_core.byte-buf-builder-append-string
      (&mut out)
      (object_target.compiler-backend-object-bytes-from-hex "4c8b9c24"))
    (compiler-backend-object-push-u32! (&mut out) remaining)
    (compiler-backend-object-bytes-finish (& out))))

(define (compiler-backend-object-prologue-bytes
  [target : be_state.CompilerBackendTarget]
  [frame-size : i64]) : String
  (when
    (and
      (> frame-size 32768)
      (be_state.compiler-backend-target-policy-new target).linux)
    (return
      (str_cat.str-cat
        (object_target.compiler-backend-object-bytes-from-hex "554889e5")
        (compiler-backend-object-stack-probe-bytes frame-size))))
  (let
    [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    [probe : bool
      (and
        (be_state.compiler-backend-target-stack-probe? target)
        (>= frame-size 4096))]
    [remaining : i64 frame-size]
    (compiler-backend-object-push-u8! (&mut out) 0x55)
    (compiler-backend-object-push-u8! (&mut out) 0x48)
    (compiler-backend-object-push-u8! (&mut out) 0x89)
    (compiler-backend-object-push-u8! (&mut out) 0xe5)
    (if (= frame-size 0)
      unit
      (if probe
        ;; Windows guard-page discipline: a frame that skips past the
        ;; single guard page faults, so large frames extend the stack one
        ;; page at a time with a touch per page (the inline equivalent of
        ;; the asm path's __chkstk call, which mapped images cannot make).
        (begin
          (while (> remaining 4096)
            (compiler-backend-object-push-sub-rsp! (&mut out) 4096)
            ;; orl $0, (%rsp)
            (compiler-backend-object-push-u8! (&mut out) 0x83)
            (compiler-backend-object-push-u8! (&mut out) 0x0c)
            (compiler-backend-object-push-u8! (&mut out) 0x24)
            (compiler-backend-object-push-u8! (&mut out) 0x00)
            (-= remaining 4096))
          (if (> remaining 0)
            (compiler-backend-object-push-sub-rsp! (&mut out) remaining)
            unit))
        (compiler-backend-object-push-sub-rsp! (&mut out) frame-size)))
    (compiler-backend-object-bytes-finish (& out))))

(define (compiler-backend-object-leave-ret-bytes) : String
  (object_target.compiler-backend-object-bytes-from-hex "c9c3"))

(define (compiler-backend-object-zero-eax-bytes) : String
  (object_target.compiler-backend-object-bytes-from-hex "31c0"))

(define (compiler-backend-object-rsp-imm-bytes [opcode : i64] [value : i64]) : String
  (let
    [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    (if (<= value 127)
      (begin
        (compiler-backend-object-push-u8! (&mut out) 0x48)
        (compiler-backend-object-push-u8! (&mut out) 0x83)
        (compiler-backend-object-push-u8! (&mut out) opcode)
        (compiler-backend-object-push-u8! (&mut out) value))
      (begin
        (compiler-backend-object-push-u8! (&mut out) 0x48)
        (compiler-backend-object-push-u8! (&mut out) 0x81)
        (compiler-backend-object-push-u8! (&mut out) opcode)
        (compiler-backend-object-push-u32! (&mut out) value)))
    (compiler-backend-object-bytes-finish (& out))))

(define (compiler-backend-object-sub-rsp-bytes
  [value : i64]
  [backend-state : be_state.CompilerBackendState]) : String
  (if (= value 0)
    ""
    (if (and
      (> value 4096)
      (be_state.compiler-backend-state-emission-target-policy backend-state).linux)
      (compiler-backend-object-stack-probe-bytes value)
      (compiler-backend-object-rsp-imm-bytes 0xec value))))

(define (compiler-backend-object-unop-rax-bytes
  [op : compiler_ir_types.CompilerIrUnOp]) : String
  (let
    [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    (match op
      [(Neg)
        (compiler-backend-object-push-u8! (&mut out) 0x48)
        (compiler-backend-object-push-u8! (&mut out) 0xf7)
        (compiler-backend-object-push-u8! (&mut out) 0xd8)]
      [(Not)
        (compiler-backend-object-push-u8! (&mut out) 0x48)
        (compiler-backend-object-push-u8! (&mut out) 0x83)
        (compiler-backend-object-push-u8! (&mut out) 0xf0)
        (compiler-backend-object-push-u8! (&mut out) 0x01)]
      [(BitNot)
        (compiler-backend-object-push-u8! (&mut out) 0x48)
        (compiler-backend-object-push-u8! (&mut out) 0xf7)
        (compiler-backend-object-push-u8! (&mut out) 0xd0)]
      [(or (Sqrt) (BitLength)) unit])
    (byte_buf_core.byte-buf-builder-finish-string (& out))))

(define (compiler-backend-object-call-r11-bytes) : String
  (let
    [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    (compiler-backend-object-push-u8! (&mut out) 0x41)
    (compiler-backend-object-push-u8! (&mut out) 0xff)
    (compiler-backend-object-push-u8! (&mut out) 0xd3)
    (byte_buf_core.byte-buf-builder-finish-string (& out))))

(define (compiler-backend-object-syscall-bytes) : String
  (let
    [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    (compiler-backend-object-push-u8! (&mut out) 0x0f)
    (compiler-backend-object-push-u8! (&mut out) 0x05)
    (byte_buf_core.byte-buf-builder-finish-string (& out))))

;; Linux x86-64 kernel argument registers for syscall operand `index` (the
;; number is operand 0 and travels in %rax).
(define (compiler-backend-object-syscall-arg-reg [index : i64]) : String
  (cond
    [(= index 1) "%rdi"]
    [(= index 2) "%rsi"]
    [(= index 3) "%rdx"]
    [(= index 4) "%r10"]
    [(= index 5) "%r8"]
    [else "%r9"]))

(define (compiler-backend-object-syscall-arg-moves
  [parts : object_target.CompilerBackendObjectTargetParts]
  [site : String]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [index : i64]
  [program-index : be_state.CompilerBackendProgramIndex]) : object_target.CompilerBackendObjectTargetParts
  (if (>=
    index
    (be_facts.compiler-backend-call-args-count
      (be_state.compiler-backend-global-shared-view args)))
    parts
    (compiler-backend-object-syscall-arg-moves
      (compiler-backend-object-load-value-to-reg
        parts
        (be_state.compiler-backend-global-shared-view site)
        (be_facts.compiler-backend-call-arg-at args index)
        (compiler-backend-object-syscall-arg-reg index)
        program-index)
      site
      args
      (+ index 1)
      program-index)))

(define (compiler-backend-object-add-rsp-bytes [value : i64]) : String
  (if (= value 0)
    ""
    (compiler-backend-object-rsp-imm-bytes 0xc4 value)))

(define (compiler-backend-object-store-rax-rsp-bytes [disp : i64]) : String
  (let
    [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    (compiler-backend-object-push-u8! (&mut out) 0x48)
    (compiler-backend-object-push-u8! (&mut out) 0x89)
    (if (compiler-backend-object-disp8? disp)
      (begin
        (compiler-backend-object-push-u8! (&mut out) 0x44)
        (compiler-backend-object-push-u8! (&mut out) 0x24)
        (compiler-backend-object-push-u8! (&mut out) disp))
      (begin
        (compiler-backend-object-push-u8! (&mut out) 0x84)
        (compiler-backend-object-push-u8! (&mut out) 0x24)
        (compiler-backend-object-push-u32! (&mut out) disp)))
    (compiler-backend-object-bytes-finish (& out))))

(define (compiler-backend-object-load-rax-rsp-bytes [disp : i64]) : String
  (let
    [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    (compiler-backend-object-push-u8! (&mut out) 0x48)
    (compiler-backend-object-push-u8! (&mut out) 0x8b)
    (if (compiler-backend-object-disp8? disp)
      (begin
        (compiler-backend-object-push-u8! (&mut out) 0x44)
        (compiler-backend-object-push-u8! (&mut out) 0x24)
        (compiler-backend-object-push-u8! (&mut out) disp))
      (begin
        (compiler-backend-object-push-u8! (&mut out) 0x84)
        (compiler-backend-object-push-u8! (&mut out) 0x24)
        (compiler-backend-object-push-u32! (&mut out) disp)))
    (compiler-backend-object-bytes-finish (& out))))

(define (compiler-backend-object-load-rax-pointee-bytes
  [type-segment-bases : i64]
  [ty : compiler_ast_types.AstType]) : String
  (let
    [size : i64 (be_operand.compiler-backend-type-size type-segment-bases ty)]
    [signed : bool
      (be_facts.compiler-backend-type-signed? type-segment-bases ty)]
    (cond
      [(= size 8)
        (object_target.compiler-backend-object-bytes-from-hex "488b00")]
      [(= size 4)
        (if signed
          (object_target.compiler-backend-object-bytes-from-hex "486300")
          (object_target.compiler-backend-object-bytes-from-hex "8b00"))]
      [(= size 2)
        (if signed
          (object_target.compiler-backend-object-bytes-from-hex "480fbf00")
          (object_target.compiler-backend-object-bytes-from-hex "0fb700"))]
      [(= size 1)
        (if signed
          (object_target.compiler-backend-object-bytes-from-hex "480fbe00")
          (object_target.compiler-backend-object-bytes-from-hex "0fb600"))]
      [else (object_target.compiler-backend-object-bytes-from-hex "488b00")])))

;; IAG-1 (object mirror): copy `size` bytes from `(%rax)` into `(%r11)` with an
;; unrolled `movq d(%rax), %r10 ; movq %r10, d(%r11)` run. The caller puts the
;; source pointer in %rax and the cell address in %r11 (LoadRipAddressR11, which
;; carries the relocation), so this blob needs none of its own.
(define (compiler-backend-object-inline-aggregate-copy-bytes [size : i64]) : String
  (let
    [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    [offset : i64 0]
    (while (< offset size)
      ;; movq offset(%rax), %r10
      (compiler-backend-object-push-u8! (&mut out) 0x4c)
      (compiler-backend-object-push-u8! (&mut out) 0x8b)
      (compiler-backend-object-push-u8! (&mut out) 0x50)
      (compiler-backend-object-push-u8! (&mut out) offset)
      ;; movq %r10, offset(%r11)
      (compiler-backend-object-push-u8! (&mut out) 0x4d)
      (compiler-backend-object-push-u8! (&mut out) 0x89)
      (compiler-backend-object-push-u8! (&mut out) 0x53)
      (compiler-backend-object-push-u8! (&mut out) offset)
      (+= offset 8))
    (compiler-backend-object-bytes-finish (& out))))

(define (compiler-backend-object-leave-bytes) : String
  (object_target.compiler-backend-object-bytes-from-hex "c9"))

(define (compiler-backend-object-load-value-to-reg
  [parts : object_target.CompilerBackendObjectTargetParts]
  [site : String]
  [value : compiler_ir_types.CompilerIrValue]
  [reg : String]
  [program-index : be_state.CompilerBackendProgramIndex]) : object_target.CompilerBackendObjectTargetParts
  (match (& value)
    [(Var id)
      (compiler-backend-object-add-nonempty-bytes
        parts
        (compiler-backend-object-load-rbp-disp-bytes
          (compiler-backend-object-slot-disp id)
          reg))]
    [(I64 n) (compiler-backend-object-add-mov-i64 parts n reg)]
    [(Bool b)
      (compiler-backend-object-add-mov-imm32
        parts
        (if b
          1
          0)
        reg)]
    [(Char c)
      (compiler-backend-object-add-mov-imm32
        parts
        (be_state.compiler-backend-char-code c)
        reg)]
    [(Unit) (compiler-backend-object-add-mov-imm32 parts 0 reg)]
    [(or (Global _) (GlobalAddr _) (String _) (Bytes _) (Function _) (F64 _))
      (compiler-backend-object-add-mov-from-rax
        (compiler-backend-object-value-ref parts site (& value) program-index)
        reg)]
    ;; Object eligibility excludes runtime globals and static array
    ;; initializers; loading nothing would leave the destination register
    ;; holding an unrelated value.
    [(compiler_ir_types.CompilerIrValue.RuntimeGlobal _)
      (abort.compiler-abort
        "tl: compiler_backend.compiler-backend-object-load-value-to-reg: runtime global reached the direct object encoder\n")]
    [(compiler_ir_types.CompilerIrValue.StaticArray _)
      (abort.compiler-abort
        "tl: compiler_backend.compiler-backend-object-load-value-to-reg: static array initializer reached the direct object encoder\n")]))

(define (compiler-backend-object-load-value-to-reg-with-type
  [parts : object_target.CompilerBackendObjectTargetParts]
  [site : String]
  [value : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [reg : String]
  [program-index : be_state.CompilerBackendProgramIndex]) : object_target.CompilerBackendObjectTargetParts
  (match (& value)
    [(F64 _)
      (compiler-backend-object-add-mov-from-rax
        (compiler-backend-object-value-ref-with-type
          parts
          site
          value
          ty
          program-index)
        reg)]
    [_
      (compiler-backend-object-load-value-to-reg
        parts
        site
        value
        reg
        program-index)]))

(define (compiler-backend-object-store-reg-to-var
  [parts : object_target.CompilerBackendObjectTargetParts]
  [dst : i64]
  [reg : String]) : object_target.CompilerBackendObjectTargetParts
  (compiler-backend-object-add-nonempty-bytes
    parts
    (compiler-backend-object-store-slot-bytes dst reg)))

(define (compiler-backend-object-addr-of-to-var
  [parts : object_target.CompilerBackendObjectTargetParts]
  [dst : i64]
  [src : i64]) : object_target.CompilerBackendObjectTargetParts
  (compiler-backend-object-store-reg-to-var
    (compiler-backend-object-add-nonempty-bytes
      parts
      (compiler-backend-object-lea-rbp-disp-bytes
        (compiler-backend-object-slot-disp src)
        "%rax"))
    dst
    "%rax"))

(define (compiler-backend-object-move-value-to-var
  [parts : object_target.CompilerBackendObjectTargetParts]
  [site : String]
  [dst : i64]
  [src : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [program-index : be_state.CompilerBackendProgramIndex]) : object_target.CompilerBackendObjectTargetParts
  (compiler-backend-object-store-reg-to-var
    (compiler-backend-object-load-value-to-reg-with-type
      parts
      site
      src
      ty
      "%rax"
      program-index)
    dst
    "%rax"))

(define (compiler-backend-object-group-word-var
  [backend-state : be_state.CompilerBackendState]
  [var : i64]
  [word-index : i64]) : i64
  (if (= word-index 0)
    var
    (+
      (be_state.compiler-backend-function-state-i64
        (be_state.compiler-backend-state-function-state backend-state)
        be_state.compiler-backend-function-i64-current-slot-vars)
      var)))

(define (compiler-backend-object-load-group-word-to-reg
  [backend-state : be_state.CompilerBackendState]
  [parts : object_target.CompilerBackendObjectTargetParts]
  [var : i64]
  [word-index : i64]
  [reg : String]) : object_target.CompilerBackendObjectTargetParts
  (compiler-backend-object-add-nonempty-bytes
    parts
    (compiler-backend-object-load-rbp-disp-bytes
      (compiler-backend-object-slot-disp
        (compiler-backend-object-group-word-var backend-state var word-index))
      reg)))

(define (compiler-backend-object-store-reg-to-group-word
  [backend-state : be_state.CompilerBackendState]
  [parts : object_target.CompilerBackendObjectTargetParts]
  [var : i64]
  [word-index : i64]
  [reg : String]) : object_target.CompilerBackendObjectTargetParts
  (compiler-backend-object-add-nonempty-bytes
    parts
    (compiler-backend-object-store-slot-bytes
      (compiler-backend-object-group-word-var backend-state var word-index)
      reg)))

(define (compiler-backend-object-move-group-value-to-var
  [parts : object_target.CompilerBackendObjectTargetParts]
  [site : String]
  [dst : i64]
  [src : compiler_ir_types.CompilerIrValue]
  [program-index : be_state.CompilerBackendProgramIndex]) : object_target.CompilerBackendObjectTargetParts
  (match (& src)
    [(Var src-var)
      (compiler-backend-object-store-reg-to-group-word
        program-index.backend-state
        (compiler-backend-object-store-reg-to-group-word
          program-index.backend-state
          (compiler-backend-object-load-group-word-to-reg
            program-index.backend-state
            (compiler-backend-object-load-group-word-to-reg
              program-index.backend-state
              parts
              src-var
              0
              "%rax")
            src-var
            1
            "%rdx")
          dst
          0
          "%rax")
        dst
        1
        "%rdx")]
    [_ (compiler-backend-object-value-ref parts site (& src) program-index)]))

(define (compiler-backend-object-pack-to-var
  [parts : object_target.CompilerBackendObjectTargetParts]
  [site : String]
  [dst : i64]
  [words : compiler_ir_types.CompilerIrValueSeq]
  [program-index : be_state.CompilerBackendProgramIndex]) : object_target.CompilerBackendObjectTargetParts
  (if (>= words.len 2)
    (compiler-backend-object-store-reg-to-group-word
      program-index.backend-state
      (compiler-backend-object-store-reg-to-group-word
        program-index.backend-state
        (compiler-backend-object-load-value-to-reg
          (compiler-backend-object-load-value-to-reg
            parts
            (be_state.compiler-backend-global-shared-view site)
            (compiler_ir_types.compiler-ir-value-seq-ref words 0)
            "%rax"
            program-index)
          site
          (compiler_ir_types.compiler-ir-value-seq-ref words 1)
          "%rdx"
          program-index)
        dst
        0
        "%rax")
      dst
      1
      "%rdx")
    (compiler-backend-object-value-seq-ref parts site words program-index)))

(define (compiler-backend-object-word-to-var
  [parts : object_target.CompilerBackendObjectTargetParts]
  [site : String]
  [dst : i64]
  [src : compiler_ir_types.CompilerIrValue]
  [word-index : i64]
  [program-index : be_state.CompilerBackendProgramIndex]) : object_target.CompilerBackendObjectTargetParts
  (match (& src)
    [(Var src-var)
      (compiler-backend-object-store-reg-to-var
        (compiler-backend-object-load-group-word-to-reg
          program-index.backend-state
          parts
          src-var
          word-index
          "%rax")
        dst
        "%rax")]
    [_ (compiler-backend-object-value-ref parts site (& src) program-index)]))

(define (compiler-backend-object-load-ptr-to-var
  [type-segment-bases : i64]
  [parts : object_target.CompilerBackendObjectTargetParts]
  [site : String]
  [dst : i64]
  [src : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [program-index : be_state.CompilerBackendProgramIndex]) : object_target.CompilerBackendObjectTargetParts
  (compiler-backend-object-store-reg-to-var
    (compiler-backend-object-add-nonempty-bytes
      (compiler-backend-object-load-value-to-reg
        parts
        site
        src
        "%rax"
        program-index)
      (compiler-backend-object-load-rax-pointee-bytes type-segment-bases ty))
    dst
    "%rax"))

(define (compiler-backend-object-sub-imm32-rax-bytes [value : i64]) : String
  (let
    [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    (compiler-backend-object-push-u8! (&mut out) 0x48)
    (compiler-backend-object-push-u8! (&mut out) 0x2d)
    (compiler-backend-object-push-u32! (&mut out) value)
    (compiler-backend-object-bytes-finish (& out))))

(define (compiler-backend-object-add-imm32-rax-bytes [value : i64]) : String
  (let
    [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    (compiler-backend-object-push-u8! (&mut out) 0x48)
    (compiler-backend-object-push-u8! (&mut out) 0x05)
    (compiler-backend-object-push-u32! (&mut out) value)
    (compiler-backend-object-bytes-finish (& out))))

(define (compiler-backend-object-imul-imm32-r8-bytes [value : i64]) : String
  (let
    [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    (compiler-backend-object-push-u8! (&mut out) 0x4d)
    (compiler-backend-object-push-u8! (&mut out) 0x69)
    (compiler-backend-object-push-u8! (&mut out) 0xc0)
    (compiler-backend-object-push-u32! (&mut out) value)
    (compiler-backend-object-bytes-finish (& out))))

(define (compiler-backend-object-add-r8-rax-bytes) : String
  (object_target.compiler-backend-object-bytes-from-hex "4c01c0"))

(define (compiler-backend-object-gep-to-var
  [type-segment-bases : i64]
  [parts : object_target.CompilerBackendObjectTargetParts]
  [site : String]
  [dst : i64]
  [base : compiler_ir_types.CompilerIrValue]
  [offset : compiler_ir_types.CompilerIrValue]
  [elem-ty : compiler_ast_types.AstType]
  [program-index : be_state.CompilerBackendProgramIndex]) : object_target.CompilerBackendObjectTargetParts
  (let
    [elem-size : i64
      (be_operand.compiler-backend-type-size type-segment-bases elem-ty)]
    [with-base : object_target.CompilerBackendObjectTargetParts
      (compiler-backend-object-load-value-to-reg
        parts
        (be_state.compiler-backend-global-shared-view site)
        base
        "%rax"
        program-index)]
    [with-offset : object_target.CompilerBackendObjectTargetParts
      (match (& offset)
        [(I64 n)
          (let
            [disp : i64 (* n elem-size)]
            (if (= disp 0)
              with-base
              (compiler-backend-object-add-nonempty-bytes
                with-base
                (compiler-backend-object-add-imm32-rax-bytes disp))))]
        [_
          (compiler-backend-object-add-nonempty-bytes
            (if (= elem-size 1)
              (compiler-backend-object-load-value-to-reg
                with-base
                site
                offset
                "%r8"
                program-index)
              (compiler-backend-object-add-nonempty-bytes
                (compiler-backend-object-load-value-to-reg
                  with-base
                  site
                  offset
                  "%r8"
                  program-index)
                (compiler-backend-object-imul-imm32-r8-bytes elem-size)))
            (compiler-backend-object-add-r8-rax-bytes))])]
    (compiler-backend-object-store-reg-to-var with-offset dst "%rax")))

;; `cmpq %rcx, %rax` (REX.W 39 /r): flags from %rax - %rcx.
(define (compiler-backend-object-cmp-rcx-rax-bytes) : String
  (let
    [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    (compiler-backend-object-push-u8! (&mut out) 0x48)
    (compiler-backend-object-push-u8! (&mut out) 0x39)
    (compiler-backend-object-push-u8! (&mut out) 0xc8)
    (compiler-backend-object-bytes-finish (& out))))

(define (compiler-backend-object-cmp-imm32-rax-bytes [value : i64]) : String
  (let
    [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    (compiler-backend-object-push-u8! (&mut out) 0x48)
    (compiler-backend-object-push-u8! (&mut out) 0x3d)
    (compiler-backend-object-push-u32! (&mut out) value)
    (compiler-backend-object-bytes-finish (& out))))

(define (compiler-backend-object-switch-indirect-jump-bytes) : String
  (object_target.compiler-backend-object-bytes-from-hex "49ff24c3"))

(define (compiler-backend-object-switch-entry-label
  [table-label : (& table-label str)]
  [index : i64]) : String
  (str_cat.str-cat table-label "_entry_" (string.int->string index)))

(define (compiler-backend-object-switch-table-cases
  [parts : object_target.CompilerBackendObjectTargetParts]
  [label-scope : String]
  [table-label : String]
  [cases : compiler_ir_types.CompilerIrSwitchCaseSeq]
  [index : i64]) : object_target.CompilerBackendObjectTargetParts
  (if (>= index cases.len)
    parts
    (match (compiler_ir_types.compiler-ir-switch-case-seq-borrow cases index)
      [(Case _ label)
        (let
          [entry-label : String
            (compiler-backend-object-switch-entry-label table-label index)]
          [target : String
            (be_operand.compiler-backend-asm-label
              (be_state.compiler-backend-global-shared-view label-scope)
              label)]
          (compiler-backend-object-switch-table-cases
            (object_target.compiler-backend-object-add-rodata
              (object_target.compiler-backend-object-add-rodata-relocation
                (object_target.compiler-backend-object-add-rodata
                  parts
                  (Label
                    (be_state.compiler-backend-global-shared-view entry-label)))
                entry-label
                (Abs64)
                (be_state.compiler-backend-global-shared-view target))
              (SymbolAddress target))
            label-scope
            table-label
            cases
            (+ index 1)))])))

(define (compiler-backend-object-switch-table
  [parts : object_target.CompilerBackendObjectTargetParts]
  [label-scope : String]
  [current-label : i64]
  [cases : compiler_ir_types.CompilerIrSwitchCaseSeq]) : object_target.CompilerBackendObjectTargetParts
  (let
    [table-label : String
      (be_facts.compiler-backend-switch-table-label
        (be_state.compiler-backend-global-shared-view label-scope)
        current-label)]
    (compiler-backend-object-switch-table-cases
      (object_target.compiler-backend-object-add-rodata
        (object_target.compiler-backend-object-add-rodata
          (object_target.compiler-backend-object-symbol-local-section
            parts
            (be_state.compiler-backend-global-shared-view table-label)
            (Rodata)
            (Data))
          (Align 8))
        (Label (be_state.compiler-backend-global-shared-view table-label)))
      label-scope
      table-label
      cases
      0)))

(define (compiler-backend-object-switch-dispatch
  [parts : object_target.CompilerBackendObjectTargetParts]
  [function-symbol : String]
  [label-scope : String]
  [current-label : i64]
  [index : compiler_ir_types.CompilerIrValue]
  [base : i64]
  [case-count : i64]
  [default-label : i64]
  [total-switch : bool]
  [program-index : be_state.CompilerBackendProgramIndex]) : object_target.CompilerBackendObjectTargetParts
  (let
    [default-symbol : String
      (be_operand.compiler-backend-asm-label
        (be_state.compiler-backend-global-shared-view label-scope)
        default-label)]
    [table-label : String
      (be_facts.compiler-backend-switch-table-label label-scope current-label)]
    [with-index : object_target.CompilerBackendObjectTargetParts
      (compiler-backend-object-load-value-to-reg
        parts
        (be_state.compiler-backend-global-shared-view function-symbol)
        index
        "%rax"
        program-index)]
    [with-base : object_target.CompilerBackendObjectTargetParts
      (if (= base 0)
        with-index
        (object_target.compiler-backend-object-add-text
          with-index
          (Bytes (compiler-backend-object-sub-imm32-rax-bytes base))))]
    [with-cmp : object_target.CompilerBackendObjectTargetParts
      (if total-switch
        with-base
        (object_target.compiler-backend-object-add-text
          with-base
          (Bytes (compiler-backend-object-cmp-imm32-rax-bytes (- case-count 1)))))]
    [with-ja : object_target.CompilerBackendObjectTargetParts
      (if total-switch
        with-cmp
        (object_target.compiler-backend-object-add-text
          (object_target.compiler-backend-object-add-text-relocation
            with-cmp
            (be_state.compiler-backend-global-shared-view function-symbol)
            (Branch)
            (be_state.compiler-backend-global-shared-view default-symbol))
          (Ja default-symbol)))]
    [with-table : object_target.CompilerBackendObjectTargetParts
      (object_target.compiler-backend-object-add-text
        (object_target.compiler-backend-object-add-text-relocation
          with-ja
          function-symbol
          (RipAddress)
          (be_state.compiler-backend-global-shared-view table-label))
        (LoadRipAddressR11 table-label))]
    (object_target.compiler-backend-object-add-text
      with-table
      (Bytes (compiler-backend-object-switch-indirect-jump-bytes)))))

(define (compiler-backend-object-switch
  [parts : object_target.CompilerBackendObjectTargetParts]
  [function-symbol : String]
  [label-scope : String]
  [current-label : i64]
  [index : compiler_ir_types.CompilerIrValue]
  [base : i64]
  [cases : compiler_ir_types.CompilerIrSwitchCaseSeq]
  [default-label : i64]
  [trap-label : i64]
  [program-index : be_state.CompilerBackendProgramIndex]) : object_target.CompilerBackendObjectTargetParts
  (let
    ;; Decide before the table walker consumes its case-list cursor.
    [total-switch : bool
      (be_facts.compiler-backend-object-total-switch? base cases trap-label)]
    [case-count : i64 (be_facts.compiler-backend-switch-case-count cases)]
    (compiler-backend-object-switch-dispatch
      (compiler-backend-object-switch-table
        parts
        (be_state.compiler-backend-global-shared-view label-scope)
        current-label
        cases)
      function-symbol
      label-scope
      current-label
      index
      base
      case-count
      default-label
      total-switch
      program-index)))

(define (compiler-backend-object-divmod-bytes
  [signed : bool]
  [remainder : bool]) : String
  (object_target.compiler-backend-object-bytes-from-hex
    (&
      (cond
        ;; cqo; idivq %r8; optionally movq %rdx, %rax
        [(and signed remainder) "489949f7f84889d0"]
        [signed "489949f7f8"]
        ;; xorl %edx, %edx; divq %r8; optionally movq %rdx, %rax
        [remainder "31d249f7f04889d0"]
        [else "31d249f7f0"]))))

(define (compiler-backend-object-binop-bytes
  [type-segment-bases : i64]
  [op : (& op compiler_ir_types.CompilerIrBinOp)]
  [ty : (& ty compiler_ast_types.AstType)]) : String
  (match op
    [(Add) (object_target.compiler-backend-object-bytes-from-hex "4c01c0")]
    [(Sub) (object_target.compiler-backend-object-bytes-from-hex "4c29c0")]
    [(Mul) (object_target.compiler-backend-object-bytes-from-hex "490fafc0")]
    [(Div)
      (compiler-backend-object-divmod-bytes
        (be_facts.compiler-backend-type-signed? type-segment-bases ty)
        false)]
    [(Mod)
      (compiler-backend-object-divmod-bytes
        (be_facts.compiler-backend-type-signed? type-segment-bases ty)
        true)]
    [(or (Eq) (Ne) (Lt) (Le) (Gt) (Ge))
      (compiler-backend-object-compare-bytes type-segment-bases op ty 0x38 true)]
    [(or (BitTestEq) (BitTestNe))
      (compiler-backend-object-compare-bytes type-segment-bases op ty 0x84 true)]
    [(or (And) (BitAnd))
      (object_target.compiler-backend-object-bytes-from-hex "4c21c0")]
    [(or (Or) (BitOr))
      (object_target.compiler-backend-object-bytes-from-hex "4c09c0")]
    [(BitXor) (object_target.compiler-backend-object-bytes-from-hex "4c31c0")]
    [_ ""]))

;; `<byte-opcode> <r8 or rax>, rax` at the operand's width, then `set<cc> %al`
;; and `movzbq %al, %rax`. Like the assembly route's sized `cmp` and `test`, it
;; reads only the operand's own bits: a narrow value's frame slot can hold
;; anything above them, from wrapping arithmetic or an assembly-route caller.
;; `byte-opcode` is the 8-bit form; the wider forms are the next opcode.
(define (compiler-backend-object-compare-bytes
  [type-segment-bases : i64]
  [op : (& op compiler_ir_types.CompilerIrBinOp)]
  [ty : (& ty compiler_ast_types.AstType)]
  [byte-opcode : i64]
  [rhs-r8? : bool]) : String
  (let
    [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    [size : i64 (be_operand.compiler-backend-type-size type-segment-bases ty)]
    [wide? : bool (not (or (= size 1) (= size 2) (= size 4)))]
    [rex : i64
      (bit-or
        (if wide?
          0x48
          0x40)
        (if rhs-r8?
          0x04
          0))]
    (when (= size 2) (compiler-backend-object-push-u8! (&mut out) 0x66))
    (when (not (= rex 0x40)) (compiler-backend-object-push-u8! (&mut out) rex))
    (compiler-backend-object-push-u8!
      (&mut out)
      (if (= size 1)
        byte-opcode
        (+ byte-opcode 1)))
    (compiler-backend-object-push-u8! (&mut out) 0xc0)
    (compiler-backend-object-push-u8! (&mut out) 0x0f)
    (compiler-backend-object-push-u8!
      (&mut out)
      (+ 0x90 (compiler-backend-object-compare-cc type-segment-bases op ty)))
    (compiler-backend-object-push-u8! (&mut out) 0xc0)
    (compiler-backend-object-push-u8! (&mut out) 0x48)
    (compiler-backend-object-push-u8! (&mut out) 0x0f)
    (compiler-backend-object-push-u8! (&mut out) 0xb6)
    (compiler-backend-object-push-u8! (&mut out) 0xc0)
    (byte_buf_core.byte-buf-builder-finish-string (& out))))

;; `test` clears CF and OF, so every condition reads as a compare against zero.
(define (compiler-backend-object-zero-compare-bytes
  [type-segment-bases : i64]
  [op : (& op compiler_ir_types.CompilerIrBinOp)]
  [ty : (& ty compiler_ast_types.AstType)]) : String
  (compiler-backend-object-compare-bytes type-segment-bases op ty 0x84 false))

(define (compiler-backend-object-binop
  [parts : object_target.CompilerBackendObjectTargetParts]
  [site : String]
  [dst : i64]
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [program-index : be_state.CompilerBackendProgramIndex]) : object_target.CompilerBackendObjectTargetParts
  (let
    [zero-test? : bool
      (match (& rhs)
        [(I64 value)
          (and
            (= value 0)
            (be_facts.compiler-backend-compare-uses-zero-test? op))]
        [_ false])]
    [op-bytes : String
      (if zero-test?
        (compiler-backend-object-zero-compare-bytes
          program-index.type-segment-bases
          op
          ty)
        (compiler-backend-object-binop-bytes
          program-index.type-segment-bases
          op
          ty))]
    (if (or
      (= (string.string-length op-bytes) 0)
      (be_operand.compiler-backend-float-type? ty))
      (compiler-backend-object-value-ref-with-type
        (compiler-backend-object-value-ref-with-type
          parts
          (be_state.compiler-backend-global-shared-view site)
          lhs
          ty
          program-index)
        site
        rhs
        ty
        program-index)
      ;; The zero test reads only %rax, so it skips loading the zero.
      (compiler-backend-object-store-reg-to-var
        (compiler-backend-object-add-nonempty-bytes
          (compiler-backend-object-load-value-to-reg
            (if zero-test?
              parts
              (compiler-backend-object-load-value-to-reg
                parts
                (be_state.compiler-backend-global-shared-view site)
                rhs
                "%r8"
                program-index))
            site
            lhs
            "%rax"
            program-index)
          op-bytes)
        dst
        "%rax"))))

(define (compiler-backend-object-scalar-select
  [parts : object_target.CompilerBackendObjectTargetParts]
  [site : String]
  [dst : i64]
  [condition : compiler_ir_types.CompilerIrValue]
  [on-true : compiler_ir_types.CompilerIrValue]
  [on-false : compiler_ir_types.CompilerIrValue]
  [program-index : be_state.CompilerBackendProgramIndex]) : object_target.CompilerBackendObjectTargetParts
  ;; Object emission keeps scalar vars in frame homes, so fixed temporaries are
  ;; safe here: false -> rax, true -> r8, condition -> r11, then cmovne.
  (compiler-backend-object-store-reg-to-var
    (compiler-backend-object-add-nonempty-bytes
      (compiler-backend-object-load-value-to-reg
        (compiler-backend-object-load-value-to-reg
          (compiler-backend-object-load-value-to-reg
            parts
            (be_state.compiler-backend-global-shared-view site)
            on-false
            "%rax"
            program-index)
          (be_state.compiler-backend-global-shared-view site)
          on-true
          "%r8"
          program-index)
        site
        condition
        "%r11"
        program-index)
      (object_target.compiler-backend-object-bytes-from-hex "4d85db490f45c0"))
    dst
    "%rax"))

(define (compiler-backend-object-call-arg-reg
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [index : i64]) : String
  (match (be_facts.compiler-backend-target-arg-reg target convention index)
    [(Ok reg) reg]
    [(Err _) "%rax"]))

(define (compiler-backend-object-call-reg-count
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]) : i64
  (be_facts.compiler-backend-call-register-count target convention))

(define (compiler-backend-object-call-stack-word-count
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [args : compiler_ir_types.CompilerIrCallArgs]) : i64
  (let
    [count : i64 (be_facts.compiler-backend-call-args-count args)]
    [regs : i64 (compiler-backend-object-call-reg-count target convention)]
    (if (> count regs)
      (- count regs)
      0)))

(define (compiler-backend-object-call-space
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [args : compiler_ir_types.CompilerIrCallArgs]) : i64
  (if (compiler-backend-object-stack-args? target)
    (be_operand.compiler-backend-round-up-16
      (+
        (be_facts.compiler-backend-outgoing-shadow-space target convention)
        (*
          8
          (compiler-backend-object-call-stack-word-count target convention args))))
    0))

(define (compiler-backend-object-call-stack-arg
  [parts : object_target.CompilerBackendObjectTargetParts]
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [site : String]
  [value : compiler_ir_types.CompilerIrValue]
  [stack-index : i64]
  [program-index : be_state.CompilerBackendProgramIndex]) : object_target.CompilerBackendObjectTargetParts
  (compiler-backend-object-add-nonempty-bytes
    (compiler-backend-object-load-value-to-reg
      parts
      site
      value
      "%rax"
      program-index)
    (compiler-backend-object-store-rax-rsp-bytes
      (be_facts.compiler-backend-outgoing-stack-arg-offset
        target
        convention
        stack-index))))

(define (compiler-backend-object-call-arg-moves
  [parts : object_target.CompilerBackendObjectTargetParts]
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [site : String]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [index : i64]
  [program-index : be_state.CompilerBackendProgramIndex]) : object_target.CompilerBackendObjectTargetParts
  (if (>=
    index
    (be_facts.compiler-backend-call-args-count
      (be_state.compiler-backend-global-shared-view args)))
    parts
    (if (>= index (compiler-backend-object-call-reg-count target convention))
      (if (compiler-backend-object-stack-args? target)
        (compiler-backend-object-call-arg-moves
          (compiler-backend-object-call-stack-arg
            parts
            target
            convention
            (be_state.compiler-backend-global-shared-view site)
            (be_facts.compiler-backend-call-arg-at args index)
            (- index (compiler-backend-object-call-reg-count target convention))
            program-index)
          target
          convention
          site
          args
          (+ index 1)
          program-index)
        parts)
      (compiler-backend-object-call-arg-moves
        (compiler-backend-object-load-value-to-reg
          parts
          (be_state.compiler-backend-global-shared-view site)
          (be_facts.compiler-backend-call-arg-at args index)
          (compiler-backend-object-call-arg-reg target convention index)
          program-index)
        target
        convention
        site
        args
        (+ index 1)
        program-index))))

(define (compiler-backend-object-direct-call
  [parts : object_target.CompilerBackendObjectTargetParts]
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [site : String]
  [symbol : String]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [program-index : be_state.CompilerBackendProgramIndex]) : object_target.CompilerBackendObjectTargetParts
  (let
    [space : i64
      (compiler-backend-object-call-space
        target
        convention
        (be_state.compiler-backend-global-shared-view args))]
    (compiler-backend-object-add-nonempty-bytes
      (object_target.compiler-backend-object-add-text
        (object_target.compiler-backend-object-add-text-relocation
          (compiler-backend-object-call-arg-moves
            (compiler-backend-object-add-nonempty-bytes
              parts
              (compiler-backend-object-sub-rsp-bytes
                space
                program-index.backend-state))
            target
            convention
            (be_state.compiler-backend-global-shared-view site)
            args
            0
            program-index)
          site
          (Call)
          (be_state.compiler-backend-global-shared-view symbol))
        (Call symbol))
      (compiler-backend-object-add-rsp-bytes space))))

(define (compiler-backend-object-param-spills-from
  [parts : object_target.CompilerBackendObjectTargetParts]
  [target : be_state.CompilerBackendTarget]
  [params : (& compiler_ir_types.CompilerIrParamSeq)]
  [int-index : i64]
  [param-index : i64]) : object_target.CompilerBackendObjectTargetParts
  (if (>= param-index params.len)
    parts
    (match (compiler_ir_types.compiler-ir-param-seq-borrow params param-index)
      [(Param _ ty var-id)
        (if (be_operand.compiler-backend-float-type? ty)
          (compiler-backend-object-param-spills-from
            parts
            target
            params
            int-index
            (+ param-index 1))
          (if (>=
            int-index
            (compiler-backend-object-call-reg-count target (Internal)))
            (compiler-backend-object-param-spills-from
              (if (compiler-backend-object-stack-args? target)
                (compiler-backend-object-store-reg-to-var
                  (compiler-backend-object-add-nonempty-bytes
                    parts
                    (compiler-backend-object-load-rbp-disp-bytes
                      (be_facts.compiler-backend-incoming-stack-arg-offset
                        target
                        (-
                          int-index
                          (compiler-backend-object-call-reg-count
                            target
                            (Internal))))
                      "%rax"))
                  var-id
                  "%rax")
                parts)
              target
              params
              (+ int-index 1)
              (+ param-index 1))
            (compiler-backend-object-param-spills-from
              (compiler-backend-object-store-reg-to-var
                parts
                var-id
                (compiler-backend-object-call-arg-reg
                  target
                  (Internal)
                  int-index))
              target
              params
              (+ int-index 1)
              (+ param-index 1))))])))

(define (compiler-backend-object-param-spills
  [parts : object_target.CompilerBackendObjectTargetParts]
  [target : be_state.CompilerBackendTarget]
  [params : (& params compiler_ir_types.CompilerIrParamSeq)]
  [int-index : i64]) : object_target.CompilerBackendObjectTargetParts
  (compiler-backend-object-param-spills-from parts target params int-index 0))

;; --- object-image phi edge copies --------------------------------------------
;;
;; The object emitter assigns every IR var its own rbp slot, so a phi whose
;; destination differs from an input needs a real copy on each incoming edge;
;; materializing the inputs and dropping the destination would silently read
;; an uninitialized slot at the merge. Jump and Branch
;; terminators targeting a block with leading phis emit these copies before
;; transferring control; conditional edges are split into tiny edge blocks so
;; each edge's copies run only when that edge is taken. Copies are staged
;; through the stack (sources first, destinations after) so parallel-copy
;; cycles like a<-b, b<-a cannot clobber a pending source. Aggregate
;; (copy-group) phis only materialize their inputs; the tlci image path never
;; lowers those.
(define (compiler-backend-object-phi-copy-list-count
  [copies : (& copies be_state.CompilerBackendPhiCopySeq)]) : i64
  copies.len)

(define (compiler-backend-object-phi-copy-list-nil?
  [copies : (& copies be_state.CompilerBackendPhiCopySeq)]) : bool
  (= copies.len 0))

;; Collected in instruction order; the stage/store walkers read it back to front
;; (compiler-backend-phi-copy-seq-rev-ref).
(define (compiler-backend-object-edge-phi-copies-scan
  [type-segment-bases : i64]
  [instrs : compiler_ir_types.CompilerIrInstrSeq]
  [program-index : be_state.CompilerBackendProgramIndex]
  [from-label : i64]
  [index : i64]) : be_state.CompilerBackendPhiCopySeq
  (let
    [out : be_state.CompilerBackendPhiCopySeq
      (be_state.compiler-backend-phi-copy-seq-with-capacity 0)]
    [i : i64 index]
    [n : i64 (compiler_ir_types.compiler-ir-instr-seq-count instrs)]
    (while (< i n)
      (match (compiler_ir_types.compiler-ir-instr-seq-ref instrs i)
        [(Phi dst inputs ty)
          (match (be_facts.compiler-backend-phi-input-value inputs from-label)
            [(Ok value)
              (if (be_facts.compiler-backend-copy-group?
                type-segment-bases
                program-index
                (be_state.compiler-backend-global-shared-view ty)
                dst
                (be_state.compiler-backend-global-shared-view value))
                unit
                (be_state.compiler-backend-phi-copy-push!
                  (&mut out)
                  (Copy dst (Value value) ty)))]
            [(Err _) unit])
          (+= i 1)]
        [_ (set! i n)]))
    out))

(define (compiler-backend-object-edge-phi-copies-seq
  [type-segment-bases : i64]
  [blocks : compiler_ir_types.CompilerIrBlockSeq]
  [program-index : be_state.CompilerBackendProgramIndex]
  [target-label : i64]
  [from-label : i64]) : be_state.CompilerBackendPhiCopySeq
  (for [index
    (iterator.range 0 (compiler_ir_types.compiler-ir-block-seq-count blocks))]
    (match (compiler_ir_types.compiler-ir-block-seq-ref blocks index)
      [(Block label instrs)
        (when
          (= label target-label)
          (return
            (compiler-backend-object-edge-phi-copies-scan
              type-segment-bases
              instrs
              program-index
              from-label
              0)))]))
  (be_state.compiler-backend-phi-copy-seq-with-capacity 0))

(define (compiler-backend-object-edge-phi-copies
  [type-segment-bases : i64]
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [program-index : be_state.CompilerBackendProgramIndex]
  [target-label : i64]
  [from-label : i64]) : be_state.CompilerBackendPhiCopySeq
  (match blocks
    [(Array seq)
      (compiler-backend-object-edge-phi-copies-seq
        type-segment-bases
        seq
        program-index
        target-label
        from-label)]))

(define (compiler-backend-object-emit-phi-copies-stage
  [parts : object_target.CompilerBackendObjectTargetParts]
  [site : String]
  [copies : be_state.CompilerBackendPhiCopySeq]
  [index : i64]
  [program-index : be_state.CompilerBackendProgramIndex]) : object_target.CompilerBackendObjectTargetParts
  (if (>= index copies.len)
    parts
    (match (be_state.compiler-backend-phi-copy-seq-rev-ref copies index)
      [(Copy _ source ty)
        (match source
          [(Value value)
            (compiler-backend-object-emit-phi-copies-stage
              (compiler-backend-object-add-nonempty-bytes
                (compiler-backend-object-load-value-to-reg-with-type
                  parts
                  (be_state.compiler-backend-global-shared-view site)
                  value
                  ty
                  "%rax"
                  program-index)
                (compiler-backend-object-store-rax-rsp-bytes (* index 8)))
              site
              copies
              (+ index 1)
              program-index)]
          [(Temp _)
            (compiler-backend-object-emit-phi-copies-stage
              parts
              site
              copies
              (+ index 1)
              program-index)])])))

(define (compiler-backend-object-emit-phi-copies-store
  [parts : object_target.CompilerBackendObjectTargetParts]
  [copies : be_state.CompilerBackendPhiCopySeq]
  [index : i64]) : object_target.CompilerBackendObjectTargetParts
  (if (>= index copies.len)
    parts
    (match (be_state.compiler-backend-phi-copy-seq-rev-ref copies index)
      [(Copy dst _ _)
        (compiler-backend-object-emit-phi-copies-store
          (compiler-backend-object-store-reg-to-var
            (compiler-backend-object-add-nonempty-bytes
              parts
              (compiler-backend-object-load-rax-rsp-bytes (* index 8)))
            dst
            "%rax")
          copies
          (+ index 1))])))

(define (compiler-backend-object-emit-phi-copies-staged
  [parts : object_target.CompilerBackendObjectTargetParts]
  [site : String]
  [copies : be_state.CompilerBackendPhiCopySeq]
  [count : i64]
  [program-index : be_state.CompilerBackendProgramIndex]) : object_target.CompilerBackendObjectTargetParts
  (compiler-backend-object-add-nonempty-bytes
    (compiler-backend-object-emit-phi-copies-store
      (compiler-backend-object-emit-phi-copies-stage
        (compiler-backend-object-add-nonempty-bytes
          parts
          (compiler-backend-object-sub-rsp-bytes
            (* count 8)
            program-index.backend-state))
        site
        (be_state.compiler-backend-global-shared-view copies)
        0
        program-index)
      copies
      0)
    (compiler-backend-object-add-rsp-bytes (* count 8))))

;; Several copies on one edge are a parallel move: every source is staged on
;; the stack before any destination is written, so no copy reads a slot an
;; earlier copy already overwrote. A lone copy has no other copy to clobber, so
;; it moves its value straight into the destination slot. That is 14 bytes
;; instead of 32 at a pair of stack-slot displacements, and it is the common
;; edge: the native TLCI entries have one on nearly every if-merge.
(define (compiler-backend-object-emit-phi-copies
  [parts : object_target.CompilerBackendObjectTargetParts]
  [site : String]
  [copies : be_state.CompilerBackendPhiCopySeq]
  [program-index : be_state.CompilerBackendProgramIndex]) : object_target.CompilerBackendObjectTargetParts
  (let
    [count : i64 (compiler-backend-object-phi-copy-list-count copies)]
    (cond
      [(= count 0) parts]
      [(= count 1)
        (match (be_state.compiler-backend-phi-copy-seq-rev-ref copies 0)
          [(Copy dst source ty)
            (match source
              [(Value value)
                (compiler-backend-object-store-reg-to-var
                  (compiler-backend-object-load-value-to-reg-with-type
                    parts
                    site
                    value
                    ty
                    "%rax"
                    program-index)
                  dst
                  "%rax")]
              [(Temp _)
                (compiler-backend-object-emit-phi-copies-staged
                  parts
                  site
                  copies
                  count
                  program-index)])])]
      [else
        (compiler-backend-object-emit-phi-copies-staged
          parts
          site
          copies
          count
          program-index)])))

(define (compiler-backend-object-use-ref
  [site : String]
  [ty : compiler_ast_types.AstMaybeType]
  [program-index : be_state.CompilerBackendProgramIndex]
  [_role : compiler_ir_types.CompilerIrOperandRole]
  [parts : object_target.CompilerBackendObjectTargetParts]
  [value : compiler_ir_types.CompilerIrValue]) : object_target.CompilerBackendObjectTargetParts
  (match ty
    [(Some use-ty)
      (compiler-backend-object-value-ref-with-type
        parts
        site
        value
        use-ty
        program-index)]
    [(No)
      (compiler-backend-object-value-ref parts site (& value) program-index)]))

;; The references of an instruction the object emitter only discovers
;; references for: each use, in operand order, references the symbol it names,
;; read as a `ty` value when `ty` is given.
(define (compiler-backend-object-uses-ref
  [parts : object_target.CompilerBackendObjectTargetParts]
  [site : String]
  [instr : compiler_ir_types.CompilerIrInstr]
  [ty : compiler_ast_types.AstMaybeType]
  [program-index : be_state.CompilerBackendProgramIndex]) : object_target.CompilerBackendObjectTargetParts
  (compiler_ir_types.compiler-ir-instr-fold-uses
    instr
    parts
    compiler-backend-object-use-ref
    (be_state.compiler-backend-global-shared-view site)
    (be_state.compiler-backend-global-shared-view ty)
    program-index))

;; The object walk emits a function's blocks in order. It records the label of
;; the block it emits next, so a jump there can fall through instead.
(define (compiler-backend-object-next-label
  [program-index : be_state.CompilerBackendProgramIndex]) : i64
  (be_state.compiler-backend-function-scratch-i64
    (be_state.compiler-backend-state-function-state program-index.backend-state)
    be_state.compiler-backend-scratch-i64-object-next-label))

(define (compiler-backend-object-set-next-label!
  [program-index : be_state.CompilerBackendProgramIndex]
  [label : i64]) : unit
  (be_state.compiler-backend-function-scratch-set-i64!
    (be_state.compiler-backend-state-function-state program-index.backend-state)
    be_state.compiler-backend-scratch-i64-object-next-label
    label))

;; The x86 condition code the object compare leaves in the flags for `op`,
;; the one its `set<cc>` reads; -1 for anything else.
(define (compiler-backend-object-compare-cc
  [type-segment-bases : i64]
  [op : (& compiler_ir_types.CompilerIrBinOp)]
  [ty : (& compiler_ast_types.AstType)]) : i64
  (match op
    [(or (Eq) (BitTestEq)) 0x4]
    [(or (Ne) (BitTestNe)) 0x5]
    [(Lt) (compiler-backend-object-ordering-cc type-segment-bases ty 0x2 0xc)]
    [(Le) (compiler-backend-object-ordering-cc type-segment-bases ty 0x6 0xe)]
    [(Gt) (compiler-backend-object-ordering-cc type-segment-bases ty 0x7 0xf)]
    [(Ge) (compiler-backend-object-ordering-cc type-segment-bases ty 0x3 0xd)]
    [_ -1]))

(define (compiler-backend-object-ordering-cc
  [type-segment-bases : i64]
  [ty : (& compiler_ast_types.AstType)]
  [unsigned-cc : i64]
  [signed-cc : i64]) : i64
  (if (be_operand.compiler-backend-unsigned-rel-ty? type-segment-bases ty)
    unsigned-cc
    signed-cc))

;; An integer compare stores its `set<cc>` result with plain moves, which keep
;; the flags. When it is the instruction right before a branch, the branch can
;; jump on those flags instead of reloading the result and testing it.
(define (compiler-backend-object-note-flags!
  [program-index : be_state.CompilerBackendProgramIndex]
  [instrs : (& instrs compiler_ir_types.CompilerIrInstrSeq)]
  [index : i64]) : unit
  (let
    [state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state
        program-index.backend-state)]
    [flags-var : i64
      (if (= index 0)
        -1
        (match (compiler_ir_types.compiler-ir-instr-seq-borrow
          instrs
          (- index 1))
          [(BinOp dst op _ _ ty)
            (let
              [cc : i64
                (compiler-backend-object-compare-cc
                  program-index.type-segment-bases
                  op
                  ty)]
              (if (or (< cc 0) (be_operand.compiler-backend-float-type? ty))
                -1
                (begin
                  (be_state.compiler-backend-function-scratch-set-i64!
                    state
                    be_state.compiler-backend-scratch-i64-object-flags-cc
                    cc)
                  dst)))]
          [_ -1]))]
    (be_state.compiler-backend-function-scratch-set-i64!
      state
      be_state.compiler-backend-scratch-i64-object-flags-var
      flags-var)))

;; The condition code that holds exactly when `cond` is nonzero, if the flags
;; of the compare that produced `cond` are still live; -1 otherwise.
(define (compiler-backend-object-branch-flags-cc
  [cond : compiler_ir_types.CompilerIrValue]
  [program-index : be_state.CompilerBackendProgramIndex]) : i64
  (let
    [state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state
        program-index.backend-state)]
    (match cond
      [(Var id)
        (if (and
          (>= id 0)
          (=
            id
            (be_state.compiler-backend-function-scratch-i64
              state
              be_state.compiler-backend-scratch-i64-object-flags-var)))
          (be_state.compiler-backend-function-scratch-i64
            state
            be_state.compiler-backend-scratch-i64-object-flags-cc)
          -1)]
      [_ -1])))

;; Sets the flags for a branch on `cond`: nothing when the compare's flags are
;; live (`flags-cc` >= 0), else `test %rax, %rax` on the loaded value, after
;; which `ne` holds exactly when it is nonzero.
(define (compiler-backend-object-branch-test
  [parts : object_target.CompilerBackendObjectTargetParts]
  [site : String]
  [cond : compiler_ir_types.CompilerIrValue]
  [flags-cc : i64]
  [program-index : be_state.CompilerBackendProgramIndex]) : object_target.CompilerBackendObjectTargetParts
  (if (>= flags-cc 0)
    parts
    (compiler-backend-object-add-nonempty-bytes
      (compiler-backend-object-load-value-to-reg
        parts
        site
        cond
        "%rax"
        program-index)
      (object_target.compiler-backend-object-bytes-from-hex "4885c0"))))

(define (compiler-backend-object-jcc
  [parts : object_target.CompilerBackendObjectTargetParts]
  [site : String]
  [cc : i64]
  [symbol : String]) : object_target.CompilerBackendObjectTargetParts
  (object_target.compiler-backend-object-add-text
    (object_target.compiler-backend-object-add-text-relocation
      parts
      site
      (Branch)
      (be_state.compiler-backend-global-shared-view symbol))
    (Jcc cc symbol)))

;; A jump to `label`'s block, left out when that block is emitted next.
(define (compiler-backend-object-jump
  [parts : object_target.CompilerBackendObjectTargetParts]
  [site : String]
  [symbol : String]
  [label : i64]
  [next-label : i64]) : object_target.CompilerBackendObjectTargetParts
  (if (and
    (compiler_ir_types.compiler-ir-label-some? next-label)
    (= label next-label))
    parts
    (object_target.compiler-backend-object-add-text
      (object_target.compiler-backend-object-add-text-relocation
        parts
        site
        (Branch)
        (be_state.compiler-backend-global-shared-view symbol))
      (Jump symbol))))

(define (compiler-backend-object-instr
  [type-segment-bases : i64]
  [parts : object_target.CompilerBackendObjectTargetParts]
  [target : be_state.CompilerBackendTarget]
  [function : String]
  [label-scope : String]
  [current-label : i64]
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [instr : compiler_ir_types.CompilerIrInstr]
  [plan : be_state.CompilerBackendRuntimePlan]
  [program-index : be_state.CompilerBackendProgramIndex]) : object_target.CompilerBackendObjectTargetParts
  (match (be_state.compiler-backend-global-shared-view instr)
    [(compiler_ir_types.CompilerIrInstr.Mov dst src ty)
      (if (be_facts.compiler-backend-copy-group?
        type-segment-bases
        program-index
        (be_state.compiler-backend-global-shared-view ty)
        dst
        (be_state.compiler-backend-global-shared-view src))
        (compiler-backend-object-move-group-value-to-var
          parts
          function
          dst
          src
          program-index)
        (compiler-backend-object-move-value-to-var
          parts
          function
          dst
          src
          ty
          program-index))]
    [(compiler_ir_types.CompilerIrInstr.BinOp dst op lhs rhs ty)
      (compiler-backend-object-binop
        parts
        function
        dst
        op
        lhs
        rhs
        ty
        program-index)]
    [(compiler_ir_types.CompilerIrInstr.UnOp dst op src ty)
      (let
        [site : String (be_state.compiler-backend-global-shared-view function)]
        [with-src : object_target.CompilerBackendObjectTargetParts
          (if (be_operand.compiler-backend-float-type? ty)
            (compiler-backend-object-value-ref-with-type
              parts
              site
              src
              ty
              program-index)
            ;; The integer operators below work on %rax in place.
            (compiler-backend-object-load-value-to-reg
              parts
              site
              src
              "%rax"
              program-index))]
        (if (and
          (be_operand.compiler-backend-float-type? ty)
          (match op
            [(compiler_ir_types.CompilerIrUnOp.Neg) true]
            [_ false]))
          (compiler-backend-object-store-reg-to-var
            (object_target.compiler-backend-object-add-rip-instr
              with-src
              function
              (cobj.CompilerObjectRelocationKind.RipValue)
              (if (be_state.compiler-backend-f64-type? ty)
                (be_facts.compiler-backend-f64-sign-bit-label)
                (be_facts.compiler-backend-f32-sign-bit-label))
              (cobj.CompilerObjectX64Instr.XorpdRip
                (if (be_state.compiler-backend-f64-type? ty)
                  (be_facts.compiler-backend-f64-sign-bit-label)
                  (be_facts.compiler-backend-f32-sign-bit-label))))
            dst
            "%rax")
          (compiler-backend-object-store-reg-to-var
            (compiler-backend-object-add-nonempty-bytes
              with-src
              (compiler-backend-object-unop-rax-bytes op))
            dst
            "%rax")))]
    [(compiler_ir_types.CompilerIrInstr.Call dst name args _)
      (let
        [call-target : String
          (be_operand.compiler-backend-call-symbol-index
            name
            plan
            program-index)]
        (compiler-backend-object-store-reg-to-var
          (compiler-backend-object-direct-call
            parts
            target
            (compiler_regalloc.compiler-reg-direct-call-convention name)
            function
            call-target
            args
            program-index)
          dst
          "%rax"))]
    [(compiler_ir_types.CompilerIrInstr.CallIndirectC dst callee args _)
      ;; Mirror object-direct-call, with the callee loaded into %r11 after
      ;; the argument moves (load-value-to-reg scratches through %rax, and
      ;; %r11 survives the C argument registers), an indirect call, and the
      ;; result stored from %rax.
      (let
        [space : i64
          (compiler-backend-object-call-space
            target
            (Platform)
            (be_state.compiler-backend-global-shared-view args))]
        (compiler-backend-object-store-reg-to-var
          (compiler-backend-object-add-nonempty-bytes
            (object_target.compiler-backend-object-add-text
              (compiler-backend-object-load-value-to-reg
                (compiler-backend-object-call-arg-moves
                  (compiler-backend-object-add-nonempty-bytes
                    parts
                    (compiler-backend-object-sub-rsp-bytes
                      space
                      program-index.backend-state))
                  target
                  (Platform)
                  (be_state.compiler-backend-global-shared-view function)
                  args
                  0
                  program-index)
                function
                callee
                "%r11"
                program-index)
              (cobj.CompilerObjectX64Instr.Bytes
                (compiler-backend-object-call-r11-bytes)))
            (compiler-backend-object-add-rsp-bytes space))
          dst
          "%rax"))]
    [(compiler_ir_types.CompilerIrInstr.CallCAbiStoreResult payload-box)
      (let
        [base
          (be_state.compiler-backend-box-field-shared-view payload-box base)]
        [name
          (be_state.compiler-backend-box-field-shared-view payload-box name)]
        [args
          (be_state.compiler-backend-box-field-shared-view payload-box args)]
        [call-target : String
          (be_operand.compiler-backend-call-symbol-index
            name
            plan
            program-index)]
        (compiler-backend-object-direct-call
          (compiler-backend-object-value-ref
            parts
            (be_state.compiler-backend-global-shared-view function)
            base
            program-index)
          target
          (Platform)
          (be_state.compiler-backend-global-shared-view function)
          call-target
          args
          program-index))]
    [(compiler_ir_types.CompilerIrInstr.TailCall name args _)
      (let
        [call-target : String
          (be_operand.compiler-backend-call-symbol-index
            name
            plan
            program-index)]
        (object_target.compiler-backend-object-add-text
          (object_target.compiler-backend-object-add-text-relocation
            (compiler-backend-object-add-nonempty-bytes
              (compiler-backend-object-call-arg-moves
                parts
                target
                (compiler_regalloc.compiler-reg-direct-call-convention name)
                (be_state.compiler-backend-global-shared-view function)
                args
                0
                program-index)
              (compiler-backend-object-leave-bytes))
            (be_state.compiler-backend-global-shared-view function)
            (cobj.CompilerObjectRelocationKind.TailCall)
            (be_state.compiler-backend-global-shared-view call-target))
          (cobj.CompilerObjectX64Instr.TailCall call-target)))]
    [(compiler_ir_types.CompilerIrInstr.Store name value ty)
      (let
        [symbol : String
          (be_operand.compiler-backend-global-symbol-index program-index name)]
        [inline-size : i64
          (be_state.compiler-backend-inline-aggregate-global-size
            program-index.backend-state
            name)]
        (if (> inline-size 0)
          ;; IAG-1: the cell holds the aggregate, so the rebind copies bytes.
          (compiler-backend-object-add-nonempty-bytes
            (object_target.compiler-backend-object-add-text
              (object_target.compiler-backend-object-add-text-relocation
                (compiler-backend-object-load-value-to-reg-with-type
                  parts
                  (be_state.compiler-backend-global-shared-view function)
                  value
                  ty
                  "%rax"
                  program-index)
                function
                (cobj.CompilerObjectRelocationKind.RipAddress)
                (be_state.compiler-backend-global-shared-view symbol))
              (cobj.CompilerObjectX64Instr.LoadRipAddressR11 symbol))
            (compiler-backend-object-inline-aggregate-copy-bytes inline-size))
          (object_target.compiler-backend-object-add-text
            (object_target.compiler-backend-object-add-text-relocation
              (compiler-backend-object-load-value-to-reg-with-type
                parts
                (be_state.compiler-backend-global-shared-view function)
                value
                ty
                "%rax"
                program-index)
              (be_state.compiler-backend-global-shared-view function)
              (cobj.CompilerObjectRelocationKind.RipAddress)
              (be_state.compiler-backend-global-shared-view symbol))
            (cobj.CompilerObjectX64Instr.StoreRip symbol))))]
    [(compiler_ir_types.CompilerIrInstr.Jump target)
      (let
        [symbol : String
          (be_operand.compiler-backend-asm-label label-scope target)]
        (compiler-backend-object-jump
          (compiler-backend-object-emit-phi-copies
            parts
            (be_state.compiler-backend-global-shared-view function)
            (compiler-backend-object-edge-phi-copies
              type-segment-bases
              blocks
              program-index
              target
              current-label)
            program-index)
          function
          symbol
          target
          (compiler-backend-object-next-label program-index)))]
    [(compiler_ir_types.CompilerIrInstr.Branch cond true-label false-label)
      (let
        [true-symbol : String
          (be_operand.compiler-backend-asm-label
            (be_state.compiler-backend-global-shared-view label-scope)
            true-label)]
        [false-symbol : String
          (be_operand.compiler-backend-asm-label
            (be_state.compiler-backend-global-shared-view label-scope)
            false-label)]
        [true-copies : be_state.CompilerBackendPhiCopySeq
          (compiler-backend-object-edge-phi-copies
            type-segment-bases
            (be_state.compiler-backend-global-shared-view blocks)
            program-index
            true-label
            current-label)]
        [false-copies : be_state.CompilerBackendPhiCopySeq
          (compiler-backend-object-edge-phi-copies
            type-segment-bases
            blocks
            program-index
            false-label
            current-label)]
        [next-label : i64 (compiler-backend-object-next-label program-index)]
        [true-is-next : bool
          (and
            (compiler_ir_types.compiler-ir-label-some? next-label)
            (= true-label next-label))]
        [false-is-next : bool
          (and
            (compiler_ir_types.compiler-ir-label-some? next-label)
            (= false-label next-label))]
        [flags-cc : i64
          (compiler-backend-object-branch-flags-cc
            (be_state.compiler-backend-global-shared-view cond)
            program-index)]
        [cc : i64
          (if (< flags-cc 0)
            5
            flags-cc)]
        (if (and
          (compiler-backend-object-phi-copy-list-nil? true-copies)
          (compiler-backend-object-phi-copy-list-nil? false-copies))
          (if (and (< flags-cc 0) (not true-is-next) (not false-is-next))
            (object_target.compiler-backend-object-add-text
              (object_target.compiler-backend-object-add-text-relocation
                (object_target.compiler-backend-object-add-text-relocation
                  (compiler-backend-object-load-value-to-reg
                    parts
                    (be_state.compiler-backend-global-shared-view function)
                    cond
                    "%rax"
                    program-index)
                  (be_state.compiler-backend-global-shared-view function)
                  (cobj.CompilerObjectRelocationKind.Branch)
                  (be_state.compiler-backend-global-shared-view true-symbol))
                (be_state.compiler-backend-global-shared-view function)
                (cobj.CompilerObjectRelocationKind.Branch)
                (be_state.compiler-backend-global-shared-view false-symbol))
              (cobj.CompilerObjectX64Instr.Branch true-symbol false-symbol))
            (let
              [tested : object_target.CompilerBackendObjectTargetParts
                (compiler-backend-object-branch-test
                  parts
                  (be_state.compiler-backend-global-shared-view function)
                  cond
                  flags-cc
                  program-index)]
              (if true-is-next
                (compiler-backend-object-jcc
                  tested
                  function
                  (bit-xor cc 1)
                  false-symbol)
                (compiler-backend-object-jump
                  (compiler-backend-object-jcc
                    tested
                    (be_state.compiler-backend-global-shared-view function)
                    cc
                    true-symbol)
                  function
                  false-symbol
                  false-label
                  next-label))))
          ;; The true edge's copies are emitted right after the branch, so the
          ;; branch jumps only for the false edge and falls into the true one.
          (let
            [true-edge : String
              (be_operand.compiler-backend-asm-label
                (be_state.compiler-backend-global-shared-view label-scope)
                (compiler_ir_types.compiler-ir-label
                  (str_cat.str-cat
                    (compiler_ir_types.compiler-ir-label-text current-label)
                    ".phit")))]
            [false-edge : String
              (be_operand.compiler-backend-asm-label
                label-scope
                (compiler_ir_types.compiler-ir-label
                  (str_cat.str-cat
                    (compiler_ir_types.compiler-ir-label-text current-label)
                    ".phif")))]
            [branched : object_target.CompilerBackendObjectTargetParts
              (compiler-backend-object-jcc
                (compiler-backend-object-branch-test
                  parts
                  (be_state.compiler-backend-global-shared-view function)
                  cond
                  flags-cc
                  program-index)
                (be_state.compiler-backend-global-shared-view function)
                (bit-xor cc 1)
                (be_state.compiler-backend-global-shared-view false-edge))]
            [true-copied : object_target.CompilerBackendObjectTargetParts
              (compiler-backend-object-emit-phi-copies
                (object_target.compiler-backend-object-add-text
                  (object_target.compiler-backend-object-symbol-local-section
                    branched
                    (be_state.compiler-backend-global-shared-view true-edge)
                    (cobj.CompilerObjectSectionKind.Text)
                    (cobj.CompilerObjectSymbolKind.Function))
                  (cobj.CompilerObjectX64Instr.Label true-edge))
                (be_state.compiler-backend-global-shared-view function)
                true-copies
                program-index)]
            [true-done : object_target.CompilerBackendObjectTargetParts
              (compiler-backend-object-jump
                true-copied
                (be_state.compiler-backend-global-shared-view function)
                true-symbol
                true-label
                -1)]
            (compiler-backend-object-jump
              (compiler-backend-object-emit-phi-copies
                (object_target.compiler-backend-object-add-text
                  (object_target.compiler-backend-object-symbol-local-section
                    true-done
                    (be_state.compiler-backend-global-shared-view false-edge)
                    (cobj.CompilerObjectSectionKind.Text)
                    (cobj.CompilerObjectSymbolKind.Function))
                  (cobj.CompilerObjectX64Instr.Label false-edge))
                (be_state.compiler-backend-global-shared-view function)
                false-copies
                program-index)
              function
              false-symbol
              false-label
              next-label))))]
    [(compiler_ir_types.CompilerIrInstr.TotalEnumBranch
        cond
        true-label
        false-label)
      (compiler-backend-object-instr
        type-segment-bases
        parts
        target
        function
        label-scope
        current-label
        blocks
        (compiler_ir_types.CompilerIrInstr.Branch cond true-label false-label)
        plan
        program-index)]
    [(compiler_ir_types.CompilerIrInstr.Return value)
      (compiler-backend-object-add-nonempty-bytes
        (match value
          [(compiler_ir_types.CompilerIrMaybeValue.No)
            (if (string.eq function "main")
              (compiler-backend-object-add-nonempty-bytes
                parts
                (compiler-backend-object-zero-eax-bytes))
              parts)]
          [(compiler_ir_types.CompilerIrMaybeValue.Some inner)
            (compiler-backend-object-load-value-to-reg
              parts
              function
              inner
              "%rax"
              program-index)])
        (compiler-backend-object-leave-ret-bytes))]
    ;; Edge copies are emitted by the Jump/Branch terminators that target this
    ;; block, so the phi itself emits nothing.
    [(compiler_ir_types.CompilerIrInstr.Phi _ _ _) parts]
    [(compiler_ir_types.CompilerIrInstr.Gep dst base offset elem-ty)
      (compiler-backend-object-gep-to-var
        type-segment-bases
        parts
        function
        dst
        base
        offset
        elem-ty
        program-index)]
    [(compiler_ir_types.CompilerIrInstr.Load dst src ty)
      (compiler-backend-object-load-ptr-to-var
        type-segment-bases
        parts
        function
        dst
        src
        ty
        program-index)]
    [(compiler_ir_types.CompilerIrInstr.StorePtr dst src ty)
      (compiler-backend-object-value-ref-with-type
        (compiler-backend-object-value-ref
          parts
          (be_state.compiler-backend-global-shared-view function)
          dst
          program-index)
        (be_state.compiler-backend-global-shared-view function)
        src
        ty
        program-index)]
    [(compiler_ir_types.CompilerIrInstr.StoreOwned dst src ty)
      (compiler-backend-object-value-ref-with-type
        (compiler-backend-object-value-ref
          parts
          (be_state.compiler-backend-global-shared-view function)
          dst
          program-index)
        (be_state.compiler-backend-global-shared-view function)
        src
        ty
        program-index)]
    [(compiler_ir_types.CompilerIrInstr.Cast dst src from-ty _)
      (compiler-backend-object-move-value-to-var
        parts
        function
        dst
        src
        from-ty
        program-index)]
    [(compiler_ir_types.CompilerIrInstr.Bitcast dst src from-ty _)
      (compiler-backend-object-move-value-to-var
        parts
        function
        dst
        src
        from-ty
        program-index)]
    [(compiler_ir_types.CompilerIrInstr.Splat _ _ _ elem-ty)
      (compiler-backend-object-uses-ref
        parts
        function
        instr
        (compiler_ast_types.AstMaybeType.Some elem-ty)
        program-index)]
    [(compiler_ir_types.CompilerIrInstr.VectorBinOp payload-box)
      (compiler-backend-object-uses-ref
        parts
        function
        instr
        (compiler_ast_types.AstMaybeType.Some
          (be_state.compiler-backend-box-field-shared-view payload-box ty))
        program-index)]
    [(compiler_ir_types.CompilerIrInstr.VectorPrefix payload-box)
      (compiler-backend-object-uses-ref
        parts
        function
        instr
        (compiler_ast_types.AstMaybeType.Some
          (be_state.compiler-backend-box-field-shared-view payload-box ty))
        program-index)]
    [(compiler_ir_types.CompilerIrInstr.VectorReduce _ _ _ _ elem-ty)
      (compiler-backend-object-uses-ref
        parts
        function
        instr
        (compiler_ast_types.AstMaybeType.Some elem-ty)
        program-index)]
    [(compiler_ir_types.CompilerIrInstr.VectorCompare payload-box)
      (compiler-backend-object-uses-ref
        parts
        function
        instr
        (compiler_ast_types.AstMaybeType.Some
          (be_state.compiler-backend-box-field-shared-view payload-box ty))
        program-index)]
    [(compiler_ir_types.CompilerIrInstr.Select payload-box)
      (let
        [dst (be_state.compiler-backend-box-field-shared-view payload-box dst)]
        [mask
          (be_state.compiler-backend-box-field-shared-view payload-box mask)]
        [on-true
          (be_state.compiler-backend-box-field-shared-view payload-box on-true)]
        [on-false
          (be_state.compiler-backend-box-field-shared-view payload-box on-false)]
        [lanes
          (be_state.compiler-backend-box-field-shared-view payload-box lanes)]
        [ty (be_state.compiler-backend-box-field-shared-view payload-box ty)]
        (if (= lanes 0)
          (compiler-backend-object-scalar-select
            parts
            (be_state.compiler-backend-global-shared-view function)
            dst
            mask
            on-true
            on-false
            program-index)
          (compiler-backend-object-value-ref-with-type
            (compiler-backend-object-value-ref-with-type
              (compiler-backend-object-value-ref
                parts
                (be_state.compiler-backend-global-shared-view function)
                mask
                program-index)
              (be_state.compiler-backend-global-shared-view function)
              on-true
              ty
              program-index)
            (be_state.compiler-backend-global-shared-view function)
            on-false
            ty
            program-index)))]
    [(compiler_ir_types.CompilerIrInstr.VectorStore payload-box)
      (let
        [base
          (be_state.compiler-backend-box-field-shared-view payload-box base)]
        [index
          (be_state.compiler-backend-box-field-shared-view payload-box index)]
        [value
          (be_state.compiler-backend-box-field-shared-view payload-box value)]
        [elem-ty
          (be_state.compiler-backend-box-field-shared-view payload-box ty)]
        (compiler-backend-object-value-ref-with-type
          (compiler-backend-object-value-ref
            (compiler-backend-object-value-ref
              parts
              (be_state.compiler-backend-global-shared-view function)
              base
              program-index)
            (be_state.compiler-backend-global-shared-view function)
            index
            program-index)
          (be_state.compiler-backend-global-shared-view function)
          value
          elem-ty
          program-index))]
    [(compiler_ir_types.CompilerIrInstr.PredicatedStore payload-box)
      (let
        [base
          (be_state.compiler-backend-box-field-shared-view payload-box base)]
        [index
          (be_state.compiler-backend-box-field-shared-view payload-box index)]
        [value
          (be_state.compiler-backend-box-field-shared-view payload-box value)]
        [mask
          (be_state.compiler-backend-box-field-shared-view payload-box mask)]
        [elem-ty
          (be_state.compiler-backend-box-field-shared-view payload-box ty)]
        (compiler-backend-object-value-ref
          (compiler-backend-object-value-ref-with-type
            (compiler-backend-object-value-ref
              (compiler-backend-object-value-ref
                parts
                (be_state.compiler-backend-global-shared-view function)
                base
                program-index)
              (be_state.compiler-backend-global-shared-view function)
              index
              program-index)
            (be_state.compiler-backend-global-shared-view function)
            value
            elem-ty
            program-index)
          (be_state.compiler-backend-global-shared-view function)
          mask
          program-index))]
    [(compiler_ir_types.CompilerIrInstr.VectorShuffle payload-box)
      (let
        [source
          (be_state.compiler-backend-box-field-shared-view payload-box source)]
        [selector-low
          (be_state.compiler-backend-box-field-shared-view
            payload-box
            selector-low)]
        [selector-high
          (be_state.compiler-backend-box-field-shared-view
            payload-box
            selector-high)]
        [active-lanes
          (be_state.compiler-backend-box-field-shared-view
            payload-box
            active-lanes)]
        [elem-ty
          (be_state.compiler-backend-box-field-shared-view payload-box ty)]
        [with-low : object_target.CompilerBackendObjectTargetParts
          (compiler-backend-object-value-ref
            (compiler-backend-object-value-ref-with-type
              parts
              (be_state.compiler-backend-global-shared-view function)
              source
              elem-ty
              program-index)
            (be_state.compiler-backend-global-shared-view function)
            selector-low
            program-index)]
        [with-high : object_target.CompilerBackendObjectTargetParts
          (match selector-high
            [(compiler_ir_types.CompilerIrMaybeValue.Some value)
              (compiler-backend-object-value-ref
                with-low
                (be_state.compiler-backend-global-shared-view function)
                value
                program-index)]
            [(compiler_ir_types.CompilerIrMaybeValue.No) with-low])]
        (compiler-backend-object-value-ref
          with-high
          function
          active-lanes
          program-index))]
    [(compiler_ir_types.CompilerIrInstr.Pack dst words _)
      (compiler-backend-object-pack-to-var
        parts
        function
        dst
        words
        program-index)]
    [(compiler_ir_types.CompilerIrInstr.Word dst src index _)
      (compiler-backend-object-word-to-var
        parts
        function
        dst
        src
        index
        program-index)]
    [(compiler_ir_types.CompilerIrInstr.AddrOf dst src _)
      (compiler-backend-object-addr-of-to-var parts dst src)]
    [(compiler_ir_types.CompilerIrInstr.Switch index base cases default-label)
      (compiler-backend-object-switch
        parts
        function
        label-scope
        current-label
        index
        base
        cases
        default-label
        (compiler_ir_types.compiler-ir-label-none)
        program-index)]
    [(compiler_ir_types.CompilerIrInstr.TotalEnumSwitch
        index
        base
        cases
        default-label
        trap-label)
      (compiler-backend-object-switch
        parts
        function
        label-scope
        current-label
        index
        base
        cases
        default-label
        trap-label
        program-index)]
    ;; A frame slot reservation has no code; the slot is addressed later.
    [(compiler_ir_types.CompilerIrInstr.Alloc _ _) parts]
    ;; `Syscall dst (number args...)` under the Linux x86-64 kernel ABI. The
    ;; arguments load first (loading scratches through %rax), then the number
    ;; into %rax; `syscall` returns in %rax and clobbers only %rcx and %r11,
    ;; which carry no value between object-encoded instructions (every var
    ;; lives in its frame slot). Stdlib runtime functions reach this encoder
    ;; without the semantic eligibility scan, so dropping the instruction here
    ;; would silently remove their kernel calls.
    [(compiler_ir_types.CompilerIrInstr.Syscall dst args)
      (if (and
        (match target
          [(be_state.CompilerBackendTarget.Linux) true]
          [_ false])
        (>=
          (be_facts.compiler-backend-call-args-count
            (be_state.compiler-backend-global-shared-view args))
          1)
        (<=
          (be_facts.compiler-backend-call-args-count
            (be_state.compiler-backend-global-shared-view args))
          7))
        (compiler-backend-object-store-reg-to-var
          (compiler-backend-object-add-nonempty-bytes
            (compiler-backend-object-load-value-to-reg
              (compiler-backend-object-syscall-arg-moves
                parts
                (be_state.compiler-backend-global-shared-view function)
                (be_state.compiler-backend-global-shared-view args)
                1
                program-index)
              (be_state.compiler-backend-global-shared-view function)
              (be_facts.compiler-backend-call-arg-at args 0)
              "%rax"
              program-index)
            (compiler-backend-object-syscall-bytes))
          dst
          "%rax")
        (compiler-backend-object-unencodable instr))]
    [(compiler_ir_types.CompilerIrInstr.CopyBytes dst src size)
      (compiler-backend-object-copy-bytes
        parts
        (be_state.compiler-backend-global-shared-view function)
        dst
        src
        size
        program-index)]
    ;; `index < length` unsigned, else the runtime's out-of-bounds abort:
    ;; `cmpq %rcx, %rax; jb ok; call tl_oob_abort; ok:` (the assembly route's
    ;; unlocated form). The length is loaded first: a global operand is read
    ;; through %rax.
    [(compiler_ir_types.CompilerIrInstr.BoundsCheck index length ok-label)
      (let
        [ok-symbol : String
          (be_operand.compiler-backend-asm-label
            (string.copy (& label-scope))
            ok-label)]
        [compared : object_target.CompilerBackendObjectTargetParts
          (compiler-backend-object-add-nonempty-bytes
            (compiler-backend-object-load-value-to-reg
              (compiler-backend-object-load-value-to-reg
                parts
                (string.copy (& function))
                length
                "%rcx"
                program-index)
              (string.copy (& function))
              index
              "%rax"
              program-index)
            (compiler-backend-object-cmp-rcx-rax-bytes))]
        [aborted : object_target.CompilerBackendObjectTargetParts
          (compiler-backend-object-direct-call
            (compiler-backend-object-jcc
              compared
              (string.copy (& function))
              2
              (string.copy (& ok-symbol)))
            target
            (compiler_regalloc.compiler-reg-direct-call-convention
              cbi.compiler-builtin-id-tl-oob-abort)
            (string.copy (& function))
            (be_operand.compiler-backend-call-symbol-index
              cbi.compiler-builtin-id-tl-oob-abort
              plan
              program-index)
            (compiler_ir_types.CompilerIrCallArgs.Nil)
            program-index)]
        (object_target.compiler-backend-object-add-text
          (object_target.compiler-backend-object-symbol-local-section
            aborted
            (string.copy (& ok-symbol))
            (cobj.CompilerObjectSectionKind.Text)
            (cobj.CompilerObjectSymbolKind.Function))
          (cobj.CompilerObjectX64Instr.Label ok-symbol)))]
    ;; Every other instruction must be excluded by object eligibility. Emitting
    ;; only its symbol references would silently drop its effect.
    [_ (compiler-backend-object-unencodable instr)]))

(define (compiler-backend-object-unencodable
  [instr : compiler_ir_types.CompilerIrInstr]) : never
  (abort.compiler-abort
    (match instr
      [(compiler_ir_types.CompilerIrInstr.BoundsCheck _ _ _)
        "tl: compiler_backend.compiler-backend-object-instr: BoundsCheck has no direct object encoding\n"]
      [(compiler_ir_types.CompilerIrInstr.CallIndirect _ _ _ _)
        "tl: compiler_backend.compiler-backend-object-instr: CallIndirect has no direct object encoding\n"]
      [(compiler_ir_types.CompilerIrInstr.Syscall _ _)
        "tl: compiler_backend.compiler-backend-object-instr: Syscall has no direct object encoding\n"]
      [_
        "tl: compiler_backend.compiler-backend-object-instr: instruction has no direct object encoding\n"])))

;; `CopyBytes dst src size`: both operands are addresses. An aggregate global's
;; `Global` value is its aggregate address (the inline home, or the box a
;; one-word cell holds), the same as the text backend. The chunk encoding uses
;; signed 8-bit displacements, so only 8-byte multiples up to 128 bytes are
;; encoded; anything else is an invariant failure, never a partial copy.
(define (compiler-backend-object-copy-bytes
  [parts : object_target.CompilerBackendObjectTargetParts]
  [function : String]
  [dst : compiler_ir_types.CompilerIrValue]
  [src : compiler_ir_types.CompilerIrValue]
  [size : i64]
  [program-index : be_state.CompilerBackendProgramIndex]) : object_target.CompilerBackendObjectTargetParts
  (if (or (<= size 0) (> size 128) (not (= (% size 8) 0)))
    (abort.compiler-abort
      "tl: compiler_backend.compiler-backend-object-copy-bytes: copy size has no direct object encoding\n")
    (let
      ;; Destination first: loading a global materializes through %rax.
      [with-dst : object_target.CompilerBackendObjectTargetParts
        (compiler-backend-object-load-value-to-reg
          parts
          (be_state.compiler-backend-global-shared-view function)
          dst
          "%r11"
          program-index)]
      [with-src : object_target.CompilerBackendObjectTargetParts
        (compiler-backend-object-load-value-to-reg
          with-dst
          function
          src
          "%rax"
          program-index)]
      (compiler-backend-object-add-nonempty-bytes
        with-src
        (compiler-backend-object-inline-aggregate-copy-bytes size)))))

(define (compiler-backend-object-instr-seq
  [type-segment-bases : i64]
  [parts : object_target.CompilerBackendObjectTargetParts]
  [target : be_state.CompilerBackendTarget]
  [function : String]
  [label-scope : String]
  [current-label : i64]
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [instrs : (& compiler_ir_types.CompilerIrInstrSeq)]
  [plan : be_state.CompilerBackendRuntimePlan]
  [program-index : be_state.CompilerBackendProgramIndex]
  [index : i64]) : object_target.CompilerBackendObjectTargetParts
  (if (>= index (compiler_ir_types.compiler-ir-instr-seq-count instrs))
    parts
    (compiler-backend-object-instr-seq
      type-segment-bases
      (begin
        (compiler-backend-object-note-flags! program-index (& instrs) index)
        (compiler-backend-object-instr
          type-segment-bases
          parts
          target
          (be_state.compiler-backend-global-shared-view function)
          (be_state.compiler-backend-global-shared-view label-scope)
          current-label
          (be_state.compiler-backend-global-shared-view blocks)
          (compiler_ir_types.compiler-ir-instr-seq-ref instrs index)
          plan
          program-index))
      target
      function
      label-scope
      current-label
      blocks
      instrs
      plan
      program-index
      (+ index 1))))

(define (compiler-backend-object-blocks
  [type-segment-bases : i64]
  [parts : object_target.CompilerBackendObjectTargetParts]
  [target : be_state.CompilerBackendTarget]
  [function-symbol : String]
  [label-scope : String]
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [plan : be_state.CompilerBackendRuntimePlan]
  [program-index : be_state.CompilerBackendProgramIndex]) : object_target.CompilerBackendObjectTargetParts
  (match blocks
    [(Array seq)
      (compiler-backend-object-block-seq
        type-segment-bases
        parts
        target
        function-symbol
        label-scope
        seq
        plan
        program-index
        0)]))

(define (compiler-backend-object-block-seq
  [type-segment-bases : i64]
  [parts : object_target.CompilerBackendObjectTargetParts]
  [target : be_state.CompilerBackendTarget]
  [function-symbol : String]
  [label-scope : String]
  [blocks : compiler_ir_types.CompilerIrBlockSeq]
  [plan : be_state.CompilerBackendRuntimePlan]
  [program-index : be_state.CompilerBackendProgramIndex]
  [index : i64]) : object_target.CompilerBackendObjectTargetParts
  (if (>= index (compiler_ir_types.compiler-ir-block-seq-count blocks))
    parts
    (match (compiler_ir_types.compiler-ir-block-seq-ref blocks index)
      [(Block label instrs)
        (let
          [block-label : String
            (be_operand.compiler-backend-asm-label
              (be_state.compiler-backend-global-shared-view label-scope)
              label)]
          [_next-label : unit
            (compiler-backend-object-set-next-label!
              program-index
              (if (<
                (+ index 1)
                (compiler_ir_types.compiler-ir-block-seq-count blocks))
                (match (compiler_ir_types.compiler-ir-block-seq-borrow
                  blocks
                  (+ index 1))
                  [(Block next _) next])
                -1))]
          (compiler-backend-object-block-seq
            type-segment-bases
            (compiler-backend-object-instr-seq
              type-segment-bases
              (object_target.compiler-backend-object-add-text
                (object_target.compiler-backend-object-symbol-local-section
                  parts
                  (be_state.compiler-backend-global-shared-view block-label)
                  (Text)
                  (Function))
                (Label block-label))
              target
              (be_state.compiler-backend-global-shared-view function-symbol)
              (be_state.compiler-backend-global-shared-view label-scope)
              label
              (Array (be_state.compiler-backend-global-shared-view blocks))
              instrs
              plan
              program-index
              0)
            target
            function-symbol
            label-scope
            blocks
            plan
            program-index
            (+ index 1)))])))

(define (compiler-backend-object-emit-function
  [type-segment-bases : i64]
  [parts : object_target.CompilerBackendObjectTargetParts]
  [target : be_state.CompilerBackendTarget]
  [func : compiler_ir_types.CompilerIrFunction]
  [plan : be_state.CompilerBackendRuntimePlan]
  [program-index : be_state.CompilerBackendProgramIndex]) : object_target.CompilerBackendObjectTargetParts
  (match func
    [(Function name params ret-ty vars blocks function-abi)
      (let
        [symbol : String
          (be_operand.compiler-backend-function-symbol-index program-index name)]
        [label-scope : String
          (be_facts.compiler-backend-function-label-scope program-index name)]
        [types : compiler_regalloc.CompilerRegVarTypes
          (compiler_regalloc.compiler-reg-function-var-types-with-metrics
            (&
              (Function
                name
                (be_state.compiler-backend-global-shared-view params)
                (be_state.compiler-backend-global-shared-view ret-ty)
                vars
                (be_state.compiler-backend-global-shared-view blocks)
                (be_state.compiler-backend-global-shared-view function-abi)))
            (be_state.compiler-backend-state-metrics
              program-index.backend-state))]
        [groups : compiler_liveness.CompilerLiveI64Set
          (compiler_regalloc.compiler-reg-function-group-vars
            type-segment-bases
            (&
              (Function
                name
                (be_state.compiler-backend-global-shared-view params)
                ret-ty
                vars
                (be_state.compiler-backend-global-shared-view blocks)
                function-abi))
            types)]
        [_group-enable : unit
          (begin
            (be_facts.compiler-backend-current-slot-vars-set!
              program-index.backend-state
              vars)
            (be_facts.compiler-backend-group-vars-enable!
              program-index.backend-state
              (be_state.compiler-backend-global-shared-view groups)
              (compiler_liveness.compiler-live-set-empty)))]
        [emitted : object_target.CompilerBackendObjectTargetParts
          (compiler-backend-object-blocks
            type-segment-bases
            (compiler-backend-object-param-spills
              (compiler-backend-object-add-nonempty-bytes
                (object_target.compiler-backend-object-add-text
                  (object_target.compiler-backend-object-symbol-export-section
                    parts
                    (be_state.compiler-backend-global-shared-view symbol)
                    (Text)
                    (Function))
                  (Label (be_state.compiler-backend-global-shared-view symbol)))
                (compiler-backend-object-prologue-bytes
                  target
                  (be_facts.compiler-backend-frame-size
                    (if (> (compiler_liveness.compiler-live-set-count groups) 0)
                      (* vars 2)
                      vars))))
              target
              (& params)
              0)
            target
            symbol
            label-scope
            blocks
            plan
            program-index)]
        [_group-disable : unit
          (be_facts.compiler-backend-group-vars-disable!
            program-index.backend-state)]
        (compiler-backend-object-c-export-entry
          type-segment-bases
          emitted
          target
          program-index
          name
          (& params)))]))

(define (compiler-backend-object-functions
  [type-segment-bases : i64]
  [parts : object_target.CompilerBackendObjectTargetParts]
  [target : be_state.CompilerBackendTarget]
  [functions : (& compiler_ir_types.CompilerIrFunctionSeq)]
  [plan : be_state.CompilerBackendRuntimePlan]
  [program-index : be_state.CompilerBackendProgramIndex]) : object_target.CompilerBackendObjectTargetParts
  (let
    [closed : bool
      (be_state.compiler-backend-state-closed-executable?
        program-index.backend-state)]
    [out : object_target.CompilerBackendObjectTargetParts
      (if (be_facts.compiler-backend-c-entry-shared-needed?
        type-segment-bases
        target
        program-index
        functions)
        (compiler-backend-object-c-entry-shared parts)
        parts)]
    (for [index (iterator.range 0 functions.len)]
      (let
        [func (owned_view.compiler-owned-element-view functions.slots index)]
        (match (& func)
          [(Function name _ _ _ _ _)
            (unless
              (and
                closed
                (be_scalar.compiler-backend-optional-runtime-function?
                  program-index.backend-state
                  name))
              (set!
                out
                (compiler-backend-object-emit-function
                  type-segment-bases
                  out
                  target
                  func
                  plan
                  program-index)))])))
    out))

;; The structured route can read the object relocation inventory directly.
;; Emit a private prelude body only when a live relocation names its entry.
;; Appending one body may add a relocation to another prelude entry.
(define (compiler-backend-object-referenced-prelude
  [type-segment-bases : i64]
  [parts : object_target.CompilerBackendObjectTargetParts]
  [target : be_state.CompilerBackendTarget]
  [functions : (& compiler_ir_types.CompilerIrFunctionSeq)]
  [plan : be_state.CompilerBackendRuntimePlan]
  [program-index : be_state.CompilerBackendProgramIndex]) : object_target.CompilerBackendObjectTargetParts
  (unless
    (be_state.compiler-backend-state-closed-executable?
      program-index.backend-state)
    (return parts))
  (let
    [out : object_target.CompilerBackendObjectTargetParts parts]
    [changed : bool true]
    (while changed
      (set! changed false)
      (for [index (iterator.range 0 functions.len)]
        (let
          [func (owned_view.compiler-owned-element-view functions.slots index)]
          (match (& func)
            [(Function name _ _ _ _ _)
              (let
                [source-name : String
                  (be_state.compiler-backend-symbol-text-index
                    program-index
                    name)]
                (when
                  (be_scalar.compiler-backend-optional-runtime-function?
                    program-index.backend-state
                    name)
                  (let
                    [body : String
                      (be_operand.compiler-backend-function-symbol-index
                        program-index
                        name)]
                    [export : String
                      (be_operand.compiler-backend-index-extern-link-symbol
                        program-index
                        name)]
                    (when
                      (and
                        (not
                          (cobj.compiler-object-symbol-builder-contains?
                            (& out.symbols)
                            (& body)
                            (Export)
                            (Function)))
                        (or
                          (cobj.compiler-object-relocation-builder-targets?
                            (& out.relocations)
                            (& body))
                          (cobj.compiler-object-relocation-builder-targets?
                            (& out.relocations)
                            (& export))
                          (cobj.compiler-object-relocation-builder-targets?
                            (& out.relocations)
                            (&
                              (be_facts.compiler-backend-closure-entry-label
                                source-name)))))
                      (set! changed true)
                      (set!
                        out
                        (compiler-backend-object-emit-function
                          type-segment-bases
                          out
                          target
                          func
                          plan
                          program-index))))))]))))
    out))

(define (compiler-backend-object-c-entry-prefix-bytes [frame : i64]) : String
  (let
    [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    (compiler-backend-object-push-u8! (&mut out) 0x56)
    (compiler-backend-object-push-u8! (&mut out) 0x57)
    (when
      (< frame 4096)
      (compiler-backend-object-push-sub-rsp! (&mut out) frame))
    (compiler-backend-object-bytes-finish (& out))))

(define (compiler-backend-object-c-entry-register-bytes
  [position : i64]
  [float? : bool]) : String
  (let
    [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    ;; Bit copies preserve f32/f64 payloads; upper SSE lanes are unspecified.
    (if float?
      (begin
        (compiler-backend-object-push-u8! (&mut out) 0x66)
        (compiler-backend-object-push-u8! (&mut out) 0x48)
        (compiler-backend-object-push-u8! (&mut out) 0x0f)
        (compiler-backend-object-push-u8! (&mut out) 0x6e)
        (compiler-backend-object-push-u8! (&mut out) (+ 0xc0 (* 8 position))))
      (begin
        (compiler-backend-object-push-u8! (&mut out) 0x48)
        (compiler-backend-object-push-u8! (&mut out) 0x89)
        (compiler-backend-object-push-u8! (&mut out) (+ 0xc6 (- position 4)))))
    (compiler-backend-object-bytes-finish (& out))))

(define (compiler-backend-object-c-entry-return-bytes) : String
  (object_target.compiler-backend-object-bytes-from-hex "5f5ec3"))

(define (compiler-backend-object-c-entry-shared
  [parts : object_target.CompilerBackendObjectTargetParts]) : object_target.CompilerBackendObjectTargetParts
  (let
    [entry : String "__tl$c_entry"]
    [end : String "__tl$c_entry$end"]
    [out : object_target.CompilerBackendObjectTargetParts
      (compiler-backend-object-add-nonempty-bytes
        (compiler-backend-object-add-nonempty-bytes
          (compiler-backend-object-add-nonempty-bytes
            (compiler-backend-object-add-nonempty-bytes
              (object_target.compiler-backend-object-add-text
                (object_target.compiler-backend-object-symbol-local-section
                  parts
                  (string.copy (& entry))
                  (Text)
                  (Function))
                (Label (string.copy (& entry))))
              (compiler-backend-object-c-entry-prefix-bytes 40))
            (compiler-backend-object-call-r11-bytes))
          (compiler-backend-object-add-rsp-bytes 40))
        (compiler-backend-object-c-entry-return-bytes))]
    (object_windows.compiler-backend-object-add-unwind
      (object_target.compiler-backend-object-add-text
        (object_target.compiler-backend-object-symbol-local-section
          out
          (string.copy (& end))
          (Text)
          (Function))
        (Label (string.copy (& end))))
      entry
      end
      (object_windows.compiler-backend-object-entry-range-unwind-bytes
        40
        6
        true))))

(define (compiler-backend-object-c-export-entry
  [type-segment-bases : i64]
  [parts : object_target.CompilerBackendObjectTargetParts]
  [target : be_state.CompilerBackendTarget]
  [index : be_state.CompilerBackendProgramIndex]
  [name : i64]
  [params : (& params compiler_ir_types.CompilerIrParamSeq)]) : object_target.CompilerBackendObjectTargetParts
  (if (not
    (and
      (compiler_abi.compiler-abi-platform-entry-bridge?
        (be_state.compiler-backend-target-abi target))
      (be_operand.compiler-backend-index-c-export? index name)))
    parts
    (let
      [entry : String
        (be_operand.compiler-backend-index-extern-link-symbol index name)]
      [end : String (str_cat.str-cat entry "$end")]
      [body : String
        (be_operand.compiler-backend-function-symbol-index index name)]
      [plan : be_facts.CompilerBackendCEntryPlan
        (be_facts.compiler-backend-c-entry-plan type-segment-bases index params)]
      [prefix : String
        (if (<= plan.len 4)
          ""
          (compiler-backend-object-c-entry-prefix-bytes plan.frame))]
      [prologue-size : i64
        (if (>= plan.frame 4096)
          15
          (string.string-length prefix))]
      [out : object_target.CompilerBackendObjectTargetParts
        (compiler-backend-object-add-nonempty-bytes
          (object_target.compiler-backend-object-add-text
            (object_target.compiler-backend-object-symbol-export-section
              parts
              (string.copy (& entry))
              (Text)
              (Function))
            (Label (string.copy (& entry))))
          prefix)]
      (when
        (<= plan.len 4)
        (return
          (object_target.compiler-backend-object-add-rip-instr
            (object_target.compiler-backend-object-add-rip-instr
              out
              (string.copy (& entry))
              (RipAddress)
              (string.copy (& body))
              (LoadRipAddressR11 body))
            entry
            (Branch)
            "__tl$c_entry"
            (Jump "__tl$c_entry"))))
      (when
        (>= plan.frame 4096)
        (set!
          out
          (object_target.compiler-backend-object-add-call-instr
            (compiler-backend-object-add-machine
              out
              (mx.MachineInstr.MovRI
                (W32)
                compiler_abi.compiler-reg-id-rax
                plan.frame))
            (string.copy (& entry))
            "__chkstk"))
        (set!
          out
          (compiler-backend-object-add-nonempty-bytes
            out
            (object_target.compiler-backend-object-bytes-from-hex "4829c4"))))
      (for [position (iterator.range 4 plan.len)]
        (set!
          out
          (compiler-backend-object-add-nonempty-bytes
            out
            (compiler-backend-object-load-rax-rsp-bytes
              (be_facts.compiler-backend-c-entry-incoming-offset
                (& plan)
                position))))
        (set!
          out
          (compiler-backend-object-add-nonempty-bytes
            out
            (if (< position 6)
              (compiler-backend-object-c-entry-register-bytes
                position
                (array-ref plan.float-words position))
              (compiler-backend-object-store-rax-rsp-bytes
                (+ 32 (* 8 (- position 6))))))))
      (set!
        out
        (compiler-backend-object-add-nonempty-bytes
          (compiler-backend-object-add-nonempty-bytes
            (object_target.compiler-backend-object-add-call-instr
              out
              (string.copy (& entry))
              body)
            (compiler-backend-object-add-rsp-bytes plan.frame))
          (compiler-backend-object-c-entry-return-bytes)))
      (object_windows.compiler-backend-object-add-unwind
        (object_target.compiler-backend-object-add-text
          (object_target.compiler-backend-object-symbol-local-section
            out
            (string.copy (& end))
            (Text)
            (Function))
          (Label (string.copy (& end))))
        entry
        end
        (object_windows.compiler-backend-object-entry-range-unwind-bytes
          plan.frame
          prologue-size
          true)))))

(define (compiler-backend-object-global-value
  [parts : object_target.CompilerBackendObjectTargetParts]
  [site : String]
  [ty : (& compiler_ast_types.AstType)]
  [value : (& compiler_ir_types.CompilerIrValue)]
  [program-index : be_state.CompilerBackendProgramIndex]) : object_target.CompilerBackendObjectTargetParts
  (match value
    [(I64 n) (object_target.compiler-backend-object-add-data parts (I64 n))]
    [(Bool b)
      (object_target.compiler-backend-object-add-data
        parts
        (I64
          (if b
            1
            0)))]
    [(Char c)
      (object_target.compiler-backend-object-add-data
        parts
        (I64 (be_state.compiler-backend-char-code c)))]
    [(Unit) (object_target.compiler-backend-object-add-data parts (I64 0))]
    [(F64 bits)
      (object_target.compiler-backend-object-add-data
        parts
        (be_data.compiler-backend-float-object-data ty bits))]
    [(String text)
      (let
        [symbol : String (be_operand.compiler-backend-string-fat-label text)]
        (object_target.compiler-backend-object-add-data
          (object_target.compiler-backend-object-add-data-relocation
            parts
            site
            (Abs64)
            (be_state.compiler-backend-global-shared-view symbol))
          (SymbolAddress symbol)))]
    [(Bytes text)
      (let
        [symbol : String (be_operand.compiler-backend-bytes-fat-label text)]
        (object_target.compiler-backend-object-add-data
          (object_target.compiler-backend-object-add-data-relocation
            parts
            site
            (Abs64)
            (be_state.compiler-backend-global-shared-view symbol))
          (SymbolAddress symbol)))]
    [(or (Global name) (GlobalAddr name))
      (let
        [symbol : String
          (be_facts.compiler-backend-function-or-global-addr-symbol
            program-index
            name)]
        (object_target.compiler-backend-object-add-data
          (object_target.compiler-backend-object-add-data-relocation
            parts
            site
            (Abs64)
            (be_state.compiler-backend-global-shared-view symbol))
          (SymbolAddress symbol)))]
    [(Function name)
      (let
        [symbol : String
          (be_operand.compiler-backend-closure-descriptor-label
            (be_state.compiler-backend-symbol-text-index program-index name))]
        (object_target.compiler-backend-object-add-data
          (object_target.compiler-backend-object-add-data-relocation
            parts
            site
            (Abs64)
            (be_state.compiler-backend-global-shared-view symbol))
          (SymbolAddress symbol)))]
    [_ parts]))

(define (compiler-backend-object-globals-from
  [parts : object_target.CompilerBackendObjectTargetParts]
  [target : be_state.CompilerBackendTarget]
  [globals : (& compiler_ir_types.CompilerIrGlobalSeq)]
  [program-index : be_state.CompilerBackendProgramIndex]
  [index : i64]) : object_target.CompilerBackendObjectTargetParts
  (if (>= index globals.len)
    parts
    (match (compiler_ir_types.compiler-ir-global-seq-borrow globals index)
      [(Global name ty value)
        (let
          [symbol : String
            (be_state.compiler-backend-state-user-symbol-id
              program-index.backend-state
              name)]
          (compiler-backend-object-globals-from
            (if (be_data.compiler-backend-runtime-global? ty value)
              (object_target.compiler-backend-object-add-bss
                (object_target.compiler-backend-object-add-bss
                  (object_target.compiler-backend-object-symbol-export-section
                    parts
                    (be_state.compiler-backend-global-shared-view symbol)
                    (Bss)
                    (Data))
                  (Label symbol))
                ;; IAG-1: an inline aggregate global reserves the aggregate.
                (Zero
                  (let
                    [inline-size : i64
                      (be_state.compiler-backend-inline-aggregate-global-size
                        program-index.backend-state
                        name)]
                    (if (> inline-size 0)
                      inline-size
                      8))))
              (compiler-backend-object-global-value
                (object_target.compiler-backend-object-add-data
                  (if (be_state.compiler-backend-state-private-global?
                    program-index.backend-state
                    name)
                    (object_target.compiler-backend-object-symbol-local-section
                      parts
                      (string.copy (& symbol))
                      (Data)
                      (Data))
                    (object_target.compiler-backend-object-symbol-export-section
                      parts
                      (be_state.compiler-backend-global-shared-view symbol)
                      (Data)
                      (Data)))
                  (Label (be_state.compiler-backend-global-shared-view symbol)))
                symbol
                ty
                value
                program-index))
            target
            globals
            program-index
            (+ index 1)))])))

(define (compiler-backend-object-globals
  [parts : object_target.CompilerBackendObjectTargetParts]
  [target : be_state.CompilerBackendTarget]
  [globals : compiler_ir_types.CompilerIrGlobalSeq]
  [program-index : be_state.CompilerBackendProgramIndex]) : object_target.CompilerBackendObjectTargetParts
  (compiler-backend-object-globals-from parts target globals program-index 0))

;; Object data outlives lower IR, which can own these literal headers/bytes.
;; Copy payloads into the object destination before the lower owner retires.
(define (compiler-backend-object-strings
  [parts : object_target.CompilerBackendObjectTargetParts]
  [strings : be_state.BackendStringSeq]
  [index : i64]) : object_target.CompilerBackendObjectTargetParts
  (if (>= index strings.len)
    parts
    (let
      [records : cobj.CompilerObjectDataRecordList
        (be_data.compiler-backend-literal-records strings index)]
      [out : object_target.CompilerBackendObjectTargetParts parts]
      [site : String ""]
      [i : i64 0]
      (while (< i records.len)
        (let
          [record : cobj.CompilerObjectDataRecord
            (be_state.compiler-backend-global-array-element-shared-view
              records.slots
              i)]
          (match (& record)
            [(Label name)
              (set! site (string.copy (& name)))
              (set!
                out
                (object_target.compiler-backend-object-symbol-local-section
                  out
                  (string.copy (& name))
                  (Rodata)
                  (Data)))]
            [(SymbolAddress target)
              (set!
                out
                (object_target.compiler-backend-object-add-rodata-relocation
                  out
                  (be_state.compiler-backend-global-shared-view site)
                  (Abs64)
                  (string.copy (& target))))]
            [_ unit])
          (set!
            out
            (object_target.compiler-backend-object-add-rodata
              out
              (be_state.compiler-backend-global-shared-view record))))
        (+= i 1))
      out)))

(define (compiler-backend-object-bytes
  [parts : object_target.CompilerBackendObjectTargetParts]
  [items : be_state.BackendStringSeq]
  [index : i64]) : object_target.CompilerBackendObjectTargetParts
  (if (>= index items.len)
    parts
    (let
      [bytes : String
        (be_state.compiler-backend-global-array-element-shared-view
          items.slots
          index)]
      [data-symbol : String (be_facts.compiler-backend-bytes-data-label bytes)]
      [fat-symbol : String (be_operand.compiler-backend-bytes-fat-label bytes)]
      (compiler-backend-object-bytes
        (object_target.compiler-backend-object-add-data
          (object_target.compiler-backend-object-add-data
            (object_target.compiler-backend-object-add-data
              (object_target.compiler-backend-object-add-data
                (object_target.compiler-backend-object-add-data-relocation
                  (object_target.compiler-backend-object-add-data
                    (object_target.compiler-backend-object-add-data
                      (object_target.compiler-backend-object-add-data
                        (object_target.compiler-backend-object-symbol-local-section
                          (object_target.compiler-backend-object-symbol-local-section
                            parts
                            (be_state.compiler-backend-global-shared-view
                              data-symbol)
                            (Data)
                            (Data))
                          (be_state.compiler-backend-global-shared-view
                            fat-symbol)
                          (Data)
                          (Data))
                        (Align 8))
                      (Label
                        (be_state.compiler-backend-global-shared-view
                          data-symbol)))
                    (if (= (string.string-length bytes) 0)
                      (Zero 1)
                      (Bytes (string.copy (& bytes)))))
                  (be_state.compiler-backend-global-shared-view fat-symbol)
                  (Abs64)
                  (be_state.compiler-backend-global-shared-view data-symbol))
                (Align 8))
              (Label fat-symbol))
            (SymbolAddress data-symbol))
          (I64 (string.string-length bytes)))
        items
        (+ index 1)))))

(define (compiler-backend-object-float
  [parts : object_target.CompilerBackendObjectTargetParts]
  [entry : be_state.BackendFloatEntry]) : object_target.CompilerBackendObjectTargetParts
  (let
    [ty : compiler_ast_types.AstType entry.ty]
    [bits : u64 entry.bits]
    [symbol : String (be_operand.compiler-backend-float-label ty bits)]
    (object_target.compiler-backend-object-add-rodata
      (object_target.compiler-backend-object-add-rodata
        (object_target.compiler-backend-object-add-rodata
          (object_target.compiler-backend-object-symbol-local-section
            parts
            (be_state.compiler-backend-global-shared-view symbol)
            (Rodata)
            (Data))
          (Align
            (if (be_state.compiler-backend-f64-type? ty)
              8
              4)))
        (Label symbol))
      (be_data.compiler-backend-float-object-data ty bits))))

(define (compiler-backend-object-floats
  [parts : object_target.CompilerBackendObjectTargetParts]
  [floats : be_state.BackendFloatSeq]) : object_target.CompilerBackendObjectTargetParts
  (let
    [slots : (__tl_dyn-array be_state.BackendFloatEntry) floats.slots]
    [count : i64 floats.len]
    [out : object_target.CompilerBackendObjectTargetParts parts]
    (for [index (iterator.range 0 count)]
      (set!
        out
        (compiler-backend-object-float
          out
          (be_state.compiler-backend-global-array-element-shared-view
            slots
            index))))
    out))

(define (compiler-backend-object-sign-bit
  [parts : object_target.CompilerBackendObjectTargetParts]
  [enabled : bool]
  [f64? : bool]) : object_target.CompilerBackendObjectTargetParts
  (if enabled
    (let
      [symbol : String
        (if f64?
          (be_facts.compiler-backend-f64-sign-bit-label)
          (be_facts.compiler-backend-f32-sign-bit-label))]
      (object_target.compiler-backend-object-add-rodata
        (object_target.compiler-backend-object-add-rodata
          (object_target.compiler-backend-object-add-rodata
            (object_target.compiler-backend-object-add-rodata
              (object_target.compiler-backend-object-symbol-local-section
                parts
                (be_state.compiler-backend-global-shared-view symbol)
                (Rodata)
                (Data))
              (Align 16))
            (Label symbol))
          (I64
            (if f64?
              -9223372036854775808
              2147483648)))
        (I64 0)))
    parts))

(define (compiler-backend-object-closure-descriptors
  [parts : object_target.CompilerBackendObjectTargetParts]
  [names : (& names be_state.BackendSymbolSeq)]
  [index : i64]
  [program-index : be_state.CompilerBackendProgramIndex]) : object_target.CompilerBackendObjectTargetParts
  (if (>= index names.len)
    parts
    (let
      [name : i64 (array-ref names.slots index)]
      [name-text : String
        (be_state.compiler-backend-symbol-text-index program-index name)]
      [descriptor : String
        (be_operand.compiler-backend-closure-descriptor-label
          (be_state.compiler-backend-global-shared-view name-text))]
      [entry : String (be_facts.compiler-backend-closure-entry-label name-text)]
      (compiler-backend-object-closure-descriptors
        (match (be_facts.compiler-backend-index-signature program-index name)
          [(Some _ _)
            (object_target.compiler-backend-object-add-rodata
              (object_target.compiler-backend-object-add-rodata
                (object_target.compiler-backend-object-add-rodata-relocation
                  (object_target.compiler-backend-object-add-rodata
                    (object_target.compiler-backend-object-add-rodata
                      (object_target.compiler-backend-object-symbol-local-section
                        (object_target.compiler-backend-object-symbol-local-section
                          parts
                          (be_state.compiler-backend-global-shared-view
                            descriptor)
                          (Rodata)
                          (Data))
                        (be_state.compiler-backend-global-shared-view entry)
                        (Text)
                        (Function))
                      (Align 8))
                    (Label
                      (be_state.compiler-backend-global-shared-view descriptor)))
                  descriptor
                  (Abs64)
                  (be_state.compiler-backend-global-shared-view entry))
                (SymbolAddress entry))
              (I64 0))]
          [(No) parts])
        names
        (+ index 1)
        program-index))))

(define (compiler-backend-object-externs
  [parts : object_target.CompilerBackendObjectTargetParts]
  [externs : compiler_ir_types.CompilerIrExternSeq]
  [plan : be_state.CompilerBackendRuntimePlan]
  [runtime-index : be_state.CompilerBackendRuntimeIndex]
  [referenced-functions : be_state.BackendSymbolSeq]
  [program-index : be_state.CompilerBackendProgramIndex]) : object_target.CompilerBackendObjectTargetParts
  (compiler-backend-object-extern-seq
    parts
    externs
    plan
    runtime-index
    referenced-functions
    program-index
    0))

(define (compiler-backend-object-extern-seq
  [parts : object_target.CompilerBackendObjectTargetParts]
  [externs : (& externs compiler_ir_types.CompilerIrExternSeq)]
  [plan : be_state.CompilerBackendRuntimePlan]
  [runtime-index : be_state.CompilerBackendRuntimeIndex]
  [referenced-functions : be_state.BackendSymbolSeq]
  [program-index : be_state.CompilerBackendProgramIndex]
  [seq-index : i64]) : object_target.CompilerBackendObjectTargetParts
  (if (>= seq-index (compiler_ir_types.compiler-ir-extern-seq-count externs))
    parts
    (match (compiler_ir_types.compiler-ir-extern-seq-borrow externs seq-index)
      [(Extern name-id source-name-id _ ty abi link-symbol-id _ provided _)
        (let
          [link-symbol : String
            (be_operand.compiler-backend-link-symbol-id
              link-symbol-id
              plan
              program-index.backend-state
              (compiler_ast_types.ast-extern-abi-c? abi))]
          [relocations : cobj.CompilerObjectRelocationBuilder
            (be_state.compiler-backend-global-shared-view parts.relocations)]
          [has-relocation : bool
            (be_state.backend-or4
              (cobj.compiler-object-relocation-builder-targets?
                relocations
                link-symbol)
              (let
                [target
                  (be_state.compiler-backend-state-user-symbol-id
                    program-index.backend-state
                    name-id)]
                (cobj.compiler-object-relocation-builder-targets?
                  relocations
                  target))
              (let
                [target
                  (be_state.compiler-backend-state-user-symbol-id
                    program-index.backend-state
                    source-name-id)]
                (cobj.compiler-object-relocation-builder-targets?
                  relocations
                  target))
              false)]
          (compiler-backend-object-extern-seq
            (if (and
              (not
                (compiler-backend-object-runtime-symbol-provided-id?
                  plan
                  program-index.backend-state
                  link-symbol-id))
              (be_facts.compiler-backend-emits-extern-symbol?
                program-index.backend-state
                name-id
                link-symbol-id
                provided
                plan)
              ;; A provided entry already owns this symbol definition. An
              ;; address alias must not add a second undefined COFF/ELF row.
              (not
                (cobj.compiler-object-symbol-builder-contains?
                  (& parts.symbols)
                  (string.copy (& link-symbol))
                  (Export)
                  (Function)))
              ;; Object relocations are the exact reference inventory.
              has-relocation)
              (object_target.compiler-backend-object-symbol-extern
                parts
                link-symbol
                (match ty
                  [(Func _ _) (Function)]
                  [_ (Data)]))
              parts)
            externs
            plan
            runtime-index
            referenced-functions
            program-index
            (+ seq-index 1)))])))

;; Emitted in this order.
(define (compiler-backend-object-runtime-symbols-list) : be_state.BackendStringSeq
  (let
    [symbols : be_state.BackendStringSeq
      (be_state.BackendStringSeq (__tl_make-array String 17) 0)]
    (be_state.compiler-backend-string-push! (&mut symbols) "tl_alloc")
    (be_state.compiler-backend-string-push! (&mut symbols) "tl_alloc_aligned")
    (be_state.compiler-backend-string-push! (&mut symbols) "tl_arena_current")
    (be_state.compiler-backend-string-push! (&mut symbols) "tl_arena_set")
    (be_state.compiler-backend-string-push!
      (&mut symbols)
      "tl_arena_make_small")
    (be_state.compiler-backend-string-push!
      (&mut symbols)
      "tl_arena_make_atomic")
    (be_state.compiler-backend-string-push! (&mut symbols) "tl_region_mark")
    (be_state.compiler-backend-string-push! (&mut symbols) "tl_region_reset")
    (be_state.compiler-backend-string-push! (&mut symbols) "tl_div_abort")
    (be_state.compiler-backend-string-push! (&mut symbols) "tl_shift_abort")
    (be_state.compiler-backend-string-push! (&mut symbols) "tl_memcpy")
    (be_state.compiler-backend-string-push! (&mut symbols) "tl_memcpy_fresh")
    (be_state.compiler-backend-string-push! (&mut symbols) "tl_memchr")
    (be_state.compiler-backend-string-push!
      (&mut symbols)
      "tl_tlci_call_macro_entry")
    (be_state.compiler-backend-string-push!
      (&mut symbols)
      "tl_tlci_call_image_entry")
    (be_state.compiler-backend-string-push!
      (&mut symbols)
      "tl_arena_debug_protect_never_reset")
    (be_state.compiler-backend-string-push!
      (&mut symbols)
      "tl_arena_debug_assert_pool_install")
    symbols))

(define (compiler-backend-object-runtime-symbol-provided?
  [plan : be_state.CompilerBackendRuntimePlan]
  [name : (& name str)]) : bool
  (cbi.compiler-builtin-refresh!)
  (cond
    [(string.eq name "tl_alloc") true]
    [(string.eq name "tl_alloc_aligned") true]
    [(string.eq name "tl_memcpy") true]
    [(string.eq name "tl_memcpy_fresh") true]
    [(string.eq name "tl_memchr") true]
    [(string.eq name "tl_tlci_call_image_entry") true]
    [(string.eq name "tl_tlci_call_macro_entry")
      (be_state.compiler-backend-runtime-tail-tlci-macro-entry?
        (be_state.compiler-backend-runtime-plan-tail plan))]
    [(string.eq name "tl_shift_abort")
      (be_operand.compiler-backend-plan-provides-id?
        plan
        cbi.compiler-builtin-id-tl-shift-abort)]
    [(string.eq name "tl_div_abort")
      (be_operand.compiler-backend-plan-provides-id?
        plan
        cbi.compiler-builtin-id-tl-div-abort)]
    [(string.eq name "tl_region_reset")
      (be_operand.compiler-backend-plan-provides-id?
        plan
        cbi.compiler-builtin-id-tl-region-reset)]
    [(string.eq name "tl_region_mark")
      (be_operand.compiler-backend-plan-provides-id?
        plan
        cbi.compiler-builtin-id-tl-region-mark)]
    [(string.eq name "tl_arena_make_atomic")
      (be_operand.compiler-backend-plan-provides-id?
        plan
        cbi.compiler-builtin-id-tl-arena-make-atomic)]
    [(string.eq name "tl_arena_make_small")
      (be_operand.compiler-backend-plan-provides-id?
        plan
        cbi.compiler-builtin-id-tl-arena-make-small)]
    [(string.eq name "tl_arena_set")
      (be_operand.compiler-backend-plan-provides-id?
        plan
        cbi.compiler-builtin-id-tl-arena-set)]
    [(string.eq name "tl_arena_current")
      (be_operand.compiler-backend-plan-provides-id?
        plan
        cbi.compiler-builtin-id-tl-arena-current)]
    [(string.eq name "tl_arena_debug_protect_never_reset")
      (be_operand.compiler-backend-plan-provides-id?
        plan
        cbi.compiler-builtin-id-tl-arena-debug-protect-never-reset)]
    [(string.eq name "tl_arena_debug_retire_protected")
      (be_operand.compiler-backend-plan-provides-id?
        plan
        cbi.compiler-builtin-id-tl-arena-debug-retire-protected)]
    [(string.eq name "tl_arena_debug_assert_pool_install")
      (be_operand.compiler-backend-plan-provides-id?
        plan
        cbi.compiler-builtin-id-tl-arena-debug-assert-pool-install)]
    [else false]))

(define (compiler-backend-object-runtime-symbol-provided-id?
  [plan : be_state.CompilerBackendRuntimePlan]
  [backend-state : be_state.CompilerBackendState]
  [name-id : i64]) : bool
  (or
    (be_operand.compiler-backend-plan-provides-id? plan name-id)
    (cbi.compiler-builtin-backend-tl-alloc-id? name-id)
    (be_operand.compiler-backend-fixed-fault-symbol-id? backend-state name-id)))

(define (compiler-backend-object-runtime-symbols
  [parts : object_target.CompilerBackendObjectTargetParts]
  [plan : be_state.CompilerBackendRuntimePlan]
  [names : be_state.BackendStringSeq]
  [closed : bool]
  [emit-entry : bool]
  [index : i64]) : object_target.CompilerBackendObjectTargetParts
  (if (>= index names.len)
    parts
    (let
      [name : String
        (be_state.compiler-backend-global-array-element-shared-view
          names.slots
          index)]
      [defined? : bool
        (or
          emit-entry
          (string.eq (& name) "tl_tlci_call_image_entry")
          (string.eq (& name) "tl_tlci_call_macro_entry"))]
      [referenced? : bool
        (cobj.compiler-object-relocation-builder-targets?
          (& parts.relocations)
          (& name))]
      (compiler-backend-object-runtime-symbols
        (cond
          [(not (compiler-backend-object-runtime-symbol-provided? plan name))
            parts]
          [(and defined? (or (not closed) referenced?))
            (object_target.compiler-backend-object-symbol-local-section
              parts
              name
              (Text)
              (Runtime))]
          [(and (not defined?) referenced?)
            (object_target.compiler-backend-object-symbol-extern-once
              parts
              name
              (Function))]
          [else parts])
        plan
        names
        closed
        emit-entry
        (+ index 1)))))

(define (compiler-backend-object-image-for-target
  [parts : object_target.CompilerBackendObjectTargetParts]
  [target : be_state.CompilerBackendTarget]
  [macro-entry : bool]
  [emit-entry : bool]
  [crt-entry : bool]
  [closed : bool]) : cobj.CompilerObjectImage
  (match target
    [(be_state.CompilerBackendTarget.Linux)
      (object_linux.compiler-backend-object-target-linux-image
        parts
        macro-entry
        emit-entry
        crt-entry
        closed)]
    [(be_state.CompilerBackendTarget.Windows)
      (object_windows.compiler-backend-object-target-windows-image
        parts
        macro-entry
        emit-entry
        crt-entry
        closed)]))

(define (compiler-backend-object-image-after-index
  [type-segment-bases : i64]
  [_program : compiler_ir_types.CompilerIrProgram]
  [target-policy : be_state.CompilerBackendTargetPolicy]
  [_mode : be_state.CompilerBackendMode]
  [functions : compiler_ir_types.CompilerIrFunctionSeq]
  [globals : compiler_ir_types.CompilerIrGlobalSeq]
  [externs : compiler_ir_types.CompilerIrExternSeq]
  [plan : be_state.CompilerBackendRuntimePlan]
  [runtime-index : be_state.CompilerBackendRuntimeIndex]
  [program-index : be_state.CompilerBackendProgramIndex]
  [emit-entry : bool]
  [crt-entry : bool]) : be_state.ResultCompilerBackendObject
  (let
    [target : be_state.CompilerBackendTarget target-policy.target]
    ;; IAG-1: the object image mirrors the text emitter's inline aggregate
    ;; cells, and classifies on the same single whole-program walk, before the
    ;; `.bss` reservations below are sized.
    [census : be_state.CompilerBackendIagCensusCell
      (be_data.compiler-backend-iag-prepare
        type-segment-bases
        program-index
        (be_state.compiler-backend-global-shared-view globals)
        (be_state.compiler-backend-global-shared-view functions))]
    [collections : be_state.CompilerBackendProgramCollections
      (be_data.compiler-backend-collect-program-collections-with-iag
        (be_state.compiler-backend-global-shared-view globals)
        (be_state.compiler-backend-global-shared-view functions)
        (be_state.compiler-backend-global-shared-view census))]
    [_frozen-globals-known : unit
      (compiler_regalloc.compiler-reg-frozen-globals-finish!)]
    [_inline-aggregates : unit
      (be_data.compiler-backend-iag-finish!
        program-index.backend-state
        census
        program-index)]
    [_
      (try
        (be_facts.compiler-backend-validate-program
          (be_state.compiler-backend-global-shared-view globals)
          (be_state.compiler-backend-global-shared-view functions)
          (be_state.compiler-backend-global-shared-view externs)
          plan
          program-index
          (& runtime-index)
          (& collections.references.items)
          emit-entry))]
    [closure-names : be_state.BackendSymbolSeq
      (be_data.compiler-backend-program-collections-functions
        (be_state.compiler-backend-global-shared-view collections))]
    [strings : be_state.BackendStringSeq
      (be_data.compiler-backend-program-collections-strings
        (be_state.compiler-backend-global-shared-view collections))]
    [bytes : be_state.BackendStringSeq
      (be_data.compiler-backend-program-collections-bytes
        (be_state.compiler-backend-global-shared-view collections))]
    [floats : be_state.BackendFloatSeq
      (be_data.compiler-backend-program-collections-floats
        (be_state.compiler-backend-global-shared-view collections))]
    [uses-f64-neg : bool
      (be_data.compiler-backend-program-collections-uses-f64-neg? collections)]
    [uses-f32-neg : bool
      (be_data.compiler-backend-program-collections-uses-f32-neg? collections)]
    [seed : object_target.CompilerBackendObjectTargetParts
      (compiler-backend-object-runtime-symbols
        (compiler-backend-object-externs
          (compiler-backend-object-referenced-prelude
            type-segment-bases
            (compiler-backend-object-sign-bit
              (compiler-backend-object-sign-bit
                (compiler-backend-object-floats
                  (compiler-backend-object-bytes
                    (compiler-backend-object-strings
                      (compiler-backend-object-closure-descriptors
                        (compiler-backend-object-globals
                          (compiler-backend-object-functions
                            type-segment-bases
                            (object_target.compiler-backend-object-parts-empty)
                            target
                            (& functions)
                            plan
                            program-index)
                          target
                          globals
                          program-index)
                        closure-names
                        0
                        program-index)
                      strings
                      0)
                    bytes
                    0)
                  floats)
                uses-f64-neg
                true)
              uses-f32-neg
              false)
            target
            (& functions)
            plan
            program-index)
          externs
          plan
          runtime-index
          closure-names
          program-index)
        plan
        (compiler-backend-object-runtime-symbols-list)
        (be_state.compiler-backend-state-closed-executable?
          program-index.backend-state)
        emit-entry
        0)]
    (Ok
      (compiler-backend-object-image-for-target
        seed
        target
        (be_state.compiler-backend-runtime-tail-tlci-macro-entry?
          (be_state.compiler-backend-runtime-plan-tail plan))
        emit-entry
        crt-entry
        (be_state.compiler-backend-state-closed-executable?
          program-index.backend-state)))))

(define (compiler-backend-object-semantic-binop-supported?
  [op : compiler_ir_types.CompilerIrBinOp]
  [ty : compiler_ast_types.AstType]) : bool
  (and
    (not (be_operand.compiler-backend-float-type? ty))
    (match op
      [(or (Add) (Sub) (Mul) (Eq) (Ne) (Lt) (Le) (Gt) (Ge) (BitTestEq)
           (BitTestNe) (And) (Or) (BitAnd) (BitOr) (BitXor))
        true]
      [_ false])))

(define (compiler-backend-object-semantic-value-supported?
  [value : compiler_ir_types.CompilerIrValue]) : bool
  (match value
    ;; The object emitter currently uses `REX.W C7 /0`, whose imm32 operand is
    ;; sign-extended. Keep wider constants on the assembly path until movabs
    ;; lowering is shared with the object backend.
    [(I64 value) (and (>= value -2147483648) (<= value 2147483647))]
    ;; This placeholder only records the initializer reference today.
    ;; The object encoder has no static-array record yet (#8369): a program with
    ;; one keeps the assembly path.
    [(or (RuntimeGlobal _) (StaticArray _)) false]
    [_ true]))

(define (compiler-backend-object-semantic-call-args-array-supported?
  [values : (__tl_dyn-array compiler_ir_types.CompilerIrValue)]) : bool
  (let
    [index : i64 0]
    [count : i64 (array-length values)]
    [supported : bool true]
    (while (and supported (< index count))
      (set!
        supported
        (compiler-backend-object-semantic-value-supported?
          (be_state.compiler-backend-global-array-element-shared-view
            values
            index)))
      (+= index 1))
    supported))

(define (compiler-backend-object-semantic-call-args-supported?
  [args : compiler_ir_types.CompilerIrCallArgs]) : bool
  (match args
    [(Nil) true]
    [(One value) (compiler-backend-object-semantic-value-supported? value)]
    [(Two lhs rhs)
      (and
        (compiler-backend-object-semantic-value-supported? lhs)
        (compiler-backend-object-semantic-value-supported? rhs))]
    [(or (Array values) (Sret values _))
      (compiler-backend-object-semantic-call-args-array-supported? values)]))

(define (compiler-backend-object-semantic-call-supported?
  [backend-state : be_state.CompilerBackendState]
  [name : i64]) : bool
  (let
    [text : String
      (be_state.compiler-backend-symbol-text-state backend-state name)]
    (and
      (not (be_operand.compiler-backend-stdlib-runtime-function-name? text))
      (not (be_operand.compiler-backend-string-prefix-at? text "tl_" 0))
      (not
        (be_operand.compiler-backend-fixed-fault-symbol-id? backend-state name)))))

;; Object-image lowering is deliberately incremental. ELF and COFF can
;; serialize every byte record produced by the cases below, but the other IR
;; instructions still have reference-discovery-only placeholders in the object
;; emitter, and its control flow still has differential mismatches for
;; conditions, early returns, and enum matches. This shared scan is therefore
;; the authoritative direct-object semantic contract; target serializers and
;; linkability checks remain separate, weaker contracts.
(define (compiler-backend-object-instr-semantically-supported?
  [backend-state : be_state.CompilerBackendState]
  [instr : compiler_ir_types.CompilerIrInstr]) : bool
  (match instr
    [(or (Mov _ src _) (Store _ src _) (Load _ src _))
      (compiler-backend-object-semantic-value-supported? src)]
    [(BinOp _ op lhs rhs ty)
      (and
        (compiler-backend-object-semantic-binop-supported? op ty)
        (compiler-backend-object-semantic-value-supported? lhs)
        (compiler-backend-object-semantic-value-supported? rhs))]
    [(UnOp _ op src ty)
      (and
        ;; The legacy object-only path has no production XMM-home plan. Its
        ;; float-negation placeholder loads/stores GP bits around a hard-wired
        ;; `%xmm0` XOR, so admitting it would silently preserve the old value.
        ;; #7205 removes this exclusion only after scalar SSE unary operations
        ;; are emitted from the shared post-regalloc machine program.
        (not (be_operand.compiler-backend-float-type? ty))
        (compiler-backend-object-semantic-value-supported? src)
        (match op
          [(or (Sqrt) (BitLength)) false]
          [_ true]))]
    [(Call _ name args _)
      (and
        (compiler-backend-object-semantic-call-supported? backend-state name)
        (compiler-backend-object-semantic-call-args-supported? args))]
    [(CallIndirectC _ callee args _)
      (and
        (compiler-backend-object-semantic-value-supported? callee)
        (compiler-backend-object-semantic-call-args-supported? args))]
    [(Jump _) true]
    [(Return maybe)
      (match maybe
        [(No) true]
        [(Some value) (compiler-backend-object-semantic-value-supported? value)])]
    [(Gep _ base offset _)
      (and
        (compiler-backend-object-semantic-value-supported? base)
        (compiler-backend-object-semantic-value-supported? offset))]
    [_ false]))

(define (compiler-backend-object-instrs-semantically-supported?
  [backend-state : be_state.CompilerBackendState]
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : bool
  (let
    [index : i64 0]
    [count : i64 (compiler_ir_types.compiler-ir-instr-seq-count instrs)]
    [supported : bool true]
    (while (and supported (< index count))
      (set!
        supported
        (compiler-backend-object-instr-semantically-supported?
          backend-state
          (compiler_ir_types.compiler-ir-instr-seq-ref instrs index)))
      (+= index 1))
    supported))

(define (compiler-backend-object-blocks-semantically-supported?
  [backend-state : be_state.CompilerBackendState]
  [blocks : compiler_ir_types.CompilerIrBlockList]) : bool
  (let
    [cursor : compiler_ir_types.CompilerIrBlockList blocks]
    (while true
      (match cursor
        [(Array seq)
          (let
            [count : i64 (compiler_ir_types.compiler-ir-block-seq-count seq)]
            (for [index (iterator.range 0 count)]
              (match (compiler_ir_types.compiler-ir-block-seq-ref seq index)
                [(Block _ instrs)
                  (when
                    (not
                      (compiler-backend-object-instrs-semantically-supported?
                        backend-state
                        instrs))
                    (return false))]))
            (return true))]))
    false))

(define (compiler-backend-object-globals-semantically-supported?
  [globals : compiler_ir_types.CompilerIrGlobalSeq]) : bool
  (for [index (iterator.range 0 globals.len)]
    (match (compiler_ir_types.compiler-ir-global-seq-ref globals index)
      [(Global _ _ value)
        (when
          (not (compiler-backend-object-semantic-value-supported? value))
          (return false))]))
  true)

(define (compiler-backend-object-functions-semantically-supported?
  [backend-state : be_state.CompilerBackendState]
  [functions : compiler_ir_types.CompilerIrFunctionSeq]) : bool
  (for [index (iterator.range 0 functions.len)]
    (match (owned_view.compiler-owned-element-view functions.slots index)
      [(Function name _ _ _ blocks _)
        (when
          (not
            (or
              (be_operand.compiler-backend-stdlib-runtime-function-name?
                (be_state.compiler-backend-symbol-text-state backend-state name))
              (compiler-backend-object-blocks-semantically-supported?
                backend-state
                blocks)))
          (return false))]))
  true)

;; Object-only ordinary-call lowering predates the shared ABI planner. Keep its
;; diagnostic vocabulary fixed and bounded: no user-controlled symbol text is
;; copied into a fallback category consumed by batch manifests and drivers.
(define (compiler-backend-object-unsupported-abi-category
  [target : be_state.CompilerBackendTarget]
  [context : be_state.CompilerBackendObjectAbiContext]) : be_state.CompilerDirectObjectFallbackReason
  (UnsupportedAbi target context))

;; The fallback category of an unsupported object ABI, per target and context.
;; These are literals because callers keep categories past their own scratch.
(define (compiler-backend-unsupported-object-abi-category
  [target : be_state.CompilerBackendTarget]
  [context : be_state.CompilerBackendObjectAbiContext]) : String
  (match target
    [(be_state.CompilerBackendTarget.Linux)
      (match context
        [(Call) "unsupported-object-abi:linux-x86_64:call"]
        [(FunctionEntry) "unsupported-object-abi:linux-x86_64:function-entry"]
        [(FunctionReturn) "unsupported-object-abi:linux-x86_64:function-return"])]
    [(be_state.CompilerBackendTarget.Windows)
      (match context
        [(Call) "unsupported-object-abi:windows-x86_64:call"]
        [(FunctionEntry) "unsupported-object-abi:windows-x86_64:function-entry"]
        [(FunctionReturn)
          "unsupported-object-abi:windows-x86_64:function-return"])]))

(define (compiler-direct-object-fallback-category
  [reason : be_state.CompilerDirectObjectFallbackReason]) : String
  (match reason
    [(ArtifactKindUnavailable _ _) "artifact-kind-unavailable"]
    [(DebugMetadata) "debug-metadata"]
    [(BackendMode) "backend-mode"]
    [(PrivateSpmdAbi) "private-spmd-abi"]
    [(ResourceBudget _ _) "resource-budget"]
    [(UnsupportedSemantics) "unsupported-object-semantics"]
    [(UnsupportedAbi target context)
      (compiler-backend-unsupported-object-abi-category target context)]
    [(ObjectEncoding) "unsupported-object-encoding"]
    [(UnsupportedCoffImage) "unsupported-coff-image"]
    [(ObjectFixup) "unsupported-object-fixup"]
    [(or (ObjectRelocation) (UndeclaredExternal _ _ _ _))
      "unsupported-external-relocation"]
    [(MissingEntrySymbol) "missing-entry-symbol"]
    [(MissingRuntimeEntry) "missing-runtime-entry"]
    [(EmptyTextSection) "empty-text-section"]
    [(ForcedAssembly) "forced-assembly"]
    [(SharedObjectCodeModel) "shared-object-code-model"]))

(define (compiler-direct-object-fallback-context
  [reason : be_state.CompilerDirectObjectFallbackReason]) : String
  (match reason
    [(ArtifactKindUnavailable target kind)
      (str_cat.str-cat
        "target="
        (be_state.compiler-backend-target-triple target)
        "|kind="
        (match kind
          [(Bin) "bin"]
          [(StaticLib) "staticlib"]))]
    [(ResourceBudget count limit)
      (str_cat.str-cat
        "owned-paths="
        (string.int->string count)
        "|limit="
        (string.int->string limit))]
    [(UndeclaredExternal section label offset symbol)
      (str_cat.str-cat
        "section="
        section
        "|label="
        label
        "|label-offset="
        (string.int->string offset)
        "|symbol="
        symbol)]
    [_ ""]))

(define (compiler-direct-object-fallback-transcript
  [reason : be_state.CompilerDirectObjectFallbackReason]) : String
  (let
    [category : String
      (compiler-direct-object-fallback-category
        (owned_view.compiler-owned-shared-view reason))]
    [context : String (compiler-direct-object-fallback-context reason)]
    (if (string.eq context "")
      category
      (str_cat.str-cat category "|" context))))

;; Whether this target's direct-object encoder passes arguments past the
;; integer registers on the stack. COFF's positional path does; the legacy ELF
;; path passes register arguments only (see compiler-backend-object-abi-capacity).
(define (compiler-backend-object-stack-args?
  [target : be_state.CompilerBackendTarget]) : bool
  (not (be_state.compiler-backend-target-elf? target)))

(define (compiler-backend-object-abi-capacity
  [target : be_state.CompilerBackendTarget]) : i64
  ;; The legacy ELF object path has no incoming or outgoing stack-argument
  ;; implementation. Six integer registers are its complete proven subset.
  ;; COFF has a tested positional GP stack path through the eleven-argument
  ;; NtCreateFile fixture. Do not silently widen either legacy subset here.
  (if (be_state.compiler-backend-target-elf? target)
    6
    11))

(define (compiler-backend-object-abi-type-supported?
  [ty : (& ty compiler_ast_types.AstType)]) : bool
  (be_operand.compiler-backend-intlike-scalar-type? ty))

(define (compiler-backend-object-abi-integer-type?
  [ty : compiler_ast_types.AstType]) : bool
  (match ty
    [(or (I64) (U64) (I32) (U32) (I16) (U16) (I8) (U8)) true]
    [_ false]))

(define (compiler-backend-object-abi-types-supported?
  [type-segment-bases : i64]
  [types : (& types compiler_ast_types.AstTypeList)]) : bool
  (let
    [count : i64 (compiler_ast_types.ast-type-list-len (& types))]
    (for [index (iterator.range 0 count)]
      (when
        (not
          (let
            [ty
              (compiler_ast_types.ast-type-segment-bases-get
                type-segment-bases
                (compiler_ast_types.ast-type-list-get
                  (& types)
                  index
                  (compiler_ast_types.ast-type-id-fallback)))]
            (compiler-backend-object-abi-type-supported? ty)))
        (return false)))
    true))

(define (compiler-backend-object-abi-param-signature-matches?
  [type-segment-bases : i64]
  [params : compiler_ir_types.CompilerIrParamSeq]
  [types : compiler_ast_types.AstTypeList]) : bool
  (let
    [count : i64 (compiler_ir_types.compiler-ir-param-seq-count params)]
    (if (not (= count (compiler_ast_types.ast-type-list-len (& types))))
      false
      (begin
        (for [index (iterator.range 0 count)]
          (match (compiler_ir_types.compiler-ir-param-seq-borrow params index)
            [(Param _ ty _)
              (let
                [indexed-ty : compiler_ast_types.AstType
                  (compiler_ast_types.ast-type-segment-bases-get
                    type-segment-bases
                    (compiler_ast_types.ast-type-list-get
                      (& types)
                      index
                      (compiler_ast_types.ast-type-id-fallback)))]
                (when
                  (or
                    (not (compiler-backend-object-abi-type-supported? ty))
                    (not
                      (compiler_optimize.opt-type-eq
                        type-segment-bases
                        ty
                        (& indexed-ty))))
                  (return false)))]))
        true))))

(define (compiler-backend-object-abi-value-matches-type?
  [type-segment-bases : i64]
  [types : compiler_regalloc.CompilerRegVarTypes]
  [global-types : be_state.CompilerBackendGlobalTypeTable]
  [value : compiler_ir_types.CompilerIrValue]
  [expected : compiler_ast_types.AstType]) : bool
  (match (& value)
    ;; Integer constants retain one raw IR variant after contextual checking.
    ;; Their declared integer width is recovered from the callee signature.
    [(I64 _) (compiler-backend-object-abi-integer-type? expected)]
    [(Bool _)
      (match expected
        [(Bool) true]
        [_ false])]
    [(Char _)
      (match expected
        [(Char) true]
        [_ false])]
    [_
      (match (be_facts.compiler-backend-value-type types global-types value)
        [(Some actual)
          (compiler_optimize.opt-type-eq type-segment-bases actual (& expected))]
        [(No) false])]))

(define (compiler-backend-object-call-abi-args-match?
  [type-segment-bases : i64]
  [types : compiler_regalloc.CompilerRegVarTypes]
  [global-types : be_state.CompilerBackendGlobalTypeTable]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [expected-types : compiler_ast_types.AstTypeList]) : bool
  (let
    [count : i64
      (be_facts.compiler-backend-call-args-count
        (be_state.compiler-backend-global-shared-view args))]
    (if (not
      (= count (compiler_ast_types.ast-type-list-len (& expected-types))))
      false
      (begin
        (for [index (iterator.range 0 count)]
          (let
            [expected : compiler_ast_types.AstType
              (compiler_ast_types.ast-type-segment-bases-get
                type-segment-bases
                (compiler_ast_types.ast-type-list-get
                  (& expected-types)
                  index
                  (compiler_ast_types.ast-type-id-fallback)))]
            (when
              (or
                (not (compiler-backend-object-abi-type-supported? expected))
                (not
                  (compiler-backend-object-abi-value-matches-type?
                    type-segment-bases
                    types
                    (be_state.compiler-backend-global-shared-view global-types)
                    (be_facts.compiler-backend-call-arg-at args index)
                    expected)))
              (return false))))
        true))))

(define (compiler-backend-object-call-abi-eligibility
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [program-index : be_state.CompilerBackendProgramIndex]
  [types : compiler_regalloc.CompilerRegVarTypes]
  [global-types : be_state.CompilerBackendGlobalTypeTable]
  [dst : i64]
  [name : i64]
  [args : compiler_ir_types.CompilerIrCallArgs]
  [ret-ty : compiler_ast_types.AstType]) : be_state.CompilerBackendObjectEligibility
  (match (be_facts.compiler-backend-index-signature program-index name)
    [(No)
      (Unsupported
        (compiler-backend-object-unsupported-abi-category target Call))]
    [(Some expected-types expected-ret)
      (let
        [count : i64
          (be_facts.compiler-backend-call-args-count
            (be_state.compiler-backend-global-shared-view args))]
        [dst-matches : bool
          (match (compiler_regalloc.compiler-reg-var-types-lookup types dst)
            [(Some dst-ty)
              (compiler_optimize.opt-type-eq
                type-segment-bases
                dst-ty
                (& ret-ty))]
            [(No) false])]
        (cond
          [(> count (compiler-backend-object-abi-capacity target))
            (Unsupported
              (compiler-backend-object-unsupported-abi-category target Call))]
          [(not
              (=
                count
                (compiler_ast_types.ast-type-list-len (& expected-types))))
            (Unsupported
              (compiler-backend-object-unsupported-abi-category target Call))]
          [(or
              (not (compiler-backend-object-abi-type-supported? expected-ret))
              (not (compiler-backend-object-abi-type-supported? ret-ty)))
            (Unsupported
              (compiler-backend-object-unsupported-abi-category target Call))]
          [(not
              (compiler_optimize.opt-type-eq
                type-segment-bases
                expected-ret
                (& ret-ty)))
            (Unsupported
              (compiler-backend-object-unsupported-abi-category target Call))]
          [(not dst-matches)
            (Unsupported
              (compiler-backend-object-unsupported-abi-category target Call))]
          [(not
              (compiler-backend-object-abi-types-supported?
                type-segment-bases
                expected-types))
            (Unsupported
              (compiler-backend-object-unsupported-abi-category target Call))]
          [(not
              (compiler-backend-object-call-abi-args-match?
                type-segment-bases
                types
                global-types
                args
                expected-types))
            (Unsupported
              (compiler-backend-object-unsupported-abi-category target Call))]
          [else Eligible]))]))

(define (compiler-backend-object-instr-abi-eligibility
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [program-index : be_state.CompilerBackendProgramIndex]
  [types : compiler_regalloc.CompilerRegVarTypes]
  [global-types : be_state.CompilerBackendGlobalTypeTable]
  [function-ret : compiler_ast_types.AstType]
  [instr : compiler_ir_types.CompilerIrInstr]) : be_state.CompilerBackendObjectEligibility
  (match instr
    [(Call dst name args ret-ty)
      (compiler-backend-object-call-abi-eligibility
        type-segment-bases
        target
        program-index
        types
        global-types
        dst
        name
        args
        ret-ty)]
    [(Return maybe)
      (match maybe
        [(No)
          (Unsupported
            (compiler-backend-object-unsupported-abi-category
              target
              FunctionReturn))]
        [(Some value)
          (if (compiler-backend-object-abi-value-matches-type?
            type-segment-bases
            types
            global-types
            value
            function-ret)
            Eligible
            (Unsupported
              (compiler-backend-object-unsupported-abi-category
                target
                FunctionReturn)))])]
    [_ Eligible]))

(define (compiler-backend-object-instrs-abi-eligibility
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [program-index : be_state.CompilerBackendProgramIndex]
  [types : compiler_regalloc.CompilerRegVarTypes]
  [global-types : be_state.CompilerBackendGlobalTypeTable]
  [function-ret : compiler_ast_types.AstType]
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : be_state.CompilerBackendObjectEligibility
  (let
    [count : i64 (compiler_ir_types.compiler-ir-instr-seq-count instrs)]
    (for [index (iterator.range 0 count)]
      (match (compiler-backend-object-instr-abi-eligibility
        type-segment-bases
        target
        program-index
        types
        (be_state.compiler-backend-global-shared-view global-types)
        (be_state.compiler-backend-global-shared-view function-ret)
        (compiler_ir_types.compiler-ir-instr-seq-ref instrs index))
        [(Eligible) unit]
        [(Unsupported category) (return (Unsupported category))]))
    Eligible))

(define (compiler-backend-object-blocks-abi-eligibility
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [program-index : be_state.CompilerBackendProgramIndex]
  [types : compiler_regalloc.CompilerRegVarTypes]
  [global-types : be_state.CompilerBackendGlobalTypeTable]
  [function-ret : compiler_ast_types.AstType]
  [blocks : compiler_ir_types.CompilerIrBlockList]) : be_state.CompilerBackendObjectEligibility
  (let
    [cursor : compiler_ir_types.CompilerIrBlockList blocks]
    (while true
      (match cursor
        [(Array seq)
          (let
            [count : i64 (compiler_ir_types.compiler-ir-block-seq-count seq)]
            (for [index (iterator.range 0 count)]
              (match (compiler_ir_types.compiler-ir-block-seq-ref seq index)
                [(Block _ instrs)
                  (match (compiler-backend-object-instrs-abi-eligibility
                    type-segment-bases
                    target
                    program-index
                    types
                    (be_state.compiler-backend-global-shared-view global-types)
                    (be_state.compiler-backend-global-shared-view function-ret)
                    instrs)
                    [(Eligible) unit]
                    [(Unsupported category) (return (Unsupported category))])]))
            (return Eligible))]))
    Eligible))

(define (compiler-backend-object-function-abi-eligibility
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [program-index : be_state.CompilerBackendProgramIndex]
  [global-types : be_state.CompilerBackendGlobalTypeTable]
  [func : compiler_ir_types.CompilerIrFunction]) : be_state.CompilerBackendObjectEligibility
  (match (be_state.compiler-backend-global-shared-view func)
    [(Function name params ret-ty _ blocks _)
      (if (be_operand.compiler-backend-stdlib-runtime-function-name?
        (be_state.compiler-backend-symbol-text-index program-index name))
        Eligible
        (match (be_facts.compiler-backend-index-function-signature
          program-index
          name)
          [(No)
            (Unsupported
              (compiler-backend-object-unsupported-abi-category
                target
                FunctionEntry))]
          [(Some indexed-params indexed-ret)
            (cond
              [(> params.len (compiler-backend-object-abi-capacity target))
                (Unsupported
                  (compiler-backend-object-unsupported-abi-category
                    target
                    FunctionEntry))]
              [(not
                  (compiler-backend-object-abi-param-signature-matches?
                    type-segment-bases
                    params
                    indexed-params))
                (Unsupported
                  (compiler-backend-object-unsupported-abi-category
                    target
                    FunctionEntry))]
              [(or
                  (not (compiler-backend-object-abi-type-supported? ret-ty))
                  (not
                    (compiler-backend-object-abi-type-supported? indexed-ret)))
                (Unsupported
                  (compiler-backend-object-unsupported-abi-category
                    target
                    FunctionEntry))]
              [(not
                  (compiler_optimize.opt-type-eq
                    type-segment-bases
                    ret-ty
                    (& indexed-ret)))
                (Unsupported
                  (compiler-backend-object-unsupported-abi-category
                    target
                    FunctionEntry))]
              [else
                (let
                  [types : compiler_regalloc.CompilerRegVarTypes
                    (compiler_regalloc.compiler-reg-function-var-types-with-representations-and-metrics
                      (& func)
                      (&
                        (be_state.compiler-backend-program-index-representations
                          program-index))
                      (be_state.compiler-backend-state-metrics
                        program-index.backend-state))]
                  (compiler-backend-object-blocks-abi-eligibility
                    type-segment-bases
                    target
                    program-index
                    types
                    global-types
                    ret-ty
                    blocks))])]))]))

(define (compiler-backend-object-functions-abi-eligibility
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [program-index : be_state.CompilerBackendProgramIndex]
  [global-types : be_state.CompilerBackendGlobalTypeTable]
  [functions : compiler_ir_types.CompilerIrFunctionSeq]) : be_state.CompilerBackendObjectEligibility
  (for [index (iterator.range 0 functions.len)]
    (match (compiler-backend-object-function-abi-eligibility
      type-segment-bases
      target
      program-index
      (be_state.compiler-backend-global-shared-view global-types)
      (be_state.compiler-backend-global-array-element-shared-view
        functions.slots
        index))
      [(Eligible) unit]
      [(Unsupported category) (return (Unsupported category))]))
  Eligible)

(define (compiler-backend-object-program-eligibility
  [backend-state : be_state.CompilerBackendState]
  [target : be_state.CompilerBackendTarget]
  [program-index : be_state.CompilerBackendProgramIndex]
  [program : compiler_ir_types.CompilerIrProgram]) : be_state.CompilerBackendObjectEligibility
  (match program
    [(Program globals functions _ _authority)
      (cond
        [(be_state.compiler-backend-state-shared-object-code-model?
            backend-state)
          (Unsupported (SharedObjectCodeModel))]
        [(not
            (and
              (compiler-backend-object-globals-semantically-supported?
                (be_state.compiler-backend-global-shared-view globals))
              (compiler-backend-object-functions-semantically-supported?
                backend-state
                (be_state.compiler-backend-global-shared-view functions))))
          (Unsupported
            (be_state.compiler-backend-object-unsupported-semantics-category))]
        [else
          (compiler-backend-object-functions-abi-eligibility
            program-index.type-segment-bases
            target
            program-index
            (be_facts.compiler-backend-global-types globals)
            functions)])]))

(define (compiler-backend-object-program-eligibility-with-type-segment-bases-and-profile-state
  [backend-state : be_state.CompilerBackendState]
  [type-segment-bases : i64]
  [program : compiler_ir_types.CompilerIrProgram]
  [target : be_state.CompilerBackendTarget]
  [profile-state : profile_state.CompilerProfileState]) : be_state.CompilerBackendObjectEligibility
  (match (be_state.compiler-backend-global-shared-view program)
    [(Program _ functions externs _authority)
      (let
        [program-index : be_state.CompilerBackendProgramIndex
          (be_facts.compiler-backend-program-index-build-with-backend-state-and-profile-state
            backend-state
            type-segment-bases
            functions
            externs
            profile-state)]
        (compiler-backend-object-program-eligibility
          backend-state
          target
          program-index
          program))]))

(define (compiler-backend-emit-program-object-image-target-with-mode-with-type-segment-bases-and-crt-and-profile-state-prepared-backend-state
  [backend-state : be_state.CompilerBackendState]
  [type-segment-bases : i64]
  [program : compiler_ir_types.CompilerIrProgram]
  [target : be_state.CompilerBackendTarget]
  [mode : be_state.CompilerBackendMode]
  [_spans : compiler_ir_types.CompilerSourceSpans]
  [emit-entry : bool]
  [crt-entry : bool]
  [profile-state : profile_state.CompilerProfileState]) : be_state.ResultCompilerBackendObject
  ;; Eligibility already routes a shared-object request to assembly
  ;; (`SharedObjectCodeModel`); an object image must never silently use the
  ;; executable code model instead.
  (when
    (be_state.compiler-backend-state-shared-object-code-model? backend-state)
    (return
      (Err
        (box
          (compiler_diagnostic.compiler-diagnostic-at-start
            ""
            "backend: direct objects do not support the shared-object code model; use the assembly route")))))
  (be_state.compiler-backend-state-set-emission-target-policy!
    backend-state
    (be_state.compiler-backend-target-policy-new target))
  (be_state.compiler-backend-state-set-absolute-switch-ok!
    backend-state
    (and
      emit-entry
      (not crt-entry)
      (be_state.compiler-backend-target-elf? target)))
  (be_state.compiler-backend-state-set-metrics!
    backend-state
    (profile_state.compiler-profile-state-metrics profile-state))
  (be_facts.compiler-backend-state-set-emission-symbols!
    backend-state
    be_state.CompilerBackendEmissionSymbols.None)
  (be_state.compiler-backend-state-user-symbol-cache-reset! backend-state)
  (be_facts.compiler-backend-state-slot-cache-reset! backend-state)
  (be_state.compiler-backend-state-set-abort-site-counter! backend-state 0)
  (match (be_data.compiler-backend-runtime-plan-with-index-with-backend-state
    backend-state
    (be_state.compiler-backend-global-shared-view program))
    [(Ok planned)
      (match (be_state.compiler-backend-global-shared-view program)
        [(Program globals functions externs _authority)
          (let
            [program-index : be_state.CompilerBackendProgramIndex
              (be_facts.compiler-backend-program-index-build-with-backend-state-and-profile-state
                backend-state
                type-segment-bases
                (be_state.compiler-backend-global-shared-view functions)
                (be_state.compiler-backend-global-shared-view externs)
                profile-state)]
            (match (be_facts.compiler-backend-switch-validate-functions
              (be_state.compiler-backend-global-shared-view functions))
              [(Ok)
                (compiler-backend-object-image-after-index
                  type-segment-bases
                  program
                  (be_state.compiler-backend-state-emission-target-policy
                    backend-state)
                  mode
                  functions
                  globals
                  externs
                  planned.plan
                  planned.index
                  program-index
                  emit-entry
                  crt-entry)]
              [(Err message)
                (Err
                  (box
                    (compiler_diagnostic.compiler-diagnostic-at-start
                      ""
                      message)))]))])]
    [(Err message)
      (Err (box (compiler_diagnostic.compiler-diagnostic-at-start "" message)))]))

(define (compiler-backend-emit-program-object-image-target-with-mode-with-type-segment-bases-and-crt-and-profile-state-backend-state
  [backend-state : be_state.CompilerBackendState]
  [type-segment-bases : i64]
  [program : compiler_ir_types.CompilerIrProgram]
  [target : be_state.CompilerBackendTarget]
  [mode : be_state.CompilerBackendMode]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [emit-entry : bool]
  [crt-entry : bool]
  [profile-state : profile_state.CompilerProfileState]) : be_state.ResultCompilerBackendObject
  (let
    [_emission-arena : arena.Arena
      (be_state.compiler-backend-state-ensure-emission-arena! backend-state)]
    [result : be_state.ResultCompilerBackendObject
      (compiler-backend-emit-program-object-image-target-with-mode-with-type-segment-bases-and-crt-and-profile-state-prepared-backend-state
        backend-state
        type-segment-bases
        program
        target
        mode
        spans
        emit-entry
        crt-entry
        profile-state)]
    (be_facts.compiler-backend-clear-function-owned-state! backend-state)
    (be_state.compiler-backend-state-retire-function-state! backend-state)
    (be_state.compiler-backend-state-clear-emission-arena! backend-state)
    result))

(define (compiler-backend-emit-program-object-image-target-with-mode-with-type-segment-bases-and-crt-and-profile-state
  [type-segment-bases : i64]
  [program : compiler_ir_types.CompilerIrProgram]
  [target : be_state.CompilerBackendTarget]
  [mode : be_state.CompilerBackendMode]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [emit-entry : bool]
  [crt-entry : bool]
  [profile-state : profile_state.CompilerProfileState]) : be_state.ResultCompilerBackendObject
  (let
    [backend-state : be_state.CompilerBackendState
      (be_state.compiler-backend-state-new
        (ci.intern-compat-state-capture-active))]
    (compiler-backend-emit-program-object-image-target-with-mode-with-type-segment-bases-and-crt-and-profile-state-backend-state
      backend-state
      type-segment-bases
      program
      target
      mode
      spans
      emit-entry
      crt-entry
      profile-state)))

(define (compiler-backend-emit-program-object-image-target-with-mode-and-crt
  [program : compiler_ir_types.CompilerIrProgram]
  [target : be_state.CompilerBackendTarget]
  [mode : be_state.CompilerBackendMode]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [emit-entry : bool]
  [crt-entry : bool]) : be_state.ResultCompilerBackendObject
  (compiler-backend-emit-program-object-image-target-with-mode-with-type-segment-bases-and-crt-and-profile-state
    (compiler_ast_types.ast-node-pool-reader-type-segment-bases)
    program
    target
    mode
    spans
    emit-entry
    crt-entry
    (profile_state.compiler-profile-state-new)))

(define (compiler-backend-emit-program-object-image-linux
  [program : compiler_ir_types.CompilerIrProgram]
  [spans : compiler_ir_types.CompilerSourceSpans]) : be_state.ResultCompilerBackendObject
  (compiler-backend-emit-program-object-image-target-with-mode-and-crt
    program
    (be_state.CompilerBackendTarget.Linux)
    (Scalar)
    spans
    true
    false))