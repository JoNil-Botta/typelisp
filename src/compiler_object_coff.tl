;; compiler_object_coff.tl - COFF object-file serialization for object images.
(import stdlib.byte_buf_core)
(import stdlib.string)
(import compiler_object as cobj)
(cfg test (import stdlib.test))

(define (compiler-object-coff-string-length [text : String]) : i64
  (__tl_string_length text))

(define (compiler-object-coff-string-ref [text : String] [index : i64]) : char
  (__tl_string_ref text index))

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

(define (compiler-object-coff-section-name
  [kind : cobj.CompilerObjectSectionKind]) : String
  (match kind
    [(cobj.CompilerObjectSectionKind.Text) ".text"]
    [(cobj.CompilerObjectSectionKind.Data) ".data"]
    [(cobj.CompilerObjectSectionKind.Rodata) ".rdata"]
    [(cobj.CompilerObjectSectionKind.Bss) ".bss"]
    [(cobj.CompilerObjectSectionKind.Pdata) ".pdata"]
    [(cobj.CompilerObjectSectionKind.Xdata) ".xdata"]
    [(cobj.CompilerObjectSectionKind.Rsrc) ".rsrc"]))

(define (compiler-object-coff-section-number
  [kind : cobj.CompilerObjectSectionKind]) : i64
  (match kind
    [(cobj.CompilerObjectSectionKind.Text) 1]
    [(cobj.CompilerObjectSectionKind.Data) 2]
    [(cobj.CompilerObjectSectionKind.Rodata) 3]
    [(cobj.CompilerObjectSectionKind.Bss) 4]
    [(cobj.CompilerObjectSectionKind.Pdata) 5]
    [(cobj.CompilerObjectSectionKind.Xdata) 6]
    [(cobj.CompilerObjectSectionKind.Rsrc) 7]))

(define (compiler-object-coff-section-flags
  [kind : cobj.CompilerObjectSectionKind]) : i64
  (match kind
    [(cobj.CompilerObjectSectionKind.Text)
      (bit-or
        compiler-object-coff-section-cnt-code
        (bit-or
          compiler-object-coff-section-align-16
          (bit-or
            compiler-object-coff-section-mem-execute
            compiler-object-coff-section-mem-read)))]
    [(cobj.CompilerObjectSectionKind.Data)
      (bit-or
        compiler-object-coff-section-cnt-initialized-data
        (bit-or
          compiler-object-coff-section-align-8
          (bit-or
            compiler-object-coff-section-mem-read
            compiler-object-coff-section-mem-write)))]
    [(cobj.CompilerObjectSectionKind.Rodata)
      (bit-or
        compiler-object-coff-section-cnt-initialized-data
        (bit-or
          compiler-object-coff-section-align-8
          compiler-object-coff-section-mem-read))]
    [(cobj.CompilerObjectSectionKind.Bss)
      (bit-or
        compiler-object-coff-section-cnt-uninitialized-data
        (bit-or
          compiler-object-coff-section-align-8
          (bit-or
            compiler-object-coff-section-mem-read
            compiler-object-coff-section-mem-write)))]
    [(cobj.CompilerObjectSectionKind.Pdata)
      (bit-or
        compiler-object-coff-section-cnt-initialized-data
        (bit-or
          compiler-object-coff-section-align-8
          compiler-object-coff-section-mem-read))]
    [(cobj.CompilerObjectSectionKind.Xdata)
      (bit-or
        compiler-object-coff-section-cnt-initialized-data
        (bit-or
          compiler-object-coff-section-align-8
          compiler-object-coff-section-mem-read))]
    [(cobj.CompilerObjectSectionKind.Rsrc)
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
  [record : cobj.CompilerObjectDataRecord]
  [offset : i64]) : i64
  (match record
    [(cobj.CompilerObjectDataRecord.Label _) offset]
    [(cobj.CompilerObjectDataRecord.Align align)
      (compiler-object-coff-align-offset offset align)]
    [(cobj.CompilerObjectDataRecord.Bytes bytes)
      (+ offset (compiler-object-coff-string-length bytes))]
    [(cobj.CompilerObjectDataRecord.String text)
      (+ offset (compiler-object-coff-string-length text))]
    [(cobj.CompilerObjectDataRecord.F64 _) (+ offset 8)]
    [(cobj.CompilerObjectDataRecord.F32 _) (+ offset 4)]
    [(cobj.CompilerObjectDataRecord.I64 _) (+ offset 8)]
    [(cobj.CompilerObjectDataRecord.Zero count) (+ offset count)]
    [(cobj.CompilerObjectDataRecord.SymbolAddress _) (+ offset 8)]
    [(cobj.CompilerObjectDataRecord.SymbolRva32 _) (+ offset 4)]))

(define (compiler-object-coff-data-records-size-from
  [records : cobj.CompilerObjectDataRecordList]
  [offset : i64]) : i64
  (let
    [count : i64 (cobj.compiler-object-data-record-list-count records)]
    [index : i64 0]
    [cur-offset : i64 offset]
    (begin
      (while (< index count)
        (begin
          (set!
            cur-offset
            (compiler-object-coff-data-record-end-offset
              (cobj.compiler-object-data-record-list-ref records index)
              cur-offset))
          (set! index (+ index 1))))
      cur-offset)))

(define (compiler-object-coff-data-records-size
  [records : cobj.CompilerObjectDataRecordList]) : i64
  (compiler-object-coff-data-records-size-from records 0))

(define (compiler-object-coff-instr-size [instr : cobj.CompilerObjectX64Instr]) : i64
  (match instr
    [(cobj.CompilerObjectX64Instr.Label _) 0]
    [(cobj.CompilerObjectX64Instr.Call _) 5]
    [(cobj.CompilerObjectX64Instr.TailCall _) 5]
    [(cobj.CompilerObjectX64Instr.Jump _) 5]
    [(cobj.CompilerObjectX64Instr.Ja _) 6]
    [(cobj.CompilerObjectX64Instr.Branch _ _) 14]
    [(cobj.CompilerObjectX64Instr.LoadRip _) 7]
    [(cobj.CompilerObjectX64Instr.LoadRipAddress _) 7]
    [(cobj.CompilerObjectX64Instr.LoadRipAddressR11 _) 7]
    [(cobj.CompilerObjectX64Instr.StoreRip _) 7]
    [(cobj.CompilerObjectX64Instr.SubRspImm8 _) 4]
    [(cobj.CompilerObjectX64Instr.MovRcxRip _) 7]
    [(cobj.CompilerObjectX64Instr.MovRdxRip _) 7]
    [(cobj.CompilerObjectX64Instr.LoadRipAddressRdx _) 7]
    [(cobj.CompilerObjectX64Instr.StoreR14Rip _) 7]
    [(cobj.CompilerObjectX64Instr.StoreR15Rip _) 7]
    [(cobj.CompilerObjectX64Instr.AddRcxRip _) 7]
    [(cobj.CompilerObjectX64Instr.MovRcxRax) 3]
    [(cobj.CompilerObjectX64Instr.XorpdRip _) 8]
    [(cobj.CompilerObjectX64Instr.Bytes bytes)
      (compiler-object-coff-string-length bytes)]
    [(cobj.CompilerObjectX64Instr.Raw _) 0]
    [_ 0]))

(define (compiler-object-coff-instr-relocation-count
  [instr : cobj.CompilerObjectX64Instr]) : i64
  (match instr
    [(cobj.CompilerObjectX64Instr.Label _) 0]
    [(cobj.CompilerObjectX64Instr.Call _) 1]
    [(cobj.CompilerObjectX64Instr.TailCall _) 1]
    [(cobj.CompilerObjectX64Instr.Jump _) 1]
    [(cobj.CompilerObjectX64Instr.Ja _) 1]
    [(cobj.CompilerObjectX64Instr.Branch _ _) 2]
    [(cobj.CompilerObjectX64Instr.LoadRip _) 1]
    [(cobj.CompilerObjectX64Instr.LoadRipAddress _) 1]
    [(cobj.CompilerObjectX64Instr.LoadRipAddressR11 _) 1]
    [(cobj.CompilerObjectX64Instr.StoreRip _) 1]
    [(cobj.CompilerObjectX64Instr.SubRspImm8 _) 0]
    [(cobj.CompilerObjectX64Instr.MovRcxRip _) 1]
    [(cobj.CompilerObjectX64Instr.MovRdxRip _) 1]
    [(cobj.CompilerObjectX64Instr.LoadRipAddressRdx _) 1]
    [(cobj.CompilerObjectX64Instr.StoreR14Rip _) 1]
    [(cobj.CompilerObjectX64Instr.StoreR15Rip _) 1]
    [(cobj.CompilerObjectX64Instr.AddRcxRip _) 1]
    [(cobj.CompilerObjectX64Instr.MovRcxRax) 0]
    [(cobj.CompilerObjectX64Instr.XorpdRip _) 1]
    [(cobj.CompilerObjectX64Instr.Bytes _) 0]
    [(cobj.CompilerObjectX64Instr.Raw _) 0]))

(define (compiler-object-coff-instrs-relocation-count
  [instrs : cobj.CompilerObjectX64InstrList]) : i64
  (let
    [count : i64 (cobj.compiler-object-instr-list-count instrs)]
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
                (cobj.compiler-object-instr-list-ref instrs index))))
          (set! index (+ index 1))))
      total)))

