;# Rust-style literal formatting for Strings and direct writer sinks.
;#
;# `format` parses a string-literal template during macro expansion. It supports
;# implicit `{}`, indexed `{0}`, explicit named, and call-site-captured `{name}`
;# selections; escapes use `{{` / `}}`. Format specifications share one parsed
;# plan supporting byte fill, alignment, sign, alternate/zero flags, width, and
;# literal/dollar/star precision counts. The generated expression evaluates
;# each supplied value once and uses one flat `str-cat` expansion. Nonnumeric
;# Display precision truncates rendered TypeLisp bytes before padding; float
;# precision selects exact fixed decimal with round-half-to-even. Fixed-width
;# integers additionally support binary, octal, and lower/uppercase hexadecimal
;# selectors with width-correct signed bit patterns. The `e` and `E` selectors
;# normalize every integer and source-width float to Rust exponent notation;
;# their precision counts digits after the leading digit.
;# `args` retains that plan with borrow-checked anchors for later replay without
;# constructing the final combined String. `format` materializes retained
;# Arguments, while `write!` and `writeln!` replay them through the same
;# canonical destination adapters and return `FormatResult`.
;#
;# Nominal structs and enums participate through their canonical owner module.
;# A module's common primary type defines `to-string`; additional nominal types
;# use `to-string-<NominalName>`. A hook must have the exact shared-borrow
;# signature `(& T) -> String`. For allocation-free default Display output it
;# may instead define `format-write` (or `format-write-<NominalName>`) with
;# signature `(& T, &mut Formatter) -> unit`. Every String/writer/stdio target
;# uses that direct hook; option-bearing placeholders fall back to `to-string`
;# so the shared option engine can transform the complete rendered value.
;# Defining both applicable spellings in either hook family is ambiguous.
;#
;# ```lisp test=run name=format-basic exit=42 stdout=""
;# (import stdlib.format)
;# (import stdlib.string)
;#
;# (define (main) : i64
;#   (let [name : String "Ada"]
;#     (if (string.eq (format.format "hello, {}" name) "hello, Ada") 42 1)))
;# ```
;#
;# ```lisp test=run name=format-retained-arguments exit=42 stdout=""
;# (import stdlib.format)
;# (import stdlib.string)
;#
;# (define (main) : i64
;#   (let
;#     [name : String "Ada"]
;#     [arguments (format.args "hello, {}" name)]
;#     (if (string.eq (format.format arguments) "hello, Ada") 42 1)))
;# ```
;#
;# Builtin placeholder values are `String`, all eight fixed-width integer
;# types, `bool`, `char`, `f64`, and `f32`. The `e`/`E` selectors accept every
;# integer and float type. The `p` selector additionally accepts raw pointers
;# in an unsafe call-site context. Structural formatting is intentionally
;# separate from this default Display-style protocol.
(import stdlib.comptime)
(import stdlib.str_cat)
(import stdlib.string)

;: Runtime panic entry used by formatting without depending on `stdlib.io`.
;:
;: `tl_abort_string` accepts the same two-word string handle for owned `String`
;: and borrowed `str`; this declaration intentionally takes the owned form so
;: importing formatting does not introduce reference-typed runtime ABI state.
(extern (format-runtime-abort-string [message : String]) : never (:symbol "tl_abort_string"))

;: Render one supported ASCII/control character as a String for formatting.
(define (format-char-string [value : char]) : String
  (let
    [code : i64 (cast value : i64)]
    [printable : String
      " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"]
    (cond
      [(= code 9) "\t"]
      [(= code 10) "\n"]
      [(= code 13) "\r"]
      [(and (>= code 32) (<= code 126))
        (string.substring printable (- code 32) 1)]
      [else
        (format-runtime-abort-string "format: unsupported non-printable char")])))

;: Classify one byte for delimiter-aware Debug escaping.
;:
;: Class 0 is literal, 1..6 are NUL/tab/LF/CR/backslash/active-delimiter,
;: and 7 is fixed-width hexadecimal. Keeping this decision in one function
;: makes the count and write passes use exactly the same escape policy.
(define (format-debug-byte-class [byte : u8] [delimiter : u8]) : i64
  (let
    [code : i64 (cast byte : i64)]
    (cond
      [(= code 0) 1]
      [(= code 9) 2]
      [(= code 10) 3]
      [(= code 13) 4]
      [(= code 92) 5]
      [(= byte delimiter) 6]
      [(and (>= code 32) (<= code 126)) 0]
      [else 7])))

;: Return the byte width of one classified Debug escape.
(define (format-debug-byte-width [escape-class : i64]) : i64
  (if (= escape-class 0)
    1
    (if (= escape-class 7)
      4
      2)))

;: Add one escape width while keeping output length in signed-i64 range.
(define (format-debug-checked-length-add [current : i64] [amount : i64]) : i64
  (if (> current (- 9223372036854775807 amount))
    (format-runtime-abort-string "format: Debug output length overflow")
    (+ current amount)))

;: Read either a raw range byte or the inline byte used by the char wrapper.
(define (format-debug-source-byte
  [source : (Ptr u8)]
  [index : i64]
  [single-byte : u8]
  [single-byte-source? : bool]) : u8
  (if single-byte-source?
    single-byte
    (unsafe
      (ptr-read (ptr-offset source index)))))

;: Count the exact quoted Debug output before allocation or destination writes.
(define (format-debug-rendered-length
  [source : (Ptr u8)]
  [source-len : i64]
  [single-byte : u8]
  [single-byte-source? : bool]
  [delimiter : u8]) : i64
  (let
    [index : i64 0]
    [output-len : i64 2]
    (begin
      (while (< index source-len)
        (let
          [byte : u8
            (format-debug-source-byte
              source
              index
              single-byte
              single-byte-source?)]
          [escape-class : i64 (format-debug-byte-class byte delimiter)]
          (begin
            (set!
              output-len
              (format-debug-checked-length-add
                output-len
                (format-debug-byte-width escape-class)))
            (set! index (+ index 1)))))
      output-len)))

;: Convert one four-bit value to a lowercase ASCII hexadecimal digit.
(define (format-debug-hex-digit [value : i64]) : u8
  (cast
    (if (< value 10)
      (+ 48 value)
      (+ 87 value))
    : u8))

;: Write one byte into a caller-validated Debug destination range.
(define (format-debug-write-code!
  [dst : (MutPtr u8)]
  [offset : i64]
  [byte : u8]) : unit
  (unsafe
    (ptr-write! (ptr-offset dst offset) byte)))

;: Write one classified Debug byte and return the next destination cursor.
(define (format-debug-write-byte!
  [dst : (MutPtr u8)]
  [cursor : i64]
  [byte : u8]
  [escape-class : i64]) : i64
  (begin
    (if (= escape-class 0)
      (format-debug-write-code! dst cursor byte)
      (begin
        (format-debug-write-code! dst cursor (cast 92 : u8))
        (match escape-class
          [1 (format-debug-write-code! dst (+ cursor 1) (cast 48 : u8))]
          [2 (format-debug-write-code! dst (+ cursor 1) (cast 116 : u8))]
          [3 (format-debug-write-code! dst (+ cursor 1) (cast 110 : u8))]
          [4 (format-debug-write-code! dst (+ cursor 1) (cast 114 : u8))]
          [5 (format-debug-write-code! dst (+ cursor 1) (cast 92 : u8))]
          [6 (format-debug-write-code! dst (+ cursor 1) byte)]
          [_
            (begin
              (format-debug-write-code! dst (+ cursor 1) (cast 120 : u8))
              (format-debug-write-code!
                dst
                (+ cursor 2)
                (format-debug-hex-digit (/ (cast byte : i64) 16)))
              (format-debug-write-code!
                dst
                (+ cursor 3)
                (format-debug-hex-digit (% (cast byte : i64) 16))))])))
    (+ cursor (format-debug-byte-width escape-class))))

;: Render a byte range with one active quote delimiter.
;:
;: The count pass completes, including every checked length addition, before
;: allocation or destination derivation. The write pass then fills exactly one
;: fresh String allocation without constructing per-byte chunk Strings.
(define (format-debug-bytes-core
  [source : (Ptr u8)]
  [source-len : i64]
  [single-byte : u8]
  [single-byte-source? : bool]
  [delimiter : u8]) : String
  (let
    [output-len : i64
      (format-debug-rendered-length
        source
        source-len
        single-byte
        single-byte-source?
        delimiter)]
    [dst : (MutPtr u8) (string.string-runtime-alloc output-len)]
    [index : i64 0]
    [cursor : i64 1]
    (begin
      (format-debug-write-code! dst 0 delimiter)
      (while (< index source-len)
        (let
          [byte : u8
            (format-debug-source-byte
              source
              index
              single-byte
              single-byte-source?)]
          [escape-class : i64 (format-debug-byte-class byte delimiter)]
          (begin
            (set!
              cursor
              (format-debug-write-byte! dst cursor byte escape-class))
            (set! index (+ index 1)))))
      (format-debug-write-code! dst cursor delimiter)
      (unsafe
        (string-from-bytes (ptr-cast dst : (Ptr u8)) output-len)))))

;: Render owned String or borrowed str bytes as double-quoted Debug text.
(define (format-debug-string-core [value : (& value str)]) : String
  (format-debug-bytes-core
    (unsafe
      (string-data value))
    (string.string-length value)
    (cast 0 : u8)
    false
    (cast 34 : u8)))

;: Render one byte-oriented char as single-quoted Debug text.
(define (format-debug-char-core [value : char]) : String
  (format-debug-bytes-core
    (ptr-null : (Ptr u8))
    1
    (cast value : u8)
    true
    (cast 39 : u8)))

;: Common runtime formatting options produced by the literal template plan.
;:
;: Alignment uses `0` for the value category's default, `1` for left, `2` for
;: center, and `3` for right. Sign uses `0` for absent, `1` for `+`, and `2` for
;: Rust's currently unused `-` spelling. Width and fill count TypeLisp bytes,
;: not Unicode scalars or terminal columns. `alternate` is retained for the
;: type-specific formatter siblings even where default Display ignores it.
;: Precision is resolved before this shared transport: `precision-present`
;: distinguishes an omitted count from an explicit zero.
(defstruct FormatOptions
  (fill char)
  (alignment i64)
  (sign i64)
  (alternate bool)
  (sign-aware-zero-pad bool)
  (width i64)
  (precision-present bool)
  (precision i64))

;: Result of streaming one immutable format plan into a destination.
;:
;: Formatting itself is deterministic and infallible apart from language
;: traps/allocation failure. `FormatErr` therefore carries only a destination
;: write status. Once a formatter observes an error, later writes are skipped
;: and the first status is retained.
(defenum FormatResult
  (FormatOk)
  (FormatErr i64))

;: Raw destination callback used by `Formatter`.
;:
;: The callback receives its adapter context, a byte pointer valid for the
;: duration of the call, and a byte length. Zero means success; every nonzero
;: value is a destination error. The raw ABI keeps `stdlib.format` independent
;: of `stdlib.io` and concrete buffer modules.
(defstruct Formatter
  (write-raw (-> i64 (Ptr u8) i64 i64))
  (context i64)
  (status i64))

;; Private growable destination used only when retained Arguments are
;; materialized as a String. The public Arguments package itself contains only
;; a capture-free renderer and a tuple of shared anchors.
(defstruct ArgumentsStringSink
  (slots (__tl_dyn-array u8))
  (len i64))

;; Copy bytes into the growable String sink addressed by `context`.
(define (arguments-string-write-raw
  [context : i64]
  [data : (Ptr u8)]
  [count : i64]) : i64
  (if (<= count 0)
    0
    (let
      [slot : (MutPtr ArgumentsStringSink)
        (unsafe
          (int->ptr (cast context : u64) : (MutPtr ArgumentsStringSink)))]
      [sink : ArgumentsStringSink
        (unsafe
          (ptr-read (ptr-cast slot : (Ptr ArgumentsStringSink))))]
      [required : i64
        (if (> sink.len (- 9223372036854775807 count))
          (format-runtime-abort-string
            "format: Arguments output length overflow")
          (+ sink.len count))]
      (begin
        (if (> required (array-length sink.slots))
          (let
            [old-capacity : i64 (array-length sink.slots)]
            [new-capacity : i64
              (if (< old-capacity 1)
                64
                old-capacity)]
            (begin
              (while (< new-capacity required)
                (if (> new-capacity (/ 9223372036854775807 2))
                  (set! new-capacity required)
                  (set! new-capacity (* new-capacity 2))))
              (let
                [larger : (__tl_dyn-array u8) (__tl_make-array u8 new-capacity)]
                (begin
                  (if (> sink.len 0)
                    (string.str-copy-bytes-into
                      (unsafe
                        (ptr-cast (__tl_array-data sink.slots) : (Ptr u8)))
                      (unsafe
                        (__tl_array-data larger))
                      0
                      sink.len)
                    unit)
                  (set! sink.slots larger)))))
          unit)
        (string.str-copy-bytes-into
          data
          (unsafe
            (__tl_array-data sink.slots))
          sink.len
          count)
        (set! sink.len required)
        (unsafe
          (ptr-write! slot sink))
        0))))

;: Construct a formatter backed by one concrete destination adapter.
(define (formatter-writer
  [context : i64]
  [write-raw : (-> i64 (Ptr u8) i64 i64)]) : Formatter
  (Formatter write-raw context 0))

;: Place one formatter in fixed caller-owned storage for synchronous writes.
(define (formatter-cell [formatter : Formatter]) : (Array Formatter 1)
  (array formatter))

;: Signature probe used for canonical writer-adapter reflection.
(define (formatter-unreachable-write-raw
  [_context : i64]
  [_data : (Ptr u8)]
  [_len : i64]) : i64
  1)

;: Write one raw byte range, preserving the first destination failure.
(define (formatter-write-raw!
  [formatter : (&mut formatter Formatter)]
  [data : (Ptr u8)]
  [len : i64]) : unit
  (if (<= len 0)
    unit
    (if (!= formatter.status 0)
      unit
      (let
        [status : i64 (formatter.write-raw formatter.context data len)]
        (if (= status 0)
          unit
          (set! formatter.status status))))))

;: Write one rendered String without constructing a combined output String.
(define (formatter-write-string!
  [formatter : (&mut formatter Formatter)]
  [text : String]) : unit
  (formatter-write-raw!
    formatter
    (unsafe
      (string-data (& text)))
    (string.string-length (& text))))

;: Return the current formatter result.
(define (formatter-result [formatter : (& formatter Formatter)]) : FormatResult
  (if (= formatter.status 0)
    (FormatOk)
    (FormatErr formatter.status)))

;: Write through the Formatter stored at a caller-owned stack-cell address.
;:
;: Writer macros use this opaque scalar address for their synchronous
;: caller-owned Formatter cell and recover the updated value afterward.
(define (formatter-write-string-at! [address : i64] [text : String]) : unit
  (let
    [slot : (MutPtr Formatter)
      (unsafe
        (int->ptr (cast address : u64) : (MutPtr Formatter)))]
    [formatter : Formatter
      (unsafe
        (ptr-read (ptr-cast slot : (Ptr Formatter))))]
    (begin
      (formatter-write-string! (&mut formatter) text)
      (unsafe
        (ptr-write! slot formatter)))))

;: Read the result of the Formatter stored at `address`.
(define (formatter-result-at [address : i64]) : FormatResult
  (let
    [slot : (Ptr Formatter)
      (unsafe
        (int->ptr (cast address : u64) : (Ptr Formatter)))]
    [formatter : Formatter
      (unsafe
        (ptr-read slot))]
    (formatter-result (& formatter))))

;: Read the raw destination status stored at `address`.
;:
;: Immediate streaming plans return this scalar status before the public macro
;: converts it to `FormatResult`.
(define (formatter-status-at [address : i64]) : i64
  (let
    [slot : (Ptr Formatter)
      (unsafe
        (int->ptr (cast address : u64) : (Ptr Formatter)))]
    [formatter : Formatter
      (unsafe
        (ptr-read slot))]
    formatter.status))

;: Validate one runtime-provided width before allocation or arithmetic.
(define (format-width-count-runtime [count : i64]) : i64
  (if (< count 0)
    (format-runtime-abort-string
      "format: dynamic width argument must be nonnegative")
    count))

;: Validate one runtime-provided precision before rendering or allocation.
(define (format-precision-count-runtime [count : i64]) : i64
  (if (< count 0)
    (format-runtime-abort-string "format: precision count must be nonnegative")
    count))

;: Fill a caller-validated live destination byte range.
;:
;: The caller must guarantee that `[start, start + count)` is in bounds for
;: `dst`; this helper performs no independent allocation or range check.
(define (format-write-fill!
  [dst : (MutPtr u8)]
  [start : i64]
  [count : i64]
  [fill : char]) : unit
  (let
    [index : i64 0]
    [byte : u8 (cast fill : u8)]
    (while (< index count)
      (begin
        (unsafe
          (ptr-write! (ptr-offset dst (+ start index)) byte))
        (set! index (+ index 1))))))

;: Copy between caller-validated live source and destination byte ranges.
;:
;: The caller must guarantee that both ranges are in bounds. A zero-byte copy
;: does not derive a source pointer, which keeps empty rendered values valid.
(define (format-copy-rendered-range!
  [rendered : (& rendered str)]
  [source-start : i64]
  [dst : (MutPtr u8)]
  [destination-start : i64]
  [count : i64]) : unit
  (if (= count 0)
    unit
    (let
      [source : (Ptr u8)
        (unsafe
          (ptr-offset (string-data rendered) source-start))]
      (string.str-copy-bytes-into source dst destination-start count))))

;: Resolve the byte length visible to shared Display padding.
;:
;: Numeric renderers own their precision semantics, so this shared fallback
;: truncates only nonnumeric output. TypeLisp text and `char` are byte-oriented:
;: the precision boundary neither decodes nor validates UTF-8.
(define (format-rendered-display-length
  [rendered-len : i64]
  [numeric? : bool]
  [options : FormatOptions]) : i64
  (if (if numeric?
    false
    (if options.precision-present
      (< options.precision rendered-len)
      false))
    options.precision
    rendered-len))

;: Apply shared Display precision, byte width, alignment, sign, and zero padding.
;:
;: The value renderer has already chosen Display/type-specific text. Padding
;: therefore follows nonnumeric byte truncation and composes with owner-module
;: `to-string`. Numeric zero padding keeps a leading sign and a
;: `0x`/`0X`/`0o`/`0b` prefix before the inserted zeroes.
(define (format-apply-options
  [rendered : String]
  [numeric? : bool]
  [options : FormatOptions]) : String
  (let
    [rendered-len : i64 (string.string-length (& rendered))]
    [display-len : i64
      (format-rendered-display-length rendered-len numeric? options)]
    [source-sign-len : i64
      (if (if numeric?
        (> rendered-len 0)
        false)
        (if (= (cast (string.string-ref (& rendered) 0) : i64) 45)
          1
          0)
        0)]
    [source-nan? : bool
      (if (and numeric? (= rendered-len 3))
        (and
          (= (cast (string.string-ref (& rendered) 0) : i64) 78)
          (= (cast (string.string-ref (& rendered) 1) : i64) 97)
          (= (cast (string.string-ref (& rendered) 2) : i64) 78))
        false)]
    [add-plus? : bool
      (if (if numeric?
        (= options.sign 1)
        false)
        (and (= source-sign-len 0) (not source-nan?))
        false)]
    [output-sign-len : i64
      (if (or add-plus? (= source-sign-len 1))
        1
        0)]
    [prefix-len : i64 0]
    (begin
      (if (if numeric?
        (>= (- rendered-len source-sign-len) 2)
        false)
        (let
          [first : i64
            (cast (string.string-ref (& rendered) source-sign-len) : i64)]
          [second : i64
            (cast (string.string-ref (& rendered) (+ source-sign-len 1)) : i64)]
          (if (if (= first 48)
            (or (= second 120) (= second 88) (= second 111) (= second 98))
            false)
            (set! prefix-len 2)
            unit))
        unit)
      (let
        [content-len : i64 (+ (- display-len source-sign-len) output-sign-len)]
        [output-len : i64
          (if (> options.width content-len)
            options.width
            content-len)]
        [padding : i64 (- output-len content-len)]
        (if (and (= display-len rendered-len) (= padding 0) (not add-plus?))
          rendered
          (let
            [dst : (MutPtr u8) (string.string-runtime-alloc output-len)]
            [zero-pad? : bool
              (if numeric?
                options.sign-aware-zero-pad
                false)]
            (begin
              (if zero-pad?
                (let
                  [cursor : i64 0]
                  (begin
                    (if (= output-sign-len 1)
                      (begin
                        (unsafe
                          (ptr-write!
                            dst
                            (cast
                              (if add-plus?
                                43
                                45)
                              : u8)))
                        (set! cursor 1))
                      unit)
                    (format-copy-rendered-range!
                      (& rendered)
                      source-sign-len
                      dst
                      cursor
                      prefix-len)
                    (set! cursor (+ cursor prefix-len))
                    (format-write-fill! dst cursor padding '0')
                    (set! cursor (+ cursor padding))
                    (format-copy-rendered-range!
                      (& rendered)
                      (+ source-sign-len prefix-len)
                      dst
                      cursor
                      (- rendered-len (+ source-sign-len prefix-len)))))
                (let
                  [alignment : i64
                    (if (= options.alignment 0)
                      (if numeric?
                        3
                        1)
                      options.alignment)]
                  [left-padding : i64
                    (match alignment
                      [1 0]
                      [2 (/ padding 2)]
                      [_ padding])]
                  [right-padding : i64 (- padding left-padding)]
                  [cursor : i64 left-padding]
                  (begin
                    (format-write-fill! dst 0 left-padding options.fill)
                    (if (= output-sign-len 1)
                      (begin
                        (unsafe
                          (ptr-write!
                            (ptr-offset dst cursor)
                            (cast
                              (if add-plus?
                                43
                                45)
                              : u8)))
                        (set! cursor (+ cursor 1)))
                      unit)
                    (format-copy-rendered-range!
                      (& rendered)
                      source-sign-len
                      dst
                      cursor
                      (- display-len source-sign-len))
                    (format-write-fill!
                      dst
                      (- output-len right-padding)
                      right-padding
                      options.fill))))
              (unsafe
                (string-from-bytes (ptr-cast dst : (Ptr u8)) output-len)))))))))

