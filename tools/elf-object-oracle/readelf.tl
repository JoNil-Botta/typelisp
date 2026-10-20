;; Projection onto fields GNU readelf displays; every record remains keyed by
;; physical table and entry identity. LLVM supplies raw indexes/flags as well.
(import linker_elf_object_reader as elf)
(import stdlib.byte_buf)
(import stdlib.text_buf as text)
(import stdlib.format)
(import stdlib.iterator)

(define (name [bytes : (& b (__tl_dyn-array u8))] [span : (& s elf.ElfSpan)]) : String
  (let
    [data : (__tl_dyn-array u8) (__tl_make-array u8 span.size)]
    (for [i (iterator.range 0 span.size)]
      (set! (array-ref data i) (array-ref bytes (+ span.offset i))))
    (byte_buf.to-string (byte_buf.ByteBuf data span.size))))

(define (flags [value : u64]) : String
  (let
    [out : text.TextBuf (text.empty)]
    [bits : (Array i64 13)
      (array 2 2048 268435456 2147483648 512 64 128 16 256 2097152 32 1024 1)]
    [letters : (Array String 13)
      (array "A" "C" "D" "E" "G" "I" "L" "M" "O" "R" "S" "T" "W")]
    (for [i (iterator.range 0 13)]
      (when
        (elf.flag? value (array-ref bits i))
        (text.append! out (clone (array-ref letters i)))))
    (when (elf.flag? value 4) (text.append! out "X"))
    (text.render out)))

(define (dump [object : (& o (elf.ElfObject input))]) : String
  (let
    [out : text.TextBuf (text.empty)]
    (for [i (iterator.range 0 (array-length object.sections))]
      (let
        [s : (& o elf.ElfSection) (& (array-ref object.sections i))]
        (text.append!
          out
          (format.format
            "S\t{}\t{:x}\t{:x}\t{:x}\t{:x}\t{}\t{}\t{}\t{}\t{}\n"
            i
            s.address
            s.file-offset
            s.size
            s.entry-size
            s.link
            s.info
            s.alignment
            (flags s.flags)
            (name object.bytes (& s.name))))))
    (for [i (iterator.range 0 (array-length object.symbols))]
      (let
        [s : (& o elf.ElfSymbol) (& (array-ref object.symbols i))]
        (text.append!
          out
          (format.format
            "Y\t{}\t{:x}\t{}\t{}\t{}\t{}\t{}\t{}\n"
            s.id.index
            s.value
            s.size
            (match s.symbol-type
              [(NoType) "NOTYPE"]
              [(ObjectSymbol) "OBJECT"]
              [(FunctionSymbol) "FUNC"]
              [(SectionSymbol) "SECTION"]
              [(FileSymbol) "FILE"]
              [(CommonSymbol) "COMMON"]
              [(TlsSymbol) "TLS"]
              [(GnuIfunc) "IFUNC"]
              [_ "UNKNOWN"])
            (match s.binding
              [(Local) "LOCAL"]
              [(Global) "GLOBAL"]
              [(Weak) "WEAK"]
              [(GnuUnique) "UNIQUE"]
              [_ "UNKNOWN"])
            (match s.visibility
              [(DefaultVisibility) "DEFAULT"]
              [(Internal) "INTERNAL"]
              [(Hidden) "HIDDEN"]
              [(Protected) "PROTECTED"])
            (match s.section
              [(Undefined) "UND"]
              [(Absolute) "ABS"]
              [(CommonSection) "COM"]
              [(DefinedSection id) (format.format "{}" id.index)]
              [_ "RESERVED"])
            (if (match s.symbol-type
              [(SectionSymbol) true]
              [_ false])
              ""
              (name object.bytes (& s.name)))))))
    (for [i (iterator.range 0 (array-length object.relocations))]
      (let
        [r : (& o elf.ElfRelocation) (& (array-ref object.relocations i))]
        (text.append!
          out
          (format.format
            "R\t{}\t{}\t{:x}\t{:x}\t{}\t{:x}\n"
            r.id.section.index
            r.id.index
            r.offset
            (+ (shl (cast r.symbol.index : u64) 32) (cast r.number : u64))
            (if (< r.addend 0)
              "-"
              "+")
            (if (< r.addend 0)
              (- (cast 0 : u64) (cast r.addend : u64))
              (cast r.addend : u64))))))
    (for [i (iterator.range 0 (array-length object.groups))]
      (let
        [g : (& o elf.ElfGroup) (& (array-ref object.groups i))]
        [table : (& o elf.ElfSection)
          (& (array-ref object.sections g.signature.section.index))]
        [signature : (& o elf.ElfSymbol)
          (&
            (array-ref object.symbols (+ table.symbol-start g.signature.index)))]
        (text.append!
          out
          (format.format
            "G\t{}\t{}\t{}\n"
            g.section.index
            g.flags
            (name object.bytes (& signature.name))))
        (for [j (iterator.range 0 g.member-count)]
          (text.append!
            out
            (format.format
              "M\t{}\t{}\t{}\n"
              g.section.index
              j
              (array-ref object.members (+ g.member-start j)).index)))))
    (for [i (iterator.range 0 (array-length object.notes))]
      (let
        [n : (& o elf.ElfNote) (& (array-ref object.notes i))]
        (text.append!
          out
          (format.format
            "N\t{}\t{}\t{}\t{:x}\t{}\n"
            n.id.section.index
            n.id.index
            n.note-type
            n.descriptor.size
            (name
              object.bytes
              (& (elf.ElfSpan n.owner.offset (- n.owner.size 1))))))))
    (text.render out)))