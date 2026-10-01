;; Implicit linker-script subset conformance (#8303), discovered by inline-test
;; CI: the real profile scripts in tests/fixtures/linker-scripts/, then tables of
;; accepted and rejected sources.
(import linker_script_subset as script)
(import stdlib.byte_buf_core as bytes)
(import stdlib.io)
(import stdlib.str_cat_runtime as cat)
(import stdlib.string)

(include-bin
  glibc-libc
  "../tests/fixtures/linker-scripts/arch-glibc-2.44-libc.so")

(include-bin
  glibc-libm
  "../tests/fixtures/linker-scripts/arch-glibc-2.44-libm.so")

(include-bin
  libbsd
  "../tests/fixtures/linker-scripts/arch-libbsd-0.12.2-libbsd.so")

(include-bin
  libbfd
  "../tests/fixtures/linker-scripts/arch-binutils-2.47-libbfd.so")

(include-bin
  libncurses
  "../tests/fixtures/linker-scripts/arch-ncurses-6.6-libncurses.so")

(include-bin
  libtinfo
  "../tests/fixtures/linker-scripts/arch-ncurses-6.6-libtinfo.so")

(include-bin
  libncursespp
  "../tests/fixtures/linker-scripts/arch-ncurses-6.6-libncurses++.so")

(define (assert [condition : bool] [message : String]) : unit
  (unless condition (io.panic (cat.str-cat message "\n"))))

(define (bytes-of [text : String]) : (__tl_dyn-array u8)
  (let
    [out : bytes.ByteBufBuilder (bytes.byte-buf-builder-new)]
    (begin
      (bytes.byte-buf-builder-append-string (&mut out) text)
      (bytes.byte-buf-builder-to-array (& out)))))

(define (at [line : i64] [column : i64]) : String
  (cat.str-cat (string.int->string line) ":" (string.int->string column)))

;; One file: `?` marks AS_NEEDED, `-l` a library, quotes a quoted path.
(define (render-input [input : (& i script.LinkerScriptInput)]) : String
  (cat.str-cat
    (at input.line input.column)
    " "
    (if input.as-needed
      "?"
      "")
    (match input.kind
      [(script.LinkerScriptInputKind.Library) "-l"]
      [(script.LinkerScriptInputKind.Path) ""])
    (if input.quoted
      "\""
      "")
    (string.copy input.name)
    (if input.quoted
      "\""
      "")))

(define (render-files
  [read : (& r script.LinkerScript)]
  [first : i64]
  [count : i64]) : String
  (let
    [out : String "["]
    [index : i64 first]
    (begin
      (while (< index (+ first count))
        (begin
          (set!
            out
            (cat.str-cat
              out
              (if (> index first)
                ", "
                "")
              (render-input (& (array-ref read.inputs.slots index)))))
          (set! index (+ index 1))))
      (cat.str-cat out "]"))))

;; A read script as one line: `L:C COMMAND(...)` per command, joined by ` | `.
(define (render-script [read : (& r script.LinkerScript)]) : String
  (let
    [out : String ""]
    [index : i64 0]
    (begin
      (while (< index read.items.len)
        (let
          [item : (& r script.LinkerScriptItem)
            (& (array-ref read.items.slots index))]
          (begin
            (set!
              out
              (cat.str-cat
                out
                (if (> index 0)
                  " | "
                  "")
                (at item.line item.column)
                " "
                (match item.command
                  [(script.LinkerScriptCommand.OutputFormat name)
                    (cat.str-cat "OUTPUT_FORMAT(" (string.copy name) ")")]
                  [(script.LinkerScriptCommand.OutputFormatEndian
                      default
                      big
                      little)
                    (cat.str-cat
                      "OUTPUT_FORMAT("
                      (string.copy default)
                      ", "
                      (string.copy big)
                      ", "
                      (string.copy little)
                      ")")]
                  [(script.LinkerScriptCommand.Input first count)
                    (cat.str-cat "INPUT" (render-files read first count))]
                  [(script.LinkerScriptCommand.Group first count)
                    (cat.str-cat "GROUP" (render-files read first count))]
                  [(script.LinkerScriptCommand.SearchDir name)
                    (cat.str-cat "SEARCH_DIR(" (string.copy name) ")")])))
            (set! index (+ index 1)))))
      out)))

(define (kind-name [kind : (& k script.LinkerScriptErrorKind)]) : String
  (match kind
    [(script.LinkerScriptErrorKind.InvalidLimits) "InvalidLimits"]
    [(script.LinkerScriptErrorKind.TooLarge) "TooLarge"]
    [(script.LinkerScriptErrorKind.TooManyTokens) "TooManyTokens"]
    [(script.LinkerScriptErrorKind.TokenTooLong) "TokenTooLong"]
    [(script.LinkerScriptErrorKind.TooDeep) "TooDeep"]
    [(script.LinkerScriptErrorKind.NulByte) "NulByte"]
    [(script.LinkerScriptErrorKind.NonAscii) "NonAscii"]
    [(script.LinkerScriptErrorKind.ControlByte) "ControlByte"]
    [(script.LinkerScriptErrorKind.UnterminatedComment) "UnterminatedComment"]
    [(script.LinkerScriptErrorKind.UnterminatedQuote) "UnterminatedQuote"]
    [(script.LinkerScriptErrorKind.UnbalancedParen) "UnbalancedParen"]
    [(script.LinkerScriptErrorKind.UnsupportedCommand) "UnsupportedCommand"]
    [(script.LinkerScriptErrorKind.Assignment) "Assignment"]
    [(script.LinkerScriptErrorKind.Expression) "Expression"]
    [(script.LinkerScriptErrorKind.UnknownCommand) "UnknownCommand"]
    [(script.LinkerScriptErrorKind.UnexpectedToken) "UnexpectedToken"]
    [(script.LinkerScriptErrorKind.MissingParen) "MissingParen"]
    [(script.LinkerScriptErrorKind.EmptyArgument) "EmptyArgument"]
    [(script.LinkerScriptErrorKind.ArgumentCount) "ArgumentCount"]
    [(script.LinkerScriptErrorKind.EmptyLibrary) "EmptyLibrary"]
    [(script.LinkerScriptErrorKind.Option) "Option"]))

;; A result as one line: the script rendering, or `error KIND L:C | message`.
(define (render [result : script.ResultLinkerScript]) : String
  (match result
    [(script.ResultLinkerScript.Ok read) (render-script (& read))]
    [(script.ResultLinkerScript.Err error)
      (cat.str-cat
        "error "
        (kind-name (& error.kind))
        " "
        (at error.line error.column)
        " | "
        (string.copy error.message))]))

(define (read-with
  [data : (__tl_dyn-array u8)]
  [limits : script.LinkerScriptLimits]) : String
  (render (script.read-linker-script "t.ld" (& data) (& limits))))

(define (read-fixture [name : String] [data : (& d (__tl_dyn-array u8))]) : String
  (let
    [limits : script.LinkerScriptLimits (script.default-limits)]
    (render (script.read-linker-script name data (& limits)))))

(define (read-text [text : String]) : String
  (read-with (bytes-of text) (script.default-limits)))

(define (expect [got : String] [want : String] [label : String]) : unit
  (assert
    (string.eq got want)
    (cat.str-cat label ":\n  got:  " got "\n  want: " want)))

;; Only the `error KIND L:C` head of a rejection, so a case pins where and what
;; without restating the whole message.
(define (head [rendered : String]) : String
  (let
    [index : i64 0]
    [cut : i64 (string.string-length rendered)]
    (begin
      (while (< index (- (string.string-length rendered) 2))
        (begin
          (when
            (and
              (= cut (string.string-length rendered))
              (string.eq (string.substring rendered index 3) " | "))
            (set! cut index))
          (set! index (+ index 1))))
      (string.substring rendered 0 cut))))

(define (contains? [text : String] [needle : String]) : bool
  (let
    [index : i64 0]
    [found : bool false]
    [n : i64 (string.string-length needle)]
    (begin
      (while (and (not found) (<= (+ index n) (string.string-length text)))
        (begin
          (when
            (string.eq (string.substring text index n) needle)
            (set! found true))
          (set! index (+ index 1))))
      found)))

(define (expect-error [text : String] [want-head : String] [names : String]) : unit
  (let
    [got : String (read-text (string.copy text))]
    (begin
      (expect (head (string.copy got)) want-head (string.copy text))
      (assert
        (contains? (string.copy got) (string.copy names))
        (cat.str-cat text ": the message does not name `" names "`: " got)))))

(test
  linker-script-real-profile-scripts
  (begin
    (expect
      (read-fixture "libc.so" (& glibc-libc))
      "4:1 OUTPUT_FORMAT(elf64-x86-64) | 5:1 GROUP[5:9 /usr/lib/libc.so.6, 5:28 /usr/lib/libc_nonshared.a, 5:67 ?/usr/lib/ld-linux-x86-64.so.2]"
      "glibc libc.so")
    (expect
      (read-fixture "libm.so" (& glibc-libm))
      "3:1 OUTPUT_FORMAT(elf64-x86-64) | 4:1 GROUP[4:9 /usr/lib/libm.so.6, 4:41 ?/usr/lib/libmvec.so.1]"
      "glibc libm.so")
    (expect
      (read-fixture "libbsd.so" (& libbsd))
      "3:1 OUTPUT_FORMAT(elf64-x86-64) | 4:1 GROUP[4:7 /usr/lib/libbsd.so.0.12.2, 4:43 ?-lmd]"
      "libbsd.so")
    (expect
      (read-fixture "libbfd.so" (& libbfd))
      "3:1 INPUT[3:8 /usr/lib/libbfd.a, 3:26 -lsframe, 3:35 -liberty, 3:44 -lz, 3:48 -lzstd, 3:55 -ldl]"
      "binutils libbfd.so")
    (expect
      (read-fixture "libncurses.so" (& libncurses))
      "1:1 INPUT[1:7 -lncursesw]"
      "ncurses libncurses.so")
    (expect
      (read-fixture "libtinfo.so" (& libtinfo))
      "1:1 INPUT[1:7 libncursesw.so.6]"
      "ncurses libtinfo.so")
    (expect
      (read-fixture "libncurses++.so" (& libncursespp))
      "1:1 INPUT[1:7 -lncurses++w]"
      "ncurses libncurses++.so")))

(test
  linker-script-accepted-syntax
  (begin
    ;; The Debian/Ubuntu multiarch libc.so.
    (expect
      (read-text
        "/* GNU ld script\n   Use the shared library, but some functions are only in\n   the static library, so try that secondarily.  */\nOUTPUT_FORMAT(elf64-x86-64)\nGROUP ( /lib/x86_64-linux-gnu/libc.so.6 /usr/lib/x86_64-linux-gnu/libc_nonshared.a  AS_NEEDED ( /lib64/ld-linux-x86-64.so.2 ) )\n")
      "4:1 OUTPUT_FORMAT(elf64-x86-64) | 5:1 GROUP[5:9 /lib/x86_64-linux-gnu/libc.so.6, 5:41 /usr/lib/x86_64-linux-gnu/libc_nonshared.a, 5:97 ?/lib64/ld-linux-x86-64.so.2]"
      "multiarch libc.so")
    ;; Comments anywhere whitespace is admitted, including inside a list and
    ;; right against a name; commas and whitespace both separate files.
    (expect
      (read-text "INPUT(a,b c , d/*x*/e)/*\n*/GROUP(/* lead */ f\n,g)")
      "1:1 INPUT[1:7 a, 1:9 b, 1:11 c, 1:15 d, 1:21 e] | 2:3 GROUP[2:20 f, 3:2 g]"
      "comments and separators")
    ;; Quoted names keep spaces, commas and UTF-8, and are always paths.
    (expect
      (read-text "INPUT(\"/opt/my lib/libx.so\" \"-lnot\" \"/opt/é/a,b\")")
      "1:1 INPUT[1:7 \"/opt/my lib/libx.so\", 1:29 \"-lnot\", 1:37 \"/opt/é/a,b\"]"
      "quoted paths")
    (expect
      (read-text "OUTPUT_FORMAT(\"elf64-x86-64\", elf64-big , elf64-little)")
      "1:1 OUTPUT_FORMAT(elf64-x86-64, elf64-big, elf64-little)"
      "three-name OUTPUT_FORMAT")
    (expect
      (read-text "SEARCH_DIR(/usr/lib) SEARCH_DIR(\"=/usr/local/lib64\")")
      "1:1 SEARCH_DIR(/usr/lib) | 1:22 SEARCH_DIR(=/usr/local/lib64)"
      "SEARCH_DIR")
    ;; AS_NEEDED nested to the depth limit: the command's own parentheses are
    ;; depth 1, so three AS_NEEDED levels reach 4.
    (expect
      (read-text "GROUP(a AS_NEEDED(b AS_NEEDED(c AS_NEEDED(d) e) f) g)")
      "1:1 GROUP[1:7 a, 1:19 ?b, 1:31 ?c, 1:43 ?d, 1:46 ?e, 1:49 ?f, 1:52 g]"
      "nesting at the limit")
    (expect (read-text "") "" "empty script")
    (expect (read-text "  /* only a comment */\n\t\n") "" "comment-only script")))

(test
  linker-script-rejected-constructs
  (begin
    (expect-error
      "SECTIONS\n{\n  .text : { *(.text) }\n}"
      "error UnsupportedCommand 1:1"
      "SECTIONS")
    (expect-error "INCLUDE other.ld" "error UnsupportedCommand 1:1" "INCLUDE")
    (expect-error
      "GROUP(a) INSERT AFTER .text"
      "error UnsupportedCommand 1:10"
      "INSERT")
    (expect-error
      "MEMORY { ram : ORIGIN = 0, LENGTH = 4K }"
      "error UnsupportedCommand 1:1"
      "MEMORY")
    (expect-error
      "PHDRS { text PT_LOAD ; }"
      "error UnsupportedCommand 1:1"
      "PHDRS")
    (expect-error "PROVIDE(end = .);" "error UnsupportedCommand 1:1" "PROVIDE")
    (expect-error "ENTRY(_start)" "error UnsupportedCommand 1:1" "ENTRY")
    (expect-error "foo = 1;" "error Assignment 1:1" "foo")
    (expect-error "\n  . = ALIGN(4);" "error Assignment 2:3" ".")
    (expect-error "foo=bar+1;" "error Assignment 1:1" "foo=bar+1")
    (expect-error "INPUT(a)\nfoo += 4;" "error Assignment 2:1" "foo")
    (expect-error "end <<= 1;" "error Assignment 1:1" "end")
    (expect-error "ALIGN(4)" "error Expression 1:1" "ALIGN")
    (expect-error "SIZEOF(.text) > 0" "error Expression 1:1" "SIZEOF")
    (expect-error "GROUP(a) . + 4" "error Expression 1:10" ".")
    (expect-error "4096" "error Expression 1:1" "4096")
    (expect-error "FOO(bar)" "error UnknownCommand 1:1" "FOO")
    (expect-error "input(libc.so.6)" "error UnknownCommand 1:1" "input")
    (expect-error "INPUT(a) ;" "error UnexpectedToken 1:10" ";")
    (expect-error "INPUT(a ; b)" "error UnexpectedToken 1:9" ";")
    (expect-error "INPUT(a { b })" "error UnexpectedToken 1:9" "{")
    (expect-error "AS_NEEDED(a)" "error UnexpectedToken 1:1" "AS_NEEDED")
    (expect-error "GROUP a" "error MissingParen 1:1" "GROUP")
    (expect-error "GROUP(a AS_NEEDED b)" "error MissingParen 1:9" "AS_NEEDED")
    (expect-error "INPUT(a\n/* c */" "error UnbalancedParen 1:7" "`)`")
    (expect-error "INPUT(a) )" "error UnbalancedParen 1:10" ")")
    (expect-error "INPUT(a (b))" "error UnbalancedParen 1:9" "(")
    (expect-error
      "GROUP(AS_NEEDED(AS_NEEDED(AS_NEEDED(AS_NEEDED(x)))))"
      "error TooDeep 1:37"
      "AS_NEEDED")
    (expect-error
      "INPUT(a) /* open\n"
      "error UnterminatedComment 1:10"
      "comment")
    (expect-error "INPUT(\"/a b)" "error UnterminatedQuote 1:7" "quote")
    (expect-error "INPUT(\"/a\nb\")" "error UnterminatedQuote 1:7" "quote")
    (expect-error "INPUT()" "error EmptyArgument 1:7" "empty")
    (expect-error "INPUT(a,,b)" "error EmptyArgument 1:9" "empty")
    (expect-error "INPUT(,a)" "error EmptyArgument 1:7" "empty")
    (expect-error "INPUT(\"\")" "error EmptyArgument 1:7" "empty")
    (expect-error "INPUT(-l)" "error EmptyLibrary 1:7" "-l")
    (expect-error "INPUT(-Bstatic -lc)" "error Option 1:7" "-Bstatic")
    (expect-error "OUTPUT_FORMAT(a, b)" "error ArgumentCount 1:1" "two")
    (expect-error
      "OUTPUT_FORMAT(a b)"
      "error ArgumentCount 1:17"
      "OUTPUT_FORMAT")
    (expect-error
      "OUTPUT_FORMAT(a, b, c, d)"
      "error ArgumentCount 1:22"
      "OUTPUT_FORMAT")
    (expect-error "SEARCH_DIR(a, b)" "error ArgumentCount 1:13" "SEARCH_DIR")
    (expect-error "SEARCH_DIR()" "error ArgumentCount 1:12" "SEARCH_DIR")
    (expect-error "INPUT(café.so)" "error NonAscii 1:10" "non-ASCII")
    (let
      [control : (__tl_dyn-array u8) (bytes-of "INPUT(ab)")]
      (begin
        (set! (array-ref control 7) (cast 1 : u8))
        (expect
          (head (read-with control (script.default-limits)))
          "error ControlByte 1:8"
          "control byte")))))

(test
  linker-script-byte-level-and-limits
  (let
    [nul : (__tl_dyn-array u8) (bytes-of "INPUT(ab)")]
    (begin
      (set! (array-ref nul 7) (cast 0 : u8))
      (expect
        (head (read-with nul (script.default-limits)))
        "error NulByte 1:8"
        "NUL")
      (expect
        (head
          (read-with
            (bytes-of "INPUT(a)\n")
            (script.LinkerScriptLimits 8 100 100 4)))
        "error TooLarge 1:1"
        "byte limit")
      (expect
        (head
          (read-with
            (bytes-of "INPUT(a b)")
            (script.LinkerScriptLimits 100 4 100 4)))
        "error TooManyTokens 1:10"
        "token limit")
      (expect
        (head
          (read-with
            (bytes-of "INPUT(abcde)")
            (script.LinkerScriptLimits 100 100 5 4)))
        "1:1 INPUT[1:7 abcde]"
        "a name at the token length limit")
      (expect
        (head
          (read-with
            (bytes-of "INPUT(abcdef)")
            (script.LinkerScriptLimits 100 100 5 4)))
        "error TokenTooLong 1:7"
        "token length limit")
      (expect
        (head
          (read-with
            (bytes-of "INPUT(\"abcdef\")")
            (script.LinkerScriptLimits 100 100 5 4)))
        "error TokenTooLong 1:7"
        "quoted token length limit")
      (expect
        (head
          (read-with
            (bytes-of "GROUP(AS_NEEDED(x))")
            (script.LinkerScriptLimits 100 100 100 1)))
        "error TooDeep 1:7"
        "depth limit")
      (expect
        (head
          (read-with (bytes-of "INPUT(a)") (script.LinkerScriptLimits 0 1 1 1)))
        "error InvalidLimits 0:0"
        "invalid limits"))))