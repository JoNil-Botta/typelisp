;; compiler_object.tl - Structured object-image records for backend object emitters.
(import compiler_owned_view as owned_view)
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

;; `String` records have an object-format backing contract distinct from the
;; language-level String/Str contract: their physical payload is the explicit
;; string bytes followed by exactly one zero byte.  The byte is part of object
;; layout only and does not make one-past-length reads or C-string conversion
;; valid in source programs.
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

;; Canonical physical end offset for data records.  Serializers retain their
;; target-specific section validation, but must use this walk for record extent
;; so labels, symbols, and relocation sites cannot drift between sinks.
(define (compiler-object-data-record-end-offset
  [record : CompilerObjectDataRecord]
  [offset : i64]) : i64
  (match record
    [(CompilerObjectDataRecord.Label _) offset]
    [(CompilerObjectDataRecord.Align align)
      (if (<= align 1)
        offset
        (let
          [rem : i64 (% offset align)]
          (if (= rem 0)
            offset
            (+ offset (- align rem)))))]
    [(CompilerObjectDataRecord.Bytes bytes)
      (+ offset (__tl_string_length bytes))]
    [(CompilerObjectDataRecord.String text)
      (+ offset (+ (__tl_string_length text) 1))]
    [(CompilerObjectDataRecord.F64 _) (+ offset 8)]
    [(CompilerObjectDataRecord.F32 _) (+ offset 4)]
    [(CompilerObjectDataRecord.I64 _) (+ offset 8)]
    [(CompilerObjectDataRecord.Zero count) (+ offset count)]
    [(CompilerObjectDataRecord.SymbolAddress _) (+ offset 8)]
    [(CompilerObjectDataRecord.SymbolRva32 _) (+ offset 4)]))

(defstruct CompilerObjectDataRecordList
  (slots (__tl_dyn-array CompilerObjectDataRecord))
  (len i64))

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

(defstruct CompilerObjectX64InstrList
  (slots (__tl_dyn-array CompilerObjectX64Instr))
  (len i64))

(defenum CompilerObjectSymbol
  (Symbol
    String
    CompilerObjectSymbolBinding
    CompilerObjectSymbolKind
    CompilerObjectMaybeSection))

(defstruct CompilerObjectSymbolList
  (slots (__tl_dyn-array CompilerObjectSymbol))
  (len i64))

(defenum CompilerObjectRelocation
  (Relocation
    CompilerObjectSectionKind
    String
    CompilerObjectRelocationKind
    String))

(defstruct CompilerObjectRelocationList
  (slots (__tl_dyn-array CompilerObjectRelocation))
  (len i64))

(defenum CompilerObjectSection
  (Section
    CompilerObjectSectionKind
    CompilerObjectDataRecordList
    CompilerObjectX64InstrList))

(defstruct CompilerObjectSectionList
  (slots (__tl_dyn-array CompilerObjectSection))
  (len i64))

(defstruct CompilerObjectImage
  (sections CompilerObjectSectionList)
  (symbols CompilerObjectSymbolList)
  (relocations CompilerObjectRelocationList))

(defstruct CompilerObjectDataRecordBuilder
  (slots (__tl_dyn-array CompilerObjectDataRecord))
  (count i64))

(defstruct CompilerObjectX64InstrBuilder
  (slots (__tl_dyn-array CompilerObjectX64Instr))
  (count i64))

(defstruct CompilerObjectSymbolBuilder
  (slots (__tl_dyn-array CompilerObjectSymbol))
  (count i64))

(defstruct CompilerObjectRelocationBuilder
  (slots (__tl_dyn-array CompilerObjectRelocation))
  (count i64))

(defstruct CompilerObjectSectionBuilder
  (slots (__tl_dyn-array CompilerObjectSection))
  (count i64))

(define (compiler-object-builder-capacity [capacity : i64]) : i64
  (if (< capacity 1)
    1
    capacity))

(define (compiler-object-data-record-builder-with-capacity [capacity : i64]) : CompilerObjectDataRecordBuilder
  (CompilerObjectDataRecordBuilder
    (__tl_make-array
      CompilerObjectDataRecord
      (compiler-object-builder-capacity capacity))
    0))

(define (compiler-object-data-record-builder-new) : CompilerObjectDataRecordBuilder
  (compiler-object-data-record-builder-with-capacity 16))

