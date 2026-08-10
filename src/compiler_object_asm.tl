;; compiler_object_asm.tl - Render a structured x86-64 object image as GNU
;; assembly. This is a cheap side-artifact path for direct object emission: it
;; preserves the already-selected instruction bytes and relocatable operations
;; without running lowering, optimization, or instruction selection again.
(import stdlib.byte_buf_core)
(import stdlib.string)
(import compiler_object as cobj)
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
  (begin
    (compiler-object-asm-append! out "0x")
    (compiler-object-asm-push-char!
      out
      (string.string-ref
        compiler-object-asm-hex-digits
        (bit-and (shr value 4) 15)))
    (compiler-object-asm-push-char!
      out
      (string.string-ref compiler-object-asm-hex-digits (bit-and value 15)))))

(define (compiler-object-asm-append-bytes!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [bytes : String]) : unit
  (let
    [count : i64 (string.string-length bytes)]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [line-count : i64
            (if (< (- count index) 16)
              (- count index)
              16)]
          [line-index : i64 0]
          (begin
            (compiler-object-asm-append! out "    .byte ")
            (while (< line-index line-count)
              (begin
                (if (> line-index 0)
                  (compiler-object-asm-push-char! out ',')
                  unit)
                (compiler-object-asm-append-hex-byte!
                  out
                  (bit-and
                    (cast (string.string-ref bytes (+ index line-index)) : i64)
                    255))
                (set! line-index (+ line-index 1))))
            (compiler-object-asm-push-char! out '\n')
            (set! index (+ index line-count)))))
      unit)))

(define (compiler-object-asm-append-label!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [label : String]) : unit
  (begin
    (compiler-object-asm-append! out label)
    (compiler-object-asm-append! out ":\n")))

(define (compiler-object-asm-append-rip-instr!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [prefix : String]
  [target : String]
  [suffix : String]) : unit
  (begin
    (compiler-object-asm-append! out prefix)
    (compiler-object-asm-append! out target)
    (compiler-object-asm-append! out suffix)))

(define (compiler-object-asm-render-instr!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [instr : cobj.CompilerObjectX64Instr]) : bool
  (match instr
    [(cobj.CompilerObjectX64Instr.Label label)
      (begin
        (compiler-object-asm-append-label! out label)
        true)]
    [(cobj.CompilerObjectX64Instr.Call target)
      (begin
        (compiler-object-asm-append-rip-instr! out "    call " target "\n")
        true)]
    [(cobj.CompilerObjectX64Instr.TailCall target)
      (begin
        (compiler-object-asm-append-rip-instr! out "    jmp " target "\n")
        true)]
    [(cobj.CompilerObjectX64Instr.Jump target)
      (begin
        (compiler-object-asm-append-rip-instr! out "    jmp " target "\n")
        true)]
    [(cobj.CompilerObjectX64Instr.Ja target)
      (begin
        (compiler-object-asm-append-rip-instr! out "    ja " target "\n")
        true)]
    [(cobj.CompilerObjectX64Instr.Branch true-target false-target)
      (begin
        (compiler-object-asm-append! out "    testq %rax, %rax\n    jne ")
        (compiler-object-asm-append! out true-target)
        (compiler-object-asm-append! out "\n    jmp ")
        (compiler-object-asm-append! out false-target)
        (compiler-object-asm-push-char! out '\n')
        true)]
    [(cobj.CompilerObjectX64Instr.LoadRip target)
      (begin
        (compiler-object-asm-append-rip-instr!
          out
          "    movq "
          target
          "(%rip), %rax\n")
        true)]
    [(cobj.CompilerObjectX64Instr.LoadRipAddress target)
      (begin
        (compiler-object-asm-append-rip-instr!
          out
          "    leaq "
          target
          "(%rip), %rax\n")
        true)]
    [(cobj.CompilerObjectX64Instr.LoadRipAddressR11 target)
      (begin
        (compiler-object-asm-append-rip-instr!
          out
          "    leaq "
          target
          "(%rip), %r11\n")
        true)]
    [(cobj.CompilerObjectX64Instr.StoreRip target)
      (begin
        (compiler-object-asm-append-rip-instr!
          out
          "    movq %rax, "
          target
          "(%rip)\n")
        true)]
    [(cobj.CompilerObjectX64Instr.SubRspImm8 immediate)
      (begin
        (compiler-object-asm-append! out "    subq $")
        (compiler-object-asm-append-int! out immediate)
        (compiler-object-asm-append! out ", %rsp\n")
        true)]
    [(cobj.CompilerObjectX64Instr.MovRcxRip target)
      (begin
        (compiler-object-asm-append-rip-instr!
          out
          "    movq "
          target
          "(%rip), %rcx\n")
        true)]
    [(cobj.CompilerObjectX64Instr.MovRdxRip target)
      (begin
        (compiler-object-asm-append-rip-instr!
          out
          "    movq "
          target
          "(%rip), %rdx\n")
        true)]
    [(cobj.CompilerObjectX64Instr.LoadRipAddressRdx target)
      (begin
        (compiler-object-asm-append-rip-instr!
          out
          "    leaq "
          target
          "(%rip), %rdx\n")
        true)]
    [(cobj.CompilerObjectX64Instr.StoreR14Rip target)
      (begin
        (compiler-object-asm-append-rip-instr!
          out
          "    movq %r14, "
          target
          "(%rip)\n")
        true)]
    [(cobj.CompilerObjectX64Instr.StoreR15Rip target)
      (begin
        (compiler-object-asm-append-rip-instr!
          out
          "    movq %r15, "
          target
          "(%rip)\n")
        true)]
    [(cobj.CompilerObjectX64Instr.AddRcxRip target)
      (begin
        (compiler-object-asm-append-rip-instr!
          out
          "    addq %rcx, "
          target
          "(%rip)\n")
        true)]
    [(cobj.CompilerObjectX64Instr.MovRcxRax)
      (begin
        (compiler-object-asm-append! out "    movq %rax, %rcx\n")
        true)]
    [(cobj.CompilerObjectX64Instr.XorpdRip target)
      (begin
        (compiler-object-asm-append-rip-instr!
          out
          "    xorpd "
          target
          "(%rip), %xmm0\n")
        true)]
    [(cobj.CompilerObjectX64Instr.Bytes bytes)
      (begin
        (compiler-object-asm-append-bytes! out bytes)
        true)]
    [(cobj.CompilerObjectX64Instr.Raw _) false]))

