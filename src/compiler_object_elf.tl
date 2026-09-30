;; compiler_object_elf.tl - ELF64 object-file serialization for object images.
(import compiler_owned_view as owned_view)
(import stdlib.byte_buf_core)
(import stdlib.string)
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
(define compiler-object-elf-section-note-gnu-stack-index : i64
  12)
(define compiler-object-elf-section-count : i64
  13)
(define compiler-object-elf-shstrtab-size : i64
  113)
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
(define compiler-object-elf-r-x86-64-pc32 : i64
  2)
(define compiler-object-elf-r-x86-64-plt32 : i64
  4)

(define (compiler-object-elf-relocation-list-supported?
  [relocs : (& relocs cobj.CompilerObjectRelocationList)]) : bool
  (layout.compiler-object-layout-relocation-list-supported? relocs false))

;; The Windows unwind and resource sections have no ELF counterpart.
(define (compiler-object-elf-sections-supported?
  [sections : (& sections cobj.CompilerObjectSectionList)]) : bool
  (let
    [count : i64 (cobj.compiler-object-section-list-count sections)]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (match (cobj.compiler-object-section-list-ref sections index)
          [(cobj.CompilerObjectSection.Section kind _ instrs)
            (match kind
              [(cobj.CompilerObjectSectionKind.Pdata) (set! ok false)]
              [(cobj.CompilerObjectSectionKind.Xdata) (set! ok false)]
              [(cobj.CompilerObjectSectionKind.Rsrc) (set! ok false)]
              [_
                (if (layout.compiler-object-layout-instrs-encodable?
                  instrs
                  true)
                  (set! index (+ index 1))
                  (set! ok false))])]))
      ok)))

;; `SymbolRva32` is a PE image-relative address with no ELF counterpart; the
;; shared layout would otherwise serialize it as a silent zero (#7732).
(define (compiler-object-elf-data-record-supported?
  [record : cobj.CompilerObjectDataRecord]) : bool
  (match record
    [(cobj.CompilerObjectDataRecord.SymbolRva32 _) false]
    [_ true]))

;; Every section's data records, text included, must have an ELF encoding.
(define (compiler-object-elf-data-records-supported?
  [sections : (& sections cobj.CompilerObjectSectionList)]) : bool
  (let
    [count : i64 (cobj.compiler-object-section-list-count sections)]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (match (cobj.compiler-object-section-list-ref sections index)
          [(cobj.CompilerObjectSection.Section _ records _)
            (let
              [record-count : i64
                (cobj.compiler-object-data-record-list-count (& records))]
              [record-index : i64 0]
              (begin
                (while (and ok (< record-index record-count))
                  (begin
                    (set!
                      ok
                      (compiler-object-elf-data-record-supported?
                        (cobj.compiler-object-data-record-list-ref
                          (& records)
                          record-index)))
                    (set! record-index (+ record-index 1))))
                (set! index (+ index 1))))]))
      ok)))

;; build_run_core classifies its ELF fallback reasons with these checks.
(define (compiler-object-elf-text-targets-known?
  [image : (& image cobj.CompilerObjectImage)]) : bool
  (layout.compiler-object-layout-text-targets-known? image))

(define (compiler-object-elf-text-relocation-count-matches?
  [image : (& image cobj.CompilerObjectImage)]) : bool
  (layout.compiler-object-layout-text-relocation-count-matches? image))

(define (compiler-object-elf-section-raw-size
  [image : (& image cobj.CompilerObjectImage)]
  [kind : cobj.CompilerObjectSectionKind]) : i64
  (layout.compiler-object-layout-section-raw-size image kind))

(define (compiler-object-elf-symbol-binding-local?
  [binding : cobj.CompilerObjectSymbolBinding]) : bool
  (match binding
    [(cobj.CompilerObjectSymbolBinding.Local) true]
    [_ false]))

(define (compiler-object-elf-local-symbol-count
  [symbols : (& symbols cobj.CompilerObjectSymbolList)]) : i64
  (let
    [count : i64 (cobj.compiler-object-symbol-list-count symbols)]
    [index : i64 0]
    [total : i64 0]
    (begin
      (while (< index count)
        (begin
          (match (cobj.compiler-object-symbol-list-ref symbols index)
            [(cobj.CompilerObjectSymbol.Symbol _ binding _ _)
              (if (compiler-object-elf-symbol-binding-local? binding)
                (set! total (+ total 1))
                unit)])
          (set! index (+ index 1))))
      total)))

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
    (begin
      (while (and (not done) (< slot count))
        (match (cobj.compiler-object-symbol-list-ref symbols slot)
          [(cobj.CompilerObjectSymbol.Symbol found binding _ _)
            (if (compiler-object-elf-symbol-binding-local? binding)
              (if (string.eq found name)
                (begin
                  (set! result cur-index)
                  (set! done true))
                (begin
                  (set! cur-index (+ cur-index 1))
                  (set! slot (+ slot 1))))
              (set! slot (+ slot 1)))]))
      result)))

(define (compiler-object-elf-global-symbol-index-from
  [symbols : (& symbols cobj.CompilerObjectSymbolList)]
  [name : String]
  [index : i64]) : i64
  (let
    [count : i64 (cobj.compiler-object-symbol-list-count symbols)]
    [slot : i64 0]
    [cur-index : i64 index]
    [result : i64 -1]
    [done : bool false]
    (begin
      (while (and (not done) (< slot count))
        (match (cobj.compiler-object-symbol-list-ref symbols slot)
          [(cobj.CompilerObjectSymbol.Symbol found binding _ _)
            (if (compiler-object-elf-symbol-binding-local? binding)
              (set! slot (+ slot 1))
              (if (string.eq found name)
                (begin
                  (set! result cur-index)
                  (set! done true))
                (begin
                  (set! cur-index (+ cur-index 1))
                  (set! slot (+ slot 1)))))]))
      result)))

(define (compiler-object-elf-symbol-index
  [image : (& image cobj.CompilerObjectImage)]
  [name : String]) : i64
  (let
    [symbols : cobj.CompilerObjectSymbolList image.symbols]
    [local : i64 (compiler-object-elf-local-symbol-index-from symbols name 1)]
    (if (>= local 0)
      local
      (compiler-object-elf-global-symbol-index-from
        symbols
        name
        (+ 1 (compiler-object-elf-local-symbol-count symbols))))))

