;; compiler_object_coff.tl - COFF object-file serialization for object images.
(cfg test (import compiler_object_windows_sections as coff_sections))
(import stdlib.iterator)
(import stdlib.byte_buf_core)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.string)
(import compiler_object as cobj)
(import compiler_object_layout as layout)
(cfg test (import stdlib.test))

(defenum ResultCompilerObjectCoff
  (Ok String)
  (Err String))

(defstruct CoffSectionHeader
  (name-offset i64)
  (size i64)
  (data i64)
  (relocs i64)
  (count i64)
  (flags i64))

(defstruct CoffProjection
  (groups layout.SectionRelocations)
  (rows (__tl_dyn-array CoffSectionHeader))
  (symbols i64)
  (string-size i64)
  (size i64))

(defenum ResultCompilerObjectCoffLayout
  (Ok CoffProjection)
  (Err String))

(defstruct CompilerObjectCoffLayoutAccumulator
  (offset i64)
  (error String))

(define compiler-object-coff-machine-amd64 : i64
  0x8664)
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
  layout.compiler-object-max-file-size)
(define compiler-object-coff-reloc-amd64-addr64 : i64
  0x0001)
(define compiler-object-coff-reloc-amd64-rel32 : i64
  0x0004)
(define compiler-object-coff-reloc-amd64-addr32nb : i64
  0x0003)
(define compiler-object-coff-section-lnk-nreloc-ovfl : i64
  0x01000000)

(define (compiler-object-coff-section-number
  [image : (& cobj.CompilerObjectImage)]
  [kind : cobj.CompilerObjectSectionId]) : i64
  (+ 1 (layout.compiler-object-layout-section-index image kind)))

(define (compiler-object-coff-push-name8!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [name : (& name str)]) : unit
  (let
    [n : i64 (layout.compiler-object-layout-string-length name)]
    (for [i (iterator.range 0 8)]
      (if (< i n)
        (byte_buf_core.byte-buf-builder-push
          out
          (cast (layout.compiler-object-layout-string-ref name i) : u8))
        (layout.compiler-object-layout-push-u8! out 0)))
    unit))

(define (compiler-object-coff-relocation-list-supported?
  [relocs : (& relocs cobj.CompilerObjectRelocationList)]) : bool
  (layout.compiler-object-layout-relocation-list-supported? relocs true))

;; Raw text bytes are ELF-only.
(define (compiler-object-coff-symbol-index-from
  [symbols : (& symbols cobj.CompilerObjectSymbolList)]
  [name : (& str)]
  [index : i64]) : i64
  (let
    [count : i64 (cobj.compiler-object-symbol-list-count symbols)]
    [slot : i64 0]
    [cur-index : i64 index]
    [result : i64 -1]
    [done : bool false]
    (while (and (not done) (< slot count))
      (match (cobj.compiler-object-symbol-list-ref symbols slot)
        [(Symbol found _ _ _)
          (if (string.eq found name)
            (begin
              (set! result cur-index)
              (set! done true))
            (begin
              (+= cur-index 1)
              (+= slot 1)))]))
    result))

(define (compiler-object-coff-symbol-index
  [image : (& image cobj.CompilerObjectImage)]
  [name : (& str)]) : i64
  (compiler-object-coff-symbol-index-from image.symbols (& name) 0))

(define (compiler-object-coff-relocation-sites-known?
  [image : (& image cobj.CompilerObjectImage)]
  [relocs : (& relocs cobj.CompilerObjectRelocationList)]) : bool
  (let
    [count : i64 (cobj.compiler-object-relocation-list-count relocs)]
    [index : i64 0]
    [ok : bool true]
    (while (and ok (< index count))
      (match (cobj.compiler-object-relocation-list-ref relocs index)
        [(Relocation section site _ target)
          (if (match section.value
            [0 (>= (compiler-object-coff-symbol-index image (& target)) 0)]
            [_
              (and
                (>=
                  (layout.compiler-object-layout-section-label-offset
                    image
                    section
                    (& site))
                  0)
                (>= (compiler-object-coff-symbol-index image (& target)) 0))])
            (+= index 1)
            (set! ok false))]))
    ok))

(define (compiler-object-coff-fixups-supported?
  [image : (& image cobj.CompilerObjectImage)]) : bool
  (and
    (compiler-object-coff-relocation-list-supported? image.relocations)
    (compiler-object-coff-relocation-sites-known? image image.relocations)
    (layout.compiler-object-layout-text-targets-known? image)
    (layout.compiler-object-layout-text-relocation-count-matches? image)))

(define (compiler-object-coff-image-supported?
  [image : (& cobj.CompilerObjectImage)]) : bool
  (let
    [error (layout.compiler-object-layout-image-error image true)]
    (and
      (string.eq (& error) "")
      (compiler-object-coff-fixups-supported? image))))

(define (compiler-object-coff-header-size
  [image : (& cobj.CompilerObjectImage)]) : i64
  (+
    compiler-object-coff-file-header-size
    (* compiler-object-coff-section-header-size image.sections.len)))

(define (compiler-object-coff-relocation-count-overflows?
  [semantic-count : i64]) : bool
  (>= semantic-count compiler-object-coff-relocation-overflow-threshold))

(define (compiler-object-coff-relocation-physical-count [semantic-count : i64]) : i64
  (if (compiler-object-coff-relocation-count-overflows? semantic-count)
    (+ semantic-count 1)
    semantic-count))

;; Encode a power-of-two byte alignment as COFF IMAGE_SCN_ALIGN_*BYTES:
;; `(log2(align) + 1) << 20`, clamped to the COFF maximum of 8192 bytes.
(define (compiler-object-coff-align-flag [align : i64]) : i64
  (let
    [clamped : i64 (cond [(< align 1) 1] [(> align 8192) 8192] [else align])]
    [shift : i64 0]
    (while (and (< (shl 1 shift) clamped) (< shift 13))
      (+= shift 1))
    (shl (+ shift 1) 20)))

(define (compiler-object-coff-section-flags-for
  [image : (& cobj.CompilerObjectImage)]
  [kind : cobj.CompilerObjectSectionId]) : i64
  (match (layout.compiler-object-layout-spec image kind).format
    [(Coff flags)
      (bit-or
        flags
        (compiler-object-coff-align-flag
          (layout.compiler-object-layout-section-align image kind)))]
    [_ 0]))

(define (compiler-object-coff-push-file-header!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [section-count : i64]
  [symbol-offset : i64]
  [symbol-count : i64]) : unit
  (layout.compiler-object-layout-push-u16!
    out
    compiler-object-coff-machine-amd64)
  (layout.compiler-object-layout-push-u16! out section-count)
  (layout.compiler-object-layout-push-u32! out 0)
  (layout.compiler-object-layout-push-u32! out symbol-offset)
  (layout.compiler-object-layout-push-u32! out symbol-count)
  (layout.compiler-object-layout-push-u16! out 0)
  (layout.compiler-object-layout-push-u16! out 0))

