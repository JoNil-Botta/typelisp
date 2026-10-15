(import parse)
(import pins)
(import stdlib.byte_buf)
(import stdlib.crypto_sha256 as sha)
(import stdlib.io)
(import stdlib.string)
(import stdlib.str_cat)

(defstruct Data
  (idna (__tl_dyn-array u8))
  (facts (__tl_dyn-array u32))
  (seen (__tl_dyn-array u8))
  (offsets (__tl_dyn-array u32))
  (lengths (__tl_dyn-array u8))
  (pool (__tl_dyn-array u32))
  (pool-count i64)
  (idna-rows i64))

(define (new) : Data
  (Data
    (__tl_make-array u8 1114112)
    (__tl_make-array u32 1114112)
    (__tl_make-array u8 1114112)
    (__tl_make-array u32 1114112)
    (__tl_make-array u8 1114112)
    (__tl_make-array u32 8192)
    0
    0))

;; Verify every source before any parser runs. Diagnostics identify the logical
;; source, never the caller's checkout path. No network mode exists.
(define (sources [directory : String]) : (__tl_dyn-array String)
  (let
    [root : String (string.replace directory "\\" "/")]
    [texts : (__tl_dyn-array String) (__tl_make-array String 8)]
    [index : i64 0]
    (while (< index 8)
      (let
        [name : String (pins.name index)]
        [path : String (str_cat.str-cat root "/" name)]
        [contents : byte_buf.ByteBuf
          (match (io.try-read-file path)
            [(io.OkIoBytes value) value]
            [(io.ErrIoBytes _)
              (parse.fail name 0 "missing or unreadable pinned input")])]
        (when
          (!= (byte_buf.len (& contents)) (pins.size index))
          (parse.fail name 0 "pinned byte size mismatch"))
        (match (sha.digest (byte_buf.as-bytes (& contents)))
          [(sha.Sha256FinalizeOk digest)
            (when
              (not (string.eq (sha.to-hex (& digest)) (pins.sha256 index)))
              (parse.fail name 0 "pinned SHA-256 mismatch"))]
          [(sha.Sha256FinalizeErr _) (parse.fail name 0 "SHA-256 failure")])
        (set! (array-ref texts index) (byte_buf.to-string contents)))
      (set! index (+ index 1)))
    texts))

(define (version [text : (& text str)] [file : (& file str)]) : unit
  (let
    [header : String
      (str_cat.str-cat
        "# "
        (string.replace (string.copy file) ".txt" "-12.0.0.txt"))]
    (when
      (or
        (< (string.string-length text) (string.string-length header))
        (not
          (string.eq
            (string.substring text 0 (string.string-length header))
            header)))
      (parse.fail file 1 "expected Unicode 12.0.0 header"))))

;; Each independently supplied property may cover a code point only once.
(define (paint
  [data : (&mut data Data)]
  [range : parse.Range]
  [mask : u8]
  [bits : u32]
  [file : (& file str)]
  [line : i64]) : unit
  (when
    (or (< range.first 0) (> range.last 1114111) (> range.first range.last))
    (parse.fail file line "property range outside code-point domain"))
  (let
    [cp : i64 range.first]
    (while (<= cp range.last)
      (when
        (!= (bit-and (array-ref data.seen cp) mask) 0)
        (parse.fail file line "duplicate or overlapping property range"))
      (set! (array-ref data.seen cp) (bit-or (array-ref data.seen cp) mask))
      (set! (array-ref data.facts cp) (bit-or (array-ref data.facts cp) bits))
      (set! cp (+ cp 1)))))

