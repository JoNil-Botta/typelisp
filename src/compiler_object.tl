;; compiler_object.tl - Structured object-image records for backend object emitters.
(import stdlib.string)
(import stdlib.vector)

(defenum CompilerObjectSectionKind
  (Text)
  (Data)
  (Rodata)
  (Bss)
  (Pdata)
  (Xdata)
  (Rsrc))

(defenum CompilerObjectMaybeSection
  (No)
  (Some CompilerObjectSectionKind))

(defenum CompilerObjectSymbolBinding
  (Local)
  (Export)
  (Extern))

(defenum CompilerObjectSymbolKind
  (Function)
  (Data)
  (Section)
  (Runtime))

(defenum CompilerObjectRelocationKind
  (Call)
  (TailCall)
  (Abs64)
  (Addr32Nb)
  (RipValue)
  (RipAddress)
  (Branch))

(defenum CompilerObjectDataRecord
  (Label String)
  (Align i64)
  (Bytes String)
  (String String)
  (F64 u64)
  (F32 u64)
  (I64 i64)
  (Zero i64)
  (SymbolAddress String)
  (SymbolRva32 String))

(import (vector.vector CompilerObjectDataRecord core) as data_record_vec)

(defstruct CompilerObjectDataRecordList
  (items data_record_vec.Vec))

(defenum CompilerObjectX64Instr
  (Label String)
  (Call String)
  (TailCall String)
  (Jump String)
  (Ja String)
  (Branch String String)
  (LoadRip String)
  (LoadRipAddress String)
  (LoadRipAddressR11 String)
  (StoreRip String)
  (SubRspImm8 i64)
  (MovRcxRip String)
  (MovRdxRip String)
  (LoadRipAddressRdx String)
  (StoreR14Rip String)
  (StoreR15Rip String)
  (AddRcxRip String)
  (MovRcxRax)
  (XorpdRip String)
  (Bytes String)
  (Raw String))

(import (vector.vector CompilerObjectX64Instr core) as x64_instr_vec)

(defstruct CompilerObjectX64InstrList
  (items x64_instr_vec.Vec))

(defenum CompilerObjectSymbol
  (Symbol
    String
    CompilerObjectSymbolBinding
    CompilerObjectSymbolKind
    CompilerObjectMaybeSection))

(import (vector.vector CompilerObjectSymbol core) as symbol_vec)

(defstruct CompilerObjectSymbolList
  (items symbol_vec.Vec))

(defenum CompilerObjectRelocation
  (Relocation
    CompilerObjectSectionKind
    String
    CompilerObjectRelocationKind
    String))

(import (vector.vector CompilerObjectRelocation core) as relocation_vec)

(defstruct CompilerObjectRelocationList
  (items relocation_vec.Vec))

(defenum CompilerObjectSection
  (Section
    CompilerObjectSectionKind
    CompilerObjectDataRecordList
    CompilerObjectX64InstrList))

(import (vector.vector CompilerObjectSection core) as section_vec)

(defstruct CompilerObjectSectionList
  (items section_vec.Vec))

(defstruct CompilerObjectImage
  (sections CompilerObjectSectionList)
  (symbols CompilerObjectSymbolList)
  (relocations CompilerObjectRelocationList))

(defstruct CompilerObjectDataRecordBuilder
  (items data_record_vec.Vec))

(defstruct CompilerObjectX64InstrBuilder
  (items x64_instr_vec.Vec))

(defstruct CompilerObjectSymbolBuilder
  (items symbol_vec.Vec))

(defstruct CompilerObjectRelocationBuilder
  (items relocation_vec.Vec))

(defstruct CompilerObjectSectionBuilder
  (items section_vec.Vec))

(define (compiler-object-data-record-builder-with-capacity [capacity : i64]) : CompilerObjectDataRecordBuilder
  (CompilerObjectDataRecordBuilder (data_record_vec.with-capacity capacity)))

(define (compiler-object-data-record-builder-new) : CompilerObjectDataRecordBuilder
  (compiler-object-data-record-builder-with-capacity 16))

(define (compiler-object-instr-builder-with-capacity [capacity : i64]) : CompilerObjectX64InstrBuilder
  (CompilerObjectX64InstrBuilder (x64_instr_vec.with-capacity capacity)))

(define (compiler-object-instr-builder-new) : CompilerObjectX64InstrBuilder
  (compiler-object-instr-builder-with-capacity 16))