(define (compiler-object-coff-push-section-header!
  [out : (&mut byte_buf_core.ByteBufBuilder)]
  [name : (& str)]
  [row : (& CoffSectionHeader)]) : unit
  (if (= row.name-offset 0)
    (compiler-object-coff-push-name8! out name)
    (compiler-object-coff-push-name8!
      out
      (& (str_cat.str-cat "/" (string.int->string row.name-offset)))))
  (layout.compiler-object-layout-push-u32! out 0)
  (layout.compiler-object-layout-push-u32! out 0)
  (layout.compiler-object-layout-push-u32! out row.size)
  (layout.compiler-object-layout-push-u32! out row.data)
  (layout.compiler-object-layout-push-u32! out row.relocs)
  (layout.compiler-object-layout-push-u32! out 0)
  (layout.compiler-object-layout-push-u16!
    out
    (if (compiler-object-coff-relocation-count-overflows? row.count)
      compiler-object-coff-relocation-overflow-threshold
      row.count))
  (layout.compiler-object-layout-push-u16! out 0)
  (layout.compiler-object-layout-push-u32! out row.flags))

(define (compiler-object-coff-render-sections!
  [out : (&mut byte_buf_core.ByteBufBuilder)]
  [image : (& cobj.CompilerObjectImage)]
  [plan : (& CoffProjection)]) : unit
  (for [i (iterator.range 0 image.sections.len)]
    (when
      (> (array-ref plan.rows i).data 0)
      (layout.compiler-object-layout-render-section!
        out
        image
        (layout.compiler-object-layout-section-at image i)))))

(define (compiler-object-coff-relocation-type
  [kind : cobj.CompilerObjectRelocationKind]) : i64
  (match kind
    [(or (Call) (TailCall) (RipValue) (RipAddress) (Branch))
      compiler-object-coff-reloc-amd64-rel32]
    [(Abs64) compiler-object-coff-reloc-amd64-addr64]
    [(Addr32Nb) compiler-object-coff-reloc-amd64-addr32nb]
    [_ 0]))

(define (compiler-object-coff-render-relocation-record!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]
  [offset : i64]
  [kind : cobj.CompilerObjectRelocationKind]
  [target : (& str)]) : unit
  (layout.compiler-object-layout-push-u32! out offset)
  (layout.compiler-object-layout-push-u32!
    out
    (compiler-object-coff-symbol-index image (& target)))
  (layout.compiler-object-layout-push-u16!
    out
    (compiler-object-coff-relocation-type kind)))

(define (compiler-object-coff-render-relocation!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]
  [reloc : (& cobj.CompilerObjectRelocation)]) : unit
  (match reloc
    [(Relocation section site kind target)
      (compiler-object-coff-render-relocation-record!
        out
        image
        (layout.compiler-object-layout-section-label-offset image section site)
        kind
        target)]))

(define (compiler-object-coff-render-relocation-overflow-sentinel!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [semantic-count : i64]) : unit
  (when
    (compiler-object-coff-relocation-count-overflows? semantic-count)
    ;; COFF stores the physical table-entry count in the sentinel.  The
    ;; sentinel itself has no symbol or relocation type and is not part of
    ;; the compiler's semantic relocation stream.
    (layout.compiler-object-layout-push-u32!
      out
      (compiler-object-coff-relocation-physical-count semantic-count))
    (layout.compiler-object-layout-push-u32! out 0)
    (layout.compiler-object-layout-push-u16! out 0)))

(define (compiler-object-coff-render-text-relocations!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]) : unit
  (match (cobj.compiler-object-section-list-find image.sections cobj.text-id)
    [(Section _ _ instrs)
      (let
        [count : i64 (cobj.compiler-object-instr-list-count instrs)]
        [end : i64 0]
        (for [index (iterator.range 0 count)]
          (let
            [instr : cobj.CompilerObjectX64Instr
              (cobj.compiler-object-instr-list-ref instrs index)]
            (+= end (layout.compiler-object-layout-instr-size (& instr)))
            (match (layout.compiler-object-layout-instr-fixup (& instr))
              [(None) unit]
              [(One kind target)
                (compiler-object-coff-render-relocation-record!
                  out
                  image
                  (- end 4)
                  kind
                  (& target))]
              [(Branch true-target false-target)
                (compiler-object-coff-render-relocation-record!
                  out
                  image
                  (- end 9)
                  (Branch)
                  (& true-target))
                (compiler-object-coff-render-relocation-record!
                  out
                  image
                  (- end 4)
                  (Branch)
                  (& false-target))])))
        unit)]))

(define (compiler-object-coff-render-relocations!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]
  [plan : (& CoffProjection)]) : unit
  (for [index (iterator.range 0 image.sections.len)]
    (let
      [kind : cobj.CompilerObjectSectionId
        (layout.compiler-object-layout-section-at image index)]
      (compiler-object-coff-render-relocation-overflow-sentinel!
        out
        (array-ref plan.rows index).count)
      (match kind.value
        [0 (compiler-object-coff-render-text-relocations! out image)]
        [_
          (let
            [entry : i64 (array-ref plan.groups.heads index)]
            (while (> entry 0)
              (compiler-object-coff-render-relocation!
                out
                image
                (& (array-ref image.relocations.slots (- entry 1))))
              (set! entry (array-ref plan.groups.next (- entry 1)))))]))))

(define (compiler-object-coff-symbol-name-long? [name : (& name str)]) : bool
  (> (layout.compiler-object-layout-string-length name) 8))

(define (compiler-object-coff-symbol-string-offset-from
  [symbols : (& symbols cobj.CompilerObjectSymbolList)]
  [name : (& name str)]
  [offset : i64]) : i64
  (let
    [count : i64 (cobj.compiler-object-symbol-list-count symbols)]
    [index : i64 0]
    [cur-offset : i64 offset]
    [result : i64 0]
    [done : bool false]
    (while (and (not done) (< index count))
      (match (cobj.compiler-object-symbol-list-ref symbols index)
        [(Symbol found _ _ _)
          (if (compiler-object-coff-symbol-name-long? found)
            (if (string.eq found name)
              (begin
                (set! result cur-offset)
                (set! done true))
              (begin
                (+=
                  cur-offset
                  (+ (layout.compiler-object-layout-string-length found) 1))
                (+= index 1)))
            (+= index 1))]))
    result))

(define (compiler-object-coff-symbol-string-offset
  [image : (& image cobj.CompilerObjectImage)]
  [name : (& name str)]) : i64
  (compiler-object-coff-symbol-string-offset-from image.symbols name 4))

