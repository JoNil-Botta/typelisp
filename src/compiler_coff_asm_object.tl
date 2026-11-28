(import compiler_object_coff as coff)
(import compiler_linux_asm_layout as asm)
(import compiler_linux_asm_resolve as resolve)
(import compiler_linux_asm_symbols as sym)
(import stdlib.byte_buf_core as buf)
(import stdlib.byte_le)
(import stdlib.iterator)
(import stdlib.string)

(define (temporary? [name : (& str)]) : bool
  (string.is-string-prefix-at name ".L" 0))

(define (string-offset! [strings : (&mut buf.ByteBufBuilder)] [name : (& str)]) : i64
  (when (<= (string.string-length name) 8) (return 0))
  (let
    [offset strings.len]
    (for [i (iterator.range 0 (string.string-length name))]
      (buf.byte-buf-builder-push strings (cast (string.string-ref name i) : u8)))
    (asm.emit-le! strings 0 1)
    offset))

(define (symbol!
  [out : (&mut buf.ByteBufBuilder)]
  [name : (& str)]
  [offset : i64]
  [value : i64]
  [section : i64]
  [storage : i64]
  [aux : i64]) : unit
  (if (= offset 0)
    (coff.compiler-object-coff-push-name8! out name)
    (begin
      (byte_le.push-u32! out 0)
      (byte_le.push-u32! out offset)))
  (byte_le.push-u32! out value)
  (byte_le.push-u16! out section)
  (byte_le.push-u16! out 0)
  (asm.emit-le! out storage 1)
  (asm.emit-le! out aux 1))

(define (flags [s : (& asm.Section)]) : i64
  (let
    [characteristics : i64
      (cond
        [(= s.ty 8) 0xc0000080]
        [(!= (bit-and s.flags 4) 0) 0x60000020]
        [(!= (bit-and s.flags 1) 0) 0xc0000040]
        [else 0x40000040])]
    (when (>= s.group 0) (set! characteristics (bit-or characteristics 0x1000)))
    (when
      (string.is-string-prefix-at (& s.name) ".debug" 0)
      (set! characteristics (bit-or characteristics 0x02000000)))
    (when
      (coff.compiler-object-coff-relocation-count-overflows? s.relocations.len)
      (set!
        characteristics
        (bit-or
          characteristics
          coff.compiler-object-coff-section-lnk-nreloc-ovfl)))
    (bit-or characteristics (coff.compiler-object-coff-align-flag s.alignment))))

(define (checksum-table) : (Array i64 256)
  (let
    [table (make-array i64 256)]
    (for [i (iterator.range 0 256)]
      (let
        [v i]
        (for [_bit (iterator.range 0 8)]
          (set!
            v
            (bit-xor
              (shr v 1)
              (if (= (bit-and v 1) 1)
                0xedb88320
                0))))
        (set! (array-ref table i) v)))
    table))

(define (checksum [table : (& (Array i64 256))] [raw : (& buf.ByteBufBuilder)]) : i64
  (let
    [v : i64 0]
    (for [j (iterator.range 0 raw.len)]
      (set!
        v
        (bit-xor
          (shr v 8)
          (array-ref
            (deref table)
            (bit-and (bit-xor v (cast (array-ref raw.slots j) : i64)) 255)))))
    v))

(defstruct SymbolIndex
  (sections (__tl_dyn-array i64))
  (names (__tl_dyn-array i64))
  (count i64))

(define (symbol-index [image : (& img asm.Image)] [values : (& resolve.Values)]) : SymbolIndex
  (let
    [n image.items.len]
    [m image.table.entries.len]
    [index (SymbolIndex (__tl_make-array i64 n) (__tl_make-array i64 m) 0)]
    (for [i (iterator.range 0 m)]
      (set! (array-ref index.names i) -1))
    (for [i (iterator.range 0 n)]
      (let
        [s : (& img asm.Section) (& (array-ref image.items.slots i))]
        (set! (array-ref index.sections i) index.count)
        (+= index.count 2)
        (when
          (and (>= s.group 0) (!= s.entry-size 5))
          (set! (array-ref index.names s.group) index.count)
          (+= index.count 1))))
    (for [i (iterator.range 0 m)]
      (let
        [s : (& img sym.Symbol) (& (array-ref image.table.entries.slots i))]
        (unless
          (or
            (>= (array-ref index.names i) 0)
            (and (<= s.binding 0) (temporary? (& s.name)))
            (and
              s.is-alias
              (= (array-ref values.items i).section resolve.undefined)))
          (set! (array-ref index.names i) index.count)
          (+= index.count 1))))
    index))

(define (relocations!
  [s : (& sec asm.Section)]
  [raw : (&mut buf.ByteBufBuilder)]
  [out : (&mut buf.ByteBufBuilder)]
  [index : (& SymbolIndex)]
  [values : (& vals resolve.Values)]) : asm.Status
  (coff.compiler-object-coff-render-relocation-overflow-sentinel!
    out
    s.relocations.len)
  (for [j (iterator.range 0 s.relocations.len)]
    (let
      [r : (& sec asm.Rela) (& (array-ref s.relocations.slots j))]
      [addend r.addend]
      [symbol : i64
        (match r.target
          [(Named id)
            (let
              [v : (& vals resolve.Value) (& (array-ref values.items id))]
              [idx (array-ref index.names id)]
              (if (>= idx 0)
                idx
                (begin
                  (when
                    (< v.section 0)
                    (return (Err "undefined local COFF relocation target")))
                  ;; IMAGE_REL_AMD64_SECTION names the containing section.
                  (unless (= r.ty 10) (+= addend v.offset))
                  (array-ref index.sections v.section))))]
          [(SectionAddress id) (array-ref index.sections id)]
          [(AbsoluteZero) (return (Err "COFF relocation needs a symbol"))])]
      (try
        (resolve.patch!
          raw
          r.offset
          (match r.ty
            [1 8]
            [10 2]
            [_ 4])
          addend
          (= r.ty 4)))
      (byte_le.push-u32! out r.offset)
      (byte_le.push-u32! out symbol)
      (byte_le.push-u16! out r.ty)))
  (Ok unit))

