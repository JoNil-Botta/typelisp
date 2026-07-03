;; compiler_object_elf.tl - ELF64 object-file serialization for object images.
(import stdlib.byte_buf_core)
(import stdlib.string)
(import "compiler_object.tl")

(define (compiler-object-elf-string-length [text : String]) : i64
  (cfg
    feature-compiler-private-string-intrinsics
    (__tl_string_length text)
    (string.string-length text)))

(define (compiler-object-elf-string-ref [text : String] [index : i64]) : char
  (cfg
    feature-compiler-private-string-intrinsics
    (__tl_string_ref text index)
    (string.string-ref text index)))

(defenum ResultCompilerObjectElf
  (Ok String)
  (Err String))

(define compiler-object-elf-header-size : i64
  64)
(define compiler-object-elf-section-header-size : i64
  64)
(define compiler-object-elf-symbol-size : i64
  24)
(define compiler-object-elf-relocation-size : i64
  24)
(define compiler-object-elf-section-null-index : i64
  0)
(define compiler-object-elf-section-text-index : i64
  1)
(define compiler-object-elf-section-data-index : i64
  2)
(define compiler-object-elf-section-rodata-index : i64
  3)
(define compiler-object-elf-section-bss-index : i64
  4)
(define compiler-object-elf-section-rela-text-index : i64
  5)
(define compiler-object-elf-section-rela-data-index : i64
  6)
(define compiler-object-elf-section-rela-rodata-index : i64
  7)
(define compiler-object-elf-section-rela-bss-index : i64
  8)
(define compiler-object-elf-section-symtab-index : i64
  9)
(define compiler-object-elf-section-strtab-index : i64
  10)
(define compiler-object-elf-section-shstrtab-index : i64
  11)
(define compiler-object-elf-section-note-gnu-stack-index : i64
  12)
(define compiler-object-elf-section-count : i64
  13)
(define compiler-object-elf-shstrtab-size : i64
  113)
(define compiler-object-elf-sht-null : i64
  0)
(define compiler-object-elf-sht-progbits : i64
  1)
(define compiler-object-elf-sht-symtab : i64
  2)
(define compiler-object-elf-sht-strtab : i64
  3)
(define compiler-object-elf-sht-rela : i64
  4)
(define compiler-object-elf-sht-nobits : i64
  8)
(define compiler-object-elf-shf-write : i64
  1)
(define compiler-object-elf-shf-alloc : i64
  2)
(define compiler-object-elf-shf-execinstr : i64
  4)
(define compiler-object-elf-r-x86-64-64 : i64
  1)
(define compiler-object-elf-r-x86-64-pc32 : i64
  2)
(define compiler-object-elf-r-x86-64-plt32 : i64
  4)

(define (compiler-object-elf-byte [value : i64]) : u8
  (cast (bit-and value 0xff) : u8))

(define (compiler-object-elf-push-u8!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (byte_buf_core.byte-buf-builder-push out (compiler-object-elf-byte value)))

(define (compiler-object-elf-push-u16!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (begin
    (compiler-object-elf-push-u8! out value)
    (compiler-object-elf-push-u8! out (shr value 8))))

(define (compiler-object-elf-push-u32!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (begin
    (compiler-object-elf-push-u8! out value)
    (compiler-object-elf-push-u8! out (shr value 8))
    (compiler-object-elf-push-u8! out (shr value 16))
    (compiler-object-elf-push-u8! out (shr value 24))))

(define (compiler-object-elf-push-u64!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : u64]) : unit
  (begin
    (compiler-object-elf-push-u32!
      out
      (cast (bit-and value (cast 0xffffffff : u64)) : i64))
    (compiler-object-elf-push-u32! out (cast (shr value 32) : i64))))

(define (compiler-object-elf-push-i64!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (compiler-object-elf-push-u64! out (cast value : u64)))

(define (compiler-object-elf-push-zeroes!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [count : i64]) : unit
  (let
    [i : i64 0]
    (begin
      (while (< i count)
        (begin
          (compiler-object-elf-push-u8! out 0)
          (set! i (+ i 1))))
      unit)))

(define (compiler-object-elf-push-string-bytes!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [text : String]) : unit
  (let
    [i : i64 0]
    [n : i64 (compiler-object-elf-string-length text)]
    (begin
      (while (< i n)
        (begin
          (byte_buf_core.byte-buf-builder-push
            out
            (cast (compiler-object-elf-string-ref text i) : u8))
          (set! i (+ i 1))))
      unit)))

(define (compiler-object-elf-align-offset [offset : i64] [align : i64]) : i64
  (if (<= align 1)
    offset
    (let
      [rem : i64 (% offset align)]
      (if (= rem 0)
        offset
        (+ offset (- align rem))))))

(define (compiler-object-elf-render-padding-to!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [offset : i64]) : unit
  (compiler-object-elf-push-zeroes! out (- offset (struct-get out len))))

(define (compiler-object-elf-data-record-end-offset
  [record : CompilerObjectDataRecord]
  [offset : i64]) : i64
  (match record
    [(CompilerObjectDataRecord.Label _) offset]
    [(CompilerObjectDataRecord.Align align)
      (compiler-object-elf-align-offset offset align)]
    [(CompilerObjectDataRecord.Bytes bytes)
      (+ offset (compiler-object-elf-string-length bytes))]
    [(CompilerObjectDataRecord.String text)
      (+ offset (+ (compiler-object-elf-string-length text) 1))]
    [(CompilerObjectDataRecord.F64 _) (+ offset 8)]
    [(CompilerObjectDataRecord.F32 _) (+ offset 4)]
    [(CompilerObjectDataRecord.I64 _) (+ offset 8)]
    [(CompilerObjectDataRecord.Zero count) (+ offset count)]
    [(CompilerObjectDataRecord.SymbolAddress _) (+ offset 8)]
    [(CompilerObjectDataRecord.SymbolRva32 _) (+ offset 4)]))

(define (compiler-object-elf-data-records-size-from
  [records : CompilerObjectDataRecordList]
  [offset : i64]) : i64
  (let
    [count : i64 (compiler-object-data-record-list-count records)]
    [index : i64 0]
    [cur-offset : i64 offset]
    (begin
      (while (< index count)
        (begin
          (set!
            cur-offset
            (compiler-object-elf-data-record-end-offset
              (compiler-object-data-record-list-ref records index)
              cur-offset))
          (set! index (+ index 1))))
      cur-offset)))

(define (compiler-object-elf-data-records-size
  [records : CompilerObjectDataRecordList]) : i64
  (compiler-object-elf-data-records-size-from records 0))

(define (compiler-object-elf-instr-size [instr : CompilerObjectX64Instr]) : i64
  (match instr
    [(CompilerObjectX64Instr.Label _) 0]
    [(CompilerObjectX64Instr.Call _) 5]
    [(CompilerObjectX64Instr.TailCall _) 5]
    [(CompilerObjectX64Instr.Jump _) 5]
    [(CompilerObjectX64Instr.Ja _) 6]
    [(CompilerObjectX64Instr.Branch _ _) 14]
    [(CompilerObjectX64Instr.LoadRip _) 7]
    [(CompilerObjectX64Instr.LoadRipAddress _) 7]
    [(CompilerObjectX64Instr.LoadRipAddressR11 _) 7]
    [(CompilerObjectX64Instr.StoreRip _) 7]
    [(CompilerObjectX64Instr.SubRspImm8 _) 4]
    [(CompilerObjectX64Instr.MovRcxRip _) 7]
    [(CompilerObjectX64Instr.MovRdxRip _) 7]
    [(CompilerObjectX64Instr.LoadRipAddressRdx _) 7]
    [(CompilerObjectX64Instr.StoreR14Rip _) 7]
    [(CompilerObjectX64Instr.StoreR15Rip _) 7]
    [(CompilerObjectX64Instr.AddRcxRip _) 7]
    [(CompilerObjectX64Instr.MovRcxRax) 3]
    [(CompilerObjectX64Instr.XorpdRip _) 8]
    [(CompilerObjectX64Instr.Bytes bytes)
      (compiler-object-elf-string-length bytes)]
    [(CompilerObjectX64Instr.Raw bytes)
      (compiler-object-elf-string-length bytes)]
    [_ 0]))

(define (compiler-object-elf-instr-relocation-count
  [instr : CompilerObjectX64Instr]) : i64
  (match instr
    [(CompilerObjectX64Instr.Label _) 0]
    [(CompilerObjectX64Instr.Call _) 1]
    [(CompilerObjectX64Instr.TailCall _) 1]
    [(CompilerObjectX64Instr.Jump _) 1]
    [(CompilerObjectX64Instr.Ja _) 1]
    [(CompilerObjectX64Instr.Branch _ _) 2]
    [(CompilerObjectX64Instr.LoadRip _) 1]
    [(CompilerObjectX64Instr.LoadRipAddress _) 1]
    [(CompilerObjectX64Instr.LoadRipAddressR11 _) 1]
    [(CompilerObjectX64Instr.StoreRip _) 1]
    [(CompilerObjectX64Instr.SubRspImm8 _) 0]
    [(CompilerObjectX64Instr.MovRcxRip _) 1]
    [(CompilerObjectX64Instr.MovRdxRip _) 1]
    [(CompilerObjectX64Instr.LoadRipAddressRdx _) 1]
    [(CompilerObjectX64Instr.StoreR14Rip _) 1]
    [(CompilerObjectX64Instr.StoreR15Rip _) 1]
    [(CompilerObjectX64Instr.AddRcxRip _) 1]
    [(CompilerObjectX64Instr.MovRcxRax) 0]
    [(CompilerObjectX64Instr.XorpdRip _) 1]
    [(CompilerObjectX64Instr.Bytes _) 0]
    [(CompilerObjectX64Instr.Raw _) 0]))

(define (compiler-object-elf-instrs-relocation-count
  [instrs : CompilerObjectX64InstrList]) : i64
  (let
    [count : i64 (compiler-object-instr-list-count instrs)]
    [index : i64 0]
    [total : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            total
            (+
              total
              (compiler-object-elf-instr-relocation-count
                (compiler-object-instr-list-ref instrs index))))
          (set! index (+ index 1))))
      total)))

(define (compiler-object-elf-instrs-size-from
  [instrs : CompilerObjectX64InstrList]
  [offset : i64]) : i64
  (let
    [count : i64 (compiler-object-instr-list-count instrs)]
    [index : i64 0]
    [cur-offset : i64 offset]
    (begin
      (while (< index count)
        (begin
          (set!
            cur-offset
            (+
              cur-offset
              (compiler-object-elf-instr-size
                (compiler-object-instr-list-ref instrs index))))
          (set! index (+ index 1))))
      cur-offset)))

(define (compiler-object-elf-instrs-size [instrs : CompilerObjectX64InstrList]) : i64
  (compiler-object-elf-instrs-size-from instrs 0))

