;; compiler_object.tl - Structured object-image records for backend object emitters.
(module compiler_object)

(import stdlib.string)

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

(defenum CompilerObjectDataRecordList
  (Nil)
  (Cons CompilerObjectDataRecord (Box CompilerObjectDataRecordList))
  (Array (Array CompilerObjectDataRecord) i64))

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

(defenum CompilerObjectX64InstrList
  (Nil)
  (Cons CompilerObjectX64Instr (Box CompilerObjectX64InstrList))
  (Array (Array CompilerObjectX64Instr) i64))

(defenum CompilerObjectSymbol
  (Symbol
    String
    CompilerObjectSymbolBinding
    CompilerObjectSymbolKind
    CompilerObjectMaybeSection))

(defenum CompilerObjectSymbolList
  (Nil)
  (Cons CompilerObjectSymbol (Box CompilerObjectSymbolList))
  (Array (Array CompilerObjectSymbol) i64))

(defenum CompilerObjectRelocation
  (Relocation
    CompilerObjectSectionKind
    String
    CompilerObjectRelocationKind
    String))

(defenum CompilerObjectRelocationList
  (Nil)
  (Cons CompilerObjectRelocation (Box CompilerObjectRelocationList))
  (Array (Array CompilerObjectRelocation) i64))

(defenum CompilerObjectSection
  (Section
    CompilerObjectSectionKind
    CompilerObjectDataRecordList
    CompilerObjectX64InstrList))

(defenum CompilerObjectSectionList
  (Nil)
  (Cons CompilerObjectSection (Box CompilerObjectSectionList))
  (Array (Array CompilerObjectSection) i64))

(defstruct CompilerObjectImage
  (sections CompilerObjectSectionList)
  (symbols CompilerObjectSymbolList)
  (relocations CompilerObjectRelocationList))

(defstruct CompilerObjectDataRecordBuilder
  (slots (Array CompilerObjectDataRecord))
  (count i64))

(defstruct CompilerObjectX64InstrBuilder
  (slots (Array CompilerObjectX64Instr))
  (count i64))

(defstruct CompilerObjectSymbolBuilder
  (slots (Array CompilerObjectSymbol))
  (count i64))

(defstruct CompilerObjectRelocationBuilder
  (slots (Array CompilerObjectRelocation))
  (count i64))

(defstruct CompilerObjectSectionBuilder
  (slots (Array CompilerObjectSection))
  (count i64))

(define (compiler-object-builder-capacity [capacity : i64]) : i64
  (if (< capacity 1)
    1
    capacity))

(define (compiler-object-data-record-builder-with-capacity [capacity : i64]) : CompilerObjectDataRecordBuilder
  (CompilerObjectDataRecordBuilder
    (make-array
      CompilerObjectDataRecord
      (compiler-object-builder-capacity capacity))
    0))

(define (compiler-object-data-record-builder-new) : CompilerObjectDataRecordBuilder
  (compiler-object-data-record-builder-with-capacity 16))

(define (compiler-object-instr-builder-with-capacity [capacity : i64]) : CompilerObjectX64InstrBuilder
  (CompilerObjectX64InstrBuilder
    (make-array
      CompilerObjectX64Instr
      (compiler-object-builder-capacity capacity))
    0))

(define (compiler-object-instr-builder-new) : CompilerObjectX64InstrBuilder
  (compiler-object-instr-builder-with-capacity 16))

(define (compiler-object-symbol-builder-with-capacity [capacity : i64]) : CompilerObjectSymbolBuilder
  (CompilerObjectSymbolBuilder
    (make-array
      CompilerObjectSymbol
      (compiler-object-builder-capacity capacity))
    0))

(define (compiler-object-symbol-builder-new) : CompilerObjectSymbolBuilder
  (compiler-object-symbol-builder-with-capacity 16))