(define (compiler-object-elf-relocation-sites-known?
  [image : (& image cobj.CompilerObjectImage)]
  [relocs : (& relocs cobj.CompilerObjectRelocationList)]) : bool
  (let
    [count : i64 (cobj.compiler-object-relocation-list-count relocs)]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (match (cobj.compiler-object-relocation-list-ref relocs index)
          [(cobj.CompilerObjectRelocation.Relocation section site _ target)
            (if (and
              (>=
                (layout.compiler-object-layout-section-label-offset
                  image
                  section
                  site)
                0)
              (>= (compiler-object-elf-symbol-index image target) 0))
              (set! index (+ index 1))
              (set! ok false))]))
      ok)))

(define (compiler-object-elf-image-supported?
  [image : (& image cobj.CompilerObjectImage)]) : bool
  (and
    (compiler-object-elf-sections-supported? image.sections)
    (compiler-object-elf-data-records-supported? image.sections)
    (compiler-object-elf-relocation-list-supported? image.relocations)
    (compiler-object-elf-relocation-sites-known? image image.relocations)
    (layout.compiler-object-layout-text-targets-known? image)
    (layout.compiler-object-layout-text-relocation-count-matches? image)))

(define (compiler-object-elf-relocation-section-size
  [image : (& image cobj.CompilerObjectImage)]
  [kind : cobj.CompilerObjectSectionKind]) : i64
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
    [index : i64 0]
    [total : i64 size]
    (begin
      (while (< index count)
        (begin
          (match (cobj.compiler-object-symbol-list-ref symbols index)
            [(cobj.CompilerObjectSymbol.Symbol name _ _ _)
              (set!
                total
                (+
                  total
                  (+ (layout.compiler-object-layout-string-length name) 1)))])
          (set! index (+ index 1))))
      total)))

(define (compiler-object-elf-string-table-size
  [symbols : (& symbols cobj.CompilerObjectSymbolList)]) : i64
  (compiler-object-elf-string-table-size-from symbols 1))

(define (compiler-object-elf-push-shstrtab-name!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [name : String]) : unit
  (begin
    (layout.compiler-object-layout-push-string-bytes! out name)
    (layout.compiler-object-layout-push-u8! out 0)))

(define (compiler-object-elf-push-shstrtab!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]) : unit
  (begin
    (layout.compiler-object-layout-push-u8! out 0)
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
    (compiler-object-elf-push-shstrtab-name! out ".shstrtab")
    (compiler-object-elf-push-shstrtab-name! out ".note.GNU-stack")))

;; ELF keeps the loadable sections, the first four of the shared order.
(define compiler-object-elf-loadable-count : i64
  4)

;; File offset of loadable section END (at 4, past .bss, where the .rela
;; sections start): .text 16-byte aligned after the header, the rest 8-byte
;; aligned.
(define (compiler-object-elf-load-offset
  [image : (& image cobj.CompilerObjectImage)]
  [end : i64]) : i64
  (let
    [offset : i64
      (layout.compiler-object-layout-align-offset
        compiler-object-elf-header-size
        16)]
    [index : i64 0]
    (begin
      (while (< index end)
        (begin
          (set!
            offset
            (layout.compiler-object-layout-align-offset
              (+
                offset
                (layout.compiler-object-layout-section-raw-size
                  image
                  (layout.compiler-object-layout-section-at index)))
              8))
          (set! index (+ index 1))))
      offset)))

;; File offset of the .rela section of loadable section END (at 4, of .symtab).
(define (compiler-object-elf-rela-offset
  [image : (& image cobj.CompilerObjectImage)]
  [end : i64]) : i64
  (let
    [offset : i64
      (compiler-object-elf-load-offset image compiler-object-elf-loadable-count)]
    [index : i64 0]
    (begin
      (while (< index end)
        (begin
          (set!
            offset
            (layout.compiler-object-layout-align-offset
              (+
                offset
                (compiler-object-elf-relocation-section-size
                  image
                  (layout.compiler-object-layout-section-at index)))
              8))
          (set! index (+ index 1))))
      offset)))

(define (compiler-object-elf-symtab-offset
  [image : (& image cobj.CompilerObjectImage)]) : i64
  (compiler-object-elf-rela-offset image compiler-object-elf-loadable-count))

(define (compiler-object-elf-strtab-offset
  [image : (& image cobj.CompilerObjectImage)]) : i64
  (+
    (compiler-object-elf-symtab-offset image)
    (compiler-object-elf-symbol-table-size image)))

(define (compiler-object-elf-shstrtab-offset
  [image : (& image cobj.CompilerObjectImage)]) : i64
  (+
    (compiler-object-elf-strtab-offset image)
    (compiler-object-elf-string-table-size image.symbols)))

(define (compiler-object-elf-section-header-offset
  [image : (& image cobj.CompilerObjectImage)]) : i64
  (layout.compiler-object-layout-align-offset
    (+
      (compiler-object-elf-shstrtab-offset image)
      compiler-object-elf-shstrtab-size)
    8))

(define (compiler-object-elf-section-index
  [kind : cobj.CompilerObjectSectionKind]) : i64
  (let
    [index : i64 (layout.compiler-object-layout-section-index kind)]
    (if (< index compiler-object-elf-loadable-count)
      (+ compiler-object-elf-section-text-index index)
      compiler-object-elf-section-null-index)))

(define (compiler-object-elf-section-name-offset [index : i64]) : i64
  (cond
    [(= index compiler-object-elf-section-text-index) 1]
    [(= index compiler-object-elf-section-data-index) 7]
    [(= index compiler-object-elf-section-rodata-index) 13]
    [(= index compiler-object-elf-section-bss-index) 21]
    [(= index compiler-object-elf-section-rela-text-index) 26]
    [(= index compiler-object-elf-section-rela-data-index) 37]
    [(= index compiler-object-elf-section-rela-rodata-index) 48]
    [(= index compiler-object-elf-section-rela-bss-index) 61]
    [(= index compiler-object-elf-section-symtab-index) 71]
    [(= index compiler-object-elf-section-strtab-index) 79]
    [(= index compiler-object-elf-section-shstrtab-index) 87]
    [(= index compiler-object-elf-section-note-gnu-stack-index) 97]
    [else 0]))