(define (idna [data : (&mut data Data)] [text : (& text str)]) : unit
  (let
    [file : String (pins.name 1)]
    [cursor : parse.Cursor (parse.Cursor 0 1)]
    [next : i64 0]
    [totals : (Array i64 5) (make-array i64 5)]
    [header : String (parse.record text (&mut cursor) true file)]
    (when
      (not (string.eq header "Codepoint,Property,Status,Description"))
      (parse.fail file 1 "wrong CSV header"))
    (while (< cursor.offset (string.string-length text))
      (let
        [line : i64 cursor.line]
        [record : String (parse.record text (&mut cursor) true file)]
        [row : parse.Fields (parse.fields record ',' true file line)]
        [range : parse.Range
          (parse.range (parse.field (& row) 0) '-' file line)]
        [property : i64
          (parse.vocabulary
            (parse.field (& row) 1)
            "DISALLOWED|PVALID|CONTEXTJ|CONTEXTO|UNASSIGNED"
            file
            line)]
        (parse.expect-fields (& row) 4 file line)
        (when
          (!= range.first next)
          (parse.fail
            file
            line
            "unsorted, overlapping or non-covering IDNA range"))
        (when
          (!= (string.string-length (parse.field (& row) 2)) 0)
          (parse.fail file line "unexpected registry status"))
        (let
          [cp : i64 range.first]
          (while (<= cp range.last)
            (set! (array-ref data.idna cp) (cast property : u8))
            (set! cp (+ cp 1))))
        (set!
          (array-ref totals property)
          (+ (array-ref totals property) (+ 1 (- range.last range.first))))
        (set! next (+ range.last 1))
        (set! data.idna-rows (+ data.idna-rows 1))))
    (when
      (or
        (!= next 1114112)
        (!= data.idna-rows 2869)
        (!= (array-ref totals 0) 154542)
        (!= (array-ref totals 1) 123006)
        (!= (array-ref totals 2) 2)
        (!= (array-ref totals 3) 25)
        (!= (array-ref totals 4) 836537))
      (parse.fail
        file
        cursor.line
        "audited IDNA row or code-point totals changed"))))

(define (bidi-names) : String
  "L|R|AL|EN|ES|ET|AN|CS|NSM|BN|B|S|WS|ON|LRE|LRO|RLE|RLO|PDF|LRI|RLI|FSI|PDI")

(define (unicode-data [data : (&mut data Data)] [text : (& text str)]) : unit
  (let
    [file : String (pins.name 2)]
    [cursor : parse.Cursor (parse.Cursor 0 1)]
    [previous : i64 -1]
    [pending : i64 -1]
    [pending-name : String ""]
    [pending-bits : u32 0]
    (while (< cursor.offset (string.string-length text))
      (let
        [line : i64 cursor.line]
        [record : String (parse.record text (&mut cursor) false file)]
        [row : parse.Fields (parse.fields record ';' false file line)]
        [cp : i64 (parse.number (parse.field (& row) 0) 16 1114111 file line)]
        [name : String (parse.field (& row) 1)]
        [category : String (parse.field (& row) 2)]
        [ccc : i64 (parse.number (parse.field (& row) 3) 10 255 file line)]
        [bidi : i64
          (parse.vocabulary (parse.field (& row) 4) (bidi-names) file line)]
        [bits : u32
          (bit-or
            (cast ccc : u32)
            (if (or
              (string.eq category "Mn")
              (string.eq category "Mc")
              (string.eq category "Me"))
              256
              0)
            (shl (cast bidi : u32) (cast 24 : u64)))]
        [mapping : String (parse.field (& row) 5)]
        (parse.expect-fields (& row) 15 file line)
        (when
          (<= cp previous)
          (parse.fail file line "duplicate or unsorted UnicodeData code point"))
        (parse.vocabulary
          category
          "Lu|Ll|Lt|Lm|Lo|Mn|Mc|Me|Nd|Nl|No|Pc|Pd|Ps|Pe|Pi|Pf|Po|Sm|Sc|Sk|So|Zs|Zl|Zp|Cc|Cf|Cs|Co|Cn"
          file
          line)
        (cond
          [(>= pending 0)
            (when
              (or
                (not (string.eq name pending-name))
                (!= bits pending-bits)
                (!= (string.string-length mapping) 0))
              (parse.fail file line "mismatched UnicodeData First/Last pair"))
            (paint data (parse.Range pending cp) 1 bits file line)
            (set! pending -1)]
          [(string.contains name ", First>")
            (set! pending cp)
            (set! pending-name (string.replace name ", First>" ", Last>"))
            (set! pending-bits bits)]
          [else
            (when
              (string.contains name ", Last>")
              (parse.fail file line "unpaired UnicodeData Last"))
            (paint data (parse.Range cp cp) 1 bits file line)
            (when
              (and
                (> (string.string-length mapping) 0)
                (!= (string.string-ref mapping 0) '<'))
              (let
                [parts : parse.Fields
                  (parse.fields mapping ' ' false file line)]
                [index : i64 0]
                (when
                  (or
                    (< parts.count 1)
                    (> parts.count 2)
                    (> (+ data.pool-count parts.count) 8192))
                  (parse.fail file line "canonical decomposition pool overflow"))
                (set! (array-ref data.offsets cp) (cast data.pool-count : u32))
                (set! (array-ref data.lengths cp) (cast parts.count : u8))
                (while (< index parts.count)
                  (let
                    [value : i64
                      (parse.number
                        (parse.field (& parts) index)
                        16
                        1114111
                        file
                        line)]
                    (when
                      (and (>= value 55296) (<= value 57343))
                      (parse.fail file line "surrogate decomposition"))
                    (set!
                      (array-ref data.pool data.pool-count)
                      (cast value : u32))
                    (set! data.pool-count (+ data.pool-count 1)))
                  (set! index (+ index 1)))))])
        (set! previous cp)))
    (when
      (>= pending 0)
      (parse.fail file cursor.line "unclosed UnicodeData First range"))))

