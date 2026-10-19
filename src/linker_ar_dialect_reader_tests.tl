(import linker_ar_dialect_reader as ar)
(import linker_archive_core as archive)
(import stdlib.byte_buf as buf)
(import stdlib.string)
(import stdlib.str_cat_runtime as cat)
(import stdlib.test)

(include-bin gnu "../tests/fixtures/ar-dialects/gnu.in")

(include-bin gnu64 "../tests/fixtures/ar-dialects/llvm-gnu64.in")

(include-bin bsd "../tests/fixtures/ar-dialects/llvm-bsd.in")

(include-bin bsd-sorted "../tests/fixtures/ar-dialects/bsd-sorted.in")

(include-bin no-index "../tests/fixtures/ar-dialects/no-index.in")

(define (identity) : archive.ArchiveIdentity
  (archive.ArchiveIdentity (cast 41 : u64) (cast 73 : u64)))

(define (limits) : archive.ArchiveLimits
  (archive.ArchiveLimits 1048576 128 65536 16 128 1 1048576))

(define (fixture [bytes : (& b (__tl_dyn-array u8))]) : String
  (let
    [out : buf.ByteBuf (buf.new)]
    [i : i64 0]
    (while (< i (array-length bytes))
      (set! out (buf.push out (array-ref bytes i)))
      (set! i (+ i 1)))
    (buf.to-string out)))

(define (text [data : (& d str)] [offset : i64] [size : i64]) : (& d str)
  (string.substring-view data offset size))

(define (assert-fixture
  [bytes : (& b (__tl_dyn-array u8))]
  [dialect : ar.ArDialect]
  [first : i64]
  [a : i64]
  [b : i64]
  [c : i64]
  [indexed : bool]
  [sorted : bool]) : unit
  (let
    [data : String (fixture bytes)]
    (match (ar.read (& data) (identity) dialect (limits))
      [(ReadFailed _) (test.assert-true false "tool-produced archive rejected")]
      [(ReadArchive parsed)
        (test.assert-i64-eq
          (array-length parsed.members)
          (+ first 4)
          "physical order")
        (let
          [names : (Array String 4)
            (array "dup.o" "unusually-long-member-name.o" "dup.o" "odd")]
          [i : i64 0]
          (while (< i 4)
            (let
              [member : ar.ArMember (array-ref parsed.members (+ first i))]
              (test.assert-true
                (string.eq
                  (text (& data) member.name-offset member.name-size)
                  (& (array-ref names i)))
                "ar t name")
              (test.assert-true
                (match member.kind
                  [(Ordinary) true]
                  [_ false])
                "ordinary member")
              (test.assert-i64-eq
                member.content-size
                (if (= i 3)
                  1
                  (if (= i 1)
                    408
                    440))
                "object content excludes BSD name")
              (set! i (+ i 1)))))
        (test.assert-i64-eq
          (array-ref parsed.directory.members first).id.header-offset
          a
          "first header")
        (test.assert-i64-eq
          (array-ref parsed.directory.members (+ first 1)).id.header-offset
          b
          "second header")
        (test.assert-i64-eq
          (array-ref parsed.directory.members (+ first 2)).id.header-offset
          c
          "duplicate header")
        (test.assert-i64-eq
          (array-length parsed.hints)
          (if indexed
            5
            0)
          "nm armap count")
        (when
          indexed
          (let
            [names : (Array String 5)
              (if sorted
                (array "alpha" "beta" "gamma" "shared" "shared")
                (array "alpha" "shared" "beta" "gamma" "shared"))]
            [offsets : (Array i64 5)
              (if sorted
                (array a b c a c)
                (array a a b c c))]
            [i : i64 0]
            (while (< i 5)
              (let
                [hint : ar.ArSymbolHint (array-ref parsed.hints i)]
                (test.assert-true
                  (string.eq
                    (text (& data) hint.name-offset hint.name-size)
                    (& (array-ref names i)))
                  "nm armap symbol order")
                (test.assert-i64-eq
                  hint.target.header-offset
                  (array-ref offsets i)
                  "nm armap target identity")
                (test.assert-true
                  (= hint.target.archive.content (cast 73 : u64))
                  "content identity")
                (set! i (+ i 1))))))
        (let
          [id : archive.ArchiveMemberId
            (array-ref parsed.directory.members first).id]
          (match (archive.open! (& parsed.directory) (&mut parsed.session) id)
            [(Opened opened _)
              (test.assert-i64-eq opened.ordinal first "load-once identity")]
            [_ (test.assert-true false "ordinary member open")])
          (match (archive.open! (& parsed.directory) (&mut parsed.session) id)
            [(AlreadyOpened _) unit]
            [_ (test.assert-true false "duplicate open")]))])))