(define (compiler-object-instr-builder-with-capacity [capacity : i64]) : CompilerObjectX64InstrBuilder
  (CompilerObjectX64InstrBuilder
    (__tl_make-array
      CompilerObjectX64Instr
      (compiler-object-builder-capacity capacity))
    0))

(define (compiler-object-instr-builder-new) : CompilerObjectX64InstrBuilder
  (compiler-object-instr-builder-with-capacity 16))

(define (compiler-object-symbol-builder-with-capacity [capacity : i64]) : CompilerObjectSymbolBuilder
  (CompilerObjectSymbolBuilder
    (__tl_make-array
      CompilerObjectSymbol
      (compiler-object-builder-capacity capacity))
    0))

(define (compiler-object-symbol-builder-new) : CompilerObjectSymbolBuilder
  (compiler-object-symbol-builder-with-capacity 16))

(define (compiler-object-relocation-builder-with-capacity [capacity : i64]) : CompilerObjectRelocationBuilder
  (CompilerObjectRelocationBuilder
    (__tl_make-array
      CompilerObjectRelocation
      (compiler-object-builder-capacity capacity))
    0))

(define (compiler-object-relocation-builder-new) : CompilerObjectRelocationBuilder
  (compiler-object-relocation-builder-with-capacity 16))

(define (compiler-object-section-builder-with-capacity [capacity : i64]) : CompilerObjectSectionBuilder
  (CompilerObjectSectionBuilder
    (__tl_make-array
      CompilerObjectSection
      (compiler-object-builder-capacity capacity))
    0))

(define (compiler-object-data-record-builder-copy-range!
  [dst : (__tl_dyn-array CompilerObjectDataRecord)]
  [src : (__tl_dyn-array CompilerObjectDataRecord)]
  [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (begin
        (set! (array-ref dst index) (array-ref src index))
        (set! index (+ index 1))))))

(define (compiler-object-instr-builder-copy-range!
  [dst : (__tl_dyn-array CompilerObjectX64Instr)]
  [src : (__tl_dyn-array CompilerObjectX64Instr)]
  [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (begin
        (set! (array-ref dst index) (array-ref src index))
        (set! index (+ index 1))))))

(define (compiler-object-symbol-builder-copy-range!
  [dst : (__tl_dyn-array CompilerObjectSymbol)]
  [src : (__tl_dyn-array CompilerObjectSymbol)]
  [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (begin
        (set! (array-ref dst index) (array-ref src index))
        (set! index (+ index 1))))))

(define (compiler-object-relocation-builder-copy-range!
  [dst : (__tl_dyn-array CompilerObjectRelocation)]
  [src : (__tl_dyn-array CompilerObjectRelocation)]
  [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (begin
        (set! (array-ref dst index) (array-ref src index))
        (set! index (+ index 1))))))

(define (compiler-object-section-builder-copy-range!
  [dst : (__tl_dyn-array CompilerObjectSection)]
  [src : (__tl_dyn-array CompilerObjectSection)]
  [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (begin
        (set! (array-ref dst index) (array-ref src index))
        (set! index (+ index 1))))))

(define (compiler-object-data-record-builder-grow
  [builder : CompilerObjectDataRecordBuilder]) : CompilerObjectDataRecordBuilder
  (let
    [count : i64 builder.count]
    [slots : (__tl_dyn-array CompilerObjectDataRecord) builder.slots]
    [bigger : (__tl_dyn-array CompilerObjectDataRecord)
      (__tl_make-array CompilerObjectDataRecord (* (array-length slots) 2))]
    (begin
      (compiler-object-data-record-builder-copy-range!
        (owned_view.compiler-owned-shared-view bigger)
        slots
        count)
      (CompilerObjectDataRecordBuilder bigger count))))

(define (compiler-object-instr-builder-grow
  [builder : CompilerObjectX64InstrBuilder]) : CompilerObjectX64InstrBuilder
  (let
    [count : i64 builder.count]
    [slots : (__tl_dyn-array CompilerObjectX64Instr) builder.slots]
    [bigger : (__tl_dyn-array CompilerObjectX64Instr)
      (__tl_make-array CompilerObjectX64Instr (* (array-length slots) 2))]
    (begin
      (compiler-object-instr-builder-copy-range!
        (owned_view.compiler-owned-shared-view bigger)
        slots
        count)
      (CompilerObjectX64InstrBuilder bigger count))))

