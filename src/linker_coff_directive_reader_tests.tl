;; Executable `.drectve` reader conformance, discovered by inline-test CI.
(import linker_coff_directive_reader as drectve)
(import stdlib.byte_buf_core as bytes)
(import stdlib.io)
(import stdlib.str_cat_runtime as cat)
(import stdlib.string)

(define (assert [condition : bool] [message : String]) : unit
  (unless condition (io.panic (cat.str-cat message "\n"))))

(define (section) : drectve.CoffDirectiveSection
  (drectve.CoffDirectiveSection "lib/a.obj" 3 ".drectve" 0x100a00 0 0))

(define (bytes-of [text : String]) : (__tl_dyn-array u8)
  (let
    [out : bytes.ByteBufBuilder (bytes.byte-buf-builder-new)]
    (begin
      (bytes.byte-buf-builder-append-string (&mut out) text)
      (bytes.byte-buf-builder-to-array (& out)))))

(define (bom-bytes [text : String]) : (__tl_dyn-array u8)
  (let
    [out : bytes.ByteBufBuilder (bytes.byte-buf-builder-new)]
    (begin
      (bytes.byte-buf-builder-push (&mut out) (cast 0xef : u8))
      (bytes.byte-buf-builder-push (&mut out) (cast 0xbb : u8))
      (bytes.byte-buf-builder-push (&mut out) (cast 0xbf : u8))
      (bytes.byte-buf-builder-append-string (&mut out) text)
      (bytes.byte-buf-builder-to-array (& out)))))

;; `text` with the byte at `index` replaced, for NUL and raw non-ASCII input.
(define (patched [data : (__tl_dyn-array u8)] [index : i64] [value : i64]) : (__tl_dyn-array
    u8)
  (begin
    (set! (array-ref data index) (cast value : u8))
    data))

(define (read-with
  [data : (__tl_dyn-array u8)]
  [limits : drectve.CoffDirectiveLimits]) : drectve.ResultCoffDirectives
  (let
    [header : drectve.CoffDirectiveSection (section)]
    (drectve.read-directives
      (& header)
      (& data)
      0
      (array-length data)
      (& limits))))

(define (read-data [data : (__tl_dyn-array u8)]) : drectve.ResultCoffDirectives
  (read-with data (drectve.default-limits)))

(define (render-directive [directive : (& d drectve.CoffDirective)]) : String
  (match directive
    [(drectve.CoffDirective.DefaultLib name)
      (cat.str-cat "DefaultLib " (string.copy name))]
    [(drectve.CoffDirective.NoDefaultLibAll) "NoDefaultLibAll"]
    [(drectve.CoffDirective.NoDefaultLib name)
      (cat.str-cat "NoDefaultLib " (string.copy name))]
    [(drectve.CoffDirective.Include name)
      (cat.str-cat "Include " (string.copy name))]
    [(drectve.CoffDirective.Export payload)
      (cat.str-cat "Export " (string.copy payload))]
    [(drectve.CoffDirective.AlternateName from to)
      (cat.str-cat "AlternateName " (string.copy from) "|" (string.copy to))]
    [(drectve.CoffDirective.FailIfMismatch key value)
      (cat.str-cat "FailIfMismatch " (string.copy key) "|" (string.copy value))]
    [(drectve.CoffDirective.DelayLoad dll)
      (cat.str-cat "DelayLoad " (string.copy dll))]
    [(drectve.CoffDirective.DelayUnload) "DelayUnload"]
    [(drectve.CoffDirective.DelayNoBind) "DelayNoBind"]))

(define (render [result : (& r drectve.ResultCoffDirectives)]) : String
  (match result
    [(drectve.ResultCoffDirectives.Err error)
      (cat.str-cat "error: " (string.copy error.message))]
    [(drectve.ResultCoffDirectives.Ok records)
      (let
        [out : String ""]
        [index : i64 0]
        (begin
          (while (< index records.len)
            (let
              [record : (& records drectve.CoffDirectiveRecord)
                (& (array-ref records.slots index))]
              (begin
                (assert
                  (and
                    (string.eq record.object "lib/a.obj")
                    (= record.section 3))
                  "record lost its object/section identity")
                (set!
                  out
                  (cat.str-cat
                    (string.copy out)
                    (string.int->string record.start)
                    ".."
                    (string.int->string record.end)
                    " "
                    (render-directive (& record.directive))
                    "\n"))
                (set! index (+ index 1)))))
          out))]))

