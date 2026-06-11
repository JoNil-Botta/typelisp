;; compiler_object_elf.tl - ELF64 object-file serialization for object images.
(import "compiler_object.tl")

(defenum ResultCompilerObjectElf
  (OkCompilerObjectElf String)
  (ErrCompilerObjectElf String))

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

(define compiler-object-elf-section-count : i64
  12)

(define compiler-object-elf-shstrtab-size : i64
  97)

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

(define (compiler-object-elf-byte [value : i64]) : u8
  (cast (bit-and value 0xff) : u8))

(define (compiler-object-elf-push-u8! [out : (Array u8)] [value : i64]) : unit
  (array-push! out (compiler-object-elf-byte value)))

(define (compiler-object-elf-push-u16! [out : (Array u8)] [value : i64]) : unit
  (begin
    (compiler-object-elf-push-u8! out value)
    (compiler-object-elf-push-u8! out (shr value 8))))

(define (compiler-object-elf-push-u32! [out : (Array u8)] [value : i64]) : unit
  (begin
    (compiler-object-elf-push-u8! out value)
    (compiler-object-elf-push-u8! out (shr value 8))
    (compiler-object-elf-push-u8! out (shr value 16))
    (compiler-object-elf-push-u8! out (shr value 24))))

(define (compiler-object-elf-push-u64! [out : (Array u8)] [value : u64]) : unit
  (begin
    (compiler-object-elf-push-u32!
      out
      (cast (bit-and value (cast 0xffffffff : u64)) : i64))
    (compiler-object-elf-push-u32! out (cast (shr value 32) : i64))))

(define (compiler-object-elf-push-i64! [out : (Array u8)] [value : i64]) : unit
  (compiler-object-elf-push-u64! out (cast value : u64)))

(define (compiler-object-elf-push-zeroes! [out : (Array u8)] [count : i64]) : unit
  (let
    [i : i64 0]
    (begin
      (while (< i count)
        (begin
          (compiler-object-elf-push-u8! out 0)
          (set! i (+ i 1))))
      unit)))

