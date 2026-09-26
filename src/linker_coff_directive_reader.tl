;; Typed COFF `.drectve` linker directives.
;;
;; Reads the admitted `.drectve` subset that MSVC and clang-cl C compilation
;; emit into ordered typed records with exact byte provenance. Reading is pure:
;; it never searches for libraries, resolves symbols or aliases, selects exports
;; or delay imports, compares mismatch keys, or forwards directive text to a
;; linker, shell or response-file parser. #7102 (default libraries, forced
;; roots, aliases, mismatch keys), #7125 (exports), #7094 (delay loads) and
;; #7423 (external-link preflight) own what the records mean.
;;
;; Grammar over the section bytes:
;;
;;   section := [UTF-8 BOM] ws* [option (ws+ option)*] ws*
;;   option  := "/" name [":" payload]
;;   payload := (plain | quoted)*
;;   plain   := any byte except ws, `"` and NUL
;;   quoted  := `"` (any byte except `"` and NUL)* `"`
;;
;; `ws` is ASCII space, tab, LF, VT, FF or CR. A payload drops its quote bytes
;; and keeps everything else, so `/DEFAULTLIB:"LIBCMT"` and
;; `/EXPORT:"?v@@3HA",DATA` read as `LIBCMT` and `?v@@3HA,DATA`. Quotes may
;; appear only after the name's `:`. A backslash directly before a quote and two
;; adjacent quotes are rejected: Windows argument parsers read both as escapes,
;; so their meaning would depend on the consumer. Option names match ASCII case
;; insensitively. Without a BOM every byte must be ASCII, because decoding with
;; a host ANSI code page would make results host-dependent; after a BOM every
;; token must be strict UTF-8.
(import compiler_incremental_binary as binary)
(import stdlib.byte_buf_core as bytes)
(import stdlib.str_cat_runtime as cat)
(import stdlib.string)
(import stdlib.vector)

;: The object reader's view of one section header. `object` is the stable
;: identity printed in diagnostics; `index` is the 1-based section number.
(defstruct CoffDirectiveSection
  (object String)
  (index i64)
  (name String)
  (characteristics i64)
  (relocations i64)
  (line-numbers i64))

(defstruct CoffDirectiveLimits
  (max-bytes i64)
  (max-options i64)
  (max-token-bytes i64))

;: The admitted profile. Real directive sections are a few hundred bytes; the
;: token bound leaves room for long decorated C++ export names.
(define (default-limits) : CoffDirectiveLimits
  (CoffDirectiveLimits 1048576 16384 65536))

(defenum CoffDirective
  (DefaultLib String)
  (NoDefaultLibAll)
  (NoDefaultLib String)
  (Include String)
  (Export String)
  (AlternateName String String)
  (FailIfMismatch String String)
  (DelayLoad String)
  (DelayUnload)
  (DelayNoBind))

;: `start` and `end` bound the option token in the section data (offsets count
;: a leading BOM). `spelling` is the token as written; payload fields drop only
;: the quote bytes and keep their case.
(defstruct CoffDirectiveRecord
  (object String)
  (section i64)
  (start i64)
  (end i64)
  (spelling String)
  (directive CoffDirective))

(import (vector.vector CoffDirectiveRecord) as record_vec)

;: Stable failure classes for consumers; the message adds the object, section,
;: byte range and the offending spelling.
(defenum CoffDirectiveErrorKind
  (NotDirectiveSection)
  (HasRelocations)
  (HasLineNumbers)
  (InvalidRange)
  (InvalidLimits)
  (TooLarge)
  (TooManyOptions)
  (TokenTooLong)
  (NulByte)
  (NonAsciiWithoutBom)
  (MalformedUtf8)
  (UnterminatedQuote)
  (AmbiguousQuote)
  (QuotedOptionName)
  (NotAnOption)
  (ResponseFile)
  (EmptyOptionName)
  (UnsupportedOption)
  (MissingPayload)
  (MissingSeparator)
  (EmptyField)
  (PathBearingDll)
  (UnknownDelayQualifier))

(defstruct CoffDirectiveError
  (kind CoffDirectiveErrorKind)
  (object String)
  (section i64)
  (start i64)
  (end i64)
  (message String))

(defenum ResultCoffDirectives
  (Ok record_vec.Vec)
  (Err CoffDirectiveError))

