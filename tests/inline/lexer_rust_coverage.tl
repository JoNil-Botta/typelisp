;; lexer_rust_coverage.tl — TypeLisp-owned coverage for src/lexer.rs inline
;; unit tests (refs #1071).
;;
;; This file exercises the remaining Rust test assertions that are not yet
;; mirrored by selfhost/lex.tl self-tests, using the (test ...) inline harness
;; from #947 so the no-Rust verification script picks them up automatically.
(import "../../selfhost/lex.tl")

(define (lexer-assert-true [condition : bool] [message : String]) : unit
  (if condition
    unit
    (panic message)))

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
      [(OkTokens toks)
        (let
          [ok : bool true]
          (begin
            (if (= (token-tag (array-ref toks 0)) (tag-lparen))
              unit
              (set! ok false))
            (if (= (token-tag (array-ref toks 1)) (tag-sym))
              unit
              (set! ok false))
            (if (string-eq (token-sym (array-ref toks 1)) "define")
              unit
              (set! ok false))
            (if (= (token-tag (array-ref toks 2)) (tag-sym))
              unit
              (set! ok false))
            (if (string-eq (token-sym (array-ref toks 2)) "x")
              unit
              (set! ok false))
            (if (= (token-tag (array-ref toks 3)) (tag-int))
              unit
              (set! ok false))
            (if (= (token-int (array-ref toks 3)) 42)
              unit
              (set! ok false))
            (if (= (token-tag (array-ref toks 4)) (tag-rparen))
              unit
              (set! ok false))
            (lexer-assert-bool-eq
              ok
              true
              "basic token sequence should match Rust test_basic_tokens")))]
      [(ErrTokens e) (lexer-assert-true false e)])))

;; ---- 2. src/lexer.rs test_types ----------------------------------------
(test
  lexer-arrow-type-tokens
  (let
    [r : ResultTokens (lex-result "(-> i64 i64)")]
    (match r
      [(OkTokens toks)
        (let
          [ok : bool true]
          (begin
            (if (= (token-tag (array-ref toks 0)) (tag-lparen))
              unit
              (set! ok false))
            (if (= (token-tag (array-ref toks 1)) (tag-sym))
              unit
              (set! ok false))
            (if (string-eq (token-sym (array-ref toks 1)) "->")
              unit
              (set! ok false))
            (if (= (token-tag (array-ref toks 2)) (tag-sym))
              unit
              (set! ok false))
            (if (string-eq (token-sym (array-ref toks 2)) "i64")
              unit
              (set! ok false))
            (if (= (token-tag (array-ref toks 3)) (tag-sym))
              unit
              (set! ok false))
            (if (string-eq (token-sym (array-ref toks 3)) "i64")
              unit
              (set! ok false))
            (if (= (token-tag (array-ref toks 4)) (tag-rparen))
              unit
              (set! ok false))
            (lexer-assert-bool-eq
              ok
              true
              "arrow-type tokens should lex as single tokens")))]
      [(ErrTokens e) (lexer-assert-true false e)])))

(test
  lexer-duplicate-symbols-share-intern-id
  (let
    [r : ResultTokens (lex-result "(x x y)")]
    (match r
      [(OkTokens toks)
        (lexer-assert-true
          (and
            (=
              (token-sym-id (array-ref toks 1))
              (token-sym-id (array-ref toks 2)))
            (not
              (=
                (token-sym-id (array-ref toks 1))
                (token-sym-id (array-ref toks 3))))
            (string-eq (token-sym (array-ref toks 1)) "x")
            (string-eq (token-sym (array-ref toks 3)) "y"))
          "duplicate symbols should reuse the same intern id")]
      [(ErrTokens e) (lexer-assert-true false e)])))

;; ---- 3. src/lexer.rs test_single_char_literals -------------------------
(test
  lexer-single-char-literal-a
  (let
    [toks : (Array Token) (lex "#a'")]
    (lexer-assert-char-eq
      (token-char (array-ref toks 0))
      #a'
      "lowercase single char")))

