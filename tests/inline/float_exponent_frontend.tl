;; Front-end coverage for decimal exponent float literals.
;;
;; These assertions intentionally live in the inline-test corpus rather than
;; production self-tests so the compiler profile does not carry test-only
;; declarations or generated symbols.
(import lex as lx)
(import token as tk)
(import compiler_float as cf)
(import format_tokens as ft)
(import format_cst as fcst)
(import format_rules as fr)
(import format_cli_core as fcli)
(import stdlib.format)
(import stdlib.io)
(import stdlib.string)

(define (fe-assert [condition : bool] [message : String]) : unit
  (if condition
    unit
    (io.panic message)))

(define (fe-lex-float-token-ok? [src : String] [expected : String]) : bool
  (match (lx.result src)
    [(lx.ResultTokens.Ok toks)
      (let
        [value : tk.Token (lx.array-shared-view toks 0)]
        [end : tk.Token (lx.array-shared-view toks 1)]
        (and
          (= (tk.tag (lx.global-shared-view value)) (tk.tag-float))
          (string.eq (tk.float value) expected)
          (= (tk.tag end) (tk.tag-end))))]
    [(lx.ResultTokens.Err _) false]))

(define (fe-lex-spanned-float-token-ok? [src : String] [expected : String]) : bool
  (match (lx.spanned-result src)
    [(lx.ResultSpannedTokens.Ok toks)
      (let
        [value : tk.Token (tk.spanned-token-tok (lx.array-shared-view toks 0))]
        [end : tk.Token (tk.spanned-token-tok (lx.array-shared-view toks 1))]
        (and
          (= (tk.tag (lx.global-shared-view value)) (tk.tag-float))
          (string.eq (tk.float value) expected)
          (= (tk.tag end) (tk.tag-end))))]
    [(lx.ResultSpannedTokens.Err _) false]))

(define (fe-lex-prefix-and-symbol-ok?) : bool
  (and
    (match (lx.result "0x1e5")
      [(lx.ResultTokens.Ok toks)
        (let
          [value : tk.Token (lx.array-shared-view toks 0)]
          [end : tk.Token (lx.array-shared-view toks 1)]
          (and
            (= (tk.tag (lx.global-shared-view value)) (tk.tag-int))
            (= (tk.int value) 485)
            (= (tk.tag end) (tk.tag-end))))]
      [(lx.ResultTokens.Err _) false])
    (match (lx.result "example value")
      [(lx.ResultTokens.Ok toks)
        (let
          [first : tk.Token (lx.array-shared-view toks 0)]
          [second : tk.Token (lx.array-shared-view toks 1)]
          [end : tk.Token (lx.array-shared-view toks 2)]
          (and
            (= (tk.tag (lx.global-shared-view first)) (tk.tag-sym))
            (string.eq (tk.sym first) "example")
            (= (tk.tag (lx.global-shared-view second)) (tk.tag-sym))
            (string.eq (tk.sym second) "value")
            (= (tk.tag end) (tk.tag-end))))]
      [(lx.ResultTokens.Err _) false])))

(define (fe-lex-malformed-exponents-ok?) : bool
  (and
    (lx.error-ok? "1e" 1 1 "lexer: malformed number literal")
    (lx.error-ok? "1e+" 1 1 "lexer: malformed number literal")
    (lx.error-ok? "1.5e" 1 1 "lexer: malformed number literal")
    (lx.error-ok? "\n  1.5e-" 2 3 "lexer: malformed number literal")
    (lx.error-ok? "1e2foo" 1 1 "lexer: malformed number literal")))

(define (fe-lex-printer-roundtrip-ok?) : bool
  (let
    [i : i64 0]
    [ok : bool true]
    (begin
      ;; Default Display is decimal-only and its shortest output must round-trip
      ;; through the decimal parser. Integer-looking Display strings are not
      ;; required to lex as float literals without an f32/f64 context.
      (while (and (< i 192) ok)
        (let
          [sign : u64
            (if (= (% i 2) 0)
              (cast 0 : u64)
              (shl (cast 1 : u64) 63))]
          [exp-field : u64 (cast (+ 1 (% (* i 37) 2046)) : u64)]
          [mantissa : u64
            (bit-or
              (shl (cast (% (* i 7919) 2048) : u64) 32)
              (cast (* i 2654435761) : u64))]
          [bits : u64 (bit-or sign (bit-or (shl exp-field 52) mantissa))]
          [text : String
            (format.format-float-core (io.float-f64-from-bits bits))]
          (begin
            (if (and
              (not
                (or
                  (string.contains (& text) "e")
                  (string.contains (& text) "E")))
              (match (io.float-parse-f64 text)
                [(io.IoFloatSomeF64 value) (= (io.float-f64-bits value) bits)]
                [(io.IoFloatNoF64) false]))
              unit
              (set! ok false))
            (set! i (+ i 1)))))
      ok)))