;; The deterministic pure-TypeLisp f64 renderer is defined below the template
;; parser. Keeping it in this module makes `stdlib.format` independent of I/O.
;: Render one supported format placeholder through the shared dispatch path.
(defmacro (format-value-resolved
  [value-type-expr : type]
  [value : comptime.Expr]
  [fill-expr : comptime.Expr]
  [alignment-expr : comptime.Expr]
  [sign-expr : comptime.Expr]
  [alternate-expr : comptime.Expr]
  [zero-expr : comptime.Expr]
  [width-kind-expr : comptime.Expr]
  [width-type-source : type]
  [width-value : comptime.Expr]
  [precision-kind-expr : comptime.Expr]
  [precision-type-source : type]
  [precision-value : comptime.Expr]
  [selector-expr : comptime.Expr]) : String
  (match fill-expr
    [(comptime.Expr.Int fill-code)
      (match alignment-expr
        [(comptime.Expr.Int alignment)
          (match sign-expr
            [(comptime.Expr.Int sign)
              (match alternate-expr
                [(comptime.Expr.Int alternate)
                  (match zero-expr
                    [(comptime.Expr.Int zero)
                      (match width-kind-expr
                        [(comptime.Expr.Int width-kind)
                          (match precision-kind-expr
                            [(comptime.Expr.Int precision-kind)
                              (let
                                [selector : String
                                  (comptime.expr-string-value selector-expr)]
                                [argument-type : comptime.Expr value-type-expr]
                                [argument-kind : String
                                  (type-kind argument-type)]
                                [borrowed? : bool
                                  (if (string.eq argument-kind "ref")
                                    true
                                    (string.eq argument-kind "mut-ref"))]
                                [value-type : comptime.Expr
                                  (if borrowed?
                                    (comptime.reference-element-type
                                      argument-type)
                                    argument-type)]
                                [raw-value-kind : String (type-kind value-type)]
                                [arguments? : bool
                                  (if (string.eq raw-value-kind "tuple")
                                    (if (= (tuple-element-count value-type) 2)
                                      (if (string.eq
                                        (type-kind
                                          (tuple-element-type value-type 0))
                                        "function")
                                        (string.eq
                                          (type-kind
                                            (tuple-element-type value-type 1))
                                          "tuple")
                                        false)
                                      false)
                                    false)]
                                [value-kind : String
                                  (if arguments?
                                    "arguments"
                                    raw-value-kind)]
                                [radix-selector? : bool
                                  (match selector
                                    ["b" true]
                                    ["o" true]
                                    ["x" true]
                                    ["X" true]
                                    [_ false])]
                                [pointer-selector? : bool
                                  (string.eq selector "p")]
                                [exponent-selector? : bool
                                  (if (string.eq selector "e")
                                    true
                                    (string.eq selector "E"))]
                                [uppercase-exponent? : bool
                                  (string.eq selector "E")]
                                [uppercase-exponent-expr : comptime.Expr
                                  (comptime.expr-bool uppercase-exponent?)]
                                [special-selector? : bool
                                  (if radix-selector?
                                    true
                                    (if pointer-selector?
                                      true
                                      exponent-selector?))]
                                [raw-pointer? : bool
                                  (if (string.eq value-kind "ptr")
                                    true
                                    (string.eq value-kind "mut-ptr"))]
                                [supported-pointer-argument? : bool
                                  (if raw-pointer?
                                    (if borrowed?
                                      (string.eq argument-kind "ref")
                                      true)
                                    false)]
                                [nominal? : bool
                                  (match value-kind
                                    ["struct" true]
                                    ["enum" true]
                                    ["region" true]
                                    [_ false])]
                                [value-key : String (type-key value-type)]
                                ;; Ownership-safe macro capture presents a
                                ;; non-place string expression as a shared
                                ;; borrow of its temporary `str` payload. Keep
                                ;; selector diagnostics at the source-level
                                ;; value type rather than exposing that
                                ;; generated capture owner.
                                [diagnostic-value-key : String
                                  (if (string.eq value-kind "str")
                                    "String"
                                    value-key)]
                                [owner : String
                                  (if nominal?
                                    (type-nominal-module value-type)
                                    "")]
                                [nominal-name : String
                                  (if nominal?
                                    (type-nominal-name value-type)
                                    "")]
                                [plain-name : String "to-string"]
                                [qualified-name : String
                                  (comptime.string-append
                                    "to-string-"
                                    nominal-name)]
                                [plain-present? : bool
                                  (if nominal?
                                    (comptime.module-value? owner plain-name)
                                    false)]
                                [qualified-present? : bool
                                  (if nominal?
                                    (comptime.module-value?
                                      owner
                                      qualified-name)
                                    false)]
                                [direct-plain-name : String "format-write"]
                                [direct-qualified-name : String
                                  (comptime.string-append
                                    "format-write-"
                                    nominal-name)]
                                [direct-plain-present? : bool
                                  (if nominal?
                                    (comptime.module-value?
                                      owner
                                      direct-plain-name)
                                    false)]
                                [direct-qualified-present? : bool
                                  (if nominal?
                                    (comptime.module-value?
                                      owner
                                      direct-qualified-name)
                                    false)]
                                [direct-hook-dispatch : i64
                                  (+
                                    (if direct-plain-present?
                                      1
                                      0)
                                    (if direct-qualified-present?
                                      2
                                      0))]
                                [direct-hook-present? : bool
                                  (if direct-plain-present?
                                    true
                                    direct-qualified-present?)]
                                [default-options? : bool
                                  (if (= fill-code 32)
                                    (if (= alignment 0)
                                      (if (= sign 0)
                                        (if (= alternate 0)
                                          (if (= zero 0)
                                            (if (= width-kind 0)
                                              (if (= precision-kind 0)
                                                (string.eq selector "")
                                                false)
                                              false)
                                            false)
                                          false)
                                        false)
                                      false)
                                    false)]
                                [plain-contract : String
                                  (comptime.string-append
                                    owner
                                    (comptime.string-append
                                      ".to-string : (-> (& "
                                      (comptime.string-append
                                        value-key
                                        ") String)")))]
                                [qualified-contract : String
                                  (comptime.string-append
                                    owner
                                    (comptime.string-append
                                      "."
                                      (comptime.string-append
                                        qualified-name
                                        (comptime.string-append
                                          " : (-> (& "
                                          (comptime.string-append
                                            value-key
                                            ") String)")))))]
                                [expected-contract : String
                                  (comptime.string-append
                                    plain-contract
                                    (comptime.string-append
                                      " or "
                                      qualified-contract))]
                                [plain-matches? : bool
                                  (if plain-present?
                                    (comptime.function-shared-borrow-returns-string?
                                      (comptime.module-value-type
                                        owner
                                        plain-name)
                                      value-type)
                                    false)]
                                [qualified-matches? : bool
                                  (if qualified-present?
                                    (comptime.function-shared-borrow-returns-string?
                                      (comptime.module-value-type
                                        owner
                                        qualified-name)
                                      value-type)
                                    false)]
                                [hook-dispatch : i64
                                  (if special-selector?
                                    4
                                    (+
                                      (if plain-matches?
                                        1
                                        0)
                                      (if qualified-matches?
                                        2
                                        0)))]
                                [hook-present? : bool
                                  (if plain-present?
                                    true
                                    qualified-present?)]
                                [integral? : bool
                                  (match value-kind
                                    ["i8" true]
                                    ["i16" true]
                                    ["i32" true]
                                    ["i64" true]
                                    ["u8" true]
                                    ["u16" true]
                                    ["u32" true]
                                    ["u64" true]
                                    [_ false])]
                                [float? : bool
                                  (match value-kind
                                    ["f64" true]
                                    ["f32" true]
                                    [_ false])]
                                [numeric? : bool
                                  (if integral?
                                    true
                                    (if float?
                                      true
                                      pointer-selector?))]
                                [use-direct-hook? : bool
                                  (if nominal?
                                    (if default-options?
                                      direct-hook-present?
                                      false)
                                    false)]
                                [direct-rendered : comptime.Expr
                                  (match direct-hook-dispatch
                                    [1
                                      `(stdlib.format.format-direct-hook-materialize
                                        ,(comptime.type-expr argument-type)
                                        ,value
                                        ,(comptime.module-value-expr
                                          owner
                                          direct-plain-name))]
                                    [2
                                      `(stdlib.format.format-direct-hook-materialize
                                        ,(comptime.type-expr argument-type)
                                        ,value
                                        ,(comptime.module-value-expr
                                          owner
                                          direct-qualified-name))]
                                    [3
                                      (comptime.comptime-error
                                        (comptime.string-append
                                          "format: ambiguous direct Formatter hooks for "
                                          (comptime.string-append
                                            value-key
                                            (comptime.string-append
                                              " in canonical module "
                                              owner))))]
                                    [_ (comptime.expr-string "")])]
                                [display-rendered : comptime.Expr
                                  (if nominal?
                                    (if use-direct-hook?
                                      direct-rendered
                                      (match hook-dispatch
                                        [4 (comptime.expr-string "")]
                                        [3
                                          (comptime.comptime-error
                                            (comptime.string-append
                                              "format: ambiguous owner hooks for "
                                              (comptime.string-append
                                                value-key
                                                (comptime.string-append
                                                  " in canonical module "
                                                  (comptime.string-append
                                                    owner
                                                    (comptime.string-append
                                                      "; define only one of "
                                                      expected-contract))))))]
                                        [1
                                          (if borrowed?
                                            `(,(comptime.module-value-expr
                                                owner
                                                plain-name)
                                              ,value)
                                            (comptime.expr-shared-call1
                                              (comptime.module-value-expr
                                                owner
                                                plain-name)
                                              value))]
                                        [2
                                          (if borrowed?
                                            `(,(comptime.module-value-expr
                                                owner
                                                qualified-name)
                                              ,value)
                                            (comptime.expr-shared-call1
                                              (comptime.module-value-expr
                                                owner
                                                qualified-name)
                                              value))]
                                        [_
                                          (if hook-present?
                                            (comptime.comptime-error
                                              (comptime.string-append
                                                "format: owner hook has wrong signature for "
                                                (comptime.string-append
                                                  value-key
                                                  (comptime.string-append
                                                    " in canonical module "
                                                    (comptime.string-append
                                                      owner
                                                      (comptime.string-append
                                                        "; expected "
                                                        expected-contract))))))
                                            (comptime.comptime-error
                                              (comptime.string-append
                                                "format: unsupported nominal type "
                                                (comptime.string-append
                                                  value-key
                                                  (comptime.string-append
                                                    " from canonical owner module "
                                                    (comptime.string-append
                                                      owner
                                                      (comptime.string-append
                                                        "; expected "
                                                        expected-contract)))))))]))
                                    (match value-kind
                                      ["string"
                                        (if borrowed?
                                          `(stdlib.string.copy ,value)
                                          value)]
                                      ["str" `(stdlib.string.copy ,value)]
                                      ["i8"
                                        (if borrowed?
                                          `(stdlib.string.int->string
                                            (cast (deref ,value) : i64))
                                          `(stdlib.string.int->string
                                            (cast ,value : i64)))]
                                      ["i16"
                                        (if borrowed?
                                          `(stdlib.string.int->string
                                            (cast (deref ,value) : i64))
                                          `(stdlib.string.int->string
                                            (cast ,value : i64)))]
                                      ["i32"
                                        (if borrowed?
                                          `(stdlib.string.int->string
                                            (cast (deref ,value) : i64))
                                          `(stdlib.string.int->string
                                            (cast ,value : i64)))]
                                      ["i64"
                                        (if borrowed?
                                          `(stdlib.string.int->string
                                            (deref ,value))
                                          `(stdlib.string.int->string ,value))]
                                      ["u8"
                                        (if borrowed?
                                          `(stdlib.format.format-u64-core
                                            (cast (deref ,value) : u64))
                                          `(stdlib.format.format-u64-core
                                            (cast ,value : u64)))]
                                      ["u16"
                                        (if borrowed?
                                          `(stdlib.format.format-u64-core
                                            (cast (deref ,value) : u64))
                                          `(stdlib.format.format-u64-core
                                            (cast ,value : u64)))]
                                      ["u32"
                                        (if borrowed?
                                          `(stdlib.format.format-u64-core
                                            (cast (deref ,value) : u64))
                                          `(stdlib.format.format-u64-core
                                            (cast ,value : u64)))]
                                      ["u64"
                                        (if borrowed?
                                          `(stdlib.format.format-u64-core
                                            (deref ,value))
                                          `(stdlib.format.format-u64-core
                                            ,value))]
                                      ["bool"
                                        (if borrowed?
                                          `(if (deref ,value)
                                            "true"
                                            "false")
                                          `(if ,value
                                            "true"
                                            "false"))]
                                      ["char"
                                        (if borrowed?
                                          `(stdlib.format.format-char-string
                                            (deref ,value))
                                          `(stdlib.format.format-char-string
                                            ,value))]
                                      ["f64"
                                        (if borrowed?
                                          `(stdlib.format.format-float-core
                                            (deref ,value))
                                          `(stdlib.format.format-float-core
                                            ,value))]
                                      ["f32"
                                        (if borrowed?
                                          `(stdlib.format.format-f32-core
                                            (deref ,value))
                                          `(stdlib.format.format-f32-core
                                            ,value))]
                                      ["arguments"
                                        (if borrowed?
                                          `(stdlib.format.format-arguments-materialize
                                            (deref ,value))
                                          `(stdlib.format.format-arguments-materialize
                                            ,value))]
                                      ["ptr"
                                        (if special-selector?
                                          (comptime.expr-string "")
                                          (comptime.comptime-error
                                            (comptime.string-append
                                              "format: unsupported argument type "
                                              value-key)))]
                                      ["mut-ptr"
                                        (if special-selector?
                                          (comptime.expr-string "")
                                          (comptime.comptime-error
                                            (comptime.string-append
                                              "format: unsupported argument type "
                                              value-key)))]
                                      [_
                                        (if special-selector?
                                          (comptime.expr-string "")
                                          (comptime.comptime-error
                                            (comptime.string-append
                                              "format: unsupported argument type "
                                              value-key)))]))]
                                [radix-value : comptime.Expr
                                  (match value-kind
                                    ["i8"
                                      (if borrowed?
                                        `(cast (cast (deref ,value) : u8) : u64)
                                        `(cast (cast ,value : u8) : u64))]
                                    ["i16"
                                      (if borrowed?
                                        `(cast
                                          (cast (deref ,value) : u16)
                                          : u64)
                                        `(cast (cast ,value : u16) : u64))]
                                    ["i32"
                                      (if borrowed?
                                        `(cast
                                          (cast (deref ,value) : u32)
                                          : u64)
                                        `(cast (cast ,value : u32) : u64))]
                                    ["i64"
                                      (if borrowed?
                                        `(cast (deref ,value) : u64)
                                        `(cast ,value : u64))]
                                    ["u8"
                                      (if borrowed?
                                        `(cast (deref ,value) : u64)
                                        `(cast ,value : u64))]
                                    ["u16"
                                      (if borrowed?
                                        `(cast (deref ,value) : u64)
                                        `(cast ,value : u64))]
                                    ["u32"
                                      (if borrowed?
                                        `(cast (deref ,value) : u64)
                                        `(cast ,value : u64))]
                                    ["u64"
                                      (if borrowed?
                                        `(deref ,value)
                                        value)]
                                    [_ (comptime.expr-int 0)])]
                                [radix-shift : i64
                                  (match selector
                                    ["b" 1]
                                    ["o" 3]
                                    [_ 4])]
                                [radix-uppercase : i64
                                  (if (string.eq selector "X")
                                    1
                                    0)]
                                [rendered
                                  : comptime.Expr
                                  ;; CTFE evaluates this selector ladder before
                                  ;; syntax macros such as `cond` are available.
                                  ;; lint-allow: nested-if-ladder
                                  (if radix-selector?
                                    (if integral?
                                      `(stdlib.format.format-u64-radix-core
                                        ,radix-value
                                        ,(comptime.expr-int radix-shift)
                                        (!=
                                          ,(comptime.expr-int radix-uppercase)
                                          0)
                                        (!= ,alternate-expr 0))
                                      (comptime.comptime-error
                                        (comptime.string-append
                                          "format: radix selector '"
                                          (comptime.string-append
                                            selector
                                            (comptime.string-append
                                              "' requires a fixed-width integer argument; got "
                                              (type-key argument-type))))))
                                    (if pointer-selector?
                                      (if supported-pointer-argument?
                                        (if borrowed?
                                          `(stdlib.format.format-pointer-core
                                            (ptr->int (deref ,value)))
                                          `(stdlib.format.format-pointer-core
                                            (ptr->int ,value)))
                                        (comptime.comptime-error
                                          (comptime.string-append
                                            "format: 'p' selector requires (Ptr T), (MutPtr T), or a shared borrow of a raw-pointer value; got "
                                            (type-key argument-type))))
                                      (if exponent-selector?
                                        (comptime.expr-string "")
                                        display-rendered)))]
                                (begin
                                  (if exponent-selector?
                                    (if (if integral?
                                      true
                                      float?)
                                      unit
                                      (comptime.comptime-error
                                        (comptime.string-append
                                          (comptime.string-append
                                            "format: '"
                                            selector)
                                          (comptime.string-append
                                            "' selector requires an integer or float argument; got "
                                            diagnostic-value-key))))
                                    unit)
                                  (if (string.eq selector "")
                                    unit
                                    (if special-selector?
                                      unit
                                      (comptime.comptime-error
                                        (comptime.string-append
                                          "format: type selector is parsed but not supported yet: "
                                          selector))))
                                  (if (= sign 1)
                                    (if numeric?
                                      unit
                                      (comptime.comptime-error
                                        "format: '+' sign requires a numeric argument"))
                                    unit)
                                  (let
                                    [resolved-width : comptime.Expr
                                      (if (= width-kind 0)
                                        (comptime.expr-int 0)
                                        (if (= width-kind 1)
                                          width-value
                                          (let
                                            [count-type : comptime.Expr
                                              width-type-source]
                                            [count-kind : String
                                              (type-kind count-type)]
                                            (if (string.eq count-kind "i64")
                                              `(stdlib.format.format-width-count-runtime
                                                ,width-value)
                                              (if (if (string.eq
                                                count-kind
                                                "ref")
                                                (string.eq
                                                  (type-kind
                                                    (comptime.reference-element-type
                                                      count-type))
                                                  "i64")
                                                (if (string.eq
                                                  count-kind
                                                  "mut-ref")
                                                  (string.eq
                                                    (type-kind
                                                      (comptime.reference-element-type
                                                        count-type))
                                                    "i64")
                                                  false))
                                                `(stdlib.format.format-width-count-runtime
                                                  (deref ,width-value))
                                                (comptime.comptime-error
                                                  "format: dynamic width argument must have exact type i64"))))))]
                                    [resolved-precision : comptime.Expr
                                      (if (= precision-kind 0)
                                        (comptime.expr-int 0)
                                        (if (= precision-kind 1)
                                          precision-value
                                          (let
                                            [count-type : comptime.Expr
                                              precision-type-source]
                                            [count-kind : String
                                              (type-kind count-type)]
                                            (if (string.eq count-kind "i64")
                                              `(stdlib.format.format-precision-count-runtime
                                                ,precision-value)
                                              (if (if (string.eq
                                                count-kind
                                                "ref")
                                                (string.eq
                                                  (type-kind
                                                    (comptime.reference-element-type
                                                      count-type))
                                                  "i64")
                                                (if (string.eq
                                                  count-kind
                                                  "mut-ref")
                                                  (string.eq
                                                    (type-kind
                                                      (comptime.reference-element-type
                                                        count-type))
                                                    "i64")
                                                  false))
                                                `(stdlib.format.format-precision-count-runtime
                                                  (deref ,precision-value))
                                                (comptime.comptime-error
                                                  "format: dynamic precision argument must have exact type i64"))))))]
                                    [precision-applies? : bool
                                      (if (= precision-kind 0)
                                        false
                                        (if exponent-selector?
                                          true
                                          (not
                                            (if integral?
                                              true
                                              pointer-selector?))))]
                                    [default-options? : bool
                                      (if (= fill-code 32)
                                        (if (= alignment 0)
                                          (if (= sign 0)
                                            (if (= alternate 0)
                                              (if (= zero 0)
                                                (if (= width-kind 0)
                                                  (not precision-applies?)
                                                  false)
                                                false)
                                              false)
                                            false)
                                          false)
                                        false)]
                                    [width-runtime? : bool (> width-kind 1)]
                                    [precision-runtime? : bool
                                      (> precision-kind 1)]
                                    [width-name : String
                                      (comptime.syntax-name-fresh
                                        "__tl_format_resolved_width")]
                                    [precision-name : String
                                      (comptime.syntax-name-fresh
                                        "__tl_format_resolved_precision")]
                                    [width-var : comptime.Expr
                                      (comptime.expr-var width-name)]
                                    [precision-var : comptime.Expr
                                      (comptime.expr-var precision-name)]
                                    [transported-width : comptime.Expr
                                      (if width-runtime?
                                        width-var
                                        resolved-width)]
                                    [pointer-alternate? : bool
                                      (if pointer-selector?
                                        (= alternate 1)
                                        false)]
                                    [effective-width : comptime.Expr
                                      (if pointer-alternate?
                                        (if (= width-kind 0)
                                          (comptime.expr-int 18)
                                          transported-width)
                                        transported-width)]
                                    [effective-zero : comptime.Expr
                                      (if pointer-alternate?
                                        (comptime.expr-int 1)
                                        zero-expr)]
                                    [transported-precision : comptime.Expr
                                      (if precision-runtime?
                                        precision-var
                                        resolved-precision)]
                                    [rendered-with-precision : comptime.Expr
                                      (if exponent-selector?
                                        (match value-kind
                                          ["i8"
                                            (if borrowed?
                                              `(stdlib.format.format-i64-exponent-core
                                                (cast (deref ,value) : i64)
                                                (!= ,precision-kind-expr 0)
                                                ,transported-precision
                                                ,uppercase-exponent-expr)
                                              `(stdlib.format.format-i64-exponent-core
                                                (cast ,value : i64)
                                                (!= ,precision-kind-expr 0)
                                                ,transported-precision
                                                ,uppercase-exponent-expr))]
                                          ["i16"
                                            (if borrowed?
                                              `(stdlib.format.format-i64-exponent-core
                                                (cast (deref ,value) : i64)
                                                (!= ,precision-kind-expr 0)
                                                ,transported-precision
                                                ,uppercase-exponent-expr)
                                              `(stdlib.format.format-i64-exponent-core
                                                (cast ,value : i64)
                                                (!= ,precision-kind-expr 0)
                                                ,transported-precision
                                                ,uppercase-exponent-expr))]
                                          ["i32"
                                            (if borrowed?
                                              `(stdlib.format.format-i64-exponent-core
                                                (cast (deref ,value) : i64)
                                                (!= ,precision-kind-expr 0)
                                                ,transported-precision
                                                ,uppercase-exponent-expr)
                                              `(stdlib.format.format-i64-exponent-core
                                                (cast ,value : i64)
                                                (!= ,precision-kind-expr 0)
                                                ,transported-precision
                                                ,uppercase-exponent-expr))]
                                          ["i64"
                                            (if borrowed?
                                              `(stdlib.format.format-i64-exponent-core
                                                (deref ,value)
                                                (!= ,precision-kind-expr 0)
                                                ,transported-precision
                                                ,uppercase-exponent-expr)
                                              `(stdlib.format.format-i64-exponent-core
                                                ,value
                                                (!= ,precision-kind-expr 0)
                                                ,transported-precision
                                                ,uppercase-exponent-expr))]
                                          ["u8"
                                            (if borrowed?
                                              `(stdlib.format.format-u64-exponent-core
                                                (cast (deref ,value) : u64)
                                                (!= ,precision-kind-expr 0)
                                                ,transported-precision
                                                ,uppercase-exponent-expr)
                                              `(stdlib.format.format-u64-exponent-core
                                                (cast ,value : u64)
                                                (!= ,precision-kind-expr 0)
                                                ,transported-precision
                                                ,uppercase-exponent-expr))]
                                          ["u16"
                                            (if borrowed?
                                              `(stdlib.format.format-u64-exponent-core
                                                (cast (deref ,value) : u64)
                                                (!= ,precision-kind-expr 0)
                                                ,transported-precision
                                                ,uppercase-exponent-expr)
                                              `(stdlib.format.format-u64-exponent-core
                                                (cast ,value : u64)
                                                (!= ,precision-kind-expr 0)
                                                ,transported-precision
                                                ,uppercase-exponent-expr))]
                                          ["u32"
                                            (if borrowed?
                                              `(stdlib.format.format-u64-exponent-core
                                                (cast (deref ,value) : u64)
                                                (!= ,precision-kind-expr 0)
                                                ,transported-precision
                                                ,uppercase-exponent-expr)
                                              `(stdlib.format.format-u64-exponent-core
                                                (cast ,value : u64)
                                                (!= ,precision-kind-expr 0)
                                                ,transported-precision
                                                ,uppercase-exponent-expr))]
                                          ["u64"
                                            (if borrowed?
                                              `(stdlib.format.format-u64-exponent-core
                                                (deref ,value)
                                                (!= ,precision-kind-expr 0)
                                                ,transported-precision
                                                ,uppercase-exponent-expr)
                                              `(stdlib.format.format-u64-exponent-core
                                                ,value
                                                (!= ,precision-kind-expr 0)
                                                ,transported-precision
                                                ,uppercase-exponent-expr))]
                                          ["f64"
                                            (if borrowed?
                                              `(stdlib.format.format-float-exponent-core
                                                (deref ,value)
                                                (!= ,precision-kind-expr 0)
                                                ,transported-precision
                                                ,uppercase-exponent-expr)
                                              `(stdlib.format.format-float-exponent-core
                                                ,value
                                                (!= ,precision-kind-expr 0)
                                                ,transported-precision
                                                ,uppercase-exponent-expr))]
                                          ["f32"
                                            (if borrowed?
                                              `(stdlib.format.format-f32-exponent-core
                                                (deref ,value)
                                                (!= ,precision-kind-expr 0)
                                                ,transported-precision
                                                ,uppercase-exponent-expr)
                                              `(stdlib.format.format-f32-exponent-core
                                                ,value
                                                (!= ,precision-kind-expr 0)
                                                ,transported-precision
                                                ,uppercase-exponent-expr))]
                                          [_ rendered])
                                        (if (if float?
                                          (!= precision-kind 0)
                                          false)
                                          (match value-kind
                                            ["f64"
                                              (if borrowed?
                                                `(stdlib.format.format-float-fixed-core
                                                  (deref ,value)
                                                  ,transported-precision)
                                                `(stdlib.format.format-float-fixed-core
                                                  ,value
                                                  ,transported-precision))]
                                            ["f32"
                                              (if borrowed?
                                                `(stdlib.format.format-f32-fixed-core
                                                  (deref ,value)
                                                  ,transported-precision)
                                                `(stdlib.format.format-f32-fixed-core
                                                  ,value
                                                  ,transported-precision))]
                                            [_ rendered])
                                          rendered))]
                                    [formatted : comptime.Expr
                                      (if default-options?
                                        rendered-with-precision
                                        (if numeric?
                                          `(stdlib.format.format-apply-options
                                            ,rendered-with-precision
                                            true
                                            (stdlib.format.FormatOptions
                                              (cast ,fill-expr : char)
                                              ,alignment-expr
                                              ,sign-expr
                                              (!= ,alternate-expr 0)
                                              (!= ,effective-zero 0)
                                              ,effective-width
                                              (!= ,precision-kind-expr 0)
                                              ,transported-precision))
                                          `(stdlib.format.format-apply-options
                                            ,rendered-with-precision
                                            false
                                            (stdlib.format.FormatOptions
                                              (cast ,fill-expr : char)
                                              ,alignment-expr
                                              ,sign-expr
                                              (!= ,alternate-expr 0)
                                              (!= ,effective-zero 0)
                                              ,effective-width
                                              (!= ,precision-kind-expr 0)
                                              ,transported-precision))))]
                                    [precision-checked : comptime.Expr
                                      (if precision-runtime?
                                        (comptime.expr-let-scope
                                          precision-name
                                          resolved-precision
                                          formatted)
                                        formatted)]
                                    (if width-runtime?
                                      (comptime.expr-let-scope
                                        width-name
                                        resolved-width
                                        precision-checked)
                                      precision-checked))))]
                            [_
                              (comptime.comptime-error
                                "format: internal precision option is malformed")])]
                        [_
                          (comptime.comptime-error
                            "format: internal width option is malformed")])]
                    [_
                      (comptime.comptime-error
                        "format: internal zero option is malformed")])]
                [_
                  (comptime.comptime-error
                    "format: internal alternate option is malformed")])]
            [_
              (comptime.comptime-error
                "format: internal sign option is malformed")])]
        [_
          (comptime.comptime-error
            "format: internal alignment option is malformed")])]
    [_ (comptime.comptime-error "format: internal fill option is malformed")]))

;; Finish a classified value/count triplet by invoking one central terminal.
;; `prefix` is empty for String materialization and carries the formatter
;; address for streaming. All three source types are preserved by retained
;; renderer markers instead of being re-reflected from generated syntax.
(defmacro (format-classified-call
  [terminal : comptime.Expr]
  [prefix : comptime.Expr]
  [value-source : type]
  [value-runtime : comptime.Expr]
  [width-source : type]
  [width-runtime : comptime.Expr]
  [precision-source : type]
  [precision-runtime : comptime.Expr]
  [fill-expr : comptime.Expr]
  [alignment-expr : comptime.Expr]
  [sign-expr : comptime.Expr]
  [alternate-expr : comptime.Expr]
  [zero-expr : comptime.Expr]
  [width-kind-expr : comptime.Expr]
  [precision-kind-expr : comptime.Expr]
  [selector-expr : comptime.Expr]) : String
  (match prefix
    [(comptime.Expr.Call _ prefix-items)
      `(,terminal
        ,(comptime.type-expr value-source)
        ,@prefix-items
        ,value-runtime
        ,fill-expr
        ,alignment-expr
        ,sign-expr
        ,alternate-expr
        ,zero-expr
        ,width-kind-expr
        ,(comptime.type-expr width-source)
        ,width-runtime
        ,precision-kind-expr
        ,(comptime.type-expr precision-source)
        ,precision-runtime
        ,selector-expr)]
    [_
      (comptime.comptime-error "format: internal terminal prefix is malformed")]))

(defmacro (format-classify-precision
  [terminal : comptime.Expr]
  [prefix : comptime.Expr]
  [value-source : type]
  [value-runtime : comptime.Expr]
  [width-source : type]
  [width-runtime : comptime.Expr]
  [precision-value : comptime.Expr]
  [fill-expr : comptime.Expr]
  [alignment-expr : comptime.Expr]
  [sign-expr : comptime.Expr]
  [alternate-expr : comptime.Expr]
  [zero-expr : comptime.Expr]
  [width-kind-expr : comptime.Expr]
  [precision-kind-expr : comptime.Expr]
  [selector-expr : comptime.Expr]) : String
  (match precision-value
    [(comptime.Expr.Call callee items)
      (if (= (comptime.expr-list-length items) 3)
        (match callee
          [(comptime.Expr.Var name)
            (if (string.eq name "__tl_format_typed_argument")
              `(stdlib.format.format-classified-call
                ,terminal
                ,prefix
                ,(comptime.type-expr value-source)
                ,value-runtime
                ,(comptime.type-expr width-source)
                ,width-runtime
                ,(comptime.expr-list-nth items 0)
                ,(comptime.expr-list-nth items 2)
                ,fill-expr
                ,alignment-expr
                ,sign-expr
                ,alternate-expr
                ,zero-expr
                ,width-kind-expr
                ,precision-kind-expr
                ,selector-expr)
              `(stdlib.format.format-classified-call
                ,terminal
                ,prefix
                ,(comptime.type-expr value-source)
                ,value-runtime
                ,(comptime.type-expr width-source)
                ,width-runtime
                ,(comptime.type-expr (comptime.expr-type precision-value))
                ,precision-value
                ,fill-expr
                ,alignment-expr
                ,sign-expr
                ,alternate-expr
                ,zero-expr
                ,width-kind-expr
                ,precision-kind-expr
                ,selector-expr))]
          [_
            `(stdlib.format.format-classified-call
              ,terminal
              ,prefix
              ,(comptime.type-expr value-source)
              ,value-runtime
              ,(comptime.type-expr width-source)
              ,width-runtime
              ,(comptime.type-expr (comptime.expr-type precision-value))
              ,precision-value
              ,fill-expr
              ,alignment-expr
              ,sign-expr
              ,alternate-expr
              ,zero-expr
              ,width-kind-expr
              ,precision-kind-expr
              ,selector-expr)])
        `(stdlib.format.format-classified-call
          ,terminal
          ,prefix
          ,(comptime.type-expr value-source)
          ,value-runtime
          ,(comptime.type-expr width-source)
          ,width-runtime
          ,(comptime.type-expr (comptime.expr-type precision-value))
          ,precision-value
          ,fill-expr
          ,alignment-expr
          ,sign-expr
          ,alternate-expr
          ,zero-expr
          ,width-kind-expr
          ,precision-kind-expr
          ,selector-expr))]
    [_
      `(stdlib.format.format-classified-call
        ,terminal
        ,prefix
        ,(comptime.type-expr value-source)
        ,value-runtime
        ,(comptime.type-expr width-source)
        ,width-runtime
        ,(comptime.type-expr (comptime.expr-type precision-value))
        ,precision-value
        ,fill-expr
        ,alignment-expr
        ,sign-expr
        ,alternate-expr
        ,zero-expr
        ,width-kind-expr
        ,precision-kind-expr
        ,selector-expr)]))

(defmacro (format-classify-width
  [terminal : comptime.Expr]
  [prefix : comptime.Expr]
  [value-source : type]
  [value-runtime : comptime.Expr]
  [width-value : comptime.Expr]
  [precision-value : comptime.Expr]
  [fill-expr : comptime.Expr]
  [alignment-expr : comptime.Expr]
  [sign-expr : comptime.Expr]
  [alternate-expr : comptime.Expr]
  [zero-expr : comptime.Expr]
  [width-kind-expr : comptime.Expr]
  [precision-kind-expr : comptime.Expr]
  [selector-expr : comptime.Expr]) : String
  (match width-value
    [(comptime.Expr.Call callee items)
      (if (= (comptime.expr-list-length items) 3)
        (match callee
          [(comptime.Expr.Var name)
            (if (string.eq name "__tl_format_typed_argument")
              `(stdlib.format.format-classify-precision
                ,terminal
                ,prefix
                ,(comptime.type-expr value-source)
                ,value-runtime
                ,(comptime.expr-list-nth items 0)
                ,(comptime.expr-list-nth items 2)
                ,precision-value
                ,fill-expr
                ,alignment-expr
                ,sign-expr
                ,alternate-expr
                ,zero-expr
                ,width-kind-expr
                ,precision-kind-expr
                ,selector-expr)
              `(stdlib.format.format-classify-precision
                ,terminal
                ,prefix
                ,(comptime.type-expr value-source)
                ,value-runtime
                ,(comptime.type-expr (comptime.expr-type width-value))
                ,width-value
                ,precision-value
                ,fill-expr
                ,alignment-expr
                ,sign-expr
                ,alternate-expr
                ,zero-expr
                ,width-kind-expr
                ,precision-kind-expr
                ,selector-expr))]
          [_
            `(stdlib.format.format-classify-precision
              ,terminal
              ,prefix
              ,(comptime.type-expr value-source)
              ,value-runtime
              ,(comptime.type-expr (comptime.expr-type width-value))
              ,width-value
              ,precision-value
              ,fill-expr
              ,alignment-expr
              ,sign-expr
              ,alternate-expr
              ,zero-expr
              ,width-kind-expr
              ,precision-kind-expr
              ,selector-expr)])
        `(stdlib.format.format-classify-precision
          ,terminal
          ,prefix
          ,(comptime.type-expr value-source)
          ,value-runtime
          ,(comptime.type-expr (comptime.expr-type width-value))
          ,width-value
          ,precision-value
          ,fill-expr
          ,alignment-expr
          ,sign-expr
          ,alternate-expr
          ,zero-expr
          ,width-kind-expr
          ,precision-kind-expr
          ,selector-expr))]
    [_
      `(stdlib.format.format-classify-precision
        ,terminal
        ,prefix
        ,(comptime.type-expr value-source)
        ,value-runtime
        ,(comptime.type-expr (comptime.expr-type width-value))
        ,width-value
        ,precision-value
        ,fill-expr
        ,alignment-expr
        ,sign-expr
        ,alternate-expr
        ,zero-expr
        ,width-kind-expr
        ,precision-kind-expr
        ,selector-expr)]))

(defmacro (format-classify-value
  [terminal : comptime.Expr]
  [prefix : comptime.Expr]
  [value : comptime.Expr]
  [fill-expr : comptime.Expr]
  [alignment-expr : comptime.Expr]
  [sign-expr : comptime.Expr]
  [alternate-expr : comptime.Expr]
  [zero-expr : comptime.Expr]
  [width-kind-expr : comptime.Expr]
  [width-value : comptime.Expr]
  [precision-kind-expr : comptime.Expr]
  [precision-value : comptime.Expr]
  [selector-expr : comptime.Expr]) : String
  (match value
    [(comptime.Expr.Call callee items)
      (if (= (comptime.expr-list-length items) 3)
        (match callee
          [(comptime.Expr.Var name)
            (if (string.eq name "__tl_format_typed_argument")
              `(stdlib.format.format-classify-width
                ,terminal
                ,prefix
                ,(comptime.expr-list-nth items 0)
                ,(comptime.expr-list-nth items 2)
                ,width-value
                ,precision-value
                ,fill-expr
                ,alignment-expr
                ,sign-expr
                ,alternate-expr
                ,zero-expr
                ,width-kind-expr
                ,precision-kind-expr
                ,selector-expr)
              `(stdlib.format.format-classify-width
                ,terminal
                ,prefix
                ,(comptime.type-expr (comptime.expr-type value))
                ,value
                ,width-value
                ,precision-value
                ,fill-expr
                ,alignment-expr
                ,sign-expr
                ,alternate-expr
                ,zero-expr
                ,width-kind-expr
                ,precision-kind-expr
                ,selector-expr))]
          [_
            `(stdlib.format.format-classify-width
              ,terminal
              ,prefix
              ,(comptime.type-expr (comptime.expr-type value))
              ,value
              ,width-value
              ,precision-value
              ,fill-expr
              ,alignment-expr
              ,sign-expr
              ,alternate-expr
              ,zero-expr
              ,width-kind-expr
              ,precision-kind-expr
              ,selector-expr)])
        `(stdlib.format.format-classify-width
          ,terminal
          ,prefix
          ,(comptime.type-expr (comptime.expr-type value))
          ,value
          ,width-value
          ,precision-value
          ,fill-expr
          ,alignment-expr
          ,sign-expr
          ,alternate-expr
          ,zero-expr
          ,width-kind-expr
          ,precision-kind-expr
          ,selector-expr))]
    [_
      `(stdlib.format.format-classify-width
        ,terminal
        ,prefix
        ,(comptime.type-expr (comptime.expr-type value))
        ,value
        ,width-value
        ,precision-value
        ,fill-expr
        ,alignment-expr
        ,sign-expr
        ,alternate-expr
        ,zero-expr
        ,width-kind-expr
        ,precision-kind-expr
        ,selector-expr)]))

;; Unwrap retained-renderer type witnesses before entering the one central
;; formatting dispatcher. Ordinary callers pass through unchanged.
(defmacro (format-value
  [value : comptime.Expr]
  [fill-expr : comptime.Expr]
  [alignment-expr : comptime.Expr]
  [sign-expr : comptime.Expr]
  [alternate-expr : comptime.Expr]
  [zero-expr : comptime.Expr]
  [width-kind-expr : comptime.Expr]
  [width-value : comptime.Expr]
  [precision-kind-expr : comptime.Expr]
  [precision-value : comptime.Expr]
  [selector-expr : comptime.Expr]) : String
  `(stdlib.format.format-classify-value
    stdlib.format.format-value-resolved
    (__tl_format_terminal_prefix)
    ,value
    ,fill-expr
    ,alignment-expr
    ,sign-expr
    ,alternate-expr
    ,zero-expr
    ,width-kind-expr
    ,width-value
    ,precision-kind-expr
    ,precision-value
    ,selector-expr))

;; Invoke one validated owner-module direct hook against the formatter stored
;; at an opaque stack-cell address, then persist its updated status. Owned
;; values receive a generated shared scope so the hook never consumes them.
(defmacro (format-direct-hook-call-at!
  [source-type : type]
  [address : comptime.Expr]
  [runtime-value : comptime.Expr]
  [hook : comptime.Expr]) : String
  (let
    [source-kind : String (type-kind source-type)]
    [borrowed? : bool
      (if (string.eq source-kind "ref")
        true
        (string.eq source-kind "mut-ref"))]
    [slot-name : String (comptime.syntax-name-fresh "__tl_format_direct_slot")]
    [formatter-name : String
      (comptime.syntax-name-fresh "__tl_format_direct_formatter")]
    [value-name : String
      (comptime.syntax-name-fresh "__tl_format_direct_value")]
    [value-ref : comptime.Expr (comptime.expr-var value-name)]
    [slot : comptime.Expr (comptime.expr-var slot-name)]
    [formatter : comptime.Expr (comptime.expr-var formatter-name)]
    [slot-init : comptime.Expr
      `(unsafe
        (int->ptr (cast ,address : u64) : (MutPtr stdlib.format.Formatter)))]
    [formatter-init : comptime.Expr
      `(unsafe
        (ptr-read (ptr-cast ,slot : (Ptr stdlib.format.Formatter))))]
    [body : comptime.Expr
      `(begin
        (,hook
          ,(if borrowed?
            runtime-value
            value-ref)
          (&mut ,formatter))
        (unsafe
          (ptr-write! ,slot ,formatter))
        "")]
    [scoped : comptime.Expr
      (comptime.expr-let-scope
        slot-name
        slot-init
        (comptime.expr-let-scope formatter-name formatter-init body))]
    (if borrowed?
      scoped
      (comptime.expr-shared-let-scope value-name runtime-value scoped))))

