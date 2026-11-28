(import compiler_assemble_linux_x64 as asm)
(import compiler_object_layout as layout)
(import linker_elf_object_reader as elf)
(import stdlib.byte_buf as buf)
(import stdlib.string)
(import stdlib.io)
(import stdlib.test)

(define (assemble [input : (& str)]) : String
  (match (asm.assemble-linux-x64 input)
    [(Ok bytes) bytes]
    [(Err reason) (io.panic reason)]))

(define (rejected? [input : (& str)]) : bool
  (match (asm.assemble-linux-x64 input)
    [(Ok _) false]
    [(Err _) true]))

(test
  final-assembler-relaxes-numeric-branches
  (let
    [object (assemble ".text\n1: nop\njmp 1b\njne 1f\n.zero 128\n1: jmp 1b\n")]
    ;; The section is the first payload. The near JNE reaches the second 1:,
    ;; whose own backward reference resolves to the same address.
    (test.assert-i64-eq
      (layout.compiler-object-layout-u8-at (& object) 64)
      0x90
      "nop")
    (test.assert-i64-eq
      (layout.compiler-object-layout-u16-at (& object) 65)
      0xfdeb
      "backward")
    (test.assert-i64-eq
      (layout.compiler-object-layout-u16-at (& object) 67)
      0x850f
      "near jne")
    (test.assert-i64-eq
      (layout.compiler-object-layout-u32-at (& object) 69)
      128
      "forward displacement")
    (test.assert-i64-eq
      (layout.compiler-object-layout-u16-at (& object) 201)
      0xfeeb
      "new numeric label")))

(test
  final-assembler-real-elf-relocations
  (let
    [object
      (assemble
        ".text\ncmpl $7, ext+8(%rip)\nmovq ext@GOTPCREL(%rip), %rax\nmovq %fs:tls@tpoff, %rax\ncall ext@PLT\n.data\n.quad .+8\n")]
    [bytes (buf.to-array (buf.from-string object))]
    [request (elf.ElfReadRequest (elf.ElfIdentity 1 2) (elf.default-limits))]
    (match (elf.read-object (& bytes) (& request))
      [(ReadFailed _)
        (test.assert-true false "ELF reader rejected assembled object")]
      [(ReadObject parsed)
        (test.assert-i64-eq
          (array-length parsed.relocations)
          5
          "five explicit relocations")
        (test.assert-i64-eq
          (array-ref parsed.relocations 0).addend
          3
          "RIP +8 minus disp32 and imm8")
        (test.assert-i64-eq
          (array-ref parsed.relocations 1).number
          42
          "relaxable REX GOT load")
        (test.assert-i64-eq
          (array-ref parsed.relocations 2).number
          23
          "thread offset")
        (test.assert-i64-eq
          (array-ref parsed.relocations 3).number
          4
          "PLT call")
        (test.assert-i64-eq
          (array-ref parsed.relocations 4).addend
          8
          "relocatable location counter")])))

(test
  final-assembler-section-group-and-link-order
  (let
    [source
      ".section .text.fun,\"axG\",@progbits,fun,comdat\n.globl fun\n.hidden fun\nfun: call ext\n.size fun,.-fun\n.pushsection rows,\"ao\",@progbits,fun\n.long fun-.\n.popsection\n.section .tbss,\"awT\",@nobits\n.zero 256\n"]
    [again (assemble (& source))]
    [object (assemble (& source))]
    [bytes (buf.to-array (buf.from-string (string.copy (& object))))]
    [request (elf.ElfReadRequest (elf.ElfIdentity 1 2) (elf.default-limits))]
    (test.assert-true (string.eq (& object) (& again)) "deterministic ELF")
    (match (elf.read-object (& bytes) (& request))
      [(ReadFailed _) (test.assert-true false "ELF reader rejected group")]
      [(ReadObject parsed)
        (test.assert-i64-eq
          (array-length parsed.groups)
          1
          "one COMDAT signature")
        (test.assert-i64-eq
          (array-ref parsed.groups 0).member-count
          2
          "code plus its relocations")])))

