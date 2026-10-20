;; Normalize LLVM's JSON, never the object's bytes. Exact JSON integer parsing
;; preserves negative RELA addends which LLVM prints as unsigned 64-bit values.
(import stdlib.json)
(import stdlib.format)
(import stdlib.string)
(import stdlib.io)
(import stdlib.text_buf as text)
(import stdlib.iterator)

(define (get [value : json.Json] [key : String]) : json.Json
  (match (json.object-get-owned value key)
    [(JsonFound result) result]
    [_ (io.panic "LLVM oracle: missing field\n")]))

(define (seq [value : json.Json]) : json.JsonSeq
  (match value
    [(JsonArray items) (deref items)]
    [_ (io.panic "LLVM oracle: expected array\n")]))

(define (str [value : json.Json]) : String
  (match value
    [(JsonString value) value]
    [_ (io.panic "LLVM oracle: expected string\n")]))

(define (word [value : json.Json]) : u64
  (match value
    [(JsonNumber spelling)
      (match (json.number->u64 (& spelling))
        [(OkJsonNumberU64 number) number]
        [_
          (match (json.number->i64 (& spelling))
            [(OkJsonNumberI64 number) (cast number : u64)]
            [_ (io.panic "LLVM oracle: expected 64-bit integer\n")])])]
    [_ (io.panic "LLVM oracle: expected number\n")]))

(define (num [value : json.Json]) : i64
  (cast (word value) : i64))

(define (hex [value : String]) : String
  (let
    [out : text.TextBuf (text.empty)]
    (when (= (string.string-length (& value)) 0) (return "-"))
    (for [i (iterator.range 0 (string.string-length (& value)))]
      (text.append!
        out
        (format.format "{:02x}" (cast (string.string-ref (& value) i) : i64))))
    (text.render out)))

(define (width [number : i64]) : i64
  (cond
    [(or (= number 0) (= number 5) (= number 35)) 0]
    [(or (= number 12) (= number 13)) 2]
    [(or (= number 14) (= number 15)) 1]
    [(= number 36) 16]
    [(or
        (= number 1)
        (and (>= number 6) (<= number 8))
        (and (>= number 16) (<= number 18))
        (= number 24)
        (= number 25)
        (and (>= number 27) (<= number 31))
        (= number 33)
        (= number 37)
        (= number 38))
      8]
    [(or (and (>= number 0) (<= number 38)) (and (>= number 41) (<= number 51)))
      4]
    [else -1]))

(define (note-type [name : String]) : i64
  (when
    (string.eq (& name) "NT_GNU_PROPERTY_TYPE_0 (property note)")
    (return 5))
  (let
    [value : i64 0]
    [active : bool false]
    (for [i (iterator.range 0 (string.string-length (& name)))]
      (let
        [c : i64 (cast (string.string-ref (& name) i) : i64)]
        (cond
          [(= c 120) (set! active true)]
          [(and active (>= c 48) (<= c 57))
            (set! value (+ (* value 16) (- c 48)))]
          [(and active (>= c 97) (<= c 102))
            (set! value (+ (* value 16) (- c 87)))]
          [(and active (not (= c 41)))
            (io.panic "LLVM oracle: unrecognized note type\n")]
          [else unit])))
    (unless active (io.panic "LLVM oracle: unrecognized note type\n"))
    value))