(define (compiler-object-symbol-builder-with-capacity [capacity : i64]) : CompilerObjectSymbolBuilder
  (CompilerObjectSymbolBuilder (symbol_vec.with-capacity capacity)))

(define (compiler-object-symbol-builder-new) : CompilerObjectSymbolBuilder
  (compiler-object-symbol-builder-with-capacity 16))

(define (compiler-object-relocation-builder-with-capacity [capacity : i64]) : CompilerObjectRelocationBuilder
  (CompilerObjectRelocationBuilder (relocation_vec.with-capacity capacity)))

(define (compiler-object-relocation-builder-new) : CompilerObjectRelocationBuilder
  (compiler-object-relocation-builder-with-capacity 16))

(define (compiler-object-section-builder-with-capacity [capacity : i64]) : CompilerObjectSectionBuilder
  (CompilerObjectSectionBuilder (section_vec.with-capacity capacity)))

(define (compiler-object-section-builder-new) : CompilerObjectSectionBuilder
  (compiler-object-section-builder-with-capacity 8))

(define (compiler-object-data-record-builder-push
  [builder : CompilerObjectDataRecordBuilder]
  [record : CompilerObjectDataRecord]) : CompilerObjectDataRecordBuilder
  (begin
    (data_record_vec.push (&mut (struct-get builder items)) record)
    builder))

(define (compiler-object-instr-builder-push
  [builder : CompilerObjectX64InstrBuilder]
  [instr : CompilerObjectX64Instr]) : CompilerObjectX64InstrBuilder
  (begin
    (x64_instr_vec.push (&mut (struct-get builder items)) instr)
    builder))

(define (compiler-object-symbol-builder-push
  [builder : CompilerObjectSymbolBuilder]
  [symbol : CompilerObjectSymbol]) : CompilerObjectSymbolBuilder
  (begin
    (symbol_vec.push (&mut (struct-get builder items)) symbol)
    builder))

(define (compiler-object-relocation-builder-push
  [builder : CompilerObjectRelocationBuilder]
  [reloc : CompilerObjectRelocation]) : CompilerObjectRelocationBuilder
  (begin
    (relocation_vec.push (&mut (struct-get builder items)) reloc)
    builder))

(define (compiler-object-section-builder-push
  [builder : CompilerObjectSectionBuilder]
  [section : CompilerObjectSection]) : CompilerObjectSectionBuilder
  (begin
    (section_vec.push (&mut (struct-get builder items)) section)
    builder))

(define (compiler-object-data-record-builder-finish
  [builder : CompilerObjectDataRecordBuilder]) : CompilerObjectDataRecordList
  (CompilerObjectDataRecordList (struct-get builder items)))

(define (compiler-object-instr-builder-finish
  [builder : CompilerObjectX64InstrBuilder]) : CompilerObjectX64InstrList
  (CompilerObjectX64InstrList (struct-get builder items)))

(define (compiler-object-symbol-builder-finish
  [builder : CompilerObjectSymbolBuilder]) : CompilerObjectSymbolList
  (CompilerObjectSymbolList (struct-get builder items)))

(define (compiler-object-relocation-builder-finish
  [builder : CompilerObjectRelocationBuilder]) : CompilerObjectRelocationList
  (CompilerObjectRelocationList (struct-get builder items)))

(define (compiler-object-section-builder-finish
  [builder : CompilerObjectSectionBuilder]) : CompilerObjectSectionList
  (CompilerObjectSectionList (struct-get builder items)))

(define (compiler-object-symbol-builder-contains?
  [builder : CompilerObjectSymbolBuilder]
  [name : String]
  [binding : CompilerObjectSymbolBinding]
  [kind : CompilerObjectSymbolKind]) : bool
  (compiler-object-symbol-list-contains?
    (compiler-object-symbol-builder-finish builder)
    name
    binding
    kind))

(define (compiler-object-section-kind-eq?
  [a : CompilerObjectSectionKind]
  [b : CompilerObjectSectionKind]) : bool
  (match a
    [(CompilerObjectSectionKind.Text)
      (match b
        [(CompilerObjectSectionKind.Text) true]
        [_ false])]
    [(CompilerObjectSectionKind.Data)
      (match b
        [(CompilerObjectSectionKind.Data) true]
        [_ false])]
    [(CompilerObjectSectionKind.Rodata)
      (match b
        [(CompilerObjectSectionKind.Rodata) true]
        [_ false])]
    [(CompilerObjectSectionKind.Bss)
      (match b
        [(CompilerObjectSectionKind.Bss) true]
        [_ false])]
    [(CompilerObjectSectionKind.Pdata)
      (match b
        [(CompilerObjectSectionKind.Pdata) true]
        [_ false])]
    [(CompilerObjectSectionKind.Xdata)
      (match b
        [(CompilerObjectSectionKind.Xdata) true]
        [_ false])]
    [(CompilerObjectSectionKind.Rsrc)
      (match b
        [(CompilerObjectSectionKind.Rsrc) true]
        [_ false])]))