(define (compiler-object-elf-push-string-bytes!
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

(define (compiler-object-elf-align-offset [offset : i64] [align : i64]) : i64
  (if (<= align 1)
    offset
    (let
      [rem : i64 (% offset align)]
      (if (= rem 0)
        offset
        (+ offset (- align rem))))))

(define (compiler-object-elf-render-padding-to!
  [out : (Array u8)]
  [offset : i64]) : unit
  (compiler-object-elf-push-zeroes! out (- offset (array-length out))))

(define (compiler-object-elf-decimal-digit? [c : char]) : bool
  (and (>= (cast c : i64) 48) (<= (cast c : i64) 57)))

(define (compiler-object-elf-decimal-digit-value [c : char]) : i64
  (- (cast c : i64) 48))

(define (compiler-object-elf-f64-value [text : String]) : f64
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [negative : bool false]
    [fraction : bool false]
    [value : f64 0.0]
    [scale : f64 1.0]
    (begin
      (while (< i n)
        (let
          [c : char (string-ref text i)]
          (begin
            (cond
              (= c #-')
              (set! negative true)
              (= c #.')
              (set! fraction true)
              (compiler-object-elf-decimal-digit? c)
              (let
                [digit : f64
                  (cast (compiler-object-elf-decimal-digit-value c) : f64)]
                (if fraction
                  (begin
                    (set! scale (* scale 0.1))
                    (set! value (+ value (* digit scale))))
                  (set! value (+ (* value 10.0) digit))))
              unit)
            (set! i (+ i 1)))))
      (if negative
        (- 0.0 value)
        value))))

(define (compiler-object-elf-f64-bits [text : String]) : u64
  (let
    [buf : (Array f64) (make-array f64 1)]
    (begin
      (array-set! buf 0 (compiler-object-elf-f64-value text))
      (unsafe
        (ptr-read (ptr-cast (array-data buf) : (Ptr u64)))))))

(define (compiler-object-elf-data-record-end-offset
  [record : CompilerObjectDataRecord]
  [offset : i64]) : i64
  (match record
    [(ObjectDataLabel _) offset]
    [(ObjectDataAlign align) (compiler-object-elf-align-offset offset align)]
    [(ObjectDataBytes bytes) (+ offset (string-length bytes))]
    [(ObjectDataString text) (+ offset (+ (string-length text) 1))]
    [(ObjectDataF64 _) (+ offset 8)]
    [(ObjectDataI64 _) (+ offset 8)]
    [(ObjectDataZero count) (+ offset count)]
    [(ObjectDataSymbolAddress _) (+ offset 8)]))

(define (compiler-object-elf-data-records-size-from
  [records : CompilerObjectDataRecordList]
  [offset : i64]) : i64
  (match records
    [(ObjectDataNil) offset]
    [(ObjectDataCons record rest)
      (compiler-object-elf-data-records-size-from
        (box-get rest)
        (compiler-object-elf-data-record-end-offset record offset))]))

(define (compiler-object-elf-data-records-size
  [records : CompilerObjectDataRecordList]) : i64
  (compiler-object-elf-data-records-size-from records 0))

(define (compiler-object-elf-instr-size [instr : CompilerObjectX64Instr]) : i64
  (match instr
    [(ObjectX64Label _) 0]
    [(ObjectX64Raw bytes) (string-length bytes)]
    [_ 0]))

(define (compiler-object-elf-instrs-size-from
  [instrs : CompilerObjectX64InstrList]
  [offset : i64]) : i64
  (match instrs
    [(ObjectInstrNil) offset]
    [(ObjectInstrCons instr rest)
      (compiler-object-elf-instrs-size-from
        (box-get rest)
        (+ offset (compiler-object-elf-instr-size instr)))]))

(define (compiler-object-elf-instrs-size [instrs : CompilerObjectX64InstrList]) : i64
  (compiler-object-elf-instrs-size-from instrs 0))

(define (compiler-object-elf-section-virtual-size
  [image : CompilerObjectImage]
  [kind : CompilerObjectSectionKind]) : i64
  (match (compiler-object-section-list-find (struct-get image sections) kind)
    [(ObjectSection _ data instrs)
      (match kind
        [(ObjectSectionText) (compiler-object-elf-instrs-size instrs)]
        [_ (compiler-object-elf-data-records-size data)])]))

(define (compiler-object-elf-section-raw-size
  [image : CompilerObjectImage]
  [kind : CompilerObjectSectionKind]) : i64
  (match kind
    [(ObjectSectionBss) 0]
    [_ (compiler-object-elf-section-virtual-size image kind)]))

(define (compiler-object-elf-relocation-kind-supported?
  [kind : CompilerObjectRelocationKind]) : bool
  (match kind
    [(ObjectRelocAbs64) true]
    [_ false]))

(define (compiler-object-elf-relocation-list-supported?
  [relocs : CompilerObjectRelocationList]) : bool
  (match relocs
    [(ObjectRelocationNil) true]
    [(ObjectRelocationCons reloc rest)
      (match reloc
        [(ObjectRelocation _ _ kind _)
          (if (compiler-object-elf-relocation-kind-supported? kind)
            (compiler-object-elf-relocation-list-supported? (box-get rest))
            false)])]))

(define (compiler-object-elf-instrs-supported?
  [instrs : CompilerObjectX64InstrList]) : bool
  (match instrs
    [(ObjectInstrNil) true]
    [(ObjectInstrCons instr rest)
      (match instr
        [(ObjectX64Label _)
          (compiler-object-elf-instrs-supported? (box-get rest))]
        [(ObjectX64Raw _)
          (compiler-object-elf-instrs-supported? (box-get rest))]
        [_ false])]))

(define (compiler-object-elf-sections-supported?
  [sections : CompilerObjectSectionList]) : bool
  (match sections
    [(ObjectSectionNil) true]
    [(ObjectSectionCons section rest)
      (match section
        [(ObjectSection _ _ instrs)
          (if (compiler-object-elf-instrs-supported? instrs)
            (compiler-object-elf-sections-supported? (box-get rest))
            false)])]))

(define (compiler-object-elf-symbol-binding-local?
  [binding : CompilerObjectSymbolBinding]) : bool
  (match binding
    [(ObjectSymbolLocal) true]
    [_ false]))

(define (compiler-object-elf-local-symbol-count
  [symbols : CompilerObjectSymbolList]) : i64
  (match symbols
    [(ObjectSymbolNil) 0]
    [(ObjectSymbolCons symbol rest)
      (match symbol
        [(ObjectSymbol _ binding _ _)
          (+
            (if (compiler-object-elf-symbol-binding-local? binding)
              1
              0)
            (compiler-object-elf-local-symbol-count (box-get rest)))])]))

(define (compiler-object-elf-local-symbol-index-from
  [symbols : CompilerObjectSymbolList]
  [name : String]
  [index : i64]) : i64
  (match symbols
    [(ObjectSymbolNil) -1]
    [(ObjectSymbolCons symbol rest)
      (match symbol
        [(ObjectSymbol found binding _ _)
          (if (compiler-object-elf-symbol-binding-local? binding)
            (if (string-eq found name)
              index
              (compiler-object-elf-local-symbol-index-from
                (box-get rest)
                name
                (+ index 1)))
            (compiler-object-elf-local-symbol-index-from
              (box-get rest)
              name
              index))])]))

(define (compiler-object-elf-global-symbol-index-from
  [symbols : CompilerObjectSymbolList]
  [name : String]
  [index : i64]) : i64
  (match symbols
    [(ObjectSymbolNil) -1]
    [(ObjectSymbolCons symbol rest)
      (match symbol
        [(ObjectSymbol found binding _ _)
          (if (compiler-object-elf-symbol-binding-local? binding)
            (compiler-object-elf-global-symbol-index-from
              (box-get rest)
              name
              index)
            (if (string-eq found name)
              index
              (compiler-object-elf-global-symbol-index-from
                (box-get rest)
                name
                (+ index 1))))])]))

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
  (match records
    [(ObjectDataNil) -1]
    [(ObjectDataCons record rest)
      (match record
        [(ObjectDataLabel found)
          (if (string-eq found label)
            offset
            (compiler-object-elf-data-label-offset-from
              (box-get rest)
              label
              offset))]
        [_
          (compiler-object-elf-data-label-offset-from
            (box-get rest)
            label
            (compiler-object-elf-data-record-end-offset record offset))])]))

(define (compiler-object-elf-instr-label-offset-from
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
            (compiler-object-elf-instr-label-offset-from
              (box-get rest)
              label
              offset))]
        [_
          (compiler-object-elf-instr-label-offset-from
            (box-get rest)
            label
            (+ offset (compiler-object-elf-instr-size instr)))])]))