(define (directive-error
  [section : (& s CoffDirectiveSection)]
  [kind : CoffDirectiveErrorKind]
  [start : i64]
  [end : i64]
  [detail : String]) : CoffDirectiveError
  (CoffDirectiveError
    kind
    (clone section.object)
    section.index
    start
    end
    (cat.str-cat
      (clone section.object)
      ": section "
      (string.int->string section.index)
      " .drectve bytes "
      (string.int->string start)
      ".."
      (string.int->string end)
      ": "
      detail)))

(define (byte-at [data : (& d (__tl_dyn-array u8))] [index : i64]) : i64
  (cast (array-ref data index) : i64))

(define (ws? [byte : i64]) : bool
  (or (= byte 32) (and (>= byte 9) (<= byte 13))))

(define (ascii-upper [byte : i64]) : i64
  (if (and (>= byte (cast 'a' : i64)) (<= byte (cast 'z' : i64)))
    (- byte 32)
    byte))

;; One scanned option token: its section-relative end, its text without quote
;; bytes, and the offset of the name/payload `:` in that text (or -1).
(defenum TokenScan
  (Scanned i64 String i64)
  (ScanFailed CoffDirectiveError))

(define (scan-token
  [section : (& s CoffDirectiveSection)]
  [data : (& d (__tl_dyn-array u8))]
  [base : i64]
  [size : i64]
  [token-start : i64]
  [bom : bool]
  [limits : (& l CoffDirectiveLimits)]) : TokenScan
  (let
    [text : bytes.ByteBufBuilder (bytes.byte-buf-builder-new)]
    [pos : i64 token-start]
    [colon : i64 -1]
    [quoted : bool false]
    [quote-start : i64 0]
    [previous : i64 -1]
    [done : bool false]
    [failure : TokenScan (TokenScan.Scanned 0 "" -1)]
    [failed : bool false]
    (begin
      (while (and (not done) (not failed) (< pos size))
        (let
          [byte : i64 (byte-at data (+ base pos))]
          (cond
            [(= byte 0)
              (begin
                (set! failed true)
                (set!
                  failure
                  (TokenScan.ScanFailed
                    (directive-error
                      section
                      (CoffDirectiveErrorKind.NulByte)
                      pos
                      (+ pos 1)
                      "NUL byte in directive text"))))]
            [(and (not quoted) (ws? byte)) (set! done true)]
            [(= byte (cast '"' : i64))
              (cond
                [(< colon 0)
                  (begin
                    (set! failed true)
                    (set!
                      failure
                      (TokenScan.ScanFailed
                        (directive-error
                          section
                          (CoffDirectiveErrorKind.QuotedOptionName)
                          token-start
                          (+ pos 1)
                          "quotes are only admitted in an option's payload"))))]
                [(or
                    (= previous (cast '\\' : i64))
                    (= previous (cast '"' : i64)))
                  (begin
                    (set! failed true)
                    (set!
                      failure
                      (TokenScan.ScanFailed
                        (directive-error
                          section
                          (CoffDirectiveErrorKind.AmbiguousQuote)
                          (- pos 1)
                          (+ pos 1)
                          "a quote after a backslash or another quote is an escape in Windows argument parsing and is not admitted"))))]
                [else
                  (begin
                    (unless quoted (set! quote-start pos))
                    (set! quoted (not quoted)))])]
            [(and (>= byte 128) (not bom))
              (begin
                (set! failed true)
                (set!
                  failure
                  (TokenScan.ScanFailed
                    (directive-error
                      section
                      (CoffDirectiveErrorKind.NonAsciiWithoutBom)
                      pos
                      (+ pos 1)
                      "non-ASCII byte without a UTF-8 BOM; host code page decoding is not admitted"))))]
            [else
              (begin
                (when
                  (and (< colon 0) (= byte (cast ':' : i64)))
                  (set! colon (bytes.byte-buf-builder-len (& text))))
                (bytes.byte-buf-builder-push (&mut text) (cast byte : u8)))])
          (unless
            (or done failed)
            (set! previous byte)
            (set! pos (+ pos 1))
            (when
              (> (- pos token-start) limits.max-token-bytes)
              (set! failed true)
              (set!
                failure
                (TokenScan.ScanFailed
                  (directive-error
                    section
                    (CoffDirectiveErrorKind.TokenTooLong)
                    token-start
                    pos
                    (cat.str-cat
                      "option exceeds "
                      (string.int->string limits.max-token-bytes)
                      " bytes"))))))))
      (cond
        [failed failure]
        [quoted
          (TokenScan.ScanFailed
            (directive-error
              section
              (CoffDirectiveErrorKind.UnterminatedQuote)
              quote-start
              pos
              "unterminated quote"))]
        [(and
            bom
            (not
              (binary.compiler-incremental-binary-utf8-range-valid?
                data
                (+ base token-start)
                (- pos token-start))))
          (TokenScan.ScanFailed
            (directive-error
              section
              (CoffDirectiveErrorKind.MalformedUtf8)
              token-start
              pos
              "malformed UTF-8"))]
        [else
          (TokenScan.Scanned
            pos
            (bytes.byte-buf-builder-to-string (& text))
            colon)]))))

