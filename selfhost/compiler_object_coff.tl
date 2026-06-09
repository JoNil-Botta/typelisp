;; compiler_object_coff.tl - COFF object-file serialization for object images.
(import "compiler_object.tl")

(defenum ResultCompilerObjectCoff
  (OkCompilerObjectCoff String)
  (ErrCompilerObjectCoff String))

(define compiler-object-coff-machine-amd64 : i64
  0x8664)

(define compiler-object-coff-section-count : i64
  4)

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
    [(ObjectSectionText) ".text"]
    [(ObjectSectionData) ".data"]
    [(ObjectSectionRodata) ".rdata"]
    [(ObjectSectionBss) ".bss"]))

(define (compiler-object-coff-section-number [kind : CompilerObjectSectionKind]) : i64
  (match kind
    [(ObjectSectionText) 1]
    [(ObjectSectionData) 2]
    [(ObjectSectionRodata) 3]
    [(ObjectSectionBss) 4]))

(define (compiler-object-coff-section-flags [kind : CompilerObjectSectionKind]) : i64
  (match kind
    [(ObjectSectionText)
      (bit-or
        compiler-object-coff-section-cnt-code
        (bit-or
          compiler-object-coff-section-align-16
          (bit-or
            compiler-object-coff-section-mem-execute
            compiler-object-coff-section-mem-read)))]
    [(ObjectSectionData)
      (bit-or
        compiler-object-coff-section-cnt-initialized-data
        (bit-or
          compiler-object-coff-section-align-8
          (bit-or
            compiler-object-coff-section-mem-read
            compiler-object-coff-section-mem-write)))]
    [(ObjectSectionRodata)
      (bit-or
        compiler-object-coff-section-cnt-initialized-data
        (bit-or
          compiler-object-coff-section-align-8
          compiler-object-coff-section-mem-read))]
    [(ObjectSectionBss)
      (bit-or
        compiler-object-coff-section-cnt-uninitialized-data
        (bit-or
          compiler-object-coff-section-align-8
          (bit-or
            compiler-object-coff-section-mem-read
            compiler-object-coff-section-mem-write)))]))

(define (compiler-object-coff-byte [value : i64]) : u8
  (cast (bit-and value 0xff) : u8))

(define (compiler-object-coff-push-u8! [out : (Array u8)] [value : i64]) : unit
  (array-push! out (compiler-object-coff-byte value)))

(define (compiler-object-coff-push-u16! [out : (Array u8)] [value : i64]) : unit
  (begin
    (compiler-object-coff-push-u8! out value)
    (compiler-object-coff-push-u8! out (shr value 8))))

(define (compiler-object-coff-push-u32! [out : (Array u8)] [value : i64]) : unit
  (begin
    (compiler-object-coff-push-u8! out value)
    (compiler-object-coff-push-u8! out (shr value 8))
    (compiler-object-coff-push-u8! out (shr value 16))
    (compiler-object-coff-push-u8! out (shr value 24))))

(define (compiler-object-coff-push-u64! [out : (Array u8)] [value : i64]) : unit
  (begin
    (compiler-object-coff-push-u32! out value)
    (compiler-object-coff-push-u32! out (shr value 32))))

(define (compiler-object-coff-push-zeroes! [out : (Array u8)] [count : i64]) : unit
  (let
    [i : i64 0]
    (begin
      (while (< i count)
        (begin
          (compiler-object-coff-push-u8! out 0)
          (set! i (+ i 1))))
      unit)))

(define (compiler-object-coff-push-string-bytes!
  [out : (Array u8)]
  [text : String]) : unit
  (let
    [i : i64 0]
    [n : i64 (string-length text)]
    (begin
      (while (< i n)
        (begin
          (array-push! out (cast (string-ref text i) : u8))
          (set! i (+ i 1))))
      unit)))

