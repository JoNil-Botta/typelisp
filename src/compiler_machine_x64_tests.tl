;; Golden assembly text and bytes for the typed x86-64 machine records (#7055).
;; Every pair was produced by GNU as from its text column: the serializer must
;; print that line and the encoder must emit the assembler's bytes for it. The
;; cases cover every REX bit combination of both widths, the stack and frame
;; registers, and the imm32 boundaries of both immediate forms.
(import compiler_machine_x64 as mx)
(import compiler_abi)
(import stdlib.byte_buf_core)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.test)

(define (mx-hex-digit [value : i64]) : String
  (string.substring "0123456789abcdef" value 1))

;; The encoding as space-separated lowercase hex, as objdump prints it.
(define (mx-hex [instr : mx.MachineInstr]) : String
  (let
    [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    (mx.compiler-machine-x64-encode! (&mut out) instr)
    (let
      [bytes : (__tl_dyn-array u8)
        (byte_buf_core.byte-buf-builder-finish-array (& out))]
      [text : String ""]
      [index : i64 0]
      (while (< index (array-length bytes))
        (let
          [value : i64 (cast (array-ref bytes index) : i64)]
          (set!
            text
            (str_cat.str-cat
              text
              (if (= index 0)
                ""
                " ")
              (mx-hex-digit (shr value 4))
              (mx-hex-digit (bit-and value 15)))))
        (set! index (+ index 1)))
      text)))

(define (mx-golden! [instr : mx.MachineInstr] [text : String] [hex : String]) : unit
  (test.assert-owned-string-eq
    (mx.compiler-machine-x64-asm-line (clone instr))
    (str_cat.str-cat "    " (string.copy text) "\n")
    (str_cat.str-cat "machine x64 text: " (string.copy text)))
  (test.assert-owned-string-eq
    (mx-hex (clone instr))
    (string.copy hex)
    (str_cat.str-cat "machine x64 bytes: " (string.copy text)))
  (test.assert-i64-eq
    (mx.compiler-machine-x64-size instr)
    (/ (+ (string.string-length hex) 1) 3)
    (str_cat.str-cat "machine x64 size: " text)))

(define (mx-rejects! [instr : mx.MachineInstr] [message : String]) : unit
  (match (mx.compiler-machine-x64-check instr)
    [(Ok) (test.assert-true false (str_cat.str-cat "accepted: " message))]
    [(Err actual)
      (test.assert-owned-string-eq actual message "machine x64 diagnostic")]))

(test
  machine-x64-mov-register-golden
  (mx-golden! (mx.MachineInstr.MovRR (W64) 3 0) "movq %rax, %rbx" "48 89 c3")
  (mx-golden! (mx.MachineInstr.MovRR (W64) 5 4) "movq %rsp, %rbp" "48 89 e5")
  (mx-golden! (mx.MachineInstr.MovRR (W64) 0 8) "movq %r8, %rax" "4c 89 c0")
  (mx-golden! (mx.MachineInstr.MovRR (W64) 9 0) "movq %rax, %r9" "49 89 c1")
  (mx-golden! (mx.MachineInstr.MovRR (W64) 15 10) "movq %r10, %r15" "4d 89 d7")
  (mx-golden! (mx.MachineInstr.MovRR (W32) 3 0) "movl %eax, %ebx" "89 c3")
  (mx-golden! (mx.MachineInstr.MovRR (W32) 0 8) "movl %r8d, %eax" "44 89 c0")
  (mx-golden! (mx.MachineInstr.MovRR (W32) 9 0) "movl %eax, %r9d" "41 89 c1")
  (mx-golden!
    (mx.MachineInstr.MovRR (W32) 15 10)
    "movl %r10d, %r15d"
    "45 89 d7"))

(test
  machine-x64-mov-immediate-golden
  (mx-golden!
    (mx.MachineInstr.MovRI (W32) 0 0)
    "movl $0, %eax"
    "b8 00 00 00 00")
  (mx-golden!
    (mx.MachineInstr.MovRI (W32) 1 1)
    "movl $1, %ecx"
    "b9 01 00 00 00")
  (mx-golden!
    (mx.MachineInstr.MovRI (W32) 7 2147483647)
    "movl $2147483647, %edi"
    "bf ff ff ff 7f")
  (mx-golden!
    (mx.MachineInstr.MovRI (W32) 8 4294967295)
    "movl $4294967295, %r8d"
    "41 b8 ff ff ff ff")
  (mx-golden!
    (mx.MachineInstr.MovRI (W64) 0 -1)
    "movq $-1, %rax"
    "48 c7 c0 ff ff ff ff")
  (mx-golden!
    (mx.MachineInstr.MovRI (W64) 2 -2147483648)
    "movq $-2147483648, %rdx"
    "48 c7 c2 00 00 00 80")
  (mx-golden!
    (mx.MachineInstr.MovRI (W64) 6 2147483647)
    "movq $2147483647, %rsi"
    "48 c7 c6 ff ff ff 7f")
  (mx-golden!
    (mx.MachineInstr.MovRI (W64) 15 0)
    "movq $0, %r15"
    "49 c7 c7 00 00 00 00")
  (mx-golden!
    (mx.MachineInstr.MovRI (W64) 12 -7)
    "movq $-7, %r12"
    "49 c7 c4 f9 ff ff ff"))

(test
  machine-x64-rejects-unencodable-operands
  (mx-rejects!
    (mx.MachineInstr.MovRI (W64) 0 2147483648)
    "machine: movq immediate 2147483648 does not fit its 32-bit form")
  (mx-rejects!
    (mx.MachineInstr.MovRI (W64) 0 -2147483649)
    "machine: movq immediate -2147483649 does not fit its 32-bit form")
  (mx-rejects!
    (mx.MachineInstr.MovRI (W32) 0 -1)
    "machine: movl immediate -1 does not fit its 32-bit form")
  (mx-rejects!
    (mx.MachineInstr.MovRI (W32) 0 4294967296)
    "machine: movl immediate 4294967296 does not fit its 32-bit form")
  (mx-rejects!
    (mx.MachineInstr.MovRR (W64) 32 0)
    "machine: mov destination 32 is not a general-purpose register")
  (mx-rejects!
    (mx.MachineInstr.MovRR (W32) 0 16)
    "machine: mov source 16 is not a general-purpose register")
  (mx-rejects!
    (mx.MachineInstr.MovRI (W64) -1 0)
    "machine: mov destination -1 is not a general-purpose register"))

;; The size every serializer lays out is the length the encoder writes, for
;; every register pair of both widths.
(test
  machine-x64-size-is-encoded-length
  (let
    [dst : i64 0]
    (while (< dst 16)
      (let
        [src : i64 0]
        (while (< src 16)
          (let
            [wide : mx.MachineInstr (mx.MachineInstr.MovRR (W64) dst src)]
            [narrow : mx.MachineInstr (mx.MachineInstr.MovRR (W32) dst src)]
            (test.assert-i64-eq
              (mx.compiler-machine-x64-size (clone wide))
              (/ (+ (string.string-length (mx-hex wide)) 1) 3)
              "machine x64 movq size")
            (test.assert-i64-eq
              (mx.compiler-machine-x64-size (clone narrow))
              (/ (+ (string.string-length (mx-hex narrow)) 1) 3)
              "machine x64 movl size"))
          (set! src (+ src 1))))
      (set! dst (+ dst 1)))))

;; The emission helpers that carry register spellings enter records through
;; `compiler-abi-register-id-from-spelling`: every general-purpose spelling
;; round-trips, and no other spelling decodes as one.
(test
  machine-x64-register-spelling-ingress
  (let
    [reg : i64 0]
    (while (< reg 16)
      (test.assert-i64-eq
        (compiler_abi.compiler-abi-register-id-from-spelling
          (compiler_abi.compiler-abi-register-spelling reg))
        reg
        "general-purpose spelling round-trips")
      (set! reg (+ reg 1))))
  (test.assert-i64-eq
    (compiler_abi.compiler-abi-register-id-from-spelling "%xmm3")
    (+ compiler_abi.compiler-reg-id-xmm-base 3)
    "xmm spelling keeps its class")
  (test.assert-i64-eq
    (compiler_abi.compiler-abi-gp-register-id-from-spelling "%r16")
    compiler_abi.compiler-reg-id-invalid
    "no r16")
  (test.assert-i64-eq
    (compiler_abi.compiler-abi-gp-register-id-from-spelling "%r1")
    compiler_abi.compiler-reg-id-invalid
    "no r1")
  (test.assert-i64-eq
    (compiler_abi.compiler-abi-gp-register-id-from-spelling "%rip")
    compiler_abi.compiler-reg-id-invalid
    "rip is not a general-purpose register")
  (test.assert-i64-eq
    (compiler_abi.compiler-abi-gp-register-id-from-spelling "%eax")
    compiler_abi.compiler-reg-id-invalid
    "a 32-bit spelling is not a 64-bit register id")
  (test.assert-i64-eq
    (compiler_abi.compiler-abi-gp-register-id-from-spelling "%xmm0")
    compiler_abi.compiler-reg-id-invalid
    "xmm is not general-purpose"))