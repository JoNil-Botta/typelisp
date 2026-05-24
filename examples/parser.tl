;; parser.tl - A recursive-descent parser written in TypeLisp itself.

;;

;; This is the second compiler front-end component authored in TypeLisp and the

;; next slice of the self-hosting milestone (#27, phase 4), following the

;; tokenizer in `lexer.tl`. It consumes a token stream and parses a real

;; precedence arithmetic grammar

;;

;;   expr   := term (('+' | '-') term)*    (left-associative)

;;   term   := factor (('*' | '/') factor)* (left-associative)

;;   factor := int | '(' expr ')'

;;

;; with a token cursor and recursive descent, exactly the shape a real parser

;; needs: a `current`/`expect`/`advance` helper set over an index into the token

;; arrays, and mutually recursive `parse-expr`/`parse-term`/`parse-factor`. `*`

;; and `/` bind tighter than `+` and `-` because the `term` rule sits one level

;; below the `expr` rule in the descent, so the tree shape encodes precedence.

;;

;; --------------------------------------------------------------------------

;; AST representation (refs #13/#27): a REAL recursive `Expr` tree.

;; --------------------------------------------------------------------------

;; The AST is the natural recursive enum

;;   (defenum Expr (ENum i64) (EAdd Expr Expr) (ESub Expr Expr)

;;                 (EMul Expr Expr) (EDiv Expr Expr))

;; where each binary variant's payload holds two `Expr` children. Recursive enum

;; payloads landed in #111 (heap-pointer indirection, refs #13): each `Expr`

;; child is an 8-byte heap pointer, so the layout is finite and every

;; constructor that escapes via a return is promoted onto the heap. `parse-expr`

;; folds left-associative `EAdd`/`ESub` nodes over the terms produced by

;; `parse-term`, which in turn folds left-associative `EMul`/`EDiv` nodes over

;; the factors produced by `parse-factor`; a recursive `eval` walks the tree

;; with a `match`. This is a genuine tree-walking interpreter, validating

;; recursive enums end-to-end.

;;

;; Cursor threading: a TypeLisp function returns a single value, and the parse

;; routines must both *return an `Expr`* and *advance the input position*. The

;; position is therefore an out-param: a single-cell `(Array i64)` (`cur`) whose

;; element is the index of the token under the cursor. `current`/`advance`/

;; `expect` read and bump that cell, and because arrays are heap references the

;; mutation is visible to the caller across the recursive calls. This is the

;; standard "parser threads a mutable cursor while returning a node" pattern.

;;

;; Token stream representation (mirrors `lexer.tl`): the tokens are stored as a

;; parallel pair of `(Array i64)` - a tag array (the Token kind, via `token-tag`)

;; and a value array (the integer payload of a `TInt`, else 0) - so the cursor is

;; a plain `i64` index the helpers advance.

(defenum Token
  (TInt i64)
  (TPlus)
  (TMinus)
  (TStar)
  (TSlash)
  (TLParen)
  (TRParen)
  (TEnd))

;; The real recursive AST: an integer literal, or a binary node over two

;; sub-expressions for each of the four arithmetic operators.

(defenum Expr
  (ENum i64)
  (EAdd Expr Expr)
  (ESub Expr Expr)
  (EMul Expr Expr)
  (EDiv Expr Expr))

;; Numeric tag for a token kind, matching the lexer's encoding so a parser fed by

;; the lexer would agree on kinds. Exercises `match` over every Token variant.

(define (token-tag [t : Token]) : i64
  (match t
    [(TInt _) 1]
    [(TPlus) 2]
    [(TMinus) 3]
    [(TStar) 4]
    [(TSlash) 5]
    [(TLParen) 6]
    [(TRParen) 7]
    [(TEnd) 8]))

;; Integer payload of a TInt token (0 for any other kind): projects the payload

;; back out of the enum in a `match` arm, the way the cursor reads operands.

(define (token-int [t : Token]) : i64
  (match t
    [(TInt v) v]
    [(TPlus) 0]
    [(TMinus) 0]
    [(TStar) 0]
    [(TSlash) 0]
    [(TLParen) 0]
    [(TRParen) 0]
    [(TEnd) 0]))

;; ---- Token-kind tag constants (kept in sync with `token-tag`). ----

(define (tag-int) : i64
  1)

(define (tag-plus) : i64
  2)

(define (tag-minus) : i64
  3)

(define (tag-star) : i64
  4)

(define (tag-slash) : i64
  5)

(define (tag-lparen) : i64
  6)

(define (tag-rparen) : i64
  7)

(define (tag-end) : i64
  8)

;; ---- Token cursor helpers over the parallel (tags, vals) arrays. ----

;; The cursor position lives in `cur` (a single-cell out-param array); `current-*`

;; peek the token under it without consuming, `advance` bumps it.

;; Current cursor position.

(define (cur-pos [cur : (Array i64)]) : i64
  (array-ref cur 0))

;; Kind tag of the token under the cursor.

(define (current-tag [tags : (Array i64)] [cur : (Array i64)]) : i64
  (array-ref tags (cur-pos cur)))

;; Integer value of the token under the cursor (meaningful only for TInt).

(define (current-val [vals : (Array i64)] [cur : (Array i64)]) : i64
  (array-ref vals (cur-pos cur)))

;; Consume the current token: advance the cursor by one.

(define (advance [cur : (Array i64)]) : unit
  (array-set! cur 0 (+ (cur-pos cur) 1)))

;; `expect`: assert the cursor is on `want`, aborting via `panic` (#45) on a

;; grammar violation - exactly how a real parser reports a syntax error - then

;; consume the matched token.

(define (expect [tags : (Array i64)] [cur : (Array i64)] [want : i64]) : unit
  (if (= (current-tag tags cur) want)
    (advance cur)
    (panic "parser: unexpected token")))

;; ---- Recursive descent. ----

;; Each parse routine reads the token stream through the shared `cur` cursor and

;; returns the `Expr` subtree it parsed, advancing `cur` past the tokens it

;; consumed. `parse-expr`, `parse-term`, and `parse-factor` are mutually

;; recursive (a parenthesized factor re-enters `parse-expr`). The three-level

;; descent (`expr` -> `term` -> `factor`) is what gives `*`/`/` higher

;; precedence than `+`/`-`.

;; factor := int | '(' expr ')'

;; Parse one factor under the cursor and return its `Expr` node.

(define (parse-factor
  [tags : (Array i64)]
  [vals : (Array i64)]
  [cur : (Array i64)]) : Expr
  (let ([t : i64 (current-tag tags cur)])
    (if (= t (tag-int))
      ;; A literal: build (ENum v) and consume the TInt token.
      (let ([v : i64 (current-val vals cur)])
        (begin
          (advance cur)
          (ENum v)))
      (if (= t (tag-lparen))
        ;; '(' expr ')': consume '(', parse the inner expr, consume ')'.
        (begin
          (expect tags cur (tag-lparen))
          (let ([inner : Expr (parse-expr tags vals cur)])
            (begin
              (expect tags cur (tag-rparen))
              inner)))
        (begin
          (panic "parser: expected an integer or '('")
          ;; Dead code: `panic` never returns, but the `if` needs an `Expr`.
          (ENum 0))))))

;; term := factor (('*' | '/') factor)*  (left-associative '*' / '/').

;; Parse a factor, then while the next token is '*' or '/', consume it, parse the

;; next factor, and fold the accumulated tree into a new `(EMul acc rhs)` /

;; `(EDiv acc rhs)` node - giving left-associative, higher-precedence `*`/`/`:

;; `2 * 3 * 4` parses to `(EMul (EMul 2 3) 4)`.

(define (parse-term
  [tags : (Array i64)]
  [vals : (Array i64)]
  [cur : (Array i64)]) : Expr
  (let ([acc : Expr (parse-factor tags vals cur)])
    (begin
      (while (or
        (= (current-tag tags cur) (tag-star))
        (= (current-tag tags cur) (tag-slash)))
        (if (= (current-tag tags cur) (tag-star))
          (begin
            (advance cur)
            (set! acc (EMul acc (parse-factor tags vals cur))))
          (begin
            (advance cur)
            (set! acc (EDiv acc (parse-factor tags vals cur))))))
      acc)))

;; expr := term (('+' | '-') term)*  (left-associative '+' / '-').

;; Parse a term, then while the next token is '+' or '-', consume it, parse the

;; next term, and fold the accumulated tree into a new `(EAdd acc rhs)` /

;; `(ESub acc rhs)` node - giving left-associative `+`/`-`: `1 + 2 + 3` parses to

;; `(EAdd (EAdd 1 2) 3)`. Because each `term` is a full `*`/`/` chain, the tree

;; shape gives `*`/`/` higher precedence than `+`/`-`.

(define (parse-expr
  [tags : (Array i64)]
  [vals : (Array i64)]
  [cur : (Array i64)]) : Expr
  (let ([acc : Expr (parse-term tags vals cur)])
    (begin
      (while (or
        (= (current-tag tags cur) (tag-plus))
        (= (current-tag tags cur) (tag-minus)))
        (if (= (current-tag tags cur) (tag-plus))
          (begin
            (advance cur)
            (set! acc (EAdd acc (parse-term tags vals cur))))
          (begin
            (advance cur)
            (set! acc (ESub acc (parse-term tags vals cur))))))
      acc)))

;; ---- Evaluator: a recursive tree walk over the real `Expr` AST. ----

;; `ENum` yields its literal; each binary node recurses into both children and

;; combines them with the matching arithmetic op (`/` is integer division). The

;; bound recursive payloads (`a`/`b`) are pointers to the child enums, passed

;; straight back into `eval`.

(define (eval [e : Expr]) : i64
  (match e
    [(ENum n) n]
    [(EAdd a b) (+ (eval a) (eval b))]
    [(ESub a b) (- (eval a) (eval b))]
    [(EMul a b) (* (eval a) (eval b))]
    [(EDiv a b) (/ (eval a) (eval b))]))

;; ---- Build the token stream for the sample "2 + 3 * 4" by hand. ----

;; (A lexer would produce this; here we construct the parallel arrays directly so

;; the parser is exercised in isolation.) Tokens: TInt(2) TPlus TInt(3) TStar

;; TInt(4) TEnd.

(define (build-sample-tags [tags : (Array i64)]) : i64
  (begin
    (array-set! tags 0 (token-tag (TInt 2)))
    (array-set! tags 1 (token-tag TPlus))
    (array-set! tags 2 (token-tag (TInt 3)))
    (array-set! tags 3 (token-tag TStar))
    (array-set! tags 4 (token-tag (TInt 4)))
    (array-set! tags 5 (token-tag TEnd))
    6))

(define (build-sample-vals [vals : (Array i64)]) : i64
  (begin
    (array-set! vals 0 (token-int (TInt 2)))
    (array-set! vals 1 0)
    (array-set! vals 2 (token-int (TInt 3)))
    (array-set! vals 3 0)
    (array-set! vals 4 (token-int (TInt 4)))
    (array-set! vals 5 0)
    6))

;; Parse and evaluate "2 + 3 * 4":

;;   - parse-expr builds the real Expr tree (EAdd (ENum 2) (EMul (ENum 3)

;;     (ENum 4))) - `*` binds tighter than `+`, so the multiplication is the

;;     right child of the addition rather than `(2 + 3) * 4`.

;;   - eval recursively folds it to 2 + (3 * 4) = 14 (NOT (2 + 3) * 4 = 20),

;;     proving the parser honours precedence.

;; `main` returns 14, an observable result an execution test can assert as the

;; process exit code.

(define (main) : i64
  (let ([tags : (Array i64) (make-array i64 16)]
    [vals : (Array i64) (make-array i64 16)]
    [cur : (Array i64) (make-array i64 1)])
    (begin
      (build-sample-tags tags)
      (build-sample-vals vals)
      (array-set! cur 0 0)
      (eval (parse-expr tags vals cur)))))