(test
  final-assembler-diagnostics
  (test.assert-true
    (rejected? "jmp 997b\n")
    "unresolved numeric backward reference")
  (test.assert-true (rejected? ".text\n.balign 3\n") "invalid alignment")
  (test.assert-true (rejected? ".text\na:\na:\n") "duplicate definition")
  (test.assert-true (rejected? ".set a,b\n.set b,a\n") "cyclic alias")
  (test.assert-true (rejected? ".cfi_endproc\n") "unmatched CFI")
  (test.assert-true (rejected? ".text\n.loc 1 12 3\n") "unknown file"))

(test
  final-assembler-quoted-local-entry
  (let
    [object
      (assemble
        ".text\n.local \"_entry:2\"\n.type \"_entry:2\",@function\n\"_entry:2\": ret\n.size \"_entry:2\",.-\"_entry:2\"\ncall \"_entry:2\"\n")]
    (test.assert-i64-eq
      (layout.compiler-object-layout-u32-at (& object) 66)
      4294967290
      "backward local call")))

(test
  final-assembler-debug-section-addresses
  (let
    [source
      ".file 1 \"math.tl\"\n.text\n.globl f\n.type f,@function\nf:\n.loc 1 3 7\n.cfi_startproc\npushq %rbp\n.cfi_def_cfa_offset 16\n.cfi_offset %rbp,-16\n.loc 1 4 1\nret\n.cfi_endproc\n.size f,.-f\n"]
    [object (assemble (& source))]
    [bytes (buf.to-array (buf.from-string (string.copy (& object))))]
    [request (elf.ElfReadRequest (elf.ElfIdentity 1 2) (elf.default-limits))]
    [line false]
    [info false]
    [frame false]
    (match (elf.read-object (& bytes) (& request))
      [(ReadFailed _)
        (test.assert-true false "ELF reader rejected debug object")]
      [(ReadObject parsed)
        (let
          [i : i64 0]
          (while (< i (array-length parsed.sections))
            (let
              [name (array-ref parsed.sections i).name]
              [text (string.substring (& object) name.offset name.size)]
              [body (cast (array-ref parsed.sections i).file-offset : i64)]
              (cond
                [(string.eq (& text) ".eh_frame")
                  (set! frame true)
                  (test.assert-i64-eq
                    (layout.compiler-object-layout-u32-at
                      (& object)
                      (+ body 36))
                    2
                    "FDE covers both instructions")]
                [(string.eq (& text) ".debug_line")
                  (set! line true)
                  (test.assert-i64-eq
                    (layout.compiler-object-layout-u16-at (& object) (+ body 4))
                    3
                    "DWARF line version")]
                [(string.eq (& text) ".debug_info")
                  (set! info true)
                  (test.assert-i64-eq
                    (layout.compiler-object-layout-u16-at (& object) (+ body 4))
                    4
                    "DWARF CU version")]
                [else unit]))
            (+= i 1)))])
    (test.assert-true
      (and line info frame)
      "line table, compilation unit and FDE")))

(test
  final-assembler-data-ranges-and-repeat-expansions
  (let
    [source
      ".text\nstart: .byte 0, 0xA5 , -0x2, + 7 , 3+4\n.irp v, 8, 9\n.byte \\v\n.endr\n.long .-start\n.quad 0xffffffffffffffff\n"]
    [object (assemble (& source))]
    (test.assert-i64-eq
      (layout.compiler-object-layout-u32-at (& object) 64)
      0x07fea500
      "decimal, hex and signed fields")
    (test.assert-i64-eq
      (layout.compiler-object-layout-u32-at (& object) 68)
      0x07090807
      "expression, repeat and label difference")
    (test.assert-i64-eq
      (layout.compiler-object-layout-u32-at (& object) 75)
      0xffffffff
      "unsigned literal maximum")
    (test.assert-true (rejected? ".byte 1, \n") "missing field")
    (test.assert-true
      (rejected? ".quad 0x10000000000000000\n")
      "out-of-range integer")
    (test.assert-true
      (rejected? ".irp v, 1\n.byte \\bad\n.endr\n")
      "invalid repeat substitution")))