(define (compiler-object-relocation-builder-with-capacity [capacity : i64]) : CompilerObjectRelocationBuilder
  (CompilerObjectRelocationBuilder
    (make-array
      CompilerObjectRelocation
      (compiler-object-builder-capacity capacity))
    0))

(define (compiler-object-relocation-builder-new) : CompilerObjectRelocationBuilder
  (compiler-object-relocation-builder-with-capacity 16))

(define (compiler-object-section-builder-with-capacity [capacity : i64]) : CompilerObjectSectionBuilder
  (CompilerObjectSectionBuilder
    (make-array
      CompilerObjectSection
      (compiler-object-builder-capacity capacity))
    0))

(define (compiler-object-section-builder-new) : CompilerObjectSectionBuilder
  (compiler-object-section-builder-with-capacity 8))

(define (compiler-object-data-record-builder-copy-range!
  [dst : (Array CompilerObjectDataRecord)]
  [src : (Array CompilerObjectDataRecord)]
  [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (begin
        (array-set! dst index (array-ref src index))
        (set! index (+ index 1))))))

(define (compiler-object-instr-builder-copy-range!
  [dst : (Array CompilerObjectX64Instr)]
  [src : (Array CompilerObjectX64Instr)]
  [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (begin
        (array-set! dst index (array-ref src index))
        (set! index (+ index 1))))))

(define (compiler-object-symbol-builder-copy-range!
  [dst : (Array CompilerObjectSymbol)]
  [src : (Array CompilerObjectSymbol)]
  [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (begin
        (array-set! dst index (array-ref src index))
        (set! index (+ index 1))))))

(define (compiler-object-relocation-builder-copy-range!
  [dst : (Array CompilerObjectRelocation)]
  [src : (Array CompilerObjectRelocation)]
  [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (begin
        (array-set! dst index (array-ref src index))
        (set! index (+ index 1))))))

(define (compiler-object-section-builder-copy-range!
  [dst : (Array CompilerObjectSection)]
  [src : (Array CompilerObjectSection)]
  [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (begin
        (array-set! dst index (array-ref src index))
        (set! index (+ index 1))))))

(define (compiler-object-data-record-builder-grow
  [builder : CompilerObjectDataRecordBuilder]) : CompilerObjectDataRecordBuilder
  (let
    [count : i64 (struct-get builder count)]
    [slots : (Array CompilerObjectDataRecord) (struct-get builder slots)]
    [bigger : (Array CompilerObjectDataRecord)
      (make-array CompilerObjectDataRecord (* (array-length slots) 2))]
    (begin
      (compiler-object-data-record-builder-copy-range! bigger slots count)
      (CompilerObjectDataRecordBuilder bigger count))))

(define (compiler-object-instr-builder-grow
  [builder : CompilerObjectX64InstrBuilder]) : CompilerObjectX64InstrBuilder
  (let
    [count : i64 (struct-get builder count)]
    [slots : (Array CompilerObjectX64Instr) (struct-get builder slots)]
    [bigger : (Array CompilerObjectX64Instr)
      (make-array CompilerObjectX64Instr (* (array-length slots) 2))]
    (begin
      (compiler-object-instr-builder-copy-range! bigger slots count)
      (CompilerObjectX64InstrBuilder bigger count))))

(define (compiler-object-symbol-builder-grow
  [builder : CompilerObjectSymbolBuilder]) : CompilerObjectSymbolBuilder
  (let
    [count : i64 (struct-get builder count)]
    [slots : (Array CompilerObjectSymbol) (struct-get builder slots)]
    [bigger : (Array CompilerObjectSymbol)
      (make-array CompilerObjectSymbol (* (array-length slots) 2))]
    (begin
      (compiler-object-symbol-builder-copy-range! bigger slots count)
      (CompilerObjectSymbolBuilder bigger count))))