(test
  ar-dialects-tool-oracles
  (assert-fixture (& gnu) (GnuSystemV) 2 214 714 1182 true false)
  (assert-fixture (& gnu64) (GnuSystemV) 2 238 738 1206 true false)
  (assert-fixture (& bsd) (BsdLittleEndian) 1 160 672 1168 true false)
  (assert-fixture (& bsd-sorted) (BsdLittleEndian) 1 168 680 1176 true true)
  (assert-fixture (& no-index) (GnuSystemV) 1 98 598 1066 false false))

(define (pad [data : String] [width : i64]) : String
  (let
    [out : buf.ByteBuf (buf.from-string data)]
    (while (< (buf.len (& out)) width)
      (set! out (buf.push out (cast 32 : u8))))
    (buf.to-string out)))

(define (member [name : String] [payload : String]) : String
  (let
    [size : i64 (string.string-length (& payload))]
    (cat.str-cat
      (pad name 16)
      "0           0     0     644     "
      (pad (string.int->string size) 10)
      "`\n"
      payload
      (if (= (% size 2) 0)
        ""
        "\n"))))

(define (word [value : u64] [width : i64] [little : bool]) : String
  (let
    [out : buf.ByteBuf (buf.new)]
    [i : i64 0]
    (while (< i width)
      (set!
        out
        (buf.push
          out
          (cast
            (bit-and
              (shr
                value
                (*
                  8
                  (if little
                    i
                    (- (- width 1) i))))
              (cast 255 : u64))
            : u8)))
      (set! i (+ i 1)))
    (buf.to-string out)))

(define (patch [data : (& d str)] [offset : i64] [replacement : String]) : String
  (let
    [size : i64 (string.string-length (& replacement))]
    (cat.str-cat
      (string.substring data 0 offset)
      replacement
      (string.substring
        data
        (+ offset size)
        (- (string.string-length data) (+ offset size))))))

(define (code [kind : ar.ArErrorKind]) : i64
  (match kind
    [(Container core)
      (match core
        [(InvalidLimits) 101]
        [(InputLimit) 102]
        [(MemberLimit) 103]
        [(RetainedLimit) 104]
        [(SpecialLimit) 105]
        [(IndexLimit) 106]
        [(WorkLimit) 107]
        [(InvalidIndexTarget) 108]
        [(SpecialTarget) 109]
        [(BadPadding) 110]
        [(BadNumeric) 111]
        [(NumericOverflow) 112]
        [_ 199])]
    [(WrongDialect) 1]
    [(BadName) 2]
    [(NameReference) 3]
    [(NameLength) 4]
    [(UnterminatedName) 5]
    [(SpecialOrder) 6]
    [(IndexSize) 7]
    [(NumberOverflow) 8]
    [(StringOffset) 9]
    [(UnterminatedSymbol) 10]
    [(TrailingData) 11]
    [(UnsortedIndex) 12]))

(define (reject
  [data : (& d str)]
  [dialect : ar.ArDialect]
  [caps : archive.ArchiveLimits]
  [expected : i64]) : unit
  (match (ar.read data (identity) dialect caps)
    [(ReadFailed error)
      (when
        (>= expected 0)
        (test.assert-i64-eq (code error.kind) expected "diagnostic kind"))
      (test.assert-true (= error.archive.input (cast 41 : u64)) "error input")
      (test.assert-true
        (= error.archive.content (cast 73 : u64))
        "error revision")]
    [_ (test.assert-true false "invalid archive accepted")]))

(define (accept
  [data : (& d str)]
  [dialect : ar.ArDialect]
  [caps : archive.ArchiveLimits]) : unit
  (match (ar.read data (identity) dialect caps)
    [(ReadArchive _) unit]
    [_ (test.assert-true false "valid archive rejected")]))