(define (compiler-object-coff-push-name8! [out : (Array u8)] [name : String]) : unit
  (let
    [i : i64 0]
    [n : i64 (string-length name)]
    (begin
      (while (< i 8)
        (begin
          (if (< i n)
            (array-push! out (cast (string-ref name i) : u8))
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
    [(ObjectDataLabel _) offset]
    [(ObjectDataAlign align) (compiler-object-coff-align-offset offset align)]
    [(ObjectDataBytes bytes) (+ offset (string-length bytes))]
    [(ObjectDataString text) (+ offset (string-length text))]
    [(ObjectDataF64 _) (+ offset 8)]
    [(ObjectDataI64 _) (+ offset 8)]
    [(ObjectDataZero count) (+ offset count)]
    [(ObjectDataSymbolAddress _) (+ offset 8)]))

(define (compiler-object-coff-data-records-size-from
  [records : CompilerObjectDataRecordList]
  [offset : i64]) : i64
  (match records
    [(ObjectDataNil) offset]
    [(ObjectDataCons record rest)
      (compiler-object-coff-data-records-size-from
        (box-get rest)
        (compiler-object-coff-data-record-end-offset record offset))]))

(define (compiler-object-coff-data-records-size
  [records : CompilerObjectDataRecordList]) : i64
  (compiler-object-coff-data-records-size-from records 0))

(define (compiler-object-coff-instr-size [instr : CompilerObjectX64Instr]) : i64
  (match instr
    [(ObjectX64Label _) 0]
    [(ObjectX64Call _) 5]
    [(ObjectX64TailCall _) 5]
    [(ObjectX64Jump _) 5]
    [(ObjectX64Branch _ _) 14]
    [(ObjectX64LoadRip _) 7]
    [(ObjectX64LoadRipAddress _) 7]
    [(ObjectX64StoreRip _) 7]
    [(ObjectX64Raw _) 0]
    [_ 0]))

(define (compiler-object-coff-instr-relocation-count
  [instr : CompilerObjectX64Instr]) : i64
  (match instr
    [(ObjectX64Label _) 0]
    [(ObjectX64Call _) 1]
    [(ObjectX64TailCall _) 1]
    [(ObjectX64Jump _) 1]
    [(ObjectX64Branch _ _) 2]
    [(ObjectX64LoadRip _) 1]
    [(ObjectX64LoadRipAddress _) 1]
    [(ObjectX64StoreRip _) 1]
    [(ObjectX64Raw _) 0]))

(define (compiler-object-coff-instrs-relocation-count
  [instrs : CompilerObjectX64InstrList]) : i64
  (match instrs
    [(ObjectInstrNil) 0]
    [(ObjectInstrCons instr rest)
      (+
        (compiler-object-coff-instr-relocation-count instr)
        (compiler-object-coff-instrs-relocation-count (box-get rest)))]))

(define (compiler-object-coff-instrs-size-from
  [instrs : CompilerObjectX64InstrList]
  [offset : i64]) : i64
  (match instrs
    [(ObjectInstrNil) offset]
    [(ObjectInstrCons instr rest)
      (compiler-object-coff-instrs-size-from
        (box-get rest)
        (+ offset (compiler-object-coff-instr-size instr)))]))

(define (compiler-object-coff-instrs-size [instrs : CompilerObjectX64InstrList]) : i64
  (compiler-object-coff-instrs-size-from instrs 0))

(define (compiler-object-coff-section-virtual-size
  [image : CompilerObjectImage]
  [kind : CompilerObjectSectionKind]) : i64
  (match (compiler-object-section-list-find (struct-get image sections) kind)
    [(ObjectSection _ data instrs)
      (match kind
        [(ObjectSectionText) (compiler-object-coff-instrs-size instrs)]
        [_ (compiler-object-coff-data-records-size data)])]))

(define (compiler-object-coff-section-raw-size
  [image : CompilerObjectImage]
  [kind : CompilerObjectSectionKind]) : i64
  (match kind
    [(ObjectSectionBss) 0]
    [_ (compiler-object-coff-section-virtual-size image kind)]))

(define (compiler-object-coff-text-relocation-kind-supported?
  [kind : CompilerObjectRelocationKind]) : bool
  (match kind
    [(ObjectRelocCall) true]
    [(ObjectRelocTailCall) true]
    [(ObjectRelocRipValue) true]
    [(ObjectRelocRipAddress) true]
    [(ObjectRelocBranch) true]
    [_ false]))

(define (compiler-object-coff-data-relocation-kind-supported?
  [kind : CompilerObjectRelocationKind]) : bool
  (match kind
    [(ObjectRelocAbs64) true]
    [_ false]))

(define (compiler-object-coff-relocation-supported?
  [reloc : CompilerObjectRelocation]) : bool
  (match reloc
    [(ObjectRelocation section _ kind _)
      (match section
        [(ObjectSectionText)
          (compiler-object-coff-text-relocation-kind-supported? kind)]
        [_ (compiler-object-coff-data-relocation-kind-supported? kind)])]))

(define (compiler-object-coff-relocation-list-supported?
  [relocs : CompilerObjectRelocationList]) : bool
  (match relocs
    [(ObjectRelocationNil) true]
    [(ObjectRelocationCons reloc rest)
      (if (compiler-object-coff-relocation-supported? reloc)
        (compiler-object-coff-relocation-list-supported? (box-get rest))
        false)]))

(define (compiler-object-coff-data-records-supported?
  [records : CompilerObjectDataRecordList]) : bool
  (match records
    [(ObjectDataNil) true]
    [(ObjectDataCons record rest)
      (match record
        [(ObjectDataF64 _) false]
        [_ (compiler-object-coff-data-records-supported? (box-get rest))])]))

(define (compiler-object-coff-instrs-supported?
  [instrs : CompilerObjectX64InstrList]) : bool
  (match instrs
    [(ObjectInstrNil) true]
    [(ObjectInstrCons instr rest)
      (match instr
        [(ObjectX64Label _)
          (compiler-object-coff-instrs-supported? (box-get rest))]
        [(ObjectX64Call _)
          (compiler-object-coff-instrs-supported? (box-get rest))]
        [(ObjectX64TailCall _)
          (compiler-object-coff-instrs-supported? (box-get rest))]
        [(ObjectX64Jump _)
          (compiler-object-coff-instrs-supported? (box-get rest))]
        [(ObjectX64Branch _ _)
          (compiler-object-coff-instrs-supported? (box-get rest))]
        [(ObjectX64LoadRip _)
          (compiler-object-coff-instrs-supported? (box-get rest))]
        [(ObjectX64LoadRipAddress _)
          (compiler-object-coff-instrs-supported? (box-get rest))]
        [(ObjectX64StoreRip _)
          (compiler-object-coff-instrs-supported? (box-get rest))]
        [_ false])]))

(define (compiler-object-coff-sections-supported?
  [sections : CompilerObjectSectionList]) : bool
  (match sections
    [(ObjectSectionNil) true]
    [(ObjectSectionCons section rest)
      (match section
        [(ObjectSection _ data instrs)
          (if (and
            (compiler-object-coff-data-records-supported? data)
            (compiler-object-coff-instrs-supported? instrs))
            (compiler-object-coff-sections-supported? (box-get rest))
            false)])]))

(define (compiler-object-coff-symbol-index-from
  [symbols : CompilerObjectSymbolList]
  [name : String]
  [index : i64]) : i64
  (match symbols
    [(ObjectSymbolNil) -1]
    [(ObjectSymbolCons symbol rest)
      (match symbol
        [(ObjectSymbol found _ _ _)
          (if (string-eq found name)
            index
            (compiler-object-coff-symbol-index-from
              (box-get rest)
              name
              (+ index 1)))])]))

(define (compiler-object-coff-symbol-index
  [image : CompilerObjectImage]
  [name : String]) : i64
  (compiler-object-coff-symbol-index-from (struct-get image symbols) name 0))

(define (compiler-object-coff-data-label-offset-from
  [records : CompilerObjectDataRecordList]
  [label : String]
  [offset : i64]) : i64
  (match records
    [(ObjectDataNil) -1]
    [(ObjectDataCons record rest)
      (match record
        [(ObjectDataLabel found)
          (if (string-eq found label)
            offset
            (compiler-object-coff-data-label-offset-from
              (box-get rest)
              label
              offset))]
        [_
          (compiler-object-coff-data-label-offset-from
            (box-get rest)
            label
            (compiler-object-coff-data-record-end-offset record offset))])]))

(define (compiler-object-coff-instr-label-offset-from
  [instrs : CompilerObjectX64InstrList]
  [label : String]
  [offset : i64]) : i64
  (match instrs
    [(ObjectInstrNil) -1]
    [(ObjectInstrCons instr rest)
      (match instr
        [(ObjectX64Label found)
          (if (string-eq found label)
            offset
            (compiler-object-coff-instr-label-offset-from
              (box-get rest)
              label
              offset))]
        [_
          (compiler-object-coff-instr-label-offset-from
            (box-get rest)
            label
            (+ offset (compiler-object-coff-instr-size instr)))])]))

(define (compiler-object-coff-section-label-offset
  [image : CompilerObjectImage]
  [kind : CompilerObjectSectionKind]
  [label : String]) : i64
  (match (compiler-object-section-list-find (struct-get image sections) kind)
    [(ObjectSection _ data instrs)
      (match kind
        [(ObjectSectionText)
          (compiler-object-coff-instr-label-offset-from instrs label 0)]
        [_ (compiler-object-coff-data-label-offset-from data label 0)])]))

(define (compiler-object-coff-relocation-sites-known?
  [image : CompilerObjectImage]
  [relocs : CompilerObjectRelocationList]) : bool
  (match relocs
    [(ObjectRelocationNil) true]
    [(ObjectRelocationCons reloc rest)
      (match reloc
        [(ObjectRelocation section site _ target)
          (if (match section
            [(ObjectSectionText)
              (>= (compiler-object-coff-symbol-index image target) 0)]
            [_
              (and
                (>=
                  (compiler-object-coff-section-label-offset image section site)
                  0)
                (>= (compiler-object-coff-symbol-index image target) 0))])
            (compiler-object-coff-relocation-sites-known? image (box-get rest))
            false)])]))

(define (compiler-object-coff-instr-targets-known?
  [image : CompilerObjectImage]
  [instrs : CompilerObjectX64InstrList]) : bool
  (match instrs
    [(ObjectInstrNil) true]
    [(ObjectInstrCons instr rest)
      (let
        [tail-ok : bool
          (compiler-object-coff-instr-targets-known? image (box-get rest))]
        (match instr
          [(ObjectX64Label _) tail-ok]
          [(ObjectX64Call target)
            (and
              (>= (compiler-object-coff-symbol-index image target) 0)
              tail-ok)]
          [(ObjectX64TailCall target)
            (and
              (>= (compiler-object-coff-symbol-index image target) 0)
              tail-ok)]
          [(ObjectX64Jump target)
            (and
              (>= (compiler-object-coff-symbol-index image target) 0)
              tail-ok)]
          [(ObjectX64Branch true-target false-target)
            (and
              (>= (compiler-object-coff-symbol-index image true-target) 0)
              (and
                (>= (compiler-object-coff-symbol-index image false-target) 0)
                tail-ok))]
          [(ObjectX64LoadRip target)
            (and
              (>= (compiler-object-coff-symbol-index image target) 0)
              tail-ok)]
          [(ObjectX64LoadRipAddress target)
            (and
              (>= (compiler-object-coff-symbol-index image target) 0)
              tail-ok)]
          [(ObjectX64StoreRip target)
            (and
              (>= (compiler-object-coff-symbol-index image target) 0)
              tail-ok)]
          [(ObjectX64Raw _) false]))]))

(define (compiler-object-coff-text-targets-known? [image : CompilerObjectImage]) : bool
  (match (compiler-object-section-list-find
    (struct-get image sections)
    (ObjectSectionText))
    [(ObjectSection _ _ instrs)
      (compiler-object-coff-instr-targets-known? image instrs)]))

(define (compiler-object-coff-text-instr-relocation-count
  [image : CompilerObjectImage]) : i64
  (match (compiler-object-section-list-find
    (struct-get image sections)
    (ObjectSectionText))
    [(ObjectSection _ _ instrs)
      (compiler-object-coff-instrs-relocation-count instrs)]))

(define (compiler-object-coff-text-relocation-count-matches?
  [image : CompilerObjectImage]) : bool
  (=
    (compiler-object-coff-relocation-count
      (struct-get image relocations)
      (ObjectSectionText))
    (compiler-object-coff-text-instr-relocation-count image)))

(define (compiler-object-coff-image-supported? [image : CompilerObjectImage]) : bool
  (and
    (compiler-object-coff-sections-supported? (struct-get image sections))
    (and
      (compiler-object-coff-relocation-list-supported?
        (struct-get image relocations))
      (and
        (compiler-object-coff-relocation-sites-known?
          image
          (struct-get image relocations))
        (and
          (compiler-object-coff-text-targets-known? image)
          (compiler-object-coff-text-relocation-count-matches? image))))))

(define (compiler-object-coff-header-size) : i64
  (+
    compiler-object-coff-file-header-size
    (*
      compiler-object-coff-section-header-size
      compiler-object-coff-section-count)))

(define (compiler-object-coff-relocation-count
  [relocs : CompilerObjectRelocationList]
  [kind : CompilerObjectSectionKind]) : i64
  (match relocs
    [(ObjectRelocationNil) 0]
    [(ObjectRelocationCons reloc rest)
      (match reloc
        [(ObjectRelocation section _ _ _)
          (+
            (if (compiler-object-section-kind-eq? section kind)
              1
              0)
            (compiler-object-coff-relocation-count (box-get rest) kind))])]))

(define (compiler-object-coff-section-relocation-count
  [image : CompilerObjectImage]
  [kind : CompilerObjectSectionKind]) : i64
  (match kind
    [(ObjectSectionText)
      (compiler-object-coff-text-instr-relocation-count image)]
    [_
      (compiler-object-coff-relocation-count
        (struct-get image relocations)
        kind)]))

(define (compiler-object-coff-total-relocation-count
  [image : CompilerObjectImage]) : i64
  (+
    (compiler-object-coff-section-relocation-count image (ObjectSectionText))
    (+
      (compiler-object-coff-section-relocation-count image (ObjectSectionData))
      (+
        (compiler-object-coff-section-relocation-count
          image
          (ObjectSectionRodata))
        (compiler-object-coff-section-relocation-count image (ObjectSectionBss))))))

(define (compiler-object-coff-raw-base-after-section
  [image : CompilerObjectImage]
  [kind : CompilerObjectSectionKind]) : i64
  (match kind
    [(ObjectSectionText) (compiler-object-coff-header-size)]
    [(ObjectSectionData)
      (+
        (compiler-object-coff-header-size)
        (compiler-object-coff-section-raw-size image (ObjectSectionText)))]
    [(ObjectSectionRodata)
      (+
        (compiler-object-coff-header-size)
        (+
          (compiler-object-coff-section-raw-size image (ObjectSectionText))
          (compiler-object-coff-section-raw-size image (ObjectSectionData))))]
    [(ObjectSectionBss) 0]))

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
      (compiler-object-coff-section-raw-size image (ObjectSectionText))
      (+
        (compiler-object-coff-section-raw-size image (ObjectSectionData))
        (compiler-object-coff-section-raw-size image (ObjectSectionRodata))))))

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
            (ObjectSectionText))]
        [data-count : i64
          (compiler-object-coff-section-relocation-count
            image
            (ObjectSectionData))]
        [rodata-count : i64
          (compiler-object-coff-section-relocation-count
            image
            (ObjectSectionRodata))]
        [base : i64 (compiler-object-coff-relocation-base image)]
        (match kind
          [(ObjectSectionText) base]
          [(ObjectSectionData)
            (+ base (* compiler-object-coff-relocation-size text-count))]
          [(ObjectSectionRodata)
            (+
              base
              (* compiler-object-coff-relocation-size (+ text-count data-count)))]
          [(ObjectSectionBss)
            (+
              base
              (*
                compiler-object-coff-relocation-size
                (+ text-count (+ data-count rodata-count))))])))))