(define (compiler-object-relocation-builder-grow
  [builder : CompilerObjectRelocationBuilder]) : CompilerObjectRelocationBuilder
  (let
    [count : i64 (struct-get builder count)]
    [slots : (Array CompilerObjectRelocation) (struct-get builder slots)]
    [bigger : (Array CompilerObjectRelocation)
      (make-array CompilerObjectRelocation (* (array-length slots) 2))]
    (begin
      (compiler-object-relocation-builder-copy-range! bigger slots count)
      (CompilerObjectRelocationBuilder bigger count))))

(define (compiler-object-section-builder-grow
  [builder : CompilerObjectSectionBuilder]) : CompilerObjectSectionBuilder
  (let
    [count : i64 (struct-get builder count)]
    [slots : (Array CompilerObjectSection) (struct-get builder slots)]
    [bigger : (Array CompilerObjectSection)
      (make-array CompilerObjectSection (* (array-length slots) 2))]
    (begin
      (compiler-object-section-builder-copy-range! bigger slots count)
      (CompilerObjectSectionBuilder bigger count))))

(define (compiler-object-data-record-builder-push
  [builder : CompilerObjectDataRecordBuilder]
  [record : CompilerObjectDataRecord]) : CompilerObjectDataRecordBuilder
  (if (< (struct-get builder count) (array-length (struct-get builder slots)))
    (let
      [slots : (Array CompilerObjectDataRecord) (struct-get builder slots)]
      [count : i64 (struct-get builder count)]
      (begin
        (array-set! slots count record)
        (CompilerObjectDataRecordBuilder slots (+ count 1))))
    (compiler-object-data-record-builder-push
      (compiler-object-data-record-builder-grow builder)
      record)))

(define (compiler-object-instr-builder-push
  [builder : CompilerObjectX64InstrBuilder]
  [instr : CompilerObjectX64Instr]) : CompilerObjectX64InstrBuilder
  (if (< (struct-get builder count) (array-length (struct-get builder slots)))
    (let
      [slots : (Array CompilerObjectX64Instr) (struct-get builder slots)]
      [count : i64 (struct-get builder count)]
      (begin
        (array-set! slots count instr)
        (CompilerObjectX64InstrBuilder slots (+ count 1))))
    (compiler-object-instr-builder-push
      (compiler-object-instr-builder-grow builder)
      instr)))

(define (compiler-object-symbol-builder-push
  [builder : CompilerObjectSymbolBuilder]
  [symbol : CompilerObjectSymbol]) : CompilerObjectSymbolBuilder
  (if (< (struct-get builder count) (array-length (struct-get builder slots)))
    (let
      [slots : (Array CompilerObjectSymbol) (struct-get builder slots)]
      [count : i64 (struct-get builder count)]
      (begin
        (array-set! slots count symbol)
        (CompilerObjectSymbolBuilder slots (+ count 1))))
    (compiler-object-symbol-builder-push
      (compiler-object-symbol-builder-grow builder)
      symbol)))

(define (compiler-object-relocation-builder-push
  [builder : CompilerObjectRelocationBuilder]
  [reloc : CompilerObjectRelocation]) : CompilerObjectRelocationBuilder
  (if (< (struct-get builder count) (array-length (struct-get builder slots)))
    (let
      [slots : (Array CompilerObjectRelocation) (struct-get builder slots)]
      [count : i64 (struct-get builder count)]
      (begin
        (array-set! slots count reloc)
        (CompilerObjectRelocationBuilder slots (+ count 1))))
    (compiler-object-relocation-builder-push
      (compiler-object-relocation-builder-grow builder)
      reloc)))

(define (compiler-object-section-builder-push
  [builder : CompilerObjectSectionBuilder]
  [section : CompilerObjectSection]) : CompilerObjectSectionBuilder
  (if (< (struct-get builder count) (array-length (struct-get builder slots)))
    (let
      [slots : (Array CompilerObjectSection) (struct-get builder slots)]
      [count : i64 (struct-get builder count)]
      (begin
        (array-set! slots count section)
        (CompilerObjectSectionBuilder slots (+ count 1))))
    (compiler-object-section-builder-push
      (compiler-object-section-builder-grow builder)
      section)))

