;; compiler_object_elf.tl - ELF64 object-file serialization for object images.
(cfg test (import compiler_object_linux_sections as elf_sections))
(import stdlib.iterator)
(import stdlib.byte_buf_core)
(import stdlib.string)
(import stdlib.sort)
(import stdlib.clone)
(import stdlib.vector)
(import compiler_str_cat as str_cat)
(import compiler_object as cobj)
(import compiler_object_layout as layout)
(cfg test (import stdlib.test))

(defenum ResultCompilerObjectElf
  (Ok String)
  (Err String))

(define compiler-object-elf-header-size : i64
  64)
(define compiler-object-elf-section-header-size : i64
  64)
(define compiler-object-elf-symbol-size : i64
  24)
(define compiler-object-elf-relocation-size : i64
  24)
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
(define compiler-object-elf-r-x86-64-64 : i64
  1)
(define compiler-object-elf-r-x86-64-pc32 : i64
  2)
(define compiler-object-elf-r-x86-64-plt32 : i64
  4)
(define compiler-object-elf-r-x86-64-32 : i64
  10)

(define (compiler-object-elf-relocation-list-supported?
  [relocs : (& relocs cobj.CompilerObjectRelocationList)]) : bool
  (layout.compiler-object-layout-relocation-list-supported? relocs false))

;; The Windows unwind and resource sections have no ELF counterpart.
(define (compiler-object-elf-sections-supported?
  [sections : (& cobj.CompilerObjectSectionList)]) : bool
  (for [i (iterator.range 0 sections.len)]
    (let
      [error
        (layout.compiler-object-layout-section-error
          (& (array-ref sections.slots i))
          false)]
      (unless (string.eq (& error) "") (return false))))
  true)

(define (compiler-object-elf-text-targets-known?
  [image : (& image cobj.CompilerObjectImage)]) : bool
  (layout.compiler-object-layout-text-targets-known? image))

(define (compiler-object-elf-text-relocation-count-matches?
  [image : (& image cobj.CompilerObjectImage)]) : bool
  (layout.compiler-object-layout-text-relocation-count-matches? image))

(define (compiler-object-elf-section-raw-size
  [image : (& image cobj.CompilerObjectImage)]
  [kind : cobj.CompilerObjectSectionId]) : i64
  (layout.compiler-object-layout-section-raw-size image kind))

(define (compiler-object-elf-symbol-binding-local?
  [binding : cobj.CompilerObjectSymbolBinding]) : bool
  (match binding
    [(Local) true]
    [_ false]))

(define (compiler-object-elf-local-symbol-count
  [symbols : (& symbols cobj.CompilerObjectSymbolList)]) : i64
  (let
    [count : i64 (cobj.compiler-object-symbol-list-count symbols)]
    [total : i64 0]
    (for [index (iterator.range 0 count)]
      (match (cobj.compiler-object-symbol-list-ref symbols index)
        [(Symbol _ binding _ _)
          (if (compiler-object-elf-symbol-binding-local? binding)
            (+= total 1)
            unit)]))
    total))

(define (compiler-object-elf-local-symbol-index-from
  [symbols : (& symbols cobj.CompilerObjectSymbolList)]
  [name : (& name str)]
  [index : i64]) : i64
  (let
    [count : i64 (cobj.compiler-object-symbol-list-count symbols)]
    [slot : i64 0]
    [cur-index : i64 index]
    [result : i64 -1]
    [done : bool false]
    (while (and (not done) (< slot count))
      (match (cobj.compiler-object-symbol-list-ref symbols slot)
        [(Symbol found binding _ _)
          (if (compiler-object-elf-symbol-binding-local? binding)
            (if (string.eq found name)
              (begin
                (set! result cur-index)
                (set! done true))
              (begin
                (+= cur-index 1)
                (+= slot 1)))
            (+= slot 1))]))
    result))

(define (compiler-object-elf-global-symbol-index-from
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
        [(Symbol found binding _ _)
          (if (compiler-object-elf-symbol-binding-local? binding)
            (+= slot 1)
            (if (string.eq found name)
              (begin
                (set! result cur-index)
                (set! done true))
              (begin
                (+= cur-index 1)
                (+= slot 1))))]))
    result))

(define (compiler-object-elf-symbol-index
  [image : (& image cobj.CompilerObjectImage)]
  [name : (& str)]) : i64
  (let
    [symbols : cobj.CompilerObjectSymbolList image.symbols]
    [local : i64 (compiler-object-elf-local-symbol-index-from symbols name 1)]
    (if (>= local 0)
      local
      (compiler-object-elf-global-symbol-index-from
        symbols
        (& name)
        (+ 1 (compiler-object-elf-local-symbol-count symbols))))))

(define (compiler-object-elf-relocation-sites-known?
  [image : (& image cobj.CompilerObjectImage)]
  [relocs : (& relocs cobj.CompilerObjectRelocationList)]) : bool
  (let
    [count : i64 (cobj.compiler-object-relocation-list-count relocs)]
    [index : i64 0]
    [ok : bool true]
    (while (and ok (< index count))
      (match (cobj.compiler-object-relocation-list-ref relocs index)
        [(Relocation section site _ target)
          (if (and
            (>=
              (layout.compiler-object-layout-section-label-offset
                image
                section
                (& site))
              0)
            (>= (compiler-object-elf-symbol-index image (& target)) 0))
            (+= index 1)
            (set! ok false))]))
    ok))

(define (compiler-object-elf-fixups-supported?
  [image : (& image cobj.CompilerObjectImage)]) : bool
  (and
    (compiler-object-elf-relocation-list-supported? image.relocations)
    (compiler-object-elf-relocation-sites-known? image image.relocations)
    (layout.compiler-object-layout-text-targets-known? image)
    (layout.compiler-object-layout-text-relocation-count-matches? image)))

(define (compiler-object-elf-image-supported?
  [image : (& cobj.CompilerObjectImage)]) : bool
  (let
    [error (layout.compiler-object-layout-image-error image false)]
    (and (string.eq (& error) "") (compiler-object-elf-fixups-supported? image))))

(define (compiler-object-elf-relocation-section-size
  [image : (& image cobj.CompilerObjectImage)]
  [kind : cobj.CompilerObjectSectionId]) : i64
  (*
    compiler-object-elf-relocation-size
    (layout.compiler-object-layout-section-relocation-count image kind)))

(define (compiler-object-elf-symbol-table-size
  [image : (& image cobj.CompilerObjectImage)]) : i64
  (*
    compiler-object-elf-symbol-size
    (+ 1 (cobj.compiler-object-symbol-list-count image.symbols))))

(define (compiler-object-elf-string-table-size-from
  [symbols : (& symbols cobj.CompilerObjectSymbolList)]
  [size : i64]) : i64
  (let
    [count : i64 (cobj.compiler-object-symbol-list-count symbols)]
    [total : i64 size]
    (for [index (iterator.range 0 count)]
      (match (cobj.compiler-object-symbol-list-ref symbols index)
        [(Symbol name _ _ _)
          (+= total (+ (layout.compiler-object-layout-string-length name) 1))]))
    total))

(define (compiler-object-elf-string-table-size
  [symbols : (& symbols cobj.CompilerObjectSymbolList)]) : i64
  (compiler-object-elf-string-table-size-from symbols 1))

(define (compiler-object-elf-push-shstrtab-name!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [name : (& str)]) : unit
  (layout.compiler-object-layout-push-string-bytes! out name)
  (layout.compiler-object-layout-push-u8! out 0))

(define (compiler-object-elf-section-index
  [image : (& cobj.CompilerObjectImage)]
  [id : cobj.CompilerObjectSectionId]) : i64
  (+ 1 (layout.compiler-object-layout-section-index image id)))

(define (compiler-object-elf-section-count
  [image : (& cobj.CompilerObjectImage)]) : i64
  (+ (* image.sections.len 2) 5))

