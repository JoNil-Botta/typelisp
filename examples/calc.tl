;; calc.tl - The TypeLisp front-end composed end to end: a String flows through
;; the lexer, the produced token.Token vector flows through a recursive-descent parser
;; into a real `Expr` AST, and a tree-walking evaluator folds it to a value.
;;
;; This is the capstone of the self-hosting front-end slice (#27, phase 4): the
;; two pieces previously exercised in isolation - the tokenizer (`lexer.tl`) and
;; the recursive-descent parser (`parser.tl`) - are wired into ONE pipeline,
;;
;;   String --lex--> token.Token Vec --parse--> Expr --eval--> i64
;;
;; proving the whole front-end *composes*: lexing, parsing, and evaluation are
;; not three separate demos but a single data path. `main` runs
;; `(eval (parse (lex "2 + 3 * 4")))` and returns 14.
;;
;; --------------------------------------------------------------------------
;; Multi-file organization: the `token.Token` model lives in an imported module.
;; --------------------------------------------------------------------------
;; The token.Token kinds, the `token.token-tag` / `token.token-int` accessors
;; that `match` over `token.Token`, and the token-kind tag constants are
;; factored into `token.tl`, a `main`-less module imported below. Dotted module
;; imports keep those declarations qualified, so this file refers to the shared
;; enum and helpers through the `token` alias.
;;
;; --------------------------------------------------------------------------
;; The unification that makes lex -> parse direct: a single token.Token vector.
;; --------------------------------------------------------------------------
;; `parser.tl` previously consumed a parallel pair of `(Array i64)` (a tag array
;; and a value array) built BY HAND, because reading a real `token.Token` back
;; out of storage was the unproven part. The lexer now emits a generated vector
;; of real `token.Token` values and the parser reads each token.Token straight
;; out of it with `(token.token-tag (token-vec.get toks i token.Token.End))` /
;; `(token.token-int (token-vec.get toks i token.Token.End))`.
;; There is no hand-built token.Token stream anywhere in this file: the parser's
;; input is exactly the lexer's output.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import token)
(import (vector.vector token.Token) as token-vec)

;; ============================ AST model ===================================
;; The real recursive AST: an integer literal, or a binary node over two
;; sub-expressions for each of the four arithmetic operators. Recursive enum
;; payloads (#111) are 8-byte heap-pointer indirections, so the layout is finite.
(defenum Expr
  (Num i64)
  (Add (Box Expr) (Box Expr))
  (Sub (Box Expr) (Box Expr))
  (Mul (Box Expr) (Box Expr))
  (Div (Box Expr) (Box Expr)))

;; ============================ Lexer =======================================
;; Scan a source String character by character into a real token.Token vector.
;; This is the tokenizer from `lexer.tl`, narrowed to the calculator surface
;; (integers, `+ - * /`, parens, whitespace) - identifiers are not part of the
;; arithmetic grammar the parser consumes, so they are dropped here.
;; ASCII code point of a char, e.g. the digit char `7` -> 55.
(define (code [c : char]) : i64
  (cast c : i64))

;; `c` is a decimal digit char.
(define (is-digit [c : char]) : bool
  (and (>= c '0') (<= c '9')))

;; `c` is ASCII whitespace: space, tab, or newline.
(define (is-space [c : char]) : bool
  (or (= c ' ') (= c '\t') (= c '\n')))

;; Decimal value of a digit char, e.g. the digit char `7` -> 7.
(define (digit-value [c : char]) : i64
  (- (code c) (code '0')))

;; Return the end index (exclusive) of the digit run that starts at `start`.
;; Prelude `and` short-circuits, so `string.char-at` is reached only in bounds.
(define (scan-int-end [src : String] [start : i64] [n : i64]) : i64
  (let
    [j : i64 start]
    (begin
      (while (and (< j n) (is-digit (string.char-at src j)))
        (set! j (+ j 1)))
      j)))

;; Classify a single non-digit, non-space char into its operator/paren token.Token,
;; building a real `token.Token` value. An unexpected char aborts through
;; `io.panic`, whose `never` result lets the failure arm type as `token.Token`.
(define (single-token [c : char]) : token.Token
  (cond
    [(= c '+') token.Token.Plus]
    [(= c '-') token.Token.Minus]
    [(= c '*') token.Token.Star]
    [(= c '/') token.Token.Slash]
    [(= c '(') token.Token.LParen]
    [(= c ')') token.Token.RParen]
    [else (io.panic "lexer: unexpected character")]))

;; Lex `src`, appending each emitted `token.Token` value into `toks` and returning the
;; token.Token count. The loop is the shape of a real lexer: a cursor over the input, a
;; whitespace skip, multi-char accumulation for integers, and single-char tokens
;; for the operators and parens. The terminating `token.Token.End` is recorded too, so
;; the parser's cursor always has a sentinel to stop on.
(define (lex [src : String] [toks : (&mut toks token-vec.Vec)]) : i64
  (let
    [i : i64 0]
    [n : i64 (string.string-length src)]
    [count : i64 0]
    (begin
      (while (< i n)
        (let
          [c : char (string.char-at src i)]
          (if (is-space c)
            (set! i (+ i 1))
            (if (is-digit c)
              ;; Accumulate a run of digits into one `token.Token.Int` token.
              (let
                [end : i64 (scan-int-end src i n)]
                [acc : i64 0]
                (begin
                  (while (< i end)
                    (begin
                      (set!
                        acc
                        (+ (* acc 10) (digit-value (string.char-at src i))))
                      (set! i (+ i 1))))
                  (token-vec.push toks (token.Token.Int acc))
                  (set! count (+ count 1))))
              (begin
                (token-vec.push toks (single-token c))
                (set! count (+ count 1))
                (set! i (+ i 1)))))))
      ;; A real lexer terminates the stream; record the sentinel too.
      (token-vec.push toks token.Token.End)
      count)))

;; ============================ Parser ======================================
;; Recursive descent over the precedence grammar
;;
;;   expr   := term   (('+' | '-') term)*    (left-associative)
;;   term   := factor (('*' | '/') factor)*  (left-associative)
;;   factor := int | '(' expr ')'
;;
;; `*`/`/` bind tighter than `+`/`-` because `term` sits one level below `expr`
;; in the descent, so the tree shape encodes precedence. The cursor is a
;; mutable reference to a single-cell fixed array holding the index of the
;; token.Token under it; the helpers read and bump that cell, and the mutation is
;; visible across the recursive calls. The parser reads tokens STRAIGHT out of
;; the lexer's token.Token vector -
;; there is no separate token.Token representation to keep in sync.
;; Current cursor position.
(define (cur-pos [cur : (& cur (Array i64 1))]) : i64
  ;; lint-allow: single-element-array-cell
  (array-ref cur 0))

;; Kind tag of the token.Token under the cursor.
(define (current-tag
  [toks : (& toks token-vec.Vec)]
  [cur : (& cur (Array i64 1))]) : i64
  (token.token-tag (token-vec.get toks (cur-pos cur) token.Token.End)))

;; Integer value of the token.Token under the cursor (meaningful only for `token.Token.Int`).
(define (current-val
  [toks : (& toks token-vec.Vec)]
  [cur : (& cur (Array i64 1))]) : i64
  (token.token-int (token-vec.get toks (cur-pos cur) token.Token.End)))

;; Consume the current token.Token: advance the cursor by one.
(define (advance [cur : (&mut cur (Array i64 1))]) : unit
  (let
    [next : i64 (+ (array-ref cur 0) 1)]
    (array-set! cur 0 next)))

;; `expect`: assert the cursor is on `want`, aborting via `io.panic` (#45) on a
;; grammar violation - exactly how a real parser reports a syntax error - then
;; consume the matched token.
(define (expect
  [toks : (& toks token-vec.Vec)]
  [cur : (&mut cur (Array i64 1))]
  [want : i64]) : unit
  (if (= (current-tag toks cur) want)
    (advance cur)
    (io.panic "parser: unexpected token.Token")))

;; factor := int | '(' expr ')'
;; Parse one factor under the cursor and return its `Expr` node.
(define (parse-factor
  [toks : (& toks token-vec.Vec)]
  [cur : (&mut cur (Array i64 1))]) : Expr
  (let
    [t : i64 (current-tag toks cur)]
    (if (= t (token.tag-int))
      ;; A literal: build `(Expr.Num v)` and consume the `token.Token.Int` token.
      (let
        [v : i64 (current-val toks cur)]
        (begin
          (advance cur)
          (Expr.Num v)))
      (if (= t (token.tag-lparen))
        ;; '(' expr ')': consume '(', parse the inner expr, consume ')'.
        (begin
          (expect toks cur (token.tag-lparen))
          (let
            [inner : Expr (parse-expr toks cur)]
            (begin
              (expect toks cur (token.tag-rparen))
              inner)))
        (io.panic "parser: expected an integer or '('")))))

;; term := factor (('*' | '/') factor)*  (left-associative '*' / '/').
;; Parse a factor, then fold left-associative `Expr.Mul`/`Expr.Div` nodes over the
;; following `*`/`/` factors, giving them higher precedence than `+`/`-`.
(define (parse-term
  [toks : (& toks token-vec.Vec)]
  [cur : (&mut cur (Array i64 1))]) : Expr
  (let
    [acc : Expr (parse-factor toks cur)]
    (begin
      (while (or
        (= (current-tag toks cur) (token.tag-star))
        (= (current-tag toks cur) (token.tag-slash)))
        (if (= (current-tag toks cur) (token.tag-star))
          (begin
            (advance cur)
            (set! acc (Expr.Mul (box acc) (box (parse-factor toks cur)))))
          (begin
            (advance cur)
            (set! acc (Expr.Div (box acc) (box (parse-factor toks cur)))))))
      acc)))

;; expr := term (('+' | '-') term)*  (left-associative '+' / '-').
;; Parse a term, then fold left-associative `Expr.Add`/`Expr.Sub` nodes over the
;; following `+`/`-` terms. Because each `term` is a full `*`/`/` chain, the tree
;; shape gives `*`/`/` higher precedence than `+`/`-`.
(define (parse-expr
  [toks : (& toks token-vec.Vec)]
  [cur : (&mut cur (Array i64 1))]) : Expr
  (let
    [acc : Expr (parse-term toks cur)]
    (begin
      (while (or
        (= (current-tag toks cur) (token.tag-plus))
        (= (current-tag toks cur) (token.tag-minus)))
        (if (= (current-tag toks cur) (token.tag-plus))
          (begin
            (advance cur)
            (set! acc (Expr.Add (box acc) (box (parse-term toks cur)))))
          (begin
            (advance cur)
            (set! acc (Expr.Sub (box acc) (box (parse-term toks cur)))))))
      acc)))

;; Parse a whole token.Token vector starting at index 0: thread a fresh cursor cell
;; through `parse-expr` and return the resulting `Expr` tree. This is the
;; Token-vector -> Expr step of the pipeline.
(define (parse [toks : (& toks token-vec.Vec)]) : Expr
  (let
    [cur : (Array i64 1) (array 0)]
    (parse-expr toks (&mut cur))))

;; ============================ Evaluator ===================================
;; A recursive tree walk over the real `Expr` AST. `Expr.Num` yields its literal;
;; each binary node recurses into both children and combines them with the
;; matching arithmetic op (`/` is integer division). The bound recursive payloads
;; (`a`/`b`) are pointers to the child enums, passed straight back into `eval`.
(define (eval [e : Expr]) : i64
  (match e
    [(Expr.Num n) n]
    [(Expr.Add a b) (+ (eval (box-get a)) (eval (box-get b)))]
    [(Expr.Sub a b) (- (eval (box-get a)) (eval (box-get b)))]
    [(Expr.Mul a b) (* (eval (box-get a)) (eval (box-get b)))]
    [(Expr.Div a b) (/ (eval (box-get a)) (eval (box-get b)))]))

;; ============================ End to end ==================================
;; Run the full front-end on "2 + 3 * 4":
;;   - lex   produces the token.Token stream token.Token.Int(2), token.Token.Plus,
;;     token.Token.Int(3), token.Token.Star, token.Token.Int(4), token.Token.End
;;     in a generated token.Token vector.
;;   - parse builds the Expr tree
;;     `(Expr.Add (Expr.Num 2) (Expr.Mul (Expr.Num 3) (Expr.Num 4)))` - `*`
;;     binds tighter than `+`, so the multiplication is the right child of the
;;     addition rather than `(2 + 3) * 4`.
;;   - eval recursively folds it to 2 + (3 * 4) = 14 (NOT (2 + 3) * 4 = 20),
;;     proving the composed pipeline honours precedence.
;; `main` prints and returns 14: lexing, parsing, and evaluation composed in
;; TypeLisp.
(define (main) : i64
  (let
    [toks : token-vec.Vec (token-vec.with-capacity 16)]
    (begin
      (lex "2 + 3 * 4" (&mut toks))
      (let
        [result : i64 (eval (parse (& toks)))]
        (begin
          (io.print-string "calculator result: ")
          (io.print result)
          result)))))