(define (compiler-object-data-record-builder-finish
  [builder : CompilerObjectDataRecordBuilder]) : CompilerObjectDataRecordList
  (CompilerObjectDataRecordList.Array
    (struct-get builder slots)
    (struct-get builder count)))

(define (compiler-object-instr-builder-finish
  [builder : CompilerObjectX64InstrBuilder]) : CompilerObjectX64InstrList
  (CompilerObjectX64InstrList.Array
    (struct-get builder slots)
    (struct-get builder count)))

(define (compiler-object-symbol-builder-finish
  [builder : CompilerObjectSymbolBuilder]) : CompilerObjectSymbolList
  (CompilerObjectSymbolList.Array
    (struct-get builder slots)
    (struct-get builder count)))

(define (compiler-object-relocation-builder-finish
  [builder : CompilerObjectRelocationBuilder]) : CompilerObjectRelocationList
  (CompilerObjectRelocationList.Array
    (struct-get builder slots)
    (struct-get builder count)))

(define (compiler-object-section-builder-finish
  [builder : CompilerObjectSectionBuilder]) : CompilerObjectSectionList
  (CompilerObjectSectionList.Array
    (struct-get builder slots)
    (struct-get builder count)))

(define (compiler-object-symbol-builder-contains?
  [builder : CompilerObjectSymbolBuilder]
  [name : String]
  [binding : CompilerObjectSymbolBinding]
  [kind : CompilerObjectSymbolKind]) : bool
  (let
    [count : i64 (struct-get builder count)]
    [slots : (Array CompilerObjectSymbol) (struct-get builder slots)]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (match (array-ref slots index)
          [(CompilerObjectSymbol.Symbol found-name found-binding found-kind _)
            (if (and
              (string.eq found-name name)
              (compiler-object-symbol-binding-eq? found-binding binding)
              (compiler-object-symbol-kind-eq? found-kind kind))
              (set! found true)
              (set! index (+ index 1)))]))
      found)))

(define (compiler-object-data-cons
  [head : CompilerObjectDataRecord]
  [tail : CompilerObjectDataRecordList]) : CompilerObjectDataRecordList
  (CompilerObjectDataRecordList.Cons head (box tail)))

(define (compiler-object-instr-cons
  [head : CompilerObjectX64Instr]
  [tail : CompilerObjectX64InstrList]) : CompilerObjectX64InstrList
  (CompilerObjectX64InstrList.Cons head (box tail)))

(define (compiler-object-symbol-cons
  [head : CompilerObjectSymbol]
  [tail : CompilerObjectSymbolList]) : CompilerObjectSymbolList
  (CompilerObjectSymbolList.Cons head (box tail)))

(define (compiler-object-relocation-cons
  [head : CompilerObjectRelocation]
  [tail : CompilerObjectRelocationList]) : CompilerObjectRelocationList
  (CompilerObjectRelocationList.Cons head (box tail)))

(define (compiler-object-section-cons
  [head : CompilerObjectSection]
  [tail : CompilerObjectSectionList]) : CompilerObjectSectionList
  (CompilerObjectSectionList.Cons head (box tail)))

(define (compiler-object-data-list-fill-reversed!
  [records : CompilerObjectDataRecordList]
  [slots : (Array CompilerObjectDataRecord)]
  [index : i64]) : unit
  (match records
    [(CompilerObjectDataRecordList.Nil) unit]
    [(CompilerObjectDataRecordList.Cons head rest)
      (begin
        (array-set! slots index head)
        (compiler-object-data-list-fill-reversed!
          (box-get rest)
          slots
          (- index 1)))]
    [(CompilerObjectDataRecordList.Array _ _) unit]))

