;; tl_eval.tl - A tiny tree-walking EVALUATOR (interpreter) over the recursive
;; `Sexpr` AST: the third component of TypeLisp's self-hosting front end (#27),
;; following the lexer and the reader. Where the reader turns a token stream into
;; the cons-cell `Sexpr` tree the parens describe, this evaluator INTERPRETS that
;; tree - it walks the s-expression and computes the integer it denotes, now with
;; VARIABLES, a `let` special form, an `if`, comparisons, AND - the milestone of
;; a real language - USER-DEFINED FUNCTIONS plus RECURSION via top-level
;; `(define (f x) body)` forms threaded through a function environment.
;;
;;   String --lex--> (Array Token) --read-form*--> (Sexpr ...) --run-program--> i64
;;
;; A WHOLE PROGRAM is now a sequence of top-level forms: zero or more
;; `(define (f x y z) body)` definitions - each with an arbitrary-arity parameter
;; LIST - followed by ONE trailing expression. This composes the whole front end:
;; `(run-program "(define (pow b e) ...) (pow 2 10)")`.
;;
;; --------------------------------------------------------------------------
;; How the reader and lexer are reused (the KEY module signal, refs #44/#81).
;; --------------------------------------------------------------------------
;; The evaluator does NOT re-derive lexing or reading. It `(import "tl_read.tl")`s
;; the reader's public `read : (-> (Array Token) Sexpr)` and the `Sexpr` enum,
;; factored into a `main`-less module precisely so they can be shared. Crucially
;; it also reuses the reader's PUBLIC CURSOR helpers - `read-form`, `peek-tag`,
;; `tag-end` - to walk MULTIPLE top-level forms out of one token stream (the
;; reader's own `read` returns just the first datum). `tl_read.tl` in turn imports
;; the `main`-less `tl_lex.tl` (the lexer), which imports the `main`-less
;; `tl_token.tl` (the token model). So this single import transitively pulls in
;; the WHOLE front end: `read`/`read-form`, the `Sexpr` AST, `lex`, the `Token`
;; model + its accessors, and the token-tag constants.
;;
;; The module loader (#44) is whole-program: it concatenates every reachable
;; module's declarations (post-order DFS: imported-before-importer), then runs the
;; unchanged pipeline. So the load order is `tl_token.tl`, `tl_lex.tl`,
;; `tl_read.tl`, then this file. Crucially, NONE of the imported modules declares
;; a `main` - only this evaluator does - so the concatenated program has exactly
;; one `main` and there is no duplicate-symbol clash. The imported `defenum Sexpr`
;; is ONE nominal type, so the tree this evaluator walks is the very tree the
;; imported `read-form` constructed - the enum, its constructors, and the
;; projections' `match` arms all carry across the boundary.
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

;; --------------------------------------------------------------------------
;; The FUNCTION environment: an assoc-list of user-defined functions (#27/#111).
;; --------------------------------------------------------------------------
;; The step from calculator to real language. A `(define (f x y z) body)`
;; registers a function: its name, its PARAMETER-NAME LIST, and its UN-EVALUATED
;; body AST. Like the value `Env` this is the classic Lisp assoc-list encoded as a
;; recursive enum (recursive payloads, #111). Its binding now carries TWO `Sexpr`
;; payloads: the original parenthesised PARAMETER LIST `(x y z)` - kept verbatim
;; as the cons-cell list of `SSym`s the reader built, NOT a single param string -
;; alongside the function body tree, plus the name String. `FNil` is the empty
;; function table, and `(FBind fn-name params body rest)` extends `rest` with one
;; function. Because every define in the program is folded into ONE `FnEnv` that
;; is threaded into every body evaluation, a function body can call ANY defined
;; function - including ITSELF: that single shared `FnEnv` is exactly what makes
;; RECURSION (e.g. `pow`) resolve. Storing the param list as an `Sexpr` (rather
;; than a fixed number of String fields) is what generalises the single-parameter
;; table to MULTI-ARGUMENT functions: the call site zips this list against the
;; argument list.
(defenum FnEnv
  (FNil)
  (FBind String Sexpr Sexpr FnEnv))

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

;; lookup-fn-params / lookup-fn-body: resolve a function name to its PARAMETER
;; LIST (an `Sexpr` of `SSym`s) and to its body AST in the function environment.
;; The two projections walk the SAME assoc-list head-first (most recent define
;; wins) and `panic` on an unknown function - exactly how an interpreter reports a
;; call to a name that was never defined. They are split into two single-result
;; functions because a TypeLisp function returns one value; both are driven by the
;; head symbol's text via `string-eq`, the same byte-wise dispatch the operators
;; use. `lookup-fn-params` returns the param list verbatim so the call site can
;; ZIP it against the argument list (multi-argument functions).
(define (lookup-fn-params [fenv : FnEnv] [name : String]) : Sexpr
  (match fenv
    [(FNil) (begin (panic "eval: unknown function") SNil)]
    [(FBind fname params _ rest)
     (if (string-eq fname name)
         params
         (lookup-fn-params rest name))]))

(define (lookup-fn-body [fenv : FnEnv] [name : String]) : Sexpr
  (match fenv
    [(FNil) (begin (panic "eval: unknown function") SNil)]
    [(FBind fname _ body rest)
     (if (string-eq fname name)
         body
         (lookup-fn-body rest name))]))

;; --------------------------------------------------------------------------
;; Sexpr projections: flat single-level `match` accessors over the AST.
;; --------------------------------------------------------------------------
;; The argument spine is a flat cons list, so these `car`/`cdr` accessors stay
;; single-level: each pulls one field out (or `panic`s on the wrong shape -
;; exactly how an interpreter reports a malformed program). Operator symbols,
;; `let` binding names, and `define` function/parameter names are handled by
;; NESTED patterns (#41), so no separate `sexpr-sym` projection is needed.

;; sexpr-head ("car"): the head child of a cons cell. A non-cons (an atom or nil
;; in operator position, or too few arguments) is a malformed call - abort.
(define (sexpr-head [s : Sexpr]) : Sexpr
  (match s
    [(SInt _) (begin (panic "eval: expected a cons cell (car of an atom)") SNil)]
    [(SSym _) (begin (panic "eval: expected a cons cell (car of an atom)") SNil)]
    [(SStr _) (begin (panic "eval: expected a cons cell (car of an atom)") SNil)]
    [(SNil) (begin (panic "eval: expected a cons cell (car of nil / too few args)") SNil)]
    [(SCons h _) h]))

;; sexpr-tail ("cdr"): the tail child of a cons cell. Same malformed-shape guard.
(define (sexpr-tail [s : Sexpr]) : Sexpr
  (match s
    [(SInt _) (begin (panic "eval: expected a cons cell (cdr of an atom)") SNil)]
    [(SSym _) (begin (panic "eval: expected a cons cell (cdr of an atom)") SNil)]
    [(SStr _) (begin (panic "eval: expected a cons cell (cdr of an atom)") SNil)]
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
    [(SStr _) (panic "eval: too many arguments")]
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
;; The `define` form: register a MULTI-parameter user function (refs #27).
;; --------------------------------------------------------------------------
;; A top-level `(define (f x y z) body)` reads into the spine
;;   form   = (SCons (SSym "define") (SCons header (SCons body SNil)))
;;   header = (SCons (SSym f) (SCons (SSym x) (SCons (SSym y) (SCons (SSym z) SNil))))
;; The helpers below destructure that shape: `define-header` pulls the
;; `(f x y z)` parenthesised header, `define-name` pulls the function name out of
;; it via a nested `(SSym ...)` pattern, `define-params` returns the PARAMETER
;; LIST `(x y z)` verbatim - the header's tail, an `Sexpr` cons-list of `SSym`s -
;; and `define-body` pulls the single body expression. The parameter list is kept
;; as an `Sexpr` (not flattened to a fixed number of Strings) so an arbitrary
;; ARITY is supported: the call site zips it against the argument list. A zero-arg
;; define `(define (f) body)` has an empty `(SNil)` parameter list, which is fine.

;; define-header: the `(f x y z)` header list out of a define form `s`.
;; `s` is `(SCons (SSym "define") (SCons header (SCons body SNil)))`, so the
;; header is the head of `s`'s tail.
(define (define-header [s : Sexpr]) : Sexpr
  (sexpr-head (sexpr-tail s)))

;; define-name: the function name `f` from the header `(f x y z)` - the head SSym.
(define (define-name [s : Sexpr]) : String
  (match (sexpr-head (define-header s))
    [(SSym name) name]
    [_ (begin (panic "eval: malformed define function name") "")]))

;; define-params: the PARAMETER LIST `(x y z)` from the header `(f x y z)` - the
;; header's tail, returned verbatim as an `Sexpr` cons-list of `SSym`s. No arity
;; restriction: zero or more parameters. `bind-args` later validates that each
;; element is an `(SSym ...)` and that the count matches the call's argument
;; count, so a malformed parameter (a non-symbol) is caught at the call.
(define (define-params [s : Sexpr]) : Sexpr
  (sexpr-tail (define-header s)))

;; define-body: the body expression of a define. `s`'s tail is
;; `(SCons header (SCons body SNil))`, so the body is the head of that tail's
;; tail, and the body's tail must be SNil (exactly one body expression).
(define (define-body [s : Sexpr]) : Sexpr
  (let ([after : Sexpr (sexpr-tail (sexpr-tail s))])
    (begin
      (sexpr-expect-nil (sexpr-tail after))
      (sexpr-head after))))

;; is-define: does this top-level form start with the symbol `define`? Drives the
;; program reader's split between definitions (folded into the `FnEnv`) and the
;; single trailing expression (evaluated). A non-symbol head, or any other head
;; symbol, is NOT a define.
(define (is-define [s : Sexpr]) : bool
  (match s
    [(SCons (SSym head) _) (string-eq head "define")]
    [_ false]))

;; --------------------------------------------------------------------------
;; eval-sexpr: the tree-walking interpreter. `(-> Sexpr Env FnEnv i64)`.
;; --------------------------------------------------------------------------
;; A recursive walk over the `Sexpr` tree, threading BOTH a lexical value
;; environment `env` and the program's function environment `fenv`, dispatching on
;; the head symbol of each call form - the heart of a Lisp `eval`:
;;   (SInt n)             -> n                  an integer literal evaluates to itself.
;;   (SSym name)          -> (lookup env name)  a bare symbol is a VARIABLE reference,
;;                           resolved in the current value environment.
;;   (SNil)               -> the empty list is not an evaluable expression - abort.
;;   (SCons (SSym name) rest)
;;                        -> a special form, a builtin call, OR a USER-FUNCTION
;;                           CALL. The nested pattern requires a symbol head and
;;                           binds it as the operator/keyword/function name:
;;                             - "let": destructure the single binding `(x e1)`
;;                               and the body out of `rest`, evaluate `e1` in the
;;                               CURRENT env, then evaluate the body in
;;                               `(EBind x v env)` - lexical scoping.
;;                             - "if": short-circuit - evaluate the condition, then
;;                               evaluate only the taken branch.
;;                             - a builtin binary op `+ - * / = < > <= >=`: project
;;                               the two argument sub-exprs, eval each in `env`
;;                               (threading `fenv` so calls nest), then dispatch on
;;                               the operator text; comparisons fold bool to 1/0.
;;                             - OTHERWISE a USER-FUNCTION CALL `(f a b c)`: look
;;                               the function up in `fenv` to get its PARAMETER
;;                               LIST and body, then build a FRESH callee env by
;;                               ZIPPING the parameter list against the argument
;;                               expressions via `bind-args` - each argument is
;;                               evaluated in the CALLER's current env (so caller
;;                               variables resolve in the actual arguments) and
;;                               bound to its parameter, `(EBind p1 v1 (EBind p2 v2
;;                               ... ENil))`. The body is then evaluated in that
;;                               callee env with the SAME `fenv`. The callee env is
;;                               lexical (params only, no caller locals leak in);
;;                               the shared `fenv` is what lets the body call other
;;                               functions AND ITSELF, so recursion (e.g. `pow`)
;;                               terminates via the base case rather than
;;                               diverging. `bind-args` panics on an arity mismatch
;;                               (param/arg counts differ).
;;
;; The recursive `eval-sexpr` calls thread BOTH envs so the result depends on the
;; whole nested shape, the bindings in scope, AND the program's functions.
;; (Deferred: multi-binding `let`, lambda, closures, variadic arity; mutual
;; recursion IS supported - the whole `fenv` is shared.)
(define (eval-sexpr [s : Sexpr] [env : Env] [fenv : FnEnv]) : i64
  (match s
    [(SInt n) n]
    [(SSym name) (lookup env name)]
    ;; A string-literal atom (#27/#128): the reader now produces `SStr` for a
    ;; `"..."` datum, but this interpreter is i64-valued - there are no string
    ;; VALUES in this slice - so evaluating one is unsupported and aborts, exactly
    ;; how the empty list does. (Deferred: real string values / string ops.)
    [(SStr _) (begin (panic "eval: strings not supported") 0)]
    [(SNil) (begin (panic "eval: cannot evaluate the empty list") 0)]
    [(SCons (SSym name) rest)
     (if (string-eq name "let")
         ;; The `let` special form: `(let ((x e1)) body)`.
         (let ([pair : Sexpr (let-binding rest)])
           (let ([var : String (let-var pair)]
                 [v : i64 (eval-sexpr (let-init pair) env fenv)])
             (eval-sexpr (let-body rest) (EBind var v env) fenv)))
         (if (string-eq name "if")
             ;; `if` SPECIAL FORM `(if cond then else)`: rest is
             ;; `(SCons cond (SCons then (SCons else SNil)))`. Project the three
             ;; sub-exprs, assert exactly three, then SHORT-CIRCUIT: eval cond,
             ;; and eval ONLY the taken branch. `0` is false, anything else true.
             (let ([cond-e : Sexpr (sexpr-head rest)]
                   [restc : Sexpr (sexpr-tail rest)])
               (let ([then-e : Sexpr (sexpr-head restc)]
                     [restt : Sexpr (sexpr-tail restc)])
                 (let ([else-e : Sexpr (sexpr-head restt)]
                       [reste : Sexpr (sexpr-tail restt)])
                   (begin
                     (sexpr-expect-nil reste)
                     (let ([c : i64 (eval-sexpr cond-e env fenv)])
                       (if (= c 0)
                           (eval-sexpr else-e env fenv)
                           (eval-sexpr then-e env fenv)))))))
             (if (is-builtin-op name)
                 ;; A builtin binary call form `(op arg1 arg2)`: rest is
                 ;; `(SCons arg1 (SCons arg2 SNil))`.
                 (let ([arg1 : Sexpr (sexpr-head rest)]
                       [rest2 : Sexpr (sexpr-tail rest)])
                   (let ([arg2 : Sexpr (sexpr-head rest2)]
                         [rest3 : Sexpr (sexpr-tail rest2)])
                     (begin
                       (sexpr-expect-nil rest3)
                       (let ([a : i64 (eval-sexpr arg1 env fenv)]
                             [b : i64 (eval-sexpr arg2 env fenv)])
                         (eval-builtin name a b)))))
                 ;; OTHERWISE: a USER-FUNCTION CALL `(f a b c)`. `rest` is the
                 ;; ARGUMENT-EXPRESSION list `(SCons a (SCons b (SCons c SNil)))`.
                 ;; Look up `f`'s PARAMETER LIST and body in the shared `fenv`,
                 ;; then build the callee env by zipping the parameter list against
                 ;; the argument list with `bind-args` (each argument evaluated in
                 ;; the CURRENT env, so caller variables resolve), and evaluate the
                 ;; body in that callee env with the SAME `fenv` - so the body
                 ;; resolves recursive and sibling calls. Arbitrary arity.
                 (let ([params : Sexpr (lookup-fn-params fenv name)]
                       [body : Sexpr (lookup-fn-body fenv name)])
                   (eval-sexpr body (bind-args params rest env fenv) fenv)))))]
    [_ (begin (panic "eval: not an evaluable expression") 0)]))

;; --------------------------------------------------------------------------
;; bind-args: zip a parameter list against an argument-expression list (#27).
;; --------------------------------------------------------------------------
;; The heart of MULTI-ARGUMENT calls. Given a function's parameter list `params`
;; (an `Sexpr` cons-list of `SSym`s, e.g. `(b e)`), the call's argument-expression
;; list `args` (an `Sexpr` cons-list of sub-exprs, e.g. `(2 10)`), the CALLER's
;; value env, and the program `fenv`, it walks BOTH lists in lock-step and builds
;; the FRESH callee env `(EBind p1 v1 (EBind p2 v2 ... ENil))`: each argument
;; sub-expr is evaluated in the CALLER's env (NOT the partially built callee env,
;; so the arguments see caller-scope variables, not sibling parameters), and the
;; resulting value is bound to the matching parameter name. Recursion bottoms out
;; when BOTH lists reach `SNil` together (`ENil`); if exactly one runs out first
;; the call's arity does not match the definition's, which is a malformed program
;; - abort. A parameter that is not an `(SSym ...)` is a malformed define header.
;; `bind-args` and `eval-sexpr` are MUTUALLY RECURSIVE: an argument may itself be
;; a call (e.g. `(pow b (- e 1))`), so evaluating it re-enters `eval-sexpr`.
(define (bind-args [params : Sexpr] [args : Sexpr] [caller : Env] [fenv : FnEnv]) : Env
  (match params
    ;; No more parameters: the argument list must also be exhausted.
    [(SNil)
     (match args
       [(SNil) ENil]
       [_ (begin (panic "eval: too many arguments in call") ENil)])]
    ;; One more parameter `(SSym pname)`: there must be a matching argument.
    [(SCons (SSym pname) ptail)
     (match args
       [(SCons arg atail)
        (EBind pname (eval-sexpr arg caller fenv)
               (bind-args ptail atail caller fenv))]
       [(SNil) (begin (panic "eval: too few arguments in call") ENil)]
       [(SInt _) (begin (panic "eval: malformed argument list") ENil)]
       [(SSym _) (begin (panic "eval: malformed argument list") ENil)]
       [(SStr _) (begin (panic "eval: malformed argument list") ENil)])]
    [_ (begin (panic "eval: malformed parameter list") ENil)]))

;; is-builtin-op: is `name` one of the fixed binary builtins? This is the dispatch
;; key that separates a builtin call from a USER-FUNCTION call in `eval-sexpr`:
;; the arithmetic operators `+ - * /` and the comparison operators `= < > <= >=`.
;; Anything else is treated as a call into the `FnEnv`.
(define (is-builtin-op [name : String]) : bool
  (or (string-eq name "+")
      (or (string-eq name "-")
          (or (string-eq name "*")
              (or (string-eq name "/")
                  (or (string-eq name "=")
                      (or (string-eq name "<")
                          (or (string-eq name ">")
                              (or (string-eq name "<=")
                                  (string-eq name ">="))))))))))

;; eval-builtin: apply a builtin binary operator to two already-evaluated
;; integer operands, dispatching on the operator text via `string-eq`. Arithmetic
;; operators yield integers directly; comparisons fold their bool result to the
;; 1 (true) / 0 (false) integer-truth convention. An operator that passed
;; `is-builtin-op` but is unmatched here is a programmer error - abort.
(define (eval-builtin [name : String] [a : i64] [b : i64]) : i64
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
                                        0)))))))))))

