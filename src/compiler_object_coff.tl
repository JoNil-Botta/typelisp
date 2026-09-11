;; compiler_object_coff.tl - COFF object-file serialization for object images.
(import compiler_owned_view as owned_view)
(import stdlib.byte_buf_core)
(import stdlib.str_cat_runtime as str_cat)
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

(defenum ResultCompilerObjectCoffLayout
  (Ok i64)
  (Err String))

(defstruct CompilerObjectCoffLayoutAccumulator
  (offset i64)
  (error String))

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
(define compiler-object-coff-relocation-overflow-threshold : i64
  0xffff)
(define compiler-object-coff-max-u32 : i64
  0xffffffff)

;; Keep object rendering bounded independently of the host address space.  The
;; format's pointers are u32, but allocating anything near that limit is not a
;; useful compiler workload and can make a malformed image take down the host.
(define compiler-object-coff-max-output-size : i64
  1073741824)
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
(define compiler-object-coff-section-lnk-nreloc-ovfl : i64
  0x01000000)
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
    [n : i64
      (compiler-object-coff-string-length
        (owned_view.compiler-owned-shared-view text))]
    (begin
      (while (< i n)
        (begin
          (byte_buf_core.byte-buf-builder-push
            out
            (cast
              (compiler-object-coff-string-ref
                (owned_view.compiler-owned-shared-view text)
                i)
              : u8))
          (set! i (+ i 1))))
      unit)))

(define (compiler-object-coff-push-name8!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [name : String]) : unit
  (let
    [i : i64 0]
    [n : i64
      (compiler-object-coff-string-length
        (owned_view.compiler-owned-shared-view name))]
    (begin
      (while (< i 8)
        (begin
          (if (< i n)
            (byte_buf_core.byte-buf-builder-push
              out
              (cast
                (compiler-object-coff-string-ref
                  (owned_view.compiler-owned-shared-view name)
                  i)
                : u8))
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
  (cobj.compiler-object-data-record-end-offset record offset))

(define (compiler-object-coff-data-records-size-from
  [records : cobj.CompilerObjectDataRecordList]
  [offset : i64]) : i64
  (let
    [count : i64
      (cobj.compiler-object-data-record-list-count
        (owned_view.compiler-owned-shared-view records))]
    [index : i64 0]
    [cur-offset : i64 offset]
    (begin
      (while (< index count)
        (begin
          (set!
            cur-offset
            (compiler-object-coff-data-record-end-offset
              (cobj.compiler-object-data-record-list-ref
                (owned_view.compiler-owned-shared-view records)
                index)
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
    [count : i64
      (cobj.compiler-object-instr-list-count
        (owned_view.compiler-owned-shared-view instrs))]
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
                (cobj.compiler-object-instr-list-ref
                  (owned_view.compiler-owned-shared-view instrs)
                  index))))
          (set! index (+ index 1))))
      total)))

(define (compiler-object-coff-instrs-size-from
  [instrs : cobj.CompilerObjectX64InstrList]
  [offset : i64]) : i64
  (let
    [count : i64
      (cobj.compiler-object-instr-list-count
        (owned_view.compiler-owned-shared-view instrs))]
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
                (cobj.compiler-object-instr-list-ref
                  (owned_view.compiler-owned-shared-view instrs)
                  index))))
          (set! index (+ index 1))))
      cur-offset)))

(define (compiler-object-coff-instrs-size
  [instrs : cobj.CompilerObjectX64InstrList]) : i64
  (compiler-object-coff-instrs-size-from instrs 0))

(define (compiler-object-coff-section-virtual-size
  [image : cobj.CompilerObjectImage]
  [kind : cobj.CompilerObjectSectionKind]) : i64
  (match (cobj.compiler-object-section-list-find image.sections kind)
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
    [count : i64
      (cobj.compiler-object-relocation-list-count
        (owned_view.compiler-owned-shared-view relocs))]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (if (compiler-object-coff-relocation-supported?
          (cobj.compiler-object-relocation-list-ref
            (owned_view.compiler-owned-shared-view relocs)
            index))
          (set! index (+ index 1))
          (set! ok false)))
      ok)))

(define (compiler-object-coff-data-records-supported?
  [records : cobj.CompilerObjectDataRecordList]) : bool
  (let
    [count : i64
      (cobj.compiler-object-data-record-list-count
        (owned_view.compiler-owned-shared-view records))]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (match (cobj.compiler-object-data-record-list-ref
          (owned_view.compiler-owned-shared-view records)
          index)
          [_ (set! index (+ index 1))]))
      ok)))