(define (compiler-object-data-list-dense-reversed
  [records : CompilerObjectDataRecordList]) : CompilerObjectDataRecordList
  (match records
    [(CompilerObjectDataRecordList.Array _ _) records]
    [_
      (let
        [count : i64 (compiler-object-data-record-list-count records)]
        [slots : (Array CompilerObjectDataRecord)
          (make-array CompilerObjectDataRecord count)]
        (begin
          (compiler-object-data-list-fill-reversed! records slots (- count 1))
          (CompilerObjectDataRecordList.Array slots count)))]))

(define (compiler-object-instr-list-fill-reversed!
  [instrs : CompilerObjectX64InstrList]
  [slots : (Array CompilerObjectX64Instr)]
  [index : i64]) : unit
  (match instrs
    [(CompilerObjectX64InstrList.Nil) unit]
    [(CompilerObjectX64InstrList.Cons head rest)
      (begin
        (array-set! slots index head)
        (compiler-object-instr-list-fill-reversed!
          (box-get rest)
          slots
          (- index 1)))]
    [(CompilerObjectX64InstrList.Array _ _) unit]))

(define (compiler-object-instr-list-dense-reversed
  [instrs : CompilerObjectX64InstrList]) : CompilerObjectX64InstrList
  (match instrs
    [(CompilerObjectX64InstrList.Array _ _) instrs]
    [_
      (let
        [count : i64 (compiler-object-instr-list-count instrs)]
        [slots : (Array CompilerObjectX64Instr)
          (make-array CompilerObjectX64Instr count)]
        (begin
          (compiler-object-instr-list-fill-reversed! instrs slots (- count 1))
          (CompilerObjectX64InstrList.Array slots count)))]))

(define (compiler-object-symbol-list-fill-reversed!
  [symbols : CompilerObjectSymbolList]
  [slots : (Array CompilerObjectSymbol)]
  [index : i64]) : unit
  (match symbols
    [(CompilerObjectSymbolList.Nil) unit]
    [(CompilerObjectSymbolList.Cons head rest)
      (begin
        (array-set! slots index head)
        (compiler-object-symbol-list-fill-reversed!
          (box-get rest)
          slots
          (- index 1)))]
    [(CompilerObjectSymbolList.Array _ _) unit]))

(define (compiler-object-symbol-list-dense-reversed
  [symbols : CompilerObjectSymbolList]) : CompilerObjectSymbolList
  (match symbols
    [(CompilerObjectSymbolList.Array _ _) symbols]
    [_
      (let
        [count : i64 (compiler-object-symbol-list-count symbols)]
        [slots : (Array CompilerObjectSymbol)
          (make-array CompilerObjectSymbol count)]
        (begin
          (compiler-object-symbol-list-fill-reversed! symbols slots (- count 1))
          (CompilerObjectSymbolList.Array slots count)))]))

(define (compiler-object-relocation-list-fill-reversed!
  [relocs : CompilerObjectRelocationList]
  [slots : (Array CompilerObjectRelocation)]
  [index : i64]) : unit
  (match relocs
    [(CompilerObjectRelocationList.Nil) unit]
    [(CompilerObjectRelocationList.Cons head rest)
      (begin
        (array-set! slots index head)
        (compiler-object-relocation-list-fill-reversed!
          (box-get rest)
          slots
          (- index 1)))]
    [(CompilerObjectRelocationList.Array _ _) unit]))

(define (compiler-object-relocation-list-dense-reversed
  [relocs : CompilerObjectRelocationList]) : CompilerObjectRelocationList
  (match relocs
    [(CompilerObjectRelocationList.Array _ _) relocs]
    [_
      (let
        [count : i64 (compiler-object-relocation-list-count relocs)]
        [slots : (Array CompilerObjectRelocation)
          (make-array CompilerObjectRelocation count)]
        (begin
          (compiler-object-relocation-list-fill-reversed!
            relocs
            slots
            (- count 1))
          (CompilerObjectRelocationList.Array slots count)))]))

