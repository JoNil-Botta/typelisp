;; compiler_object.tl - Structured object-image records for backend object emitters.
(defenum CompilerObjectSectionKind
  (ObjectSectionText)
  (ObjectSectionData)
  (ObjectSectionRodata)
  (ObjectSectionBss))

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
  (ObjectDataSymbolAddress String))

(defenum CompilerObjectDataRecordList
  (ObjectDataNil)
  (ObjectDataCons CompilerObjectDataRecord (Box CompilerObjectDataRecordList)))

(defenum CompilerObjectX64Instr
  (ObjectX64Label String)
  (ObjectX64Call String)
  (ObjectX64TailCall String)
  (ObjectX64Jump String)
  (ObjectX64Branch String String)
  (ObjectX64LoadRip String)
  (ObjectX64LoadRipAddress String)
  (ObjectX64StoreRip String)
  (ObjectX64Raw String))

(defenum CompilerObjectX64InstrList
  (ObjectInstrNil)
  (ObjectInstrCons CompilerObjectX64Instr (Box CompilerObjectX64InstrList)))

(defenum CompilerObjectSymbol
  (ObjectSymbol
    String
    CompilerObjectSymbolBinding
    CompilerObjectSymbolKind
    CompilerObjectMaybeSection))

(defenum CompilerObjectSymbolList
  (ObjectSymbolNil)
  (ObjectSymbolCons CompilerObjectSymbol (Box CompilerObjectSymbolList)))

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
    (Box CompilerObjectRelocationList)))

(defenum CompilerObjectSection
  (ObjectSection
    CompilerObjectSectionKind
    CompilerObjectDataRecordList
    CompilerObjectX64InstrList))

(defenum CompilerObjectSectionList
  (ObjectSectionNil)
  (ObjectSectionCons CompilerObjectSection (Box CompilerObjectSectionList)))

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

(define (compiler-object-data-list-reverse-onto
  [records : CompilerObjectDataRecordList]
  [out : CompilerObjectDataRecordList]) : CompilerObjectDataRecordList
  (match records
    [(ObjectDataNil) out]
    [(ObjectDataCons head rest)
      (compiler-object-data-list-reverse-onto
        (box-get rest)
        (compiler-object-data-cons head out))]))

(define (compiler-object-data-list-reverse
  [records : CompilerObjectDataRecordList]) : CompilerObjectDataRecordList
  (compiler-object-data-list-reverse-onto records ObjectDataNil))

(define (compiler-object-instr-list-reverse-onto
  [instrs : CompilerObjectX64InstrList]
  [out : CompilerObjectX64InstrList]) : CompilerObjectX64InstrList
  (match instrs
    [(ObjectInstrNil) out]
    [(ObjectInstrCons head rest)
      (compiler-object-instr-list-reverse-onto
        (box-get rest)
        (compiler-object-instr-cons head out))]))

(define (compiler-object-instr-list-reverse
  [instrs : CompilerObjectX64InstrList]) : CompilerObjectX64InstrList
  (compiler-object-instr-list-reverse-onto instrs ObjectInstrNil))

(define (compiler-object-symbol-list-reverse-onto
  [symbols : CompilerObjectSymbolList]
  [out : CompilerObjectSymbolList]) : CompilerObjectSymbolList
  (match symbols
    [(ObjectSymbolNil) out]
    [(ObjectSymbolCons head rest)
      (compiler-object-symbol-list-reverse-onto
        (box-get rest)
        (compiler-object-symbol-cons head out))]))

(define (compiler-object-symbol-list-reverse
  [symbols : CompilerObjectSymbolList]) : CompilerObjectSymbolList
  (compiler-object-symbol-list-reverse-onto symbols ObjectSymbolNil))

(define (compiler-object-relocation-list-reverse-onto
  [relocs : CompilerObjectRelocationList]
  [out : CompilerObjectRelocationList]) : CompilerObjectRelocationList
  (match relocs
    [(ObjectRelocationNil) out]
    [(ObjectRelocationCons head rest)
      (compiler-object-relocation-list-reverse-onto
        (box-get rest)
        (compiler-object-relocation-cons head out))]))

(define (compiler-object-relocation-list-reverse
  [relocs : CompilerObjectRelocationList]) : CompilerObjectRelocationList
  (compiler-object-relocation-list-reverse-onto relocs ObjectRelocationNil))

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
      (+ 1 (compiler-object-symbol-list-count (box-get rest)))]))

(define (compiler-object-relocation-list-count
  [relocs : CompilerObjectRelocationList]) : i64
  (match relocs
    [(ObjectRelocationNil) 0]
    [(ObjectRelocationCons _ rest)
      (+ 1 (compiler-object-relocation-list-count (box-get rest)))]))

(define (compiler-object-data-record-list-count
  [records : CompilerObjectDataRecordList]) : i64
  (match records
    [(ObjectDataNil) 0]
    [(ObjectDataCons _ rest)
      (+ 1 (compiler-object-data-record-list-count (box-get rest)))]))

(define (compiler-object-instr-list-count [instrs : CompilerObjectX64InstrList]) : i64
  (match instrs
    [(ObjectInstrNil) 0]
    [(ObjectInstrCons _ rest)
      (+ 1 (compiler-object-instr-list-count (box-get rest)))]))