(define (compiler-object-coff-instrs-supported?
  [instrs : cobj.CompilerObjectX64InstrList]) : bool
  (let
    [count : i64
      (cobj.compiler-object-instr-list-count
        (owned_view.compiler-owned-shared-view instrs))]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (match (cobj.compiler-object-instr-list-ref
          (owned_view.compiler-owned-shared-view instrs)
          index)
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
    [count : i64
      (cobj.compiler-object-section-list-count
        (owned_view.compiler-owned-shared-view sections))]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (match (cobj.compiler-object-section-list-ref
          (owned_view.compiler-owned-shared-view sections)
          index)
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
    [count : i64
      (cobj.compiler-object-symbol-list-count
        (owned_view.compiler-owned-shared-view symbols))]
    [slot : i64 0]
    [cur-index : i64 index]
    [result : i64 -1]
    [done : bool false]
    (begin
      (while (and (not done) (< slot count))
        (match (cobj.compiler-object-symbol-list-ref
          (owned_view.compiler-owned-shared-view symbols)
          slot)
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
  (compiler-object-coff-symbol-index-from image.symbols name 0))

(define (compiler-object-coff-data-label-offset-from
  [records : cobj.CompilerObjectDataRecordList]
  [label : String]
  [offset : i64]) : i64
  (let
    [count : i64
      (cobj.compiler-object-data-record-list-count
        (owned_view.compiler-owned-shared-view records))]
    [index : i64 0]
    [cur-offset : i64 offset]
    [result : i64 -1]
    [done : bool false]
    (begin
      (while (and (not done) (< index count))
        (let
          [record : cobj.CompilerObjectDataRecord
            (cobj.compiler-object-data-record-list-ref
              (owned_view.compiler-owned-shared-view records)
              index)]
          (match (owned_view.compiler-owned-shared-view record)
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
    [count : i64
      (cobj.compiler-object-instr-list-count
        (owned_view.compiler-owned-shared-view instrs))]
    [index : i64 0]
    [cur-offset : i64 offset]
    [result : i64 -1]
    [done : bool false]
    (begin
      (while (and (not done) (< index count))
        (let
          [instr : cobj.CompilerObjectX64Instr
            (cobj.compiler-object-instr-list-ref
              (owned_view.compiler-owned-shared-view instrs)
              index)]
          (match (owned_view.compiler-owned-shared-view instr)
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
  (match (cobj.compiler-object-section-list-find image.sections kind)
    [(cobj.CompilerObjectSection.Section _ data instrs)
      (match kind
        [(cobj.CompilerObjectSectionKind.Text)
          (compiler-object-coff-instr-label-offset-from instrs label 0)]
        [_ (compiler-object-coff-data-label-offset-from data label 0)])]))

(define (compiler-object-coff-relocation-sites-known?
  [image : cobj.CompilerObjectImage]
  [relocs : cobj.CompilerObjectRelocationList]) : bool
  (let
    [count : i64
      (cobj.compiler-object-relocation-list-count
        (owned_view.compiler-owned-shared-view relocs))]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (match (cobj.compiler-object-relocation-list-ref
          (owned_view.compiler-owned-shared-view relocs)
          index)
          [(cobj.CompilerObjectRelocation.Relocation section site _ target)
            (if (match section
              [(cobj.CompilerObjectSectionKind.Text)
                (>=
                  (compiler-object-coff-symbol-index
                    (owned_view.compiler-owned-shared-view image)
                    target)
                  0)]
              [_
                (and
                  (>=
                    (compiler-object-coff-section-label-offset
                      (owned_view.compiler-owned-shared-view image)
                      section
                      site)
                    0)
                  (>=
                    (compiler-object-coff-symbol-index
                      (owned_view.compiler-owned-shared-view image)
                      target)
                    0))])
              (set! index (+ index 1))
              (set! ok false))]))
      ok)))

(define (compiler-object-coff-instr-targets-known?
  [image : cobj.CompilerObjectImage]
  [instrs : cobj.CompilerObjectX64InstrList]) : bool
  (let
    [count : i64
      (cobj.compiler-object-instr-list-count
        (owned_view.compiler-owned-shared-view instrs))]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (match (cobj.compiler-object-instr-list-ref
          (owned_view.compiler-owned-shared-view instrs)
          index)
          [(cobj.CompilerObjectX64Instr.Label _) (set! index (+ index 1))]
          [(cobj.CompilerObjectX64Instr.Call target)
            (if (>=
              (compiler-object-coff-symbol-index
                (owned_view.compiler-owned-shared-view image)
                target)
              0)
              (set! index (+ index 1))
              (set! ok false))]
          [(cobj.CompilerObjectX64Instr.TailCall target)
            (if (>=
              (compiler-object-coff-symbol-index
                (owned_view.compiler-owned-shared-view image)
                target)
              0)
              (set! index (+ index 1))
              (set! ok false))]
          [(cobj.CompilerObjectX64Instr.Jump target)
            (if (>=
              (compiler-object-coff-symbol-index
                (owned_view.compiler-owned-shared-view image)
                target)
              0)
              (set! index (+ index 1))
              (set! ok false))]
          [(cobj.CompilerObjectX64Instr.Ja target)
            (if (>=
              (compiler-object-coff-symbol-index
                (owned_view.compiler-owned-shared-view image)
                target)
              0)
              (set! index (+ index 1))
              (set! ok false))]
          [(cobj.CompilerObjectX64Instr.Branch true-target false-target)
            (if (and
              (>=
                (compiler-object-coff-symbol-index
                  (owned_view.compiler-owned-shared-view image)
                  true-target)
                0)
              (>=
                (compiler-object-coff-symbol-index
                  (owned_view.compiler-owned-shared-view image)
                  false-target)
                0))
              (set! index (+ index 1))
              (set! ok false))]
          [(cobj.CompilerObjectX64Instr.LoadRip target)
            (if (>=
              (compiler-object-coff-symbol-index
                (owned_view.compiler-owned-shared-view image)
                target)
              0)
              (set! index (+ index 1))
              (set! ok false))]
          [(cobj.CompilerObjectX64Instr.LoadRipAddress target)
            (if (>=
              (compiler-object-coff-symbol-index
                (owned_view.compiler-owned-shared-view image)
                target)
              0)
              (set! index (+ index 1))
              (set! ok false))]
          [(cobj.CompilerObjectX64Instr.LoadRipAddressR11 target)
            (if (>=
              (compiler-object-coff-symbol-index
                (owned_view.compiler-owned-shared-view image)
                target)
              0)
              (set! index (+ index 1))
              (set! ok false))]
          [(cobj.CompilerObjectX64Instr.StoreRip target)
            (if (>=
              (compiler-object-coff-symbol-index
                (owned_view.compiler-owned-shared-view image)
                target)
              0)
              (set! index (+ index 1))
              (set! ok false))]
          [(cobj.CompilerObjectX64Instr.SubRspImm8 _) (set! index (+ index 1))]
          [(cobj.CompilerObjectX64Instr.MovRcxRip target)
            (if (>=
              (compiler-object-coff-symbol-index
                (owned_view.compiler-owned-shared-view image)
                target)
              0)
              (set! index (+ index 1))
              (set! ok false))]
          [(cobj.CompilerObjectX64Instr.MovRdxRip target)
            (if (>=
              (compiler-object-coff-symbol-index
                (owned_view.compiler-owned-shared-view image)
                target)
              0)
              (set! index (+ index 1))
              (set! ok false))]
          [(cobj.CompilerObjectX64Instr.LoadRipAddressRdx target)
            (if (>=
              (compiler-object-coff-symbol-index
                (owned_view.compiler-owned-shared-view image)
                target)
              0)
              (set! index (+ index 1))
              (set! ok false))]
          [(cobj.CompilerObjectX64Instr.StoreR14Rip target)
            (if (>=
              (compiler-object-coff-symbol-index
                (owned_view.compiler-owned-shared-view image)
                target)
              0)
              (set! index (+ index 1))
              (set! ok false))]
          [(cobj.CompilerObjectX64Instr.StoreR15Rip target)
            (if (>=
              (compiler-object-coff-symbol-index
                (owned_view.compiler-owned-shared-view image)
                target)
              0)
              (set! index (+ index 1))
              (set! ok false))]
          [(cobj.CompilerObjectX64Instr.AddRcxRip target)
            (if (>=
              (compiler-object-coff-symbol-index
                (owned_view.compiler-owned-shared-view image)
                target)
              0)
              (set! index (+ index 1))
              (set! ok false))]
          [(cobj.CompilerObjectX64Instr.MovRcxRax) (set! index (+ index 1))]
          [(cobj.CompilerObjectX64Instr.XorpdRip target)
            (if (>=
              (compiler-object-coff-symbol-index
                (owned_view.compiler-owned-shared-view image)
                target)
              0)
              (set! index (+ index 1))
              (set! ok false))]
          [(cobj.CompilerObjectX64Instr.Bytes _) (set! index (+ index 1))]
          [(cobj.CompilerObjectX64Instr.Raw _) (set! ok false)]))
      ok)))

(define (compiler-object-coff-text-targets-known?
  [image : cobj.CompilerObjectImage]) : bool
  (match (cobj.compiler-object-section-list-find
    (owned_view.compiler-owned-shared-view image.sections)
    (cobj.CompilerObjectSectionKind.Text))
    [(cobj.CompilerObjectSection.Section _ _ instrs)
      (compiler-object-coff-instr-targets-known?
        (owned_view.compiler-owned-shared-view image)
        instrs)]))

(define (compiler-object-coff-text-instr-relocation-count
  [image : cobj.CompilerObjectImage]) : i64
  (match (cobj.compiler-object-section-list-find
    image.sections
    (cobj.CompilerObjectSectionKind.Text))
    [(cobj.CompilerObjectSection.Section _ _ instrs)
      (compiler-object-coff-instrs-relocation-count instrs)]))

(define (compiler-object-coff-text-relocation-count-matches?
  [image : cobj.CompilerObjectImage]) : bool
  (=
    (compiler-object-coff-relocation-count
      (owned_view.compiler-owned-shared-view image.relocations)
      (cobj.CompilerObjectSectionKind.Text))
    (compiler-object-coff-text-instr-relocation-count
      (owned_view.compiler-owned-shared-view image))))

(define (compiler-object-coff-image-supported?
  [image : cobj.CompilerObjectImage]) : bool
  (and
    (compiler-object-coff-sections-supported?
      (owned_view.compiler-owned-shared-view image.sections))
    (compiler-object-coff-relocation-list-supported?
      (owned_view.compiler-owned-shared-view image.relocations))
    (compiler-object-coff-relocation-sites-known?
      (owned_view.compiler-owned-shared-view image)
      (owned_view.compiler-owned-shared-view image.relocations))
    (compiler-object-coff-text-targets-known?
      (owned_view.compiler-owned-shared-view image))
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
    [count : i64
      (cobj.compiler-object-relocation-list-count
        (owned_view.compiler-owned-shared-view relocs))]
    [index : i64 0]
    [total : i64 0]
    (begin
      (while (< index count)
        (begin
          (match (cobj.compiler-object-relocation-list-ref
            (owned_view.compiler-owned-shared-view relocs)
            index)
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
    [_ (compiler-object-coff-relocation-count image.relocations kind)]))

(define (compiler-object-coff-relocation-count-overflows?
  [semantic-count : i64]) : bool
  (>= semantic-count compiler-object-coff-relocation-overflow-threshold))

(define (compiler-object-coff-relocation-physical-count [semantic-count : i64]) : i64
  (if (compiler-object-coff-relocation-count-overflows? semantic-count)
    (+ semantic-count 1)
    semantic-count))

(define (compiler-object-coff-section-relocation-physical-count
  [image : cobj.CompilerObjectImage]
  [kind : cobj.CompilerObjectSectionKind]) : i64
  (compiler-object-coff-relocation-physical-count
    (compiler-object-coff-section-relocation-count image kind)))

(define (compiler-object-coff-section-header-relocation-count
  [image : cobj.CompilerObjectImage]
  [kind : cobj.CompilerObjectSectionKind]) : i64
  (let
    [semantic-count : i64
      (compiler-object-coff-section-relocation-count image kind)]
    (if (compiler-object-coff-relocation-count-overflows? semantic-count)
      compiler-object-coff-relocation-overflow-threshold
      semantic-count)))

(define (compiler-object-coff-section-header-flags
  [image : cobj.CompilerObjectImage]
  [kind : cobj.CompilerObjectSectionKind]) : i64
  (if (compiler-object-coff-relocation-count-overflows?
    (compiler-object-coff-section-relocation-count image kind))
    (bit-or
      (compiler-object-coff-section-flags kind)
      compiler-object-coff-section-lnk-nreloc-ovfl)
    (compiler-object-coff-section-flags kind)))

(define (compiler-object-coff-total-relocation-physical-count
  [image : cobj.CompilerObjectImage]) : i64
  (+
    (compiler-object-coff-section-relocation-physical-count
      (owned_view.compiler-owned-shared-view image)
      (cobj.CompilerObjectSectionKind.Text))
    (+
      (compiler-object-coff-section-relocation-physical-count
        (owned_view.compiler-owned-shared-view image)
        (cobj.CompilerObjectSectionKind.Data))
      (+
        (compiler-object-coff-section-relocation-physical-count
          (owned_view.compiler-owned-shared-view image)
          (cobj.CompilerObjectSectionKind.Rodata))
        (+
          (compiler-object-coff-section-relocation-physical-count
            (owned_view.compiler-owned-shared-view image)
            (cobj.CompilerObjectSectionKind.Bss))
          (+
            (compiler-object-coff-section-relocation-physical-count
              (owned_view.compiler-owned-shared-view image)
              (cobj.CompilerObjectSectionKind.Pdata))
            (+
              (compiler-object-coff-section-relocation-physical-count
                (owned_view.compiler-owned-shared-view image)
                (cobj.CompilerObjectSectionKind.Xdata))
              (compiler-object-coff-section-relocation-physical-count
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
            (owned_view.compiler-owned-shared-view image)
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
            (owned_view.compiler-owned-shared-view image)
            (cobj.CompilerObjectSectionKind.Text))
          (+
            (compiler-object-coff-section-raw-size
              (owned_view.compiler-owned-shared-view image)
              (cobj.CompilerObjectSectionKind.Data))
            (compiler-object-coff-section-raw-size
              image
              (cobj.CompilerObjectSectionKind.Rodata)))))]
    [(cobj.CompilerObjectSectionKind.Xdata)
      (+
        (compiler-object-coff-header-size)
        (+
          (compiler-object-coff-section-raw-size
            (owned_view.compiler-owned-shared-view image)
            (cobj.CompilerObjectSectionKind.Text))
          (+
            (compiler-object-coff-section-raw-size
              (owned_view.compiler-owned-shared-view image)
              (cobj.CompilerObjectSectionKind.Data))
            (+
              (compiler-object-coff-section-raw-size
                (owned_view.compiler-owned-shared-view image)
                (cobj.CompilerObjectSectionKind.Rodata))
              (compiler-object-coff-section-raw-size
                image
                (cobj.CompilerObjectSectionKind.Pdata))))))]
    [(cobj.CompilerObjectSectionKind.Rsrc)
      (+
        (compiler-object-coff-header-size)
        (+
          (compiler-object-coff-section-raw-size
            (owned_view.compiler-owned-shared-view image)
            (cobj.CompilerObjectSectionKind.Text))
          (+
            (compiler-object-coff-section-raw-size
              (owned_view.compiler-owned-shared-view image)
              (cobj.CompilerObjectSectionKind.Data))
            (+
              (compiler-object-coff-section-raw-size
                (owned_view.compiler-owned-shared-view image)
                (cobj.CompilerObjectSectionKind.Rodata))
              (+
                (compiler-object-coff-section-raw-size
                  (owned_view.compiler-owned-shared-view image)
                  (cobj.CompilerObjectSectionKind.Pdata))
                (compiler-object-coff-section-raw-size
                  image
                  (cobj.CompilerObjectSectionKind.Xdata)))))))]))

(define (compiler-object-coff-section-raw-pointer
  [image : cobj.CompilerObjectImage]
  [kind : cobj.CompilerObjectSectionKind]) : i64
  (if (>
    (compiler-object-coff-section-raw-size
      (owned_view.compiler-owned-shared-view image)
      kind)
    0)
    (compiler-object-coff-raw-base-after-section image kind)
    0))

(define (compiler-object-coff-relocation-base
  [image : cobj.CompilerObjectImage]) : i64
  (+
    (compiler-object-coff-header-size)
    (+
      (compiler-object-coff-section-raw-size
        (owned_view.compiler-owned-shared-view image)
        (cobj.CompilerObjectSectionKind.Text))
      (+
        (compiler-object-coff-section-raw-size
          (owned_view.compiler-owned-shared-view image)
          (cobj.CompilerObjectSectionKind.Data))
        (+
          (compiler-object-coff-section-raw-size
            (owned_view.compiler-owned-shared-view image)
            (cobj.CompilerObjectSectionKind.Rodata))
          (+
            (compiler-object-coff-section-raw-size
              (owned_view.compiler-owned-shared-view image)
              (cobj.CompilerObjectSectionKind.Pdata))
            (+
              (compiler-object-coff-section-raw-size
                (owned_view.compiler-owned-shared-view image)
                (cobj.CompilerObjectSectionKind.Xdata))
              (compiler-object-coff-section-raw-size
                image
                (cobj.CompilerObjectSectionKind.Rsrc)))))))))

(define (compiler-object-coff-relocation-pointer
  [image : cobj.CompilerObjectImage]
  [kind : cobj.CompilerObjectSectionKind]) : i64
  (let
    [count : i64
      (compiler-object-coff-section-relocation-count
        (owned_view.compiler-owned-shared-view image)
        kind)]
    (if (= count 0)
      0
      (let
        [text-count : i64
          (compiler-object-coff-section-relocation-physical-count
            (owned_view.compiler-owned-shared-view image)
            (cobj.CompilerObjectSectionKind.Text))]
        [data-count : i64
          (compiler-object-coff-section-relocation-physical-count
            (owned_view.compiler-owned-shared-view image)
            (cobj.CompilerObjectSectionKind.Data))]
        [rodata-count : i64
          (compiler-object-coff-section-relocation-physical-count
            (owned_view.compiler-owned-shared-view image)
            (cobj.CompilerObjectSectionKind.Rodata))]
        [bss-count : i64
          (compiler-object-coff-section-relocation-physical-count
            (owned_view.compiler-owned-shared-view image)
            (cobj.CompilerObjectSectionKind.Bss))]
        [pdata-count : i64
          (compiler-object-coff-section-relocation-physical-count
            (owned_view.compiler-owned-shared-view image)
            (cobj.CompilerObjectSectionKind.Pdata))]
        [xdata-count : i64
          (compiler-object-coff-section-relocation-physical-count
            (owned_view.compiler-owned-shared-view image)
            (cobj.CompilerObjectSectionKind.Xdata))]
        [base : i64
          (compiler-object-coff-relocation-base
            (owned_view.compiler-owned-shared-view image))]
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
    (compiler-object-coff-relocation-base
      (owned_view.compiler-owned-shared-view image))
    (*
      compiler-object-coff-relocation-size
      (compiler-object-coff-total-relocation-physical-count image))))

(define (compiler-object-coff-push-file-header!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : cobj.CompilerObjectImage]) : unit
  (begin
    (compiler-object-coff-push-u16! out compiler-object-coff-machine-amd64)
    (compiler-object-coff-push-u16! out compiler-object-coff-section-count)
    (compiler-object-coff-push-u32! out 0)
    (compiler-object-coff-push-u32!
      out
      (compiler-object-coff-symbol-table-pointer
        (owned_view.compiler-owned-shared-view image)))
    (compiler-object-coff-push-u32!
      out
      (cobj.compiler-object-symbol-list-count image.symbols))
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
      (compiler-object-coff-section-virtual-size
        (owned_view.compiler-owned-shared-view image)
        kind))
    (compiler-object-coff-push-u32! out 0)
    (compiler-object-coff-push-u32!
      out
      (compiler-object-coff-section-raw-size
        (owned_view.compiler-owned-shared-view image)
        kind))
    (compiler-object-coff-push-u32!
      out
      (compiler-object-coff-section-raw-pointer
        (owned_view.compiler-owned-shared-view image)
        kind))
    (compiler-object-coff-push-u32!
      out
      (compiler-object-coff-relocation-pointer
        (owned_view.compiler-owned-shared-view image)
        kind))
    (compiler-object-coff-push-u32! out 0)
    (compiler-object-coff-push-u16!
      out
      (compiler-object-coff-section-header-relocation-count
        (owned_view.compiler-owned-shared-view image)
        kind))
    (compiler-object-coff-push-u16! out 0)
    (compiler-object-coff-push-u32!
      out
      (compiler-object-coff-section-header-flags image kind))))

(define (compiler-object-coff-push-section-headers!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : cobj.CompilerObjectImage]) : unit
  (begin
    (compiler-object-coff-push-section-header!
      out
      (owned_view.compiler-owned-shared-view image)
      (cobj.CompilerObjectSectionKind.Text))
    (compiler-object-coff-push-section-header!
      out
      (owned_view.compiler-owned-shared-view image)
      (cobj.CompilerObjectSectionKind.Data))
    (compiler-object-coff-push-section-header!
      out
      (owned_view.compiler-owned-shared-view image)
      (cobj.CompilerObjectSectionKind.Rodata))
    (compiler-object-coff-push-section-header!
      out
      (owned_view.compiler-owned-shared-view image)
      (cobj.CompilerObjectSectionKind.Bss))
    (compiler-object-coff-push-section-header!
      out
      (owned_view.compiler-owned-shared-view image)
      (cobj.CompilerObjectSectionKind.Pdata))
    (compiler-object-coff-push-section-header!
      out
      (owned_view.compiler-owned-shared-view image)
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
        (compiler-object-coff-push-string-bytes!
          out
          (owned_view.compiler-owned-shared-view bytes))
        (+ offset (compiler-object-coff-string-length bytes)))]
    [(cobj.CompilerObjectDataRecord.String text)
      (begin
        (compiler-object-coff-push-string-bytes!
          out
          (owned_view.compiler-owned-shared-view text))
        (compiler-object-coff-push-u8! out 0)
        (compiler-object-coff-data-record-end-offset
          (cobj.CompilerObjectDataRecord.String text)
          offset))]
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
    [count : i64
      (cobj.compiler-object-data-record-list-count
        (owned_view.compiler-owned-shared-view records))]
    [index : i64 0]
    [cur-offset : i64 offset]
    (begin
      (while (< index count)
        (begin
          (set!
            cur-offset
            (compiler-object-coff-render-data-record!
              out
              (cobj.compiler-object-data-record-list-ref
                (owned_view.compiler-owned-shared-view records)
                index)
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
    [count : i64
      (cobj.compiler-object-instr-list-count
        (owned_view.compiler-owned-shared-view instrs))]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (compiler-object-coff-render-instr!
            out
            (cobj.compiler-object-instr-list-ref
              (owned_view.compiler-owned-shared-view instrs)
              index))
          (set! index (+ index 1))))
      unit)))

(define (compiler-object-coff-render-section-data!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : cobj.CompilerObjectImage]
  [kind : cobj.CompilerObjectSectionKind]) : unit
  (match (cobj.compiler-object-section-list-find image.sections kind)
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
      (owned_view.compiler-owned-shared-view image)
      (cobj.CompilerObjectSectionKind.Text))
    (compiler-object-coff-render-section-data!
      out
      (owned_view.compiler-owned-shared-view image)
      (cobj.CompilerObjectSectionKind.Data))
    (compiler-object-coff-render-section-data!
      out
      (owned_view.compiler-owned-shared-view image)
      (cobj.CompilerObjectSectionKind.Rodata))
    (compiler-object-coff-render-section-data!
      out
      (owned_view.compiler-owned-shared-view image)
      (cobj.CompilerObjectSectionKind.Pdata))
    (compiler-object-coff-render-section-data!
      out
      (owned_view.compiler-owned-shared-view image)
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
      (compiler-object-coff-symbol-index
        (owned_view.compiler-owned-shared-view image)
        target))
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
        (owned_view.compiler-owned-shared-view image)
        (compiler-object-coff-section-label-offset image section site)
        kind
        target)]))

(define (compiler-object-coff-render-relocation-overflow-sentinel!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : cobj.CompilerObjectImage]
  [kind : cobj.CompilerObjectSectionKind]) : unit
  (let
    [semantic-count : i64
      (compiler-object-coff-section-relocation-count image kind)]
    (if (compiler-object-coff-relocation-count-overflows? semantic-count)
      (begin
        ;; COFF stores the physical table-entry count in the sentinel.  The
        ;; sentinel itself has no symbol or relocation type and is not part of
        ;; the compiler's semantic relocation stream.
        (compiler-object-coff-push-u32!
          out
          (compiler-object-coff-relocation-physical-count semantic-count))
        (compiler-object-coff-push-u32! out 0)
        (compiler-object-coff-push-u16! out 0))
      unit)))

(define (compiler-object-coff-render-text-instr-relocations!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : cobj.CompilerObjectImage]
  [instrs : cobj.CompilerObjectX64InstrList]
  [offset : i64]) : unit
  (let
    [count : i64
      (cobj.compiler-object-instr-list-count
        (owned_view.compiler-owned-shared-view instrs))]
    [index : i64 0]
    [cur-offset : i64 offset]
    (begin
      (while (< index count)
        (let
          [instr : cobj.CompilerObjectX64Instr
            (cobj.compiler-object-instr-list-ref
              (owned_view.compiler-owned-shared-view instrs)
              index)]
          (begin
            (match (owned_view.compiler-owned-shared-view instr)
              [(cobj.CompilerObjectX64Instr.Label _) unit]
              [(cobj.CompilerObjectX64Instr.Call target)
                (compiler-object-coff-render-relocation-record!
                  out
                  (owned_view.compiler-owned-shared-view image)
                  (+ cur-offset 1)
                  (cobj.CompilerObjectRelocationKind.Call)
                  target)]
              [(cobj.CompilerObjectX64Instr.TailCall target)
                (compiler-object-coff-render-relocation-record!
                  out
                  (owned_view.compiler-owned-shared-view image)
                  (+ cur-offset 1)
                  (cobj.CompilerObjectRelocationKind.TailCall)
                  target)]
              [(cobj.CompilerObjectX64Instr.Jump target)
                (compiler-object-coff-render-relocation-record!
                  out
                  (owned_view.compiler-owned-shared-view image)
                  (+ cur-offset 1)
                  (cobj.CompilerObjectRelocationKind.Branch)
                  target)]
              [(cobj.CompilerObjectX64Instr.Ja target)
                (compiler-object-coff-render-relocation-record!
                  out
                  (owned_view.compiler-owned-shared-view image)
                  (+ cur-offset 2)
                  (cobj.CompilerObjectRelocationKind.Branch)
                  target)]
              [(cobj.CompilerObjectX64Instr.Branch true-target false-target)
                (begin
                  (compiler-object-coff-render-relocation-record!
                    out
                    (owned_view.compiler-owned-shared-view image)
                    (+ cur-offset 5)
                    (cobj.CompilerObjectRelocationKind.Branch)
                    true-target)
                  (compiler-object-coff-render-relocation-record!
                    out
                    (owned_view.compiler-owned-shared-view image)
                    (+ cur-offset 10)
                    (cobj.CompilerObjectRelocationKind.Branch)
                    false-target))]
              [(cobj.CompilerObjectX64Instr.LoadRip target)
                (compiler-object-coff-render-relocation-record!
                  out
                  (owned_view.compiler-owned-shared-view image)
                  (+ cur-offset 3)
                  (cobj.CompilerObjectRelocationKind.RipValue)
                  target)]
              [(cobj.CompilerObjectX64Instr.LoadRipAddress target)
                (compiler-object-coff-render-relocation-record!
                  out
                  (owned_view.compiler-owned-shared-view image)
                  (+ cur-offset 3)
                  (cobj.CompilerObjectRelocationKind.RipAddress)
                  target)]
              [(cobj.CompilerObjectX64Instr.LoadRipAddressR11 target)
                (compiler-object-coff-render-relocation-record!
                  out
                  (owned_view.compiler-owned-shared-view image)
                  (+ cur-offset 3)
                  (cobj.CompilerObjectRelocationKind.RipAddress)
                  target)]
              [(cobj.CompilerObjectX64Instr.StoreRip target)
                (compiler-object-coff-render-relocation-record!
                  out
                  (owned_view.compiler-owned-shared-view image)
                  (+ cur-offset 3)
                  (cobj.CompilerObjectRelocationKind.RipAddress)
                  target)]
              [(cobj.CompilerObjectX64Instr.SubRspImm8 _) unit]
              [(cobj.CompilerObjectX64Instr.MovRcxRip target)
                (compiler-object-coff-render-relocation-record!
                  out
                  (owned_view.compiler-owned-shared-view image)
                  (+ cur-offset 3)
                  (cobj.CompilerObjectRelocationKind.RipValue)
                  target)]
              [(cobj.CompilerObjectX64Instr.MovRdxRip target)
                (compiler-object-coff-render-relocation-record!
                  out
                  (owned_view.compiler-owned-shared-view image)
                  (+ cur-offset 3)
                  (cobj.CompilerObjectRelocationKind.RipValue)
                  target)]
              [(cobj.CompilerObjectX64Instr.LoadRipAddressRdx target)
                (compiler-object-coff-render-relocation-record!
                  out
                  (owned_view.compiler-owned-shared-view image)
                  (+ cur-offset 3)
                  (cobj.CompilerObjectRelocationKind.RipAddress)
                  target)]
              [(cobj.CompilerObjectX64Instr.StoreR14Rip target)
                (compiler-object-coff-render-relocation-record!
                  out
                  (owned_view.compiler-owned-shared-view image)
                  (+ cur-offset 3)
                  (cobj.CompilerObjectRelocationKind.RipAddress)
                  target)]
              [(cobj.CompilerObjectX64Instr.StoreR15Rip target)
                (compiler-object-coff-render-relocation-record!
                  out
                  (owned_view.compiler-owned-shared-view image)
                  (+ cur-offset 3)
                  (cobj.CompilerObjectRelocationKind.RipAddress)
                  target)]
              [(cobj.CompilerObjectX64Instr.AddRcxRip target)
                (compiler-object-coff-render-relocation-record!
                  out
                  (owned_view.compiler-owned-shared-view image)
                  (+ cur-offset 3)
                  (cobj.CompilerObjectRelocationKind.RipAddress)
                  target)]
              [(cobj.CompilerObjectX64Instr.MovRcxRax) unit]
              [(cobj.CompilerObjectX64Instr.XorpdRip target)
                (compiler-object-coff-render-relocation-record!
                  out
                  (owned_view.compiler-owned-shared-view image)
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
    (owned_view.compiler-owned-shared-view image.sections)
    (cobj.CompilerObjectSectionKind.Text))
    [(cobj.CompilerObjectSection.Section _ _ instrs)
      (compiler-object-coff-render-text-instr-relocations!
        out
        (owned_view.compiler-owned-shared-view image)
        instrs
        0)]))

(define (compiler-object-coff-render-relocations-for-section!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : cobj.CompilerObjectImage]
  [relocs : cobj.CompilerObjectRelocationList]
  [kind : cobj.CompilerObjectSectionKind]) : unit
  (let
    [count : i64
      (cobj.compiler-object-relocation-list-count
        (owned_view.compiler-owned-shared-view relocs))]
    [index : i64 0]
    (begin
      (compiler-object-coff-render-relocation-overflow-sentinel!
        out
        (owned_view.compiler-owned-shared-view image)
        kind)
      (while (< index count)
        (let
          [reloc : cobj.CompilerObjectRelocation
            (cobj.compiler-object-relocation-list-ref
              (owned_view.compiler-owned-shared-view relocs)
              index)]
          (begin
            (match (owned_view.compiler-owned-shared-view reloc)
              [(cobj.CompilerObjectRelocation.Relocation section _ _ _)
                (if (cobj.compiler-object-section-kind-eq? section kind)
                  (compiler-object-coff-render-relocation!
                    out
                    (owned_view.compiler-owned-shared-view image)
                    reloc)
                  unit)])
            (set! index (+ index 1)))))
      unit)))

(define (compiler-object-coff-render-relocations!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : cobj.CompilerObjectImage]) : unit
  (begin
    (compiler-object-coff-render-relocation-overflow-sentinel!
      out
      (owned_view.compiler-owned-shared-view image)
      (cobj.CompilerObjectSectionKind.Text))
    (compiler-object-coff-render-text-relocations!
      out
      (owned_view.compiler-owned-shared-view image))
    (compiler-object-coff-render-relocations-for-section!
      out
      (owned_view.compiler-owned-shared-view image)
      (owned_view.compiler-owned-shared-view image.relocations)
      (cobj.CompilerObjectSectionKind.Data))
    (compiler-object-coff-render-relocations-for-section!
      out
      (owned_view.compiler-owned-shared-view image)
      (owned_view.compiler-owned-shared-view image.relocations)
      (cobj.CompilerObjectSectionKind.Rodata))
    (compiler-object-coff-render-relocations-for-section!
      out
      (owned_view.compiler-owned-shared-view image)
      (owned_view.compiler-owned-shared-view image.relocations)
      (cobj.CompilerObjectSectionKind.Bss))
    (compiler-object-coff-render-relocations-for-section!
      out
      (owned_view.compiler-owned-shared-view image)
      (owned_view.compiler-owned-shared-view image.relocations)
      (cobj.CompilerObjectSectionKind.Pdata))
    (compiler-object-coff-render-relocations-for-section!
      out
      (owned_view.compiler-owned-shared-view image)
      (owned_view.compiler-owned-shared-view image.relocations)
      (cobj.CompilerObjectSectionKind.Xdata))
    (compiler-object-coff-render-relocations-for-section!
      out
      (owned_view.compiler-owned-shared-view image)
      (owned_view.compiler-owned-shared-view image.relocations)
      (cobj.CompilerObjectSectionKind.Rsrc))))

(define (compiler-object-coff-symbol-name-long? [name : String]) : bool
  (> (compiler-object-coff-string-length name) 8))

(define (compiler-object-coff-symbol-string-offset-from
  [symbols : cobj.CompilerObjectSymbolList]
  [name : String]
  [offset : i64]) : i64
  (let
    [count : i64
      (cobj.compiler-object-symbol-list-count
        (owned_view.compiler-owned-shared-view symbols))]
    [index : i64 0]
    [cur-offset : i64 offset]
    [result : i64 0]
    [done : bool false]
    (begin
      (while (and (not done) (< index count))
        (match (cobj.compiler-object-symbol-list-ref
          (owned_view.compiler-owned-shared-view symbols)
          index)
          [(cobj.CompilerObjectSymbol.Symbol found _ _ _)
            (if (compiler-object-coff-symbol-name-long?
              (owned_view.compiler-owned-shared-view found))
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
  (compiler-object-coff-symbol-string-offset-from image.symbols name 4))

(define (compiler-object-coff-push-symbol-name!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : cobj.CompilerObjectImage]
  [name : String]) : unit
  (if (compiler-object-coff-symbol-name-long?
    (owned_view.compiler-owned-shared-view name))
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
        (compiler-object-coff-push-symbol-name!
          out
          (owned_view.compiler-owned-shared-view image)
          (owned_view.compiler-owned-shared-view name))
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
    [count : i64
      (cobj.compiler-object-symbol-list-count
        (owned_view.compiler-owned-shared-view symbols))]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (compiler-object-coff-render-symbol!
            out
            (owned_view.compiler-owned-shared-view image)
            (cobj.compiler-object-symbol-list-ref
              (owned_view.compiler-owned-shared-view symbols)
              index))
          (set! index (+ index 1))))
      unit)))

(define (compiler-object-coff-string-table-size-from
  [symbols : cobj.CompilerObjectSymbolList]
  [size : i64]) : i64
  (let
    [count : i64
      (cobj.compiler-object-symbol-list-count
        (owned_view.compiler-owned-shared-view symbols))]
    [index : i64 0]
    [total : i64 size]
    (begin
      (while (< index count)
        (begin
          (match (cobj.compiler-object-symbol-list-ref
            (owned_view.compiler-owned-shared-view symbols)
            index)
            [(cobj.CompilerObjectSymbol.Symbol name _ _ _)
              (if (compiler-object-coff-symbol-name-long?
                (owned_view.compiler-owned-shared-view name))
                (set!
                  total
                  (+ total (+ (compiler-object-coff-string-length name) 1)))
                unit)])
          (set! index (+ index 1))))
      total)))

(define (compiler-object-coff-string-table-size
  [symbols : cobj.CompilerObjectSymbolList]) : i64
  (compiler-object-coff-string-table-size-from symbols 4))

(define (compiler-object-coff-layout-accumulator-ok?
  [acc : CompilerObjectCoffLayoutAccumulator]) : bool
  (= (compiler-object-coff-string-length acc.error) 0))

(define (compiler-object-coff-layout-section-error
  [kind : cobj.CompilerObjectSectionKind]
  [semantic-count : i64]
  [detail : String]) : String
  (str_cat.str-cat
    "coff: windows-x86_64 section "
    (compiler-object-coff-section-name kind)
    " relocation count "
    (string.int->string semantic-count)
    " "
    detail))

(define (compiler-object-coff-layout-section-size-error
  [kind : cobj.CompilerObjectSectionKind]
  [size : i64]
  [detail : String]) : String
  (str_cat.str-cat
    "coff: windows-x86_64 section "
    (compiler-object-coff-section-name kind)
    " size "
    (string.int->string size)
    " "
    detail))

(define (compiler-object-coff-check-section-data-layout
  [acc : CompilerObjectCoffLayoutAccumulator]
  [image : cobj.CompilerObjectImage]
  [kind : cobj.CompilerObjectSectionKind]
  [max-output-size : i64]) : CompilerObjectCoffLayoutAccumulator
  (if (not
    (compiler-object-coff-layout-accumulator-ok?
      (owned_view.compiler-owned-shared-view acc)))
    acc
    (let
      [virtual-size : i64
        (compiler-object-coff-section-virtual-size
          (owned_view.compiler-owned-shared-view image)
          kind)]
      [raw-size : i64 (compiler-object-coff-section-raw-size image kind)]
      (cond
        [(or (< virtual-size 0) (> virtual-size compiler-object-coff-max-u32))
          (CompilerObjectCoffLayoutAccumulator
            acc.offset
            (compiler-object-coff-layout-section-size-error
              kind
              virtual-size
              "is not representable in the COFF section header"))]
        [(or (< raw-size 0) (> raw-size compiler-object-coff-max-u32))
          (CompilerObjectCoffLayoutAccumulator
            acc.offset
            (compiler-object-coff-layout-section-size-error
              kind
              raw-size
              "raw data is not representable in the COFF section header"))]
        [(or
            (> acc.offset max-output-size)
            (> raw-size (- max-output-size acc.offset)))
          (CompilerObjectCoffLayoutAccumulator
            acc.offset
            (compiler-object-coff-layout-section-size-error
              kind
              raw-size
              "raw data exceeds the configured object-size limit"))]
        [else (CompilerObjectCoffLayoutAccumulator (+ acc.offset raw-size) "")]))))

;; This helper is intentionally count-based so boundary and malformed states
;; can be tested without first allocating an equally large relocation list.
(define (compiler-object-coff-check-relocation-count-layout
  [acc : CompilerObjectCoffLayoutAccumulator]
  [kind : cobj.CompilerObjectSectionKind]
  [semantic-count : i64]
  [max-output-size : i64]) : CompilerObjectCoffLayoutAccumulator
  (if (not
    (compiler-object-coff-layout-accumulator-ok?
      (owned_view.compiler-owned-shared-view acc)))
    acc
    (cond
      [(< semantic-count 0)
        (CompilerObjectCoffLayoutAccumulator
          acc.offset
          (compiler-object-coff-layout-section-error
            kind
            semantic-count
            "is negative"))]
      [(and
          (compiler-object-coff-relocation-count-overflows? semantic-count)
          (> semantic-count (- compiler-object-coff-max-u32 1)))
        (CompilerObjectCoffLayoutAccumulator
          acc.offset
          (compiler-object-coff-layout-section-error
            kind
            semantic-count
            "cannot encode semantic_count + 1 in the 32-bit overflow sentinel"))]
      [else
        (let
          [physical-count : i64
            (compiler-object-coff-relocation-physical-count semantic-count)]
          (if (or
            (>
              physical-count
              (/ max-output-size compiler-object-coff-relocation-size))
            (> acc.offset max-output-size)
            (>
              (* physical-count compiler-object-coff-relocation-size)
              (- max-output-size acc.offset)))
            (CompilerObjectCoffLayoutAccumulator
              acc.offset
              (compiler-object-coff-layout-section-error
                kind
                semantic-count
                "physical relocation table exceeds the configured object-size limit"))
            (CompilerObjectCoffLayoutAccumulator
              (+
                acc.offset
                (* physical-count compiler-object-coff-relocation-size))
              "")))])))

(define (compiler-object-coff-check-section-relocation-layout
  [acc : CompilerObjectCoffLayoutAccumulator]
  [image : cobj.CompilerObjectImage]
  [kind : cobj.CompilerObjectSectionKind]
  [max-output-size : i64]) : CompilerObjectCoffLayoutAccumulator
  (compiler-object-coff-check-relocation-count-layout
    acc
    kind
    (compiler-object-coff-section-relocation-count image kind)
    max-output-size))

(define (compiler-object-coff-check-symbol-table-layout
  [acc : CompilerObjectCoffLayoutAccumulator]
  [symbols : cobj.CompilerObjectSymbolList]
  [max-output-size : i64]) : CompilerObjectCoffLayoutAccumulator
  (if (not
    (compiler-object-coff-layout-accumulator-ok?
      (owned_view.compiler-owned-shared-view acc)))
    acc
    (let
      [count : i64
        (cobj.compiler-object-symbol-list-count
          (owned_view.compiler-owned-shared-view symbols))]
      (if (or
        (< count 0)
        (> count compiler-object-coff-max-u32)
        (> count (/ max-output-size 18))
        (> acc.offset max-output-size)
        (> (* count 18) (- max-output-size acc.offset)))
        (CompilerObjectCoffLayoutAccumulator
          acc.offset
          (str_cat.str-cat
            "coff: windows-x86_64 symbol count "
            (string.int->string count)
            " exceeds the COFF or configured object-size limit"))
        (CompilerObjectCoffLayoutAccumulator (+ acc.offset (* count 18)) "")))))

(define (compiler-object-coff-check-string-table-layout
  [acc : CompilerObjectCoffLayoutAccumulator]
  [symbols : cobj.CompilerObjectSymbolList]
  [max-output-size : i64]) : CompilerObjectCoffLayoutAccumulator
  (if (not
    (compiler-object-coff-layout-accumulator-ok?
      (owned_view.compiler-owned-shared-view acc)))
    acc
    (let
      [count : i64
        (cobj.compiler-object-symbol-list-count
          (owned_view.compiler-owned-shared-view symbols))]
      [index : i64 0]
      [table-size : i64 4]
      [error : String ""]
      (begin
        (while (and
          (=
            (compiler-object-coff-string-length
              (owned_view.compiler-owned-shared-view error))
            0)
          (< index count))
          (begin
            (match (cobj.compiler-object-symbol-list-ref
              (owned_view.compiler-owned-shared-view symbols)
              index)
              [(cobj.CompilerObjectSymbol.Symbol name _ _ _)
                (if (compiler-object-coff-symbol-name-long?
                  (owned_view.compiler-owned-shared-view name))
                  (let
                    [name-size : i64
                      (compiler-object-coff-string-length
                        (owned_view.compiler-owned-shared-view name))]
                    (if (or
                      (> name-size (- compiler-object-coff-max-u32 1))
                      (>
                        (+ name-size 1)
                        (- compiler-object-coff-max-u32 table-size)))
                      (set!
                        error
                        (str_cat.str-cat
                          "coff: windows-x86_64 symbol "
                          name
                          " makes the string table exceed its 32-bit size"))
                      (set! table-size (+ table-size (+ name-size 1)))))
                  unit)])
            (set! index (+ index 1))))
        (if (>
          (compiler-object-coff-string-length
            (owned_view.compiler-owned-shared-view error))
          0)
          (CompilerObjectCoffLayoutAccumulator acc.offset error)
          (if (or
            (> acc.offset max-output-size)
            (> table-size (- max-output-size acc.offset)))
            (CompilerObjectCoffLayoutAccumulator
              acc.offset
              (str_cat.str-cat
                "coff: windows-x86_64 string table size "
                (string.int->string table-size)
                " exceeds the configured object-size limit"))
            (CompilerObjectCoffLayoutAccumulator (+ acc.offset table-size) "")))))))

(define (compiler-object-coff-layout-with-limit
  [image : cobj.CompilerObjectImage]
  [max-output-size : i64]) : ResultCompilerObjectCoffLayout
  (if (or
    (< max-output-size (compiler-object-coff-header-size))
    (> max-output-size compiler-object-coff-max-u32))
    (ResultCompilerObjectCoffLayout.Err
      (str_cat.str-cat
        "coff: windows-x86_64 configured object-size limit "
        (string.int->string max-output-size)
        " is invalid"))
    (let
      [data0 : CompilerObjectCoffLayoutAccumulator
        (CompilerObjectCoffLayoutAccumulator
          (compiler-object-coff-header-size)
          "")]
      [data1 : CompilerObjectCoffLayoutAccumulator
        (compiler-object-coff-check-section-data-layout
          data0
          (owned_view.compiler-owned-shared-view image)
          (cobj.CompilerObjectSectionKind.Text)
          max-output-size)]
      [data2 : CompilerObjectCoffLayoutAccumulator
        (compiler-object-coff-check-section-data-layout
          data1
          (owned_view.compiler-owned-shared-view image)
          (cobj.CompilerObjectSectionKind.Data)
          max-output-size)]
      [data3 : CompilerObjectCoffLayoutAccumulator
        (compiler-object-coff-check-section-data-layout
          data2
          (owned_view.compiler-owned-shared-view image)
          (cobj.CompilerObjectSectionKind.Rodata)
          max-output-size)]
      [data4 : CompilerObjectCoffLayoutAccumulator
        (compiler-object-coff-check-section-data-layout
          data3
          (owned_view.compiler-owned-shared-view image)
          (cobj.CompilerObjectSectionKind.Bss)
          max-output-size)]
      [data5 : CompilerObjectCoffLayoutAccumulator
        (compiler-object-coff-check-section-data-layout
          data4
          (owned_view.compiler-owned-shared-view image)
          (cobj.CompilerObjectSectionKind.Pdata)
          max-output-size)]
      [data6 : CompilerObjectCoffLayoutAccumulator
        (compiler-object-coff-check-section-data-layout
          data5
          (owned_view.compiler-owned-shared-view image)
          (cobj.CompilerObjectSectionKind.Xdata)
          max-output-size)]
      [data7 : CompilerObjectCoffLayoutAccumulator
        (compiler-object-coff-check-section-data-layout
          data6
          (owned_view.compiler-owned-shared-view image)
          (cobj.CompilerObjectSectionKind.Rsrc)
          max-output-size)]
      [reloc1 : CompilerObjectCoffLayoutAccumulator
        (compiler-object-coff-check-section-relocation-layout
          data7
          (owned_view.compiler-owned-shared-view image)
          (cobj.CompilerObjectSectionKind.Text)
          max-output-size)]
      [reloc2 : CompilerObjectCoffLayoutAccumulator
        (compiler-object-coff-check-section-relocation-layout
          reloc1
          (owned_view.compiler-owned-shared-view image)
          (cobj.CompilerObjectSectionKind.Data)
          max-output-size)]
      [reloc3 : CompilerObjectCoffLayoutAccumulator
        (compiler-object-coff-check-section-relocation-layout
          reloc2
          (owned_view.compiler-owned-shared-view image)
          (cobj.CompilerObjectSectionKind.Rodata)
          max-output-size)]
      [reloc4 : CompilerObjectCoffLayoutAccumulator
        (compiler-object-coff-check-section-relocation-layout
          reloc3
          (owned_view.compiler-owned-shared-view image)
          (cobj.CompilerObjectSectionKind.Bss)
          max-output-size)]
      [reloc5 : CompilerObjectCoffLayoutAccumulator
        (compiler-object-coff-check-section-relocation-layout
          reloc4
          (owned_view.compiler-owned-shared-view image)
          (cobj.CompilerObjectSectionKind.Pdata)
          max-output-size)]
      [reloc6 : CompilerObjectCoffLayoutAccumulator
        (compiler-object-coff-check-section-relocation-layout
          reloc5
          (owned_view.compiler-owned-shared-view image)
          (cobj.CompilerObjectSectionKind.Xdata)
          max-output-size)]
      [reloc7 : CompilerObjectCoffLayoutAccumulator
        (compiler-object-coff-check-section-relocation-layout
          reloc6
          (owned_view.compiler-owned-shared-view image)
          (cobj.CompilerObjectSectionKind.Rsrc)
          max-output-size)]
      [symbols : CompilerObjectCoffLayoutAccumulator
        (compiler-object-coff-check-symbol-table-layout
          reloc7
          (owned_view.compiler-owned-shared-view image.symbols)
          max-output-size)]
      [strings : CompilerObjectCoffLayoutAccumulator
        (compiler-object-coff-check-string-table-layout
          symbols
          (owned_view.compiler-owned-shared-view image.symbols)
          max-output-size)]
      (if (compiler-object-coff-layout-accumulator-ok?
        (owned_view.compiler-owned-shared-view strings))
        (ResultCompilerObjectCoffLayout.Ok strings.offset)
        (ResultCompilerObjectCoffLayout.Err strings.error)))))

(define (compiler-object-coff-render-string-table-symbols!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [symbols : cobj.CompilerObjectSymbolList]) : unit
  (let
    [count : i64
      (cobj.compiler-object-symbol-list-count
        (owned_view.compiler-owned-shared-view symbols))]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (match (cobj.compiler-object-symbol-list-ref
            (owned_view.compiler-owned-shared-view symbols)
            index)
            [(cobj.CompilerObjectSymbol.Symbol name _ _ _)
              (if (compiler-object-coff-symbol-name-long?
                (owned_view.compiler-owned-shared-view name))
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
      (compiler-object-coff-string-table-size
        (owned_view.compiler-owned-shared-view image.symbols)))
    (compiler-object-coff-render-string-table-symbols! out image.symbols)))

(define (compiler-object-coff-bytes-string
  [out : (& out byte_buf_core.ByteBufBuilder)]) : String
  (byte_buf_core.byte-buf-builder-finish-string out))

(define (compiler-object-coff-render [image : cobj.CompilerObjectImage]) : ResultCompilerObjectCoff
  (if (compiler-object-coff-image-supported?
    (owned_view.compiler-owned-shared-view image))
    (match (compiler-object-coff-layout-with-limit
      (owned_view.compiler-owned-shared-view image)
      compiler-object-coff-max-output-size)
      [(ResultCompilerObjectCoffLayout.Ok output-size)
        (let
          [out : byte_buf_core.ByteBufBuilder
            (byte_buf_core.byte-buf-builder-with-capacity output-size)]
          (begin
            (compiler-object-coff-push-file-header!
              (&mut out)
              (owned_view.compiler-owned-shared-view image))
            (compiler-object-coff-push-section-headers!
              (&mut out)
              (owned_view.compiler-owned-shared-view image))
            (compiler-object-coff-render-sections!
              (&mut out)
              (owned_view.compiler-owned-shared-view image))
            (compiler-object-coff-render-relocations!
              (&mut out)
              (owned_view.compiler-owned-shared-view image))
            (compiler-object-coff-render-symbols!
              (&mut out)
              (owned_view.compiler-owned-shared-view image)
              (owned_view.compiler-owned-shared-view image.symbols))
            (compiler-object-coff-render-string-table!
              (&mut out)
              (owned_view.compiler-owned-shared-view image))
            (ResultCompilerObjectCoff.Ok
              (compiler-object-coff-bytes-string (& out)))))]
      [(ResultCompilerObjectCoffLayout.Err message)
        (ResultCompilerObjectCoff.Err message)])
    (ResultCompilerObjectCoff.Err
      "coff: object image contains unsupported text, f64, or relocation records")))

(define (compiler-object-coff-u16-at [text : String] [offset : i64]) : i64
  (+
    (cast
      (compiler-object-coff-string-ref
        (owned_view.compiler-owned-shared-view text)
        offset)
      : i64)
    (shl (cast (compiler-object-coff-string-ref text (+ offset 1)) : i64) 8)))

(define (compiler-object-coff-u32-at [text : String] [offset : i64]) : i64
  (+
    (compiler-object-coff-u16-at
      (owned_view.compiler-owned-shared-view text)
      offset)
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
    [text-len : i64
      (compiler-object-coff-string-length
        (owned_view.compiler-owned-shared-view text))]
    [needle-len : i64
      (compiler-object-coff-string-length
        (owned_view.compiler-owned-shared-view needle))]
    (if (> (+ start needle-len) text-len)
      false
      (let
        [i : i64 0]
        [ok : bool true]
        (begin
          (while ok
            (if (< i needle-len)
              (if (=
                (compiler-object-coff-string-ref
                  (owned_view.compiler-owned-shared-view text)
                  (+ start i))
                (compiler-object-coff-string-ref
                  (owned_view.compiler-owned-shared-view needle)
                  i))
                (set! i (+ i 1))
                (set! ok false))
              (set! ok false)))
          (= i needle-len))))))

(define (compiler-object-coff-contains? [text : String] [needle : String]) : bool
  (let
    [i : i64 0]
    [n : i64
      (compiler-object-coff-string-length
        (owned_view.compiler-owned-shared-view text))]
    [found : bool false]
    (begin
      (while (and (not found) (< i n))
        (begin
          (if (compiler-object-coff-prefix-at?
            (owned_view.compiler-owned-shared-view text)
            (owned_view.compiler-owned-shared-view needle)
            i)
            (set! found true)
            unit)
          (set! i (+ i 1))))
      found)))

(cfg
  test
  (define (compiler-object-coff-interior-nul-string) : String
    (let
      [out : byte_buf_core.ByteBufBuilder
        (byte_buf_core.byte-buf-builder-with-capacity 3)]
      (begin
        (byte_buf_core.byte-buf-builder-push (&mut out) 0x61)
        (byte_buf_core.byte-buf-builder-push (&mut out) 0)
        (byte_buf_core.byte-buf-builder-push (&mut out) 0x62)
        (byte_buf_core.byte-buf-builder-finish-string (& out))))))

(cfg
  test
  (define (compiler-object-coff-string-record-layout-ok?) : bool
    (let
      [out : byte_buf_core.ByteBufBuilder
        (byte_buf_core.byte-buf-builder-with-capacity 8)]
      [after-empty : i64
        (compiler-object-coff-render-data-record!
          (&mut out)
          (cobj.CompilerObjectDataRecord.String "")
          0)]
      [after-interior-nul : i64
        (compiler-object-coff-render-data-record!
          (&mut out)
          (cobj.CompilerObjectDataRecord.String
            (compiler-object-coff-interior-nul-string))
          after-empty)]
      [bytes : String (byte_buf_core.byte-buf-builder-finish-string (& out))]
      (and
        (= after-empty 1)
        (= after-interior-nul 5)
        (=
          (compiler-object-coff-string-length
            (owned_view.compiler-owned-shared-view bytes))
          5)
        (=
          (compiler-object-coff-u8-at
            (owned_view.compiler-owned-shared-view bytes)
            0)
          0)
        (=
          (compiler-object-coff-u8-at
            (owned_view.compiler-owned-shared-view bytes)
            1)
          0x61)
        (=
          (compiler-object-coff-u8-at
            (owned_view.compiler-owned-shared-view bytes)
            2)
          0)
        (=
          (compiler-object-coff-u8-at
            (owned_view.compiler-owned-shared-view bytes)
            3)
          0x62)
        (=
          (compiler-object-coff-u8-at
            (owned_view.compiler-owned-shared-view bytes)
            4)
          0)))))

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
            (owned_view.compiler-owned-shared-view empty-instrs)))]
      [sections3 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections2
          (cobj.CompilerObjectSection.Section
            (cobj.CompilerObjectSectionKind.Rodata)
            (cobj.compiler-object-data-record-builder-finish rodata2)
            (owned_view.compiler-owned-shared-view empty-instrs)))]
      [sections4 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections3
          (cobj.CompilerObjectSection.Section
            (cobj.CompilerObjectSectionKind.Bss)
            (cobj.compiler-object-data-record-builder-finish bss2)
            (owned_view.compiler-owned-shared-view empty-instrs)))]
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
            (compiler-object-coff-u16-at
              (owned_view.compiler-owned-shared-view obj)
              0)
            compiler-object-coff-machine-amd64)
          (=
            (compiler-object-coff-u16-at
              (owned_view.compiler-owned-shared-view obj)
              2)
            compiler-object-coff-section-count)
          (>
            (compiler-object-coff-u32-at
              (owned_view.compiler-owned-shared-view obj)
              8)
            0)
          (=
            (compiler-object-coff-u32-at
              (owned_view.compiler-owned-shared-view obj)
              12)
            5)
          (=
            (compiler-object-coff-u32-at
              (owned_view.compiler-owned-shared-view obj)
              (+ 60 16))
            16)
          (=
            (compiler-object-coff-u16-at
              (owned_view.compiler-owned-shared-view obj)
              (+ 60 32))
            1)
          (compiler-object-coff-contains?
            (owned_view.compiler-owned-shared-view obj)
            ".rdata")
          (compiler-object-coff-contains?
            (owned_view.compiler-owned-shared-view obj)
            "foreign_exact")
          (compiler-object-coff-contains?
            (owned_view.compiler-owned-shared-view obj)
            "long_rodata_label_name"))]
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
            (owned_view.compiler-owned-shared-view empty-data)
            (compiler-object-coff-text-smoke-instrs)))]
      [sections2 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections1
          (cobj.CompilerObjectSection.Section
            (cobj.CompilerObjectSectionKind.Data)
            (cobj.compiler-object-data-record-builder-finish data4)
            (owned_view.compiler-owned-shared-view empty-instrs)))]
      [sections3 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections2
          (cobj.CompilerObjectSection.Section
            (cobj.CompilerObjectSectionKind.Rodata)
            (owned_view.compiler-owned-shared-view empty-data)
            (owned_view.compiler-owned-shared-view empty-instrs)))]
      [sections4 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections3
          (cobj.CompilerObjectSection.Section
            (cobj.CompilerObjectSectionKind.Bss)
            (owned_view.compiler-owned-shared-view empty-data)
            (owned_view.compiler-owned-shared-view empty-instrs)))]
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
      (=
        (compiler-object-coff-u32-at
          (owned_view.compiler-owned-shared-view obj)
          entry)
        offset)
      (=
        (compiler-object-coff-u32-at
          (owned_view.compiler-owned-shared-view obj)
          (+ entry 4))
        symbol-index)
      (=
        (compiler-object-coff-u16-at
          (owned_view.compiler-owned-shared-view obj)
          (+ entry 8))
        reloc-type))))

(cfg
  test
  (define (compiler-object-coff-text-smoke-bytes-ok?
    [obj : String]
    [text-ptr : i64]) : bool
    (and
      (=
        (compiler-object-coff-u8-at
          (owned_view.compiler-owned-shared-view obj)
          text-ptr)
        0x48)
      (=
        (compiler-object-coff-u8-at
          (owned_view.compiler-owned-shared-view obj)
          (+ text-ptr 1))
        0x8b)
      (=
        (compiler-object-coff-u8-at
          (owned_view.compiler-owned-shared-view obj)
          (+ text-ptr 2))
        0x05)
      (=
        (compiler-object-coff-u8-at
          (owned_view.compiler-owned-shared-view obj)
          (+ text-ptr 7))
        0x48)
      (=
        (compiler-object-coff-u8-at
          (owned_view.compiler-owned-shared-view obj)
          (+ text-ptr 8))
        0x8d)
      (=
        (compiler-object-coff-u8-at
          (owned_view.compiler-owned-shared-view obj)
          (+ text-ptr 14))
        0x48)
      (=
        (compiler-object-coff-u8-at
          (owned_view.compiler-owned-shared-view obj)
          (+ text-ptr 15))
        0x89)
      (=
        (compiler-object-coff-u8-at
          (owned_view.compiler-owned-shared-view obj)
          (+ text-ptr 21))
        0xe8)
      (=
        (compiler-object-coff-u8-at
          (owned_view.compiler-owned-shared-view obj)
          (+ text-ptr 26))
        0xe9)
      (=
        (compiler-object-coff-u8-at
          (owned_view.compiler-owned-shared-view obj)
          (+ text-ptr 31))
        0xe9)
      (=
        (compiler-object-coff-u8-at
          (owned_view.compiler-owned-shared-view obj)
          (+ text-ptr 36))
        0x48)
      (=
        (compiler-object-coff-u8-at
          (owned_view.compiler-owned-shared-view obj)
          (+ text-ptr 37))
        0x85)
      (=
        (compiler-object-coff-u8-at
          (owned_view.compiler-owned-shared-view obj)
          (+ text-ptr 38))
        0xc0)
      (=
        (compiler-object-coff-u8-at
          (owned_view.compiler-owned-shared-view obj)
          (+ text-ptr 39))
        0x0f)
      (=
        (compiler-object-coff-u8-at
          (owned_view.compiler-owned-shared-view obj)
          (+ text-ptr 40))
        0x85)
      (=
        (compiler-object-coff-u8-at
          (owned_view.compiler-owned-shared-view obj)
          (+ text-ptr 45))
        0xe9))))

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
          (owned_view.compiler-owned-shared-view obj)
          reloc-ptr
          0
          3
          (compiler-object-coff-symbol-index
            (owned_view.compiler-owned-shared-view image)
            "_tl_answer")
          rel32)
        (compiler-object-coff-reloc-entry-ok?
          (owned_view.compiler-owned-shared-view obj)
          reloc-ptr
          1
          10
          (compiler-object-coff-symbol-index
            (owned_view.compiler-owned-shared-view image)
            "_tl_slot")
          rel32)
        (compiler-object-coff-reloc-entry-ok?
          (owned_view.compiler-owned-shared-view obj)
          reloc-ptr
          2
          17
          (compiler-object-coff-symbol-index
            (owned_view.compiler-owned-shared-view image)
            "_tl_slot")
          rel32)
        (compiler-object-coff-reloc-entry-ok?
          (owned_view.compiler-owned-shared-view obj)
          reloc-ptr
          3
          22
          (compiler-object-coff-symbol-index
            (owned_view.compiler-owned-shared-view image)
            "foreign_exact")
          rel32)
        (compiler-object-coff-reloc-entry-ok?
          (owned_view.compiler-owned-shared-view obj)
          reloc-ptr
          4
          27
          (compiler-object-coff-symbol-index
            (owned_view.compiler-owned-shared-view image)
            "_tl_done")
          rel32)
        (compiler-object-coff-reloc-entry-ok?
          (owned_view.compiler-owned-shared-view obj)
          reloc-ptr
          5
          32
          (compiler-object-coff-symbol-index
            (owned_view.compiler-owned-shared-view image)
            "_tl_done")
          rel32)
        (compiler-object-coff-reloc-entry-ok?
          (owned_view.compiler-owned-shared-view obj)
          reloc-ptr
          6
          41
          (compiler-object-coff-symbol-index
            (owned_view.compiler-owned-shared-view image)
            "_tl_true")
          rel32)
        (compiler-object-coff-reloc-entry-ok?
          (owned_view.compiler-owned-shared-view obj)
          reloc-ptr
          7
          46
          (compiler-object-coff-symbol-index
            (owned_view.compiler-owned-shared-view image)
            "_tl_false")
          rel32)))))