(define (compiler-object-section-list-fill!
  [sections : CompilerObjectSectionList]
  [slots : (Array CompilerObjectSection)]
  [index : i64]) : unit
  (match sections
    [(CompilerObjectSectionList.Nil) unit]
    [(CompilerObjectSectionList.Cons head rest)
      (begin
        (array-set! slots index head)
        (compiler-object-section-list-fill! (box-get rest) slots (+ index 1)))]
    [(CompilerObjectSectionList.Array _ _) unit]))

(define (compiler-object-section-list-dense
  [sections : CompilerObjectSectionList]) : CompilerObjectSectionList
  (match sections
    [(CompilerObjectSectionList.Array _ _) sections]
    [_
      (let
        [count : i64 (compiler-object-section-list-count sections)]
        [slots : (Array CompilerObjectSection)
          (make-array CompilerObjectSection count)]
        (begin
          (compiler-object-section-list-fill! sections slots 0)
          (CompilerObjectSectionList.Array slots count)))]))

(define (compiler-object-data-list-reverse
  [records : CompilerObjectDataRecordList]) : CompilerObjectDataRecordList
  (compiler-object-data-list-dense-reversed records))

(define (compiler-object-instr-list-reverse
  [instrs : CompilerObjectX64InstrList]) : CompilerObjectX64InstrList
  (compiler-object-instr-list-dense-reversed instrs))

(define (compiler-object-symbol-list-reverse
  [symbols : CompilerObjectSymbolList]) : CompilerObjectSymbolList
  (compiler-object-symbol-list-dense-reversed symbols))

(define (compiler-object-relocation-list-reverse
  [relocs : CompilerObjectRelocationList]) : CompilerObjectRelocationList
  (compiler-object-relocation-list-dense-reversed relocs))

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
  (match symbols
    [(CompilerObjectSymbolList.Nil) 0]
    [(CompilerObjectSymbolList.Cons _ rest)
      (+ 1 (compiler-object-symbol-list-count (box-get rest)))]
    [(CompilerObjectSymbolList.Array _ count) count]))

(define (compiler-object-symbol-list-ref
  [symbols : CompilerObjectSymbolList]
  [index : i64]) : CompilerObjectSymbol
  (match symbols
    [(CompilerObjectSymbolList.Nil)
      (CompilerObjectSymbol.Symbol
        ""
        (CompilerObjectSymbolBinding.Local)
        (CompilerObjectSymbolKind.Data)
        CompilerObjectMaybeSection.No)]
    [(CompilerObjectSymbolList.Cons head rest)
      (if (= index 0)
        head
        (compiler-object-symbol-list-ref (box-get rest) (- index 1)))]
    [(CompilerObjectSymbolList.Array slots _) (array-ref slots index)]))

(define (compiler-object-relocation-list-count
  [relocs : CompilerObjectRelocationList]) : i64
  (match relocs
    [(CompilerObjectRelocationList.Nil) 0]
    [(CompilerObjectRelocationList.Cons _ rest)
      (+ 1 (compiler-object-relocation-list-count (box-get rest)))]
    [(CompilerObjectRelocationList.Array _ count) count]))

(define (compiler-object-relocation-list-ref
  [relocs : CompilerObjectRelocationList]
  [index : i64]) : CompilerObjectRelocation
  (match relocs
    [(CompilerObjectRelocationList.Nil)
      (CompilerObjectRelocation.Relocation
        (CompilerObjectSectionKind.Text)
        ""
        (CompilerObjectRelocationKind.Abs64)
        "")]
    [(CompilerObjectRelocationList.Cons head rest)
      (if (= index 0)
        head
        (compiler-object-relocation-list-ref (box-get rest) (- index 1)))]
    [(CompilerObjectRelocationList.Array slots _) (array-ref slots index)]))

(define (compiler-object-data-record-list-count
  [records : CompilerObjectDataRecordList]) : i64
  (match records
    [(CompilerObjectDataRecordList.Nil) 0]
    [(CompilerObjectDataRecordList.Cons _ rest)
      (+ 1 (compiler-object-data-record-list-count (box-get rest)))]
    [(CompilerObjectDataRecordList.Array _ count) count]))