(define (fe-compiler-float-roundtrip-ok?) : bool
  (let
    [i : i64 0]
    [ok : bool true]
    (begin
      ;; Exercise finite f64 printer/parser pairs across signs, exponent
      ;; fields, and mantissas.  NaN/Inf exponent fields are intentionally
      ;; excluded from the generated set.
      (while (and (< i 160) ok)
        (let
          [sign : u64
            (if (= (% i 2) 0)
              (cast 0 : u64)
              (shl (cast 1 : u64) 63))]
          [exp-field : u64 (cast (+ 1 (% (* i 29) 2046)) : u64)]
          [mantissa : u64
            (bit-or
              (shl (cast (% (* i 193) 4096) : u64) 32)
              (cast (* i 2246822519) : u64))]
          [bits : u64 (bit-or sign (bit-or (shl exp-field 52) mantissa))]
          [text : String
            (cf.compiler-float-format-f64
              (cf.compiler-float-f64-from-bits bits))]
          (begin
            (if (cf.compiler-float-parse-bits-eq? text bits)
              unit
              (set! ok false))
            (set! i (+ i 1)))))
      ;; Contextual f32 parsing rounds the widened f64 spelling back to the
      ;; original binary32 payload.  Keep the same finite-only bound here.
      (set! i 0)
      (while (and (< i 160) ok)
        (let
          [sign : u32
            (if (= (% i 2) 0)
              (cast 0 : u32)
              (shl (cast 1 : u32) 31))]
          [exp-field : u32 (cast (+ 1 (% (* i 17) 254)) : u32)]
          [mantissa : u32
            (bit-or
              (shl (cast (% (* i 71) 1024) : u32) 13)
              (bit-and (cast (* i 2654435761) : u32) 0x7fffff))]
          [bits : u32 (bit-or sign (bit-or (shl exp-field 23) mantissa))]
          [value : f64 (cf.compiler-float-f32-bits-to-f64 (cast bits : u64))]
          [text : String (cf.compiler-float-format-f64 value)]
          (begin
            (if (cf.compiler-float-parse-f32-bits-eq? text (cast bits : u64))
              unit
              (set! ok false))
            (set! i (+ i 1)))))
      ok)))

(define (fe-format-cst-malformed-number-at?
  [src : String]
  [line : i64]
  [col : i64]
  [expected : String]) : bool
  (match (fcst.parse-format-source-result src)
    [(fcst.ResultFormatCst.Ok _) false]
    [(fcst.ResultFormatCst.Err err)
      (and
        (string.eq
          (ft.format-source-error-message (lx.global-shared-view err))
          expected)
        (ft.format-source-span-eq?
          (ft.format-source-error-span err)
          line
          col
          line
          col))]))

(define (fe-format-cst-malformed-exponents-ok?) : bool
  (let
    [message : String "format lexer: malformed number literal"]
    (and
      (fe-format-cst-malformed-number-at?
        "1e"
        1
        1
        (lx.global-shared-view message))
      (fe-format-cst-malformed-number-at?
        "1e+"
        1
        1
        (lx.global-shared-view message))
      (fe-format-cst-malformed-number-at?
        "1.5e"
        1
        1
        (lx.global-shared-view message))
      (fe-format-cst-malformed-number-at?
        "1e2foo"
        1
        1
        (lx.global-shared-view message))
      (fe-format-cst-malformed-number-at?
        "1.e2"
        1
        1
        (lx.global-shared-view message))
      (fe-format-cst-malformed-number-at?
        "1_0e2"
        1
        1
        (lx.global-shared-view message))
      (fe-format-cst-malformed-number-at?
        "1e2.3"
        1
        1
        (lx.global-shared-view message))
      (fe-format-cst-malformed-number-at?
        "1e2_3"
        1
        1
        (lx.global-shared-view message))
      (fe-format-cst-malformed-number-at? "\n  1.5e-" 2 3 message))))

(define (fe-format-rules-source) : String
  "(define F64_LO : f64 1.5e-9) (define F64_UP : f64 2.5E+3) (define F64_ONLY : f64 1e10) (define F32_NEG : f32 -1e-5) (define F32_PLUS : f32 1e+5)")

(define (fe-format-rules-expected) : String
  "(define F64_LO : f64
  1.5e-9)
(define F64_UP : f64
  2.5E+3)
(define F64_ONLY : f64
  1e10)
(define F32_NEG : f32
  -1e-5)
(define F32_PLUS : f32
  1e+5)")

(define (fe-format-cli-malformed-error?
  [source : String]
  [line : i64]
  [col : i64]) : bool
  (match (fr.format-rules-render-source-width-result source 80)
    [(fr.ResultFormatString.Ok _) false]
    [(fr.ResultFormatString.Err err)
      (and
        (string.eq
          (ft.format-source-error-message (lx.global-shared-view err))
          "format lexer: malformed number literal")
        (let
          [span : ft.FormatSourceSpan (ft.format-source-error-span err)]
          (ft.format-source-span-eq? span line col line col)))]))