(define (compiler-object-symbol-binding-eq?
  [a : CompilerObjectSymbolBinding]
  [b : CompilerObjectSymbolBinding]) : bool
  (match a
    [(CompilerObjectSymbolBinding.Local)
      (match b
        [(CompilerObjectSymbolBinding.Local) true]
        [_ false])]
    [(CompilerObjectSymbolBinding.Export)
      (match b
        [(CompilerObjectSymbolBinding.Export) true]
        [_ false])]
    [(CompilerObjectSymbolBinding.Extern)
      (match b
        [(CompilerObjectSymbolBinding.Extern) true]
        [_ false])]))

(define (compiler-object-symbol-kind-eq?
  [a : CompilerObjectSymbolKind]
  [b : CompilerObjectSymbolKind]) : bool
  (match a
    [(CompilerObjectSymbolKind.Function)
      (match b
        [(CompilerObjectSymbolKind.Function) true]
        [_ false])]
    [(CompilerObjectSymbolKind.Data)
      (match b
        [(CompilerObjectSymbolKind.Data) true]
        [_ false])]
    [(CompilerObjectSymbolKind.Section)
      (match b
        [(CompilerObjectSymbolKind.Section) true]
        [_ false])]
    [(CompilerObjectSymbolKind.Runtime)
      (match b
        [(CompilerObjectSymbolKind.Runtime) true]
        [_ false])]))

(define (compiler-object-relocation-kind-eq?
  [a : CompilerObjectRelocationKind]
  [b : CompilerObjectRelocationKind]) : bool
  (match a
    [(CompilerObjectRelocationKind.Call)
      (match b
        [(CompilerObjectRelocationKind.Call) true]
        [_ false])]
    [(CompilerObjectRelocationKind.TailCall)
      (match b
        [(CompilerObjectRelocationKind.TailCall) true]
        [_ false])]
    [(CompilerObjectRelocationKind.Abs64)
      (match b
        [(CompilerObjectRelocationKind.Abs64) true]
        [_ false])]
    [(CompilerObjectRelocationKind.Addr32Nb)
      (match b
        [(CompilerObjectRelocationKind.Addr32Nb) true]
        [_ false])]
    [(CompilerObjectRelocationKind.RipValue)
      (match b
        [(CompilerObjectRelocationKind.RipValue) true]
        [_ false])]
    [(CompilerObjectRelocationKind.RipAddress)
      (match b
        [(CompilerObjectRelocationKind.RipAddress) true]
        [_ false])]
    [(CompilerObjectRelocationKind.Branch)
      (match b
        [(CompilerObjectRelocationKind.Branch) true]
        [_ false])]))

(define (compiler-object-symbol-list-count [symbols : CompilerObjectSymbolList]) : i64
  (symbol_vec.len (& (struct-get symbols items))))

(define (compiler-object-symbol-list-ref
  [symbols : CompilerObjectSymbolList]
  [index : i64]) : CompilerObjectSymbol
  (array-ref (symbol_vec.slots (& (struct-get symbols items))) index))

(define (compiler-object-relocation-list-count
  [relocs : CompilerObjectRelocationList]) : i64
  (relocation_vec.len (& (struct-get relocs items))))

(define (compiler-object-relocation-list-ref
  [relocs : CompilerObjectRelocationList]
  [index : i64]) : CompilerObjectRelocation
  (array-ref (relocation_vec.slots (& (struct-get relocs items))) index))

(define (compiler-object-data-record-list-count
  [records : CompilerObjectDataRecordList]) : i64
  (data_record_vec.len (& (struct-get records items))))

(define (compiler-object-data-record-list-ref
  [records : CompilerObjectDataRecordList]
  [index : i64]) : CompilerObjectDataRecord
  (array-ref (data_record_vec.slots (& (struct-get records items))) index))