(test
  lexer-single-char-literal-Z
  (let
    [toks : (Array Token) (lex "#Z'")]
    (lexer-assert-char-eq
      (token-char (array-ref toks 0))
      #Z'
      "uppercase single char")))

(test
  lexer-single-char-literal-zero
  (let
    [toks : (Array Token) (lex "#0'")]
    (lexer-assert-char-eq
      (token-char (array-ref toks 0))
      #0'
      "digit single char")))

(test
  lexer-single-char-literal-lparen
  (let
    [toks : (Array Token) (lex "#('")]
    (lexer-assert-char-eq
      (token-char (array-ref toks 0))
      #('
      "punctuation single char")))

(test
  lexer-single-char-literal-plus
  (let
    [toks : (Array Token) (lex "#+'")]
    (lexer-assert-char-eq
      (token-char (array-ref toks 0))
      #+'
      "symbol single char")))

(test
  lexer-single-char-literal-space
  (let
    [toks : (Array Token) (lex "# '")]
    (lexer-assert-char-eq
      (token-char (array-ref toks 0))
      #\space'
      "space single char")))

;; ---- 4. src/lexer.rs test_escaped_char_literals (extra edge) -----------
(test
  lexer-escaped-char-literal-a
  (let
    [toks : (Array Token) (lex "#\\a'")]
    (lexer-assert-char-eq
      (token-char (array-ref toks 0))
      #a'
      "escaped ordinary letter")))