(define (render-owned [result : drectve.ResultCoffDirectives]) : String
  (render (& result)))

(define (read-section
  [header : drectve.CoffDirectiveSection]
  [data : (& d (__tl_dyn-array u8))]
  [start : i64]
  [size : i64]) : drectve.ResultCoffDirectives
  (let
    [limits : drectve.CoffDirectiveLimits (drectve.default-limits)]
    (drectve.read-directives (& header) data start size (& limits))))

(define (expect
  [name : String]
  [data : (__tl_dyn-array u8)]
  [expected : String]) : unit
  (let
    [result : drectve.ResultCoffDirectives (read-data data)]
    [actual : String (render (& result))]
    (assert
      (string.eq actual expected)
      (cat.str-cat (clone name) ": unexpected records:\n" actual))))

(define (kind-name [kind : (& k drectve.CoffDirectiveErrorKind)]) : String
  (match kind
    [(drectve.CoffDirectiveErrorKind.NotDirectiveSection) "NotDirectiveSection"]
    [(drectve.CoffDirectiveErrorKind.HasRelocations) "HasRelocations"]
    [(drectve.CoffDirectiveErrorKind.HasLineNumbers) "HasLineNumbers"]
    [(drectve.CoffDirectiveErrorKind.InvalidRange) "InvalidRange"]
    [(drectve.CoffDirectiveErrorKind.InvalidLimits) "InvalidLimits"]
    [(drectve.CoffDirectiveErrorKind.TooLarge) "TooLarge"]
    [(drectve.CoffDirectiveErrorKind.TooManyOptions) "TooManyOptions"]
    [(drectve.CoffDirectiveErrorKind.TokenTooLong) "TokenTooLong"]
    [(drectve.CoffDirectiveErrorKind.NulByte) "NulByte"]
    [(drectve.CoffDirectiveErrorKind.NonAsciiWithoutBom) "NonAsciiWithoutBom"]
    [(drectve.CoffDirectiveErrorKind.MalformedUtf8) "MalformedUtf8"]
    [(drectve.CoffDirectiveErrorKind.UnterminatedQuote) "UnterminatedQuote"]
    [(drectve.CoffDirectiveErrorKind.AmbiguousQuote) "AmbiguousQuote"]
    [(drectve.CoffDirectiveErrorKind.QuotedOptionName) "QuotedOptionName"]
    [(drectve.CoffDirectiveErrorKind.NotAnOption) "NotAnOption"]
    [(drectve.CoffDirectiveErrorKind.ResponseFile) "ResponseFile"]
    [(drectve.CoffDirectiveErrorKind.EmptyOptionName) "EmptyOptionName"]
    [(drectve.CoffDirectiveErrorKind.UnsupportedOption) "UnsupportedOption"]
    [(drectve.CoffDirectiveErrorKind.MissingPayload) "MissingPayload"]
    [(drectve.CoffDirectiveErrorKind.MissingSeparator) "MissingSeparator"]
    [(drectve.CoffDirectiveErrorKind.EmptyField) "EmptyField"]
    [(drectve.CoffDirectiveErrorKind.PathBearingDll) "PathBearingDll"]
    [(drectve.CoffDirectiveErrorKind.UnknownDelayQualifier)
      "UnknownDelayQualifier"]))

;; Require one failure class at exactly `[start, end)`, reported with the
;; object, section and byte range, plus `detail` somewhere in the message.
(define (expect-failure
  [result : drectve.ResultCoffDirectives]
  [kind : String]
  [start : i64]
  [end : i64]
  [detail : String]) : unit
  (match result
    [(drectve.ResultCoffDirectives.Ok _)
      (io.panic (cat.str-cat "expected " kind " but the directives parsed\n"))]
    [(drectve.ResultCoffDirectives.Err error)
      (let
        [location : String
          (cat.str-cat
            "lib/a.obj: section 3 .drectve bytes "
            (string.int->string start)
            ".."
            (string.int->string end)
            ": ")]
        (assert
          (and
            (string.eq (kind-name (& error.kind)) kind)
            (= error.start start)
            (= error.end end)
            (= error.section 3)
            (string.eq error.object "lib/a.obj")
            (string.is-string-prefix-at (& error.message) (& location) 0)
            (string.contains (& error.message) (& detail)))
          (cat.str-cat
            "expected "
            kind
            " at "
            (string.int->string start)
            ".."
            (string.int->string end)
            ", got "
            (kind-name (& error.kind))
            ": "
            (clone error.message))))]))

