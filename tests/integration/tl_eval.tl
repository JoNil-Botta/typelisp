;; tl_eval.tl - A tiny tree-walking EVALUATOR (interpreter) over the recursive
;; `Sexpr` AST: the third component of TypeLisp's self-hosting front end (#27),
;; following the lexer and the reader. Where the reader turns a token stream into
;; the cons-cell `Sexpr` tree the parens describe, this evaluator INTERPRETS that
;; tree - it walks the s-expression and computes the integer it denotes, now with
;; VARIABLES and a `let` special form threaded through a lexical environment.
;;
;;   String --lex--> (Array Token) --read--> Sexpr --eval-sexpr--> i64
;;
;; This composes the whole front end: `(eval-sexpr (read (lex SRC)) ENil)`.
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
;; The lexical environment: a cons-cell association list (refs #27/#111).
;; --------------------------------------------------------------------------
;; Variables turn the calculator into a real interpreter: an expression is now
;; evaluated WITH RESPECT TO an environment mapping variable names to their
;; integer values. The environment is the classic Lisp assoc-list, encoded as a
;; recursive enum (recursive enum payloads, #111, make this finite): `ENil` is the
;; empty environment, and `(EBind name value rest)` extends an environment `rest`
;; with one binding `name -> value`. A `let` pushes a fresh `EBind` frame in front
;; of the current environment; because lookup walks the chain head-first, an inner
;; binding SHADOWS an outer one of the same name - lexical scoping for free.
(defenum Env
  (ENil)
  (EBind String i64 Env))

;; lookup: resolve a variable name to its value in the environment, walking the
;; assoc-list head-first so the most recently pushed (innermost) binding wins. An
;; unbound variable is a malformed program - abort via `panic`, exactly how an
;; interpreter reports a reference to a name that is not in scope. `string-eq` is
;; the byte-wise equality builtin used to compare the bound name against the query.
(define (lookup [env : Env] [name : String]) : i64
  (match env
    [(ENil) (begin (panic "eval: unbound variable") 0)]
    [(EBind bound val rest)
     (if (string-eq bound name)
         val
         (lookup rest name))]))

;; --------------------------------------------------------------------------
;; Sexpr projections: flat single-level `match` accessors over the AST.
;; --------------------------------------------------------------------------
;; The argument spine is a flat cons list, so these `car`/`cdr` accessors stay
;; single-level: each pulls one field out (or `panic`s on the wrong shape -
;; exactly how an interpreter reports a malformed program). Operator symbols and
;; `let` binding names are handled by NESTED patterns (#41), so no separate
;; `sexpr-sym` projection is needed.

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
;; The `let` special form: a single lexical binding pushed onto the environment.
;; --------------------------------------------------------------------------
;; A `(let ((x e1)) body)` form reads into the spine
;;   rest     = (SCons bindings (SCons body SNil))
;;   bindings = (SCons (SCons (SSym x) (SCons e1 SNil)) SNil)
;; The helpers destructure this shape one cons level at a time with `car`/`cdr`;
;; the binding name itself uses a nested pattern to require `(SSym name)`.
;;
;; SCOPE OF THIS SLICE: exactly one binding. The first and only binding pair is
;; taken from the head of `bindings`; multi-binding lists `((x 1) (y 2))` abort
;; cleanly rather than silently dropping bindings. The single-binding case is the
;; load-bearing step from calculator to environment interpreter.

;; let-binding: the single binding pair `(x e1)` out of the `let` form's tail.
;; `rest` is `(SCons bindings (SCons body SNil))`, so the binding LIST is
;; `(sexpr-head rest)` and the pair is the head of that list. The binding list's
;; tail must be SNil, so multi-binding lists abort cleanly.
(define (let-binding [rest : Sexpr]) : Sexpr
  (let ([bindings : Sexpr (sexpr-head rest)])
    (begin
      (sexpr-expect-nil (sexpr-tail bindings))
      (sexpr-head bindings))))

;; let-var: the bound variable's name `x` from a binding pair `(x e1)`.
(define (let-var [pair : Sexpr]) : String
  (match pair
    [(SCons (SSym name) _) name]
    [_ (begin (panic "eval: malformed let binding name") "")]))

;; let-init: the initializer sub-expression `e1` from a binding pair `(x e1)`.
;; The pair's tail-tail must be SNil: each binding has exactly a name and one
;; initializer.
(define (let-init [pair : Sexpr]) : Sexpr
  (let ([rest : Sexpr (sexpr-tail pair)])
    (begin
      (sexpr-expect-nil (sexpr-tail rest))
      (sexpr-head rest))))

;; let-body: the body sub-expression. `rest` is `(SCons bindings (SCons body
;; SNil))`, so the body is the head of `rest`'s tail, and that tail's tail must be
;; SNil (a `let` has exactly one body expression - use `begin` for sequencing).
(define (let-body [rest : Sexpr]) : Sexpr
  (let ([after : Sexpr (sexpr-tail rest)])
    (begin
      (sexpr-expect-nil (sexpr-tail after))
      (sexpr-head after))))

;; --------------------------------------------------------------------------
;; eval-sexpr: the tree-walking interpreter. `(-> Sexpr Env i64)`.
;; --------------------------------------------------------------------------
;; A recursive walk over the `Sexpr` tree, threading a lexical environment and
;; dispatching on the head symbol of each call form - the heart of a Lisp `eval`:
;;   (SInt n)             -> n                  an integer literal evaluates to itself.
;;   (SSym name)          -> (lookup env name)  a bare symbol is a VARIABLE reference,
;;                           resolved in the current environment.
;;   (SNil)               -> the empty list is not an evaluable expression - abort.
;;   (SCons (SSym name) rest)
;;                        -> a call form OR the `let` special form. The nested
;;                           pattern requires a symbol head and binds it as
;;                           the operator/keyword name:
;;                             - "let": the special form - destructure the single
;;                               binding `(x e1)` and the body out of `rest`,
;;                               evaluate `e1` in the CURRENT env, then evaluate the
;;                               body in `(EBind x v env)` - pushing the binding so
;;                               `x` is in scope (and shadows) inside the body only.
;;                             - otherwise a binary call `(op a b)`: project the two
;;                               argument sub-exprs out of the spine, recursively
;;                               `eval-sexpr` each IN `env` (so nested variable
;;                               references resolve), then dispatch on the operator
;;                               text via `string-eq`: "+"->a+b, "-"->a-b, "*"->a*b,
;;                               "/"->a/b. An unknown operator aborts via `panic`.
;;
;; The `match` is exhaustive over all four `Sexpr` variants. The recursive
;; `eval-sexpr` calls thread `env` so the result depends on the WHOLE nested shape
;; AND on the bindings in scope - the defining property of an environment-based
;; interpreter. (Deferred: multi-binding `let`, nested binding lists, `define`,
;; lambda, variadic arity.)
(define (eval-sexpr [s : Sexpr] [env : Env]) : i64
  (match s
    [(SInt n) n]
    [(SSym name) (lookup env name)]
    [(SNil) (begin (panic "eval: cannot evaluate the empty list") 0)]
    [(SCons (SSym name) rest)
     (if (string-eq name "let")
         ;; The `let` special form: `(let ((x e1)) body)`.
         (let ([pair : Sexpr (let-binding rest)])
           (let ([var : String (let-var pair)]
                 [v : i64 (eval-sexpr (let-init pair) env)])
             (eval-sexpr (let-body rest) (EBind var v env))))
         ;; A binary call form `(op arg1 arg2)`: rest is
         ;; `(SCons arg1 (SCons arg2 SNil))`.
         (let ([arg1 : Sexpr (sexpr-head rest)]
               [rest2 : Sexpr (sexpr-tail rest)])
           (let ([arg2 : Sexpr (sexpr-head rest2)]
                 [rest3 : Sexpr (sexpr-tail rest2)])
             (begin
               (sexpr-expect-nil rest3)
               (let ([a : i64 (eval-sexpr arg1 env)]
                     [b : i64 (eval-sexpr arg2 env)])
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
                                   0))))))))))]
    [_ (begin (panic "eval: not an evaluable expression") 0)]))

