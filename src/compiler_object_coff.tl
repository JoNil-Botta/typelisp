;; compiler_object_coff.tl - COFF object-file serialization for object images.
(import compiler_owned_view as owned_view)
(import stdlib.byte_buf_core)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.string)
(import compiler_object as cobj)
(import compiler_object_layout as layout)
(cfg test (import stdlib.test))

(defenum ResultCompilerObjectCoff
  (Ok String)
  (Err String))

(defenum ResultCompilerObjectCoffLayout
  (Ok i64)
  (Err String))

(defstruct CompilerObjectCoffLayoutAccumulator
  (offset i64)
  (error String))

(define compiler-object-coff-machine-amd64 : i64
  0x8664)
(define compiler-object-coff-section-count : i64
  7)
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
  1073741824)
(define compiler-object-coff-reloc-amd64-addr64 : i64
  0x0001)
(define compiler-object-coff-reloc-amd64-rel32 : i64
  0x0004)
(define compiler-object-coff-reloc-amd64-addr32nb : i64
  0x0003)
(define compiler-object-coff-section-cnt-code : i64
  0x00000020)
(define compiler-object-coff-section-cnt-initialized-data : i64
  0x00000040)
(define compiler-object-coff-section-cnt-uninitialized-data : i64
  0x00000080)
(define compiler-object-coff-section-lnk-nreloc-ovfl : i64
  0x01000000)
(define compiler-object-coff-section-align-8 : i64
  0x00400000)
(define compiler-object-coff-section-align-16 : i64
  0x00500000)
(define compiler-object-coff-section-mem-execute : i64
  0x20000000)
(define compiler-object-coff-section-mem-read : i64
  0x40000000)
(define compiler-object-coff-section-mem-write : i64
  0x80000000)

(define (compiler-object-coff-section-name
  [kind : cobj.CompilerObjectSectionKind]) : String
  (match kind
    [(cobj.CompilerObjectSectionKind.Text) ".text"]
    [(cobj.CompilerObjectSectionKind.Data) ".data"]
    [(cobj.CompilerObjectSectionKind.Rodata) ".rdata"]
    [(cobj.CompilerObjectSectionKind.Bss) ".bss"]
    [(cobj.CompilerObjectSectionKind.Pdata) ".pdata"]
    [(cobj.CompilerObjectSectionKind.Xdata) ".xdata"]
    [(cobj.CompilerObjectSectionKind.Rsrc) ".rsrc"]))

(define (compiler-object-coff-section-number
  [kind : cobj.CompilerObjectSectionKind]) : i64
  (+ 1 (layout.compiler-object-layout-section-index kind)))

(define (compiler-object-coff-section-flags
  [kind : cobj.CompilerObjectSectionKind]) : i64
  (match kind
    [(cobj.CompilerObjectSectionKind.Text)
      (bit-or
        compiler-object-coff-section-cnt-code
        (bit-or
          compiler-object-coff-section-align-16
          (bit-or
            compiler-object-coff-section-mem-execute
            compiler-object-coff-section-mem-read)))]
    [(cobj.CompilerObjectSectionKind.Data)
      (bit-or
        compiler-object-coff-section-cnt-initialized-data
        (bit-or
          compiler-object-coff-section-align-8
          (bit-or
            compiler-object-coff-section-mem-read
            compiler-object-coff-section-mem-write)))]
    [(cobj.CompilerObjectSectionKind.Rodata)
      (bit-or
        compiler-object-coff-section-cnt-initialized-data
        (bit-or
          compiler-object-coff-section-align-8
          compiler-object-coff-section-mem-read))]
    [(cobj.CompilerObjectSectionKind.Bss)
      (bit-or
        compiler-object-coff-section-cnt-uninitialized-data
        (bit-or
          compiler-object-coff-section-align-8
          (bit-or
            compiler-object-coff-section-mem-read
            compiler-object-coff-section-mem-write)))]
    [(cobj.CompilerObjectSectionKind.Pdata)
      (bit-or
        compiler-object-coff-section-cnt-initialized-data
        (bit-or
          compiler-object-coff-section-align-8
          compiler-object-coff-section-mem-read))]
    [(cobj.CompilerObjectSectionKind.Xdata)
      (bit-or
        compiler-object-coff-section-cnt-initialized-data
        (bit-or
          compiler-object-coff-section-align-8
          compiler-object-coff-section-mem-read))]
    [(cobj.CompilerObjectSectionKind.Rsrc)
      (bit-or
        compiler-object-coff-section-cnt-initialized-data
        (bit-or
          compiler-object-coff-section-align-8
          compiler-object-coff-section-mem-read))]))

(define (compiler-object-coff-push-name8!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [name : (& name str)]) : unit
  (let
    [i : i64 0]
    [n : i64 (layout.compiler-object-layout-string-length name)]
    (begin
      (while (< i 8)
        (begin
          (if (< i n)
            (byte_buf_core.byte-buf-builder-push
              out
              (cast (layout.compiler-object-layout-string-ref name i) : u8))
            (layout.compiler-object-layout-push-u8! out 0))
          (set! i (+ i 1))))
      unit)))

(define (compiler-object-coff-relocation-list-supported?
  [relocs : (& relocs cobj.CompilerObjectRelocationList)]) : bool
  (layout.compiler-object-layout-relocation-list-supported? relocs true))

;; Raw text bytes are ELF-only; every other instruction form encodes.
(define (compiler-object-coff-sections-supported?
  [sections : (& sections cobj.CompilerObjectSectionList)]) : bool
  (let
    [count : i64 (cobj.compiler-object-section-list-count sections)]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (match (cobj.compiler-object-section-list-ref sections index)
          [(cobj.CompilerObjectSection.Section _ _ instrs)
            (let
              [instr-count : i64 (cobj.compiler-object-instr-list-count instrs)]
              [instr-index : i64 0]
              (begin
                (while (and ok (< instr-index instr-count))
                  (match (cobj.compiler-object-instr-list-ref
                    instrs
                    instr-index)
                    [(cobj.CompilerObjectX64Instr.Raw _) (set! ok false)]
                    [_ (set! instr-index (+ instr-index 1))]))
                (set! index (+ index 1))))]))
      ok)))