(define (compiler-object-symbol-builder-grow
  [builder : CompilerObjectSymbolBuilder]) : CompilerObjectSymbolBuilder
  (let
    [count : i64 builder.count]
    [slots : (__tl_dyn-array CompilerObjectSymbol) builder.slots]
    [bigger : (__tl_dyn-array CompilerObjectSymbol)
      (__tl_make-array CompilerObjectSymbol (* (array-length slots) 2))]
    (begin
      (compiler-object-symbol-builder-copy-range!
        (owned_view.compiler-owned-shared-view bigger)
        slots
        count)
      (CompilerObjectSymbolBuilder bigger count))))

(define (compiler-object-relocation-builder-grow
  [builder : CompilerObjectRelocationBuilder]) : CompilerObjectRelocationBuilder
  (let
    [count : i64 builder.count]
    [slots : (__tl_dyn-array CompilerObjectRelocation) builder.slots]
    [bigger : (__tl_dyn-array CompilerObjectRelocation)
      (__tl_make-array CompilerObjectRelocation (* (array-length slots) 2))]
    (begin
      (compiler-object-relocation-builder-copy-range!
        (owned_view.compiler-owned-shared-view bigger)
        slots
        count)
      (CompilerObjectRelocationBuilder bigger count))))

(define (compiler-object-section-builder-grow
  [builder : CompilerObjectSectionBuilder]) : CompilerObjectSectionBuilder
  (let
    [count : i64 builder.count]
    [slots : (__tl_dyn-array CompilerObjectSection) builder.slots]
    [bigger : (__tl_dyn-array CompilerObjectSection)
      (__tl_make-array CompilerObjectSection (* (array-length slots) 2))]
    (begin
      (compiler-object-section-builder-copy-range!
        (owned_view.compiler-owned-shared-view bigger)
        slots
        count)
      (CompilerObjectSectionBuilder bigger count))))

(define (compiler-object-data-record-builder-push
  [builder : CompilerObjectDataRecordBuilder]
  [record : CompilerObjectDataRecord]) : CompilerObjectDataRecordBuilder
  (if (< builder.count (array-length builder.slots))
    (let
      [slots : (__tl_dyn-array CompilerObjectDataRecord) builder.slots]
      [count : i64 builder.count]
      (begin
        (set! (array-ref slots count) record)
        (CompilerObjectDataRecordBuilder slots (+ count 1))))
    (compiler-object-data-record-builder-push
      (compiler-object-data-record-builder-grow builder)
      record)))

(define (compiler-object-instr-builder-push
  [builder : CompilerObjectX64InstrBuilder]
  [instr : CompilerObjectX64Instr]) : CompilerObjectX64InstrBuilder
  (if (< builder.count (array-length builder.slots))
    (let
      [slots : (__tl_dyn-array CompilerObjectX64Instr) builder.slots]
      [count : i64 builder.count]
      (begin
        (set! (array-ref slots count) instr)
        (CompilerObjectX64InstrBuilder slots (+ count 1))))
    (compiler-object-instr-builder-push
      (compiler-object-instr-builder-grow builder)
      instr)))

(define (compiler-object-symbol-builder-push
  [builder : CompilerObjectSymbolBuilder]
  [symbol : CompilerObjectSymbol]) : CompilerObjectSymbolBuilder
  (if (< builder.count (array-length builder.slots))
    (let
      [slots : (__tl_dyn-array CompilerObjectSymbol) builder.slots]
      [count : i64 builder.count]
      (begin
        (set! (array-ref slots count) symbol)
        (CompilerObjectSymbolBuilder slots (+ count 1))))
    (compiler-object-symbol-builder-push
      (compiler-object-symbol-builder-grow builder)
      symbol)))

(define (compiler-object-relocation-builder-push
  [builder : CompilerObjectRelocationBuilder]
  [reloc : CompilerObjectRelocation]) : CompilerObjectRelocationBuilder
  (if (< builder.count (array-length builder.slots))
    (let
      [slots : (__tl_dyn-array CompilerObjectRelocation) builder.slots]
      [count : i64 builder.count]
      (begin
        (set! (array-ref slots count) reloc)
        (CompilerObjectRelocationBuilder slots (+ count 1))))
    (compiler-object-relocation-builder-push
      (compiler-object-relocation-builder-grow builder)
      reloc)))