;; --------------------------------------------------------------------------
;; main: the whole front end composed - lex, read, then interpret with variables.
;; --------------------------------------------------------------------------
;; `(eval-sexpr (read (lex "(let ((x 5)) (+ x (* 2 x)))")) ENil)`:
;;   - lex   produces the token stream  ( let ( ( x 5 ) ) ( + x ( * 2 x ) ) ) End
;;   - read  builds the Sexpr tree, a `let` whose binding list binds `x` to 5 and
;;     whose body is `(+ x (* 2 x))`.
;;   - eval-sexpr interprets it in the EMPTY environment `ENil`: it sees the `let`
;;     keyword, evaluates the initializer `5` to 5, then evaluates the body in
;;     `(EBind "x" 5 ENil)`. In that body each `x` resolves via `lookup` to 5, so
;;     `(* 2 x)` = 10 and `(+ x 10)` = 15. The variable reference proves the
;;     environment is really threaded - the body cannot be computed without it.
;; `main` returns 15, an observable result an execution test asserts as the exit
;; code. (Sanity, still tree-shape dependent with NO variables:
;; "(- (* 4 5) (/ 10 2))" interprets to (* 4 5) = 20 and (/ 10 2) = 5, then
;; 20 - 5 = 15 - the same exit code via a different path.)
(define (main) : i64
  (eval-sexpr (read (lex "(let ((x 5)) (+ x (* 2 x)))")) ENil))
