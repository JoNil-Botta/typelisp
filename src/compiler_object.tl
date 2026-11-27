;; compiler_object.tl - Structured object-image records for backend object emitters.
(import stdlib.iterator)
(import stdlib.vector)
(import stdlib.sort)
(import stdlib.clone)
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as section_ids)
(import compiler_owned_view as owned_view)
(import compiler_machine_x64 as mx)
(import stdlib.string)

;; Lowering asks the target for one of these four semantic roles.
(defenum CompilerObjectSectionKind
  (Text)
  (Data)
  (Rodata)
  (Bss))

;; IDs are assigned by the image producer. Sorting a section never changes
;; the ID recorded by a symbol or a relocation.
(defstruct CompilerObjectSectionId
  (value i64))

(defenum CompilerObjectSectionFormat
  (Elf i64 i64)
  (Coff i64))

(defenum CompilerObjectSectionStorage
  (Initialized)
  (ZeroFill i64))

(defstruct CompilerObjectSectionSpec
  (id CompilerObjectSectionId)
  (order i64)
  (name String)
  (align i64)
  (storage CompilerObjectSectionStorage)
  (format CompilerObjectSectionFormat))

(define text-id : CompilerObjectSectionId
  (CompilerObjectSectionId 0))
(define data-id : CompilerObjectSectionId
  (CompilerObjectSectionId 1))
(define rodata-id : CompilerObjectSectionId
  (CompilerObjectSectionId 2))
(define bss-id : CompilerObjectSectionId
  (CompilerObjectSectionId 3))

(define (compiler-object-role-id [role : CompilerObjectSectionKind]) : CompilerObjectSectionId
  (match role
    [(Text) text-id]
    [(Data) data-id]
    [(Rodata) rodata-id]
    [(Bss) bss-id]))

(defenum CompilerObjectMaybeSection
  (No)
  (Some CompilerObjectSectionId))

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
  (Abs32)
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
  [record : (& CompilerObjectDataRecord)]
  [offset : i64]) : i64
  (match record
    [(Label _) offset]
    [(Align align)
      (if (<= align 1)
        offset
        (let
          [rem : i64 (% offset align)]
          (if (= rem 0)
            offset
            (+ offset (- align rem)))))]
    [(Bytes bytes) (+ offset (__tl_string_length bytes))]
    [(String text) (+ offset (+ (__tl_string_length text) 1))]
    [(or (F64 _) (I64 _) (SymbolAddress _)) (+ offset 8)]
    [(Zero count) (+ offset count)]
    [(or (F32 _) (SymbolRva32 _)) (+ offset 4)]))

(defstruct CompilerObjectDataRecordList
  (slots (__tl_dyn-array CompilerObjectDataRecord))
  (len i64))

(defenum CompilerObjectX64Instr
  (Label String)
  (Call String)
  (TailCall String)
  (Jump String)
  (Ja String)
  ;; `j<cc> rel32` for the x86 condition code `cc` (0x0-0xf): 0F 80+cc rel32.
  (Jcc i64 String)
  (Branch String String)
  (LoadRip String)
  (LoadRipAddress String)
  (LoadAbsAddress String)
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
  ;; A typed machine record (#7055): its bytes and its assembly text both come
  ;; from compiler_machine_x64.
  (Machine mx.MachineInstr)
  (Bytes String)
  (Raw String))

(define (compiler-object-condition-code-valid? [cc : i64]) : bool
  (and (>= cc 0) (< cc 16)))

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
    CompilerObjectSectionId
    String
    CompilerObjectRelocationKind
    String))

(defstruct CompilerObjectRelocationList
  (slots (__tl_dyn-array CompilerObjectRelocation))
  (len i64))

(defenum CompilerObjectSection
  (Section
    CompilerObjectSectionSpec
    CompilerObjectDataRecordList
    CompilerObjectX64InstrList))

(defstruct CompilerObjectSectionList
  (slots (__tl_dyn-array CompilerObjectSection))
  (len i64)
  (indices section_ids.Map))

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
  [dst : (&mut dst (__tl_dyn-array CompilerObjectDataRecord))]
  [src : (__tl_dyn-array CompilerObjectDataRecord)]
  [count : i64]) : unit
  (for [index (iterator.range 0 count)]
    (set!
      (array-ref dst index)
      (owned_view.compiler-owned-element-view src index))))

(define (compiler-object-instr-builder-copy-range!
  [dst : (&mut dst (__tl_dyn-array CompilerObjectX64Instr))]
  [src : (__tl_dyn-array CompilerObjectX64Instr)]
  [count : i64]) : unit
  (for [index (iterator.range 0 count)]
    (set!
      (array-ref dst index)
      (owned_view.compiler-owned-element-view src index))))