(define (compiler-object-coff-symbol-index-from
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
          [(cobj.CompilerObjectSymbol.Symbol found _ _ _)
            (if (string.eq found name)
              (begin
                (set! result cur-index)
                (set! done true))
              (begin
                (set! cur-index (+ cur-index 1))
                (set! slot (+ slot 1))))]))
      result)))

(define (compiler-object-coff-symbol-index
  [image : (& image cobj.CompilerObjectImage)]
  [name : String]) : i64
  (compiler-object-coff-symbol-index-from image.symbols name 0))

(define (compiler-object-coff-relocation-sites-known?
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
            (if (match section
              [(cobj.CompilerObjectSectionKind.Text)
                (>= (compiler-object-coff-symbol-index image target) 0)]
              [_
                (and
                  (>=
                    (layout.compiler-object-layout-section-label-offset
                      image
                      section
                      site)
                    0)
                  (>= (compiler-object-coff-symbol-index image target) 0))])
              (set! index (+ index 1))
              (set! ok false))]))
      ok)))

(define (compiler-object-coff-image-supported?
  [image : (& image cobj.CompilerObjectImage)]) : bool
  (and
    (compiler-object-coff-sections-supported? image.sections)
    (compiler-object-coff-relocation-list-supported? image.relocations)
    (compiler-object-coff-relocation-sites-known? image image.relocations)
    (layout.compiler-object-layout-text-targets-known? image)
    (layout.compiler-object-layout-text-relocation-count-matches? image)))

(define (compiler-object-coff-header-size) : i64
  (+
    compiler-object-coff-file-header-size
    (*
      compiler-object-coff-section-header-size
      compiler-object-coff-section-count)))

(define (compiler-object-coff-relocation-count-overflows?
  [semantic-count : i64]) : bool
  (>= semantic-count compiler-object-coff-relocation-overflow-threshold))

(define (compiler-object-coff-relocation-physical-count [semantic-count : i64]) : i64
  (if (compiler-object-coff-relocation-count-overflows? semantic-count)
    (+ semantic-count 1)
    semantic-count))

(define (compiler-object-coff-section-relocation-physical-count
  [image : (& image cobj.CompilerObjectImage)]
  [kind : cobj.CompilerObjectSectionKind]) : i64
  (compiler-object-coff-relocation-physical-count
    (layout.compiler-object-layout-section-relocation-count image kind)))

(define (compiler-object-coff-section-header-relocation-count
  [image : (& image cobj.CompilerObjectImage)]
  [kind : cobj.CompilerObjectSectionKind]) : i64
  (let
    [semantic-count : i64
      (layout.compiler-object-layout-section-relocation-count image kind)]
    (if (compiler-object-coff-relocation-count-overflows? semantic-count)
      compiler-object-coff-relocation-overflow-threshold
      semantic-count)))

(define (compiler-object-coff-section-header-flags
  [image : (& image cobj.CompilerObjectImage)]
  [kind : cobj.CompilerObjectSectionKind]) : i64
  (if (compiler-object-coff-relocation-count-overflows?
    (layout.compiler-object-layout-section-relocation-count image kind))
    (bit-or
      (compiler-object-coff-section-flags kind)
      compiler-object-coff-section-lnk-nreloc-ovfl)
    (compiler-object-coff-section-flags kind)))

(define (compiler-object-coff-raw-size-before
  [image : (& image cobj.CompilerObjectImage)]
  [end : i64]) : i64
  (let
    [index : i64 0]
    [total : i64 0]
    (begin
      (while (< index end)
        (begin
          (set!
            total
            (+
              total
              (layout.compiler-object-layout-section-raw-size
                image
                (layout.compiler-object-layout-section-at index))))
          (set! index (+ index 1))))
      total)))

(define (compiler-object-coff-relocation-physical-count-before
  [image : (& image cobj.CompilerObjectImage)]
  [end : i64]) : i64
  (let
    [index : i64 0]
    [total : i64 0]
    (begin
      (while (< index end)
        (begin
          (set!
            total
            (+
              total
              (compiler-object-coff-section-relocation-physical-count
                image
                (layout.compiler-object-layout-section-at index))))
          (set! index (+ index 1))))
      total)))

(define (compiler-object-coff-section-raw-pointer
  [image : (& image cobj.CompilerObjectImage)]
  [kind : cobj.CompilerObjectSectionKind]) : i64
  (if (> (layout.compiler-object-layout-section-raw-size image kind) 0)
    (+
      (compiler-object-coff-header-size)
      (compiler-object-coff-raw-size-before
        image
        (layout.compiler-object-layout-section-index kind)))
    0))

(define (compiler-object-coff-relocation-base
  [image : (& image cobj.CompilerObjectImage)]) : i64
  (+
    (compiler-object-coff-header-size)
    (compiler-object-coff-raw-size-before
      image
      layout.compiler-object-layout-section-count)))

(define (compiler-object-coff-relocation-pointer
  [image : (& image cobj.CompilerObjectImage)]
  [kind : cobj.CompilerObjectSectionKind]) : i64
  (if (= (layout.compiler-object-layout-section-relocation-count image kind) 0)
    0
    (+
      (compiler-object-coff-relocation-base image)
      (*
        compiler-object-coff-relocation-size
        (compiler-object-coff-relocation-physical-count-before
          image
          (layout.compiler-object-layout-section-index kind))))))

(define (compiler-object-coff-symbol-table-pointer
  [image : (& image cobj.CompilerObjectImage)]) : i64
  (+
    (compiler-object-coff-relocation-base image)
    (*
      compiler-object-coff-relocation-size
      (compiler-object-coff-relocation-physical-count-before
        image
        layout.compiler-object-layout-section-count))))