(define (compiler-object-elf-push-header!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]) : unit
  (begin
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
    (layout.compiler-object-layout-push-u64!
      out
      (compiler-object-elf-section-header-offset image))
    (layout.compiler-object-layout-push-u32! out 0)
    (layout.compiler-object-layout-push-u16!
      out
      compiler-object-elf-header-size)
    (layout.compiler-object-layout-push-u16! out 0)
    (layout.compiler-object-layout-push-u16! out 0)
    (layout.compiler-object-layout-push-u16!
      out
      compiler-object-elf-section-header-size)
    (layout.compiler-object-layout-push-u16!
      out
      compiler-object-elf-section-count)
    (layout.compiler-object-layout-push-u16!
      out
      compiler-object-elf-section-shstrtab-index)))

(define (compiler-object-elf-render-loadable-sections!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]) : unit
  (let
    [index : i64 0]
    (while (< index compiler-object-elf-loadable-count)
      (begin
        (match (layout.compiler-object-layout-section-at index)
          [(cobj.CompilerObjectSectionKind.Bss) unit]
          [_
            (begin
              (layout.compiler-object-layout-render-padding-to!
                out
                (compiler-object-elf-load-offset image index))
              (layout.compiler-object-layout-render-section!
                out
                image
                (layout.compiler-object-layout-section-at index)))])
        (set! index (+ index 1))))))

(define (compiler-object-elf-relocation-type
  [kind : cobj.CompilerObjectRelocationKind]) : i64
  (match kind
    [(cobj.CompilerObjectRelocationKind.Call)
      compiler-object-elf-r-x86-64-plt32]
    [(cobj.CompilerObjectRelocationKind.TailCall)
      compiler-object-elf-r-x86-64-plt32]
    [(cobj.CompilerObjectRelocationKind.Abs64) compiler-object-elf-r-x86-64-64]
    [(cobj.CompilerObjectRelocationKind.RipValue)
      compiler-object-elf-r-x86-64-pc32]
    [(cobj.CompilerObjectRelocationKind.RipAddress)
      compiler-object-elf-r-x86-64-pc32]
    [(cobj.CompilerObjectRelocationKind.Branch)
      compiler-object-elf-r-x86-64-pc32]
    [_ 0]))

(define (compiler-object-elf-relocation-addend
  [kind : cobj.CompilerObjectRelocationKind]) : i64
  (match kind
    [(cobj.CompilerObjectRelocationKind.Call) -4]
    [(cobj.CompilerObjectRelocationKind.TailCall) -4]
    [(cobj.CompilerObjectRelocationKind.RipValue) -4]
    [(cobj.CompilerObjectRelocationKind.RipAddress) -4]
    [(cobj.CompilerObjectRelocationKind.Branch) -4]
    [_ 0]))

(define (compiler-object-elf-render-relocation-record!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]
  [offset : i64]
  [kind : cobj.CompilerObjectRelocationKind]
  [target : String]) : unit
  (begin
    (layout.compiler-object-layout-push-u64! out offset)
    (layout.compiler-object-layout-push-u64!
      out
      (bit-or
        (shl (compiler-object-elf-symbol-index image target) 32)
        (compiler-object-elf-relocation-type kind)))
    (layout.compiler-object-layout-push-u64!
      out
      (compiler-object-elf-relocation-addend kind))))

(define (compiler-object-elf-render-relocation!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]
  [reloc : cobj.CompilerObjectRelocation]) : unit
  (match reloc
    [(cobj.CompilerObjectRelocation.Relocation section site kind target)
      (compiler-object-elf-render-relocation-record!
        out
        image
        (layout.compiler-object-layout-section-label-offset image section site)
        kind
        target)]))

(define (compiler-object-elf-render-text-relocations!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]) : unit
  (match (cobj.compiler-object-section-list-find
    image.sections
    (cobj.CompilerObjectSectionKind.Text))
    [(cobj.CompilerObjectSection.Section _ _ instrs)
      (let
        [count : i64 (cobj.compiler-object-instr-list-count instrs)]
        [index : i64 0]
        [end : i64 0]
        (begin
          (while (< index count)
            (let
              [instr : cobj.CompilerObjectX64Instr
                (cobj.compiler-object-instr-list-ref instrs index)]
              (begin
                (set!
                  end
                  (+
                    end
                    (layout.compiler-object-layout-instr-size
                      (owned_view.compiler-owned-shared-view instr))))
                (match (layout.compiler-object-layout-instr-fixup instr)
                  [(layout.CompilerObjectLayoutFixup.None) unit]
                  [(layout.CompilerObjectLayoutFixup.One kind target)
                    (compiler-object-elf-render-relocation-record!
                      out
                      image
                      (- end 4)
                      kind
                      target)]
                  [(layout.CompilerObjectLayoutFixup.Branch
                      true-target
                      false-target)
                    (begin
                      (compiler-object-elf-render-relocation-record!
                        out
                        image
                        (- end 9)
                        (cobj.CompilerObjectRelocationKind.Branch)
                        true-target)
                      (compiler-object-elf-render-relocation-record!
                        out
                        image
                        (- end 4)
                        (cobj.CompilerObjectRelocationKind.Branch)
                        false-target))])
                (set! index (+ index 1)))))
          unit))]))

(define (compiler-object-elf-render-relocations-for-section!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]
  [relocs : (& relocs cobj.CompilerObjectRelocationList)]
  [kind : cobj.CompilerObjectSectionKind]) : unit
  (let
    [count : i64 (cobj.compiler-object-relocation-list-count relocs)]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [reloc : cobj.CompilerObjectRelocation
            (cobj.compiler-object-relocation-list-ref relocs index)]
          (begin
            (match (owned_view.compiler-owned-shared-view reloc)
              [(cobj.CompilerObjectRelocation.Relocation section _ _ _)
                (if (cobj.compiler-object-section-kind-eq? section kind)
                  (compiler-object-elf-render-relocation! out image reloc)
                  unit)])
            (set! index (+ index 1)))))
      unit)))

(define (compiler-object-elf-render-relocation-sections!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]) : unit
  (let
    [index : i64 0]
    (while (< index compiler-object-elf-loadable-count)
      (begin
        (layout.compiler-object-layout-render-padding-to!
          out
          (compiler-object-elf-rela-offset image index))
        (let
          [kind : cobj.CompilerObjectSectionKind
            (layout.compiler-object-layout-section-at index)]
          (match kind
            [(cobj.CompilerObjectSectionKind.Text)
              (compiler-object-elf-render-text-relocations! out image)]
            [_
              (compiler-object-elf-render-relocations-for-section!
                out
                image
                image.relocations
                kind)]))
        (set! index (+ index 1))))))

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
    (begin
      (while (and (not done) (< index count))
        (match (cobj.compiler-object-symbol-list-ref symbols index)
          [(cobj.CompilerObjectSymbol.Symbol found _ _ _)
            (if (string.eq found name)
              (begin
                (set! result cur-offset)
                (set! done true))
              (begin
                (set!
                  cur-offset
                  (+
                    cur-offset
                    (+ (layout.compiler-object-layout-string-length found) 1)))
                (set! index (+ index 1))))]))
      result)))