(define (compiler-object-elf-name
  [image : (& cobj.CompilerObjectImage)]
  [index : i64]) : String
  (let
    [count : i64 image.sections.len]
    (cond
      [(= index 0) ""]
      [(<= index count)
        (match (& (array-ref image.sections.slots (- index 1)))
          [(Section spec _ _) (string.copy spec.name)])]
      [(<= index (* 2 count))
        (match (& (array-ref image.sections.slots (- (- index 1) count)))
          [(Section spec _ _) (str_cat.str-cat ".rela" (string.copy spec.name))])]
      [else
        (match (- index (* 2 count))
          [1 ".symtab"]
          [2 ".strtab"]
          [3 ".shstrtab"]
          [_ ".note.GNU-stack"])])))

(defstruct ElfSectionHeader
  (name i64)
  (ty i64)
  (flags i64)
  (offset i64)
  (size i64)
  (link i64)
  (info i64)
  (align i64)
  (entry-size i64))

(defstruct ElfProjection
  (rows (__tl_dyn-array ElfSectionHeader))
  (names String)
  (headers i64)
  (symtab i64))

(defenum ResultElfProjection
  (Ok ElfProjection)
  (Err String))

;; Row zero is the null header. Each declared section gets one RELA row.
;; The symbol and string tables and the stack note follow both groups.
(define (compiler-object-elf-project [image : (& cobj.CompilerObjectImage)]) : ResultElfProjection
  (let
    [count : i64 image.sections.len]
    [symtab : i64 (+ 1 (* count 2))]
    [rows : (__tl_dyn-array ElfSectionHeader)
      (__tl_make-array
        ElfSectionHeader
        (compiler-object-elf-section-count image))]
    [names : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    [offset : i64 compiler-object-elf-header-size]
    (for [i (iterator.range 0 count)]
      (match (& (array-ref image.sections.slots i))
        [(Section spec _ _)
          (let
            [size : i64
              (layout.compiler-object-layout-section-size
                (& (array-ref image.sections.slots i)))]
            [at : i64
              (layout.compiler-object-layout-align-offset offset spec.align)]
            (match spec.format
              [(Elf ty flags)
                (set!
                  (array-ref rows (+ i 1))
                  (ElfSectionHeader 0 ty flags at size 0 0 spec.align 0))
                (when
                  (and (!= ty compiler-object-elf-sht-nobits) (> size 0))
                  (when
                    (> size (- layout.compiler-object-max-file-size at))
                    (return
                      (Err
                        (str_cat.str-cat
                          "elf: section exceeds size limit: "
                          (string.copy spec.name)))))
                  (set! offset (+ at size)))]
              [_ (return (Err "elf: invalid section descriptor"))]))]))
    (set! offset (layout.compiler-object-layout-align-offset offset 8))
    (for [i (iterator.range 0 count)]
      (let
        [id (layout.compiler-object-layout-section-at image i)]
        [size (compiler-object-elf-relocation-section-size image id)]
        (when
          (> size (- layout.compiler-object-max-file-size offset))
          (return
            (Err
              (str_cat.str-cat
                "elf: relocation section exceeds size limit: "
                (string.copy (layout.compiler-object-layout-spec image id).name)))))
        (set!
          (array-ref rows (+ count (+ 1 i)))
          (ElfSectionHeader
            0
            compiler-object-elf-sht-rela
            0
            offset
            size
            symtab
            (+ i 1)
            8
            compiler-object-elf-relocation-size))
        (+= offset size)))
    (let
      [size (compiler-object-elf-symbol-table-size image)]
      (set!
        (array-ref rows symtab)
        (ElfSectionHeader
          0
          compiler-object-elf-sht-symtab
          0
          offset
          size
          (+ symtab 1)
          (+ 1 (compiler-object-elf-local-symbol-count image.symbols))
          8
          compiler-object-elf-symbol-size))
      (+= offset size))
    (let
      [size (compiler-object-elf-string-table-size image.symbols)]
      (set!
        (array-ref rows (+ symtab 1))
        (ElfSectionHeader
          0
          compiler-object-elf-sht-strtab
          0
          offset
          size
          0
          0
          1
          0))
      (+= offset size))
    (set!
      (array-ref rows (+ symtab 3))
      (ElfSectionHeader 0 compiler-object-elf-sht-progbits 0 0 0 0 0 1 0))
    (layout.compiler-object-layout-push-u8! (&mut names) 0)
    (for [i (iterator.range 1 (array-length rows))]
      (set! (array-ref rows i).name names.len)
      (compiler-object-elf-push-shstrtab-name!
        (&mut names)
        (& (compiler-object-elf-name image i))))
    (set!
      (array-ref rows (+ symtab 2))
      (ElfSectionHeader
        (array-ref rows (+ symtab 2)).name
        compiler-object-elf-sht-strtab
        0
        offset
        names.len
        0
        0
        1
        0))
    (set!
      offset
      (layout.compiler-object-layout-align-offset (+ offset names.len) 8))
    (when
      (>
        (+
          offset
          (* (array-length rows) compiler-object-elf-section-header-size))
        layout.compiler-object-max-file-size)
      (return
        (Err
          "elf: symbol, string or section header table exceeds file size limit")))
    (Ok
      (ElfProjection
        rows
        (layout.compiler-object-layout-bytes-string (& names))
        offset
        symtab))))

(define (compiler-object-elf-push-header!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [plan : (& ElfProjection)]) : unit
  (layout.compiler-object-layout-push-u8! out 0x7f)
  (layout.compiler-object-layout-push-u8! out 0x45)
  (layout.compiler-object-layout-push-u8! out 0x4c)
  (layout.compiler-object-layout-push-u8! out 0x46)
  (layout.compiler-object-layout-push-u8! out 2)
  (layout.compiler-object-layout-push-u8! out 1)
  (layout.compiler-object-layout-push-u8! out 1)
  (layout.compiler-object-layout-push-u8! out 0)
  (layout.compiler-object-layout-push-u8! out 0)
  (layout.compiler-object-layout-push-zeroes! out 7)
  (layout.compiler-object-layout-push-u16! out 1)
  (layout.compiler-object-layout-push-u16! out 62)
  (layout.compiler-object-layout-push-u32! out 1)
  (layout.compiler-object-layout-push-u64! out 0)
  (layout.compiler-object-layout-push-u64! out 0)
  (layout.compiler-object-layout-push-u64! out plan.headers)
  (layout.compiler-object-layout-push-u32! out 0)
  (layout.compiler-object-layout-push-u16! out compiler-object-elf-header-size)
  (layout.compiler-object-layout-push-u16! out 0)
  (layout.compiler-object-layout-push-u16! out 0)
  (layout.compiler-object-layout-push-u16!
    out
    compiler-object-elf-section-header-size)
  (layout.compiler-object-layout-push-u16! out (array-length plan.rows))
  (layout.compiler-object-layout-push-u16! out (+ plan.symtab 2)))

(define (compiler-object-elf-render-loadable-sections!
  [out : (&mut byte_buf_core.ByteBufBuilder)]
  [image : (& cobj.CompilerObjectImage)]
  [plan : (& ElfProjection)]) : unit
  (for [index (iterator.range 0 image.sections.len)]
    (let
      [id (layout.compiler-object-layout-section-at image index)]
      (when
        (and
          (> (array-ref plan.rows (+ 1 index)).size 0)
          (!=
            (array-ref plan.rows (+ 1 index)).ty
            compiler-object-elf-sht-nobits))
        (layout.compiler-object-layout-render-padding-to!
          out
          (array-ref plan.rows (+ index 1)).offset)
        (layout.compiler-object-layout-render-section! out image id)))))

(define (compiler-object-elf-relocation-type
  [kind : cobj.CompilerObjectRelocationKind]) : i64
  (match kind
    [(or (Call) (TailCall)) compiler-object-elf-r-x86-64-plt32]
    [(Abs64) compiler-object-elf-r-x86-64-64]
    [(Abs32) compiler-object-elf-r-x86-64-32]
    [(or (RipValue) (RipAddress) (Branch)) compiler-object-elf-r-x86-64-pc32]
    [_ 0]))

(define (compiler-object-elf-relocation-addend
  [kind : cobj.CompilerObjectRelocationKind]) : i64
  (match kind
    [(or (Call) (TailCall) (RipValue) (RipAddress) (Branch)) -4]
    [_ 0]))

(define (compiler-object-elf-render-relocation-record!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]
  [offset : i64]
  [kind : cobj.CompilerObjectRelocationKind]
  [target : (& str)]) : unit
  (layout.compiler-object-layout-push-u64! out offset)
  (layout.compiler-object-layout-push-u64!
    out
    (bit-or
      (shl (compiler-object-elf-symbol-index image (& target)) 32)
      (compiler-object-elf-relocation-type kind)))
  (layout.compiler-object-layout-push-u64!
    out
    (compiler-object-elf-relocation-addend kind)))

