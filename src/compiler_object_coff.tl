;; compiler_object_coff.tl - COFF object-file serialization for object images.
(import stdlib.byte_buf_core)
(import stdlib.string)
(import "compiler_object.tl")

(define (compiler-object-coff-string-length [text : String]) : i64
  (cfg
    feature-compiler-private-string-intrinsics
    (__tl_string_length text)
    (string.string-length text)))

(define (compiler-object-coff-string-ref [text : String] [index : i64]) : char
  (cfg
    feature-compiler-private-string-intrinsics
    (__tl_string_ref text index)
    (string.string-ref text index)))

(defenum ResultCompilerObjectCoff
  (Ok String)
  (Err String))

(define compiler-object-coff-machine-amd64 : i64
  0x8664)
(define compiler-object-coff-section-count : i64
  7)
(define compiler-object-coff-file-header-size : i64
  20)
(define compiler-object-coff-section-header-size : i64
  40)
(define compiler-object-coff-relocation-size : i64
  10)
(define compiler-object-coff-symbol-size : i64
  18)
(define compiler-object-coff-reloc-amd64-addr64 : i64
  0x0001)
(define compiler-object-coff-reloc-amd64-rel32 : i64
  0x0004)
(define compiler-object-coff-reloc-amd64-addr32nb : i64
  0x0003)
(define compiler-object-coff-section-cnt-code : i64
  0x00000020)
(define compiler-object-coff-section-cnt-initialized-data : i64
  0x00000040)
(define compiler-object-coff-section-cnt-uninitialized-data : i64
  0x00000080)
(define compiler-object-coff-section-align-8 : i64
  0x00400000)
(define compiler-object-coff-section-align-16 : i64
  0x00500000)
(define compiler-object-coff-section-mem-execute : i64
  0x20000000)
(define compiler-object-coff-section-mem-read : i64
  0x40000000)
(define compiler-object-coff-section-mem-write : i64
  0x80000000)

(define (compiler-object-coff-section-name [kind : CompilerObjectSectionKind]) : String
  (match kind
    [(CompilerObjectSectionKind.Text) ".text"]
    [(CompilerObjectSectionKind.Data) ".data"]
    [(CompilerObjectSectionKind.Rodata) ".rdata"]
    [(CompilerObjectSectionKind.Bss) ".bss"]
    [(CompilerObjectSectionKind.Pdata) ".pdata"]
    [(CompilerObjectSectionKind.Xdata) ".xdata"]
    [(CompilerObjectSectionKind.Rsrc) ".rsrc"]))

(define (compiler-object-coff-section-number [kind : CompilerObjectSectionKind]) : i64
  (match kind
    [(CompilerObjectSectionKind.Text) 1]
    [(CompilerObjectSectionKind.Data) 2]
    [(CompilerObjectSectionKind.Rodata) 3]
    [(CompilerObjectSectionKind.Bss) 4]
    [(CompilerObjectSectionKind.Pdata) 5]
    [(CompilerObjectSectionKind.Xdata) 6]
    [(CompilerObjectSectionKind.Rsrc) 7]))

(define (compiler-object-coff-section-flags [kind : CompilerObjectSectionKind]) : i64
  (match kind
    [(CompilerObjectSectionKind.Text)
      (bit-or
        compiler-object-coff-section-cnt-code
        (bit-or
          compiler-object-coff-section-align-16
          (bit-or
            compiler-object-coff-section-mem-execute
            compiler-object-coff-section-mem-read)))]
    [(CompilerObjectSectionKind.Data)
      (bit-or
        compiler-object-coff-section-cnt-initialized-data
        (bit-or
          compiler-object-coff-section-align-8
          (bit-or
            compiler-object-coff-section-mem-read
            compiler-object-coff-section-mem-write)))]
    [(CompilerObjectSectionKind.Rodata)
      (bit-or
        compiler-object-coff-section-cnt-initialized-data
        (bit-or
          compiler-object-coff-section-align-8
          compiler-object-coff-section-mem-read))]
    [(CompilerObjectSectionKind.Bss)
      (bit-or
        compiler-object-coff-section-cnt-uninitialized-data
        (bit-or
          compiler-object-coff-section-align-8
          (bit-or
            compiler-object-coff-section-mem-read
            compiler-object-coff-section-mem-write)))]
    [(CompilerObjectSectionKind.Pdata)
      (bit-or
        compiler-object-coff-section-cnt-initialized-data
        (bit-or
          compiler-object-coff-section-align-8
          compiler-object-coff-section-mem-read))]
    [(CompilerObjectSectionKind.Xdata)
      (bit-or
        compiler-object-coff-section-cnt-initialized-data
        (bit-or
          compiler-object-coff-section-align-8
          compiler-object-coff-section-mem-read))]
    [(CompilerObjectSectionKind.Rsrc)
      (bit-or
        compiler-object-coff-section-cnt-initialized-data
        (bit-or
          compiler-object-coff-section-align-8
          compiler-object-coff-section-mem-read))]))

(define (compiler-object-coff-byte [value : i64]) : u8
  (cast (bit-and value 0xff) : u8))

(define (compiler-object-coff-push-u8!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (byte_buf_core.byte-buf-builder-push out (compiler-object-coff-byte value)))

(define (compiler-object-coff-push-u16!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (begin
    (compiler-object-coff-push-u8! out value)
    (compiler-object-coff-push-u8! out (shr value 8))))

(define (compiler-object-coff-push-u32!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (begin
    (compiler-object-coff-push-u8! out value)
    (compiler-object-coff-push-u8! out (shr value 8))
    (compiler-object-coff-push-u8! out (shr value 16))
    (compiler-object-coff-push-u8! out (shr value 24))))

(define (compiler-object-coff-push-u64!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (begin
    (compiler-object-coff-push-u32! out value)
    (compiler-object-coff-push-u32! out (shr value 32))))

(define (compiler-object-coff-push-zeroes!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [count : i64]) : unit
  (let
    [i : i64 0]
    (begin
      (while (< i count)
        (begin
          (compiler-object-coff-push-u8! out 0)
          (set! i (+ i 1))))
      unit)))

(define (compiler-object-coff-push-string-bytes!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [text : String]) : unit
  (let
    [i : i64 0]
    [n : i64 (compiler-object-coff-string-length text)]
    (begin
      (while (< i n)
        (begin
          (byte_buf_core.byte-buf-builder-push
            out
            (cast (compiler-object-coff-string-ref text i) : u8))
          (set! i (+ i 1))))
      unit)))

(define (compiler-object-coff-push-name8!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [name : String]) : unit
  (let
    [i : i64 0]
    [n : i64 (compiler-object-coff-string-length name)]
    (begin
      (while (< i 8)
        (begin
          (if (< i n)
            (byte_buf_core.byte-buf-builder-push
              out
              (cast (compiler-object-coff-string-ref name i) : u8))
            (compiler-object-coff-push-u8! out 0))
          (set! i (+ i 1))))
      unit)))

(define (compiler-object-coff-align-offset [offset : i64] [align : i64]) : i64
  (if (<= align 1)
    offset
    (let
      [rem : i64 (% offset align)]
      (if (= rem 0)
        offset
        (+ offset (- align rem))))))

(define (compiler-object-coff-data-record-end-offset
  [record : CompilerObjectDataRecord]
  [offset : i64]) : i64
  (match record
    [(CompilerObjectDataRecord.Label _) offset]
    [(CompilerObjectDataRecord.Align align)
      (compiler-object-coff-align-offset offset align)]
    [(CompilerObjectDataRecord.Bytes bytes)
      (+ offset (compiler-object-coff-string-length bytes))]
    [(CompilerObjectDataRecord.String text)
      (+ offset (compiler-object-coff-string-length text))]
    [(CompilerObjectDataRecord.F64 _) (+ offset 8)]
    [(CompilerObjectDataRecord.F32 _) (+ offset 4)]
    [(CompilerObjectDataRecord.I64 _) (+ offset 8)]
    [(CompilerObjectDataRecord.Zero count) (+ offset count)]
    [(CompilerObjectDataRecord.SymbolAddress _) (+ offset 8)]
    [(CompilerObjectDataRecord.SymbolRva32 _) (+ offset 4)]))

(define (compiler-object-coff-data-records-size-from
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
            (compiler-object-coff-data-record-end-offset
              (compiler-object-data-record-list-ref records index)
              cur-offset))
          (set! index (+ index 1))))
      cur-offset)))

