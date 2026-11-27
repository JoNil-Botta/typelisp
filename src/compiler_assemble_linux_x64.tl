;; In-process assembler for the compiler's final Linux x86-64 dialect.
(import compiler_linux_asm_debug as dbg)
(import compiler_linux_asm_reader as reader)
(import compiler_linux_asm_layout as asm)
(import compiler_linux_asm_symbols as sym)
(import compiler_linux_asm_resolve as resolve)
(import compiler_object_elf as elf)
(import compiler_object_layout as layout)
(import stdlib.byte_buf_core as buf)
(import stdlib.byte_le)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.iterator)

(define (local? [s : (& sym.Symbol)] [v : (& resolve.Value)]) : bool
  (and
    (<= s.binding 0)
    (!= v.section resolve.undefined)
    (!= v.section resolve.common)))

(define (temporary? [name : (& str)]) : bool
  (and
    (>= (string.string-length name) 2)
    (= (string.string-ref name 0) '.')
    (= (string.string-ref name 1) 'L')))

(defstruct Tables
  (symbols buf.ByteBufBuilder)
  (strings buf.ByteBufBuilder)
  (indices (__tl_dyn-array i64))
  (first-global i64))

(defenum ResultTables
  (Ok Tables)
  (Err String))

(define (symbol-tables
  [image : (& img asm.Image)]
  [values : (&mut vals resolve.Values)]
  [signatures : (& (__tl_dyn-array i64))]
  [first-section : i64]) : ResultTables
  (let
    [n image.table.entries.len]
    [syms (buf.byte-buf-builder-new)]
    [strs (buf.byte-buf-builder-new)]
    [indices (__tl_make-array i64 n)]
    [first-global : i64 0]
    (elf.push-symbol! (&mut syms) 0 0 0 0 0 0)
    (buf.byte-buf-builder-push (&mut strs) (cast 0 : u8))
    (for [i (iterator.range 0 image.items.len)]
      (elf.push-symbol! (&mut syms) 0 3 0 (+ i first-section) 0 0))
    (for [pass (iterator.range 0 2)]
      (when (= pass 1) (set! first-global (/ syms.len 24)))
      (for [i (iterator.range 0 n)]
        (let
          [s : (& img sym.Symbol) (& (array-ref image.table.entries.slots i))]
          [section (array-ref values.items i).section]
          [value (array-ref values.items i).offset]
          [group-label
            (and (>= (array-ref signatures i) 0) (= section resolve.undefined))]
          [local (or group-label (local? s (& (array-ref values.items i))))]
          (when
            (and
              (= local (= pass 0))
              (not (and s.is-alias (= section resolve.undefined)))
              (or
                (>= (array-ref signatures i) 0)
                (not local)
                s.retain-name
                (not (temporary? (& s.name)))))
            (let
              [dot (resolve.at-position image (& s.size-origin))]
              [size (try (resolve.evaluate! image values (& s.size) (& dot)))]
              [binding : i64
                (if local
                  0
                  (if (= s.binding 2)
                    2
                    1))]
              [kind : i64
                (if (and
                  (>= section 0)
                  (!=
                    0
                    (bit-and (array-ref image.items.slots section).flags 1024)))
                  6
                  s.kind)]
              [shndx : i64
                (cond
                  [group-label (array-ref signatures i)]
                  [(>= section 0) (+ section first-section)]
                  [(= section resolve.absolute) 0xfff1]
                  [(= section resolve.common) 0xfff2]
                  [else 0])]
              (unless
                (= size.section resolve.absolute)
                (return (Err "symbol size is not absolute")))
              (set! (array-ref indices i) (/ syms.len 24))
              (elf.push-symbol!
                (&mut syms)
                strs.len
                (bit-or (shl binding 4) kind)
                s.visibility
                shndx
                value
                size.offset)
              (elf.compiler-object-elf-push-shstrtab-name!
                (&mut strs)
                (& s.name)))))))
    (Ok (Tables syms strs indices first-global))))

(define (link-order [image : (& img asm.Image)] [name : (& str)]) : i64
  (let
    [id (asm.section-index image name)]
    (when (>= id 0) (return (+ id 1)))
    (let
      [symbol (sym.lookup (& image.table) name)]
      (if (>= symbol 0)
        (+ 1 (array-ref image.table.entries.slots symbol).position.section)
        0))))