(define (compiler-object-symbol-builder-copy-range!
  [dst : (&mut dst (__tl_dyn-array CompilerObjectSymbol))]
  [src : (__tl_dyn-array CompilerObjectSymbol)]
  [count : i64]) : unit
  (for [index (iterator.range 0 count)]
    (set!
      (array-ref dst index)
      (owned_view.compiler-owned-element-view src index))))

(define (compiler-object-relocation-builder-copy-range!
  [dst : (&mut dst (__tl_dyn-array CompilerObjectRelocation))]
  [src : (__tl_dyn-array CompilerObjectRelocation)]
  [count : i64]) : unit
  (for [index (iterator.range 0 count)]
    (set!
      (array-ref dst index)
      (owned_view.compiler-owned-element-view src index))))

(define (compiler-object-section-builder-copy-range!
  [dst : (&mut dst (__tl_dyn-array CompilerObjectSection))]
  [src : (__tl_dyn-array CompilerObjectSection)]
  [count : i64]) : unit
  (for [index (iterator.range 0 count)]
    (set!
      (array-ref dst index)
      (owned_view.compiler-owned-element-view src index))))

(define (compiler-object-data-record-builder-grow
  [builder : CompilerObjectDataRecordBuilder]) : CompilerObjectDataRecordBuilder
  (let
    [count : i64 builder.count]
    [slots : (__tl_dyn-array CompilerObjectDataRecord) builder.slots]
    [bigger : (__tl_dyn-array CompilerObjectDataRecord)
      (__tl_make-array CompilerObjectDataRecord (* (array-length slots) 2))]
    (compiler-object-data-record-builder-copy-range! (&mut bigger) slots count)
    (CompilerObjectDataRecordBuilder bigger count)))

(define (compiler-object-instr-builder-grow
  [builder : CompilerObjectX64InstrBuilder]) : CompilerObjectX64InstrBuilder
  (let
    [count : i64 builder.count]
    [slots : (__tl_dyn-array CompilerObjectX64Instr) builder.slots]
    [bigger : (__tl_dyn-array CompilerObjectX64Instr)
      (__tl_make-array CompilerObjectX64Instr (* (array-length slots) 2))]
    (compiler-object-instr-builder-copy-range! (&mut bigger) slots count)
    (CompilerObjectX64InstrBuilder bigger count)))

(define (compiler-object-symbol-builder-grow
  [builder : CompilerObjectSymbolBuilder]) : CompilerObjectSymbolBuilder
  (let
    [count : i64 builder.count]
    [slots : (__tl_dyn-array CompilerObjectSymbol) builder.slots]
    [bigger : (__tl_dyn-array CompilerObjectSymbol)
      (__tl_make-array CompilerObjectSymbol (* (array-length slots) 2))]
    (compiler-object-symbol-builder-copy-range! (&mut bigger) slots count)
    (CompilerObjectSymbolBuilder bigger count)))

(define (compiler-object-relocation-builder-grow
  [builder : CompilerObjectRelocationBuilder]) : CompilerObjectRelocationBuilder
  (let
    [count : i64 builder.count]
    [slots : (__tl_dyn-array CompilerObjectRelocation) builder.slots]
    [bigger : (__tl_dyn-array CompilerObjectRelocation)
      (__tl_make-array CompilerObjectRelocation (* (array-length slots) 2))]
    (compiler-object-relocation-builder-copy-range! (&mut bigger) slots count)
    (CompilerObjectRelocationBuilder bigger count)))

(define (compiler-object-section-builder-grow
  [builder : CompilerObjectSectionBuilder]) : CompilerObjectSectionBuilder
  (let
    [count : i64 builder.count]
    [slots : (__tl_dyn-array CompilerObjectSection) builder.slots]
    [bigger : (__tl_dyn-array CompilerObjectSection)
      (__tl_make-array CompilerObjectSection (* (array-length slots) 2))]
    (compiler-object-section-builder-copy-range! (&mut bigger) slots count)
    (CompilerObjectSectionBuilder bigger count)))