;; Materialize one direct owner hook through the same growable String
;; destination used when retained Arguments are converted to a String.
(defmacro (format-direct-hook-materialize
  [source-type : type]
  [runtime-value : comptime.Expr]
  [hook : comptime.Expr]) : String
  `(let
    [__tl_format_direct_sink
      (stdlib.format.ArgumentsStringSink (__tl_make-array u8 64) 0)]
    [__tl_format_direct_sink_cell (array __tl_format_direct_sink)]
    [__tl_format_direct_sink_address : i64
      (unsafe
        (cast
          (ptr->int
            (ptr-cast (__tl_array-data __tl_format_direct_sink_cell) : (Ptr u8)))
          : i64))]
    [__tl_format_direct_formatter
      (stdlib.format.formatter-writer
        __tl_format_direct_sink_address
        stdlib.format.arguments-string-write-raw)]
    [__tl_format_direct_formatter_cell
      (stdlib.format.formatter-cell __tl_format_direct_formatter)]
    [__tl_format_direct_formatter_address : i64
      (unsafe
        (cast
          (ptr->int
            (ptr-cast
              (__tl_array-data __tl_format_direct_formatter_cell)
              : (Ptr u8)))
          : i64))]
    [__tl_format_direct_ignored : String
      (stdlib.format.format-direct-hook-call-at!
        ,(comptime.type-expr source-type)
        __tl_format_direct_formatter_address
        ,runtime-value
        ,hook)]
    [__tl_format_direct_status : i64
      (stdlib.format.formatter-status-at __tl_format_direct_formatter_address)]
    [__tl_format_direct_finished (array-ref __tl_format_direct_sink_cell 0)]
    (if (!= __tl_format_direct_status 0)
      (stdlib.format.format-runtime-abort-string
        "format: internal direct-hook String sink failed")
      (if (= __tl_format_direct_finished.len 0)
        ""
        (unsafe
          (string-from-bytes
            (ptr-cast
              (__tl_array-data __tl_format_direct_finished.slots)
              : (Ptr u8))
            __tl_format_direct_finished.len))))))

;: Stream one value through the same conversion path used by `format`.
;:
;: The conversion may allocate its scalar or owner `to-string` result, but it
;: never constructs a combined String for the complete format plan.
(defmacro (format-stream-value-at-resolved!
  [source-type : type]
  [address : comptime.Expr]
  [runtime-value : comptime.Expr]
  [fill-expr : comptime.Expr]
  [alignment-expr : comptime.Expr]
  [sign-expr : comptime.Expr]
  [alternate-expr : comptime.Expr]
  [zero-expr : comptime.Expr]
  [width-kind-expr : comptime.Expr]
  [width-source : type]
  [width-value : comptime.Expr]
  [precision-kind-expr : comptime.Expr]
  [precision-source : type]
  [precision-value : comptime.Expr]
  [selector-expr : comptime.Expr]) : String
  (let
    [fallback : comptime.Expr
      `(begin
        (stdlib.format.formatter-write-string-at!
          ,address
          (stdlib.format.format-value-resolved
            ,(comptime.type-expr source-type)
            ,runtime-value
            ,fill-expr
            ,alignment-expr
            ,sign-expr
            ,alternate-expr
            ,zero-expr
            ,width-kind-expr
            ,(comptime.type-expr width-source)
            ,width-value
            ,precision-kind-expr
            ,(comptime.type-expr precision-source)
            ,precision-value
            ,selector-expr))
        "")]
    [direct : comptime.Expr
      `(stdlib.format.format-stream-value-at-default-resolved!
        ,(comptime.type-expr source-type)
        ,address
        ,runtime-value
        ,fill-expr
        ,alignment-expr
        ,sign-expr
        ,alternate-expr
        ,zero-expr
        ,width-kind-expr
        ,(comptime.type-expr width-source)
        ,width-value
        ,precision-kind-expr
        ,(comptime.type-expr precision-source)
        ,precision-value
        ,selector-expr)]
    (match fill-expr
      [(comptime.Expr.Int fill)
        (if (= fill 32)
          (match alignment-expr
            [(comptime.Expr.Int alignment)
              (if (= alignment 0)
                (match sign-expr
                  [(comptime.Expr.Int sign)
                    (if (= sign 0)
                      (match alternate-expr
                        [(comptime.Expr.Int alternate)
                          (if (= alternate 0)
                            (match zero-expr
                              [(comptime.Expr.Int zero)
                                (if (= zero 0)
                                  (match width-kind-expr
                                    [(comptime.Expr.Int width-kind)
                                      (if (= width-kind 0)
                                        (match precision-kind-expr
                                          [(comptime.Expr.Int precision-kind)
                                            (if (= precision-kind 0)
                                              (if (string.eq
                                                (comptime.expr-string-value
                                                  selector-expr)
                                                "")
                                                direct
                                                fallback)
                                              fallback)]
                                          [_ fallback])
                                        fallback)]
                                    [_ fallback])
                                  fallback)]
                              [_ fallback])
                            fallback)]
                        [_ fallback])
                      fallback)]
                  [_ fallback])
                fallback)]
            [_ fallback])
          fallback)]
      [_ fallback])))

(defmacro (format-stream-direct-owner-at-resolved!
  [source-type : type]
  [address : comptime.Expr]
  [runtime-value : comptime.Expr]) : String
  (let
    [source-kind : String (type-kind source-type)]
    [borrowed? : bool
      (if (string.eq source-kind "ref")
        true
        (string.eq source-kind "mut-ref"))]
    [value-type : comptime.Expr
      (if borrowed?
        (comptime.reference-element-type source-type)
        source-type)]
    [owner : String (type-nominal-module value-type)]
    [nominal-name : String (type-nominal-name value-type)]
    [plain-name : String "format-write"]
    [qualified-name : String
      (comptime.string-append "format-write-" nominal-name)]
    [plain-present? : bool (comptime.module-value? owner plain-name)]
    [qualified-present? : bool (comptime.module-value? owner qualified-name)]
    [dispatch : i64
      (+
        (if plain-present?
          1
          0)
        (if qualified-present?
          2
          0))]
    [fallback : comptime.Expr
      `(begin
        (stdlib.format.formatter-write-string-at!
          ,address
          (stdlib.format.format-value-resolved
            ,(comptime.type-expr source-type)
            ,runtime-value
            32
            0
            0
            0
            0
            0
            ,(comptime.type-expr source-type)
            0
            0
            ,(comptime.type-expr source-type)
            0
            ""))
        "")]
    (match dispatch
      [3
        (comptime.comptime-error
          (comptime.string-append
            "format: ambiguous direct Formatter hooks for "
            (comptime.string-append
              (type-key value-type)
              (comptime.string-append " in canonical module " owner))))]
      [1
        `(stdlib.format.format-direct-hook-call-at!
          ,(comptime.type-expr source-type)
          ,address
          ,runtime-value
          ,(comptime.module-value-expr owner plain-name))]
      [2
        `(stdlib.format.format-direct-hook-call-at!
          ,(comptime.type-expr source-type)
          ,address
          ,runtime-value
          ,(comptime.module-value-expr owner qualified-name))]
      [_ fallback])))

(defmacro (format-stream-value-at-default-resolved!
  [source-type : type]
  [address : comptime.Expr]
  [runtime-value : comptime.Expr]
  [fill-expr : comptime.Expr]
  [alignment-expr : comptime.Expr]
  [sign-expr : comptime.Expr]
  [alternate-expr : comptime.Expr]
  [zero-expr : comptime.Expr]
  [width-kind-expr : comptime.Expr]
  [width-source : type]
  [width-value : comptime.Expr]
  [precision-kind-expr : comptime.Expr]
  [precision-source : type]
  [precision-value : comptime.Expr]
  [selector-expr : comptime.Expr]) : String
  (let
    [source-kind : String (type-kind source-type)]
    [borrowed? : bool
      (if (string.eq source-kind "ref")
        true
        (string.eq source-kind "mut-ref"))]
    [value-type : comptime.Expr
      (if borrowed?
        (comptime.reference-element-type source-type)
        source-type)]
    [raw-value-kind : String (type-kind value-type)]
    [arguments? : bool
      (if (string.eq raw-value-kind "tuple")
        (if (= (tuple-element-count value-type) 2)
          (if (string.eq
            (type-kind (tuple-element-type value-type 0))
            "function")
            (string.eq (type-kind (tuple-element-type value-type 1)) "tuple")
            false)
          false)
        false)]
    [value-kind : String
      (if arguments?
        (if borrowed?
          "arguments-borrowed"
          "arguments")
        raw-value-kind)]
    [fallback : comptime.Expr
      `(begin
        (stdlib.format.formatter-write-string-at!
          ,address
          (stdlib.format.format-value-resolved
            ,(comptime.type-expr source-type)
            ,runtime-value
            ,fill-expr
            ,alignment-expr
            ,sign-expr
            ,alternate-expr
            ,zero-expr
            ,width-kind-expr
            ,(comptime.type-expr width-source)
            ,width-value
            ,precision-kind-expr
            ,(comptime.type-expr precision-source)
            ,precision-value
            ,selector-expr))
        "")]
    (match value-kind
      ["arguments"
        `(begin
          (stdlib.format.format-arguments-render-at-resolved!
            ,(comptime.type-expr value-type)
            0
            ,runtime-value
            ,address)
          "")]
      ["arguments-borrowed"
        `(begin
          (stdlib.format.format-arguments-render-at-resolved!
            ,(comptime.type-expr value-type)
            1
            ,runtime-value
            ,address)
          "")]
      ["struct"
        `(stdlib.format.format-stream-direct-owner-at-resolved!
          ,(comptime.type-expr source-type)
          ,address
          ,runtime-value)]
      ["enum"
        `(stdlib.format.format-stream-direct-owner-at-resolved!
          ,(comptime.type-expr source-type)
          ,address
          ,runtime-value)]
      ["region"
        `(stdlib.format.format-stream-direct-owner-at-resolved!
          ,(comptime.type-expr source-type)
          ,address
          ,runtime-value)]
      [_ fallback])))

(defmacro (format-stream-value-at!
  [address : comptime.Expr]
  [value : comptime.Expr]
  [fill-expr : comptime.Expr]
  [alignment-expr : comptime.Expr]
  [sign-expr : comptime.Expr]
  [alternate-expr : comptime.Expr]
  [zero-expr : comptime.Expr]
  [width-kind-expr : comptime.Expr]
  [width-value : comptime.Expr]
  [precision-kind-expr : comptime.Expr]
  [precision-value : comptime.Expr]
  [selector-expr : comptime.Expr]) : String
  `(stdlib.format.format-classify-value
    stdlib.format.format-stream-value-at-resolved!
    (__tl_format_terminal_prefix ,address)
    ,value
    ,fill-expr
    ,alignment-expr
    ,sign-expr
    ,alternate-expr
    ,zero-expr
    ,width-kind-expr
    ,width-value
    ,precision-kind-expr
    ,precision-value
    ,selector-expr))

;: Mark one explicit named argument for `format`.
;:
;: This wrapper expands to private marker syntax consumed by `format`; using it
;: outside a format argument is invalid. Imported module aliases expand to the
;: same marker.
(defmacro (named [name : comptime.Expr] [value : comptime.Expr]) : comptime.Expr
  `(__tl_format_named_argument ,name ,value))