(define (compiler-object-elf-symbol-string-offset
  [image : (& image cobj.CompilerObjectImage)]
  [name : (& name str)]) : i64
  (compiler-object-elf-symbol-string-offset-from image.symbols name 1))

(define (compiler-object-elf-symbol-binding
  [binding : cobj.CompilerObjectSymbolBinding]) : i64
  (match binding
    [(cobj.CompilerObjectSymbolBinding.Local) 0]
    [_ 1]))

(define (compiler-object-elf-symbol-type [kind : cobj.CompilerObjectSymbolKind]) : i64
  (match kind
    [(cobj.CompilerObjectSymbolKind.Function) 2]
    [(cobj.CompilerObjectSymbolKind.Runtime) 2]
    [(cobj.CompilerObjectSymbolKind.Data) 1]
    [_ 0]))

(define (compiler-object-elf-symbol-info
  [binding : cobj.CompilerObjectSymbolBinding]
  [kind : cobj.CompilerObjectSymbolKind]) : i64
  (bit-or
    (shl (compiler-object-elf-symbol-binding binding) 4)
    (compiler-object-elf-symbol-type kind)))

(define (compiler-object-elf-symbol-section-index
  [section : cobj.CompilerObjectMaybeSection]) : i64
  (match section
    [(cobj.CompilerObjectMaybeSection.No) 0]
    [(cobj.CompilerObjectMaybeSection.Some kind)
      (compiler-object-elf-section-index kind)]))

(define (compiler-object-elf-render-null-symbol!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]) : unit
  (layout.compiler-object-layout-push-zeroes!
    out
    compiler-object-elf-symbol-size))

(define (compiler-object-elf-render-symbol!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]
  [symbol : cobj.CompilerObjectSymbol]) : unit
  (match symbol
    [(cobj.CompilerObjectSymbol.Symbol name binding kind section)
      (begin
        (layout.compiler-object-layout-push-u32!
          out
          (compiler-object-elf-symbol-string-offset image name))
        (layout.compiler-object-layout-push-u8!
          out
          (compiler-object-elf-symbol-info binding kind))
        (layout.compiler-object-layout-push-u8! out 0)
        (layout.compiler-object-layout-push-u16!
          out
          (compiler-object-elf-symbol-section-index section))
        (layout.compiler-object-layout-push-u64!
          out
          (layout.compiler-object-layout-symbol-value image name section))
        (layout.compiler-object-layout-push-u64! out 0))]))

(define (compiler-object-elf-render-symbols-by-locality!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]
  [symbols : (& symbols cobj.CompilerObjectSymbolList)]
  [want-local : bool]) : unit
  (let
    [count : i64 (cobj.compiler-object-symbol-list-count symbols)]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [symbol : cobj.CompilerObjectSymbol
            (cobj.compiler-object-symbol-list-ref symbols index)]
          (begin
            (match (owned_view.compiler-owned-shared-view symbol)
              [(cobj.CompilerObjectSymbol.Symbol _ binding _ _)
                (if (=
                  (compiler-object-elf-symbol-binding-local? binding)
                  want-local)
                  (compiler-object-elf-render-symbol! out image symbol)
                  unit)])
            (set! index (+ index 1)))))
      unit)))

(define (compiler-object-elf-render-symbol-table!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]) : unit
  (begin
    (layout.compiler-object-layout-render-padding-to!
      out
      (compiler-object-elf-symtab-offset image))
    (compiler-object-elf-render-null-symbol! out)
    (compiler-object-elf-render-symbols-by-locality!
      out
      image
      image.symbols
      true)
    (compiler-object-elf-render-symbols-by-locality!
      out
      image
      image.symbols
      false)))

(define (compiler-object-elf-render-string-table-symbols!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [symbols : (& symbols cobj.CompilerObjectSymbolList)]) : unit
  (let
    [count : i64 (cobj.compiler-object-symbol-list-count symbols)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (match (cobj.compiler-object-symbol-list-ref symbols index)
            [(cobj.CompilerObjectSymbol.Symbol name _ _ _)
              (begin
                (layout.compiler-object-layout-push-string-bytes! out name)
                (layout.compiler-object-layout-push-u8! out 0))])
          (set! index (+ index 1))))
      unit)))

(define (compiler-object-elf-render-string-tables!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]) : unit
  (begin
    (layout.compiler-object-layout-render-padding-to!
      out
      (compiler-object-elf-strtab-offset image))
    (layout.compiler-object-layout-push-u8! out 0)
    (compiler-object-elf-render-string-table-symbols! out image.symbols)
    (layout.compiler-object-layout-render-padding-to!
      out
      (compiler-object-elf-shstrtab-offset image))
    (compiler-object-elf-push-shstrtab! out)))

(define (compiler-object-elf-section-flags
  [kind : cobj.CompilerObjectSectionKind]) : i64
  (match kind
    [(cobj.CompilerObjectSectionKind.Text)
      (bit-or compiler-object-elf-shf-alloc compiler-object-elf-shf-execinstr)]
    [(cobj.CompilerObjectSectionKind.Data)
      (bit-or compiler-object-elf-shf-alloc compiler-object-elf-shf-write)]
    [(cobj.CompilerObjectSectionKind.Rodata) compiler-object-elf-shf-alloc]
    [(cobj.CompilerObjectSectionKind.Bss)
      (bit-or compiler-object-elf-shf-alloc compiler-object-elf-shf-write)]
    [(cobj.CompilerObjectSectionKind.Pdata) 0]
    [(cobj.CompilerObjectSectionKind.Xdata) 0]
    [(cobj.CompilerObjectSectionKind.Rsrc) 0]))

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
  (begin
    (layout.compiler-object-layout-push-u32! out name-offset)
    (layout.compiler-object-layout-push-u32! out section-type)
    (layout.compiler-object-layout-push-u64! out flags)
    (layout.compiler-object-layout-push-u64! out addr)
    (layout.compiler-object-layout-push-u64! out offset)
    (layout.compiler-object-layout-push-u64! out size)
    (layout.compiler-object-layout-push-u32! out link)
    (layout.compiler-object-layout-push-u32! out info)
    (layout.compiler-object-layout-push-u64! out align)
    (layout.compiler-object-layout-push-u64! out entry-size)))

