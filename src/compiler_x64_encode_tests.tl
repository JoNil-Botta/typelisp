;; Fixed instruction bytes verified with GNU as --64 and objdump -drw.
;; The fixup tests leave symbol resolution to the caller.
(import compiler_x64_encode as x64)
(import compiler_x64_encode_bytes as enc)
(import stdlib.byte_buf_core)
(import stdlib.string)
(import stdlib.test)

(define (assert-bytes!
  [out : (& byte_buf_core.ByteBufBuilder)]
  [hex : (& str)]
  [message : String]) : unit
  (test.assert-i64-eq
    (* 2 out.len)
    (string.string-length hex)
    (string.copy message))
  (let
    [i : i64 0]
    (while (< i out.len)
      (let
        [at (* i 2)]
        [digits "0123456789abcdef"]
        [hi
          (string.index-of-byte
            (& digits)
            0
            (cast (string.string-ref hex at) : u8))]
        [lo
          (string.index-of-byte
            (& digits)
            0
            (cast (string.string-ref hex (+ at 1)) : u8))]
        (test.assert-i64-eq
          (cast (array-ref out.slots i) : i64)
          (+ (* hi 16) lo)
          (string.copy message)))
      (+= i 1))))

(define (golden! [line : String] [hex : String]) : unit
  (let
    [out (byte_buf_core.byte-buf-builder-new)]
    (match (x64.x64-encode-instruction! (&mut out) (& line) (Near))
      [(Err message) (test.assert-true false message)]
      [(Ok encoded)
        (test.assert-i64-eq encoded.fixup-count 0 (string.copy line))
        (assert-bytes! (& out) (& hex) line)])))

(test
  x64-final-text-register-widths-and-addressing
  (golden! "movl %r15d, %r8d" "4589f8")
  (golden! "movq %r8, %r15" "4d89c7")
  (golden! "movabsq $0x8000000000000000, %r13" "49bd0000000000000080")
  (golden! "movq $2147483648, %r13" "49bd0000008000000000")
  (golden! "movq $-2147483648, (%r12)" "49c7042400000080")
  (golden! "movzbl %ah, %eax" "0fb6c4")
  (golden! "movb %sil, %al" "4088f0")
  (golden! "movb %ah, (%rbp)" "886500")
  (golden! "movb %al, 0(%r13)" "41884500")
  (golden! "movq %fs:0x28, %r11" "644c8b1c2528000000")
  (golden! "movl 12(%r13d,%r12d,4), %r10d" "67478b54a50c")
  (golden! "leaq (,%r12,8), %r11" "4e8d1ce500000000")
  (golden! "sub $80, %rsp" "4883ec50")
  (golden! "cmpw $65535, %cx" "6683f9ff"))

(test
  x64-final-text-group-immediate-boundaries
  (golden! "cmpw $65408, %cx" "6683f980")
  (golden! "cmpw $65407, %cx" "6681f97fff")
  (golden! "cmpw $128, %cx" "6681f98000")
  (golden! "cmpw $127, %cx" "6683f97f")
  (golden! "cmpl $4294967295, %r10d" "4183faff")
  (golden! "movq $-1, 216(%rsp)" "48c78424d8000000ffffffff")
  (golden! "lock cmpxchgl %edx, (%rdi)" "f00fb117")
  (golden! "lock xaddl %eax, (%rdi)" "f00fc107")
  (golden! "lock cmpxchgq %r10, 16(%r9)" "f04d0fb15110")
  (golden! "lock xaddq %rax, (%r12)" "f0490fc10424"))

(test
  x64-final-text-integer-instructions-and-prefixes
  (golden! "rep movsb" "f3a4")
  (golden! "rep movsq" "f348a5")
  (golden! "rep stosq" "f348ab")
  (golden! "repne scasb" "f2ae")
  (golden! "btsq $9, %r10" "490fbaea09")
  (golden! "xchgq %r12, %rax" "4994")
  (golden! "imulq $3, 16(%rbp), %r10" "4c6b551003")
  (golden! "shrq %cl, %r10" "49d3ea")
  (golden! "callq *%r12" "41ffd4")
  (golden! "jmpq *16(%r13)" "41ff6510")
  (golden! "setae %r10b" "410f93c2")
  (golden! "cmovgq %r8, %r10" "4d0f4fd0")
  (golden! "movq %xmm0, -40(%rbp)" "660fd645d8"))