(define (compiler-object-asm-render-instrs!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [instrs : cobj.CompilerObjectX64InstrList]) : bool
  (let
    [count : i64 (cobj.compiler-object-instr-list-count instrs)]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (begin
          (set!
            ok
            (compiler-object-asm-render-instr!
              out
              (cobj.compiler-object-instr-list-ref instrs index)))
          (set! index (+ index 1))))
      ok)))

(define (compiler-object-asm-render-data-record!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [record : cobj.CompilerObjectDataRecord]) : unit
  (match record
    [(cobj.CompilerObjectDataRecord.Label label)
      (compiler-object-asm-append-label! out label)]
    [(cobj.CompilerObjectDataRecord.Align alignment)
      (begin
        (compiler-object-asm-append! out "    .balign ")
        (compiler-object-asm-append-int! out alignment)
        (compiler-object-asm-push-char! out '\n'))]
    [(cobj.CompilerObjectDataRecord.Bytes bytes)
      (compiler-object-asm-append-bytes! out bytes)]
    [(cobj.CompilerObjectDataRecord.String text)
      (compiler-object-asm-append-bytes! out text)]
    [(cobj.CompilerObjectDataRecord.F64 bits)
      (begin
        (compiler-object-asm-append! out "    .quad ")
        (compiler-object-asm-append-int! out (cast bits : i64))
        (compiler-object-asm-push-char! out '\n'))]
    [(cobj.CompilerObjectDataRecord.F32 bits)
      (begin
        (compiler-object-asm-append! out "    .long ")
        (compiler-object-asm-append-int! out (cast bits : i64))
        (compiler-object-asm-push-char! out '\n'))]
    [(cobj.CompilerObjectDataRecord.I64 value)
      (begin
        (compiler-object-asm-append! out "    .quad ")
        (compiler-object-asm-append-int! out value)
        (compiler-object-asm-push-char! out '\n'))]
    [(cobj.CompilerObjectDataRecord.Zero count)
      (begin
        (compiler-object-asm-append! out "    .zero ")
        (compiler-object-asm-append-int! out count)
        (compiler-object-asm-push-char! out '\n'))]
    [(cobj.CompilerObjectDataRecord.SymbolAddress target)
      (begin
        (compiler-object-asm-append! out "    .quad ")
        (compiler-object-asm-append! out target)
        (compiler-object-asm-push-char! out '\n'))]
    [(cobj.CompilerObjectDataRecord.SymbolRva32 target)
      (begin
        (compiler-object-asm-append! out "    .rva ")
        (compiler-object-asm-append! out target)
        (compiler-object-asm-push-char! out '\n'))]))

(define (compiler-object-asm-render-data-records!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [records : cobj.CompilerObjectDataRecordList]) : unit
  (let
    [count : i64 (cobj.compiler-object-data-record-list-count records)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (compiler-object-asm-render-data-record!
            out
            (cobj.compiler-object-data-record-list-ref records index))
          (set! index (+ index 1))))
      unit)))

(define (compiler-object-asm-section-header
  [kind : cobj.CompilerObjectSectionKind]) : String
  (match kind
    [(cobj.CompilerObjectSectionKind.Text) ".text\n    .balign 16\n"]
    [(cobj.CompilerObjectSectionKind.Data) ".data\n    .balign 8\n"]
    [(cobj.CompilerObjectSectionKind.Rodata)
      ".section .rdata,\"dr\"\n    .balign 8\n"]
    [(cobj.CompilerObjectSectionKind.Bss) ".bss\n    .balign 8\n"]
    [(cobj.CompilerObjectSectionKind.Pdata)
      ".section .pdata,\"dr\"\n    .balign 8\n"]
    [(cobj.CompilerObjectSectionKind.Xdata)
      ".section .xdata,\"dr\"\n    .balign 8\n"]
    [(cobj.CompilerObjectSectionKind.Rsrc)
      ".section .rsrc,\"dr\"\n    .balign 8\n"]))

