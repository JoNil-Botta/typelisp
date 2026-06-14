;; calc.tl - The TypeLisp front-end composed end to end: a String flows through
;; the lexer, the produced token array flows through a recursive-descent parser
;; into a real `Expr` AST, and a tree-walking evaluator folds it to a value.
;;
;; This is the capstone of the self-hosting front-end slice (#27, phase 4): the
;; two pieces previously exercised in isolation - the tokenizer (`lexer.tl`) and
;; the recursive-descent parser (`parser.tl`) - are wired into ONE pipeline,
;;
;;   String --lex--> (Array Token) --parse--> Expr --eval--> i64
;;
;; proving the whole front-end *composes*: lexing, parsing, and evaluation are
;; not three separate demos but a single data path. `main` runs
;; `(eval (parse (lex "2 + 3 * 4")))` and returns 14.
;;
;; --------------------------------------------------------------------------
;; Multi-file organization: the `Token` model lives in an imported module.
;; --------------------------------------------------------------------------
;; The token kinds, the `token-tag` / `token-int` accessors that `match` over
;; `Token`, and the token-kind tag constants are factored into `token.tl`, a
;; `main`-less module imported below. The legacy stage0 module loader (#44) is
;; still whole-program: it concatenates every imported module's declarations
;; into a single program, imported-before-importer, then runs the unchanged
;; `typecheck -> lower -> codegen` pipeline. So the imported `defenum Token`
;; defines ONE nominal type that this file's lexer constructs (`(TInt acc)`,
;; `TPlus`, ...) and that the imported accessors `match` over. The selfhost
;; namespace model specified in SPEC.md replaces this flat import behavior with
;; qualified module identities.
;;
;; --------------------------------------------------------------------------
;; The unification that makes lex -> parse direct: a single `(Array Token)`.
;; --------------------------------------------------------------------------
;; `parser.tl` previously consumed a parallel pair of `(Array i64)` (a tag array
;; and a value array) built BY HAND, because reading a real `Token` back out of
;; an array was the unproven part. Aggregate-element arrays (#106) and recursive
;; enum payloads (#111) now make `(Array Token)` first-class, so the lexer emits
;; a real `(Array Token)` and the parser reads each token straight out of it with
;; `(token-tag (array-ref toks i))` / `(token-int (array-ref toks i))`. There is
;; no hand-built token stream anywhere in this file: the parser's input is
;; exactly the lexer's output.
;; The shared token model: the `Token` enum, the `token-tag` / `token-int`
;; accessors, and the tag constants. Resolved relative to this file, so it finds
;; the co-located `token.tl`.
(import "stdlib/io.tl")

(import "token.tl")

;; ============================ AST model ===================================
;; The real recursive AST: an integer literal, or a binary node over two
;; sub-expressions for each of the four arithmetic operators. Recursive enum
;; payloads (#111) are 8-byte heap-pointer indirections, so the layout is finite.
(defenum Expr
  (ENum i64)
  (EAdd (Box Expr) (Box Expr))
  (ESub (Box Expr) (Box Expr))
  (EMul (Box Expr) (Box Expr))
  (EDiv (Box Expr) (Box Expr)))

;; ============================ Lexer =======================================
;; Scan a source String character by character into a real `(Array Token)`.
;; This is the tokenizer from `lexer.tl`, narrowed to the calculator surface
;; (integers, `+ - * /`, parens, whitespace) - identifiers are not part of the
;; arithmetic grammar the parser consumes, so they are dropped here.
;; ASCII code point of a char, e.g. the digit char `7` -> 55.
(define (code [c : char]) : i64
  (cast c : i64))

;; `c` is a decimal digit char.
(define (is-digit [c : char]) : bool
  (and (>= c #0') (<= c #9')))

;; `c` is ASCII whitespace: space, tab, or newline.
(define (is-space [c : char]) : bool
  (or (= c #\space') (= c #\tab') (= c #\newline')))

;; Decimal value of a digit char, e.g. the digit char `7` -> 7.
(define (digit-value [c : char]) : i64
  (- (code c) (code #0')))

;; Return the end index (exclusive) of the digit run that starts at `start`.
;; Keep the bounds check outside the `string-ref`; boolean `and` is not a
;; short-circuit guard in lowered TypeLisp code.
(define (scan-int-end [src : String] [start : i64] [n : i64]) : i64
  (let
    [j : i64 start]
    [keep : bool true]
    (begin
      (while keep
        (if (< j n)
          (if (is-digit (string-ref src j))
            (set! j (+ j 1))
            (set! keep false))
          (set! keep false)))
      j)))

;; Classify a single non-digit, non-space char into its operator/paren Token,
;; building a real `Token` value. An unexpected char aborts via the `panic`
;; builtin (#45) - exactly as a real lexer reports malformed input; the trailing
;; `TEnd` is dead code that only satisfies the `Token` result type, since `panic`
;; yields unit and never returns.
(define (single-token [c : char]) : Token
  (cond
    [(= c #+') TPlus]
    [(= c #-') TMinus]
    [(= c #*') TStar]
    [(= c #/') TSlash]
    [(= c #(') TLParen]
    [(= c #)') TRParen]
    [else
      (begin
        (panic "lexer: unexpected character")
        TEnd)]))

;; Lex `src`, recording each emitted `Token` value into `toks` (which must be
;; large enough to hold every token plus the TEnd sentinel) and returning the
;; token count. The loop is the shape of a real lexer: a cursor over the input, a
;; whitespace skip, multi-char accumulation for integers, and single-char tokens
;; for the operators and parens. The terminating `TEnd` is recorded too, so the
;; parser's cursor always has a sentinel to stop on.
(define (lex [src : String] [toks : (Array Token)]) : i64
  (let
    [i : i64 0]
    [n : i64 (string-length src)]
    [count : i64 0]
    (begin
      (while (< i n)
        (let
          [c : char (string-ref src i)]
          (if (is-space c)
            (set! i (+ i 1))
            (if (is-digit c)
              ;; Accumulate a run of digits into one TInt token.
              (let
                [end : i64 (scan-int-end src i n)]
                [acc : i64 0]
                (begin
                  (while (< i end)
                    (begin
                      (set! acc (+ (* acc 10) (digit-value (string-ref src i))))
                      (set! i (+ i 1))))
                  (array-set! toks count (TInt acc))
                  (set! count (+ count 1))))
              (begin
                (array-set! toks count (single-token c))
                (set! count (+ count 1))
                (set! i (+ i 1)))))))
      ;; A real lexer terminates the stream; record the sentinel too.
      (array-set! toks count TEnd)
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
;; single-cell `(Array i64)` (`cur`) holding the index of the token under it; the
;; helpers read and bump that cell, and because arrays are heap references the
;; mutation is visible across the recursive calls. The parser reads tokens
;; STRAIGHT out of the lexer's `(Array Token)` - there is no separate token
;; representation to keep in sync.
;; Current cursor position.
(define (cur-pos [cur : (Array i64)]) : i64
  (array-ref cur 0))

;; Kind tag of the token under the cursor (read from the real `(Array Token)`).
(define (current-tag [toks : (Array Token)] [cur : (Array i64)]) : i64
  (token-tag (array-ref toks (cur-pos cur))))

;; Integer value of the token under the cursor (meaningful only for TInt).
(define (current-val [toks : (Array Token)] [cur : (Array i64)]) : i64
  (token-int (array-ref toks (cur-pos cur))))

;; Consume the current token: advance the cursor by one.
(define (advance [cur : (Array i64)]) : unit
  (array-set! cur 0 (+ (cur-pos cur) 1)))

;; `expect`: assert the cursor is on `want`, aborting via `panic` (#45) on a
;; grammar violation - exactly how a real parser reports a syntax error - then
;; consume the matched token.
(define (expect [toks : (Array Token)] [cur : (Array i64)] [want : i64]) : unit
  (if (= (current-tag toks cur) want)
    (advance cur)
    (panic "parser: unexpected token")))

;; factor := int | '(' expr ')'
;; Parse one factor under the cursor and return its `Expr` node.
(define (parse-factor [toks : (Array Token)] [cur : (Array i64)]) : Expr
  (let
    [t : i64 (current-tag toks cur)]
    (if (= t (tag-int))
      ;; A literal: build (ENum v) and consume the TInt token.
      (let
        [v : i64 (current-val toks cur)]
        (begin
          (advance cur)
          (ENum v)))
      (if (= t (tag-lparen))
        ;; '(' expr ')': consume '(', parse the inner expr, consume ')'.
        (begin
          (expect toks cur (tag-lparen))
          (let
            [inner : Expr (parse-expr toks cur)]
            (begin
              (expect toks cur (tag-rparen))
              inner)))
        (begin
          (panic "parser: expected an integer or '('")
          ;; Dead code: `panic` never returns, but the `if` needs an `Expr`.
          (ENum 0))))))

;; term := factor (('*' | '/') factor)*  (left-associative '*' / '/').
;; Parse a factor, then fold left-associative `EMul`/`EDiv` nodes over the
;; following `*`/`/` factors, giving them higher precedence than `+`/`-`.
(define (parse-term [toks : (Array Token)] [cur : (Array i64)]) : Expr
  (let
    [acc : Expr (parse-factor toks cur)]
    (begin
      (while (or
        (= (current-tag toks cur) (tag-star))
        (= (current-tag toks cur) (tag-slash)))
        (if (= (current-tag toks cur) (tag-star))
          (begin
            (advance cur)
            (set! acc (EMul (box acc) (box (parse-factor toks cur)))))
          (begin
            (advance cur)
            (set! acc (EDiv (box acc) (box (parse-factor toks cur)))))))
      acc)))

;; expr := term (('+' | '-') term)*  (left-associative '+' / '-').
;; Parse a term, then fold left-associative `EAdd`/`ESub` nodes over the
;; following `+`/`-` terms. Because each `term` is a full `*`/`/` chain, the tree
;; shape gives `*`/`/` higher precedence than `+`/`-`.
(define (parse-expr [toks : (Array Token)] [cur : (Array i64)]) : Expr
  (let
    [acc : Expr (parse-term toks cur)]
    (begin
      (while (or
        (= (current-tag toks cur) (tag-plus))
        (= (current-tag toks cur) (tag-minus)))
        (if (= (current-tag toks cur) (tag-plus))
          (begin
            (advance cur)
            (set! acc (EAdd (box acc) (box (parse-term toks cur)))))
          (begin
            (advance cur)
            (set! acc (ESub (box acc) (box (parse-term toks cur)))))))
      acc)))

;; Parse a whole token array starting at index 0: thread a fresh cursor cell
;; through `parse-expr` and return the resulting `Expr` tree. This is the
;; `(Array Token) -> Expr` step of the pipeline.
(define (parse [toks : (Array Token)]) : Expr
  (let
    [cur : (Array i64) (make-array i64 1)]
    (begin
      (array-set! cur 0 0)
      (parse-expr toks cur))))

;; ============================ Evaluator ===================================
;; A recursive tree walk over the real `Expr` AST. `ENum` yields its literal;
;; each binary node recurses into both children and combines them with the
;; matching arithmetic op (`/` is integer division). The bound recursive payloads
;; (`a`/`b`) are pointers to the child enums, passed straight back into `eval`.
(define (eval [e : Expr]) : i64
  (match e
    [(ENum n) n]
    [(EAdd a b) (+ (eval (box-get a)) (eval (box-get b)))]
    [(ESub a b) (- (eval (box-get a)) (eval (box-get b)))]
    [(EMul a b) (* (eval (box-get a)) (eval (box-get b)))]
    [(EDiv a b) (/ (eval (box-get a)) (eval (box-get b)))]))

;; ============================ End to end ==================================
;; Run the full front-end on "2 + 3 * 4":
;;   - lex   produces the token stream TInt(2) TPlus TInt(3) TStar TInt(4) TEnd
;;     in a real `(Array Token)`.
;;   - parse builds the Expr tree (EAdd (ENum 2) (EMul (ENum 3) (ENum 4))) - `*`
;;     binds tighter than `+`, so the multiplication is the right child of the
;;     addition rather than `(2 + 3) * 4`.
;;   - eval recursively folds it to 2 + (3 * 4) = 14 (NOT (2 + 3) * 4 = 20),
;;     proving the composed pipeline honours precedence.
;; `main` returns 14: lexing, parsing, and evaluation composed in TypeLisp, an
;; observable result an execution test can assert as the process exit code.
(define (main) : i64
  (let
    [toks : (Array Token) (make-array Token 16)]
    (begin
      (lex "2 + 3 * 4" toks)
      (eval (parse toks)))))