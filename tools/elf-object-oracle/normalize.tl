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
    [file : json.Json (json.clone-json (& (array-ref files.slots 0)))]
    [sections : json.JsonSeq (seq (get (json.clone-json (& file)) "Sections"))]
    [table : i64
      (num
        (get (get (json.clone-json (& file)) "ElfHeader") "SectionHeaderOffset"))]
    [out : text.TextBuf (text.empty)]
    [symtab : i64 -1]
    [symoffset : i64 0]
    (for [i (iterator.range 0 sections.len)]
      (let
        [s : json.Json
          (get (json.clone-json (& (array-ref sections.slots i))) "Section")]
        [kind : i64 (num (get (get (json.clone-json (& s)) "Type") "Value"))]
        (when
          (= kind 2)
          (set! symtab i)
          (set! symoffset (num (get (json.clone-json (& s)) "Offset"))))
        (text.append!
          out
          (format.format
            "S\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\n"
            i
            (+ table (* i 64))
            kind
            (word (get (get (json.clone-json (& s)) "Flags") "Value"))
            (word (get (json.clone-json (& s)) "Address"))
            (word (get (json.clone-json (& s)) "Offset"))
            (word (get (json.clone-json (& s)) "Size"))
            (num (get (json.clone-json (& s)) "Link"))
            (num (get (json.clone-json (& s)) "Info"))
            (word (get (json.clone-json (& s)) "AddressAlignment"))
            (word (get (json.clone-json (& s)) "EntrySize"))
            (num (get (get (json.clone-json (& s)) "Name") "Value"))
            (hex (str (get (get (json.clone-json (& s)) "Name") "Name")))))))
    (let
      [symbols : json.JsonSeq (seq (get (json.clone-json (& file)) "Symbols"))]
      (unless
        (>= symtab 0)
        (io.panic "LLVM oracle: fixture must have one symbol table\n"))
      (for [i (iterator.range 0 symbols.len)]
        (let
          [s : json.Json
            (get (json.clone-json (& (array-ref symbols.slots i))) "Symbol")]
          (text.append!
            out
            (format.format
              "Y\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\n"
              symtab
              i
              (+ symoffset (* i 24))
              (num (get (get (json.clone-json (& s)) "Name") "Value"))
              ;; LLVM displays STT_SECTION's section name for st_name=0.
              ;; The ELF spelling at string-table index zero is still empty.
              (if (= (num (get (get (json.clone-json (& s)) "Name") "Value")) 0)
                "-"
                (hex (str (get (get (json.clone-json (& s)) "Name") "Name"))))
              (num (get (get (json.clone-json (& s)) "Binding") "Value"))
              (num (get (get (json.clone-json (& s)) "Type") "Value"))
              (num (get (get (json.clone-json (& s)) "Other") "Value"))
              (num (get (get (json.clone-json (& s)) "Section") "Value"))
              (word (get (json.clone-json (& s)) "Value"))
              (word (get (json.clone-json (& s)) "Size"))
              (+ symoffset (* i 24) 6))))))
    (let
      [tables : json.JsonSeq
        (seq (get (json.clone-json (& file)) "Relocations"))]
      (for [i (iterator.range 0 tables.len)]
        (let
          [r : json.Json (json.clone-json (& (array-ref tables.slots i)))]
          [index : i64 (num (get (json.clone-json (& r)) "SectionIndex"))]
          [s : json.Json
            (get
              (json.clone-json (& (array-ref sections.slots index)))
              "Section")]
          [entries : json.JsonSeq (seq (get (json.clone-json (& r)) "Relocs"))]
          (for [j (iterator.range 0 entries.len)]
            (let
              [r : json.Json
                (get
                  (json.clone-json (& (array-ref entries.slots j)))
                  "Relocation")]
              [symbol : i64
                (num (get (get (json.clone-json (& r)) "Symbol") "Value"))]
              [number : i64
                (num (get (get (json.clone-json (& r)) "Type") "Value"))]
              (text.append!
                out
                (format.format
                  "R\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\n"
                  index
                  j
                  (+ (num (get (json.clone-json (& s)) "Offset")) (* j 24))
                  (num (get (json.clone-json (& s)) "Info"))
                  (num (get (json.clone-json (& s)) "Link"))
                  symbol
                  (+ symoffset (* symbol 24))
                  (word (get (json.clone-json (& r)) "Offset"))
                  number
                  (width number)
                  (cast (word (get (json.clone-json (& r)) "Addend")) : i64))))))))
    ;; LLVM represents groups as an object with one repeated Group member.
    (match (get (json.clone-json (& file)) "Groups")
      [(JsonObject boxed)
        (let
          [groups : json.JsonMemberSeq (deref boxed)]
          (for [i (iterator.range 0 groups.len)]
            (let
              [g : json.Json
                (json.clone-json (& (array-ref groups.slots i).value))]
              [index : i64 (num (get (json.clone-json (& g)) "Index"))]
              [signature : i64 (num (get (json.clone-json (& g)) "Info"))]
              [members : json.JsonSeq
                (seq (get (json.clone-json (& g)) "GroupSections"))]
              (text.append!
                out
                (format.format
                  "G\t{}\t{}\t{}\t{}\t{}\t{}\n"
                  index
                  (num (get (get (json.clone-json (& g)) "Type") "Value"))
                  (num (get (json.clone-json (& g)) "Link"))
                  signature
                  (+ symoffset (* signature 24))
                  members.len))
              (for [j (iterator.range 0 members.len)]
                (let
                  [member : i64
                    (num
                      (get
                        (json.clone-json (& (array-ref members.slots j)))
                        "Index"))]
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
      [notes : json.JsonSeq
        (seq (get (json.clone-json (& file)) "NoteSections"))]
      (for [i (iterator.range 0 notes.len)]
        (let
          [n : json.Json
            (get (json.clone-json (& (array-ref notes.slots i))) "NoteSection")]
          [start : i64 (num (get (json.clone-json (& n)) "Offset"))]
          [at : i64 start]
          [index : i64 -1]
          [alignment : i64 4]
          [entries : json.JsonSeq (seq (get (json.clone-json (& n)) "Notes"))]
          (for [j (iterator.range 0 sections.len)]
            (let
              [s : json.Json
                (get
                  (json.clone-json (& (array-ref sections.slots j)))
                  "Section")]
              (when
                (and
                  (= (num (get (json.clone-json (& s)) "Offset")) start)
                  (= (num (get (get (json.clone-json (& s)) "Type") "Value")) 7))
                (set! index j)
                (when
                  (= (num (get (json.clone-json (& s)) "AddressAlignment")) 8)
                  (set! alignment 8)))))
          (unless (>= index 0) (io.panic "LLVM oracle: missing note section\n"))
          (for [j (iterator.range 0 entries.len)]
            (let
              [n : json.Json (json.clone-json (& (array-ref entries.slots j)))]
              [owner : String (str (get (json.clone-json (& n)) "Owner"))]
              [owner-size : i64 (+ (string.string-length (& owner)) 1)]
              [owner-end : i64 (+ at 12 owner-size)]
              [desc : i64
                (+
                  owner-end
                  (% (- alignment (% (- owner-end start) alignment)) alignment))]
              [size : i64 (num (get (json.clone-json (& n)) "Data size"))]
              [end : i64 (+ desc size)]
              (text.append!
                out
                (format.format
                  "N\t{}\t{}\t{}\t{}\t{}\t{}\t{}00\t{}\t{}\t{}\n"
                  index
                  j
                  at
                  (note-type (str (get (json.clone-json (& n)) "Type")))
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