;; compiler_machine_x64.tl - typed post-register-allocation x86-64 machine
;; instructions, with one assembly serializer and one byte encoder (#7055).
;;
;; A record states its instruction completely: the opcode form, the operand
;; width, physical registers by encoding number, and the immediate. Registers
;; are `compiler_abi` register ids, whose general-purpose ids 0-15 are the
;; hardware encoding numbers rax..r15. Both serializers read only the record,
;; so the assembly text and the object bytes of one record cannot disagree
;; about a register, a width or a form: neither chooses one.
;;
;; `compiler-machine-x64-check` decides whether a form can encode its operands.
;; `compiler-machine-x64-checked` is the construction boundary: an operand its
;; form cannot encode is a precise diagnostic, never a truncated immediate or an
;; inferred width.
;;
;; Extension rules. A new instruction enters as a variant with every operand
;; explicit, with an arm in each of `-check`, `-asm-line`, `-size` and
;; `-encode!`, and with assembler-derived golden text and bytes in
;; compiler_machine_x64_tests. No variant carries preformatted text or
;; preencoded bytes; an instruction that has not migrated stays a
;; `CompilerObjectX64Instr` form or backend text until its family does (#7022,
;; #7028-#7031).
(import stdlib.byte_buf_core)
(import stdlib.io)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import compiler_abi)

(defenum MachineWidth
  (W32)
  (W64))

(defenum MachineInstr
  ;; `mov{l,q} %src, %dst` between general-purpose registers: width, dst, src.
  ;; The 32-bit form zero-extends into the destination's upper half.
  (MovRR MachineWidth i64 i64)
  ;; `mov{l,q} $imm, %dst`: width, dst, imm. `movl` zero-extends a 32-bit
  ;; immediate, 0 <= imm < 2^32; `movq` sign-extends one, -2^31 <= imm < 2^31.
  ;; A full-width immediate is a different form (#7022).
  (MovRI MachineWidth i64 i64))

(defenum MachineCheck
  (Ok)
  (Err String))

(define (compiler-machine-x64-gpr? [reg : i64]) : bool
  (and
    (>= reg compiler_abi.compiler-reg-id-rax)
    (<= reg compiler_abi.compiler-reg-id-r15)))

;; Whether `imm` is an immediate the `width` form of `mov $imm, %reg` encodes.
(define (compiler-machine-x64-mov-imm-fits? [width : MachineWidth] [imm : i64]) : bool
  (match width
    [(W32) (and (>= imm 0) (< imm 4294967296))]
    [(W64) (and (>= imm -2147483648) (< imm 2147483648))]))

(define (compiler-machine-x64-register-error [role : String] [reg : i64]) : MachineCheck
  (Err
    (str_cat.str-cat
      "machine: mov "
      role
      " "
      (string.int->string reg)
      " is not a general-purpose register")))

(define (compiler-machine-x64-check [instr : MachineInstr]) : MachineCheck
  (match instr
    [(MovRR _ dst src)
      (cond
        [(not (compiler-machine-x64-gpr? dst))
          (compiler-machine-x64-register-error "destination" dst)]
        [(not (compiler-machine-x64-gpr? src))
          (compiler-machine-x64-register-error "source" src)]
        [else (Ok)])]
    [(MovRI width dst imm)
      (cond
        [(not (compiler-machine-x64-gpr? dst))
          (compiler-machine-x64-register-error "destination" dst)]
        [(not (compiler-machine-x64-mov-imm-fits? width imm))
          (Err
            (str_cat.str-cat
              "machine: "
              (compiler-machine-x64-mnemonic width)
              " immediate "
              (string.int->string imm)
              " does not fit its 32-bit form"))]
        [else (Ok)])]))

;; `instr` itself, or an internal-error diagnostic naming why its form cannot
;; encode it.
(define (compiler-machine-x64-checked [instr : MachineInstr]) : MachineInstr
  (match (compiler-machine-x64-check (clone instr))
    [(Ok) instr]
    [(Err message) (io.panic message)]))

(define (compiler-machine-x64-mnemonic [width : MachineWidth]) : String
  (match width
    [(W32) "movl"]
    [(W64) "movq"]))

(define (compiler-machine-x64-register-name [width : MachineWidth] [reg : i64]) : String
  (match width
    [(W64) (compiler_abi.compiler-abi-register-spelling reg)]
    [(W32)
      (cond
        [(= reg 0) "%eax"]
        [(= reg 1) "%ecx"]
        [(= reg 2) "%edx"]
        [(= reg 3) "%ebx"]
        [(= reg 4) "%esp"]
        [(= reg 5) "%ebp"]
        [(= reg 6) "%esi"]
        [(= reg 7) "%edi"]
        [(= reg 8) "%r8d"]
        [(= reg 9) "%r9d"]
        [(= reg 10) "%r10d"]
        [(= reg 11) "%r11d"]
        [(= reg 12) "%r12d"]
        [(= reg 13) "%r13d"]
        [(= reg 14) "%r14d"]
        [else "%r15d"])]))

;; An instruction's line of TypeLisp assembly is
;; `<head><source>, <destination>\n`, with the indent and mnemonic in `head`.
;; Consumers append the pieces to their own buffers, so a register move builds
;; no string.
(defstruct MachineAsmParts
  (head String)
  (source String)
  (destination String))

(define (compiler-machine-x64-asm-parts [instr : MachineInstr]) : MachineAsmParts
  (match instr
    [(MovRR width dst src)
      (MachineAsmParts
        (match width
          [(W32) "    movl "]
          [(W64) "    movq "])
        (compiler-machine-x64-register-name width src)
        (compiler-machine-x64-register-name width dst))]
    [(MovRI width dst imm)
      (MachineAsmParts
        (match width
          [(W32) "    movl $"]
          [(W64) "    movq $"])
        (string.int->string imm)
        (compiler-machine-x64-register-name width dst))]))

;; The instruction's line of TypeLisp assembly, with its indent and newline.
(define (compiler-machine-x64-asm-line [instr : MachineInstr]) : String
  (let
    [parts : MachineAsmParts (compiler-machine-x64-asm-parts instr)]
    (str_cat.str-cat parts.head parts.source ", " parts.destination "\n")))

(define (compiler-machine-x64-high? [reg : i64]) : bool
  (>= reg 8))

;; The REX prefix of a register-direct form (0x40 for none needed at W32):
;; W for 64-bit operands, R for the ModRM reg field, B for its r/m field.
(define (compiler-machine-x64-rex
  [width : MachineWidth]
  [reg-field : i64]
  [rm-field : i64]) : i64
  (+
    (match width
      [(W32) 0x40]
      [(W64) 0x48])
    (+
      (if (compiler-machine-x64-high? reg-field)
        4
        0)
      (if (compiler-machine-x64-high? rm-field)
        1
        0))))

;; Encoded length in bytes.
(define (compiler-machine-x64-size [instr : MachineInstr]) : i64
  (match instr
    [(MovRR width dst src)
      (if (= (compiler-machine-x64-rex width src dst) 0x40)
        2
        3)]
    [(MovRI width dst _)
      (match width
        [(W32)
          (if (compiler-machine-x64-high? dst)
            6
            5)]
        [(W64) 7])]))

(define (compiler-machine-x64-push!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (byte_buf_core.byte-buf-builder-push out (cast (bit-and value 0xff) : u8)))

(define (compiler-machine-x64-push-imm32!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (compiler-machine-x64-push! out value)
  (compiler-machine-x64-push! out (shr value 8))
  (compiler-machine-x64-push! out (shr value 16))
  (compiler-machine-x64-push! out (shr value 24)))

;; Appends the instruction's bytes: `89 /r` for a register move, `B8+rd id` for
;; `movl $imm`, `REX.W C7 /0 id` for `movq $imm`, as GNU as encodes them.
(define (compiler-machine-x64-encode!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [instr : MachineInstr]) : unit
  (match instr
    [(MovRR width dst src)
      (let
        [rex : i64 (compiler-machine-x64-rex width src dst)]
        (unless (= rex 0x40) (compiler-machine-x64-push! out rex))
        (compiler-machine-x64-push! out 0x89)
        (compiler-machine-x64-push!
          out
          (+ 0xc0 (+ (* (bit-and src 7) 8) (bit-and dst 7)))))]
    [(MovRI width dst imm)
      (match width
        [(W32)
          (when
            (compiler-machine-x64-high? dst)
            (compiler-machine-x64-push! out 0x41))
          (compiler-machine-x64-push! out (+ 0xb8 (bit-and dst 7)))]
        [(W64)
          (compiler-machine-x64-push!
            out
            (compiler-machine-x64-rex (W64) 0 dst))
          (compiler-machine-x64-push! out 0xc7)
          (compiler-machine-x64-push! out (+ 0xc0 (bit-and dst 7)))])
      (compiler-machine-x64-push-imm32! out imm)]))