(define (compiler-object-instr-list-count [instrs : CompilerObjectX64InstrList]) : i64
  (x64_instr_vec.len (& (struct-get instrs items))))

(define (compiler-object-instr-list-ref
  [instrs : CompilerObjectX64InstrList]
  [index : i64]) : CompilerObjectX64Instr
  (array-ref (x64_instr_vec.slots (& (struct-get instrs items))) index))

(define (compiler-object-section-list-count
  [sections : CompilerObjectSectionList]) : i64
  (section_vec.len (& (struct-get sections items))))

(define (compiler-object-section-list-ref
  [sections : CompilerObjectSectionList]
  [index : i64]) : CompilerObjectSection
  (array-ref (section_vec.slots (& (struct-get sections items))) index))

(define (compiler-object-image-dense? [_image : CompilerObjectImage]) : bool
  true)

(define (compiler-object-section-list-find
  [sections : CompilerObjectSectionList]
  [kind : CompilerObjectSectionKind]) : CompilerObjectSection
  (let
    [count : i64 (compiler-object-section-list-count sections)]
    [index : i64 0]
    [result : CompilerObjectSection
      (CompilerObjectSection.Section
        kind
        (CompilerObjectDataRecordList (data_record_vec.new))
        (CompilerObjectX64InstrList (x64_instr_vec.new)))]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (let
          [section : CompilerObjectSection
            (compiler-object-section-list-ref sections index)]
          (match section
            [(CompilerObjectSection.Section found-kind _ _)
              (if (compiler-object-section-kind-eq? found-kind kind)
                (begin
                  (set! result section)
                  (set! found true))
                (set! index (+ index 1)))])))
      result)))

(define (compiler-object-section-data-count
  [sections : CompilerObjectSectionList]
  [kind : CompilerObjectSectionKind]) : i64
  (match (compiler-object-section-list-find sections kind)
    [(CompilerObjectSection.Section _ data _)
      (compiler-object-data-record-list-count data)]))

(define (compiler-object-section-instr-count
  [sections : CompilerObjectSectionList]
  [kind : CompilerObjectSectionKind]) : i64
  (match (compiler-object-section-list-find sections kind)
    [(CompilerObjectSection.Section _ _ instrs)
      (compiler-object-instr-list-count instrs)]))

(define (compiler-object-symbol-list-contains?
  [symbols : CompilerObjectSymbolList]
  [name : String]
  [binding : CompilerObjectSymbolBinding]
  [kind : CompilerObjectSymbolKind]) : bool
  (let
    [count : i64 (compiler-object-symbol-list-count symbols)]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (match (compiler-object-symbol-list-ref symbols index)
          [(CompilerObjectSymbol.Symbol found-name found-binding found-kind _)
            (if (and
              (string.eq found-name name)
              (compiler-object-symbol-binding-eq? found-binding binding)
              (compiler-object-symbol-kind-eq? found-kind kind))
              (set! found true)
              (set! index (+ index 1)))]))
      found)))

(define (compiler-object-relocation-list-contains?
  [relocs : CompilerObjectRelocationList]
  [kind : CompilerObjectRelocationKind]
  [target : String]) : bool
  (let
    [count : i64 (compiler-object-relocation-list-count relocs)]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (match (compiler-object-relocation-list-ref relocs index)
          [(CompilerObjectRelocation.Relocation _ _ found-kind found-target)
            (if (and
              (compiler-object-relocation-kind-eq? found-kind kind)
              (string.eq found-target target))
              (set! found true)
              (set! index (+ index 1)))]))
      found)))

(define (compiler-object-data-record-list-contains-string?
  [records : CompilerObjectDataRecordList]
  [text : String]) : bool
  (let
    [count : i64 (compiler-object-data-record-list-count records)]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (match (compiler-object-data-record-list-ref records index)
          [(CompilerObjectDataRecord.String value)
            (if (string.eq value text)
              (set! found true)
              (set! index (+ index 1)))]
          [_ (set! index (+ index 1))]))
      found)))

(define (compiler-object-data-record-list-contains-f64?
  [records : CompilerObjectDataRecordList]
  [bits : u64]) : bool
  (let
    [count : i64 (compiler-object-data-record-list-count records)]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (match (compiler-object-data-record-list-ref records index)
          [(CompilerObjectDataRecord.F64 value)
            (if (= value bits)
              (set! found true)
              (set! index (+ index 1)))]
          [_ (set! index (+ index 1))]))
      found)))

