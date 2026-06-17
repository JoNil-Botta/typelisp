;; compiler_object.tl - Structured object-image records for backend object emitters.
(defenum CompilerObjectSectionKind
  (ObjectSectionText)
  (ObjectSectionData)
  (ObjectSectionRodata)
  (ObjectSectionBss)
  (ObjectSectionPdata)
  (ObjectSectionXdata))

(defenum CompilerObjectMaybeSection
  (ObjectNoSection)
  (ObjectSomeSection CompilerObjectSectionKind))

(defenum CompilerObjectSymbolBinding
  (ObjectSymbolLocal)
  (ObjectSymbolExport)
  (ObjectSymbolExtern))

(defenum CompilerObjectSymbolKind
  (ObjectSymbolFunction)
  (ObjectSymbolData)
  (ObjectSymbolSection)
  (ObjectSymbolRuntime))

(defenum CompilerObjectRelocationKind
  (ObjectRelocCall)
  (ObjectRelocTailCall)
  (ObjectRelocAbs64)
  (ObjectRelocAddr32Nb)
  (ObjectRelocRipValue)
  (ObjectRelocRipAddress)
  (ObjectRelocBranch))

(defenum CompilerObjectDataRecord
  (ObjectDataLabel String)
  (ObjectDataAlign i64)
  (ObjectDataBytes String)
  (ObjectDataString String)
  (ObjectDataF64 String)
  (ObjectDataI64 i64)
  (ObjectDataZero i64)
  (ObjectDataSymbolAddress String)
  (ObjectDataSymbolRva32 String))

(defenum CompilerObjectDataRecordList
  (ObjectDataNil)
  (ObjectDataCons CompilerObjectDataRecord (Box CompilerObjectDataRecordList))
  (ObjectDataArray (Array CompilerObjectDataRecord) i64))

(defenum CompilerObjectX64Instr
  (ObjectX64Label String)
  (ObjectX64Call String)
  (ObjectX64TailCall String)
  (ObjectX64Jump String)
  (ObjectX64Branch String String)
  (ObjectX64LoadRip String)
  (ObjectX64LoadRipAddress String)
  (ObjectX64StoreRip String)
  (ObjectX64SubRspImm8 i64)
  (ObjectX64MovRcxRip String)
  (ObjectX64MovRdxRip String)
  (ObjectX64LoadRipAddressRdx String)
  (ObjectX64StoreR14Rip String)
  (ObjectX64StoreR15Rip String)
  (ObjectX64AddRcxRip String)
  (ObjectX64MovRcxRax)
  (ObjectX64XorpdRip String)
  (ObjectX64Bytes String)
  (ObjectX64Raw String))

(defenum CompilerObjectX64InstrList
  (ObjectInstrNil)
  (ObjectInstrCons CompilerObjectX64Instr (Box CompilerObjectX64InstrList))
  (ObjectInstrArray (Array CompilerObjectX64Instr) i64))

(defenum CompilerObjectSymbol
  (ObjectSymbol
    String
    CompilerObjectSymbolBinding
    CompilerObjectSymbolKind
    CompilerObjectMaybeSection))

(defenum CompilerObjectSymbolList
  (ObjectSymbolNil)
  (ObjectSymbolCons CompilerObjectSymbol (Box CompilerObjectSymbolList))
  (ObjectSymbolArray (Array CompilerObjectSymbol) i64))

(defenum CompilerObjectRelocation
  (ObjectRelocation
    CompilerObjectSectionKind
    String
    CompilerObjectRelocationKind
    String))

(defenum CompilerObjectRelocationList
  (ObjectRelocationNil)
  (ObjectRelocationCons
    CompilerObjectRelocation
    (Box CompilerObjectRelocationList))
  (ObjectRelocationArray (Array CompilerObjectRelocation) i64))

(defenum CompilerObjectSection
  (ObjectSection
    CompilerObjectSectionKind
    CompilerObjectDataRecordList
    CompilerObjectX64InstrList))

(defenum CompilerObjectSectionList
  (ObjectSectionNil)
  (ObjectSectionCons CompilerObjectSection (Box CompilerObjectSectionList))
  (ObjectSectionArray (Array CompilerObjectSection) i64))