(define (compiler-object-data-record-list-ref
  [records : CompilerObjectDataRecordList]
  [index : i64]) : CompilerObjectDataRecord
  (match records
    [(CompilerObjectDataRecordList.Nil) (CompilerObjectDataRecord.Zero 0)]
    [(CompilerObjectDataRecordList.Cons head rest)
      (if (= index 0)
        head
        (compiler-object-data-record-list-ref (box-get rest) (- index 1)))]
    [(CompilerObjectDataRecordList.Array slots _) (array-ref slots index)]))

(define (compiler-object-instr-list-count [instrs : CompilerObjectX64InstrList]) : i64
  (match instrs
    [(CompilerObjectX64InstrList.Nil) 0]
    [(CompilerObjectX64InstrList.Cons _ rest)
      (+ 1 (compiler-object-instr-list-count (box-get rest)))]
    [(CompilerObjectX64InstrList.Array _ count) count]))

(define (compiler-object-instr-list-ref
  [instrs : CompilerObjectX64InstrList]
  [index : i64]) : CompilerObjectX64Instr
  (match instrs
    [(CompilerObjectX64InstrList.Nil) (CompilerObjectX64Instr.Raw "")]
    [(CompilerObjectX64InstrList.Cons head rest)
      (if (= index 0)
        head
        (compiler-object-instr-list-ref (box-get rest) (- index 1)))]
    [(CompilerObjectX64InstrList.Array slots _) (array-ref slots index)]))

(define (compiler-object-section-list-count
  [sections : CompilerObjectSectionList]) : i64
  (match sections
    [(CompilerObjectSectionList.Nil) 0]
    [(CompilerObjectSectionList.Cons _ rest)
      (+ 1 (compiler-object-section-list-count (box-get rest)))]
    [(CompilerObjectSectionList.Array _ count) count]))

(define (compiler-object-section-list-ref
  [sections : CompilerObjectSectionList]
  [index : i64]) : CompilerObjectSection
  (match sections
    [(CompilerObjectSectionList.Nil)
      (CompilerObjectSection.Section
        (CompilerObjectSectionKind.Text)
        CompilerObjectDataRecordList.Nil
        CompilerObjectX64InstrList.Nil)]
    [(CompilerObjectSectionList.Cons head rest)
      (if (= index 0)
        head
        (compiler-object-section-list-ref (box-get rest) (- index 1)))]
    [(CompilerObjectSectionList.Array slots _) (array-ref slots index)]))

(define (compiler-object-section-payloads-dense?
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
              (match data
                [(CompilerObjectDataRecordList.Array _ _) true]
                [_ false])
              (match instrs
                [(CompilerObjectX64InstrList.Array _ _) true]
                [_ false]))
              (set! index (+ index 1))
              (set! ok false))]))
      ok)))

(define (compiler-object-image-dense? [image : CompilerObjectImage]) : bool
  (let
    [sections : CompilerObjectSectionList (struct-get image sections)]
    (and
      (match sections
        [(CompilerObjectSectionList.Array _ _) true]
        [_ false])
      (compiler-object-section-payloads-dense? sections)
      (match (struct-get image symbols)
        [(CompilerObjectSymbolList.Array _ _) true]
        [_ false])
      (match (struct-get image relocations)
        [(CompilerObjectRelocationList.Array _ _) true]
        [_ false]))))

(define (compiler-object-section-list-find
  [sections : CompilerObjectSectionList]
  [kind : CompilerObjectSectionKind]) : CompilerObjectSection
  (let
    [count : i64 (compiler-object-section-list-count sections)]
    [index : i64 0]
    [result : CompilerObjectSection
      (CompilerObjectSection.Section
        kind
        CompilerObjectDataRecordList.Nil
        CompilerObjectX64InstrList.Nil)]
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