(test
  x64-final-text-sse-operand-fields
  (golden! "movq %xmm9, %r10" "664d0f7eca")
  (golden! "cvtsi2sdq (%rax), %xmm10" "f24c0f2a10")
  (golden! "movdqu (%r12), %xmm9" "f3450f6f0c24")
  (golden! "ucomisd 8(%rsp), %xmm2" "660f2e542408")
  (golden! "psrldq $3, %xmm9" "66410f73d903")
  (golden! "punpcklbw %xmm8, %xmm9" "66450f60c8")
  (golden! "vpxor %ymm8, %ymm9, %ymm10" "c44135efd0"))

(test
  x64-final-text-vex-operand-fields
  (golden! "vpsrlq $31, %ymm8, %ymm10" "c4c12d73d01f")
  (golden! "vpermq $3, %ymm10, %ymm13" "c443fd00ea03")
  (golden! "vextracti128 $1, %ymm6, %xmm2" "c4e37d39f201")
  (golden! "vblendvpd %ymm15, %ymm12, %ymm3, %ymm10" "c443654bd4f0")
  (golden! "vpgatherqd %xmm10, 32(%r13,%ymm14,4), %xmm11" "c4022d915cb520")
  (golden! "vpmaskmovq %ymm9, %ymm13, 0(%r10)" "c442958e0a")
  (golden! "kmovw %r10d, %k7" "c4c17892fa")
  (golden! "kmovq %k2, %r12" "c461fb93e2")
  (golden! "kshiftlw $8, %k7, %k6" "c4e3f932f708")
  (golden! "vpcmpuq $6, %zmm30, %zmm24, %k7" "6293bd401efe06"))

(test
  x64-final-text-evex-and-vsib-operand-fields
  (golden! "vmovdqu8 %zmm7, (%r12){%k2}" "62d17f4a7f3c24")
  (golden! "vmovdqu64 64(%r12), %zmm17{%k7}{z}" "62c1fecf6f4c2401")
  (golden! "vmovdqu64 32(%r12), %zmm17{%k7}{z}" "62c1fecf6f8c2420000000")
  (golden! "vpxord %zmm17, %zmm20, %zmm31" "62215d40eff9")
  (golden! "vgatherqps 64(%r13,%zmm22,4), %ymm11{%k1}" "62527d41935cb510")
  (golden! "vextracti64x4 $1, %zmm26, %ymm19" "6223fd483bd301")
  (golden! "vzeroupper" "c5f877"))

(define (assert-fixup!
  [fixup : (& enc.X64Fixup)]
  [field : i64]
  [width : i64]
  [end : i64]
  [expression : String]) : unit
  (test.assert-i64-eq fixup.field-offset field "fixup byte offset")
  (test.assert-i64-eq fixup.width width "fixup field width")
  (test.assert-i64-eq
    fixup.instruction-end
    end
    "offset after the entire instruction")
  (test.assert-string-eq (& fixup.expression) (& expression) "fixup expression"))

(test
  x64-final-text-two-relocations-and-caller-relative-offsets
  (let
    [out (byte_buf_core.byte-buf-builder-new)]
    (byte_buf_core.byte-buf-builder-push (&mut out) 0x90)
    (match (x64.x64-encode-instruction!
      (&mut out)
      "movq $item-4, table+8(%rip)"
      (Near))
      [(Err message) (test.assert-true false message)]
      [(Ok encoded)
        (test.assert-i64-eq
          encoded.fixup-count
          2
          "RIP displacement followed by immediate")
        (assert-bytes! (& out) "9048c7050000000000000000" "appended bytes")
        (assert-fixup! (& (array-ref encoded.fixups 0)) 4 4 12 "table+8")
        (assert-fixup! (& (array-ref encoded.fixups 1)) 8 4 12 "item-4")
        (test.assert-true
          (match (array-ref encoded.fixups 0).intent
            [(PcRelative) true]
            [_ false])
          "RIP displacement relocation")
        (test.assert-true
          (match (array-ref encoded.fixups 1).intent
            [(SignedAbsolute) true]
            [_ false])
          "sign-extended immediate relocation")])))