(define (compiler-object-elf-render-relocation!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]
  [reloc : (& cobj.CompilerObjectRelocation)]) : unit
  (match reloc
    [(Relocation section site kind target)
      (compiler-object-elf-render-relocation-record!
        out
        image
        (layout.compiler-object-layout-section-label-offset image section site)
        kind
        target)]))

(define (compiler-object-elf-render-text-relocations!
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
                (compiler-object-elf-render-relocation-record!
                  out
                  image
                  (- end 4)
                  kind
                  (& target))]
              [(Branch true-target false-target)
                (compiler-object-elf-render-relocation-record!
                  out
                  image
                  (- end 9)
                  (Branch)
                  (& true-target))
                (compiler-object-elf-render-relocation-record!
                  out
                  image
                  (- end 4)
                  (Branch)
                  (& false-target))])))
        unit)]))

(define (compiler-object-elf-render-relocations-for-section!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]
  [relocs : (& relocs cobj.CompilerObjectRelocationList)]
  [kind : cobj.CompilerObjectSectionId]) : unit
  (let
    [count : i64 (cobj.compiler-object-relocation-list-count relocs)]
    (for [index (iterator.range 0 count)]
      (let
        [reloc : cobj.CompilerObjectRelocation
          (cobj.compiler-object-relocation-list-ref relocs index)]
        (match (& reloc)
          [(Relocation section _ _ _)
            (if (cobj.compiler-object-section-id-eq? section kind)
              (compiler-object-elf-render-relocation! out image (& reloc))
              unit)])))
    unit))

(define (compiler-object-elf-render-relocation-sections!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]
  [plan : (& ElfProjection)]) : unit
  (for [index (iterator.range 0 image.sections.len)]
    (layout.compiler-object-layout-render-padding-to!
      out
      (array-ref plan.rows (+ image.sections.len (+ index 1))).offset)
    (let
      [kind : cobj.CompilerObjectSectionId
        (layout.compiler-object-layout-section-at image index)]
      (match kind.value
        [0 (compiler-object-elf-render-text-relocations! out image)]
        [_
          (compiler-object-elf-render-relocations-for-section!
            out
            image
            image.relocations
            kind)]))))

(define (compiler-object-elf-symbol-string-offset-from
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
          (if (string.eq found name)
            (begin
              (set! result cur-offset)
              (set! done true))
            (begin
              (+=
                cur-offset
                (+ (layout.compiler-object-layout-string-length found) 1))
              (+= index 1)))]))
    result))

(define (compiler-object-elf-symbol-string-offset
  [image : (& image cobj.CompilerObjectImage)]
  [name : (& name str)]) : i64
  (compiler-object-elf-symbol-string-offset-from image.symbols name 1))

(define (compiler-object-elf-symbol-binding
  [binding : cobj.CompilerObjectSymbolBinding]) : i64
  (match binding
    [(Local) 0]
    [_ 1]))

(define (compiler-object-elf-symbol-type [kind : cobj.CompilerObjectSymbolKind]) : i64
  (match kind
    [(or (Function) (Runtime)) 2]
    [(Data) 1]
    [_ 0]))

(define (compiler-object-elf-symbol-info
  [binding : cobj.CompilerObjectSymbolBinding]
  [kind : cobj.CompilerObjectSymbolKind]) : i64
  (bit-or
    (shl (compiler-object-elf-symbol-binding binding) 4)
    (compiler-object-elf-symbol-type kind)))

(define (compiler-object-elf-symbol-section-index
  [image : (& cobj.CompilerObjectImage)]
  [section : cobj.CompilerObjectMaybeSection]) : i64
  (match section
    [(No) 0]
    [(Some kind) (compiler-object-elf-section-index image kind)]))

(define (compiler-object-elf-render-null-symbol!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]) : unit
  (layout.compiler-object-layout-push-zeroes!
    out
    compiler-object-elf-symbol-size))

(define (compiler-object-elf-render-symbol!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]
  [symbol : (& cobj.CompilerObjectSymbol)]) : unit
  (match symbol
    [(Symbol name binding kind section)
      (layout.compiler-object-layout-push-u32!
        out
        (compiler-object-elf-symbol-string-offset image name))
      (layout.compiler-object-layout-push-u8!
        out
        (compiler-object-elf-symbol-info binding kind))
      (layout.compiler-object-layout-push-u8! out 0)
      (layout.compiler-object-layout-push-u16!
        out
        (compiler-object-elf-symbol-section-index image section))
      (layout.compiler-object-layout-push-u64!
        out
        (layout.compiler-object-layout-symbol-value image name section))
      (layout.compiler-object-layout-push-u64! out 0)]))

(define (compiler-object-elf-render-symbols-by-locality!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]
  [symbols : (& symbols cobj.CompilerObjectSymbolList)]
  [want-local : bool]) : unit
  (let
    [count : i64 (cobj.compiler-object-symbol-list-count symbols)]
    (for [index (iterator.range 0 count)]
      (let
        [symbol : cobj.CompilerObjectSymbol
          (cobj.compiler-object-symbol-list-ref symbols index)]
        (match (& symbol)
          [(Symbol _ binding _ _)
            (if (=
              (compiler-object-elf-symbol-binding-local? binding)
              want-local)
              (compiler-object-elf-render-symbol! out image (& symbol))
              unit)])))
    unit))

(define (compiler-object-elf-render-symbol-table!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]) : unit
  (compiler-object-elf-render-null-symbol! out)
  (compiler-object-elf-render-symbols-by-locality! out image image.symbols true)
  (compiler-object-elf-render-symbols-by-locality!
    out
    image
    image.symbols
    false))

(define (compiler-object-elf-render-string-table-symbols!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [symbols : (& symbols cobj.CompilerObjectSymbolList)]) : unit
  (let
    [count : i64 (cobj.compiler-object-symbol-list-count symbols)]
    (for [index (iterator.range 0 count)]
      (match (cobj.compiler-object-symbol-list-ref symbols index)
        [(Symbol name _ _ _)
          (layout.compiler-object-layout-push-string-bytes! out name)
          (layout.compiler-object-layout-push-u8! out 0)]))
    unit))

(define (compiler-object-elf-section-flags
  [image : (& cobj.CompilerObjectImage)]
  [id : cobj.CompilerObjectSectionId]) : i64
  (match (layout.compiler-object-layout-spec image id).format
    [(Elf _ flags) flags]
    [_ 0]))

(define (compiler-object-elf-section-type
  [image : (& cobj.CompilerObjectImage)]
  [id : cobj.CompilerObjectSectionId]) : i64
  (match (layout.compiler-object-layout-spec image id).format
    [(Elf ty _) ty]
    [_ 0]))