(define (write-relocations!
  [out : (&mut buf.ByteBufBuilder)]
  [s : (& sec asm.Section)]
  [image : (& img asm.Image)]
  [values : (& vals resolve.Values)]
  [tables : (& Tables)]) : unit
  (for [j (iterator.range 0 s.relocations.len)]
    (let
      [r : (& sec asm.Rela) (& (array-ref s.relocations.slots j))]
      [symbol-id : i64
        (match r.target
          [(Named symbol) symbol]
          [(SectionAddress section)
            (elf.push-rela! out r.offset (+ section 1) r.ty r.addend)
            (continue)]
          [(AbsoluteZero)
            (elf.push-rela! out r.offset 0 r.ty r.addend)
            (continue)])]
      [v : (& vals resolve.Value) (& (array-ref values.items symbol-id))]
      [symbol : (& img sym.Symbol)
        (& (array-ref image.table.entries.slots symbol-id))]
      [target (array-ref tables.indices symbol-id)]
      [addend r.addend]
      (when
        (and
          (>= v.section 0)
          (local? symbol v)
          (not symbol.retain-name)
          (or (= target 0) (= symbol.kind 0))
          (!= r.ty 4))
        (set! target (+ 1 v.section))
        (+= addend v.offset))
      (elf.push-rela! out r.offset target r.ty addend))))