;; --------------------------------------------------------------------------
;; The program reader: read MULTIPLE top-level forms from one token stream.
;; --------------------------------------------------------------------------
;; The reader's own public `read` returns just the FIRST datum, but a real program
;; is a SEQUENCE of forms. So `run-forms` reuses the reader's lower-level public
;; cursor API directly: `read-form` reads exactly one s-expression and ADVANCES
;; the shared mutable cursor (`(Array i64)`) past the tokens it consumed, and
;; `peek-tag` / `tag-end` test whether the cursor has reached the end-of-stream
;; sentinel. `run-forms` reads one form at a time, folding it into the program:
;;   - if after reading a form the cursor is at `TEnd`, that was the LAST form -
;;     it is the trailing EXPRESSION, evaluated in the empty value env with the
;;     accumulated `fenv` and returned.
;;   - otherwise the form must be a `(define (f x y z) body)`: register it as a
;;     fresh `(FBind name params body fenv)` frame (the param LIST kept verbatim)
;;     and recurse to read the rest, threading
;;     the EXTENDED `fenv` so every subsequent form (and the final expression) sees
;;     this and all earlier definitions - which is what makes recursion resolve.
;; A non-define form that is NOT the last form is a malformed program (only the
;; trailing form may be a bare expression) and aborts.
(define (run-forms [toks : (Array Token)] [cur : (Array i64)] [fenv : FnEnv]) : i64
  (let ([form : Sexpr (read-form toks cur)])
    (if (= (peek-tag toks cur) (tag-end))
        ;; Last form: the trailing expression to evaluate.
        (eval-sexpr form ENil fenv)
        ;; A leading form must be a definition; fold it into the function env.
        (if (is-define form)
            (run-forms toks cur
              (FBind (define-name form) (define-params form)
                     (define-body form) fenv))
            (begin
              (panic "eval: a non-final top-level form must be a (define ...)")
              0)))))