(define (compiler-object-elf-push-section-header!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
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
  (layout.compiler-object-layout-push-u32! out name-offset)
  (layout.compiler-object-layout-push-u32! out section-type)
  (layout.compiler-object-layout-push-u64! out flags)
  (layout.compiler-object-layout-push-u64! out addr)
  (layout.compiler-object-layout-push-u64! out offset)
  (layout.compiler-object-layout-push-u64! out size)
  (layout.compiler-object-layout-push-u32! out link)
  (layout.compiler-object-layout-push-u32! out info)
  (layout.compiler-object-layout-push-u64! out align)
  (layout.compiler-object-layout-push-u64! out entry-size))

(define (compiler-object-elf-render [image : (& cobj.CompilerObjectImage)]) : ResultCompilerObjectElf
  (let
    [error (layout.compiler-object-layout-image-error image false)]
    (unless (string.eq (& error) "") (return (Err error))))
  (unless
    (compiler-object-elf-fixups-supported? image)
    (return
      (Err
        "elf: object image contains unsupported text instructions or relocation records")))
  (let
    [plan : ElfProjection (try (compiler-object-elf-project image))]
    [out
      (byte_buf_core.byte-buf-builder-with-capacity
        (+
          plan.headers
          (* (array-length plan.rows) compiler-object-elf-section-header-size)))]
    (compiler-object-elf-push-header! (&mut out) (& plan))
    (compiler-object-elf-render-loadable-sections! (&mut out) image (& plan))
    (compiler-object-elf-render-relocation-sections! (&mut out) image (& plan))
    (layout.compiler-object-layout-render-padding-to!
      (&mut out)
      (array-ref plan.rows plan.symtab).offset)
    (compiler-object-elf-render-symbol-table! (&mut out) image)
    (layout.compiler-object-layout-push-u8! (&mut out) 0)
    (compiler-object-elf-render-string-table-symbols! (&mut out) image.symbols)
    (layout.compiler-object-layout-push-string-bytes! (&mut out) plan.names)
    (layout.compiler-object-layout-render-padding-to! (&mut out) plan.headers)
    (for [i (iterator.range 0 (array-length plan.rows))]
      (let
        [h (array-ref plan.rows i)]
        (compiler-object-elf-push-section-header!
          (&mut out)
          h.name
          h.ty
          h.flags
          0
          h.offset
          h.size
          h.link
          h.info
          h.align
          h.entry-size)))
    (Ok (layout.compiler-object-layout-bytes-string (& out)))))

;; The writer bounds files below 4 GiB, so section file offsets fit u32.
(define (compiler-object-elf-section-field
  [object : (& str)]
  [index : i64]
  [field : i64]) : i64
  (layout.compiler-object-layout-u32-at
    object
    (+
      (layout.compiler-object-layout-u32-at object 40)
      (+ (* index compiler-object-elf-section-header-size) field))))

;; The base encoder has already assigned offsets and emitted every fixup.
;; Repartition its payload by the defined function and data symbols. Preserve
;; symbol ordering, so relocation symbol indices and the string table carry over.
(define (compiler-object-elf-append-range!
  [out : (&mut byte_buf_core.ByteBufBuilder)]
  [text : (& str)]
  [offset : i64]
  [size : i64]) : unit
  (layout.compiler-object-layout-push-string-bytes!
    out
    (string.substring-view text offset size)))

(defstruct CompilerObjectElfRange
  (section i64)
  (start i64)
  (name String))

(clone.gen-clone CompilerObjectElfRange)

;; The owner equality hook the full-mode vector shared with `stdlib.sort.vec`
;; requires.
(define (eq-compiler-object-elf-range
  [left : (& left CompilerObjectElfRange)]
  [right : (& right CompilerObjectElfRange)]) : bool
  (and
    (= left.section right.section)
    (= left.start right.start)
    (string.eq (& left.name) (& right.name))))

(import (stdlib.vector.vector CompilerObjectElfRange) as range_vec)
(import (stdlib.sort.vec CompilerObjectElfRange) as range_sort)

(define (compiler-object-elf-range-less?
  [left : CompilerObjectElfRange]
  [right : CompilerObjectElfRange]) : bool
  (or
    (< left.section right.section)
    (and (= left.section right.section) (< left.start right.start))))

(define (compiler-object-elf-range-index
  [ranges : (& (__tl_dyn-array CompilerObjectElfRange))]
  [count : i64]
  [section : i64]
  [offset : i64]) : i64
  (let
    [low : i64 0]
    [high : i64 count]
    (while (< low high)
      (let
        [mid : i64 (/ (+ low high) 2)]
        [range-section : i64 (array-ref ranges mid).section]
        [range-start : i64 (array-ref ranges mid).start]
        (if (or
          (< range-section section)
          (and (= range-section section) (<= range-start offset)))
          (set! low (+ mid 1))
          (set! high mid))))
    (- low 1)))

(define (compiler-object-elf-archive-symbol-value [flat : (& str)] [pos : i64]) : i64
  (bit-or
    (layout.compiler-object-layout-u32-at flat (+ pos 8))
    (shl (layout.compiler-object-layout-u32-at flat (+ pos 12)) 32)))

(define (compiler-object-elf-archive-ranges
  [image : (& cobj.CompilerObjectImage)]
  [flat : (& str)]) : range_vec.Vec
  (let
    [candidates : range_vec.Vec (range_vec.new)]
    [ranges : range_vec.Vec (range_vec.new)]
    [strtab : i64
      (compiler-object-elf-section-field flat (+ (* image.sections.len 2) 2) 24)]
    (for [i (iterator.range 1 (+ image.sections.len 1))]
      (range_vec.push-ref! (&mut candidates) (CompilerObjectElfRange i 0 "")))
    (let
      [pos : i64
        (compiler-object-elf-section-field
          flat
          (+ (* image.sections.len 2) 1)
          24)]
      (while (< pos strtab)
        (let
          [section : i64 (layout.compiler-object-layout-u16-at flat (+ pos 6))]
          [info : i64 (layout.compiler-object-layout-u8-at flat (+ pos 4))]
          [kind : i64 (bit-and info 15)]
          ;; Local text labels include basic-block entries. Fallthrough into
          ;; those blocks must stay inside the enclosing function's section.
          ;; Rodata can share overlapping string suffixes.
          (when
            (or
              (and
                (=
                  section
                  (compiler-object-elf-section-index image cobj.text-id))
                (= info 18))
              (and
                (= kind 1)
                (or
                  (=
                    section
                    (compiler-object-elf-section-index image cobj.data-id))
                  (=
                    section
                    (compiler-object-elf-section-index image cobj.bss-id)))))
            (let
              [start : i64
                (+ strtab (layout.compiler-object-layout-u32-at flat pos))]
              [end : i64 (string.index-of-byte flat start 0)]
              (range_vec.push-ref!
                (&mut candidates)
                (CompilerObjectElfRange
                  section
                  (compiler-object-elf-archive-symbol-value flat pos)
                  (string.substring flat start (- end start)))))))
        (+= pos compiler-object-elf-symbol-size)))
    (range_sort.sort! (&mut candidates) compiler-object-elf-range-less?)
    (for [i (iterator.range 0 (range_vec.len (& candidates)))]
      (let
        [entry : CompilerObjectElfRange
          (range_vec.get (& candidates) i (CompilerObjectElfRange 0 0 ""))]
        [count : i64 (range_vec.len (& ranges))]
        [prior : CompilerObjectElfRange
          (range_vec.get (& ranges) (- count 1) (CompilerObjectElfRange 0 0 ""))]
        (cond
          [(or (!= entry.section prior.section) (!= entry.start prior.start))
            (range_vec.push-ref! (&mut ranges) entry)]
          [(string.eq (& prior.name) "")
            (range_vec.set-ref! (&mut ranges) (- count 1) entry)]
          [else unit])))
    ranges))

(define (compiler-object-elf-archive-base
  [image : (& cobj.CompilerObjectImage)]
  [section : i64]
  [start : i64]) : i64
  (let
    [align
      (layout.compiler-object-layout-section-align
        image
        (layout.compiler-object-layout-section-at image (- section 1)))]
    (bit-and start (bit-not (- align 1)))))

(define (compiler-object-elf-archive-render-symbols!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& cobj.CompilerObjectImage)]
  [flat : (& str)]
  [ranges : (& (__tl_dyn-array CompilerObjectElfRange))]
  [count : i64]) : unit
  (let
    [pos : i64
      (compiler-object-elf-section-field flat (+ (* image.sections.len 2) 1) 24)]
    [end : i64
      (compiler-object-elf-section-field flat (+ (* image.sections.len 2) 2) 24)]
    (while (< pos end)
      (let
        [section : i64 (layout.compiler-object-layout-u16-at flat (+ pos 6))]
        [value : i64 (compiler-object-elf-archive-symbol-value flat pos)]
        (if (= section 0)
          (compiler-object-elf-append-range!
            out
            flat
            pos
            compiler-object-elf-symbol-size)
          (let
            [index : i64
              (compiler-object-elf-range-index ranges count section value)]
            [start : i64 (array-ref ranges index).start]
            (compiler-object-elf-append-range! out flat pos 6)
            (layout.compiler-object-layout-push-u16! out (+ index 1))
            (layout.compiler-object-layout-push-u64!
              out
              (- value (compiler-object-elf-archive-base image section start)))
            (compiler-object-elf-append-range! out flat (+ pos 16) 8))))
      (+= pos compiler-object-elf-symbol-size))))