(cfg
  test
  (define (compiler-object-coff-text-smoke-ok?) : bool
    (let
      [image : cobj.CompilerObjectImage (compiler-object-coff-text-smoke-image)]
      (match (compiler-object-coff-render
        (owned_view.compiler-owned-shared-view image))
        [(ResultCompilerObjectCoff.Ok obj)
          (let
            [text-header : i64
              (compiler-object-coff-section-header-offset
                (cobj.CompilerObjectSectionKind.Text))]
            [text-size : i64
              (compiler-object-coff-u32-at
                (owned_view.compiler-owned-shared-view obj)
                (+ text-header 16))]
            [text-ptr : i64
              (compiler-object-coff-u32-at
                (owned_view.compiler-owned-shared-view obj)
                (+ text-header 20))]
            [reloc-ptr : i64
              (compiler-object-coff-u32-at
                (owned_view.compiler-owned-shared-view obj)
                (+ text-header 24))]
            [reloc-count : i64
              (compiler-object-coff-u16-at
                (owned_view.compiler-owned-shared-view obj)
                (+ text-header 32))]
            (and
              (= text-size 50)
              (= text-ptr (compiler-object-coff-header-size))
              (= reloc-count 8)
              (compiler-object-coff-text-smoke-bytes-ok?
                (owned_view.compiler-owned-shared-view obj)
                text-ptr)
              (compiler-object-coff-text-smoke-relocs-ok?
                (owned_view.compiler-owned-shared-view image)
                (owned_view.compiler-owned-shared-view obj)
                reloc-ptr)))]
        [(ResultCompilerObjectCoff.Err _) false]))))