(define (compiler-object-coff-push-symbol-name!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]
  [name : (& name str)]) : unit
  (if (compiler-object-coff-symbol-name-long? name)
    (begin
      (layout.compiler-object-layout-push-u32! out 0)
      (layout.compiler-object-layout-push-u32!
        out
        (compiler-object-coff-symbol-string-offset image name)))
    (compiler-object-coff-push-name8! out name)))

(define (compiler-object-coff-symbol-storage-class
  [binding : cobj.CompilerObjectSymbolBinding]) : i64
  (match binding
    [(Local) 3]
    [_ 2]))

(define (compiler-object-coff-symbol-type
  [kind : cobj.CompilerObjectSymbolKind]) : i64
  (match kind
    [(Function) 0x20]
    [_ 0]))

(define (compiler-object-coff-symbol-section-number
  [image : (& cobj.CompilerObjectImage)]
  [section : cobj.CompilerObjectMaybeSection]) : i64
  (match section
    [(No) 0]
    [(Some kind) (compiler-object-coff-section-number image kind)]))

(define (compiler-object-coff-render-symbol!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]
  [symbol : (& cobj.CompilerObjectSymbol)]) : unit
  (match symbol
    [(Symbol name binding kind section)
      (compiler-object-coff-push-symbol-name! out image name)
      (layout.compiler-object-layout-push-u32!
        out
        (layout.compiler-object-layout-symbol-value image name section))
      (layout.compiler-object-layout-push-u16!
        out
        (compiler-object-coff-symbol-section-number image section))
      (layout.compiler-object-layout-push-u16!
        out
        (compiler-object-coff-symbol-type kind))
      (layout.compiler-object-layout-push-u8!
        out
        (compiler-object-coff-symbol-storage-class binding))
      (layout.compiler-object-layout-push-u8! out 0)]))

(define (compiler-object-coff-render-symbols!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]
  [symbols : (& symbols cobj.CompilerObjectSymbolList)]) : unit
  (let
    [count : i64 (cobj.compiler-object-symbol-list-count symbols)]
    (for [index (iterator.range 0 count)]
      (compiler-object-coff-render-symbol!
        out
        image
        (& (cobj.compiler-object-symbol-list-ref symbols index))))
    unit))

(define (compiler-object-coff-string-table-size-from
  [symbols : (& symbols cobj.CompilerObjectSymbolList)]
  [size : i64]) : i64
  (let
    [count : i64 (cobj.compiler-object-symbol-list-count symbols)]
    [total : i64 size]
    (for [index (iterator.range 0 count)]
      (match (cobj.compiler-object-symbol-list-ref symbols index)
        [(Symbol name _ _ _)
          (if (compiler-object-coff-symbol-name-long? name)
            (+= total (+ (layout.compiler-object-layout-string-length name) 1))
            unit)]))
    total))

(define (compiler-object-coff-string-table-size
  [symbols : (& symbols cobj.CompilerObjectSymbolList)]) : i64
  (compiler-object-coff-string-table-size-from symbols 4))

(define (compiler-object-coff-layout-accumulator-ok?
  [acc : (& acc CompilerObjectCoffLayoutAccumulator)]) : bool
  (= (layout.compiler-object-layout-string-length acc.error) 0))

(define (compiler-object-coff-layout-section-error
  [name : (& str)]
  [semantic-count : i64]
  [detail : String]) : String
  (str_cat.str-cat
    "coff: windows-x86_64 section "
    (string.copy name)
    " relocation count "
    (string.int->string semantic-count)
    " "
    detail))

;; This helper is intentionally count-based so boundary and malformed states
;; can be tested without first allocating an equally large relocation list.
(define (compiler-object-coff-check-relocation-count-layout
  [acc : CompilerObjectCoffLayoutAccumulator]
  [name : (& str)]
  [semantic-count : i64]
  [max-output-size : i64]) : CompilerObjectCoffLayoutAccumulator
  (if (not (compiler-object-coff-layout-accumulator-ok? acc))
    acc
    (cond
      [(< semantic-count 0)
        (CompilerObjectCoffLayoutAccumulator
          acc.offset
          (compiler-object-coff-layout-section-error
            name
            semantic-count
            "is negative"))]
      [(and
          (compiler-object-coff-relocation-count-overflows? semantic-count)
          (> semantic-count (- compiler-object-coff-max-u32 1)))
        (CompilerObjectCoffLayoutAccumulator
          acc.offset
          (compiler-object-coff-layout-section-error
            name
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
                name
                semantic-count
                "physical relocation table exceeds the configured object-size limit"))
            (CompilerObjectCoffLayoutAccumulator
              (+
                acc.offset
                (* physical-count compiler-object-coff-relocation-size))
              "")))])))

(define (compiler-object-coff-check-symbol-table-layout
  [acc : CompilerObjectCoffLayoutAccumulator]
  [symbols : (& symbols cobj.CompilerObjectSymbolList)]
  [max-output-size : i64]) : CompilerObjectCoffLayoutAccumulator
  (if (not (compiler-object-coff-layout-accumulator-ok? acc))
    acc
    (let
      [count : i64 (cobj.compiler-object-symbol-list-count symbols)]
      (if (or
        (< count 0)
        (> count compiler-object-coff-max-u32)
        (> count (/ max-output-size 18))
        (> acc.offset max-output-size)
        (> (* count 18) (- max-output-size acc.offset)))
        (begin
          (set!
            acc.error
            (str_cat.str-cat
              "coff: windows-x86_64 symbol count "
              (string.int->string count)
              " exceeds the COFF or configured object-size limit"))
          acc)
        (CompilerObjectCoffLayoutAccumulator (+ acc.offset (* count 18)) "")))))

(define (compiler-object-coff-check-string-table-layout
  [acc : CompilerObjectCoffLayoutAccumulator]
  [symbols : (& symbols cobj.CompilerObjectSymbolList)]
  [max-output-size : i64]) : CompilerObjectCoffLayoutAccumulator
  (if (not (compiler-object-coff-layout-accumulator-ok? acc))
    acc
    (let
      [count : i64 (cobj.compiler-object-symbol-list-count symbols)]
      [index : i64 0]
      [table-size : i64 4]
      [error : String ""]
      (while (and
        (= (layout.compiler-object-layout-string-length error) 0)
        (< index count))
        (match (cobj.compiler-object-symbol-list-ref symbols index)
          [(Symbol name _ _ _)
            (if (compiler-object-coff-symbol-name-long? name)
              (let
                [name-size : i64
                  (layout.compiler-object-layout-string-length name)]
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
                  (+= table-size (+ name-size 1))))
              unit)])
        (+= index 1))
      (if (> (layout.compiler-object-layout-string-length error) 0)
        (begin
          (set! acc.error error)
          acc)
        (if (or
          (> acc.offset max-output-size)
          (> table-size (- max-output-size acc.offset)))
          (begin
            (set!
              acc.error
              (str_cat.str-cat
                "coff: windows-x86_64 string table size "
                (string.int->string table-size)
                " exceeds the configured object-size limit"))
            acc)
          (CompilerObjectCoffLayoutAccumulator (+ acc.offset table-size) ""))))))