(defstruct CompilerObjectImage
  (sections CompilerObjectSectionList)
  (symbols CompilerObjectSymbolList)
  (relocations CompilerObjectRelocationList))

(define (compiler-object-data-cons
  [head : CompilerObjectDataRecord]
  [tail : CompilerObjectDataRecordList]) : CompilerObjectDataRecordList
  (ObjectDataCons head (box tail)))

(define (compiler-object-instr-cons
  [head : CompilerObjectX64Instr]
  [tail : CompilerObjectX64InstrList]) : CompilerObjectX64InstrList
  (ObjectInstrCons head (box tail)))

(define (compiler-object-symbol-cons
  [head : CompilerObjectSymbol]
  [tail : CompilerObjectSymbolList]) : CompilerObjectSymbolList
  (ObjectSymbolCons head (box tail)))

(define (compiler-object-relocation-cons
  [head : CompilerObjectRelocation]
  [tail : CompilerObjectRelocationList]) : CompilerObjectRelocationList
  (ObjectRelocationCons head (box tail)))

(define (compiler-object-section-cons
  [head : CompilerObjectSection]
  [tail : CompilerObjectSectionList]) : CompilerObjectSectionList
  (ObjectSectionCons head (box tail)))

(define (compiler-object-data-list-fill-reversed!
  [records : CompilerObjectDataRecordList]
  [slots : (Array CompilerObjectDataRecord)]
  [index : i64]) : unit
  (match records
    [(ObjectDataNil) unit]
    [(ObjectDataCons head rest)
      (begin
        (array-set! slots index head)
        (compiler-object-data-list-fill-reversed!
          (box-get rest)
          slots
          (- index 1)))]
    [(ObjectDataArray _ _) unit]))

(define (compiler-object-data-list-dense-reversed
  [records : CompilerObjectDataRecordList]) : CompilerObjectDataRecordList
  (match records
    [(ObjectDataArray _ _) records]
    [_
      (let
        [count : i64 (compiler-object-data-record-list-count records)]
        [slots : (Array CompilerObjectDataRecord)
          (make-array CompilerObjectDataRecord count)]
        (begin
          (compiler-object-data-list-fill-reversed! records slots (- count 1))
          (ObjectDataArray slots count)))]))

(define (compiler-object-instr-list-fill-reversed!
  [instrs : CompilerObjectX64InstrList]
  [slots : (Array CompilerObjectX64Instr)]
  [index : i64]) : unit
  (match instrs
    [(ObjectInstrNil) unit]
    [(ObjectInstrCons head rest)
      (begin
        (array-set! slots index head)
        (compiler-object-instr-list-fill-reversed!
          (box-get rest)
          slots
          (- index 1)))]
    [(ObjectInstrArray _ _) unit]))

(define (compiler-object-instr-list-dense-reversed
  [instrs : CompilerObjectX64InstrList]) : CompilerObjectX64InstrList
  (match instrs
    [(ObjectInstrArray _ _) instrs]
    [_
      (let
        [count : i64 (compiler-object-instr-list-count instrs)]
        [slots : (Array CompilerObjectX64Instr)
          (make-array CompilerObjectX64Instr count)]
        (begin
          (compiler-object-instr-list-fill-reversed! instrs slots (- count 1))
          (ObjectInstrArray slots count)))]))

(define (compiler-object-symbol-list-fill-reversed!
  [symbols : CompilerObjectSymbolList]
  [slots : (Array CompilerObjectSymbol)]
  [index : i64]) : unit
  (match symbols
    [(ObjectSymbolNil) unit]
    [(ObjectSymbolCons head rest)
      (begin
        (array-set! slots index head)
        (compiler-object-symbol-list-fill-reversed!
          (box-get rest)
          slots
          (- index 1)))]
    [(ObjectSymbolArray _ _) unit]))

