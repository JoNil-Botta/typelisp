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
;; `(define (f x) body)` definitions followed by ONE trailing expression. This
;; composes the whole front end: `(run-program "(define (fact n) ...) (fact 5)")`.
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
;; The step from calculator to real language. A `(define (f x) body)` registers a
;; function: its name, its single parameter name, and its UN-EVALUATED body AST.
;; Like the value `Env` this is the classic Lisp assoc-list encoded as a recursive
;; enum (recursive payloads, #111), but its binding carries an `Sexpr` payload -
;; the function body tree - alongside the two name Strings: `FNil` is the empty
;; function table, and `(FBind fn-name param body rest)` extends `rest` with one
;; function. Because every define in the program is folded into ONE `FnEnv` that
;; is threaded into every body evaluation, a function body can call ANY defined
;; function - including ITSELF: that single shared `FnEnv` is exactly what makes
;; RECURSION (e.g. factorial) resolve.
(defenum FnEnv
  (FNil)
  (FBind String String Sexpr FnEnv))

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

;; lookup-fn-param / lookup-fn-body: resolve a function name to its parameter name
;; and to its body AST in the function environment. The two projections walk the
;; SAME assoc-list head-first (most recent define wins) and `panic` on an unknown
;; function - exactly how an interpreter reports a call to a name that was never
;; defined. They are split into two single-result functions because a TypeLisp
;; function returns one value; both are driven by the head symbol's text via
;; `string-eq`, the same byte-wise dispatch the operators use.
(define (lookup-fn-param [fenv : FnEnv] [name : String]) : String
  (match fenv
    [(FNil) (begin (panic "eval: unknown function") "")]
    [(FBind fname param _ rest)
     (if (string-eq fname name)
         param
         (lookup-fn-param rest name))]))

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
;; The `define` form: register a single-parameter user function (refs #27).
;; --------------------------------------------------------------------------
;; A top-level `(define (f x) body)` reads into the spine
;;   form   = (SCons (SSym "define") (SCons header (SCons body SNil)))
;;   header = (SCons (SSym f) (SCons (SSym x) SNil))
;; The helpers below destructure that shape: `define-header` pulls the
;; `(f x)` parenthesised header, `define-name`/`define-param` pull the function
;; and parameter names out of it via nested `(SSym ...)` patterns, and
;; `define-body` pulls the single body expression. SCOPE OF THIS SLICE: exactly
;; ONE parameter (the header's tail-tail must be SNil), so `(define (f x y) ...)`
;; aborts cleanly rather than silently dropping a parameter.

;; define-header: the `(f x)` header list out of a define form `s`.
;; `s` is `(SCons (SSym "define") (SCons header (SCons body SNil)))`, so the
;; header is the head of `s`'s tail.
(define (define-header [s : Sexpr]) : Sexpr
  (sexpr-head (sexpr-tail s)))

;; define-name: the function name `f` from the header `(f x)` - the head SSym.
(define (define-name [s : Sexpr]) : String
  (match (sexpr-head (define-header s))
    [(SSym name) name]
    [_ (begin (panic "eval: malformed define function name") "")]))

;; define-param: the single parameter name `x` from the header `(f x)` - the
;; head SSym of the header's tail. The header's tail-tail must be SNil: this slice
;; supports exactly one parameter.
(define (define-param [s : Sexpr]) : String
  (let ([after : Sexpr (sexpr-tail (define-header s))])
    (begin
      (sexpr-expect-nil (sexpr-tail after))
      (match (sexpr-head after)
        [(SSym pname) pname]
        [_ (begin (panic "eval: malformed define parameter name") "")]))))

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
;;                             - OTHERWISE a USER-FUNCTION CALL `(f arg)`: look the
;;                               function up in `fenv` to get its parameter name and
;;                               body, eval the single argument in the CURRENT env,
;;                               then eval the body in a FRESH env binding only the
;;                               parameter - `(EBind param argval ENil)` - with the
;;                               SAME `fenv`. The fresh env is lexical (params only,
;;                               no caller locals leak in); the shared `fenv` is
;;                               what lets the body call other functions AND ITSELF,
;;                               so recursion (e.g. factorial) terminates via the
;;                               base case rather than diverging.
;;
;; The recursive `eval-sexpr` calls thread BOTH envs so the result depends on the
;; whole nested shape, the bindings in scope, AND the program's functions.
;; (Deferred: multi-binding `let`, multi-argument functions, lambda, closures,
;; mutual recursion is supported - the whole `fenv` is shared - but only via
;; single-arg calls.)
(define (eval-sexpr [s : Sexpr] [env : Env] [fenv : FnEnv]) : i64
  (match s
    [(SInt n) n]
    [(SSym name) (lookup env name)]
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
                 ;; OTHERWISE: a USER-FUNCTION CALL `(f arg)`. rest is
                 ;; `(SCons arg SNil)`. Look up `f`'s parameter and body in the
                 ;; shared `fenv`, evaluate the single argument in the CURRENT
                 ;; env, then evaluate the body in a FRESH env binding only the
                 ;; parameter, with the SAME `fenv` - so the body resolves
                 ;; recursive and sibling calls. Single argument only.
                 (let ([arg : Sexpr (sexpr-head rest)]
                       [rest1 : Sexpr (sexpr-tail rest)])
                   (begin
                     (sexpr-expect-nil rest1)
                     (let ([param : String (lookup-fn-param fenv name)]
                           [body : Sexpr (lookup-fn-body fenv name)]
                           [argval : i64 (eval-sexpr arg env fenv)])
                       (eval-sexpr body (EBind param argval ENil) fenv)))))))]
    [_ (begin (panic "eval: not an evaluable expression") 0)]))

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
;;   - otherwise the form must be a `(define (f x) body)`: register it as a fresh
;;     `(FBind name param body fenv)` frame and recurse to read the rest, threading
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
              (FBind (define-name form) (define-param form)
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
;; user functions and recursion.
;; --------------------------------------------------------------------------
;; `(run-program "(define (fact n) (if (< n 1) 1 (* n (fact (- n 1))))) (fact 5)")`:
;;   - the program is TWO top-level forms: one recursive `define` of `fact`, then
;;     the trailing call `(fact 5)`.
;;   - the program reader folds the `define` into `(FBind "fact" "n" body FNil)`,
;;     then evaluates `(fact 5)` against that function env.
;;   - the body recurses: `fact(5) = 5*fact(4) = 5*4*fact(3) = ... = 5*4*3*2*1`,
;;     bottoming out at the `(< n 1)` base case which returns 1.
;;   - 5! = 120, used as the process exit code.
;; This single program proves the evaluator is now a real language: top-level
;; function definitions, single-argument calls, and RECURSION resolving through a
;; shared function environment, all composed atop the reused lexer and reader.
;; (Deferred: multi-argument functions, lambda, closures.)
(define (main) : i64
  (run-program "(define (fact n) (if (< n 1) 1 (* n (fact (- n 1))))) (fact 5)"))