(define (compiler-object-elf-section-label-offset
  [image : CompilerObjectImage]
  [kind : CompilerObjectSectionKind]
  [label : String]) : i64
  (match (compiler-object-section-list-find (struct-get image sections) kind)
    [(ObjectSection _ data instrs)
      (match kind
        [(ObjectSectionText)
          (compiler-object-elf-instr-label-offset-from instrs label 0)]
        [_ (compiler-object-elf-data-label-offset-from data label 0)])]))

(define (compiler-object-elf-relocation-sites-known?
  [image : CompilerObjectImage]
  [relocs : CompilerObjectRelocationList]) : bool
  (match relocs
    [(ObjectRelocationNil) true]
    [(ObjectRelocationCons reloc rest)
      (match reloc
        [(ObjectRelocation section site _ target)
          (if (and
            (>= (compiler-object-elf-section-label-offset image section site) 0)
            (>= (compiler-object-elf-symbol-index image target) 0))
            (compiler-object-elf-relocation-sites-known? image (box-get rest))
            false)])]))

(define (compiler-object-elf-image-supported? [image : CompilerObjectImage]) : bool
  (and
    (compiler-object-elf-sections-supported? (struct-get image sections))
    (compiler-object-elf-relocation-list-supported?
      (struct-get image relocations))
    (compiler-object-elf-relocation-sites-known?
      image
      (struct-get image relocations))))

(define (compiler-object-elf-relocation-count
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
            (compiler-object-elf-relocation-count (box-get rest) kind))])]))

(define (compiler-object-elf-relocation-section-size
  [image : CompilerObjectImage]
  [kind : CompilerObjectSectionKind]) : i64
  (*
    compiler-object-elf-relocation-size
    (compiler-object-elf-relocation-count (struct-get image relocations) kind)))

(define (compiler-object-elf-symbol-table-size [image : CompilerObjectImage]) : i64
  (*
    compiler-object-elf-symbol-size
    (+ 1 (compiler-object-symbol-list-count (struct-get image symbols)))))

