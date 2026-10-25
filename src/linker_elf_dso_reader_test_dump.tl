;; Test-only projection onto GNU readelf's dynamic/symbol/version records.
(import linker_elf_dso_reader as dso)
(import linker_elf_object_reader as elf)
(import linker_elf_dynamic as dynamic)
(import linker_elf_version_codec as versions)
(import stdlib.byte_buf)
(import stdlib.text_buf as text)
(import stdlib.format)
(import stdlib.string)

(define (name [data : (& b (__tl_dyn-array u8))] [span : (& s elf.ElfSpan)]) : String
  (let
    [out : (__tl_dyn-array u8) (__tl_make-array u8 span.size)]
    [i : i64 0]
    (while (< i span.size)
      (set! (array-ref out i) (array-ref data (+ span.offset i)))
      (set! i (+ i 1)))
    (byte_buf.to-string (byte_buf.ByteBuf out span.size))))

(define (indexed-name [object : (& o (dso.DsoObject input))] [index : i64]) : String
  (let
    [request : dso.DsoReadRequest
      (dso.DsoReadRequest (clone object.identity) (dso.default-limits))]
    [check : dso.DsoCheck (dso.new-check (& request))]
    [span : elf.ElfSpan
      (dso.name-span!
        object.bytes
        (& object.strings)
        (cast index : u64)
        (&mut check)
        0)]
    (name object.bytes (& span))))

(define (symbol-name [object : (& o (dso.DsoObject input))] [index : i64]) : String
  (let
    [symbol : (& o elf.ElfSymbol) (& (array-ref object.symbols index))]
    [plain : String (name object.bytes (& symbol.name))]
    [request : dso.DsoReadRequest
      (dso.DsoReadRequest (clone object.identity) (dso.default-limits))]
    [check : dso.DsoCheck (dso.new-check (& request))]
    [span : elf.ElfSpan (dso.version-name! object index (&mut check))]
    (when (= span.size 0) (return plain))
    (let
      [version : String (name object.bytes (& span))]
      (when
        (and (= symbol.raw-section 65521) (string.eq plain version))
        (return plain))
      (let
        [hidden : bool
          (match object.versions
            [(Unversioned) false]
            [(Versioned table)
              (not
                (=
                  (bit-and
                    (cast (array-ref table.symbols index) : i64)
                    versions.index-hidden)
                  0))])]
        (format.format
          "{}{}{}"
          plain
          (if (or hidden (= symbol.raw-section 0))
            "@"
            "@@")
          version)))))

(define (dump [object : (& o (dso.DsoObject input))] [version-records : bool]) : String
  (let
    [out : text.TextBuf (text.empty)]
    [i : i64 0]
    (while (< i (array-length object.entries))
      (let
        [entry : (& o dso.DsoDynamic) (& (array-ref object.entries i))]
        (text.append!
          out
          (format.format
            "D\t{:x}\t{}\n"
            entry.tag
            (if (dynamic.string-tag? entry.tag)
              (format.format "[{}]" (name object.bytes (& entry.name)))
              (format.format "{:x}" entry.value)))))
      (set! i (+ i 1)))
    (set! i 0)
    (while (< i (array-length object.symbols))
      (let
        [symbol : (& o elf.ElfSymbol) (& (array-ref object.symbols i))]
        (text.append!
          out
          (format.format
            "Y\t{}\t{:x}\t{}\t{}\t{}\t{}\t{}\t[{}]\n"
            i
            symbol.value
            symbol.size
            (match symbol.symbol-type
              [(NoType) "NOTYPE"]
              [(ObjectSymbol) "OBJECT"]
              [(FunctionSymbol) "FUNC"]
              [(TlsSymbol) "TLS"]
              [(GnuIfunc) "IFUNC"]
              [(SectionSymbol) "SECTION"]
              [(FileSymbol) "FILE"]
              [(CommonSymbol) "COMMON"]
              [(UnknownSymbolType _) "UNKNOWN"])
            (match symbol.binding
              [(Local) "LOCAL"]
              [(Global) "GLOBAL"]
              [(Weak) "WEAK"]
              [(GnuUnique) "UNIQUE"]
              [(UnknownBinding _) "UNKNOWN"])
            (match symbol.visibility
              [(DefaultVisibility) "DEFAULT"]
              [(Internal) "INTERNAL"]
              [(Hidden) "HIDDEN"]
              [(Protected) "PROTECTED"])
            (match symbol.raw-section
              [0 "UND"]
              [65521 "ABS"]
              [65522 "COM"]
              [other (format.format "{}" other)])
            (symbol-name object i))))
      (set! i (+ i 1)))
    (when
      version-records
      (match object.versions
        [(Unversioned) unit]
        [(Versioned table)
          (set! i 0)
          (while (< i (array-length table.symbols))
            (text.append!
              out
              (format.format
                "VS\t{}\t{}\n"
                i
                (cast (array-ref table.symbols i) : i64)))
            (set! i (+ i 1)))
          (set! i 0)
          (while (< i table.definitions.records.len)
            (let
              [record : (& table versions.VersionRecord)
                (& (array-ref table.definitions.records.slots i))]
              [j : i64 0]
              (text.append!
                out
                (format.format
                  "VD\t{:x}\t{}\t{}\t{}\t{}\n"
                  record.offset
                  record.flags
                  record.index
                  record.aux.len
                  (indexed-name object (array-ref record.aux.slots 0).name)))
              (while (< j record.aux.len)
                (when
                  (> j 0)
                  (text.append!
                    out
                    (format.format
                      "VP\t{:x}\t{}\t{}\n"
                      (array-ref record.aux.slots j).offset
                      j
                      (indexed-name object (array-ref record.aux.slots j).name))))
                (set! j (+ j 1))))
            (set! i (+ i 1)))
          (set! i 0)
          (while (< i table.needs.records.len)
            (let
              [record : (& table versions.VersionRecord)
                (& (array-ref table.needs.records.slots i))]
              [j : i64 0]
              (text.append!
                out
                (format.format
                  "VN\t{:x}\t{}\t{}\n"
                  record.offset
                  record.aux.len
                  (indexed-name object record.file)))
              (while (< j record.aux.len)
                (let
                  [aux : (& table versions.VersionAux)
                    (& (array-ref record.aux.slots j))]
                  (text.append!
                    out
                    (format.format
                      "VA\t{:x}\t{}\t{}\t{}\n"
                      aux.offset
                      aux.flags
                      aux.index
                      (indexed-name object aux.name))))
                (set! j (+ j 1))))
            (set! i (+ i 1)))]))
    (text.render out)))