(cfg
  test
  (define (compiler-object-coff-boundary-relocations
    [data-count : i64]
    [rodata-count : i64]) : cobj.CompilerObjectRelocationList
    (let
      [builder : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-with-capacity
          (+ data-count rodata-count))]
      [index : i64 0]
      (begin
        (while (< index data-count)
          (begin
            (set!
              builder
              (cobj.compiler-object-relocation-builder-push
                builder
                (cobj.CompilerObjectRelocation.Relocation
                  (cobj.CompilerObjectSectionKind.Data)
                  "_tl_ptr"
                  (cobj.CompilerObjectRelocationKind.Abs64)
                  (if (= index (- data-count 1))
                    "foreign_exact"
                    "_tl_answer"))))
            (set! index (+ index 1))))
        (set! index 0)
        (while (< index rodata-count)
          (begin
            (set!
              builder
              (cobj.compiler-object-relocation-builder-push
                builder
                (cobj.CompilerObjectRelocation.Relocation
                  (cobj.CompilerObjectSectionKind.Rodata)
                  "long_rodata_label_name"
                  (cobj.CompilerObjectRelocationKind.Abs64)
                  (if (= index (- rodata-count 1))
                    "foreign_exact"
                    "_tl_answer"))))
            (set! index (+ index 1))))
        (cobj.compiler-object-relocation-builder-finish builder)))))