(define (compiler-object-coff-project
  [image : (& cobj.CompilerObjectImage)]
  [limit : i64]) : ResultCompilerObjectCoffLayout
  (let
    [error (layout.compiler-object-layout-image-error image true)]
    (unless (string.eq (& error) "") (return (Err error))))
  (unless
    (compiler-object-coff-fixups-supported? image)
    (return
      (Err
        "coff: object image contains unsupported text, f64, or relocation records")))
  (let
    [groups (layout.compiler-object-layout-group-relocations image)]
    [rows : (__tl_dyn-array CoffSectionHeader)
      (__tl_make-array CoffSectionHeader image.sections.len)]
    [offset : i64 (compiler-object-coff-header-size image)]
    [string-size : i64 (compiler-object-coff-string-table-size image.symbols)]
    (for [i (iterator.range 0 image.sections.len)]
      (match (& (array-ref image.sections.slots i))
        [(Section spec _ _)
          (let
            [size
              (layout.compiler-object-layout-section-size
                (& (array-ref image.sections.slots i)))]
            [raw
              (match spec.storage
                [(Initialized) size]
                [_ 0])]
            [len (string.string-length spec.name)]
            [id (layout.compiler-object-layout-section-at image i)]
            (when
              (> raw (- limit offset))
              (return
                (Err
                  (str_cat.str-cat
                    "coff: section exceeds size limit: "
                    (string.copy spec.name)))))
            (when
              (and (> len 8) (> string-size 9999999))
              (return
                (Err
                  (str_cat.str-cat
                    "coff: long section name offset exceeds seven decimal digits: "
                    (string.copy spec.name)))))
            (set!
              (array-ref rows i)
              (CoffSectionHeader
                (if (> len 8)
                  string-size
                  0)
                size
                (if (> raw 0)
                  offset
                  0)
                0
                (array-ref groups.counts i)
                (compiler-object-coff-section-flags-for image id)))
            (when (> len 8) (+= string-size (+ len 1)))
            (+= offset raw))]))
    (let
      [acc : CompilerObjectCoffLayoutAccumulator
        (CompilerObjectCoffLayoutAccumulator offset "")]
      (for [i (iterator.range 0 image.sections.len)]
        (let
          [count (array-ref rows i).count]
          (when
            (> count 0)
            (set! (array-ref rows i).relocs acc.offset)
            (when
              (compiler-object-coff-relocation-count-overflows? count)
              (set!
                (array-ref rows i).flags
                (bit-or
                  (array-ref rows i).flags
                  compiler-object-coff-section-lnk-nreloc-ovfl)))
            (match (& (array-ref image.sections.slots i))
              [(Section spec _ _)
                (set!
                  acc
                  (compiler-object-coff-check-relocation-count-layout
                    acc
                    spec.name
                    count
                    limit))])
            (unless
              (compiler-object-coff-layout-accumulator-ok? acc)
              (return (Err acc.error))))))
      (let
        [symbols : i64 acc.offset]
        (set!
          acc
          (compiler-object-coff-check-symbol-table-layout
            acc
            image.symbols
            limit))
        (unless
          (compiler-object-coff-layout-accumulator-ok? acc)
          (return (Err acc.error)))
        (set! offset acc.offset)
        (set!
          acc
          (compiler-object-coff-check-string-table-layout
            acc
            image.symbols
            limit))
        (unless
          (compiler-object-coff-layout-accumulator-ok? acc)
          (return (Err acc.error)))
        (when
          (> string-size (- limit offset))
          (return
            (Err "coff: section name string table exceeds file size limit")))
        (Ok
          (CoffProjection
            groups
            rows
            symbols
            string-size
            (+ offset string-size)))))))

(define (compiler-object-coff-render-string-table-symbols!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [symbols : (& symbols cobj.CompilerObjectSymbolList)]) : unit
  (let
    [count : i64 (cobj.compiler-object-symbol-list-count symbols)]
    (for [index (iterator.range 0 count)]
      (match (cobj.compiler-object-symbol-list-ref symbols index)
        [(Symbol name _ _ _)
          (when
            (compiler-object-coff-symbol-name-long? name)
            (layout.compiler-object-layout-push-string-bytes! out name)
            (layout.compiler-object-layout-push-u8! out 0))]))
    unit))

(define (compiler-object-coff-render-string-table!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]
  [plan : (& CoffProjection)]) : unit
  (layout.compiler-object-layout-push-u32! out plan.string-size)
  (compiler-object-coff-render-string-table-symbols! out image.symbols)
  (for [i (iterator.range 0 image.sections.len)]
    (match (& (array-ref image.sections.slots i))
      [(Section spec _ _)
        (when
          (> (string.string-length spec.name) 8)
          (layout.compiler-object-layout-push-string-bytes! out spec.name)
          (layout.compiler-object-layout-push-u8! out 0))])))

(defstruct CoffAssembly
  (names (__tl_dyn-array String))
  (contents (__tl_dyn-array byte_buf_core.ByteBufBuilder))
  (relocs byte_buf_core.ByteBufBuilder)
  (symbols byte_buf_core.ByteBufBuilder)
  (strings byte_buf_core.ByteBufBuilder))

(defenum CoffPayloads
  (:lifetimes source plan)
  (ObjectImage (& source cobj.CompilerObjectImage) (& plan CoffProjection))
  (Assembled (& source CoffAssembly)))

(define (append-buffer!
  [out : (&mut byte_buf_core.ByteBufBuilder)]
  [b : (& byte_buf_core.ByteBufBuilder)]) : unit
  (byte_buf_core.byte-buf-builder-append-array-range out (& b.slots) 0 b.len))