(define (compiler-object-elf-string-table-size-from
  [symbols : CompilerObjectSymbolList]
  [size : i64]) : i64
  (match symbols
    [(ObjectSymbolNil) size]
    [(ObjectSymbolCons symbol rest)
      (match symbol
        [(ObjectSymbol name _ _ _)
          (compiler-object-elf-string-table-size-from
            (box-get rest)
            (+ size (+ (string-length name) 1)))])]))

(define (compiler-object-elf-string-table-size
  [symbols : CompilerObjectSymbolList]) : i64
  (compiler-object-elf-string-table-size-from symbols 1))

(define (compiler-object-elf-push-shstrtab-name!
  [out : (Array u8)]
  [name : String]) : unit
  (begin
    (compiler-object-elf-push-string-bytes! out name)
    (compiler-object-elf-push-u8! out 0)))

(define (compiler-object-elf-push-shstrtab! [out : (Array u8)]) : unit
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
    (compiler-object-elf-push-shstrtab-name! out ".shstrtab")))

(define (compiler-object-elf-text-offset [image : CompilerObjectImage]) : i64
  (compiler-object-elf-align-offset compiler-object-elf-header-size 16))

(define (compiler-object-elf-data-offset [image : CompilerObjectImage]) : i64
  (compiler-object-elf-align-offset
    (+
      (compiler-object-elf-text-offset image)
      (compiler-object-elf-section-raw-size image (ObjectSectionText)))
    8))

(define (compiler-object-elf-rodata-offset [image : CompilerObjectImage]) : i64
  (compiler-object-elf-align-offset
    (+
      (compiler-object-elf-data-offset image)
      (compiler-object-elf-section-raw-size image (ObjectSectionData)))
    8))

(define (compiler-object-elf-bss-offset [image : CompilerObjectImage]) : i64
  (compiler-object-elf-align-offset
    (+
      (compiler-object-elf-rodata-offset image)
      (compiler-object-elf-section-raw-size image (ObjectSectionRodata)))
    8))

(define (compiler-object-elf-rela-text-offset [image : CompilerObjectImage]) : i64
  (compiler-object-elf-align-offset (compiler-object-elf-bss-offset image) 8))

(define (compiler-object-elf-rela-data-offset [image : CompilerObjectImage]) : i64
  (compiler-object-elf-align-offset
    (+
      (compiler-object-elf-rela-text-offset image)
      (compiler-object-elf-relocation-section-size image (ObjectSectionText)))
    8))

(define (compiler-object-elf-rela-rodata-offset [image : CompilerObjectImage]) : i64
  (compiler-object-elf-align-offset
    (+
      (compiler-object-elf-rela-data-offset image)
      (compiler-object-elf-relocation-section-size image (ObjectSectionData)))
    8))

(define (compiler-object-elf-rela-bss-offset [image : CompilerObjectImage]) : i64
  (compiler-object-elf-align-offset
    (+
      (compiler-object-elf-rela-rodata-offset image)
      (compiler-object-elf-relocation-section-size image (ObjectSectionRodata)))
    8))

(define (compiler-object-elf-symtab-offset [image : CompilerObjectImage]) : i64
  (compiler-object-elf-align-offset
    (+
      (compiler-object-elf-rela-bss-offset image)
      (compiler-object-elf-relocation-section-size image (ObjectSectionBss)))
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
    [(ObjectSectionText) compiler-object-elf-section-text-index]
    [(ObjectSectionData) compiler-object-elf-section-data-index]
    [(ObjectSectionRodata) compiler-object-elf-section-rodata-index]
    [(ObjectSectionBss) compiler-object-elf-section-bss-index]))

(define (compiler-object-elf-section-file-offset
  [image : CompilerObjectImage]
  [kind : CompilerObjectSectionKind]) : i64
  (match kind
    [(ObjectSectionText) (compiler-object-elf-text-offset image)]
    [(ObjectSectionData) (compiler-object-elf-data-offset image)]
    [(ObjectSectionRodata) (compiler-object-elf-rodata-offset image)]
    [(ObjectSectionBss) (compiler-object-elf-bss-offset image)]))

(define (compiler-object-elf-relocation-section-offset
  [image : CompilerObjectImage]
  [kind : CompilerObjectSectionKind]) : i64
  (match kind
    [(ObjectSectionText) (compiler-object-elf-rela-text-offset image)]
    [(ObjectSectionData) (compiler-object-elf-rela-data-offset image)]
    [(ObjectSectionRodata) (compiler-object-elf-rela-rodata-offset image)]
    [(ObjectSectionBss) (compiler-object-elf-rela-bss-offset image)]))