(define (reject
  [text : String]
  [kind : String]
  [start : i64]
  [end : i64]
  [detail : String]) : unit
  (expect-failure (read-data (bytes-of text)) kind start end detail))

;; --- admitted directives ------------------------------------------------------
(test
  drectve-reads-msvc-and-clang-cl-sections
  (begin
    ;; MSVC `#pragma comment(lib)` and STL mismatch checks.
    (expect
      "msvc default libraries"
      (bytes-of "   /DEFAULTLIB:\"LIBCMT\" /DEFAULTLIB:\"OLDNAMES\" ")
      "3..23 DefaultLib LIBCMT\n24..46 DefaultLib OLDNAMES\n")
    (expect
      "msvc mismatch keys"
      (bytes-of
        "/FAILIFMISMATCH:\"_MSC_VER=1900\" /FAILIFMISMATCH:\"RuntimeLibrary=MT_StaticRelease\"")
      "0..31 FailIfMismatch _MSC_VER|1900\n32..81 FailIfMismatch RuntimeLibrary|MT_StaticRelease\n")
    ;; clang-cl default libraries, forced symbols and exports.
    (expect
      "clang-cl"
      (bytes-of
        " /DEFAULTLIB:libcmt.lib /DEFAULTLIB:oldnames.lib /INCLUDE:_tls_used /EXPORT:f /EXPORT:\"?v@@3HA\",DATA")
      "1..23 DefaultLib libcmt.lib\n24..48 DefaultLib oldnames.lib\n49..67 Include _tls_used\n68..77 Export f\n78..100 Export ?v@@3HA,DATA\n")))

(test
  drectve-reads-every-admitted-option-in-order
  (begin
    (expect
      "mixed case and repeats keep order and spelling"
      (bytes-of
        "/defaultlib:Foo.lib /DefaultLib:foo.lib /NODEFAULTLIB /nodefaultlib:libc.lib /include:\"?x@@3HA\"")
      "0..19 DefaultLib Foo.lib\n20..39 DefaultLib foo.lib\n40..53 NoDefaultLibAll\n54..76 NoDefaultLib libc.lib\n77..95 Include ?x@@3HA\n")
    (expect
      "aliases and exports"
      (bytes-of
        "/ALTERNATENAME:__imp_f=__imp_g /alternatename:a=b=c /export:bar,PRIVATE")
      "0..30 AlternateName __imp_f|__imp_g\n31..51 AlternateName a|b=c\n52..71 Export bar,PRIVATE\n")
    (expect
      "delay loads and qualifiers"
      (bytes-of
        "/DELAYLOAD:user32.dll /delayload:USER32.DLL /DELAY:UNLOAD /delay:nobind /Delay:Unload /DELAYLOAD:user32.dll")
      "0..21 DelayLoad user32.dll\n22..43 DelayLoad USER32.DLL\n44..57 DelayUnload\n58..71 DelayNoBind\n72..85 DelayUnload\n86..107 DelayLoad user32.dll\n")
    (expect
      "quoted spaces, backslashes and every separator"
      (bytes-of
        "\t/DEFAULTLIB:\"my lib.lib\"\r\n/DEFAULTLIB:C:\\lib\\x.lib\n/DEFAULTLIB:\"C:\\lib dir\\y.lib\"  ")
      "1..25 DefaultLib my lib.lib\n27..51 DefaultLib C:\\lib\\x.lib\n52..82 DefaultLib C:\\lib dir\\y.lib\n")
    (expect "empty section" (bytes-of "") "")
    (expect "whitespace only" (bytes-of " \t\r\n") "")
    (expect "bom only" (bom-bytes "") "")
    (expect
      "bom-marked utf-8 payload"
      (bom-bytes "/DEFAULTLIB:\"bibliothèque.lib\" /INCLUDE:日本")
      "3..34 DefaultLib bibliothèque.lib\n35..50 Include 日本\n")))