(define (compiler-object-elf-push-load-section-header!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]
  [index : i64]) : unit
  (let
    [kind : cobj.CompilerObjectSectionKind
      (layout.compiler-object-layout-section-at index)]
    (compiler-object-elf-push-section-header!
      out
      (compiler-object-elf-section-name-offset
        (+ compiler-object-elf-section-text-index index))
      (match kind
        [(cobj.CompilerObjectSectionKind.Bss) compiler-object-elf-sht-nobits]
        [_ compiler-object-elf-sht-progbits])
      (compiler-object-elf-section-flags kind)
      0
      (compiler-object-elf-load-offset image index)
      (layout.compiler-object-layout-section-virtual-size image kind)
      0
      0
      (match kind
        [(cobj.CompilerObjectSectionKind.Text) 16]
        [_ 8])
      0)))

(define (compiler-object-elf-push-rela-section-header!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]
  [index : i64]) : unit
  (compiler-object-elf-push-section-header!
    out
    (compiler-object-elf-section-name-offset
      (+ compiler-object-elf-section-rela-text-index index))
    compiler-object-elf-sht-rela
    0
    0
    (compiler-object-elf-rela-offset image index)
    (compiler-object-elf-relocation-section-size
      image
      (layout.compiler-object-layout-section-at index))
    compiler-object-elf-section-symtab-index
    (+ compiler-object-elf-section-text-index index)
    8
    compiler-object-elf-relocation-size))

(define (compiler-object-elf-push-section-headers!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]) : unit
  (begin
    (layout.compiler-object-layout-render-padding-to!
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
    (let
      [index : i64 0]
      (while (< index compiler-object-elf-loadable-count)
        (begin
          (compiler-object-elf-push-load-section-header! out image index)
          (set! index (+ index 1)))))
    (let
      [index : i64 0]
      (while (< index compiler-object-elf-loadable-count)
        (begin
          (compiler-object-elf-push-rela-section-header! out image index)
          (set! index (+ index 1)))))
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
      (+ 1 (compiler-object-elf-local-symbol-count image.symbols))
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
      (compiler-object-elf-string-table-size image.symbols)
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
      0)
    (compiler-object-elf-push-section-header!
      out
      (compiler-object-elf-section-name-offset
        compiler-object-elf-section-note-gnu-stack-index)
      compiler-object-elf-sht-progbits
      0
      0
      0
      0
      0
      0
      1
      0)))

(define (compiler-object-elf-render
  [image : (& image cobj.CompilerObjectImage)]) : ResultCompilerObjectElf
  (cond
    [(not (compiler-object-elf-data-records-supported? image.sections))
      (ResultCompilerObjectElf.Err
        "elf: object image contains a PE-only SymbolRva32 data record")]
    [(compiler-object-elf-image-supported? image)
      (let
        [out : byte_buf_core.ByteBufBuilder
          (byte_buf_core.byte-buf-builder-new)]
        (begin
          (compiler-object-elf-push-header! (&mut out) image)
          (compiler-object-elf-render-loadable-sections! (&mut out) image)
          (compiler-object-elf-render-relocation-sections! (&mut out) image)
          (compiler-object-elf-render-symbol-table! (&mut out) image)
          (compiler-object-elf-render-string-tables! (&mut out) image)
          (compiler-object-elf-push-section-headers! (&mut out) image)
          (ResultCompilerObjectElf.Ok
            (layout.compiler-object-layout-bytes-string (& out)))))]
    [else
      (ResultCompilerObjectElf.Err
        "elf: object image contains unsupported text instructions or relocation records")]))

(define (compiler-object-elf-section-header-start
  [image : (& image cobj.CompilerObjectImage)]
  [index : i64]) : i64
  (+
    (compiler-object-elf-section-header-offset image)
    (* compiler-object-elf-section-header-size index)))

(define (compiler-object-elf-section-header-size-at
  [text : (& text str)]
  [image : (& image cobj.CompilerObjectImage)]
  [index : i64]) : i64
  (layout.compiler-object-layout-u32-at
    text
    (+ (compiler-object-elf-section-header-start image index) 32)))

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
      (begin
        (layout.compiler-object-layout-push-u8! (&mut out) 0xc3)
        (layout.compiler-object-layout-bytes-string (& out))))))

(cfg
  test
  (define (compiler-object-elf-text-smoke-instrs) : cobj.CompilerObjectX64InstrList
    (let
      [instrs0 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-with-capacity 16)]
      [instrs1 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs0
          (cobj.CompilerObjectX64Instr.Label "_tl_text"))]
      [instrs2 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs1
          (cobj.CompilerObjectX64Instr.Call "foreign_exact"))]
      [instrs3 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs2
          (cobj.CompilerObjectX64Instr.LoadRip "_tl_cell"))]
      [instrs4 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs3
          (cobj.CompilerObjectX64Instr.LoadRipAddress "_tl_message"))]
      [instrs5 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs4
          (cobj.CompilerObjectX64Instr.StoreRip "_tl_cell"))]
      [instrs6 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs5
          (cobj.CompilerObjectX64Instr.Branch ".L_true" ".L_false"))]
      [instrs7 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs6
          (cobj.CompilerObjectX64Instr.Label ".L_true"))]
      [instrs8 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs7
          (cobj.CompilerObjectX64Instr.Jump ".L_done"))]
      [instrs9 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs8
          (cobj.CompilerObjectX64Instr.Label ".L_false"))]
      [instrs10 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs9
          (cobj.CompilerObjectX64Instr.TailCall "_tl_text"))]
      [instrs11 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs10
          (cobj.CompilerObjectX64Instr.Label ".L_done"))]
      [instrs12 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs11
          (cobj.CompilerObjectX64Instr.SubRspImm8 8))]
      [instrs13 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs12
          (cobj.CompilerObjectX64Instr.MovRcxRip "_tl_cell"))]
      [instrs14 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs13
          (cobj.CompilerObjectX64Instr.MovRdxRip "_tl_message"))]
      [instrs15 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs14
          (cobj.CompilerObjectX64Instr.MovRcxRax))]
      [instrs16 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs15
          (cobj.CompilerObjectX64Instr.Raw (compiler-object-elf-ret-bytes)))]
      (cobj.compiler-object-instr-builder-finish instrs16))))

