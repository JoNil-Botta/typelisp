;; parser.tl - A recursive-descent parser written in TypeLisp itself.
;;
;; This is the second compiler front-end component authored in TypeLisp and the
;; next slice of the self-hosting milestone (#27, phase 4), following the
;; tokenizer in `lexer.tl`. It consumes a token stream and parses the small
;; arithmetic grammar
;;
;;   expr := term ('+' term)*
;;   term := int | '(' expr ')'
;;
;; (left-associative `+`) with a token cursor and recursive descent, exactly the
;; shape a real parser needs: a `current`/`expect`/`advance` helper set over an
;; index into the token arrays, and mutually recursive `parse-expr`/`parse-term`.
;;
;; --------------------------------------------------------------------------
;; AST representation (refs #13/#27): a REAL recursive `Expr` tree.
;; --------------------------------------------------------------------------
;; The AST is the natural recursive enum
;;   (defenum Expr (ENum i64) (EAdd Expr Expr))
;; where an `EAdd` payload holds two `Expr` children. Recursive enum payloads
;; landed in #111 (heap-pointer indirection, refs #13): each `Expr` child is an
;; 8-byte heap pointer, so the layout is finite and every constructor that
;; escapes via a return is promoted onto the heap. `parse-expr` folds left-
;; associative `EAdd` nodes over the children produced by `parse-term`, and a
;; recursive `eval` walks the tree with a `match`. This replaces the previous
;; flat postfix / RPN op-stream encoding (and its value-stack folder) with a
;; genuine tree-walking interpreter, validating recursive enums end-to-end.
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
  (TLParen)
  (TRParen)
  (TEnd))

;; The real recursive AST: an integer literal, or the sum of two sub-expressions.
(defenum Expr
  (ENum i64)
  (EAdd Expr Expr))

;; Numeric tag for a token kind, matching the lexer's encoding so a parser fed by
;; the lexer would agree on kinds. Exercises `match` over every Token variant.
(define (token-tag [t : Token]) : i64
  (match t
    [(TInt _) 1]
    [(TPlus) 2]
    [(TLParen) 3]
    [(TRParen) 4]
    [(TEnd) 5]))

;; Integer payload of a TInt token (0 for any other kind): projects the payload
;; back out of the enum in a `match` arm, the way the cursor reads operands.
(define (token-int [t : Token]) : i64
  (match t
    [(TInt v) v]
    [(TPlus) 0]
    [(TLParen) 0]
    [(TRParen) 0]
    [(TEnd) 0]))

;; ---- Token-kind tag constants (kept in sync with `token-tag`). ----
(define (tag-int) : i64 1)
(define (tag-plus) : i64 2)
(define (tag-lparen) : i64 3)
(define (tag-rparen) : i64 4)
(define (tag-end) : i64 5)

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
;; consumed. `parse-expr` and `parse-term` are mutually recursive (a parenthesized
;; term re-enters `parse-expr`).

;; term := int | '(' expr ')'
;; Parse one term under the cursor and return its `Expr` node.
(define (parse-term [tags : (Array i64)] [vals : (Array i64)]
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

;; expr := term ('+' term)*  (left-associative '+').
;; Parse a term, then while the next token is '+', consume it, parse the next
;; term, and fold the accumulated tree into a new `(EAdd acc rhs)` node - giving
;; a left-associative `+` AST: `1 + 2 + 3` parses to `(EAdd (EAdd 1 2) 3)`.
(define (parse-expr [tags : (Array i64)] [vals : (Array i64)]
                    [cur : (Array i64)]) : Expr
  (let ([acc : Expr (parse-term tags vals cur)])
    (begin
      (while (= (current-tag tags cur) (tag-plus))
        (begin
          (advance cur)
          (set! acc (EAdd acc (parse-term tags vals cur)))))
      acc)))

;; ---- Evaluator: a recursive tree walk over the real `Expr` AST. ----
;; `ENum` yields its literal; `EAdd` recurses into both children and sums them.
;; The bound recursive payloads (`a`/`b`) are pointers to the child enums, passed
;; straight back into `eval`.
(define (eval [e : Expr]) : i64
  (match e
    [(ENum n) n]
    [(EAdd a b) (+ (eval a) (eval b))]))

;; ---- Build the token stream for the sample "1 + 2 + 3" by hand. ----
;; (A lexer would produce this; here we construct the parallel arrays directly so
;; the parser is exercised in isolation.) Tokens: TInt(1) TPlus TInt(2) TPlus
;; TInt(3) TEnd.
(define (build-sample-tags [tags : (Array i64)]) : i64
  (begin
    (array-set! tags 0 (token-tag (TInt 1)))
    (array-set! tags 1 (token-tag TPlus))
    (array-set! tags 2 (token-tag (TInt 2)))
    (array-set! tags 3 (token-tag TPlus))
    (array-set! tags 4 (token-tag (TInt 3)))
    (array-set! tags 5 (token-tag TEnd))
    6))

(define (build-sample-vals [vals : (Array i64)]) : i64
  (begin
    (array-set! vals 0 (token-int (TInt 1)))
    (array-set! vals 1 0)
    (array-set! vals 2 (token-int (TInt 2)))
    (array-set! vals 3 0)
    (array-set! vals 4 (token-int (TInt 3)))
    (array-set! vals 5 0)
    6))

;; Parse and evaluate "1 + 2 + 3":
;;   - parse-expr builds the real Expr tree (EAdd (EAdd (ENum 1) (ENum 2))
;;     (ENum 3)) - left-associative.
;;   - eval recursively folds it to 6.
;; `main` returns 6, an observable result an execution test can assert as the
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