(define (compiler-object-coff-instrs-size-from
  [instrs : cobj.CompilerObjectX64InstrList]
  [offset : i64]) : i64
  (let
    [count : i64 (cobj.compiler-object-instr-list-count instrs)]
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
                (cobj.compiler-object-instr-list-ref instrs index))))
          (set! index (+ index 1))))
      cur-offset)))

(define (compiler-object-coff-instrs-size
  [instrs : cobj.CompilerObjectX64InstrList]) : i64
  (compiler-object-coff-instrs-size-from instrs 0))

(define (compiler-object-coff-section-virtual-size
  [image : cobj.CompilerObjectImage]
  [kind : cobj.CompilerObjectSectionKind]) : i64
  (match (cobj.compiler-object-section-list-find
    (struct-get image sections)
    kind)
    [(cobj.CompilerObjectSection.Section _ data instrs)
      (match kind
        [(cobj.CompilerObjectSectionKind.Text)
          (compiler-object-coff-instrs-size instrs)]
        [_ (compiler-object-coff-data-records-size data)])]))

(define (compiler-object-coff-section-raw-size
  [image : cobj.CompilerObjectImage]
  [kind : cobj.CompilerObjectSectionKind]) : i64
  (match kind
    [(cobj.CompilerObjectSectionKind.Bss) 0]
    [_ (compiler-object-coff-section-virtual-size image kind)]))

(define (compiler-object-coff-text-relocation-kind-supported?
  [kind : cobj.CompilerObjectRelocationKind]) : bool
  (match kind
    [(cobj.CompilerObjectRelocationKind.Call) true]
    [(cobj.CompilerObjectRelocationKind.TailCall) true]
    [(cobj.CompilerObjectRelocationKind.RipValue) true]
    [(cobj.CompilerObjectRelocationKind.RipAddress) true]
    [(cobj.CompilerObjectRelocationKind.Branch) true]
    [_ false]))

(define (compiler-object-coff-data-relocation-kind-supported?
  [kind : cobj.CompilerObjectRelocationKind]) : bool
  (match kind
    [(cobj.CompilerObjectRelocationKind.Abs64) true]
    [(cobj.CompilerObjectRelocationKind.Addr32Nb) true]
    [_ false]))

(define (compiler-object-coff-relocation-supported?
  [reloc : cobj.CompilerObjectRelocation]) : bool
  (match reloc
    [(cobj.CompilerObjectRelocation.Relocation section _ kind _)
      (match section
        [(cobj.CompilerObjectSectionKind.Text)
          (compiler-object-coff-text-relocation-kind-supported? kind)]
        [_ (compiler-object-coff-data-relocation-kind-supported? kind)])]))

(define (compiler-object-coff-relocation-list-supported?
  [relocs : cobj.CompilerObjectRelocationList]) : bool
  (let
    [count : i64 (cobj.compiler-object-relocation-list-count relocs)]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (if (compiler-object-coff-relocation-supported?
          (cobj.compiler-object-relocation-list-ref relocs index))
          (set! index (+ index 1))
          (set! ok false)))
      ok)))

(define (compiler-object-coff-data-records-supported?
  [records : cobj.CompilerObjectDataRecordList]) : bool
  (let
    [count : i64 (cobj.compiler-object-data-record-list-count records)]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (match (cobj.compiler-object-data-record-list-ref records index)
          [_ (set! index (+ index 1))]))
      ok)))

(define (compiler-object-coff-instrs-supported?
  [instrs : cobj.CompilerObjectX64InstrList]) : bool
  (let
    [count : i64 (cobj.compiler-object-instr-list-count instrs)]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (match (cobj.compiler-object-instr-list-ref instrs index)
          [(cobj.CompilerObjectX64Instr.Label _) (set! index (+ index 1))]
          [(cobj.CompilerObjectX64Instr.Call _) (set! index (+ index 1))]
          [(cobj.CompilerObjectX64Instr.TailCall _) (set! index (+ index 1))]
          [(cobj.CompilerObjectX64Instr.Jump _) (set! index (+ index 1))]
          [(cobj.CompilerObjectX64Instr.Ja _) (set! index (+ index 1))]
          [(cobj.CompilerObjectX64Instr.Branch _ _) (set! index (+ index 1))]
          [(cobj.CompilerObjectX64Instr.LoadRip _) (set! index (+ index 1))]
          [(cobj.CompilerObjectX64Instr.LoadRipAddress _)
            (set! index (+ index 1))]
          [(cobj.CompilerObjectX64Instr.LoadRipAddressR11 _)
            (set! index (+ index 1))]
          [(cobj.CompilerObjectX64Instr.StoreRip _) (set! index (+ index 1))]
          [(cobj.CompilerObjectX64Instr.SubRspImm8 _) (set! index (+ index 1))]
          [(cobj.CompilerObjectX64Instr.MovRcxRip _) (set! index (+ index 1))]
          [(cobj.CompilerObjectX64Instr.MovRdxRip _) (set! index (+ index 1))]
          [(cobj.CompilerObjectX64Instr.LoadRipAddressRdx _)
            (set! index (+ index 1))]
          [(cobj.CompilerObjectX64Instr.StoreR14Rip _) (set! index (+ index 1))]
          [(cobj.CompilerObjectX64Instr.StoreR15Rip _) (set! index (+ index 1))]
          [(cobj.CompilerObjectX64Instr.AddRcxRip _) (set! index (+ index 1))]
          [(cobj.CompilerObjectX64Instr.MovRcxRax) (set! index (+ index 1))]
          [(cobj.CompilerObjectX64Instr.XorpdRip _) (set! index (+ index 1))]
          [(cobj.CompilerObjectX64Instr.Bytes _) (set! index (+ index 1))]
          [(cobj.CompilerObjectX64Instr.Raw _) (set! ok false)]))
      ok)))

(define (compiler-object-coff-sections-supported?
  [sections : cobj.CompilerObjectSectionList]) : bool
  (let
    [count : i64 (cobj.compiler-object-section-list-count sections)]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (match (cobj.compiler-object-section-list-ref sections index)
          [(cobj.CompilerObjectSection.Section _ data instrs)
            (if (and
              (compiler-object-coff-data-records-supported? data)
              (compiler-object-coff-instrs-supported? instrs))
              (set! index (+ index 1))
              (set! ok false))]))
      ok)))

(define (compiler-object-coff-symbol-index-from
  [symbols : cobj.CompilerObjectSymbolList]
  [name : String]
  [index : i64]) : i64
  (let
    [count : i64 (cobj.compiler-object-symbol-list-count symbols)]
    [slot : i64 0]
    [cur-index : i64 index]
    [result : i64 -1]
    [done : bool false]
    (begin
      (while (and (not done) (< slot count))
        (match (cobj.compiler-object-symbol-list-ref symbols slot)
          [(cobj.CompilerObjectSymbol.Symbol found _ _ _)
            (if (string.eq found name)
              (begin
                (set! result cur-index)
                (set! done true))
              (begin
                (set! cur-index (+ cur-index 1))
                (set! slot (+ slot 1))))]))
      result)))

(define (compiler-object-coff-symbol-index
  [image : cobj.CompilerObjectImage]
  [name : String]) : i64
  (compiler-object-coff-symbol-index-from (struct-get image symbols) name 0))