(define (compiler-object-data-record-list-contains-f32?
  [records : CompilerObjectDataRecordList]
  [bits : u64]) : bool
  (let
    [count : i64 (compiler-object-data-record-list-count records)]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (match (compiler-object-data-record-list-ref records index)
          [(CompilerObjectDataRecord.F32 value)
            (if (= value bits)
              (set! found true)
              (set! index (+ index 1)))]
          [_ (set! index (+ index 1))]))
      found)))

(define (compiler-object-data-record-list-contains-label?
  [records : CompilerObjectDataRecordList]
  [label : String]) : bool
  (let
    [count : i64 (compiler-object-data-record-list-count records)]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (match (compiler-object-data-record-list-ref records index)
          [(CompilerObjectDataRecord.Label value)
            (if (string.eq value label)
              (set! found true)
              (set! index (+ index 1)))]
          [_ (set! index (+ index 1))]))
      found)))

(define (compiler-object-data-record-list-contains-align?
  [records : CompilerObjectDataRecordList]
  [align : i64]) : bool
  (let
    [count : i64 (compiler-object-data-record-list-count records)]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (match (compiler-object-data-record-list-ref records index)
          [(CompilerObjectDataRecord.Align value)
            (if (= value align)
              (set! found true)
              (set! index (+ index 1)))]
          [_ (set! index (+ index 1))]))
      found)))

(define (compiler-object-data-record-list-contains-i64?
  [records : CompilerObjectDataRecordList]
  [value : i64]) : bool
  (let
    [count : i64 (compiler-object-data-record-list-count records)]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (match (compiler-object-data-record-list-ref records index)
          [(CompilerObjectDataRecord.I64 found-value)
            (if (= found-value value)
              (set! found true)
              (set! index (+ index 1)))]
          [_ (set! index (+ index 1))]))
      found)))

(define (compiler-object-data-record-list-label-has-i64-pair?
  [records : CompilerObjectDataRecordList]
  [label : String]
  [first : i64]
  [second : i64]) : bool
  (let
    [count : i64 (compiler-object-data-record-list-count records)]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (match (compiler-object-data-record-list-ref records index)
          [(CompilerObjectDataRecord.Label value)
            (if (and (string.eq value label) (< (+ index 2) count))
              (match (compiler-object-data-record-list-ref records (+ index 1))
                [(CompilerObjectDataRecord.I64 first-found)
                  (if (= first-found first)
                    (match (compiler-object-data-record-list-ref
                      records
                      (+ index 2))
                      [(CompilerObjectDataRecord.I64 second-found)
                        (if (= second-found second)
                          (set! found true)
                          (set! index (+ index 1)))]
                      [_ (set! index (+ index 1))])
                    (set! index (+ index 1)))]
                [_ (set! index (+ index 1))])
              (set! index (+ index 1)))]
          [_ (set! index (+ index 1))]))
      found)))

(define (compiler-object-section-contains-string?
  [sections : CompilerObjectSectionList]
  [kind : CompilerObjectSectionKind]
  [text : String]) : bool
  (match (compiler-object-section-list-find sections kind)
    [(CompilerObjectSection.Section _ data _)
      (compiler-object-data-record-list-contains-string? data text)]))

(define (compiler-object-section-contains-f64?
  [sections : CompilerObjectSectionList]
  [kind : CompilerObjectSectionKind]
  [bits : u64]) : bool
  (match (compiler-object-section-list-find sections kind)
    [(CompilerObjectSection.Section _ data _)
      (compiler-object-data-record-list-contains-f64? data bits)]))

(define (compiler-object-section-contains-f32?
  [sections : CompilerObjectSectionList]
  [kind : CompilerObjectSectionKind]
  [bits : u64]) : bool
  (match (compiler-object-section-list-find sections kind)
    [(CompilerObjectSection.Section _ data _)
      (compiler-object-data-record-list-contains-f32? data bits)]))

(define (compiler-object-section-contains-label?
  [sections : CompilerObjectSectionList]
  [kind : CompilerObjectSectionKind]
  [label : String]) : bool
  (match (compiler-object-section-list-find sections kind)
    [(CompilerObjectSection.Section _ data _)
      (compiler-object-data-record-list-contains-label? data label)]))

(define (compiler-object-section-contains-align?
  [sections : CompilerObjectSectionList]
  [kind : CompilerObjectSectionKind]
  [align : i64]) : bool
  (match (compiler-object-section-list-find sections kind)
    [(CompilerObjectSection.Section _ data _)
      (compiler-object-data-record-list-contains-align? data align)]))