(define (serialize
  [rows : (& (__tl_dyn-array CoffSectionHeader))]
  [size : i64]
  [symbol-offset : i64]
  [symbol-count : i64]
  [payloads : (CoffPayloads source plan)]) : ResultCompilerObjectCoff
  (let
    [n (array-length rows)]
    [out (byte_buf_core.byte-buf-builder-with-capacity size)]
    (compiler-object-coff-push-file-header!
      (&mut out)
      n
      symbol-offset
      symbol-count)
    (for [i (iterator.range 0 n)]
      (match payloads
        [(ObjectImage image _)
          (match (& (array-ref image.sections.slots i))
            [(Section spec _ _)
              (compiler-object-coff-push-section-header!
                (&mut out)
                spec.name
                (& (array-ref rows i)))])]
        [(Assembled assembled)
          (compiler-object-coff-push-section-header!
            (&mut out)
            (& (array-ref assembled.names i))
            (& (array-ref rows i)))]))
    (match payloads
      [(ObjectImage image plan)
        (compiler-object-coff-render-sections! (&mut out) image plan)
        (compiler-object-coff-render-relocations! (&mut out) image plan)
        (compiler-object-coff-render-symbols! (&mut out) image image.symbols)
        (compiler-object-coff-render-string-table! (&mut out) image plan)]
      [(Assembled assembled)
        (for [i (iterator.range 0 n)]
          (append-buffer! (&mut out) (& (array-ref assembled.contents i))))
        (append-buffer! (&mut out) (& assembled.relocs))
        (append-buffer! (&mut out) (& assembled.symbols))
        (append-buffer! (&mut out) (& assembled.strings))])
    (unless
      (= size out.len)
      (return (Err "COFF serialized size differs from projection")))
    (Ok (layout.compiler-object-layout-bytes-string (& out)))))

(define (compiler-object-coff-render
  [image : (& image cobj.CompilerObjectImage)]) : ResultCompilerObjectCoff
  (let
    [plan
      (try
        (compiler-object-coff-project
          image
          compiler-object-coff-max-output-size))]
    (serialize
      (& plan.rows)
      plan.size
      plan.symbols
      (cobj.compiler-object-symbol-list-count image.symbols)
      (ObjectImage image (& plan)))))

(define (compiler-object-coff-section-header-offset
  [image : (& cobj.CompilerObjectImage)]
  [kind : cobj.CompilerObjectSectionId]) : i64
  (+
    compiler-object-coff-file-header-size
    (*
      compiler-object-coff-section-header-size
      (- (compiler-object-coff-section-number image kind) 1))))

(cfg
  test
  (define (compiler-object-coff-interior-nul-string) : String
    (let
      [out : byte_buf_core.ByteBufBuilder
        (byte_buf_core.byte-buf-builder-with-capacity 3)]
      (byte_buf_core.byte-buf-builder-push (&mut out) 0x61)
      (byte_buf_core.byte-buf-builder-push (&mut out) 0)
      (byte_buf_core.byte-buf-builder-push (&mut out) 0x62)
      (byte_buf_core.byte-buf-builder-finish-string (& out)))))

(cfg
  test
  (define (compiler-object-coff-string-record-layout-ok?) : bool
    (let
      [out : byte_buf_core.ByteBufBuilder
        (byte_buf_core.byte-buf-builder-with-capacity 8)]
      [after-empty : i64
        (layout.compiler-object-layout-render-data-record!
          (&mut out)
          (String "")
          0)]
      [after-interior-nul : i64
        (layout.compiler-object-layout-render-data-record!
          (&mut out)
          (String (compiler-object-coff-interior-nul-string))
          after-empty)]
      [bytes : String (byte_buf_core.byte-buf-builder-finish-string (& out))]
      (and
        (= after-empty 1)
        (= after-interior-nul 5)
        (= (layout.compiler-object-layout-string-length bytes) 5)
        (= (layout.compiler-object-layout-u8-at bytes 0) 0)
        (= (layout.compiler-object-layout-u8-at bytes 1) 0x61)
        (= (layout.compiler-object-layout-u8-at bytes 2) 0)
        (= (layout.compiler-object-layout-u8-at bytes 3) 0x62)
        (= (layout.compiler-object-layout-u8-at bytes 4) 0)))))

(cfg
  test
  (define (compiler-object-coff-smoke-image) : cobj.CompilerObjectImage
    (let
      [text0 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-with-capacity 1)]
      [text1 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push text0 (Label "_tl_empty"))]
      [data0 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-with-capacity 4)]
      [data1 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          data0
          (Label "_tl_answer"))]
      [data2 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push data1 (I64 42))]
      [data3 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push data2 (Label "_tl_ptr"))]
      [data4 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          data3
          (SymbolAddress "_tl_answer"))]
      [rodata0 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-with-capacity 2)]
      [rodata1 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          rodata0
          (Label "long_rodata_label_name"))]
      ;; The relocation-overflow fixture places an ADDR64 at this label.
      [rodata2 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          rodata1
          (String "example"))]
      [bss0 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-with-capacity 2)]
      [bss1 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push bss0 (Label "_tl_heap"))]
      [bss2 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push bss1 (Zero 16))]
      [sections0 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-with-capacity 4)]
      [sections1 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections0
          (coff_sections.windows-base-section
            (Text)
            (cobj.compiler-object-data-record-list-empty)
            (cobj.compiler-object-instr-builder-finish text1)))]
      [sections2 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections1
          (coff_sections.windows-base-section
            (Data)
            (cobj.compiler-object-data-record-builder-finish data4)
            (cobj.compiler-object-instr-list-empty)))]
      [sections3 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections2
          (coff_sections.windows-base-section
            (Rodata)
            (cobj.compiler-object-data-record-builder-finish rodata2)
            (cobj.compiler-object-instr-list-empty)))]
      [sections4 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections3
          (coff_sections.windows-base-section
            (Bss)
            (cobj.compiler-object-data-record-builder-finish bss2)
            (cobj.compiler-object-instr-list-empty)))]
      [symbols0 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-with-capacity 5)]
      [symbols1 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols0
          (Symbol "_tl_empty" (Export) (Function) (Some cobj.text-id)))]
      [symbols2 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols1
          (Symbol "_tl_answer" (Export) (Data) (Some cobj.data-id)))]
      [symbols3 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols2
          (Symbol "_tl_ptr" (Local) (Data) (Some cobj.data-id)))]
      [symbols4 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols3
          (Symbol "long_rodata_label_name" (Local) (Data) (Some cobj.rodata-id)))]
      [symbols5 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols4
          (Symbol "foreign_exact" (Extern) (Function) No))]
      [relocs : cobj.CompilerObjectRelocationList
        (cobj.compiler-object-relocation-builder-finish
          (cobj.compiler-object-relocation-builder-push
            (cobj.compiler-object-relocation-builder-with-capacity 1)
            (Relocation cobj.data-id "_tl_ptr" (Abs64) "_tl_answer")))]
      (cobj.CompilerObjectImage
        (cobj.compiler-object-section-builder-finish sections4)
        (cobj.compiler-object-symbol-builder-finish symbols5)
        relocs))))