(test
  float-exponent-lexer-token-spellings
  (begin
    (fe-assert
      (and
        (fe-lex-float-token-ok? "1.5e-9" "1.5e-9")
        (fe-lex-float-token-ok? "1e10" "1e10")
        (fe-lex-float-token-ok? "2.5E+3" "2.5E+3")
        (fe-lex-float-token-ok? "-1e-5" "-1e-5")
        (fe-lex-float-token-ok? "-1.5e+9" "-1.5e+9")
        (fe-lex-float-token-ok? "3.14" "3.14")
        (fe-lex-spanned-float-token-ok? "1.5e-9" "1.5e-9")
        (fe-lex-spanned-float-token-ok? "1e10" "1e10")
        (fe-lex-spanned-float-token-ok? "2.5E+3" "2.5E+3")
        (fe-lex-spanned-float-token-ok? "-1e-5" "-1e-5")
        (fe-lex-spanned-float-token-ok? "-1.5e+9" "-1.5e+9")
        (fe-lex-spanned-float-token-ok? "3.14" "3.14"))
      "lexer exponent token spellings changed")
    (fe-assert
      (fe-lex-prefix-and-symbol-ok?)
      "prefixed integer or symbol-e lexer behavior changed")))

(test
  float-exponent-lexer-malformed-literals
  (fe-assert
    (fe-lex-malformed-exponents-ok?)
    "lexer malformed exponent diagnostics changed"))

(test
  float-exponent-lexer-printer-roundtrip
  (fe-assert
    (fe-lex-printer-roundtrip-ok?)
    "lexer printer/parser exponent roundtrip changed"))

(test
  float-exponent-compiler-float-roundtrip
  (fe-assert
    (fe-compiler-float-roundtrip-ok?)
    "compiler float exponent roundtrip changed"))

(test
  float-exponent-format-cst
  (let
    [stream : ft.FormatTokenStream
      (ft.format-lex "(1.5e-9 1e10 2.5E+3 -1e-5 0x1e5)")]
    (begin
      (fe-assert
        (and
          (=
            (ft.format-token-tag-count
              (lx.global-shared-view stream)
              (ft.fmt-tag-int))
            5)
          (string.eq
            (ft.format-token-text
              (ft.format-token-at (lx.global-shared-view stream) 1))
            "1.5e-9")
          (string.eq
            (ft.format-token-text
              (ft.format-token-at (lx.global-shared-view stream) 2))
            "1e10")
          (string.eq
            (ft.format-token-text
              (ft.format-token-at (lx.global-shared-view stream) 3))
            "2.5E+3")
          (string.eq
            (ft.format-token-text
              (ft.format-token-at (lx.global-shared-view stream) 4))
            "-1e-5")
          (string.eq
            (ft.format-token-text
              (ft.format-token-at (lx.global-shared-view stream) 5))
            "0x1e5")
          (=
            (ft.format-token-tag
              (ft.format-token-at (lx.global-shared-view stream) 7))
            (ft.fmt-tag-end)))
        "formatter exponent atoms changed")
      (fe-assert
        (fe-format-cst-malformed-exponents-ok?)
        "formatter malformed exponent diagnostics changed"))))

(test
  float-exponent-format-rules-fixpoint
  (let
    [source : String (fe-format-rules-source)]
    [expected : String (fe-format-rules-expected)]
    [formatted : String (fr.format-rules-render-source-width source 80)]
    [fixpoint : String
      (fr.format-rules-render-source-width (lx.global-shared-view formatted) 80)]
    (begin
      (fe-assert
        (string.eq formatted expected)
        "formatter exponent rendering changed")
      (fe-assert
        (string.eq fixpoint formatted)
        "formatter exponent fixpoint changed"))))

(test
  float-exponent-format-cli-diagnostics
  (begin
    (fe-assert
      (fe-format-cli-malformed-error? "1e" 1 1)
      "missing 1e diagnostic")
    (fe-assert
      (fe-format-cli-malformed-error? "1e+" 1 1)
      "missing 1e+ diagnostic")
    (fe-assert
      (fe-format-cli-malformed-error? "1.5e" 1 1)
      "missing 1.5e diagnostic")
    (fe-assert
      (fe-format-cli-malformed-error? "\n  1.5e-" 2 3)
      "missing multiline exponent diagnostic")
    (match (fr.format-rules-render-source-width-result "\n  1.5e-" 80)
      [(fr.ResultFormatString.Ok _)
        (io.panic "malformed exponent unexpectedly formatted")]
      [(fr.ResultFormatString.Err err)
        (fe-assert
          (string.eq
            (fcli.fmt-source-error-message "bad.tl" err)
            "bad.tl:2:3: format lexer: malformed number literal")
          "CLI malformed exponent path diagnostic changed")])))