(define (upper-range [text : (& t str)] [from : i64] [to : i64]) : String
  (let
    [out : bytes.ByteBufBuilder
      (bytes.byte-buf-builder-with-capacity (- to from))]
    [index : i64 from]
    (begin
      (while (< index to)
        (bytes.byte-buf-builder-push
          (&mut out)
          (cast (ascii-upper (cast (string.string-ref text index) : i64)) : u8))
        (set! index (+ index 1)))
      (bytes.byte-buf-builder-to-string (& out)))))

(define (admitted-directives) : String
  "admitted directives are /DEFAULTLIB, /NODEFAULTLIB, /INCLUDE, /EXPORT, /ALTERNATENAME, /FAILIFMISMATCH, /DELAYLOAD, /DELAY:UNLOAD and /DELAY:NOBIND; output, search paths, section layout and security policy come only from explicit link configuration")

(define (unsupported-category [upper : (& u str)]) : String
  (cond
    [(or (string.eq upper "MERGE") (string.eq upper "SECTION"))
      " (section layout)"]
    [(or
        (string.eq upper "OUT")
        (string.eq upper "DLL")
        (string.eq upper "IMPLIB")
        (string.eq upper "PDB")
        (string.eq upper "MAP")
        (string.eq upper "DEF"))
      " (output selection)"]
    [(string.eq upper "LIBPATH") " (library search path)"]
    [(or
        (string.eq upper "DYNAMICBASE")
        (string.eq upper "NXCOMPAT")
        (string.eq upper "SAFESEH")
        (string.eq upper "GUARD")
        (string.eq upper "HIGHENTROPYVA")
        (string.eq upper "CETCOMPAT")
        (string.eq upper "FORCE")
        (string.eq upper "INTEGRITYCHECK"))
      " (security policy)"]
    [else ""]))

(defenum OptionParse
  (Parsed CoffDirective)
  (Rejected CoffDirectiveErrorKind String))

(define (reject [kind : CoffDirectiveErrorKind] [detail : String]) : OptionParse
  (OptionParse.Rejected kind detail))

(define (require-payload
  [written : (& w str)]
  [payload : (& p str)]
  [present : bool]
  [directive : CoffDirective]) : OptionParse
  (cond
    [(not present)
      (reject
        (CoffDirectiveErrorKind.MissingPayload)
        (cat.str-cat "/" (string.copy written) " requires a `:` payload"))]
    [(= (string.string-length payload) 0)
      (reject
        (CoffDirectiveErrorKind.EmptyField)
        (cat.str-cat "/" (string.copy written) " has an empty payload"))]
    [else (OptionParse.Parsed directive)]))

;; Split `key=value` at the first `=`; both sides must be nonempty.
(define (pair-field
  [written : (& w str)]
  [payload : (& p str)]
  [present : bool]
  [alias : bool]) : OptionParse
  (let
    [equals : i64 (string.index-of-byte payload 0 (cast '=' : u8))]
    [length : i64 (string.string-length payload)]
    (cond
      [(not present)
        (reject
          (CoffDirectiveErrorKind.MissingPayload)
          (cat.str-cat "/" (string.copy written) " requires a `:` payload"))]
      [(< equals 0)
        (reject
          (CoffDirectiveErrorKind.MissingSeparator)
          (cat.str-cat "/" (string.copy written) " payload needs `=`"))]
      [(or (= equals 0) (= equals (- length 1)))
        (reject
          (CoffDirectiveErrorKind.EmptyField)
          (cat.str-cat "/" (string.copy written) " has an empty side of `=`"))]
      [else
        (let
          [left : String (string.substring payload 0 equals)]
          [right : String
            (string.substring payload (+ equals 1) (- length (+ equals 1)))]
          (OptionParse.Parsed
            (if alias
              (CoffDirective.AlternateName left right)
              (CoffDirective.FailIfMismatch left right))))])))