(cfg
  test
  (define (compiler-object-coff-smoke-ok?) : bool
    (match (let
      [image (compiler-object-coff-smoke-image)]
      (compiler-object-coff-render image))
      [(Ok obj)
        (and
          (=
            (layout.compiler-object-layout-u16-at obj 0)
            compiler-object-coff-machine-amd64)
          (= (layout.compiler-object-layout-u16-at obj 2) 4)
          (> (layout.compiler-object-layout-u32-at obj 8) 0)
          (= (layout.compiler-object-layout-u32-at obj 12) 5)
          (= (layout.compiler-object-layout-u32-at obj (+ 60 16)) 16)
          (= (layout.compiler-object-layout-u16-at obj (+ 60 32)) 1)
          (layout.compiler-object-layout-contains? obj ".rdata")
          (layout.compiler-object-layout-contains? obj "foreign_exact")
          (layout.compiler-object-layout-contains? obj "long_rodata_label_name"))]
      [(Err _) false])))

(cfg
  test
  (define (compiler-object-coff-text-smoke-instrs) : cobj.CompilerObjectX64InstrList
    (let
      [instrs0 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-with-capacity 11)]
      [instrs1 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push instrs0 (Label "_tl_text"))]
      [instrs2 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push instrs1 (LoadRip "_tl_answer"))]
      [instrs3 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs2
          (LoadRipAddress "_tl_slot"))]
      [instrs4 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push instrs3 (StoreRip "_tl_slot"))]
      [instrs5 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push instrs4 (Call "foreign_exact"))]
      [instrs6 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push instrs5 (TailCall "_tl_done"))]
      [instrs7 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push instrs6 (Jump "_tl_done"))]
      [instrs8 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs7
          (Branch "_tl_true" "_tl_false"))]
      [instrs9 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push instrs8 (Label "_tl_true"))]
      [instrs10 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push instrs9 (Label "_tl_false"))]
      [instrs11 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push instrs10 (Label "_tl_done"))]
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
          (Symbol "_tl_text" (Export) (Function) (Some cobj.text-id)))]
      [symbols2 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols1
          (Symbol "_tl_true" (Local) (Function) (Some cobj.text-id)))]
      [symbols3 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols2
          (Symbol "_tl_false" (Local) (Function) (Some cobj.text-id)))]
      [symbols4 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols3
          (Symbol "_tl_done" (Local) (Function) (Some cobj.text-id)))]
      [symbols5 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols4
          (Symbol "_tl_answer" (Export) (Data) (Some cobj.data-id)))]
      [symbols6 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols5
          (Symbol "_tl_slot" (Local) (Data) (Some cobj.data-id)))]
      [symbols7 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols6
          (Symbol "foreign_exact" (Extern) (Function) No))]
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
          (Relocation cobj.text-id "_tl_text" (RipValue) "_tl_answer"))]
      [relocs2 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs1
          (Relocation cobj.text-id "_tl_text" (RipAddress) "_tl_slot"))]
      [relocs3 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs2
          (Relocation cobj.text-id "_tl_text" (RipAddress) "_tl_slot"))]
      [relocs4 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs3
          (Relocation cobj.text-id "_tl_text" (Call) "foreign_exact"))]
      [relocs5 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs4
          (Relocation cobj.text-id "_tl_text" (TailCall) "_tl_done"))]
      [relocs6 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs5
          (Relocation cobj.text-id "_tl_text" (Branch) "_tl_done"))]
      [relocs7 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs6
          (Relocation cobj.text-id "_tl_text" (Branch) "_tl_true"))]
      [relocs8 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs7
          (Relocation cobj.text-id "_tl_text" (Branch) "_tl_false"))]
      (cobj.compiler-object-relocation-builder-finish relocs8))))

(cfg
  test
  (define (compiler-object-coff-text-smoke-image) : cobj.CompilerObjectImage
    (let
      [data0 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-with-capacity 4)]
      [data1 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          data0
          (Label "_tl_answer"))]
      [data2 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push data1 (I64 42))]
      [data3 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push data2 (Label "_tl_slot"))]
      [data4 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push data3 (I64 0))]
      [sections0 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-with-capacity 4)]
      [sections1 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections0
          (coff_sections.windows-base-section
            (Text)
            (cobj.compiler-object-data-record-list-empty)
            (compiler-object-coff-text-smoke-instrs)))]
      [sections2 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections1
          (coff_sections.windows-base-section
            (Data)
            (cobj.compiler-object-data-record-builder-finish data4)
            (cobj.compiler-object-instr-list-empty)))]
      [sections3 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections2
          (coff_sections.windows-base-section
            (Rodata)
            (cobj.compiler-object-data-record-list-empty)
            (cobj.compiler-object-instr-list-empty)))]
      [sections4 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections3
          (coff_sections.windows-base-section
            (Bss)
            (cobj.compiler-object-data-record-list-empty)
            (cobj.compiler-object-instr-list-empty)))]
      (cobj.CompilerObjectImage
        (cobj.compiler-object-section-builder-finish sections4)
        (compiler-object-coff-text-smoke-symbols)
        (compiler-object-coff-text-smoke-relocs)))))

(define (compiler-object-coff-reloc-entry-ok?
  [obj : (& obj str)]
  [base : i64]
  [index : i64]
  [offset : i64]
  [symbol-index : i64]
  [reloc-type : i64]) : bool
  (let
    [entry : i64 (+ base (* index compiler-object-coff-relocation-size))]
    (and
      (= (layout.compiler-object-layout-u32-at obj entry) offset)
      (= (layout.compiler-object-layout-u32-at obj (+ entry 4)) symbol-index)
      (= (layout.compiler-object-layout-u16-at obj (+ entry 8)) reloc-type))))

(cfg
  test
  (define (compiler-object-coff-text-smoke-bytes-ok?
    [obj : (& str)]
    [text-ptr : i64]) : bool
    (and
      (= (layout.compiler-object-layout-u8-at obj text-ptr) 0x48)
      (= (layout.compiler-object-layout-u8-at obj (+ text-ptr 1)) 0x8b)
      (= (layout.compiler-object-layout-u8-at obj (+ text-ptr 2)) 0x05)
      (= (layout.compiler-object-layout-u8-at obj (+ text-ptr 7)) 0x48)
      (= (layout.compiler-object-layout-u8-at obj (+ text-ptr 8)) 0x8d)
      (= (layout.compiler-object-layout-u8-at obj (+ text-ptr 14)) 0x48)
      (= (layout.compiler-object-layout-u8-at obj (+ text-ptr 15)) 0x89)
      (= (layout.compiler-object-layout-u8-at obj (+ text-ptr 21)) 0xe8)
      (= (layout.compiler-object-layout-u8-at obj (+ text-ptr 26)) 0xe9)
      (= (layout.compiler-object-layout-u8-at obj (+ text-ptr 31)) 0xe9)
      (= (layout.compiler-object-layout-u8-at obj (+ text-ptr 36)) 0x48)
      (= (layout.compiler-object-layout-u8-at obj (+ text-ptr 37)) 0x85)
      (= (layout.compiler-object-layout-u8-at obj (+ text-ptr 38)) 0xc0)
      (= (layout.compiler-object-layout-u8-at obj (+ text-ptr 39)) 0x0f)
      (= (layout.compiler-object-layout-u8-at obj (+ text-ptr 40)) 0x85)
      (= (layout.compiler-object-layout-u8-at obj (+ text-ptr 45)) 0xe9))))