(define (compiler-object-elf-archive-section-name
  [image : (& cobj.CompilerObjectImage)]
  [id : cobj.CompilerObjectSectionId]
  [name : (& str)]) : String
  (if (string.eq name "")
    (string.copy (layout.compiler-object-layout-spec image id).name)
    (str_cat.str-cat
      (string.copy (layout.compiler-object-layout-spec image id).name)
      "."
      (string.copy name))))

(define (compiler-object-elf-render-archive
  [image : (& cobj.CompilerObjectImage)]) : ResultCompilerObjectElf
  (let
    [flat (try (compiler-object-elf-render image))]
    [ranges : range_vec.Vec (compiler-object-elf-archive-ranges image (& flat))]
    [count : i64 (range_vec.len (& ranges))]
    ;; Up to one relocation section per payload section.
    [_ : unit
      (when
        (>= (+ (* 2 count) 5) 0xff00)
        (return (Err "elf: too many archive sections")))]
    [entries (range_vec.slots (& ranges))]
    [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    [headers : byte_buf_core.ByteBufBuilder
      (byte_buf_core.byte-buf-builder-new)]
    [names : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
    [rels : (__tl_dyn-array byte_buf_core.ByteBufBuilder)
      (__tl_make-array byte_buf_core.ByteBufBuilder count)]
    [rela-count : i64 0]
    (layout.compiler-object-layout-push-u8! (&mut names) 0)
    (compiler-object-elf-append-range!
      (&mut out)
      (& flat)
      0
      compiler-object-elf-header-size)
    (layout.compiler-object-layout-push-zeroes!
      (&mut headers)
      compiler-object-elf-section-header-size)
    (for [i (iterator.range 0 count)]
      (let
        [range : CompilerObjectElfRange
          (range_vec.get (& ranges) i (CompilerObjectElfRange 0 0 ""))]
        [kind : cobj.CompilerObjectSectionId
          (layout.compiler-object-layout-section-at image (- range.section 1))]
        [base : i64
          (compiler-object-elf-archive-base image range.section range.start)]
        [offset : i64
          (layout.compiler-object-layout-align-offset
            out.len
            (layout.compiler-object-layout-section-align image kind))]
        [end : i64
          (if (and
            (< (+ i 1) count)
            (= range.section (array-ref entries (+ i 1)).section))
            (array-ref entries (+ i 1)).start
            (layout.compiler-object-layout-section-virtual-size image kind))]
        (when
          (and
            (!=
              (compiler-object-elf-section-type image kind)
              compiler-object-elf-sht-nobits)
            (> (- end base) (- layout.compiler-object-max-file-size offset)))
          (return
            (Err
              (str_cat.str-cat
                "elf: archive section exceeds size limit: "
                (string.copy
                  (layout.compiler-object-layout-spec image kind).name)))))
        (compiler-object-elf-push-section-header!
          (&mut headers)
          names.len
          (compiler-object-elf-section-type image kind)
          (compiler-object-elf-section-flags image kind)
          0
          offset
          (- end base)
          0
          0
          (layout.compiler-object-layout-section-align image kind)
          0)
        (compiler-object-elf-push-shstrtab-name!
          (&mut names)
          (&
            (compiler-object-elf-archive-section-name image kind (& range.name))))
        (unless
          (=
            (compiler-object-elf-section-type image kind)
            compiler-object-elf-sht-nobits)
          (layout.compiler-object-layout-render-padding-to! (&mut out) offset)
          (layout.compiler-object-layout-push-zeroes!
            (&mut out)
            (- range.start base))
          (compiler-object-elf-append-range!
            (&mut out)
            (& flat)
            (+
              (compiler-object-elf-section-field (& flat) range.section 24)
              range.start)
            (- end range.start)))
        (set! (array-ref rels i) (byte_buf_core.byte-buf-builder-new))))
    (for [i (iterator.range 0 image.sections.len)]
      (let
        [pos : i64
          (compiler-object-elf-section-field
            (& flat)
            (+ image.sections.len (+ i 1))
            24)]
        [end : i64
          (+
            pos
            (compiler-object-elf-section-field
              (& flat)
              (+ image.sections.len (+ i 1))
              32))]
        (while (< pos end)
          (let
            [offset : i64 (layout.compiler-object-layout-u32-at (& flat) pos)]
            [index : i64
              (compiler-object-elf-range-index entries count (+ i 1) offset)]
            [base : i64
              (compiler-object-elf-archive-base
                image
                (+ i 1)
                (array-ref entries index).start)]
            (when (= (array-ref rels index).len 0) (+= rela-count 1))
            (layout.compiler-object-layout-push-u64!
              (&mut (array-ref rels index))
              (- offset base))
            (compiler-object-elf-append-range!
              (&mut (array-ref rels index))
              (& flat)
              (+ pos 8)
              16))
          (+= pos compiler-object-elf-relocation-size))))
    (let
      [symtab-index : i64 (+ 1 (+ count rela-count))]
      [strtab-index : i64 (+ symtab-index 1)]
      [shstrtab-index : i64 (+ strtab-index 1)]
      (layout.compiler-object-layout-render-padding-to!
        (&mut out)
        (layout.compiler-object-layout-align-offset out.len 8))
      (for [i (iterator.range 0 count)]
        (let
          [rel-length : i64 (array-ref rels i).len]
          [range : CompilerObjectElfRange
            (range_vec.get (& ranges) i (CompilerObjectElfRange 0 0 ""))]
          (when
            (> rel-length 0)
            (compiler-object-elf-push-section-header!
              (&mut headers)
              names.len
              compiler-object-elf-sht-rela
              0
              0
              out.len
              rel-length
              symtab-index
              (+ i 1)
              8
              compiler-object-elf-relocation-size)
            (compiler-object-elf-push-shstrtab-name!
              (&mut names)
              (&
                (str_cat.str-cat
                  ".rela"
                  (compiler-object-elf-archive-section-name
                    image
                    (layout.compiler-object-layout-section-at
                      image
                      (- range.section 1))
                    (& range.name)))))
            (byte_buf_core.byte-buf-builder-append-array-range
              (&mut out)
              (& (array-ref rels i).slots)
              0
              rel-length))))
      (compiler-object-elf-push-section-header!
        (&mut headers)
        names.len
        compiler-object-elf-sht-symtab
        0
        0
        out.len
        (compiler-object-elf-symbol-table-size image)
        strtab-index
        (+ 1 (compiler-object-elf-local-symbol-count image.symbols))
        8
        compiler-object-elf-symbol-size)
      (compiler-object-elf-push-shstrtab-name! (&mut names) ".symtab")
      (compiler-object-elf-archive-render-symbols!
        (&mut out)
        image
        (& flat)
        entries
        count)
      (let
        [strtab : i64
          (compiler-object-elf-section-field
            flat
            (+ (* image.sections.len 2) 2)
            24)]
        [strtab-size : i64
          (compiler-object-elf-string-table-size image.symbols)]
        (compiler-object-elf-push-section-header!
          (&mut headers)
          names.len
          compiler-object-elf-sht-strtab
          0
          0
          out.len
          strtab-size
          0
          0
          1
          0)
        (compiler-object-elf-push-shstrtab-name! (&mut names) ".strtab")
        (compiler-object-elf-append-range!
          (&mut out)
          (& flat)
          strtab
          strtab-size))
      (let
        [shstr-name : i64 names.len]
        [_ : unit
          (compiler-object-elf-push-shstrtab-name! (&mut names) ".shstrtab")]
        [stack-name : i64 names.len]
        [_ : unit
          (compiler-object-elf-push-shstrtab-name!
            (&mut names)
            ".note.GNU-stack")]
        (compiler-object-elf-push-section-header!
          (&mut headers)
          shstr-name
          compiler-object-elf-sht-strtab
          0
          0
          out.len
          names.len
          0
          0
          1
          0)
        (compiler-object-elf-push-section-header!
          (&mut headers)
          stack-name
          compiler-object-elf-sht-progbits
          0
          0
          out.len
          0
          0
          0
          1
          0)
        (byte_buf_core.byte-buf-builder-append-array-range
          (&mut out)
          (& names.slots)
          0
          names.len)
        (let
          [shoff : i64 (layout.compiler-object-layout-align-offset out.len 8)]
          (layout.compiler-object-layout-render-padding-to! (&mut out) shoff)
          (byte_buf_core.byte-buf-builder-append-array-range
            (&mut out)
            (& headers.slots)
            0
            headers.len)
          (for [i (iterator.range 0 8)]
            (set!
              (array-ref out.slots (+ 40 i))
              (cast (shr shoff (* i 8)) : u8)))
          (let
            [shnum : i64 (+ shstrtab-index 2)]
            (set! (array-ref out.slots 60) (cast shnum : u8))
            (set! (array-ref out.slots 61) (cast (shr shnum 8) : u8))
            (set! (array-ref out.slots 62) (cast shstrtab-index : u8))
            (set! (array-ref out.slots 63) (cast (shr shstrtab-index 8) : u8)))
          (Ok (layout.compiler-object-layout-bytes-string (& out))))))))

(define (compiler-object-elf-rela-entry-offset
  [section-offset : i64]
  [index : i64]) : i64
  (+ section-offset (* compiler-object-elf-relocation-size index)))

(define (compiler-object-elf-rela-type-at
  [text : (& text str)]
  [section-offset : i64]
  [index : i64]) : i64
  (layout.compiler-object-layout-u32-at
    text
    (+ (compiler-object-elf-rela-entry-offset section-offset index) 8)))

(define (compiler-object-elf-rela-target-offset-at
  [text : (& text str)]
  [section-offset : i64]
  [index : i64]) : i64
  (layout.compiler-object-layout-u32-at
    text
    (compiler-object-elf-rela-entry-offset section-offset index)))

(define (compiler-object-elf-rela-addend-rel32?
  [text : (& text str)]
  [section-offset : i64]
  [index : i64]) : bool
  (let
    [entry : i64 (compiler-object-elf-rela-entry-offset section-offset index)]
    (and
      (= (layout.compiler-object-layout-u32-at text (+ entry 16)) 0xfffffffc)
      (= (layout.compiler-object-layout-u32-at text (+ entry 20)) 0xffffffff))))

(cfg
  test
  (define (compiler-object-elf-ret-bytes) : String
    (let
      [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
      (layout.compiler-object-layout-push-u8! (&mut out) 0xc3)
      (layout.compiler-object-layout-bytes-string (& out)))))

(cfg
  test
  (define (compiler-object-elf-text-smoke-instrs) : cobj.CompilerObjectX64InstrList
    (let
      [instrs0 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-with-capacity 17)]
      [instrs1 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push instrs0 (Label "_tl_text"))]
      [instrs2 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push instrs1 (Call "foreign_exact"))]
      [instrs3 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push instrs2 (LoadRip "_tl_cell"))]
      [instrs4 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs3
          (LoadRipAddress "_tl_message"))]
      [instrs5 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push instrs4 (StoreRip "_tl_cell"))]
      [instrs6 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs5
          (Branch ".L_true" ".L_false"))]
      [instrs7 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push instrs6 (Label ".L_true"))]
      [instrs8 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push instrs7 (Jump ".L_done"))]
      [instrs9 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push instrs8 (Label ".L_false"))]
      [instrs10 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push instrs9 (TailCall "_tl_text"))]
      [instrs11 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push instrs10 (Label ".L_done"))]
      [instrs12 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push instrs11 (SubRspImm8 8))]
      [instrs13 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs12
          (MovRcxRip "_tl_cell"))]
      [instrs14 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs13
          (MovRdxRip "_tl_message"))]
      [instrs15 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push instrs14 (MovRcxRax))]
      [instrs16 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs15
          (Raw (compiler-object-elf-ret-bytes)))]
      (cobj.compiler-object-instr-builder-finish
        (cobj.compiler-object-instr-builder-push
          instrs16
          (LoadAbsAddress "_tl_message"))))))