;; An independently written small ranlib fixture. Both hints intentionally
;; name the same symbol/member; sorted does not imply unique.
(define (small-index
  [width : i64]
  [bsd? : bool]
  [little : bool]
  [sorted : bool]) : String
  (let
    [size : i64
      (if bsd?
        (+ (* 6 width) 4)
        (+ (* 3 width) 4))]
    [target : u64 (cast (+ 68 size) : u64)]
    [name : String
      (if bsd?
        (if sorted
          "__.SYMDEF SORTED"
          "__.SYMDEF")
        (if (= width 4)
          "/"
          "/SYM64/"))]
    [payload : String
      (cat.str-cat
        (word
          (cast
            (if bsd?
              (* 4 width)
              2)
            : u64)
          width
          little)
        (if bsd?
          (word (cast 0 : u64) width little)
          "")
        (word target width little)
        (if bsd?
          (word (cast 2 : u64) width little)
          "")
        (word target width little)
        (if bsd?
          (word (cast 4 : u64) width little)
          "")
        "a"
        (word (cast 0 : u64) 1 false)
        "a"
        (word (cast 0 : u64) 1 false))]
    (cat.str-cat "!<arch>\n" (member name payload) (member "obj" "x"))))

(test
  ar-dialects-index-target-boundaries
  (let
    [data : String (fixture (& gnu))]
    [at : i64 0]
    (while (< at (string.string-length (& data)))
      (let
        [changed : String (patch (& data) 72 (word (cast at : u64) 4 false))]
        [valid : bool (or (= at 214) (= at 714) (= at 1182) (= at 1682))]
        (match (ar.read (& changed) (identity) (GnuSystemV) (limits))
          [(ReadArchive parsed)
            (test.assert-true
              valid
              "only complete ordinary headers are targets")
            (test.assert-i64-eq
              (array-ref parsed.hints 0).target.header-offset
              at
              "target")]
          [(ReadFailed error)
            (test.assert-false valid "ordinary target rejected")
            (test.assert-i64-eq
              (code error.kind)
              (if (or (= at 8) (= at 124))
                109
                108)
              "invalid target")
            (test.assert-i64-eq error.member 0 "index member provenance")
            (test.assert-i64-eq error.entry 0 "index entry provenance")
            (test.assert-i64-eq error.offset 72 "offset field provenance")
            (test.assert-true
              (= error.value (cast at : u64))
              "offending target")])
        (set! at (+ at 1))))))

(test
  ar-dialects-truncation-and-word-widths
  (let
    [variant : i64 0]
    (while (< variant 6)
      (let
        [bsd? : bool (>= variant 2)]
        [little : bool (and bsd? (< variant 4))]
        [width : i64
          (if (= (% variant 2) 0)
            4
            8)]
        [dialect : ar.ArDialect
          (if bsd?
            (if little
              (BsdLittleEndian)
              (BsdBigEndian))
            (GnuSystemV))]
        [data : String (small-index width bsd? little false)]
        [at : i64 0]
        ;; A 64-bit BSD index uses the explicit reserved spelling.
        (when
          (and bsd? (= width 8))
          (set! data (patch (& data) 8 (pad "__.SYMDEF_64" 16))))
        (accept (& data) dialect (limits))
        (while (< at (string.string-length (& data)))
          (unless (= at 8) (reject (text (& data) 0 at) dialect (limits) -1))
          (set! at (+ at 1)))
        (let
          [size : i64
            (if bsd?
              (+ (* 6 width) 4)
              (+ (* 3 width) 4))]
          [cut : i64 0]
          (while (< cut size)
            (let
              [payload : String (string.substring (& data) 68 cut)]
              [target : i64 (+ 68 (+ cut (% cut 2)))]
              [first-offset : i64
                (if bsd?
                  (* 2 width)
                  width)]
              [second-offset : i64
                (if bsd?
                  (* 4 width)
                  (* 2 width))]
              (when
                (>= cut (+ first-offset width))
                (set!
                  payload
                  (patch
                    (& payload)
                    first-offset
                    (word (cast target : u64) width little))))
              (when
                (>= cut (+ second-offset width))
                (set!
                  payload
                  (patch
                    (& payload)
                    second-offset
                    (word (cast target : u64) width little))))
              (let
                [changed : String
                  (cat.str-cat
                    "!<arch>\n"
                    (member (string.substring (& data) 8 16) payload)
                    (member "obj" "x"))]
                (reject (& changed) dialect (limits) -1)))
            (set! cut (+ cut 1))))
        (set! variant (+ variant 1))))))