;; ---- 5. src/lexer.rs test_named_char_literal_in_context ----------------
(test
  lexer-named-char-in-context
  (let
    [r : ResultTokens (lex-result "(= c #\\space')")]
    (match r
      [(OkTokens toks)
        (let
          [ok : bool true]
          (begin
            (if (= (token-tag (array-ref toks 0)) (tag-lparen))
              unit
              (set! ok false))
            (if (= (token-tag (array-ref toks 1)) (tag-sym))
              unit
              (set! ok false))
            (if (string-eq (token-sym (array-ref toks 1)) "=")
              unit
              (set! ok false))
            (if (= (token-tag (array-ref toks 2)) (tag-sym))
              unit
              (set! ok false))
            (if (string-eq (token-sym (array-ref toks 2)) "c")
              unit
              (set! ok false))
            (if (= (token-tag (array-ref toks 3)) (tag-char))
              unit
              (set! ok false))
            (if (= (token-char (array-ref toks 3)) #\space')
              unit
              (set! ok false))
            (if (= (token-tag (array-ref toks 4)) (tag-rparen))
              unit
              (set! ok false))
            (lexer-assert-bool-eq
              ok
              true
              "named char literal should lex in a surrounding token stream")))]
      [(ErrTokens e) (lexer-assert-true false e)])))

;; ---- 6. src/lexer.rs test_spans_single_line ----------------------------
(test
  lexer-single-line-spans
  (let
    [r : ResultSpannedTokens (lex-spanned-result "(define x 42)")]
    (match r
      [(OkSpannedTokens s)
        (let
          [ok : bool true]
          (begin
            (if (= (spanned-token-line (array-ref s 0)) 1)
              unit
              (set! ok false))
            (if (= (spanned-token-col (array-ref s 0)) 1)
              unit
              (set! ok false))
            (if (= (spanned-token-line (array-ref s 1)) 1)
              unit
              (set! ok false))
            (if (= (spanned-token-col (array-ref s 1)) 2)
              unit
              (set! ok false))
            (if (= (spanned-token-line (array-ref s 2)) 1)
              unit
              (set! ok false))
            (if (= (spanned-token-col (array-ref s 2)) 9)
              unit
              (set! ok false))
            (if (= (spanned-token-line (array-ref s 3)) 1)
              unit
              (set! ok false))
            (if (= (spanned-token-col (array-ref s 3)) 11)
              unit
              (set! ok false))
            (if (= (spanned-token-line (array-ref s 4)) 1)
              unit
              (set! ok false))
            (if (= (spanned-token-col (array-ref s 4)) 13)
              unit
              (set! ok false))
            (if (= (spanned-token-line (array-ref s 5)) 1)
              unit
              (set! ok false))
            (if (= (spanned-token-col (array-ref s 5)) 14)
              unit
              (set! ok false))
            (if (= (token-tag (spanned-token-tok (array-ref s 5))) (tag-end))
              unit
              (set! ok false))
            (lexer-assert-bool-eq
              ok
              true
              "single-line spans should match Rust test_spans_single_line")))]
      [(ErrSpannedTokens e) (lexer-assert-true false (source-error-message e))])))

;; ---- 7. src/lexer.rs test_spans_multi_line_and_blank_lines -------------
(test
  lexer-multi-line-blank-spans
  (let
    [r : ResultSpannedTokens (lex-spanned-result "(a\n\n  bb)")]
    (match r
      [(OkSpannedTokens s)
        (let
          [ok : bool true]
          (begin
            (if (= (spanned-token-line (array-ref s 1)) 1)
              unit
              (set! ok false))
            (if (= (spanned-token-col (array-ref s 1)) 2)
              unit
              (set! ok false))
            (if (= (spanned-token-line (array-ref s 2)) 3)
              unit
              (set! ok false))
            (if (= (spanned-token-col (array-ref s 2)) 3)
              unit
              (set! ok false))
            (lexer-assert-bool-eq
              ok
              true
              "multi-line blank spans should match Rust test")))]
      [(ErrSpannedTokens e) (lexer-assert-true false (source-error-message e))])))

;; ---- 8. src/lexer.rs EOF handling --------------------------------------
(test
  lexer-eof-singleton
  (let
    [toks : (Array Token) (lex "")]
    (lexer-assert-bool-eq
      (= (token-tag (array-ref toks 0)) (tag-end))
      true
      "empty source should yield just EOF")))

;; ---- 9. Additional Rust inline tests -----------------------------------
(test
  lexer-error-on-unknown-named-char
  (let
    [r : ResultTokens (lex-result "#\\spcae'")]
    (match r
      [(OkTokens _) (lexer-assert-true false "should error")]
      [(ErrTokens msg)
        (let
          [haystack : String msg]
          [needle : String "unknown named character literal"]
          (lexer-assert-bool-eq
            (string-contains (& haystack) (& needle))
            true
            "unknown named char literal should error"))])))

(test
  lexer-named-char-literals
  (let
    [toks : (Array Token) (lex "#\\space'")]
    (lexer-assert-char-eq
      (token-char (array-ref toks 0))
      #\space'
      "named char #space"))
  (let
    [toks : (Array Token) (lex "#\\newline'")]
    (lexer-assert-char-eq
      (token-char (array-ref toks 0))
      #\newline'
      "named char #newline"))
  (let
    [toks : (Array Token) (lex "#\\tab'")]
    (lexer-assert-char-eq
      (token-char (array-ref toks 0))
      #\tab'
      "named char #tab"))
  (let
    [toks : (Array Token) (lex "#\\return'")]
    (lexer-assert-char-eq
      (token-char (array-ref toks 0))
      #\return'
      "named char #return"))
  (let
    [toks : (Array Token) (lex "#\\nul'")]
    (lexer-assert-char-eq
      (token-char (array-ref toks 0))
      #\nul'
      "named char #nul")))

(test
  lexer-escaped-char-literals
  (let
    [toks : (Array Token) (lex "#\\n'")]
    (lexer-assert-char-eq (token-char (array-ref toks 0)) #\newline' "escape n"))
  (let
    [toks : (Array Token) (lex "#\\t'")]
    (lexer-assert-char-eq (token-char (array-ref toks 0)) #\tab' "escape t"))
  (let
    [toks : (Array Token) (lex "#\\r'")]
    (lexer-assert-char-eq (token-char (array-ref toks 0)) #\return' "escape r"))
  (let
    [toks : (Array Token) (lex "#\\0'")]
    (lexer-assert-char-eq (token-char (array-ref toks 0)) #\nul' "escape 0"))
  ;; already have escaped ordinary letter in test 4
  )