(define (compiler-object-coff-push-file-header!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]) : unit
  (begin
    (layout.compiler-object-layout-push-u16!
      out
      compiler-object-coff-machine-amd64)
    (layout.compiler-object-layout-push-u16!
      out
      compiler-object-coff-section-count)
    (layout.compiler-object-layout-push-u32! out 0)
    (layout.compiler-object-layout-push-u32!
      out
      (compiler-object-coff-symbol-table-pointer image))
    (layout.compiler-object-layout-push-u32!
      out
      (cobj.compiler-object-symbol-list-count image.symbols))
    (layout.compiler-object-layout-push-u16! out 0)
    (layout.compiler-object-layout-push-u16! out 0)))

(define (compiler-object-coff-push-section-header!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]
  [kind : cobj.CompilerObjectSectionKind]) : unit
  (begin
    (compiler-object-coff-push-name8!
      out
      (compiler-object-coff-section-name kind))
    (layout.compiler-object-layout-push-u32!
      out
      (layout.compiler-object-layout-section-virtual-size image kind))
    (layout.compiler-object-layout-push-u32! out 0)
    (layout.compiler-object-layout-push-u32!
      out
      (layout.compiler-object-layout-section-raw-size image kind))
    (layout.compiler-object-layout-push-u32!
      out
      (compiler-object-coff-section-raw-pointer image kind))
    (layout.compiler-object-layout-push-u32!
      out
      (compiler-object-coff-relocation-pointer image kind))
    (layout.compiler-object-layout-push-u32! out 0)
    (layout.compiler-object-layout-push-u16!
      out
      (compiler-object-coff-section-header-relocation-count image kind))
    (layout.compiler-object-layout-push-u16! out 0)
    (layout.compiler-object-layout-push-u32!
      out
      (compiler-object-coff-section-header-flags image kind))))

(define (compiler-object-coff-push-section-headers!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]) : unit
  (let
    [index : i64 0]
    (while (< index layout.compiler-object-layout-section-count)
      (begin
        (compiler-object-coff-push-section-header!
          out
          image
          (layout.compiler-object-layout-section-at index))
        (set! index (+ index 1))))))

(define (compiler-object-coff-render-sections!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]) : unit
  (let
    [index : i64 0]
    (while (< index layout.compiler-object-layout-section-count)
      (begin
        (let
          [kind : cobj.CompilerObjectSectionKind
            (layout.compiler-object-layout-section-at index)]
          (match kind
            [(cobj.CompilerObjectSectionKind.Bss) unit]
            [_ (layout.compiler-object-layout-render-section! out image kind)]))
        (set! index (+ index 1))))))

(define (compiler-object-coff-relocation-type
  [kind : cobj.CompilerObjectRelocationKind]) : i64
  (match kind
    [(cobj.CompilerObjectRelocationKind.Call)
      compiler-object-coff-reloc-amd64-rel32]
    [(cobj.CompilerObjectRelocationKind.TailCall)
      compiler-object-coff-reloc-amd64-rel32]
    [(cobj.CompilerObjectRelocationKind.Abs64)
      compiler-object-coff-reloc-amd64-addr64]
    [(cobj.CompilerObjectRelocationKind.Addr32Nb)
      compiler-object-coff-reloc-amd64-addr32nb]
    [(cobj.CompilerObjectRelocationKind.RipValue)
      compiler-object-coff-reloc-amd64-rel32]
    [(cobj.CompilerObjectRelocationKind.RipAddress)
      compiler-object-coff-reloc-amd64-rel32]
    [(cobj.CompilerObjectRelocationKind.Branch)
      compiler-object-coff-reloc-amd64-rel32]
    [_ 0]))

(define (compiler-object-coff-render-relocation-record!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]
  [offset : i64]
  [kind : cobj.CompilerObjectRelocationKind]
  [target : String]) : unit
  (begin
    (layout.compiler-object-layout-push-u32! out offset)
    (layout.compiler-object-layout-push-u32!
      out
      (compiler-object-coff-symbol-index image target))
    (layout.compiler-object-layout-push-u16!
      out
      (compiler-object-coff-relocation-type kind))))

(define (compiler-object-coff-render-relocation!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]
  [reloc : cobj.CompilerObjectRelocation]) : unit
  (match reloc
    [(cobj.CompilerObjectRelocation.Relocation section site kind target)
      (compiler-object-coff-render-relocation-record!
        out
        image
        (layout.compiler-object-layout-section-label-offset image section site)
        kind
        target)]))

(define (compiler-object-coff-render-relocation-overflow-sentinel!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]
  [kind : cobj.CompilerObjectSectionKind]) : unit
  (let
    [semantic-count : i64
      (layout.compiler-object-layout-section-relocation-count image kind)]
    (if (compiler-object-coff-relocation-count-overflows? semantic-count)
      (begin
        ;; COFF stores the physical table-entry count in the sentinel.  The
        ;; sentinel itself has no symbol or relocation type and is not part of
        ;; the compiler's semantic relocation stream.
        (layout.compiler-object-layout-push-u32!
          out
          (compiler-object-coff-relocation-physical-count semantic-count))
        (layout.compiler-object-layout-push-u32! out 0)
        (layout.compiler-object-layout-push-u16! out 0))
      unit)))

(define (compiler-object-coff-render-text-relocations!
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
                    (compiler-object-coff-render-relocation-record!
                      out
                      image
                      (- end 4)
                      kind
                      target)]
                  [(layout.CompilerObjectLayoutFixup.Branch
                      true-target
                      false-target)
                    (begin
                      (compiler-object-coff-render-relocation-record!
                        out
                        image
                        (- end 9)
                        (cobj.CompilerObjectRelocationKind.Branch)
                        true-target)
                      (compiler-object-coff-render-relocation-record!
                        out
                        image
                        (- end 4)
                        (cobj.CompilerObjectRelocationKind.Branch)
                        false-target))])
                (set! index (+ index 1)))))
          unit))]))