(test
  ar-dialects-bsd-sorted-and-extended
  (let
    [data : String (small-index 4 true true true)]
    (accept (& data) (BsdLittleEndian) (limits))
    (let
      [bad : String (patch (& data) 92 "z")]
      (reject (& bad) (BsdLittleEndian) (limits) 12))
    (let
      [body : String (string.substring (& data) 68 28)]
      [prefix : String
        (cat.str-cat "__.SYMDEF SORTED" (word (cast 0 : u64) 4 false))]
      [target : String (word (cast 116 : u64) 4 true)]
      (set! body (patch (& body) 8 (clone target)))
      (set! body (patch (& body) 16 target))
      (let
        [extended : String
          (cat.str-cat
            "!<arch>\n"
            (member "#1/20" (cat.str-cat prefix body))
            (member "obj" "x"))]
        (accept (& extended) (BsdLittleEndian) (limits))
        (let
          [special-target : String
            (patch (& extended) 96 (word (cast 8 : u64) 4 true))]
          (reject (& special-target) (BsdLittleEndian) (limits) 109))))))

(defstruct BadWord
  (offset i64)
  (width i64)
  (value u64)
  (expected i64))

(define (bad-words
  [data : (& d str)]
  [dialect : ar.ArDialect]
  [little : bool]
  [cases : (& c (Slice BadWord))]) : unit
  (let
    [i : i64 0]
    (while (< i (array-length cases))
      (let
        [item : BadWord (array-ref cases i)]
        [changed : String
          (patch data item.offset (word item.value item.width little))]
        (reject (& changed) dialect (limits) item.expected))
      (set! i (+ i 1)))))

(test
  ar-dialects-malformed-index-structures
  (let
    [data : String (fixture (& gnu))]
    [cases : (Array BadWord 3)
      (array
        (BadWord 68 4 (cast 4294967295 : u64) 7)
        (BadWord 72 4 (cast 4294967295 : u64) 108)
        (BadWord 122 2 (cast 65535 : u64) 10))]
    (bad-words (& data) (GnuSystemV) false (& cases))
    (let
      [bad : String (patch (& data) 123 "x")]
      (reject (& bad) (GnuSystemV) (limits) 11)))
  (let
    [data : String (fixture (& gnu64))]
    [cases : (Array BadWord 3)
      (array
        (BadWord 68 8 (cast -1 : u64) 8)
        (BadWord 68 8 (cast 9223372036854775807 : u64) 7)
        (BadWord 76 8 (cast -1 : u64) 8))]
    (bad-words (& data) (GnuSystemV) false (& cases))
    (let
      [changed : String (patch (& data) 76 (word (cast -1 : u64) 8 false))]
      (match (ar.read (& changed) (identity) (GnuSystemV) (limits))
        [(ReadFailed error)
          (test.assert-i64-eq error.entry 0 "overflow entry")
          (test.assert-i64-eq error.offset 76 "overflow field")
          (test.assert-true
            (= error.value (cast -1 : u64))
            "unsigned overflow retained")]
        [_ (test.assert-true false "overflow accepted")])))
  (let
    [data : String (fixture (& bsd))]
    [cases : (Array BadWord 5)
      (array
        (BadWord 80 4 (cast 39 : u64) 7)
        (BadWord 124 4 (cast 4294967295 : u64) 7)
        (BadWord 84 4 (cast 31 : u64) 9)
        (BadWord 84 4 (cast 4294967295 : u64) 9)
        (BadWord 158 1 (cast 65 : u64) 10))]
    (bad-words (& data) (BsdLittleEndian) true (& cases))
    (reject (& data) (BsdBigEndian) (limits) 7)
    (reject (& data) (GnuSystemV) (limits) 1)
    (let
      [bad : String (patch (& data) 159 "x")]
      (reject (& bad) (BsdLittleEndian) (limits) 11))))