(cfg
  test
  (define (compiler-object-elf-text-smoke-relocations) : cobj.CompilerObjectRelocationList
    (let
      [relocs0 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-with-capacity 10)]
      [relocs1 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs0
          (cobj.CompilerObjectRelocation.Relocation
            (cobj.CompilerObjectSectionKind.Text)
            "_tl_text"
            (cobj.CompilerObjectRelocationKind.Call)
            "foreign_exact"))]
      [relocs2 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs1
          (cobj.CompilerObjectRelocation.Relocation
            (cobj.CompilerObjectSectionKind.Text)
            "_tl_text"
            (cobj.CompilerObjectRelocationKind.RipValue)
            "_tl_cell"))]
      [relocs3 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs2
          (cobj.CompilerObjectRelocation.Relocation
            (cobj.CompilerObjectSectionKind.Text)
            "_tl_text"
            (cobj.CompilerObjectRelocationKind.RipAddress)
            "_tl_message"))]
      [relocs4 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs3
          (cobj.CompilerObjectRelocation.Relocation
            (cobj.CompilerObjectSectionKind.Text)
            "_tl_text"
            (cobj.CompilerObjectRelocationKind.RipAddress)
            "_tl_cell"))]
      [relocs5 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs4
          (cobj.CompilerObjectRelocation.Relocation
            (cobj.CompilerObjectSectionKind.Text)
            "_tl_text"
            (cobj.CompilerObjectRelocationKind.Branch)
            ".L_true"))]
      [relocs6 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs5
          (cobj.CompilerObjectRelocation.Relocation
            (cobj.CompilerObjectSectionKind.Text)
            "_tl_text"
            (cobj.CompilerObjectRelocationKind.Branch)
            ".L_false"))]
      [relocs7 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs6
          (cobj.CompilerObjectRelocation.Relocation
            (cobj.CompilerObjectSectionKind.Text)
            "_tl_text"
            (cobj.CompilerObjectRelocationKind.Branch)
            ".L_done"))]
      [relocs8 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs7
          (cobj.CompilerObjectRelocation.Relocation
            (cobj.CompilerObjectSectionKind.Text)
            "_tl_text"
            (cobj.CompilerObjectRelocationKind.TailCall)
            "_tl_text"))]
      [relocs9 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs8
          (cobj.CompilerObjectRelocation.Relocation
            (cobj.CompilerObjectSectionKind.Text)
            "_tl_text"
            (cobj.CompilerObjectRelocationKind.RipValue)
            "_tl_cell"))]
      [relocs10 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs9
          (cobj.CompilerObjectRelocation.Relocation
            (cobj.CompilerObjectSectionKind.Text)
            "_tl_text"
            (cobj.CompilerObjectRelocationKind.RipValue)
            "_tl_message"))]
      (cobj.compiler-object-relocation-builder-finish relocs10))))

(cfg
  test
  (define (compiler-object-elf-interior-nul-string) : String
    (let
      [out : byte_buf_core.ByteBufBuilder
        (byte_buf_core.byte-buf-builder-with-capacity 3)]
      (begin
        (byte_buf_core.byte-buf-builder-push (&mut out) 0x61)
        (byte_buf_core.byte-buf-builder-push (&mut out) 0)
        (byte_buf_core.byte-buf-builder-push (&mut out) 0x62)
        (byte_buf_core.byte-buf-builder-finish-string (& out))))))

(cfg
  test
  (define (compiler-object-elf-string-record-layout-ok?) : bool
    (let
      [out : byte_buf_core.ByteBufBuilder
        (byte_buf_core.byte-buf-builder-with-capacity 8)]
      [after-empty : i64
        (layout.compiler-object-layout-render-data-record!
          (&mut out)
          (cobj.CompilerObjectDataRecord.String "")
          0)]
      [after-interior-nul : i64
        (layout.compiler-object-layout-render-data-record!
          (&mut out)
          (cobj.CompilerObjectDataRecord.String
            (compiler-object-elf-interior-nul-string))
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
      [empty-data : cobj.CompilerObjectDataRecordList
        (cobj.compiler-object-data-record-builder-finish
          (cobj.compiler-object-data-record-builder-with-capacity 1))]
      [empty-instrs : cobj.CompilerObjectX64InstrList
        (cobj.compiler-object-instr-builder-finish
          (cobj.compiler-object-instr-builder-with-capacity 1))]
      [data0 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-with-capacity 2)]
      [data1 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          data0
          (cobj.CompilerObjectDataRecord.Label "_tl_cell"))]
      [data2 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          data1
          (cobj.CompilerObjectDataRecord.I64 0))]
      [rodata0 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-with-capacity 2)]
      [rodata1 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          rodata0
          (cobj.CompilerObjectDataRecord.Label "_tl_message"))]
      [rodata2 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          rodata1
          (cobj.CompilerObjectDataRecord.String "ok"))]
      [sections0 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-with-capacity 4)]
      [sections1 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections0
          (cobj.CompilerObjectSection.Section
            (cobj.CompilerObjectSectionKind.Text)
            (owned_view.compiler-owned-shared-view empty-data)
            (compiler-object-elf-text-smoke-instrs)))]
      [sections2 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections1
          (cobj.CompilerObjectSection.Section
            (cobj.CompilerObjectSectionKind.Data)
            (cobj.compiler-object-data-record-builder-finish data2)
            (owned_view.compiler-owned-shared-view empty-instrs)))]
      [sections3 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections2
          (cobj.CompilerObjectSection.Section
            (cobj.CompilerObjectSectionKind.Rodata)
            (cobj.compiler-object-data-record-builder-finish rodata2)
            (owned_view.compiler-owned-shared-view empty-instrs)))]
      [sections4 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections3
          (cobj.CompilerObjectSection.Section
            (cobj.CompilerObjectSectionKind.Bss)
            empty-data
            empty-instrs))]
      [symbols0 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-with-capacity 7)]
      [symbols1 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols0
          (cobj.CompilerObjectSymbol.Symbol
            ".L_true"
            (cobj.CompilerObjectSymbolBinding.Local)
            (cobj.CompilerObjectSymbolKind.Function)
            (cobj.CompilerObjectMaybeSection.Some
              (cobj.CompilerObjectSectionKind.Text))))]
      [symbols2 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols1
          (cobj.CompilerObjectSymbol.Symbol
            ".L_false"
            (cobj.CompilerObjectSymbolBinding.Local)
            (cobj.CompilerObjectSymbolKind.Function)
            (cobj.CompilerObjectMaybeSection.Some
              (cobj.CompilerObjectSectionKind.Text))))]
      [symbols3 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols2
          (cobj.CompilerObjectSymbol.Symbol
            ".L_done"
            (cobj.CompilerObjectSymbolBinding.Local)
            (cobj.CompilerObjectSymbolKind.Function)
            (cobj.CompilerObjectMaybeSection.Some
              (cobj.CompilerObjectSectionKind.Text))))]
      [symbols4 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols3
          (cobj.CompilerObjectSymbol.Symbol
            "_tl_message"
            (cobj.CompilerObjectSymbolBinding.Local)
            (cobj.CompilerObjectSymbolKind.Data)
            (cobj.CompilerObjectMaybeSection.Some
              (cobj.CompilerObjectSectionKind.Rodata))))]
      [symbols5 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols4
          (cobj.CompilerObjectSymbol.Symbol
            "_tl_text"
            (cobj.CompilerObjectSymbolBinding.Export)
            (cobj.CompilerObjectSymbolKind.Function)
            (cobj.CompilerObjectMaybeSection.Some
              (cobj.CompilerObjectSectionKind.Text))))]
      [symbols6 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols5
          (cobj.CompilerObjectSymbol.Symbol
            "_tl_cell"
            (cobj.CompilerObjectSymbolBinding.Export)
            (cobj.CompilerObjectSymbolKind.Data)
            (cobj.CompilerObjectMaybeSection.Some
              (cobj.CompilerObjectSectionKind.Data))))]
      [symbols7 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols6
          (cobj.CompilerObjectSymbol.Symbol
            "foreign_exact"
            (cobj.CompilerObjectSymbolBinding.Extern)
            (cobj.CompilerObjectSymbolKind.Function)
            cobj.CompilerObjectMaybeSection.No))]
      (cobj.CompilerObjectImage
        (cobj.compiler-object-section-builder-finish sections4)
        (cobj.compiler-object-symbol-builder-finish symbols7)
        (compiler-object-elf-text-smoke-relocations)))))