(define (compiler-object-coff-symbol-table-pointer
  [image : CompilerObjectImage]) : i64
  (+
    (compiler-object-coff-relocation-base image)
    (*
      compiler-object-coff-relocation-size
      (compiler-object-coff-total-relocation-count image))))

(define (compiler-object-coff-push-file-header!
  [out : (Array u8)]
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
  [out : (Array u8)]
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
  [out : (Array u8)]
  [image : CompilerObjectImage]) : unit
  (begin
    (compiler-object-coff-push-section-header! out image (ObjectSectionText))
    (compiler-object-coff-push-section-header! out image (ObjectSectionData))
    (compiler-object-coff-push-section-header! out image (ObjectSectionRodata))
    (compiler-object-coff-push-section-header! out image (ObjectSectionBss))))

(define (compiler-object-coff-render-data-record!
  [out : (Array u8)]
  [record : CompilerObjectDataRecord]
  [offset : i64]) : i64
  (match record
    [(ObjectDataLabel _) offset]
    [(ObjectDataAlign align)
      (let
        [aligned : i64 (compiler-object-coff-align-offset offset align)]
        (begin
          (compiler-object-coff-push-zeroes! out (- aligned offset))
          aligned))]
    [(ObjectDataBytes bytes)
      (begin
        (compiler-object-coff-push-string-bytes! out bytes)
        (+ offset (string-length bytes)))]
    [(ObjectDataString text)
      (begin
        (compiler-object-coff-push-string-bytes! out text)
        (+ offset (string-length text)))]
    [(ObjectDataF64 _)
      (begin
        (compiler-object-coff-push-u64! out 0)
        (+ offset 8))]
    [(ObjectDataI64 value)
      (begin
        (compiler-object-coff-push-u64! out value)
        (+ offset 8))]
    [(ObjectDataZero count)
      (begin
        (compiler-object-coff-push-zeroes! out count)
        (+ offset count))]
    [(ObjectDataSymbolAddress _)
      (begin
        (compiler-object-coff-push-u64! out 0)
        (+ offset 8))]))

