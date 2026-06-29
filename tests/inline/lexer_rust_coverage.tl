;; lexer_rust_coverage.tl — TypeLisp-owned coverage for src/lexer.rs inline
;; unit tests (refs #1071).
;;
;; This file exercises the remaining Rust test assertions that are not yet
;; mirrored by src/lex.tl self-tests, using the (test ...) inline harness
;; from #947 so the CI verification script picks them up automatically.
(import "../../src/lex.tl")
(import "../../src/token.tl")
(import stdlib.io)
(import "../../stdlib/string.tl")

(define (lexer-assert-true [condition : bool] [message : String]) : unit
  (if condition
    unit
    (io.panic message)))

(define (lexer-assert-bool-eq
  [actual : bool]
  [expected : bool]
  [message : String]) : unit
  (lexer-assert-true (= actual expected) message))

(define (lexer-assert-char-eq
  [actual : char]
  [expected : char]
  [message : String]) : unit
  (lexer-assert-true (= (cast actual : i64) (cast expected : i64)) message))

;; ---- 1. src/lexer.rs test_basic_tokens  --------------------------------
(test
  lexer-basic-tokens
  (let
    [r : ResultTokens (lex-result "(define x 42)")]
    (match r
      [(ResultTokens.Ok toks)
        (let
          [ok : bool true]
          (begin
            (if (= (token.token-tag (array-ref toks 0)) (token.tag-lparen))
              unit
              (set! ok false))
            (if (= (token.token-tag (array-ref toks 1)) (token.tag-sym))
              unit
              (set! ok false))
            (if (string-eq (token.token-sym (array-ref toks 1)) "define")
              unit
              (set! ok false))
            (if (= (token.token-tag (array-ref toks 2)) (token.tag-sym))
              unit
              (set! ok false))
            (if (string-eq (token.token-sym (array-ref toks 2)) "x")
              unit
              (set! ok false))
            (if (= (token.token-tag (array-ref toks 3)) (token.tag-int))
              unit
              (set! ok false))
            (if (= (token.token-int (array-ref toks 3)) 42)
              unit
              (set! ok false))
            (if (= (token.token-tag (array-ref toks 4)) (token.tag-rparen))
              unit
              (set! ok false))
            (lexer-assert-bool-eq
              ok
              true
              "basic token sequence should match Rust test_basic_tokens")))]
      [(ResultTokens.Err e) (lexer-assert-true false e)])))

;; ---- 2. src/lexer.rs test_types ----------------------------------------
(test
  lexer-arrow-type-tokens
  (let
    [r : ResultTokens (lex-result "(-> i64 i64)")]
    (match r
      [(ResultTokens.Ok toks)
        (let
          [ok : bool true]
          (begin
            (if (= (token.token-tag (array-ref toks 0)) (token.tag-lparen))
              unit
              (set! ok false))
            (if (= (token.token-tag (array-ref toks 1)) (token.tag-sym))
              unit
              (set! ok false))
            (if (string-eq (token.token-sym (array-ref toks 1)) "->")
              unit
              (set! ok false))
            (if (= (token.token-tag (array-ref toks 2)) (token.tag-sym))
              unit
              (set! ok false))
            (if (string-eq (token.token-sym (array-ref toks 2)) "i64")
              unit
              (set! ok false))
            (if (= (token.token-tag (array-ref toks 3)) (token.tag-sym))
              unit
              (set! ok false))
            (if (string-eq (token.token-sym (array-ref toks 3)) "i64")
              unit
              (set! ok false))
            (if (= (token.token-tag (array-ref toks 4)) (token.tag-rparen))
              unit
              (set! ok false))
            (lexer-assert-bool-eq
              ok
              true
              "arrow-type tokens should lex as single tokens")))]
      [(ResultTokens.Err e) (lexer-assert-true false e)])))

(test
  lexer-duplicate-symbols-share-intern-id
  (let
    [r : ResultTokens (lex-result "(x x y)")]
    (match r
      [(ResultTokens.Ok toks)
        (lexer-assert-true
          (and
            (=
              (token.token-sym-id (array-ref toks 1))
              (token.token-sym-id (array-ref toks 2)))
            (not
              (=
                (token.token-sym-id (array-ref toks 1))
                (token.token-sym-id (array-ref toks 3))))
            (string-eq (token.token-sym (array-ref toks 1)) "x")
            (string-eq (token.token-sym (array-ref toks 3)) "y"))
          "duplicate symbols should reuse the same intern id")]
      [(ResultTokens.Err e) (lexer-assert-true false e)])))

;; ---- 3. src/lexer.rs test_single_char_literals -------------------------
(test
  lexer-single-char-literal-a
  (let
    [toks : (Array token.Token) (lex "'a'")]
    (lexer-assert-char-eq
      (token.token-char (array-ref toks 0))
      'a'
      "lowercase single char")))

(test
  lexer-single-char-literal-Z
  (let
    [toks : (Array token.Token) (lex "'Z'")]
    (lexer-assert-char-eq
      (token.token-char (array-ref toks 0))
      'Z'
      "uppercase single char")))

(test
  lexer-single-char-literal-zero
  (let
    [toks : (Array token.Token) (lex "'0'")]
    (lexer-assert-char-eq
      (token.token-char (array-ref toks 0))
      '0'
      "digit single char")))

(test
  lexer-single-char-literal-lparen
  (let
    [toks : (Array token.Token) (lex "'('")]
    (lexer-assert-char-eq
      (token.token-char (array-ref toks 0))
      '('
      "punctuation single char")))

(test
  lexer-single-char-literal-plus
  (let
    [toks : (Array token.Token) (lex "'+'")]
    (lexer-assert-char-eq
      (token.token-char (array-ref toks 0))
      '+'
      "symbol single char")))

(test
  lexer-single-char-literal-space
  (let
    [toks : (Array token.Token) (lex "' '")]
    (lexer-assert-char-eq
      (token.token-char (array-ref toks 0))
      ' '
      "space single char")))

;; ---- 4. src/lexer.rs test_escaped_char_literals (extra edge) -----------
(test
  lexer-legacy-escaped-char-literal-rejected
  (let
    [r : ResultTokens (lex-result "#\\a'")]
    (match r
      [(ResultTokens.Ok _)
        (lexer-assert-true false "legacy escaped char should error")]
      [(ResultTokens.Err msg)
        (let
          [haystack : String msg]
          [needle : String "unexpected character"]
          (lexer-assert-bool-eq
            (string-contains (& haystack) (& needle))
            true
            "legacy escaped char literal should be rejected"))])))

(test
  lexer-apostrophe-char-literal-a
  (let
    [toks : (Array token.Token) (lex "'a'")]
    (lexer-assert-char-eq
      (token.token-char (array-ref toks 0))
      'a'
      "apostrophe lowercase single char")))

(test
  lexer-apostrophe-char-literal-space
  (let
    [toks : (Array token.Token) (lex "' '")]
    (lexer-assert-char-eq
      (token.token-char (array-ref toks 0))
      ' '
      "apostrophe space single char")))

(test
  lexer-apostrophe-char-literal-double-quote
  (let
    [toks : (Array token.Token) (lex "'\"'")]
    (lexer-assert-bool-eq
      (= (cast (token.token-char (array-ref toks 0)) : i64) 34)
      true
      "apostrophe double quote single char")))

(test
  lexer-apostrophe-escaped-char-literal-newline
  (let
    [toks : (Array token.Token) (lex "'\\n'")]
    (lexer-assert-char-eq
      (token.token-char (array-ref toks 0))
      '\n'
      "apostrophe escaped newline")))

(test
  lexer-apostrophe-invalid-escape-errors
  (let
    [r : ResultTokens (lex-result "'\\x'")]
    (match r
      [(ResultTokens.Ok _) (lexer-assert-true false "should error")]
      [(ResultTokens.Err msg)
        (let
          [haystack : String msg]
          [needle : String "unknown character escape"]
          (lexer-assert-bool-eq
            (string-contains (& haystack) (& needle))
            true
            "apostrophe unknown escape should error"))])))

(test
  lexer-apostrophe-quote-vs-char
  (match (lex-result "'form")
    [(ResultTokens.Ok toks)
      (lexer-assert-true
        (and
          (= (token.token-tag (array-ref toks 0)) (token.tag-quote))
          (= (token.token-tag (array-ref toks 1)) (token.tag-sym))
          (string-eq (token.token-sym (array-ref toks 1)) "form")
          (= (token.token-tag (array-ref toks 2)) (token.tag-end)))
        "apostrophe quote should still quote forms")]
    [(ResultTokens.Err msg) (lexer-assert-true false msg)]))

;; ---- 5. src/lexer.rs test_char_literal_in_context ----------------------
(test
  lexer-char-literal-in-context
  (let
    [r : ResultTokens (lex-result "(= c ' ')")]
    (match r
      [(ResultTokens.Ok toks)
        (let
          [ok : bool true]
          (begin
            (if (= (token.token-tag (array-ref toks 0)) (token.tag-lparen))
              unit
              (set! ok false))
            (if (= (token.token-tag (array-ref toks 1)) (token.tag-sym))
              unit
              (set! ok false))
            (if (string-eq (token.token-sym (array-ref toks 1)) "=")
              unit
              (set! ok false))
            (if (= (token.token-tag (array-ref toks 2)) (token.tag-sym))
              unit
              (set! ok false))
            (if (string-eq (token.token-sym (array-ref toks 2)) "c")
              unit
              (set! ok false))
            (if (= (token.token-tag (array-ref toks 3)) (token.tag-char))
              unit
              (set! ok false))
            (if (= (token.token-char (array-ref toks 3)) ' ')
              unit
              (set! ok false))
            (if (= (token.token-tag (array-ref toks 4)) (token.tag-rparen))
              unit
              (set! ok false))
            (lexer-assert-bool-eq
              ok
              true
              "char literal should lex in a surrounding token stream")))]
      [(ResultTokens.Err e) (lexer-assert-true false e)])))

;; ---- 6. src/lexer.rs test_spans_single_line ----------------------------
(test
  lexer-single-line-spans
  (let
    [r : ResultSpannedTokens (lex-spanned-result "(define x 42)")]
    (match r
      [(ResultSpannedTokens.Ok s)
        (let
          [ok : bool true]
          (begin
            (if (= (token.spanned-token-line (array-ref s 0)) 1)
              unit
              (set! ok false))
            (if (= (token.spanned-token-col (array-ref s 0)) 1)
              unit
              (set! ok false))
            (if (= (token.spanned-token-line (array-ref s 1)) 1)
              unit
              (set! ok false))
            (if (= (token.spanned-token-col (array-ref s 1)) 2)
              unit
              (set! ok false))
            (if (= (token.spanned-token-line (array-ref s 2)) 1)
              unit
              (set! ok false))
            (if (= (token.spanned-token-col (array-ref s 2)) 9)
              unit
              (set! ok false))
            (if (= (token.spanned-token-line (array-ref s 3)) 1)
              unit
              (set! ok false))
            (if (= (token.spanned-token-col (array-ref s 3)) 11)
              unit
              (set! ok false))
            (if (= (token.spanned-token-line (array-ref s 4)) 1)
              unit
              (set! ok false))
            (if (= (token.spanned-token-col (array-ref s 4)) 13)
              unit
              (set! ok false))
            (if (= (token.spanned-token-line (array-ref s 5)) 1)
              unit
              (set! ok false))
            (if (= (token.spanned-token-col (array-ref s 5)) 14)
              unit
              (set! ok false))
            (if (=
              (token.token-tag (token.spanned-token-tok (array-ref s 5)))
              (token.tag-end))
              unit
              (set! ok false))
            (lexer-assert-bool-eq
              ok
              true
              "single-line spans should match Rust test_spans_single_line")))]
      [(ResultSpannedTokens.Err e)
        (lexer-assert-true false (token.source-error-message e))])))

;; ---- 7. src/lexer.rs test_spans_multi_line_and_blank_lines -------------
(test
  lexer-multi-line-blank-spans
  (let
    [r : ResultSpannedTokens (lex-spanned-result "(a\n\n  bb)")]
    (match r
      [(ResultSpannedTokens.Ok s)
        (let
          [ok : bool true]
          (begin
            (if (= (token.spanned-token-line (array-ref s 1)) 1)
              unit
              (set! ok false))
            (if (= (token.spanned-token-col (array-ref s 1)) 2)
              unit
              (set! ok false))
            (if (= (token.spanned-token-line (array-ref s 2)) 3)
              unit
              (set! ok false))
            (if (= (token.spanned-token-col (array-ref s 2)) 3)
              unit
              (set! ok false))
            (lexer-assert-bool-eq
              ok
              true
              "multi-line blank spans should match Rust test")))]
      [(ResultSpannedTokens.Err e)
        (lexer-assert-true false (token.source-error-message e))])))

;; ---- 8. src/lexer.rs EOF handling --------------------------------------
(test
  lexer-eof-singleton
  (let
    [toks : (Array token.Token) (lex "")]
    (lexer-assert-bool-eq
      (= (token.token-tag (array-ref toks 0)) (token.tag-end))
      true
      "empty source should yield just EOF")))

;; ---- 9. Additional Rust inline tests -----------------------------------
(test
  lexer-legacy-named-char-rejected
  (let
    [r : ResultTokens (lex-result "#\\spcae'")]
    (match r
      [(ResultTokens.Ok _) (lexer-assert-true false "should error")]
      [(ResultTokens.Err msg)
        (let
          [haystack : String msg]
          [needle : String "unexpected character"]
          (lexer-assert-bool-eq
            (string-contains (& haystack) (& needle))
            true
            "legacy named char literal should be rejected"))])))

(test
  lexer-control-char-literals
  (let
    [toks : (Array token.Token) (lex "' '")]
    (lexer-assert-char-eq
      (token.token-char (array-ref toks 0))
      ' '
      "space char literal"))
  (let
    [toks : (Array token.Token) (lex "'\\n'")]
    (lexer-assert-char-eq
      (token.token-char (array-ref toks 0))
      '\n'
      "newline char literal"))
  (let
    [toks : (Array token.Token) (lex "'\\t'")]
    (lexer-assert-char-eq
      (token.token-char (array-ref toks 0))
      '\t'
      "tab char literal"))
  (let
    [toks : (Array token.Token) (lex "'\\r'")]
    (lexer-assert-char-eq
      (token.token-char (array-ref toks 0))
      '\r'
      "return char literal"))
  (let
    [toks : (Array token.Token) (lex "'\\0'")]
    (lexer-assert-char-eq
      (token.token-char (array-ref toks 0))
      '\0'
      "nul char literal")))

(test
  lexer-apostrophe-escaped-char-literals
  (let
    [toks : (Array token.Token) (lex "'\\n'")]
    (lexer-assert-char-eq (token.token-char (array-ref toks 0)) '\n' "escape n"))
  (let
    [toks : (Array token.Token) (lex "'\\t'")]
    (lexer-assert-char-eq (token.token-char (array-ref toks 0)) '\t' "escape t"))
  (let
    [toks : (Array token.Token) (lex "'\\r'")]
    (lexer-assert-char-eq (token.token-char (array-ref toks 0)) '\r' "escape r"))
  (let
    [toks : (Array token.Token) (lex "'\\0'")]
    (lexer-assert-char-eq (token.token-char (array-ref toks 0)) '\0' "escape 0"))
  ;; ordinary letters are direct character payloads in the apostrophe syntax
  )