(cfg
  test
  (define (compiler-object-coff-boundary-image
    [data-count : i64]
    [rodata-count : i64]) : cobj.CompilerObjectImage
    (let
      [base : cobj.CompilerObjectImage (compiler-object-coff-smoke-image)]
      (cobj.CompilerObjectImage
        (owned_view.compiler-owned-shared-view base.sections)
        (owned_view.compiler-owned-shared-view base.symbols)
        (compiler-object-coff-boundary-relocations data-count rodata-count)))))

(cfg
  test
  (define (compiler-object-coff-header-has-relocation-overflow?
    [obj : String]
    [kind : cobj.CompilerObjectSectionKind]) : bool
    (not
      (=
        (bit-and
          (compiler-object-coff-u32-at
            (owned_view.compiler-owned-shared-view obj)
            (+ (compiler-object-coff-section-header-offset kind) 36))
          compiler-object-coff-section-lnk-nreloc-ovfl)
        0))))

(cfg
  test
  (define (compiler-object-coff-relocation-overflow-below-boundary-ok?) : bool
    (let
      [semantic-count : i64 0xfffe]
      [image : cobj.CompilerObjectImage
        (compiler-object-coff-boundary-image semantic-count 0)]
      (match (compiler-object-coff-render
        (owned_view.compiler-owned-shared-view image))
        [(ResultCompilerObjectCoff.Ok obj)
          (let
            [text-header : i64
              (compiler-object-coff-section-header-offset
                (cobj.CompilerObjectSectionKind.Text))]
            [header : i64
              (compiler-object-coff-section-header-offset
                (cobj.CompilerObjectSectionKind.Data))]
            [reloc-pointer : i64
              (compiler-object-coff-u32-at
                (owned_view.compiler-owned-shared-view obj)
                (+ header 24))]
            [symbol-pointer : i64
              (compiler-object-coff-u32-at
                (owned_view.compiler-owned-shared-view obj)
                8)]
            (and
              (=
                (compiler-object-coff-u16-at
                  (owned_view.compiler-owned-shared-view obj)
                  (+ text-header 32))
                0)
              (=
                (compiler-object-coff-u32-at
                  (owned_view.compiler-owned-shared-view obj)
                  (+ text-header 24))
                0)
              (not
                (compiler-object-coff-header-has-relocation-overflow?
                  (owned_view.compiler-owned-shared-view obj)
                  (cobj.CompilerObjectSectionKind.Text)))
              (=
                (compiler-object-coff-u16-at
                  (owned_view.compiler-owned-shared-view obj)
                  (+ header 32))
                semantic-count)
              (not
                (compiler-object-coff-header-has-relocation-overflow?
                  (owned_view.compiler-owned-shared-view obj)
                  (cobj.CompilerObjectSectionKind.Data)))
              (compiler-object-coff-reloc-entry-ok?
                (owned_view.compiler-owned-shared-view obj)
                reloc-pointer
                0
                8
                (compiler-object-coff-symbol-index
                  (owned_view.compiler-owned-shared-view image)
                  "_tl_answer")
                compiler-object-coff-reloc-amd64-addr64)
              (compiler-object-coff-reloc-entry-ok?
                (owned_view.compiler-owned-shared-view obj)
                reloc-pointer
                (- semantic-count 1)
                8
                (compiler-object-coff-symbol-index
                  (owned_view.compiler-owned-shared-view image)
                  "foreign_exact")
                compiler-object-coff-reloc-amd64-addr64)
              (=
                symbol-pointer
                (+
                  reloc-pointer
                  (* semantic-count compiler-object-coff-relocation-size)))))]
        [(ResultCompilerObjectCoff.Err _) false]))))