(define (compiler-object-section-builder-push
  [builder : CompilerObjectSectionBuilder]
  [section : CompilerObjectSection]) : CompilerObjectSectionBuilder
  (if (< builder.count (array-length builder.slots))
    (let
      [slots : (__tl_dyn-array CompilerObjectSection) builder.slots]
      [count : i64 builder.count]
      (begin
        (set! (array-ref slots count) section)
        (CompilerObjectSectionBuilder slots (+ count 1))))
    (compiler-object-section-builder-push
      (compiler-object-section-builder-grow builder)
      section)))

(define (compiler-object-data-record-builder-finish
  [builder : CompilerObjectDataRecordBuilder]) : CompilerObjectDataRecordList
  (CompilerObjectDataRecordList builder.slots builder.count))

(define (compiler-object-instr-builder-finish
  [builder : CompilerObjectX64InstrBuilder]) : CompilerObjectX64InstrList
  (CompilerObjectX64InstrList builder.slots builder.count))

(define (compiler-object-symbol-builder-finish
  [builder : CompilerObjectSymbolBuilder]) : CompilerObjectSymbolList
  (CompilerObjectSymbolList builder.slots builder.count))

(define (compiler-object-relocation-builder-finish
  [builder : CompilerObjectRelocationBuilder]) : CompilerObjectRelocationList
  (CompilerObjectRelocationList builder.slots builder.count))

(define (compiler-object-section-builder-finish
  [builder : CompilerObjectSectionBuilder]) : CompilerObjectSectionList
  (CompilerObjectSectionList builder.slots builder.count))

(define (compiler-object-symbol-builder-contains?
  [builder : CompilerObjectSymbolBuilder]
  [name : String]
  [binding : CompilerObjectSymbolBinding]
  [kind : CompilerObjectSymbolKind]) : bool
  (let
    [count : i64 builder.count]
    [slots : (__tl_dyn-array CompilerObjectSymbol) builder.slots]
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

(define (compiler-object-relocation-builder-targets?
  [builder : CompilerObjectRelocationBuilder]
  [target : String]) : bool
  (let
    [count : i64 builder.count]
    [slots : (__tl_dyn-array CompilerObjectRelocation) builder.slots]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (match (array-ref slots index)
          [(CompilerObjectRelocation.Relocation _ _ _ found-target)
            (if (string.eq found-target target)
              (set! found true)
              (set! index (+ index 1)))]))
      found)))

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
  symbols.len)

(define (compiler-object-symbol-list-ref
  [symbols : CompilerObjectSymbolList]
  [index : i64]) : CompilerObjectSymbol
  (array-ref symbols.slots index))

(define (compiler-object-relocation-list-count
  [relocs : CompilerObjectRelocationList]) : i64
  relocs.len)

(define (compiler-object-relocation-list-ref
  [relocs : CompilerObjectRelocationList]
  [index : i64]) : CompilerObjectRelocation
  (array-ref relocs.slots index))

(define (compiler-object-data-record-list-count
  [records : CompilerObjectDataRecordList]) : i64
  records.len)

(define (compiler-object-data-record-list-ref
  [records : CompilerObjectDataRecordList]
  [index : i64]) : CompilerObjectDataRecord
  (array-ref records.slots index))

(define (compiler-object-instr-list-count [instrs : CompilerObjectX64InstrList]) : i64
  instrs.len)

(define (compiler-object-instr-list-ref
  [instrs : CompilerObjectX64InstrList]
  [index : i64]) : CompilerObjectX64Instr
  (array-ref instrs.slots index))

(define (compiler-object-section-list-count
  [sections : CompilerObjectSectionList]) : i64
  sections.len)

(define (compiler-object-section-list-ref
  [sections : CompilerObjectSectionList]
  [index : i64]) : CompilerObjectSection
  (array-ref sections.slots index))

(define (compiler-object-image-dense? [_image : CompilerObjectImage]) : bool
  true)

