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
;; shape a real parser needs: a `current`/`advance`/`expect` helper set over an
;; index into the token arrays, and mutually recursive `parse-expr`/`parse-term`.
;;
;; --------------------------------------------------------------------------
;; AST representation (refs #13/#27): a FLAT postfix / RPN op stream, NOT a tree.
;; --------------------------------------------------------------------------
;; The natural AST for this grammar is a recursive enum
;;   (defenum Expr (ENum i64) (EAdd Expr Expr))
;; where an `EAdd` payload holds two `Expr` children. The TypeLisp typechecker
;; currently *rejects* such recursive enums outright:
;;   "recursive enum 'Expr' (variant 'EAdd') is not yet supported
;;    (needs heap indirection, see #13)"
;; (an enum value is inline `{ tag, payload }` storage, and a self-referential
;; payload field would need to become an 8-byte heap pointer with per-node
;; allocation in the constructor and a deref in every `match` arm — a layout +
;; codegen change deferred to #13). Until recursive enums land, this parser emits
;; the AST in a non-recursive but fully faithful form: a postfix op stream packed
;; into an `(Array i64)`. Each cell is one of
;;   OP-PUSH (0) followed by a literal value cell  -> "push integer N"
;;   OP-ADD  (1)                                   -> "pop b, pop a, push a+b"
;; This is a real abstract syntax encoding (the same information a tree carries,
;; serialized in evaluation order); a tree-walking interpreter is replaced by a
;; single linear pass over the op stream with an explicit value stack. When
;; recursive enums are supported, `parse-expr`/`parse-term` can be retargeted to
;; build `(EAdd a b)` / `(ENum n)` nodes with no change to the grammar logic.
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

;; ---- AST op-code constants for the postfix op stream. ----
(define (op-push) : i64 0)
(define (op-add) : i64 1)

;; ---- Token cursor helpers over the parallel (tags, vals) arrays. ----
;; The cursor is the `i64` index `pos`; `current-*` peek without consuming.

;; Kind tag of the token under the cursor.
(define (current-tag [tags : (Array i64)] [pos : i64]) : i64
  (array-ref tags pos))

;; Integer value of the token under the cursor (meaningful only for TInt).
(define (current-val [vals : (Array i64)] [pos : i64]) : i64
  (array-ref vals pos))

;; `expect`: assert the cursor is on `want`, aborting via `panic` (#45) on a
;; grammar violation - exactly how a real parser reports a syntax error. Returns
;; the next cursor position (advance past the matched token).
(define (expect [tags : (Array i64)] [pos : i64] [want : i64]) : i64
  (if (= (array-ref tags pos) want)
      (+ pos 1)
      (begin
        (panic "parser: unexpected token")
        pos)))

;; ---- Emit helper: append one op-code cell to the op stream and return the new
;; length (the count of cells written so far). ----
(define (emit [ops : (Array i64)] [len : i64] [code : i64]) : i64
  (begin
    (array-set! ops len code)
    (+ len 1)))

;; ---- Recursive descent. ----
;; Each parse routine threads two cursors: the input position `pos` over the
;; token arrays, and the output length `len` over the op-stream array. Because a
;; TypeLisp function returns a single value, the two are folded into one i64 by
;; the convention `state = pos * BIG + len`, where BIG is larger than any
;; op-stream length we will produce. `state-pos`/`state-len` unpack it. This is
;; the standard "parser threads a mutable cursor" pattern expressed without
;; out-params or a recursive struct.

(define (big) : i64 1000000)

(define (make-state [pos : i64] [len : i64]) : i64
  (+ (* pos (big)) len))

(define (state-pos [s : i64]) : i64
  (/ s (big)))

(define (state-len [s : i64]) : i64
  (% s (big)))

;; term := int | '(' expr ')'
;; Parse one term starting at `pos`, appending its postfix ops to `ops` starting
;; at `len`; return the packed (pos, len) state after the term.
(define (parse-term [tags : (Array i64)] [vals : (Array i64)]
                    [ops : (Array i64)] [pos : i64] [len : i64]) : i64
  (let ([t : i64 (current-tag tags pos)])
    (if (= t (tag-int))
        ;; A literal: emit OP-PUSH <value> and consume the TInt token.
        (let ([len1 : i64 (emit ops len (op-push))])
          (let ([len2 : i64 (emit ops len1 (current-val vals pos))])
            (make-state (+ pos 1) len2)))
        (if (= t (tag-lparen))
            ;; '(' expr ')': consume '(', parse the inner expr, consume ')'.
            (let ([pos1 : i64 (expect tags pos (tag-lparen))])
              (let ([inner : i64 (parse-expr tags vals ops pos1 len)])
                (let ([pos2 : i64 (expect tags (state-pos inner) (tag-rparen))])
                  (make-state pos2 (state-len inner)))))
            (begin
              (panic "parser: expected an integer or '('")
              (make-state pos len))))))

;; expr := term ('+' term)*  (left-associative '+').
;; Parse a term, then while the next token is '+', consume it, parse the next
;; term, and emit OP-ADD - which in postfix combines the two most recent values,
;; giving left-associative addition for free.
(define (parse-expr [tags : (Array i64)] [vals : (Array i64)]
                    [ops : (Array i64)] [pos : i64] [len : i64]) : i64
  (let ([st : i64 (parse-term tags vals ops pos len)])
    (begin
      (while (= (current-tag tags (state-pos st)) (tag-plus))
        (let ([afterplus : i64 (+ (state-pos st) 1)])
          (let ([rhs : i64 (parse-term tags vals ops afterplus (state-len st))])
            (let ([len2 : i64 (emit ops (state-len rhs) (op-add))])
              (set! st (make-state (state-pos rhs) len2))))))
      st)))

;; ---- Evaluator: fold the postfix op stream with an explicit value stack. ----
;; A single linear pass: OP-PUSH pushes the following value cell, OP-ADD pops two
;; and pushes their sum. The final stack top is the expression's value.
(define (eval-ops [ops : (Array i64)] [oplen : i64] [stack : (Array i64)]) : i64
  (let ([i : i64 0]
        [sp : i64 0])           ; stack pointer (count of values on the stack)
    (begin
      (while (< i oplen)
        (let ([code : i64 (array-ref ops i)])
          (if (= code (op-push))
              (begin
                (array-set! stack sp (array-ref ops (+ i 1)))
                (set! sp (+ sp 1))
                (set! i (+ i 2)))
              (begin
                ;; OP-ADD: pop b (top), pop a, push a + b.
                (let ([b : i64 (array-ref stack (- sp 1))])
                  (let ([a : i64 (array-ref stack (- sp 2))])
                    (begin
                      (array-set! stack (- sp 2) (+ a b))
                      (set! sp (- sp 1)))))
                (set! i (+ i 1))))))
      (array-ref stack 0))))

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
;;   - parse-expr emits the postfix op stream
;;       PUSH 1, PUSH 2, ADD, PUSH 3, ADD
;;     (left-associative: ((1 + 2) + 3)).
;;   - eval-ops folds it to 6.
;; `main` returns 6, an observable result an execution test can assert as the
;; process exit code.
(define (main) : i64
  (let ([tags : (Array i64) (make-array i64 16)]
        [vals : (Array i64) (make-array i64 16)]
        [ops : (Array i64) (make-array i64 64)]
        [stack : (Array i64) (make-array i64 32)])
    (begin
      (build-sample-tags tags)
      (build-sample-vals vals)
      (let ([st : i64 (parse-expr tags vals ops 0 0)])
        (eval-ops ops (state-len st) stack)))))