(define (compiler-object-elf-section-name-offset [index : i64]) : i64
  (cond
    (= index compiler-object-elf-section-text-index)
    1
    (= index compiler-object-elf-section-data-index)
    7
    (= index compiler-object-elf-section-rodata-index)
    13
    (= index compiler-object-elf-section-bss-index)
    21
    (= index compiler-object-elf-section-rela-text-index)
    26
    (= index compiler-object-elf-section-rela-data-index)
    37
    (= index compiler-object-elf-section-rela-rodata-index)
    48
    (= index compiler-object-elf-section-rela-bss-index)
    61
    (= index compiler-object-elf-section-symtab-index)
    71
    (= index compiler-object-elf-section-strtab-index)
    79
    (= index compiler-object-elf-section-shstrtab-index)
    87
    0))

(define (compiler-object-elf-push-header!
  [out : (Array u8)]
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
  [out : (Array u8)]
  [record : CompilerObjectDataRecord]
  [offset : i64]) : i64
  (match record
    [(ObjectDataLabel _) offset]
    [(ObjectDataAlign align)
      (let
        [aligned : i64 (compiler-object-elf-align-offset offset align)]
        (begin
          (compiler-object-elf-push-zeroes! out (- aligned offset))
          aligned))]
    [(ObjectDataBytes bytes)
      (begin
        (compiler-object-elf-push-string-bytes! out bytes)
        (+ offset (string-length bytes)))]
    [(ObjectDataString text)
      (begin
        (compiler-object-elf-push-string-bytes! out text)
        (compiler-object-elf-push-u8! out 0)
        (+ offset (+ (string-length text) 1)))]
    [(ObjectDataF64 text)
      (begin
        (compiler-object-elf-push-u64! out (compiler-object-elf-f64-bits text))
        (+ offset 8))]
    [(ObjectDataI64 value)
      (begin
        (compiler-object-elf-push-i64! out value)
        (+ offset 8))]
    [(ObjectDataZero count)
      (begin
        (compiler-object-elf-push-zeroes! out count)
        (+ offset count))]
    [(ObjectDataSymbolAddress _)
      (begin
        (compiler-object-elf-push-i64! out 0)
        (+ offset 8))]))

(define (compiler-object-elf-render-data-records!
  [out : (Array u8)]
  [records : CompilerObjectDataRecordList]
  [offset : i64]) : i64
  (match records
    [(ObjectDataNil) offset]
    [(ObjectDataCons record rest)
      (compiler-object-elf-render-data-records!
        out
        (box-get rest)
        (compiler-object-elf-render-data-record! out record offset))]))

(define (compiler-object-elf-render-instr!
  [out : (Array u8)]
  [instr : CompilerObjectX64Instr]) : unit
  (match instr
    [(ObjectX64Label _) unit]
    [(ObjectX64Raw bytes) (compiler-object-elf-push-string-bytes! out bytes)]
    [_ unit]))

(define (compiler-object-elf-render-instrs!
  [out : (Array u8)]
  [instrs : CompilerObjectX64InstrList]) : unit
  (match instrs
    [(ObjectInstrNil) unit]
    [(ObjectInstrCons instr rest)
      (begin
        (compiler-object-elf-render-instr! out instr)
        (compiler-object-elf-render-instrs! out (box-get rest)))]))

(define (compiler-object-elf-render-section!
  [out : (Array u8)]
  [image : CompilerObjectImage]
  [kind : CompilerObjectSectionKind]) : unit
  (match (compiler-object-section-list-find (struct-get image sections) kind)
    [(ObjectSection _ data instrs)
      (match kind
        [(ObjectSectionText) (compiler-object-elf-render-instrs! out instrs)]
        [_
          (begin
            (compiler-object-elf-render-data-records! out data 0)
            unit)])]))