(define (compiler-object-symbol-list-dense-reversed
  [symbols : CompilerObjectSymbolList]) : CompilerObjectSymbolList
  (match symbols
    [(ObjectSymbolArray _ _) symbols]
    [_
      (let
        [count : i64 (compiler-object-symbol-list-count symbols)]
        [slots : (Array CompilerObjectSymbol)
          (make-array CompilerObjectSymbol count)]
        (begin
          (compiler-object-symbol-list-fill-reversed! symbols slots (- count 1))
          (ObjectSymbolArray slots count)))]))

(define (compiler-object-relocation-list-fill-reversed!
  [relocs : CompilerObjectRelocationList]
  [slots : (Array CompilerObjectRelocation)]
  [index : i64]) : unit
  (match relocs
    [(ObjectRelocationNil) unit]
    [(ObjectRelocationCons head rest)
      (begin
        (array-set! slots index head)
        (compiler-object-relocation-list-fill-reversed!
          (box-get rest)
          slots
          (- index 1)))]
    [(ObjectRelocationArray _ _) unit]))

(define (compiler-object-relocation-list-dense-reversed
  [relocs : CompilerObjectRelocationList]) : CompilerObjectRelocationList
  (match relocs
    [(ObjectRelocationArray _ _) relocs]
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
          (ObjectRelocationArray slots count)))]))

(define (compiler-object-section-list-fill!
  [sections : CompilerObjectSectionList]
  [slots : (Array CompilerObjectSection)]
  [index : i64]) : unit
  (match sections
    [(ObjectSectionNil) unit]
    [(ObjectSectionCons head rest)
      (begin
        (array-set! slots index head)
        (compiler-object-section-list-fill! (box-get rest) slots (+ index 1)))]
    [(ObjectSectionArray _ _) unit]))

(define (compiler-object-section-list-dense
  [sections : CompilerObjectSectionList]) : CompilerObjectSectionList
  (match sections
    [(ObjectSectionArray _ _) sections]
    [_
      (let
        [count : i64 (compiler-object-section-list-count sections)]
        [slots : (Array CompilerObjectSection)
          (make-array CompilerObjectSection count)]
        (begin
          (compiler-object-section-list-fill! sections slots 0)
          (ObjectSectionArray slots count)))]))

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
    [(ObjectSectionText)
      (match b
        [(ObjectSectionText) true]
        [_ false])]
    [(ObjectSectionData)
      (match b
        [(ObjectSectionData) true]
        [_ false])]
    [(ObjectSectionRodata)
      (match b
        [(ObjectSectionRodata) true]
        [_ false])]
    [(ObjectSectionBss)
      (match b
        [(ObjectSectionBss) true]
        [_ false])]
    [(ObjectSectionPdata)
      (match b
        [(ObjectSectionPdata) true]
        [_ false])]
    [(ObjectSectionXdata)
      (match b
        [(ObjectSectionXdata) true]
        [_ false])]))

(define (compiler-object-symbol-binding-eq?
  [a : CompilerObjectSymbolBinding]
  [b : CompilerObjectSymbolBinding]) : bool
  (match a
    [(ObjectSymbolLocal)
      (match b
        [(ObjectSymbolLocal) true]
        [_ false])]
    [(ObjectSymbolExport)
      (match b
        [(ObjectSymbolExport) true]
        [_ false])]
    [(ObjectSymbolExtern)
      (match b
        [(ObjectSymbolExtern) true]
        [_ false])]))

(define (compiler-object-symbol-kind-eq?
  [a : CompilerObjectSymbolKind]
  [b : CompilerObjectSymbolKind]) : bool
  (match a
    [(ObjectSymbolFunction)
      (match b
        [(ObjectSymbolFunction) true]
        [_ false])]
    [(ObjectSymbolData)
      (match b
        [(ObjectSymbolData) true]
        [_ false])]
    [(ObjectSymbolSection)
      (match b
        [(ObjectSymbolSection) true]
        [_ false])]
    [(ObjectSymbolRuntime)
      (match b
        [(ObjectSymbolRuntime) true]
        [_ false])]))