(test
  ar-dialects-names-and-special-order
  (let
    [data : String (fixture (& gnu))]
    [cases : (Array String 4)
      (array
        (patch (& data) 714 (pad "/30" 16))
        (patch (& data) 714 (pad "/1" 16))
        (patch (& data) 714 (pad "/29" 16))
        (patch (& data) 714 (pad "/-1" 16)))]
    [i : i64 0]
    (while (< i 4)
      (reject
        (& (array-ref cases i))
        (GnuSystemV)
        (limits)
        (if (= i 3)
          111
          3))
      (set! i (+ i 1)))
    (let
      [bad : String (patch (& data) 213 "x")]
      (reject (& bad) (GnuSystemV) (limits) 5))
    (let
      [bad : String (patch (& data) 212 "x")]
      (reject (& bad) (GnuSystemV) (limits) 5)))
  (let
    [index : String (member "/" (word (cast 0 : u64) 4 false))]
    [table : String (member "//" "long-name/\n")]
    [obj : String (member "x/" "x")]
    [cases : (Array String 5)
      (array
        (cat.str-cat "!<arch>\n" (clone index) (clone index))
        (cat.str-cat "!<arch>\n" (clone table) (clone index))
        (cat.str-cat "!<arch>\n" (clone obj) index)
        (cat.str-cat "!<arch>\n" (clone table) table)
        (cat.str-cat "!<arch>\n" obj (member "//" "name/\n")))]
    [i : i64 0]
    (while (< i 5)
      (reject (& (array-ref cases i)) (GnuSystemV) (limits) 6)
      (set! i (+ i 1))))
  (let
    [without-table : String (cat.str-cat "!<arch>\n" (member "/0" "x"))]
    [long-bsd : String (cat.str-cat "!<arch>\n" (member "#1/4" "abc"))]
    [bad-bsd : String
      (cat.str-cat
        "!<arch>\n"
        (member "#1/3" (cat.str-cat "a" (word (cast 0 : u64) 1 false) "b")))]
    (reject (& without-table) (GnuSystemV) (limits) 3)
    (reject (& long-bsd) (BsdLittleEndian) (limits) 4)
    (reject (& bad-bsd) (BsdLittleEndian) (limits) 2))
  (let
    [missing-length : String (cat.str-cat "!<arch>\n" (member "#1/" ""))]
    (reject (& missing-length) (BsdLittleEndian) (limits) 2)))

(test
  ar-dialects-empty-and-byte-names
  (let
    [variant : i64 0]
    (while (< variant 4)
      (let
        [dialect : ar.ArDialect
          (if (= variant 1)
            (BsdLittleEndian)
            (GnuSystemV))]
        [data : String
          (cond
            [(= variant 0) (cat.str-cat "!<arch>\n" (member "" "x"))]
            [(= variant 1) (cat.str-cat "!<arch>\n" (member "#1/0" "x"))]
            [(= variant 2)
              (cat.str-cat "!<arch>\n" (member "//" "/\n") (member "/0" "x"))]
            [else
              (cat.str-cat
                "!<arch>\n"
                (member (cat.str-cat (word (cast 255 : u64) 1 false) "/") "x"))])]
        (match (ar.read (& data) (identity) dialect (limits))
          [(ReadArchive parsed)
            (let
              [at : i64
                (if (= variant 2)
                  1
                  0)]
              [entry : ar.ArMember (array-ref parsed.members at)]
              (test.assert-i64-eq
                entry.name-size
                (if (= variant 3)
                  1
                  0)
                "empty or byte name")
              (test.assert-true
                (string.eq
                  (text (& data) entry.content-offset entry.content-size)
                  "x")
                "odd payload"))]
          [_ (test.assert-true false "empty/byte member name rejected")]))
      (set! variant (+ variant 1))))
  (let
    [data : String (cat.str-cat "!<arch>\n" (member "abcdefghijklmnop" ""))]
    (accept (& data) (BsdLittleEndian) (limits))))

(test
  ar-dialects-padding-and-empty-index
  (let
    [data : String
      (cat.str-cat "!<arch>\n" (member "//" "abc/\n\n") (member "/0" "x"))]
    (accept (& data) (GnuSystemV) (limits))
    (let
      [bad : String (patch (& data) 74 (pad "/5" 16))]
      (reject (& bad) (GnuSystemV) (limits) 5))
    (let
      [bad : String (patch (& data) 135 "x")]
      (reject (& bad) (GnuSystemV) (limits) 110)))
  (let
    [data : String
      (cat.str-cat "!<arch>\n" (member "/" (word (cast 0 : u64) 4 false)))]
    (accept (& data) (GnuSystemV) (limits)))
  (let
    [data : String
      (cat.str-cat
        "!<arch>\n"
        (member "__.SYMDEF" (word (cast 0 : u64) 8 false)))]
    (accept (& data) (BsdLittleEndian) (limits))))

(test
  ar-dialects-resolved-names-are-not-header-tags
  (let
    [data : String
      (cat.str-cat
        "!<arch>\n"
        (member "//" "dir//\n//\n__.SYMDEF/\n")
        (member "/0" "x")
        (member "/6" "x")
        (member "/9" "x"))]
    (match (ar.read (& data) (identity) (GnuSystemV) (limits))
      [(ReadArchive parsed)
        (let
          [expected : (Array String 3) (array "dir/" "/" "__.SYMDEF")]
          [i : i64 0]
          (while (< i 3)
            (let
              [entry : ar.ArMember (array-ref parsed.members (+ i 1))]
              (test.assert-true
                (match entry.kind
                  [(Ordinary) true]
                  [_ false])
                "name is not a special header")
              (test.assert-true
                (string.eq
                  (text (& data) entry.name-offset entry.name-size)
                  (& (array-ref expected i)))
                "resolved bytes preserved"))
            (set! i (+ i 1))))]
      [_ (test.assert-true false "ordinary indirect names rejected")])))