(define (compiler-object-coff-render-relocations-for-section!
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
                  (compiler-object-coff-render-relocation! out image reloc)
                  unit)])
            (set! index (+ index 1)))))
      unit)))

(define (compiler-object-coff-render-relocations!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]) : unit
  (let
    [index : i64 0]
    (while (< index layout.compiler-object-layout-section-count)
      (let
        [kind : cobj.CompilerObjectSectionKind
          (layout.compiler-object-layout-section-at index)]
        (begin
          (compiler-object-coff-render-relocation-overflow-sentinel!
            out
            image
            kind)
          (match kind
            [(cobj.CompilerObjectSectionKind.Text)
              (compiler-object-coff-render-text-relocations! out image)]
            [_
              (compiler-object-coff-render-relocations-for-section!
                out
                image
                image.relocations
                kind)])
          (set! index (+ index 1)))))))

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
    (begin
      (while (and (not done) (< index count))
        (match (cobj.compiler-object-symbol-list-ref symbols index)
          [(cobj.CompilerObjectSymbol.Symbol found _ _ _)
            (if (compiler-object-coff-symbol-name-long? found)
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
                  (set! index (+ index 1))))
              (set! index (+ index 1)))]))
      result)))

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
    [(cobj.CompilerObjectSymbolBinding.Local) 3]
    [_ 2]))

(define (compiler-object-coff-symbol-type
  [kind : cobj.CompilerObjectSymbolKind]) : i64
  (match kind
    [(cobj.CompilerObjectSymbolKind.Function) 0x20]
    [_ 0]))

(define (compiler-object-coff-symbol-section-number
  [section : cobj.CompilerObjectMaybeSection]) : i64
  (match section
    [(cobj.CompilerObjectMaybeSection.No) 0]
    [(cobj.CompilerObjectMaybeSection.Some kind)
      (compiler-object-coff-section-number kind)]))

(define (compiler-object-coff-render-symbol!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]
  [symbol : cobj.CompilerObjectSymbol]) : unit
  (match symbol
    [(cobj.CompilerObjectSymbol.Symbol name binding kind section)
      (begin
        (compiler-object-coff-push-symbol-name! out image name)
        (layout.compiler-object-layout-push-u32!
          out
          (layout.compiler-object-layout-symbol-value image name section))
        (layout.compiler-object-layout-push-u16!
          out
          (compiler-object-coff-symbol-section-number section))
        (layout.compiler-object-layout-push-u16!
          out
          (compiler-object-coff-symbol-type kind))
        (layout.compiler-object-layout-push-u8!
          out
          (compiler-object-coff-symbol-storage-class binding))
        (layout.compiler-object-layout-push-u8! out 0))]))

(define (compiler-object-coff-render-symbols!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]
  [symbols : (& symbols cobj.CompilerObjectSymbolList)]) : unit
  (let
    [count : i64 (cobj.compiler-object-symbol-list-count symbols)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (compiler-object-coff-render-symbol!
            out
            image
            (cobj.compiler-object-symbol-list-ref symbols index))
          (set! index (+ index 1))))
      unit)))

(define (compiler-object-coff-string-table-size-from
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
              (if (compiler-object-coff-symbol-name-long? name)
                (set!
                  total
                  (+
                    total
                    (+ (layout.compiler-object-layout-string-length name) 1)))
                unit)])
          (set! index (+ index 1))))
      total)))

(define (compiler-object-coff-string-table-size
  [symbols : (& symbols cobj.CompilerObjectSymbolList)]) : i64
  (compiler-object-coff-string-table-size-from symbols 4))

(define (compiler-object-coff-layout-accumulator-ok?
  [acc : (& acc CompilerObjectCoffLayoutAccumulator)]) : bool
  (= (layout.compiler-object-layout-string-length acc.error) 0))

(define (compiler-object-coff-layout-section-error
  [kind : cobj.CompilerObjectSectionKind]
  [semantic-count : i64]
  [detail : String]) : String
  (str_cat.str-cat
    "coff: windows-x86_64 section "
    (compiler-object-coff-section-name kind)
    " relocation count "
    (string.int->string semantic-count)
    " "
    detail))

(define (compiler-object-coff-layout-section-size-error
  [kind : cobj.CompilerObjectSectionKind]
  [size : i64]
  [detail : String]) : String
  (str_cat.str-cat
    "coff: windows-x86_64 section "
    (compiler-object-coff-section-name kind)
    " size "
    (string.int->string size)
    " "
    detail))

(define (compiler-object-coff-check-section-data-layout
  [acc : CompilerObjectCoffLayoutAccumulator]
  [image : (& image cobj.CompilerObjectImage)]
  [kind : cobj.CompilerObjectSectionKind]
  [max-output-size : i64]) : CompilerObjectCoffLayoutAccumulator
  (if (not (compiler-object-coff-layout-accumulator-ok? acc))
    acc
    (let
      [virtual-size : i64
        (layout.compiler-object-layout-section-virtual-size image kind)]
      [raw-size : i64
        (layout.compiler-object-layout-section-raw-size image kind)]
      (cond
        [(or (< virtual-size 0) (> virtual-size compiler-object-coff-max-u32))
          (CompilerObjectCoffLayoutAccumulator
            acc.offset
            (compiler-object-coff-layout-section-size-error
              kind
              virtual-size
              "is not representable in the COFF section header"))]
        [(or (< raw-size 0) (> raw-size compiler-object-coff-max-u32))
          (CompilerObjectCoffLayoutAccumulator
            acc.offset
            (compiler-object-coff-layout-section-size-error
              kind
              raw-size
              "raw data is not representable in the COFF section header"))]
        [(or
            (> acc.offset max-output-size)
            (> raw-size (- max-output-size acc.offset)))
          (CompilerObjectCoffLayoutAccumulator
            acc.offset
            (compiler-object-coff-layout-section-size-error
              kind
              raw-size
              "raw data exceeds the configured object-size limit"))]
        [else (CompilerObjectCoffLayoutAccumulator (+ acc.offset raw-size) "")]))))

