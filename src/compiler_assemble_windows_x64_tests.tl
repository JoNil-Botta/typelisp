(import compiler_assemble_windows_x64 as asm)
(import compiler_object_layout as layout)
(import stdlib.string)
(import stdlib.test)
(import stdlib.io)
(import stdlib.iterator)

(define (assemble [text : (& str)]) : String
  (match (asm.assemble-windows-x64 text)
    [(Ok object) object]
    [(Err message) (io.panic message)]))

(define (rejected? [text : (& str)]) : bool
  (match (asm.assemble-windows-x64 text)
    [(Ok _) false]
    [(Err _) true]))

(define (header [obj : (& str)] [name : (& str)] [comdat : bool]) : i64
  (for [i (iterator.range 0 (layout.compiler-object-layout-u16-at obj 2))]
    (let
      [at (+ 20 (* i 40))]
      (when
        (and
          (string.is-string-prefix-at obj name at)
          (=
            comdat
            (!=
              0
              (bit-and
                0x1000
                (layout.compiler-object-layout-u32-at obj (+ at 36))))))
        (return at))))
  (io.panic "missing COFF section"))

(test
  windows-assembler-unwind-and-associations
  (let
    [obj
      (assemble
        ".section .text,\"xr\",one_only,entry
.globl entry
.seh_proc entry
entry:
pushq %r12
.seh_pushreg %r12
subq $655360, %rsp
.seh_stackalloc 655360
movq %rbx, 524288(%rsp)
.seh_savereg %rbx, 524288
movdqu %xmm14, 1048576(%rsp)
.seh_savexmm %xmm14, 1048576
leaq 48(%rsp), %rbp
.seh_setframe %rbp,48
.seh_endprologue
ret
.seh_endproc
.text
.seh_proc g
g:
push %rdi
.seh_pushreg %rdi
subq $136, %rsp
.seh_stackalloc 136
.seh_endprologue
ret
.seh_endproc
.seh_proc h
h:
.seh_endprologue
ret
.seh_endproc
")]
    [comdat (header (& obj) ".text" true)]
    [xdata (header (& obj) ".xdata" true)]
    [pdata (header (& obj) ".pdata" true)]
    [x (layout.compiler-object-layout-u32-at (& obj) (+ xdata 20))]
    [symtab (layout.compiler-object-layout-u32-at (& obj) 8)]
    [base-pdata (header (& obj) ".pdata" false)]
    [p (layout.compiler-object-layout-u32-at (& obj) (+ base-pdata 20))]
    ;; LLVM MC's complete UNWIND_INFO, including operand words and padding.
    [expected : (Array i64 7)
      (array
        0x350b2001
        0xe91b0320
        0x00100000
        0x00003511
        0x11090008
        0x000a0000
        0x0000c002)]
    (for [i (iterator.range 0 7)]
      (test.assert-i64-eq
        (layout.compiler-object-layout-u32-at (& obj) (+ x (* 4 i)))
        (array-ref expected i)
        "unwind bytes"))
    (test.assert-i64-eq
      (layout.compiler-object-layout-u32-at (& obj) (+ base-pdata 16))
      24
      "two runtime functions")
    (test.assert-i64-eq
      (layout.compiler-object-layout-u32-at (& obj) (+ p 12))
      9
      "second begin")
    (test.assert-i64-eq
      (layout.compiler-object-layout-u32-at (& obj) (+ p 16))
      10
      "second end")
    (test.assert-i64-eq
      (layout.compiler-object-layout-u32-at (& obj) (+ p 20))
      12
      "second unwind offset")
    (for [j (iterator.range 0 2)]
      (let
        [name : String
          (if (= j 0)
            ".xdata"
            ".pdata")]
        [number
          (+
            1
            (/
              (-
                (if (= j 0)
                  xdata
                  pdata)
                20)
              40))]
        [i : i64 0]
        [found false]
        (while (< i (layout.compiler-object-layout-u32-at (& obj) 12))
          (let
            [row (+ symtab (* 18 i))]
            [aux (layout.compiler-object-layout-u8-at (& obj) (+ row 17))]
            (when
              (and
                (= aux 1)
                (=
                  (layout.compiler-object-layout-u16-at (& obj) (+ row 12))
                  number)
                (string.is-string-prefix-at (& obj) (& name) row))
              (test.assert-i64-eq
                (layout.compiler-object-layout-u8-at (& obj) (+ row 32))
                5
                "associative")
              (test.assert-i64-eq
                (layout.compiler-object-layout-u16-at (& obj) (+ row 30))
                (+ 1 (/ (- comdat 20) 40))
                "parent code section")
              (set! found true))
            (+= i (+ aux 1))))
        (test.assert-true found "section definition")))))

(test
  windows-assembler-inline-relocation-addends
  (let
    [obj
      (assemble
        ".text\ncmpl $1, ext(%rip)\ncmpl $257, ext+32(%rip)\ncall ext\n.data\n.long ext - .\n.long ext+6\n.rva ext+10\n.quad ext-4\n")]
    [text (header (& obj) ".text" false)]
    [data (header (& obj) ".data" false)]
    [bytes (layout.compiler-object-layout-u32-at (& obj) (+ text 20))]
    [d (layout.compiler-object-layout-u32-at (& obj) (+ data 20))]
    [r (layout.compiler-object-layout-u32-at (& obj) (+ data 24))]
    [types : (Array i64 4) (array 4 2 3 1)]
    [addends : (Array i64 4) (array 4 6 10 0xfffffffc)]
    (test.assert-i64-eq
      (layout.compiler-object-layout-u32-at (& obj) (+ bytes 2))
      0xffffffff
      "one trailing byte")
    (test.assert-i64-eq
      (layout.compiler-object-layout-u32-at (& obj) (+ bytes 9))
      28
      "four trailing bytes")
    (for [i (iterator.range 0 4)]
      (test.assert-i64-eq
        (layout.compiler-object-layout-u32-at (& obj) (+ d (* 4 i)))
        (array-ref addends i)
        "inline addend")
      (test.assert-i64-eq
        (layout.compiler-object-layout-u16-at (& obj) (+ r (+ 8 (* 10 i))))
        (array-ref types i)
        "COFF relocation type"))))

(test
  windows-assembler-malformed-directives
  (test.assert-true (rejected? ".seh_pushreg %rbp\n") "missing procedure")
  (test.assert-true (rejected? ".seh_proc a\na: ret\n") "unclosed procedure")
  (test.assert-true
    (rejected? ".seh_proc a\na: nop\n.seh_stackalloc 7\n.seh_endproc\n")
    "misaligned allocation")
  (test.assert-true
    (rejected? ".seh_proc a\na: .space 256\n.seh_endprologue\n.seh_endproc\n")
    "overlong prologue")
  (test.assert-true
    (rejected? ".section .pdata,\"dr\",associative,missing\n")
    "missing parent")
  (test.assert-true (rejected? ".data\n.rva 42\n") "RVA requires symbol")
  (test.assert-true
    (rejected? ".cv_loc 0 1 9 0\n")
    "unknown CodeView function and file"))