(cfg
  test
  (define (compiler-object-elf-smoke-image) : cobj.CompilerObjectImage
    (let
      [empty-data : cobj.CompilerObjectDataRecordList
        (cobj.compiler-object-data-record-builder-finish
          (cobj.compiler-object-data-record-builder-with-capacity 1))]
      [empty-instrs : cobj.CompilerObjectX64InstrList
        (cobj.compiler-object-instr-builder-finish
          (cobj.compiler-object-instr-builder-with-capacity 1))]
      [text0 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-with-capacity 2)]
      [text1 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          text0
          (cobj.CompilerObjectX64Instr.Label "_tl_empty"))]
      [text2 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          text1
          (cobj.CompilerObjectX64Instr.Raw (compiler-object-elf-ret-bytes)))]
      [data0 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-with-capacity 3)]
      [data1 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          data0
          (cobj.CompilerObjectDataRecord.Label "_tl_cell"))]
      [data2 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          data1
          (cobj.CompilerObjectDataRecord.SymbolAddress "_tl_message"))]
      [data3 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          data2
          (cobj.CompilerObjectDataRecord.I64 99))]
      [rodata0 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-with-capacity 5)]
      [rodata1 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          rodata0
          (cobj.CompilerObjectDataRecord.Label "_tl_message"))]
      [rodata2 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          rodata1
          (cobj.CompilerObjectDataRecord.String "ok"))]
      [rodata3 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          rodata2
          (cobj.CompilerObjectDataRecord.Align 8))]
      [rodata4 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          rodata3
          (cobj.CompilerObjectDataRecord.Label "_tl_pi"))]
      [rodata5 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          rodata4
          (cobj.CompilerObjectDataRecord.F64 0x400c000000000000))]
      [bss0 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-with-capacity 2)]
      [bss1 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          bss0
          (cobj.CompilerObjectDataRecord.Label "_tl_zero"))]
      [bss2 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          bss1
          (cobj.CompilerObjectDataRecord.Zero 16))]
      [sections0 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-with-capacity 4)]
      [sections1 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections0
          (cobj.CompilerObjectSection.Section
            (cobj.CompilerObjectSectionKind.Text)
            empty-data
            (cobj.compiler-object-instr-builder-finish text2)))]
      [sections2 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections1
          (cobj.CompilerObjectSection.Section
            (cobj.CompilerObjectSectionKind.Data)
            (cobj.compiler-object-data-record-builder-finish data3)
            (owned_view.compiler-owned-shared-view empty-instrs)))]
      [sections3 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections2
          (cobj.CompilerObjectSection.Section
            (cobj.CompilerObjectSectionKind.Rodata)
            (cobj.compiler-object-data-record-builder-finish rodata5)
            (owned_view.compiler-owned-shared-view empty-instrs)))]
      [sections4 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections3
          (cobj.CompilerObjectSection.Section
            (cobj.CompilerObjectSectionKind.Bss)
            (cobj.compiler-object-data-record-builder-finish bss2)
            empty-instrs))]
      [symbols0 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-with-capacity 5)]
      [symbols1 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols0
          (cobj.CompilerObjectSymbol.Symbol
            "_tl_empty"
            (cobj.CompilerObjectSymbolBinding.Export)
            (cobj.CompilerObjectSymbolKind.Function)
            (cobj.CompilerObjectMaybeSection.Some
              (cobj.CompilerObjectSectionKind.Text))))]
      [symbols2 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols1
          (cobj.CompilerObjectSymbol.Symbol
            "_tl_cell"
            (cobj.CompilerObjectSymbolBinding.Export)
            (cobj.CompilerObjectSymbolKind.Data)
            (cobj.CompilerObjectMaybeSection.Some
              (cobj.CompilerObjectSectionKind.Data))))]
      [symbols3 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols2
          (cobj.CompilerObjectSymbol.Symbol
            "_tl_message"
            (cobj.CompilerObjectSymbolBinding.Local)
            (cobj.CompilerObjectSymbolKind.Data)
            (cobj.CompilerObjectMaybeSection.Some
              (cobj.CompilerObjectSectionKind.Rodata))))]
      [symbols4 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols3
          (cobj.CompilerObjectSymbol.Symbol
            "_tl_zero"
            (cobj.CompilerObjectSymbolBinding.Export)
            (cobj.CompilerObjectSymbolKind.Data)
            (cobj.CompilerObjectMaybeSection.Some
              (cobj.CompilerObjectSectionKind.Bss))))]
      [symbols5 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols4
          (cobj.CompilerObjectSymbol.Symbol
            "foreign_exact"
            (cobj.CompilerObjectSymbolBinding.Extern)
            (cobj.CompilerObjectSymbolKind.Function)
            cobj.CompilerObjectMaybeSection.No))]
      [relocs : cobj.CompilerObjectRelocationList
        (cobj.compiler-object-relocation-builder-finish
          (cobj.compiler-object-relocation-builder-push
            (cobj.compiler-object-relocation-builder-with-capacity 1)
            (cobj.CompilerObjectRelocation.Relocation
              (cobj.CompilerObjectSectionKind.Data)
              "_tl_cell"
              (cobj.CompilerObjectRelocationKind.Abs64)
              "_tl_message")))]
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
      [(ResultCompilerObjectElf.Ok obj)
        (and
          (=
            (layout.compiler-object-layout-string-length obj)
            (+
              (let
                [image (compiler-object-elf-smoke-image)]
                (compiler-object-elf-section-header-offset image))
              (*
                compiler-object-elf-section-header-size
                compiler-object-elf-section-count)))
          (= (cast (layout.compiler-object-layout-string-ref obj 0) : i64) 0x7f)
          (= (cast (layout.compiler-object-layout-string-ref obj 1) : i64) 0x45)
          (= (layout.compiler-object-layout-u16-at obj 18) 62)
          (=
            (layout.compiler-object-layout-u16-at obj 58)
            compiler-object-elf-section-header-size)
          (=
            (layout.compiler-object-layout-u16-at obj 60)
            compiler-object-elf-section-count)
          (layout.compiler-object-layout-contains? obj ".rela.data")
          (layout.compiler-object-layout-contains? obj ".note.GNU-stack")
          (layout.compiler-object-layout-contains? obj "_tl_message")
          (layout.compiler-object-layout-contains? obj "foreign_exact"))]
      [(ResultCompilerObjectElf.Err _) false])))