(define (compiler-object-section-list-count
  [sections : CompilerObjectSectionList]) : i64
  (match sections
    [(ObjectSectionNil) 0]
    [(ObjectSectionCons _ rest)
      (+ 1 (compiler-object-section-list-count (box-get rest)))]))

(define (compiler-object-section-list-find
  [sections : CompilerObjectSectionList]
  [kind : CompilerObjectSectionKind]) : CompilerObjectSection
  (match sections
    [(ObjectSectionNil) (ObjectSection kind ObjectDataNil ObjectInstrNil)]
    [(ObjectSectionCons section rest)
      (match section
        [(ObjectSection found _ _)
          (if (compiler-object-section-kind-eq? found kind)
            section
            (compiler-object-section-list-find (box-get rest) kind))])]))

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
  (match symbols
    [(ObjectSymbolNil) false]
    [(ObjectSymbolCons symbol rest)
      (match symbol
        [(ObjectSymbol found-name found-binding found-kind _)
          (if (and
            (string-eq found-name name)
            (compiler-object-symbol-binding-eq? found-binding binding)
            (compiler-object-symbol-kind-eq? found-kind kind))
            true
            (compiler-object-symbol-list-contains?
              (box-get rest)
              name
              binding
              kind))])]))

(define (compiler-object-relocation-list-contains?
  [relocs : CompilerObjectRelocationList]
  [kind : CompilerObjectRelocationKind]
  [target : String]) : bool
  (match relocs
    [(ObjectRelocationNil) false]
    [(ObjectRelocationCons reloc rest)
      (match reloc
        [(ObjectRelocation _ _ found-kind found-target)
          (if (and
            (compiler-object-relocation-kind-eq? found-kind kind)
            (string-eq found-target target))
            true
            (compiler-object-relocation-list-contains?
              (box-get rest)
              kind
              target))])]))

(define (compiler-object-data-record-list-contains-string?
  [records : CompilerObjectDataRecordList]
  [text : String]) : bool
  (match records
    [(ObjectDataNil) false]
    [(ObjectDataCons record rest)
      (match record
        [(ObjectDataString found)
          (if (string-eq found text)
            true
            (compiler-object-data-record-list-contains-string?
              (box-get rest)
              text))]
        [_
          (compiler-object-data-record-list-contains-string?
            (box-get rest)
            text)])]))

(define (compiler-object-data-record-list-contains-f64?
  [records : CompilerObjectDataRecordList]
  [text : String]) : bool
  (match records
    [(ObjectDataNil) false]
    [(ObjectDataCons record rest)
      (match record
        [(ObjectDataF64 found)
          (if (string-eq found text)
            true
            (compiler-object-data-record-list-contains-f64? (box-get rest) text))]
        [_ (compiler-object-data-record-list-contains-f64? (box-get rest) text)])]))

(define (compiler-object-data-record-list-contains-label?
  [records : CompilerObjectDataRecordList]
  [label : String]) : bool
  (match records
    [(ObjectDataNil) false]
    [(ObjectDataCons record rest)
      (match record
        [(ObjectDataLabel found)
          (if (string-eq found label)
            true
            (compiler-object-data-record-list-contains-label?
              (box-get rest)
              label))]
        [_
          (compiler-object-data-record-list-contains-label?
            (box-get rest)
            label)])]))

(define (compiler-object-data-record-list-contains-align?
  [records : CompilerObjectDataRecordList]
  [align : i64]) : bool
  (match records
    [(ObjectDataNil) false]
    [(ObjectDataCons record rest)
      (match record
        [(ObjectDataAlign found)
          (if (= found align)
            true
            (compiler-object-data-record-list-contains-align?
              (box-get rest)
              align))]
        [_
          (compiler-object-data-record-list-contains-align?
            (box-get rest)
            align)])]))

(define (compiler-object-data-record-list-contains-i64?
  [records : CompilerObjectDataRecordList]
  [value : i64]) : bool
  (match records
    [(ObjectDataNil) false]
    [(ObjectDataCons record rest)
      (match record
        [(ObjectDataI64 found)
          (if (= found value)
            true
            (compiler-object-data-record-list-contains-i64?
              (box-get rest)
              value))]
        [_
          (compiler-object-data-record-list-contains-i64? (box-get rest) value)])]))

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

(define (compiler-object-instr-list-contains-call?
  [instrs : CompilerObjectX64InstrList]
  [target : String]) : bool
  (match instrs
    [(ObjectInstrNil) false]
    [(ObjectInstrCons instr rest)
      (match instr
        [(ObjectX64Call found)
          (if (string-eq found target)
            true
            (compiler-object-instr-list-contains-call? (box-get rest) target))]
        [_ (compiler-object-instr-list-contains-call? (box-get rest) target)])]))

(define (compiler-object-section-contains-call?
  [sections : CompilerObjectSectionList]
  [target : String]) : bool
  (match (compiler-object-section-list-find sections (ObjectSectionText))
    [(ObjectSection _ _ instrs)
      (compiler-object-instr-list-contains-call? instrs target)]))