(cfg
  test
  (define (compiler-object-coff-relocation-overflow-multiple-sections-ok?) : bool
    (let
      [data-count : i64 0xffff]
      [rodata-count : i64 0x10000]
      [data-physical : i64 (+ data-count 1)]
      [rodata-physical : i64 (+ rodata-count 1)]
      [image : cobj.CompilerObjectImage
        (compiler-object-coff-boundary-image data-count rodata-count)]
      (match (compiler-object-coff-render
        (owned_view.compiler-owned-shared-view image))
        [(ResultCompilerObjectCoff.Ok obj)
          (let
            [data-header : i64
              (compiler-object-coff-section-header-offset
                (cobj.CompilerObjectSectionKind.Data))]
            [rodata-header : i64
              (compiler-object-coff-section-header-offset
                (cobj.CompilerObjectSectionKind.Rodata))]
            [data-pointer : i64
              (compiler-object-coff-u32-at
                (owned_view.compiler-owned-shared-view obj)
                (+ data-header 24))]
            [rodata-pointer : i64
              (compiler-object-coff-u32-at
                (owned_view.compiler-owned-shared-view obj)
                (+ rodata-header 24))]
            [symbol-pointer : i64
              (compiler-object-coff-u32-at
                (owned_view.compiler-owned-shared-view obj)
                8)]
            [expected-size : i64
              (+
                symbol-pointer
                (+
                  (*
                    (cobj.compiler-object-symbol-list-count
                      (owned_view.compiler-owned-shared-view image.symbols))
                    18)
                  (compiler-object-coff-string-table-size
                    (owned_view.compiler-owned-shared-view image.symbols))))]
            (and
              (=
                (compiler-object-coff-u16-at
                  (owned_view.compiler-owned-shared-view obj)
                  (+ data-header 32))
                0xffff)
              (=
                (compiler-object-coff-u16-at
                  (owned_view.compiler-owned-shared-view obj)
                  (+ rodata-header 32))
                0xffff)
              (compiler-object-coff-header-has-relocation-overflow?
                (owned_view.compiler-owned-shared-view obj)
                (cobj.CompilerObjectSectionKind.Data))
              (compiler-object-coff-header-has-relocation-overflow?
                (owned_view.compiler-owned-shared-view obj)
                (cobj.CompilerObjectSectionKind.Rodata))
              (compiler-object-coff-reloc-entry-ok?
                (owned_view.compiler-owned-shared-view obj)
                data-pointer
                0
                data-physical
                0
                0)
              (compiler-object-coff-reloc-entry-ok?
                (owned_view.compiler-owned-shared-view obj)
                data-pointer
                1
                8
                (compiler-object-coff-symbol-index
                  (owned_view.compiler-owned-shared-view image)
                  "_tl_answer")
                compiler-object-coff-reloc-amd64-addr64)
              (compiler-object-coff-reloc-entry-ok?
                (owned_view.compiler-owned-shared-view obj)
                data-pointer
                data-count
                8
                (compiler-object-coff-symbol-index
                  (owned_view.compiler-owned-shared-view image)
                  "foreign_exact")
                compiler-object-coff-reloc-amd64-addr64)
              (=
                rodata-pointer
                (+
                  data-pointer
                  (* data-physical compiler-object-coff-relocation-size)))
              (compiler-object-coff-reloc-entry-ok?
                (owned_view.compiler-owned-shared-view obj)
                rodata-pointer
                0
                rodata-physical
                0
                0)
              (compiler-object-coff-reloc-entry-ok?
                (owned_view.compiler-owned-shared-view obj)
                rodata-pointer
                1
                0
                (compiler-object-coff-symbol-index
                  (owned_view.compiler-owned-shared-view image)
                  "_tl_answer")
                compiler-object-coff-reloc-amd64-addr64)
              (compiler-object-coff-reloc-entry-ok?
                (owned_view.compiler-owned-shared-view obj)
                rodata-pointer
                rodata-count
                0
                (compiler-object-coff-symbol-index
                  (owned_view.compiler-owned-shared-view image)
                  "foreign_exact")
                compiler-object-coff-reloc-amd64-addr64)
              (=
                symbol-pointer
                (+
                  rodata-pointer
                  (* rodata-physical compiler-object-coff-relocation-size)))
              (=
                (compiler-object-coff-string-length
                  (owned_view.compiler-owned-shared-view obj))
                expected-size)))]
        [(ResultCompilerObjectCoff.Err _) false]))))