;: Classify and bind one direct format operand before continuing expansion.
;:
;: Matching the direct operand preserves a call callee's compiler-owned syntax
;: identity. The private marker emitted by `named` is consumed here; every other
;: call is reconstructed as an ordinary positional value.
(defmacro (format-expand-call
  [plan : comptime.Expr]
  [argument-carrier : comptime.Expr]
  [argument-index : comptime.Expr]
  [named-seen : comptime.Expr]
  [positional-vars : comptime.Expr]
  [named-names : comptime.Expr]
  [named-vars : comptime.Expr]
  [bindings : comptime.Expr]
  [argument : comptime.Expr]) : String
  (match argument-index
    [(comptime.Expr.Int index)
      (match named-seen
        [(comptime.Expr.Int named-state)
          (match positional-vars
            [(comptime.Expr.Call _ positional-items)
              (match named-names
                [(comptime.Expr.Call _ named-name-items)
                  (match named-vars
                    [(comptime.Expr.Call _ named-var-items)
                      (match bindings
                        [(comptime.Expr.Call _ binding-items)
                          (match argument
                            [(comptime.Expr.Call callee call-items)
                              (let
                                [callee-name : String
                                  (match callee
                                    [(comptime.Expr.Var found) found]
                                    [_ ""])]
                                [named-wrapper? : bool
                                  (string.eq
                                    callee-name
                                    "__tl_format_named_argument")]
                                (if named-wrapper?
                                  (if (!=
                                    (comptime.expr-list-length call-items)
                                    2)
                                    (comptime.comptime-error
                                      "format: named argument wrapper expects a name and value")
                                    (let
                                      [name-expr : comptime.Expr
                                        (comptime.expr-list-nth call-items 0)]
                                      [value-expr : comptime.Expr
                                        (comptime.expr-list-nth call-items 1)]
                                      [argument-name : String
                                        (match name-expr
                                          [(comptime.Expr.Var found) found]
                                          [_
                                            (comptime.comptime-error
                                              "format: named argument name must be an identifier")])]
                                      [duplicate? : bool false]
                                      [name-index : i64 0]
                                      (begin
                                        (if (string.eq argument-name "_")
                                          (comptime.comptime-error
                                            "format: bare '_' is not a named argument identifier")
                                          unit)
                                        (while (<
                                          name-index
                                          (comptime.expr-list-length
                                            named-name-items))
                                          (begin
                                            (if (string.eq
                                              (comptime.expr-string-value
                                                (comptime.expr-list-nth
                                                  named-name-items
                                                  name-index))
                                              argument-name)
                                              (set! duplicate? true)
                                              unit)
                                            (set! name-index (+ name-index 1))))
                                        (if duplicate?
                                          (comptime.comptime-error
                                            (comptime.string-append
                                              "format: duplicate named argument "
                                              argument-name))
                                          unit)
                                        (let
                                          [fresh-name : String
                                            (comptime.syntax-name-fresh
                                              (comptime.string-append
                                                "__tl_format_shared_named_"
                                                (comptime.int->string index)))]
                                          [fresh-var : comptime.Expr
                                            (comptime.expr-var fresh-name)]
                                          (begin
                                            `(stdlib.format.format-expand
                                              ,plan
                                              ,argument-carrier
                                              ,(comptime.expr-int (+ index 1))
                                              ,(comptime.expr-int 1)
                                              ,positional-vars
                                              (__tl_format_named_names
                                                ,@named-name-items
                                                ,(comptime.expr-string
                                                  argument-name))
                                              (__tl_format_named_vars
                                                ,@named-var-items
                                                ,fresh-var)
                                              (__tl_format_bindings
                                                ,@binding-items
                                                ,(comptime.expr-begin-unit
                                                  (comptime.expr-list-cons
                                                    fresh-var
                                                    (comptime.expr-list-cons
                                                      value-expr
                                                      (comptime.expr-list-empty)))))))))))
                                  (if (!= named-state 0)
                                    (comptime.comptime-error
                                      "format: positional argument follows named argument")
                                    (let
                                      [argument-value : comptime.Expr
                                        `(,callee ,@call-items)]
                                      [value-kind : String
                                        (type-kind
                                          (comptime.expr-type argument-value))]
                                      [borrow-mode : i64
                                        (match value-kind
                                          ["string" 1]
                                          ["struct" 1]
                                          ["enum" 1]
                                          ["region" 1]
                                          [_ 0])]
                                      [fresh-name : String
                                        (comptime.syntax-name-fresh
                                          (comptime.string-append
                                            "__tl_format_positional_"
                                            (comptime.int->string index)))]
                                      [fresh-var : comptime.Expr
                                        (comptime.expr-var fresh-name)]
                                      (begin
                                        (if (= borrow-mode 1)
                                          (set!
                                            fresh-var
                                            (comptime.expr-var
                                              (comptime.string-append
                                                "__tl_format_shared_"
                                                fresh-name)))
                                          unit)
                                        `(stdlib.format.format-expand
                                          ,plan
                                          ,argument-carrier
                                          ,(comptime.expr-int (+ index 1))
                                          ,(comptime.expr-int 0)
                                          (__tl_format_positional_vars
                                            ,@positional-items
                                            ,fresh-var)
                                          ,named-names
                                          ,named-vars
                                          (__tl_format_bindings
                                            ,@binding-items
                                            ,(comptime.expr-begin-unit
                                              (comptime.expr-list-cons
                                                fresh-var
                                                (comptime.expr-list-cons
                                                  argument-value
                                                  (comptime.expr-list-empty)))))))))))]
                            [_
                              (if (!= named-state 0)
                                (comptime.comptime-error
                                  "format: positional argument follows named argument")
                                (let
                                  [value-kind : String
                                    (type-kind (comptime.expr-type argument))]
                                  [borrow-mode : i64
                                    (match value-kind
                                      ["string" 1]
                                      ["struct" 1]
                                      ["enum" 1]
                                      ["region" 1]
                                      [_ 0])]
                                  [fresh-name : String
                                    (comptime.syntax-name-fresh
                                      (comptime.string-append
                                        "__tl_format_positional_"
                                        (comptime.int->string index)))]
                                  [fresh-var : comptime.Expr
                                    (comptime.expr-var fresh-name)]
                                  (begin
                                    (if (= borrow-mode 1)
                                      (set!
                                        fresh-var
                                        (comptime.expr-var
                                          (comptime.string-append
                                            "__tl_format_shared_"
                                            fresh-name)))
                                      unit)
                                    `(stdlib.format.format-expand
                                      ,plan
                                      ,argument-carrier
                                      ,(comptime.expr-int (+ index 1))
                                      ,(comptime.expr-int 0)
                                      (__tl_format_positional_vars
                                        ,@positional-items
                                        ,fresh-var)
                                      ,named-names
                                      ,named-vars
                                      (__tl_format_bindings
                                        ,@binding-items
                                        ,(comptime.expr-begin-unit
                                          (comptime.expr-list-cons
                                            fresh-var
                                            (comptime.expr-list-cons
                                              argument
                                              (comptime.expr-list-empty)))))))))])]
                        [_
                          (comptime.comptime-error
                            "format: internal binding carrier is malformed")])]
                    [_
                      (comptime.comptime-error
                        "format: internal named variable carrier is malformed")])]
                [_
                  (comptime.comptime-error
                    "format: internal named argument carrier is malformed")])]
            [_
              (comptime.comptime-error
                "format: internal positional carrier is malformed")])]
        [_
          (comptime.comptime-error
            "format: internal named-argument state is malformed")])]
    [_
      (comptime.comptime-error
        "format: internal argument index is not an integer")]))

;: Classify and bind one direct format operand for a mode-aware plan.
;:
;: Matching the direct operand preserves a call callee's compiler-owned syntax
;: identity. The private marker emitted by `named` is consumed here; every other
;: call is reconstructed as an ordinary positional value.
(defmacro (format-expand-mode-call
  [plan : comptime.Expr]
  [argument-carrier : comptime.Expr]
  [stream-address : comptime.Expr]
  [argument-index : comptime.Expr]
  [named-seen : comptime.Expr]
  [positional-vars : comptime.Expr]
  [named-names : comptime.Expr]
  [named-vars : comptime.Expr]
  [bindings : comptime.Expr]
  [argument : comptime.Expr]) : comptime.Expr
  (match argument-index
    [(comptime.Expr.Int index)
      (match named-seen
        [(comptime.Expr.Int named-state)
          (match positional-vars
            [(comptime.Expr.Call _ positional-items)
              (match named-names
                [(comptime.Expr.Call _ named-name-items)
                  (match named-vars
                    [(comptime.Expr.Call _ named-var-items)
                      (match bindings
                        [(comptime.Expr.Call _ binding-items)
                          (match argument
                            [(comptime.Expr.Call callee call-items)
                              (let
                                [callee-name : String
                                  (match callee
                                    [(comptime.Expr.Var found) found]
                                    [_ ""])]
                                [named-wrapper? : bool
                                  (string.eq
                                    callee-name
                                    "__tl_format_named_argument")]
                                (if named-wrapper?
                                  (if (!=
                                    (comptime.expr-list-length call-items)
                                    2)
                                    (comptime.comptime-error
                                      "format: named argument wrapper expects a name and value")
                                    (let
                                      [name-expr : comptime.Expr
                                        (comptime.expr-list-nth call-items 0)]
                                      [value-expr : comptime.Expr
                                        (comptime.expr-list-nth call-items 1)]
                                      [argument-name : String
                                        (match name-expr
                                          [(comptime.Expr.Var found) found]
                                          [_
                                            (comptime.comptime-error
                                              "format: named argument name must be an identifier")])]
                                      [duplicate? : bool false]
                                      [name-index : i64 0]
                                      (begin
                                        (if (string.eq argument-name "_")
                                          (comptime.comptime-error
                                            "format: bare '_' is not a named argument identifier")
                                          unit)
                                        (while (<
                                          name-index
                                          (comptime.expr-list-length
                                            named-name-items))
                                          (begin
                                            (if (string.eq
                                              (comptime.expr-string-value
                                                (comptime.expr-list-nth
                                                  named-name-items
                                                  name-index))
                                              argument-name)
                                              (set! duplicate? true)
                                              unit)
                                            (set! name-index (+ name-index 1))))
                                        (if duplicate?
                                          (comptime.comptime-error
                                            (comptime.string-append
                                              "format: duplicate named argument "
                                              argument-name))
                                          unit)
                                        (let
                                          [fresh-name : String
                                            (comptime.syntax-name-fresh
                                              (comptime.string-append
                                                "__tl_format_shared_named_"
                                                (comptime.int->string index)))]
                                          [fresh-var : comptime.Expr
                                            (comptime.expr-var fresh-name)]
                                          (begin
                                            `(stdlib.format.format-expand-mode
                                              ,plan
                                              ,argument-carrier
                                              ,stream-address
                                              ,(comptime.expr-int (+ index 1))
                                              ,(comptime.expr-int 1)
                                              ,positional-vars
                                              (__tl_format_named_names
                                                ,@named-name-items
                                                ,(comptime.expr-string
                                                  argument-name))
                                              (__tl_format_named_vars
                                                ,@named-var-items
                                                ,fresh-var)
                                              (__tl_format_bindings
                                                ,@binding-items
                                                ,(comptime.expr-begin-unit
                                                  (comptime.expr-list-cons
                                                    fresh-var
                                                    (comptime.expr-list-cons
                                                      value-expr
                                                      (comptime.expr-list-empty)))))))))))
                                  (if (!= named-state 0)
                                    (comptime.comptime-error
                                      "format: positional argument follows named argument")
                                    (let
                                      [argument-value : comptime.Expr
                                        `(,callee ,@call-items)]
                                      [value-kind : String
                                        (type-kind
                                          (comptime.expr-type argument-value))]
                                      [borrow-mode : i64
                                        (match value-kind
                                          ["string" 1]
                                          ["struct" 1]
                                          ["enum" 1]
                                          ["region" 1]
                                          [_ 0])]
                                      [fresh-name : String
                                        (comptime.syntax-name-fresh
                                          (comptime.string-append
                                            "__tl_format_positional_"
                                            (comptime.int->string index)))]
                                      [fresh-var : comptime.Expr
                                        (comptime.expr-var fresh-name)]
                                      (begin
                                        (if (= borrow-mode 1)
                                          (set!
                                            fresh-var
                                            (comptime.expr-var
                                              (comptime.string-append
                                                "__tl_format_shared_"
                                                fresh-name)))
                                          unit)
                                        `(stdlib.format.format-expand-mode
                                          ,plan
                                          ,argument-carrier
                                          ,stream-address
                                          ,(comptime.expr-int (+ index 1))
                                          ,(comptime.expr-int 0)
                                          (__tl_format_positional_vars
                                            ,@positional-items
                                            ,fresh-var)
                                          ,named-names
                                          ,named-vars
                                          (__tl_format_bindings
                                            ,@binding-items
                                            ,(comptime.expr-begin-unit
                                              (comptime.expr-list-cons
                                                fresh-var
                                                (comptime.expr-list-cons
                                                  argument-value
                                                  (comptime.expr-list-empty)))))))))))]
                            [_
                              (if (!= named-state 0)
                                (comptime.comptime-error
                                  "format: positional argument follows named argument")
                                (let
                                  [value-type : comptime.Expr
                                    (comptime.expr-type argument)]
                                  [value-kind : String (type-kind value-type)]
                                  [borrow-mode : i64
                                    (match value-kind
                                      ["string"
                                        (if (comptime.expr-string? argument)
                                          0
                                          1)]
                                      ["struct" 1]
                                      ["enum" 1]
                                      ["region" 1]
                                      [_ 0])]
                                  [fresh-name : String
                                    (comptime.syntax-name-fresh
                                      (comptime.string-append
                                        "__tl_format_positional_"
                                        (comptime.int->string index)))]
                                  [fresh-var : comptime.Expr
                                    (comptime.expr-var fresh-name)]
                                  (begin
                                    (if (= borrow-mode 1)
                                      (set!
                                        fresh-var
                                        (comptime.expr-var
                                          (comptime.string-append
                                            "__tl_format_shared_"
                                            fresh-name)))
                                      unit)
                                    `(stdlib.format.format-expand-mode
                                      ,plan
                                      ,argument-carrier
                                      ,stream-address
                                      ,(comptime.expr-int (+ index 1))
                                      ,(comptime.expr-int 0)
                                      (__tl_format_positional_vars
                                        ,@positional-items
                                        ,fresh-var)
                                      ,named-names
                                      ,named-vars
                                      (__tl_format_bindings
                                        ,@binding-items
                                        ,(comptime.expr-begin-unit
                                          (comptime.expr-list-cons
                                            fresh-var
                                            (comptime.expr-list-cons
                                              argument
                                              (comptime.expr-list-empty)))))))))])]
                        [_
                          (comptime.comptime-error
                            "format: internal binding carrier is malformed")])]
                    [_
                      (comptime.comptime-error
                        "format: internal named variable carrier is malformed")])]
                [_
                  (comptime.comptime-error
                    "format: internal named argument carrier is malformed")])]
            [_
              (comptime.comptime-error
                "format: internal positional carrier is malformed")])]
        [_
          (comptime.comptime-error
            "format: internal named-argument state is malformed")])]
    [_
      (comptime.comptime-error
        "format: internal argument index is not an integer")]))

;: Bind supplied arguments, validate a completed plan, and emit one flat concat.
(defmacro (format-expand
  [plan : comptime.Expr]
  [argument-carrier : comptime.Expr]
  [argument-index : comptime.Expr]
  [named-seen : comptime.Expr]
  [positional-vars : comptime.Expr]
  [named-names : comptime.Expr]
  [named-vars : comptime.Expr]
  [bindings : comptime.Expr]) : String
  (match argument-index
    [(comptime.Expr.Int index)
      (match argument-carrier
        [(comptime.Expr.Call _ arguments)
          (if (< index (comptime.expr-list-length arguments))
            (let
              [argument : comptime.Expr
                (comptime.expr-list-nth arguments index)]
              `(stdlib.format.format-expand-call
                ,plan
                ,argument-carrier
                ,argument-index
                ,named-seen
                ,positional-vars
                ,named-names
                ,named-vars
                ,bindings
                ,argument))
            (match plan
              [(comptime.Expr.Call _ plan-pieces)
                (match positional-vars
                  [(comptime.Expr.Call _ positional-items)
                    (match named-names
                      [(comptime.Expr.Call _ named-name-items)
                        (match named-vars
                          [(comptime.Expr.Call _ named-var-items)
                            (match bindings
                              [(comptime.Expr.Call _ binding-items)
                                (let
                                  [plan-len : i64
                                    (comptime.expr-list-length plan-pieces)]
                                  [positional-count : i64
                                    (comptime.expr-list-length positional-items)]
                                  [capture-names : comptime.ExprList
                                    (comptime.expr-list-empty)]
                                  [capture-vars : comptime.ExprList
                                    (comptime.expr-list-empty)]
                                  [capture-bindings : comptime.ExprList
                                    (comptime.expr-list-empty)]
                                  [capture-count : i64 0]
                                  [plan-index : i64 (- plan-len 1)]
                                  (begin
                                    ;; Validate every placeholder carrier and
                                    ;; every positional value/count reference.
                                    (while (>= plan-index 0)
                                      (let
                                        [piece : comptime.Expr
                                          (comptime.expr-list-nth
                                            plan-pieces
                                            plan-index)]
                                        [fields : comptime.ExprList
                                          (comptime.expr-list-empty)]
                                        (begin
                                          (match piece
                                            [(comptime.Expr.Begin found-fields)
                                              (set! fields found-fields)]
                                            [_ unit])
                                          (if (comptime.expr-string? piece)
                                            unit
                                            (if (!=
                                              (comptime.expr-list-length fields)
                                              14)
                                              (comptime.comptime-error
                                                "format: internal placeholder plan is malformed")
                                              (let
                                                [selector-kind : i64 -1]
                                                [implicit-state : i64 -1]
                                                [width-kind : i64 -1]
                                                [precision-kind : i64 -1]
                                                (begin
                                                  (match (comptime.expr-list-nth
                                                    fields
                                                    0)
                                                    [(comptime.Expr.Int found)
                                                      (set! selector-kind found)]
                                                    [_ unit])
                                                  (match (comptime.expr-list-nth
                                                    fields
                                                    2)
                                                    [(comptime.Expr.Int found)
                                                      (set!
                                                        implicit-state
                                                        found)]
                                                    [_ unit])
                                                  (match (comptime.expr-list-nth
                                                    fields
                                                    8)
                                                    [(comptime.Expr.Int found)
                                                      (set! width-kind found)]
                                                    [_ unit])
                                                  (match (comptime.expr-list-nth
                                                    fields
                                                    10)
                                                    [(comptime.Expr.Int found)
                                                      (set!
                                                        precision-kind
                                                        found)]
                                                    [_ unit])
                                                  (if (= selector-kind 0)
                                                    (match (comptime.expr-list-nth
                                                      fields
                                                      1)
                                                      [(comptime.Expr.Int
                                                          selected)
                                                        (if (>=
                                                          selected
                                                          positional-count)
                                                          (if (!=
                                                            implicit-state
                                                            0)
                                                            (comptime.comptime-error
                                                              "format: not enough arguments for placeholders")
                                                            (comptime.comptime-error
                                                              (comptime.string-append
                                                                "format: positional argument index is out of range: "
                                                                (comptime.int->string
                                                                  selected))))
                                                          unit)]
                                                      [_
                                                        (comptime.comptime-error
                                                          "format: internal positional selector is malformed")])
                                                    (if (= selector-kind 1)
                                                      (let
                                                        [selector-value : comptime.Expr
                                                          (comptime.expr-list-nth
                                                            fields
                                                            1)]
                                                        (if (not
                                                          (comptime.expr-string?
                                                            selector-value))
                                                          (comptime.comptime-error
                                                            "format: internal named selector is malformed")
                                                          unit))
                                                      (comptime.comptime-error
                                                        "format: internal selector kind is malformed")))
                                                  ;; Macro CTFE cannot invoke `cond`.
                                                  ;; lint-allow: nested-if-ladder
                                                  (if (= width-kind 2)
                                                    (match (comptime.expr-list-nth
                                                      fields
                                                      9)
                                                      [(comptime.Expr.Int
                                                          selected)
                                                        (if (>=
                                                          selected
                                                          positional-count)
                                                          (comptime.comptime-error
                                                            (comptime.string-append
                                                              "format: dynamic width argument index is out of range: "
                                                              (comptime.int->string
                                                                selected)))
                                                          unit)]
                                                      [_
                                                        (comptime.comptime-error
                                                          "format: internal width reference is malformed")])
                                                    (if (< width-kind 0)
                                                      (comptime.comptime-error
                                                        "format: internal width kind is malformed")
                                                      (if (> width-kind 3)
                                                        (comptime.comptime-error
                                                          "format: internal width kind is malformed")
                                                        unit)))
                                                  ;; Macro CTFE cannot invoke `cond`.
                                                  ;; lint-allow: nested-if-ladder
                                                  (if (if (= precision-kind 2)
                                                    true
                                                    (= precision-kind 4))
                                                    (match (comptime.expr-list-nth
                                                      fields
                                                      11)
                                                      [(comptime.Expr.Int
                                                          selected)
                                                        (if (>=
                                                          selected
                                                          positional-count)
                                                          (comptime.comptime-error
                                                            (comptime.string-append
                                                              "format: dynamic precision argument index is out of range: "
                                                              (comptime.int->string
                                                                selected)))
                                                          unit)]
                                                      [_
                                                        (comptime.comptime-error
                                                          "format: internal precision reference is malformed")])
                                                    (if (< precision-kind 0)
                                                      (comptime.comptime-error
                                                        "format: internal precision kind is malformed")
                                                      (if (> precision-kind 4)
                                                        (comptime.comptime-error
                                                          "format: internal precision kind is malformed")
                                                        unit)))))))
                                          (set! plan-index (- plan-index 1)))))
                                    ;; Every positional value/count reference
                                    ;; counts as a use. Scanner-resolved star
                                    ;; counts have already advanced the implicit
                                    ;; iterator; dollar references have not.
                                    (let
                                      [positional-index : i64 0]
                                      (while (<
                                        positional-index
                                        positional-count)
                                        (let
                                          [used? : bool false]
                                          [piece-index : i64 0]
                                          (begin
                                            (while (< piece-index plan-len)
                                              (let
                                                [piece : comptime.Expr
                                                  (comptime.expr-list-nth
                                                    plan-pieces
                                                    piece-index)]
                                                [fields : comptime.ExprList
                                                  (comptime.expr-list-empty)]
                                                [slot : i64 0]
                                                (begin
                                                  (match piece
                                                    [(comptime.Expr.Begin
                                                        found-fields)
                                                      (set! fields found-fields)]
                                                    [_ unit])
                                                  (if (=
                                                    (comptime.expr-list-length
                                                      fields)
                                                    14)
                                                    (while (< slot 3)
                                                      (let
                                                        [reference-kind : i64
                                                          -1]
                                                        [reference-value : comptime.Expr
                                                          (comptime.expr-int 0)]
                                                        (begin
                                                          (if (= slot 0)
                                                            (begin
                                                              (match (comptime.expr-list-nth
                                                                fields
                                                                0)
                                                                [(comptime.Expr.Int
                                                                    found)
                                                                  (set!
                                                                    reference-kind
                                                                    found)]
                                                                [_ unit])
                                                              (set!
                                                                reference-value
                                                                (comptime.expr-list-nth
                                                                  fields
                                                                  1)))
                                                            (if (= slot 1)
                                                              (begin
                                                                (match (comptime.expr-list-nth
                                                                  fields
                                                                  8)
                                                                  [(comptime.Expr.Int
                                                                      found)
                                                                    (set!
                                                                      reference-kind
                                                                      found)]
                                                                  [_ unit])
                                                                (set!
                                                                  reference-value
                                                                  (comptime.expr-list-nth
                                                                    fields
                                                                    9)))
                                                              (begin
                                                                (match (comptime.expr-list-nth
                                                                  fields
                                                                  10)
                                                                  [(comptime.Expr.Int
                                                                      found)
                                                                    (set!
                                                                      reference-kind
                                                                      found)]
                                                                  [_ unit])
                                                                (set!
                                                                  reference-value
                                                                  (comptime.expr-list-nth
                                                                    fields
                                                                    11)))))
                                                          (if (= slot 0)
                                                            (if (=
                                                              reference-kind
                                                              0)
                                                              (match reference-value
                                                                [(comptime.Expr.Int
                                                                    selected)
                                                                  (if (=
                                                                    selected
                                                                    positional-index)
                                                                    (set!
                                                                      used?
                                                                      true)
                                                                    unit)]
                                                                [_ unit])
                                                              unit)
                                                            (if (if (=
                                                              reference-kind
                                                              2)
                                                              true
                                                              (if (= slot 2)
                                                                (=
                                                                  reference-kind
                                                                  4)
                                                                false))
                                                              (match reference-value
                                                                [(comptime.Expr.Int
                                                                    selected)
                                                                  (if (=
                                                                    selected
                                                                    positional-index)
                                                                    (set!
                                                                      used?
                                                                      true)
                                                                    unit)]
                                                                [_ unit])
                                                              unit))
                                                          (set! slot (+ slot 1)))))
                                                    unit)
                                                  (set!
                                                    piece-index
                                                    (+ piece-index 1)))))
                                            (if (not used?)
                                              (comptime.comptime-error
                                                (comptime.string-append
                                                  "format: not enough placeholders for arguments; unused positional argument "
                                                  (comptime.int->string
                                                    positional-index)))
                                              unit)
                                            (set!
                                              positional-index
                                              (+ positional-index 1))))))
                                    ;; Explicit named values may be selected as
                                    ;; either the rendered value or a count.
                                    (let
                                      [named-index : i64 0]
                                      (while (<
                                        named-index
                                        (comptime.expr-list-length
                                          named-name-items))
                                        (let
                                          [name : String
                                            (comptime.expr-string-value
                                              (comptime.expr-list-nth
                                                named-name-items
                                                named-index))]
                                          [used? : bool false]
                                          [piece-index : i64 0]
                                          (begin
                                            (while (< piece-index plan-len)
                                              (let
                                                [piece : comptime.Expr
                                                  (comptime.expr-list-nth
                                                    plan-pieces
                                                    piece-index)]
                                                [fields : comptime.ExprList
                                                  (comptime.expr-list-empty)]
                                                [slot : i64 0]
                                                (begin
                                                  (match piece
                                                    [(comptime.Expr.Begin
                                                        found-fields)
                                                      (set! fields found-fields)]
                                                    [_ unit])
                                                  (if (=
                                                    (comptime.expr-list-length
                                                      fields)
                                                    14)
                                                    (while (< slot 3)
                                                      (let
                                                        [reference-kind : i64
                                                          -1]
                                                        [reference-value : comptime.Expr
                                                          (comptime.expr-int 0)]
                                                        (begin
                                                          (if (= slot 0)
                                                            (begin
                                                              (match (comptime.expr-list-nth
                                                                fields
                                                                0)
                                                                [(comptime.Expr.Int
                                                                    found)
                                                                  (set!
                                                                    reference-kind
                                                                    found)]
                                                                [_ unit])
                                                              (set!
                                                                reference-value
                                                                (comptime.expr-list-nth
                                                                  fields
                                                                  1)))
                                                            (if (= slot 1)
                                                              (begin
                                                                (match (comptime.expr-list-nth
                                                                  fields
                                                                  8)
                                                                  [(comptime.Expr.Int
                                                                      found)
                                                                    (set!
                                                                      reference-kind
                                                                      found)]
                                                                  [_ unit])
                                                                (set!
                                                                  reference-value
                                                                  (comptime.expr-list-nth
                                                                    fields
                                                                    9)))
                                                              (begin
                                                                (match (comptime.expr-list-nth
                                                                  fields
                                                                  10)
                                                                  [(comptime.Expr.Int
                                                                      found)
                                                                    (set!
                                                                      reference-kind
                                                                      found)]
                                                                  [_ unit])
                                                                (set!
                                                                  reference-value
                                                                  (comptime.expr-list-nth
                                                                    fields
                                                                    11)))))
                                                          (if (= slot 0)
                                                            (if (=
                                                              reference-kind
                                                              1)
                                                              (if (string.eq
                                                                (comptime.expr-string-value
                                                                  reference-value)
                                                                name)
                                                                (set!
                                                                  used?
                                                                  true)
                                                                unit)
                                                              unit)
                                                            (if (=
                                                              reference-kind
                                                              3)
                                                              (if (string.eq
                                                                (comptime.expr-string-value
                                                                  reference-value)
                                                                name)
                                                                (set!
                                                                  used?
                                                                  true)
                                                                unit)
                                                              unit))
                                                          (set! slot (+ slot 1)))))
                                                    unit)
                                                  (set!
                                                    piece-index
                                                    (+ piece-index 1)))))
                                            (if (not used?)
                                              (comptime.comptime-error
                                                (comptime.string-append
                                                  "format: unused named argument "
                                                  name))
                                              unit)
                                            (set! named-index (+ named-index 1))))))
                                    ;; Discover selector/count captures in
                                    ;; template order, once per lexical name.
                                    (set! plan-index (- plan-len 1))
                                    (while (>= plan-index 0)
                                      (let
                                        [piece : comptime.Expr
                                          (comptime.expr-list-nth
                                            plan-pieces
                                            plan-index)]
                                        [fields : comptime.ExprList
                                          (comptime.expr-list-empty)]
                                        [slot : i64 0]
                                        (begin
                                          (match piece
                                            [(comptime.Expr.Begin found-fields)
                                              (set! fields found-fields)]
                                            [_ unit])
                                          (if (=
                                            (comptime.expr-list-length fields)
                                            14)
                                            (while (< slot 3)
                                              (let
                                                [reference-kind : i64 -1]
                                                [reference-value : comptime.Expr
                                                  (comptime.expr-int 0)]
                                                [named-reference? : bool false]
                                                (begin
                                                  (if (= slot 0)
                                                    (begin
                                                      (match (comptime.expr-list-nth
                                                        fields
                                                        0)
                                                        [(comptime.Expr.Int
                                                            found)
                                                          (set!
                                                            reference-kind
                                                            found)]
                                                        [_ unit])
                                                      (set!
                                                        reference-value
                                                        (comptime.expr-list-nth
                                                          fields
                                                          1)))
                                                    (if (= slot 1)
                                                      (begin
                                                        (match (comptime.expr-list-nth
                                                          fields
                                                          8)
                                                          [(comptime.Expr.Int
                                                              found)
                                                            (set!
                                                              reference-kind
                                                              found)]
                                                          [_ unit])
                                                        (set!
                                                          reference-value
                                                          (comptime.expr-list-nth
                                                            fields
                                                            9)))
                                                      (begin
                                                        (match (comptime.expr-list-nth
                                                          fields
                                                          10)
                                                          [(comptime.Expr.Int
                                                              found)
                                                            (set!
                                                              reference-kind
                                                              found)]
                                                          [_ unit])
                                                        (set!
                                                          reference-value
                                                          (comptime.expr-list-nth
                                                            fields
                                                            11)))))
                                                  (if (= slot 0)
                                                    (if (= reference-kind 1)
                                                      (set!
                                                        named-reference?
                                                        true)
                                                      unit)
                                                    (if (= reference-kind 3)
                                                      (set!
                                                        named-reference?
                                                        true)
                                                      unit))
                                                  (if named-reference?
                                                    (let
                                                      [name : String
                                                        (comptime.expr-string-value
                                                          reference-value)]
                                                      [explicit-index : i64 -1]
                                                      [capture-index : i64 -1]
                                                      [explicit-scan : i64 0]
                                                      [capture-scan : i64 0]
                                                      (begin
                                                        (while (<
                                                          explicit-scan
                                                          (comptime.expr-list-length
                                                            named-name-items))
                                                          (begin
                                                            (if (string.eq
                                                              (comptime.expr-string-value
                                                                (comptime.expr-list-nth
                                                                  named-name-items
                                                                  explicit-scan))
                                                              name)
                                                              (set!
                                                                explicit-index
                                                                explicit-scan)
                                                              unit)
                                                            (set!
                                                              explicit-scan
                                                              (+
                                                                explicit-scan
                                                                1))))
                                                        (while (<
                                                          capture-scan
                                                          (comptime.expr-list-length
                                                            capture-names))
                                                          (begin
                                                            (if (string.eq
                                                              (comptime.expr-string-value
                                                                (comptime.expr-list-nth
                                                                  capture-names
                                                                  capture-scan))
                                                              name)
                                                              (set!
                                                                capture-index
                                                                capture-scan)
                                                              unit)
                                                            (set!
                                                              capture-scan
                                                              (+ capture-scan 1))))
                                                        (if (< explicit-index 0)
                                                          (if (<
                                                            capture-index
                                                            0)
                                                            (let
                                                              [fresh-name : String
                                                                (comptime.syntax-name-fresh
                                                                  (comptime.string-append
                                                                    "__tl_format_shared_capture_"
                                                                    (comptime.int->string
                                                                      capture-count)))]
                                                              [fresh-var : comptime.Expr
                                                                (comptime.expr-var
                                                                  fresh-name)]
                                                              [entry-items : comptime.ExprList
                                                                (comptime.expr-list-cons
                                                                  fresh-var
                                                                  (comptime.expr-list-cons
                                                                    (comptime.expr-var
                                                                      name)
                                                                    (comptime.expr-list-empty)))]
                                                              (begin
                                                                (set!
                                                                  capture-names
                                                                  (comptime.expr-list-cons
                                                                    (comptime.expr-string
                                                                      name)
                                                                    capture-names))
                                                                (set!
                                                                  capture-vars
                                                                  (comptime.expr-list-cons
                                                                    fresh-var
                                                                    capture-vars))
                                                                (set!
                                                                  capture-bindings
                                                                  (comptime.expr-list-cons
                                                                    (comptime.expr-begin-unit
                                                                      entry-items)
                                                                    capture-bindings))
                                                                (set!
                                                                  capture-count
                                                                  (+
                                                                    capture-count
                                                                    1))))
                                                            unit)
                                                          unit)))
                                                    unit)
                                                  (set! slot (+ slot 1)))))
                                            unit)
                                          (set! plan-index (- plan-index 1)))))
                                    ;; Render the reverse plan into forward flat
                                    ;; concat operands while resolving names.
                                    (let
                                      [output : comptime.ExprList
                                        (comptime.expr-list-empty)]
                                      [piece-index : i64 0]
                                      (begin
                                        (while (< piece-index plan-len)
                                          (let
                                            [piece : comptime.Expr
                                              (comptime.expr-list-nth
                                                plan-pieces
                                                piece-index)]
                                            [fields : comptime.ExprList
                                              (comptime.expr-list-empty)]
                                            (begin
                                              (match piece
                                                [(comptime.Expr.Begin
                                                    found-fields)
                                                  (set! fields found-fields)]
                                                [_ unit])
                                              (if (comptime.expr-string? piece)
                                                (set!
                                                  output
                                                  (comptime.expr-list-cons
                                                    piece
                                                    output))
                                                (let
                                                  [selector-kind : i64 -1]
                                                  [selected : comptime.Expr
                                                    (comptime.expr-int 0)]
                                                  [width-kind : i64 -1]
                                                  [resolved-width : comptime.Expr
                                                    (comptime.expr-int 0)]
                                                  [precision-kind : i64 -1]
                                                  [resolved-precision : comptime.Expr
                                                    (comptime.expr-int 0)]
                                                  (begin
                                                    (match (comptime.expr-list-nth
                                                      fields
                                                      0)
                                                      [(comptime.Expr.Int found)
                                                        (set!
                                                          selector-kind
                                                          found)]
                                                      [_ unit])
                                                    (if (= selector-kind 0)
                                                      (match (comptime.expr-list-nth
                                                        fields
                                                        1)
                                                        [(comptime.Expr.Int
                                                            selected-index)
                                                          (set!
                                                            selected
                                                            (comptime.expr-list-nth
                                                              positional-items
                                                              selected-index))]
                                                        [_ unit])
                                                      (let
                                                        [name : String
                                                          (comptime.expr-string-value
                                                            (comptime.expr-list-nth
                                                              fields
                                                              1))]
                                                        [scan : i64 0]
                                                        (begin
                                                          (while (<
                                                            scan
                                                            (comptime.expr-list-length
                                                              named-name-items))
                                                            (begin
                                                              (if (string.eq
                                                                (comptime.expr-string-value
                                                                  (comptime.expr-list-nth
                                                                    named-name-items
                                                                    scan))
                                                                name)
                                                                (set!
                                                                  selected
                                                                  (comptime.expr-list-nth
                                                                    named-var-items
                                                                    scan))
                                                                unit)
                                                              (set!
                                                                scan
                                                                (+ scan 1))))
                                                          (set! scan 0)
                                                          (while (<
                                                            scan
                                                            (comptime.expr-list-length
                                                              capture-names))
                                                            (begin
                                                              (if (string.eq
                                                                (comptime.expr-string-value
                                                                  (comptime.expr-list-nth
                                                                    capture-names
                                                                    scan))
                                                                name)
                                                                (set!
                                                                  selected
                                                                  (comptime.expr-list-nth
                                                                    capture-vars
                                                                    scan))
                                                                unit)
                                                              (set!
                                                                scan
                                                                (+ scan 1)))))))
                                                    (match (comptime.expr-list-nth
                                                      fields
                                                      8)
                                                      [(comptime.Expr.Int found)
                                                        (set! width-kind found)]
                                                      [_ unit])
                                                    (if (= width-kind 2)
                                                      (match (comptime.expr-list-nth
                                                        fields
                                                        9)
                                                        [(comptime.Expr.Int
                                                            width-index)
                                                          (set!
                                                            resolved-width
                                                            (comptime.expr-list-nth
                                                              positional-items
                                                              width-index))]
                                                        [_ unit])
                                                      (if (= width-kind 3)
                                                        (let
                                                          [name : String
                                                            (comptime.expr-string-value
                                                              (comptime.expr-list-nth
                                                                fields
                                                                9))]
                                                          [scan : i64 0]
                                                          (begin
                                                            (while (<
                                                              scan
                                                              (comptime.expr-list-length
                                                                named-name-items))
                                                              (begin
                                                                (if (string.eq
                                                                  (comptime.expr-string-value
                                                                    (comptime.expr-list-nth
                                                                      named-name-items
                                                                      scan))
                                                                  name)
                                                                  (set!
                                                                    resolved-width
                                                                    (comptime.expr-list-nth
                                                                      named-var-items
                                                                      scan))
                                                                  unit)
                                                                (set!
                                                                  scan
                                                                  (+ scan 1))))
                                                            (set! scan 0)
                                                            (while (<
                                                              scan
                                                              (comptime.expr-list-length
                                                                capture-names))
                                                              (begin
                                                                (if (string.eq
                                                                  (comptime.expr-string-value
                                                                    (comptime.expr-list-nth
                                                                      capture-names
                                                                      scan))
                                                                  name)
                                                                  (set!
                                                                    resolved-width
                                                                    (comptime.expr-list-nth
                                                                      capture-vars
                                                                      scan))
                                                                  unit)
                                                                (set!
                                                                  scan
                                                                  (+ scan 1))))))
                                                        (set!
                                                          resolved-width
                                                          (comptime.expr-list-nth
                                                            fields
                                                            9))))
                                                    (match (comptime.expr-list-nth
                                                      fields
                                                      10)
                                                      [(comptime.Expr.Int found)
                                                        (set!
                                                          precision-kind
                                                          found)]
                                                      [_ unit])
                                                    (if (if (= precision-kind 2)
                                                      true
                                                      (= precision-kind 4))
                                                      (match (comptime.expr-list-nth
                                                        fields
                                                        11)
                                                        [(comptime.Expr.Int
                                                            precision-index)
                                                          (set!
                                                            resolved-precision
                                                            (comptime.expr-list-nth
                                                              positional-items
                                                              precision-index))]
                                                        [_ unit])
                                                      (if (= precision-kind 3)
                                                        (let
                                                          [name : String
                                                            (comptime.expr-string-value
                                                              (comptime.expr-list-nth
                                                                fields
                                                                11))]
                                                          [scan : i64 0]
                                                          (begin
                                                            (while (<
                                                              scan
                                                              (comptime.expr-list-length
                                                                named-name-items))
                                                              (begin
                                                                (if (string.eq
                                                                  (comptime.expr-string-value
                                                                    (comptime.expr-list-nth
                                                                      named-name-items
                                                                      scan))
                                                                  name)
                                                                  (set!
                                                                    resolved-precision
                                                                    (comptime.expr-list-nth
                                                                      named-var-items
                                                                      scan))
                                                                  unit)
                                                                (set!
                                                                  scan
                                                                  (+ scan 1))))
                                                            (set! scan 0)
                                                            (while (<
                                                              scan
                                                              (comptime.expr-list-length
                                                                capture-names))
                                                              (begin
                                                                (if (string.eq
                                                                  (comptime.expr-string-value
                                                                    (comptime.expr-list-nth
                                                                      capture-names
                                                                      scan))
                                                                  name)
                                                                  (set!
                                                                    resolved-precision
                                                                    (comptime.expr-list-nth
                                                                      capture-vars
                                                                      scan))
                                                                  unit)
                                                                (set!
                                                                  scan
                                                                  (+ scan 1))))))
                                                        (set!
                                                          resolved-precision
                                                          (comptime.expr-list-nth
                                                            fields
                                                            11))))
                                                    (set!
                                                      output
                                                      (comptime.expr-list-cons
                                                        `(stdlib.format.format-value
                                                          ,selected
                                                          ,(comptime.expr-list-nth
                                                            fields
                                                            3)
                                                          ,(comptime.expr-list-nth
                                                            fields
                                                            4)
                                                          ,(comptime.expr-list-nth
                                                            fields
                                                            5)
                                                          ,(comptime.expr-list-nth
                                                            fields
                                                            6)
                                                          ,(comptime.expr-list-nth
                                                            fields
                                                            7)
                                                          ,(comptime.expr-list-nth
                                                            fields
                                                            8)
                                                          ,resolved-width
                                                          ,(comptime.expr-list-nth
                                                            fields
                                                            10)
                                                          ,resolved-precision
                                                          ,(comptime.expr-list-nth
                                                            fields
                                                            12))
                                                        output)))))
                                              (set!
                                                piece-index
                                                (+ piece-index 1)))))
                                        (let
                                          [result : comptime.Expr
                                            `(stdlib.str_cat.str-cat ,@output)]
                                          [capture-index : i64 0]
                                          [binding-index : i64
                                            (-
                                              (comptime.expr-list-length
                                                binding-items)
                                              1)]
                                          (begin
                                            ;; Captures are reverse template
                                            ;; order; supplied bindings are
                                            ;; forward source order. The letter
                                            ;; s at generated-name offset 12
                                            ;; marks a shared binding.
                                            (while (<
                                              capture-index
                                              (comptime.expr-list-length
                                                capture-bindings))
                                              (match (comptime.expr-list-nth
                                                capture-bindings
                                                capture-index)
                                                [(comptime.Expr.Begin entry)
                                                  (match (comptime.expr-list-nth
                                                    entry
                                                    0)
                                                    [(comptime.Expr.Var
                                                        binding-name)
                                                      (let
                                                        [init : comptime.Expr
                                                          (comptime.expr-list-nth
                                                            entry
                                                            1)]
                                                        (if (=
                                                          (cast
                                                            (string.string-ref
                                                              binding-name
                                                              12)
                                                            : i64)
                                                          115)
                                                          (set!
                                                            result
                                                            (comptime.expr-shared-let-scope
                                                              binding-name
                                                              init
                                                              result))
                                                          (set!
                                                            result
                                                            (comptime.expr-let-scope
                                                              binding-name
                                                              init
                                                              result))))]
                                                    [_
                                                      (comptime.comptime-error
                                                        "format: internal capture binding is malformed")])]
                                                [_
                                                  (comptime.comptime-error
                                                    "format: internal capture binding is malformed")])
                                              (set!
                                                capture-index
                                                (+ capture-index 1)))
                                            (while (>= binding-index 0)
                                              (match (comptime.expr-list-nth
                                                binding-items
                                                binding-index)
                                                [(comptime.Expr.Begin entry)
                                                  (match (comptime.expr-list-nth
                                                    entry
                                                    0)
                                                    [(comptime.Expr.Var
                                                        binding-name)
                                                      (let
                                                        [init : comptime.Expr
                                                          (comptime.expr-list-nth
                                                            entry
                                                            1)]
                                                        (if (=
                                                          (cast
                                                            (string.string-ref
                                                              binding-name
                                                              12)
                                                            : i64)
                                                          115)
                                                          (set!
                                                            result
                                                            (comptime.expr-shared-let-scope
                                                              binding-name
                                                              init
                                                              result))
                                                          (set!
                                                            result
                                                            (comptime.expr-let-scope
                                                              binding-name
                                                              init
                                                              result))))]
                                                    [_
                                                      (comptime.comptime-error
                                                        "format: internal supplied binding is malformed")])]
                                                [_
                                                  (comptime.comptime-error
                                                    "format: internal supplied binding is malformed")])
                                              (set!
                                                binding-index
                                                (- binding-index 1)))
                                            result))))))]
                              [_
                                (comptime.comptime-error
                                  "format: internal binding carrier is malformed")])]
                          [_
                            (comptime.comptime-error
                              "format: internal named variable carrier is malformed")])]
                      [_
                        (comptime.comptime-error
                          "format: internal named argument carrier is malformed")])]
                  [_
                    (comptime.comptime-error
                      "format: internal positional carrier is malformed")])]
              [_
                (comptime.comptime-error
                  "format: internal plan carrier is malformed")]))]
        [_
          (comptime.comptime-error
            "format: internal argument carrier is malformed")])]
    [_
      (comptime.comptime-error
        "format: internal argument index is not an integer")]))

;: Bind supplied arguments, validate a completed plan, and select its sink.
(defmacro (format-expand-mode-complete
  [plan : comptime.Expr]
  [argument-carrier : comptime.Expr]
  [stream-address : comptime.Expr]
  [named-seen : comptime.Expr]
  [positional-vars : comptime.Expr]
  [named-names : comptime.Expr]
  [named-vars : comptime.Expr]
  [bindings : comptime.Expr]) : comptime.Expr
  (let
    [immediate : comptime.Expr
      `(stdlib.format.format-expand-mode
        ,plan
        ,argument-carrier
        ,stream-address
        9223372036854775807
        ,named-seen
        ,positional-vars
        ,named-names
        ,named-vars
        ,bindings)]
    (match stream-address
      [(comptime.Expr.Call retained-callee retained-items)
        (if (= (comptime.expr-list-length retained-items) 0)
          (match retained-callee
            [(comptime.Expr.Var retained-name)
              (if (string.eq retained-name "__tl_format_retained_sink")
                `(stdlib.format.format-expand-arguments-finish
                  ,plan
                  ,positional-vars
                  ,named-names
                  ,named-vars
                  ,bindings)
                immediate)]
            [_ immediate])
          immediate)]
      [_ immediate])))

(defmacro (format-expand-mode
  [plan : comptime.Expr]
  [argument-carrier : comptime.Expr]
  [stream-address : comptime.Expr]
  [argument-index : comptime.Expr]
  [named-seen : comptime.Expr]
  [positional-vars : comptime.Expr]
  [named-names : comptime.Expr]
  [named-vars : comptime.Expr]
  [bindings : comptime.Expr]) : comptime.Expr
  (match argument-index
    [(comptime.Expr.Int index)
      (match argument-carrier
        [(comptime.Expr.Call _ arguments)
          (if (< index (comptime.expr-list-length arguments))
            (let
              [argument : comptime.Expr
                (comptime.expr-list-nth arguments index)]
              `(stdlib.format.format-expand-mode-call
                ,plan
                ,argument-carrier
                ,stream-address
                ,argument-index
                ,named-seen
                ,positional-vars
                ,named-names
                ,named-vars
                ,bindings
                ,argument))
            (if (!= index 9223372036854775807)
              `(stdlib.format.format-expand-mode-complete
                ,plan
                ,argument-carrier
                ,stream-address
                ,named-seen
                ,positional-vars
                ,named-names
                ,named-vars
                ,bindings)
              (match plan
                [(comptime.Expr.Call _ plan-pieces)
                  (match positional-vars
                    [(comptime.Expr.Call _ positional-items)
                      (match named-names
                        [(comptime.Expr.Call _ named-name-items)
                          (match named-vars
                            [(comptime.Expr.Call _ named-var-items)
                              (match bindings
                                [(comptime.Expr.Call _ binding-items)
                                  (let
                                    [plan-len : i64
                                      (comptime.expr-list-length plan-pieces)]
                                    [positional-count : i64
                                      (comptime.expr-list-length
                                        positional-items)]
                                    [capture-names : comptime.ExprList
                                      (comptime.expr-list-empty)]
                                    [capture-vars : comptime.ExprList
                                      (comptime.expr-list-empty)]
                                    [capture-bindings : comptime.ExprList
                                      (comptime.expr-list-empty)]
                                    [capture-count : i64 0]
                                    [plan-index : i64 (- plan-len 1)]
                                    (begin
                                      ;; Validate every placeholder carrier and
                                      ;; every positional value/count reference.
                                      (while (>= plan-index 0)
                                        (let
                                          [piece : comptime.Expr
                                            (comptime.expr-list-nth
                                              plan-pieces
                                              plan-index)]
                                          [fields : comptime.ExprList
                                            (comptime.expr-list-empty)]
                                          (begin
                                            (match piece
                                              [(comptime.Expr.Begin
                                                  found-fields)
                                                (set! fields found-fields)]
                                              [_ unit])
                                            (if (comptime.expr-string? piece)
                                              unit
                                              (if (!=
                                                (comptime.expr-list-length
                                                  fields)
                                                14)
                                                (comptime.comptime-error
                                                  "format: internal placeholder plan is malformed")
                                                (let
                                                  [selector-kind : i64 -1]
                                                  [implicit-state : i64 -1]
                                                  [width-kind : i64 -1]
                                                  [precision-kind : i64 -1]
                                                  (begin
                                                    (match (comptime.expr-list-nth
                                                      fields
                                                      0)
                                                      [(comptime.Expr.Int found)
                                                        (set!
                                                          selector-kind
                                                          found)]
                                                      [_ unit])
                                                    (match (comptime.expr-list-nth
                                                      fields
                                                      2)
                                                      [(comptime.Expr.Int found)
                                                        (set!
                                                          implicit-state
                                                          found)]
                                                      [_ unit])
                                                    (match (comptime.expr-list-nth
                                                      fields
                                                      8)
                                                      [(comptime.Expr.Int found)
                                                        (set! width-kind found)]
                                                      [_ unit])
                                                    (match (comptime.expr-list-nth
                                                      fields
                                                      10)
                                                      [(comptime.Expr.Int found)
                                                        (set!
                                                          precision-kind
                                                          found)]
                                                      [_ unit])
                                                    (if (= selector-kind 0)
                                                      (match (comptime.expr-list-nth
                                                        fields
                                                        1)
                                                        [(comptime.Expr.Int
                                                            selected)
                                                          (if (>=
                                                            selected
                                                            positional-count)
                                                            (if (!=
                                                              implicit-state
                                                              0)
                                                              (comptime.comptime-error
                                                                "format: not enough arguments for placeholders")
                                                              (comptime.comptime-error
                                                                (comptime.string-append
                                                                  "format: positional argument index is out of range: "
                                                                  (comptime.int->string
                                                                    selected))))
                                                            unit)]
                                                        [_
                                                          (comptime.comptime-error
                                                            "format: internal positional selector is malformed")])
                                                      (if (= selector-kind 1)
                                                        (let
                                                          [selector-value : comptime.Expr
                                                            (comptime.expr-list-nth
                                                              fields
                                                              1)]
                                                          (if (not
                                                            (comptime.expr-string?
                                                              selector-value))
                                                            (comptime.comptime-error
                                                              "format: internal named selector is malformed")
                                                            unit))
                                                        (comptime.comptime-error
                                                          "format: internal selector kind is malformed")))
                                                    ;; Macro CTFE cannot invoke `cond`.
                                                    ;; lint-allow: nested-if-ladder
                                                    (if (= width-kind 2)
                                                      (match (comptime.expr-list-nth
                                                        fields
                                                        9)
                                                        [(comptime.Expr.Int
                                                            selected)
                                                          (if (>=
                                                            selected
                                                            positional-count)
                                                            (comptime.comptime-error
                                                              (comptime.string-append
                                                                "format: dynamic width argument index is out of range: "
                                                                (comptime.int->string
                                                                  selected)))
                                                            unit)]
                                                        [_
                                                          (comptime.comptime-error
                                                            "format: internal width reference is malformed")])
                                                      (if (< width-kind 0)
                                                        (comptime.comptime-error
                                                          "format: internal width kind is malformed")
                                                        (if (> width-kind 3)
                                                          (comptime.comptime-error
                                                            "format: internal width kind is malformed")
                                                          unit)))
                                                    ;; Macro CTFE cannot invoke `cond`.
                                                    ;; lint-allow: nested-if-ladder
                                                    (if (if (= precision-kind 2)
                                                      true
                                                      (= precision-kind 4))
                                                      (match (comptime.expr-list-nth
                                                        fields
                                                        11)
                                                        [(comptime.Expr.Int
                                                            selected)
                                                          (if (>=
                                                            selected
                                                            positional-count)
                                                            (comptime.comptime-error
                                                              (comptime.string-append
                                                                "format: dynamic precision argument index is out of range: "
                                                                (comptime.int->string
                                                                  selected)))
                                                            unit)]
                                                        [_
                                                          (comptime.comptime-error
                                                            "format: internal precision reference is malformed")])
                                                      (if (< precision-kind 0)
                                                        (comptime.comptime-error
                                                          "format: internal precision kind is malformed")
                                                        (if (> precision-kind 4)
                                                          (comptime.comptime-error
                                                            "format: internal precision kind is malformed")
                                                          unit)))))))
                                            (set! plan-index (- plan-index 1)))))
                                      ;; Every positional value/count reference
                                      ;; counts as a use. Scanner-resolved star
                                      ;; counts have already advanced the implicit
                                      ;; iterator; dollar references have not.
                                      (let
                                        [positional-index : i64 0]
                                        (while (<
                                          positional-index
                                          positional-count)
                                          (let
                                            [used? : bool false]
                                            [piece-index : i64 0]
                                            (begin
                                              (while (< piece-index plan-len)
                                                (let
                                                  [piece : comptime.Expr
                                                    (comptime.expr-list-nth
                                                      plan-pieces
                                                      piece-index)]
                                                  [fields : comptime.ExprList
                                                    (comptime.expr-list-empty)]
                                                  [slot : i64 0]
                                                  (begin
                                                    (match piece
                                                      [(comptime.Expr.Begin
                                                          found-fields)
                                                        (set!
                                                          fields
                                                          found-fields)]
                                                      [_ unit])
                                                    (if (=
                                                      (comptime.expr-list-length
                                                        fields)
                                                      14)
                                                      (while (< slot 3)
                                                        (let
                                                          [reference-kind : i64
                                                            -1]
                                                          [reference-value : comptime.Expr
                                                            (comptime.expr-int
                                                              0)]
                                                          (begin
                                                            (if (= slot 0)
                                                              (begin
                                                                (match (comptime.expr-list-nth
                                                                  fields
                                                                  0)
                                                                  [(comptime.Expr.Int
                                                                      found)
                                                                    (set!
                                                                      reference-kind
                                                                      found)]
                                                                  [_ unit])
                                                                (set!
                                                                  reference-value
                                                                  (comptime.expr-list-nth
                                                                    fields
                                                                    1)))
                                                              (if (= slot 1)
                                                                (begin
                                                                  (match (comptime.expr-list-nth
                                                                    fields
                                                                    8)
                                                                    [(comptime.Expr.Int
                                                                        found)
                                                                      (set!
                                                                        reference-kind
                                                                        found)]
                                                                    [_ unit])
                                                                  (set!
                                                                    reference-value
                                                                    (comptime.expr-list-nth
                                                                      fields
                                                                      9)))
                                                                (begin
                                                                  (match (comptime.expr-list-nth
                                                                    fields
                                                                    10)
                                                                    [(comptime.Expr.Int
                                                                        found)
                                                                      (set!
                                                                        reference-kind
                                                                        found)]
                                                                    [_ unit])
                                                                  (set!
                                                                    reference-value
                                                                    (comptime.expr-list-nth
                                                                      fields
                                                                      11)))))
                                                            (if (= slot 0)
                                                              (if (=
                                                                reference-kind
                                                                0)
                                                                (match reference-value
                                                                  [(comptime.Expr.Int
                                                                      selected)
                                                                    (if (=
                                                                      selected
                                                                      positional-index)
                                                                      (set!
                                                                        used?
                                                                        true)
                                                                      unit)]
                                                                  [_ unit])
                                                                unit)
                                                              (if (if (=
                                                                reference-kind
                                                                2)
                                                                true
                                                                (if (= slot 2)
                                                                  (=
                                                                    reference-kind
                                                                    4)
                                                                  false))
                                                                (match reference-value
                                                                  [(comptime.Expr.Int
                                                                      selected)
                                                                    (if (=
                                                                      selected
                                                                      positional-index)
                                                                      (set!
                                                                        used?
                                                                        true)
                                                                      unit)]
                                                                  [_ unit])
                                                                unit))
                                                            (set!
                                                              slot
                                                              (+ slot 1)))))
                                                      unit)
                                                    (set!
                                                      piece-index
                                                      (+ piece-index 1)))))
                                              (if (not used?)
                                                (comptime.comptime-error
                                                  (comptime.string-append
                                                    "format: not enough placeholders for arguments; unused positional argument "
                                                    (comptime.int->string
                                                      positional-index)))
                                                unit)
                                              (set!
                                                positional-index
                                                (+ positional-index 1))))))
                                      ;; Explicit named values may be selected as
                                      ;; either the rendered value or a count.
                                      (let
                                        [named-index : i64 0]
                                        (while (<
                                          named-index
                                          (comptime.expr-list-length
                                            named-name-items))
                                          (let
                                            [name : String
                                              (comptime.expr-string-value
                                                (comptime.expr-list-nth
                                                  named-name-items
                                                  named-index))]
                                            [used? : bool false]
                                            [piece-index : i64 0]
                                            (begin
                                              (while (< piece-index plan-len)
                                                (let
                                                  [piece : comptime.Expr
                                                    (comptime.expr-list-nth
                                                      plan-pieces
                                                      piece-index)]
                                                  [fields : comptime.ExprList
                                                    (comptime.expr-list-empty)]
                                                  [slot : i64 0]
                                                  (begin
                                                    (match piece
                                                      [(comptime.Expr.Begin
                                                          found-fields)
                                                        (set!
                                                          fields
                                                          found-fields)]
                                                      [_ unit])
                                                    (if (=
                                                      (comptime.expr-list-length
                                                        fields)
                                                      14)
                                                      (while (< slot 3)
                                                        (let
                                                          [reference-kind : i64
                                                            -1]
                                                          [reference-value : comptime.Expr
                                                            (comptime.expr-int
                                                              0)]
                                                          (begin
                                                            (if (= slot 0)
                                                              (begin
                                                                (match (comptime.expr-list-nth
                                                                  fields
                                                                  0)
                                                                  [(comptime.Expr.Int
                                                                      found)
                                                                    (set!
                                                                      reference-kind
                                                                      found)]
                                                                  [_ unit])
                                                                (set!
                                                                  reference-value
                                                                  (comptime.expr-list-nth
                                                                    fields
                                                                    1)))
                                                              (if (= slot 1)
                                                                (begin
                                                                  (match (comptime.expr-list-nth
                                                                    fields
                                                                    8)
                                                                    [(comptime.Expr.Int
                                                                        found)
                                                                      (set!
                                                                        reference-kind
                                                                        found)]
                                                                    [_ unit])
                                                                  (set!
                                                                    reference-value
                                                                    (comptime.expr-list-nth
                                                                      fields
                                                                      9)))
                                                                (begin
                                                                  (match (comptime.expr-list-nth
                                                                    fields
                                                                    10)
                                                                    [(comptime.Expr.Int
                                                                        found)
                                                                      (set!
                                                                        reference-kind
                                                                        found)]
                                                                    [_ unit])
                                                                  (set!
                                                                    reference-value
                                                                    (comptime.expr-list-nth
                                                                      fields
                                                                      11)))))
                                                            (if (= slot 0)
                                                              (if (=
                                                                reference-kind
                                                                1)
                                                                (if (string.eq
                                                                  (comptime.expr-string-value
                                                                    reference-value)
                                                                  name)
                                                                  (set!
                                                                    used?
                                                                    true)
                                                                  unit)
                                                                unit)
                                                              (if (=
                                                                reference-kind
                                                                3)
                                                                (if (string.eq
                                                                  (comptime.expr-string-value
                                                                    reference-value)
                                                                  name)
                                                                  (set!
                                                                    used?
                                                                    true)
                                                                  unit)
                                                                unit))
                                                            (set!
                                                              slot
                                                              (+ slot 1)))))
                                                      unit)
                                                    (set!
                                                      piece-index
                                                      (+ piece-index 1)))))
                                              (if (not used?)
                                                (comptime.comptime-error
                                                  (comptime.string-append
                                                    "format: unused named argument "
                                                    name))
                                                unit)
                                              (set!
                                                named-index
                                                (+ named-index 1))))))
                                      ;; Discover selector/count captures in
                                      ;; template order, once per lexical name.
                                      (set! plan-index (- plan-len 1))
                                      (while (>= plan-index 0)
                                        (let
                                          [piece : comptime.Expr
                                            (comptime.expr-list-nth
                                              plan-pieces
                                              plan-index)]
                                          [fields : comptime.ExprList
                                            (comptime.expr-list-empty)]
                                          [slot : i64 0]
                                          (begin
                                            (match piece
                                              [(comptime.Expr.Begin
                                                  found-fields)
                                                (set! fields found-fields)]
                                              [_ unit])
                                            (if (=
                                              (comptime.expr-list-length fields)
                                              14)
                                              (while (< slot 3)
                                                (let
                                                  [reference-kind : i64 -1]
                                                  [reference-value : comptime.Expr
                                                    (comptime.expr-int 0)]
                                                  [named-reference? : bool
                                                    false]
                                                  (begin
                                                    (if (= slot 0)
                                                      (begin
                                                        (match (comptime.expr-list-nth
                                                          fields
                                                          0)
                                                          [(comptime.Expr.Int
                                                              found)
                                                            (set!
                                                              reference-kind
                                                              found)]
                                                          [_ unit])
                                                        (set!
                                                          reference-value
                                                          (comptime.expr-list-nth
                                                            fields
                                                            1)))
                                                      (if (= slot 1)
                                                        (begin
                                                          (match (comptime.expr-list-nth
                                                            fields
                                                            8)
                                                            [(comptime.Expr.Int
                                                                found)
                                                              (set!
                                                                reference-kind
                                                                found)]
                                                            [_ unit])
                                                          (set!
                                                            reference-value
                                                            (comptime.expr-list-nth
                                                              fields
                                                              9)))
                                                        (begin
                                                          (match (comptime.expr-list-nth
                                                            fields
                                                            10)
                                                            [(comptime.Expr.Int
                                                                found)
                                                              (set!
                                                                reference-kind
                                                                found)]
                                                            [_ unit])
                                                          (set!
                                                            reference-value
                                                            (comptime.expr-list-nth
                                                              fields
                                                              11)))))
                                                    (if (= slot 0)
                                                      (if (= reference-kind 1)
                                                        (set!
                                                          named-reference?
                                                          true)
                                                        unit)
                                                      (if (= reference-kind 3)
                                                        (set!
                                                          named-reference?
                                                          true)
                                                        unit))
                                                    (if named-reference?
                                                      (let
                                                        [name : String
                                                          (comptime.expr-string-value
                                                            reference-value)]
                                                        [explicit-index : i64
                                                          -1]
                                                        [capture-index : i64 -1]
                                                        [explicit-scan : i64 0]
                                                        [capture-scan : i64 0]
                                                        (begin
                                                          (while (<
                                                            explicit-scan
                                                            (comptime.expr-list-length
                                                              named-name-items))
                                                            (begin
                                                              (if (string.eq
                                                                (comptime.expr-string-value
                                                                  (comptime.expr-list-nth
                                                                    named-name-items
                                                                    explicit-scan))
                                                                name)
                                                                (set!
                                                                  explicit-index
                                                                  explicit-scan)
                                                                unit)
                                                              (set!
                                                                explicit-scan
                                                                (+
                                                                  explicit-scan
                                                                  1))))
                                                          (while (<
                                                            capture-scan
                                                            (comptime.expr-list-length
                                                              capture-names))
                                                            (begin
                                                              (if (string.eq
                                                                (comptime.expr-string-value
                                                                  (comptime.expr-list-nth
                                                                    capture-names
                                                                    capture-scan))
                                                                name)
                                                                (set!
                                                                  capture-index
                                                                  capture-scan)
                                                                unit)
                                                              (set!
                                                                capture-scan
                                                                (+
                                                                  capture-scan
                                                                  1))))
                                                          (if (<
                                                            explicit-index
                                                            0)
                                                            (if (<
                                                              capture-index
                                                              0)
                                                              (let
                                                                [capture-expr : comptime.Expr
                                                                  (comptime.expr-var
                                                                    name)]
                                                                [fresh-name : String
                                                                  (comptime.syntax-name-fresh
                                                                    (comptime.string-append
                                                                      "__tl_format_shared_capture_"
                                                                      (comptime.int->string
                                                                        capture-count)))]
                                                                [fresh-var : comptime.Expr
                                                                  (comptime.expr-var
                                                                    fresh-name)]
                                                                [entry-items : comptime.ExprList
                                                                  (comptime.expr-list-cons
                                                                    fresh-var
                                                                    (comptime.expr-list-cons
                                                                      capture-expr
                                                                      (comptime.expr-list-empty)))]
                                                                (begin
                                                                  (set!
                                                                    capture-names
                                                                    (comptime.expr-list-cons
                                                                      (comptime.expr-string
                                                                        name)
                                                                      capture-names))
                                                                  (set!
                                                                    capture-vars
                                                                    (comptime.expr-list-cons
                                                                      fresh-var
                                                                      capture-vars))
                                                                  (set!
                                                                    capture-bindings
                                                                    (comptime.expr-list-cons
                                                                      (comptime.expr-begin-unit
                                                                        entry-items)
                                                                      capture-bindings))
                                                                  (set!
                                                                    capture-count
                                                                    (+
                                                                      capture-count
                                                                      1))))
                                                              unit)
                                                            unit)))
                                                      unit)
                                                    (set! slot (+ slot 1)))))
                                              unit)
                                            (set! plan-index (- plan-index 1)))))
                                      ;; Render the reverse plan into forward flat
                                      ;; concat operands while resolving names.
                                      (let
                                        [output : comptime.ExprList
                                          (comptime.expr-list-empty)]
                                        [piece-index : i64 0]
                                        (begin
                                          (while (< piece-index plan-len)
                                            (let
                                              [piece : comptime.Expr
                                                (comptime.expr-list-nth
                                                  plan-pieces
                                                  piece-index)]
                                              [fields : comptime.ExprList
                                                (comptime.expr-list-empty)]
                                              (begin
                                                (match piece
                                                  [(comptime.Expr.Begin
                                                      found-fields)
                                                    (set! fields found-fields)]
                                                  [_ unit])
                                                (if (comptime.expr-string?
                                                  piece)
                                                  (set!
                                                    output
                                                    (comptime.expr-list-cons
                                                      piece
                                                      output))
                                                  (let
                                                    [selector-kind : i64 -1]
                                                    [selected : comptime.Expr
                                                      (comptime.expr-int 0)]
                                                    [width-kind : i64 -1]
                                                    [resolved-width : comptime.Expr
                                                      (comptime.expr-int 0)]
                                                    [precision-kind : i64 -1]
                                                    [resolved-precision : comptime.Expr
                                                      (comptime.expr-int 0)]
                                                    (begin
                                                      (match (comptime.expr-list-nth
                                                        fields
                                                        0)
                                                        [(comptime.Expr.Int
                                                            found)
                                                          (set!
                                                            selector-kind
                                                            found)]
                                                        [_ unit])
                                                      (if (= selector-kind 0)
                                                        (match (comptime.expr-list-nth
                                                          fields
                                                          1)
                                                          [(comptime.Expr.Int
                                                              selected-index)
                                                            (set!
                                                              selected
                                                              (comptime.expr-list-nth
                                                                positional-items
                                                                selected-index))]
                                                          [_ unit])
                                                        (let
                                                          [name : String
                                                            (comptime.expr-string-value
                                                              (comptime.expr-list-nth
                                                                fields
                                                                1))]
                                                          [scan : i64 0]
                                                          (begin
                                                            (while (<
                                                              scan
                                                              (comptime.expr-list-length
                                                                named-name-items))
                                                              (begin
                                                                (if (string.eq
                                                                  (comptime.expr-string-value
                                                                    (comptime.expr-list-nth
                                                                      named-name-items
                                                                      scan))
                                                                  name)
                                                                  (set!
                                                                    selected
                                                                    (comptime.expr-list-nth
                                                                      named-var-items
                                                                      scan))
                                                                  unit)
                                                                (set!
                                                                  scan
                                                                  (+ scan 1))))
                                                            (set! scan 0)
                                                            (while (<
                                                              scan
                                                              (comptime.expr-list-length
                                                                capture-names))
                                                              (begin
                                                                (if (string.eq
                                                                  (comptime.expr-string-value
                                                                    (comptime.expr-list-nth
                                                                      capture-names
                                                                      scan))
                                                                  name)
                                                                  (set!
                                                                    selected
                                                                    (comptime.expr-list-nth
                                                                      capture-vars
                                                                      scan))
                                                                  unit)
                                                                (set!
                                                                  scan
                                                                  (+ scan 1)))))))
                                                      (match (comptime.expr-list-nth
                                                        fields
                                                        8)
                                                        [(comptime.Expr.Int
                                                            found)
                                                          (set!
                                                            width-kind
                                                            found)]
                                                        [_ unit])
                                                      (if (= width-kind 2)
                                                        (match (comptime.expr-list-nth
                                                          fields
                                                          9)
                                                          [(comptime.Expr.Int
                                                              width-index)
                                                            (set!
                                                              resolved-width
                                                              (comptime.expr-list-nth
                                                                positional-items
                                                                width-index))]
                                                          [_ unit])
                                                        (if (= width-kind 3)
                                                          (let
                                                            [name : String
                                                              (comptime.expr-string-value
                                                                (comptime.expr-list-nth
                                                                  fields
                                                                  9))]
                                                            [scan : i64 0]
                                                            (begin
                                                              (while (<
                                                                scan
                                                                (comptime.expr-list-length
                                                                  named-name-items))
                                                                (begin
                                                                  (if (string.eq
                                                                    (comptime.expr-string-value
                                                                      (comptime.expr-list-nth
                                                                        named-name-items
                                                                        scan))
                                                                    name)
                                                                    (set!
                                                                      resolved-width
                                                                      (comptime.expr-list-nth
                                                                        named-var-items
                                                                        scan))
                                                                    unit)
                                                                  (set!
                                                                    scan
                                                                    (+ scan 1))))
                                                              (set! scan 0)
                                                              (while (<
                                                                scan
                                                                (comptime.expr-list-length
                                                                  capture-names))
                                                                (begin
                                                                  (if (string.eq
                                                                    (comptime.expr-string-value
                                                                      (comptime.expr-list-nth
                                                                        capture-names
                                                                        scan))
                                                                    name)
                                                                    (set!
                                                                      resolved-width
                                                                      (comptime.expr-list-nth
                                                                        capture-vars
                                                                        scan))
                                                                    unit)
                                                                  (set!
                                                                    scan
                                                                    (+ scan 1))))))
                                                          (set!
                                                            resolved-width
                                                            (comptime.expr-list-nth
                                                              fields
                                                              9))))
                                                      (match (comptime.expr-list-nth
                                                        fields
                                                        10)
                                                        [(comptime.Expr.Int
                                                            found)
                                                          (set!
                                                            precision-kind
                                                            found)]
                                                        [_ unit])
                                                      (if (if (=
                                                        precision-kind
                                                        2)
                                                        true
                                                        (= precision-kind 4))
                                                        (match (comptime.expr-list-nth
                                                          fields
                                                          11)
                                                          [(comptime.Expr.Int
                                                              precision-index)
                                                            (set!
                                                              resolved-precision
                                                              (comptime.expr-list-nth
                                                                positional-items
                                                                precision-index))]
                                                          [_ unit])
                                                        (if (= precision-kind 3)
                                                          (let
                                                            [name : String
                                                              (comptime.expr-string-value
                                                                (comptime.expr-list-nth
                                                                  fields
                                                                  11))]
                                                            [scan : i64 0]
                                                            (begin
                                                              (while (<
                                                                scan
                                                                (comptime.expr-list-length
                                                                  named-name-items))
                                                                (begin
                                                                  (if (string.eq
                                                                    (comptime.expr-string-value
                                                                      (comptime.expr-list-nth
                                                                        named-name-items
                                                                        scan))
                                                                    name)
                                                                    (set!
                                                                      resolved-precision
                                                                      (comptime.expr-list-nth
                                                                        named-var-items
                                                                        scan))
                                                                    unit)
                                                                  (set!
                                                                    scan
                                                                    (+ scan 1))))
                                                              (set! scan 0)
                                                              (while (<
                                                                scan
                                                                (comptime.expr-list-length
                                                                  capture-names))
                                                                (begin
                                                                  (if (string.eq
                                                                    (comptime.expr-string-value
                                                                      (comptime.expr-list-nth
                                                                        capture-names
                                                                        scan))
                                                                    name)
                                                                    (set!
                                                                      resolved-precision
                                                                      (comptime.expr-list-nth
                                                                        capture-vars
                                                                        scan))
                                                                    unit)
                                                                  (set!
                                                                    scan
                                                                    (+ scan 1))))))
                                                          (set!
                                                            resolved-precision
                                                            (comptime.expr-list-nth
                                                              fields
                                                              11))))
                                                      (set!
                                                        output
                                                        (comptime.expr-list-cons
                                                          `(stdlib.format.format-stream-value-at!
                                                            ,stream-address
                                                            ,selected
                                                            ,(comptime.expr-list-nth
                                                              fields
                                                              3)
                                                            ,(comptime.expr-list-nth
                                                              fields
                                                              4)
                                                            ,(comptime.expr-list-nth
                                                              fields
                                                              5)
                                                            ,(comptime.expr-list-nth
                                                              fields
                                                              6)
                                                            ,(comptime.expr-list-nth
                                                              fields
                                                              7)
                                                            ,(comptime.expr-list-nth
                                                              fields
                                                              8)
                                                            ,resolved-width
                                                            ,(comptime.expr-list-nth
                                                              fields
                                                              10)
                                                            ,resolved-precision
                                                            ,(comptime.expr-list-nth
                                                              fields
                                                              12))
                                                          output)))))
                                                (set!
                                                  piece-index
                                                  (+ piece-index 1)))))
                                          (let
                                            [result : comptime.Expr
                                              `(stdlib.str_cat.str-cat ,@output)]
                                            [write-items : comptime.ExprList
                                              (comptime.expr-list-empty)]
                                            [write-index : i64
                                              (-
                                                (comptime.expr-list-length
                                                  output)
                                                1)]
                                            [capture-index : i64 0]
                                            [binding-index : i64
                                              (-
                                                (comptime.expr-list-length
                                                  binding-items)
                                                1)]
                                            (begin
                                              (while (>= write-index 0)
                                                (begin
                                                  (set!
                                                    write-items
                                                    (comptime.expr-list-cons
                                                      `(stdlib.format.formatter-write-string-at!
                                                        ,stream-address
                                                        ,(comptime.expr-list-nth
                                                          output
                                                          write-index))
                                                      write-items))
                                                  (set!
                                                    write-index
                                                    (- write-index 1))))
                                              (set!
                                                result
                                                `(begin
                                                  ,@write-items
                                                  (stdlib.format.formatter-status-at
                                                    ,stream-address)))
                                              ;; Captures are reverse template
                                              ;; order; supplied bindings are
                                              ;; forward source order. The letter
                                              ;; s at generated-name offset 12
                                              ;; marks a shared binding.
                                              (while (<
                                                capture-index
                                                (comptime.expr-list-length
                                                  capture-bindings))
                                                (match (comptime.expr-list-nth
                                                  capture-bindings
                                                  capture-index)
                                                  [(comptime.Expr.Begin entry)
                                                    (match (comptime.expr-list-nth
                                                      entry
                                                      0)
                                                      [(comptime.Expr.Var
                                                          binding-name)
                                                        (let
                                                          [init : comptime.Expr
                                                            (comptime.expr-list-nth
                                                              entry
                                                              1)]
                                                          (if (=
                                                            (cast
                                                              (string.string-ref
                                                                binding-name
                                                                12)
                                                              : i64)
                                                            115)
                                                            (set!
                                                              result
                                                              (comptime.expr-shared-let-scope
                                                                binding-name
                                                                init
                                                                result))
                                                            (set!
                                                              result
                                                              (comptime.expr-let-scope
                                                                binding-name
                                                                init
                                                                result))))]
                                                      [_
                                                        (comptime.comptime-error
                                                          "format: internal capture binding is malformed")])]
                                                  [_
                                                    (comptime.comptime-error
                                                      "format: internal capture binding is malformed")])
                                                (set!
                                                  capture-index
                                                  (+ capture-index 1)))
                                              (while (>= binding-index 0)
                                                (match (comptime.expr-list-nth
                                                  binding-items
                                                  binding-index)
                                                  [(comptime.Expr.Begin entry)
                                                    (match (comptime.expr-list-nth
                                                      entry
                                                      0)
                                                      [(comptime.Expr.Var
                                                          binding-name)
                                                        (let
                                                          [init : comptime.Expr
                                                            (comptime.expr-list-nth
                                                              entry
                                                              1)]
                                                          (if (=
                                                            (cast
                                                              (string.string-ref
                                                                binding-name
                                                                12)
                                                              : i64)
                                                            115)
                                                            (set!
                                                              result
                                                              (comptime.expr-shared-let-scope
                                                                binding-name
                                                                init
                                                                result))
                                                            (set!
                                                              result
                                                              (comptime.expr-let-scope
                                                                binding-name
                                                                init
                                                                result))))]
                                                      [_
                                                        (comptime.comptime-error
                                                          "format: internal supplied binding is malformed")])]
                                                  [_
                                                    (comptime.comptime-error
                                                      "format: internal supplied binding is malformed")])
                                                (set!
                                                  binding-index
                                                  (- binding-index 1)))
                                              result))))))]
                                [_
                                  (comptime.comptime-error
                                    "format: internal binding carrier is malformed")])]
                            [_
                              (comptime.comptime-error
                                "format: internal named variable carrier is malformed")])]
                        [_
                          (comptime.comptime-error
                            "format: internal named argument carrier is malformed")])]
                    [_
                      (comptime.comptime-error
                        "format: internal positional carrier is malformed")])]
                [_
                  (comptime.comptime-error
                    "format: internal plan carrier is malformed")])))]
        [_
          (comptime.comptime-error
            "format: internal argument carrier is malformed")])]
    [_
      (comptime.comptime-error
        "format: internal argument index is not an integer")]))

;: Parse one literal template and expand it through the selected terminal mode.
;:
;: Each placeholder is one `__tl_format_placeholder` plan record containing
;: value selection plus all common options. Argument expansion resolves value
;: and count references, evaluates supplied values once in source order,
;: captures missing names at the call site, then emits either one flat
;: `str-cat` or immediate writer calls.
(defmacro (format-parse
  [template : comptime.Expr]
  [argument-carrier : comptime.Expr]
  [terminal : comptime.Expr]
  [stream-address : comptime.Expr]) : comptime.Expr
  (if (comptime.expr-string? template)
    (let
      [text : String (comptime.expr-string-value template)]
      [template-len : i64 (string.string-length text)]
      [plan-pieces : comptime.ExprList (comptime.expr-list-empty)]
      [index : i64 0]
      [literal-start : i64 0]
      [next-implicit : i64 0]
      (begin
        (while (< index template-len)
          (let
            [code : i64 (cast (string.string-ref text index) : i64)]
            (if (= code 123)
              (if (>= (+ index 1) template-len)
                (comptime.comptime-error "format: unmatched '{'")
                (let
                  [following : i64
                    (cast (string.string-ref text (+ index 1)) : i64)]
                  (if (= following 123)
                    (begin
                      (if (> index literal-start)
                        (set!
                          plan-pieces
                          (comptime.expr-list-cons
                            (comptime.expr-string
                              (comptime.string-slice
                                text
                                literal-start
                                (- index literal-start)))
                            plan-pieces))
                        unit)
                      (set!
                        plan-pieces
                        (comptime.expr-list-cons
                          (comptime.expr-string "{")
                          plan-pieces))
                      (set! index (+ index 2))
                      (set! literal-start index))
                    (let
                      [close : i64 (+ index 1)]
                      [searching : bool true]
                      (begin
                        (while searching
                          (if (< close template-len)
                            (if (!=
                              (cast (string.string-ref text close) : i64)
                              125)
                              (set! close (+ close 1))
                              (set! searching false))
                            (set! searching false)))
                        (if (>= close template-len)
                          (comptime.comptime-error "format: unmatched '{'")
                          unit)
                        (if (> index literal-start)
                          (set!
                            plan-pieces
                            (comptime.expr-list-cons
                              (comptime.expr-string
                                (comptime.string-slice
                                  text
                                  literal-start
                                  (- index literal-start)))
                              plan-pieces))
                          unit)
                        (let
                          [placeholder-start : i64 (+ index 1)]
                          [placeholder-end : i64 close]
                          [trimming : bool true]
                          (begin
                            (while trimming
                              (if (> placeholder-end placeholder-start)
                                (let
                                  [whitespace-code : i64
                                    (cast
                                      (string.string-ref
                                        text
                                        (- placeholder-end 1))
                                      : i64)]
                                  ;; CTFE cannot invoke the surface `cond` macro.
                                  ;; lint-allow: nested-if-ladder
                                  (if (if (= whitespace-code 9)
                                    true
                                    (if (= whitespace-code 10)
                                      true
                                      (if (= whitespace-code 11)
                                        true
                                        (if (= whitespace-code 12)
                                          true
                                          (if (= whitespace-code 13)
                                            true
                                            (= whitespace-code 32))))))
                                    (set! placeholder-end (- placeholder-end 1))
                                    (set! trimming false)))
                                (set! trimming false)))
                            (let
                              [colon : i64 -1]
                              [scan : i64 placeholder-start]
                              [argument-end : i64 placeholder-end]
                              [selector-kind : i64 0]
                              [selector-value : comptime.Expr
                                (comptime.expr-int 0)]
                              [implicit-state : i64 0]
                              [fill-code : i64 32]
                              [alignment : i64 0]
                              [sign : i64 0]
                              [alternate : i64 0]
                              [zero : i64 0]
                              [width-kind : i64 0]
                              [width-value : comptime.Expr
                                (comptime.expr-int 0)]
                              [precision-kind : i64 0]
                              [precision-value : comptime.Expr
                                (comptime.expr-int 0)]
                              [type-selector : String ""]
                              [valid-type-selector? : bool false]
                              (begin
                                (while (< scan placeholder-end)
                                  (begin
                                    (if (if (< colon 0)
                                      (=
                                        (cast
                                          (string.string-ref text scan)
                                          : i64)
                                        58)
                                      false)
                                      (set! colon scan)
                                      unit)
                                    (set! scan (+ scan 1))))
                                (if (>= colon 0)
                                  (set! argument-end colon)
                                  unit)
                                ;; Parse the value selector before the colon.
                                (if (= placeholder-start argument-end)
                                  (begin
                                    (set! selector-kind 0)
                                    (set!
                                      selector-value
                                      (comptime.expr-int next-implicit))
                                    (set! implicit-state 1)
                                    (set! next-implicit (+ next-implicit 1)))
                                  (let
                                    [first-code : i64
                                      (cast
                                        (string.string-ref
                                          text
                                          placeholder-start)
                                        : i64)]
                                    [argument-len : i64
                                      (- argument-end placeholder-start)]
                                    [argument-scan : i64 placeholder-start]
                                    [has-hash : bool false]
                                    [has-whitespace : bool false]
                                    [has-non-ascii : bool false]
                                    (begin
                                      (while (< argument-scan argument-end)
                                        (let
                                          [argument-code : i64
                                            (cast
                                              (string.string-ref
                                                text
                                                argument-scan)
                                              : i64)]
                                          (begin
                                            (if (= argument-code 35)
                                              (set! has-hash true)
                                              unit)
                                            ;; CTFE cannot invoke the surface
                                            ;; `cond` macro.
                                            ;; lint-allow: nested-if-ladder
                                            (if (if (= argument-code 9)
                                              true
                                              (if (= argument-code 10)
                                                true
                                                (if (= argument-code 11)
                                                  true
                                                  (if (= argument-code 12)
                                                    true
                                                    (if (= argument-code 13)
                                                      true
                                                      (= argument-code 32))))))
                                              (set! has-whitespace true)
                                              unit)
                                            (if (>= argument-code 128)
                                              (set! has-non-ascii true)
                                              unit)
                                            (set!
                                              argument-scan
                                              (+ argument-scan 1)))))
                                      (if has-hash
                                        (comptime.comptime-error
                                          "format: Rust raw identifiers use the TypeLisp spelling without 'r#'")
                                        unit)
                                      (if has-whitespace
                                        (comptime.comptime-error
                                          "format: whitespace is only allowed immediately before '}'")
                                        unit)
                                      (if has-non-ascii
                                        (comptime.comptime-error
                                          "format: placeholder names and whitespace are ASCII-only")
                                        unit)
                                      (if (if (>= first-code 48)
                                        (<= first-code 57)
                                        false)
                                        (let
                                          [value : i64 0]
                                          [digit-index : i64 placeholder-start]
                                          (begin
                                            (while (< digit-index argument-end)
                                              (let
                                                [digit-code : i64
                                                  (cast
                                                    (string.string-ref
                                                      text
                                                      digit-index)
                                                    : i64)]
                                                (begin
                                                  (if (not
                                                    (if (>= digit-code 48)
                                                      (<= digit-code 57)
                                                      false))
                                                    (comptime.comptime-error
                                                      "format: malformed positional argument index")
                                                    unit)
                                                  (let
                                                    [digit : i64
                                                      (- digit-code 48)]
                                                    (begin
                                                      (if (if (>
                                                        value
                                                        922337203685477580)
                                                        true
                                                        (if (=
                                                          value
                                                          922337203685477580)
                                                          (> digit 7)
                                                          false))
                                                        (comptime.comptime-error
                                                          "format: positional argument index overflow")
                                                        unit)
                                                      (set!
                                                        value
                                                        (+ (* value 10) digit))))
                                                  (set!
                                                    digit-index
                                                    (+ digit-index 1)))))
                                            (set! selector-kind 0)
                                            (set!
                                              selector-value
                                              (comptime.expr-int value))))
                                        (let
                                          [name : String
                                            (comptime.string-slice
                                              text
                                              placeholder-start
                                              argument-len)]
                                          [name-index : i64 0]
                                          [valid? : bool true]
                                          (begin
                                            (if (string.eq name "_")
                                              (comptime.comptime-error
                                                "format: bare '_' is not a captured identifier")
                                              unit)
                                            (while (< name-index argument-len)
                                              (begin
                                                (let
                                                  [name-code : i64
                                                    (cast
                                                      (string.string-ref
                                                        name
                                                        name-index)
                                                      : i64)]
                                                  [folded : i64
                                                    (if (if (>= name-code 65)
                                                      (<= name-code 90)
                                                      false)
                                                      (+ name-code 32)
                                                      name-code)]
                                                  ;; CTFE cannot invoke `cond`.
                                                  ;; lint-allow: nested-if-ladder
                                                  (if (not
                                                    ;; lint-allow: nested-if-ladder
                                                    (if (if (>= folded 97)
                                                      (<= folded 122)
                                                      false)
                                                      true
                                                      (if (if (>= name-code 48)
                                                        (<= name-code 57)
                                                        false)
                                                        true
                                                        (if (if (>=
                                                          name-code
                                                          42)
                                                          (<= name-code 63)
                                                          false)
                                                          (if (!= name-code 44)
                                                            (!= name-code 59)
                                                            false)
                                                          (if (= name-code 33)
                                                            true
                                                            (if (if (>=
                                                              name-code
                                                              37)
                                                              (<= name-code 38)
                                                              false)
                                                              true
                                                              (= name-code 95)))))))
                                                    (set! valid? false)
                                                    unit))
                                                (set!
                                                  name-index
                                                  (+ name-index 1))))
                                            (if valid?
                                              (begin
                                                (set! selector-kind 1)
                                                (set!
                                                  selector-value
                                                  (comptime.expr-string name)))
                                              (comptime.comptime-error
                                                "format: malformed captured argument identifier"))))))))
                                ;; Parse the stable format_spec grammar.
                                (let
                                  [cursor : i64
                                    (if (>= colon 0)
                                      (+ colon 1)
                                      placeholder-end)]
                                  (begin
                                    (if (< cursor placeholder-end)
                                      (let
                                        [first-align : i64 0]
                                        [second-align : i64 0]
                                        (begin
                                          (let
                                            [alignment-code : i64
                                              (cast
                                                (string.string-ref text cursor)
                                                : i64)]
                                            ;; Macro CTFE cannot invoke `cond`.
                                            ;; lint-allow: nested-if-ladder
                                            (if (= alignment-code 60)
                                              (set! first-align 1)
                                              (if (= alignment-code 94)
                                                (set! first-align 2)
                                                (if (= alignment-code 62)
                                                  (set! first-align 3)
                                                  unit))))
                                          (if (< (+ cursor 1) placeholder-end)
                                            (let
                                              [alignment-code : i64
                                                (cast
                                                  (string.string-ref
                                                    text
                                                    (+ cursor 1))
                                                  : i64)]
                                              ;; Macro CTFE cannot invoke `cond`.
                                              ;; lint-allow: nested-if-ladder
                                              (if (= alignment-code 60)
                                                (set! second-align 1)
                                                (if (= alignment-code 94)
                                                  (set! second-align 2)
                                                  (if (= alignment-code 62)
                                                    (set! second-align 3)
                                                    unit))))
                                            unit)
                                          (if (!= first-align 0)
                                            (begin
                                              (set! alignment first-align)
                                              (set! cursor (+ cursor 1)))
                                            (if (!= second-align 0)
                                              (begin
                                                (set!
                                                  fill-code
                                                  (cast
                                                    (string.string-ref
                                                      text
                                                      cursor)
                                                    : i64))
                                                (set! alignment second-align)
                                                (set! cursor (+ cursor 2)))
                                              (let
                                                [align-scan : i64 (+ cursor 2)]
                                                [late-align? : bool false]
                                                (begin
                                                  (while (<
                                                    align-scan
                                                    placeholder-end)
                                                    (begin
                                                      (let
                                                        [alignment-code : i64
                                                          (cast
                                                            (string.string-ref
                                                              text
                                                              align-scan)
                                                            : i64)]
                                                        (if (if (=
                                                          alignment-code
                                                          60)
                                                          true
                                                          (if (=
                                                            alignment-code
                                                            94)
                                                            true
                                                            (=
                                                              alignment-code
                                                              62)))
                                                          (set!
                                                            late-align?
                                                            true)
                                                          unit))
                                                      (set!
                                                        align-scan
                                                        (+ align-scan 1))))
                                                  (if late-align?
                                                    (comptime.comptime-error
                                                      "format: fill must be exactly one TypeLisp byte before alignment")
                                                    unit)))))))
                                      unit)
                                    (if (< cursor placeholder-end)
                                      (let
                                        [sign-code : i64
                                          (cast
                                            (string.string-ref text cursor)
                                            : i64)]
                                        (if (= sign-code 43)
                                          (begin
                                            (set! sign 1)
                                            (set! cursor (+ cursor 1)))
                                          (if (= sign-code 45)
                                            (begin
                                              (set! sign 2)
                                              (set! cursor (+ cursor 1)))
                                            unit)))
                                      unit)
                                    (if (if (< cursor placeholder-end)
                                      (=
                                        (cast
                                          (string.string-ref text cursor)
                                          : i64)
                                        35)
                                      false)
                                      (begin
                                        (set! alternate 1)
                                        (set! cursor (+ cursor 1)))
                                      unit)
                                    ;; `0$` is a dynamic width reference, not
                                    ;; the zero-padding flag.
                                    (if (if (< cursor placeholder-end)
                                      (=
                                        (cast
                                          (string.string-ref text cursor)
                                          : i64)
                                        48)
                                      false)
                                      (let
                                        [zero-scan : i64 cursor]
                                        [zero-scanning? : bool true]
                                        (begin
                                          (while zero-scanning?
                                            (if (< zero-scan placeholder-end)
                                              (let
                                                [digit-code : i64
                                                  (cast
                                                    (string.string-ref
                                                      text
                                                      zero-scan)
                                                    : i64)]
                                                (if (>= digit-code 48)
                                                  (if (<= digit-code 57)
                                                    (set!
                                                      zero-scan
                                                      (+ zero-scan 1))
                                                    (set! zero-scanning? false))
                                                  (set! zero-scanning? false)))
                                              (set! zero-scanning? false)))
                                          (if (if (= zero-scan (+ cursor 1))
                                            (if (< zero-scan placeholder-end)
                                              (=
                                                (cast
                                                  (string.string-ref
                                                    text
                                                    zero-scan)
                                                  : i64)
                                                36)
                                              false)
                                            false)
                                            unit
                                            (begin
                                              (set! zero 1)
                                              (set! cursor (+ cursor 1))))))
                                      unit)
                                    ;; Width: inline integer, N$, or name$.
                                    (let
                                      [width-digit? : bool false]
                                      (begin
                                        (if (< cursor placeholder-end)
                                          (let
                                            [digit-code : i64
                                              (cast
                                                (string.string-ref text cursor)
                                                : i64)]
                                            (if (>= digit-code 48)
                                              (if (<= digit-code 57)
                                                (set! width-digit? true)
                                                unit)
                                              unit))
                                          unit)
                                        (if width-digit?
                                          (let
                                            [width-number : i64 0]
                                            [width-scan : i64 cursor]
                                            [width-scanning? : bool true]
                                            (begin
                                              (while width-scanning?
                                                (if (<
                                                  width-scan
                                                  placeholder-end)
                                                  (let
                                                    [digit-code : i64
                                                      (cast
                                                        (string.string-ref
                                                          text
                                                          width-scan)
                                                        : i64)]
                                                    (if (>= digit-code 48)
                                                      (if (<= digit-code 57)
                                                        (let
                                                          [digit : i64
                                                            (- digit-code 48)]
                                                          (begin
                                                            (if (if (>
                                                              width-number
                                                              922337203685477580)
                                                              true
                                                              (if (=
                                                                width-number
                                                                922337203685477580)
                                                                (> digit 7)
                                                                false))
                                                              (comptime.comptime-error
                                                                "format: width integer overflow")
                                                              unit)
                                                            (set!
                                                              width-number
                                                              (+
                                                                (*
                                                                  width-number
                                                                  10)
                                                                digit))
                                                            (set!
                                                              width-scan
                                                              (+ width-scan 1))))
                                                        (set!
                                                          width-scanning?
                                                          false))
                                                      (set!
                                                        width-scanning?
                                                        false)))
                                                  (set! width-scanning? false)))
                                              (if (if (<
                                                width-scan
                                                placeholder-end)
                                                (=
                                                  (cast
                                                    (string.string-ref
                                                      text
                                                      width-scan)
                                                    : i64)
                                                  36)
                                                false)
                                                (begin
                                                  (set! width-kind 2)
                                                  (set!
                                                    width-value
                                                    (comptime.expr-int
                                                      width-number))
                                                  (set! cursor (+ width-scan 1)))
                                                (begin
                                                  (set! width-kind 1)
                                                  (set!
                                                    width-value
                                                    (comptime.expr-int
                                                      width-number))
                                                  (set! cursor width-scan)))))
                                          (if (if (< cursor placeholder-end)
                                            (!=
                                              (cast
                                                (string.string-ref text cursor)
                                                : i64)
                                              46)
                                            false)
                                            (let
                                              [name-scan : i64 cursor]
                                              [name-scanning? : bool true]
                                              (begin
                                                (while name-scanning?
                                                  (if (<
                                                    name-scan
                                                    placeholder-end)
                                                    (let
                                                      [name-code : i64
                                                        (cast
                                                          (string.string-ref
                                                            text
                                                            name-scan)
                                                          : i64)]
                                                      [folded : i64
                                                        (if (if (>=
                                                          name-code
                                                          65)
                                                          (<= name-code 90)
                                                          false)
                                                          (+ name-code 32)
                                                          name-code)]
                                                      ;; CTFE cannot invoke `cond`.
                                                      ;; lint-allow: nested-if-ladder
                                                      (if (if (>= folded 97)
                                                        (<= folded 122)
                                                        false)
                                                        (set!
                                                          name-scan
                                                          (+ name-scan 1))
                                                        (if (if (>=
                                                          name-code
                                                          48)
                                                          (<= name-code 57)
                                                          false)
                                                          (set!
                                                            name-scan
                                                            (+ name-scan 1))
                                                          (if (if (>=
                                                            name-code
                                                            42)
                                                            (<= name-code 63)
                                                            false)
                                                            (if (!=
                                                              name-code
                                                              44)
                                                              (if (!=
                                                                name-code
                                                                59)
                                                                (set!
                                                                  name-scan
                                                                  (+
                                                                    name-scan
                                                                    1))
                                                                (set!
                                                                  name-scanning?
                                                                  false))
                                                              (set!
                                                                name-scanning?
                                                                false))
                                                            (if (= name-code 33)
                                                              (set!
                                                                name-scan
                                                                (+ name-scan 1))
                                                              (if (if (>=
                                                                name-code
                                                                37)
                                                                (<=
                                                                  name-code
                                                                  38)
                                                                false)
                                                                (set!
                                                                  name-scan
                                                                  (+
                                                                    name-scan
                                                                    1))
                                                                (if (=
                                                                  name-code
                                                                  95)
                                                                  (set!
                                                                    name-scan
                                                                    (+
                                                                      name-scan
                                                                      1))
                                                                  (set!
                                                                    name-scanning?
                                                                    false))))))))
                                                    (set! name-scanning? false)))
                                                (if (if (<
                                                  name-scan
                                                  placeholder-end)
                                                  (=
                                                    (cast
                                                      (string.string-ref
                                                        text
                                                        name-scan)
                                                      : i64)
                                                    36)
                                                  false)
                                                  (let
                                                    [width-name : String
                                                      (comptime.string-slice
                                                        text
                                                        cursor
                                                        (- name-scan cursor))]
                                                    (begin
                                                      (if (= name-scan cursor)
                                                        (comptime.comptime-error
                                                          "format: malformed dynamic width name")
                                                        unit)
                                                      (if (string.eq
                                                        width-name
                                                        "_")
                                                        (comptime.comptime-error
                                                          "format: bare '_' is not a dynamic width name")
                                                        unit)
                                                      (set! width-kind 3)
                                                      (set!
                                                        width-value
                                                        (comptime.expr-string
                                                          width-name))
                                                      (set!
                                                        cursor
                                                        (+ name-scan 1))))
                                                  unit)))
                                            unit))))
                                    ;; Precision shares the independent implicit
                                    ;; value iterator. For `{:.*}`, the selector
                                    ;; provisionally consumed the count slot, so
                                    ;; move the value to the following slot.
                                    (if (if (< cursor placeholder-end)
                                      (=
                                        (cast
                                          (string.string-ref text cursor)
                                          : i64)
                                        46)
                                      false)
                                      (begin
                                        (set! cursor (+ cursor 1))
                                        (if (>= cursor placeholder-end)
                                          (comptime.comptime-error
                                            "format: precision requires a count or '*'")
                                          unit)
                                        (if (=
                                          (cast
                                            (string.string-ref text cursor)
                                            : i64)
                                          42)
                                          (begin
                                            (set! precision-kind 4)
                                            (set!
                                              precision-value
                                              (if (= implicit-state 1)
                                                selector-value
                                                (comptime.expr-int
                                                  next-implicit)))
                                            (if (= implicit-state 1)
                                              (set!
                                                selector-value
                                                (comptime.expr-int
                                                  next-implicit))
                                              unit)
                                            (set!
                                              next-implicit
                                              (+ next-implicit 1))
                                            (set! cursor (+ cursor 1)))
                                          (let
                                            [precision-digit? : bool false]
                                            (begin
                                              (let
                                                [digit-code : i64
                                                  (cast
                                                    (string.string-ref
                                                      text
                                                      cursor)
                                                    : i64)]
                                                (if (>= digit-code 48)
                                                  (if (<= digit-code 57)
                                                    (set! precision-digit? true)
                                                    unit)
                                                  unit))
                                              (if precision-digit?
                                                (let
                                                  [precision-number : i64 0]
                                                  [precision-scan : i64 cursor]
                                                  [precision-scanning? : bool
                                                    true]
                                                  (begin
                                                    (while precision-scanning?
                                                      (if (<
                                                        precision-scan
                                                        placeholder-end)
                                                        (let
                                                          [digit-code : i64
                                                            (cast
                                                              (string.string-ref
                                                                text
                                                                precision-scan)
                                                              : i64)]
                                                          (if (>= digit-code 48)
                                                            (if (<=
                                                              digit-code
                                                              57)
                                                              (let
                                                                [digit : i64
                                                                  (-
                                                                    digit-code
                                                                    48)]
                                                                (begin
                                                                  (if (if (>
                                                                    precision-number
                                                                    922337203685477580)
                                                                    true
                                                                    (if (=
                                                                      precision-number
                                                                      922337203685477580)
                                                                      (>
                                                                        digit
                                                                        7)
                                                                      false))
                                                                    (comptime.comptime-error
                                                                      "format: precision integer overflow")
                                                                    unit)
                                                                  (set!
                                                                    precision-number
                                                                    (+
                                                                      (*
                                                                        precision-number
                                                                        10)
                                                                      digit))
                                                                  (set!
                                                                    precision-scan
                                                                    (+
                                                                      precision-scan
                                                                      1))))
                                                              (set!
                                                                precision-scanning?
                                                                false))
                                                            (set!
                                                              precision-scanning?
                                                              false)))
                                                        (set!
                                                          precision-scanning?
                                                          false)))
                                                    (if (if (<
                                                      precision-scan
                                                      placeholder-end)
                                                      (=
                                                        (cast
                                                          (string.string-ref
                                                            text
                                                            precision-scan)
                                                          : i64)
                                                        36)
                                                      false)
                                                      (begin
                                                        (set! precision-kind 2)
                                                        (set!
                                                          precision-value
                                                          (comptime.expr-int
                                                            precision-number))
                                                        (set!
                                                          cursor
                                                          (+ precision-scan 1)))
                                                      (begin
                                                        (set! precision-kind 1)
                                                        (set!
                                                          precision-value
                                                          (comptime.expr-int
                                                            precision-number))
                                                        (set!
                                                          cursor
                                                          precision-scan)))))
                                                (let
                                                  [precision-scan : i64 cursor]
                                                  [precision-name-scanning? : bool
                                                    true]
                                                  (begin
                                                    (while precision-name-scanning?
                                                      (if (<
                                                        precision-scan
                                                        placeholder-end)
                                                        (let
                                                          [name-code : i64
                                                            (cast
                                                              (string.string-ref
                                                                text
                                                                precision-scan)
                                                              : i64)]
                                                          [folded : i64
                                                            (if (if (>=
                                                              name-code
                                                              65)
                                                              (<= name-code 90)
                                                              false)
                                                              (+ name-code 32)
                                                              name-code)]
                                                          ;; CTFE cannot invoke `cond`.
                                                          ;; lint-allow: nested-if-ladder
                                                          (if (if (>= folded 97)
                                                            (<= folded 122)
                                                            false)
                                                            (set!
                                                              precision-scan
                                                              (+
                                                                precision-scan
                                                                1))
                                                            (if (if (>=
                                                              name-code
                                                              48)
                                                              (<= name-code 57)
                                                              false)
                                                              (set!
                                                                precision-scan
                                                                (+
                                                                  precision-scan
                                                                  1))
                                                              (if (if (>=
                                                                name-code
                                                                42)
                                                                (<=
                                                                  name-code
                                                                  63)
                                                                false)
                                                                (if (!=
                                                                  name-code
                                                                  44)
                                                                  (if (!=
                                                                    name-code
                                                                    59)
                                                                    (set!
                                                                      precision-scan
                                                                      (+
                                                                        precision-scan
                                                                        1))
                                                                    (set!
                                                                      precision-name-scanning?
                                                                      false))
                                                                  (set!
                                                                    precision-name-scanning?
                                                                    false))
                                                                (if (=
                                                                  name-code
                                                                  33)
                                                                  (set!
                                                                    precision-scan
                                                                    (+
                                                                      precision-scan
                                                                      1))
                                                                  (if (if (>=
                                                                    name-code
                                                                    37)
                                                                    (<=
                                                                      name-code
                                                                      38)
                                                                    false)
                                                                    (set!
                                                                      precision-scan
                                                                      (+
                                                                        precision-scan
                                                                        1))
                                                                    (if (=
                                                                      name-code
                                                                      95)
                                                                      (set!
                                                                        precision-scan
                                                                        (+
                                                                          precision-scan
                                                                          1))
                                                                      (set!
                                                                        precision-name-scanning?
                                                                        false))))))))
                                                        (set!
                                                          precision-name-scanning?
                                                          false)))
                                                    (if (if (<
                                                      precision-scan
                                                      placeholder-end)
                                                      (=
                                                        (cast
                                                          (string.string-ref
                                                            text
                                                            precision-scan)
                                                          : i64)
                                                        36)
                                                      false)
                                                      (let
                                                        [precision-name : String
                                                          (comptime.string-slice
                                                            text
                                                            cursor
                                                            (-
                                                              precision-scan
                                                              cursor))]
                                                        (begin
                                                          (if (=
                                                            precision-scan
                                                            cursor)
                                                            (comptime.comptime-error
                                                              "format: malformed dynamic precision name")
                                                            unit)
                                                          (if (string.eq
                                                            precision-name
                                                            "_")
                                                            (comptime.comptime-error
                                                              "format: bare '_' is not a dynamic precision name")
                                                            unit)
                                                          (set!
                                                            precision-kind
                                                            3)
                                                          (set!
                                                            precision-value
                                                            (comptime.expr-string
                                                              precision-name))
                                                          (set!
                                                            cursor
                                                            (+ precision-scan 1))))
                                                      (comptime.comptime-error
                                                        "format: malformed precision count")))))))))
                                      unit)
                                    (set!
                                      type-selector
                                      (comptime.string-slice
                                        text
                                        cursor
                                        (- placeholder-end cursor)))
                                    (if (string.eq type-selector "")
                                      (set! valid-type-selector? true)
                                      unit)
                                    (if (string.eq type-selector "?")
                                      (set! valid-type-selector? true)
                                      unit)
                                    (if (string.eq type-selector "x?")
                                      (set! valid-type-selector? true)
                                      unit)
                                    (if (string.eq type-selector "X?")
                                      (set! valid-type-selector? true)
                                      unit)
                                    (if (string.eq type-selector "o")
                                      (set! valid-type-selector? true)
                                      unit)
                                    (if (string.eq type-selector "x")
                                      (set! valid-type-selector? true)
                                      unit)
                                    (if (string.eq type-selector "X")
                                      (set! valid-type-selector? true)
                                      unit)
                                    (if (string.eq type-selector "p")
                                      (set! valid-type-selector? true)
                                      unit)
                                    (if (string.eq type-selector "b")
                                      (set! valid-type-selector? true)
                                      unit)
                                    (if (string.eq type-selector "e")
                                      (set! valid-type-selector? true)
                                      unit)
                                    (if (string.eq type-selector "E")
                                      (set! valid-type-selector? true)
                                      unit)
                                    (if (not valid-type-selector?)
                                      (comptime.comptime-error
                                        "format: malformed, duplicated, or out-of-order format specifier")
                                      unit)
                                    (let
                                      [placeholder : comptime.Expr
                                        (comptime.expr-begin-unit
                                          (comptime.expr-list-cons
                                            (comptime.expr-int selector-kind)
                                            (comptime.expr-list-cons
                                              selector-value
                                              (comptime.expr-list-cons
                                                (comptime.expr-int
                                                  implicit-state)
                                                (comptime.expr-list-cons
                                                  (comptime.expr-int fill-code)
                                                  (comptime.expr-list-cons
                                                    (comptime.expr-int
                                                      alignment)
                                                    (comptime.expr-list-cons
                                                      (comptime.expr-int sign)
                                                      (comptime.expr-list-cons
                                                        (comptime.expr-int
                                                          alternate)
                                                        (comptime.expr-list-cons
                                                          (comptime.expr-int
                                                            zero)
                                                          (comptime.expr-list-cons
                                                            (comptime.expr-int
                                                              width-kind)
                                                            (comptime.expr-list-cons
                                                              width-value
                                                              (comptime.expr-list-cons
                                                                (comptime.expr-int
                                                                  precision-kind)
                                                                (comptime.expr-list-cons
                                                                  precision-value
                                                                  (comptime.expr-list-cons
                                                                    (comptime.expr-string
                                                                      type-selector)
                                                                    (comptime.expr-list-empty)))))))))))))))]
                                      (set!
                                        plan-pieces
                                        (comptime.expr-list-cons
                                          placeholder
                                          plan-pieces))))))
                              (set! index (+ close 1))
                              (set! literal-start index)))))))))
              (if (= code 125)
                (if (if (< (+ index 1) template-len)
                  (= (cast (string.string-ref text (+ index 1)) : i64) 125)
                  false)
                  (begin
                    (if (> index literal-start)
                      (set!
                        plan-pieces
                        (comptime.expr-list-cons
                          (comptime.expr-string
                            (comptime.string-slice
                              text
                              literal-start
                              (- index literal-start)))
                          plan-pieces))
                      unit)
                    (set!
                      plan-pieces
                      (comptime.expr-list-cons
                        (comptime.expr-string "}")
                        plan-pieces))
                    (set! index (+ index 2))
                    (set! literal-start index))
                  (comptime.comptime-error "format: unmatched '}'"))
                (set! index (+ index 1))))))
        (if (> template-len literal-start)
          (set!
            plan-pieces
            (comptime.expr-list-cons
              (comptime.expr-string
                (comptime.string-slice
                  text
                  literal-start
                  (- template-len literal-start)))
              plan-pieces))
          unit)
        (let
          [plan : comptime.Expr
            (comptime.expr-call
              (comptime.expr-var "__tl_format_plan")
              plan-pieces)]
          (comptime.expr-call
            terminal
            (comptime.expr-list-cons
              plan
              (comptime.expr-list-cons
                argument-carrier
                (comptime.expr-list-cons
                  stream-address
                  (comptime.expr-list-empty))))))))
    (comptime.comptime-error "format: template must be a string literal")))

;: Start one legacy materializing expansion from a parsed plan.
(defmacro (format-expand-materialized-start
  [plan : comptime.Expr]
  [argument-carrier : comptime.Expr]
  [_stream-address : comptime.Expr]) : comptime.Expr
  `(stdlib.format.format-expand
    ,plan
    ,argument-carrier
    0
    0
    (__tl_format_positional_vars)
    (__tl_format_named_names)
    (__tl_format_named_vars)
    (__tl_format_bindings)))

;: Start one immediate writer expansion from a parsed plan.
(defmacro (format-expand-stream-start
  [plan : comptime.Expr]
  [argument-carrier : comptime.Expr]
  [stream-address : comptime.Expr]) : comptime.Expr
  `(stdlib.format.format-expand-mode
    ,plan
    ,argument-carrier
    ,stream-address
    0
    0
    (__tl_format_positional_vars)
    (__tl_format_named_names)
    (__tl_format_named_vars)
    (__tl_format_bindings)))

;; The capture-free renderer is the first package field, so its fixed function
;; width is also the byte offset of the following anchors tuple.
(define arguments-renderer-byte-size : i64
  (comptime (size-of (type (-> (Tuple i64 i64) i64)))))

;; Invoke the fixed scalar renderer ABI after a macro has located the package's
;; first word. Keeping the function-pointer type in ordinary runtime code lets
;; the embedded macro image carry only scalar builder operations.
(define (arguments-renderer-call-at
  [renderer-address : i64]
  [formatter-address : i64]
  [anchors-address : i64]) : i64
  ((unsafe
      (ptr-read
        (int->ptr
          (cast renderer-address : u64)
          : (Ptr (-> (Tuple i64 i64) i64)))))
    (tuple formatter-address anchors-address)))

;; Finish a retained Arguments package after every supplied value and lexical
;; capture has been converted to a shared anchor. The renderer receives only
;; `(formatter-address, anchors-address)` machine words; the package's checked
;; anchor tuple retains all lifetimes while this scalar control ABI avoids
;; passing heterogeneous reference-bearing aggregates through an indirect call.
(defmacro (format-arguments-package
  [plan : comptime.Expr]
  [anchors : comptime.Expr]
  [renderer-values : comptime.Expr]
  [argument-kinds : comptime.Expr]
  [argument-names : comptime.Expr]) : comptime.Expr
  (match argument-kinds
    [(comptime.Expr.Call _ kind-items)
      (match argument-names
        [(comptime.Expr.Call _ name-items)
          (if (!=
            (comptime.expr-list-length kind-items)
            (comptime.expr-list-length name-items))
            (comptime.comptime-error
              "format: internal retained argument metadata is malformed")
            (let
              [parameter-name : String
                (comptime.syntax-name-fresh "__tl_format_arguments_values")]
              [parameter : comptime.Expr (comptime.expr-var parameter-name)]
              [anchors-type : comptime.Expr (comptime.expr-type anchors)]
              [_anchors-type-expr : comptime.Expr
                (comptime.type-expr anchors-type)]
              [stream-address : comptime.Expr
                (comptime.expr-tuple-ref parameter 0)]
              [anchors-address : comptime.Expr
                (comptime.expr-tuple-ref parameter 1)]
              [anchors-source : comptime.Expr
                `(unsafe
                  (ptr-read
                    (int->ptr
                      (cast ,anchors-address : u64)
                      : (Ptr ,_anchors-type-expr))))]
              [anchors-name : String
                (comptime.syntax-name-fresh "__tl_format_renderer_anchors")]
              [anchors-value : comptime.Expr (comptime.expr-var anchors-name)]
              [render-arguments : comptime.ExprList (comptime.expr-list-empty)]
              [renderer-bindings : comptime.ExprList (comptime.expr-list-empty)]
              [index : i64 (- (comptime.expr-list-length kind-items) 1)]
              (begin
                (if (!=
                  (tuple-element-count anchors-type)
                  (comptime.expr-list-length kind-items))
                  (comptime.comptime-error
                    "format: internal retained anchor count is malformed")
                  unit)
                (while (>= index 0)
                  (let
                    [projection : comptime.Expr
                      (comptime.expr-tuple-ref anchors-value index)]
                    [source-projection : comptime.Expr
                      (tuple-element-type anchors-type index)]
                    [_source-type-expr : comptime.Expr
                      (comptime.type-expr source-projection)]
                    [runtime-source : comptime.Expr
                      (if (string.eq (type-kind source-projection) "string")
                        `(unsafe
                          (ptr-read (ptr-addr-of ,projection)))
                        projection)]
                    [runtime-name : String
                      (comptime.syntax-name-fresh
                        (comptime.string-append
                          "__tl_format_renderer_anchor_"
                          (comptime.int->string index)))]
                    [runtime-var : comptime.Expr
                      (comptime.expr-var runtime-name)]
                    [runtime-binding : comptime.Expr
                      (comptime.expr-begin-unit
                        (comptime.expr-list-cons
                          runtime-var
                          (comptime.expr-list-cons
                            runtime-source
                            (comptime.expr-list-empty))))]
                    [typed-projection : comptime.Expr
                      `(ann ,runtime-var : ,_source-type-expr)]
                    (begin
                      (set!
                        renderer-bindings
                        (comptime.expr-list-cons
                          runtime-binding
                          renderer-bindings))
                      (match (comptime.expr-list-nth kind-items index)
                        [(comptime.Expr.Int kind)
                          (if (= kind 0)
                            (set!
                              render-arguments
                              (comptime.expr-list-cons
                                typed-projection
                                render-arguments))
                            (if (= kind 1)
                              (set!
                                render-arguments
                                (comptime.expr-list-cons
                                  `(__tl_format_named_argument
                                    ,(comptime.expr-list-nth name-items index)
                                    ,typed-projection)
                                  render-arguments))
                              (comptime.comptime-error
                                "format: internal retained argument kind is malformed")))]
                        [_
                          (comptime.comptime-error
                            "format: internal retained argument kind is malformed")])
                      (set! index (- index 1)))))
                (let
                  [parameter-type : comptime.Expr
                    (comptime.expr-type renderer-values)]
                  [body : comptime.Expr
                    `(stdlib.format.format-expand-mode
                      ,plan
                      (__tl_format_arguments ,@render-arguments)
                      ,stream-address
                      0
                      0
                      (__tl_format_positional_vars)
                      (__tl_format_named_names)
                      (__tl_format_named_vars)
                      (__tl_format_bindings))]
                  [renderer-body : comptime.Expr body]
                  [binding-index : i64
                    (- (comptime.expr-list-length renderer-bindings) 1)]
                  (begin
                    (while (>= binding-index 0)
                      (match (comptime.expr-list-nth
                        renderer-bindings
                        binding-index)
                        [(comptime.Expr.Begin entry)
                          (match (comptime.expr-list-nth entry 0)
                            [(comptime.Expr.Var binding-name)
                              (set!
                                renderer-body
                                (comptime.expr-let-scope
                                  binding-name
                                  (comptime.expr-list-nth entry 1)
                                  renderer-body))]
                            [_
                              (comptime.comptime-error
                                "format: internal renderer binding is malformed")])]
                        [_
                          (comptime.comptime-error
                            "format: internal renderer binding is malformed")])
                      (set! binding-index (- binding-index 1)))
                    (set!
                      renderer-body
                      (comptime.expr-let-scope
                        anchors-name
                        anchors-source
                        renderer-body))
                    (let
                      [renderer : comptime.Expr
                        (comptime.expr-lambda1
                          parameter-name
                          parameter-type
                          renderer-body)]
                      `(tuple ,renderer ,anchors)))))))]
        [_
          (comptime.comptime-error
            "format: internal retained argument names are malformed")])]
    [_
      (comptime.comptime-error
        "format: internal retained argument kinds are malformed")]))

;; Finish an Arguments package after the standard streaming binder has
;; classified every supplied operand. Reusing that binder is important: each
;; operand is typechecked before reflection, so nested Arguments can be copied
;; while ordinary owned values remain shared anchors.
(defmacro (format-expand-arguments-finish
  [plan : comptime.Expr]
  [positional-vars : comptime.Expr]
  [named-names : comptime.Expr]
  [named-vars : comptime.Expr]
  [bindings : comptime.Expr]) : comptime.Expr
  (match plan
    [(comptime.Expr.Call _ plan-pieces)
      (match positional-vars
        [(comptime.Expr.Call _ positional-items)
          (match named-names
            [(comptime.Expr.Call _ named-name-items)
              (match named-vars
                [(comptime.Expr.Call _ named-var-items)
                  (match bindings
                    [(comptime.Expr.Call _ supplied-bindings)
                      (let
                        [supplied-vars : comptime.ExprList
                          (comptime.expr-list-empty)]
                        [supplied-kinds : comptime.ExprList
                          (comptime.expr-list-empty)]
                        [supplied-names : comptime.ExprList
                          (comptime.expr-list-empty)]
                        [ordered-vars : comptime.ExprList
                          (comptime.expr-list-empty)]
                        [ordered-kinds : comptime.ExprList
                          (comptime.expr-list-empty)]
                        [ordered-names : comptime.ExprList
                          (comptime.expr-list-empty)]
                        [explicit-names : comptime.ExprList named-name-items]
                        [capture-bindings : comptime.ExprList
                          (comptime.expr-list-empty)]
                        [capture-vars : comptime.ExprList
                          (comptime.expr-list-empty)]
                        [capture-kinds : comptime.ExprList
                          (comptime.expr-list-empty)]
                        [capture-argument-names : comptime.ExprList
                          (comptime.expr-list-empty)]
                        [capture-names : comptime.ExprList
                          (comptime.expr-list-empty)]
                        [capture-count : i64 0]
                        [supplied-index : i64 0]
                        (begin
                          ;; Build each group in reverse with constant-start
                          ;; forward loops, then reverse the combined metadata
                          ;; once. This keeps positional values before named
                          ;; values without requiring a reflected length in a
                          ;; let initializer.
                          (while (<
                            supplied-index
                            (comptime.expr-list-length positional-items))
                            (begin
                              (set!
                                supplied-vars
                                (comptime.expr-list-cons
                                  (comptime.expr-list-nth
                                    positional-items
                                    supplied-index)
                                  supplied-vars))
                              (set!
                                supplied-kinds
                                (comptime.expr-list-cons
                                  (comptime.expr-int 0)
                                  supplied-kinds))
                              (set!
                                supplied-names
                                (comptime.expr-list-cons
                                  (comptime.expr-int 0)
                                  supplied-names))
                              (set! supplied-index (+ supplied-index 1))))
                          (set! supplied-index 0)
                          (while (<
                            supplied-index
                            (comptime.expr-list-length named-var-items))
                            (begin
                              (set!
                                supplied-vars
                                (comptime.expr-list-cons
                                  (comptime.expr-list-nth
                                    named-var-items
                                    supplied-index)
                                  supplied-vars))
                              (set!
                                supplied-kinds
                                (comptime.expr-list-cons
                                  (comptime.expr-int 1)
                                  supplied-kinds))
                              (set!
                                supplied-names
                                (comptime.expr-list-cons
                                  (comptime.expr-var
                                    (comptime.expr-string-value
                                      (comptime.expr-list-nth
                                        named-name-items
                                        supplied-index)))
                                  supplied-names))
                              (set! supplied-index (+ supplied-index 1))))
                          (set! supplied-index 0)
                          (while (<
                            supplied-index
                            (comptime.expr-list-length supplied-vars))
                            (begin
                              (set!
                                ordered-vars
                                (comptime.expr-list-cons
                                  (comptime.expr-list-nth
                                    supplied-vars
                                    supplied-index)
                                  ordered-vars))
                              (set!
                                ordered-kinds
                                (comptime.expr-list-cons
                                  (comptime.expr-list-nth
                                    supplied-kinds
                                    supplied-index)
                                  ordered-kinds))
                              (set!
                                ordered-names
                                (comptime.expr-list-cons
                                  (comptime.expr-list-nth
                                    supplied-names
                                    supplied-index)
                                  ordered-names))
                              (set! supplied-index (+ supplied-index 1))))
                          (set! supplied-vars ordered-vars)
                          (set! supplied-kinds ordered-kinds)
                          (set! supplied-names ordered-names)
                          ;; Find all implicit named selector, width, and precision
                          ;; captures. `plan-pieces` is reverse-template order, so this
                          ;; matches the established formatter capture traversal.
                          (let
                            [plan-index : i64 0]
                            (while (<
                              plan-index
                              (comptime.expr-list-length plan-pieces))
                              (let
                                [piece : comptime.Expr
                                  (comptime.expr-list-nth
                                    plan-pieces
                                    plan-index)]
                                [fields : comptime.ExprList
                                  (comptime.expr-list-empty)]
                                [slot : i64 0]
                                (begin
                                  (match piece
                                    [(comptime.Expr.Begin found-fields)
                                      (set! fields found-fields)]
                                    [_ unit])
                                  (if (= (comptime.expr-list-length fields) 14)
                                    (while (< slot 3)
                                      (let
                                        [reference-kind : i64 -1]
                                        [reference-value : comptime.Expr
                                          (comptime.expr-int 0)]
                                        [named-reference? : bool false]
                                        (begin
                                          (if (= slot 0)
                                            (begin
                                              (match (comptime.expr-list-nth
                                                fields
                                                0)
                                                [(comptime.Expr.Int found)
                                                  (set! reference-kind found)]
                                                [_ unit])
                                              (set!
                                                reference-value
                                                (comptime.expr-list-nth
                                                  fields
                                                  1)))
                                            (if (= slot 1)
                                              (begin
                                                (match (comptime.expr-list-nth
                                                  fields
                                                  8)
                                                  [(comptime.Expr.Int found)
                                                    (set! reference-kind found)]
                                                  [_ unit])
                                                (set!
                                                  reference-value
                                                  (comptime.expr-list-nth
                                                    fields
                                                    9)))
                                              (begin
                                                (match (comptime.expr-list-nth
                                                  fields
                                                  10)
                                                  [(comptime.Expr.Int found)
                                                    (set! reference-kind found)]
                                                  [_ unit])
                                                (set!
                                                  reference-value
                                                  (comptime.expr-list-nth
                                                    fields
                                                    11)))))
                                          (if (= slot 0)
                                            (if (= reference-kind 1)
                                              (set! named-reference? true)
                                              unit)
                                            (if (= reference-kind 3)
                                              (set! named-reference? true)
                                              unit))
                                          (if named-reference?
                                            (let
                                              [name : String
                                                (comptime.expr-string-value
                                                  reference-value)]
                                              [explicit? : bool false]
                                              [captured? : bool false]
                                              [scan : i64 0]
                                              (begin
                                                (while (<
                                                  scan
                                                  (comptime.expr-list-length
                                                    explicit-names))
                                                  (begin
                                                    (if (string.eq
                                                      (comptime.expr-string-value
                                                        (comptime.expr-list-nth
                                                          explicit-names
                                                          scan))
                                                      name)
                                                      (set! explicit? true)
                                                      unit)
                                                    (set! scan (+ scan 1))))
                                                (set! scan 0)
                                                (while (<
                                                  scan
                                                  (comptime.expr-list-length
                                                    capture-names))
                                                  (begin
                                                    (if (string.eq
                                                      (comptime.expr-string-value
                                                        (comptime.expr-list-nth
                                                          capture-names
                                                          scan))
                                                      name)
                                                      (set! captured? true)
                                                      unit)
                                                    (set! scan (+ scan 1))))
                                                (if (if explicit?
                                                  true
                                                  captured?)
                                                  unit
                                                  (let
                                                    [capture-source : comptime.Expr
                                                      (comptime.expr-var name)]
                                                    [capture-name : String
                                                      (comptime.syntax-name-fresh
                                                        (comptime.string-append
                                                          "__tl_format_shared_capture_"
                                                          (comptime.int->string
                                                            capture-count)))]
                                                    [capture-var : comptime.Expr
                                                      (comptime.expr-var
                                                        capture-name)]
                                                    [entry : comptime.Expr
                                                      (comptime.expr-begin-unit
                                                        (comptime.expr-list-cons
                                                          capture-var
                                                          (comptime.expr-list-cons
                                                            capture-source
                                                            (comptime.expr-list-empty))))]
                                                    (begin
                                                      (set!
                                                        capture-names
                                                        (comptime.expr-list-cons
                                                          (comptime.expr-string
                                                            name)
                                                          capture-names))
                                                      (set!
                                                        capture-bindings
                                                        (comptime.expr-list-cons
                                                          entry
                                                          capture-bindings))
                                                      (set!
                                                        capture-vars
                                                        (comptime.expr-list-cons
                                                          capture-var
                                                          capture-vars))
                                                      (set!
                                                        capture-kinds
                                                        (comptime.expr-list-cons
                                                          (comptime.expr-int 1)
                                                          capture-kinds))
                                                      (set!
                                                        capture-argument-names
                                                        (comptime.expr-list-cons
                                                          (comptime.expr-var
                                                            name)
                                                          capture-argument-names))
                                                      (set!
                                                        capture-count
                                                        (+ capture-count 1)))))))
                                            unit)
                                          (set! slot (+ slot 1)))))
                                    unit)
                                  (set! plan-index (+ plan-index 1))))))
                          (let
                            [result : comptime.Expr
                              `(stdlib.format.format-arguments-package
                                ,plan
                                (tuple ,@supplied-vars ,@capture-vars)
                                (tuple (cast 0 : i64) (cast 0 : i64))
                                (__tl_format_retained_kinds
                                  ,@supplied-kinds
                                  ,@capture-kinds)
                                (__tl_format_retained_names
                                  ,@supplied-names
                                  ,@capture-argument-names))]
                            [capture-index : i64 0]
                            [ordered-bindings : comptime.ExprList
                              (comptime.expr-list-empty)]
                            [binding-index : i64 0]
                            (begin
                              (while (<
                                binding-index
                                (comptime.expr-list-length supplied-bindings))
                                (begin
                                  (set!
                                    ordered-bindings
                                    (comptime.expr-list-cons
                                      (comptime.expr-list-nth
                                        supplied-bindings
                                        binding-index)
                                      ordered-bindings))
                                  (set! binding-index (+ binding-index 1))))
                              (set! binding-index 0)
                              (while (<
                                capture-index
                                (comptime.expr-list-length capture-bindings))
                                (match (comptime.expr-list-nth
                                  capture-bindings
                                  capture-index)
                                  [(comptime.Expr.Begin entry)
                                    (match (comptime.expr-list-nth entry 0)
                                      [(comptime.Expr.Var binding-name)
                                        (set!
                                          result
                                          (comptime.expr-shared-let-scope
                                            binding-name
                                            (comptime.expr-list-nth entry 1)
                                            result))]
                                      [_
                                        (comptime.comptime-error
                                          "format: internal retained capture is malformed")])]
                                  [_
                                    (comptime.comptime-error
                                      "format: internal retained capture is malformed")])
                                (set! capture-index (+ capture-index 1)))
                              (while (<
                                binding-index
                                (comptime.expr-list-length ordered-bindings))
                                (match (comptime.expr-list-nth
                                  ordered-bindings
                                  binding-index)
                                  [(comptime.Expr.Begin entry)
                                    (match (comptime.expr-list-nth entry 0)
                                      [(comptime.Expr.Var binding-name)
                                        (if (=
                                          (cast
                                            (string.string-ref binding-name 12)
                                            : i64)
                                          115)
                                          (set!
                                            result
                                            (comptime.expr-shared-let-scope
                                              binding-name
                                              (comptime.expr-list-nth entry 1)
                                              result))
                                          (set!
                                            result
                                            (comptime.expr-let-scope
                                              binding-name
                                              (comptime.expr-list-nth entry 1)
                                              result)))]
                                      [_
                                        (comptime.comptime-error
                                          "format: internal retained binding is malformed")])]
                                  [_
                                    (comptime.comptime-error
                                      "format: internal retained binding is malformed")])
                                (set! binding-index (+ binding-index 1)))
                              result))))]
                    [_
                      (comptime.comptime-error
                        "format: internal retained binding carrier is malformed")])]
                [_
                  (comptime.comptime-error
                    "format: internal retained named variable carrier is malformed")])]
            [_
              (comptime.comptime-error
                "format: internal retained named argument carrier is malformed")])]
        [_
          (comptime.comptime-error
            "format: internal retained positional carrier is malformed")])]
    [_ (comptime.comptime-error "format: internal retained plan is malformed")]))

;; Start retained binding from the same parsed plan used by all other sinks.
(defmacro (format-expand-arguments-start
  [plan : comptime.Expr]
  [argument-carrier : comptime.Expr]
  [_stream-address : comptime.Expr]) : comptime.Expr
  `(stdlib.format.format-expand-mode
    ,plan
    ,argument-carrier
    (__tl_format_retained_sink)
    0
    0
    (__tl_format_positional_vars)
    (__tl_format_named_names)
    (__tl_format_named_vars)
    (__tl_format_bindings)))

;; Replay retained Arguments into an existing formatter stack-cell address.
(defmacro (format-arguments-render-at-resolved!
  [arguments-type : type]
  [borrowed-expr : comptime.Expr]
  [arguments : comptime.Expr]
  [stream-address : comptime.Expr]) : i64
  (match borrowed-expr
    [(comptime.Expr.Int borrowed)
      (let
        [address-name : String
          (comptime.syntax-name-fresh "__tl_format_anchors_address")]
        [address-var : comptime.Expr (comptime.expr-var address-name)]
        [address-value : comptime.Expr
          (if (= borrowed 1)
            `(unsafe
              (cast
                (ptr-read (ptr-cast (ptr-addr-of ,arguments) : (Ptr u64)))
                : i64))
            `(unsafe
              (cast
                (ptr->int (ptr-cast (ptr-addr-of ,arguments) : (Ptr u8)))
                : i64)))]
        [call : comptime.Expr
          `(stdlib.format.arguments-renderer-call-at
            ,address-var
            ,stream-address
            (+ ,address-var stdlib.format.arguments-renderer-byte-size))]
        (begin
          ;; Force validation of the package shape at the resolved boundary.
          (if (= (tuple-element-count arguments-type) 2)
            unit
            (comptime.comptime-error
              "format: malformed retained Arguments package"))
          (comptime.expr-let-scope address-name address-value call)))]
    [_
      (comptime.comptime-error
        "format: internal Arguments borrow marker is malformed")]))