;; This helper is intentionally count-based so boundary and malformed states
;; can be tested without first allocating an equally large relocation list.
(define (compiler-object-coff-check-relocation-count-layout
  [acc : CompilerObjectCoffLayoutAccumulator]
  [kind : cobj.CompilerObjectSectionKind]
  [semantic-count : i64]
  [max-output-size : i64]) : CompilerObjectCoffLayoutAccumulator
  (if (not (compiler-object-coff-layout-accumulator-ok? acc))
    acc
    (cond
      [(< semantic-count 0)
        (CompilerObjectCoffLayoutAccumulator
          acc.offset
          (compiler-object-coff-layout-section-error
            kind
            semantic-count
            "is negative"))]
      [(and
          (compiler-object-coff-relocation-count-overflows? semantic-count)
          (> semantic-count (- compiler-object-coff-max-u32 1)))
        (CompilerObjectCoffLayoutAccumulator
          acc.offset
          (compiler-object-coff-layout-section-error
            kind
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
                kind
                semantic-count
                "physical relocation table exceeds the configured object-size limit"))
            (CompilerObjectCoffLayoutAccumulator
              (+
                acc.offset
                (* physical-count compiler-object-coff-relocation-size))
              "")))])))

(define (compiler-object-coff-check-section-relocation-layout
  [acc : CompilerObjectCoffLayoutAccumulator]
  [image : (& image cobj.CompilerObjectImage)]
  [kind : cobj.CompilerObjectSectionKind]
  [max-output-size : i64]) : CompilerObjectCoffLayoutAccumulator
  (compiler-object-coff-check-relocation-count-layout
    acc
    kind
    (layout.compiler-object-layout-section-relocation-count image kind)
    max-output-size))

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
        (CompilerObjectCoffLayoutAccumulator
          acc.offset
          (str_cat.str-cat
            "coff: windows-x86_64 symbol count "
            (string.int->string count)
            " exceeds the COFF or configured object-size limit"))
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
      (begin
        (while (and
          (= (layout.compiler-object-layout-string-length error) 0)
          (< index count))
          (begin
            (match (cobj.compiler-object-symbol-list-ref symbols index)
              [(cobj.CompilerObjectSymbol.Symbol name _ _ _)
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
                      (set! table-size (+ table-size (+ name-size 1)))))
                  unit)])
            (set! index (+ index 1))))
        (if (> (layout.compiler-object-layout-string-length error) 0)
          (CompilerObjectCoffLayoutAccumulator acc.offset error)
          (if (or
            (> acc.offset max-output-size)
            (> table-size (- max-output-size acc.offset)))
            (CompilerObjectCoffLayoutAccumulator
              acc.offset
              (str_cat.str-cat
                "coff: windows-x86_64 string table size "
                (string.int->string table-size)
                " exceeds the configured object-size limit"))
            (CompilerObjectCoffLayoutAccumulator (+ acc.offset table-size) "")))))))

(define (compiler-object-coff-layout-with-limit
  [image : (& image cobj.CompilerObjectImage)]
  [max-output-size : i64]) : ResultCompilerObjectCoffLayout
  (if (or
    (< max-output-size (compiler-object-coff-header-size))
    (> max-output-size compiler-object-coff-max-u32))
    (ResultCompilerObjectCoffLayout.Err
      (str_cat.str-cat
        "coff: windows-x86_64 configured object-size limit "
        (string.int->string max-output-size)
        " is invalid"))
    (let
      [acc : CompilerObjectCoffLayoutAccumulator
        (CompilerObjectCoffLayoutAccumulator
          (compiler-object-coff-header-size)
          "")]
      [index : i64 0]
      (begin
        (while (< index layout.compiler-object-layout-section-count)
          (begin
            (set!
              acc
              (compiler-object-coff-check-section-data-layout
                acc
                image
                (layout.compiler-object-layout-section-at index)
                max-output-size))
            (set! index (+ index 1))))
        (set! index 0)
        (while (< index layout.compiler-object-layout-section-count)
          (begin
            (set!
              acc
              (compiler-object-coff-check-section-relocation-layout
                acc
                image
                (layout.compiler-object-layout-section-at index)
                max-output-size))
            (set! index (+ index 1))))
        (set!
          acc
          (compiler-object-coff-check-symbol-table-layout
            acc
            image.symbols
            max-output-size))
        (set!
          acc
          (compiler-object-coff-check-string-table-layout
            acc
            image.symbols
            max-output-size))
        (if (compiler-object-coff-layout-accumulator-ok? acc)
          (ResultCompilerObjectCoffLayout.Ok acc.offset)
          (ResultCompilerObjectCoffLayout.Err acc.error))))))

(define (compiler-object-coff-render-string-table-symbols!
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
              (if (compiler-object-coff-symbol-name-long? name)
                (begin
                  (layout.compiler-object-layout-push-string-bytes! out name)
                  (layout.compiler-object-layout-push-u8! out 0))
                unit)])
          (set! index (+ index 1))))
      unit)))

(define (compiler-object-coff-render-string-table!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [image : (& image cobj.CompilerObjectImage)]) : unit
  (begin
    (layout.compiler-object-layout-push-u32!
      out
      (compiler-object-coff-string-table-size image.symbols))
    (compiler-object-coff-render-string-table-symbols! out image.symbols)))