(cfg
  test
  (define (compiler-object-coff-relocation-layout-rejection-ok?) : bool
    (let
      [initial : CompilerObjectCoffLayoutAccumulator
        (CompilerObjectCoffLayoutAccumulator 400 "")]
      [negative : CompilerObjectCoffLayoutAccumulator
        (compiler-object-coff-check-relocation-count-layout
          (owned_view.compiler-owned-shared-view initial)
          (cobj.CompilerObjectSectionKind.Pdata)
          -1
          1000)]
      [sentinel-overflow : CompilerObjectCoffLayoutAccumulator
        (compiler-object-coff-check-relocation-count-layout
          (owned_view.compiler-owned-shared-view initial)
          (cobj.CompilerObjectSectionKind.Xdata)
          0xffffffff
          compiler-object-coff-max-output-size)]
      [table-overflow : CompilerObjectCoffLayoutAccumulator
        (compiler-object-coff-check-relocation-count-layout
          initial
          (cobj.CompilerObjectSectionKind.Rsrc)
          10
          499)]
      (and
        (compiler-object-coff-contains?
          (owned_view.compiler-owned-shared-view negative.error)
          "section .pdata relocation count -1")
        (compiler-object-coff-contains?
          (owned_view.compiler-owned-shared-view sentinel-overflow.error)
          "section .xdata relocation count 4294967295")
        (compiler-object-coff-contains?
          (owned_view.compiler-owned-shared-view table-overflow.error)
          "section .rsrc relocation count 10")
        (= (compiler-object-coff-relocation-physical-count 0xfffe) 0xfffe)
        (= (compiler-object-coff-relocation-physical-count 0xffff) 0x10000)
        (= (compiler-object-coff-relocation-physical-count 0x10000) 0x10001)))))

(cfg
  test
  (test
    compiler-object-coff-smoke
    (begin
      (test.assert-true
        (compiler-object-coff-string-record-layout-ok?)
        "coff string records include one terminal zero")
      (test.assert-true (compiler-object-coff-smoke-ok?) "coff object smoke")
      (test.assert-true
        (compiler-object-coff-text-smoke-ok?)
        "coff text object smoke")
      (test.assert-true
        (compiler-object-coff-relocation-overflow-below-boundary-ok?)
        "coff relocation count 0xfffe stays in ordinary form")
      (test.assert-true
        (compiler-object-coff-relocation-overflow-multiple-sections-ok?)
        "coff relocation overflow is section-local and layout-complete")
      (test.assert-true
        (compiler-object-coff-relocation-layout-rejection-ok?)
        "coff relocation layout rejects malformed or oversized counts"))))