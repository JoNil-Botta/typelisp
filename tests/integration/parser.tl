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
;;   (defenum Expr (Num i64) (Add (Box Expr) (Box Expr)) ...)
;; where each binary variant's payload holds two `Expr` children. Recursive enum
;; payloads landed in #111 (heap-pointer indirection, refs #13): each `Expr`
;; child is an 8-byte heap pointer, so the layout is finite and every
;; constructor that escapes via a return is promoted onto the heap. `parse-expr`
;; folds left-associative `Expr.Add`/`Expr.Sub` nodes over the terms produced by
;; `parse-term`, which in turn folds left-associative `Expr.Mul`/`Expr.Div` nodes over
;; the factors produced by `parse-factor`; a recursive `eval` walks the tree
;; with a `match`. This is a genuine tree-walking interpreter, validating
;; recursive enums end-to-end.
;;
;; Cursor threading: a TypeLisp function returns a single value, and the parse
;; routines must both *return an `Expr`* and *advance the input position*. The
;; position is therefore a single-cell fixed array (`cur`) whose element is the
;; index of the token under the cursor. `current`/`advance`/`expect` read and
;; bump that cell, and the mutation is visible to the caller across the
;; recursive calls. This is the standard "parser threads a mutable cursor while
;; returning a node" pattern.
;;
;; Token stream representation (mirrors `lexer.tl`): the tokens are stored as a
;; parallel pair of generated `i64` vectors - a tag vector (the Token kind, via
;; `token-tag`) and a value vector (the integer payload of `Token.Int`, else 0) -
;; so the cursor is a plain `i64` index the helpers advance.
(import stdlib.io)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

(defenum Token
  (Int i64)
  (Plus)
  (Minus)
  (Star)
  (Slash)
  (LParen)
  (RParen)
  (End))

;; The real recursive AST: an integer literal, or a binary node over two
;; sub-expressions for each of the four arithmetic operators.
(defenum Expr
  (Num i64)
  (Add (Box Expr) (Box Expr))
  (Sub (Box Expr) (Box Expr))
  (Mul (Box Expr) (Box Expr))
  (Div (Box Expr) (Box Expr)))

;; Numeric tag for a token kind, matching the lexer's encoding so a parser fed by
;; the lexer would agree on kinds. Exercises `match` over every Token variant.
(define (token-tag [t : Token]) : i64
  (match t
    [(Token.Int _) 1]
    [(Token.Plus) 2]
    [(Token.Minus) 3]
    [(Token.Star) 4]
    [(Token.Slash) 5]
    [(Token.LParen) 6]
    [(Token.RParen) 7]
    [(Token.End) 8]))

;; Integer payload of `Token.Int` (0 for any other kind): projects the payload
;; back out of the enum in a `match` arm, the way the cursor reads operands.
(define (token-int [t : Token]) : i64
  (match t
    [(Token.Int v) v]
    [(Token.Plus) 0]
    [(Token.Minus) 0]
    [(Token.Star) 0]
    [(Token.Slash) 0]
    [(Token.LParen) 0]
    [(Token.RParen) 0]
    [(Token.End) 0]))

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

;; ---- Token cursor helpers over the parallel (tags, vals) vectors. ----
;; The cursor position lives in `cur`; `current-*` peek the token under it
;; without consuming, `advance` bumps it.
;; Current cursor position.
(define (cur-pos [cur : (Array i64 1)]) : i64
  ;; lint-allow: single-element-array-cell
  (array-ref cur 0))

;; Kind tag of the token under the cursor.
(define (current-tag [tags : (& tags i64vec.Vec)] [cur : (Array i64 1)]) : i64
  (i64vec.get tags (cur-pos cur) (tag-end)))

;; Integer value of the token under the cursor (meaningful only for `Token.Int`).
(define (current-val [vals : (& vals i64vec.Vec)] [cur : (Array i64 1)]) : i64
  (i64vec.get vals (cur-pos cur) 0))

;; Consume the current token: advance the cursor by one.
(define (advance [cur : (Array i64 1)]) : unit
  (array-set! cur 0 (+ (cur-pos cur) 1)))

;; `expect`: assert the cursor is on `want`, aborting via `panic` (#45) on a
;; grammar violation - exactly how a real parser reports a syntax error - then
;; consume the matched token.
(define (expect [tags : (& tags i64vec.Vec)] [cur : (Array i64 1)] [want : i64]) : unit
  (if (= (current-tag tags cur) want)
    (advance cur)
    (io.panic "parser: unexpected token")))

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
  [tags : (& tags i64vec.Vec)]
  [vals : (& vals i64vec.Vec)]
  [cur : (Array i64 1)]) : Expr
  (let
    [t : i64 (current-tag tags cur)]
    (if (= t (tag-int))
      ;; A literal: build `(Expr.Num v)` and consume the `Token.Int` token.
      (let
        [v : i64 (current-val vals cur)]
        (begin
          (advance cur)
          (Expr.Num v)))
      (if (= t (tag-lparen))
        ;; '(' expr ')': consume '(', parse the inner expr, consume ')'.
        (begin
          (expect tags cur (tag-lparen))
          (let
            [inner : Expr (parse-expr tags vals cur)]
            (begin
              (expect tags cur (tag-rparen))
              inner)))
        (io.panic "parser: expected an integer or '('")
        ;; Compatibility-style dead code; builtin `panic` can now satisfy
        ;; the `Expr` result directly.
        ))))