(define (compiler-object-relocation-kind-eq?
  [a : CompilerObjectRelocationKind]
  [b : CompilerObjectRelocationKind]) : bool
  (match a
    [(ObjectRelocCall)
      (match b
        [(ObjectRelocCall) true]
        [_ false])]
    [(ObjectRelocTailCall)
      (match b
        [(ObjectRelocTailCall) true]
        [_ false])]
    [(ObjectRelocAbs64)
      (match b
        [(ObjectRelocAbs64) true]
        [_ false])]
    [(ObjectRelocAddr32Nb)
      (match b
        [(ObjectRelocAddr32Nb) true]
        [_ false])]
    [(ObjectRelocRipValue)
      (match b
        [(ObjectRelocRipValue) true]
        [_ false])]
    [(ObjectRelocRipAddress)
      (match b
        [(ObjectRelocRipAddress) true]
        [_ false])]
    [(ObjectRelocBranch)
      (match b
        [(ObjectRelocBranch) true]
        [_ false])]))

(define (compiler-object-symbol-list-count [symbols : CompilerObjectSymbolList]) : i64
  (match symbols
    [(ObjectSymbolNil) 0]
    [(ObjectSymbolCons _ rest)
      (+ 1 (compiler-object-symbol-list-count (box-get rest)))]
    [(ObjectSymbolArray _ count) count]))

(define (compiler-object-symbol-list-ref
  [symbols : CompilerObjectSymbolList]
  [index : i64]) : CompilerObjectSymbol
  (match symbols
    [(ObjectSymbolNil)
      (ObjectSymbol "" (ObjectSymbolLocal) (ObjectSymbolData) ObjectNoSection)]
    [(ObjectSymbolCons head rest)
      (if (= index 0)
        head
        (compiler-object-symbol-list-ref (box-get rest) (- index 1)))]
    [(ObjectSymbolArray slots _) (array-ref slots index)]))

(define (compiler-object-relocation-list-count
  [relocs : CompilerObjectRelocationList]) : i64
  (match relocs
    [(ObjectRelocationNil) 0]
    [(ObjectRelocationCons _ rest)
      (+ 1 (compiler-object-relocation-list-count (box-get rest)))]
    [(ObjectRelocationArray _ count) count]))

(define (compiler-object-relocation-list-ref
  [relocs : CompilerObjectRelocationList]
  [index : i64]) : CompilerObjectRelocation
  (match relocs
    [(ObjectRelocationNil)
      (ObjectRelocation (ObjectSectionText) "" (ObjectRelocAbs64) "")]
    [(ObjectRelocationCons head rest)
      (if (= index 0)
        head
        (compiler-object-relocation-list-ref (box-get rest) (- index 1)))]
    [(ObjectRelocationArray slots _) (array-ref slots index)]))

(define (compiler-object-data-record-list-count
  [records : CompilerObjectDataRecordList]) : i64
  (match records
    [(ObjectDataNil) 0]
    [(ObjectDataCons _ rest)
      (+ 1 (compiler-object-data-record-list-count (box-get rest)))]
    [(ObjectDataArray _ count) count]))

(define (compiler-object-data-record-list-ref
  [records : CompilerObjectDataRecordList]
  [index : i64]) : CompilerObjectDataRecord
  (match records
    [(ObjectDataNil) (ObjectDataZero 0)]
    [(ObjectDataCons head rest)
      (if (= index 0)
        head
        (compiler-object-data-record-list-ref (box-get rest) (- index 1)))]
    [(ObjectDataArray slots _) (array-ref slots index)]))

(define (compiler-object-instr-list-count [instrs : CompilerObjectX64InstrList]) : i64
  (match instrs
    [(ObjectInstrNil) 0]
    [(ObjectInstrCons _ rest)
      (+ 1 (compiler-object-instr-list-count (box-get rest)))]
    [(ObjectInstrArray _ count) count]))

(define (compiler-object-instr-list-ref
  [instrs : CompilerObjectX64InstrList]
  [index : i64]) : CompilerObjectX64Instr
  (match instrs
    [(ObjectInstrNil) (ObjectX64Raw "")]
    [(ObjectInstrCons head rest)
      (if (= index 0)
        head
        (compiler-object-instr-list-ref (box-get rest) (- index 1)))]
    [(ObjectInstrArray slots _) (array-ref slots index)]))