(define (assemble-image [image : (&mut img asm.Image)] [debug : (& dbg.Debug)]) : elf.ResultCompilerObjectElf
  (for [i (iterator.range 0 image.items.len)]
    (try (asm.relax! (&mut (array-ref image.items.slots i)) i (& image.table))))
  (let
    [values (try (resolve.resolve-all image))]
    (try (dbg.generate! debug image (&mut values)))
    (let
      [count image.items.len]
      [n image.table.entries.len]
      [raw (__tl_make-array buf.ByteBufBuilder count)]
      [groups (__tl_make-array i64 n)]
      [rela (__tl_make-array i64 count)]
      [first-section : i64 1]
      [next : i64 0]
      (for [i (iterator.range 0 n)]
        (set! (array-ref groups i) -1))
      ;; ELF requires each SHT_GROUP header to precede every member.
      (for [i (iterator.range 0 count)]
        (let
          [g (array-ref image.items.slots i).group]
          (when
            (and (>= g 0) (< (array-ref groups g) 0))
            (set! (array-ref groups g) first-section)
            (+= first-section 1))))
      (set! next (+ first-section count))
      (for [i (iterator.range 0 count)]
        (set!
          (array-ref raw i)
          (asm.materialize!
            (&mut (array-ref image.items.slots i))
            i
            (& image.table)))
        (try
          (resolve.apply-fields! image i (&mut values) (&mut (array-ref raw i))))
        (let
          [s : (& img asm.Section) (& (array-ref image.items.slots i))]
          (when
            (> s.relocations.len 0)
            (set! (array-ref rela i) next)
            (+= next 1))))
      (let
        [tables
          (try (symbol-tables image (&mut values) (& groups) first-section))]
        [symtab next]
        [total (+ symtab 3)]
        [rows (__tl_make-array elf.ElfSectionHeader total)]
        [contents (__tl_make-array buf.ByteBufBuilder total)]
        [names (buf.byte-buf-builder-new)]
        [offset : i64 elf.compiler-object-elf-header-size]
        (when (>= total 0xff00) (return (Err "too many ELF sections")))
        (buf.byte-buf-builder-push (&mut names) (cast 0 : u8))
        (for [i (iterator.range 0 count)]
          (let
            [s : (& img asm.Section) (& (array-ref image.items.slots i))]
            [idx (+ i first-section)]
            [rel (array-ref rela i)]
            [link : i64 0]
            (when
              (!= 0 (bit-and s.flags 128))
              (set! link (link-order image (& s.link-name)))
              (when (> link 0) (+= link (- first-section 1)))
              (when
                (= link 0)
                (return
                  (Err
                    (str_cat.str-cat
                      "unknown link-order target: "
                      (string.copy (& s.link-name)))))))
            (set!
              (array-ref rows idx)
              (try
                (elf.project-input-section
                  (& (asm.section-spec s i))
                  names.len
                  0
                  s.size
                  link
                  s.entry-size)))
            (elf.compiler-object-elf-push-shstrtab-name!
              (&mut names)
              (& s.name))
            (set!
              (array-ref contents idx)
              (replace! (array-ref raw i) (buf.byte-buf-builder-new)))
            (when
              (> rel 0)
              (let
                [bytes (buf.byte-buf-builder-new)]
                (write-relocations! (&mut bytes) s image (& values) (& tables))
                (set!
                  (array-ref rows rel)
                  (elf.ElfSectionHeader
                    names.len
                    4
                    (bit-or 64 (bit-and s.flags 512))
                    0
                    bytes.len
                    symtab
                    idx
                    8
                    24))
                (elf.compiler-object-elf-push-shstrtab-name!
                  (&mut names)
                  (& (str_cat.str-cat ".rela" (string.copy (& s.name)))))
                (set! (array-ref contents rel) bytes)))
            (when
              (>= s.group 0)
              (let
                [g (array-ref groups s.group)]
                (when
                  (= (array-ref rows g).ty 0)
                  (set!
                    (array-ref rows g)
                    (elf.ElfSectionHeader
                      names.len
                      17
                      0
                      0
                      0
                      symtab
                      (array-ref tables.indices s.group)
                      4
                      4))
                  (elf.compiler-object-elf-push-shstrtab-name!
                    (&mut names)
                    ".group")
                  (set! (array-ref contents g) (buf.byte-buf-builder-new))
                  (byte_le.push-u32! (&mut (array-ref contents g)) 1))
                (byte_le.push-u32! (&mut (array-ref contents g)) idx)
                (when
                  (> rel 0)
                  (byte_le.push-u32! (&mut (array-ref contents g)) rel))
                (set! (array-ref rows g).size (array-ref contents g).len)))))
        (set!
          (array-ref rows symtab)
          (elf.ElfSectionHeader
            names.len
            2
            0
            0
            tables.symbols.len
            (+ symtab 1)
            tables.first-global
            8
            24))
        (elf.compiler-object-elf-push-shstrtab-name! (&mut names) ".symtab")
        (set!
          (array-ref contents symtab)
          (replace! tables.symbols (buf.byte-buf-builder-new)))
        (set!
          (array-ref rows (+ symtab 1))
          (elf.ElfSectionHeader names.len 3 0 0 tables.strings.len 0 0 1 0))
        (elf.compiler-object-elf-push-shstrtab-name! (&mut names) ".strtab")
        (set!
          (array-ref contents (+ symtab 1))
          (replace! tables.strings (buf.byte-buf-builder-new)))
        (set!
          (array-ref rows (+ symtab 2))
          (elf.ElfSectionHeader names.len 3 0 0 0 0 0 1 0))
        (elf.compiler-object-elf-push-shstrtab-name! (&mut names) ".shstrtab")
        (set! (array-ref rows (+ symtab 2)).size names.len)
        (for [i (iterator.range 1 total)]
          (let
            [aligned
              (layout.compiler-object-layout-align-offset
                offset
                (array-ref rows i).align)]
            (set! (array-ref rows i).offset aligned)
            (unless
              (= (array-ref rows i).ty 8)
              (when
                (>
                  (array-ref rows i).size
                  (- layout.compiler-object-max-file-size aligned))
                (return (Err "ELF object exceeds size limit")))
              (set! offset (+ aligned (array-ref rows i).size)))))
        (let
          [headers (layout.compiler-object-layout-align-offset offset 8)]
          [plan
            (elf.ElfProjection
              rows
              (buf.byte-buf-builder-finish-string (& names))
              headers
              symtab)]
          (elf.serialize (& plan) (Assembled (& contents))))))))

(define (assemble-text [final-text : (& str)]) : elf.ResultCompilerObjectElf
  (let
    [parser (reader.new-reader)]
    (match (reader.read-source! (&mut parser) final-text 0)
      [(Ok _) unit]
      [(Err reason)
        (let
          [offset parser.source-offset]
          [text (string.copy (reader.next-line final-text (&mut offset)))]
          (return (Err (str_cat.str-cat reason " on assembly line: " text))))])
    (unless (= parser.stack.len 0) (return (Err "unclosed .pushsection")))
    (try
      (asm.select-section! (&mut parser.image) ".note.GNU-stack" 0 0 0 -1 ""))
    (assemble-image (&mut parser.image) (& parser.debug))))

(define (assemble-linux-x64 [final-text : (& str)]) : elf.ResultCompilerObjectElf
  (with-scratch (assemble-text final-text)))