(cfg
  test
  (define (compiler-object-elf-text-smoke-ok?) : bool
    (let
      [image : cobj.CompilerObjectImage (compiler-object-elf-text-smoke-image)]
      (match (compiler-object-elf-render image)
        [(ResultCompilerObjectElf.Ok obj)
          (let
            [text-offset : i64 (compiler-object-elf-load-offset image 0)]
            [rela-offset : i64 (compiler-object-elf-rela-offset image 0)]
            (and
              (=
                (compiler-object-elf-section-header-size-at
                  obj
                  image
                  compiler-object-elf-section-text-index)
                72)
              (=
                (compiler-object-elf-section-header-size-at
                  obj
                  image
                  compiler-object-elf-section-rela-text-index)
                (* 10 compiler-object-elf-relocation-size))
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
              (layout.compiler-object-layout-contains? obj "_tl_cell")
              (layout.compiler-object-layout-contains? obj "foreign_exact")))]
        [(ResultCompilerObjectElf.Err _) false]))))

(cfg
  test
  (define (compiler-object-elf-rodata-record-image
    [record : cobj.CompilerObjectDataRecord]) : cobj.CompilerObjectImage
    (let
      [empty-data : cobj.CompilerObjectDataRecordList
        (cobj.compiler-object-data-record-builder-finish
          (cobj.compiler-object-data-record-builder-with-capacity 1))]
      [empty-instrs : cobj.CompilerObjectX64InstrList
        (cobj.compiler-object-instr-builder-finish
          (cobj.compiler-object-instr-builder-with-capacity 1))]
      [data0 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-with-capacity 2)]
      [data1 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          data0
          (cobj.CompilerObjectDataRecord.Label "_tl_cell"))]
      [data2 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          data1
          (cobj.CompilerObjectDataRecord.I64 0))]
      [rodata0 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-with-capacity 2)]
      [rodata1 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          rodata0
          (cobj.CompilerObjectDataRecord.Label "_tl_table"))]
      [rodata2 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push rodata1 record)]
      [sections0 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-with-capacity 4)]
      [sections1 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections0
          (cobj.CompilerObjectSection.Section
            (cobj.CompilerObjectSectionKind.Text)
            (owned_view.compiler-owned-shared-view empty-data)
            (owned_view.compiler-owned-shared-view empty-instrs)))]
      [sections2 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections1
          (cobj.CompilerObjectSection.Section
            (cobj.CompilerObjectSectionKind.Data)
            (cobj.compiler-object-data-record-builder-finish data2)
            (owned_view.compiler-owned-shared-view empty-instrs)))]
      [sections3 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections2
          (cobj.CompilerObjectSection.Section
            (cobj.CompilerObjectSectionKind.Rodata)
            (cobj.compiler-object-data-record-builder-finish rodata2)
            (owned_view.compiler-owned-shared-view empty-instrs)))]
      [sections4 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections3
          (cobj.CompilerObjectSection.Section
            (cobj.CompilerObjectSectionKind.Bss)
            empty-data
            empty-instrs))]
      [symbols0 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-with-capacity 1)]
      [symbols1 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols0
          (cobj.CompilerObjectSymbol.Symbol
            "_tl_cell"
            (cobj.CompilerObjectSymbolBinding.Export)
            (cobj.CompilerObjectSymbolKind.Data)
            (cobj.CompilerObjectMaybeSection.Some
              (cobj.CompilerObjectSectionKind.Data))))]
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
        (compiler-object-elf-rodata-record-image
          (cobj.CompilerObjectDataRecord.SymbolRva32 "_tl_cell"))]
      [control : cobj.CompilerObjectImage
        (compiler-object-elf-rodata-record-image
          (cobj.CompilerObjectDataRecord.SymbolAddress "_tl_cell"))]
      (and
        (not (compiler-object-elf-image-supported? rva))
        (match (compiler-object-elf-render rva)
          [(ResultCompilerObjectElf.Err message)
            (string.eq
              message
              "elf: object image contains a PE-only SymbolRva32 data record")]
          [(ResultCompilerObjectElf.Ok _) false])
        (compiler-object-elf-image-supported? control)
        (match (compiler-object-elf-render control)
          [(ResultCompilerObjectElf.Ok _) true]
          [(ResultCompilerObjectElf.Err _) false])))))

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
        "elf rejects PE-only SymbolRva32 data records"))))