(define (compiler-object-section-list-find
  [sections : CompilerObjectSectionList]
  [kind : CompilerObjectSectionKind]) : CompilerObjectSection
  (let
    [count : i64
      (compiler-object-section-list-count
        (owned_view.compiler-owned-shared-view sections))]
    [index : i64 0]
    [result : CompilerObjectSection
      (CompilerObjectSection.Section
        kind
        (CompilerObjectDataRecordList
          (__tl_make-array CompilerObjectDataRecord 0)
          0)
        (CompilerObjectX64InstrList
          (__tl_make-array CompilerObjectX64Instr 0)
          0))]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (let
          [section : CompilerObjectSection
            (compiler-object-section-list-ref
              (owned_view.compiler-owned-shared-view sections)
              index)]
          (match (owned_view.compiler-owned-shared-view section)
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
    [count : i64
      (compiler-object-symbol-list-count
        (owned_view.compiler-owned-shared-view symbols))]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (match (compiler-object-symbol-list-ref
          (owned_view.compiler-owned-shared-view symbols)
          index)
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
    [count : i64
      (compiler-object-relocation-list-count
        (owned_view.compiler-owned-shared-view relocs))]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (match (compiler-object-relocation-list-ref
          (owned_view.compiler-owned-shared-view relocs)
          index)
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
    [count : i64
      (compiler-object-data-record-list-count
        (owned_view.compiler-owned-shared-view records))]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (match (compiler-object-data-record-list-ref
          (owned_view.compiler-owned-shared-view records)
          index)
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
    [count : i64
      (compiler-object-data-record-list-count
        (owned_view.compiler-owned-shared-view records))]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (match (compiler-object-data-record-list-ref
          (owned_view.compiler-owned-shared-view records)
          index)
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
    [count : i64
      (compiler-object-data-record-list-count
        (owned_view.compiler-owned-shared-view records))]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (match (compiler-object-data-record-list-ref
          (owned_view.compiler-owned-shared-view records)
          index)
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
    [count : i64
      (compiler-object-data-record-list-count
        (owned_view.compiler-owned-shared-view records))]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (match (compiler-object-data-record-list-ref
          (owned_view.compiler-owned-shared-view records)
          index)
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
    [count : i64
      (compiler-object-data-record-list-count
        (owned_view.compiler-owned-shared-view records))]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (match (compiler-object-data-record-list-ref
          (owned_view.compiler-owned-shared-view records)
          index)
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
    [count : i64
      (compiler-object-data-record-list-count
        (owned_view.compiler-owned-shared-view records))]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (match (compiler-object-data-record-list-ref
          (owned_view.compiler-owned-shared-view records)
          index)
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
    [count : i64
      (compiler-object-data-record-list-count
        (owned_view.compiler-owned-shared-view records))]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (match (compiler-object-data-record-list-ref
          (owned_view.compiler-owned-shared-view records)
          index)
          [(CompilerObjectDataRecord.Label value)
            (if (and (string.eq value label) (< (+ index 2) count))
              (match (compiler-object-data-record-list-ref
                (owned_view.compiler-owned-shared-view records)
                (+ index 1))
                [(CompilerObjectDataRecord.I64 first-found)
                  (if (= first-found first)
                    (match (compiler-object-data-record-list-ref
                      (owned_view.compiler-owned-shared-view records)
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
    [count : i64
      (compiler-object-instr-list-count
        (owned_view.compiler-owned-shared-view instrs))]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (match (compiler-object-instr-list-ref
          (owned_view.compiler-owned-shared-view instrs)
          index)
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
    [(compiler-object-string-prefix-at?
        (owned_view.compiler-owned-shared-view haystack)
        (owned_view.compiler-owned-shared-view needle)
        start
        0)
      true]
    [else (compiler-object-string-contains? haystack needle (+ start 1))]))

(define (compiler-object-instr-list-contains-bytes?
  [instrs : CompilerObjectX64InstrList]
  [bytes : String]) : bool
  (let
    [count : i64
      (compiler-object-instr-list-count
        (owned_view.compiler-owned-shared-view instrs))]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (match (compiler-object-instr-list-ref
          (owned_view.compiler-owned-shared-view instrs)
          index)
          [(CompilerObjectX64Instr.Bytes value)
            (if (compiler-object-string-contains?
              value
              (owned_view.compiler-owned-shared-view bytes)
              0)
              (set! found true)
              (set! index (+ index 1)))]
          [(CompilerObjectX64Instr.Raw value)
            (if (compiler-object-string-contains?
              value
              (owned_view.compiler-owned-shared-view bytes)
              0)
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
    [count : i64
      (compiler-object-instr-list-count
        (owned_view.compiler-owned-shared-view instrs))]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (match (compiler-object-instr-list-ref
          (owned_view.compiler-owned-shared-view instrs)
          index)
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