(define (compiler-object-elf-render-loadable-sections!
  [out : (Array u8)]
  [image : CompilerObjectImage]) : unit
  (begin
    (compiler-object-elf-render-padding-to!
      out
      (compiler-object-elf-text-offset image))
    (compiler-object-elf-render-section! out image (ObjectSectionText))
    (compiler-object-elf-render-padding-to!
      out
      (compiler-object-elf-data-offset image))
    (compiler-object-elf-render-section! out image (ObjectSectionData))
    (compiler-object-elf-render-padding-to!
      out
      (compiler-object-elf-rodata-offset image))
    (compiler-object-elf-render-section! out image (ObjectSectionRodata))))

(define (compiler-object-elf-relocation-type
  [kind : CompilerObjectRelocationKind]) : i64
  (match kind
    [(ObjectRelocAbs64) compiler-object-elf-r-x86-64-64]
    [_ 0]))

(define (compiler-object-elf-render-relocation!
  [out : (Array u8)]
  [image : CompilerObjectImage]
  [reloc : CompilerObjectRelocation]) : unit
  (match reloc
    [(ObjectRelocation section site kind target)
      (begin
        (compiler-object-elf-push-i64!
          out
          (compiler-object-elf-section-label-offset image section site))
        (compiler-object-elf-push-i64!
          out
          (bit-or
            (shl (compiler-object-elf-symbol-index image target) 32)
            (compiler-object-elf-relocation-type kind)))
        (compiler-object-elf-push-i64! out 0))]))

(define (compiler-object-elf-render-relocations-for-section!
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
              (compiler-object-elf-render-relocation! out image reloc)
              unit)])
        (compiler-object-elf-render-relocations-for-section!
          out
          image
          (box-get rest)
          kind))]))

(define (compiler-object-elf-render-relocation-section!
  [out : (Array u8)]
  [image : CompilerObjectImage]
  [kind : CompilerObjectSectionKind]) : unit
  (begin
    (compiler-object-elf-render-padding-to!
      out
      (compiler-object-elf-relocation-section-offset image kind))
    (compiler-object-elf-render-relocations-for-section!
      out
      image
      (struct-get image relocations)
      kind)))

(define (compiler-object-elf-symbol-string-offset-from
  [symbols : CompilerObjectSymbolList]
  [name : String]
  [offset : i64]) : i64
  (match symbols
    [(ObjectSymbolNil) 0]
    [(ObjectSymbolCons symbol rest)
      (match symbol
        [(ObjectSymbol found _ _ _)
          (if (string-eq found name)
            offset
            (compiler-object-elf-symbol-string-offset-from
              (box-get rest)
              name
              (+ offset (+ (string-length found) 1))))])]))

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
    [(ObjectSymbolLocal) 0]
    [_ 1]))

(define (compiler-object-elf-symbol-type [kind : CompilerObjectSymbolKind]) : i64
  (match kind
    [(ObjectSymbolFunction) 2]
    [(ObjectSymbolRuntime) 2]
    [(ObjectSymbolData) 1]
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
    [(ObjectNoSection) 0]
    [(ObjectSomeSection kind) (compiler-object-elf-section-index kind)]))

(define (compiler-object-elf-symbol-value
  [image : CompilerObjectImage]
  [name : String]
  [section : CompilerObjectMaybeSection]) : i64
  (match section
    [(ObjectNoSection) 0]
    [(ObjectSomeSection kind)
      (let
        [offset : i64
          (compiler-object-elf-section-label-offset image kind name)]
        (if (< offset 0)
          0
          offset))]))

(define (compiler-object-elf-render-null-symbol! [out : (Array u8)]) : unit
  (compiler-object-elf-push-zeroes! out compiler-object-elf-symbol-size))