(define (script-names) : String
  "Common|Latin|Greek|Cyrillic|Armenian|Hebrew|Arabic|Syriac|Thaana|Devanagari|Bengali|Gurmukhi|Gujarati|Oriya|Tamil|Telugu|Kannada|Malayalam|Sinhala|Thai|Lao|Tibetan|Myanmar|Georgian|Hangul|Ethiopic|Cherokee|Canadian_Aboriginal|Ogham|Runic|Khmer|Mongolian|Hiragana|Katakana|Bopomofo|Han|Yi|Old_Italic|Gothic|Deseret|Inherited|Tagalog|Hanunoo|Buhid|Tagbanwa|Limbu|Tai_Le|Linear_B|Ugaritic|Shavian|Osmanya|Cypriot|Braille|Buginese|Coptic|New_Tai_Lue|Glagolitic|Tifinagh|Syloti_Nagri|Old_Persian|Kharoshthi|Balinese|Cuneiform|Phoenician|Phags_Pa|Nko|Sundanese|Lepcha|Ol_Chiki|Vai|Saurashtra|Kayah_Li|Rejang|Lycian|Carian|Lydian|Cham|Tai_Tham|Tai_Viet|Avestan|Egyptian_Hieroglyphs|Samaritan|Lisu|Bamum|Javanese|Meetei_Mayek|Imperial_Aramaic|Old_South_Arabian|Inscriptional_Parthian|Inscriptional_Pahlavi|Old_Turkic|Kaithi|Batak|Brahmi|Mandaic|Chakma|Meroitic_Cursive|Meroitic_Hieroglyphs|Miao|Sharada|Sora_Sompeng|Takri|Caucasian_Albanian|Bassa_Vah|Duployan|Elbasan|Grantha|Pahawh_Hmong|Khojki|Linear_A|Mahajani|Manichaean|Mende_Kikakui|Modi|Mro|Old_North_Arabian|Nabataean|Palmyrene|Pau_Cin_Hau|Old_Permic|Psalter_Pahlavi|Siddham|Khudawadi|Tirhuta|Warang_Citi|Ahom|Anatolian_Hieroglyphs|Hatran|Multani|Old_Hungarian|SignWriting|Adlam|Bhaiksuki|Marchen|Newa|Osage|Tangut|Masaram_Gondi|Nushu|Soyombo|Zanabazar_Square|Dogra|Gunjala_Gondi|Makasar|Medefaidrin|Hanifi_Rohingya|Sogdian|Old_Sogdian|Elymaic|Nandinagari|Nyiakeng_Puachue_Hmong|Wancho")