(define (compiler-object-coff-data-records-size
  [records : CompilerObjectDataRecordList]) : i64
  (compiler-object-coff-data-records-size-from records 0))

(define (compiler-object-coff-instr-size [instr : CompilerObjectX64Instr]) : i64
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
      (compiler-object-coff-string-length bytes)]
    [(CompilerObjectX64Instr.Raw _) 0]
    [_ 0]))

(define (compiler-object-coff-instr-relocation-count
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

(define (compiler-object-coff-instrs-relocation-count
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
              (compiler-object-coff-instr-relocation-count
                (compiler-object-instr-list-ref instrs index))))
          (set! index (+ index 1))))
      total)))

(define (compiler-object-coff-instrs-size-from
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
              (compiler-object-coff-instr-size
                (compiler-object-instr-list-ref instrs index))))
          (set! index (+ index 1))))
      cur-offset)))

(define (compiler-object-coff-instrs-size [instrs : CompilerObjectX64InstrList]) : i64
  (compiler-object-coff-instrs-size-from instrs 0))

(define (compiler-object-coff-section-virtual-size
  [image : CompilerObjectImage]
  [kind : CompilerObjectSectionKind]) : i64
  (match (compiler-object-section-list-find (struct-get image sections) kind)
    [(CompilerObjectSection.Section _ data instrs)
      (match kind
        [(CompilerObjectSectionKind.Text)
          (compiler-object-coff-instrs-size instrs)]
        [_ (compiler-object-coff-data-records-size data)])]))

(define (compiler-object-coff-section-raw-size
  [image : CompilerObjectImage]
  [kind : CompilerObjectSectionKind]) : i64
  (match kind
    [(CompilerObjectSectionKind.Bss) 0]
    [_ (compiler-object-coff-section-virtual-size image kind)]))

(define (compiler-object-coff-text-relocation-kind-supported?
  [kind : CompilerObjectRelocationKind]) : bool
  (match kind
    [(CompilerObjectRelocationKind.Call) true]
    [(CompilerObjectRelocationKind.TailCall) true]
    [(CompilerObjectRelocationKind.RipValue) true]
    [(CompilerObjectRelocationKind.RipAddress) true]
    [(CompilerObjectRelocationKind.Branch) true]
    [_ false]))

(define (compiler-object-coff-data-relocation-kind-supported?
  [kind : CompilerObjectRelocationKind]) : bool
  (match kind
    [(CompilerObjectRelocationKind.Abs64) true]
    [(CompilerObjectRelocationKind.Addr32Nb) true]
    [_ false]))

(define (compiler-object-coff-relocation-supported?
  [reloc : CompilerObjectRelocation]) : bool
  (match reloc
    [(CompilerObjectRelocation.Relocation section _ kind _)
      (match section
        [(CompilerObjectSectionKind.Text)
          (compiler-object-coff-text-relocation-kind-supported? kind)]
        [_ (compiler-object-coff-data-relocation-kind-supported? kind)])]))

(define (compiler-object-coff-relocation-list-supported?
  [relocs : CompilerObjectRelocationList]) : bool
  (let
    [count : i64 (compiler-object-relocation-list-count relocs)]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (if (compiler-object-coff-relocation-supported?
          (compiler-object-relocation-list-ref relocs index))
          (set! index (+ index 1))
          (set! ok false)))
      ok)))

(define (compiler-object-coff-data-records-supported?
  [records : CompilerObjectDataRecordList]) : bool
  (let
    [count : i64 (compiler-object-data-record-list-count records)]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (match (compiler-object-data-record-list-ref records index)
          [_ (set! index (+ index 1))]))
      ok)))

(define (compiler-object-coff-instrs-supported?
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
          [(CompilerObjectX64Instr.Raw _) (set! ok false)]))
      ok)))

(define (compiler-object-coff-sections-supported?
  [sections : CompilerObjectSectionList]) : bool
  (let
    [count : i64 (compiler-object-section-list-count sections)]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (match (compiler-object-section-list-ref sections index)
          [(CompilerObjectSection.Section _ data instrs)
            (if (and
              (compiler-object-coff-data-records-supported? data)
              (compiler-object-coff-instrs-supported? instrs))
              (set! index (+ index 1))
              (set! ok false))]))
      ok)))

(define (compiler-object-coff-symbol-index-from
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
          [(CompilerObjectSymbol.Symbol found _ _ _)
            (if (string.string-eq found name)
              (begin
                (set! result cur-index)
                (set! done true))
              (begin
                (set! cur-index (+ cur-index 1))
                (set! slot (+ slot 1))))]))
      result)))

(define (compiler-object-coff-symbol-index
  [image : CompilerObjectImage]
  [name : String]) : i64
  (compiler-object-coff-symbol-index-from (struct-get image symbols) name 0))

(define (compiler-object-coff-data-label-offset-from
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
              (if (string.string-eq found label)
                (begin
                  (set! result cur-offset)
                  (set! done true))
                (set! index (+ index 1)))]
            [_
              (begin
                (set!
                  cur-offset
                  (compiler-object-coff-data-record-end-offset
                    record
                    cur-offset))
                (set! index (+ index 1)))])))
      result)))

(define (compiler-object-coff-instr-label-offset-from
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
              (if (string.string-eq found label)
                (begin
                  (set! result cur-offset)
                  (set! done true))
                (set! index (+ index 1)))]
            [_
              (begin
                (set!
                  cur-offset
                  (+ cur-offset (compiler-object-coff-instr-size instr)))
                (set! index (+ index 1)))])))
      result)))

(define (compiler-object-coff-section-label-offset
  [image : CompilerObjectImage]
  [kind : CompilerObjectSectionKind]
  [label : String]) : i64
  (match (compiler-object-section-list-find (struct-get image sections) kind)
    [(CompilerObjectSection.Section _ data instrs)
      (match kind
        [(CompilerObjectSectionKind.Text)
          (compiler-object-coff-instr-label-offset-from instrs label 0)]
        [_ (compiler-object-coff-data-label-offset-from data label 0)])]))

(define (compiler-object-coff-relocation-sites-known?
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
            (if (match section
              [(CompilerObjectSectionKind.Text)
                (>= (compiler-object-coff-symbol-index image target) 0)]
              [_
                (and
                  (>=
                    (compiler-object-coff-section-label-offset
                      image
                      section
                      site)
                    0)
                  (>= (compiler-object-coff-symbol-index image target) 0))])
              (set! index (+ index 1))
              (set! ok false))]))
      ok)))