(defmacro (format-arguments-render-at!
  [arguments : comptime.Expr]
  [stream-address : comptime.Expr]) : i64
  (match (type-kind (comptime.expr-type arguments))
    ["ref"
      `(stdlib.format.format-arguments-render-at-resolved!
        ,(comptime.reference-element-type (comptime.expr-type arguments))
        1
        ,arguments
        ,stream-address)]
    ["mut-ref"
      `(stdlib.format.format-arguments-render-at-resolved!
        ,(comptime.reference-element-type (comptime.expr-type arguments))
        1
        ,arguments
        ,stream-address)]
    [_
      `(stdlib.format.format-arguments-render-at-resolved!
        ,(comptime.expr-type arguments)
        0
        ,arguments
        ,stream-address)]))

;; Materialize retained Arguments into one fresh active-arena String.
(defmacro (format-arguments-materialize [arguments : comptime.Expr]) : String
  (let
    [name : String (comptime.syntax-name-fresh "__tl_format_arguments_value")]
    [value : comptime.Expr (comptime.expr-var name)]
    [body : comptime.Expr
      `(let
        [__tl_format_arguments_sink
          (stdlib.format.ArgumentsStringSink (__tl_make-array u8 64) 0)]
        [__tl_format_arguments_sink_cell (array __tl_format_arguments_sink)]
        [__tl_format_arguments_sink_address : i64
          (unsafe
            (cast
              (ptr->int
                (ptr-cast
                  (__tl_array-data __tl_format_arguments_sink_cell)
                  : (Ptr u8)))
              : i64))]
        [__tl_format_arguments_formatter
          (stdlib.format.formatter-writer
            __tl_format_arguments_sink_address
            stdlib.format.arguments-string-write-raw)]
        [__tl_format_arguments_formatter_cell
          (stdlib.format.formatter-cell __tl_format_arguments_formatter)]
        [__tl_format_arguments_formatter_address : i64
          (unsafe
            (cast
              (ptr->int
                (ptr-cast
                  (__tl_array-data __tl_format_arguments_formatter_cell)
                  : (Ptr u8)))
              : i64))]
        [__tl_format_arguments_status : i64
          (stdlib.format.format-arguments-render-at!
            ,value
            __tl_format_arguments_formatter_address)]
        [__tl_format_arguments_finished
          (array-ref __tl_format_arguments_sink_cell 0)]
        (if (!= __tl_format_arguments_status 0)
          (stdlib.format.format-runtime-abort-string
            "format: internal Arguments String sink failed")
          (if (= __tl_format_arguments_finished.len 0)
            ""
            (unsafe
              (string-from-bytes
                (ptr-cast
                  (__tl_array-data __tl_format_arguments_finished.slots)
                  : (Ptr u8))
                __tl_format_arguments_finished.len)))))]
    (comptime.expr-shared-let-scope name arguments body)))