(define (path-bearing? [name : (& n str)]) : bool
  (or
    (string.contains-char name '/')
    (string.contains-char name '\\')
    (string.contains-char name ':')))

(define (delay-qualifier
  [written : (& w str)]
  [payload : (& p str)]
  [present : bool]) : OptionParse
  (let
    [qualifier : String (upper-range payload 0 (string.string-length payload))]
    (cond
      [(not present)
        (reject
          (CoffDirectiveErrorKind.MissingPayload)
          (cat.str-cat "/" (string.copy written) " requires :UNLOAD or :NOBIND"))]
      [(string.eq qualifier "UNLOAD")
        (OptionParse.Parsed (CoffDirective.DelayUnload))]
      [(string.eq qualifier "NOBIND")
        (OptionParse.Parsed (CoffDirective.DelayNoBind))]
      [else
        (reject
          (CoffDirectiveErrorKind.UnknownDelayQualifier)
          (cat.str-cat
            "/"
            (string.copy written)
            ":"
            (string.copy payload)
            " is not admitted; use UNLOAD or NOBIND"))])))

;; `text` is a scanned token without quote bytes; `colon` is its name/payload
;; separator or -1. Names are compared in ASCII upper case.
(define (parse-named-option [text : (& t str)] [colon : i64]) : OptionParse
  (let
    [length : i64 (string.string-length text)]
    [name-end : i64
      (if (< colon 0)
        length
        colon)]
    [present : bool (>= colon 0)]
    [payload : String
      (if present
        (string.substring text (+ colon 1) (- length (+ colon 1)))
        "")]
    [written : String (string.substring text 1 (- name-end 1))]
    [upper : String (upper-range text 1 name-end)]
    (cond
      [(= name-end 1)
        (reject (CoffDirectiveErrorKind.EmptyOptionName) "empty option name")]
      [(string.eq upper "DEFAULTLIB")
        (require-payload
          (& written)
          (& payload)
          present
          (CoffDirective.DefaultLib (clone payload)))]
      [(string.eq upper "INCLUDE")
        (require-payload
          (& written)
          (& payload)
          present
          (CoffDirective.Include (clone payload)))]
      [(string.eq upper "EXPORT")
        (require-payload
          (& written)
          (& payload)
          present
          (CoffDirective.Export (clone payload)))]
      [(string.eq upper "NODEFAULTLIB")
        (if present
          (require-payload
            (& written)
            (& payload)
            present
            (CoffDirective.NoDefaultLib (clone payload)))
          (OptionParse.Parsed (CoffDirective.NoDefaultLibAll)))]
      [(string.eq upper "ALTERNATENAME")
        (pair-field (& written) (& payload) present true)]
      [(string.eq upper "FAILIFMISMATCH")
        (pair-field (& written) (& payload) present false)]
      [(string.eq upper "DELAYLOAD")
        (if (and present (path-bearing? (& payload)))
          (reject
            (CoffDirectiveErrorKind.PathBearingDll)
            (cat.str-cat
              "/"
              (clone written)
              " names a path; only a DLL file name is admitted"))
          (require-payload
            (& written)
            (& payload)
            present
            (CoffDirective.DelayLoad (clone payload))))]
      [(string.eq upper "DELAY")
        (delay-qualifier (& written) (& payload) present)]
      [else
        (reject
          (CoffDirectiveErrorKind.UnsupportedOption)
          (cat.str-cat
            "linker directive /"
            (clone written)
            (unsupported-category (& upper))
            " is not admitted; "
            (admitted-directives)))])))

(define (parse-option [text : (& t str)] [colon : i64]) : OptionParse
  (let
    [first : i64 (cast (string.string-ref text 0) : i64)]
    (cond
      [(= first (cast '@' : i64))
        (reject
          (CoffDirectiveErrorKind.ResponseFile)
          "response files are not admitted in directives")]
      [(= first (cast '/' : i64)) (parse-named-option text colon)]
      [else
        (reject
          (CoffDirectiveErrorKind.NotAnOption)
          (cat.str-cat
            "expected an option starting with `/`"
            (if (= first (cast '-' : i64))
              "; the `-` spelling is not admitted"
              "")))])))