;; term := factor (('*' | '/') factor)*  (left-associative '*' / '/').
;; Parse a factor, then while the next token is '*' or '/', consume it, parse the
;; next factor, and fold the accumulated tree into a new `Expr.Mul` /
;; `Expr.Div` node - giving left-associative, higher-precedence `*`/`/`:
;; `2 * 3 * 4` parses to `(Expr.Mul (Expr.Mul 2 3) 4)`.
(define (parse-term
  [tags : (& tags i64vec.Vec)]
  [vals : (& vals i64vec.Vec)]
  [cur : (Array i64 1)]) : Expr
  (let
    [acc : Expr (parse-factor tags vals cur)]
    (begin
      (while (or
        (= (current-tag tags cur) (tag-star))
        (= (current-tag tags cur) (tag-slash)))
        (if (= (current-tag tags cur) (tag-star))
          (begin
            (advance cur)
            (set! acc (Expr.Mul (box acc) (box (parse-factor tags vals cur)))))
          (begin
            (advance cur)
            (set! acc (Expr.Div (box acc) (box (parse-factor tags vals cur)))))))
      acc)))

;; expr := term (('+' | '-') term)*  (left-associative '+' / '-').
;; Parse a term, then while the next token is '+' or '-', consume it, parse the
;; next term, and fold the accumulated tree into a new `Expr.Add` /
;; `Expr.Sub` node - giving left-associative `+`/`-`: `1 + 2 + 3` parses to
;; `(Expr.Add (Expr.Add 1 2) 3)`. Because each `term` is a full `*`/`/` chain, the tree
;; shape gives `*`/`/` higher precedence than `+`/`-`.
(define (parse-expr
  [tags : (& tags i64vec.Vec)]
  [vals : (& vals i64vec.Vec)]
  [cur : (Array i64 1)]) : Expr
  (let
    [acc : Expr (parse-term tags vals cur)]
    (begin
      (while (or
        (= (current-tag tags cur) (tag-plus))
        (= (current-tag tags cur) (tag-minus)))
        (if (= (current-tag tags cur) (tag-plus))
          (begin
            (advance cur)
            (set! acc (Expr.Add (box acc) (box (parse-term tags vals cur)))))
          (begin
            (advance cur)
            (set! acc (Expr.Sub (box acc) (box (parse-term tags vals cur)))))))
      acc)))

;; ---- Evaluator: a recursive tree walk over the real `Expr` AST. ----
;; `Expr.Num` yields its literal; each binary node recurses into both children and
;; combines them with the matching arithmetic op (`/` is integer division). The
;; bound recursive payloads (`a`/`b`) are pointers to the child enums, passed
;; straight back into `eval`.
(define (eval [e : Expr]) : i64
  (match e
    [(Expr.Num n) n]
    [(Expr.Add a b) (+ (eval (box-get a)) (eval (box-get b)))]
    [(Expr.Sub a b) (- (eval (box-get a)) (eval (box-get b)))]
    [(Expr.Mul a b) (* (eval (box-get a)) (eval (box-get b)))]
    [(Expr.Div a b) (/ (eval (box-get a)) (eval (box-get b)))]))

;; ---- Build the token stream for the sample "2 + 3 * 4" by hand. ----
;; (A lexer would produce this; here we construct the parallel vectors directly
;; so the parser is exercised in isolation.) Tokens: Token.Int(2), Token.Plus,
;; Token.Int(3), Token.Star, Token.Int(4), Token.End.
(define (build-sample-tags [tags : (&mut tags i64vec.Vec)]) : i64
  (begin
    (i64vec.push-ref! tags (token-tag (Token.Int 2)))
    (i64vec.push-ref! tags (token-tag Token.Plus))
    (i64vec.push-ref! tags (token-tag (Token.Int 3)))
    (i64vec.push-ref! tags (token-tag Token.Star))
    (i64vec.push-ref! tags (token-tag (Token.Int 4)))
    (i64vec.push-ref! tags (token-tag Token.End))
    6))

(define (build-sample-vals [vals : (&mut vals i64vec.Vec)]) : i64
  (begin
    (i64vec.push-ref! vals (token-int (Token.Int 2)))
    (i64vec.push-ref! vals 0)
    (i64vec.push-ref! vals (token-int (Token.Int 3)))
    (i64vec.push-ref! vals 0)
    (i64vec.push-ref! vals (token-int (Token.Int 4)))
    (i64vec.push-ref! vals 0)
    6))

;; Parse and evaluate "2 + 3 * 4":
;;   - parse-expr builds the real Expr tree `(Expr.Add (Expr.Num 2)
;;     (Expr.Mul (Expr.Num 3) (Expr.Num 4)))` - `*` binds tighter than `+`, so the multiplication is the
;;     right child of the addition rather than `(2 + 3) * 4`.
;;   - eval recursively folds it to 2 + (3 * 4) = 14 (NOT (2 + 3) * 4 = 20),
;;     proving the parser honours precedence.
;; `main` returns 14, an observable result an execution test can assert as the
;; process exit code.
(define (main) : i64
  (let
    [tags : i64vec.Vec (i64vec.with-capacity 6)]
    [vals : i64vec.Vec (i64vec.with-capacity 6)]
    [cur : (Array i64 1) (array 0)]
    (begin
      (build-sample-tags (&mut tags))
      (build-sample-vals (&mut vals))
      (eval (parse-expr (& tags) (& vals) cur)))))