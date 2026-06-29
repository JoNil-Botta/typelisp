;; compiler_object.tl - Structured object-image records for backend object emitters.
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