(define (normalize [source : String]) : String
  (let
    [files : json.JsonSeq
      (seq
        (match (json.parse (& source))
          [(OkJson value) value]
          [_ (io.panic "LLVM oracle: invalid JSON\n")]))]
    [file : json.Json (clone (array-ref files.slots 0))]
    [sections : json.JsonSeq (seq (get (clone file) "Sections"))]
    [table : i64
      (num (get (get (clone file) "ElfHeader") "SectionHeaderOffset"))]
    [out : text.TextBuf (text.empty)]
    [symtab : i64 -1]
    [symoffset : i64 0]
    (for [i (iterator.range 0 sections.len)]
      (let
        [s : json.Json (get (clone (array-ref sections.slots i)) "Section")]
        [kind : i64 (num (get (get (clone s) "Type") "Value"))]
        (when
          (= kind 2)
          (set! symtab i)
          (set! symoffset (num (get (clone s) "Offset"))))
        (text.append!
          out
          (format.format
            "S\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\n"
            i
            (+ table (* i 64))
            kind
            (word (get (get (clone s) "Flags") "Value"))
            (word (get (clone s) "Address"))
            (word (get (clone s) "Offset"))
            (word (get (clone s) "Size"))
            (num (get (clone s) "Link"))
            (num (get (clone s) "Info"))
            (word (get (clone s) "AddressAlignment"))
            (word (get (clone s) "EntrySize"))
            (num (get (get (clone s) "Name") "Value"))
            (hex (str (get (get (clone s) "Name") "Name")))))))
    (let
      [symbols : json.JsonSeq (seq (get (clone file) "Symbols"))]
      (unless
        (>= symtab 0)
        (io.panic "LLVM oracle: fixture must have one symbol table\n"))
      (for [i (iterator.range 0 symbols.len)]
        (let
          [s : json.Json (get (clone (array-ref symbols.slots i)) "Symbol")]
          (text.append!
            out
            (format.format
              "Y\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\n"
              symtab
              i
              (+ symoffset (* i 24))
              (num (get (get (clone s) "Name") "Value"))
              ;; LLVM displays STT_SECTION's section name for st_name=0.
              ;; The ELF spelling at string-table index zero is still empty.
              (if (= (num (get (get (clone s) "Name") "Value")) 0)
                "-"
                (hex (str (get (get (clone s) "Name") "Name"))))
              (num (get (get (clone s) "Binding") "Value"))
              (num (get (get (clone s) "Type") "Value"))
              (num (get (get (clone s) "Other") "Value"))
              (num (get (get (clone s) "Section") "Value"))
              (word (get (clone s) "Value"))
              (word (get (clone s) "Size"))
              (+ symoffset (* i 24) 6))))))
    (let
      [tables : json.JsonSeq (seq (get (clone file) "Relocations"))]
      (for [i (iterator.range 0 tables.len)]
        (let
          [r : json.Json (clone (array-ref tables.slots i))]
          [index : i64 (num (get (clone r) "SectionIndex"))]
          [s : json.Json
            (get (clone (array-ref sections.slots index)) "Section")]
          [entries : json.JsonSeq (seq (get (clone r) "Relocs"))]
          (for [j (iterator.range 0 entries.len)]
            (let
              [r : json.Json
                (get (clone (array-ref entries.slots j)) "Relocation")]
              [symbol : i64 (num (get (get (clone r) "Symbol") "Value"))]
              [number : i64 (num (get (get (clone r) "Type") "Value"))]
              (text.append!
                out
                (format.format
                  "R\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\n"
                  index
                  j
                  (+ (num (get (clone s) "Offset")) (* j 24))
                  (num (get (clone s) "Info"))
                  (num (get (clone s) "Link"))
                  symbol
                  (+ symoffset (* symbol 24))
                  (word (get (clone r) "Offset"))
                  number
                  (width number)
                  (cast (word (get (clone r) "Addend")) : i64))))))))
    ;; LLVM represents groups as an object with one repeated Group member.
    (match (get (clone file) "Groups")
      [(JsonObject boxed)
        (let
          [groups : json.JsonMemberSeq (deref boxed)]
          (for [i (iterator.range 0 groups.len)]
            (let
              [g : json.Json (clone (array-ref groups.slots i).value)]
              [index : i64 (num (get (clone g) "Index"))]
              [signature : i64 (num (get (clone g) "Info"))]
              [members : json.JsonSeq (seq (get (clone g) "GroupSections"))]
              (text.append!
                out
                (format.format
                  "G\t{}\t{}\t{}\t{}\t{}\t{}\n"
                  index
                  (num (get (get (clone g) "Type") "Value"))
                  (num (get (clone g) "Link"))
                  signature
                  (+ symoffset (* signature 24))
                  members.len))
              (for [j (iterator.range 0 members.len)]
                (let
                  [member : i64
                    (num (get (clone (array-ref members.slots j)) "Index"))]
                  (text.append!
                    out
                    (format.format
                      "M\t{}\t{}\t{}\t{}\n"
                      index
                      j
                      member
                      (+ table (* member 64)))))))))]
      [_ (io.panic "LLVM oracle: expected groups object\n")])
    (let
      [notes : json.JsonSeq (seq (get (clone file) "NoteSections"))]
      (for [i (iterator.range 0 notes.len)]
        (let
          [n : json.Json (get (clone (array-ref notes.slots i)) "NoteSection")]
          [start : i64 (num (get (clone n) "Offset"))]
          [at : i64 start]
          [index : i64 -1]
          [alignment : i64 4]
          [entries : json.JsonSeq (seq (get (clone n) "Notes"))]
          (for [j (iterator.range 0 sections.len)]
            (let
              [s : json.Json
                (get (clone (array-ref sections.slots j)) "Section")]
              (when
                (and
                  (= (num (get (clone s) "Offset")) start)
                  (= (num (get (get (clone s) "Type") "Value")) 7))
                (set! index j)
                (when
                  (= (num (get (clone s) "AddressAlignment")) 8)
                  (set! alignment 8)))))
          (unless (>= index 0) (io.panic "LLVM oracle: missing note section\n"))
          (for [j (iterator.range 0 entries.len)]
            (let
              [n : json.Json (clone (array-ref entries.slots j))]
              [owner : String (str (get (clone n) "Owner"))]
              [owner-size : i64 (+ (string.string-length (& owner)) 1)]
              [owner-end : i64 (+ at 12 owner-size)]
              [desc : i64
                (+
                  owner-end
                  (% (- alignment (% (- owner-end start) alignment)) alignment))]
              [size : i64 (num (get (clone n) "Data size"))]
              [end : i64 (+ desc size)]
              (text.append!
                out
                (format.format
                  "N\t{}\t{}\t{}\t{}\t{}\t{}\t{}00\t{}\t{}\t{}\n"
                  index
                  j
                  at
                  (note-type (str (get (clone n) "Type")))
                  (+ at 12)
                  owner-size
                  (hex owner)
                  desc
                  size
                  alignment))
              (set!
                at
                (+ end (% (- alignment (% (- end start) alignment)) alignment))))))))
    (text.render out)))