(cfg
  test
  (define (compiler-object-coff-text-smoke-relocs-ok?
    [image : (& cobj.CompilerObjectImage)]
    [obj : (& str)]
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
        (compiler-object-coff-reloc-entry-ok?
          obj
          reloc-ptr
          1
          10
          (compiler-object-coff-symbol-index image "_tl_slot")
          rel32)
        (compiler-object-coff-reloc-entry-ok?
          obj
          reloc-ptr
          2
          17
          (compiler-object-coff-symbol-index image "_tl_slot")
          rel32)
        (compiler-object-coff-reloc-entry-ok?
          obj
          reloc-ptr
          3
          22
          (compiler-object-coff-symbol-index image "foreign_exact")
          rel32)
        (compiler-object-coff-reloc-entry-ok?
          obj
          reloc-ptr
          4
          27
          (compiler-object-coff-symbol-index image "_tl_done")
          rel32)
        (compiler-object-coff-reloc-entry-ok?
          obj
          reloc-ptr
          5
          32
          (compiler-object-coff-symbol-index image "_tl_done")
          rel32)
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
          rel32)))))

(cfg
  test
  (define (compiler-object-coff-text-smoke-ok?) : bool
    (let
      [image : cobj.CompilerObjectImage (compiler-object-coff-text-smoke-image)]
      (match (compiler-object-coff-render image)
        [(Ok obj)
          (let
            [text-header : i64
              (compiler-object-coff-section-header-offset image cobj.text-id)]
            [text-size : i64
              (layout.compiler-object-layout-u32-at obj (+ text-header 16))]
            [text-ptr : i64
              (layout.compiler-object-layout-u32-at obj (+ text-header 20))]
            [reloc-ptr : i64
              (layout.compiler-object-layout-u32-at obj (+ text-header 24))]
            [reloc-count : i64
              (layout.compiler-object-layout-u16-at obj (+ text-header 32))]
            (and
              (= text-size 50)
              (= text-ptr (compiler-object-coff-header-size image))
              (= reloc-count 8)
              (compiler-object-coff-text-smoke-bytes-ok? (& obj) text-ptr)
              (compiler-object-coff-text-smoke-relocs-ok?
                (& image)
                (& obj)
                reloc-ptr)))]
        [(Err _) false]))))

(cfg
  test
  (define (compiler-object-coff-boundary-relocations
    [data-count : i64]
    [rodata-count : i64]) : cobj.CompilerObjectRelocationList
    (let
      [builder : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-with-capacity
          (+ data-count rodata-count))]
      (for [index (iterator.range 0 data-count)]
        (set!
          builder
          (cobj.compiler-object-relocation-builder-push
            builder
            (Relocation
              cobj.data-id
              "_tl_ptr"
              (Abs64)
              (if (= index (- data-count 1))
                "foreign_exact"
                "_tl_answer")))))
      (for [index (iterator.range 0 rodata-count)]
        (set!
          builder
          (cobj.compiler-object-relocation-builder-push
            builder
            (Relocation
              cobj.rodata-id
              "long_rodata_label_name"
              (Abs64)
              (if (= index (- rodata-count 1))
                "foreign_exact"
                "_tl_answer")))))
      (cobj.compiler-object-relocation-builder-finish builder))))

(cfg
  test
  (define (compiler-object-coff-boundary-image
    [data-count : i64]
    [rodata-count : i64]) : cobj.CompilerObjectImage
    (let
      [base : cobj.CompilerObjectImage (compiler-object-coff-smoke-image)]
      (cobj.CompilerObjectImage
        base.sections
        base.symbols
        (compiler-object-coff-boundary-relocations data-count rodata-count)))))

(cfg
  test
  (define (compiler-object-coff-header-has-relocation-overflow?
    [image : (& cobj.CompilerObjectImage)]
    [obj : (& str)]
    [kind : cobj.CompilerObjectSectionId]) : bool
    (not
      (=
        (bit-and
          (layout.compiler-object-layout-u32-at
            obj
            (+ (compiler-object-coff-section-header-offset image kind) 36))
          compiler-object-coff-section-lnk-nreloc-ovfl)
        0))))