(cfg
  test
  (define (compiler-object-elf-text-smoke-relocations) : cobj.CompilerObjectRelocationList
    (let
      [relocs0 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-with-capacity 11)]
      [relocs1 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs0
          (Relocation cobj.text-id "_tl_text" (Call) "foreign_exact"))]
      [relocs2 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs1
          (Relocation cobj.text-id "_tl_text" (RipValue) "_tl_cell"))]
      [relocs3 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs2
          (Relocation cobj.text-id "_tl_text" (RipAddress) "_tl_message"))]
      [relocs4 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs3
          (Relocation cobj.text-id "_tl_text" (RipAddress) "_tl_cell"))]
      [relocs5 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs4
          (Relocation cobj.text-id "_tl_text" (Branch) ".L_true"))]
      [relocs6 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs5
          (Relocation cobj.text-id "_tl_text" (Branch) ".L_false"))]
      [relocs7 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs6
          (Relocation cobj.text-id "_tl_text" (Branch) ".L_done"))]
      [relocs8 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs7
          (Relocation cobj.text-id "_tl_text" (TailCall) "_tl_text"))]
      [relocs9 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs8
          (Relocation cobj.text-id "_tl_text" (RipValue) "_tl_cell"))]
      [relocs10 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs9
          (Relocation cobj.text-id "_tl_text" (RipValue) "_tl_message"))]
      (cobj.compiler-object-relocation-builder-finish
        (cobj.compiler-object-relocation-builder-push
          relocs10
          (Relocation cobj.text-id "_tl_text" (Abs32) "_tl_message"))))))

(cfg
  test
  (define (compiler-object-elf-interior-nul-string) : String
    (let
      [out : byte_buf_core.ByteBufBuilder
        (byte_buf_core.byte-buf-builder-with-capacity 3)]
      (byte_buf_core.byte-buf-builder-push (&mut out) 0x61)
      (byte_buf_core.byte-buf-builder-push (&mut out) 0)
      (byte_buf_core.byte-buf-builder-push (&mut out) 0x62)
      (byte_buf_core.byte-buf-builder-finish-string (& out)))))

