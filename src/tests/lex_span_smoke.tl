;; lex_span_smoke.tl - Runnable smoke for the spanned token stream.
;;
;; Lexes a multi-line, nested source and checks that each token carries the
;; correct 1-based line/column (including a token inside a nested list and the
;; trailing EOF). Returns 42 on success.
(import lex as lexer)
(import compiler_builtin_ids as cbi)

(define (main) : i64
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (lexer.lex-span-self-test)))