(define (compiler-object-section-list-count
  [sections : CompilerObjectSectionList]) : i64
  (match sections
    [(ObjectSectionNil) 0]
    [(ObjectSectionCons _ rest)
      (+ 1 (compiler-object-section-list-count (box-get rest)))]
    [(ObjectSectionArray _ count) count]))

(define (compiler-object-section-list-ref
  [sections : CompilerObjectSectionList]
  [index : i64]) : CompilerObjectSection
  (match sections
    [(ObjectSectionNil)
      (ObjectSection (ObjectSectionText) ObjectDataNil ObjectInstrNil)]
    [(ObjectSectionCons head rest)
      (if (= index 0)
        head
        (compiler-object-section-list-ref (box-get rest) (- index 1)))]
    [(ObjectSectionArray slots _) (array-ref slots index)]))

(define (compiler-object-section-payloads-dense?
  [sections : CompilerObjectSectionList]) : bool
  (let
    [count : i64 (compiler-object-section-list-count sections)]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (match (compiler-object-section-list-ref sections index)
          [(ObjectSection _ data instrs)
            (if (and
              (match data
                [(ObjectDataArray _ _) true]
                [_ false])
              (match instrs
                [(ObjectInstrArray _ _) true]
                [_ false]))
              (set! index (+ index 1))
              (set! ok false))]))
      ok)))

(define (compiler-object-image-dense? [image : CompilerObjectImage]) : bool
  (let
    [sections : CompilerObjectSectionList (struct-get image sections)]
    (and
      (match sections
        [(ObjectSectionArray _ _) true]
        [_ false])
      (compiler-object-section-payloads-dense? sections)
      (match (struct-get image symbols)
        [(ObjectSymbolArray _ _) true]
        [_ false])
      (match (struct-get image relocations)
        [(ObjectRelocationArray _ _) true]
        [_ false]))))