(define (compiler-object-coff-instr-targets-known?
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
            (if (>= (compiler-object-coff-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(CompilerObjectX64Instr.TailCall target)
            (if (>= (compiler-object-coff-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(CompilerObjectX64Instr.Jump target)
            (if (>= (compiler-object-coff-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(CompilerObjectX64Instr.Ja target)
            (if (>= (compiler-object-coff-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(CompilerObjectX64Instr.Branch true-target false-target)
            (if (and
              (>= (compiler-object-coff-symbol-index image true-target) 0)
              (>= (compiler-object-coff-symbol-index image false-target) 0))
              (set! index (+ index 1))
              (set! ok false))]
          [(CompilerObjectX64Instr.LoadRip target)
            (if (>= (compiler-object-coff-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(CompilerObjectX64Instr.LoadRipAddress target)
            (if (>= (compiler-object-coff-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(CompilerObjectX64Instr.LoadRipAddressR11 target)
            (if (>= (compiler-object-coff-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(CompilerObjectX64Instr.StoreRip target)
            (if (>= (compiler-object-coff-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(CompilerObjectX64Instr.SubRspImm8 _) (set! index (+ index 1))]
          [(CompilerObjectX64Instr.MovRcxRip target)
            (if (>= (compiler-object-coff-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(CompilerObjectX64Instr.MovRdxRip target)
            (if (>= (compiler-object-coff-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(CompilerObjectX64Instr.LoadRipAddressRdx target)
            (if (>= (compiler-object-coff-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(CompilerObjectX64Instr.StoreR14Rip target)
            (if (>= (compiler-object-coff-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(CompilerObjectX64Instr.StoreR15Rip target)
            (if (>= (compiler-object-coff-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(CompilerObjectX64Instr.AddRcxRip target)
            (if (>= (compiler-object-coff-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(CompilerObjectX64Instr.MovRcxRax) (set! index (+ index 1))]
          [(CompilerObjectX64Instr.XorpdRip target)
            (if (>= (compiler-object-coff-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(CompilerObjectX64Instr.Bytes _) (set! index (+ index 1))]
          [(CompilerObjectX64Instr.Raw _) (set! ok false)]))
      ok)))

(define (compiler-object-coff-text-targets-known? [image : CompilerObjectImage]) : bool
  (match (compiler-object-section-list-find
    (struct-get image sections)
    (CompilerObjectSectionKind.Text))
    [(CompilerObjectSection.Section _ _ instrs)
      (compiler-object-coff-instr-targets-known? image instrs)]))

(define (compiler-object-coff-text-instr-relocation-count
  [image : CompilerObjectImage]) : i64
  (match (compiler-object-section-list-find
    (struct-get image sections)
    (CompilerObjectSectionKind.Text))
    [(CompilerObjectSection.Section _ _ instrs)
      (compiler-object-coff-instrs-relocation-count instrs)]))

(define (compiler-object-coff-text-relocation-count-matches?
  [image : CompilerObjectImage]) : bool
  (=
    (compiler-object-coff-relocation-count
      (struct-get image relocations)
      (CompilerObjectSectionKind.Text))
    (compiler-object-coff-text-instr-relocation-count image)))

(define (compiler-object-coff-image-supported? [image : CompilerObjectImage]) : bool
  (and
    (compiler-object-coff-sections-supported? (struct-get image sections))
    (compiler-object-coff-relocation-list-supported?
      (struct-get image relocations))
    (compiler-object-coff-relocation-sites-known?
      image
      (struct-get image relocations))
    (compiler-object-coff-text-targets-known? image)
    (compiler-object-coff-text-relocation-count-matches? image)))

(define (compiler-object-coff-header-size) : i64
  (+
    compiler-object-coff-file-header-size
    (*
      compiler-object-coff-section-header-size
      compiler-object-coff-section-count)))

(define (compiler-object-coff-relocation-count
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

(define (compiler-object-coff-section-relocation-count
  [image : CompilerObjectImage]
  [kind : CompilerObjectSectionKind]) : i64
  (match kind
    [(CompilerObjectSectionKind.Text)
      (compiler-object-coff-text-instr-relocation-count image)]
    [_
      (compiler-object-coff-relocation-count
        (struct-get image relocations)
        kind)]))

(define (compiler-object-coff-total-relocation-count
  [image : CompilerObjectImage]) : i64
  (+
    (compiler-object-coff-section-relocation-count
      image
      (CompilerObjectSectionKind.Text))
    (+
      (compiler-object-coff-section-relocation-count
        image
        (CompilerObjectSectionKind.Data))
      (+
        (compiler-object-coff-section-relocation-count
          image
          (CompilerObjectSectionKind.Rodata))
        (+
          (compiler-object-coff-section-relocation-count
            image
            (CompilerObjectSectionKind.Bss))
          (+
            (compiler-object-coff-section-relocation-count
              image
              (CompilerObjectSectionKind.Pdata))
            (+
              (compiler-object-coff-section-relocation-count
                image
                (CompilerObjectSectionKind.Xdata))
              (compiler-object-coff-section-relocation-count
                image
                (CompilerObjectSectionKind.Rsrc)))))))))

(define (compiler-object-coff-raw-base-after-section
  [image : CompilerObjectImage]
  [kind : CompilerObjectSectionKind]) : i64
  (match kind
    [(CompilerObjectSectionKind.Text) (compiler-object-coff-header-size)]
    [(CompilerObjectSectionKind.Data)
      (+
        (compiler-object-coff-header-size)
        (compiler-object-coff-section-raw-size
          image
          (CompilerObjectSectionKind.Text)))]
    [(CompilerObjectSectionKind.Rodata)
      (+
        (compiler-object-coff-header-size)
        (+
          (compiler-object-coff-section-raw-size
            image
            (CompilerObjectSectionKind.Text))
          (compiler-object-coff-section-raw-size
            image
            (CompilerObjectSectionKind.Data))))]
    [(CompilerObjectSectionKind.Bss) 0]
    [(CompilerObjectSectionKind.Pdata)
      (+
        (compiler-object-coff-header-size)
        (+
          (compiler-object-coff-section-raw-size
            image
            (CompilerObjectSectionKind.Text))
          (+
            (compiler-object-coff-section-raw-size
              image
              (CompilerObjectSectionKind.Data))
            (compiler-object-coff-section-raw-size
              image
              (CompilerObjectSectionKind.Rodata)))))]
    [(CompilerObjectSectionKind.Xdata)
      (+
        (compiler-object-coff-header-size)
        (+
          (compiler-object-coff-section-raw-size
            image
            (CompilerObjectSectionKind.Text))
          (+
            (compiler-object-coff-section-raw-size
              image
              (CompilerObjectSectionKind.Data))
            (+
              (compiler-object-coff-section-raw-size
                image
                (CompilerObjectSectionKind.Rodata))
              (compiler-object-coff-section-raw-size
                image
                (CompilerObjectSectionKind.Pdata))))))]
    [(CompilerObjectSectionKind.Rsrc)
      (+
        (compiler-object-coff-header-size)
        (+
          (compiler-object-coff-section-raw-size
            image
            (CompilerObjectSectionKind.Text))
          (+
            (compiler-object-coff-section-raw-size
              image
              (CompilerObjectSectionKind.Data))
            (+
              (compiler-object-coff-section-raw-size
                image
                (CompilerObjectSectionKind.Rodata))
              (+
                (compiler-object-coff-section-raw-size
                  image
                  (CompilerObjectSectionKind.Pdata))
                (compiler-object-coff-section-raw-size
                  image
                  (CompilerObjectSectionKind.Xdata)))))))]))

(define (compiler-object-coff-section-raw-pointer
  [image : CompilerObjectImage]
  [kind : CompilerObjectSectionKind]) : i64
  (if (> (compiler-object-coff-section-raw-size image kind) 0)
    (compiler-object-coff-raw-base-after-section image kind)
    0))

(define (compiler-object-coff-relocation-base [image : CompilerObjectImage]) : i64
  (+
    (compiler-object-coff-header-size)
    (+
      (compiler-object-coff-section-raw-size
        image
        (CompilerObjectSectionKind.Text))
      (+
        (compiler-object-coff-section-raw-size
          image
          (CompilerObjectSectionKind.Data))
        (+
          (compiler-object-coff-section-raw-size
            image
            (CompilerObjectSectionKind.Rodata))
          (+
            (compiler-object-coff-section-raw-size
              image
              (CompilerObjectSectionKind.Pdata))
            (+
              (compiler-object-coff-section-raw-size
                image
                (CompilerObjectSectionKind.Xdata))
              (compiler-object-coff-section-raw-size
                image
                (CompilerObjectSectionKind.Rsrc)))))))))

(define (compiler-object-coff-relocation-pointer
  [image : CompilerObjectImage]
  [kind : CompilerObjectSectionKind]) : i64
  (let
    [count : i64 (compiler-object-coff-section-relocation-count image kind)]
    (if (= count 0)
      0
      (let
        [text-count : i64
          (compiler-object-coff-section-relocation-count
            image
            (CompilerObjectSectionKind.Text))]
        [data-count : i64
          (compiler-object-coff-section-relocation-count
            image
            (CompilerObjectSectionKind.Data))]
        [rodata-count : i64
          (compiler-object-coff-section-relocation-count
            image
            (CompilerObjectSectionKind.Rodata))]
        [bss-count : i64
          (compiler-object-coff-section-relocation-count
            image
            (CompilerObjectSectionKind.Bss))]
        [pdata-count : i64
          (compiler-object-coff-section-relocation-count
            image
            (CompilerObjectSectionKind.Pdata))]
        [xdata-count : i64
          (compiler-object-coff-section-relocation-count
            image
            (CompilerObjectSectionKind.Xdata))]
        [base : i64 (compiler-object-coff-relocation-base image)]
        (match kind
          [(CompilerObjectSectionKind.Text) base]
          [(CompilerObjectSectionKind.Data)
            (+ base (* compiler-object-coff-relocation-size text-count))]
          [(CompilerObjectSectionKind.Rodata)
            (+
              base
              (* compiler-object-coff-relocation-size (+ text-count data-count)))]
          [(CompilerObjectSectionKind.Bss)
            (+
              base
              (*
                compiler-object-coff-relocation-size
                (+ text-count (+ data-count rodata-count))))]
          [(CompilerObjectSectionKind.Pdata)
            (+
              base
              (*
                compiler-object-coff-relocation-size
                (+ text-count (+ data-count (+ rodata-count bss-count)))))]
          [(CompilerObjectSectionKind.Xdata)
            (+
              base
              (*
                compiler-object-coff-relocation-size
                (+
                  text-count
                  (+ data-count (+ rodata-count (+ bss-count pdata-count))))))]
          [(CompilerObjectSectionKind.Rsrc)
            (+
              base
              (*
                compiler-object-coff-relocation-size
                (+
                  text-count
                  (+
                    data-count
                    (+ rodata-count (+ bss-count (+ pdata-count xdata-count)))))))])))))

(define (compiler-object-coff-symbol-table-pointer
  [image : CompilerObjectImage]) : i64
  (+
    (compiler-object-coff-relocation-base image)
    (*
      compiler-object-coff-relocation-size
      (compiler-object-coff-total-relocation-count image))))

(define (compiler-object-coff-push-file-header!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : CompilerObjectImage]) : unit
  (begin
    (compiler-object-coff-push-u16! out compiler-object-coff-machine-amd64)
    (compiler-object-coff-push-u16! out compiler-object-coff-section-count)
    (compiler-object-coff-push-u32! out 0)
    (compiler-object-coff-push-u32!
      out
      (compiler-object-coff-symbol-table-pointer image))
    (compiler-object-coff-push-u32!
      out
      (compiler-object-symbol-list-count (struct-get image symbols)))
    (compiler-object-coff-push-u16! out 0)
    (compiler-object-coff-push-u16! out 0)))

(define (compiler-object-coff-push-section-header!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : CompilerObjectImage]
  [kind : CompilerObjectSectionKind]) : unit
  (begin
    (compiler-object-coff-push-name8!
      out
      (compiler-object-coff-section-name kind))
    (compiler-object-coff-push-u32!
      out
      (compiler-object-coff-section-virtual-size image kind))
    (compiler-object-coff-push-u32! out 0)
    (compiler-object-coff-push-u32!
      out
      (compiler-object-coff-section-raw-size image kind))
    (compiler-object-coff-push-u32!
      out
      (compiler-object-coff-section-raw-pointer image kind))
    (compiler-object-coff-push-u32!
      out
      (compiler-object-coff-relocation-pointer image kind))
    (compiler-object-coff-push-u32! out 0)
    (compiler-object-coff-push-u16!
      out
      (compiler-object-coff-section-relocation-count image kind))
    (compiler-object-coff-push-u16! out 0)
    (compiler-object-coff-push-u32!
      out
      (compiler-object-coff-section-flags kind))))

(define (compiler-object-coff-push-section-headers!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : CompilerObjectImage]) : unit
  (begin
    (compiler-object-coff-push-section-header!
      out
      image
      (CompilerObjectSectionKind.Text))
    (compiler-object-coff-push-section-header!
      out
      image
      (CompilerObjectSectionKind.Data))
    (compiler-object-coff-push-section-header!
      out
      image
      (CompilerObjectSectionKind.Rodata))
    (compiler-object-coff-push-section-header!
      out
      image
      (CompilerObjectSectionKind.Bss))
    (compiler-object-coff-push-section-header!
      out
      image
      (CompilerObjectSectionKind.Pdata))
    (compiler-object-coff-push-section-header!
      out
      image
      (CompilerObjectSectionKind.Xdata))
    (compiler-object-coff-push-section-header!
      out
      image
      (CompilerObjectSectionKind.Rsrc))))

(define (compiler-object-coff-render-data-record!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [record : CompilerObjectDataRecord]
  [offset : i64]) : i64
  (match record
    [(CompilerObjectDataRecord.Label _) offset]
    [(CompilerObjectDataRecord.Align align)
      (let
        [aligned : i64 (compiler-object-coff-align-offset offset align)]
        (begin
          (compiler-object-coff-push-zeroes! out (- aligned offset))
          aligned))]
    [(CompilerObjectDataRecord.Bytes bytes)
      (begin
        (compiler-object-coff-push-string-bytes! out bytes)
        (+ offset (compiler-object-coff-string-length bytes)))]
    [(CompilerObjectDataRecord.String text)
      (begin
        (compiler-object-coff-push-string-bytes! out text)
        (+ offset (compiler-object-coff-string-length text)))]
    [(CompilerObjectDataRecord.F64 bits)
      (begin
        (compiler-object-coff-push-u64! out (cast bits : i64))
        (+ offset 8))]
    [(CompilerObjectDataRecord.F32 bits)
      (begin
        (compiler-object-coff-push-u32! out (cast bits : i64))
        (+ offset 4))]
    [(CompilerObjectDataRecord.I64 value)
      (begin
        (compiler-object-coff-push-u64! out value)
        (+ offset 8))]
    [(CompilerObjectDataRecord.Zero count)
      (begin
        (compiler-object-coff-push-zeroes! out count)
        (+ offset count))]
    [(CompilerObjectDataRecord.SymbolAddress _)
      (begin
        (compiler-object-coff-push-u64! out 0)
        (+ offset 8))]
    [(CompilerObjectDataRecord.SymbolRva32 _)
      (begin
        (compiler-object-coff-push-u32! out 0)
        (+ offset 4))]))

(define (compiler-object-coff-render-data-records!
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
            (compiler-object-coff-render-data-record!
              out
              (compiler-object-data-record-list-ref records index)
              cur-offset))
          (set! index (+ index 1))))
      cur-offset)))

(define (compiler-object-coff-push-rel32-placeholder!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]) : unit
  (compiler-object-coff-push-u32! out 0))

(define (compiler-object-coff-render-instr!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [instr : CompilerObjectX64Instr]) : unit
  (match instr
    [(CompilerObjectX64Instr.Label _) unit]
    [(CompilerObjectX64Instr.Call _)
      (begin
        (compiler-object-coff-push-u8! out 0xe8)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(CompilerObjectX64Instr.TailCall _)
      (begin
        (compiler-object-coff-push-u8! out 0xe9)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(CompilerObjectX64Instr.Jump _)
      (begin
        (compiler-object-coff-push-u8! out 0xe9)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(CompilerObjectX64Instr.Ja _)
      (begin
        (compiler-object-coff-push-u8! out 0x0f)
        (compiler-object-coff-push-u8! out 0x87)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(CompilerObjectX64Instr.Branch _ _)
      (begin
        (compiler-object-coff-push-u8! out 0x48)
        (compiler-object-coff-push-u8! out 0x85)
        (compiler-object-coff-push-u8! out 0xc0)
        (compiler-object-coff-push-u8! out 0x0f)
        (compiler-object-coff-push-u8! out 0x85)
        (compiler-object-coff-push-rel32-placeholder! out)
        (compiler-object-coff-push-u8! out 0xe9)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(CompilerObjectX64Instr.LoadRip _)
      (begin
        (compiler-object-coff-push-u8! out 0x48)
        (compiler-object-coff-push-u8! out 0x8b)
        (compiler-object-coff-push-u8! out 0x05)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(CompilerObjectX64Instr.LoadRipAddress _)
      (begin
        (compiler-object-coff-push-u8! out 0x48)
        (compiler-object-coff-push-u8! out 0x8d)
        (compiler-object-coff-push-u8! out 0x05)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(CompilerObjectX64Instr.LoadRipAddressR11 _)
      (begin
        (compiler-object-coff-push-u8! out 0x4c)
        (compiler-object-coff-push-u8! out 0x8d)
        (compiler-object-coff-push-u8! out 0x1d)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(CompilerObjectX64Instr.StoreRip _)
      (begin
        (compiler-object-coff-push-u8! out 0x48)
        (compiler-object-coff-push-u8! out 0x89)
        (compiler-object-coff-push-u8! out 0x05)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(CompilerObjectX64Instr.SubRspImm8 imm)
      (begin
        (compiler-object-coff-push-u8! out 0x48)
        (compiler-object-coff-push-u8! out 0x83)
        (compiler-object-coff-push-u8! out 0xec)
        (compiler-object-coff-push-u8! out imm))]
    [(CompilerObjectX64Instr.MovRcxRip _)
      (begin
        (compiler-object-coff-push-u8! out 0x48)
        (compiler-object-coff-push-u8! out 0x8b)
        (compiler-object-coff-push-u8! out 0x0d)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(CompilerObjectX64Instr.MovRdxRip _)
      (begin
        (compiler-object-coff-push-u8! out 0x48)
        (compiler-object-coff-push-u8! out 0x8b)
        (compiler-object-coff-push-u8! out 0x15)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(CompilerObjectX64Instr.LoadRipAddressRdx _)
      (begin
        (compiler-object-coff-push-u8! out 0x48)
        (compiler-object-coff-push-u8! out 0x8d)
        (compiler-object-coff-push-u8! out 0x15)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(CompilerObjectX64Instr.StoreR14Rip _)
      (begin
        (compiler-object-coff-push-u8! out 0x4c)
        (compiler-object-coff-push-u8! out 0x89)
        (compiler-object-coff-push-u8! out 0x35)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(CompilerObjectX64Instr.StoreR15Rip _)
      (begin
        (compiler-object-coff-push-u8! out 0x4c)
        (compiler-object-coff-push-u8! out 0x89)
        (compiler-object-coff-push-u8! out 0x3d)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(CompilerObjectX64Instr.AddRcxRip _)
      (begin
        (compiler-object-coff-push-u8! out 0x48)
        (compiler-object-coff-push-u8! out 0x01)
        (compiler-object-coff-push-u8! out 0x0d)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(CompilerObjectX64Instr.MovRcxRax)
      (begin
        (compiler-object-coff-push-u8! out 0x48)
        (compiler-object-coff-push-u8! out 0x89)
        (compiler-object-coff-push-u8! out 0xc1))]
    [(CompilerObjectX64Instr.XorpdRip _)
      (begin
        (compiler-object-coff-push-u8! out 0x66)
        (compiler-object-coff-push-u8! out 0x0f)
        (compiler-object-coff-push-u8! out 0x57)
        (compiler-object-coff-push-u8! out 0x05)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(CompilerObjectX64Instr.Bytes bytes)
      (compiler-object-coff-push-string-bytes! out bytes)]
    [(CompilerObjectX64Instr.Raw _) unit]))

(define (compiler-object-coff-render-instrs!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [instrs : CompilerObjectX64InstrList]) : unit
  (let
    [count : i64 (compiler-object-instr-list-count instrs)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (compiler-object-coff-render-instr!
            out
            (compiler-object-instr-list-ref instrs index))
          (set! index (+ index 1))))
      unit)))

(define (compiler-object-coff-render-section-data!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : CompilerObjectImage]
  [kind : CompilerObjectSectionKind]) : unit
  (match (compiler-object-section-list-find (struct-get image sections) kind)
    [(CompilerObjectSection.Section _ data instrs)
      (match kind
        [(CompilerObjectSectionKind.Text)
          (compiler-object-coff-render-instrs! out instrs)]
        [_
          (begin
            (compiler-object-coff-render-data-records! out data 0)
            unit)])]))

(define (compiler-object-coff-render-sections!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : CompilerObjectImage]) : unit
  (begin
    (compiler-object-coff-render-section-data!
      out
      image
      (CompilerObjectSectionKind.Text))
    (compiler-object-coff-render-section-data!
      out
      image
      (CompilerObjectSectionKind.Data))
    (compiler-object-coff-render-section-data!
      out
      image
      (CompilerObjectSectionKind.Rodata))
    (compiler-object-coff-render-section-data!
      out
      image
      (CompilerObjectSectionKind.Pdata))
    (compiler-object-coff-render-section-data!
      out
      image
      (CompilerObjectSectionKind.Xdata))
    (compiler-object-coff-render-section-data!
      out
      image
      (CompilerObjectSectionKind.Rsrc))))

(define (compiler-object-coff-relocation-type
  [kind : CompilerObjectRelocationKind]) : i64
  (match kind
    [(CompilerObjectRelocationKind.Call) compiler-object-coff-reloc-amd64-rel32]
    [(CompilerObjectRelocationKind.TailCall)
      compiler-object-coff-reloc-amd64-rel32]
    [(CompilerObjectRelocationKind.Abs64)
      compiler-object-coff-reloc-amd64-addr64]
    [(CompilerObjectRelocationKind.Addr32Nb)
      compiler-object-coff-reloc-amd64-addr32nb]
    [(CompilerObjectRelocationKind.RipValue)
      compiler-object-coff-reloc-amd64-rel32]
    [(CompilerObjectRelocationKind.RipAddress)
      compiler-object-coff-reloc-amd64-rel32]
    [(CompilerObjectRelocationKind.Branch)
      compiler-object-coff-reloc-amd64-rel32]
    [_ 0]))

(define (compiler-object-coff-render-relocation-record!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : CompilerObjectImage]
  [offset : i64]
  [kind : CompilerObjectRelocationKind]
  [target : String]) : unit
  (begin
    (compiler-object-coff-push-u32! out offset)
    (compiler-object-coff-push-u32!
      out
      (compiler-object-coff-symbol-index image target))
    (compiler-object-coff-push-u16!
      out
      (compiler-object-coff-relocation-type kind))))

(define (compiler-object-coff-render-relocation!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : CompilerObjectImage]
  [reloc : CompilerObjectRelocation]) : unit
  (match reloc
    [(CompilerObjectRelocation.Relocation section site kind target)
      (compiler-object-coff-render-relocation-record!
        out
        image
        (compiler-object-coff-section-label-offset image section site)
        kind
        target)]))

(define (compiler-object-coff-render-text-instr-relocations!
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
                (compiler-object-coff-render-relocation-record!
                  out
                  image
                  (+ cur-offset 1)
                  (CompilerObjectRelocationKind.Call)
                  target)]
              [(CompilerObjectX64Instr.TailCall target)
                (compiler-object-coff-render-relocation-record!
                  out
                  image
                  (+ cur-offset 1)
                  (CompilerObjectRelocationKind.TailCall)
                  target)]
              [(CompilerObjectX64Instr.Jump target)
                (compiler-object-coff-render-relocation-record!
                  out
                  image
                  (+ cur-offset 1)
                  (CompilerObjectRelocationKind.Branch)
                  target)]
              [(CompilerObjectX64Instr.Ja target)
                (compiler-object-coff-render-relocation-record!
                  out
                  image
                  (+ cur-offset 2)
                  (CompilerObjectRelocationKind.Branch)
                  target)]
              [(CompilerObjectX64Instr.Branch true-target false-target)
                (begin
                  (compiler-object-coff-render-relocation-record!
                    out
                    image
                    (+ cur-offset 5)
                    (CompilerObjectRelocationKind.Branch)
                    true-target)
                  (compiler-object-coff-render-relocation-record!
                    out
                    image
                    (+ cur-offset 10)
                    (CompilerObjectRelocationKind.Branch)
                    false-target))]
              [(CompilerObjectX64Instr.LoadRip target)
                (compiler-object-coff-render-relocation-record!
                  out
                  image
                  (+ cur-offset 3)
                  (CompilerObjectRelocationKind.RipValue)
                  target)]
              [(CompilerObjectX64Instr.LoadRipAddress target)
                (compiler-object-coff-render-relocation-record!
                  out
                  image
                  (+ cur-offset 3)
                  (CompilerObjectRelocationKind.RipAddress)
                  target)]
              [(CompilerObjectX64Instr.LoadRipAddressR11 target)
                (compiler-object-coff-render-relocation-record!
                  out
                  image
                  (+ cur-offset 3)
                  (CompilerObjectRelocationKind.RipAddress)
                  target)]
              [(CompilerObjectX64Instr.StoreRip target)
                (compiler-object-coff-render-relocation-record!
                  out
                  image
                  (+ cur-offset 3)
                  (CompilerObjectRelocationKind.RipAddress)
                  target)]
              [(CompilerObjectX64Instr.SubRspImm8 _) unit]
              [(CompilerObjectX64Instr.MovRcxRip target)
                (compiler-object-coff-render-relocation-record!
                  out
                  image
                  (+ cur-offset 3)
                  (CompilerObjectRelocationKind.RipValue)
                  target)]
              [(CompilerObjectX64Instr.MovRdxRip target)
                (compiler-object-coff-render-relocation-record!
                  out
                  image
                  (+ cur-offset 3)
                  (CompilerObjectRelocationKind.RipValue)
                  target)]
              [(CompilerObjectX64Instr.LoadRipAddressRdx target)
                (compiler-object-coff-render-relocation-record!
                  out
                  image
                  (+ cur-offset 3)
                  (CompilerObjectRelocationKind.RipAddress)
                  target)]
              [(CompilerObjectX64Instr.StoreR14Rip target)
                (compiler-object-coff-render-relocation-record!
                  out
                  image
                  (+ cur-offset 3)
                  (CompilerObjectRelocationKind.RipAddress)
                  target)]
              [(CompilerObjectX64Instr.StoreR15Rip target)
                (compiler-object-coff-render-relocation-record!
                  out
                  image
                  (+ cur-offset 3)
                  (CompilerObjectRelocationKind.RipAddress)
                  target)]
              [(CompilerObjectX64Instr.AddRcxRip target)
                (compiler-object-coff-render-relocation-record!
                  out
                  image
                  (+ cur-offset 3)
                  (CompilerObjectRelocationKind.RipAddress)
                  target)]
              [(CompilerObjectX64Instr.MovRcxRax) unit]
              [(CompilerObjectX64Instr.XorpdRip target)
                (compiler-object-coff-render-relocation-record!
                  out
                  image
                  (+ cur-offset 4)
                  (CompilerObjectRelocationKind.RipValue)
                  target)]
              [(CompilerObjectX64Instr.Bytes _) unit]
              [(CompilerObjectX64Instr.Raw _) unit])
            (set!
              cur-offset
              (+ cur-offset (compiler-object-coff-instr-size instr)))
            (set! index (+ index 1)))))
      unit)))

(define (compiler-object-coff-render-text-relocations!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : CompilerObjectImage]) : unit
  (match (compiler-object-section-list-find
    (struct-get image sections)
    (CompilerObjectSectionKind.Text))
    [(CompilerObjectSection.Section _ _ instrs)
      (compiler-object-coff-render-text-instr-relocations! out image instrs 0)]))

(define (compiler-object-coff-render-relocations-for-section!
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
                  (compiler-object-coff-render-relocation! out image reloc)
                  unit)])
            (set! index (+ index 1)))))
      unit)))

(define (compiler-object-coff-render-relocations!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : CompilerObjectImage]) : unit
  (begin
    (compiler-object-coff-render-text-relocations! out image)
    (compiler-object-coff-render-relocations-for-section!
      out
      image
      (struct-get image relocations)
      (CompilerObjectSectionKind.Data))
    (compiler-object-coff-render-relocations-for-section!
      out
      image
      (struct-get image relocations)
      (CompilerObjectSectionKind.Rodata))
    (compiler-object-coff-render-relocations-for-section!
      out
      image
      (struct-get image relocations)
      (CompilerObjectSectionKind.Bss))
    (compiler-object-coff-render-relocations-for-section!
      out
      image
      (struct-get image relocations)
      (CompilerObjectSectionKind.Pdata))
    (compiler-object-coff-render-relocations-for-section!
      out
      image
      (struct-get image relocations)
      (CompilerObjectSectionKind.Xdata))
    (compiler-object-coff-render-relocations-for-section!
      out
      image
      (struct-get image relocations)
      (CompilerObjectSectionKind.Rsrc))))

(define (compiler-object-coff-symbol-name-long? [name : String]) : bool
  (> (compiler-object-coff-string-length name) 8))

(define (compiler-object-coff-symbol-string-offset-from
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
            (if (compiler-object-coff-symbol-name-long? found)
              (if (string.string-eq found name)
                (begin
                  (set! result cur-offset)
                  (set! done true))
                (begin
                  (set!
                    cur-offset
                    (+
                      cur-offset
                      (+ (compiler-object-coff-string-length found) 1)))
                  (set! index (+ index 1))))
              (set! index (+ index 1)))]))
      result)))

(define (compiler-object-coff-symbol-string-offset
  [image : CompilerObjectImage]
  [name : String]) : i64
  (compiler-object-coff-symbol-string-offset-from
    (struct-get image symbols)
    name
    4))

(define (compiler-object-coff-push-symbol-name!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : CompilerObjectImage]
  [name : String]) : unit
  (if (compiler-object-coff-symbol-name-long? name)
    (begin
      (compiler-object-coff-push-u32! out 0)
      (compiler-object-coff-push-u32!
        out
        (compiler-object-coff-symbol-string-offset image name)))
    (compiler-object-coff-push-name8! out name)))

(define (compiler-object-coff-symbol-storage-class
  [binding : CompilerObjectSymbolBinding]) : i64
  (match binding
    [(CompilerObjectSymbolBinding.Local) 3]
    [_ 2]))

(define (compiler-object-coff-symbol-type [kind : CompilerObjectSymbolKind]) : i64
  (match kind
    [(CompilerObjectSymbolKind.Function) 0x20]
    [_ 0]))

(define (compiler-object-coff-symbol-section-number
  [section : CompilerObjectMaybeSection]) : i64
  (match section
    [(CompilerObjectMaybeSection.No) 0]
    [(CompilerObjectMaybeSection.Some kind)
      (compiler-object-coff-section-number kind)]))

(define (compiler-object-coff-symbol-value
  [image : CompilerObjectImage]
  [name : String]
  [section : CompilerObjectMaybeSection]) : i64
  (match section
    [(CompilerObjectMaybeSection.No) 0]
    [(CompilerObjectMaybeSection.Some kind)
      (let
        [offset : i64
          (compiler-object-coff-section-label-offset image kind name)]
        (if (< offset 0)
          0
          offset))]))

(define (compiler-object-coff-render-symbol!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : CompilerObjectImage]
  [symbol : CompilerObjectSymbol]) : unit
  (match symbol
    [(CompilerObjectSymbol.Symbol name binding kind section)
      (begin
        (compiler-object-coff-push-symbol-name! out image name)
        (compiler-object-coff-push-u32!
          out
          (compiler-object-coff-symbol-value image name section))
        (compiler-object-coff-push-u16!
          out
          (compiler-object-coff-symbol-section-number section))
        (compiler-object-coff-push-u16!
          out
          (compiler-object-coff-symbol-type kind))
        (compiler-object-coff-push-u8!
          out
          (compiler-object-coff-symbol-storage-class binding))
        (compiler-object-coff-push-u8! out 0))]))

(define (compiler-object-coff-render-symbols!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : CompilerObjectImage]
  [symbols : CompilerObjectSymbolList]) : unit
  (let
    [count : i64 (compiler-object-symbol-list-count symbols)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (compiler-object-coff-render-symbol!
            out
            image
            (compiler-object-symbol-list-ref symbols index))
          (set! index (+ index 1))))
      unit)))

(define (compiler-object-coff-string-table-size-from
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
              (if (compiler-object-coff-symbol-name-long? name)
                (set!
                  total
                  (+ total (+ (compiler-object-coff-string-length name) 1)))
                unit)])
          (set! index (+ index 1))))
      total)))

(define (compiler-object-coff-string-table-size
  [symbols : CompilerObjectSymbolList]) : i64
  (compiler-object-coff-string-table-size-from symbols 4))

(define (compiler-object-coff-render-string-table-symbols!
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
              (if (compiler-object-coff-symbol-name-long? name)
                (begin
                  (compiler-object-coff-push-string-bytes! out name)
                  (compiler-object-coff-push-u8! out 0))
                unit)])
          (set! index (+ index 1))))
      unit)))

(define (compiler-object-coff-render-string-table!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : CompilerObjectImage]) : unit
  (begin
    (compiler-object-coff-push-u32!
      out
      (compiler-object-coff-string-table-size (struct-get image symbols)))
    (compiler-object-coff-render-string-table-symbols!
      out
      (struct-get image symbols))))

(define (compiler-object-coff-bytes-string
  [out : (& out byte_buf_core.ByteBufBuilder)]) : String
  (byte_buf_core.byte-buf-builder-finish-string out))

(define (compiler-object-coff-render [image : CompilerObjectImage]) : ResultCompilerObjectCoff
  (if (compiler-object-coff-image-supported? image)
    (let
      [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
      (begin
        (compiler-object-coff-push-file-header! (&mut out) image)
        (compiler-object-coff-push-section-headers! (&mut out) image)
        (compiler-object-coff-render-sections! (&mut out) image)
        (compiler-object-coff-render-relocations! (&mut out) image)
        (compiler-object-coff-render-symbols!
          (&mut out)
          image
          (struct-get image symbols))
        (compiler-object-coff-render-string-table! (&mut out) image)
        (ResultCompilerObjectCoff.Ok
          (compiler-object-coff-bytes-string (& out)))))
    (ResultCompilerObjectCoff.Err
      "coff: object image contains unsupported text, f64, or relocation records")))

(define (compiler-object-coff-u16-at [text : String] [offset : i64]) : i64
  (+
    (cast (compiler-object-coff-string-ref text offset) : i64)
    (shl (cast (compiler-object-coff-string-ref text (+ offset 1)) : i64) 8)))

(define (compiler-object-coff-u32-at [text : String] [offset : i64]) : i64
  (+
    (compiler-object-coff-u16-at text offset)
    (shl (compiler-object-coff-u16-at text (+ offset 2)) 16)))

(define (compiler-object-coff-u8-at [text : String] [offset : i64]) : i64
  (cast (compiler-object-coff-string-ref text offset) : i64))

(define (compiler-object-coff-section-header-offset
  [kind : CompilerObjectSectionKind]) : i64
  (+
    compiler-object-coff-file-header-size
    (*
      compiler-object-coff-section-header-size
      (- (compiler-object-coff-section-number kind) 1))))

(define (compiler-object-coff-prefix-at?
  [text : String]
  [needle : String]
  [start : i64]) : bool
  (let
    [text-len : i64 (compiler-object-coff-string-length text)]
    [needle-len : i64 (compiler-object-coff-string-length needle)]
    (if (> (+ start needle-len) text-len)
      false
      (let
        [i : i64 0]
        [ok : bool true]
        (begin
          (while ok
            (if (< i needle-len)
              (if (=
                (compiler-object-coff-string-ref text (+ start i))
                (compiler-object-coff-string-ref needle i))
                (set! i (+ i 1))
                (set! ok false))
              (set! ok false)))
          (= i needle-len))))))

(define (compiler-object-coff-contains? [text : String] [needle : String]) : bool
  (let
    [i : i64 0]
    [n : i64 (compiler-object-coff-string-length text)]
    [found : bool false]
    (begin
      (while (and (not found) (< i n))
        (begin
          (if (compiler-object-coff-prefix-at? text needle i)
            (set! found true)
            unit)
          (set! i (+ i 1))))
      found)))

(define (compiler-object-coff-smoke-image) : CompilerObjectImage
  (CompilerObjectImage
    (compiler-object-section-cons
      (CompilerObjectSection.Section
        (CompilerObjectSectionKind.Text)
        CompilerObjectDataRecordList.Nil
        (compiler-object-instr-cons
          (CompilerObjectX64Instr.Label "_tl_empty")
          CompilerObjectX64InstrList.Nil))
      (compiler-object-section-cons
        (CompilerObjectSection.Section
          (CompilerObjectSectionKind.Data)
          (compiler-object-data-cons
            (CompilerObjectDataRecord.Label "_tl_answer")
            (compiler-object-data-cons
              (CompilerObjectDataRecord.I64 42)
              (compiler-object-data-cons
                (CompilerObjectDataRecord.Label "_tl_ptr")
                (compiler-object-data-cons
                  (CompilerObjectDataRecord.SymbolAddress "_tl_answer")
                  CompilerObjectDataRecordList.Nil))))
          CompilerObjectX64InstrList.Nil)
        (compiler-object-section-cons
          (CompilerObjectSection.Section
            (CompilerObjectSectionKind.Rodata)
            (compiler-object-data-cons
              (CompilerObjectDataRecord.Label "long_rodata_label_name")
              (compiler-object-data-cons
                (CompilerObjectDataRecord.String "hello")
                CompilerObjectDataRecordList.Nil))
            CompilerObjectX64InstrList.Nil)
          (compiler-object-section-cons
            (CompilerObjectSection.Section
              (CompilerObjectSectionKind.Bss)
              (compiler-object-data-cons
                (CompilerObjectDataRecord.Label "_tl_heap")
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
          "_tl_answer"
          (CompilerObjectSymbolBinding.Export)
          (CompilerObjectSymbolKind.Data)
          (CompilerObjectMaybeSection.Some (CompilerObjectSectionKind.Data)))
        (compiler-object-symbol-cons
          (CompilerObjectSymbol.Symbol
            "_tl_ptr"
            (CompilerObjectSymbolBinding.Local)
            (CompilerObjectSymbolKind.Data)
            (CompilerObjectMaybeSection.Some (CompilerObjectSectionKind.Data)))
          (compiler-object-symbol-cons
            (CompilerObjectSymbol.Symbol
              "long_rodata_label_name"
              (CompilerObjectSymbolBinding.Local)
              (CompilerObjectSymbolKind.Data)
              (CompilerObjectMaybeSection.Some
                (CompilerObjectSectionKind.Rodata)))
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
        "_tl_ptr"
        (CompilerObjectRelocationKind.Abs64)
        "_tl_answer")
      CompilerObjectRelocationList.Nil)))

(define (compiler-object-coff-smoke-ok?) : bool
  (match (compiler-object-coff-render (compiler-object-coff-smoke-image))
    [(ResultCompilerObjectCoff.Ok obj)
      (and
        (=
          (compiler-object-coff-u16-at obj 0)
          compiler-object-coff-machine-amd64)
        (=
          (compiler-object-coff-u16-at obj 2)
          compiler-object-coff-section-count)
        (> (compiler-object-coff-u32-at obj 8) 0)
        (= (compiler-object-coff-u32-at obj 12) 5)
        (= (compiler-object-coff-u32-at obj (+ 60 16)) 16)
        (= (compiler-object-coff-u16-at obj (+ 60 32)) 1)
        (compiler-object-coff-contains? obj ".rdata")
        (compiler-object-coff-contains? obj "foreign_exact")
        (compiler-object-coff-contains? obj "long_rodata_label_name"))]
    [(ResultCompilerObjectCoff.Err _) false]))

(define (compiler-object-coff-text-smoke-instrs) : CompilerObjectX64InstrList
  (compiler-object-instr-cons
    (CompilerObjectX64Instr.Label "_tl_text")
    (compiler-object-instr-cons
      (CompilerObjectX64Instr.LoadRip "_tl_answer")
      (compiler-object-instr-cons
        (CompilerObjectX64Instr.LoadRipAddress "_tl_slot")
        (compiler-object-instr-cons
          (CompilerObjectX64Instr.StoreRip "_tl_slot")
          (compiler-object-instr-cons
            (CompilerObjectX64Instr.Call "foreign_exact")
            (compiler-object-instr-cons
              (CompilerObjectX64Instr.TailCall "_tl_done")
              (compiler-object-instr-cons
                (CompilerObjectX64Instr.Jump "_tl_done")
                (compiler-object-instr-cons
                  (CompilerObjectX64Instr.Branch "_tl_true" "_tl_false")
                  (compiler-object-instr-cons
                    (CompilerObjectX64Instr.Label "_tl_true")
                    (compiler-object-instr-cons
                      (CompilerObjectX64Instr.Label "_tl_false")
                      (compiler-object-instr-cons
                        (CompilerObjectX64Instr.Label "_tl_done")
                        CompilerObjectX64InstrList.Nil))))))))))))

(define (compiler-object-coff-text-smoke-symbols) : CompilerObjectSymbolList
  (compiler-object-symbol-cons
    (CompilerObjectSymbol.Symbol
      "_tl_text"
      (CompilerObjectSymbolBinding.Export)
      (CompilerObjectSymbolKind.Function)
      (CompilerObjectMaybeSection.Some (CompilerObjectSectionKind.Text)))
    (compiler-object-symbol-cons
      (CompilerObjectSymbol.Symbol
        "_tl_true"
        (CompilerObjectSymbolBinding.Local)
        (CompilerObjectSymbolKind.Function)
        (CompilerObjectMaybeSection.Some (CompilerObjectSectionKind.Text)))
      (compiler-object-symbol-cons
        (CompilerObjectSymbol.Symbol
          "_tl_false"
          (CompilerObjectSymbolBinding.Local)
          (CompilerObjectSymbolKind.Function)
          (CompilerObjectMaybeSection.Some (CompilerObjectSectionKind.Text)))
        (compiler-object-symbol-cons
          (CompilerObjectSymbol.Symbol
            "_tl_done"
            (CompilerObjectSymbolBinding.Local)
            (CompilerObjectSymbolKind.Function)
            (CompilerObjectMaybeSection.Some (CompilerObjectSectionKind.Text)))
          (compiler-object-symbol-cons
            (CompilerObjectSymbol.Symbol
              "_tl_answer"
              (CompilerObjectSymbolBinding.Export)
              (CompilerObjectSymbolKind.Data)
              (CompilerObjectMaybeSection.Some (CompilerObjectSectionKind.Data)))
            (compiler-object-symbol-cons
              (CompilerObjectSymbol.Symbol
                "_tl_slot"
                (CompilerObjectSymbolBinding.Local)
                (CompilerObjectSymbolKind.Data)
                (CompilerObjectMaybeSection.Some
                  (CompilerObjectSectionKind.Data)))
              (compiler-object-symbol-cons
                (CompilerObjectSymbol.Symbol
                  "foreign_exact"
                  (CompilerObjectSymbolBinding.Extern)
                  (CompilerObjectSymbolKind.Function)
                  (CompilerObjectMaybeSection.No))
                CompilerObjectSymbolList.Nil))))))))

(define (compiler-object-coff-text-smoke-relocs) : CompilerObjectRelocationList
  (compiler-object-relocation-cons
    (CompilerObjectRelocation.Relocation
      (CompilerObjectSectionKind.Text)
      "_tl_text"
      (CompilerObjectRelocationKind.RipValue)
      "_tl_answer")
    (compiler-object-relocation-cons
      (CompilerObjectRelocation.Relocation
        (CompilerObjectSectionKind.Text)
        "_tl_text"
        (CompilerObjectRelocationKind.RipAddress)
        "_tl_slot")
      (compiler-object-relocation-cons
        (CompilerObjectRelocation.Relocation
          (CompilerObjectSectionKind.Text)
          "_tl_text"
          (CompilerObjectRelocationKind.RipAddress)
          "_tl_slot")
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
              (CompilerObjectRelocationKind.TailCall)
              "_tl_done")
            (compiler-object-relocation-cons
              (CompilerObjectRelocation.Relocation
                (CompilerObjectSectionKind.Text)
                "_tl_text"
                (CompilerObjectRelocationKind.Branch)
                "_tl_done")
              (compiler-object-relocation-cons
                (CompilerObjectRelocation.Relocation
                  (CompilerObjectSectionKind.Text)
                  "_tl_text"
                  (CompilerObjectRelocationKind.Branch)
                  "_tl_true")
                (compiler-object-relocation-cons
                  (CompilerObjectRelocation.Relocation
                    (CompilerObjectSectionKind.Text)
                    "_tl_text"
                    (CompilerObjectRelocationKind.Branch)
                    "_tl_false")
                  CompilerObjectRelocationList.Nil)))))))))

(define (compiler-object-coff-text-smoke-image) : CompilerObjectImage
  (CompilerObjectImage
    (compiler-object-section-cons
      (CompilerObjectSection.Section
        (CompilerObjectSectionKind.Text)
        CompilerObjectDataRecordList.Nil
        (compiler-object-coff-text-smoke-instrs))
      (compiler-object-section-cons
        (CompilerObjectSection.Section
          (CompilerObjectSectionKind.Data)
          (compiler-object-data-cons
            (CompilerObjectDataRecord.Label "_tl_answer")
            (compiler-object-data-cons
              (CompilerObjectDataRecord.I64 42)
              (compiler-object-data-cons
                (CompilerObjectDataRecord.Label "_tl_slot")
                (compiler-object-data-cons
                  (CompilerObjectDataRecord.I64 0)
                  CompilerObjectDataRecordList.Nil))))
          CompilerObjectX64InstrList.Nil)
        (compiler-object-section-cons
          (CompilerObjectSection.Section
            (CompilerObjectSectionKind.Rodata)
            CompilerObjectDataRecordList.Nil
            CompilerObjectX64InstrList.Nil)
          (compiler-object-section-cons
            (CompilerObjectSection.Section
              (CompilerObjectSectionKind.Bss)
              CompilerObjectDataRecordList.Nil
              CompilerObjectX64InstrList.Nil)
            CompilerObjectSectionList.Nil))))
    (compiler-object-coff-text-smoke-symbols)
    (compiler-object-coff-text-smoke-relocs)))

(define (compiler-object-coff-reloc-entry-ok?
  [obj : String]
  [base : i64]
  [index : i64]
  [offset : i64]
  [symbol-index : i64]
  [reloc-type : i64]) : bool
  (let
    [entry : i64 (+ base (* index compiler-object-coff-relocation-size))]
    (and
      (= (compiler-object-coff-u32-at obj entry) offset)
      (= (compiler-object-coff-u32-at obj (+ entry 4)) symbol-index)
      (= (compiler-object-coff-u16-at obj (+ entry 8)) reloc-type))))

(define (compiler-object-coff-text-smoke-bytes-ok?
  [obj : String]
  [text-ptr : i64]) : bool
  (and
    (= (compiler-object-coff-u8-at obj text-ptr) 0x48)
    (= (compiler-object-coff-u8-at obj (+ text-ptr 1)) 0x8b)
    (= (compiler-object-coff-u8-at obj (+ text-ptr 2)) 0x05)
    (= (compiler-object-coff-u8-at obj (+ text-ptr 7)) 0x48)
    (= (compiler-object-coff-u8-at obj (+ text-ptr 8)) 0x8d)
    (= (compiler-object-coff-u8-at obj (+ text-ptr 14)) 0x48)
    (= (compiler-object-coff-u8-at obj (+ text-ptr 15)) 0x89)
    (= (compiler-object-coff-u8-at obj (+ text-ptr 21)) 0xe8)
    (= (compiler-object-coff-u8-at obj (+ text-ptr 26)) 0xe9)
    (= (compiler-object-coff-u8-at obj (+ text-ptr 31)) 0xe9)
    (= (compiler-object-coff-u8-at obj (+ text-ptr 36)) 0x48)
    (= (compiler-object-coff-u8-at obj (+ text-ptr 37)) 0x85)
    (= (compiler-object-coff-u8-at obj (+ text-ptr 38)) 0xc0)
    (= (compiler-object-coff-u8-at obj (+ text-ptr 39)) 0x0f)
    (= (compiler-object-coff-u8-at obj (+ text-ptr 40)) 0x85)
    (= (compiler-object-coff-u8-at obj (+ text-ptr 45)) 0xe9)))

(define (compiler-object-coff-text-smoke-relocs-ok?
  [image : CompilerObjectImage]
  [obj : String]
  [reloc-ptr : i64]) : bool
  (let
    [rel32 : i64 compiler-object-coff-reloc-amd64-rel32]
    (and
      (compiler-object-coff-reloc-entry-ok?
        obj
        reloc-ptr
        0
        3
        (compiler-object-coff-symbol-index image "_tl_answer")
        rel32)
      (compiler-object-coff-reloc-entry-ok?
        obj
        reloc-ptr
        1
        10
        (compiler-object-coff-symbol-index image "_tl_slot")
        rel32)
      (compiler-object-coff-reloc-entry-ok?
        obj
        reloc-ptr
        2
        17
        (compiler-object-coff-symbol-index image "_tl_slot")
        rel32)
      (compiler-object-coff-reloc-entry-ok?
        obj
        reloc-ptr
        3
        22
        (compiler-object-coff-symbol-index image "foreign_exact")
        rel32)
      (compiler-object-coff-reloc-entry-ok?
        obj
        reloc-ptr
        4
        27
        (compiler-object-coff-symbol-index image "_tl_done")
        rel32)
      (compiler-object-coff-reloc-entry-ok?
        obj
        reloc-ptr
        5
        32
        (compiler-object-coff-symbol-index image "_tl_done")
        rel32)
      (compiler-object-coff-reloc-entry-ok?
        obj
        reloc-ptr
        6
        41
        (compiler-object-coff-symbol-index image "_tl_true")
        rel32)
      (compiler-object-coff-reloc-entry-ok?
        obj
        reloc-ptr
        7
        46
        (compiler-object-coff-symbol-index image "_tl_false")
        rel32))))

(define (compiler-object-coff-text-smoke-ok?) : bool
  (let
    [image : CompilerObjectImage (compiler-object-coff-text-smoke-image)]
    (match (compiler-object-coff-render image)
      [(ResultCompilerObjectCoff.Ok obj)
        (let
          [text-header : i64
            (compiler-object-coff-section-header-offset
              (CompilerObjectSectionKind.Text))]
          [text-size : i64 (compiler-object-coff-u32-at obj (+ text-header 16))]
          [text-ptr : i64 (compiler-object-coff-u32-at obj (+ text-header 20))]
          [reloc-ptr : i64 (compiler-object-coff-u32-at obj (+ text-header 24))]
          [reloc-count : i64
            (compiler-object-coff-u16-at obj (+ text-header 32))]
          (and
            (= text-size 50)
            (= text-ptr (compiler-object-coff-header-size))
            (= reloc-count 8)
            (compiler-object-coff-text-smoke-bytes-ok? obj text-ptr)
            (compiler-object-coff-text-smoke-relocs-ok? image obj reloc-ptr)))]
      [(ResultCompilerObjectCoff.Err _) false])))