(define (compiler-object-coff-data-label-offset-from
  [records : cobj.CompilerObjectDataRecordList]
  [label : String]
  [offset : i64]) : i64
  (let
    [count : i64 (cobj.compiler-object-data-record-list-count records)]
    [index : i64 0]
    [cur-offset : i64 offset]
    [result : i64 -1]
    [done : bool false]
    (begin
      (while (and (not done) (< index count))
        (let
          [record : cobj.CompilerObjectDataRecord
            (cobj.compiler-object-data-record-list-ref records index)]
          (match record
            [(cobj.CompilerObjectDataRecord.Label found)
              (if (string.eq found label)
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
  [instrs : cobj.CompilerObjectX64InstrList]
  [label : String]
  [offset : i64]) : i64
  (let
    [count : i64 (cobj.compiler-object-instr-list-count instrs)]
    [index : i64 0]
    [cur-offset : i64 offset]
    [result : i64 -1]
    [done : bool false]
    (begin
      (while (and (not done) (< index count))
        (let
          [instr : cobj.CompilerObjectX64Instr
            (cobj.compiler-object-instr-list-ref instrs index)]
          (match instr
            [(cobj.CompilerObjectX64Instr.Label found)
              (if (string.eq found label)
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
  [image : cobj.CompilerObjectImage]
  [kind : cobj.CompilerObjectSectionKind]
  [label : String]) : i64
  (match (cobj.compiler-object-section-list-find
    (struct-get image sections)
    kind)
    [(cobj.CompilerObjectSection.Section _ data instrs)
      (match kind
        [(cobj.CompilerObjectSectionKind.Text)
          (compiler-object-coff-instr-label-offset-from instrs label 0)]
        [_ (compiler-object-coff-data-label-offset-from data label 0)])]))

(define (compiler-object-coff-relocation-sites-known?
  [image : cobj.CompilerObjectImage]
  [relocs : cobj.CompilerObjectRelocationList]) : bool
  (let
    [count : i64 (cobj.compiler-object-relocation-list-count relocs)]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (match (cobj.compiler-object-relocation-list-ref relocs index)
          [(cobj.CompilerObjectRelocation.Relocation section site _ target)
            (if (match section
              [(cobj.CompilerObjectSectionKind.Text)
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
  [image : cobj.CompilerObjectImage]
  [instrs : cobj.CompilerObjectX64InstrList]) : bool
  (let
    [count : i64 (cobj.compiler-object-instr-list-count instrs)]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (match (cobj.compiler-object-instr-list-ref instrs index)
          [(cobj.CompilerObjectX64Instr.Label _) (set! index (+ index 1))]
          [(cobj.CompilerObjectX64Instr.Call target)
            (if (>= (compiler-object-coff-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(cobj.CompilerObjectX64Instr.TailCall target)
            (if (>= (compiler-object-coff-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(cobj.CompilerObjectX64Instr.Jump target)
            (if (>= (compiler-object-coff-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(cobj.CompilerObjectX64Instr.Ja target)
            (if (>= (compiler-object-coff-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(cobj.CompilerObjectX64Instr.Branch true-target false-target)
            (if (and
              (>= (compiler-object-coff-symbol-index image true-target) 0)
              (>= (compiler-object-coff-symbol-index image false-target) 0))
              (set! index (+ index 1))
              (set! ok false))]
          [(cobj.CompilerObjectX64Instr.LoadRip target)
            (if (>= (compiler-object-coff-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(cobj.CompilerObjectX64Instr.LoadRipAddress target)
            (if (>= (compiler-object-coff-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(cobj.CompilerObjectX64Instr.LoadRipAddressR11 target)
            (if (>= (compiler-object-coff-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(cobj.CompilerObjectX64Instr.StoreRip target)
            (if (>= (compiler-object-coff-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(cobj.CompilerObjectX64Instr.SubRspImm8 _) (set! index (+ index 1))]
          [(cobj.CompilerObjectX64Instr.MovRcxRip target)
            (if (>= (compiler-object-coff-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(cobj.CompilerObjectX64Instr.MovRdxRip target)
            (if (>= (compiler-object-coff-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(cobj.CompilerObjectX64Instr.LoadRipAddressRdx target)
            (if (>= (compiler-object-coff-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(cobj.CompilerObjectX64Instr.StoreR14Rip target)
            (if (>= (compiler-object-coff-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(cobj.CompilerObjectX64Instr.StoreR15Rip target)
            (if (>= (compiler-object-coff-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(cobj.CompilerObjectX64Instr.AddRcxRip target)
            (if (>= (compiler-object-coff-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(cobj.CompilerObjectX64Instr.MovRcxRax) (set! index (+ index 1))]
          [(cobj.CompilerObjectX64Instr.XorpdRip target)
            (if (>= (compiler-object-coff-symbol-index image target) 0)
              (set! index (+ index 1))
              (set! ok false))]
          [(cobj.CompilerObjectX64Instr.Bytes _) (set! index (+ index 1))]
          [(cobj.CompilerObjectX64Instr.Raw _) (set! ok false)]))
      ok)))

(define (compiler-object-coff-text-targets-known?
  [image : cobj.CompilerObjectImage]) : bool
  (match (cobj.compiler-object-section-list-find
    (struct-get image sections)
    (cobj.CompilerObjectSectionKind.Text))
    [(cobj.CompilerObjectSection.Section _ _ instrs)
      (compiler-object-coff-instr-targets-known? image instrs)]))

(define (compiler-object-coff-text-instr-relocation-count
  [image : cobj.CompilerObjectImage]) : i64
  (match (cobj.compiler-object-section-list-find
    (struct-get image sections)
    (cobj.CompilerObjectSectionKind.Text))
    [(cobj.CompilerObjectSection.Section _ _ instrs)
      (compiler-object-coff-instrs-relocation-count instrs)]))

(define (compiler-object-coff-text-relocation-count-matches?
  [image : cobj.CompilerObjectImage]) : bool
  (=
    (compiler-object-coff-relocation-count
      (struct-get image relocations)
      (cobj.CompilerObjectSectionKind.Text))
    (compiler-object-coff-text-instr-relocation-count image)))

(define (compiler-object-coff-image-supported?
  [image : cobj.CompilerObjectImage]) : bool
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
  [relocs : cobj.CompilerObjectRelocationList]
  [kind : cobj.CompilerObjectSectionKind]) : i64
  (let
    [count : i64 (cobj.compiler-object-relocation-list-count relocs)]
    [index : i64 0]
    [total : i64 0]
    (begin
      (while (< index count)
        (begin
          (match (cobj.compiler-object-relocation-list-ref relocs index)
            [(cobj.CompilerObjectRelocation.Relocation section _ _ _)
              (if (cobj.compiler-object-section-kind-eq? section kind)
                (set! total (+ total 1))
                unit)])
          (set! index (+ index 1))))
      total)))

(define (compiler-object-coff-section-relocation-count
  [image : cobj.CompilerObjectImage]
  [kind : cobj.CompilerObjectSectionKind]) : i64
  (match kind
    [(cobj.CompilerObjectSectionKind.Text)
      (compiler-object-coff-text-instr-relocation-count image)]
    [_
      (compiler-object-coff-relocation-count
        (struct-get image relocations)
        kind)]))

(define (compiler-object-coff-total-relocation-count
  [image : cobj.CompilerObjectImage]) : i64
  (+
    (compiler-object-coff-section-relocation-count
      image
      (cobj.CompilerObjectSectionKind.Text))
    (+
      (compiler-object-coff-section-relocation-count
        image
        (cobj.CompilerObjectSectionKind.Data))
      (+
        (compiler-object-coff-section-relocation-count
          image
          (cobj.CompilerObjectSectionKind.Rodata))
        (+
          (compiler-object-coff-section-relocation-count
            image
            (cobj.CompilerObjectSectionKind.Bss))
          (+
            (compiler-object-coff-section-relocation-count
              image
              (cobj.CompilerObjectSectionKind.Pdata))
            (+
              (compiler-object-coff-section-relocation-count
                image
                (cobj.CompilerObjectSectionKind.Xdata))
              (compiler-object-coff-section-relocation-count
                image
                (cobj.CompilerObjectSectionKind.Rsrc)))))))))

(define (compiler-object-coff-raw-base-after-section
  [image : cobj.CompilerObjectImage]
  [kind : cobj.CompilerObjectSectionKind]) : i64
  (match kind
    [(cobj.CompilerObjectSectionKind.Text) (compiler-object-coff-header-size)]
    [(cobj.CompilerObjectSectionKind.Data)
      (+
        (compiler-object-coff-header-size)
        (compiler-object-coff-section-raw-size
          image
          (cobj.CompilerObjectSectionKind.Text)))]
    [(cobj.CompilerObjectSectionKind.Rodata)
      (+
        (compiler-object-coff-header-size)
        (+
          (compiler-object-coff-section-raw-size
            image
            (cobj.CompilerObjectSectionKind.Text))
          (compiler-object-coff-section-raw-size
            image
            (cobj.CompilerObjectSectionKind.Data))))]
    [(cobj.CompilerObjectSectionKind.Bss) 0]
    [(cobj.CompilerObjectSectionKind.Pdata)
      (+
        (compiler-object-coff-header-size)
        (+
          (compiler-object-coff-section-raw-size
            image
            (cobj.CompilerObjectSectionKind.Text))
          (+
            (compiler-object-coff-section-raw-size
              image
              (cobj.CompilerObjectSectionKind.Data))
            (compiler-object-coff-section-raw-size
              image
              (cobj.CompilerObjectSectionKind.Rodata)))))]
    [(cobj.CompilerObjectSectionKind.Xdata)
      (+
        (compiler-object-coff-header-size)
        (+
          (compiler-object-coff-section-raw-size
            image
            (cobj.CompilerObjectSectionKind.Text))
          (+
            (compiler-object-coff-section-raw-size
              image
              (cobj.CompilerObjectSectionKind.Data))
            (+
              (compiler-object-coff-section-raw-size
                image
                (cobj.CompilerObjectSectionKind.Rodata))
              (compiler-object-coff-section-raw-size
                image
                (cobj.CompilerObjectSectionKind.Pdata))))))]
    [(cobj.CompilerObjectSectionKind.Rsrc)
      (+
        (compiler-object-coff-header-size)
        (+
          (compiler-object-coff-section-raw-size
            image
            (cobj.CompilerObjectSectionKind.Text))
          (+
            (compiler-object-coff-section-raw-size
              image
              (cobj.CompilerObjectSectionKind.Data))
            (+
              (compiler-object-coff-section-raw-size
                image
                (cobj.CompilerObjectSectionKind.Rodata))
              (+
                (compiler-object-coff-section-raw-size
                  image
                  (cobj.CompilerObjectSectionKind.Pdata))
                (compiler-object-coff-section-raw-size
                  image
                  (cobj.CompilerObjectSectionKind.Xdata)))))))]))

(define (compiler-object-coff-section-raw-pointer
  [image : cobj.CompilerObjectImage]
  [kind : cobj.CompilerObjectSectionKind]) : i64
  (if (> (compiler-object-coff-section-raw-size image kind) 0)
    (compiler-object-coff-raw-base-after-section image kind)
    0))

(define (compiler-object-coff-relocation-base
  [image : cobj.CompilerObjectImage]) : i64
  (+
    (compiler-object-coff-header-size)
    (+
      (compiler-object-coff-section-raw-size
        image
        (cobj.CompilerObjectSectionKind.Text))
      (+
        (compiler-object-coff-section-raw-size
          image
          (cobj.CompilerObjectSectionKind.Data))
        (+
          (compiler-object-coff-section-raw-size
            image
            (cobj.CompilerObjectSectionKind.Rodata))
          (+
            (compiler-object-coff-section-raw-size
              image
              (cobj.CompilerObjectSectionKind.Pdata))
            (+
              (compiler-object-coff-section-raw-size
                image
                (cobj.CompilerObjectSectionKind.Xdata))
              (compiler-object-coff-section-raw-size
                image
                (cobj.CompilerObjectSectionKind.Rsrc)))))))))

(define (compiler-object-coff-relocation-pointer
  [image : cobj.CompilerObjectImage]
  [kind : cobj.CompilerObjectSectionKind]) : i64
  (let
    [count : i64 (compiler-object-coff-section-relocation-count image kind)]
    (if (= count 0)
      0
      (let
        [text-count : i64
          (compiler-object-coff-section-relocation-count
            image
            (cobj.CompilerObjectSectionKind.Text))]
        [data-count : i64
          (compiler-object-coff-section-relocation-count
            image
            (cobj.CompilerObjectSectionKind.Data))]
        [rodata-count : i64
          (compiler-object-coff-section-relocation-count
            image
            (cobj.CompilerObjectSectionKind.Rodata))]
        [bss-count : i64
          (compiler-object-coff-section-relocation-count
            image
            (cobj.CompilerObjectSectionKind.Bss))]
        [pdata-count : i64
          (compiler-object-coff-section-relocation-count
            image
            (cobj.CompilerObjectSectionKind.Pdata))]
        [xdata-count : i64
          (compiler-object-coff-section-relocation-count
            image
            (cobj.CompilerObjectSectionKind.Xdata))]
        [base : i64 (compiler-object-coff-relocation-base image)]
        (match kind
          [(cobj.CompilerObjectSectionKind.Text) base]
          [(cobj.CompilerObjectSectionKind.Data)
            (+ base (* compiler-object-coff-relocation-size text-count))]
          [(cobj.CompilerObjectSectionKind.Rodata)
            (+
              base
              (* compiler-object-coff-relocation-size (+ text-count data-count)))]
          [(cobj.CompilerObjectSectionKind.Bss)
            (+
              base
              (*
                compiler-object-coff-relocation-size
                (+ text-count (+ data-count rodata-count))))]
          [(cobj.CompilerObjectSectionKind.Pdata)
            (+
              base
              (*
                compiler-object-coff-relocation-size
                (+ text-count (+ data-count (+ rodata-count bss-count)))))]
          [(cobj.CompilerObjectSectionKind.Xdata)
            (+
              base
              (*
                compiler-object-coff-relocation-size
                (+
                  text-count
                  (+ data-count (+ rodata-count (+ bss-count pdata-count))))))]
          [(cobj.CompilerObjectSectionKind.Rsrc)
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
  [image : cobj.CompilerObjectImage]) : i64
  (+
    (compiler-object-coff-relocation-base image)
    (*
      compiler-object-coff-relocation-size
      (compiler-object-coff-total-relocation-count image))))

(define (compiler-object-coff-push-file-header!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : cobj.CompilerObjectImage]) : unit
  (begin
    (compiler-object-coff-push-u16! out compiler-object-coff-machine-amd64)
    (compiler-object-coff-push-u16! out compiler-object-coff-section-count)
    (compiler-object-coff-push-u32! out 0)
    (compiler-object-coff-push-u32!
      out
      (compiler-object-coff-symbol-table-pointer image))
    (compiler-object-coff-push-u32!
      out
      (cobj.compiler-object-symbol-list-count (struct-get image symbols)))
    (compiler-object-coff-push-u16! out 0)
    (compiler-object-coff-push-u16! out 0)))

(define (compiler-object-coff-push-section-header!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : cobj.CompilerObjectImage]
  [kind : cobj.CompilerObjectSectionKind]) : unit
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
  [image : cobj.CompilerObjectImage]) : unit
  (begin
    (compiler-object-coff-push-section-header!
      out
      image
      (cobj.CompilerObjectSectionKind.Text))
    (compiler-object-coff-push-section-header!
      out
      image
      (cobj.CompilerObjectSectionKind.Data))
    (compiler-object-coff-push-section-header!
      out
      image
      (cobj.CompilerObjectSectionKind.Rodata))
    (compiler-object-coff-push-section-header!
      out
      image
      (cobj.CompilerObjectSectionKind.Bss))
    (compiler-object-coff-push-section-header!
      out
      image
      (cobj.CompilerObjectSectionKind.Pdata))
    (compiler-object-coff-push-section-header!
      out
      image
      (cobj.CompilerObjectSectionKind.Xdata))
    (compiler-object-coff-push-section-header!
      out
      image
      (cobj.CompilerObjectSectionKind.Rsrc))))

(define (compiler-object-coff-render-data-record!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [record : cobj.CompilerObjectDataRecord]
  [offset : i64]) : i64
  (match record
    [(cobj.CompilerObjectDataRecord.Label _) offset]
    [(cobj.CompilerObjectDataRecord.Align align)
      (let
        [aligned : i64 (compiler-object-coff-align-offset offset align)]
        (begin
          (compiler-object-coff-push-zeroes! out (- aligned offset))
          aligned))]
    [(cobj.CompilerObjectDataRecord.Bytes bytes)
      (begin
        (compiler-object-coff-push-string-bytes! out bytes)
        (+ offset (compiler-object-coff-string-length bytes)))]
    [(cobj.CompilerObjectDataRecord.String text)
      (begin
        (compiler-object-coff-push-string-bytes! out text)
        (+ offset (compiler-object-coff-string-length text)))]
    [(cobj.CompilerObjectDataRecord.F64 bits)
      (begin
        (compiler-object-coff-push-u64! out (cast bits : i64))
        (+ offset 8))]
    [(cobj.CompilerObjectDataRecord.F32 bits)
      (begin
        (compiler-object-coff-push-u32! out (cast bits : i64))
        (+ offset 4))]
    [(cobj.CompilerObjectDataRecord.I64 value)
      (begin
        (compiler-object-coff-push-u64! out value)
        (+ offset 8))]
    [(cobj.CompilerObjectDataRecord.Zero count)
      (begin
        (compiler-object-coff-push-zeroes! out count)
        (+ offset count))]
    [(cobj.CompilerObjectDataRecord.SymbolAddress _)
      (begin
        (compiler-object-coff-push-u64! out 0)
        (+ offset 8))]
    [(cobj.CompilerObjectDataRecord.SymbolRva32 _)
      (begin
        (compiler-object-coff-push-u32! out 0)
        (+ offset 4))]))

(define (compiler-object-coff-render-data-records!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [records : cobj.CompilerObjectDataRecordList]
  [offset : i64]) : i64
  (let
    [count : i64 (cobj.compiler-object-data-record-list-count records)]
    [index : i64 0]
    [cur-offset : i64 offset]
    (begin
      (while (< index count)
        (begin
          (set!
            cur-offset
            (compiler-object-coff-render-data-record!
              out
              (cobj.compiler-object-data-record-list-ref records index)
              cur-offset))
          (set! index (+ index 1))))
      cur-offset)))

(define (compiler-object-coff-push-rel32-placeholder!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]) : unit
  (compiler-object-coff-push-u32! out 0))

(define (compiler-object-coff-render-instr!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [instr : cobj.CompilerObjectX64Instr]) : unit
  (match instr
    [(cobj.CompilerObjectX64Instr.Label _) unit]
    [(cobj.CompilerObjectX64Instr.Call _)
      (begin
        (compiler-object-coff-push-u8! out 0xe8)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(cobj.CompilerObjectX64Instr.TailCall _)
      (begin
        (compiler-object-coff-push-u8! out 0xe9)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(cobj.CompilerObjectX64Instr.Jump _)
      (begin
        (compiler-object-coff-push-u8! out 0xe9)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(cobj.CompilerObjectX64Instr.Ja _)
      (begin
        (compiler-object-coff-push-u8! out 0x0f)
        (compiler-object-coff-push-u8! out 0x87)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(cobj.CompilerObjectX64Instr.Branch _ _)
      (begin
        (compiler-object-coff-push-u8! out 0x48)
        (compiler-object-coff-push-u8! out 0x85)
        (compiler-object-coff-push-u8! out 0xc0)
        (compiler-object-coff-push-u8! out 0x0f)
        (compiler-object-coff-push-u8! out 0x85)
        (compiler-object-coff-push-rel32-placeholder! out)
        (compiler-object-coff-push-u8! out 0xe9)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(cobj.CompilerObjectX64Instr.LoadRip _)
      (begin
        (compiler-object-coff-push-u8! out 0x48)
        (compiler-object-coff-push-u8! out 0x8b)
        (compiler-object-coff-push-u8! out 0x05)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(cobj.CompilerObjectX64Instr.LoadRipAddress _)
      (begin
        (compiler-object-coff-push-u8! out 0x48)
        (compiler-object-coff-push-u8! out 0x8d)
        (compiler-object-coff-push-u8! out 0x05)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(cobj.CompilerObjectX64Instr.LoadRipAddressR11 _)
      (begin
        (compiler-object-coff-push-u8! out 0x4c)
        (compiler-object-coff-push-u8! out 0x8d)
        (compiler-object-coff-push-u8! out 0x1d)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(cobj.CompilerObjectX64Instr.StoreRip _)
      (begin
        (compiler-object-coff-push-u8! out 0x48)
        (compiler-object-coff-push-u8! out 0x89)
        (compiler-object-coff-push-u8! out 0x05)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(cobj.CompilerObjectX64Instr.SubRspImm8 imm)
      (begin
        (compiler-object-coff-push-u8! out 0x48)
        (compiler-object-coff-push-u8! out 0x83)
        (compiler-object-coff-push-u8! out 0xec)
        (compiler-object-coff-push-u8! out imm))]
    [(cobj.CompilerObjectX64Instr.MovRcxRip _)
      (begin
        (compiler-object-coff-push-u8! out 0x48)
        (compiler-object-coff-push-u8! out 0x8b)
        (compiler-object-coff-push-u8! out 0x0d)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(cobj.CompilerObjectX64Instr.MovRdxRip _)
      (begin
        (compiler-object-coff-push-u8! out 0x48)
        (compiler-object-coff-push-u8! out 0x8b)
        (compiler-object-coff-push-u8! out 0x15)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(cobj.CompilerObjectX64Instr.LoadRipAddressRdx _)
      (begin
        (compiler-object-coff-push-u8! out 0x48)
        (compiler-object-coff-push-u8! out 0x8d)
        (compiler-object-coff-push-u8! out 0x15)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(cobj.CompilerObjectX64Instr.StoreR14Rip _)
      (begin
        (compiler-object-coff-push-u8! out 0x4c)
        (compiler-object-coff-push-u8! out 0x89)
        (compiler-object-coff-push-u8! out 0x35)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(cobj.CompilerObjectX64Instr.StoreR15Rip _)
      (begin
        (compiler-object-coff-push-u8! out 0x4c)
        (compiler-object-coff-push-u8! out 0x89)
        (compiler-object-coff-push-u8! out 0x3d)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(cobj.CompilerObjectX64Instr.AddRcxRip _)
      (begin
        (compiler-object-coff-push-u8! out 0x48)
        (compiler-object-coff-push-u8! out 0x01)
        (compiler-object-coff-push-u8! out 0x0d)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(cobj.CompilerObjectX64Instr.MovRcxRax)
      (begin
        (compiler-object-coff-push-u8! out 0x48)
        (compiler-object-coff-push-u8! out 0x89)
        (compiler-object-coff-push-u8! out 0xc1))]
    [(cobj.CompilerObjectX64Instr.XorpdRip _)
      (begin
        (compiler-object-coff-push-u8! out 0x66)
        (compiler-object-coff-push-u8! out 0x0f)
        (compiler-object-coff-push-u8! out 0x57)
        (compiler-object-coff-push-u8! out 0x05)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(cobj.CompilerObjectX64Instr.Bytes bytes)
      (compiler-object-coff-push-string-bytes! out bytes)]
    [(cobj.CompilerObjectX64Instr.Raw _) unit]))

(define (compiler-object-coff-render-instrs!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [instrs : cobj.CompilerObjectX64InstrList]) : unit
  (let
    [count : i64 (cobj.compiler-object-instr-list-count instrs)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (compiler-object-coff-render-instr!
            out
            (cobj.compiler-object-instr-list-ref instrs index))
          (set! index (+ index 1))))
      unit)))

(define (compiler-object-coff-render-section-data!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : cobj.CompilerObjectImage]
  [kind : cobj.CompilerObjectSectionKind]) : unit
  (match (cobj.compiler-object-section-list-find
    (struct-get image sections)
    kind)
    [(cobj.CompilerObjectSection.Section _ data instrs)
      (match kind
        [(cobj.CompilerObjectSectionKind.Text)
          (compiler-object-coff-render-instrs! out instrs)]
        [_
          (begin
            (compiler-object-coff-render-data-records! out data 0)
            unit)])]))

(define (compiler-object-coff-render-sections!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : cobj.CompilerObjectImage]) : unit
  (begin
    (compiler-object-coff-render-section-data!
      out
      image
      (cobj.CompilerObjectSectionKind.Text))
    (compiler-object-coff-render-section-data!
      out
      image
      (cobj.CompilerObjectSectionKind.Data))
    (compiler-object-coff-render-section-data!
      out
      image
      (cobj.CompilerObjectSectionKind.Rodata))
    (compiler-object-coff-render-section-data!
      out
      image
      (cobj.CompilerObjectSectionKind.Pdata))
    (compiler-object-coff-render-section-data!
      out
      image
      (cobj.CompilerObjectSectionKind.Xdata))
    (compiler-object-coff-render-section-data!
      out
      image
      (cobj.CompilerObjectSectionKind.Rsrc))))

(define (compiler-object-coff-relocation-type
  [kind : cobj.CompilerObjectRelocationKind]) : i64
  (match kind
    [(cobj.CompilerObjectRelocationKind.Call)
      compiler-object-coff-reloc-amd64-rel32]
    [(cobj.CompilerObjectRelocationKind.TailCall)
      compiler-object-coff-reloc-amd64-rel32]
    [(cobj.CompilerObjectRelocationKind.Abs64)
      compiler-object-coff-reloc-amd64-addr64]
    [(cobj.CompilerObjectRelocationKind.Addr32Nb)
      compiler-object-coff-reloc-amd64-addr32nb]
    [(cobj.CompilerObjectRelocationKind.RipValue)
      compiler-object-coff-reloc-amd64-rel32]
    [(cobj.CompilerObjectRelocationKind.RipAddress)
      compiler-object-coff-reloc-amd64-rel32]
    [(cobj.CompilerObjectRelocationKind.Branch)
      compiler-object-coff-reloc-amd64-rel32]
    [_ 0]))

(define (compiler-object-coff-render-relocation-record!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : cobj.CompilerObjectImage]
  [offset : i64]
  [kind : cobj.CompilerObjectRelocationKind]
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
  [image : cobj.CompilerObjectImage]
  [reloc : cobj.CompilerObjectRelocation]) : unit
  (match reloc
    [(cobj.CompilerObjectRelocation.Relocation section site kind target)
      (compiler-object-coff-render-relocation-record!
        out
        image
        (compiler-object-coff-section-label-offset image section site)
        kind
        target)]))

(define (compiler-object-coff-render-text-instr-relocations!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : cobj.CompilerObjectImage]
  [instrs : cobj.CompilerObjectX64InstrList]
  [offset : i64]) : unit
  (let
    [count : i64 (cobj.compiler-object-instr-list-count instrs)]
    [index : i64 0]
    [cur-offset : i64 offset]
    (begin
      (while (< index count)
        (let
          [instr : cobj.CompilerObjectX64Instr
            (cobj.compiler-object-instr-list-ref instrs index)]
          (begin
            (match instr
              [(cobj.CompilerObjectX64Instr.Label _) unit]
              [(cobj.CompilerObjectX64Instr.Call target)
                (compiler-object-coff-render-relocation-record!
                  out
                  image
                  (+ cur-offset 1)
                  (cobj.CompilerObjectRelocationKind.Call)
                  target)]
              [(cobj.CompilerObjectX64Instr.TailCall target)
                (compiler-object-coff-render-relocation-record!
                  out
                  image
                  (+ cur-offset 1)
                  (cobj.CompilerObjectRelocationKind.TailCall)
                  target)]
              [(cobj.CompilerObjectX64Instr.Jump target)
                (compiler-object-coff-render-relocation-record!
                  out
                  image
                  (+ cur-offset 1)
                  (cobj.CompilerObjectRelocationKind.Branch)
                  target)]
              [(cobj.CompilerObjectX64Instr.Ja target)
                (compiler-object-coff-render-relocation-record!
                  out
                  image
                  (+ cur-offset 2)
                  (cobj.CompilerObjectRelocationKind.Branch)
                  target)]
              [(cobj.CompilerObjectX64Instr.Branch true-target false-target)
                (begin
                  (compiler-object-coff-render-relocation-record!
                    out
                    image
                    (+ cur-offset 5)
                    (cobj.CompilerObjectRelocationKind.Branch)
                    true-target)
                  (compiler-object-coff-render-relocation-record!
                    out
                    image
                    (+ cur-offset 10)
                    (cobj.CompilerObjectRelocationKind.Branch)
                    false-target))]
              [(cobj.CompilerObjectX64Instr.LoadRip target)
                (compiler-object-coff-render-relocation-record!
                  out
                  image
                  (+ cur-offset 3)
                  (cobj.CompilerObjectRelocationKind.RipValue)
                  target)]
              [(cobj.CompilerObjectX64Instr.LoadRipAddress target)
                (compiler-object-coff-render-relocation-record!
                  out
                  image
                  (+ cur-offset 3)
                  (cobj.CompilerObjectRelocationKind.RipAddress)
                  target)]
              [(cobj.CompilerObjectX64Instr.LoadRipAddressR11 target)
                (compiler-object-coff-render-relocation-record!
                  out
                  image
                  (+ cur-offset 3)
                  (cobj.CompilerObjectRelocationKind.RipAddress)
                  target)]
              [(cobj.CompilerObjectX64Instr.StoreRip target)
                (compiler-object-coff-render-relocation-record!
                  out
                  image
                  (+ cur-offset 3)
                  (cobj.CompilerObjectRelocationKind.RipAddress)
                  target)]
              [(cobj.CompilerObjectX64Instr.SubRspImm8 _) unit]
              [(cobj.CompilerObjectX64Instr.MovRcxRip target)
                (compiler-object-coff-render-relocation-record!
                  out
                  image
                  (+ cur-offset 3)
                  (cobj.CompilerObjectRelocationKind.RipValue)
                  target)]
              [(cobj.CompilerObjectX64Instr.MovRdxRip target)
                (compiler-object-coff-render-relocation-record!
                  out
                  image
                  (+ cur-offset 3)
                  (cobj.CompilerObjectRelocationKind.RipValue)
                  target)]
              [(cobj.CompilerObjectX64Instr.LoadRipAddressRdx target)
                (compiler-object-coff-render-relocation-record!
                  out
                  image
                  (+ cur-offset 3)
                  (cobj.CompilerObjectRelocationKind.RipAddress)
                  target)]
              [(cobj.CompilerObjectX64Instr.StoreR14Rip target)
                (compiler-object-coff-render-relocation-record!
                  out
                  image
                  (+ cur-offset 3)
                  (cobj.CompilerObjectRelocationKind.RipAddress)
                  target)]
              [(cobj.CompilerObjectX64Instr.StoreR15Rip target)
                (compiler-object-coff-render-relocation-record!
                  out
                  image
                  (+ cur-offset 3)
                  (cobj.CompilerObjectRelocationKind.RipAddress)
                  target)]
              [(cobj.CompilerObjectX64Instr.AddRcxRip target)
                (compiler-object-coff-render-relocation-record!
                  out
                  image
                  (+ cur-offset 3)
                  (cobj.CompilerObjectRelocationKind.RipAddress)
                  target)]
              [(cobj.CompilerObjectX64Instr.MovRcxRax) unit]
              [(cobj.CompilerObjectX64Instr.XorpdRip target)
                (compiler-object-coff-render-relocation-record!
                  out
                  image
                  (+ cur-offset 4)
                  (cobj.CompilerObjectRelocationKind.RipValue)
                  target)]
              [(cobj.CompilerObjectX64Instr.Bytes _) unit]
              [(cobj.CompilerObjectX64Instr.Raw _) unit])
            (set!
              cur-offset
              (+ cur-offset (compiler-object-coff-instr-size instr)))
            (set! index (+ index 1)))))
      unit)))

(define (compiler-object-coff-render-text-relocations!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : cobj.CompilerObjectImage]) : unit
  (match (cobj.compiler-object-section-list-find
    (struct-get image sections)
    (cobj.CompilerObjectSectionKind.Text))
    [(cobj.CompilerObjectSection.Section _ _ instrs)
      (compiler-object-coff-render-text-instr-relocations! out image instrs 0)]))

(define (compiler-object-coff-render-relocations-for-section!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : cobj.CompilerObjectImage]
  [relocs : cobj.CompilerObjectRelocationList]
  [kind : cobj.CompilerObjectSectionKind]) : unit
  (let
    [count : i64 (cobj.compiler-object-relocation-list-count relocs)]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [reloc : cobj.CompilerObjectRelocation
            (cobj.compiler-object-relocation-list-ref relocs index)]
          (begin
            (match reloc
              [(cobj.CompilerObjectRelocation.Relocation section _ _ _)
                (if (cobj.compiler-object-section-kind-eq? section kind)
                  (compiler-object-coff-render-relocation! out image reloc)
                  unit)])
            (set! index (+ index 1)))))
      unit)))

(define (compiler-object-coff-render-relocations!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : cobj.CompilerObjectImage]) : unit
  (begin
    (compiler-object-coff-render-text-relocations! out image)
    (compiler-object-coff-render-relocations-for-section!
      out
      image
      (struct-get image relocations)
      (cobj.CompilerObjectSectionKind.Data))
    (compiler-object-coff-render-relocations-for-section!
      out
      image
      (struct-get image relocations)
      (cobj.CompilerObjectSectionKind.Rodata))
    (compiler-object-coff-render-relocations-for-section!
      out
      image
      (struct-get image relocations)
      (cobj.CompilerObjectSectionKind.Bss))
    (compiler-object-coff-render-relocations-for-section!
      out
      image
      (struct-get image relocations)
      (cobj.CompilerObjectSectionKind.Pdata))
    (compiler-object-coff-render-relocations-for-section!
      out
      image
      (struct-get image relocations)
      (cobj.CompilerObjectSectionKind.Xdata))
    (compiler-object-coff-render-relocations-for-section!
      out
      image
      (struct-get image relocations)
      (cobj.CompilerObjectSectionKind.Rsrc))))

(define (compiler-object-coff-symbol-name-long? [name : String]) : bool
  (> (compiler-object-coff-string-length name) 8))

(define (compiler-object-coff-symbol-string-offset-from
  [symbols : cobj.CompilerObjectSymbolList]
  [name : String]
  [offset : i64]) : i64
  (let
    [count : i64 (cobj.compiler-object-symbol-list-count symbols)]
    [index : i64 0]
    [cur-offset : i64 offset]
    [result : i64 0]
    [done : bool false]
    (begin
      (while (and (not done) (< index count))
        (match (cobj.compiler-object-symbol-list-ref symbols index)
          [(cobj.CompilerObjectSymbol.Symbol found _ _ _)
            (if (compiler-object-coff-symbol-name-long? found)
              (if (string.eq found name)
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
  [image : cobj.CompilerObjectImage]
  [name : String]) : i64
  (compiler-object-coff-symbol-string-offset-from
    (struct-get image symbols)
    name
    4))

(define (compiler-object-coff-push-symbol-name!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : cobj.CompilerObjectImage]
  [name : String]) : unit
  (if (compiler-object-coff-symbol-name-long? name)
    (begin
      (compiler-object-coff-push-u32! out 0)
      (compiler-object-coff-push-u32!
        out
        (compiler-object-coff-symbol-string-offset image name)))
    (compiler-object-coff-push-name8! out name)))

(define (compiler-object-coff-symbol-storage-class
  [binding : cobj.CompilerObjectSymbolBinding]) : i64
  (match binding
    [(cobj.CompilerObjectSymbolBinding.Local) 3]
    [_ 2]))

(define (compiler-object-coff-symbol-type
  [kind : cobj.CompilerObjectSymbolKind]) : i64
  (match kind
    [(cobj.CompilerObjectSymbolKind.Function) 0x20]
    [_ 0]))

(define (compiler-object-coff-symbol-section-number
  [section : cobj.CompilerObjectMaybeSection]) : i64
  (match section
    [(cobj.CompilerObjectMaybeSection.No) 0]
    [(cobj.CompilerObjectMaybeSection.Some kind)
      (compiler-object-coff-section-number kind)]))

(define (compiler-object-coff-symbol-value
  [image : cobj.CompilerObjectImage]
  [name : String]
  [section : cobj.CompilerObjectMaybeSection]) : i64
  (match section
    [(cobj.CompilerObjectMaybeSection.No) 0]
    [(cobj.CompilerObjectMaybeSection.Some kind)
      (let
        [offset : i64
          (compiler-object-coff-section-label-offset image kind name)]
        (if (< offset 0)
          0
          offset))]))

(define (compiler-object-coff-render-symbol!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : cobj.CompilerObjectImage]
  [symbol : cobj.CompilerObjectSymbol]) : unit
  (match symbol
    [(cobj.CompilerObjectSymbol.Symbol name binding kind section)
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
  [image : cobj.CompilerObjectImage]
  [symbols : cobj.CompilerObjectSymbolList]) : unit
  (let
    [count : i64 (cobj.compiler-object-symbol-list-count symbols)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (compiler-object-coff-render-symbol!
            out
            image
            (cobj.compiler-object-symbol-list-ref symbols index))
          (set! index (+ index 1))))
      unit)))

(define (compiler-object-coff-string-table-size-from
  [symbols : cobj.CompilerObjectSymbolList]
  [size : i64]) : i64
  (let
    [count : i64 (cobj.compiler-object-symbol-list-count symbols)]
    [index : i64 0]
    [total : i64 size]
    (begin
      (while (< index count)
        (begin
          (match (cobj.compiler-object-symbol-list-ref symbols index)
            [(cobj.CompilerObjectSymbol.Symbol name _ _ _)
              (if (compiler-object-coff-symbol-name-long? name)
                (set!
                  total
                  (+ total (+ (compiler-object-coff-string-length name) 1)))
                unit)])
          (set! index (+ index 1))))
      total)))

(define (compiler-object-coff-string-table-size
  [symbols : cobj.CompilerObjectSymbolList]) : i64
  (compiler-object-coff-string-table-size-from symbols 4))

(define (compiler-object-coff-render-string-table-symbols!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [symbols : cobj.CompilerObjectSymbolList]) : unit
  (let
    [count : i64 (cobj.compiler-object-symbol-list-count symbols)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (match (cobj.compiler-object-symbol-list-ref symbols index)
            [(cobj.CompilerObjectSymbol.Symbol name _ _ _)
              (if (compiler-object-coff-symbol-name-long? name)
                (begin
                  (compiler-object-coff-push-string-bytes! out name)
                  (compiler-object-coff-push-u8! out 0))
                unit)])
          (set! index (+ index 1))))
      unit)))

(define (compiler-object-coff-render-string-table!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : cobj.CompilerObjectImage]) : unit
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

(define (compiler-object-coff-render [image : cobj.CompilerObjectImage]) : ResultCompilerObjectCoff
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
  [kind : cobj.CompilerObjectSectionKind]) : i64
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

(cfg
  test
  (define (compiler-object-coff-smoke-image) : cobj.CompilerObjectImage
    (let
      [empty-data : cobj.CompilerObjectDataRecordList
        (cobj.compiler-object-data-record-builder-finish
          (cobj.compiler-object-data-record-builder-with-capacity 1))]
      [empty-instrs : cobj.CompilerObjectX64InstrList
        (cobj.compiler-object-instr-builder-finish
          (cobj.compiler-object-instr-builder-with-capacity 1))]
      [text0 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-with-capacity 1)]
      [text1 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          text0
          (cobj.CompilerObjectX64Instr.Label "_tl_empty"))]
      [data0 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-with-capacity 4)]
      [data1 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          data0
          (cobj.CompilerObjectDataRecord.Label "_tl_answer"))]
      [data2 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          data1
          (cobj.CompilerObjectDataRecord.I64 42))]
      [data3 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          data2
          (cobj.CompilerObjectDataRecord.Label "_tl_ptr"))]
      [data4 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          data3
          (cobj.CompilerObjectDataRecord.SymbolAddress "_tl_answer"))]
      [rodata0 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-with-capacity 2)]
      [rodata1 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          rodata0
          (cobj.CompilerObjectDataRecord.Label "long_rodata_label_name"))]
      [rodata2 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          rodata1
          (cobj.CompilerObjectDataRecord.String "hello"))]
      [bss0 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-with-capacity 2)]
      [bss1 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          bss0
          (cobj.CompilerObjectDataRecord.Label "_tl_heap"))]
      [bss2 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          bss1
          (cobj.CompilerObjectDataRecord.Zero 16))]
      [sections0 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-with-capacity 4)]
      [sections1 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections0
          (cobj.CompilerObjectSection.Section
            (cobj.CompilerObjectSectionKind.Text)
            empty-data
            (cobj.compiler-object-instr-builder-finish text1)))]
      [sections2 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections1
          (cobj.CompilerObjectSection.Section
            (cobj.CompilerObjectSectionKind.Data)
            (cobj.compiler-object-data-record-builder-finish data4)
            empty-instrs))]
      [sections3 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections2
          (cobj.CompilerObjectSection.Section
            (cobj.CompilerObjectSectionKind.Rodata)
            (cobj.compiler-object-data-record-builder-finish rodata2)
            empty-instrs))]
      [sections4 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections3
          (cobj.CompilerObjectSection.Section
            (cobj.CompilerObjectSectionKind.Bss)
            (cobj.compiler-object-data-record-builder-finish bss2)
            empty-instrs))]
      [symbols0 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-with-capacity 5)]
      [symbols1 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols0
          (cobj.CompilerObjectSymbol.Symbol
            "_tl_empty"
            (cobj.CompilerObjectSymbolBinding.Export)
            (cobj.CompilerObjectSymbolKind.Function)
            (cobj.CompilerObjectMaybeSection.Some
              (cobj.CompilerObjectSectionKind.Text))))]
      [symbols2 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols1
          (cobj.CompilerObjectSymbol.Symbol
            "_tl_answer"
            (cobj.CompilerObjectSymbolBinding.Export)
            (cobj.CompilerObjectSymbolKind.Data)
            (cobj.CompilerObjectMaybeSection.Some
              (cobj.CompilerObjectSectionKind.Data))))]
      [symbols3 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols2
          (cobj.CompilerObjectSymbol.Symbol
            "_tl_ptr"
            (cobj.CompilerObjectSymbolBinding.Local)
            (cobj.CompilerObjectSymbolKind.Data)
            (cobj.CompilerObjectMaybeSection.Some
              (cobj.CompilerObjectSectionKind.Data))))]
      [symbols4 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols3
          (cobj.CompilerObjectSymbol.Symbol
            "long_rodata_label_name"
            (cobj.CompilerObjectSymbolBinding.Local)
            (cobj.CompilerObjectSymbolKind.Data)
            (cobj.CompilerObjectMaybeSection.Some
              (cobj.CompilerObjectSectionKind.Rodata))))]
      [symbols5 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols4
          (cobj.CompilerObjectSymbol.Symbol
            "foreign_exact"
            (cobj.CompilerObjectSymbolBinding.Extern)
            (cobj.CompilerObjectSymbolKind.Function)
            cobj.CompilerObjectMaybeSection.No))]
      [relocs : cobj.CompilerObjectRelocationList
        (cobj.compiler-object-relocation-builder-finish
          (cobj.compiler-object-relocation-builder-push
            (cobj.compiler-object-relocation-builder-with-capacity 1)
            (cobj.CompilerObjectRelocation.Relocation
              (cobj.CompilerObjectSectionKind.Data)
              "_tl_ptr"
              (cobj.CompilerObjectRelocationKind.Abs64)
              "_tl_answer")))]
      (cobj.CompilerObjectImage
        (cobj.compiler-object-section-builder-finish sections4)
        (cobj.compiler-object-symbol-builder-finish symbols5)
        relocs))))

(cfg
  test
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
      [(ResultCompilerObjectCoff.Err _) false])))

(cfg
  test
  (define (compiler-object-coff-text-smoke-instrs) : cobj.CompilerObjectX64InstrList
    (let
      [instrs0 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-with-capacity 11)]
      [instrs1 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs0
          (cobj.CompilerObjectX64Instr.Label "_tl_text"))]
      [instrs2 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs1
          (cobj.CompilerObjectX64Instr.LoadRip "_tl_answer"))]
      [instrs3 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs2
          (cobj.CompilerObjectX64Instr.LoadRipAddress "_tl_slot"))]
      [instrs4 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs3
          (cobj.CompilerObjectX64Instr.StoreRip "_tl_slot"))]
      [instrs5 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs4
          (cobj.CompilerObjectX64Instr.Call "foreign_exact"))]
      [instrs6 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs5
          (cobj.CompilerObjectX64Instr.TailCall "_tl_done"))]
      [instrs7 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs6
          (cobj.CompilerObjectX64Instr.Jump "_tl_done"))]
      [instrs8 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs7
          (cobj.CompilerObjectX64Instr.Branch "_tl_true" "_tl_false"))]
      [instrs9 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs8
          (cobj.CompilerObjectX64Instr.Label "_tl_true"))]
      [instrs10 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs9
          (cobj.CompilerObjectX64Instr.Label "_tl_false"))]
      [instrs11 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs10
          (cobj.CompilerObjectX64Instr.Label "_tl_done"))]
      (cobj.compiler-object-instr-builder-finish instrs11))))

(cfg
  test
  (define (compiler-object-coff-text-smoke-symbols) : cobj.CompilerObjectSymbolList
    (let
      [symbols0 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-with-capacity 7)]
      [symbols1 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols0
          (cobj.CompilerObjectSymbol.Symbol
            "_tl_text"
            (cobj.CompilerObjectSymbolBinding.Export)
            (cobj.CompilerObjectSymbolKind.Function)
            (cobj.CompilerObjectMaybeSection.Some
              (cobj.CompilerObjectSectionKind.Text))))]
      [symbols2 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols1
          (cobj.CompilerObjectSymbol.Symbol
            "_tl_true"
            (cobj.CompilerObjectSymbolBinding.Local)
            (cobj.CompilerObjectSymbolKind.Function)
            (cobj.CompilerObjectMaybeSection.Some
              (cobj.CompilerObjectSectionKind.Text))))]
      [symbols3 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols2
          (cobj.CompilerObjectSymbol.Symbol
            "_tl_false"
            (cobj.CompilerObjectSymbolBinding.Local)
            (cobj.CompilerObjectSymbolKind.Function)
            (cobj.CompilerObjectMaybeSection.Some
              (cobj.CompilerObjectSectionKind.Text))))]
      [symbols4 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols3
          (cobj.CompilerObjectSymbol.Symbol
            "_tl_done"
            (cobj.CompilerObjectSymbolBinding.Local)
            (cobj.CompilerObjectSymbolKind.Function)
            (cobj.CompilerObjectMaybeSection.Some
              (cobj.CompilerObjectSectionKind.Text))))]
      [symbols5 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols4
          (cobj.CompilerObjectSymbol.Symbol
            "_tl_answer"
            (cobj.CompilerObjectSymbolBinding.Export)
            (cobj.CompilerObjectSymbolKind.Data)
            (cobj.CompilerObjectMaybeSection.Some
              (cobj.CompilerObjectSectionKind.Data))))]
      [symbols6 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols5
          (cobj.CompilerObjectSymbol.Symbol
            "_tl_slot"
            (cobj.CompilerObjectSymbolBinding.Local)
            (cobj.CompilerObjectSymbolKind.Data)
            (cobj.CompilerObjectMaybeSection.Some
              (cobj.CompilerObjectSectionKind.Data))))]
      [symbols7 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols6
          (cobj.CompilerObjectSymbol.Symbol
            "foreign_exact"
            (cobj.CompilerObjectSymbolBinding.Extern)
            (cobj.CompilerObjectSymbolKind.Function)
            cobj.CompilerObjectMaybeSection.No))]
      (cobj.compiler-object-symbol-builder-finish symbols7))))

(cfg
  test
  (define (compiler-object-coff-text-smoke-relocs) : cobj.CompilerObjectRelocationList
    (let
      [relocs0 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-with-capacity 8)]
      [relocs1 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs0
          (cobj.CompilerObjectRelocation.Relocation
            (cobj.CompilerObjectSectionKind.Text)
            "_tl_text"
            (cobj.CompilerObjectRelocationKind.RipValue)
            "_tl_answer"))]
      [relocs2 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs1
          (cobj.CompilerObjectRelocation.Relocation
            (cobj.CompilerObjectSectionKind.Text)
            "_tl_text"
            (cobj.CompilerObjectRelocationKind.RipAddress)
            "_tl_slot"))]
      [relocs3 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs2
          (cobj.CompilerObjectRelocation.Relocation
            (cobj.CompilerObjectSectionKind.Text)
            "_tl_text"
            (cobj.CompilerObjectRelocationKind.RipAddress)
            "_tl_slot"))]
      [relocs4 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs3
          (cobj.CompilerObjectRelocation.Relocation
            (cobj.CompilerObjectSectionKind.Text)
            "_tl_text"
            (cobj.CompilerObjectRelocationKind.Call)
            "foreign_exact"))]
      [relocs5 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs4
          (cobj.CompilerObjectRelocation.Relocation
            (cobj.CompilerObjectSectionKind.Text)
            "_tl_text"
            (cobj.CompilerObjectRelocationKind.TailCall)
            "_tl_done"))]
      [relocs6 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs5
          (cobj.CompilerObjectRelocation.Relocation
            (cobj.CompilerObjectSectionKind.Text)
            "_tl_text"
            (cobj.CompilerObjectRelocationKind.Branch)
            "_tl_done"))]
      [relocs7 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs6
          (cobj.CompilerObjectRelocation.Relocation
            (cobj.CompilerObjectSectionKind.Text)
            "_tl_text"
            (cobj.CompilerObjectRelocationKind.Branch)
            "_tl_true"))]
      [relocs8 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs7
          (cobj.CompilerObjectRelocation.Relocation
            (cobj.CompilerObjectSectionKind.Text)
            "_tl_text"
            (cobj.CompilerObjectRelocationKind.Branch)
            "_tl_false"))]
      (cobj.compiler-object-relocation-builder-finish relocs8))))

(cfg
  test
  (define (compiler-object-coff-text-smoke-image) : cobj.CompilerObjectImage
    (let
      [empty-data : cobj.CompilerObjectDataRecordList
        (cobj.compiler-object-data-record-builder-finish
          (cobj.compiler-object-data-record-builder-with-capacity 1))]
      [empty-instrs : cobj.CompilerObjectX64InstrList
        (cobj.compiler-object-instr-builder-finish
          (cobj.compiler-object-instr-builder-with-capacity 1))]
      [data0 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-with-capacity 4)]
      [data1 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          data0
          (cobj.CompilerObjectDataRecord.Label "_tl_answer"))]
      [data2 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          data1
          (cobj.CompilerObjectDataRecord.I64 42))]
      [data3 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          data2
          (cobj.CompilerObjectDataRecord.Label "_tl_slot"))]
      [data4 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          data3
          (cobj.CompilerObjectDataRecord.I64 0))]
      [sections0 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-with-capacity 4)]
      [sections1 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections0
          (cobj.CompilerObjectSection.Section
            (cobj.CompilerObjectSectionKind.Text)
            empty-data
            (compiler-object-coff-text-smoke-instrs)))]
      [sections2 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections1
          (cobj.CompilerObjectSection.Section
            (cobj.CompilerObjectSectionKind.Data)
            (cobj.compiler-object-data-record-builder-finish data4)
            empty-instrs))]
      [sections3 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections2
          (cobj.CompilerObjectSection.Section
            (cobj.CompilerObjectSectionKind.Rodata)
            empty-data
            empty-instrs))]
      [sections4 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections3
          (cobj.CompilerObjectSection.Section
            (cobj.CompilerObjectSectionKind.Bss)
            empty-data
            empty-instrs))]
      (cobj.CompilerObjectImage
        (cobj.compiler-object-section-builder-finish sections4)
        (compiler-object-coff-text-smoke-symbols)
        (compiler-object-coff-text-smoke-relocs)))))

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