(define (compiler-object-section-contains-i64?
  [sections : CompilerObjectSectionList]
  [kind : CompilerObjectSectionKind]
  [value : i64]) : bool
  (match (compiler-object-section-list-find sections kind)
    [(CompilerObjectSection.Section _ data _)
      (compiler-object-data-record-list-contains-i64? data value)]))

(define (compiler-object-section-label-has-i64-pair?
  [sections : CompilerObjectSectionList]
  [kind : CompilerObjectSectionKind]
  [label : String]
  [first : i64]
  [second : i64]) : bool
  (match (compiler-object-section-list-find sections kind)
    [(CompilerObjectSection.Section _ data _)
      (compiler-object-data-record-list-label-has-i64-pair?
        data
        label
        first
        second)]))

(define (compiler-object-instr-list-contains-call?
  [instrs : CompilerObjectX64InstrList]
  [target : String]) : bool
  (let
    [count : i64 (compiler-object-instr-list-count instrs)]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (match (compiler-object-instr-list-ref instrs index)
          [(CompilerObjectX64Instr.Call value)
            (if (string.eq value target)
              (set! found true)
              (set! index (+ index 1)))]
          [_ (set! index (+ index 1))]))
      found)))

(define (compiler-object-section-contains-call?
  [sections : CompilerObjectSectionList]
  [target : String]) : bool
  (match (compiler-object-section-list-find
    sections
    (CompilerObjectSectionKind.Text))
    [(CompilerObjectSection.Section _ _ instrs)
      (compiler-object-instr-list-contains-call? instrs target)]))

(define (compiler-object-string-prefix-at?
  [haystack : String]
  [needle : String]
  [start : i64]
  [index : i64]) : bool
  (cond
    [(>= index (string.string-length needle)) true]
    [(>= (+ start index) (string.string-length haystack)) false]
    [(=
        (string.string-ref haystack (+ start index))
        (string.string-ref needle index))
      (compiler-object-string-prefix-at? haystack needle start (+ index 1))]
    [else false]))

(define (compiler-object-string-contains?
  [haystack : String]
  [needle : String]
  [start : i64]) : bool
  (cond
    [(= (string.string-length needle) 0) true]
    [(> (+ start (string.string-length needle)) (string.string-length haystack))
      false]
    [(compiler-object-string-prefix-at? haystack needle start 0) true]
    [else (compiler-object-string-contains? haystack needle (+ start 1))]))

(define (compiler-object-instr-list-contains-bytes?
  [instrs : CompilerObjectX64InstrList]
  [bytes : String]) : bool
  (let
    [count : i64 (compiler-object-instr-list-count instrs)]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (match (compiler-object-instr-list-ref instrs index)
          [(CompilerObjectX64Instr.Bytes value)
            (if (compiler-object-string-contains? value bytes 0)
              (set! found true)
              (set! index (+ index 1)))]
          [(CompilerObjectX64Instr.Raw value)
            (if (compiler-object-string-contains? value bytes 0)
              (set! found true)
              (set! index (+ index 1)))]
          [_ (set! index (+ index 1))]))
      found)))

(define (compiler-object-section-contains-bytes?
  [sections : CompilerObjectSectionList]
  [bytes : String]) : bool
  (match (compiler-object-section-list-find
    sections
    (CompilerObjectSectionKind.Text))
    [(CompilerObjectSection.Section _ _ instrs)
      (compiler-object-instr-list-contains-bytes? instrs bytes)]))

(define (compiler-object-instr-list-contains-xorpd-rip?
  [instrs : CompilerObjectX64InstrList]
  [target : String]) : bool
  (let
    [count : i64 (compiler-object-instr-list-count instrs)]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (match (compiler-object-instr-list-ref instrs index)
          [(CompilerObjectX64Instr.XorpdRip value)
            (if (string.eq value target)
              (set! found true)
              (set! index (+ index 1)))]
          [_ (set! index (+ index 1))]))
      found)))

(define (compiler-object-section-contains-xorpd-rip?
  [sections : CompilerObjectSectionList]
  [target : String]) : bool
  (match (compiler-object-section-list-find
    sections
    (CompilerObjectSectionKind.Text))
    [(CompilerObjectSection.Section _ _ instrs)
      (compiler-object-instr-list-contains-xorpd-rip? instrs target)]))