(define (compiler-object-elf-section-virtual-size
  [image : CompilerObjectImage]
  [kind : CompilerObjectSectionKind]) : i64
  (match (compiler-object-section-list-find (struct-get image sections) kind)
    [(CompilerObjectSection.Section _ data instrs)
      (match kind
        [(CompilerObjectSectionKind.Text)
          (compiler-object-elf-instrs-size instrs)]
        [_ (compiler-object-elf-data-records-size data)])]))

(define (compiler-object-elf-section-raw-size
  [image : CompilerObjectImage]
  [kind : CompilerObjectSectionKind]) : i64
  (match kind
    [(CompilerObjectSectionKind.Bss) 0]
    [_ (compiler-object-elf-section-virtual-size image kind)]))

(define (compiler-object-elf-text-relocation-kind-supported?
  [kind : CompilerObjectRelocationKind]) : bool
  (match kind
    [(CompilerObjectRelocationKind.Call) true]
    [(CompilerObjectRelocationKind.TailCall) true]
    [(CompilerObjectRelocationKind.RipValue) true]
    [(CompilerObjectRelocationKind.RipAddress) true]
    [(CompilerObjectRelocationKind.Branch) true]
    [_ false]))

(define (compiler-object-elf-data-relocation-kind-supported?
  [kind : CompilerObjectRelocationKind]) : bool
  (match kind
    [(CompilerObjectRelocationKind.Abs64) true]
    [_ false]))

(define (compiler-object-elf-relocation-supported?
  [reloc : CompilerObjectRelocation]) : bool
  (match reloc
    [(CompilerObjectRelocation.Relocation section _ kind _)
      (match section
        [(CompilerObjectSectionKind.Text)
          (compiler-object-elf-text-relocation-kind-supported? kind)]
        [_ (compiler-object-elf-data-relocation-kind-supported? kind)])]))

(define (compiler-object-elf-relocation-list-supported?
  [relocs : CompilerObjectRelocationList]) : bool
  (let
    [count : i64 (compiler-object-relocation-list-count relocs)]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (if (compiler-object-elf-relocation-supported?
          (compiler-object-relocation-list-ref relocs index))
          (set! index (+ index 1))
          (set! ok false)))
      ok)))

(define (compiler-object-elf-instrs-supported?
  [instrs : CompilerObjectX64InstrList]) : bool
  (let
    [count : i64 (compiler-object-instr-list-count instrs)]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (match (compiler-object-instr-list-ref instrs index)
          [(CompilerObjectX64Instr.Label _) (set! index (+ index 1))]
          [(CompilerObjectX64Instr.Call _) (set! index (+ index 1))]
          [(CompilerObjectX64Instr.TailCall _) (set! index (+ index 1))]
          [(CompilerObjectX64Instr.Jump _) (set! index (+ index 1))]
          [(CompilerObjectX64Instr.Ja _) (set! index (+ index 1))]
          [(CompilerObjectX64Instr.Branch _ _) (set! index (+ index 1))]
          [(CompilerObjectX64Instr.LoadRip _) (set! index (+ index 1))]
          [(CompilerObjectX64Instr.LoadRipAddress _) (set! index (+ index 1))]
          [(CompilerObjectX64Instr.LoadRipAddressR11 _)
            (set! index (+ index 1))]
          [(CompilerObjectX64Instr.StoreRip _) (set! index (+ index 1))]
          [(CompilerObjectX64Instr.SubRspImm8 _) (set! index (+ index 1))]
          [(CompilerObjectX64Instr.MovRcxRip _) (set! index (+ index 1))]
          [(CompilerObjectX64Instr.MovRdxRip _) (set! index (+ index 1))]
          [(CompilerObjectX64Instr.LoadRipAddressRdx _)
            (set! index (+ index 1))]
          [(CompilerObjectX64Instr.StoreR14Rip _) (set! index (+ index 1))]
          [(CompilerObjectX64Instr.StoreR15Rip _) (set! index (+ index 1))]
          [(CompilerObjectX64Instr.AddRcxRip _) (set! index (+ index 1))]
          [(CompilerObjectX64Instr.MovRcxRax) (set! index (+ index 1))]
          [(CompilerObjectX64Instr.XorpdRip _) (set! index (+ index 1))]
          [(CompilerObjectX64Instr.Bytes _) (set! index (+ index 1))]
          [(CompilerObjectX64Instr.Raw _) (set! index (+ index 1))]
          [_ (set! ok false)]))
      ok)))

(define (compiler-object-elf-sections-supported?
  [sections : CompilerObjectSectionList]) : bool
  (let
    [count : i64 (compiler-object-section-list-count sections)]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (match (compiler-object-section-list-ref sections index)
          [(CompilerObjectSection.Section kind _ instrs)
            (if (and
              (match kind
                [(CompilerObjectSectionKind.Pdata) false]
                [(CompilerObjectSectionKind.Xdata) false]
                [(CompilerObjectSectionKind.Rsrc) false]
                [_ true])
              (compiler-object-elf-instrs-supported? instrs))
              (set! index (+ index 1))
              (set! ok false))]))
      ok)))

(define (compiler-object-elf-symbol-binding-local?
  [binding : CompilerObjectSymbolBinding]) : bool
  (match binding
    [(CompilerObjectSymbolBinding.Local) true]
    [_ false]))

(define (compiler-object-elf-local-symbol-count
  [symbols : CompilerObjectSymbolList]) : i64
  (let
    [count : i64 (compiler-object-symbol-list-count symbols)]
    [index : i64 0]
    [total : i64 0]
    (begin
      (while (< index count)
        (begin
          (match (compiler-object-symbol-list-ref symbols index)
            [(CompilerObjectSymbol.Symbol _ binding _ _)
              (if (compiler-object-elf-symbol-binding-local? binding)
                (set! total (+ total 1))
                unit)])
          (set! index (+ index 1))))
      total)))

(define (compiler-object-elf-local-symbol-index-from
  [symbols : CompilerObjectSymbolList]
  [name : String]
  [index : i64]) : i64
  (let
    [count : i64 (compiler-object-symbol-list-count symbols)]
    [slot : i64 0]
    [cur-index : i64 index]
    [result : i64 -1]
    [done : bool false]
    (begin
      (while (and (not done) (< slot count))
        (match (compiler-object-symbol-list-ref symbols slot)
          [(CompilerObjectSymbol.Symbol found binding _ _)
            (if (compiler-object-elf-symbol-binding-local? binding)
              (if (string.eq found name)
                (begin
                  (set! result cur-index)
                  (set! done true))
                (begin
                  (set! cur-index (+ cur-index 1))
                  (set! slot (+ slot 1))))
              (set! slot (+ slot 1)))]))
      result)))

(define (compiler-object-elf-global-symbol-index-from
  [symbols : CompilerObjectSymbolList]
  [name : String]
  [index : i64]) : i64
  (let
    [count : i64 (compiler-object-symbol-list-count symbols)]
    [slot : i64 0]
    [cur-index : i64 index]
    [result : i64 -1]
    [done : bool false]
    (begin
      (while (and (not done) (< slot count))
        (match (compiler-object-symbol-list-ref symbols slot)
          [(CompilerObjectSymbol.Symbol found binding _ _)
            (if (compiler-object-elf-symbol-binding-local? binding)
              (set! slot (+ slot 1))
              (if (string.eq found name)
                (begin
                  (set! result cur-index)
                  (set! done true))
                (begin
                  (set! cur-index (+ cur-index 1))
                  (set! slot (+ slot 1)))))]))
      result)))

(define (compiler-object-elf-symbol-index
  [image : CompilerObjectImage]
  [name : String]) : i64
  (let
    [symbols : CompilerObjectSymbolList (struct-get image symbols)]
    [local : i64 (compiler-object-elf-local-symbol-index-from symbols name 1)]
    (if (>= local 0)
      local
      (compiler-object-elf-global-symbol-index-from
        symbols
        name
        (+ 1 (compiler-object-elf-local-symbol-count symbols))))))

(define (compiler-object-elf-data-label-offset-from
  [records : CompilerObjectDataRecordList]
  [label : String]
  [offset : i64]) : i64
  (let
    [count : i64 (compiler-object-data-record-list-count records)]
    [index : i64 0]
    [cur-offset : i64 offset]
    [result : i64 -1]
    [done : bool false]
    (begin
      (while (and (not done) (< index count))
        (let
          [record : CompilerObjectDataRecord
            (compiler-object-data-record-list-ref records index)]
          (match record
            [(CompilerObjectDataRecord.Label found)
              (if (string.eq found label)
                (begin
                  (set! result cur-offset)
                  (set! done true))
                (set! index (+ index 1)))]
            [_
              (begin
                (set!
                  cur-offset
                  (compiler-object-elf-data-record-end-offset record cur-offset))
                (set! index (+ index 1)))])))
      result)))

(define (compiler-object-elf-instr-label-offset-from
  [instrs : CompilerObjectX64InstrList]
  [label : String]
  [offset : i64]) : i64
  (let
    [count : i64 (compiler-object-instr-list-count instrs)]
    [index : i64 0]
    [cur-offset : i64 offset]
    [result : i64 -1]
    [done : bool false]
    (begin
      (while (and (not done) (< index count))
        (let
          [instr : CompilerObjectX64Instr
            (compiler-object-instr-list-ref instrs index)]
          (match instr
            [(CompilerObjectX64Instr.Label found)
              (if (string.eq found label)
                (begin
                  (set! result cur-offset)
                  (set! done true))
                (set! index (+ index 1)))]
            [_
              (begin
                (set!
                  cur-offset
                  (+ cur-offset (compiler-object-elf-instr-size instr)))
                (set! index (+ index 1)))])))
      result)))

(define (compiler-object-elf-section-label-offset
  [image : CompilerObjectImage]
  [kind : CompilerObjectSectionKind]
  [label : String]) : i64
  (match (compiler-object-section-list-find (struct-get image sections) kind)
    [(CompilerObjectSection.Section _ data instrs)
      (match kind
        [(CompilerObjectSectionKind.Text)
          (compiler-object-elf-instr-label-offset-from instrs label 0)]
        [_ (compiler-object-elf-data-label-offset-from data label 0)])]))

(define (compiler-object-elf-relocation-sites-known?
  [image : CompilerObjectImage]
  [relocs : CompilerObjectRelocationList]) : bool
  (let
    [count : i64 (compiler-object-relocation-list-count relocs)]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (match (compiler-object-relocation-list-ref relocs index)
          [(CompilerObjectRelocation.Relocation section site _ target)
            (if (and
              (>=
                (compiler-object-elf-section-label-offset image section site)
                0)
              (>= (compiler-object-elf-symbol-index image target) 0))
              (set! index (+ index 1))
              (set! ok false))]))
      ok)))