(define (compiler-object-coff-render
  [image : (& image cobj.CompilerObjectImage)]) : ResultCompilerObjectCoff
  (if (compiler-object-coff-image-supported? image)
    (match (compiler-object-coff-layout-with-limit
      image
      compiler-object-coff-max-output-size)
      [(ResultCompilerObjectCoffLayout.Ok output-size)
        (let
          [out : byte_buf_core.ByteBufBuilder
            (byte_buf_core.byte-buf-builder-with-capacity output-size)]
          (begin
            (compiler-object-coff-push-file-header! (&mut out) image)
            (compiler-object-coff-push-section-headers! (&mut out) image)
            (compiler-object-coff-render-sections! (&mut out) image)
            (compiler-object-coff-render-relocations! (&mut out) image)
            (compiler-object-coff-render-symbols!
              (&mut out)
              image
              image.symbols)
            (compiler-object-coff-render-string-table! (&mut out) image)
            (ResultCompilerObjectCoff.Ok
              (layout.compiler-object-layout-bytes-string (& out)))))]
      [(ResultCompilerObjectCoffLayout.Err message)
        (ResultCompilerObjectCoff.Err message)])
    (ResultCompilerObjectCoff.Err
      "coff: object image contains unsupported text, f64, or relocation records")))

(define (compiler-object-coff-section-header-offset
  [kind : cobj.CompilerObjectSectionKind]) : i64
  (+
    compiler-object-coff-file-header-size
    (*
      compiler-object-coff-section-header-size
      (- (compiler-object-coff-section-number kind) 1))))

(cfg
  test
  (define (compiler-object-coff-interior-nul-string) : String
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
  (define (compiler-object-coff-string-record-layout-ok?) : bool
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
            (compiler-object-coff-interior-nul-string))
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
      [empty-data : cobj.CompilerObjectDataRecordList
        (cobj.compiler-object-data-record-builder-finish
          (cobj.compiler-object-data-record-builder-with-capacity 1))]
      [empty-instrs : cobj.CompilerObjectX64InstrList
        (cobj.compiler-object-instr-builder-finish
          (cobj.compiler-object-instr-builder-with-capacity 1))]
      [text0 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-with-capacity 1)]
      [text1 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          text0
          (cobj.CompilerObjectX64Instr.Label "_tl_empty"))]
      [data0 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-with-capacity 4)]
      [data1 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          data0
          (cobj.CompilerObjectDataRecord.Label "_tl_answer"))]
      [data2 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          data1
          (cobj.CompilerObjectDataRecord.I64 42))]
      [data3 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          data2
          (cobj.CompilerObjectDataRecord.Label "_tl_ptr"))]
      [data4 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          data3
          (cobj.CompilerObjectDataRecord.SymbolAddress "_tl_answer"))]
      [rodata0 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-with-capacity 2)]
      [rodata1 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          rodata0
          (cobj.CompilerObjectDataRecord.Label "long_rodata_label_name"))]
      [rodata2 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          rodata1
          (cobj.CompilerObjectDataRecord.String "hello"))]
      [bss0 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-with-capacity 2)]
      [bss1 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          bss0
          (cobj.CompilerObjectDataRecord.Label "_tl_heap"))]
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
            (cobj.compiler-object-instr-builder-finish text1)))]
      [sections2 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections1
          (cobj.CompilerObjectSection.Section
            (cobj.CompilerObjectSectionKind.Data)
            (cobj.compiler-object-data-record-builder-finish data4)
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
            "_tl_answer"
            (cobj.CompilerObjectSymbolBinding.Export)
            (cobj.CompilerObjectSymbolKind.Data)
            (cobj.CompilerObjectMaybeSection.Some
              (cobj.CompilerObjectSectionKind.Data))))]
      [symbols3 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols2
          (cobj.CompilerObjectSymbol.Symbol
            "_tl_ptr"
            (cobj.CompilerObjectSymbolBinding.Local)
            (cobj.CompilerObjectSymbolKind.Data)
            (cobj.CompilerObjectMaybeSection.Some
              (cobj.CompilerObjectSectionKind.Data))))]
      [symbols4 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols3
          (cobj.CompilerObjectSymbol.Symbol
            "long_rodata_label_name"
            (cobj.CompilerObjectSymbolBinding.Local)
            (cobj.CompilerObjectSymbolKind.Data)
            (cobj.CompilerObjectMaybeSection.Some
              (cobj.CompilerObjectSectionKind.Rodata))))]
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
              "_tl_ptr"
              (cobj.CompilerObjectRelocationKind.Abs64)
              "_tl_answer")))]
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
      [(ResultCompilerObjectCoff.Ok obj)
        (and
          (=
            (layout.compiler-object-layout-u16-at obj 0)
            compiler-object-coff-machine-amd64)
          (=
            (layout.compiler-object-layout-u16-at obj 2)
            compiler-object-coff-section-count)
          (> (layout.compiler-object-layout-u32-at obj 8) 0)
          (= (layout.compiler-object-layout-u32-at obj 12) 5)
          (= (layout.compiler-object-layout-u32-at obj (+ 60 16)) 16)
          (= (layout.compiler-object-layout-u16-at obj (+ 60 32)) 1)
          (layout.compiler-object-layout-contains? obj ".rdata")
          (layout.compiler-object-layout-contains? obj "foreign_exact")
          (layout.compiler-object-layout-contains? obj "long_rodata_label_name"))]
      [(ResultCompilerObjectCoff.Err _) false])))