;; Stream either retained Arguments or a literal template into one raw
;; formatter callback. This is the common entry used by writers and stdio.
(defmacro (format-write-callback-dispatch
  [template : comptime.Expr]
  [argument-carrier : comptime.Expr]
  [context : comptime.Expr]
  [write-raw : comptime.Expr]
  [newline : comptime.Expr]) : FormatResult
  (match argument-carrier
    [(comptime.Expr.Call _ values)
      (let
        [template-type : comptime.Expr (comptime.expr-type template)]
        [retained? : bool
          (if (= (comptime.expr-list-length values) 0)
            (if (string.eq (type-kind template-type) "tuple")
              (if (= (tuple-element-count template-type) 2)
                (if (string.eq
                  (type-kind (tuple-element-type template-type 0))
                  "function")
                  (string.eq
                    (type-kind (tuple-element-type template-type 1))
                    "tuple")
                  false)
                false)
              false)
            false)]
        (if retained?
          (let
            [name : String
              (comptime.syntax-name-fresh "__tl_format_stream_arguments")]
            [arguments : comptime.Expr (comptime.expr-var name)]
            [body : comptime.Expr
              `(let
                [__tl_format_stream_formatter
                  (stdlib.format.formatter-writer ,context ,write-raw)]
                [__tl_format_stream_cell
                  (stdlib.format.formatter-cell __tl_format_stream_formatter)]
                [__tl_format_stream_formatter_address : i64
                  (unsafe
                    (cast
                      (ptr->int
                        (ptr-cast
                          (__tl_array-data __tl_format_stream_cell)
                          : (Ptr u8)))
                      : i64))]
                [__tl_format_stream_status : i64
                  (stdlib.format.format-arguments-render-at!
                    ,arguments
                    __tl_format_stream_formatter_address)]
                (begin
                  (if (!= ,newline 0)
                    (if (= __tl_format_stream_status 0)
                      (stdlib.format.formatter-write-string-at!
                        __tl_format_stream_formatter_address
                        "\n")
                      unit)
                    unit)
                  (stdlib.format.formatter-result-at
                    __tl_format_stream_formatter_address)))]
            (comptime.expr-shared-let-scope name template body))
          `(stdlib.format.format-write-literal-callback
            ,template
            ,argument-carrier
            ,context
            ,write-raw
            ,newline)))]
    [_
      (comptime.comptime-error
        "format: internal writer argument carrier is malformed")]))

;: Retain one literal plan and shared borrows of its values without building
;: the final String. The concrete structural package type is inferred.
(defmacro (args [template : comptime.Expr] [values : comptime.Expr ...]) : comptime.Expr
  `(stdlib.format.format-parse
    ,template
    (__tl_format_arguments ,@values)
    stdlib.format.format-expand-arguments-start
    0))

;: Format a literal template and values into one freshly allocated String.
(defmacro (format [template : comptime.Expr] [values : comptime.Expr ...]) : String
  (if (= (comptime.expr-list-length values) 0)
    (let
      [template-type : comptime.Expr (comptime.expr-type template)]
      [retained? : bool
        (if (string.eq (type-kind template-type) "tuple")
          (if (= (tuple-element-count template-type) 2)
            (if (string.eq
              (type-kind (tuple-element-type template-type 0))
              "function")
              (string.eq
                (type-kind (tuple-element-type template-type 1))
                "tuple")
              false)
            false)
          false)]
      (if retained?
        `(stdlib.format.format-arguments-materialize ,template)
        `(stdlib.format.format-parse
          ,template
          (__tl_format_arguments)
          stdlib.format.format-expand-materialized-start
          0)))
    `(stdlib.format.format-parse
      ,template
      (__tl_format_arguments ,@values)
      stdlib.format.format-expand-materialized-start
      0)))

;: Stream a literal plan immediately while its generated shared borrows live.
;:
;: The fused path keeps nominal captures inside the plan's binding scopes and
;: preserves caller ownership.
(defmacro (format-write-literal-callback
  [template : comptime.Expr]
  [argument-carrier : comptime.Expr]
  [context : comptime.Expr]
  [write-raw : comptime.Expr]
  [newline : comptime.Expr]) : FormatResult
  `(let
    [__tl_format_stream_formatter
      (stdlib.format.formatter-writer ,context ,write-raw)]
    [__tl_format_stream_cell
      (stdlib.format.formatter-cell __tl_format_stream_formatter)]
    [__tl_format_stream_formatter_address : i64
      (unsafe
        (cast
          (ptr->int
            (ptr-cast (__tl_array-data __tl_format_stream_cell) : (Ptr u8)))
          : i64))]
    [__tl_format_stream_status : i64
      (stdlib.format.format-parse
        ,template
        ,argument-carrier
        stdlib.format.format-expand-stream-start
        __tl_format_stream_formatter_address)]
    (begin
      (if (!= ,newline 0)
        (if (= __tl_format_stream_status 0)
          (stdlib.format.formatter-write-string-at!
            __tl_format_stream_formatter_address
            "\n")
          unit)
        unit)
      (stdlib.format.formatter-result-at __tl_format_stream_formatter_address))))

;: Resolve one concrete writer's canonical raw Formatter adapter.
(defmacro (format-write-expand
  [writer : comptime.Expr]
  [template : comptime.Expr]
  [argument-carrier : comptime.Expr]
  [newline : comptime.Expr]) : FormatResult
  (let
    [writer-type : comptime.Expr (comptime.expr-type writer)]
    [writer-kind : String (type-kind writer-type)]
    [nominal? : bool
      (match writer-kind
        ["struct" true]
        ["enum" true]
        ["region" true]
        [_ false])]
    (if nominal?
      (let
        [owner : String (type-nominal-module writer-type)]
        [nominal-name : String (type-nominal-name writer-type)]
        [plain-name : String "format-write-raw"]
        [qualified-name : String
          (comptime.string-append "format-write-raw-" nominal-name)]
        [plain-present? : bool (comptime.module-value? owner plain-name)]
        [qualified-present? : bool
          (comptime.module-value? owner qualified-name)]
        [expected-signature : comptime.Expr
          (comptime.module-value-type
            "stdlib.format"
            "formatter-unreachable-write-raw")]
        [plain-matches? : bool
          (if plain-present?
            (string.eq
              (type-key (comptime.module-value-type owner plain-name))
              (type-key expected-signature))
            false)]
        [qualified-matches? : bool
          (if qualified-present?
            (string.eq
              (type-key (comptime.module-value-type owner qualified-name))
              (type-key expected-signature))
            false)]
        [dispatch : i64
          (+
            (if plain-matches?
              1
              0)
            (if qualified-matches?
              2
              0))]
        [present? : bool
          (if plain-present?
            true
            qualified-present?)]
        [cell-name : String
          (if (= dispatch 2)
            (comptime.string-append "format-writer-cell-" nominal-name)
            "format-writer-cell")]
        [cell-present? : bool (comptime.module-value? owner cell-name)]
        [hook : comptime.Expr
          (match dispatch
            [1 (comptime.module-value-expr owner plain-name)]
            [2 (comptime.module-value-expr owner qualified-name)]
            [3
              (comptime.comptime-error
                (comptime.string-append
                  "format: ambiguous writer adapters in canonical module "
                  owner))]
            [_
              (if present?
                (comptime.comptime-error
                  (comptime.string-append
                    "format: writer adapter has wrong signature in canonical module "
                    owner))
                (comptime.comptime-error
                  (comptime.string-append
                    "format: unsupported writer type from canonical module "
                    owner)))])]
        [cell-hook : comptime.Expr
          (if cell-present?
            (comptime.module-value-expr owner cell-name)
            (comptime.comptime-error
              (comptime.string-append
                "format: writer cell adapter is missing from canonical module "
                owner)))]
        `(let
          [__tl_format_writer_cell (,cell-hook ,writer)]
          [__tl_format_writer_address : i64
            (unsafe
              (cast
                (ptr->int
                  (ptr-cast
                    (__tl_array-data __tl_format_writer_cell)
                    : (Ptr u8)))
                : i64))]
          [__tl_format_writer_result
            (stdlib.format.format-write-callback-dispatch
              ,template
              ,argument-carrier
              __tl_format_writer_address
              ,hook
              ,newline)]
          (begin
            (set! ,writer (array-ref __tl_format_writer_cell 0))
            __tl_format_writer_result)))
      (comptime.comptime-error
        "format: write destination must be a nominal mutable writer"))))