;; run-program: the public entry. Lex the whole SOURCE into one `(Array Token)`,
;; set a fresh cursor at index 0, then `run-forms` over every top-level form with
;; an initially empty function environment `FNil`. The result is the i64 the
;; trailing expression denotes after all definitions are in scope.
(define (run-program [src : String]) : i64
  (let ([toks : (Array Token) (lex src)]
        [cur : (Array i64) (make-array i64 1)])
    (begin
      (array-set! cur 0 0)
      (run-forms toks cur FNil))))

;; --------------------------------------------------------------------------
;; main: the whole front end composed - lex, read MANY forms, interpret with
;; MULTI-ARGUMENT user functions and recursion.
;; --------------------------------------------------------------------------
;; `(run-program "(define (pow b e) (if (< e 1) 1 (* b (pow b (- e 1))))) (pow 2 7)")`:
;;   - the program is TWO top-level forms: one recursive TWO-parameter `define` of
;;     `pow`, then the trailing call `(pow 2 7)`.
;;   - the program reader folds the `define` into
;;     `(FBind "pow" (b e) body FNil)` - the param LIST `(b e)` kept verbatim -
;;     then evaluates `(pow 2 7)` against that function env.
;;   - the call zips the params `(b e)` against the args `(2 7)` via `bind-args`,
;;     building the callee env `(EBind "b" 2 (EBind "e" 7 ENil))`. The body then
;;     recurses on the SECOND argument: `pow(2,7) = 2*pow(2,6) = ... = 2^7`,
;;     bottoming out at the `(< e 1)` base case which returns 1.
;;   - 2^7 = 128, used as the process exit code. (The exponent is chosen so the
;;     result fits a byte: a process exit code is taken mod 256, so e.g. 2^10 =
;;     1024 would wrap to an unobservable 0. 128 is a distinct, observable
;;     witness that still exercises seven levels of two-argument recursion.)
;; This single program proves the evaluator now supports MULTI-ARGUMENT user
;; functions: the parameter list `(b e)` is zipped against the argument list, both
;; parameters are in scope in the body, and RECURSION resolves through the shared
;; function environment, all composed atop the reused lexer and reader. (An
;; alternative three-arg witness, `(define (add3 a b c) (+ a (+ b c))) (add3 10 20
;; 30)` => 60, exercises the zipping without recursion - both were verified on
;; Linux.) (Deferred: lambda, closures, variadic arity.)
(define (main) : i64
  (run-program "(define (pow b e) (if (< e 1) 1 (* b (pow b (- e 1))))) (pow 2 7)"))
