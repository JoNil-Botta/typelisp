;; lexer.tl - A lexer for TypeLisp's OWN s-expression syntax, written in
;; TypeLisp itself. The first piece of the *real* self-hosting compiler front end
;; (#27): it tokenizes actual TypeLisp source - the surface this very file is
;; written in - rather than the arithmetic-calculator surface that `lexer.tl` /
;; `calc.tl` exercise.
;;
;; --------------------------------------------------------------------------
;; What "TypeLisp's own syntax" means for the tokenizer.
;; --------------------------------------------------------------------------
;; TypeLisp source is s-expressions: balanced parentheses around atoms. An atom
;; is either an integer literal or a *symbol* - and in an s-expression language a
;; symbol is everything else that is one contiguous lexeme: an operator (`+`), a
;; comparison (`<=`), a keyword (`define`, `let`, `while`), a builtin name
;; (`string->int`, `array-set!`), or a user name (`parse-expr`). So the lexer
;; does NOT recognise a fixed operator alphabet the way the calculator lexer
;; does; it slices each maximal symbol/int run out of the source. The token kinds
;; collapse to: `(` `)` integer symbol end (see the imported `token.tl`).
;;
;; The scan loop is the shape of a real lexer: a cursor over the input, a
;; whitespace skip, single-char paren tokens, a digit run sliced into a
;; `(TInt (string->int ...))`, and a symbol run sliced into a `(TSym ...)` with
;; `substring`, string literals, char literals, and line comments. The reusable
;; entrypoint returns malformed input as a recoverable `ResultTokens` value; the
;; legacy `lex` wrapper still panics for older callers.
;;
;; String literals (`"..."`), char literals (`#x'` / `#\x'`), and `;` line
;; comments are now lexed too: a `"` opens a string whose inner text is sliced
;; into a `(TStr ...)` (closing quote skipped), a `#` opens a character literal
;; recorded as `(TChar ...)`, and a `;` skips the rest of the line, emitting no
;; token.
;;
;; Deferred - current scope boundaries, recorded as self-hosting signal:
;;   - String-literal ESCAPES (`\"`, `\n`, ...): the inner text is sliced raw,
;;     so `\"` does NOT continue the string and `\n` is two literal chars.
;;   - Keyword classification: keywords are lexed as plain `TSym` tokens here; a
;;     later pass (or the parser) distinguishes `define`/`let`/... from names.

;; The reusable lexer lives in the `main`-less `lex.tl` module. This demo imports
;; it rather than carrying a second copy, so `lex`, `lex-result`, `Token`, and the
;; token accessors all flow through one implementation.
(import "lex.tl")

;; Count the TSym tokens in `toks` up to and including the TEnd sentinel: walk
;; the array, tallying each token whose tag is `tag-sym`, and stop at TEnd. An
;; observable, count-based result that depends on the symbol classification.
(define (count-syms [toks : (Array Token)]) : i64
  (let ([i : i64 0]
        [syms : i64 0]
        [keep : bool true])
    (begin
      (while keep
        (let ([t : i64 (token-tag (array-ref toks i))])
          (if (= t (tag-end))
              (set! keep false)
              (begin
                (if (= t (tag-sym))
                    (set! syms (+ syms 1))
                    (set! syms syms))
                (set! i (+ i 1))))))
      syms)))

;; Count the TStr tokens in `toks` up to the TEnd sentinel: same walk, tallying
;; each token whose tag is `tag-str`. Depends on the string-literal lexing.
(define (count-strs [toks : (Array Token)]) : i64
  (let ([i : i64 0]
        [strs : i64 0]
        [keep : bool true])
    (begin
      (while keep
        (let ([t : i64 (token-tag (array-ref toks i))])
          (if (= t (tag-end))
              (set! keep false)
              (begin
                (if (= t (tag-str))
                    (set! strs (+ strs 1))
                    (set! strs strs))
                (set! i (+ i 1))))))
      strs)))

;; Count the TChar tokens in `toks` up to the TEnd sentinel: same walk, tallying
;; each token whose tag is `tag-char`. Depends on char literal lexing and keeps
;; chars observably distinct from symbols, ints, and strings.
(define (count-chars [toks : (Array Token)]) : i64
  (let ([i : i64 0]
        [chars : i64 0]
        [keep : bool true])
    (begin
      (while keep
        (let ([t : i64 (token-tag (array-ref toks i))])
          (if (= t (tag-end))
              (set! keep false)
              (begin
                (if (= t (tag-char))
                    (set! chars (+ chars 1))
                    (set! chars chars))
                (set! i (+ i 1))))))
      chars)))

;; Sum character code points in TChar tokens so the demo observes decoded
;; single, escaped, and named character values, not just token tags.
(define (sum-char-codes [toks : (Array Token)]) : i64
  (let ([i : i64 0]
        [total : i64 0]
        [keep : bool true])
    (begin
      (while keep
        (let ([t : Token (array-ref toks i)])
          (if (= (token-tag t) (tag-end))
              (set! keep false)
              (begin
                (if (= (token-tag t) (tag-char))
                    (set! total (+ total (code (token-char t))))
                    (set! total total))
                (set! i (+ i 1))))))
      total)))

;; Total token count (every token before the TEnd sentinel). Depends on the
;; comment skip producing NO token and a string literal being exactly ONE token.
(define (count-tokens [toks : (Array Token)]) : i64
  (let ([i : i64 0]
        [keep : bool true])
    (begin
      (while keep
        (if (= (token-tag (array-ref toks i)) (tag-end))
            (set! keep false)
            (set! i (+ i 1))))
      i)))

(define (lexer-recoverable-error-ok?) : bool
  (match (lex-result "\"unterminated")
    [(ErrTokens message) (string-eq message "lexer: unterminated string literal")]
    [(OkTokens _) false]))

(define (lexer-token-spans-ok?) : bool
  (let ([toks : (Array SpannedToken) (lex-spanned "a\n (b)")])
    (let ([a : SourceSpan (spanned-token-span (array-ref toks 0))]
          [open : SourceSpan (spanned-token-span (array-ref toks 1))]
          [eof : SourceSpan (spanned-token-span (array-ref toks 4))])
      (and (span-eq? a 1 1 1 2)
           (and (span-eq? open 2 2 2 3)
                (span-eq? eof 2 5 2 5))))))

(define (lexer-spanned-error-ok?) : bool
  (match (lex-spanned-result "ok\n@")
    [(ErrSpannedTokens err)
     (and (string-eq (source-error-message err) "lexer: unexpected character")
          (span-eq? (source-error-span err) 2 1 2 1))]
    [(OkSpannedTokens _) false]))

;; Lex a real TypeLisp s-expression sample exercising string-literal,
;; char-literal, and line-comment scanners, and return an observable count. The
;; source is
;;   (foo "hi" #x' #\n' #\space' #\newline' 42) ; c
;;   (bar)
;; built from an escaped string literal. It tokenizes into 12 tokens: the prior
;; string/comment witness plus four TChar literals. The decoded char code sum is
;; 172 (`x` 120 + newline 10 + space 32 + named newline 10). `main` also checks
;; the recoverable lexer entrypoint returns a String error for malformed input.
;; It returns total tokens (12) + TStr count (1) + TChar count (4) when those
;; checks pass, for an observable exit code of 17.
(define (main) : i64
  (let ([toks : (Array Token)
          (lex "(foo \"hi\" #x' #\\n' #\\space' #\\newline' 42) ; c\n(bar)")])
    (+ (count-tokens toks)
       (+ (count-strs toks)
          (if (and (= (sum-char-codes toks) 172)
                   (and (lexer-recoverable-error-ok?)
                        (and (lexer-token-spans-ok?) (lexer-spanned-error-ok?))))
              (count-chars toks)
              0)))))