(define (compiler-object-data-record-builder-push
  [builder : CompilerObjectDataRecordBuilder]
  [record : CompilerObjectDataRecord]) : CompilerObjectDataRecordBuilder
  (if (< builder.count (array-length builder.slots))
    (let
      [slots : (__tl_dyn-array CompilerObjectDataRecord) builder.slots]
      [count : i64 builder.count]
      (set! (array-ref slots count) record)
      (CompilerObjectDataRecordBuilder slots (+ count 1)))
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
      (set! (array-ref slots count) instr)
      (CompilerObjectX64InstrBuilder slots (+ count 1)))
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
      (set! (array-ref slots count) symbol)
      (CompilerObjectSymbolBuilder slots (+ count 1)))
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
      (set! (array-ref slots count) reloc)
      (CompilerObjectRelocationBuilder slots (+ count 1)))
    (compiler-object-relocation-builder-push
      (compiler-object-relocation-builder-grow builder)
      reloc)))

(define (compiler-object-section-less?
  [left : (& CompilerObjectSection)]
  [right : (& CompilerObjectSection)]) : bool
  (match left
    [(Section a _ _)
      (match right
        [(Section b _ _)
          (or
            (< a.order b.order)
            (and (= a.order b.order) (< a.id.value b.id.value)))])]))

