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
;; The argument spine is a flat cons list, so these `car`/`cdr` accessors stay
;; single-level: each pulls one field out (or `panic`s on the wrong shape -
;; exactly how an interpreter reports a malformed program). The OPERATOR-symbol
;; projection that used to be a third helper (`sexpr-sym`) is now folded into
;; `eval-sexpr`'s dispatch via a NESTED pattern (#41): the `SCons` arm matches
;; `(SCons (SSym name) rest)`, binding the operator text `name` one enum layer
;; down in the same `match` - no separate projection function needed.

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

;; --------------------------------------------------------------------------
;; eval-sexpr: the tree-walking interpreter. `(-> Sexpr i64)`.
;; --------------------------------------------------------------------------
;; A recursive walk over the `Sexpr` tree, dispatching on the head symbol of each
;; call form - the heart of a Lisp interpreter's `eval`:
;;   (SInt n)                  -> n       an integer literal evaluates to itself.
;;   (SCons (SSym name) rest)  -> a call form whose operator head is the symbol
;;                           `name`. This NESTED pattern (#41) matches two enum
;;                           layers at once: it requires the head to itself be an
;;                           `(SSym name)` and binds the operator text `name`
;;                           directly. The head dispatch first checks for the
;;                           `if` SPECIAL FORM (whose evaluation is short-circuit,
;;                           NOT a fixed-arity strict call); everything else is a
;;                           strict fixed-arity BINARY operator.
;;   _                    -> any other shape (a bare symbol, an empty list, or an
;;                           `SCons` whose head is NOT a symbol) is non-evaluable
;;                           - abort.
;;
;; -------------------------------------------------------------------------
;; The `if` special form: `(if cond then else)`.
;; -------------------------------------------------------------------------
;; CONDITIONALS are a control-flow construct, so `if` CANNOT be evaluated like the
;; strict binary operators: those eval BOTH operands up front, but `if` must
;; SHORT-CIRCUIT - evaluate `cond`, then evaluate ONLY the taken branch (so e.g.
;; the untaken branch may safely contain a division by zero or a non-terminating
;; recursion). `if` therefore gets its own dispatch arm, ahead of the binary path.
;;
;; The form-tail `rest` for `(if cond then else)` is the three-element spine
;; `(SCons cond (SCons then (SCons else SNil)))`. We project the three sub-exprs
;; one cons level at a time with the shared `sexpr-head`/`sexpr-tail` helpers, and
;; assert the spine is exactly three long via `sexpr-expect-nil` on the final
;; tail (a fourth element is a malformed `if`). Then we eval `cond` in isolation
;; and branch on whether it is non-zero - the integer truth convention this
;; interpreter uses (the comparison operators below produce 1 for true, 0 for
;; false). Crucially, exactly ONE of `(eval-sexpr then)` / `(eval-sexpr else)`
;; runs, inside the two arms of the host-language `if` - that is the
;; short-circuit.
;;
;; -------------------------------------------------------------------------
;; Comparison operators: `= < > <= >=`, the integer-truth convention.
;; -------------------------------------------------------------------------
;; TypeLisp's own `= < > <= >=` operators return `bool`, but this interpreter is
;; an `(-> Sexpr i64)` - every expression denotes an integer. So a comparison
;; folds its bool back to the integer truth convention with a host `if`: true ->
;; 1, false -> 0. `(eval-sexpr (read (lex "(< 2 3)")))` is therefore 1, and a
;; `cond`-position `(< x 3)` reads back as the 1/0 the `if` special form tests.
;; These join the existing arithmetic operators in the strict binary dispatch:
;; both operands are eval'd (in order) before the operator is applied.
(define (eval-sexpr [s : Sexpr]) : i64
  (match s
    [(SInt n) n]
    ;; Nested pattern: the call's head must itself be `(SSym name)`. Binds the
    ;; operator text `name : String` (one enum layer down) and the spine `rest`
    ;; together; a non-symbol head fails this and falls through to the `_` arm.
    [(SCons (SSym name) rest)
     (if (string-eq name "if")
         ;; `if` SPECIAL FORM `(if cond then else)`: rest is
         ;; `(SCons cond (SCons then (SCons else SNil)))`. Project the three
         ;; sub-exprs, assert exactly three, then SHORT-CIRCUIT: eval cond, and
         ;; eval ONLY the taken branch. `0` is false, anything else true.
         (let ([cond-e : Sexpr (sexpr-head rest)]
               [restc : Sexpr (sexpr-tail rest)])
           (let ([then-e : Sexpr (sexpr-head restc)]
                 [restt : Sexpr (sexpr-tail restc)])
             (let ([else-e : Sexpr (sexpr-head restt)]
                   [reste : Sexpr (sexpr-tail restt)])
               (begin
                 (sexpr-expect-nil reste)
                 (let ([c : i64 (eval-sexpr cond-e)])
                   ;; Only one branch is evaluated - the untaken sub-expr is
                   ;; NOT walked. (Condition true when c is non-zero.)
                   (if (= c 0)
                       (eval-sexpr else-e)
                       (eval-sexpr then-e)))))))
         ;; A strict fixed-arity BINARY call form `(name arg1 arg2)`: rest is
         ;; `(SCons arg1 (SCons arg2 SNil))`.
         (let ([arg1 : Sexpr (sexpr-head rest)]
               [rest2 : Sexpr (sexpr-tail rest)])
           (let ([arg2 : Sexpr (sexpr-head rest2)]
                 [rest3 : Sexpr (sexpr-tail rest2)])
             (begin
               (sexpr-expect-nil rest3)
               (let ([a : i64 (eval-sexpr arg1)]
                     [b : i64 (eval-sexpr arg2)])
                 ;; Dispatch on the operator text. `string-eq` is the byte-wise
                 ;; equality builtin; an unmatched operator falls through to a
                 ;; panic. The arithmetic operators `+ - * /` yield their integer
                 ;; result directly; the comparison operators `= < > <= >=` fold
                 ;; their bool to the 1 (true) / 0 (false) integer convention.
                 (if (string-eq name "+")
                     (+ a b)
                     (if (string-eq name "-")
                         (- a b)
                         (if (string-eq name "*")
                             (* a b)
                             (if (string-eq name "/")
                                 (/ a b)
                                 (if (string-eq name "=")
                                     (if (= a b) 1 0)
                                     (if (string-eq name "<")
                                         (if (< a b) 1 0)
                                         (if (string-eq name ">")
                                             (if (> a b) 1 0)
                                             (if (string-eq name "<=")
                                                 (if (<= a b) 1 0)
                                                 (if (string-eq name ">=")
                                                     (if (>= a b) 1 0)
                                                     (begin
                                                       (panic "eval: unknown operator")
                                                       0)))))))))))))))]
    [_ (begin (panic "eval: not an evaluable expression") 0)]))

;; --------------------------------------------------------------------------
;; main: the whole front end composed - lex, read, then interpret.
;; --------------------------------------------------------------------------
;; `(eval-sexpr (read (lex "(if (< 2 3) (* 5 5) 0)")))` exercises CONDITIONALS:
;;   - lex   produces the token stream for the `if` form
;;   - read  builds the Sexpr tree
;;       (SCons (SSym "if")
;;         (SCons (SCons (SSym "<") (SCons (SInt 2) (SCons (SInt 3) (SNil))))
;;           (SCons (SCons (SSym "*") (SCons (SInt 5) (SCons (SInt 5) (SNil))))
;;             (SCons (SInt 0) (SNil)))))
;;   - eval-sexpr interprets it: the comparison `(< 2 3)` evaluates to 1 (true),
;;     so the `if` SHORT-CIRCUITS to the THEN branch `(* 5 5)` = 25, and the ELSE
;;     branch `0` is never evaluated. `main` returns 25, the observable result an
;;     execution test asserts as the exit code. (Sanity, also conditional: a
;;     false guard `(if (> 2 3) 99 7)` short-circuits to the ELSE branch => 7.)
(define (main) : i64
  (eval-sexpr (read (lex "(if (< 2 3) (* 5 5) 0)"))))