(define (properties
  [data : (&mut data Data)]
  [text : (& text str)]
  [source : i64]) : unit
  (let
    [file : String (pins.name source)]
    [cursor : parse.Cursor (parse.Cursor 0 1)]
    [previous : (__tl_dyn-array i64) (__tl_make-array i64 256)]
    [index : i64 0]
    (version text file)
    (while (< index 256)
      (set! (array-ref previous index) -1)
      (set! index (+ index 1)))
    (while (< cursor.offset (string.string-length text))
      (let
        [line : i64 cursor.line]
        [record : String (parse.record text (&mut cursor) false file)]
        [row : parse.Fields (parse.fields record ';' false file line)]
        [first : String (parse.field (& row) 0)]
        (when
          (> (string.string-length first) 0)
          (parse.expect-fields (& row) 2 file line)
          (let
            [range : parse.Range (parse.range first '.' file line)]
            [value : String (parse.field (& row) 1)]
            [key : i64
              (parse.vocabulary
                value
                (cond
                  [(= source 5) (script-names)]
                  [(= source 6) "U|L|D|T|R|C"]
                  [else (bidi-names)])
                file
                line)]
            [bits : u32
              (cond
                [(= source 5)
                  (shl
                    (cast
                      (cond
                        [(string.eq value "Greek") 1]
                        [(string.eq value "Hebrew") 2]
                        [(string.eq value "Hiragana") 3]
                        [(string.eq value "Katakana") 4]
                        [(string.eq value "Han") 5]
                        [else 0])
                      : u32)
                    (cast 9 : u64))]
                [(= source 6) (shl (cast key : u32) (cast 12 : u64))]
                [else (shl (cast key : u32) (cast 15 : u64))])]
            (when
              (<= range.first (array-ref previous key))
              (parse.fail file line "unsorted property group"))
            (set! (array-ref previous key) range.last)
            (when
              (= source 7)
              (let
                [cp : i64 range.first]
                (while (<= cp range.last)
                  (when
                    (and
                      (!= (bit-and (array-ref data.seen cp) 1) 0)
                      (!=
                        (shr (array-ref data.facts cp) (cast 24 : u64))
                        (cast key : u32)))
                    (parse.fail
                      file
                      line
                      "bidi class disagrees with UnicodeData"))
                  (set! cp (+ cp 1)))))
            (paint
              data
              range
              (cond [(= source 5) 2] [(= source 6) 4] [else 8])
              bits
              file
              line)))))))

(define (normalization [data : (&mut data Data)] [text : (& text str)]) : unit
  (let
    [file : String (pins.name 3)]
    [cursor : parse.Cursor (parse.Cursor 0 1)]
    [previous : (Array i64 3) (array -1 -1 -1)]
    (version text file)
    (while (< cursor.offset (string.string-length text))
      (let
        [line : i64 cursor.line]
        [record : String (parse.record text (&mut cursor) false file)]
        [row : parse.Fields (parse.fields record ';' false file line)]
        [first : String (parse.field (& row) 0)]
        (when
          (> (string.string-length first) 0)
          (let
            [range : parse.Range (parse.range first '.' file line)]
            [property : String (parse.field (& row) 1)]
            (cond
              [(string.eq property "Full_Composition_Exclusion")
                (parse.expect-fields (& row) 2 file line)
                (when
                  (<= range.first (array-ref previous 0))
                  (parse.fail file line "unsorted composition exclusions"))
                (set! (array-ref previous 0) range.last)
                (paint data range 16 0 file line)]
              [(string.eq property "NFC_QC")
                (parse.expect-fields (& row) 3 file line)
                (let
                  [value : i64
                    (+
                      1
                      (parse.vocabulary (parse.field (& row) 2) "N|M" file line))]
                  (when
                    (<= range.first (array-ref previous value))
                    (parse.fail file line "unsorted NFC quick-check group"))
                  (set! (array-ref previous value) range.last)
                  (paint
                    data
                    range
                    32
                    (shl (cast value : u32) (cast 20 : u64))
                    file
                    line))]
              [else unit])))))))

;; Registry prose is provenance, not executable rules. These nine identities
;; are the exhaustively reviewed interface consumed by issue #7269.
(define (context [text : (& text str)]) : unit
  (let
    [file : String (pins.name 0)]
    [cursor : parse.Cursor (parse.Cursor 0 1)]
    [starts : (Array i64 9) (array 8204 8205 183 885 1523 1524 12539 1632 1776)]
    [ends : (Array i64 9) (array 8204 8205 183 885 1523 1524 12539 1641 1785)]
    [count : i64 0]
    [header : String (parse.record text (&mut cursor) true file)]
    (when
      (not (string.eq header "Code Point,Lookup,Rule Set,Overview,Description"))
      (parse.fail file 1 "wrong contextual CSV header"))
    (while (< cursor.offset (string.string-length text))
      (let
        [line : i64 cursor.line]
        [record : String (parse.record text (&mut cursor) true file)]
        [row : parse.Fields (parse.fields record ',' true file line)]
        [range : parse.Range
          (parse.range (parse.field (& row) 0) '-' file line)]
        (parse.expect-fields (& row) 5 file line)
        (when
          (or
            (>= count 9)
            (!= range.first (array-ref starts count))
            (!= range.last (array-ref ends count))
            (not
              (string.eq
                (parse.field (& row) 1)
                (if (< count 2)
                  "True"
                  "False"))))
          (parse.fail file line "unreviewed contextual rule or applicability"))
        (set! count (+ count 1))))
    (when
      (!= count 9)
      (parse.fail file cursor.line "expected nine contextual rules"))))