(define (compiler-object-section-builder-push
  [builder : CompilerObjectSectionBuilder]
  [section : CompilerObjectSection]) : CompilerObjectSectionBuilder
  (if (< builder.count (array-length builder.slots))
    (let
      [slots : (__tl_dyn-array CompilerObjectSection) builder.slots]
      [count : i64 builder.count]
      (set! (array-ref slots count) section)
      (CompilerObjectSectionBuilder slots (+ count 1)))
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

;; Sort scalar keys so the merge sort never clones section payloads.
(defstruct SectionSortKey
  (order i64)
  (id i64)
  (source i64))

(clone.gen-clone SectionSortKey)

(define (eq-section-sort-key [a : (& SectionSortKey)] [b : (& SectionSortKey)]) : bool
  (and (= a.order b.order) (= a.id b.id) (= a.source b.source)))

(import (stdlib.vector.vector SectionSortKey) as section_keys)
(import (stdlib.sort.vec SectionSortKey) as section_sort)

(define (section-sort-key-less? [a : SectionSortKey] [b : SectionSortKey]) : bool
  (or (< a.order b.order) (and (= a.order b.order) (< a.id b.id))))

(define (compiler-object-empty-section [id : CompilerObjectSectionId]) : CompilerObjectSection
  (Section
    (CompilerObjectSectionSpec id 0 "" 1 (Initialized) (Elf 0 0))
    (compiler-object-data-record-list-empty)
    (compiler-object-instr-list-empty)))

(define (compiler-object-section-builder-finish
  [builder : CompilerObjectSectionBuilder]) : CompilerObjectSectionList
  (let
    [count : i64 builder.count]
    [slots : (__tl_dyn-array CompilerObjectSection) builder.slots]
    [indices : section_ids.Map (section_ids.with-capacity count)]
    [ordered? : bool true]
    (for [i (iterator.range 1 count)]
      (when
        (compiler-object-section-less?
          (& (array-ref slots i))
          (& (array-ref slots (- i 1))))
        (set! ordered? false)
        (break)))
    (unless
      ordered?
      (let
        [keys : section_keys.Vec (section_keys.with-capacity count)]
        [sorted : (__tl_dyn-array CompilerObjectSection)
          (__tl_make-array CompilerObjectSection count)]
        (for [i (iterator.range 0 count)]
          (match (& (array-ref slots i))
            [(Section spec _ _)
              (section_keys.push-ref!
                (&mut keys)
                (SectionSortKey spec.order spec.id.value i))]))
        (section_sort.sort! (&mut keys) section-sort-key-less?)
        (for [i (iterator.range 0 count)]
          (let
            [key (section_keys.get (& keys) i (SectionSortKey 0 0 0))]
            (set!
              (array-ref sorted i)
              (replace!
                (array-ref slots key.source)
                (compiler-object-empty-section text-id)))))
        (set! slots sorted)))
    (for [i (iterator.range 0 count)]
      (match (& (array-ref slots i))
        [(Section spec _ _)
          (section_ids.insert-ref! (&mut indices) spec.id.value i)]))
    (CompilerObjectSectionList slots count indices)))

(define (compiler-object-section-list-index
  [sections : (& CompilerObjectSectionList)]
  [id : CompilerObjectSectionId]) : i64
  (section_ids.get-value-or (& sections.indices) id.value -1))

;; Fresh empty lists: each section that has no records or instructions owns
;; its own.
(define (compiler-object-data-record-list-empty) : CompilerObjectDataRecordList
  (compiler-object-data-record-builder-finish
    (compiler-object-data-record-builder-with-capacity 1)))

(define (compiler-object-instr-list-empty) : CompilerObjectX64InstrList
  (compiler-object-instr-builder-finish
    (compiler-object-instr-builder-with-capacity 1)))

(define (compiler-object-symbol-builder-contains?
  [builder : (& CompilerObjectSymbolBuilder)]
  [name : (& name str)]
  [binding : CompilerObjectSymbolBinding]
  [kind : CompilerObjectSymbolKind]) : bool
  (let
    [count : i64 builder.count]
    [index : i64 0]
    [found : bool false]
    (while (and (not found) (< index count))
      (match (& (array-ref builder.slots index))
        [(Symbol found-name found-binding found-kind _)
          (if (and
            (string.eq found-name name)
            (compiler-object-symbol-binding-eq? found-binding binding)
            (compiler-object-symbol-kind-eq? found-kind kind))
            (set! found true)
            (+= index 1))]))
    found))

(define (compiler-object-relocation-builder-targets?
  [builder : (& builder CompilerObjectRelocationBuilder)]
  [target : (& target str)]) : bool
  (let
    [count : i64 builder.count]
    [slots : (__tl_dyn-array CompilerObjectRelocation) builder.slots]
    [index : i64 0]
    [found : bool false]
    (while (and (not found) (< index count))
      (match (array-ref slots index)
        [(Relocation _ _ _ found-target)
          (if (string.eq found-target target)
            (set! found true)
            (+= index 1))]))
    found))

(define (compiler-object-section-id-eq?
  [a : CompilerObjectSectionId]
  [b : CompilerObjectSectionId]) : bool
  (= a.value b.value))

(define (compiler-object-symbol-binding-eq?
  [a : CompilerObjectSymbolBinding]
  [b : CompilerObjectSymbolBinding]) : bool
  (match a
    [(Local)
      (match b
        [(Local) true]
        [_ false])]
    [(Export)
      (match b
        [(Export) true]
        [_ false])]
    [(Extern)
      (match b
        [(Extern) true]
        [_ false])]))

(define (compiler-object-symbol-kind-eq?
  [a : CompilerObjectSymbolKind]
  [b : CompilerObjectSymbolKind]) : bool
  (match a
    [(Function)
      (match b
        [(Function) true]
        [_ false])]
    [(Data)
      (match b
        [(Data) true]
        [_ false])]
    [(Section)
      (match b
        [(Section) true]
        [_ false])]
    [(Runtime)
      (match b
        [(Runtime) true]
        [_ false])]))

(define (compiler-object-relocation-kind-eq?
  [a : CompilerObjectRelocationKind]
  [b : CompilerObjectRelocationKind]) : bool
  (match a
    [(Call)
      (match b
        [(Call) true]
        [_ false])]
    [(TailCall)
      (match b
        [(TailCall) true]
        [_ false])]
    [(Abs64)
      (match b
        [(Abs64) true]
        [_ false])]
    [(Abs32)
      (match b
        [(Abs32) true]
        [_ false])]
    [(Addr32Nb)
      (match b
        [(Addr32Nb) true]
        [_ false])]
    [(RipValue)
      (match b
        [(RipValue) true]
        [_ false])]
    [(RipAddress)
      (match b
        [(RipAddress) true]
        [_ false])]
    [(Branch)
      (match b
        [(Branch) true]
        [_ false])]))

(define (compiler-object-symbol-list-count
  [symbols : (& symbols CompilerObjectSymbolList)]) : i64
  symbols.len)

(define (compiler-object-symbol-list-ref
  [symbols : (& symbols CompilerObjectSymbolList)]
  [index : i64]) : CompilerObjectSymbol
  (owned_view.compiler-owned-reference-shared-view
    (& (array-ref symbols.slots index))))

(define (compiler-object-relocation-list-count
  [relocs : (& relocs CompilerObjectRelocationList)]) : i64
  relocs.len)

(define (compiler-object-relocation-list-ref
  [relocs : (& relocs CompilerObjectRelocationList)]
  [index : i64]) : CompilerObjectRelocation
  (owned_view.compiler-owned-reference-shared-view
    (& (array-ref relocs.slots index))))

(define (compiler-object-data-record-list-count
  [records : (& records CompilerObjectDataRecordList)]) : i64
  records.len)

(define (compiler-object-data-record-list-ref
  [records : (& records CompilerObjectDataRecordList)]
  [index : i64]) : CompilerObjectDataRecord
  (owned_view.compiler-owned-reference-shared-view
    (& (array-ref records.slots index))))

(define (compiler-object-instr-list-count
  [instrs : (& instrs CompilerObjectX64InstrList)]) : i64
  instrs.len)

(define (compiler-object-instr-list-ref
  [instrs : (& instrs CompilerObjectX64InstrList)]
  [index : i64]) : CompilerObjectX64Instr
  (owned_view.compiler-owned-reference-shared-view
    (& (array-ref instrs.slots index))))

(define (compiler-object-section-list-count
  [sections : (& sections CompilerObjectSectionList)]) : i64
  sections.len)

(define (compiler-object-section-list-ref
  [sections : (& sections CompilerObjectSectionList)]
  [index : i64]) : CompilerObjectSection
  (owned_view.compiler-owned-reference-shared-view
    (& (array-ref sections.slots index))))

(define (compiler-object-section-list-find
  [sections : (& CompilerObjectSectionList)]
  [id : CompilerObjectSectionId]) : CompilerObjectSection
  (let
    [i (compiler-object-section-list-index sections id)]
    (when (>= i 0) (return (compiler-object-section-list-ref sections i))))
  (compiler-object-empty-section id))

(define (compiler-object-symbol-list-contains?
  [symbols : (& symbols CompilerObjectSymbolList)]
  [name : (& name str)]
  [binding : CompilerObjectSymbolBinding]
  [kind : CompilerObjectSymbolKind]) : bool
  (let
    [count : i64 (compiler-object-symbol-list-count symbols)]
    [index : i64 0]
    [found : bool false]
    (while (and (not found) (< index count))
      (match (compiler-object-symbol-list-ref symbols index)
        [(Symbol found-name found-binding found-kind _)
          (if (and
            (string.eq found-name name)
            (compiler-object-symbol-binding-eq? found-binding binding)
            (compiler-object-symbol-kind-eq? found-kind kind))
            (set! found true)
            (+= index 1))]))
    found))

(define (compiler-object-relocation-list-contains?
  [relocs : (& relocs CompilerObjectRelocationList)]
  [kind : CompilerObjectRelocationKind]
  [target : (& target str)]) : bool
  (let
    [count : i64 (compiler-object-relocation-list-count relocs)]
    [index : i64 0]
    [found : bool false]
    (while (and (not found) (< index count))
      (match (compiler-object-relocation-list-ref relocs index)
        [(Relocation _ _ found-kind found-target)
          (if (and
            (compiler-object-relocation-kind-eq? found-kind kind)
            (string.eq found-target target))
            (set! found true)
            (+= index 1))]))
    found))

(define (compiler-object-data-record-list-contains-label?
  [records : (& CompilerObjectDataRecordList)]
  [label : (& label str)]) : bool
  (let
    [count : i64 (compiler-object-data-record-list-count records)]
    [index : i64 0]
    [found : bool false]
    (while (and (not found) (< index count))
      (match (compiler-object-data-record-list-ref records index)
        [(Label value)
          (if (string.eq value label)
            (set! found true)
            (+= index 1))]
        [_ (+= index 1)]))
    found))

(define (compiler-object-section-contains-label?
  [sections : (& sections CompilerObjectSectionList)]
  [kind : CompilerObjectSectionId]
  [label : (& label str)]) : bool
  (match (compiler-object-section-list-find sections kind)
    [(Section _ data _)
      (compiler-object-data-record-list-contains-label? (& data) label)]))

(define (compiler-object-string-prefix-at?
  [haystack : (& haystack str)]
  [needle : (& needle str)]
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
  [haystack : (& str)]
  [needle : (& needle str)]
  [start : i64]) : bool
  (cond
    [(= (string.string-length needle) 0) true]
    [(> (+ start (string.string-length needle)) (string.string-length haystack))
      false]
    [(compiler-object-string-prefix-at? haystack needle start 0) true]
    [else (compiler-object-string-contains? haystack needle (+ start 1))]))

(define (compiler-object-instr-list-contains-bytes?
  [instrs : (& CompilerObjectX64InstrList)]
  [bytes : (& bytes str)]) : bool
  (let
    [count : i64 (compiler-object-instr-list-count instrs)]
    [index : i64 0]
    [found : bool false]
    (while (and (not found) (< index count))
      (match (compiler-object-instr-list-ref instrs index)
        [(or (Bytes value) (Raw value))
          (if (compiler-object-string-contains? (& value) bytes 0)
            (set! found true)
            (+= index 1))]
        [_ (+= index 1)]))
    found))

(define (compiler-object-section-contains-bytes?
  [sections : (& sections CompilerObjectSectionList)]
  [bytes : (& str)]) : bool
  (match (compiler-object-section-list-find sections text-id)
    [(Section _ _ instrs)
      (compiler-object-instr-list-contains-bytes? (& instrs) bytes)]))