(define (compiler-object-section-list-find
  [sections : CompilerObjectSectionList]
  [kind : CompilerObjectSectionKind]) : CompilerObjectSection
  (let
    [count : i64 (compiler-object-section-list-count sections)]
    [index : i64 0]
    [result : CompilerObjectSection
      (ObjectSection kind ObjectDataNil ObjectInstrNil)]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (let
          [section : CompilerObjectSection
            (compiler-object-section-list-ref sections index)]
          (match section
            [(ObjectSection found-kind _ _)
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
    [(ObjectSection _ data _) (compiler-object-data-record-list-count data)]))

(define (compiler-object-section-instr-count
  [sections : CompilerObjectSectionList]
  [kind : CompilerObjectSectionKind]) : i64
  (match (compiler-object-section-list-find sections kind)
    [(ObjectSection _ _ instrs) (compiler-object-instr-list-count instrs)]))

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
          [(ObjectSymbol found-name found-binding found-kind _)
            (if (and
              (string-eq found-name name)
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
          [(ObjectRelocation _ _ found-kind found-target)
            (if (and
              (compiler-object-relocation-kind-eq? found-kind kind)
              (string-eq found-target target))
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
          [(ObjectDataString value)
            (if (string-eq value text)
              (set! found true)
              (set! index (+ index 1)))]
          [_ (set! index (+ index 1))]))
      found)))

(define (compiler-object-data-record-list-contains-f64?
  [records : CompilerObjectDataRecordList]
  [text : String]) : bool
  (let
    [count : i64 (compiler-object-data-record-list-count records)]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (match (compiler-object-data-record-list-ref records index)
          [(ObjectDataF64 value)
            (if (string-eq value text)
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
          [(ObjectDataLabel value)
            (if (string-eq value label)
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
          [(ObjectDataAlign value)
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
          [(ObjectDataI64 found-value)
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
          [(ObjectDataLabel value)
            (if (and (string-eq value label) (< (+ index 2) count))
              (match (compiler-object-data-record-list-ref records (+ index 1))
                [(ObjectDataI64 first-found)
                  (if (= first-found first)
                    (match (compiler-object-data-record-list-ref
                      records
                      (+ index 2))
                      [(ObjectDataI64 second-found)
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
    [(ObjectSection _ data _)
      (compiler-object-data-record-list-contains-string? data text)]))

(define (compiler-object-section-contains-f64?
  [sections : CompilerObjectSectionList]
  [kind : CompilerObjectSectionKind]
  [text : String]) : bool
  (match (compiler-object-section-list-find sections kind)
    [(ObjectSection _ data _)
      (compiler-object-data-record-list-contains-f64? data text)]))

(define (compiler-object-section-contains-label?
  [sections : CompilerObjectSectionList]
  [kind : CompilerObjectSectionKind]
  [label : String]) : bool
  (match (compiler-object-section-list-find sections kind)
    [(ObjectSection _ data _)
      (compiler-object-data-record-list-contains-label? data label)]))

(define (compiler-object-section-contains-align?
  [sections : CompilerObjectSectionList]
  [kind : CompilerObjectSectionKind]
  [align : i64]) : bool
  (match (compiler-object-section-list-find sections kind)
    [(ObjectSection _ data _)
      (compiler-object-data-record-list-contains-align? data align)]))

(define (compiler-object-section-contains-i64?
  [sections : CompilerObjectSectionList]
  [kind : CompilerObjectSectionKind]
  [value : i64]) : bool
  (match (compiler-object-section-list-find sections kind)
    [(ObjectSection _ data _)
      (compiler-object-data-record-list-contains-i64? data value)]))

(define (compiler-object-section-label-has-i64-pair?
  [sections : CompilerObjectSectionList]
  [kind : CompilerObjectSectionKind]
  [label : String]
  [first : i64]
  [second : i64]) : bool
  (match (compiler-object-section-list-find sections kind)
    [(ObjectSection _ data _)
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
          [(ObjectX64Call value)
            (if (string-eq value target)
              (set! found true)
              (set! index (+ index 1)))]
          [_ (set! index (+ index 1))]))
      found)))

(define (compiler-object-section-contains-call?
  [sections : CompilerObjectSectionList]
  [target : String]) : bool
  (match (compiler-object-section-list-find sections (ObjectSectionText))
    [(ObjectSection _ _ instrs)
      (compiler-object-instr-list-contains-call? instrs target)]))

(define (compiler-object-string-prefix-at?
  [haystack : String]
  [needle : String]
  [start : i64]
  [index : i64]) : bool
  (if (>= index (string-length needle))
    true
    (if (>= (+ start index) (string-length haystack))
      false
      (if (char-eq
        (string-ref haystack (+ start index))
        (string-ref needle index))
        (compiler-object-string-prefix-at? haystack needle start (+ index 1))
        false))))

(define (compiler-object-string-contains?
  [haystack : String]
  [needle : String]
  [start : i64]) : bool
  (if (= (string-length needle) 0)
    true
    (if (> (+ start (string-length needle)) (string-length haystack))
      false
      (if (compiler-object-string-prefix-at? haystack needle start 0)
        true
        (compiler-object-string-contains? haystack needle (+ start 1))))))

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
          [(ObjectX64Bytes value)
            (if (compiler-object-string-contains? value bytes 0)
              (set! found true)
              (set! index (+ index 1)))]
          [(ObjectX64Raw value)
            (if (compiler-object-string-contains? value bytes 0)
              (set! found true)
              (set! index (+ index 1)))]
          [_ (set! index (+ index 1))]))
      found)))

(define (compiler-object-section-contains-bytes?
  [sections : CompilerObjectSectionList]
  [bytes : String]) : bool
  (match (compiler-object-section-list-find sections (ObjectSectionText))
    [(ObjectSection _ _ instrs)
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
          [(ObjectX64XorpdRip value)
            (if (string-eq value target)
              (set! found true)
              (set! index (+ index 1)))]
          [_ (set! index (+ index 1))]))
      found)))

(define (compiler-object-section-contains-xorpd-rip?
  [sections : CompilerObjectSectionList]
  [target : String]) : bool
  (match (compiler-object-section-list-find sections (ObjectSectionText))
    [(ObjectSection _ _ instrs)
      (compiler-object-instr-list-contains-xorpd-rip? instrs target)]))