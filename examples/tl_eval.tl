;; tl_eval.tl - A tiny tree-walking EVALUATOR (interpreter) over the recursive
;; `Sexpr` AST: the third component of TypeLisp's self-hosting front end (#27),
;; following the lexer and the reader. Where the reader turns a token stream into
;; the cons-cell `Sexpr` tree the parens describe, this evaluator INTERPRETS that
;; tree - it walks the s-expression and computes the integer it denotes.
;;
;;   String --lex--> (Array Token) --read--> Sexpr --eval-sexpr--> i64
;;
;; This composes the whole front end: `(eval-sexpr (read (lex SRC)))`.
;;
;; --------------------------------------------------------------------------
;; How the reader and lexer are reused (the KEY module signal, refs #44/#81).
;; --------------------------------------------------------------------------
;; The evaluator does NOT re-derive lexing or reading. It `(import "tl_read.tl")`s
;; the reader's public `read : (-> (Array Token) Sexpr)` and the `Sexpr` enum,
;; factored into a `main`-less module precisely so they can be shared. `tl_read.tl`
;; in turn imports the `main`-less `tl_lex.tl` (the lexer), which imports the
;; `main`-less `tl_token.tl` (the token model). So this single import transitively
;; pulls in the WHOLE front end: `read`, the `Sexpr` AST, `lex`, and the `Token`
;; model + its accessors.
;;
;; The module loader (#44) is whole-program: it concatenates every reachable
;; module's declarations (post-order DFS: imported-before-importer), then runs the
;; unchanged pipeline. So the load order is `tl_token.tl`, `tl_lex.tl`,
;; `tl_read.tl`, then this file. Crucially, NONE of the imported modules declares
;; a `main` - only this evaluator does - so the concatenated program has exactly
;; one `main` and there is no duplicate-symbol clash. (Importing the
;; `main`-bearing `tl_reader.tl` demo instead would have clashed; that is why the
;; reusable reader lives in the `main`-less `tl_read.tl`, factored here the way
;; `tl_lex.tl` was factored from `tl_lexer.tl`.) The imported `defenum Sexpr` is
;; ONE nominal type, so the tree this evaluator walks is the very tree the
;; imported `read` constructed - the enum, its constructors, and the projections'
;; `match` arms all carry across the boundary.
(import "tl_read.tl")

;; --------------------------------------------------------------------------
;; Sexpr projections: flat single-level `match` accessors over the AST.
;; --------------------------------------------------------------------------
;; TypeLisp's `match` binds a variant's payload fields to flat variable names; it
;; does NOT support nested patterns (e.g. `(SCons (SSym op) rest)` is not a single
;; pattern). So instead of destructuring a call form in one nested match, the
;; evaluator projects one level at a time with these helpers, each a single-level
;; `match` that pulls one field out (or `panic`s on the wrong shape - exactly how
;; an interpreter reports a malformed program). This is the cons-cell discipline
;; of a real Lisp interpreter: `car`, `cdr`, and a symbol projector.

;; sexpr-head ("car"): the head child of a cons cell. A non-cons (an atom or nil
;; in operator position, or too few arguments) is a malformed call - abort.
(define (sexpr-head [s : Sexpr]) : Sexpr
  (match s
    [(SInt _) (begin (panic "eval: expected a cons cell (car of an atom)") SNil)]
    [(SSym _) (begin (panic "eval: expected a cons cell (car of an atom)") SNil)]
    [(SNil) (begin (panic "eval: expected a cons cell (car of nil / too few args)") SNil)]
    [(SCons h _) h]))

;; sexpr-tail ("cdr"): the tail child of a cons cell. Same malformed-shape guard.
(define (sexpr-tail [s : Sexpr]) : Sexpr
  (match s
    [(SInt _) (begin (panic "eval: expected a cons cell (cdr of an atom)") SNil)]
    [(SSym _) (begin (panic "eval: expected a cons cell (cdr of an atom)") SNil)]
    [(SNil) (begin (panic "eval: expected a cons cell (cdr of nil / too few args)") SNil)]
    [(SCons _ t) t]))

;; sexpr-expect-nil: fixed-arity binary operators must have exactly two
;; arguments. After projecting arg1 and arg2, the remaining tail must be SNil; a
;; third cons cell is a malformed call rather than an ignored extra operand.
(define (sexpr-expect-nil [s : Sexpr]) : unit
  (match s
    [(SNil) unit]
    [(SInt _) (panic "eval: too many arguments")]
    [(SSym _) (panic "eval: too many arguments")]
    [(SCons _ _) (panic "eval: too many arguments")]))

;; sexpr-sym: the operator symbol text. The head of a call form must be a symbol
;; (`+`, `-`, `*`, `/`); any other head shape is a non-symbol operator - abort.
(define (sexpr-sym [s : Sexpr]) : String
  (match s
    [(SInt _) (begin (panic "eval: non-symbol in operator position") "")]
    [(SSym name) name]
    [(SNil) (begin (panic "eval: non-symbol in operator position") "")]
    [(SCons _ _) (begin (panic "eval: non-symbol in operator position") "")]))

;; --------------------------------------------------------------------------
;; eval-sexpr: the tree-walking interpreter. `(-> Sexpr i64)`.
;; --------------------------------------------------------------------------
;; A recursive walk over the `Sexpr` tree, dispatching on the head symbol of each
;; call form - the heart of a Lisp interpreter's `eval`:
;;   (SInt n)             -> n            an integer literal evaluates to itself.
;;   (SCons op rest)      -> a call form. The head `op` is the operator symbol;
;;                           `rest` is the proper-list `(SCons arg1 (SCons arg2
;;                           SNil))` of the (fixed two) argument sub-exprs. Project
;;                           the two args out of the spine, recursively `eval-sexpr`
;;                           each, then DISPATCH on the operator text via
;;                           `string-eq`: "+" -> a+b, "-" -> a-b, "*" -> a*b,
;;                           "/" -> a/b (integer division). An unknown operator is
;;                           a malformed program - abort via `panic`.
;;   (SSym _) / (SNil)    -> a bare symbol or the empty list is not an evaluable
;;                           expression in this slice (no variable lookup yet) -
;;                           abort. (Deferred: SSym variable lookup, `define`,
;;                           variadic arity.)
;;
;; The `match` is exhaustive over all four `Sexpr` variants. In the `SCons` arm,
;; `op` is the operator sub-expr and `rest` the argument-list sub-expr; the binary
;; fixed-arity argument extraction walks the cons spine with the projections
;; above, and the recursive `eval-sexpr` calls on each argument make this a
;; genuine tree walk - the result depends on the WHOLE nested shape.
(define (eval-sexpr [s : Sexpr]) : i64
  (match s
    [(SInt n) n]
    [(SSym _) (begin (panic "eval: cannot evaluate a bare symbol (no variables yet)") 0)]
    [(SNil) (begin (panic "eval: cannot evaluate the empty list") 0)]
    [(SCons op rest)
     ;; A call form `(op arg1 arg2)`: rest is `(SCons arg1 (SCons arg2 SNil))`.
     (let ([name : String (sexpr-sym op)]
           [arg1 : Sexpr (sexpr-head rest)]
           [rest2 : Sexpr (sexpr-tail rest)])
       (let ([arg2 : Sexpr (sexpr-head rest2)]
             [rest3 : Sexpr (sexpr-tail rest2)])
         (begin
           (sexpr-expect-nil rest3)
           (let ([a : i64 (eval-sexpr arg1)]
                 [b : i64 (eval-sexpr arg2)])
             ;; Dispatch on the operator text. `string-eq` is the byte-wise
             ;; equality builtin; an unmatched operator falls through to a panic.
             (if (string-eq name "+")
                 (+ a b)
                 (if (string-eq name "-")
                     (- a b)
                     (if (string-eq name "*")
                         (* a b)
                         (if (string-eq name "/")
                             (/ a b)
                             (begin
                               (panic "eval: unknown operator")
                               0)))))))))]))

;; --------------------------------------------------------------------------
;; main: the whole front end composed - lex, read, then interpret.
;; --------------------------------------------------------------------------
;; `(eval-sexpr (read (lex "(+ 1 (* 2 3))")))`:
;;   - lex   produces the token stream  (  +  1  (  *  2  3  )  )  End
;;   - read  builds the Sexpr tree
;;       (SCons (SSym "+")
;;         (SCons (SInt 1)
;;           (SCons (SCons (SSym "*") (SCons (SInt 2) (SCons (SInt 3) (SNil))))
;;             (SNil))))
;;   - eval-sexpr interprets it: the inner `(* 2 3)` evaluates to 6, then the
;;     outer `(+ 1 6)` evaluates to 7. Multiplication runs FIRST because it is the
;;     nested argument - proving the interpreter honours the tree's structure.
;; `main` returns 7, an observable result an execution test asserts as the exit
;; code. (Sanity, also tree-shape dependent: "(- (* 4 5) (/ 10 2))" interprets to
;; (* 4 5) = 20 and (/ 10 2) = 5, then 20 - 5 = 15.)
(define (main) : i64
  (eval-sexpr (read (lex "(+ 1 (* 2 3))"))))