(test
  ar-dialects-all-resource-bounds
  (let
    [data : String (fixture (& gnu))]
    [which : i64 0]
    (while (< which 7)
      (let
        [caps : archive.ArchiveLimits (limits)]
        (cond
          [(= which 0) (set! caps.max-input-bytes -1)]
          [(= which 1) (set! caps.max-members -1)]
          [(= which 2) (set! caps.max-retained-bytes -1)]
          [(= which 3) (set! caps.max-special-members -1)]
          [(= which 4) (set! caps.max-index-entries -1)]
          [(= which 5) (set! caps.max-diagnostic-rows 0)]
          [else (set! caps.max-work -1)])
        (reject (& data) (GnuSystemV) caps 101))
      (set! which (+ which 1)))
    (match (ar.read (& data) (identity) (GnuSystemV) (limits))
      [(ReadArchive parsed)
        (let
          [exact : archive.ArchiveLimits (limits)]
          (set! exact.max-input-bytes (string.string-length (& data)))
          (set! exact.max-members 6)
          (set!
            exact.max-retained-bytes
            (+
              (*
                6
                (+
                  archive.retained-member-bytes
                  (comptime (size-of (type ar.ArMember)))))
              (* 5 (comptime (size-of (type ar.ArSymbolHint))))))
          (set! exact.max-special-members 2)
          (set! exact.max-index-entries 5)
          (set! exact.max-work (- exact.max-work parsed.session.work-left))
          (accept (& data) (GnuSystemV) (clone exact))
          (set! which 0)
          (while (< which 6)
            (let
              [caps : archive.ArchiveLimits (clone exact)]
              (cond
                [(= which 0)
                  (set! caps.max-input-bytes (- caps.max-input-bytes 1))]
                [(= which 1) (set! caps.max-members 5)]
                [(= which 2)
                  (set! caps.max-retained-bytes (- caps.max-retained-bytes 1))]
                [(= which 3) (set! caps.max-special-members 1)]
                [(= which 4) (set! caps.max-index-entries 4)]
                [else (set! caps.max-work (- caps.max-work 1))])
              (reject (& data) (GnuSystemV) caps (+ 102 which)))
            (set! which (+ which 1))))]
      [_ (test.assert-true false "limits baseline")]))
  (let
    [empty : String "!<arch>\n"]
    [caps : archive.ArchiveLimits (archive.ArchiveLimits 8 0 0 0 0 1 13)]
    (accept (& empty) (GnuSystemV) caps)))

(test
  ar-dialects-stable-input-identity
  (let
    [a : String (fixture (& gnu))]
    [b : String (clone a)]
    (match (ar.read (& a) (identity) (GnuSystemV) (limits))
      [(ReadArchive first)
        (match (ar.read (& b) (identity) (GnuSystemV) (limits))
          [(ReadArchive second)
            (let
              [i : i64 0]
              (while (< i (array-length first.hints))
                (let
                  [x : ar.ArSymbolHint (array-ref first.hints i)]
                  [y : ar.ArSymbolHint (array-ref second.hints i)]
                  (test.assert-i64-eq
                    x.name-offset
                    y.name-offset
                    "stable symbol span")
                  (test.assert-i64-eq
                    x.target.ordinal
                    y.target.ordinal
                    "stable physical occurrence")
                  (test.assert-i64-eq
                    x.target.header-offset
                    y.target.header-offset
                    "stable header")
                  (test.assert-true
                    (= x.target.archive.input y.target.archive.input)
                    "stable input token"))
                (set! i (+ i 1))))]
          [_ (test.assert-true false "copied input rejected")])
        (let
          [changed : archive.ArchiveIdentity (identity)]
          (set! changed.content (cast 74 : u64))
          (match (ar.read (& b) changed (GnuSystemV) (limits))
            [(ReadArchive second)
              (match (archive.check-id
                (& second.directory)
                (array-ref first.hints 0).target)
                [(InvalidId (StaleIdentity)) unit]
                [_ (test.assert-true false "revision is part of identity")])]
            [_ (test.assert-true false "new revision rejected")]))]
      [_ (test.assert-true false "identity fixture")])))