;: Stream a literal template directly into a mutable writer.
(defmacro (write!
  [writer : comptime.Expr]
  [template : comptime.Expr]
  [values : comptime.Expr ...]) : FormatResult
  `(stdlib.format.format-write-expand
    ,writer
    ,template
    (__tl_format_arguments ,@values)
    0))

;: Stream formatted bytes into a mutable writer and append exactly one newline.
(defmacro (writeln!
  [writer : comptime.Expr]
  [template : comptime.Expr]
  [values : comptime.Expr ...]) : FormatResult
  `(stdlib.format.format-write-expand
    ,writer
    ,template
    (__tl_format_arguments ,@values)
    1))

;: Count decimal digits in an unsigned 64-bit value.
(define (format-u64-digit-count [value : u64]) : i64
  (let
    [cursor : u64 value]
    [digits : i64 1]
    (begin
      (while (>= cursor (cast 10 : u64))
        (begin
          (set! cursor (/ cursor (cast 10 : u64)))
          (set! digits (+ digits 1))))
      digits)))

;: Render the complete unsigned 64-bit range as decimal Display text.
(define (format-u64-core [value : u64]) : String
  (let
    [digits : i64 (format-u64-digit-count value)]
    [dst : (MutPtr u8) (string.string-runtime-alloc digits)]
    [cursor : u64 value]
    [index : i64 (- digits 1)]
    (begin
      (while (>= index 0)
        (let
          [next : u64 (/ cursor (cast 10 : u64))]
          [digit : u64 (- cursor (* next (cast 10 : u64)))]
          (begin
            (unsafe
              (ptr-write!
                (ptr-offset dst index)
                (cast (+ digit (cast 48 : u64)) : u8)))
            (set! cursor next)
            (set! index (- index 1)))))
      (unsafe
        (string-from-bytes (ptr-cast dst : (Ptr u8)) digits)))))

;: Count the minimal digits needed for one power-of-two radix value.
;:
;: `shift` is one for binary, three for octal, or four for hexadecimal. Zero
;: retains one digit; every other value loses one base digit per shift.
(define (format-u64-radix-digit-count [value : u64] [shift : i64]) : i64
  (let
    [cursor : u64 value]
    [digits : i64 1]
    (begin
      (set! cursor (shr cursor shift))
      (while (!= cursor (cast 0 : u64))
        (begin
          (set! cursor (shr cursor shift))
          (set! digits (+ digits 1))))
      digits)))

;: Render one unsigned bit pattern in binary, octal, or hexadecimal.
;:
;: Signed callers cast through their same-width unsigned twin before widening,
;: so this one converter preserves the selected integer type's exact 8/16/32/
;: 64-bit two's-complement width. The renderer allocates one exact-size String;
;: prefix/sign/width composition remains in `format-apply-options`.
(define (format-u64-radix-core
  [value : u64]
  [shift : i64]
  [uppercase? : bool]
  [alternate? : bool]) : String
  (let
    [digits : i64 (format-u64-radix-digit-count value shift)]
    [prefix-len : i64
      (if alternate?
        2
        0)]
    [output-len : i64 (+ prefix-len digits)]
    [dst : (MutPtr u8) (string.string-runtime-alloc output-len)]
    [remaining : u64 value]
    [mask : u64 (- (shl (cast 1 : u64) shift) (cast 1 : u64))]
    [index : i64 (- output-len 1)]
    (begin
      (if alternate?
        (unsafe
          (begin
            (ptr-write! dst (cast 48 : u8))
            (ptr-write!
              (ptr-offset dst 1)
              (cast
                (match shift
                  [1 98]
                  [3 111]
                  [_ 120])
                : u8))))
        unit)
      (while (>= index prefix-len)
        (let
          [digit : u64 (bit-and remaining mask)]
          [code : u64
            (if (< digit (cast 10 : u64))
              (+ digit (cast 48 : u64))
              (+
                (- digit (cast 10 : u64))
                (cast
                  (if uppercase?
                    65
                    97)
                  : u64)))]
          (begin
            (unsafe
              (ptr-write! (ptr-offset dst index) (cast code : u8)))
            (set! remaining (shr remaining shift))
            (set! index (- index 1)))))
      (unsafe
        (string-from-bytes (ptr-cast dst : (Ptr u8)) output-len)))))

;: Render normalized decimal digits with Rust exponent layout.
;:
;: `digits` is an exact or already-shortest positive decimal coefficient and
;: `decimal-exponent` is the exponent of its leading digit. A present
;: precision selects digits after the point. Exact coefficients are rounded
;: half to even; omitted precision drops insignificant trailing zeroes.
;: Positive exponents have no sign or leading zeroes. This formatter-private
;: normalization seam is also reusable by Debug's general-float policy.
(define (format-exponent-layout
  [neg : bool]
  [digits : (& digits str)]
  [decimal-exponent : i64]
  [precision-present : bool]
  [precision : i64]
  [uppercase : bool]) : String
  (let
    [source-len : i64 (string.string-length digits)]
    [significant-len : i64 source-len]
    (begin
      (if precision-present
        unit
        (while (if (> significant-len 1)
          (= (cast (string.string-ref digits (- significant-len 1)) : i64) 48)
          false)
          (set! significant-len (- significant-len 1))))
      (when
        (and precision-present (= precision 9223372036854775807))
        (format-runtime-abort-string "format: exponent output length overflow"))
      (let
        [output-significant-len : i64
          (if precision-present
            (+ precision 1)
            significant-len)]
        [round-up? : bool false]
        (begin
          (when
            (and precision-present (> source-len output-significant-len))
            (let
              [first-discarded : i64
                (cast (string.string-ref digits output-significant-len) : i64)]
              (cond
                [(> first-discarded 53) (set! round-up? true)]
                [(= first-discarded 53)
                  (let
                    [scan : i64 (+ output-significant-len 1)]
                    [tail-nonzero? : bool false]
                    (begin
                      (while (and (not tail-nonzero?) (< scan source-len))
                        (begin
                          (when
                            (!= (cast (string.string-ref digits scan) : i64) 48)
                            (set! tail-nonzero? true))
                          (set! scan (+ scan 1))))
                      (if tail-nonzero?
                        (set! round-up? true)
                        (when
                          (!=
                            (%
                              (cast
                                (string.string-ref
                                  digits
                                  (- output-significant-len 1))
                                : i64)
                              2)
                            0)
                          (set! round-up? true)))))]
                [else unit])))
          (let
            [carry-past-leading? : bool false]
            (begin
              (when
                round-up?
                (let
                  [scan : i64 0]
                  [all-nine? : bool true]
                  (begin
                    (while (and all-nine? (< scan output-significant-len))
                      (begin
                        (when
                          (!= (cast (string.string-ref digits scan) : i64) 57)
                          (set! all-nine? false))
                        (set! scan (+ scan 1))))
                    (set! carry-past-leading? all-nine?))))
              (let
                [rendered-exponent : i64
                  (+
                    decimal-exponent
                    (if carry-past-leading?
                      1
                      0))]
                [negative-exponent? : bool (< rendered-exponent 0)]
                [exponent-magnitude : u64
                  (cast
                    (if negative-exponent?
                      (- 0 rendered-exponent)
                      rendered-exponent)
                    : u64)]
                [exponent-digits : i64
                  (format-u64-digit-count exponent-magnitude)]
                [fraction-digits : i64
                  (if precision-present
                    precision
                    (- significant-len 1))]
                [fixed-output-len : i64
                  (+
                    (+
                      (+
                        (if neg
                          1
                          0)
                        1)
                      1)
                    (+
                      (if negative-exponent?
                        1
                        0)
                      exponent-digits))]
                [output-len : i64
                  (if (> fraction-digits 0)
                    (if (>
                      fraction-digits
                      (- 9223372036854775807 (+ fixed-output-len 1)))
                      (format-runtime-abort-string
                        "format: exponent output length overflow")
                      (+ fixed-output-len (+ 1 fraction-digits)))
                    fixed-output-len)]
                [dst : (MutPtr u8) (string.string-runtime-alloc output-len)]
                [cursor : i64 0]
                [digit-index : i64 0]
                [digit-start : i64
                  (if neg
                    1
                    0)]
                (begin
                  (when
                    neg
                    (begin
                      (unsafe
                        (ptr-write! dst (cast '-' : u8)))
                      (set! cursor 1)))
                  (while (< digit-index output-significant-len)
                    (begin
                      (when
                        (and (= digit-index 1) (> fraction-digits 0))
                        (begin
                          (unsafe
                            (ptr-write! (ptr-offset dst cursor) (cast '.' : u8)))
                          (set! cursor (+ cursor 1))))
                      (unsafe
                        (ptr-write!
                          (ptr-offset dst cursor)
                          (if (< digit-index source-len)
                            (cast (string.string-ref digits digit-index) : u8)
                            (cast '0' : u8))))
                      (set! cursor (+ cursor 1))
                      (set! digit-index (+ digit-index 1))))
                  (when
                    round-up?
                    (if carry-past-leading?
                      (let
                        [reset-index : i64 0]
                        (while (< reset-index output-significant-len)
                          (let
                            [destination : i64
                              (+
                                digit-start
                                (+
                                  reset-index
                                  (if (and
                                    (> reset-index 0)
                                    (> fraction-digits 0))
                                    1
                                    0)))]
                            (begin
                              (unsafe
                                (ptr-write!
                                  (ptr-offset dst destination)
                                  (cast
                                    (if (= reset-index 0)
                                      '1'
                                      '0')
                                    : u8)))
                              (set! reset-index (+ reset-index 1))))))
                      (let
                        [carry? : bool true]
                        [round-index : i64 (- output-significant-len 1)]
                        (while (and carry? (>= round-index 0))
                          (let
                            [destination : i64
                              (+
                                digit-start
                                (+
                                  round-index
                                  (if (and
                                    (> round-index 0)
                                    (> fraction-digits 0))
                                    1
                                    0)))]
                            [digit : u8
                              (unsafe
                                (ptr-read
                                  (ptr-offset
                                    (ptr-cast dst : (Ptr u8))
                                    destination)))]
                            (if (< (cast digit : i64) 57)
                              (begin
                                (unsafe
                                  (ptr-write!
                                    (ptr-offset dst destination)
                                    (cast (+ (cast digit : i64) 1) : u8)))
                                (set! carry? false))
                              (begin
                                (unsafe
                                  (ptr-write!
                                    (ptr-offset dst destination)
                                    (cast '0' : u8)))
                                (set! round-index (- round-index 1)))))))))
                  (unsafe
                    (ptr-write!
                      (ptr-offset dst cursor)
                      (cast
                        (if uppercase
                          'E'
                          'e')
                        : u8)))
                  (set! cursor (+ cursor 1))
                  (when
                    negative-exponent?
                    (begin
                      (unsafe
                        (ptr-write! (ptr-offset dst cursor) (cast '-' : u8)))
                      (set! cursor (+ cursor 1))))
                  (let
                    [remaining : u64 exponent-magnitude]
                    [write-index : i64 (- output-len 1)]
                    (while (>= write-index cursor)
                      (let
                        [next : u64 (/ remaining (cast 10 : u64))]
                        [digit : u64 (- remaining (* next (cast 10 : u64)))]
                        (begin
                          (unsafe
                            (ptr-write!
                              (ptr-offset dst write-index)
                              (cast (+ digit (cast 48 : u64)) : u8)))
                          (set! remaining next)
                          (set! write-index (- write-index 1))))))
                  (unsafe
                    (string-from-bytes (ptr-cast dst : (Ptr u8)) output-len)))))))))))

;: Render one signed integer through the shared exponent layout.
(define (format-i64-exponent-core
  [value : i64]
  [precision-present : bool]
  [precision : i64]
  [uppercase : bool]) : String
  (let
    [neg : bool (< value 0)]
    [magnitude : u64
      (if neg
        (+ (cast (- 0 (+ value 1)) : u64) (cast 1 : u64))
        (cast value : u64))]
    [decimal : String (format-u64-core magnitude)]
    [decimal-len : i64 (string.string-length (& decimal))]
    (format-exponent-layout
      neg
      (& decimal)
      (- decimal-len 1)
      precision-present
      precision
      uppercase)))

;: Render one unsigned integer through the shared exponent layout.
(define (format-u64-exponent-core
  [value : u64]
  [precision-present : bool]
  [precision : i64]
  [uppercase : bool]) : String
  (let
    [decimal : String (format-u64-core value)]
    [decimal-len : i64 (string.string-length (& decimal))]
    (format-exponent-layout
      false
      (& decimal)
      (- decimal-len 1)
      precision-present
      precision
      uppercase)))

;: Render one raw-pointer address as minimal lowercase hexadecimal text.
;:
;: The formatter macro performs the unsafe pointer-to-integer conversion at
;: the caller's expansion site. This runtime helper receives only that integer
;: representation, never dereferences or otherwise uses pointer provenance,
;: and reuses the shared lowercase hexadecimal converter.
(define (format-pointer-core [address : u64]) : String
  (format-u64-radix-core address 4 false true))

;: Fixed-capacity base-2^32 bignum backing the pure-TL float formatter.
(defstruct BigNum
  (limbs (__tl_dyn-array u64))
  (len i64))

;: Limb capacity of formatter bignum scratch buffers.
(define ftoa-cap : i64
  40)

;: Limb capacity for exact fixed-precision f64 decimal coefficients.
;:
;: The largest coefficient is a 53-bit significand multiplied by `5^1074`,
;: which needs fewer than 81 base-2^32 limbs. Shortest Display keeps the
;: smaller `ftoa-cap` buffers so omitted precision does not regress.
(define ftoa-fixed-cap : i64
  84)

;: Decimal scratch bytes covering every value representable by 84 limbs.
(define ftoa-fixed-decimal-cap : i64
  820)

;: Low 32-bit mask isolating a base-2^32 limb.
(define ftoa-mask32 : u64
  0xffffffff)

;: A zero-valued formatter BigNum with caller-selected scratch capacity.
(define (bn-zero-cap [capacity : i64]) : BigNum
  (BigNum (__tl_make-array u64 capacity) 0))

;: A zero-valued shortest-formatter BigNum.
(define (bn-zero) : BigNum
  (bn-zero-cap stdlib.format.ftoa-cap))

;: BigNum holding the u64 value x with caller-selected scratch capacity.
(define (bn-from-u64-cap [x : u64] [capacity : i64]) : BigNum
  (let
    [r : BigNum (bn-zero-cap capacity)]
    [lo : u64 (bit-and x stdlib.format.ftoa-mask32)]
    [hi : u64 (shr x 32)]
    (begin
      (set! (array-ref r.limbs 0) lo)
      (set! (array-ref r.limbs 1) hi)
      (if (> hi (cast 0 : u64))
        (BigNum r.limbs 2)
        (if (> lo (cast 0 : u64))
          (BigNum r.limbs 1)
          (BigNum r.limbs 0))))))

;: BigNum holding the u64 value x for shortest formatting.
(define (bn-from-u64 [x : u64]) : BigNum
  (bn-from-u64-cap x stdlib.format.ftoa-cap))

;: Compare BigNums a and b; -1 if a<b, 0 if equal, 1 if a>b.
(define (bn-cmp [a : (& a BigNum)] [b : (& b BigNum)]) : i64
  (let
    [la : i64 a.len]
    [lb : i64 b.len]
    (if (> la lb)
      1
      (if (< la lb)
        -1
        (let
          [i : i64 (- la 1)]
          [res : i64 0]
          [done : bool false]
          (begin
            (while (and (not done) (>= i 0))
              (let
                [av : u64 (array-ref a.limbs i)]
                [bv : u64 (array-ref b.limbs i)]
                (begin
                  (if (> av bv)
                    (begin
                      (set! res 1)
                      (set! done true))
                    (if (< av bv)
                      (begin
                        (set! res -1)
                        (set! done true))
                      unit))
                  (set! i (- i 1)))))
            res))))))