(define (compiler-object-coff-render-data-records!
  [out : (Array u8)]
  [records : CompilerObjectDataRecordList]
  [offset : i64]) : i64
  (match records
    [(ObjectDataNil) offset]
    [(ObjectDataCons record rest)
      (compiler-object-coff-render-data-records!
        out
        (box-get rest)
        (compiler-object-coff-render-data-record! out record offset))]))

(define (compiler-object-coff-push-rel32-placeholder! [out : (Array u8)]) : unit
  (compiler-object-coff-push-u32! out 0))

(define (compiler-object-coff-render-instr!
  [out : (Array u8)]
  [instr : CompilerObjectX64Instr]) : unit
  (match instr
    [(ObjectX64Label _) unit]
    [(ObjectX64Call _)
      (begin
        (compiler-object-coff-push-u8! out 0xe8)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(ObjectX64TailCall _)
      (begin
        (compiler-object-coff-push-u8! out 0xe9)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(ObjectX64Jump _)
      (begin
        (compiler-object-coff-push-u8! out 0xe9)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(ObjectX64Branch _ _)
      (begin
        (compiler-object-coff-push-u8! out 0x48)
        (compiler-object-coff-push-u8! out 0x85)
        (compiler-object-coff-push-u8! out 0xc0)
        (compiler-object-coff-push-u8! out 0x0f)
        (compiler-object-coff-push-u8! out 0x85)
        (compiler-object-coff-push-rel32-placeholder! out)
        (compiler-object-coff-push-u8! out 0xe9)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(ObjectX64LoadRip _)
      (begin
        (compiler-object-coff-push-u8! out 0x48)
        (compiler-object-coff-push-u8! out 0x8b)
        (compiler-object-coff-push-u8! out 0x05)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(ObjectX64LoadRipAddress _)
      (begin
        (compiler-object-coff-push-u8! out 0x48)
        (compiler-object-coff-push-u8! out 0x8d)
        (compiler-object-coff-push-u8! out 0x05)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(ObjectX64StoreRip _)
      (begin
        (compiler-object-coff-push-u8! out 0x48)
        (compiler-object-coff-push-u8! out 0x89)
        (compiler-object-coff-push-u8! out 0x05)
        (compiler-object-coff-push-rel32-placeholder! out))]
    [(ObjectX64Raw _) unit]))

(define (compiler-object-coff-render-instrs!
  [out : (Array u8)]
  [instrs : CompilerObjectX64InstrList]) : unit
  (match instrs
    [(ObjectInstrNil) unit]
    [(ObjectInstrCons instr rest)
      (begin
        (compiler-object-coff-render-instr! out instr)
        (compiler-object-coff-render-instrs! out (box-get rest)))]))

(define (compiler-object-coff-render-section-data!
  [out : (Array u8)]
  [image : CompilerObjectImage]
  [kind : CompilerObjectSectionKind]) : unit
  (match (compiler-object-section-list-find (struct-get image sections) kind)
    [(ObjectSection _ data instrs)
      (match kind
        [(ObjectSectionText) (compiler-object-coff-render-instrs! out instrs)]
        [_
          (begin
            (compiler-object-coff-render-data-records! out data 0)
            unit)])]))

(define (compiler-object-coff-render-sections!
  [out : (Array u8)]
  [image : CompilerObjectImage]) : unit
  (begin
    (compiler-object-coff-render-section-data! out image (ObjectSectionText))
    (compiler-object-coff-render-section-data! out image (ObjectSectionData))
    (compiler-object-coff-render-section-data! out image (ObjectSectionRodata))))

(define (compiler-object-coff-relocation-type
  [kind : CompilerObjectRelocationKind]) : i64
  (match kind
    [(ObjectRelocCall) compiler-object-coff-reloc-amd64-rel32]
    [(ObjectRelocTailCall) compiler-object-coff-reloc-amd64-rel32]
    [(ObjectRelocAbs64) compiler-object-coff-reloc-amd64-addr64]
    [(ObjectRelocRipValue) compiler-object-coff-reloc-amd64-rel32]
    [(ObjectRelocRipAddress) compiler-object-coff-reloc-amd64-rel32]
    [(ObjectRelocBranch) compiler-object-coff-reloc-amd64-rel32]
    [_ 0]))

(define (compiler-object-coff-render-relocation-record!
  [out : (Array u8)]
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
  [out : (Array u8)]
  [image : CompilerObjectImage]
  [reloc : CompilerObjectRelocation]) : unit
  (match reloc
    [(ObjectRelocation section site kind target)
      (begin
        (compiler-object-coff-render-relocation-record!
          out
          image
          (compiler-object-coff-section-label-offset image section site)
          kind
          target))]))

(define (compiler-object-coff-render-text-instr-relocations!
  [out : (Array u8)]
  [image : CompilerObjectImage]
  [instrs : CompilerObjectX64InstrList]
  [offset : i64]) : unit
  (match instrs
    [(ObjectInstrNil) unit]
    [(ObjectInstrCons instr rest)
      (begin
        (match instr
          [(ObjectX64Label _) unit]
          [(ObjectX64Call target)
            (compiler-object-coff-render-relocation-record!
              out
              image
              (+ offset 1)
              (ObjectRelocCall)
              target)]
          [(ObjectX64TailCall target)
            (compiler-object-coff-render-relocation-record!
              out
              image
              (+ offset 1)
              (ObjectRelocTailCall)
              target)]
          [(ObjectX64Jump target)
            (compiler-object-coff-render-relocation-record!
              out
              image
              (+ offset 1)
              (ObjectRelocBranch)
              target)]
          [(ObjectX64Branch true-target false-target)
            (begin
              (compiler-object-coff-render-relocation-record!
                out
                image
                (+ offset 5)
                (ObjectRelocBranch)
                true-target)
              (compiler-object-coff-render-relocation-record!
                out
                image
                (+ offset 10)
                (ObjectRelocBranch)
                false-target))]
          [(ObjectX64LoadRip target)
            (compiler-object-coff-render-relocation-record!
              out
              image
              (+ offset 3)
              (ObjectRelocRipValue)
              target)]
          [(ObjectX64LoadRipAddress target)
            (compiler-object-coff-render-relocation-record!
              out
              image
              (+ offset 3)
              (ObjectRelocRipAddress)
              target)]
          [(ObjectX64StoreRip target)
            (compiler-object-coff-render-relocation-record!
              out
              image
              (+ offset 3)
              (ObjectRelocRipAddress)
              target)]
          [(ObjectX64Raw _) unit])
        (compiler-object-coff-render-text-instr-relocations!
          out
          image
          (box-get rest)
          (+ offset (compiler-object-coff-instr-size instr))))]))

(define (compiler-object-coff-render-text-relocations!
  [out : (Array u8)]
  [image : CompilerObjectImage]) : unit
  (match (compiler-object-section-list-find
    (struct-get image sections)
    (ObjectSectionText))
    [(ObjectSection _ _ instrs)
      (compiler-object-coff-render-text-instr-relocations! out image instrs 0)]))

(define (compiler-object-coff-render-relocations-for-section!
  [out : (Array u8)]
  [image : CompilerObjectImage]
  [relocs : CompilerObjectRelocationList]
  [kind : CompilerObjectSectionKind]) : unit
  (match relocs
    [(ObjectRelocationNil) unit]
    [(ObjectRelocationCons reloc rest)
      (begin
        (match reloc
          [(ObjectRelocation section _ _ _)
            (if (compiler-object-section-kind-eq? section kind)
              (compiler-object-coff-render-relocation! out image reloc)
              unit)])
        (compiler-object-coff-render-relocations-for-section!
          out
          image
          (box-get rest)
          kind))]))

(define (compiler-object-coff-render-relocations!
  [out : (Array u8)]
  [image : CompilerObjectImage]) : unit
  (begin
    (compiler-object-coff-render-text-relocations! out image)
    (compiler-object-coff-render-relocations-for-section!
      out
      image
      (struct-get image relocations)
      (ObjectSectionData))
    (compiler-object-coff-render-relocations-for-section!
      out
      image
      (struct-get image relocations)
      (ObjectSectionRodata))
    (compiler-object-coff-render-relocations-for-section!
      out
      image
      (struct-get image relocations)
      (ObjectSectionBss))))

(define (compiler-object-coff-symbol-name-long? [name : String]) : bool
  (> (string-length name) 8))

(define (compiler-object-coff-symbol-string-offset-from
  [symbols : CompilerObjectSymbolList]
  [name : String]
  [offset : i64]) : i64
  (match symbols
    [(ObjectSymbolNil) 0]
    [(ObjectSymbolCons symbol rest)
      (match symbol
        [(ObjectSymbol found _ _ _)
          (if (compiler-object-coff-symbol-name-long? found)
            (if (string-eq found name)
              offset
              (compiler-object-coff-symbol-string-offset-from
                (box-get rest)
                name
                (+ offset (+ (string-length found) 1))))
            (compiler-object-coff-symbol-string-offset-from
              (box-get rest)
              name
              offset))])]))

(define (compiler-object-coff-symbol-string-offset
  [image : CompilerObjectImage]
  [name : String]) : i64
  (compiler-object-coff-symbol-string-offset-from
    (struct-get image symbols)
    name
    4))

(define (compiler-object-coff-push-symbol-name!
  [out : (Array u8)]
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
    [(ObjectSymbolLocal) 3]
    [_ 2]))

(define (compiler-object-coff-symbol-type [kind : CompilerObjectSymbolKind]) : i64
  (match kind
    [(ObjectSymbolFunction) 0x20]
    [_ 0]))

(define (compiler-object-coff-symbol-section-number
  [section : CompilerObjectMaybeSection]) : i64
  (match section
    [(ObjectNoSection) 0]
    [(ObjectSomeSection kind) (compiler-object-coff-section-number kind)]))

(define (compiler-object-coff-symbol-value
  [image : CompilerObjectImage]
  [name : String]
  [section : CompilerObjectMaybeSection]) : i64
  (match section
    [(ObjectNoSection) 0]
    [(ObjectSomeSection kind)
      (let
        [offset : i64
          (compiler-object-coff-section-label-offset image kind name)]
        (if (< offset 0)
          0
          offset))]))

(define (compiler-object-coff-render-symbol!
  [out : (Array u8)]
  [image : CompilerObjectImage]
  [symbol : CompilerObjectSymbol]) : unit
  (match symbol
    [(ObjectSymbol name binding kind section)
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
  [out : (Array u8)]
  [image : CompilerObjectImage]
  [symbols : CompilerObjectSymbolList]) : unit
  (match symbols
    [(ObjectSymbolNil) unit]
    [(ObjectSymbolCons symbol rest)
      (begin
        (compiler-object-coff-render-symbol! out image symbol)
        (compiler-object-coff-render-symbols! out image (box-get rest)))]))

(define (compiler-object-coff-string-table-size-from
  [symbols : CompilerObjectSymbolList]
  [size : i64]) : i64
  (match symbols
    [(ObjectSymbolNil) size]
    [(ObjectSymbolCons symbol rest)
      (match symbol
        [(ObjectSymbol name _ _ _)
          (compiler-object-coff-string-table-size-from
            (box-get rest)
            (if (compiler-object-coff-symbol-name-long? name)
              (+ size (+ (string-length name) 1))
              size))])]))

(define (compiler-object-coff-string-table-size
  [symbols : CompilerObjectSymbolList]) : i64
  (compiler-object-coff-string-table-size-from symbols 4))

(define (compiler-object-coff-render-string-table-symbols!
  [out : (Array u8)]
  [symbols : CompilerObjectSymbolList]) : unit
  (match symbols
    [(ObjectSymbolNil) unit]
    [(ObjectSymbolCons symbol rest)
      (begin
        (match symbol
          [(ObjectSymbol name _ _ _)
            (if (compiler-object-coff-symbol-name-long? name)
              (begin
                (compiler-object-coff-push-string-bytes! out name)
                (compiler-object-coff-push-u8! out 0))
              unit)])
        (compiler-object-coff-render-string-table-symbols! out (box-get rest)))]))

(define (compiler-object-coff-render-string-table!
  [out : (Array u8)]
  [image : CompilerObjectImage]) : unit
  (begin
    (compiler-object-coff-push-u32!
      out
      (compiler-object-coff-string-table-size (struct-get image symbols)))
    (compiler-object-coff-render-string-table-symbols!
      out
      (struct-get image symbols))))

(define (compiler-object-coff-bytes-string [bytes : (Array u8)]) : String
  (unsafe
    (string-from-bytes
      (ptr-cast (array-data bytes) : (Ptr u8))
      (array-length bytes))))

(define (compiler-object-coff-render [image : CompilerObjectImage]) : ResultCompilerObjectCoff
  (if (compiler-object-coff-image-supported? image)
    (let
      [out : (Array u8) (make-array u8 0)]
      (begin
        (compiler-object-coff-push-file-header! out image)
        (compiler-object-coff-push-section-headers! out image)
        (compiler-object-coff-render-sections! out image)
        (compiler-object-coff-render-relocations! out image)
        (compiler-object-coff-render-symbols!
          out
          image
          (struct-get image symbols))
        (compiler-object-coff-render-string-table! out image)
        (OkCompilerObjectCoff (compiler-object-coff-bytes-string out))))
    (ErrCompilerObjectCoff
      "coff: object image contains unsupported text, f64, or relocation records")))

(define (compiler-object-coff-u16-at [text : String] [offset : i64]) : i64
  (+
    (cast (string-ref text offset) : i64)
    (shl (cast (string-ref text (+ offset 1)) : i64) 8)))

(define (compiler-object-coff-u32-at [text : String] [offset : i64]) : i64
  (+
    (compiler-object-coff-u16-at text offset)
    (shl (compiler-object-coff-u16-at text (+ offset 2)) 16)))

(define (compiler-object-coff-u8-at [text : String] [offset : i64]) : i64
  (cast (string-ref text offset) : i64))

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
    [text-len : i64 (string-length text)]
    [needle-len : i64 (string-length needle)]
    (if (> (+ start needle-len) text-len)
      false
      (let
        [i : i64 0]
        [ok : bool true]
        (begin
          (while ok
            (if (< i needle-len)
              (if (= (string-ref text (+ start i)) (string-ref needle i))
                (set! i (+ i 1))
                (set! ok false))
              (set! ok false)))
          (= i needle-len))))))

(define (compiler-object-coff-contains? [text : String] [needle : String]) : bool
  (let
    [i : i64 0]
    [n : i64 (string-length text)]
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
      (ObjectSection
        (ObjectSectionText)
        ObjectDataNil
        (compiler-object-instr-cons (ObjectX64Label "_tl_empty") ObjectInstrNil))
      (compiler-object-section-cons
        (ObjectSection
          (ObjectSectionData)
          (compiler-object-data-cons
            (ObjectDataLabel "_tl_answer")
            (compiler-object-data-cons
              (ObjectDataI64 42)
              (compiler-object-data-cons
                (ObjectDataLabel "_tl_ptr")
                (compiler-object-data-cons
                  (ObjectDataSymbolAddress "_tl_answer")
                  ObjectDataNil))))
          ObjectInstrNil)
        (compiler-object-section-cons
          (ObjectSection
            (ObjectSectionRodata)
            (compiler-object-data-cons
              (ObjectDataLabel "long_rodata_label_name")
              (compiler-object-data-cons
                (ObjectDataString "hello")
                ObjectDataNil))
            ObjectInstrNil)
          (compiler-object-section-cons
            (ObjectSection
              (ObjectSectionBss)
              (compiler-object-data-cons
                (ObjectDataLabel "_tl_heap")
                (compiler-object-data-cons (ObjectDataZero 16) ObjectDataNil))
              ObjectInstrNil)
            ObjectSectionNil))))
    (compiler-object-symbol-cons
      (ObjectSymbol
        "_tl_empty"
        (ObjectSymbolExport)
        (ObjectSymbolFunction)
        (ObjectSomeSection (ObjectSectionText)))
      (compiler-object-symbol-cons
        (ObjectSymbol
          "_tl_answer"
          (ObjectSymbolExport)
          (ObjectSymbolData)
          (ObjectSomeSection (ObjectSectionData)))
        (compiler-object-symbol-cons
          (ObjectSymbol
            "_tl_ptr"
            (ObjectSymbolLocal)
            (ObjectSymbolData)
            (ObjectSomeSection (ObjectSectionData)))
          (compiler-object-symbol-cons
            (ObjectSymbol
              "long_rodata_label_name"
              (ObjectSymbolLocal)
              (ObjectSymbolData)
              (ObjectSomeSection (ObjectSectionRodata)))
            (compiler-object-symbol-cons
              (ObjectSymbol
                "foreign_exact"
                (ObjectSymbolExtern)
                (ObjectSymbolFunction)
                (ObjectNoSection))
              ObjectSymbolNil)))))
    (compiler-object-relocation-cons
      (ObjectRelocation
        (ObjectSectionData)
        "_tl_ptr"
        (ObjectRelocAbs64)
        "_tl_answer")
      ObjectRelocationNil)))

(define (compiler-object-coff-smoke-ok?) : bool
  (match (compiler-object-coff-render (compiler-object-coff-smoke-image))
    [(OkCompilerObjectCoff obj)
      (and
        (=
          (compiler-object-coff-u16-at obj 0)
          compiler-object-coff-machine-amd64)
        (and
          (= (compiler-object-coff-u16-at obj 2) 4)
          (and
            (> (compiler-object-coff-u32-at obj 8) 0)
            (and
              (= (compiler-object-coff-u32-at obj 12) 5)
              (and
                (= (compiler-object-coff-u32-at obj (+ 60 16)) 16)
                (and
                  (= (compiler-object-coff-u16-at obj (+ 60 32)) 1)
                  (and
                    (compiler-object-coff-contains? obj ".rdata")
                    (and
                      (compiler-object-coff-contains? obj "foreign_exact")
                      (compiler-object-coff-contains?
                        obj
                        "long_rodata_label_name")))))))))]
    [(ErrCompilerObjectCoff _) false]))

(define (compiler-object-coff-text-smoke-instrs) : CompilerObjectX64InstrList
  (compiler-object-instr-cons
    (ObjectX64Label "_tl_text")
    (compiler-object-instr-cons
      (ObjectX64LoadRip "_tl_answer")
      (compiler-object-instr-cons
        (ObjectX64LoadRipAddress "_tl_slot")
        (compiler-object-instr-cons
          (ObjectX64StoreRip "_tl_slot")
          (compiler-object-instr-cons
            (ObjectX64Call "foreign_exact")
            (compiler-object-instr-cons
              (ObjectX64TailCall "_tl_done")
              (compiler-object-instr-cons
                (ObjectX64Jump "_tl_done")
                (compiler-object-instr-cons
                  (ObjectX64Branch "_tl_true" "_tl_false")
                  (compiler-object-instr-cons
                    (ObjectX64Label "_tl_true")
                    (compiler-object-instr-cons
                      (ObjectX64Label "_tl_false")
                      (compiler-object-instr-cons
                        (ObjectX64Label "_tl_done")
                        ObjectInstrNil))))))))))))

(define (compiler-object-coff-text-smoke-symbols) : CompilerObjectSymbolList
  (compiler-object-symbol-cons
    (ObjectSymbol
      "_tl_text"
      (ObjectSymbolExport)
      (ObjectSymbolFunction)
      (ObjectSomeSection (ObjectSectionText)))
    (compiler-object-symbol-cons
      (ObjectSymbol
        "_tl_true"
        (ObjectSymbolLocal)
        (ObjectSymbolFunction)
        (ObjectSomeSection (ObjectSectionText)))
      (compiler-object-symbol-cons
        (ObjectSymbol
          "_tl_false"
          (ObjectSymbolLocal)
          (ObjectSymbolFunction)
          (ObjectSomeSection (ObjectSectionText)))
        (compiler-object-symbol-cons
          (ObjectSymbol
            "_tl_done"
            (ObjectSymbolLocal)
            (ObjectSymbolFunction)
            (ObjectSomeSection (ObjectSectionText)))
          (compiler-object-symbol-cons
            (ObjectSymbol
              "_tl_answer"
              (ObjectSymbolExport)
              (ObjectSymbolData)
              (ObjectSomeSection (ObjectSectionData)))
            (compiler-object-symbol-cons
              (ObjectSymbol
                "_tl_slot"
                (ObjectSymbolLocal)
                (ObjectSymbolData)
                (ObjectSomeSection (ObjectSectionData)))
              (compiler-object-symbol-cons
                (ObjectSymbol
                  "foreign_exact"
                  (ObjectSymbolExtern)
                  (ObjectSymbolFunction)
                  (ObjectNoSection))
                ObjectSymbolNil))))))))

(define (compiler-object-coff-text-smoke-relocs) : CompilerObjectRelocationList
  (compiler-object-relocation-cons
    (ObjectRelocation
      (ObjectSectionText)
      "_tl_text"
      (ObjectRelocRipValue)
      "_tl_answer")
    (compiler-object-relocation-cons
      (ObjectRelocation
        (ObjectSectionText)
        "_tl_text"
        (ObjectRelocRipAddress)
        "_tl_slot")
      (compiler-object-relocation-cons
        (ObjectRelocation
          (ObjectSectionText)
          "_tl_text"
          (ObjectRelocRipAddress)
          "_tl_slot")
        (compiler-object-relocation-cons
          (ObjectRelocation
            (ObjectSectionText)
            "_tl_text"
            (ObjectRelocCall)
            "foreign_exact")
          (compiler-object-relocation-cons
            (ObjectRelocation
              (ObjectSectionText)
              "_tl_text"
              (ObjectRelocTailCall)
              "_tl_done")
            (compiler-object-relocation-cons
              (ObjectRelocation
                (ObjectSectionText)
                "_tl_text"
                (ObjectRelocBranch)
                "_tl_done")
              (compiler-object-relocation-cons
                (ObjectRelocation
                  (ObjectSectionText)
                  "_tl_text"
                  (ObjectRelocBranch)
                  "_tl_true")
                (compiler-object-relocation-cons
                  (ObjectRelocation
                    (ObjectSectionText)
                    "_tl_text"
                    (ObjectRelocBranch)
                    "_tl_false")
                  ObjectRelocationNil)))))))))

(define (compiler-object-coff-text-smoke-image) : CompilerObjectImage
  (CompilerObjectImage
    (compiler-object-section-cons
      (ObjectSection
        (ObjectSectionText)
        ObjectDataNil
        (compiler-object-coff-text-smoke-instrs))
      (compiler-object-section-cons
        (ObjectSection
          (ObjectSectionData)
          (compiler-object-data-cons
            (ObjectDataLabel "_tl_answer")
            (compiler-object-data-cons
              (ObjectDataI64 42)
              (compiler-object-data-cons
                (ObjectDataLabel "_tl_slot")
                (compiler-object-data-cons (ObjectDataI64 0) ObjectDataNil))))
          ObjectInstrNil)
        (compiler-object-section-cons
          (ObjectSection (ObjectSectionRodata) ObjectDataNil ObjectInstrNil)
          (compiler-object-section-cons
            (ObjectSection (ObjectSectionBss) ObjectDataNil ObjectInstrNil)
            ObjectSectionNil))))
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
      (and
        (= (compiler-object-coff-u32-at obj (+ entry 4)) symbol-index)
        (= (compiler-object-coff-u16-at obj (+ entry 8)) reloc-type)))))

(define (compiler-object-coff-text-smoke-bytes-ok?
  [obj : String]
  [text-ptr : i64]) : bool
  (and
    (= (compiler-object-coff-u8-at obj text-ptr) 0x48)
    (and
      (= (compiler-object-coff-u8-at obj (+ text-ptr 1)) 0x8b)
      (and
        (= (compiler-object-coff-u8-at obj (+ text-ptr 2)) 0x05)
        (and
          (= (compiler-object-coff-u8-at obj (+ text-ptr 7)) 0x48)
          (and
            (= (compiler-object-coff-u8-at obj (+ text-ptr 8)) 0x8d)
            (and
              (= (compiler-object-coff-u8-at obj (+ text-ptr 14)) 0x48)
              (and
                (= (compiler-object-coff-u8-at obj (+ text-ptr 15)) 0x89)
                (and
                  (= (compiler-object-coff-u8-at obj (+ text-ptr 21)) 0xe8)
                  (and
                    (= (compiler-object-coff-u8-at obj (+ text-ptr 26)) 0xe9)
                    (and
                      (= (compiler-object-coff-u8-at obj (+ text-ptr 31)) 0xe9)
                      (and
                        (=
                          (compiler-object-coff-u8-at obj (+ text-ptr 36))
                          0x48)
                        (and
                          (=
                            (compiler-object-coff-u8-at obj (+ text-ptr 37))
                            0x85)
                          (and
                            (=
                              (compiler-object-coff-u8-at obj (+ text-ptr 38))
                              0xc0)
                            (and
                              (=
                                (compiler-object-coff-u8-at obj (+ text-ptr 39))
                                0x0f)
                              (and
                                (=
                                  (compiler-object-coff-u8-at
                                    obj
                                    (+ text-ptr 40))
                                  0x85)
                                (=
                                  (compiler-object-coff-u8-at
                                    obj
                                    (+ text-ptr 45))
                                  0xe9)))))))))))))))))

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
      (and
        (compiler-object-coff-reloc-entry-ok?
          obj
          reloc-ptr
          1
          10
          (compiler-object-coff-symbol-index image "_tl_slot")
          rel32)
        (and
          (compiler-object-coff-reloc-entry-ok?
            obj
            reloc-ptr
            2
            17
            (compiler-object-coff-symbol-index image "_tl_slot")
            rel32)
          (and
            (compiler-object-coff-reloc-entry-ok?
              obj
              reloc-ptr
              3
              22
              (compiler-object-coff-symbol-index image "foreign_exact")
              rel32)
            (and
              (compiler-object-coff-reloc-entry-ok?
                obj
                reloc-ptr
                4
                27
                (compiler-object-coff-symbol-index image "_tl_done")
                rel32)
              (and
                (compiler-object-coff-reloc-entry-ok?
                  obj
                  reloc-ptr
                  5
                  32
                  (compiler-object-coff-symbol-index image "_tl_done")
                  rel32)
                (and
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
                    rel32))))))))))

(define (compiler-object-coff-text-smoke-ok?) : bool
  (let
    [image : CompilerObjectImage (compiler-object-coff-text-smoke-image)]
    (match (compiler-object-coff-render image)
      [(OkCompilerObjectCoff obj)
        (let
          [text-header : i64
            (compiler-object-coff-section-header-offset (ObjectSectionText))]
          [text-size : i64 (compiler-object-coff-u32-at obj (+ text-header 16))]
          [text-ptr : i64 (compiler-object-coff-u32-at obj (+ text-header 20))]
          [reloc-ptr : i64 (compiler-object-coff-u32-at obj (+ text-header 24))]
          [reloc-count : i64
            (compiler-object-coff-u16-at obj (+ text-header 32))]
          (and
            (= text-size 50)
            (and
              (= text-ptr (compiler-object-coff-header-size))
              (and
                (= reloc-count 8)
                (and
                  (compiler-object-coff-text-smoke-bytes-ok? obj text-ptr)
                  (compiler-object-coff-text-smoke-relocs-ok?
                    image
                    obj
                    reloc-ptr))))))]
      [(ErrCompilerObjectCoff _) false])))