(define (compiler-object-asm-render-symbols!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [symbols : cobj.CompilerObjectSymbolList]) : unit
  (let
    [count : i64 (cobj.compiler-object-symbol-list-count symbols)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (match (cobj.compiler-object-symbol-list-ref symbols index)
            [(cobj.CompilerObjectSymbol.Symbol name binding _ _)
              (match binding
                [(cobj.CompilerObjectSymbolBinding.Export)
                  (begin
                    (compiler-object-asm-append! out ".globl ")
                    (compiler-object-asm-append! out name)
                    (compiler-object-asm-push-char! out '\n'))]
                [_ unit])])
          (set! index (+ index 1))))
      (compiler-object-asm-push-char! out '\n'))))

(define (compiler-object-asm-render-sections!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [sections : cobj.CompilerObjectSectionList]) : bool
  (let
    [count : i64 (cobj.compiler-object-section-list-count sections)]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (begin
          (match (cobj.compiler-object-section-list-ref sections index)
            [(cobj.CompilerObjectSection.Section kind records instrs)
              (begin
                (compiler-object-asm-append!
                  out
                  (compiler-object-asm-section-header kind))
                (compiler-object-asm-render-data-records! out records)
                (set! ok (compiler-object-asm-render-instrs! out instrs))
                (compiler-object-asm-push-char! out '\n'))])
          (set! index (+ index 1))))
      ok)))

(define (compiler-object-asm-render [image : cobj.CompilerObjectImage]) : ResultCompilerObjectAsm
  (let
    [out : byte_buf_core.ByteBufBuilder
      (byte_buf_core.byte-buf-builder-with-capacity 65536)]
    (begin
      (compiler-object-asm-render-symbols! (&mut out) image.symbols)
      (if (compiler-object-asm-render-sections! (&mut out) image.sections)
        (ResultCompilerObjectAsm.Ok
          (byte_buf_core.byte-buf-builder-finish-string (& out)))
        (ResultCompilerObjectAsm.Err
          "structured assembly rendering does not support raw instructions")))))

(cfg
  test
  (test
    compiler-object-asm-render-smoke
    (let
      [text-instrs : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          (cobj.compiler-object-instr-builder-push
            (cobj.compiler-object-instr-builder-with-capacity 2)
            (cobj.CompilerObjectX64Instr.Label "_tl_start"))
          (cobj.CompilerObjectX64Instr.Call "ExitProcess"))]
      [data-records : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          (cobj.compiler-object-data-record-builder-push
            (cobj.compiler-object-data-record-builder-with-capacity 2)
            (cobj.CompilerObjectDataRecord.Label "_tl_answer"))
          (cobj.CompilerObjectDataRecord.I64 42))]
      [sections : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          (cobj.compiler-object-section-builder-push
            (cobj.compiler-object-section-builder-with-capacity 2)
            (cobj.CompilerObjectSection.Section
              (cobj.CompilerObjectSectionKind.Text)
              (cobj.compiler-object-data-record-builder-finish
                (cobj.compiler-object-data-record-builder-with-capacity 1))
              (cobj.compiler-object-instr-builder-finish text-instrs)))
          (cobj.CompilerObjectSection.Section
            (cobj.CompilerObjectSectionKind.Data)
            (cobj.compiler-object-data-record-builder-finish data-records)
            (cobj.compiler-object-instr-builder-finish
              (cobj.compiler-object-instr-builder-with-capacity 1))))]
      [symbols : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          (cobj.compiler-object-symbol-builder-with-capacity 1)
          (cobj.CompilerObjectSymbol.Symbol
            "_tl_start"
            (cobj.CompilerObjectSymbolBinding.Export)
            (cobj.CompilerObjectSymbolKind.Function)
            (cobj.CompilerObjectMaybeSection.Some
              (cobj.CompilerObjectSectionKind.Text))))]
      [image : cobj.CompilerObjectImage
        (cobj.CompilerObjectImage
          (cobj.compiler-object-section-builder-finish sections)
          (cobj.compiler-object-symbol-builder-finish symbols)
          (cobj.compiler-object-relocation-builder-finish
            (cobj.compiler-object-relocation-builder-with-capacity 1)))]
      (match (compiler-object-asm-render image)
        [(ResultCompilerObjectAsm.Err message) (test.assert-true false message)]
        [(ResultCompilerObjectAsm.Ok asm)
          (let
            [export-needle : String ".globl _tl_start\n"]
            [call-needle : String "    call ExitProcess\n"]
            [data-needle : String "    .quad 42\n"]
            (begin
              (test.assert-true
                (string.contains (& asm) (& export-needle))
                "structured assembly preserves exported symbols")
              (test.assert-true
                (string.contains (& asm) (& call-needle))
                "structured assembly preserves relocatable calls")
              (test.assert-true
                (string.contains (& asm) (& data-needle))
                "structured assembly preserves data records")))]))))