;: Limb count of arr with high zero limbs trimmed, starting from hint.
(define (bn-norm-len [arr : (& arr (__tl_dyn-array u64))] [hint : i64]) : i64
  (let
    [i : i64 hint]
    (begin
      (while (and (> i 0) (= (array-ref arr (- i 1)) (cast 0 : u64)))
        (set! i (- i 1)))
      i)))

;: Sum of BigNums a and b.
(define (bn-add [a : (& a BigNum)] [b : (& b BigNum)]) : BigNum
  (let
    [a-cap : i64 (array-length a.limbs)]
    [b-cap : i64 (array-length b.limbs)]
    [capacity : i64
      (if (> a-cap b-cap)
        a-cap
        b-cap)]
    [r : (__tl_dyn-array u64) (__tl_make-array u64 capacity)]
    [la : i64 a.len]
    [lb : i64 b.len]
    [n : i64
      (if (> la lb)
        la
        lb)]
    [carry : u64 (cast 0 : u64)]
    [i : i64 0]
    (begin
      (while (< i n)
        (let
          [av : u64
            (if (< i la)
              (array-ref a.limbs i)
              (cast 0 : u64))]
          [bv : u64
            (if (< i lb)
              (array-ref b.limbs i)
              (cast 0 : u64))]
          [s : u64 (+ (+ av bv) carry)]
          (begin
            (set! (array-ref r i) (bit-and s stdlib.format.ftoa-mask32))
            (set! carry (shr s 32))
            (set! i (+ i 1)))))
      (when
        (> carry (cast 0 : u64))
        (begin
          (set! (array-ref r i) carry)
          (set! n (+ n 1))))
      (let
        [norm : i64 (bn-norm-len (& r) n)]
        (BigNum r norm)))))

;: Product of BigNum a and a value m that fits in 32 bits.
(define (bn-mul-u32 [a : (& a BigNum)] [m : u64]) : BigNum
  (let
    [r : (__tl_dyn-array u64) (__tl_make-array u64 (array-length a.limbs))]
    [la : i64 a.len]
    [carry : u64 (cast 0 : u64)]
    [i : i64 0]
    (begin
      (while (< i la)
        (let
          [p : u64 (+ (* (array-ref a.limbs i) m) carry)]
          (begin
            (set! (array-ref r i) (bit-and p stdlib.format.ftoa-mask32))
            (set! carry (shr p 32))
            (set! i (+ i 1)))))
      (while (> carry (cast 0 : u64))
        (begin
          (set! (array-ref r i) (bit-and carry stdlib.format.ftoa-mask32))
          (set! carry (shr carry 32))
          (set! i (+ i 1))))
      (let
        [norm : i64 (bn-norm-len (& r) i)]
        (BigNum r norm)))))

;: Compare a with b multiplied by a 32-bit value without borrowing a temporary.
(define (bn-cmp-mul-u32 [a : (& a BigNum)] [b : (& b BigNum)] [m : u64]) : i64
  (let
    [product : BigNum (bn-mul-u32 b m)]
    (bn-cmp a (& product))))

;: BigNum a shifted left by n bits.
(define (bn-shl-bits [a : BigNum] [n : i64]) : BigNum
  (if (= a.len 0)
    a
    (let
      [limb-shift : i64 (/ n 32)]
      [bit-shift : i64 (% n 32)]
      [r : (__tl_dyn-array u64) (__tl_make-array u64 (array-length a.limbs))]
      [la : i64 a.len]
      [carry : u64 (cast 0 : u64)]
      [i : i64 0]
      (begin
        (if (= bit-shift 0)
          (while (< i la)
            (begin
              (set! (array-ref r (+ i limb-shift)) (array-ref a.limbs i))
              (set! i (+ i 1))))
          (while (< i la)
            (let
              [v : u64 (array-ref a.limbs i)]
              [shifted : u64
                (bit-or
                  (bit-and (shl v bit-shift) stdlib.format.ftoa-mask32)
                  carry)]
              (begin
                (set! (array-ref r (+ i limb-shift)) shifted)
                (set! carry (shr v (- 32 bit-shift)))
                (set! i (+ i 1))))))
        (when
          (and (not (= bit-shift 0)) (> carry (cast 0 : u64)))
          (set! (array-ref r (+ la limb-shift)) carry))
        (let
          [norm : i64 (bn-norm-len (& r) (+ la (+ limb-shift 1)))]
          (BigNum r norm))))))

;: BigNum a multiplied by ten raised to p.
(define (bn-mul-pow10 [a : BigNum] [p : i64]) : BigNum
  (let
    [r : BigNum a]
    [remaining : i64 p]
    (begin
      (while (>= remaining 9)
        (begin
          (set! r (bn-mul-u32 (& r) (cast 1000000000 : u64)))
          (set! remaining (- remaining 9))))
      (while (> remaining 0)
        (begin
          (set! r (bn-mul-u32 (& r) (cast 10 : u64)))
          (set! remaining (- remaining 1))))
      r)))

;: BigNum a multiplied by five raised to p.
(define (bn-mul-pow5 [a : BigNum] [p : i64]) : BigNum
  (let
    [r : BigNum a]
    [remaining : i64 p]
    (begin
      (while (>= remaining 13)
        (begin
          (set! r (bn-mul-u32 r (cast 1220703125 : u64)))
          (set! remaining (- remaining 13))))
      (while (> remaining 0)
        (begin
          (set! r (bn-mul-u32 r (cast 5 : u64)))
          (set! remaining (- remaining 1))))
      r)))

;: Difference of BigNums a and b, assuming a >= b.
(define (bn-sub [a : (& a BigNum)] [b : (& b BigNum)]) : BigNum
  (let
    [r : (__tl_dyn-array u64) (__tl_make-array u64 (array-length a.limbs))]
    [borrow : u64 (cast 0 : u64)]
    [i : i64 0]
    (begin
      (while (< i a.len)
        (let
          [av : u64 (array-ref a.limbs i)]
          [bv : u64
            (if (< i b.len)
              (array-ref b.limbs i)
              (cast 0 : u64))]
          [subtrahend : u64 (+ bv borrow)]
          (begin
            ;; Unsigned subtraction wraps, and masking its low limb is exactly
            ;; subtraction modulo 2^32. This avoids carrying a hoistable 2^32
            ;; literal across the allocation calls above: the O2 backend may
            ;; place such a rematerializable literal in a caller-saved register.
            (set!
              (array-ref r i)
              (bit-and (- av subtrahend) stdlib.format.ftoa-mask32))
            (if (>= av subtrahend)
              (set! borrow (cast 0 : u64))
              (set! borrow (cast 1 : u64)))
            (set! i (+ i 1)))))
      (let
        [norm : i64 (bn-norm-len (& r) a.len)]
        (BigNum r norm)))))

;: BigNum a shifted right by n bits.
(define (bn-shr-bits [a : (& a BigNum)] [n : i64]) : BigNum
  (if (or (= a.len 0) (<= n 0))
    (BigNum (clone a.limbs) a.len)
    (let
      [limb-shift : i64 (/ n 32)]
      [bit-shift : i64 (% n 32)]
      [capacity : i64 (array-length a.limbs)]
      [r : (__tl_dyn-array u64) (__tl_make-array u64 capacity)]
      [out-len : i64
        (if (>= limb-shift a.len)
          0
          (- a.len limb-shift))]
      [i : i64 0]
      (begin
        (while (< i out-len)
          (let
            [source-index : i64 (+ i limb-shift)]
            [low : u64 (shr (array-ref a.limbs source-index) bit-shift)]
            [high : u64
              (if (if (= bit-shift 0)
                false
                (< (+ source-index 1) a.len))
                (bit-and
                  (shl (array-ref a.limbs (+ source-index 1)) (- 32 bit-shift))
                  stdlib.format.ftoa-mask32)
                (cast 0 : u64))]
            (begin
              (set!
                (array-ref r i)
                (bit-and (bit-or low high) stdlib.format.ftoa-mask32))
              (set! i (+ i 1)))))
        (let
          [norm : i64 (bn-norm-len (& r) out-len)]
          (BigNum r norm))))))

;: Whether one zero-based bit is set in a BigNum.
(define (bn-bit-set? [a : (& a BigNum)] [index : i64]) : bool
  (if (< index 0)
    false
    (let
      [limb-index : i64 (/ index 32)]
      [bit-index : i64 (% index 32)]
      (if (>= limb-index a.len)
        false
        (!=
          (bit-and
            (shr (array-ref a.limbs limb-index) bit-index)
            (cast 1 : u64))
          (cast 0 : u64))))))

;: Whether any of the lowest `count` bits are nonzero.
(define (bn-low-bits-nonzero? [a : (& a BigNum)] [count : i64]) : bool
  (if (<= count 0)
    false
    (let
      [full-limbs : i64 (/ count 32)]
      [partial-bits : i64 (% count 32)]
      [i : i64 0]
      [found : bool false]
      (begin
        (while (and (not found) (< i full-limbs) (< i a.len))
          (begin
            (when (!= (array-ref a.limbs i) (cast 0 : u64)) (set! found true))
            (set! i (+ i 1))))
        (if (if found
          false
          (if (= partial-bits 0)
            false
            (< full-limbs a.len)))
          (let
            [mask : u64 (- (shl (cast 1 : u64) partial-bits) (cast 1 : u64))]
            (!= (bit-and (array-ref a.limbs full-limbs) mask) (cast 0 : u64)))
          found)))))

;: Divide by 2^shift and round an exact midpoint to an even quotient.
(define (bn-round-shr-even [a : BigNum] [shift : i64]) : BigNum
  (if (<= shift 0)
    a
    (let
      [quotient : BigNum (bn-shr-bits (& a) shift)]
      [half? : bool (bn-bit-set? (& a) (- shift 1))]
      [lower? : bool (bn-low-bits-nonzero? (& a) (- shift 1))]
      [odd? : bool
        (if (= quotient.len 0)
          false
          (!=
            (bit-and (array-ref quotient.limbs 0) (cast 1 : u64))
            (cast 0 : u64)))]
      (if (and half? (or lower? odd?))
        (let
          [one : BigNum (bn-from-u64-cap (cast 1 : u64) (array-length a.limbs))]
          (bn-add quotient one))
        quotient))))

;: One base-2^32 long-division step by a u32-sized divisor.
(defstruct BigDivU32Step
  (quotient BigNum)
  (remainder u64))

;: Divide a BigNum by one nonzero value that fits in 32 bits.
(define (bn-div-u32 [a : (& a BigNum)] [divisor : u64]) : BigDivU32Step
  (let
    [r : (__tl_dyn-array u64) (__tl_make-array u64 (array-length a.limbs))]
    [remainder : u64 (cast 0 : u64)]
    [i : i64 (- a.len 1)]
    (begin
      (while (>= i 0)
        (let
          [current : u64 (bit-or (shl remainder 32) (array-ref a.limbs i))]
          [digit : u64 (/ current divisor)]
          (begin
            (set! (array-ref r i) digit)
            (set! remainder (- current (* digit divisor)))
            (set! i (- i 1)))))
      (let
        [norm : i64 (bn-norm-len (& r) a.len)]
        (BigDivU32Step (BigNum r norm) remainder)))))

;: One base-10 long-division digit and its exact remainder.
(defstruct BigDigitStep
  (digit i64)
  (remainder BigNum))

;: Divide num by den when the quotient is one decimal digit.
(define (bn-div-digit [num : (& num BigNum)] [den : (& den BigNum)]) : BigDigitStep
  (let
    [digit : i64 0]
    (begin
      (while (>= (bn-cmp-mul-u32 num den (cast (+ digit 1) : u64)) 0)
        (set! digit (+ digit 1)))
      (let
        [product : BigNum (bn-mul-u32 den (cast digit : u64))]
        [remainder : BigNum (bn-sub num (& product))]
        (BigDigitStep digit remainder)))))

;: floor(a / b) for b > 0 (TL `/` truncates toward zero).
(define (ftoa-floor-div [a : i64] [b : i64]) : i64
  (if (>= a 0)
    (/ a b)
    (- 0 (/ (+ (- 0 a) (- b 1)) b))))

;: Index of the highest set bit of m.
(define (ftoa-msb-index [m : u64]) : i64
  (let
    [i : i64 0]
    [v : u64 m]
    (begin
      (while (> v (cast 1 : u64))
        (begin
          (set! v (shr v 1))
          (set! i (+ i 1))))
      i)))

;: Significant-digit string of d with trailing zeros removed (>= 1 digit).
(define (ftoa-strip-zeros [d : i64]) : String
  (let
    [dd : i64 d]
    (begin
      (while (and (> dd 9) (= (% dd 10) 0))
        (set! dd (/ dd 10)))
      (string.int->string dd))))

;: Expose an array's backing bytes without taking ownership.
(define (format-array-const-ptr [buf : (__tl_dyn-array u8)]) : (Ptr u8)
  (unsafe
    (ptr-cast (__tl_array-data buf) : (Ptr u8))))

;: Render one nonnegative BigNum as decimal digits.
(define (bn-decimal-string [value : BigNum]) : String
  (if (= value.len 0)
    "0"
    (let
      [out : (__tl_dyn-array u8)
        (__tl_make-array u8 stdlib.format.ftoa-fixed-decimal-cap)]
      [cursor : i64 stdlib.format.ftoa-fixed-decimal-cap]
      [current : BigNum value]
      (begin
        (while (> current.len 0)
          (let
            [step : BigDivU32Step (bn-div-u32 current (cast 1000000000 : u64))]
            [chunk : u64 step.remainder]
            [digit-count : i64
              (if (> step.quotient.len 0)
                9
                (format-u64-digit-count chunk))]
            [i : i64 0]
            (begin
              (while (< i digit-count)
                (let
                  [next : u64 (/ chunk (cast 10 : u64))]
                  [digit : u64 (- chunk (* next (cast 10 : u64)))]
                  (begin
                    (set! cursor (- cursor 1))
                    (set!
                      (array-ref out cursor)
                      (cast (+ digit (cast 48 : u64)) : u8))
                    (set! chunk next)
                    (set! i (+ i 1)))))
              (set! current step.quotient))))
        (unsafe
          (string-from-bytes
            (ptr-offset (format-array-const-ptr out) cursor)
            (- stdlib.format.ftoa-fixed-decimal-cap cursor)))))))

;: A string of n zero characters.
(define (ftoa-zeros [n : i64]) : String
  (let
    [out : (__tl_dyn-array u8) (__tl_make-array u8 n)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! (array-ref out i) (cast '0' : u8))
          (set! i (+ i 1))))
      (unsafe
        (string-from-bytes (format-array-const-ptr out) n)))))

;: Format significant digits whose leading digit has decimal exponent k.
;: Rust Display always uses decimal notation, including very small/large values.
(define (ftoa-render [neg : bool] [s : String] [k : i64]) : String
  (let
    [body : String ""]
    [ndig : i64 (string-length s)]
    (begin
      (cond
        [(< k 0)
          (set!
            body
            (str_cat.str-cat "0." (stdlib.format.ftoa-zeros (- (- 0 k) 1)) s))]
        [(>= (+ k 1) ndig)
          (set!
            body
            (str_cat.str-cat s (stdlib.format.ftoa-zeros (- (+ k 1) ndig)) ""))]
        [else
          (set!
            body
            (str_cat.str-cat
              (string.substring s 0 (+ k 1))
              "."
              (string.substring s (+ k 1) (- ndig (+ k 1)))))])
      (if neg
        (str_cat.str-cat "-" body "")
        body))))

;: Normalize shortest decimal Display text into exponent notation.
;:
;: This keeps shortest-digit selection in the established source-width float
;: renderer and exposes exponent normalization as a separate reusable seam.
(define (format-exponent-normalize [rendered : String] [uppercase : bool]) : String
  (let
    [rendered-len : i64 (string.string-length (& rendered))]
    [neg : bool
      (and
        (> rendered-len 0)
        (= (cast (string.string-ref (& rendered) 0) : i64) 45))]
    [start : i64
      (if neg
        1
        0)]
    [decimal-point : i64 rendered-len]
    [scan : i64 start]
    (begin
      (while (< scan rendered-len)
        (begin
          (when
            (= (cast (string.string-ref (& rendered) scan) : i64) 46)
            (set! decimal-point scan))
          (set! scan (+ scan 1))))
      (let
        [first-significant : i64 start]
        (begin
          (when
            (and
              (< decimal-point rendered-len)
              (= decimal-point (+ start 1))
              (= (cast (string.string-ref (& rendered) start) : i64) 48))
            (begin
              (set! first-significant (+ decimal-point 1))
              (while (if (< first-significant rendered-len)
                (=
                  (cast
                    (string.string-ref (& rendered) first-significant)
                    : i64)
                  48)
                false)
                (set! first-significant (+ first-significant 1)))))
          (let
            [decimal-exponent : i64
              (if (= first-significant start)
                (-
                  (if (= decimal-point rendered-len)
                    rendered-len
                    decimal-point)
                  (+ start 1))
                (- 0 (- first-significant decimal-point)))]
            [coefficient-len : i64
              (-
                (- rendered-len first-significant)
                (if (and
                  (< decimal-point rendered-len)
                  (> decimal-point first-significant))
                  1
                  0))]
            [digits : String
              (if (and
                (< decimal-point rendered-len)
                (> decimal-point first-significant))
                (str_cat.str-cat
                  (string.substring
                    rendered
                    first-significant
                    (- decimal-point first-significant))
                  (string.substring
                    rendered
                    (+ decimal-point 1)
                    (- rendered-len (+ decimal-point 1)))
                  "")
                (string.substring rendered first-significant coefficient-len))]
            (format-exponent-layout
              neg
              (& digits)
              decimal-exponent
              false
              0
              uppercase)))))))

;: Checked output byte length for fixed float Display.
(define (ftoa-fixed-output-length
  [neg : bool]
  [integer-digits : i64]
  [precision : i64]) : i64
  (let
    [base : i64
      (+
        integer-digits
        (if neg
          1
          0))]
    (if (= precision 0)
      base
      (if (> precision (- 9223372036854775807 (+ base 1)))
        (format-runtime-abort-string
          "format: fixed float output length overflow")
        (+ base (+ 1 precision))))))

;: Render exact decimal digits at `scale`, extending to requested precision.
;:
;: `precision >= scale`. Rounding has already happened when precision is below
;: the source value's exact terminating-decimal scale.
(define (ftoa-render-fixed
  [neg : bool]
  [digits : String]
  [scale : i64]
  [precision : i64]) : String
  (let
    [digits-len : i64 (string.string-length (& digits))]
    [decimal-position : i64 (- digits-len scale)]
    [integer-digits : i64
      (if (> decimal-position 0)
        decimal-position
        1)]
    [output-len : i64 (ftoa-fixed-output-length neg integer-digits precision)]
    [dst : (MutPtr u8) (string.string-runtime-alloc output-len)]
    [cursor : i64 0]
    (begin
      (when
        neg
        (begin
          (unsafe
            (ptr-write! dst (cast '-' : u8)))
          (set! cursor 1)))
      (if (= precision 0)
        (format-copy-rendered-range! (& digits) 0 dst cursor digits-len)
        (if (<= decimal-position 0)
          (begin
            (unsafe
              (ptr-write! (ptr-offset dst cursor) (cast '0' : u8)))
            (set! cursor (+ cursor 1))
            (unsafe
              (ptr-write! (ptr-offset dst cursor) (cast '.' : u8)))
            (set! cursor (+ cursor 1))
            (format-write-fill! dst cursor (- 0 decimal-position) '0')
            (set! cursor (+ cursor (- 0 decimal-position)))
            (format-copy-rendered-range! (& digits) 0 dst cursor digits-len)
            (set! cursor (+ cursor digits-len))
            (format-write-fill! dst cursor (- precision scale) '0'))
          (begin
            (format-copy-rendered-range!
              (& digits)
              0
              dst
              cursor
              decimal-position)
            (set! cursor (+ cursor decimal-position))
            (unsafe
              (ptr-write! (ptr-offset dst cursor) (cast '.' : u8)))
            (set! cursor (+ cursor 1))
            (format-copy-rendered-range!
              (& digits)
              decimal-position
              dst
              cursor
              (- digits-len decimal-position))
            (set! cursor (+ cursor (- digits-len decimal-position)))
            (format-write-fill! dst cursor (- precision scale) '0'))))
      (unsafe
        (string-from-bytes (ptr-cast dst : (Ptr u8)) output-len)))))

;: Ten raised to n for n <= 17.
(define (ftoa-pow10-u64 [n : i64]) : u64
  (let
    [result : u64 (cast 1 : u64)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! result (* result (cast 10 : u64)))
          (set! i (+ i 1))))
      result)))

;: Dragon-style shortest-decimal generation using exact interval boundaries.
(define (ftoa-shortest
  [neg : bool]
  [m : u64]
  [e2 : i64]
  [lower-close : bool]
  [max-digits : i64]) : String
  (let
    [mv : u64 (* m (cast 4 : u64))]
    [mp : u64 (+ mv (cast 2 : u64))]
    [mm : u64
      (-
        (- mv (cast 1 : u64))
        (if lower-close
          (cast 0 : u64)
          (cast 1 : u64)))]
    [boundary-e2 : i64 (- e2 2)]
    [r : BigNum (bn-from-u64 mv)]
    [s : BigNum (bn-from-u64 (cast 1 : u64))]
    [mminus : BigNum (bn-from-u64 (- mv mm))]
    [mplus : BigNum (bn-from-u64 (- mp mv))]
    [accept-bounds : bool (= (bit-and m (cast 1 : u64)) (cast 0 : u64))]
    [msb : i64 (ftoa-msb-index m)]
    [k : i64 (ftoa-floor-div (* (+ msb e2) 30103) 100000)]
    [prefix : u64 (cast 0 : u64)]
    [digits : i64 0]
    [done : bool false]
    (begin
      (if (>= boundary-e2 0)
        (begin
          (set! r (bn-shl-bits r boundary-e2))
          (set! mminus (bn-shl-bits mminus boundary-e2))
          (set! mplus (bn-shl-bits mplus boundary-e2)))
        (set! s (bn-shl-bits s (- 0 boundary-e2))))
      (if (>= k 0)
        (set! s (bn-mul-pow10 s k))
        (begin
          (set! r (bn-mul-pow10 r (- 0 k)))
          (set! mminus (bn-mul-pow10 mminus (- 0 k)))
          (set! mplus (bn-mul-pow10 mplus (- 0 k)))))
      (while (>= (bn-cmp-mul-u32 (& r) (& s) (cast 10 : u64)) 0)
        (begin
          (set! s (bn-mul-u32 s (cast 10 : u64)))
          (set! k (+ k 1))))
      (while (< (bn-cmp r s) 0)
        (begin
          (set! r (bn-mul-u32 r (cast 10 : u64)))
          (set! mminus (bn-mul-u32 mminus (cast 10 : u64)))
          (set! mplus (bn-mul-u32 mplus (cast 10 : u64)))
          (set! k (- k 1))))
      (while (not done)
        (let
          [step : BigDigitStep (bn-div-digit (& r) (& s))]
          [remainder : BigNum step.remainder]
          [low-cmp : i64 (bn-cmp (& remainder) (& mminus))]
          [high-sum : BigNum (bn-add (& remainder) (& mplus))]
          [high-cmp : i64 (bn-cmp (& high-sum) (& s))]
          [low : bool (or (< low-cmp 0) (and accept-bounds (= low-cmp 0)))]
          [high : bool (or (> high-cmp 0) (and accept-bounds (= high-cmp 0)))]
          (begin
            (set! prefix (+ (* prefix (cast 10 : u64)) (cast step.digit : u64)))
            (set! digits (+ digits 1))
            (if (or low high (>= digits max-digits))
              (let
                [round-up : bool false]
                (begin
                  (cond
                    [(and high (not low)) (set! round-up true)]
                    [(and low (not high)) unit]
                    [else
                      (let
                        [twice-remainder : BigNum (bn-shl-bits remainder 1)]
                        [half-cmp : i64 (bn-cmp (& twice-remainder) (& s))]
                        (if (> half-cmp 0)
                          (set! round-up true)
                          (if (= half-cmp 0)
                            ;; Rust shortest Display breaks an exact decimal
                            ;; midpoint toward the larger magnitude.
                            (set! round-up true)
                            unit)))])
                  (when round-up (set! prefix (+ prefix (cast 1 : u64))))
                  (when (>= prefix (ftoa-pow10-u64 digits)) (set! k (+ k 1)))
                  (set! done true)))
              (begin
                (set! r (bn-mul-u32 (& remainder) (cast 10 : u64)))
                (set! mminus (bn-mul-u32 (& mminus) (cast 10 : u64)))
                (set! mplus (bn-mul-u32 (& mplus) (cast 10 : u64))))))))
      (ftoa-render neg (ftoa-strip-zeros (cast prefix : i64)) k))))

;: Shared IEEE-754 Display implementation for f64 and f32 bit layouts.
(define (format-float-parts
  [neg : bool]
  [expf : u64]
  [frac : u64]
  [exp-max : u64]
  [mantissa-bits : i64]
  [bias : i64]
  [max-digits : i64]) : String
  (begin
    (when
      (= expf exp-max)
      (return
        (if (= frac (cast 0 : u64))
          (if neg
            "-inf"
            "inf")
          "NaN")))
    (when
      (and (= expf (cast 0 : u64)) (= frac (cast 0 : u64)))
      (return
        (if neg
          "-0"
          "0")))
    (let
      [m : u64
        (if (= expf (cast 0 : u64))
          frac
          (bit-or frac (shl (cast 1 : u64) mantissa-bits)))]
      [e2 : i64
        (if (= expf (cast 0 : u64))
          (- (- 1 bias) mantissa-bits)
          (- (- (cast expf : i64) bias) mantissa-bits))]
      [lower-close : bool (and (= frac (cast 0 : u64)) (> expf (cast 1 : u64)))]
      (ftoa-shortest neg m e2 lower-close max-digits))))

;: Shared exact fixed-precision implementation for f64 and f32 bit layouts.
(define (format-float-fixed-parts
  [neg : bool]
  [expf : u64]
  [frac : u64]
  [exp-max : u64]
  [mantissa-bits : i64]
  [bias : i64]
  [precision : i64]) : String
  (begin
    (when
      (= expf exp-max)
      (return
        (if (= frac (cast 0 : u64))
          (if neg
            "-inf"
            "inf")
          "NaN")))
    (when
      (and (= expf (cast 0 : u64)) (= frac (cast 0 : u64)))
      (return (ftoa-render-fixed neg "0" 0 precision)))
    (let
      [m : u64
        (if (= expf (cast 0 : u64))
          frac
          (bit-or frac (shl (cast 1 : u64) mantissa-bits)))]
      [e2 : i64
        (if (= expf (cast 0 : u64))
          (- (- 1 bias) mantissa-bits)
          (- (- (cast expf : i64) bias) mantissa-bits))]
      [base : BigNum (bn-from-u64-cap m stdlib.format.ftoa-fixed-cap)]
      (if (>= e2 0)
        (ftoa-render-fixed
          neg
          (bn-decimal-string (bn-shl-bits base e2))
          0
          precision)
        (let
          [exact-scale : i64 (- 0 e2)]
          (if (< precision exact-scale)
            (let
              [scaled : BigNum (bn-mul-pow5 base precision)]
              [rounded : BigNum
                (bn-round-shr-even scaled (- exact-scale precision))]
              (ftoa-render-fixed
                neg
                (bn-decimal-string rounded)
                precision
                precision))
            (let
              [coefficient : BigNum (bn-mul-pow5 base exact-scale)]
              (ftoa-render-fixed
                neg
                (bn-decimal-string coefficient)
                exact-scale
                precision))))))))

;: Render one decoded finite nonzero float at exact exponent precision.
;:
;: The terminating decimal coefficient reuses fixed formatting's wide bignum
;: capacity and feeds the common half-even significant-digit layout.
(define (format-float-exponent-exact
  [neg : bool]
  [m : u64]
  [e2 : i64]
  [precision : i64]
  [uppercase : bool]) : String
  (let
    [base : BigNum (bn-from-u64-cap m stdlib.format.ftoa-fixed-cap)]
    (if (>= e2 0)
      (let
        [digits : String (bn-decimal-string (bn-shl-bits base e2))]
        [digits-len : i64 (string.string-length (& digits))]
        (format-exponent-layout
          neg
          (& digits)
          (- digits-len 1)
          true
          precision
          uppercase))
      (let
        [exact-scale : i64 (- 0 e2)]
        [coefficient : BigNum (bn-mul-pow5 base exact-scale)]
        [digits : String (bn-decimal-string coefficient)]
        [digits-len : i64 (string.string-length (& digits))]
        (format-exponent-layout
          neg
          (& digits)
          (- (- digits-len exact-scale) 1)
          true
          precision
          uppercase)))))

;: Render an f64 with Rust Display-compatible shortest decimal semantics.
(define (format-float-core [value : f64]) : String
  (let
    [bits : u64 (__tl_float_to_bits value)]
    [neg : bool (= (bit-and (shr bits 63) (cast 1 : u64)) (cast 1 : u64))]
    [expf : u64 (bit-and (shr bits 52) (cast 0x7ff : u64))]
    [frac : u64 (bit-and bits 0xfffffffffffff)]
    (format-float-parts neg expf frac (cast 0x7ff : u64) 52 1023 17)))

;: Render an f32 at source width (without widening through f64).
(define (format-f32-core [value : f32]) : String
  (let
    [bits32 : u32 (__tl_float_to_bits value)]
    [bits : u64 (cast bits32 : u64)]
    [neg : bool (= (bit-and (shr bits 31) (cast 1 : u64)) (cast 1 : u64))]
    [expf : u64 (bit-and (shr bits 23) (cast 0xff : u64))]
    [frac : u64 (bit-and bits (cast 0x7fffff : u64))]
    (format-float-parts neg expf frac (cast 0xff : u64) 23 127 9)))

;: Render an f64 with exact fixed precision and round-half-to-even.
(define (format-float-fixed-core [value : f64] [precision : i64]) : String
  (let
    [bits : u64 (__tl_float_to_bits value)]
    [neg : bool (= (bit-and (shr bits 63) (cast 1 : u64)) (cast 1 : u64))]
    [expf : u64 (bit-and (shr bits 52) (cast 0x7ff : u64))]
    [frac : u64 (bit-and bits 0xfffffffffffff)]
    (format-float-fixed-parts
      neg
      expf
      frac
      (cast 0x7ff : u64)
      52
      1023
      precision)))

;: Render an f32 at source width with exact fixed precision.
(define (format-f32-fixed-core [value : f32] [precision : i64]) : String
  (let
    [bits32 : u32 (__tl_float_to_bits value)]
    [bits : u64 (cast bits32 : u64)]
    [neg : bool (= (bit-and (shr bits 31) (cast 1 : u64)) (cast 1 : u64))]
    [expf : u64 (bit-and (shr bits 23) (cast 0xff : u64))]
    [frac : u64 (bit-and bits (cast 0x7fffff : u64))]
    (format-float-fixed-parts neg expf frac (cast 0xff : u64) 23 127 precision)))

;: Render an f64 with Rust LowerExp/UpperExp semantics.
(define (format-float-exponent-core
  [value : f64]
  [precision-present : bool]
  [precision : i64]
  [uppercase : bool]) : String
  (let
    [bits : u64 (__tl_float_to_bits value)]
    [neg : bool (= (bit-and (shr bits 63) (cast 1 : u64)) (cast 1 : u64))]
    [expf : u64 (bit-and (shr bits 52) (cast 0x7ff : u64))]
    [frac : u64 (bit-and bits 0xfffffffffffff)]
    (begin
      (when
        (= expf (cast 0x7ff : u64))
        (return
          (if (= frac (cast 0 : u64))
            (if neg
              "-inf"
              "inf")
            "NaN")))
      (when
        (and (= expf (cast 0 : u64)) (= frac (cast 0 : u64)))
        (let
          [zero : String "0"]
          (return
            (format-exponent-layout
              neg
              (& zero)
              0
              precision-present
              precision
              uppercase))))
      (if precision-present
        (let
          [m : u64
            (if (= expf (cast 0 : u64))
              frac
              (bit-or frac (shl (cast 1 : u64) 52)))]
          [e2 : i64
            (if (= expf (cast 0 : u64))
              -1074
              (- (- (cast expf : i64) 1023) 52))]
          (format-float-exponent-exact neg m e2 precision uppercase))
        (format-exponent-normalize (format-float-core value) uppercase)))))

;: Render an f32 at source width with Rust LowerExp/UpperExp semantics.
(define (format-f32-exponent-core
  [value : f32]
  [precision-present : bool]
  [precision : i64]
  [uppercase : bool]) : String
  (let
    [bits32 : u32 (__tl_float_to_bits value)]
    [bits : u64 (cast bits32 : u64)]
    [neg : bool (= (bit-and (shr bits 31) (cast 1 : u64)) (cast 1 : u64))]
    [expf : u64 (bit-and (shr bits 23) (cast 0xff : u64))]
    [frac : u64 (bit-and bits (cast 0x7fffff : u64))]
    (begin
      (when
        (= expf (cast 0xff : u64))
        (return
          (if (= frac (cast 0 : u64))
            (if neg
              "-inf"
              "inf")
            "NaN")))
      (when
        (and (= expf (cast 0 : u64)) (= frac (cast 0 : u64)))
        (let
          [zero : String "0"]
          (return
            (format-exponent-layout
              neg
              (& zero)
              0
              precision-present
              precision
              uppercase))))
      (if precision-present
        (let
          [m : u64
            (if (= expf (cast 0 : u64))
              frac
              (bit-or frac (shl (cast 1 : u64) 23)))]
          [e2 : i64
            (if (= expf (cast 0 : u64))
              -149
              (- (- (cast expf : i64) 127) 23))]
          (format-float-exponent-exact neg m e2 precision uppercase))
        (format-exponent-normalize (format-f32-core value) uppercase)))))