(cfg
  test
  (define (compiler-object-coff-text-smoke-instrs) : cobj.CompilerObjectX64InstrList
    (let
      [instrs0 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-with-capacity 11)]
      [instrs1 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs0
          (cobj.CompilerObjectX64Instr.Label "_tl_text"))]
      [instrs2 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs1
          (cobj.CompilerObjectX64Instr.LoadRip "_tl_answer"))]
      [instrs3 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs2
          (cobj.CompilerObjectX64Instr.LoadRipAddress "_tl_slot"))]
      [instrs4 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs3
          (cobj.CompilerObjectX64Instr.StoreRip "_tl_slot"))]
      [instrs5 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs4
          (cobj.CompilerObjectX64Instr.Call "foreign_exact"))]
      [instrs6 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs5
          (cobj.CompilerObjectX64Instr.TailCall "_tl_done"))]
      [instrs7 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs6
          (cobj.CompilerObjectX64Instr.Jump "_tl_done"))]
      [instrs8 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs7
          (cobj.CompilerObjectX64Instr.Branch "_tl_true" "_tl_false"))]
      [instrs9 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs8
          (cobj.CompilerObjectX64Instr.Label "_tl_true"))]
      [instrs10 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs9
          (cobj.CompilerObjectX64Instr.Label "_tl_false"))]
      [instrs11 : cobj.CompilerObjectX64InstrBuilder
        (cobj.compiler-object-instr-builder-push
          instrs10
          (cobj.CompilerObjectX64Instr.Label "_tl_done"))]
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
          (cobj.CompilerObjectSymbol.Symbol
            "_tl_text"
            (cobj.CompilerObjectSymbolBinding.Export)
            (cobj.CompilerObjectSymbolKind.Function)
            (cobj.CompilerObjectMaybeSection.Some
              (cobj.CompilerObjectSectionKind.Text))))]
      [symbols2 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols1
          (cobj.CompilerObjectSymbol.Symbol
            "_tl_true"
            (cobj.CompilerObjectSymbolBinding.Local)
            (cobj.CompilerObjectSymbolKind.Function)
            (cobj.CompilerObjectMaybeSection.Some
              (cobj.CompilerObjectSectionKind.Text))))]
      [symbols3 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols2
          (cobj.CompilerObjectSymbol.Symbol
            "_tl_false"
            (cobj.CompilerObjectSymbolBinding.Local)
            (cobj.CompilerObjectSymbolKind.Function)
            (cobj.CompilerObjectMaybeSection.Some
              (cobj.CompilerObjectSectionKind.Text))))]
      [symbols4 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols3
          (cobj.CompilerObjectSymbol.Symbol
            "_tl_done"
            (cobj.CompilerObjectSymbolBinding.Local)
            (cobj.CompilerObjectSymbolKind.Function)
            (cobj.CompilerObjectMaybeSection.Some
              (cobj.CompilerObjectSectionKind.Text))))]
      [symbols5 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols4
          (cobj.CompilerObjectSymbol.Symbol
            "_tl_answer"
            (cobj.CompilerObjectSymbolBinding.Export)
            (cobj.CompilerObjectSymbolKind.Data)
            (cobj.CompilerObjectMaybeSection.Some
              (cobj.CompilerObjectSectionKind.Data))))]
      [symbols6 : cobj.CompilerObjectSymbolBuilder
        (cobj.compiler-object-symbol-builder-push
          symbols5
          (cobj.CompilerObjectSymbol.Symbol
            "_tl_slot"
            (cobj.CompilerObjectSymbolBinding.Local)
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
          (cobj.CompilerObjectRelocation.Relocation
            (cobj.CompilerObjectSectionKind.Text)
            "_tl_text"
            (cobj.CompilerObjectRelocationKind.RipValue)
            "_tl_answer"))]
      [relocs2 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs1
          (cobj.CompilerObjectRelocation.Relocation
            (cobj.CompilerObjectSectionKind.Text)
            "_tl_text"
            (cobj.CompilerObjectRelocationKind.RipAddress)
            "_tl_slot"))]
      [relocs3 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs2
          (cobj.CompilerObjectRelocation.Relocation
            (cobj.CompilerObjectSectionKind.Text)
            "_tl_text"
            (cobj.CompilerObjectRelocationKind.RipAddress)
            "_tl_slot"))]
      [relocs4 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs3
          (cobj.CompilerObjectRelocation.Relocation
            (cobj.CompilerObjectSectionKind.Text)
            "_tl_text"
            (cobj.CompilerObjectRelocationKind.Call)
            "foreign_exact"))]
      [relocs5 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs4
          (cobj.CompilerObjectRelocation.Relocation
            (cobj.CompilerObjectSectionKind.Text)
            "_tl_text"
            (cobj.CompilerObjectRelocationKind.TailCall)
            "_tl_done"))]
      [relocs6 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs5
          (cobj.CompilerObjectRelocation.Relocation
            (cobj.CompilerObjectSectionKind.Text)
            "_tl_text"
            (cobj.CompilerObjectRelocationKind.Branch)
            "_tl_done"))]
      [relocs7 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs6
          (cobj.CompilerObjectRelocation.Relocation
            (cobj.CompilerObjectSectionKind.Text)
            "_tl_text"
            (cobj.CompilerObjectRelocationKind.Branch)
            "_tl_true"))]
      [relocs8 : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-push
          relocs7
          (cobj.CompilerObjectRelocation.Relocation
            (cobj.CompilerObjectSectionKind.Text)
            "_tl_text"
            (cobj.CompilerObjectRelocationKind.Branch)
            "_tl_false"))]
      (cobj.compiler-object-relocation-builder-finish relocs8))))