(define (compiler-object-elf-instr-targets-known?
  [image : CompilerObjectImage]
  [instrs : CompilerObjectX64InstrList]) : bool
  (let
    [count : i64 (compiler-object-instr-list-count instrs)]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (match (compiler-object-instr-list-ref instrs index)
          [(CompilerObjectX64Instr.Label _) (set! index (+ index 1))]
          [(CompilerObjectX64Instr.Call target)
            (if (>= (compiler-object-elf-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(CompilerObjectX64Instr.TailCall target)
            (if (>= (compiler-object-elf-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(CompilerObjectX64Instr.Jump target)
            (if (>= (compiler-object-elf-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(CompilerObjectX64Instr.Ja target)
            (if (>= (compiler-object-elf-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(CompilerObjectX64Instr.Branch true-target false-target)
            (if (and
              (>= (compiler-object-elf-symbol-index image true-target) 0)
              (>= (compiler-object-elf-symbol-index image false-target) 0))
              (set! index (+ index 1))
              (set! ok false))]
          [(CompilerObjectX64Instr.LoadRip target)
            (if (>= (compiler-object-elf-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(CompilerObjectX64Instr.LoadRipAddress target)
            (if (>= (compiler-object-elf-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(CompilerObjectX64Instr.LoadRipAddressR11 target)
            (if (>= (compiler-object-elf-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(CompilerObjectX64Instr.StoreRip target)
            (if (>= (compiler-object-elf-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(CompilerObjectX64Instr.SubRspImm8 _) (set! index (+ index 1))]
          [(CompilerObjectX64Instr.MovRcxRip target)
            (if (>= (compiler-object-elf-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(CompilerObjectX64Instr.MovRdxRip target)
            (if (>= (compiler-object-elf-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(CompilerObjectX64Instr.LoadRipAddressRdx target)
            (if (>= (compiler-object-elf-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(CompilerObjectX64Instr.StoreR14Rip target)
            (if (>= (compiler-object-elf-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(CompilerObjectX64Instr.StoreR15Rip target)
            (if (>= (compiler-object-elf-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(CompilerObjectX64Instr.AddRcxRip target)
            (if (>= (compiler-object-elf-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(CompilerObjectX64Instr.MovRcxRax) (set! index (+ index 1))]
          [(CompilerObjectX64Instr.XorpdRip target)
            (if (>= (compiler-object-elf-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(CompilerObjectX64Instr.Bytes _) (set! index (+ index 1))]
          [(CompilerObjectX64Instr.Raw _) (set! index (+ index 1))]))
      ok)))

(define (compiler-object-elf-text-targets-known? [image : CompilerObjectImage]) : bool
  (match (compiler-object-section-list-find
    (struct-get image sections)
    (CompilerObjectSectionKind.Text))
    [(CompilerObjectSection.Section _ _ instrs)
      (compiler-object-elf-instr-targets-known? image instrs)]))

(define (compiler-object-elf-text-instr-relocation-count
  [image : CompilerObjectImage]) : i64
  (match (compiler-object-section-list-find
    (struct-get image sections)
    (CompilerObjectSectionKind.Text))
    [(CompilerObjectSection.Section _ _ instrs)
      (compiler-object-elf-instrs-relocation-count instrs)]))

(define (compiler-object-elf-text-relocation-count-matches?
  [image : CompilerObjectImage]) : bool
  (=
    (compiler-object-elf-relocation-count
      (struct-get image relocations)
      (CompilerObjectSectionKind.Text))
    (compiler-object-elf-text-instr-relocation-count image)))

(define (compiler-object-elf-image-supported? [image : CompilerObjectImage]) : bool
  (and
    (compiler-object-elf-sections-supported? (struct-get image sections))
    (compiler-object-elf-relocation-list-supported?
      (struct-get image relocations))
    (compiler-object-elf-relocation-sites-known?
      image
      (struct-get image relocations))
    (compiler-object-elf-text-targets-known? image)
    (compiler-object-elf-text-relocation-count-matches? image)))

(define (compiler-object-elf-relocation-count
  [relocs : CompilerObjectRelocationList]
  [kind : CompilerObjectSectionKind]) : i64
  (let
    [count : i64 (compiler-object-relocation-list-count relocs)]
    [index : i64 0]
    [total : i64 0]
    (begin
      (while (< index count)
        (begin
          (match (compiler-object-relocation-list-ref relocs index)
            [(CompilerObjectRelocation.Relocation section _ _ _)
              (if (compiler-object-section-kind-eq? section kind)
                (set! total (+ total 1))
                unit)])
          (set! index (+ index 1))))
      total)))

(define (compiler-object-elf-section-relocation-count
  [image : CompilerObjectImage]
  [kind : CompilerObjectSectionKind]) : i64
  (match kind
    [(CompilerObjectSectionKind.Text)
      (compiler-object-elf-text-instr-relocation-count image)]
    [_
      (compiler-object-elf-relocation-count (struct-get image relocations) kind)]))

(define (compiler-object-elf-relocation-section-size
  [image : CompilerObjectImage]
  [kind : CompilerObjectSectionKind]) : i64
  (*
    compiler-object-elf-relocation-size
    (compiler-object-elf-section-relocation-count image kind)))

(define (compiler-object-elf-symbol-table-size [image : CompilerObjectImage]) : i64
  (*
    compiler-object-elf-symbol-size
    (+ 1 (compiler-object-symbol-list-count (struct-get image symbols)))))

(define (compiler-object-elf-string-table-size-from
  [symbols : CompilerObjectSymbolList]
  [size : i64]) : i64
  (let
    [count : i64 (compiler-object-symbol-list-count symbols)]
    [index : i64 0]
    [total : i64 size]
    (begin
      (while (< index count)
        (begin
          (match (compiler-object-symbol-list-ref symbols index)
            [(CompilerObjectSymbol.Symbol name _ _ _)
              (set!
                total
                (+ total (+ (compiler-object-elf-string-length name) 1)))])
          (set! index (+ index 1))))
      total)))

(define (compiler-object-elf-string-table-size
  [symbols : CompilerObjectSymbolList]) : i64
  (compiler-object-elf-string-table-size-from symbols 1))

(define (compiler-object-elf-push-shstrtab-name!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [name : String]) : unit
  (begin
    (compiler-object-elf-push-string-bytes! out name)
    (compiler-object-elf-push-u8! out 0)))

(define (compiler-object-elf-push-shstrtab!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]) : unit
  (begin
    (compiler-object-elf-push-u8! out 0)
    (compiler-object-elf-push-shstrtab-name! out ".text")
    (compiler-object-elf-push-shstrtab-name! out ".data")
    (compiler-object-elf-push-shstrtab-name! out ".rodata")
    (compiler-object-elf-push-shstrtab-name! out ".bss")
    (compiler-object-elf-push-shstrtab-name! out ".rela.text")
    (compiler-object-elf-push-shstrtab-name! out ".rela.data")
    (compiler-object-elf-push-shstrtab-name! out ".rela.rodata")
    (compiler-object-elf-push-shstrtab-name! out ".rela.bss")
    (compiler-object-elf-push-shstrtab-name! out ".symtab")
    (compiler-object-elf-push-shstrtab-name! out ".strtab")
    (compiler-object-elf-push-shstrtab-name! out ".shstrtab")
    (compiler-object-elf-push-shstrtab-name! out ".note.GNU-stack")))

(define (compiler-object-elf-text-offset [_image : CompilerObjectImage]) : i64
  (compiler-object-elf-align-offset compiler-object-elf-header-size 16))

(define (compiler-object-elf-data-offset [image : CompilerObjectImage]) : i64
  (compiler-object-elf-align-offset
    (+
      (compiler-object-elf-text-offset image)
      (compiler-object-elf-section-raw-size
        image
        (CompilerObjectSectionKind.Text)))
    8))

(define (compiler-object-elf-rodata-offset [image : CompilerObjectImage]) : i64
  (compiler-object-elf-align-offset
    (+
      (compiler-object-elf-data-offset image)
      (compiler-object-elf-section-raw-size
        image
        (CompilerObjectSectionKind.Data)))
    8))

(define (compiler-object-elf-bss-offset [image : CompilerObjectImage]) : i64
  (compiler-object-elf-align-offset
    (+
      (compiler-object-elf-rodata-offset image)
      (compiler-object-elf-section-raw-size
        image
        (CompilerObjectSectionKind.Rodata)))
    8))

(define (compiler-object-elf-rela-text-offset [image : CompilerObjectImage]) : i64
  (compiler-object-elf-align-offset (compiler-object-elf-bss-offset image) 8))

(define (compiler-object-elf-rela-data-offset [image : CompilerObjectImage]) : i64
  (compiler-object-elf-align-offset
    (+
      (compiler-object-elf-rela-text-offset image)
      (compiler-object-elf-relocation-section-size
        image
        (CompilerObjectSectionKind.Text)))
    8))

(define (compiler-object-elf-rela-rodata-offset [image : CompilerObjectImage]) : i64
  (compiler-object-elf-align-offset
    (+
      (compiler-object-elf-rela-data-offset image)
      (compiler-object-elf-relocation-section-size
        image
        (CompilerObjectSectionKind.Data)))
    8))

(define (compiler-object-elf-rela-bss-offset [image : CompilerObjectImage]) : i64
  (compiler-object-elf-align-offset
    (+
      (compiler-object-elf-rela-rodata-offset image)
      (compiler-object-elf-relocation-section-size
        image
        (CompilerObjectSectionKind.Rodata)))
    8))

(define (compiler-object-elf-symtab-offset [image : CompilerObjectImage]) : i64
  (compiler-object-elf-align-offset
    (+
      (compiler-object-elf-rela-bss-offset image)
      (compiler-object-elf-relocation-section-size
        image
        (CompilerObjectSectionKind.Bss)))
    8))

(define (compiler-object-elf-strtab-offset [image : CompilerObjectImage]) : i64
  (+
    (compiler-object-elf-symtab-offset image)
    (compiler-object-elf-symbol-table-size image)))

(define (compiler-object-elf-shstrtab-offset [image : CompilerObjectImage]) : i64
  (+
    (compiler-object-elf-strtab-offset image)
    (compiler-object-elf-string-table-size (struct-get image symbols))))

(define (compiler-object-elf-section-header-offset
  [image : CompilerObjectImage]) : i64
  (compiler-object-elf-align-offset
    (+
      (compiler-object-elf-shstrtab-offset image)
      compiler-object-elf-shstrtab-size)
    8))

(define (compiler-object-elf-section-index [kind : CompilerObjectSectionKind]) : i64
  (match kind
    [(CompilerObjectSectionKind.Text) compiler-object-elf-section-text-index]
    [(CompilerObjectSectionKind.Data) compiler-object-elf-section-data-index]
    [(CompilerObjectSectionKind.Rodata)
      compiler-object-elf-section-rodata-index]
    [(CompilerObjectSectionKind.Bss) compiler-object-elf-section-bss-index]
    [(CompilerObjectSectionKind.Pdata) compiler-object-elf-section-null-index]
    [(CompilerObjectSectionKind.Xdata) compiler-object-elf-section-null-index]
    [(CompilerObjectSectionKind.Rsrc) compiler-object-elf-section-null-index]))

(define (compiler-object-elf-section-file-offset
  [image : CompilerObjectImage]
  [kind : CompilerObjectSectionKind]) : i64
  (match kind
    [(CompilerObjectSectionKind.Text) (compiler-object-elf-text-offset image)]
    [(CompilerObjectSectionKind.Data) (compiler-object-elf-data-offset image)]
    [(CompilerObjectSectionKind.Rodata)
      (compiler-object-elf-rodata-offset image)]
    [(CompilerObjectSectionKind.Bss) (compiler-object-elf-bss-offset image)]
    [(CompilerObjectSectionKind.Pdata) 0]
    [(CompilerObjectSectionKind.Xdata) 0]
    [(CompilerObjectSectionKind.Rsrc) 0]))

(define (compiler-object-elf-relocation-section-offset
  [image : CompilerObjectImage]
  [kind : CompilerObjectSectionKind]) : i64
  (match kind
    [(CompilerObjectSectionKind.Text)
      (compiler-object-elf-rela-text-offset image)]
    [(CompilerObjectSectionKind.Data)
      (compiler-object-elf-rela-data-offset image)]
    [(CompilerObjectSectionKind.Rodata)
      (compiler-object-elf-rela-rodata-offset image)]
    [(CompilerObjectSectionKind.Bss)
      (compiler-object-elf-rela-bss-offset image)]
    [(CompilerObjectSectionKind.Pdata) 0]
    [(CompilerObjectSectionKind.Xdata) 0]
    [(CompilerObjectSectionKind.Rsrc) 0]))

(define (compiler-object-elf-section-name-offset [index : i64]) : i64
  (cond
    [(= index compiler-object-elf-section-text-index) 1]
    [(= index compiler-object-elf-section-data-index) 7]
    [(= index compiler-object-elf-section-rodata-index) 13]
    [(= index compiler-object-elf-section-bss-index) 21]
    [(= index compiler-object-elf-section-rela-text-index) 26]
    [(= index compiler-object-elf-section-rela-data-index) 37]
    [(= index compiler-object-elf-section-rela-rodata-index) 48]
    [(= index compiler-object-elf-section-rela-bss-index) 61]
    [(= index compiler-object-elf-section-symtab-index) 71]
    [(= index compiler-object-elf-section-strtab-index) 79]
    [(= index compiler-object-elf-section-shstrtab-index) 87]
    [(= index compiler-object-elf-section-note-gnu-stack-index) 97]
    [else 0]))

(define (compiler-object-elf-push-header!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : CompilerObjectImage]) : unit
  (begin
    (compiler-object-elf-push-u8! out 0x7f)
    (compiler-object-elf-push-u8! out 0x45)
    (compiler-object-elf-push-u8! out 0x4c)
    (compiler-object-elf-push-u8! out 0x46)
    (compiler-object-elf-push-u8! out 2)
    (compiler-object-elf-push-u8! out 1)
    (compiler-object-elf-push-u8! out 1)
    (compiler-object-elf-push-u8! out 0)
    (compiler-object-elf-push-u8! out 0)
    (compiler-object-elf-push-zeroes! out 7)
    (compiler-object-elf-push-u16! out 1)
    (compiler-object-elf-push-u16! out 62)
    (compiler-object-elf-push-u32! out 1)
    (compiler-object-elf-push-i64! out 0)
    (compiler-object-elf-push-i64! out 0)
    (compiler-object-elf-push-i64!
      out
      (compiler-object-elf-section-header-offset image))
    (compiler-object-elf-push-u32! out 0)
    (compiler-object-elf-push-u16! out compiler-object-elf-header-size)
    (compiler-object-elf-push-u16! out 0)
    (compiler-object-elf-push-u16! out 0)
    (compiler-object-elf-push-u16! out compiler-object-elf-section-header-size)
    (compiler-object-elf-push-u16! out compiler-object-elf-section-count)
    (compiler-object-elf-push-u16!
      out
      compiler-object-elf-section-shstrtab-index)))

(define (compiler-object-elf-render-data-record!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [record : CompilerObjectDataRecord]
  [offset : i64]) : i64
  (match record
    [(CompilerObjectDataRecord.Label _) offset]
    [(CompilerObjectDataRecord.Align align)
      (let
        [aligned : i64 (compiler-object-elf-align-offset offset align)]
        (begin
          (compiler-object-elf-push-zeroes! out (- aligned offset))
          aligned))]
    [(CompilerObjectDataRecord.Bytes bytes)
      (begin
        (compiler-object-elf-push-string-bytes! out bytes)
        (+ offset (compiler-object-elf-string-length bytes)))]
    [(CompilerObjectDataRecord.String text)
      (begin
        (compiler-object-elf-push-string-bytes! out text)
        (compiler-object-elf-push-u8! out 0)
        (+ offset (+ (compiler-object-elf-string-length text) 1)))]
    [(CompilerObjectDataRecord.F64 bits)
      (begin
        (compiler-object-elf-push-u64! out bits)
        (+ offset 8))]
    [(CompilerObjectDataRecord.F32 bits)
      (begin
        (compiler-object-elf-push-u32! out (cast bits : i64))
        (+ offset 4))]
    [(CompilerObjectDataRecord.I64 value)
      (begin
        (compiler-object-elf-push-i64! out value)
        (+ offset 8))]
    [(CompilerObjectDataRecord.Zero count)
      (begin
        (compiler-object-elf-push-zeroes! out count)
        (+ offset count))]
    [(CompilerObjectDataRecord.SymbolAddress _)
      (begin
        (compiler-object-elf-push-i64! out 0)
        (+ offset 8))]
    [(CompilerObjectDataRecord.SymbolRva32 _)
      (begin
        (compiler-object-elf-push-u32! out 0)
        (+ offset 4))]))

(define (compiler-object-elf-render-data-records!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [records : CompilerObjectDataRecordList]
  [offset : i64]) : i64
  (let
    [count : i64 (compiler-object-data-record-list-count records)]
    [index : i64 0]
    [cur-offset : i64 offset]
    (begin
      (while (< index count)
        (begin
          (set!
            cur-offset
            (compiler-object-elf-render-data-record!
              out
              (compiler-object-data-record-list-ref records index)
              cur-offset))
          (set! index (+ index 1))))
      cur-offset)))

(define (compiler-object-elf-push-rel32-placeholder!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]) : unit
  (compiler-object-elf-push-u32! out 0))

(define (compiler-object-elf-render-instr!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [instr : CompilerObjectX64Instr]) : unit
  (match instr
    [(CompilerObjectX64Instr.Label _) unit]
    [(CompilerObjectX64Instr.Call _)
      (begin
        (compiler-object-elf-push-u8! out 0xe8)
        (compiler-object-elf-push-rel32-placeholder! out))]
    [(CompilerObjectX64Instr.TailCall _)
      (begin
        (compiler-object-elf-push-u8! out 0xe9)
        (compiler-object-elf-push-rel32-placeholder! out))]
    [(CompilerObjectX64Instr.Jump _)
      (begin
        (compiler-object-elf-push-u8! out 0xe9)
        (compiler-object-elf-push-rel32-placeholder! out))]
    [(CompilerObjectX64Instr.Ja _)
      (begin
        (compiler-object-elf-push-u8! out 0x0f)
        (compiler-object-elf-push-u8! out 0x87)
        (compiler-object-elf-push-rel32-placeholder! out))]
    [(CompilerObjectX64Instr.Branch _ _)
      (begin
        (compiler-object-elf-push-u8! out 0x48)
        (compiler-object-elf-push-u8! out 0x85)
        (compiler-object-elf-push-u8! out 0xc0)
        (compiler-object-elf-push-u8! out 0x0f)
        (compiler-object-elf-push-u8! out 0x85)
        (compiler-object-elf-push-rel32-placeholder! out)
        (compiler-object-elf-push-u8! out 0xe9)
        (compiler-object-elf-push-rel32-placeholder! out))]
    [(CompilerObjectX64Instr.LoadRip _)
      (begin
        (compiler-object-elf-push-u8! out 0x48)
        (compiler-object-elf-push-u8! out 0x8b)
        (compiler-object-elf-push-u8! out 0x05)
        (compiler-object-elf-push-rel32-placeholder! out))]
    [(CompilerObjectX64Instr.LoadRipAddress _)
      (begin
        (compiler-object-elf-push-u8! out 0x48)
        (compiler-object-elf-push-u8! out 0x8d)
        (compiler-object-elf-push-u8! out 0x05)
        (compiler-object-elf-push-rel32-placeholder! out))]
    [(CompilerObjectX64Instr.LoadRipAddressR11 _)
      (begin
        (compiler-object-elf-push-u8! out 0x4c)
        (compiler-object-elf-push-u8! out 0x8d)
        (compiler-object-elf-push-u8! out 0x1d)
        (compiler-object-elf-push-rel32-placeholder! out))]
    [(CompilerObjectX64Instr.StoreRip _)
      (begin
        (compiler-object-elf-push-u8! out 0x48)
        (compiler-object-elf-push-u8! out 0x89)
        (compiler-object-elf-push-u8! out 0x05)
        (compiler-object-elf-push-rel32-placeholder! out))]
    [(CompilerObjectX64Instr.SubRspImm8 imm)
      (begin
        (compiler-object-elf-push-u8! out 0x48)
        (compiler-object-elf-push-u8! out 0x83)
        (compiler-object-elf-push-u8! out 0xec)
        (compiler-object-elf-push-u8! out imm))]
    [(CompilerObjectX64Instr.MovRcxRip _)
      (begin
        (compiler-object-elf-push-u8! out 0x48)
        (compiler-object-elf-push-u8! out 0x8b)
        (compiler-object-elf-push-u8! out 0x0d)
        (compiler-object-elf-push-rel32-placeholder! out))]
    [(CompilerObjectX64Instr.MovRdxRip _)
      (begin
        (compiler-object-elf-push-u8! out 0x48)
        (compiler-object-elf-push-u8! out 0x8b)
        (compiler-object-elf-push-u8! out 0x15)
        (compiler-object-elf-push-rel32-placeholder! out))]
    [(CompilerObjectX64Instr.LoadRipAddressRdx _)
      (begin
        (compiler-object-elf-push-u8! out 0x48)
        (compiler-object-elf-push-u8! out 0x8d)
        (compiler-object-elf-push-u8! out 0x15)
        (compiler-object-elf-push-rel32-placeholder! out))]
    [(CompilerObjectX64Instr.StoreR14Rip _)
      (begin
        (compiler-object-elf-push-u8! out 0x4c)
        (compiler-object-elf-push-u8! out 0x89)
        (compiler-object-elf-push-u8! out 0x35)
        (compiler-object-elf-push-rel32-placeholder! out))]
    [(CompilerObjectX64Instr.StoreR15Rip _)
      (begin
        (compiler-object-elf-push-u8! out 0x4c)
        (compiler-object-elf-push-u8! out 0x89)
        (compiler-object-elf-push-u8! out 0x3d)
        (compiler-object-elf-push-rel32-placeholder! out))]
    [(CompilerObjectX64Instr.AddRcxRip _)
      (begin
        (compiler-object-elf-push-u8! out 0x48)
        (compiler-object-elf-push-u8! out 0x01)
        (compiler-object-elf-push-u8! out 0x0d)
        (compiler-object-elf-push-rel32-placeholder! out))]
    [(CompilerObjectX64Instr.MovRcxRax)
      (begin
        (compiler-object-elf-push-u8! out 0x48)
        (compiler-object-elf-push-u8! out 0x89)
        (compiler-object-elf-push-u8! out 0xc1))]
    [(CompilerObjectX64Instr.XorpdRip _)
      (begin
        (compiler-object-elf-push-u8! out 0x66)
        (compiler-object-elf-push-u8! out 0x0f)
        (compiler-object-elf-push-u8! out 0x57)
        (compiler-object-elf-push-u8! out 0x05)
        (compiler-object-elf-push-rel32-placeholder! out))]
    [(CompilerObjectX64Instr.Bytes bytes)
      (compiler-object-elf-push-string-bytes! out bytes)]
    [(CompilerObjectX64Instr.Raw bytes)
      (compiler-object-elf-push-string-bytes! out bytes)]
    [_ unit]))

(define (compiler-object-elf-render-instrs!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [instrs : CompilerObjectX64InstrList]) : unit
  (let
    [count : i64 (compiler-object-instr-list-count instrs)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (compiler-object-elf-render-instr!
            out
            (compiler-object-instr-list-ref instrs index))
          (set! index (+ index 1))))
      unit)))

(define (compiler-object-elf-render-section!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : CompilerObjectImage]
  [kind : CompilerObjectSectionKind]) : unit
  (match (compiler-object-section-list-find (struct-get image sections) kind)
    [(CompilerObjectSection.Section _ data instrs)
      (match kind
        [(CompilerObjectSectionKind.Text)
          (compiler-object-elf-render-instrs! out instrs)]
        [_
          (begin
            (compiler-object-elf-render-data-records! out data 0)
            unit)])]))

(define (compiler-object-elf-render-loadable-sections!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : CompilerObjectImage]) : unit
  (begin
    (compiler-object-elf-render-padding-to!
      out
      (compiler-object-elf-text-offset image))
    (compiler-object-elf-render-section!
      out
      image
      (CompilerObjectSectionKind.Text))
    (compiler-object-elf-render-padding-to!
      out
      (compiler-object-elf-data-offset image))
    (compiler-object-elf-render-section!
      out
      image
      (CompilerObjectSectionKind.Data))
    (compiler-object-elf-render-padding-to!
      out
      (compiler-object-elf-rodata-offset image))
    (compiler-object-elf-render-section!
      out
      image
      (CompilerObjectSectionKind.Rodata))))

(define (compiler-object-elf-relocation-type
  [kind : CompilerObjectRelocationKind]) : i64
  (match kind
    [(CompilerObjectRelocationKind.Call) compiler-object-elf-r-x86-64-plt32]
    [(CompilerObjectRelocationKind.TailCall) compiler-object-elf-r-x86-64-plt32]
    [(CompilerObjectRelocationKind.Abs64) compiler-object-elf-r-x86-64-64]
    [(CompilerObjectRelocationKind.RipValue) compiler-object-elf-r-x86-64-pc32]
    [(CompilerObjectRelocationKind.RipAddress)
      compiler-object-elf-r-x86-64-pc32]
    [(CompilerObjectRelocationKind.Branch) compiler-object-elf-r-x86-64-pc32]
    [_ 0]))

(define (compiler-object-elf-relocation-addend
  [kind : CompilerObjectRelocationKind]) : i64
  (match kind
    [(CompilerObjectRelocationKind.Call) -4]
    [(CompilerObjectRelocationKind.TailCall) -4]
    [(CompilerObjectRelocationKind.RipValue) -4]
    [(CompilerObjectRelocationKind.RipAddress) -4]
    [(CompilerObjectRelocationKind.Branch) -4]
    [_ 0]))

(define (compiler-object-elf-render-relocation-record!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : CompilerObjectImage]
  [offset : i64]
  [kind : CompilerObjectRelocationKind]
  [target : String]) : unit
  (begin
    (compiler-object-elf-push-i64! out offset)
    (compiler-object-elf-push-i64!
      out
      (bit-or
        (shl (compiler-object-elf-symbol-index image target) 32)
        (compiler-object-elf-relocation-type kind)))
    (compiler-object-elf-push-i64!
      out
      (compiler-object-elf-relocation-addend kind))))

(define (compiler-object-elf-render-relocation!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : CompilerObjectImage]
  [reloc : CompilerObjectRelocation]) : unit
  (match reloc
    [(CompilerObjectRelocation.Relocation section site kind target)
      (compiler-object-elf-render-relocation-record!
        out
        image
        (compiler-object-elf-section-label-offset image section site)
        kind
        target)]))

(define (compiler-object-elf-render-text-instr-relocations!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : CompilerObjectImage]
  [instrs : CompilerObjectX64InstrList]
  [offset : i64]) : unit
  (let
    [count : i64 (compiler-object-instr-list-count instrs)]
    [index : i64 0]
    [cur-offset : i64 offset]
    (begin
      (while (< index count)
        (let
          [instr : CompilerObjectX64Instr
            (compiler-object-instr-list-ref instrs index)]
          (begin
            (match instr
              [(CompilerObjectX64Instr.Label _) unit]
              [(CompilerObjectX64Instr.Call target)
                (compiler-object-elf-render-relocation-record!
                  out
                  image
                  (+ cur-offset 1)
                  (CompilerObjectRelocationKind.Call)
                  target)]
              [(CompilerObjectX64Instr.TailCall target)
                (compiler-object-elf-render-relocation-record!
                  out
                  image
                  (+ cur-offset 1)
                  (CompilerObjectRelocationKind.TailCall)
                  target)]
              [(CompilerObjectX64Instr.Jump target)
                (compiler-object-elf-render-relocation-record!
                  out
                  image
                  (+ cur-offset 1)
                  (CompilerObjectRelocationKind.Branch)
                  target)]
              [(CompilerObjectX64Instr.Ja target)
                (compiler-object-elf-render-relocation-record!
                  out
                  image
                  (+ cur-offset 2)
                  (CompilerObjectRelocationKind.Branch)
                  target)]
              [(CompilerObjectX64Instr.Branch true-target false-target)
                (begin
                  (compiler-object-elf-render-relocation-record!
                    out
                    image
                    (+ cur-offset 5)
                    (CompilerObjectRelocationKind.Branch)
                    true-target)
                  (compiler-object-elf-render-relocation-record!
                    out
                    image
                    (+ cur-offset 10)
                    (CompilerObjectRelocationKind.Branch)
                    false-target))]
              [(CompilerObjectX64Instr.LoadRip target)
                (compiler-object-elf-render-relocation-record!
                  out
                  image
                  (+ cur-offset 3)
                  (CompilerObjectRelocationKind.RipValue)
                  target)]
              [(CompilerObjectX64Instr.LoadRipAddress target)
                (compiler-object-elf-render-relocation-record!
                  out
                  image
                  (+ cur-offset 3)
                  (CompilerObjectRelocationKind.RipAddress)
                  target)]
              [(CompilerObjectX64Instr.LoadRipAddressR11 target)
                (compiler-object-elf-render-relocation-record!
                  out
                  image
                  (+ cur-offset 3)
                  (CompilerObjectRelocationKind.RipAddress)
                  target)]
              [(CompilerObjectX64Instr.StoreRip target)
                (compiler-object-elf-render-relocation-record!
                  out
                  image
                  (+ cur-offset 3)
                  (CompilerObjectRelocationKind.RipAddress)
                  target)]
              [(CompilerObjectX64Instr.SubRspImm8 _) unit]
              [(CompilerObjectX64Instr.MovRcxRip target)
                (compiler-object-elf-render-relocation-record!
                  out
                  image
                  (+ cur-offset 3)
                  (CompilerObjectRelocationKind.RipValue)
                  target)]
              [(CompilerObjectX64Instr.MovRdxRip target)
                (compiler-object-elf-render-relocation-record!
                  out
                  image
                  (+ cur-offset 3)
                  (CompilerObjectRelocationKind.RipValue)
                  target)]
              [(CompilerObjectX64Instr.LoadRipAddressRdx target)
                (compiler-object-elf-render-relocation-record!
                  out
                  image
                  (+ cur-offset 3)
                  (CompilerObjectRelocationKind.RipAddress)
                  target)]
              [(CompilerObjectX64Instr.StoreR14Rip target)
                (compiler-object-elf-render-relocation-record!
                  out
                  image
                  (+ cur-offset 3)
                  (CompilerObjectRelocationKind.RipAddress)
                  target)]
              [(CompilerObjectX64Instr.StoreR15Rip target)
                (compiler-object-elf-render-relocation-record!
                  out
                  image
                  (+ cur-offset 3)
                  (CompilerObjectRelocationKind.RipAddress)
                  target)]
              [(CompilerObjectX64Instr.AddRcxRip target)
                (compiler-object-elf-render-relocation-record!
                  out
                  image
                  (+ cur-offset 3)
                  (CompilerObjectRelocationKind.RipAddress)
                  target)]
              [(CompilerObjectX64Instr.MovRcxRax) unit]
              [(CompilerObjectX64Instr.XorpdRip target)
                (compiler-object-elf-render-relocation-record!
                  out
                  image
                  (+ cur-offset 4)
                  (CompilerObjectRelocationKind.RipValue)
                  target)]
              [(CompilerObjectX64Instr.Bytes _) unit]
              [(CompilerObjectX64Instr.Raw _) unit])
            (set!
              cur-offset
              (+ cur-offset (compiler-object-elf-instr-size instr)))
            (set! index (+ index 1)))))
      unit)))

(define (compiler-object-elf-render-text-relocations!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : CompilerObjectImage]) : unit
  (match (compiler-object-section-list-find
    (struct-get image sections)
    (CompilerObjectSectionKind.Text))
    [(CompilerObjectSection.Section _ _ instrs)
      (compiler-object-elf-render-text-instr-relocations! out image instrs 0)]))

(define (compiler-object-elf-render-relocations-for-section!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : CompilerObjectImage]
  [relocs : CompilerObjectRelocationList]
  [kind : CompilerObjectSectionKind]) : unit
  (let
    [count : i64 (compiler-object-relocation-list-count relocs)]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [reloc : CompilerObjectRelocation
            (compiler-object-relocation-list-ref relocs index)]
          (begin
            (match reloc
              [(CompilerObjectRelocation.Relocation section _ _ _)
                (if (compiler-object-section-kind-eq? section kind)
                  (compiler-object-elf-render-relocation! out image reloc)
                  unit)])
            (set! index (+ index 1)))))
      unit)))

(define (compiler-object-elf-render-relocation-section!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : CompilerObjectImage]
  [kind : CompilerObjectSectionKind]) : unit
  (begin
    (compiler-object-elf-render-padding-to!
      out
      (compiler-object-elf-relocation-section-offset image kind))
    (match kind
      [(CompilerObjectSectionKind.Text)
        (compiler-object-elf-render-text-relocations! out image)]
      [_
        (compiler-object-elf-render-relocations-for-section!
          out
          image
          (struct-get image relocations)
          kind)])))

(define (compiler-object-elf-symbol-string-offset-from
  [symbols : CompilerObjectSymbolList]
  [name : String]
  [offset : i64]) : i64
  (let
    [count : i64 (compiler-object-symbol-list-count symbols)]
    [index : i64 0]
    [cur-offset : i64 offset]
    [result : i64 0]
    [done : bool false]
    (begin
      (while (and (not done) (< index count))
        (match (compiler-object-symbol-list-ref symbols index)
          [(CompilerObjectSymbol.Symbol found _ _ _)
            (if (string.eq found name)
              (begin
                (set! result cur-offset)
                (set! done true))
              (begin
                (set!
                  cur-offset
                  (+ cur-offset (+ (compiler-object-elf-string-length found) 1)))
                (set! index (+ index 1))))]))
      result)))

(define (compiler-object-elf-symbol-string-offset
  [image : CompilerObjectImage]
  [name : String]) : i64
  (compiler-object-elf-symbol-string-offset-from
    (struct-get image symbols)
    name
    1))

(define (compiler-object-elf-symbol-binding
  [binding : CompilerObjectSymbolBinding]) : i64
  (match binding
    [(CompilerObjectSymbolBinding.Local) 0]
    [_ 1]))

(define (compiler-object-elf-symbol-type [kind : CompilerObjectSymbolKind]) : i64
  (match kind
    [(CompilerObjectSymbolKind.Function) 2]
    [(CompilerObjectSymbolKind.Runtime) 2]
    [(CompilerObjectSymbolKind.Data) 1]
    [_ 0]))

(define (compiler-object-elf-symbol-info
  [binding : CompilerObjectSymbolBinding]
  [kind : CompilerObjectSymbolKind]) : i64
  (bit-or
    (shl (compiler-object-elf-symbol-binding binding) 4)
    (compiler-object-elf-symbol-type kind)))

(define (compiler-object-elf-symbol-section-index
  [section : CompilerObjectMaybeSection]) : i64
  (match section
    [(CompilerObjectMaybeSection.No) 0]
    [(CompilerObjectMaybeSection.Some kind)
      (compiler-object-elf-section-index kind)]))

(define (compiler-object-elf-symbol-value
  [image : CompilerObjectImage]
  [name : String]
  [section : CompilerObjectMaybeSection]) : i64
  (match section
    [(CompilerObjectMaybeSection.No) 0]
    [(CompilerObjectMaybeSection.Some kind)
      (let
        [offset : i64
          (compiler-object-elf-section-label-offset image kind name)]
        (if (< offset 0)
          0
          offset))]))

(define (compiler-object-elf-render-null-symbol!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]) : unit
  (compiler-object-elf-push-zeroes! out compiler-object-elf-symbol-size))

(define (compiler-object-elf-render-symbol!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : CompilerObjectImage]
  [symbol : CompilerObjectSymbol]) : unit
  (match symbol
    [(CompilerObjectSymbol.Symbol name binding kind section)
      (begin
        (compiler-object-elf-push-u32!
          out
          (compiler-object-elf-symbol-string-offset image name))
        (compiler-object-elf-push-u8!
          out
          (compiler-object-elf-symbol-info binding kind))
        (compiler-object-elf-push-u8! out 0)
        (compiler-object-elf-push-u16!
          out
          (compiler-object-elf-symbol-section-index section))
        (compiler-object-elf-push-i64!
          out
          (compiler-object-elf-symbol-value image name section))
        (compiler-object-elf-push-i64! out 0))]))

(define (compiler-object-elf-render-symbols-by-locality!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : CompilerObjectImage]
  [symbols : CompilerObjectSymbolList]
  [want-local : bool]) : unit
  (let
    [count : i64 (compiler-object-symbol-list-count symbols)]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [symbol : CompilerObjectSymbol
            (compiler-object-symbol-list-ref symbols index)]
          (begin
            (match symbol
              [(CompilerObjectSymbol.Symbol _ binding _ _)
                (if (=
                  (compiler-object-elf-symbol-binding-local? binding)
                  want-local)
                  (compiler-object-elf-render-symbol! out image symbol)
                  unit)])
            (set! index (+ index 1)))))
      unit)))

(define (compiler-object-elf-render-symbol-table!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : CompilerObjectImage]) : unit
  (begin
    (compiler-object-elf-render-padding-to!
      out
      (compiler-object-elf-symtab-offset image))
    (compiler-object-elf-render-null-symbol! out)
    (compiler-object-elf-render-symbols-by-locality!
      out
      image
      (struct-get image symbols)
      true)
    (compiler-object-elf-render-symbols-by-locality!
      out
      image
      (struct-get image symbols)
      false)))

(define (compiler-object-elf-render-string-table-symbols!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [symbols : CompilerObjectSymbolList]) : unit
  (let
    [count : i64 (compiler-object-symbol-list-count symbols)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (match (compiler-object-symbol-list-ref symbols index)
            [(CompilerObjectSymbol.Symbol name _ _ _)
              (begin
                (compiler-object-elf-push-string-bytes! out name)
                (compiler-object-elf-push-u8! out 0))])
          (set! index (+ index 1))))
      unit)))

(define (compiler-object-elf-render-string-tables!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : CompilerObjectImage]) : unit
  (begin
    (compiler-object-elf-render-padding-to!
      out
      (compiler-object-elf-strtab-offset image))
    (compiler-object-elf-push-u8! out 0)
    (compiler-object-elf-render-string-table-symbols!
      out
      (struct-get image symbols))
    (compiler-object-elf-render-padding-to!
      out
      (compiler-object-elf-shstrtab-offset image))
    (compiler-object-elf-push-shstrtab! out)))

(define (compiler-object-elf-section-flags [kind : CompilerObjectSectionKind]) : i64
  (match kind
    [(CompilerObjectSectionKind.Text)
      (bit-or compiler-object-elf-shf-alloc compiler-object-elf-shf-execinstr)]
    [(CompilerObjectSectionKind.Data)
      (bit-or compiler-object-elf-shf-alloc compiler-object-elf-shf-write)]
    [(CompilerObjectSectionKind.Rodata) compiler-object-elf-shf-alloc]
    [(CompilerObjectSectionKind.Bss)
      (bit-or compiler-object-elf-shf-alloc compiler-object-elf-shf-write)]
    [(CompilerObjectSectionKind.Pdata) 0]
    [(CompilerObjectSectionKind.Xdata) 0]
    [(CompilerObjectSectionKind.Rsrc) 0]))

(define (compiler-object-elf-push-section-header!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [name-offset : i64]
  [section-type : i64]
  [flags : i64]
  [addr : i64]
  [offset : i64]
  [size : i64]
  [link : i64]
  [info : i64]
  [align : i64]
  [entry-size : i64]) : unit
  (begin
    (compiler-object-elf-push-u32! out name-offset)
    (compiler-object-elf-push-u32! out section-type)
    (compiler-object-elf-push-i64! out flags)
    (compiler-object-elf-push-i64! out addr)
    (compiler-object-elf-push-i64! out offset)
    (compiler-object-elf-push-i64! out size)
    (compiler-object-elf-push-u32! out link)
    (compiler-object-elf-push-u32! out info)
    (compiler-object-elf-push-i64! out align)
    (compiler-object-elf-push-i64! out entry-size)))

(define (compiler-object-elf-push-load-section-header!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : CompilerObjectImage]
  [kind : CompilerObjectSectionKind]) : unit
  (let
    [index : i64 (compiler-object-elf-section-index kind)]
    (compiler-object-elf-push-section-header!
      out
      (compiler-object-elf-section-name-offset index)
      (match kind
        [(CompilerObjectSectionKind.Bss) compiler-object-elf-sht-nobits]
        [_ compiler-object-elf-sht-progbits])
      (compiler-object-elf-section-flags kind)
      0
      (compiler-object-elf-section-file-offset image kind)
      (compiler-object-elf-section-virtual-size image kind)
      0
      0
      (match kind
        [(CompilerObjectSectionKind.Text) 16]
        [_ 8])
      0)))

(define (compiler-object-elf-rela-section-index
  [kind : CompilerObjectSectionKind]) : i64
  (match kind
    [(CompilerObjectSectionKind.Text)
      compiler-object-elf-section-rela-text-index]
    [(CompilerObjectSectionKind.Data)
      compiler-object-elf-section-rela-data-index]
    [(CompilerObjectSectionKind.Rodata)
      compiler-object-elf-section-rela-rodata-index]
    [(CompilerObjectSectionKind.Bss) compiler-object-elf-section-rela-bss-index]
    [(CompilerObjectSectionKind.Pdata) compiler-object-elf-section-null-index]
    [(CompilerObjectSectionKind.Xdata) compiler-object-elf-section-null-index]
    [(CompilerObjectSectionKind.Rsrc) compiler-object-elf-section-null-index]))

(define (compiler-object-elf-push-rela-section-header!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : CompilerObjectImage]
  [kind : CompilerObjectSectionKind]) : unit
  (let
    [index : i64 (compiler-object-elf-rela-section-index kind)]
    (compiler-object-elf-push-section-header!
      out
      (compiler-object-elf-section-name-offset index)
      compiler-object-elf-sht-rela
      0
      0
      (compiler-object-elf-relocation-section-offset image kind)
      (compiler-object-elf-relocation-section-size image kind)
      compiler-object-elf-section-symtab-index
      (compiler-object-elf-section-index kind)
      8
      compiler-object-elf-relocation-size)))

(define (compiler-object-elf-push-section-headers!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : CompilerObjectImage]) : unit
  (begin
    (compiler-object-elf-render-padding-to!
      out
      (compiler-object-elf-section-header-offset image))
    (compiler-object-elf-push-section-header!
      out
      0
      compiler-object-elf-sht-null
      0
      0
      0
      0
      0
      0
      0
      0)
    (compiler-object-elf-push-load-section-header!
      out
      image
      (CompilerObjectSectionKind.Text))
    (compiler-object-elf-push-load-section-header!
      out
      image
      (CompilerObjectSectionKind.Data))
    (compiler-object-elf-push-load-section-header!
      out
      image
      (CompilerObjectSectionKind.Rodata))
    (compiler-object-elf-push-load-section-header!
      out
      image
      (CompilerObjectSectionKind.Bss))
    (compiler-object-elf-push-rela-section-header!
      out
      image
      (CompilerObjectSectionKind.Text))
    (compiler-object-elf-push-rela-section-header!
      out
      image
      (CompilerObjectSectionKind.Data))
    (compiler-object-elf-push-rela-section-header!
      out
      image
      (CompilerObjectSectionKind.Rodata))
    (compiler-object-elf-push-rela-section-header!
      out
      image
      (CompilerObjectSectionKind.Bss))
    (compiler-object-elf-push-section-header!
      out
      (compiler-object-elf-section-name-offset
        compiler-object-elf-section-symtab-index)
      compiler-object-elf-sht-symtab
      0
      0
      (compiler-object-elf-symtab-offset image)
      (compiler-object-elf-symbol-table-size image)
      compiler-object-elf-section-strtab-index
      (+ 1 (compiler-object-elf-local-symbol-count (struct-get image symbols)))
      8
      compiler-object-elf-symbol-size)
    (compiler-object-elf-push-section-header!
      out
      (compiler-object-elf-section-name-offset
        compiler-object-elf-section-strtab-index)
      compiler-object-elf-sht-strtab
      0
      0
      (compiler-object-elf-strtab-offset image)
      (compiler-object-elf-string-table-size (struct-get image symbols))
      0
      0
      1
      0)
    (compiler-object-elf-push-section-header!
      out
      (compiler-object-elf-section-name-offset
        compiler-object-elf-section-shstrtab-index)
      compiler-object-elf-sht-strtab
      0
      0
      (compiler-object-elf-shstrtab-offset image)
      compiler-object-elf-shstrtab-size
      0
      0
      1
      0)
    (compiler-object-elf-push-section-header!
      out
      (compiler-object-elf-section-name-offset
        compiler-object-elf-section-note-gnu-stack-index)
      compiler-object-elf-sht-progbits
      0
      0
      0
      0
      0
      0
      1
      0)))

(define (compiler-object-elf-bytes-string
  [out : (& out byte_buf_core.ByteBufBuilder)]) : String
  (byte_buf_core.byte-buf-builder-finish-string out))

(define (compiler-object-elf-render [image : CompilerObjectImage]) : ResultCompilerObjectElf
  (if (compiler-object-elf-image-supported? image)
    (let
      [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
      (begin
        (compiler-object-elf-push-header! (&mut out) image)
        (compiler-object-elf-render-loadable-sections! (&mut out) image)
        (compiler-object-elf-render-relocation-section!
          (&mut out)
          image
          (CompilerObjectSectionKind.Text))
        (compiler-object-elf-render-relocation-section!
          (&mut out)
          image
          (CompilerObjectSectionKind.Data))
        (compiler-object-elf-render-relocation-section!
          (&mut out)
          image
          (CompilerObjectSectionKind.Rodata))
        (compiler-object-elf-render-relocation-section!
          (&mut out)
          image
          (CompilerObjectSectionKind.Bss))
        (compiler-object-elf-render-symbol-table! (&mut out) image)
        (compiler-object-elf-render-string-tables! (&mut out) image)
        (compiler-object-elf-push-section-headers! (&mut out) image)
        (ResultCompilerObjectElf.Ok (compiler-object-elf-bytes-string (& out)))))
    (ResultCompilerObjectElf.Err
      "elf: object image contains unsupported text instructions or relocation records")))

(define (compiler-object-elf-u16-at [text : String] [offset : i64]) : i64
  (+
    (cast (compiler-object-elf-string-ref text offset) : i64)
    (shl (cast (compiler-object-elf-string-ref text (+ offset 1)) : i64) 8)))

(define (compiler-object-elf-u32-at [text : String] [offset : i64]) : i64
  (+
    (compiler-object-elf-u16-at text offset)
    (shl (compiler-object-elf-u16-at text (+ offset 2)) 16)))

(define (compiler-object-elf-u8-at [text : String] [offset : i64]) : i64
  (cast (compiler-object-elf-string-ref text offset) : i64))

(define (compiler-object-elf-section-header-start
  [image : CompilerObjectImage]
  [index : i64]) : i64
  (+
    (compiler-object-elf-section-header-offset image)
    (* compiler-object-elf-section-header-size index)))

(define (compiler-object-elf-section-header-size-at
  [text : String]
  [image : CompilerObjectImage]
  [index : i64]) : i64
  (compiler-object-elf-u32-at
    text
    (+ (compiler-object-elf-section-header-start image index) 32)))

(define (compiler-object-elf-rela-entry-offset
  [section-offset : i64]
  [index : i64]) : i64
  (+ section-offset (* compiler-object-elf-relocation-size index)))

(define (compiler-object-elf-rela-type-at
  [text : String]
  [section-offset : i64]
  [index : i64]) : i64
  (compiler-object-elf-u32-at
    text
    (+ (compiler-object-elf-rela-entry-offset section-offset index) 8)))

(define (compiler-object-elf-rela-target-offset-at
  [text : String]
  [section-offset : i64]
  [index : i64]) : i64
  (compiler-object-elf-u32-at
    text
    (compiler-object-elf-rela-entry-offset section-offset index)))

(define (compiler-object-elf-rela-addend-rel32?
  [text : String]
  [section-offset : i64]
  [index : i64]) : bool
  (let
    [entry : i64 (compiler-object-elf-rela-entry-offset section-offset index)]
    (and
      (= (compiler-object-elf-u32-at text (+ entry 16)) 0xfffffffc)
      (= (compiler-object-elf-u32-at text (+ entry 20)) 0xffffffff))))

(define (compiler-object-elf-prefix-at?
  [text : String]
  [needle : String]
  [start : i64]) : bool
  (let
    [text-len : i64 (compiler-object-elf-string-length text)]
    [needle-len : i64 (compiler-object-elf-string-length needle)]
    (if (> (+ start needle-len) text-len)
      false
      (let
        [i : i64 0]
        [ok : bool true]
        (begin
          (while ok
            (if (< i needle-len)
              (if (=
                (compiler-object-elf-string-ref text (+ start i))
                (compiler-object-elf-string-ref needle i))
                (set! i (+ i 1))
                (set! ok false))
              (set! ok false)))
          (= i needle-len))))))

(define (compiler-object-elf-contains? [text : String] [needle : String]) : bool
  (let
    [i : i64 0]
    [n : i64 (compiler-object-elf-string-length text)]
    [found : bool false]
    (begin
      (while (and (not found) (< i n))
        (begin
          (if (compiler-object-elf-prefix-at? text needle i)
            (set! found true)
            unit)
          (set! i (+ i 1))))
      found)))

(define (compiler-object-elf-ret-bytes) : String
  (let
    [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    (begin
      (compiler-object-elf-push-u8! (&mut out) 0xc3)
      (compiler-object-elf-bytes-string (& out)))))

(define (compiler-object-elf-text-smoke-instrs) : CompilerObjectX64InstrList
  (compiler-object-instr-cons
    (CompilerObjectX64Instr.Label "_tl_text")
    (compiler-object-instr-cons
      (CompilerObjectX64Instr.Call "foreign_exact")
      (compiler-object-instr-cons
        (CompilerObjectX64Instr.LoadRip "_tl_cell")
        (compiler-object-instr-cons
          (CompilerObjectX64Instr.LoadRipAddress "_tl_message")
          (compiler-object-instr-cons
            (CompilerObjectX64Instr.StoreRip "_tl_cell")
            (compiler-object-instr-cons
              (CompilerObjectX64Instr.Branch ".L_true" ".L_false")
              (compiler-object-instr-cons
                (CompilerObjectX64Instr.Label ".L_true")
                (compiler-object-instr-cons
                  (CompilerObjectX64Instr.Jump ".L_done")
                  (compiler-object-instr-cons
                    (CompilerObjectX64Instr.Label ".L_false")
                    (compiler-object-instr-cons
                      (CompilerObjectX64Instr.TailCall "_tl_text")
                      (compiler-object-instr-cons
                        (CompilerObjectX64Instr.Label ".L_done")
                        (compiler-object-instr-cons
                          (CompilerObjectX64Instr.SubRspImm8 8)
                          (compiler-object-instr-cons
                            (CompilerObjectX64Instr.MovRcxRip "_tl_cell")
                            (compiler-object-instr-cons
                              (CompilerObjectX64Instr.MovRdxRip "_tl_message")
                              (compiler-object-instr-cons
                                (CompilerObjectX64Instr.MovRcxRax)
                                (compiler-object-instr-cons
                                  (CompilerObjectX64Instr.Raw
                                    (compiler-object-elf-ret-bytes))
                                  CompilerObjectX64InstrList.Nil)))))))))))))))))

(define (compiler-object-elf-text-smoke-relocations) : CompilerObjectRelocationList
  (compiler-object-relocation-cons
    (CompilerObjectRelocation.Relocation
      (CompilerObjectSectionKind.Text)
      "_tl_text"
      (CompilerObjectRelocationKind.Call)
      "foreign_exact")
    (compiler-object-relocation-cons
      (CompilerObjectRelocation.Relocation
        (CompilerObjectSectionKind.Text)
        "_tl_text"
        (CompilerObjectRelocationKind.RipValue)
        "_tl_cell")
      (compiler-object-relocation-cons
        (CompilerObjectRelocation.Relocation
          (CompilerObjectSectionKind.Text)
          "_tl_text"
          (CompilerObjectRelocationKind.RipAddress)
          "_tl_message")
        (compiler-object-relocation-cons
          (CompilerObjectRelocation.Relocation
            (CompilerObjectSectionKind.Text)
            "_tl_text"
            (CompilerObjectRelocationKind.RipAddress)
            "_tl_cell")
          (compiler-object-relocation-cons
            (CompilerObjectRelocation.Relocation
              (CompilerObjectSectionKind.Text)
              "_tl_text"
              (CompilerObjectRelocationKind.Branch)
              ".L_true")
            (compiler-object-relocation-cons
              (CompilerObjectRelocation.Relocation
                (CompilerObjectSectionKind.Text)
                "_tl_text"
                (CompilerObjectRelocationKind.Branch)
                ".L_false")
              (compiler-object-relocation-cons
                (CompilerObjectRelocation.Relocation
                  (CompilerObjectSectionKind.Text)
                  "_tl_text"
                  (CompilerObjectRelocationKind.Branch)
                  ".L_done")
                (compiler-object-relocation-cons
                  (CompilerObjectRelocation.Relocation
                    (CompilerObjectSectionKind.Text)
                    "_tl_text"
                    (CompilerObjectRelocationKind.TailCall)
                    "_tl_text")
                  (compiler-object-relocation-cons
                    (CompilerObjectRelocation.Relocation
                      (CompilerObjectSectionKind.Text)
                      "_tl_text"
                      (CompilerObjectRelocationKind.RipValue)
                      "_tl_cell")
                    (compiler-object-relocation-cons
                      (CompilerObjectRelocation.Relocation
                        (CompilerObjectSectionKind.Text)
                        "_tl_text"
                        (CompilerObjectRelocationKind.RipValue)
                        "_tl_message")
                      CompilerObjectRelocationList.Nil)))))))))))

(define (compiler-object-elf-text-smoke-image) : CompilerObjectImage
  (CompilerObjectImage
    (compiler-object-section-cons
      (CompilerObjectSection.Section
        (CompilerObjectSectionKind.Text)
        CompilerObjectDataRecordList.Nil
        (compiler-object-elf-text-smoke-instrs))
      (compiler-object-section-cons
        (CompilerObjectSection.Section
          (CompilerObjectSectionKind.Data)
          (compiler-object-data-cons
            (CompilerObjectDataRecord.Label "_tl_cell")
            (compiler-object-data-cons
              (CompilerObjectDataRecord.I64 0)
              CompilerObjectDataRecordList.Nil))
          CompilerObjectX64InstrList.Nil)
        (compiler-object-section-cons
          (CompilerObjectSection.Section
            (CompilerObjectSectionKind.Rodata)
            (compiler-object-data-cons
              (CompilerObjectDataRecord.Label "_tl_message")
              (compiler-object-data-cons
                (CompilerObjectDataRecord.String "ok")
                CompilerObjectDataRecordList.Nil))
            CompilerObjectX64InstrList.Nil)
          (compiler-object-section-cons
            (CompilerObjectSection.Section
              (CompilerObjectSectionKind.Bss)
              CompilerObjectDataRecordList.Nil
              CompilerObjectX64InstrList.Nil)
            CompilerObjectSectionList.Nil))))
    (compiler-object-symbol-cons
      (CompilerObjectSymbol.Symbol
        ".L_true"
        (CompilerObjectSymbolBinding.Local)
        (CompilerObjectSymbolKind.Function)
        (CompilerObjectMaybeSection.Some (CompilerObjectSectionKind.Text)))
      (compiler-object-symbol-cons
        (CompilerObjectSymbol.Symbol
          ".L_false"
          (CompilerObjectSymbolBinding.Local)
          (CompilerObjectSymbolKind.Function)
          (CompilerObjectMaybeSection.Some (CompilerObjectSectionKind.Text)))
        (compiler-object-symbol-cons
          (CompilerObjectSymbol.Symbol
            ".L_done"
            (CompilerObjectSymbolBinding.Local)
            (CompilerObjectSymbolKind.Function)
            (CompilerObjectMaybeSection.Some (CompilerObjectSectionKind.Text)))
          (compiler-object-symbol-cons
            (CompilerObjectSymbol.Symbol
              "_tl_message"
              (CompilerObjectSymbolBinding.Local)
              (CompilerObjectSymbolKind.Data)
              (CompilerObjectMaybeSection.Some
                (CompilerObjectSectionKind.Rodata)))
            (compiler-object-symbol-cons
              (CompilerObjectSymbol.Symbol
                "_tl_text"
                (CompilerObjectSymbolBinding.Export)
                (CompilerObjectSymbolKind.Function)
                (CompilerObjectMaybeSection.Some
                  (CompilerObjectSectionKind.Text)))
              (compiler-object-symbol-cons
                (CompilerObjectSymbol.Symbol
                  "_tl_cell"
                  (CompilerObjectSymbolBinding.Export)
                  (CompilerObjectSymbolKind.Data)
                  (CompilerObjectMaybeSection.Some
                    (CompilerObjectSectionKind.Data)))
                (compiler-object-symbol-cons
                  (CompilerObjectSymbol.Symbol
                    "foreign_exact"
                    (CompilerObjectSymbolBinding.Extern)
                    (CompilerObjectSymbolKind.Function)
                    (CompilerObjectMaybeSection.No))
                  CompilerObjectSymbolList.Nil)))))))
    (compiler-object-elf-text-smoke-relocations)))

(define (compiler-object-elf-smoke-image) : CompilerObjectImage
  (CompilerObjectImage
    (compiler-object-section-cons
      (CompilerObjectSection.Section
        (CompilerObjectSectionKind.Text)
        CompilerObjectDataRecordList.Nil
        (compiler-object-instr-cons
          (CompilerObjectX64Instr.Label "_tl_empty")
          (compiler-object-instr-cons
            (CompilerObjectX64Instr.Raw (compiler-object-elf-ret-bytes))
            CompilerObjectX64InstrList.Nil)))
      (compiler-object-section-cons
        (CompilerObjectSection.Section
          (CompilerObjectSectionKind.Data)
          (compiler-object-data-cons
            (CompilerObjectDataRecord.Label "_tl_cell")
            (compiler-object-data-cons
              (CompilerObjectDataRecord.SymbolAddress "_tl_message")
              (compiler-object-data-cons
                (CompilerObjectDataRecord.I64 99)
                CompilerObjectDataRecordList.Nil)))
          CompilerObjectX64InstrList.Nil)
        (compiler-object-section-cons
          (CompilerObjectSection.Section
            (CompilerObjectSectionKind.Rodata)
            (compiler-object-data-cons
              (CompilerObjectDataRecord.Label "_tl_message")
              (compiler-object-data-cons
                (CompilerObjectDataRecord.String "ok")
                (compiler-object-data-cons
                  (CompilerObjectDataRecord.Align 8)
                  (compiler-object-data-cons
                    (CompilerObjectDataRecord.Label "_tl_pi")
                    (compiler-object-data-cons
                      (CompilerObjectDataRecord.F64 0x400c000000000000)
                      CompilerObjectDataRecordList.Nil)))))
            CompilerObjectX64InstrList.Nil)
          (compiler-object-section-cons
            (CompilerObjectSection.Section
              (CompilerObjectSectionKind.Bss)
              (compiler-object-data-cons
                (CompilerObjectDataRecord.Label "_tl_zero")
                (compiler-object-data-cons
                  (CompilerObjectDataRecord.Zero 16)
                  CompilerObjectDataRecordList.Nil))
              CompilerObjectX64InstrList.Nil)
            CompilerObjectSectionList.Nil))))
    (compiler-object-symbol-cons
      (CompilerObjectSymbol.Symbol
        "_tl_empty"
        (CompilerObjectSymbolBinding.Export)
        (CompilerObjectSymbolKind.Function)
        (CompilerObjectMaybeSection.Some (CompilerObjectSectionKind.Text)))
      (compiler-object-symbol-cons
        (CompilerObjectSymbol.Symbol
          "_tl_cell"
          (CompilerObjectSymbolBinding.Export)
          (CompilerObjectSymbolKind.Data)
          (CompilerObjectMaybeSection.Some (CompilerObjectSectionKind.Data)))
        (compiler-object-symbol-cons
          (CompilerObjectSymbol.Symbol
            "_tl_message"
            (CompilerObjectSymbolBinding.Local)
            (CompilerObjectSymbolKind.Data)
            (CompilerObjectMaybeSection.Some (CompilerObjectSectionKind.Rodata)))
          (compiler-object-symbol-cons
            (CompilerObjectSymbol.Symbol
              "_tl_zero"
              (CompilerObjectSymbolBinding.Export)
              (CompilerObjectSymbolKind.Data)
              (CompilerObjectMaybeSection.Some (CompilerObjectSectionKind.Bss)))
            (compiler-object-symbol-cons
              (CompilerObjectSymbol.Symbol
                "foreign_exact"
                (CompilerObjectSymbolBinding.Extern)
                (CompilerObjectSymbolKind.Function)
                (CompilerObjectMaybeSection.No))
              CompilerObjectSymbolList.Nil)))))
    (compiler-object-relocation-cons
      (CompilerObjectRelocation.Relocation
        (CompilerObjectSectionKind.Data)
        "_tl_cell"
        (CompilerObjectRelocationKind.Abs64)
        "_tl_message")
      CompilerObjectRelocationList.Nil)))

(define (compiler-object-elf-smoke-ok?) : bool
  (match (compiler-object-elf-render (compiler-object-elf-smoke-image))
    [(ResultCompilerObjectElf.Ok obj)
      (and
        (=
          (compiler-object-elf-string-length obj)
          (+
            (compiler-object-elf-section-header-offset
              (compiler-object-elf-smoke-image))
            (*
              compiler-object-elf-section-header-size
              compiler-object-elf-section-count)))
        (= (cast (compiler-object-elf-string-ref obj 0) : i64) 0x7f)
        (= (cast (compiler-object-elf-string-ref obj 1) : i64) 0x45)
        (= (compiler-object-elf-u16-at obj 18) 62)
        (=
          (compiler-object-elf-u16-at obj 58)
          compiler-object-elf-section-header-size)
        (=
          (compiler-object-elf-u16-at obj 60)
          compiler-object-elf-section-count)
        (compiler-object-elf-contains? obj ".rela.data")
        (compiler-object-elf-contains? obj ".note.GNU-stack")
        (compiler-object-elf-contains? obj "_tl_message")
        (compiler-object-elf-contains? obj "foreign_exact"))]
    [(ResultCompilerObjectElf.Err _) false]))

(define (compiler-object-elf-text-smoke-ok?) : bool
  (let
    [image : CompilerObjectImage (compiler-object-elf-text-smoke-image)]
    (match (compiler-object-elf-render image)
      [(ResultCompilerObjectElf.Ok obj)
        (let
          [text-offset : i64 (compiler-object-elf-text-offset image)]
          [rela-offset : i64 (compiler-object-elf-rela-text-offset image)]
          (and
            (=
              (compiler-object-elf-section-header-size-at
                obj
                image
                compiler-object-elf-section-text-index)
              72)
            (=
              (compiler-object-elf-section-header-size-at
                obj
                image
                compiler-object-elf-section-rela-text-index)
              (* 10 compiler-object-elf-relocation-size))
            (= (compiler-object-elf-u8-at obj text-offset) 0xe8)
            (= (compiler-object-elf-u8-at obj (+ text-offset 26)) 0x48)
            (= (compiler-object-elf-u8-at obj (+ text-offset 27)) 0x85)
            (= (compiler-object-elf-u8-at obj (+ text-offset 28)) 0xc0)
            (= (compiler-object-elf-rela-target-offset-at obj rela-offset 0) 1)
            (=
              (compiler-object-elf-rela-type-at obj rela-offset 0)
              compiler-object-elf-r-x86-64-plt32)
            (compiler-object-elf-rela-addend-rel32? obj rela-offset 0)
            (= (compiler-object-elf-rela-target-offset-at obj rela-offset 1) 8)
            (=
              (compiler-object-elf-rela-type-at obj rela-offset 1)
              compiler-object-elf-r-x86-64-pc32)
            (compiler-object-elf-rela-addend-rel32? obj rela-offset 1)
            (= (compiler-object-elf-rela-target-offset-at obj rela-offset 5) 36)
            (=
              (compiler-object-elf-rela-type-at obj rela-offset 5)
              compiler-object-elf-r-x86-64-pc32)
            (compiler-object-elf-rela-addend-rel32? obj rela-offset 5)
            (compiler-object-elf-contains? obj "_tl_cell")
            (compiler-object-elf-contains? obj "foreign_exact")))]
      [(ResultCompilerObjectElf.Err _) false])))