(cfg
  test
  (define (compiler-object-coff-relocation-overflow-below-boundary-ok?) : bool
    (let
      [semantic-count : i64 0xfffe]
      [image : cobj.CompilerObjectImage
        (compiler-object-coff-boundary-image semantic-count 0)]
      (match (compiler-object-coff-render image)
        [(Ok obj)
          (let
            [text-header : i64
              (compiler-object-coff-section-header-offset image cobj.text-id)]
            [header : i64
              (compiler-object-coff-section-header-offset image cobj.data-id)]
            [reloc-pointer : i64
              (layout.compiler-object-layout-u32-at obj (+ header 24))]
            [symbol-pointer : i64 (layout.compiler-object-layout-u32-at obj 8)]
            (and
              (=
                (layout.compiler-object-layout-u16-at obj (+ text-header 32))
                0)
              (=
                (layout.compiler-object-layout-u32-at obj (+ text-header 24))
                0)
              (not
                (compiler-object-coff-header-has-relocation-overflow?
                  image
                  (& obj)
                  cobj.text-id))
              (=
                (layout.compiler-object-layout-u16-at obj (+ header 32))
                semantic-count)
              (not
                (compiler-object-coff-header-has-relocation-overflow?
                  image
                  (& obj)
                  cobj.data-id))
              (compiler-object-coff-reloc-entry-ok?
                obj
                reloc-pointer
                0
                8
                (compiler-object-coff-symbol-index image "_tl_answer")
                compiler-object-coff-reloc-amd64-addr64)
              (compiler-object-coff-reloc-entry-ok?
                obj
                reloc-pointer
                (- semantic-count 1)
                8
                (compiler-object-coff-symbol-index image "foreign_exact")
                compiler-object-coff-reloc-amd64-addr64)
              (=
                symbol-pointer
                (+
                  reloc-pointer
                  (* semantic-count compiler-object-coff-relocation-size)))))]
        [(Err _) false]))))

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
      (match (compiler-object-coff-render image)
        [(Ok obj)
          (let
            [data-header : i64
              (compiler-object-coff-section-header-offset image cobj.data-id)]
            [rodata-header : i64
              (compiler-object-coff-section-header-offset image cobj.rodata-id)]
            [data-pointer : i64
              (layout.compiler-object-layout-u32-at obj (+ data-header 24))]
            [rodata-pointer : i64
              (layout.compiler-object-layout-u32-at obj (+ rodata-header 24))]
            [symbol-pointer : i64 (layout.compiler-object-layout-u32-at obj 8)]
            [expected-size : i64
              (+
                symbol-pointer
                (+
                  (* (cobj.compiler-object-symbol-list-count image.symbols) 18)
                  (compiler-object-coff-string-table-size image.symbols)))]
            (and
              (=
                (layout.compiler-object-layout-u16-at obj (+ data-header 32))
                0xffff)
              (=
                (layout.compiler-object-layout-u16-at obj (+ rodata-header 32))
                0xffff)
              (compiler-object-coff-header-has-relocation-overflow?
                image
                (& obj)
                cobj.data-id)
              (compiler-object-coff-header-has-relocation-overflow?
                image
                (& obj)
                cobj.rodata-id)
              (compiler-object-coff-reloc-entry-ok?
                obj
                data-pointer
                0
                data-physical
                0
                0)
              (compiler-object-coff-reloc-entry-ok?
                obj
                data-pointer
                1
                8
                (compiler-object-coff-symbol-index image "_tl_answer")
                compiler-object-coff-reloc-amd64-addr64)
              (compiler-object-coff-reloc-entry-ok?
                obj
                data-pointer
                data-count
                8
                (compiler-object-coff-symbol-index image "foreign_exact")
                compiler-object-coff-reloc-amd64-addr64)
              (=
                rodata-pointer
                (+
                  data-pointer
                  (* data-physical compiler-object-coff-relocation-size)))
              (compiler-object-coff-reloc-entry-ok?
                obj
                rodata-pointer
                0
                rodata-physical
                0
                0)
              (compiler-object-coff-reloc-entry-ok?
                obj
                rodata-pointer
                1
                0
                (compiler-object-coff-symbol-index image "_tl_answer")
                compiler-object-coff-reloc-amd64-addr64)
              (compiler-object-coff-reloc-entry-ok?
                obj
                rodata-pointer
                rodata-count
                0
                (compiler-object-coff-symbol-index image "foreign_exact")
                compiler-object-coff-reloc-amd64-addr64)
              (=
                symbol-pointer
                (+
                  rodata-pointer
                  (* rodata-physical compiler-object-coff-relocation-size)))
              (=
                (layout.compiler-object-layout-string-length obj)
                expected-size)))]
        [(Err _) false]))))

(cfg
  test
  (define (compiler-object-coff-relocation-layout-rejection-ok?) : bool
    (let
      [negative : CompilerObjectCoffLayoutAccumulator
        (compiler-object-coff-check-relocation-count-layout
          (CompilerObjectCoffLayoutAccumulator 400 "")
          ".pdata"
          -1
          1000)]
      [sentinel-overflow : CompilerObjectCoffLayoutAccumulator
        (compiler-object-coff-check-relocation-count-layout
          (CompilerObjectCoffLayoutAccumulator 400 "")
          ".xdata"
          0xffffffff
          compiler-object-coff-max-output-size)]
      [table-overflow : CompilerObjectCoffLayoutAccumulator
        (compiler-object-coff-check-relocation-count-layout
          (CompilerObjectCoffLayoutAccumulator 400 "")
          ".rsrc"
          10
          499)]
      (and
        (layout.compiler-object-layout-contains?
          negative.error
          "section .pdata relocation count -1")
        (layout.compiler-object-layout-contains?
          sentinel-overflow.error
          "section .xdata relocation count 4294967295")
        (layout.compiler-object-layout-contains?
          table-overflow.error
          "section .rsrc relocation count 10")
        (= (compiler-object-coff-relocation-physical-count 0xfffe) 0xfffe)
        (= (compiler-object-coff-relocation-physical-count 0xffff) 0x10000)
        (= (compiler-object-coff-relocation-physical-count 0x10000) 0x10001)))))

(cfg
  test
  (define (compiler-object-coff-bss-align-case-ok?
    [align : i64]
    [expected-align-flag : i64]) : bool
    (let
      [bss0 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-with-capacity 3)]
      [bss1 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push bss0 (Align align))]
      [bss2 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          bss1
          (Label "_tl_aligned_cell"))]
      [bss3 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push bss2 (Zero align))]
      [sections0 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-with-capacity 4)]
      [sections1 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections0
          (coff_sections.windows-base-section
            (Text)
            (cobj.compiler-object-data-record-list-empty)
            (cobj.compiler-object-instr-list-empty)))]
      [sections2 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections1
          (coff_sections.windows-base-section
            (Data)
            (cobj.compiler-object-data-record-list-empty)
            (cobj.compiler-object-instr-list-empty)))]
      [sections3 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections2
          (coff_sections.windows-base-section
            (Rodata)
            (cobj.compiler-object-data-record-list-empty)
            (cobj.compiler-object-instr-list-empty)))]
      [sections4 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections3
          (coff_sections.windows-base-section
            (Bss)
            (cobj.compiler-object-data-record-builder-finish bss3)
            (cobj.compiler-object-instr-list-empty)))]
      [symbols0 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-with-capacity 1)]
      [symbols1 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols0
          (Symbol "_tl_aligned_cell" (Export) (Data) (Some cobj.bss-id)))]
      [image : cobj.CompilerObjectImage
        (cobj.CompilerObjectImage
          (cobj.compiler-object-section-builder-finish sections4)
          (cobj.compiler-object-symbol-builder-finish symbols1)
          (cobj.compiler-object-relocation-builder-finish
            (cobj.compiler-object-relocation-builder-with-capacity 1)))]
      (match (compiler-object-coff-render (& image))
        [(Ok obj)
          (let
            [bss-hdr : i64
              (+
                compiler-object-coff-file-header-size
                (*
                  (layout.compiler-object-layout-section-index
                    image
                    cobj.bss-id)
                  compiler-object-coff-section-header-size))]
            [flags : i64
              (layout.compiler-object-layout-u32-at (& obj) (+ bss-hdr 36))]
            (= (bit-and flags 0x00f00000) expected-align-flag))]
        [(Err _) false]))))

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
        "coff relocation layout rejects malformed or oversized counts")
      (test.assert-true
        (and
          (compiler-object-coff-bss-align-case-ok? 16 0x00500000)
          (compiler-object-coff-bss-align-case-ok? 32 0x00600000))
        "coff propagates >8B .bss record alignment into section flags"))))