(cfg
  test
  (define (compiler-object-coff-text-smoke-image) : cobj.CompilerObjectImage
    (let
      [empty-data : cobj.CompilerObjectDataRecordList
        (cobj.compiler-object-data-record-builder-finish
          (cobj.compiler-object-data-record-builder-with-capacity 1))]
      [empty-instrs : cobj.CompilerObjectX64InstrList
        (cobj.compiler-object-instr-builder-finish
          (cobj.compiler-object-instr-builder-with-capacity 1))]
      [data0 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-with-capacity 4)]
      [data1 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          data0
          (cobj.CompilerObjectDataRecord.Label "_tl_answer"))]
      [data2 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          data1
          (cobj.CompilerObjectDataRecord.I64 42))]
      [data3 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          data2
          (cobj.CompilerObjectDataRecord.Label "_tl_slot"))]
      [data4 : cobj.CompilerObjectDataRecordBuilder
        (cobj.compiler-object-data-record-builder-push
          data3
          (cobj.CompilerObjectDataRecord.I64 0))]
      [sections0 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-with-capacity 4)]
      [sections1 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections0
          (cobj.CompilerObjectSection.Section
            (cobj.CompilerObjectSectionKind.Text)
            (owned_view.compiler-owned-shared-view empty-data)
            (compiler-object-coff-text-smoke-instrs)))]
      [sections2 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections1
          (cobj.CompilerObjectSection.Section
            (cobj.CompilerObjectSectionKind.Data)
            (cobj.compiler-object-data-record-builder-finish data4)
            (owned_view.compiler-owned-shared-view empty-instrs)))]
      [sections3 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections2
          (cobj.CompilerObjectSection.Section
            (cobj.CompilerObjectSectionKind.Rodata)
            (owned_view.compiler-owned-shared-view empty-data)
            (owned_view.compiler-owned-shared-view empty-instrs)))]
      [sections4 : cobj.CompilerObjectSectionBuilder
        (cobj.compiler-object-section-builder-push
          sections3
          (cobj.CompilerObjectSection.Section
            (cobj.CompilerObjectSectionKind.Bss)
            empty-data
            empty-instrs))]
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
    [obj : String]
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
    [image : cobj.CompilerObjectImage]
    [obj : String]
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
        [(ResultCompilerObjectCoff.Ok obj)
          (let
            [text-header : i64
              (compiler-object-coff-section-header-offset
                (cobj.CompilerObjectSectionKind.Text))]
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
              (= text-ptr (compiler-object-coff-header-size))
              (= reloc-count 8)
              (compiler-object-coff-text-smoke-bytes-ok?
                (owned_view.compiler-owned-shared-view obj)
                text-ptr)
              (compiler-object-coff-text-smoke-relocs-ok? image obj reloc-ptr)))]
        [(ResultCompilerObjectCoff.Err _) false]))))

(cfg
  test
  (define (compiler-object-coff-boundary-relocations
    [data-count : i64]
    [rodata-count : i64]) : cobj.CompilerObjectRelocationList
    (let
      [builder : cobj.CompilerObjectRelocationBuilder
        (cobj.compiler-object-relocation-builder-with-capacity
          (+ data-count rodata-count))]
      [index : i64 0]
      (begin
        (while (< index data-count)
          (begin
            (set!
              builder
              (cobj.compiler-object-relocation-builder-push
                builder
                (cobj.CompilerObjectRelocation.Relocation
                  (cobj.CompilerObjectSectionKind.Data)
                  "_tl_ptr"
                  (cobj.CompilerObjectRelocationKind.Abs64)
                  (if (= index (- data-count 1))
                    "foreign_exact"
                    "_tl_answer"))))
            (set! index (+ index 1))))
        (set! index 0)
        (while (< index rodata-count)
          (begin
            (set!
              builder
              (cobj.compiler-object-relocation-builder-push
                builder
                (cobj.CompilerObjectRelocation.Relocation
                  (cobj.CompilerObjectSectionKind.Rodata)
                  "long_rodata_label_name"
                  (cobj.CompilerObjectRelocationKind.Abs64)
                  (if (= index (- rodata-count 1))
                    "foreign_exact"
                    "_tl_answer"))))
            (set! index (+ index 1))))
        (cobj.compiler-object-relocation-builder-finish builder)))))

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
    [obj : String]
    [kind : cobj.CompilerObjectSectionKind]) : bool
    (not
      (=
        (bit-and
          (layout.compiler-object-layout-u32-at
            obj
            (+ (compiler-object-coff-section-header-offset kind) 36))
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
        [(ResultCompilerObjectCoff.Ok obj)
          (let
            [text-header : i64
              (compiler-object-coff-section-header-offset
                (cobj.CompilerObjectSectionKind.Text))]
            [header : i64
              (compiler-object-coff-section-header-offset
                (cobj.CompilerObjectSectionKind.Data))]
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
                  (owned_view.compiler-owned-shared-view obj)
                  (cobj.CompilerObjectSectionKind.Text)))
              (=
                (layout.compiler-object-layout-u16-at obj (+ header 32))
                semantic-count)
              (not
                (compiler-object-coff-header-has-relocation-overflow?
                  (owned_view.compiler-owned-shared-view obj)
                  (cobj.CompilerObjectSectionKind.Data)))
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
        [(ResultCompilerObjectCoff.Err _) false]))))

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
        [(ResultCompilerObjectCoff.Ok obj)
          (let
            [data-header : i64
              (compiler-object-coff-section-header-offset
                (cobj.CompilerObjectSectionKind.Data))]
            [rodata-header : i64
              (compiler-object-coff-section-header-offset
                (cobj.CompilerObjectSectionKind.Rodata))]
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
                (owned_view.compiler-owned-shared-view obj)
                (cobj.CompilerObjectSectionKind.Data))
              (compiler-object-coff-header-has-relocation-overflow?
                (owned_view.compiler-owned-shared-view obj)
                (cobj.CompilerObjectSectionKind.Rodata))
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
        [(ResultCompilerObjectCoff.Err _) false]))))

(cfg
  test
  (define (compiler-object-coff-relocation-layout-rejection-ok?) : bool
    (let
      [initial : CompilerObjectCoffLayoutAccumulator
        (CompilerObjectCoffLayoutAccumulator 400 "")]
      [negative : CompilerObjectCoffLayoutAccumulator
        (compiler-object-coff-check-relocation-count-layout
          (owned_view.compiler-owned-shared-view initial)
          (cobj.CompilerObjectSectionKind.Pdata)
          -1
          1000)]
      [sentinel-overflow : CompilerObjectCoffLayoutAccumulator
        (compiler-object-coff-check-relocation-count-layout
          (owned_view.compiler-owned-shared-view initial)
          (cobj.CompilerObjectSectionKind.Xdata)
          0xffffffff
          compiler-object-coff-max-output-size)]
      [table-overflow : CompilerObjectCoffLayoutAccumulator
        (compiler-object-coff-check-relocation-count-layout
          initial
          (cobj.CompilerObjectSectionKind.Rsrc)
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
        "coff relocation layout rejects malformed or oversized counts"))))