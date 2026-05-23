;; tl_eval.tl - A tiny tree-walking EVALUATOR (interpreter) over the recursive
;; `Sexpr` AST: the third component of TypeLisp's self-hosting front end (#27),
;; following the lexer and the reader. Where the reader turns a token stream into
;; the cons-cell `Sexpr` tree the parens describe, this evaluator INTERPRETS that
;; tree - it walks the s-expression and computes the tagged VALUE it denotes
;; (a `(VInt n)` or a `(VStr s)`, the value domain generalised from a raw i64 so
;; it can carry strings), now with
;; VARIABLES, a MULTI-BINDING `let` special form, an `if`, comparisons, AND - the
;; milestone of a real language - USER-DEFINED FUNCTIONS plus RECURSION via
;; top-level `(define (f x y z) body)` forms threaded through a function
;; environment.
;;
;;   String --lex--> (Array Token) --read-form*--> (Sexpr ...)
;;          --eval--> Value --as-int--> i64
;;
;; A WHOLE PROGRAM is now a sequence of top-level forms: zero or more
;; `(define (f x y z) body)` definitions - each with an arbitrary-arity parameter
;; LIST - followed by ONE trailing expression. This composes the whole front end:
;; `(run-program "(define (pow b e) ...) (let ((b 2) (e 10) (r (pow b e))) ...))"`.
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
;; The VALUE domain: a tagged union of the things an expression denotes (#27).
;; --------------------------------------------------------------------------
;; The interpreter was previously i64-VALUED: every expression denoted a raw
;; `i64`. To carry STRING values (the foundation for string ops and, later,
;; lambda) the value domain is GENERALISED to a tagged `Value`: `(VInt n)` for an
;; integer, `(VStr s)` for a string. `eval-sexpr` now returns a `Value`, the
;; environment binds `Value`s, and the arithmetic / comparison / `if`-condition
;; contexts that require an integer go through `as-int`, which projects a `VInt`
;; and aborts on a `VStr` ("type error: expected int") - exactly how a dynamically
;; typed interpreter reports a type error at a use site that demands a number.
(defenum Value
  (VInt i64)
  (VStr String))

;; as-int: project the i64 out of a `Value`, used wherever an INTEGER is required
;; - the operands of arithmetic / comparison operators and the condition of `if`.
;; A `VStr` in such a position is a type error in the interpreted program (e.g.
;; `(+ "a" 1)`), reported by aborting via `panic`, the interpreter's malformed-
;; program channel.
(define (as-int [v : Value]) : i64
  (match v
    [(VInt n) n]
    [(VStr _) (begin (panic "type error: expected int") 0)]))

;; as-str: the STRING counterpart of `as-int` - project the String out of a
;; `Value`, used wherever a string operand is required (the `string-length` /
;; `substring` / `string-eq` builtins below). A `VInt` in such a position is a
;; type error in the interpreted program (e.g. `(string-length 5)`), reported by
;; aborting via `panic` - the same malformed-program channel `as-int` uses for a
;; string in a numeric context.
(define (as-str [v : Value]) : String
  (match v
    [(VStr s) s]
    [(VInt _) (begin (panic "type error: expected string") "")]))

;; --------------------------------------------------------------------------
;; The lexical environment: a cons-cell association list (refs #27/#111).
;; --------------------------------------------------------------------------
;; Variables turn the calculator into a real interpreter: an expression is now
;; evaluated WITH RESPECT TO an environment mapping variable names to their
;; VALUES. The environment is the classic Lisp assoc-list, encoded as a
;; recursive enum (recursive enum payloads, #111, make this finite): `ENil` is the
;; empty environment, and `(EBind name value rest)` extends an environment `rest`
;; with one binding `name -> value`, where the value is now a tagged `Value`
;; (`VInt`/`VStr`) rather than a raw `i64`. A multi-binding `let` pushes one fresh
;; `EBind` frame per pair, sequentially, in front of the current environment;
;; because lookup walks the chain head-first, an inner binding SHADOWS an outer one
;; of the same name - lexical scoping for free.
(defenum Env
  (ENil)
  (EBind String Value Env))

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
(define (lookup [env : Env] [name : String]) : Value
  (match env
    [(ENil) (begin (panic "eval: unbound variable") (VInt 0))]
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
;; The `let` special form: MULTIPLE lexical bindings pushed onto the environment.
;; --------------------------------------------------------------------------
;; A `(let ((x e1) (y e2) ...) body)` form reads into the spine
;;   rest     = (SCons bindings (SCons body SNil))
;;   bindings = (SCons (SCons (SSym x) (SCons e1 SNil))
;;                     (SCons (SCons (SSym y) (SCons e2 SNil)) ... SNil))
;; The helpers destructure this shape one cons level at a time with `car`/`cdr`;
;; each binding name uses a nested pattern to require `(SSym name)`.
;;
;; SCOPE: zero or more bindings. The binding LIST is folded head-first into the
;; environment by `eval-let-bindings`, which evaluates each initializer in the
;; environment built so far and pushes one `EBind` frame per pair. So the binding
;; semantics is SEQUENTIAL (`let*`-style): a later initializer sees the variables
;; bound by earlier pairs in the same `let` - e.g. `(let ((x 1) (y (+ x 1))) y)`
;; evaluates `(+ x 1)` with `x` in scope. (For a single binding this is identical
;; to the previous single-binding `let`.) An empty binding list `()` is allowed
;; and simply evaluates the body in the unextended environment.

;; let-bindings: the binding LIST `((x e1) (y e2) ...)` out of the `let` form's
;; tail. `rest` is `(SCons bindings (SCons body SNil))`, so the binding list is
;; `(sexpr-head rest)`. The list itself is destructured pair-by-pair by
;; `eval-let-bindings`, so this is just the projection of its head.
(define (let-bindings [rest : Sexpr]) : Sexpr
  (sexpr-head rest))

;; eval-let-bindings: fold the binding LIST `((x e1) (y e2) ...)` into the
;; environment, head-first and SEQUENTIALLY. For each pair `(v init)` it evaluates
;; `init` in the environment accumulated so far (`acc`) and pushes the resulting
;; value as a fresh `(EBind v val acc)` frame, then recurses on the rest of the
;; list - so a later initializer sees the bindings introduced by earlier pairs
;; (`let*` semantics). An empty list `(SNil)` returns the environment unchanged.
;; A malformed binding list (a non-cons element where a pair is expected) is a
;; malformed program - abort. `eval-let-bindings` and `eval-sexpr` are mutually
;; recursive: each initializer is evaluated by re-entering `eval-sexpr`.
(define (eval-let-bindings [bindings : Sexpr] [acc : Env] [fenv : FnEnv]) : Env
  (match bindings
    [(SNil) acc]
    [(SCons pair more)
     (let ([var : String (let-var pair)]
           [v : Value (eval-sexpr (let-init pair) acc fenv)])
       (eval-let-bindings more (EBind var v acc) fenv))]
    [(SInt _) (begin (panic "eval: malformed let binding list") acc)]
    [(SSym _) (begin (panic "eval: malformed let binding list") acc)]
    [(SStr _) (begin (panic "eval: malformed let binding list") acc)]))

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
;; eval-sexpr: the tree-walking interpreter. `(-> Sexpr Env FnEnv Value)`.
;; --------------------------------------------------------------------------
;; A recursive walk over the `Sexpr` tree, threading BOTH a lexical value
;; environment `env` and the program's function environment `fenv`, dispatching on
;; the head symbol of each call form - the heart of a Lisp `eval`. It now yields a
;; tagged `Value` (`VInt`/`VStr`) rather than a raw `i64`, so it can carry string
;; values; contexts that demand a number (operator operands, the `if` condition)
;; funnel through `as-int`:
;;   (SInt n)             -> (VInt n)           an integer literal evaluates to itself.
;;   (SStr s)             -> (VStr s)           a string literal evaluates to itself.
;;   (SSym name)          -> (lookup env name)  a bare symbol is a VARIABLE reference,
;;                           resolved in the current value environment (a `Value`).
;;   (SNil)               -> the empty list is not an evaluable expression - abort.
;;   (SCons (SSym name) rest)
;;                        -> a special form, a builtin call, OR a USER-FUNCTION
;;                           CALL. The nested pattern requires a symbol head and
;;                           binds it as the operator/keyword/function name:
;;                             - "let": destructure the binding LIST
;;                               `((x e1) (y e2) ...)` and the body out of `rest`,
;;                               fold every binding into the env SEQUENTIALLY (each
;;                               initializer evaluated in the env built so far, so
;;                               a later init sees earlier bindings - `let*`), then
;;                               evaluate the body in that extended env - lexical
;;                               scoping.
;;                             - "if": short-circuit - evaluate the condition,
;;                               `as-int` it (0 = false), then evaluate only the
;;                               taken branch.
;;                             - "print": evaluate the single argument, emit it via
;;                               the matching host builtin (`VInt` via `print`,
;;                               `VStr` via `print-string`), and RETURN that value
;;                               so `(print x)` composes inside a larger expression.
;;                             - string ops `string-length` / `substring` /
;;                               `string-eq`: eval their argument sub-exprs, project
;;                               with `as-str` / `as-int`, call the host builtin,
;;                               then re-wrap the result as a tagged `Value`.
;;                             - a builtin binary op `+ - * / = < > <= >=`: project
;;                               the two argument sub-exprs, eval each in `env`
;;                               (threading `fenv` so calls nest), `as-int` both,
;;                               compute, then re-wrap the i64 result as `(VInt r)`;
;;                               comparisons fold bool to 1/0.
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
;; (Deferred: interpreted `string-append` / concat dispatch, lambda, closures,
;; variadic arity; mutual recursion IS supported - the whole `fenv` is shared.)
(define (eval-sexpr [s : Sexpr] [env : Env] [fenv : FnEnv]) : Value
  (match s
    [(SInt n) (VInt n)]
    [(SSym name) (lookup env name)]
    ;; A string-literal atom (#27/#128): the reader produces `SStr` for a `"..."`
    ;; datum. The value domain now carries strings, so it evaluates to itself as a
    ;; `(VStr s)` - a first-class string VALUE that can be bound, returned, passed,
    ;; printed, and consumed by the string-operation dispatch arms below.
    [(SStr s) (VStr s)]
    [(SNil) (begin (panic "eval: cannot evaluate the empty list") (VInt 0))]
    [(SCons (SSym name) rest)
     (if (string-eq name "let")
         ;; The `let` special form: `(let ((x e1) (y e2) ...) body)`. Fold the
         ;; whole binding LIST into the environment (sequentially, `let*`-style),
         ;; then evaluate the body in that extended environment.
         (eval-sexpr (let-body rest)
                     (eval-let-bindings (let-bindings rest) env fenv)
                     fenv)
         (if (string-eq name "if")
             ;; `if` SPECIAL FORM `(if cond then else)`: rest is
             ;; `(SCons cond (SCons then (SCons else SNil)))`. Project the three
             ;; sub-exprs, assert exactly three, then SHORT-CIRCUIT: eval cond,
             ;; `as-int` it, and eval ONLY the taken branch. `0` is false, anything
             ;; else true (a `VStr` condition is a type error, caught by `as-int`).
             (let ([cond-e : Sexpr (sexpr-head rest)]
                   [restc : Sexpr (sexpr-tail rest)])
               (let ([then-e : Sexpr (sexpr-head restc)]
                     [restt : Sexpr (sexpr-tail restc)])
                 (let ([else-e : Sexpr (sexpr-head restt)]
                       [reste : Sexpr (sexpr-tail restt)])
                   (begin
                     (sexpr-expect-nil reste)
                     (let ([c : i64 (as-int (eval-sexpr cond-e env fenv))])
                       (if (= c 0)
                           (eval-sexpr else-e env fenv)
                           (eval-sexpr then-e env fenv)))))))
             (if (string-eq name "print")
                 ;; The `print` special form `(print e)`: rest is
                 ;; `(SCons e SNil)`. Evaluate the single argument, emit it via the
                 ;; matching host builtin, and RETURN the value so `(print x)`
                 ;; composes inside a larger expression. A `VInt` prints its integer
                 ;; (+ a newline) via the host `print`; a `VStr` writes its raw
                 ;; bytes (NO trailing newline) via the host `print-string` builtin
                 ;; (the write(2)-syscall string emitter, #13/#27) - so STRING values
                 ;; are now printable too, not a deferred abort.
                 (let ([arg : Sexpr (sexpr-head rest)]
                       [restp : Sexpr (sexpr-tail rest)])
                   (begin
                     (sexpr-expect-nil restp)
                     (let ([v : Value (eval-sexpr arg env fenv)])
                       (begin
                         (match v
                           [(VInt n) (print n)]
                           [(VStr s) (print-string s)])
                         v))))
                 (if (string-eq name "string-length")
                     ;; STRING OP `(string-length s)`: rest is `(SCons s SNil)`.
                     ;; Evaluate the single argument, `as-str`-project it (a `VInt`
                     ;; here is a type error), call the host `string-length`
                     ;; builtin, and re-wrap its i64 byte-count as `(VInt r)`.
                     (let ([arg : Sexpr (sexpr-head rest)]
                           [restl : Sexpr (sexpr-tail rest)])
                       (begin
                         (sexpr-expect-nil restl)
                         (VInt (string-length (as-str (eval-sexpr arg env fenv))))))
                     (if (string-eq name "substring")
                         ;; STRING OP `(substring s i n)`: rest is
                         ;; `(SCons s (SCons i (SCons n SNil)))`. Evaluate all three
                         ;; sub-exprs, `as-str` the source and `as-int` the start /
                         ;; length, call the host `substring` builtin (a half-open
                         ;; `[i, i+n)` slice, bounds-checked at runtime), and re-wrap
                         ;; the fresh String result as `(VStr r)`.
                         (let ([se : Sexpr (sexpr-head rest)]
                               [rests : Sexpr (sexpr-tail rest)])
                           (let ([ie : Sexpr (sexpr-head rests)]
                                 [rests2 : Sexpr (sexpr-tail rests)])
                             (let ([ne : Sexpr (sexpr-head rests2)]
                                   [rests3 : Sexpr (sexpr-tail rests2)])
                               (begin
                                 (sexpr-expect-nil rests3)
                                 (VStr (substring (as-str (eval-sexpr se env fenv))
                                                  (as-int (eval-sexpr ie env fenv))
                                                  (as-int (eval-sexpr ne env fenv))))))))
                         (if (string-eq name "string-eq")
                             ;; STRING OP `(string-eq a b)`: rest is
                             ;; `(SCons a (SCons b SNil))`. Evaluate both operands,
                             ;; `as-str` each, call the host byte-wise `string-eq`
                             ;; builtin (a `bool`), and fold its result to the
                             ;; 1 (equal) / 0 (unequal) integer-truth convention as
                             ;; `(VInt r)` - matching how the comparison operators
                             ;; encode booleans.
                             (let ([ae : Sexpr (sexpr-head rest)]
                                   [reste : Sexpr (sexpr-tail rest)])
                               (let ([be : Sexpr (sexpr-head reste)]
                                     [reste2 : Sexpr (sexpr-tail reste)])
                                 (begin
                                   (sexpr-expect-nil reste2)
                                   (VInt (if (string-eq (as-str (eval-sexpr ae env fenv))
                                                        (as-str (eval-sexpr be env fenv)))
                                             1
                                             0)))))
                             (if (string-eq name "int->string")
                                 ;; STRING OP `(int->string n)`: rest is
                                 ;; `(SCons n SNil)`. Evaluate the single argument,
                                 ;; `as-int`-project it (a `VStr` here is a type
                                 ;; error), call the host `int->string` builtin
                                 ;; (the i64 -> decimal-text conversion), and
                                 ;; re-wrap the fresh String result as `(VStr r)` -
                                 ;; so an integer VALUE can be turned into a string
                                 ;; VALUE inside an interpreted program.
                                 (let ([arg : Sexpr (sexpr-head rest)]
                                       [resti : Sexpr (sexpr-tail rest)])
                                   (begin
                                     (sexpr-expect-nil resti)
                                     (VStr (int->string (as-int (eval-sexpr arg env fenv))))))
                             (if (string-eq name "string->int")
                                 ;; STRING OP `(string->int s)`: rest is
                                 ;; `(SCons s SNil)`. Evaluate the single argument,
                                 ;; `as-str`-project it (a `VInt` here is a type
                                 ;; error), call the host `string->int` builtin (the
                                 ;; decimal-string -> i64 parse), and re-wrap the
                                 ;; i64 result as `(VInt r)` - the inverse of
                                 ;; `int->string`, so a string VALUE denoting a
                                 ;; number can be parsed back to an integer VALUE.
                                 (let ([arg : Sexpr (sexpr-head rest)]
                                       [restp2 : Sexpr (sexpr-tail rest)])
                                   (begin
                                     (sexpr-expect-nil restp2)
                                     (VInt (string->int (as-str (eval-sexpr arg env fenv))))))
                             (if (is-builtin-op name)
                                 ;; A builtin binary call form `(op arg1 arg2)`: rest is
                                 ;; `(SCons arg1 (SCons arg2 SNil))`. Both operands must be
                                 ;; integers, so each is `as-int`-projected; the i64 result is
                                 ;; re-wrapped as `(VInt r)`.
                                 (let ([arg1 : Sexpr (sexpr-head rest)]
                                       [rest2 : Sexpr (sexpr-tail rest)])
                                   (let ([arg2 : Sexpr (sexpr-head rest2)]
                                         [rest3 : Sexpr (sexpr-tail rest2)])
                                     (begin
                                       (sexpr-expect-nil rest3)
                                       (let ([a : i64 (as-int (eval-sexpr arg1 env fenv))]
                                             [b : i64 (as-int (eval-sexpr arg2 env fenv))])
                                         (VInt (eval-builtin name a b))))))
                                 ;; OTHERWISE: a USER-FUNCTION CALL `(f a b c)`. `rest` is the
                                 ;; ARGUMENT-EXPRESSION list `(SCons a (SCons b (SCons c SNil)))`.
                                 ;; Look up `f`'s PARAMETER LIST and body in the shared `fenv`,
                                 ;; then build the callee env by zipping the parameter list
                                 ;; against the argument list with `bind-args` (each argument
                                 ;; evaluated in the CURRENT env, so caller variables resolve),
                                 ;; and evaluate the body in that callee env with the SAME
                                 ;; `fenv` - so the body resolves recursive and sibling calls.
                                 ;; Arbitrary arity.
                                 (let ([params : Sexpr (lookup-fn-params fenv name)]
                                       [body : Sexpr (lookup-fn-body fenv name)])
                                   (eval-sexpr body (bind-args params rest env fenv) fenv)))))))))))]
    [_ (begin (panic "eval: not an evaluable expression") (VInt 0))]))

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
        ;; Last form: the trailing expression to evaluate. Its `Value` result is
        ;; projected to an i64 via `as-int` for the program's integer result (so a
        ;; program whose trailing expression denotes a string is a type error).
        (as-int (eval-sexpr form ENil fenv))
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
;; MULTI-ARGUMENT user functions, recursion, multi-binding `let`, AND STRING OPS.
;; --------------------------------------------------------------------------
;; `(run-program "(define (pow b e) (if (< e 1) 1 (* b (pow b (- e 1))))) (define (seq a b) b)
;;                (let ((s "hello world") (h (substring s 0 5)) (n (string-length h))
;;                      (t (int->string (pow 2 n))) (m (string->int t)))
;;                  (seq (seq (print h) (print t)) (print (+ m (string-eq h "hello")))))")`:
;;   - the program is THREE top-level forms: a recursive TWO-parameter `define` of
;;     `pow`, a two-parameter `seq` whose body is just its SECOND argument (a
;;     left-to-right sequencer - the interpreted language has no `begin`, so a
;;     two-arg function whose arguments are evaluated in order, returning the last,
;;     stands in for one), then the trailing expression - a MULTI-BINDING `let`
;;     exercising the new STRING OPERATIONS whose body prints BOTH a STRING and an
;;     integer via `seq`.
;;   - the program reader folds both defines into the `FnEnv`, then evaluates the
;;     `let` against that function env.
;;   - the `let` has FIVE bindings, folded SEQUENTIALLY (`let*`):
;;     `s -> (VStr "hello world")` (a first-class string VALUE), then
;;     `h -> (substring s 0 5)` whose initializer SEES the earlier `s` - the
;;     load-bearing proof that a later init resolves earlier bindings - so the
;;     `substring` STRING OP slices `[0, 5)` to `(VStr "hello")`, then
;;     `n -> (string-length h)` whose `string-length` STRING OP yields the byte
;;     count `(VInt 5)`, then `t -> (int->string (pow 2 n))` - `(pow 2 5)` is the
;;     recursive `(VInt 32)`, and the `int->string` STRING OP turns that integer
;;     VALUE into the string VALUE `(VStr "32")`, then `m -> (string->int t)`
;;     parses that string back with the `string->int` STRING OP to the `(VInt 32)`
;;     it denotes - a round-trip through the new int<->string conversions. Each
;;     op unwraps its operand via `as-str` / `as-int` and re-wraps the host
;;     builtin's result.
;;   - the body `(seq (seq (print h) (print t)) (print (+ m (string-eq h "hello"))))`
;;     evaluates left-to-right in the caller env: FIRST `(print h)` prints `h`'s
;;     `(VStr "hello")` via the `VStr` arm - the host `print-string` builtin writes
;;     the raw bytes `hello` to STDOUT (NO trailing newline); SECOND `(print t)`
;;     prints `t`'s `(VStr "32")` the same way, writing `32` (NO newline) - this is
;;     the visible witness of `int->string`; THIRD `(print (+ m (string-eq h
;;     "hello")))` - `m` is the `(VInt 32)` parsed by `string->int`, `(string-eq h
;;     "hello")` folds byte-wise equality to the `1` integer-truth value, their sum
;;     is `(VInt 33)` - prints `33` via the `VInt` arm (the host `print` appends a
;;     newline), so `33\n`. The outer `seq` returns its second arg `(VInt 33)`, so
;;     the `let` - and the whole program - denotes `33`. STDOUT is therefore
;;     `hello3233\n`. Because output is to STDOUT we escape the mod-256
;;     process-exit-code ceiling.
;; This single program proves the evaluator now (a) carries a tagged `Value`
;; domain - the env binds `VInt`s/`VStr`s, numeric contexts go through `as-int`,
;; string contexts through `as-str`, and BOTH a `(VStr ...)` and a `(VInt ...)`
;; are PRINTABLE (the `VStr` arm dispatches to the host `print-string`, the `VInt`
;; arm to the host `print`); (b) supports MULTI-ARGUMENT user functions with
;; RECURSION through the shared function environment; (c) supports MULTI-BINDING
;; `let` with sequential (`let*`) scoping; and (d) exposes the STRING OPERATIONS
;; `substring` / `string-length` / `string-eq` / `int->string` / `string->int`,
;; each dispatched on the head symbol and operating on the tagged `Value` - the
;; int<->string pair lets an interpreted program convert between integer and
;; string VALUES (and build numeric strings) - all composed atop the reused lexer
;; and reader. (Deferred: an interpreted `string-append` dispatch arm now that the
;; host compiler has the `string-append` builtin (#136); lambda; closures;
;; variadic arity; string-literal escapes.)
(define (main) : i64
  (run-program "(define (pow b e) (if (< e 1) 1 (* b (pow b (- e 1))))) (define (seq a b) b) (let ((s \"hello world\") (h (substring s 0 5)) (n (string-length h)) (t (int->string (pow 2 n))) (m (string->int t))) (seq (seq (print h) (print t)) (print (+ m (string-eq h \"hello\")))))"))