(test
  drectve-records-keep-the-written-spelling
  (match (read-data (bytes-of "  /DefaultLib:\"a b\" "))
    [(drectve.ResultCoffDirectives.Ok records)
      (assert
        (and
          (= records.len 1)
          (string.eq (array-ref records.slots 0).spelling "/DefaultLib:\"a b\""))
        "spelling is not the exact token")]
    [_ (io.panic "spelling fixture failed\n")]))

;; --- rejected input -------------------------------------------------------------
(test
  drectve-rejects-malformed-text-with-exact-spans
  (begin
    (reject
      "/DEFAULTLIB:\"LIBCMT"
      "UnterminatedQuote"
      12
      19
      "unterminated quote")
    (reject "/DEFAULTLIB:\"a\\\"b\"" "AmbiguousQuote" 14 16 "escape")
    (reject "/DEFAULTLIB:\"\"" "AmbiguousQuote" 12 14 "escape")
    (reject "/EXPORT:\"a\"\"b\"" "AmbiguousQuote" 10 12 "escape")
    (reject "\"/DEFAULTLIB:x\"" "QuotedOptionName" 0 1 "payload")
    (reject "/DEF\"AULT\"LIB:x" "QuotedOptionName" 0 5 "payload")
    (reject "DEFAULTLIB:x" "NotAnOption" 0 12 "starting with `/`")
    (reject "-defaultlib:x" "NotAnOption" 0 13 "`-` spelling")
    (reject ":x" "NotAnOption" 0 2 "starting with `/`")
    (reject "@args.rsp" "ResponseFile" 0 9 "response files")
    (reject "/" "EmptyOptionName" 0 1 "empty option name")
    (reject "/:x" "EmptyOptionName" 0 3 "empty option name")
    (expect-failure
      (read-data (patched (bytes-of "/DEFAULTLIB:a#b") 13 0))
      "NulByte"
      13
      14
      "NUL")
    (expect-failure
      (read-data (patched (bytes-of "/DEFAULTLIB:#.lib") 12 0xc3))
      "NonAsciiWithoutBom"
      12
      13
      "code page")
    (expect-failure
      (read-data (patched (bom-bytes "/DEFAULTLIB:#(") 15 0xc3))
      "MalformedUtf8"
      3
      17
      "UTF-8")
    (expect-failure
      (read-data (patched (patched (bom-bytes "/INCLUDE:##") 12 0xc0) 13 0x80))
      "MalformedUtf8"
      3
      14
      "UTF-8")
    (expect-failure
      (read-data
        (patched
          (patched (patched (bom-bytes "/INCLUDE:###") 12 0xed) 13 0xa0)
          14
          0x80))
      "MalformedUtf8"
      3
      15
      "UTF-8")))

(test
  drectve-rejects-malformed-fields
  (begin
    (reject "/DEFAULTLIB" "MissingPayload" 0 11 "requires")
    (reject "/INCLUDE" "MissingPayload" 0 8 "requires")
    (reject "/EXPORT" "MissingPayload" 0 7 "requires")
    (reject "/ALTERNATENAME" "MissingPayload" 0 14 "requires")
    (reject "/FAILIFMISMATCH" "MissingPayload" 0 15 "requires")
    (reject "/DELAYLOAD" "MissingPayload" 0 10 "requires")
    (reject "/DELAY" "MissingPayload" 0 6 "UNLOAD or :NOBIND")
    (reject "/DEFAULTLIB:" "EmptyField" 0 12 "empty payload")
    (reject "/NODEFAULTLIB:" "EmptyField" 0 14 "empty payload")
    (reject "/DELAYLOAD:" "EmptyField" 0 11 "empty payload")
    (reject "/ALTERNATENAME:=b" "EmptyField" 0 17 "empty side")
    (reject "/ALTERNATENAME:a=" "EmptyField" 0 17 "empty side")
    (reject "/FAILIFMISMATCH:\"=\"" "EmptyField" 0 19 "empty side")
    (reject "/ALTERNATENAME:ab" "MissingSeparator" 0 17 "needs `=`")
    (reject "/FAILIFMISMATCH:\"key\"" "MissingSeparator" 0 21 "needs `=`")
    (reject "/DELAYLOAD:C:\\x.dll" "PathBearingDll" 0 19 "file name")
    (reject "/DELAYLOAD:dir/x.dll" "PathBearingDll" 0 20 "file name")
    (reject "/DELAYLOAD:..\\x.dll" "PathBearingDll" 0 19 "file name")
    (reject
      "/DELAY:UNLOAD,NOBIND"
      "UnknownDelayQualifier"
      0
      20
      "UNLOAD or NOBIND")
    (reject "/DELAY:load" "UnknownDelayQualifier" 0 11 "UNLOAD or NOBIND")
    (reject "/DELAY:" "UnknownDelayQualifier" 0 7 "UNLOAD or NOBIND")))