(cfg
  test
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
      (= (compiler-object-coff-u8-at obj (+ text-ptr 45)) 0xe9))))

(cfg
  test
  (define (compiler-object-coff-text-smoke-relocs-ok?
    [image : cobj.CompilerObjectImage]
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
          rel32)))))

(cfg
  test
  (define (compiler-object-coff-text-smoke-ok?) : bool
    (let
      [image : cobj.CompilerObjectImage (compiler-object-coff-text-smoke-image)]
      (match (compiler-object-coff-render image)
        [(ResultCompilerObjectCoff.Ok obj)
          (let
            [text-header : i64
              (compiler-object-coff-section-header-offset
                (cobj.CompilerObjectSectionKind.Text))]
            [text-size : i64
              (compiler-object-coff-u32-at obj (+ text-header 16))]
            [text-ptr : i64
              (compiler-object-coff-u32-at obj (+ text-header 20))]
            [reloc-ptr : i64
              (compiler-object-coff-u32-at obj (+ text-header 24))]
            [reloc-count : i64
              (compiler-object-coff-u16-at obj (+ text-header 32))]
            (and
              (= text-size 50)
              (= text-ptr (compiler-object-coff-header-size))
              (= reloc-count 8)
              (compiler-object-coff-text-smoke-bytes-ok? obj text-ptr)
              (compiler-object-coff-text-smoke-relocs-ok? image obj reloc-ptr)))]
        [(ResultCompilerObjectCoff.Err _) false]))))

(cfg
  test
  (test
    compiler-object-coff-smoke
    (begin
      (test.assert-true (compiler-object-coff-smoke-ok?) "coff object smoke")
      (test.assert-true
        (compiler-object-coff-text-smoke-ok?)
        "coff text object smoke"))))