(cfg
  test
  (define (compiler-object-elf-string-record-layout-ok?) : bool
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
          (String (compiler-object-elf-interior-nul-string))
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
  (define (compiler-object-elf-text-smoke-image) : cobj.CompilerObjectImage
    (let
      [data0 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-with-capacity 2)]
      [data1 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push data0 (Label "_tl_cell"))]
      [data2 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push data1 (I64 0))]
      [rodata0 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-with-capacity 2)]
      [rodata1 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          rodata0
          (Label "_tl_message"))]
      [rodata2 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push rodata1 (String "ok"))]
      [sections0 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-with-capacity 4)]
      [sections1 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections0
          (elf_sections.linux-base-section
            (Text)
            (cobj.compiler-object-data-record-list-empty)
            (compiler-object-elf-text-smoke-instrs)))]
      [sections2 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections1
          (elf_sections.linux-base-section
            (Data)
            (cobj.compiler-object-data-record-builder-finish data2)
            (cobj.compiler-object-instr-list-empty)))]
      [sections3 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections2
          (elf_sections.linux-base-section
            (Rodata)
            (cobj.compiler-object-data-record-builder-finish rodata2)
            (cobj.compiler-object-instr-list-empty)))]
      [sections4 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections3
          (elf_sections.linux-base-section
            (Bss)
            (cobj.compiler-object-data-record-list-empty)
            (cobj.compiler-object-instr-list-empty)))]
      [symbols0 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-with-capacity 7)]
      [symbols1 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols0
          (Symbol ".L_true" (Local) (Function) (Some cobj.text-id)))]
      [symbols2 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols1
          (Symbol ".L_false" (Local) (Function) (Some cobj.text-id)))]
      [symbols3 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols2
          (Symbol ".L_done" (Local) (Function) (Some cobj.text-id)))]
      [symbols4 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols3
          (Symbol "_tl_message" (Local) (Data) (Some cobj.rodata-id)))]
      [symbols5 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols4
          (Symbol "_tl_text" (Export) (Function) (Some cobj.text-id)))]
      [symbols6 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols5
          (Symbol "_tl_cell" (Export) (Data) (Some cobj.data-id)))]
      [symbols7 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols6
          (Symbol "foreign_exact" (Extern) (Function) No))]
      (cobj.CompilerObjectImage
        (cobj.compiler-object-section-builder-finish sections4)
        (cobj.compiler-object-symbol-builder-finish symbols7)
        (compiler-object-elf-text-smoke-relocations)))))

(cfg
  test
  (define (compiler-object-elf-smoke-image) : cobj.CompilerObjectImage
    (let
      [text0 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-with-capacity 2)]
      [text1 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push text0 (Label "_tl_empty"))]
      [text2 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          text1
          (Raw (compiler-object-elf-ret-bytes)))]
      [data0 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-with-capacity 3)]
      [data1 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push data0 (Label "_tl_cell"))]
      [data2 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          data1
          (SymbolAddress "_tl_message"))]
      [data3 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push data2 (I64 99))]
      [rodata0 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-with-capacity 5)]
      [rodata1 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          rodata0
          (Label "_tl_message"))]
      [rodata2 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push rodata1 (String "ok"))]
      [rodata3 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push rodata2 (Align 8))]
      [rodata4 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push rodata3 (Label "_tl_pi"))]
      [rodata5 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          rodata4
          (F64 0x400c000000000000))]
      [bss0 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-with-capacity 2)]
      [bss1 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push bss0 (Label "_tl_zero"))]
      [bss2 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push bss1 (Zero 16))]
      [sections0 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-with-capacity 4)]
      [sections1 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections0
          (elf_sections.linux-base-section
            (Text)
            (cobj.compiler-object-data-record-list-empty)
            (cobj.compiler-object-instr-builder-finish text2)))]
      [sections2 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections1
          (elf_sections.linux-base-section
            (Data)
            (cobj.compiler-object-data-record-builder-finish data3)
            (cobj.compiler-object-instr-list-empty)))]
      [sections3 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections2
          (elf_sections.linux-base-section
            (Rodata)
            (cobj.compiler-object-data-record-builder-finish rodata5)
            (cobj.compiler-object-instr-list-empty)))]
      [sections4 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections3
          (elf_sections.linux-base-section
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
          (Symbol "_tl_cell" (Export) (Data) (Some cobj.data-id)))]
      [symbols3 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols2
          (Symbol "_tl_message" (Local) (Data) (Some cobj.rodata-id)))]
      [symbols4 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols3
          (Symbol "_tl_zero" (Export) (Data) (Some cobj.bss-id)))]
      [symbols5 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols4
          (Symbol "foreign_exact" (Extern) (Function) No))]
      [relocs : cobj.CompilerObjectRelocationList
        (cobj.compiler-object-relocation-builder-finish
          (cobj.compiler-object-relocation-builder-push
            (cobj.compiler-object-relocation-builder-with-capacity 1)
            (Relocation cobj.data-id "_tl_cell" (Abs64) "_tl_message")))]
      (cobj.CompilerObjectImage
        (cobj.compiler-object-section-builder-finish sections4)
        (cobj.compiler-object-symbol-builder-finish symbols5)
        relocs))))

(cfg
  test
  (define (compiler-object-elf-smoke-ok?) : bool
    (match (let
      [image (compiler-object-elf-smoke-image)]
      (compiler-object-elf-render image))
      [(Ok obj)
        (and
          (=
            (layout.compiler-object-layout-string-length obj)
            (+
              (layout.compiler-object-layout-u32-at obj 40)
              (* compiler-object-elf-section-header-size 13)))
          (= (cast (layout.compiler-object-layout-string-ref obj 0) : i64) 0x7f)
          (= (cast (layout.compiler-object-layout-string-ref obj 1) : i64) 0x45)
          (= (layout.compiler-object-layout-u16-at obj 18) 62)
          (=
            (layout.compiler-object-layout-u16-at obj 58)
            compiler-object-elf-section-header-size)
          (= (layout.compiler-object-layout-u16-at obj 60) 13)
          (layout.compiler-object-layout-contains? obj ".rela.data")
          (layout.compiler-object-layout-contains? obj ".note.GNU-stack")
          (layout.compiler-object-layout-contains? obj "_tl_message")
          (layout.compiler-object-layout-contains? obj "foreign_exact"))]
      [(Err _) false])))

(cfg
  test
  (define (compiler-object-elf-text-smoke-ok?) : bool
    (let
      [image : cobj.CompilerObjectImage (compiler-object-elf-text-smoke-image)]
      (match (compiler-object-elf-render image)
        [(Ok obj)
          (let
            [text-offset : i64 (compiler-object-elf-section-field obj 1 24)]
            [rela-offset : i64
              (compiler-object-elf-section-field
                obj
                (+ 1 image.sections.len)
                24)]
            (and
              (=
                (compiler-object-elf-section-field
                  obj
                  (compiler-object-elf-section-index image cobj.text-id)
                  32)
                77)
              (=
                (compiler-object-elf-section-field
                  obj
                  (+ image.sections.len 1)
                  32)
                (* 11 compiler-object-elf-relocation-size))
              (= (layout.compiler-object-layout-u8-at obj text-offset) 0xe8)
              (=
                (layout.compiler-object-layout-u8-at obj (+ text-offset 26))
                0x48)
              (=
                (layout.compiler-object-layout-u8-at obj (+ text-offset 27))
                0x85)
              (=
                (layout.compiler-object-layout-u8-at obj (+ text-offset 28))
                0xc0)
              (=
                (compiler-object-elf-rela-target-offset-at obj rela-offset 0)
                1)
              (=
                (compiler-object-elf-rela-type-at obj rela-offset 0)
                compiler-object-elf-r-x86-64-plt32)
              (compiler-object-elf-rela-addend-rel32? obj rela-offset 0)
              (=
                (compiler-object-elf-rela-target-offset-at obj rela-offset 1)
                8)
              (=
                (compiler-object-elf-rela-type-at obj rela-offset 1)
                compiler-object-elf-r-x86-64-pc32)
              (compiler-object-elf-rela-addend-rel32? obj rela-offset 1)
              (=
                (compiler-object-elf-rela-target-offset-at obj rela-offset 5)
                36)
              (=
                (compiler-object-elf-rela-type-at obj rela-offset 5)
                compiler-object-elf-r-x86-64-pc32)
              (compiler-object-elf-rela-addend-rel32? obj rela-offset 5)
              (=
                (layout.compiler-object-layout-u8-at obj (+ text-offset 72))
                0xb8)
              (=
                (compiler-object-elf-rela-target-offset-at obj rela-offset 10)
                73)
              (=
                (compiler-object-elf-rela-type-at obj rela-offset 10)
                compiler-object-elf-r-x86-64-32)
              (=
                (layout.compiler-object-layout-u32-at
                  obj
                  (+ (compiler-object-elf-rela-entry-offset rela-offset 10) 16))
                0)
              (=
                (layout.compiler-object-layout-u32-at
                  obj
                  (+ (compiler-object-elf-rela-entry-offset rela-offset 10) 20))
                0)
              (layout.compiler-object-layout-contains? obj "_tl_cell")
              (layout.compiler-object-layout-contains? obj "foreign_exact")))]
        [(Err _) false]))))