(test
  drectve-fails-closed-on-unadmitted-options
  (begin
    (reject
      "/MERGE:.a=.b"
      "UnsupportedOption"
      0
      12
      "/MERGE (section layout) is not admitted")
    (reject
      "/section:.x,RW"
      "UnsupportedOption"
      0
      14
      "/section (section layout)")
    (reject "/OUT:x.exe" "UnsupportedOption" 0 10 "(output selection)")
    (reject "/LIBPATH:C:\\x" "UnsupportedOption" 0 13 "(library search path)")
    (reject "/DYNAMICBASE:NO" "UnsupportedOption" 0 15 "(security policy)")
    (reject "/guard:no" "UnsupportedOption" 0 9 "(security policy)")
    (reject "/OPT:REF" "UnsupportedOption" 0 8 "/OPT is not admitted")
    ;; The alternatives are named in every unsupported-option diagnostic.
    (reject
      "/FOO"
      "UnsupportedOption"
      0
      4
      "admitted directives are /DEFAULTLIB, /NODEFAULTLIB, /INCLUDE, /EXPORT, /ALTERNATENAME, /FAILIFMISMATCH, /DELAYLOAD, /DELAY:UNLOAD and /DELAY:NOBIND")
    ;; A failure after admitted options reports only the offending token.
    (reject
      "/DEFAULTLIB:a  /MERGE:x /INCLUDE:b"
      "UnsupportedOption"
      15
      23
      "/MERGE")))

(test
  drectve-checks-the-section-header-and-limits
  (let
    [data : (__tl_dyn-array u8) (bytes-of "/DEFAULTLIB:a /INCLUDE:b")]
    (begin
      (expect-failure
        (read-section
          (drectve.CoffDirectiveSection "lib/a.obj" 3 ".text" 0x100a00 0 0)
          (& data)
          0
          24)
        "NotDirectiveSection"
        0
        0
        ".text")
      (expect-failure
        (read-section
          (drectve.CoffDirectiveSection "lib/a.obj" 3 ".drectve" 0x100800 0 0)
          (& data)
          0
          24)
        "NotDirectiveSection"
        0
        0
        "IMAGE_SCN_LNK_INFO")
      (expect-failure
        (read-section
          (drectve.CoffDirectiveSection "lib/a.obj" 3 ".drectve" 0x200 1 0)
          (& data)
          0
          24)
        "HasRelocations"
        0
        0
        "relocations")
      (expect-failure
        (read-section
          (drectve.CoffDirectiveSection "lib/a.obj" 3 ".drectve" 0x200 0 2)
          (& data)
          0
          24)
        "HasLineNumbers"
        0
        0
        "line numbers")
      (expect-failure
        (read-section (section) (& data) 20 5)
        "InvalidRange"
        0
        5
        "outside")
      (expect-failure
        (read-section (section) (& data) -1 3)
        "InvalidRange"
        0
        3
        "outside")
      (expect-failure
        (read-section (section) (& data) 0 -1)
        "InvalidRange"
        0
        -1
        "outside")
      (expect-failure
        (read-with (bytes-of "/INCLUDE:a") (drectve.CoffDirectiveLimits 0 1 1))
        "InvalidLimits"
        0
        0
        "positive")
      ;; Each bound admits its exact limit and rejects one more.
      (assert
        (string.eq
          (render-owned
            (read-with
              (bytes-of "/INCLUDE:a")
              (drectve.CoffDirectiveLimits 10 1 10)))
          "0..10 Include a\n")
        "exact limits were rejected")
      (expect-failure
        (read-with
          (bytes-of "/INCLUDE:a ")
          (drectve.CoffDirectiveLimits 10 1 10))
        "TooLarge"
        0
        11
        "exceeds 10 bytes")
      (expect-failure
        (read-with
          (bytes-of "/INCLUDE:a /INCLUDE:b")
          (drectve.CoffDirectiveLimits 100 1 10))
        "TooManyOptions"
        11
        21
        "more than 1 options")
      (expect-failure
        (read-with
          (bytes-of "/INCLUDE:ab")
          (drectve.CoffDirectiveLimits 100 4 10))
        "TokenTooLong"
        0
        11
        "exceeds 10 bytes"))))