(define (read-options
  [section : (& s CoffDirectiveSection)]
  [data : (& d (__tl_dyn-array u8))]
  [base : i64]
  [size : i64]
  [limits : (& l CoffDirectiveLimits)]) : ResultCoffDirectives
  (let
    [bom : bool
      (and
        (>= size 3)
        (= (byte-at data base) 0xef)
        (= (byte-at data (+ base 1)) 0xbb)
        (= (byte-at data (+ base 2)) 0xbf))]
    [pos : i64
      (if bom
        3
        0)]
    [records : record_vec.Vec (record_vec.new)]
    [failure : CoffDirectiveError
      (directive-error section (CoffDirectiveErrorKind.InvalidRange) 0 0 "")]
    [failed : bool false]
    (begin
      (while (and (not failed) (< pos size))
        (if (ws? (byte-at data (+ base pos)))
          (set! pos (+ pos 1))
          (match (scan-token section data base size pos bom limits)
            [(TokenScan.ScanFailed error)
              (begin
                (set! failure error)
                (set! failed true))]
            [(TokenScan.Scanned end text colon)
              (cond
                [(>= records.len limits.max-options)
                  (begin
                    (set!
                      failure
                      (directive-error
                        section
                        (CoffDirectiveErrorKind.TooManyOptions)
                        pos
                        end
                        (cat.str-cat
                          "more than "
                          (string.int->string limits.max-options)
                          " options")))
                    (set! failed true))]
                [else
                  (match (parse-option (& text) colon)
                    [(OptionParse.Parsed directive)
                      (let
                        [spelling : bytes.ByteBufBuilder
                          (bytes.byte-buf-builder-with-capacity (- end pos))]
                        (begin
                          (bytes.byte-buf-builder-append-array-range
                            (&mut spelling)
                            data
                            (+ base pos)
                            (- end pos))
                          (record_vec.push-ref!
                            (&mut records)
                            (CoffDirectiveRecord
                              (clone section.object)
                              section.index
                              pos
                              end
                              (bytes.byte-buf-builder-to-string (& spelling))
                              directive))
                          (set! pos end)))]
                    [(OptionParse.Rejected kind detail)
                      (begin
                        (set!
                          failure
                          (directive-error section kind pos end detail))
                        (set! failed true))])])])))
      (if failed
        (ResultCoffDirectives.Err failure)
        (ResultCoffDirectives.Ok records)))))

;: Read the directives in `data[start, start + size)`, the raw data of
;: `section`. The caller's object reader has already bounds-checked the
;: section; the range is still checked here before any byte is read.
(define (read-directives
  [section : (& s CoffDirectiveSection)]
  [data : (& d (__tl_dyn-array u8))]
  [start : i64]
  [size : i64]
  [limits : (& l CoffDirectiveLimits)]) : ResultCoffDirectives
  (cond
    [(not (string.eq section.name ".drectve"))
      (ResultCoffDirectives.Err
        (directive-error
          section
          (CoffDirectiveErrorKind.NotDirectiveSection)
          0
          0
          (cat.str-cat "section `" (clone section.name) "` is not .drectve")))]
    [(= (bit-and section.characteristics 0x200) 0)
      (ResultCoffDirectives.Err
        (directive-error
          section
          (CoffDirectiveErrorKind.NotDirectiveSection)
          0
          0
          "section lacks IMAGE_SCN_LNK_INFO"))]
    [(!= section.relocations 0)
      (ResultCoffDirectives.Err
        (directive-error
          section
          (CoffDirectiveErrorKind.HasRelocations)
          0
          0
          "a directive section must have no relocations"))]
    [(!= section.line-numbers 0)
      (ResultCoffDirectives.Err
        (directive-error
          section
          (CoffDirectiveErrorKind.HasLineNumbers)
          0
          0
          "a directive section must have no line numbers"))]
    [(or
        (<= limits.max-bytes 0)
        (<= limits.max-options 0)
        (<= limits.max-token-bytes 0))
      (ResultCoffDirectives.Err
        (directive-error
          section
          (CoffDirectiveErrorKind.InvalidLimits)
          0
          0
          "directive limits must be positive"))]
    [(not
        (binary.compiler-incremental-binary-range-present?
          (array-length data)
          start
          size))
      (ResultCoffDirectives.Err
        (directive-error
          section
          (CoffDirectiveErrorKind.InvalidRange)
          0
          size
          "section data lies outside the object bytes"))]
    [(> size limits.max-bytes)
      (ResultCoffDirectives.Err
        (directive-error
          section
          (CoffDirectiveErrorKind.TooLarge)
          0
          size
          (cat.str-cat
            "section exceeds "
            (string.int->string limits.max-bytes)
            " bytes")))]
    [else (read-options section data start size limits)]))