(test
  x64-final-text-tls-displacement-and-full-width-absolute-fixups
  (let
    [out (byte_buf_core.byte-buf-builder-new)]
    (match (x64.x64-encode-instruction!
      (&mut out)
      "movq %fs:slot@TPOFF, %r9"
      (Near))
      [(Err message) (test.assert-true false message)]
      [(Ok encoded)
        (test.assert-i64-eq encoded.fixup-count 1 "TLS displacement")
        (assert-fixup! (& (array-ref encoded.fixups 0)) 5 4 9 "slot@TPOFF")])
    (match (x64.x64-encode-instruction!
      (&mut out)
      "movabsq $pointer, %r15"
      (Near))
      [(Err message) (test.assert-true false message)]
      [(Ok encoded)
        (test.assert-i64-eq encoded.fixup-count 1 "symbol address")
        (assert-fixup! (& (array-ref encoded.fixups 0)) 11 8 19 "pointer")
        (test.assert-true
          (match (array-ref encoded.fixups 0).intent
            [(Absolute) true]
            [_ false])
          "full-width immediate relocation")])
    (assert-bytes!
      (& out)
      "644c8b0c250000000049bf0000000000000000"
      "TLS and movabs bytes")))

(define (branch-golden!
  [line : String]
  [selection : enc.X64BranchWidth]
  [hex : String]
  [offset : i64]
  [width : i64]
  [end : i64]
  [expression : String]) : unit
  (let
    [out (byte_buf_core.byte-buf-builder-new)]
    (match (x64.x64-encode-instruction! (&mut out) (& line) selection)
      [(Err message) (test.assert-true false message)]
      [(Ok encoded)
        (assert-bytes! (& out) (& hex) line)
        (test.assert-i64-eq encoded.fixup-count 1 "one branch target")
        (assert-fixup!
          (& (array-ref encoded.fixups 0))
          offset
          width
          end
          expression)
        (test.assert-true
          (match (array-ref encoded.fixups 0).intent
            [(BranchRelative) true]
            [_ false])
          "direct branch relocation")])))

(test
  x64-final-text-short-near-and-plt-branches
  (branch-golden! "jne .Lnext" (Short) "7500" 1 1 2 ".Lnext")
  (branch-golden! "jne .Lnext" (Near) "0f8500000000" 2 4 6 ".Lnext")
  (branch-golden! "jmp 1b" (Short) "eb00" 1 1 2 "1b")
  (branch-golden! "jmp 1f" (Near) "e900000000" 1 4 5 "1f")
  (branch-golden! "call memcpy@PLT" (Short) "e800000000" 1 4 5 "memcpy@PLT"))

(define (reject! [line : String]) : unit
  (let
    [out (byte_buf_core.byte-buf-builder-new)]
    (byte_buf_core.byte-buf-builder-push (&mut out) 0x90)
    (match (x64.x64-encode-instruction! (&mut out) (& line) (Near))
      [(Ok _) (test.assert-true false line)]
      [(Err _) (assert-bytes! (& out) "90" line)])))

(test
  x64-final-text-diagnoses-unsupported-forms-without-modifying-the-sink
  (reject! "madeup %rax")
  (reject! "movq 4(%r10, %r12, 3), %rax")
  (reject! "movq 4(%r10, %r12, 4, 8), %rax")
  (reject! "movq (%r10),")
  (reject! "movq %rax, (%rax")
  (reject! "movb %ah, %sil")
  (reject! "movzbq %ah, %rax")
  (reject! "cmpw $65536, %cx")
  (reject! "cmpq $4294967295, %r10")
  (reject! "lock cmpq $0, (%rax)")
  (reject! "lock cmpxchgq %r10, %r11")
  (reject! "vpxor %ymm8, %xmm9, %ymm10")
  (reject! "vpxor %ymm8, %ymm9, %ymm10{%k7}")
  (reject! "vmovdqu8 %zmm7, (%r12){%k2}{z}")
  (reject! "vgatherqps (%r13,%zmm22,4), %ymm11"))