;; --- boundaries and determinism ---------------------------------------------------
;; Cutting the section at any byte reads every option that ends before the cut
;; unchanged. The cut option may still read (as a shorter payload) or fail, but
;; a failure always lies inside that option, and a cut between options reads.
(define (complete-before
  [records : (& r drectve.ResultCoffDirectives)]
  [cut : i64]) : i64
  (match records
    [(drectve.ResultCoffDirectives.Ok expected)
      (let
        [kept : i64 0]
        (begin
          (while (and
            (< kept expected.len)
            (<= (array-ref expected.slots kept).end cut))
            (set! kept (+ kept 1)))
          kept))]
    [_ (io.panic "truncation fixture failed\n")]))

(define (record-start
  [records : (& r drectve.ResultCoffDirectives)]
  [index : i64]) : i64
  (match records
    [(drectve.ResultCoffDirectives.Ok expected)
      (if (< index expected.len)
        (array-ref expected.slots index).start
        -1)]
    [_ -1]))

(define (same-prefix?
  [full : (& f drectve.ResultCoffDirectives)]
  [cut : (& c drectve.ResultCoffDirectives)]
  [kept : i64]) : bool
  (match full
    [(drectve.ResultCoffDirectives.Ok expected)
      (match cut
        [(drectve.ResultCoffDirectives.Ok records)
          (let
            [index : i64 0]
            [same : bool
              (and (>= records.len kept) (<= records.len (+ kept 1)))]
            (begin
              (while (and same (< index kept))
                (set!
                  same
                  (and
                    (string.eq
                      (array-ref records.slots index).spelling
                      (array-ref expected.slots index).spelling)
                    (=
                      (array-ref records.slots index).start
                      (array-ref expected.slots index).start)
                    (=
                      (array-ref records.slots index).end
                      (array-ref expected.slots index).end)))
                (set! index (+ index 1)))
              same))]
        [_ false])]
    [_ false]))

(test
  drectve-truncation-at-every-byte-boundary
  (let
    [text : String
      "   /DEFAULTLIB:\"LIBCMT\" /FAILIFMISMATCH:\"_MSC_VER=1900\"\t/EXPORT:\"?v@@3HA\",DATA /DELAY:UNLOAD"]
    [full : drectve.ResultCoffDirectives (read-data (bytes-of (clone text)))]
    [length : i64 (string.string-length (& text))]
    [cut : i64 0]
    (while (<= cut length)
      (let
        [result : drectve.ResultCoffDirectives
          (read-data (bytes-of (string.substring (& text) 0 cut)))]
        [kept : i64 (complete-before (& full) cut)]
        [next-start : i64 (record-start (& full) kept)]
        (begin
          (match (& result)
            [(drectve.ResultCoffDirectives.Ok _)
              (assert
                (same-prefix? (& full) (& result) kept)
                (cat.str-cat
                  "complete options changed at cut "
                  (string.int->string cut)))]
            [(drectve.ResultCoffDirectives.Err error)
              (assert
                (and
                  (>= next-start 0)
                  (< next-start cut)
                  (>= error.start next-start)
                  (<= error.end cut))
                (cat.str-cat
                  "cut "
                  (string.int->string cut)
                  " failed outside its partial option: "
                  (string.copy error.message)))])
          (set! cut (+ cut 1)))))))