(cfg
  test
  (define (compiler-object-elf-rodata-record-image
    [record : cobj.CompilerObjectDataRecord]) : cobj.CompilerObjectImage
    (let
      [data0 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-with-capacity 2)]
      [data1 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push data0 (Label "_tl_cell"))]
      [data2 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push data1 (I64 0))]
      [rodata0 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-with-capacity 2)]
      [rodata1 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          rodata0
          (Label "_tl_table"))]
      [rodata2 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push rodata1 record)]
      [sections0 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-with-capacity 4)]
      [sections1 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections0
          (elf_sections.linux-base-section
            (Text)
            (cobj.compiler-object-data-record-list-empty)
            (cobj.compiler-object-instr-list-empty)))]
      [sections2 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections1
          (elf_sections.linux-base-section
            (Data)
            (cobj.compiler-object-data-record-builder-finish data2)
            (cobj.compiler-object-instr-list-empty)))]
      [sections3 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections2
          (elf_sections.linux-base-section
            (Rodata)
            (cobj.compiler-object-data-record-builder-finish rodata2)
            (cobj.compiler-object-instr-list-empty)))]
      [sections4 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections3
          (elf_sections.linux-base-section
            (Bss)
            (cobj.compiler-object-data-record-list-empty)
            (cobj.compiler-object-instr-list-empty)))]
      [symbols0 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-with-capacity 1)]
      [symbols1 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols0
          (Symbol "_tl_cell" (Export) (Data) (Some cobj.data-id)))]
      (cobj.CompilerObjectImage
        (cobj.compiler-object-section-builder-finish sections4)
        (cobj.compiler-object-symbol-builder-finish symbols1)
        (cobj.compiler-object-relocation-builder-finish
          (cobj.compiler-object-relocation-builder-with-capacity 1))))))

;; #7732: a PE-only SymbolRva32 record in any section fails ELF rendering with
;; its own error before any bytes are produced, here in the section after a
;; valid one; the same image with an ELF record in its place still renders.
(cfg
  test
  (define (compiler-object-elf-rva32-rejected-ok?) : bool
    (let
      [rva : cobj.CompilerObjectImage
        (compiler-object-elf-rodata-record-image (SymbolRva32 "_tl_cell"))]
      [control : cobj.CompilerObjectImage
        (compiler-object-elf-rodata-record-image (SymbolAddress "_tl_cell"))]
      (and
        (not (compiler-object-elf-image-supported? rva))
        (match (compiler-object-elf-render rva)
          [(Err message)
            (string.eq
              message
              "elf: section .rodata: incompatible SymbolRva32 data record")]
          [(Ok _) false])
        (compiler-object-elf-image-supported? control)
        (match (compiler-object-elf-render control)
          [(Ok _) true]
          [(Err _) false])))))

(cfg
  test
  (define (compiler-object-elf-bss-align-image [align : i64]) : cobj.CompilerObjectImage
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
          (elf_sections.linux-base-section
            (Text)
            (cobj.compiler-object-data-record-list-empty)
            (cobj.compiler-object-instr-list-empty)))]
      [sections2 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections1
          (elf_sections.linux-base-section
            (Data)
            (cobj.compiler-object-data-record-list-empty)
            (cobj.compiler-object-instr-list-empty)))]
      [sections3 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections2
          (elf_sections.linux-base-section
            (Rodata)
            (cobj.compiler-object-data-record-list-empty)
            (cobj.compiler-object-instr-list-empty)))]
      [sections4 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections3
          (elf_sections.linux-base-section
            (Bss)
            (cobj.compiler-object-data-record-builder-finish bss3)
            (cobj.compiler-object-instr-list-empty)))]
      [symbols0 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-with-capacity 1)]
      [symbols1 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols0
          (Symbol "_tl_aligned_cell" (Export) (Data) (Some cobj.bss-id)))]
      (cobj.CompilerObjectImage
        (cobj.compiler-object-section-builder-finish sections4)
        (cobj.compiler-object-symbol-builder-finish symbols1)
        (cobj.compiler-object-relocation-builder-finish
          (cobj.compiler-object-relocation-builder-with-capacity 1))))))

(cfg
  test
  (define (compiler-object-elf-bss-align-case-ok? [align : i64]) : bool
    (let
      [image : cobj.CompilerObjectImage
        (compiler-object-elf-bss-align-image align)]
      [flat-ok? : bool
        (match (compiler-object-elf-render (& image))
          [(Ok obj)
            (let
              [shoff : i64 (layout.compiler-object-layout-u32-at (& obj) 40)]
              [bss-hdr : i64
                (+
                  shoff
                  (*
                    (compiler-object-elf-section-index image cobj.bss-id)
                    compiler-object-elf-section-header-size))]
              (=
                (layout.compiler-object-layout-u32-at (& obj) (+ bss-hdr 48))
                align))]
          [(Err _) false])]
      [archive-ok? : bool
        (match (compiler-object-elf-render-archive (& image))
          [(Ok obj)
            (let
              [shoff : i64 (layout.compiler-object-layout-u32-at (& obj) 40)]
              [shnum : i64 (layout.compiler-object-layout-u16-at (& obj) 60)]
              [found-nobits? : bool false]
              [all-match? : bool true]
              (for [i (iterator.range 0 shnum)]
                (let
                  [hdr : i64
                    (+ shoff (* i compiler-object-elf-section-header-size))]
                  [shtype : i64
                    (layout.compiler-object-layout-u32-at (& obj) (+ hdr 4))]
                  (when
                    (= shtype compiler-object-elf-sht-nobits)
                    (set! found-nobits? true)
                    (unless
                      (=
                        (layout.compiler-object-layout-u32-at
                          (& obj)
                          (+ hdr 48))
                        align)
                      (set! all-match? false)))))
              (and found-nobits? all-match?))]
          [(Err _) false])]
      (and flat-ok? archive-ok?))))

(cfg
  test
  (test
    compiler-object-elf-smoke
    (begin
      (test.assert-true
        (compiler-object-elf-string-record-layout-ok?)
        "elf string records include one terminal zero")
      (test.assert-true (compiler-object-elf-smoke-ok?) "elf object smoke")
      (test.assert-true
        (compiler-object-elf-text-smoke-ok?)
        "elf text object smoke")
      (test.assert-true
        (compiler-object-elf-rva32-rejected-ok?)
        "elf rejects PE-only SymbolRva32 data records")
      (test.assert-true
        (and
          (compiler-object-elf-bss-align-case-ok? 16)
          (compiler-object-elf-bss-align-case-ok? 32))
        "elf propagates >8B .bss record alignment into sh_addralign"))))