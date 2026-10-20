;; Test-only canonical structure. Decimal scalars and hex byte strings avoid
;; host pointers, locale, ambiguous delimiters, and platform newline policy.
(import linker_elf_object_reader as elf)
(import stdlib.byte_le as le)
(import stdlib.format)
(import stdlib.text_buf as text)
(import stdlib.iterator)

(define (hex-span [data : (& b (__tl_dyn-array u8))] [span : (& s elf.ElfSpan)]) : String
  (let
    [out : text.TextBuf (text.empty)]
    (when (= span.size 0) (return "-"))
    (for [i (iterator.range 0 span.size)]
      (text.append!
        out
        (format.format "{:02x}" (le.byte-le-at data (+ span.offset i)))))
    (text.render out)))

(define (binding-number [binding : (& b elf.ElfSymbolBinding)]) : i64
  (match (deref binding)
    [(Local) 0]
    [(Global) 1]
    [(Weak) 2]
    [(GnuUnique) 10]
    [(UnknownBinding value) value]))

(define (type-number [kind : (& k elf.ElfSymbolType)]) : i64
  (match (deref kind)
    [(NoType) 0]
    [(ObjectSymbol) 1]
    [(FunctionSymbol) 2]
    [(SectionSymbol) 3]
    [(FileSymbol) 4]
    [(CommonSymbol) 5]
    [(TlsSymbol) 6]
    [(GnuIfunc) 10]
    [(UnknownSymbolType value) value]))

(define (dump [object : (& o (elf.ElfObject input))] [complete : bool]) : String
  (let
    [out : text.TextBuf (text.empty)]
    (when
      complete
      (text.append!
        out
        (format.format
          "H\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\n"
          object.identity.input
          object.identity.content
          object.header.osabi
          object.header.abi-version
          object.header.flags
          object.header.entry
          object.header.section-offset
          object.header.section-count
          object.header.name-table)))
    (for [i (iterator.range 0 (array-length object.sections))]
      (let
        [s : (& o elf.ElfSection) (& (array-ref object.sections i))]
        (text.append!
          out
          (format.format
            "S\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\n"
            s.id.index
            s.id.offset
            s.section-type
            s.flags
            s.address
            s.file-offset
            s.size
            s.link
            s.info
            s.alignment
            s.entry-size
            s.name-index
            (hex-span object.bytes (& s.name))))
        (when
          complete
          (text.append!
            out
            (format.format
              "X\t{}\t{}\t{}\n"
              i
              (match s.class
                [(KnownSection) 0]
                [(UnknownNonAllocSection) 1]
                [(UnknownAllocSection) 2])
              s.gnu-stack))
          (match s.body
            [(Compressed c)
              (text.append!
                out
                (format.format
                  "C\t{}\t{}\t{}\t{}\t{}\t{}\n"
                  i
                  (match c.kind
                    [(Zlib) (cast 1 : i64)]
                    [(Zstd) (cast 2 : i64)]
                    [(UnknownCompression value) value])
                  c.size
                  c.alignment
                  c.payload.offset
                  c.payload.size))]
            [(NoFileBytes) (text.append! out (format.format "B\t{}\n" i))]
            [_ unit])
          (match s.priority
            [(Priority value)
              (text.append! out (format.format "P\t{}\t{}\n" i value))]
            [_ unit]))))
    (for [i (iterator.range 0 (array-length object.symbols))]
      (let
        [s : (& o elf.ElfSymbol) (& (array-ref object.symbols i))]
        (text.append!
          out
          (format.format
            "Y\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\n"
            s.id.section.index
            s.id.index
            s.id.offset
            s.name-index
            (hex-span object.bytes (& s.name))
            (binding-number (& s.binding))
            (type-number (& s.symbol-type))
            s.other
            s.raw-section
            s.value
            s.size
            s.section-index-offset))))
    (for [i (iterator.range 0 (array-length object.relocations))]
      (let
        [r : (& o elf.ElfRelocation) (& (array-ref object.relocations i))]
        (text.append!
          out
          (format.format
            "R\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\n"
            r.id.section.index
            r.id.index
            r.id.offset
            r.target.index
            r.symbol.section.index
            r.symbol.index
            r.symbol.offset
            r.offset
            r.number
            r.width
            r.addend))))
    (for [i (iterator.range 0 (array-length object.groups))]
      (let
        [g : (& o elf.ElfGroup) (& (array-ref object.groups i))]
        (text.append!
          out
          (format.format
            "G\t{}\t{}\t{}\t{}\t{}\t{}\n"
            g.section.index
            g.flags
            g.signature.section.index
            g.signature.index
            g.signature.offset
            g.member-count))
        (for [j (iterator.range 0 g.member-count)]
          (let
            [m : (& o elf.ElfSectionId)
              (& (array-ref object.members (+ g.member-start j)))]
            (text.append!
              out
              (format.format
                "M\t{}\t{}\t{}\t{}\n"
                g.section.index
                j
                m.index
                m.offset))))))
    (for [i (iterator.range 0 (array-length object.notes))]
      (let
        [n : (& o elf.ElfNote) (& (array-ref object.notes i))]
        (text.append!
          out
          (format.format
            "N\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\n"
            n.id.section.index
            n.id.index
            n.id.offset
            n.note-type
            n.owner.offset
            n.owner.size
            (hex-span object.bytes (& n.owner))
            n.descriptor.offset
            n.descriptor.size
            n.alignment))))
    (text.render out)))