;; Only the section's bytes matter: the same text embedded anywhere in the
;; object reads identically, and bytes around it are never inspected.
(test
  drectve-reads-only-the-section-range
  (let
    [text : String "/DEFAULTLIB:\"LIBCMT\" /INCLUDE:x"]
    [standalone : String (render-owned (read-data (bytes-of (clone text))))]
    [object : (__tl_dyn-array u8)
      (patched
        (patched (bytes-of (cat.str-cat "#####" (clone text) "##")) 0 0)
        36
        0xff)]
    [embedded : drectve.ResultCoffDirectives
      (read-section (section) (& object) 5 31)]
    [again : drectve.ResultCoffDirectives
      (read-section (section) (& object) 5 31)]
    (assert
      (and
        (string.eq standalone "0..20 DefaultLib LIBCMT\n21..31 Include x\n")
        (string.eq (render (& embedded)) standalone)
        (string.eq (render (& again)) standalone))
      (cat.str-cat "embedded read differs:\n" (render (& embedded))))))

;; Seeded fuzz over a hostile alphabet: every section either fails with a span
;; inside it or yields ordered, disjoint records whose spelling is their bytes.
(define fuzz-state : i64
  6364136223846793005)

(define (fuzz-below [bound : i64]) : i64
  (begin
    (set! fuzz-state (bit-xor fuzz-state (shl fuzz-state 13)))
    (set! fuzz-state (bit-xor fuzz-state (shr fuzz-state 7)))
    (set! fuzz-state (bit-xor fuzz-state (shl fuzz-state 17)))
    (% (bit-and fuzz-state 9223372036854775807) bound)))

(define (fuzz-byte) : i64
  (let
    [alphabet : String "/:\"\\ \t=@-.aDELAYNOBIND"]
    [pick : i64 (fuzz-below 30)]
    (cond
      [(< pick (string.string-length (& alphabet)))
        (cast (string.string-ref (& alphabet) pick) : i64)]
      [(= pick 26) 0]
      [(= pick 27) 0xc3]
      [(= pick 28) 0xa9]
      [else 0xef])))

(define (fuzz-section) : (__tl_dyn-array u8)
  (let
    [out : bytes.ByteBufBuilder (bytes.byte-buf-builder-new)]
    [count : i64 (fuzz-below 48)]
    [index : i64 0]
    (begin
      (when
        (= (fuzz-below 4) 0)
        (bytes.byte-buf-builder-append-string (&mut out) "/DEFAULTLIB:"))
      (while (< index count)
        (bytes.byte-buf-builder-push (&mut out) (cast (fuzz-byte) : u8))
        (set! index (+ index 1)))
      (bytes.byte-buf-builder-to-array (& out)))))

(define (raw-text [data : (& d (__tl_dyn-array u8))] [start : i64] [end : i64]) : String
  (let
    [out : bytes.ByteBufBuilder (bytes.byte-buf-builder-new)]
    (begin
      (bytes.byte-buf-builder-append-array-range
        (&mut out)
        data
        start
        (- end start))
      (bytes.byte-buf-builder-to-string (& out)))))

(test
  drectve-fuzzed-sections-stay-in-bounds
  (let
    [case : i64 0]
    [parsed : i64 0]
    (begin
      (while (< case 3000)
        (let
          [data : (__tl_dyn-array u8) (fuzz-section)]
          [size : i64 (array-length data)]
          [result : drectve.ResultCoffDirectives (read-data (clone data))]
          (begin
            (match (& result)
              [(drectve.ResultCoffDirectives.Err error)
                (assert
                  (and
                    (>= error.start 0)
                    (<= error.start error.end)
                    (<= error.end size))
                  (cat.str-cat
                    "fuzz error span escaped: "
                    (string.copy error.message)))]
              [(drectve.ResultCoffDirectives.Ok records)
                (let
                  [index : i64 0]
                  [previous-end : i64 0]
                  (begin
                    (set! parsed (+ parsed 1))
                    (while (< index records.len)
                      (let
                        [record : (& records drectve.CoffDirectiveRecord)
                          (& (array-ref records.slots index))]
                        (begin
                          (assert
                            (and
                              (>= record.start previous-end)
                              (< record.start record.end)
                              (<= record.end size)
                              (string.eq
                                record.spelling
                                (raw-text (& data) record.start record.end)))
                            "fuzz record range or spelling is wrong")
                          (set! previous-end record.end)
                          (set! index (+ index 1)))))))])
            (set! case (+ case 1)))))
      (assert (> parsed 0) "fuzz never produced an accepted section"))))