(define (compiler-object-elf-render-symbol!
  [out : (Array u8)]
  [image : CompilerObjectImage]
  [symbol : CompilerObjectSymbol]) : unit
  (match symbol
    [(ObjectSymbol name binding kind section)
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
  [out : (Array u8)]
  [image : CompilerObjectImage]
  [symbols : CompilerObjectSymbolList]
  [want-local : bool]) : unit
  (match symbols
    [(ObjectSymbolNil) unit]
    [(ObjectSymbolCons symbol rest)
      (begin
        (match symbol
          [(ObjectSymbol _ binding _ _)
            (if (=
              (compiler-object-elf-symbol-binding-local? binding)
              want-local)
              (compiler-object-elf-render-symbol! out image symbol)
              unit)])
        (compiler-object-elf-render-symbols-by-locality!
          out
          image
          (box-get rest)
          want-local))]))

(define (compiler-object-elf-render-symbol-table!
  [out : (Array u8)]
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
  [out : (Array u8)]
  [symbols : CompilerObjectSymbolList]) : unit
  (match symbols
    [(ObjectSymbolNil) unit]
    [(ObjectSymbolCons symbol rest)
      (begin
        (match symbol
          [(ObjectSymbol name _ _ _)
            (begin
              (compiler-object-elf-push-string-bytes! out name)
              (compiler-object-elf-push-u8! out 0))])
        (compiler-object-elf-render-string-table-symbols! out (box-get rest)))]))

(define (compiler-object-elf-render-string-tables!
  [out : (Array u8)]
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
    [(ObjectSectionText)
      (bit-or compiler-object-elf-shf-alloc compiler-object-elf-shf-execinstr)]
    [(ObjectSectionData)
      (bit-or compiler-object-elf-shf-alloc compiler-object-elf-shf-write)]
    [(ObjectSectionRodata) compiler-object-elf-shf-alloc]
    [(ObjectSectionBss)
      (bit-or compiler-object-elf-shf-alloc compiler-object-elf-shf-write)]))

(define (compiler-object-elf-push-section-header!
  [out : (Array u8)]
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
  [out : (Array u8)]
  [image : CompilerObjectImage]
  [kind : CompilerObjectSectionKind]) : unit
  (let
    [index : i64 (compiler-object-elf-section-index kind)]
    (compiler-object-elf-push-section-header!
      out
      (compiler-object-elf-section-name-offset index)
      (match kind
        [(ObjectSectionBss) compiler-object-elf-sht-nobits]
        [_ compiler-object-elf-sht-progbits])
      (compiler-object-elf-section-flags kind)
      0
      (compiler-object-elf-section-file-offset image kind)
      (compiler-object-elf-section-virtual-size image kind)
      0
      0
      (match kind
        [(ObjectSectionText) 16]
        [_ 8])
      0)))

(define (compiler-object-elf-rela-section-index
  [kind : CompilerObjectSectionKind]) : i64
  (match kind
    [(ObjectSectionText) compiler-object-elf-section-rela-text-index]
    [(ObjectSectionData) compiler-object-elf-section-rela-data-index]
    [(ObjectSectionRodata) compiler-object-elf-section-rela-rodata-index]
    [(ObjectSectionBss) compiler-object-elf-section-rela-bss-index]))

(define (compiler-object-elf-push-rela-section-header!
  [out : (Array u8)]
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
  [out : (Array u8)]
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
      (ObjectSectionText))
    (compiler-object-elf-push-load-section-header!
      out
      image
      (ObjectSectionData))
    (compiler-object-elf-push-load-section-header!
      out
      image
      (ObjectSectionRodata))
    (compiler-object-elf-push-load-section-header! out image (ObjectSectionBss))
    (compiler-object-elf-push-rela-section-header!
      out
      image
      (ObjectSectionText))
    (compiler-object-elf-push-rela-section-header!
      out
      image
      (ObjectSectionData))
    (compiler-object-elf-push-rela-section-header!
      out
      image
      (ObjectSectionRodata))
    (compiler-object-elf-push-rela-section-header! out image (ObjectSectionBss))
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
      0)))

(define (compiler-object-elf-bytes-string [bytes : (Array u8)]) : String
  (unsafe
    (string-from-bytes
      (ptr-cast (array-data bytes) : (Ptr u8))
      (array-length bytes))))

(define (compiler-object-elf-render [image : CompilerObjectImage]) : ResultCompilerObjectElf
  (if (compiler-object-elf-image-supported? image)
    (let
      [out : (Array u8) (make-array u8 0)]
      (begin
        (compiler-object-elf-push-header! out image)
        (compiler-object-elf-render-loadable-sections! out image)
        (compiler-object-elf-render-relocation-section!
          out
          image
          (ObjectSectionText))
        (compiler-object-elf-render-relocation-section!
          out
          image
          (ObjectSectionData))
        (compiler-object-elf-render-relocation-section!
          out
          image
          (ObjectSectionRodata))
        (compiler-object-elf-render-relocation-section!
          out
          image
          (ObjectSectionBss))
        (compiler-object-elf-render-symbol-table! out image)
        (compiler-object-elf-render-string-tables! out image)
        (compiler-object-elf-push-section-headers! out image)
        (OkCompilerObjectElf (compiler-object-elf-bytes-string out))))
    (ErrCompilerObjectElf
      "elf: object image contains unsupported text instructions or relocation records")))

