;; compiler_object_asm.tl - Render a structured x86-64 object image as GNU
;; assembly. This is a cheap side-artifact path for direct object emission: it
;; preserves the already-selected instruction bytes and relocatable operations
;; without running lowering, optimization, or instruction selection again.
(import compiler_object_layout as layout)
(cfg test (import compiler_object_windows_sections as coff_sections))
(import stdlib.iterator)
(import stdlib.byte_buf_core)
(import stdlib.string)
(import compiler_object as cobj)
(import compiler_machine_x64 as mx)
(cfg test (import stdlib.test))

(defenum ResultCompilerObjectAsm
  (Ok String)
  (Err String))

(define compiler-object-asm-hex-digits : String
  "0123456789abcdef")

(define (compiler-object-asm-append!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [text : String]) : unit
  (byte_buf_core.byte-buf-builder-append-string out text))

(define (compiler-object-asm-append-int!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (compiler-object-asm-append! out (string.int->string value)))

(define (compiler-object-asm-push-char!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : char]) : unit
  (byte_buf_core.byte-buf-builder-push out (cast value : u8)))

(define (compiler-object-asm-append-hex-byte!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (compiler-object-asm-append! out "0x")
  (compiler-object-asm-push-char!
    out
    (string.string-ref
      compiler-object-asm-hex-digits
      (bit-and (shr value 4) 15)))
  (compiler-object-asm-push-char!
    out
    (string.string-ref compiler-object-asm-hex-digits (bit-and value 15))))

(define (compiler-object-asm-append-bytes!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [bytes : String]) : unit
  (let
    [count : i64 (string.string-length bytes)]
    [index : i64 0]
    (while (< index count)
      (let
        [line-count : i64
          (if (< (- count index) 16)
            (- count index)
            16)]
        (compiler-object-asm-append! out "    .byte ")
        (for [line-index (iterator.range 0 line-count)]
          (if (> line-index 0)
            (compiler-object-asm-push-char! out ',')
            unit)
          (compiler-object-asm-append-hex-byte!
            out
            (bit-and
              (cast (string.string-ref bytes (+ index line-index)) : i64)
              255)))
        (compiler-object-asm-push-char! out '\n')
        (+= index line-count)))
    unit))

(define (compiler-object-asm-append-label!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [label : String]) : unit
  (compiler-object-asm-append! out label)
  (compiler-object-asm-append! out ":\n"))

(define (compiler-object-asm-append-rip-instr!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [prefix : String]
  [target : String]
  [suffix : String]) : unit
  (compiler-object-asm-append! out prefix)
  (compiler-object-asm-append! out target)
  (compiler-object-asm-append! out suffix))

;; `    j<cc> ` for an x86 condition code.
(define (compiler-object-asm-jcc-mnemonic [cc : i64]) : String
  (cond
    [(= cc 0x0) "    jo "]
    [(= cc 0x1) "    jno "]
    [(= cc 0x2) "    jb "]
    [(= cc 0x3) "    jae "]
    [(= cc 0x4) "    je "]
    [(= cc 0x5) "    jne "]
    [(= cc 0x6) "    jbe "]
    [(= cc 0x7) "    ja "]
    [(= cc 0x8) "    js "]
    [(= cc 0x9) "    jns "]
    [(= cc 0xa) "    jp "]
    [(= cc 0xb) "    jnp "]
    [(= cc 0xc) "    jl "]
    [(= cc 0xd) "    jge "]
    [(= cc 0xe) "    jle "]
    [else "    jg "]))

(define (compiler-object-asm-render-instr!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [instr : cobj.CompilerObjectX64Instr]) : bool
  (match instr
    [(Label label)
      (compiler-object-asm-append-label! out label)
      true]
    [(Call target)
      (compiler-object-asm-append-rip-instr! out "    call " target "\n")
      true]
    [(TailCall target)
      (compiler-object-asm-append-rip-instr! out "    jmp " target "\n")
      true]
    [(Jump target)
      (compiler-object-asm-append-rip-instr! out "    jmp " target "\n")
      true]
    [(Ja target)
      (compiler-object-asm-append-rip-instr! out "    ja " target "\n")
      true]
    [(Jcc cc target)
      (if (cobj.compiler-object-condition-code-valid? cc)
        (begin
          (compiler-object-asm-append-rip-instr!
            out
            (compiler-object-asm-jcc-mnemonic cc)
            target
            "\n")
          true)
        false)]
    [(Branch true-target false-target)
      (compiler-object-asm-append! out "    testq %rax, %rax\n    jne ")
      (compiler-object-asm-append! out true-target)
      (compiler-object-asm-append! out "\n    jmp ")
      (compiler-object-asm-append! out false-target)
      (compiler-object-asm-push-char! out '\n')
      true]
    [(LoadRip target)
      (compiler-object-asm-append-rip-instr!
        out
        "    movq "
        target
        "(%rip), %rax\n")
      true]
    [(LoadRipAddress target)
      (compiler-object-asm-append-rip-instr!
        out
        "    leaq "
        target
        "(%rip), %rax\n")
      true]
    [(LoadAbsAddress target)
      (compiler-object-asm-append-rip-instr! out "    movl $" target ", %eax\n")
      true]
    [(LoadRipAddressR11 target)
      (compiler-object-asm-append-rip-instr!
        out
        "    leaq "
        target
        "(%rip), %r11\n")
      true]
    [(StoreRip target)
      (compiler-object-asm-append-rip-instr!
        out
        "    movq %rax, "
        target
        "(%rip)\n")
      true]
    [(SubRspImm8 immediate)
      (compiler-object-asm-append! out "    subq $")
      (compiler-object-asm-append-int! out immediate)
      (compiler-object-asm-append! out ", %rsp\n")
      true]
    [(MovRcxRip target)
      (compiler-object-asm-append-rip-instr!
        out
        "    movq "
        target
        "(%rip), %rcx\n")
      true]
    [(MovRdxRip target)
      (compiler-object-asm-append-rip-instr!
        out
        "    movq "
        target
        "(%rip), %rdx\n")
      true]
    [(LoadRipAddressRdx target)
      (compiler-object-asm-append-rip-instr!
        out
        "    leaq "
        target
        "(%rip), %rdx\n")
      true]
    [(StoreR14Rip target)
      (compiler-object-asm-append-rip-instr!
        out
        "    movq %r14, "
        target
        "(%rip)\n")
      true]
    [(StoreR15Rip target)
      (compiler-object-asm-append-rip-instr!
        out
        "    movq %r15, "
        target
        "(%rip)\n")
      true]
    [(AddRcxRip target)
      (compiler-object-asm-append-rip-instr!
        out
        "    addq %rcx, "
        target
        "(%rip)\n")
      true]
    [(MovRcxRax)
      (compiler-object-asm-append! out "    movq %rax, %rcx\n")
      true]
    [(XorpdRip target)
      (compiler-object-asm-append-rip-instr!
        out
        "    xorpd "
        target
        "(%rip), %xmm0\n")
      true]
    [(Machine instr)
      (compiler-object-asm-append! out (mx.compiler-machine-x64-asm-line instr))
      true]
    [(Bytes bytes)
      (compiler-object-asm-append-bytes! out bytes)
      true]
    [(Raw _) false]))

(define (compiler-object-asm-render-instrs!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [instrs : cobj.CompilerObjectX64InstrList]) : bool
  (let
    [count : i64 (cobj.compiler-object-instr-list-count instrs)]
    [index : i64 0]
    [ok : bool true]
    (while (and ok (< index count))
      (set!
        ok
        (compiler-object-asm-render-instr!
          out
          (cobj.compiler-object-instr-list-ref instrs index)))
      (+= index 1))
    ok))

(define (compiler-object-asm-render-data-record!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [record : cobj.CompilerObjectDataRecord]) : unit
  (match record
    [(Label label) (compiler-object-asm-append-label! out label)]
    [(Align alignment)
      (compiler-object-asm-append! out "    .balign ")
      (compiler-object-asm-append-int! out alignment)
      (compiler-object-asm-push-char! out '\n')]
    [(Bytes bytes) (compiler-object-asm-append-bytes! out bytes)]
    [(String text)
      (compiler-object-asm-append-bytes! out text)
      (compiler-object-asm-append! out "    .byte 0\n")]
    [(F64 bits)
      (compiler-object-asm-append! out "    .quad ")
      (compiler-object-asm-append-int! out (cast bits : i64))
      (compiler-object-asm-push-char! out '\n')]
    [(F32 bits)
      (compiler-object-asm-append! out "    .long ")
      (compiler-object-asm-append-int! out (cast bits : i64))
      (compiler-object-asm-push-char! out '\n')]
    [(I64 value)
      (compiler-object-asm-append! out "    .quad ")
      (compiler-object-asm-append-int! out value)
      (compiler-object-asm-push-char! out '\n')]
    [(Zero count)
      (compiler-object-asm-append! out "    .zero ")
      (compiler-object-asm-append-int! out count)
      (compiler-object-asm-push-char! out '\n')]
    [(SymbolAddress target)
      (compiler-object-asm-append! out "    .quad ")
      (compiler-object-asm-append! out target)
      (compiler-object-asm-push-char! out '\n')]
    [(SymbolRva32 target)
      (compiler-object-asm-append! out "    .rva ")
      (compiler-object-asm-append! out target)
      (compiler-object-asm-push-char! out '\n')]))

(define (compiler-object-asm-render-data-records!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [records : (& cobj.CompilerObjectDataRecordList)]) : unit
  (let
    [count : i64 (cobj.compiler-object-data-record-list-count records)]
    (for [index (iterator.range 0 count)]
      (compiler-object-asm-render-data-record!
        out
        (cobj.compiler-object-data-record-list-ref records index)))
    unit))

(define (compiler-object-asm-section-header!
  [out : (&mut byte_buf_core.ByteBufBuilder)]
  [spec : (& cobj.CompilerObjectSectionSpec)]) : unit
  (if (match spec.format
    [(Elf ty flags)
      (or
        (and (= ty 1) (= flags 6) (string.eq spec.name ".text"))
        (and (= ty 1) (= flags 3) (string.eq spec.name ".data"))
        (and (= ty 8) (= flags 3) (string.eq spec.name ".bss")))]
    [(Coff flags)
      (or
        (and (= flags 0x60000020) (string.eq spec.name ".text"))
        (and (= flags 0xc0000040) (string.eq spec.name ".data"))
        (and (= flags 0xc0000080) (string.eq spec.name ".bss")))])
    (compiler-object-asm-append! out (string.copy spec.name))
    (begin
      (compiler-object-asm-append! out ".section ")
      (compiler-object-asm-append! out (string.copy spec.name))
      (compiler-object-asm-append! out ",\"")
      (match spec.format
        [(Elf ty flags)
          (when (!= (bit-and flags 2) 0) (compiler-object-asm-append! out "a"))
          (when (!= (bit-and flags 1) 0) (compiler-object-asm-append! out "w"))
          (when (!= (bit-and flags 4) 0) (compiler-object-asm-append! out "x"))
          (compiler-object-asm-append!
            out
            (if (= ty 8)
              "\",@nobits"
              "\",@progbits"))]
        [(Coff flags)
          (compiler-object-asm-append!
            out
            (match (bit-and flags 0xe0)
              [32 "x"]
              [128 "b"]
              [_ "d"]))
          (compiler-object-asm-append!
            out
            (if (!= (bit-and flags 0x80000000) 0)
              "w"
              "r"))
          (compiler-object-asm-append!
            out
            (if (!= (bit-and flags 0x02000000) 0)
              "D\""
              "\""))])))
  (compiler-object-asm-append! out "\n    .balign ")
  (compiler-object-asm-append-int! out spec.align)
  (compiler-object-asm-append! out "\n"))

(define (compiler-object-asm-render-symbols!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [symbols : cobj.CompilerObjectSymbolList]) : unit
  (let
    [count : i64 (cobj.compiler-object-symbol-list-count symbols)]
    (for [index (iterator.range 0 count)]
      (match (cobj.compiler-object-symbol-list-ref symbols index)
        [(Symbol name binding _ _)
          (match binding
            [(Export)
              (compiler-object-asm-append! out ".globl ")
              (compiler-object-asm-append! out name)
              (compiler-object-asm-push-char! out '\n')]
            [_ unit])]))
    (compiler-object-asm-push-char! out '\n')))

(define (compiler-object-asm-render-sections!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [sections : cobj.CompilerObjectSectionList]) : bool
  (let
    [count : i64 (cobj.compiler-object-section-list-count sections)]
    [index : i64 0]
    [ok : bool true]
    (while (and ok (< index count))
      (match (cobj.compiler-object-section-list-ref sections index)
        [(Section kind records instrs)
          (compiler-object-asm-section-header! out (& kind))
          (compiler-object-asm-render-data-records! out (& records))
          (match kind.storage
            [(ZeroFill size)
              (let
                [tail : i64
                  (-
                    size
                    (layout.compiler-object-layout-data-records-size
                      (& records)))]
                (when
                  (> tail 0)
                  (compiler-object-asm-render-data-record! out (Zero tail))))]
            [_ unit])
          (set! ok (compiler-object-asm-render-instrs! out instrs))
          (compiler-object-asm-push-char! out '\n')])
      (+= index 1))
    ok))

(define (compiler-object-asm-render [image : cobj.CompilerObjectImage]) : ResultCompilerObjectAsm
  (let
    [coff? : bool
      (and
        (> image.sections.len 0)
        (match (& (array-ref image.sections.slots 0))
          [(Section spec _ _)
            (match spec.format
              [(Coff _) true]
              [_ false])]))]
    [error : String (layout.compiler-object-layout-image-error (& image) coff?)]
    (unless (string.eq (& error) "") (return (Err error))))
  (let
    [out : byte_buf_core.ByteBufBuilder
      (byte_buf_core.byte-buf-builder-with-capacity 65536)]
    (compiler-object-asm-render-symbols! (&mut out) image.symbols)
    (if (compiler-object-asm-render-sections! (&mut out) image.sections)
      (Ok (byte_buf_core.byte-buf-builder-finish-string (& out)))
      (Err
        "structured assembly rendering requires supported instructions and condition codes"))))

(cfg
  test
  (define (compiler-object-asm-interior-nul-string) : String
    (let
      [out : byte_buf_core.ByteBufBuilder
        (byte_buf_core.byte-buf-builder-with-capacity 3)]
      (byte_buf_core.byte-buf-builder-push (&mut out) 0x61)
      (byte_buf_core.byte-buf-builder-push (&mut out) 0)
      (byte_buf_core.byte-buf-builder-push (&mut out) 0x62)
      (byte_buf_core.byte-buf-builder-finish-string (& out)))))

(cfg
  test
  (test
    compiler-object-asm-string-record-layout
    (let
      [out : byte_buf_core.ByteBufBuilder
        (byte_buf_core.byte-buf-builder-with-capacity 64)]
      [_empty : unit
        (compiler-object-asm-render-data-record! (&mut out) (String ""))]
      [_interior-nul : unit
        (compiler-object-asm-render-data-record!
          (&mut out)
          (String (compiler-object-asm-interior-nul-string)))]
      [rendered : String (byte_buf_core.byte-buf-builder-finish-string (& out))]
      (test.assert-true
        (string.eq
          rendered
          "    .byte 0\n    .byte 0x61,0x00,0x62\n    .byte 0\n")
        "structured assembly string records include one terminal zero"))))

(cfg
  test
  (test
    compiler-object-asm-render-smoke
    (let
      [text-instrs : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          (cobj.compiler-object-instr-builder-push
            (cobj.compiler-object-instr-builder-with-capacity 2)
            (Label "_tl_start"))
          (Call "ExitProcess"))]
      [data-records : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          (cobj.compiler-object-data-record-builder-push
            (cobj.compiler-object-data-record-builder-with-capacity 2)
            (Label "_tl_answer"))
          (I64 42))]
      [sections : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          (cobj.compiler-object-section-builder-push
            (cobj.compiler-object-section-builder-with-capacity 2)
            (coff_sections.windows-base-section
              (Text)
              (cobj.compiler-object-data-record-builder-finish
                (cobj.compiler-object-data-record-builder-with-capacity 1))
              (cobj.compiler-object-instr-builder-finish text-instrs)))
          (coff_sections.windows-base-section
            (Data)
            (cobj.compiler-object-data-record-builder-finish data-records)
            (cobj.compiler-object-instr-builder-finish
              (cobj.compiler-object-instr-builder-with-capacity 1))))]
      [symbols : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          (cobj.compiler-object-symbol-builder-with-capacity 1)
          (Symbol "_tl_start" (Export) (Function) (Some cobj.text-id)))]
      [image : cobj.CompilerObjectImage
        (cobj.CompilerObjectImage
          (cobj.compiler-object-section-builder-finish sections)
          (cobj.compiler-object-symbol-builder-finish symbols)
          (cobj.compiler-object-relocation-builder-finish
            (cobj.compiler-object-relocation-builder-with-capacity 1)))]
      (match (compiler-object-asm-render image)
        [(Err message) (test.assert-true false message)]
        [(Ok asm)
          (let
            [export-needle : String ".globl _tl_start\n"]
            [call-needle : String "    call ExitProcess\n"]
            [data-needle : String "    .quad 42\n"]
            (test.assert-true
              (string.contains (& asm) (& export-needle))
              "structured assembly preserves exported symbols")
            (test.assert-true
              (string.contains (& asm) (& call-needle))
              "structured assembly preserves relocatable calls")
            (test.assert-true
              (string.contains (& asm) (& data-needle))
              "structured assembly preserves data records"))]))))