(define (serialize
  [image : (& img asm.Image)]
  [values : (& vals resolve.Values)]
  [raw : (__tl_dyn-array buf.ByteBufBuilder)]) : coff.ResultCompilerObjectCoff
  (let
    [n image.items.len]
    [m image.table.entries.len]
    [index (symbol-index image values)]
    [rows (__tl_make-array coff.CoffSectionHeader n)]
    [names (__tl_make-array String n)]
    [relocs (buf.byte-buf-builder-new)]
    [symbols (buf.byte-buf-builder-new)]
    [strings (buf.byte-buf-builder-new)]
    [crc (checksum-table)]
    [offset (+ 20 (* n 40))]
    (when (> n 32767) (return (Err "too many COFF sections")))
    (byte_le.push-u32! (&mut strings) 0)
    (for [i (iterator.range 0 n)]
      (let
        [s : (& img asm.Section) (& (array-ref image.items.slots i))]
        [name-off (string-offset! (&mut strings) (& s.name))]
        [parent (+ i 1)]
        [data (&mut (array-ref raw i))]
        (when
          (or (> s.alignment 8192) (> name-off 9999999))
          (return (Err "COFF section header exceeds format limits")))
        (when
          (>= s.group 0)
          (let
            [key (array-ref values.items s.group).section]
            (unless
              (and
                (>= key 0)
                (= (array-ref image.items.slots key).group s.group)
                (!= (array-ref image.items.slots key).entry-size 5)
                (or (= s.entry-size 5) (= key i)))
              (return (Err "invalid COMDAT key or association")))
            (set! parent (+ key 1))))
        (set! (array-ref names i) (string.copy (& s.name)))
        (set!
          (array-ref rows i)
          (coff.CoffSectionHeader
            name-off
            s.size
            (if (> data.len 0)
              offset
              0)
            relocs.len
            s.relocations.len
            (flags s)))
        (try (relocations! s data (&mut relocs) (& index) values))
        (+= offset data.len)
        (symbol! (&mut symbols) (& s.name) name-off 0 (+ i 1) 3 1)
        (byte_le.push-u32! (&mut symbols) s.size)
        (byte_le.push-u16!
          (&mut symbols)
          (if (> s.relocations.len 65535)
            65535
            s.relocations.len))
        (byte_le.push-u16! (&mut symbols) 0)
        (byte_le.push-u32! (&mut symbols) (checksum (& crc) data))
        (byte_le.push-u16! (&mut symbols) parent)
        (asm.emit-le! (&mut symbols) s.entry-size 1)
        (asm.emit-le! (&mut symbols) 0 3)
        (when
          (and (>= s.group 0) (!= s.entry-size 5))
          (let
            [key : (& img sym.Symbol)
              (& (array-ref image.table.entries.slots s.group))]
            (symbol!
              (&mut symbols)
              (& key.name)
              (string-offset! (&mut strings) (& key.name))
              (array-ref values.items s.group).offset
              (+ i 1)
              2
              0)))))
    (for [i (iterator.range 0 m)]
      (let
        [s : (& img sym.Symbol) (& (array-ref image.table.entries.slots i))]
        [v : (& vals resolve.Value) (& (array-ref values.items i))]
        [sec v.section]
        (when
          (and
            (= sec resolve.undefined)
            (temporary? (& s.name))
            (not s.is-alias))
          (return (Err "undefined local COFF symbol")))
        (when
          (= (array-ref index.names i) (/ symbols.len 18))
          (when (= s.binding 2) (return (Err "unsupported COFF weak symbol")))
          (symbol!
            (&mut symbols)
            (& s.name)
            (string-offset! (&mut strings) (& s.name))
            (if (= sec resolve.common)
              s.size.constant
              v.offset)
            (cond [(>= sec 0) (+ sec 1)] [(= sec resolve.absolute) -1] [else 0])
            (if (or
              (> s.binding 0)
              (= sec resolve.undefined)
              (= sec resolve.common))
              2
              3)
            0))))
    (let
      [sym-offset (+ offset relocs.len)]
      [size (+ sym-offset (+ symbols.len strings.len))]
      (when
        (> size coff.compiler-object-coff-max-output-size)
        (return (Err "COFF object exceeds size limit")))
      (try (resolve.patch! (&mut strings) 0 4 strings.len false))
      (for [i (iterator.range 0 n)]
        (let
          [row (&mut (array-ref rows i))]
          (if (> row.count 0)
            (+= row.relocs offset)
            (set! row.relocs 0))))
      (let
        [assembled (coff.CoffAssembly names raw relocs symbols strings)]
        (coff.serialize
          (& rows)
          size
          sym-offset
          index.count
          (Assembled (& assembled)))))))