(define (compiler-object-elf-u16-at [text : String] [offset : i64]) : i64
  (+
    (cast (string-ref text offset) : i64)
    (shl (cast (string-ref text (+ offset 1)) : i64) 8)))

(define (compiler-object-elf-u32-at [text : String] [offset : i64]) : i64
  (+
    (compiler-object-elf-u16-at text offset)
    (shl (compiler-object-elf-u16-at text (+ offset 2)) 16)))

(define (compiler-object-elf-prefix-at?
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

(define (compiler-object-elf-contains? [text : String] [needle : String]) : bool
  (let
    [i : i64 0]
    [n : i64 (string-length text)]
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
    [out : (Array u8) (make-array u8 0)]
    (begin
      (compiler-object-elf-push-u8! out 0xc3)
      (compiler-object-elf-bytes-string out))))

(define (compiler-object-elf-smoke-image) : CompilerObjectImage
  (CompilerObjectImage
    (compiler-object-section-cons
      (ObjectSection
        (ObjectSectionText)
        ObjectDataNil
        (compiler-object-instr-cons
          (ObjectX64Label "_tl_empty")
          (compiler-object-instr-cons
            (ObjectX64Raw (compiler-object-elf-ret-bytes))
            ObjectInstrNil)))
      (compiler-object-section-cons
        (ObjectSection
          (ObjectSectionData)
          (compiler-object-data-cons
            (ObjectDataLabel "_tl_cell")
            (compiler-object-data-cons
              (ObjectDataSymbolAddress "_tl_message")
              (compiler-object-data-cons (ObjectDataI64 99) ObjectDataNil)))
          ObjectInstrNil)
        (compiler-object-section-cons
          (ObjectSection
            (ObjectSectionRodata)
            (compiler-object-data-cons
              (ObjectDataLabel "_tl_message")
              (compiler-object-data-cons
                (ObjectDataString "ok")
                (compiler-object-data-cons
                  (ObjectDataAlign 8)
                  (compiler-object-data-cons
                    (ObjectDataLabel "_tl_pi")
                    (compiler-object-data-cons
                      (ObjectDataF64 "3.5")
                      ObjectDataNil)))))
            ObjectInstrNil)
          (compiler-object-section-cons
            (ObjectSection
              (ObjectSectionBss)
              (compiler-object-data-cons
                (ObjectDataLabel "_tl_zero")
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
          "_tl_cell"
          (ObjectSymbolExport)
          (ObjectSymbolData)
          (ObjectSomeSection (ObjectSectionData)))
        (compiler-object-symbol-cons
          (ObjectSymbol
            "_tl_message"
            (ObjectSymbolLocal)
            (ObjectSymbolData)
            (ObjectSomeSection (ObjectSectionRodata)))
          (compiler-object-symbol-cons
            (ObjectSymbol
              "_tl_zero"
              (ObjectSymbolExport)
              (ObjectSymbolData)
              (ObjectSomeSection (ObjectSectionBss)))
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
        "_tl_cell"
        (ObjectRelocAbs64)
        "_tl_message")
      ObjectRelocationNil)))

(define (compiler-object-elf-smoke-ok?) : bool
  (match (compiler-object-elf-render (compiler-object-elf-smoke-image))
    [(OkCompilerObjectElf obj)
      (and
        (=
          (string-length obj)
          (+
            (compiler-object-elf-section-header-offset
              (compiler-object-elf-smoke-image))
            (*
              compiler-object-elf-section-header-size
              compiler-object-elf-section-count)))
        (= (cast (string-ref obj 0) : i64) 0x7f)
        (= (cast (string-ref obj 1) : i64) 0x45)
        (= (compiler-object-elf-u16-at obj 18) 62)
        (=
          (compiler-object-elf-u16-at obj 58)
          compiler-object-elf-section-header-size)
        (=
          (compiler-object-elf-u16-at obj 60)
          compiler-object-elf-section-count)
        (compiler-object-elf-contains? obj ".rela.data")
        (compiler-object-elf-contains? obj "_tl_message")
        (compiler-object-elf-contains? obj "foreign_exact"))]
    [(ErrCompilerObjectElf _) false]))