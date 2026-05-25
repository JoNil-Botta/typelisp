;; eval.tl - A tiny tree-walking EVALUATOR (interpreter) over the recursive
;; `Sexpr` AST: the third component of TypeLisp's self-hosting front end (#27),
;; following the lexer and the reader. Where the reader turns a token stream into
;; the cons-cell `Sexpr` tree the parens describe, this evaluator INTERPRETS that
;; tree - it walks the s-expression and computes the tagged VALUE it denotes
;; (a `(VInt n)`, a `(VStr s)`, a `(VClosure ...)`, or a `(VPair ...)`, the value
;; domain generalised from a raw i64 so it can carry strings, first-class functions,
;; AND cons pairs), now with
;; VARIABLES, a MULTI-BINDING `let` special form, an `if`, comparisons, a `begin`
;; SEQUENCING special form, FIRST-CLASS FUNCTIONS (`lambda` + CLOSURES), CONS PAIRS
;; / LINKED LISTS - a `(VPair Value Value)` value built by `cons` and taken apart by
;; `car` / `cdr`, so interpreted programs can construct heterogeneous pairs and
;; singly-linked lists - AND - the milestone of a real language -
;; USER-DEFINED FUNCTIONS plus RECURSION via top-level `(define (f x y z) body)`
;; forms threaded through a function environment.
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
;; The evaluator does NOT re-derive lexing or reading. It `(import "read.tl")`s
;; the reader's public `read : (-> (Array Token) Sexpr)` and the `Sexpr` enum,
;; factored into a `main`-less module precisely so they can be shared. Crucially
;; it also reuses the reader's PUBLIC CURSOR helpers - `read-form`, `peek-tag`,
;; `tag-end` - to walk MULTIPLE top-level forms out of one token stream (the
;; reader's own `read` returns just the first datum). `read.tl` in turn imports
;; the `main`-less `lex.tl` (the lexer), which imports the `main`-less
;; `token.tl` (the token model). So this single import transitively pulls in
;; the WHOLE front end: `read`/`read-form`, the `Sexpr` AST, `lex`, the `Token`
;; model + its accessors, and the token-tag constants.
;;
;; The module loader (#44) is whole-program: it concatenates every reachable
;; module's declarations (post-order DFS: imported-before-importer), then runs the
;; unchanged pipeline. So the load order is `token.tl`, `lex.tl`,
;; `read.tl`, then this file. Crucially, NONE of the imported modules declares
;; a `main` - only this evaluator does - so the concatenated program has exactly
;; one `main` and there is no duplicate-symbol clash. The imported `defenum Sexpr`
;; is ONE nominal type, so the tree this evaluator walks is the very tree the
;; imported `read-form` constructed - the enum, its constructors, and the
;; projections' `match` arms all carry across the boundary.
(import "read.tl")

;; --------------------------------------------------------------------------
;; The VALUE domain: a tagged union of the things an expression denotes (#27).
;; --------------------------------------------------------------------------
;; The interpreter was previously i64-VALUED: every expression denoted a raw
;; `i64`. To carry STRING values (the foundation for string ops) the value domain
;; was GENERALISED to a tagged `Value`: `(VInt n)` for an integer, `(VStr s)` for
;; a string. It now ALSO carries FIRST-CLASS FUNCTIONS: `(VClosure params body
;; captured-env)` is the value a `(lambda (p...) body)` denotes - a CLOSURE pairing
;; the un-evaluated parameter LIST and body AST (both `Sexpr`s, kept verbatim as
;; the reader built them) with the lexical value environment captured AT THE POINT
;; THE LAMBDA WAS EVALUATED. That captured `Env` is what makes free variables in
;; the body resolve to their definition-site bindings when the closure is later
;; applied somewhere else - the defining property of a closure. Because `VClosure`
;; carries an `Env` and `Env` (via `EBind`) carries a `Value`, `Value` and `Env`
;; are now MUTUALLY RECURSIVE enums; each is pointer-sized, so the layout stays
;; finite (recursive/cross-recursive enum payloads, #111/#41).
;;
;; The domain ALSO carries CONS PAIRS: `(VPair Value Value)` is a two-field cell
;; holding any two `Value`s (its fields are `Value` pointers, #111). `cons` builds
;; one, `car` / `cdr` project its first / second field. A singly-linked LIST is the
;; classic right-nested chain `(cons 1 (cons 2 (cons 3 0)))` whose final `cdr` is
;; the integer `0` used as the empty-list sentinel (NIL) - this slice deliberately
;; reuses `(VInt 0)` as nil rather than adding a dedicated variant (refs #141), so
;; there is still no separate `nil` value. The two LIST PREDICATES read against
;; exactly this convention: `(pair? x)` is true iff `x` is a `(VPair ...)`, and
;; `(null? x)` is true iff `x` is the nil sentinel `(VInt 0)` - together they let an
;; interpreted recursive list algorithm detect the end of a list (see the dispatch
;; arms). Both fold to the 1 / 0 integer-truth convention and are TOTAL over the
;; value domain (a non-pair / non-nil is simply false, never a type error - unlike
;; `car` / `cdr`).
;;
;; `eval-sexpr` returns a `Value`, the environment binds `Value`s, and the
;; arithmetic / comparison / `if`-condition contexts that require an integer go
;; through `as-int`, which projects a `VInt` and aborts on a non-integer ("type
;; error: expected int") - exactly how a dynamically typed interpreter reports a
;; type error at a use site that demands a number.
(defenum Value
  (VInt i64)
  (VStr String)
  (VClosure Sexpr Sexpr Env)
  (VPair Value Value))

;; as-int: project the i64 out of a `Value`, used wherever an INTEGER is required
;; - the operands of arithmetic / comparison operators and the condition of `if`.
;; A `VStr` in such a position is a type error in the interpreted program (e.g.
;; `(+ "a" 1)`), reported by aborting via `panic`, the interpreter's malformed-
;; program channel.
(define (as-int [v : Value]) : i64
  (match v
    [(VInt n) n]
    [(VStr _)
      (begin
        (panic "type error: expected int")
        0)]
    [(VClosure _ _ _)
      (begin
        (panic "type error: expected int")
        0)]
    [(VPair _ _)
      (begin
        (panic "type error: expected int")
        0)]))

;; as-str: the STRING counterpart of `as-int` - project the String out of a
;; `Value`, used wherever a string operand is required (the `string-length` /
;; `substring` / `string-eq` builtins below). A `VInt` in such a position is a
;; type error in the interpreted program (e.g. `(string-length 5)`), reported by
;; aborting via `panic` - the same malformed-program channel `as-int` uses for a
;; string in a numeric context.
(define (as-str [v : Value]) : String
  (match v
    [(VStr s) s]
    [(VInt _)
      (begin
        (panic "type error: expected string")
        "")]
    [(VClosure _ _ _)
      (begin
        (panic "type error: expected string")
        "")]
    [(VPair _ _)
      (begin
        (panic "type error: expected string")
        "")]))

;; --------------------------------------------------------------------------
;; print-value / print-list-tail: RECURSIVE list/value printer (refs #27).
;; --------------------------------------------------------------------------
;; The `print` special form was previously TOTAL but lossy on a `(VPair ...)`: a
;; pair emitted the placeholder `#<pair>` because a whole list has no flat textual
;; rendering without a recursive walk and a delimiter convention. This pair of
;; mutually recursive helpers SUPPLIES that walk, so a proper list - whether built
;; by the variadic `(list ...)` constructor or hand-nested `cons` cells - now PRINTS
;; as `(e1 e2 ... en)`, the readable surface syntax a Lisp list is written in,
;; rather than the opaque placeholder. (Strings/closures/ints stay exactly as the
;; `print` arms rendered them, see below.)
;;
;; `print-value` dispatches on the value's shape and writes its textual rendering
;; via the host string emitters (`print-string` writes raw bytes to fd 1 with NO
;; trailing newline; `int->string` is the i64 -> decimal-text conversion). It is
;; deliberately NEWLINE-FREE: it renders a value's TEXT only, so it composes as a
;; LIST ELEMENT (the `print` special form decides newline policy at the top, and
;; the lexer has no string-escape support so a literal `"\n"` is unavailable).
;;   (VInt n)        -> the decimal text of n          (e.g. `1`)
;;   (VStr s)        -> the raw string bytes           (e.g. `hi`)
;;   (VClosure ...)  -> the fixed marker `#<closure>`  (no readable surface form)
;;   (VPair a d)     -> a parenthesised LIST: `(`, then the elements of the cons
;;                      chain printed by `print-value` and separated by single
;;                      spaces, then `)` - the recursive list rendering. The first
;;                      element `a` is printed here; the REST of the chain `d` is
;;                      walked by `print-list-tail`, which emits each subsequent
;;                      element preceded by a space, then either closes the paren
;;                      (a proper list, terminated by the `(VInt 0)` nil) or, for an
;;                      IMPROPER list, emits the dotted-pair tail ` . <cdr>)`.
;; NESTING falls out for free: a `(VPair ...)` ELEMENT re-enters `print-value`, so
;; `(list 1 (list 2 3) 4)` renders the inner pair parenthesised -> `(1 (2 3) 4)`.
(define (print-value [v : Value]) : unit
  (match v
    [(VInt n) (print-string (int->string n))]
    [(VStr s) (print-string s)]
    [(VClosure _ _ _) (print-string "#<closure>")]
    [(VPair a d)
      (begin
        (print-string "(")
        (print-value a)
        (print-list-tail d))]))

;; print-list-tail: walk the CDR chain of a list, printing each remaining element
;; preceded by a single space, then close the paren. `rest` is the cdr of the cell
;; whose car was just printed:
;;   (VInt 0)       -> the NIL sentinel (this file reuses `(VInt 0)` as the empty
;;                     list, refs #141): the list ends here, so just emit `)`.
;;   (VPair a d)    -> one more element: emit a separating space, print the element
;;                     `a` via `print-value` (so a nested list element recurses),
;;                     and continue down the chain on `d`.
;; IMPROPER TAIL (a cdr that is neither a pair nor the `(VInt 0)` nil sentinel - a
;; non-zero int, a string, or a closure): the list is IMPROPER, so this renders the
;; standard Lisp DOTTED-PAIR notation `(a . b)` - it emits a ` . ` separator (space,
;; dot, space), then `print-value` of the non-nil cdr (so the tail recurses through
;; the normal value printer: an int -> its decimal text, a string -> its bytes, a
;; closure -> `#<closure>`), then closes the paren. So `(cons 10 20)` renders
;; `(10 . 20)` and a left-nested-spine improper list `(cons 1 (cons 2 3))` renders
;; `(1 2 . 3)` - every proper PREFIX element is printed by the `(VPair ...)` arm and
;; only the FINAL non-nil cdr gets the dotted form. A proper list built by `cons` /
;; `list` always terminates in `(VInt 0)`, so its tail hits the `(= n 0)` case and
;; closes with a plain `)`, never a dot.
(define (print-list-tail [rest : Value]) : unit
  (match rest
    [(VInt n)
      (if (= n 0)
        (print-string ")")
        ;; improper tail: a non-nil integer cdr - dotted pair `(... . n)`.
        (begin
          (print-string " . ")
          (print-value (VInt n))
          (print-string ")")))]
    [(VPair a d)
      (begin
        (print-string " ")
        (print-value a)
        (print-list-tail d))]
    ;; improper tail: a string cdr - dotted pair `(... . s)`.
    [(VStr s)
      (begin
        (print-string " . ")
        (print-value (VStr s))
        (print-string ")"))]
    ;; improper tail: a closure cdr - dotted pair `(... . #<closure>)`.
    [(VClosure p b e)
      (begin
        (print-string " . ")
        (print-value (VClosure p b e))
        (print-string ")"))]))

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

(defenum ResultValue
  (OkValue Value)
  (ErrValue String))

(defenum ResultI64
  (OkI64 i64)
  (ErrI64 String))

(defenum ResultString
  (OkString String)
  (ErrString String))

(defenum ResultEnv
  (OkEnv Env)
  (ErrEnv String))

(defenum ResultFnDef
  (OkFnDef String Sexpr Sexpr)
  (ErrFnDef String))

(defenum ResultUnaryArg
  (OkUnaryArg Sexpr)
  (ErrUnaryArg String))

(defenum ResultBinaryArgs
  (OkBinaryArgs Sexpr Sexpr)
  (ErrBinaryArgs String))

(defenum ResultTernaryArgs
  (OkTernaryArgs Sexpr Sexpr Sexpr)
  (ErrTernaryArgs String))

;; lookup: resolve a variable name to its value in the environment, walking the
;; assoc-list head-first so the most recently pushed (innermost) binding wins. An
;; unbound variable is a malformed program - abort via `panic`, exactly how an
;; interpreter reports a reference to a name that is not in scope. `string-eq` is
;; the byte-wise equality builtin used to compare the bound name against the query.
(define (lookup [env : Env] [name : String]) : Value
  (match env
    [(ENil)
      (begin
        (panic "eval: unbound variable")
        (VInt 0))]
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
    [(FNil)
      (begin
        (panic "eval: unknown function")
        SNil)]
    [(FBind fname params _ rest)
      (if (string-eq fname name)
        params
        (lookup-fn-params rest name))]))

(define (lookup-fn-body [fenv : FnEnv] [name : String]) : Sexpr
  (match fenv
    [(FNil)
      (begin
        (panic "eval: unknown function")
        SNil)]
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
    [(SInt _)
      (begin
        (panic "eval: expected a cons cell (car of an atom)")
        SNil)]
    [(SSym _)
      (begin
        (panic "eval: expected a cons cell (car of an atom)")
        SNil)]
    [(SStr _)
      (begin
        (panic "eval: expected a cons cell (car of an atom)")
        SNil)]
    [(SFloat _)
      (begin
        (panic "eval: expected a cons cell (car of an atom)")
        SNil)]
    [(SChar _)
      (begin
        (panic "eval: expected a cons cell (car of an atom)")
        SNil)]
    [(SNil)
      (begin
        (panic "eval: expected a cons cell (car of nil / too few args)")
        SNil)]
    [(SCons h _) h]))

;; sexpr-tail ("cdr"): the tail child of a cons cell. Same malformed-shape guard.
(define (sexpr-tail [s : Sexpr]) : Sexpr
  (match s
    [(SInt _)
      (begin
        (panic "eval: expected a cons cell (cdr of an atom)")
        SNil)]
    [(SSym _)
      (begin
        (panic "eval: expected a cons cell (cdr of an atom)")
        SNil)]
    [(SStr _)
      (begin
        (panic "eval: expected a cons cell (cdr of an atom)")
        SNil)]
    [(SFloat _)
      (begin
        (panic "eval: expected a cons cell (cdr of an atom)")
        SNil)]
    [(SChar _)
      (begin
        (panic "eval: expected a cons cell (cdr of an atom)")
        SNil)]
    [(SNil)
      (begin
        (panic "eval: expected a cons cell (cdr of nil / too few args)")
        SNil)]
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
    [(SFloat _) (panic "eval: too many arguments")]
    [(SChar _) (panic "eval: too many arguments")]
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
      (let
        [var : String (let-var pair)]
        [v : Value (eval-sexpr (let-init pair) acc fenv)]
        (eval-let-bindings more (EBind var v acc) fenv))]
    [(SInt _)
      (begin
        (panic "eval: malformed let binding list")
        acc)]
    [(SSym _)
      (begin
        (panic "eval: malformed let binding list")
        acc)]
    [(SStr _)
      (begin
        (panic "eval: malformed let binding list")
        acc)]
    [(SFloat _)
      (begin
        (panic "eval: malformed let binding list")
        acc)]
    [(SChar _)
      (begin
        (panic "eval: malformed let binding list")
        acc)]))

;; let-var: the bound variable's name `x` from a binding pair `(x e1)`.
(define (let-var [pair : Sexpr]) : String
  (match pair
    [(SCons (SSym name) _) name]
    [_
      (begin
        (panic "eval: malformed let binding name")
        "")]))

;; let-init: the initializer sub-expression `e1` from a binding pair `(x e1)`.
;; The pair's tail-tail must be SNil: each binding has exactly a name and one
;; initializer.
(define (let-init [pair : Sexpr]) : Sexpr
  (let
    [rest : Sexpr (sexpr-tail pair)]
    (begin
      (sexpr-expect-nil (sexpr-tail rest))
      (sexpr-head rest))))

;; let-body: the body sub-expression. `rest` is `(SCons bindings (SCons body
;; SNil))`, so the body is the head of `rest`'s tail, and that tail's tail must be
;; SNil (a `let` has exactly one body expression - use `begin` for sequencing).
(define (let-body [rest : Sexpr]) : Sexpr
  (let
    [after : Sexpr (sexpr-tail rest)]
    (begin
      (sexpr-expect-nil (sexpr-tail after))
      (sexpr-head after))))

;; --------------------------------------------------------------------------
;; The `begin` special form: sequence sub-expressions, return the LAST (#27).
;; --------------------------------------------------------------------------
;; `(begin e1 e2 ... en)` is the natural SEQUENCING primitive of the interpreted
;; language - it evaluates each sub-expression IN ORDER for its side effects and
;; denotes the value of the LAST one. This retires the `seq` two-argument-function
;; workaround `(define (seq a b) b)`, whose only job was to evaluate two forms
;; left-to-right and return the second: `begin` generalises that to any number of
;; forms and is a real special form (its operands are NOT a call's argument list -
;; it controls evaluation order directly), so a sequence no longer has to be
;; nested pairs of `seq` calls.
;;
;; `(begin e1 e2 ... en)` reads into the spine
;;   rest = (SCons e1 (SCons e2 ... (SCons en SNil)))
;; so `eval-seq` walks that flat cons list head-first: for each cell it evaluates
;; the head form `e_i` in the current env/fenv (so EVERY form runs, for its side
;; effects), then if the tail is `SNil` that head was the LAST form and its value
;; is the result; otherwise it discards the value and recurses on the tail. The
;; threaded `env`/`fenv` are unchanged across the sequence (a `begin` introduces no
;; new bindings - it is purely sequencing), and `eval-seq` / `eval-sexpr` are
;; mutually recursive (each form is evaluated by re-entering `eval-sexpr`).
;;
;; EMPTY `(begin)`: `rest` is `SNil`, so there is no last value. CHOICE: return
;; `(VInt 0)` (rather than `panic`), matching the `(VInt 0)` neutral result the
;; other malformed-shape guards in this file fall back to - an empty sequence
;; simply denotes `0`. A malformed (improper) spine - a non-`SCons`, non-`SNil`
;; tail where a list element is expected - is a malformed program and aborts.
(define (eval-seq [forms : Sexpr] [env : Env] [fenv : FnEnv]) : Value
  (match forms
    [(SNil) (VInt 0)]
    [(SCons form rest)
      (let
        [v : Value (eval-sexpr form env fenv)]
        (match rest
          [(SNil) v]
          [_ (eval-seq rest env fenv)]))]
    [(SInt _)
      (begin
        (panic "eval: malformed begin body")
        (VInt 0))]
    [(SSym _)
      (begin
        (panic "eval: malformed begin body")
        (VInt 0))]
    [(SStr _)
      (begin
        (panic "eval: malformed begin body")
        (VInt 0))]
    [(SFloat _)
      (begin
        (panic "eval: malformed begin body")
        (VInt 0))]
    [(SChar _)
      (begin
        (panic "eval: malformed begin body")
        (VInt 0))]))

;; --------------------------------------------------------------------------
;; The `list` special form: build a cons LIST from N evaluated elements (#27).
;; --------------------------------------------------------------------------
;; `(list e1 e2 ... en)` is the variadic LIST CONSTRUCTOR - the ergonomic way to
;; build the right-nested chain of pairs `(cons e1 (cons e2 ... (cons en 0)))`
;; that this file uses as its singly-linked list, terminated by the `(VInt 0)`
;; NIL sentinel (so `null?` recognises its end). It is a SPECIAL FORM rather than
;; a builtin op because it takes an arbitrary NUMBER of operands (no fixed arity
;; to zip), so it is dispatched in `eval-sexpr` BEFORE the fixed-arity builtin-op
;; / user-call paths. `(list)` with no elements denotes the empty list `(VInt 0)`.
;;
;; `(list e1 e2 ... en)` reads into the spine
;;   rest = (SCons e1 (SCons e2 ... (SCons en SNil)))
;; so `eval-list` walks that flat cons list head-first - structurally identical to
;; how `eval-seq` walks a `begin` body, except instead of discarding all but the
;; last value it CONSES every evaluated element onto the recursively built tail:
;; at `SNil` the tail is `(VInt 0)` (NIL); at `(SCons head tail)` it evaluates
;; `head` in the current env/fenv and builds `(VPair <head-val> (eval-list tail))`.
;; So the result is exactly the cons chain a nested `cons` literal would build -
;; and `pair?` / `null?` / `car` / `cdr` / `sum-list` walk it identically.
;; `eval-list` and `eval-sexpr` are mutually recursive (each element is evaluated
;; by re-entering `eval-sexpr`). A malformed (improper) spine - a non-`SCons`,
;; non-`SNil` element position - is a malformed program and aborts.
(define (eval-list [elems : Sexpr] [env : Env] [fenv : FnEnv]) : Value
  (match elems
    [(SNil) (VInt 0)]
    [(SCons head tail)
      (VPair (eval-sexpr head env fenv) (eval-list tail env fenv))]
    [(SInt _)
      (begin
        (panic "eval: malformed list elements")
        (VInt 0))]
    [(SSym _)
      (begin
        (panic "eval: malformed list elements")
        (VInt 0))]
    [(SStr _)
      (begin
        (panic "eval: malformed list elements")
        (VInt 0))]
    [(SFloat _)
      (begin
        (panic "eval: malformed list elements")
        (VInt 0))]
    [(SChar _)
      (begin
        (panic "eval: malformed list elements")
        (VInt 0))]))

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
    [_
      (begin
        (panic "eval: malformed define function name")
        "")]))

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
  (let
    [after : Sexpr (sexpr-tail (sexpr-tail s))]
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
;; The `lambda` form: project the PARAMETER LIST and body (refs #27).
;; --------------------------------------------------------------------------
;; A `(lambda (p...) body)` form's tail `rest` reads into the spine
;;   rest = (SCons params (SCons body SNil))
;; so the parameter LIST is `rest`'s head and the body is the head of `rest`'s
;; tail (whose own tail must be `SNil` - a lambda has exactly one body expression,
;; like `let`). The parameter list is kept verbatim as the reader's cons-list of
;; `SSym`s so an arbitrary ARITY is supported; `bind-args-onto` validates each
;; element is an `(SSym ...)` and that the count matches at the call.
;; lambda-params: the parameter LIST `(p...)` from a lambda form's tail `rest`.
(define (lambda-params [rest : Sexpr]) : Sexpr
  (sexpr-head rest))

;; lambda-body: the single body expression from a lambda form's tail `rest`. The
;; tail's tail must be `SNil` (exactly one body expression).
(define (lambda-body [rest : Sexpr]) : Sexpr
  (let
    [after : Sexpr (sexpr-tail rest)]
    (begin
      (sexpr-expect-nil (sexpr-tail after))
      (sexpr-head after))))

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
;;   (SChar _)            -> unsupported here; the selfhost evaluator has no VChar yet.
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
;; Implemented here: lambda/closures and the variadic `list` special form.
;; Deferred: variadic user-function arity. Mutual recursion IS supported because
;; the whole `fenv` is shared.
(define (eval-sexpr [s : Sexpr] [env : Env] [fenv : FnEnv]) : Value
  (match s
    [(SInt n) (VInt n)]
    [(SSym name) (lookup env name)]
    ;; A string-literal atom (#27/#128): the reader produces `SStr` for a `"..."`
    ;; datum. The value domain now carries strings, so it evaluates to itself as a
    ;; `(VStr s)` - a first-class string VALUE that can be bound, returned, passed,
    ;; printed, and consumed by the string-operation dispatch arms below.
    [(SStr s) (VStr s)]
    [(SFloat _)
      (begin
        (panic "eval: float literal not supported yet")
        (VInt 0))]
    [(SChar _)
      (begin
        (panic "eval: char literal not supported yet")
        (VInt 0))]
    [(SNil)
      (begin
        (panic "eval: cannot evaluate the empty list")
        (VInt 0))]
    [(SCons (SSym name) rest)
      (if (string-eq name "list")
        ;; The `list` SPECIAL FORM `(list e1 e2 ... en)`: `rest` is the cons
        ;; spine `(SCons e1 (SCons e2 ... SNil))` of element expressions. Build
        ;; the cons LIST `(VPair v1 (VPair v2 ... (VInt 0)))` with `eval-list`,
        ;; which evaluates each element and conses it onto the recursively built
        ;; tail, terminating at `(VInt 0)` (NIL). `(list)` denotes `(VInt 0)`.
        ;; Like `begin` this is dispatched as a SPECIAL FORM (checked before the
        ;; fixed-arity builtin-op and user-call paths) because it is variadic -
        ;; there is no fixed parameter list to zip its operands against.
        (eval-list rest env fenv)
        (if (string-eq name "begin")
          ;; The `begin` SPECIAL FORM `(begin e1 e2 ... en)`: `rest` is the cons
          ;; spine `(SCons e1 (SCons e2 ... SNil))` of sub-expressions. Walk it
          ;; with `eval-seq`, evaluating each form in order for its side effects
          ;; and returning the LAST form's value (an empty `(begin)` denotes
          ;; `(VInt 0)`). This is checked FIRST - before the builtin-op and
          ;; user-call paths - so `begin` is dispatched as a special form (its
          ;; operands control evaluation ORDER; they are not a call's arguments).
          (eval-seq rest env fenv)
          (if (string-eq name "lambda")
            ;; The `lambda` SPECIAL FORM `(lambda (p...) body)`: rest is
            ;; `(SCons params (SCons body SNil))`. It does NOT evaluate the body; it
            ;; CAPTURES the current value environment `env` and packages the verbatim
            ;; parameter LIST and body AST into a `(VClosure params body env)` VALUE -
            ;; a first-class function. The captured `env` is what makes the body's
            ;; FREE variables resolve to their definition-site bindings when the
            ;; closure is later applied (closure = code + captured environment). The
            ;; `fenv` is NOT captured: top-level `define`s live in the single shared
            ;; function environment threaded through every application, so a closure
            ;; body can still call any defined function.
            (VClosure (lambda-params rest) (lambda-body rest) env)
            (if (string-eq name "let")
              ;; The `let` special form: `(let ((x e1) (y e2) ...) body)`. Fold the
              ;; whole binding LIST into the environment (sequentially, `let*`-style),
              ;; then evaluate the body in that extended environment.
              (eval-sexpr
                (let-body rest)
                (eval-let-bindings (let-bindings rest) env fenv)
                fenv)
              (if (string-eq name "if")
                ;; `if` SPECIAL FORM `(if cond then else)`: rest is
                ;; `(SCons cond (SCons then (SCons else SNil)))`. Project the three
                ;; sub-exprs, assert exactly three, then SHORT-CIRCUIT: eval cond,
                ;; `as-int` it, and eval ONLY the taken branch. `0` is false, anything
                ;; else true (a `VStr` condition is a type error, caught by `as-int`).
                (let
                  [cond-e : Sexpr (sexpr-head rest)]
                  [restc : Sexpr (sexpr-tail rest)]
                  (let
                    [then-e : Sexpr (sexpr-head restc)]
                    [restt : Sexpr (sexpr-tail restc)]
                    (let
                      [else-e : Sexpr (sexpr-head restt)]
                      [reste : Sexpr (sexpr-tail restt)]
                      (begin
                        (sexpr-expect-nil reste)
                        (let
                          [c : i64 (as-int (eval-sexpr cond-e env fenv))]
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
                  (let
                    [arg : Sexpr (sexpr-head rest)]
                    [restp : Sexpr (sexpr-tail rest)]
                    (begin
                      (sexpr-expect-nil restp)
                      (let
                        [v : Value (eval-sexpr arg env fenv)]
                        (begin
                          ;; A `VPair` now RENDERS AS A LIST (refs #27): the
                          ;; recursive `print-value` walks the cons chain and emits
                          ;; `(e1 e2 ... en)` (nesting parenthesised, an improper
                          ;; final cdr rendered in dotted-pair form `(a . b)` - see
                          ;; `print-value` / `print-list-tail`),
                          ;; replacing the old opaque `#<pair>` placeholder. Like the
                          ;; `VStr` / `VClosure` arms it writes RAW bytes with NO
                          ;; trailing newline (only the `VInt` arm appends one via the
                          ;; host `print`; the lexer has no string-escape support, so a
                          ;; literal newline is unavailable - the caller appends one by
                          ;; printing an int next when a clean line is wanted). `print`
                          ;; stays TOTAL over every `Value` shape, and a pair in an
                          ;; integer/string CONTEXT is still a type error via
                          ;; `as-int` / `as-str`. The pair VALUE is still RETURNED so
                          ;; `(print x)` composes inside a larger expression.
                          (match v
                            [(VInt n) (print n)]
                            [(VStr s) (print-string s)]
                            ;; A closure has no readable surface syntax, so it
                            ;; prints a fixed `#<closure>` marker (raw bytes, NO
                            ;; trailing newline - like the `VStr` arm) rather than
                            ;; aborting; the closure value is still RETURNED so
                            ;; `(print f)` composes.
                            [(VClosure _ _ _) (print-string "#<closure>")]
                            ;; A `VPair` prints as a list `(e1 e2 ... en)` via the
                            ;; recursive `print-value` walk (nesting parenthesised; an
                            ;; improper final cdr rendered in dotted-pair form
                            ;; `(a . b)` - handling documented there).
                            [(VPair _ _) (print-value v)])
                          v))))
                  (if (string-eq name "string-length")
                    ;; STRING OP `(string-length s)`: rest is `(SCons s SNil)`.
                    ;; Evaluate the single argument, `as-str`-project it (a `VInt`
                    ;; here is a type error), call the host `string-length`
                    ;; builtin, and re-wrap its i64 byte-count as `(VInt r)`.
                    (let
                      [arg : Sexpr (sexpr-head rest)]
                      [restl : Sexpr (sexpr-tail rest)]
                      (begin
                        (sexpr-expect-nil restl)
                        (VInt
                          (string-length (as-str (eval-sexpr arg env fenv))))))
                    (if (string-eq name "substring")
                      ;; STRING OP `(substring s i n)`: rest is
                      ;; `(SCons s (SCons i (SCons n SNil)))`. Evaluate all three
                      ;; sub-exprs, `as-str` the source and `as-int` the start /
                      ;; length, call the host `substring` builtin (a half-open
                      ;; `[i, i+n)` slice, bounds-checked at runtime), and re-wrap
                      ;; the fresh String result as `(VStr r)`.
                      (let
                        [se : Sexpr (sexpr-head rest)]
                        [rests : Sexpr (sexpr-tail rest)]
                        (let
                          [ie : Sexpr (sexpr-head rests)]
                          [rests2 : Sexpr (sexpr-tail rests)]
                          (let
                            [ne : Sexpr (sexpr-head rests2)]
                            [rests3 : Sexpr (sexpr-tail rests2)]
                            (begin
                              (sexpr-expect-nil rests3)
                              (VStr
                                (substring
                                  (as-str (eval-sexpr se env fenv))
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
                        (let
                          [ae : Sexpr (sexpr-head rest)]
                          [reste : Sexpr (sexpr-tail rest)]
                          (let
                            [be : Sexpr (sexpr-head reste)]
                            [reste2 : Sexpr (sexpr-tail reste)]
                            (begin
                              (sexpr-expect-nil reste2)
                              (VInt
                                (if (string-eq
                                  (as-str (eval-sexpr ae env fenv))
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
                          (let
                            [arg : Sexpr (sexpr-head rest)]
                            [resti : Sexpr (sexpr-tail rest)]
                            (begin
                              (sexpr-expect-nil resti)
                              (VStr
                                (int->string (as-int (eval-sexpr arg env fenv))))))
                          (if (string-eq name "string->int")
                            ;; STRING OP `(string->int s)`: rest is
                            ;; `(SCons s SNil)`. Evaluate the single argument,
                            ;; `as-str`-project it (a `VInt` here is a type
                            ;; error), call the host `string->int` builtin (the
                            ;; decimal-string -> i64 parse), and re-wrap the
                            ;; i64 result as `(VInt r)` - the inverse of
                            ;; `int->string`, so a string VALUE denoting a
                            ;; number can be parsed back to an integer VALUE.
                            (let
                              [arg : Sexpr (sexpr-head rest)]
                              [restp2 : Sexpr (sexpr-tail rest)]
                              (begin
                                (sexpr-expect-nil restp2)
                                (VInt
                                  (string->int
                                    (as-str (eval-sexpr arg env fenv))))))
                            (if (string-eq name "string-append")
                              ;; STRING OP `(string-append a b)`: rest is
                              ;; `(SCons a (SCons b SNil))`. Evaluate both
                              ;; operands, `as-str`-project each (a `VInt` here
                              ;; is a type error), call the host `string-append`
                              ;; builtin - the emit-on-demand `tl_string_concat`
                              ;; runtime that copies both operands' bytes into
                              ;; ONE fresh heap String - and re-wrap that joined
                              ;; String as `(VStr r)`. This completes the
                              ;; interpreter's string toolkit: it can now BUILD
                              ;; strings, not only measure / slice / compare /
                              ;; print them.
                              (let
                                [ae : Sexpr (sexpr-head rest)]
                                [restA : Sexpr (sexpr-tail rest)]
                                (let
                                  [be : Sexpr (sexpr-head restA)]
                                  [restA2 : Sexpr (sexpr-tail restA)]
                                  (begin
                                    (sexpr-expect-nil restA2)
                                    (VStr
                                      (string-append
                                        (as-str (eval-sexpr ae env fenv))
                                        (as-str (eval-sexpr be env fenv)))))))
                              (if (string-eq name "cons")
                                ;; CONS PAIR `(cons a b)`: rest is
                                ;; `(SCons a (SCons b SNil))`. Evaluate BOTH
                                ;; argument sub-exprs (in the current env, so
                                ;; nested calls resolve) into `Value`s and pack
                                ;; them into a fresh `(VPair a-val b-val)` cell -
                                ;; the heap-allocated two-field cons cell of the
                                ;; interpreted language. No `as-int`/`as-str`
                                ;; projection: a pair holds ANY two values
                                ;; (ints, strings, or further pairs), which is
                                ;; exactly what makes a singly-linked LIST a
                                ;; right-nested chain of pairs.
                                (let
                                  [ae : Sexpr (sexpr-head rest)]
                                  [restC : Sexpr (sexpr-tail rest)]
                                  (let
                                    [be : Sexpr (sexpr-head restC)]
                                    [restC2 : Sexpr (sexpr-tail restC)]
                                    (begin
                                      (sexpr-expect-nil restC2)
                                      (VPair
                                        (eval-sexpr ae env fenv)
                                        (eval-sexpr be env fenv)))))
                                (if (string-eq name "car")
                                  ;; CAR `(car p)`: rest is `(SCons p SNil)`.
                                  ;; Evaluate the single argument and project the
                                  ;; FIRST field of the pair. A non-pair value in
                                  ;; car position is a type error in the interpreted
                                  ;; program - abort via `panic` (the same channel
                                  ;; `as-int` / `as-str` use). `(VInt 0)` is the
                                  ;; neutral fall-through after the panic.
                                  (let
                                    [pe : Sexpr (sexpr-head rest)]
                                    [restR : Sexpr (sexpr-tail rest)]
                                    (begin
                                      (sexpr-expect-nil restR)
                                      (match (eval-sexpr pe env fenv)
                                        [(VPair a _) a]
                                        [(VInt _)
                                          (begin
                                            (panic "car: not a pair")
                                            (VInt 0))]
                                        [(VStr _)
                                          (begin
                                            (panic "car: not a pair")
                                            (VInt 0))]
                                        [(VClosure _ _ _)
                                          (begin
                                            (panic "car: not a pair")
                                            (VInt 0))])))
                                  (if (string-eq name "cdr")
                                    ;; CDR `(cdr p)`: rest is `(SCons p SNil)`.
                                    ;; Evaluate the single argument and project the
                                    ;; SECOND field of the pair - the REST of a list.
                                    ;; A non-pair value is a type error - abort.
                                    (let
                                      [pe : Sexpr (sexpr-head rest)]
                                      [restD : Sexpr (sexpr-tail rest)]
                                      (begin
                                        (sexpr-expect-nil restD)
                                        (match (eval-sexpr pe env fenv)
                                          [(VPair _ d) d]
                                          [(VInt _)
                                            (begin
                                              (panic "cdr: not a pair")
                                              (VInt 0))]
                                          [(VStr _)
                                            (begin
                                              (panic "cdr: not a pair")
                                              (VInt 0))]
                                          [(VClosure _ _ _)
                                            (begin
                                              (panic "cdr: not a pair")
                                              (VInt 0))])))
                                    (if (string-eq name "pair?")
                                      ;; PREDICATE `(pair? x)` (refs #27): rest is
                                      ;; `(SCons x SNil)`. Evaluate the single argument
                                      ;; and ask whether the resulting `Value` is a CONS
                                      ;; PAIR - a `(VPair ...)` cell. Folds to the
                                      ;; 1 (true) / 0 (false) integer-truth convention as
                                      ;; `(VInt r)`, matching the comparison operators and
                                      ;; `null?`. This is the structural test a recursive
                                      ;; list algorithm uses to tell a non-empty list
                                      ;; (a pair) from the NIL terminator, so it can recur
                                      ;; on `(cdr l)` only while there is more list - the
                                      ;; termination witness for `sum-list` below. Unlike
                                      ;; `car` / `cdr` it is TOTAL: a non-pair is simply
                                      ;; `(VInt 0)` (false), never a type error.
                                      (let
                                        [pe : Sexpr (sexpr-head rest)]
                                        [restP : Sexpr (sexpr-tail rest)]
                                        (begin
                                          (sexpr-expect-nil restP)
                                          (match (eval-sexpr pe env fenv)
                                            [(VPair _ _) (VInt 1)]
                                            [(VInt _) (VInt 0)]
                                            [(VStr _) (VInt 0)]
                                            [(VClosure _ _ _) (VInt 0)])))
                                      (if (string-eq name "null?")
                                        ;; PREDICATE `(null? x)` (refs #27/#141): rest is
                                        ;; `(SCons x SNil)`. Evaluate the single argument and
                                        ;; ask whether it is the EMPTY-LIST sentinel NIL.
                                        ;; This file reuses `(VInt 0)` as nil (see the value
                                        ;; domain notes: a list is a right-nested chain of
                                        ;; pairs terminated by the integer `0`, no dedicated
                                        ;; nil variant), so `null?` is true exactly when the
                                        ;; value is `(VInt 0)`. Any other value - a non-zero
                                        ;; int, a string, a closure, or a pair - is not nil.
                                        ;; Folds to the 1 / 0 integer-truth convention as
                                        ;; `(VInt r)`. Also TOTAL over the value domain.
                                        (let
                                          [pe : Sexpr (sexpr-head rest)]
                                          [restN : Sexpr (sexpr-tail rest)]
                                          (begin
                                            (sexpr-expect-nil restN)
                                            (match (eval-sexpr pe env fenv)
                                              [(VInt n)
                                                (if (= n 0)
                                                  (VInt 1)
                                                  (VInt 0))]
                                              [(VStr _) (VInt 0)]
                                              [(VClosure _ _ _) (VInt 0)]
                                              [(VPair _ _) (VInt 0)])))
                                        (if (is-builtin-op name)
                                          ;; A builtin binary call form `(op arg1 arg2)`: rest is
                                          ;; `(SCons arg1 (SCons arg2 SNil))`. Both operands must be
                                          ;; integers, so each is `as-int`-projected; the i64 result is
                                          ;; re-wrapped as `(VInt r)`.
                                          (let
                                            [arg1 : Sexpr (sexpr-head rest)]
                                            [rest2 : Sexpr (sexpr-tail rest)]
                                            (let
                                              [arg2 : Sexpr (sexpr-head rest2)]
                                              [rest3 : Sexpr (sexpr-tail rest2)]
                                              (begin
                                                (sexpr-expect-nil rest3)
                                                (let
                                                  [a : i64
                                                    (as-int
                                                      (eval-sexpr arg1 env fenv))]
                                                  [b : i64
                                                    (as-int
                                                      (eval-sexpr arg2 env fenv))]
                                                  (VInt (eval-builtin name a b))))))
                                          ;; OTHERWISE: a USER-FUNCTION CALL `(f a b c)`. `rest` is the
                                          ;; ARGUMENT-EXPRESSION list `(SCons a (SCons b (SCons c SNil)))`.
                                          ;; Look up `f`'s PARAMETER LIST and body in the shared `fenv`,
                                          ;; then build the callee env by zipping the parameter list
                                          ;; against the argument list with `bind-args` (each argument
                                          ;; evaluated in the CURRENT env, so caller variables resolve),
                                          ;; and evaluate the body in that callee env with the SAME
                                          ;; `fenv` - so the body resolves recursive and sibling calls.
                                          ;; Arbitrary arity. BUT FIRST: a symbol head may
                                          ;; name a CLOSURE-VALUED VARIABLE in the lexical
                                          ;; env (e.g. `(let ((f (lambda (x) x))) (f 5))`),
                                          ;; not a top-level `define`. So if `name` is bound
                                          ;; in `env`, look it up and APPLY the resulting
                                          ;; value as a closure (the variable shadows any
                                          ;; same-named define); otherwise it is a call into
                                          ;; the shared `fenv`.
                                          (if (env-has env name)
                                            (apply-value
                                              (lookup env name)
                                              rest
                                              env
                                              fenv)
                                            (let
                                              [params : Sexpr
                                                (lookup-fn-params fenv name)]
                                              [body : Sexpr
                                                (lookup-fn-body fenv name)]
                                              (eval-sexpr
                                                body
                                                (bind-args params rest env fenv)
                                                fenv)))))))))))))))))))))]
    ;; APPLICATION OF A COMPUTED OPERATOR `((<expr>) a b ...)`: the head is itself
    ;; a non-symbol form (a `lambda` literal, or any expression that evaluates to a
    ;; closure), so it falls through the symbol-head arm. Evaluate the head form in
    ;; the current env to a `Value`, then apply it as a closure to the argument
    ;; list `rest` - e.g. `((lambda (x) (* x x)) 5)`.
    [(SCons head rest) (apply-value (eval-sexpr head env fenv) rest env fenv)]
    [_
      (begin
        (panic "eval: not an evaluable expression")
        (VInt 0))]))

;; --------------------------------------------------------------------------
;; Closure application + the env predicate that routes a symbol-head call (#27).
;; --------------------------------------------------------------------------
;; env-has: does `name` have a binding in the lexical environment? Walks the
;; assoc-list head-first exactly like `lookup`, but returns a bool instead of
;; aborting on the empty environment - it is the non-fatal probe that decides, at
;; a symbol-head call site `(f a b)`, whether `f` is a closure-valued VARIABLE
;; (apply it) or a top-level `define` (call into `fenv`). A variable shadows a
;; same-named define, matching the usual lexical-scoping rule.
(define (env-has [env : Env] [name : String]) : bool
  (match env
    [(ENil) false]
    [(EBind bound _ rest)
      (if (string-eq bound name)
        true
        (env-has rest name))]))

;; apply-value: APPLY a value to an argument-expression list. The value must be a
;; `(VClosure params body captured-env)`; a non-closure in operator position
;; (e.g. `(5 1 2)`) is a type error in the interpreted program - abort. The
;; closure is applied by ZIPPING its parameter list against the argument exprs
;; (each evaluated in the CALLER's env, so the actual arguments see caller-scope
;; variables) and EXTENDING THE CAPTURED ENV with those bindings via
;; `bind-args-onto` - so the body sees both its parameters AND the free variables
;; captured when the lambda was created. The body is then evaluated in that
;; extended env with the shared `fenv` (top-level functions stay reachable).
(define (apply-value [f : Value] [args : Sexpr] [caller : Env] [fenv : FnEnv]) : Value
  (match f
    [(VClosure params body captured)
      (eval-sexpr body (bind-args-onto params args caller fenv captured) fenv)]
    [(VInt _)
      (begin
        (panic "eval: cannot apply a non-function value")
        (VInt 0))]
    [(VStr _)
      (begin
        (panic "eval: cannot apply a non-function value")
        (VInt 0))]
    [(VPair _ _)
      (begin
        (panic "eval: cannot apply a non-function value")
        (VInt 0))]))

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
;;
;; `bind-args` builds the callee env on top of the EMPTY environment `ENil` (a
;; top-level `define` body is lexically closed - it sees only its parameters and
;; the shared `fenv`, never caller locals). It is the `base = ENil` case of the
;; generalised `bind-args-onto`, to which it delegates: a CLOSURE application
;; instead extends the lambda's CAPTURED env, so the two share this one zip.
(define (bind-args
  [params : Sexpr]
  [args : Sexpr]
  [caller : Env]
  [fenv : FnEnv]) : Env
  (bind-args-onto params args caller fenv ENil))

;; bind-args-onto: the generalised parameter/argument zip. Identical to
;; `bind-args` except the freshly built frames are pushed onto a caller-supplied
;; BASE environment rather than `ENil`. A top-level call passes `ENil` (closed
;; scope, via `bind-args`); a CLOSURE application passes the lambda's CAPTURED env
;; (so the body sees its parameters layered over the variables free in the lambda
;; - the essence of a closure). Each argument is still evaluated in the CALLER's
;; env (so actual arguments resolve caller-scope variables, not sibling params /
;; captured names), and the parameter/argument lists must have equal length.
(define (bind-args-onto
  [params : Sexpr]
  [args : Sexpr]
  [caller : Env]
  [fenv : FnEnv]
  [base : Env]) : Env
  (match params
    ;; No more parameters: the argument list must also be exhausted. The result is
    ;; the BASE env (`ENil` for a top-level call, the captured env for a closure).
    [(SNil)
      (match args
        [(SNil) base]
        [_
          (begin
            (panic "eval: too many arguments in call")
            base)])]
    ;; One more parameter `(SSym pname)`: there must be a matching argument.
    [(SCons (SSym pname) ptail)
      (match args
        [(SCons arg atail)
          (EBind
            pname
            (eval-sexpr arg caller fenv)
            (bind-args-onto ptail atail caller fenv base))]
        [(SNil)
          (begin
            (panic "eval: too few arguments in call")
            base)]
        [(SInt _)
          (begin
            (panic "eval: malformed argument list")
            base)]
        [(SSym _)
          (begin
            (panic "eval: malformed argument list")
            base)]
        [(SStr _)
          (begin
            (panic "eval: malformed argument list")
            base)]
        [(SFloat _)
          (begin
            (panic "eval: malformed argument list")
            base)]
        [(SChar _)
          (begin
            (panic "eval: malformed argument list")
            base)])]
    [_
      (begin
        (panic "eval: malformed parameter list")
        base)]))

;; is-builtin-op: is `name` one of the fixed binary builtins? This is the dispatch
;; key that separates a builtin call from a USER-FUNCTION call in `eval-sexpr`:
;; the arithmetic operators `+ - * /` and the comparison operators `= < > <= >=`.
;; Anything else is treated as a call into the `FnEnv`.
(define (is-builtin-op [name : String]) : bool
  (or
    (string-eq name "+")
    (or
      (string-eq name "-")
      (or
        (string-eq name "*")
        (or
          (string-eq name "/")
          (or
            (string-eq name "=")
            (or
              (string-eq name "<")
              (or
                (string-eq name ">")
                (or (string-eq name "<=") (string-eq name ">="))))))))))

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
            (if (= a b)
              1
              0)
            (if (string-eq name "<")
              (if (< a b)
                1
                0)
              (if (string-eq name ">")
                (if (> a b)
                  1
                  0)
                (if (string-eq name "<=")
                  (if (<= a b)
                    1
                    0)
                  (if (string-eq name ">=")
                    (if (>= a b)
                      1
                      0)
                    (begin
                      (panic "eval: unknown operator")
                      0)))))))))))

;; --------------------------------------------------------------------------
;; Recoverable evaluator path (#445).
;; --------------------------------------------------------------------------
;; The original evaluator helpers above intentionally remain as a compact
;; smoke-test witness. The public driver below now uses these `*-result` helpers
;; so malformed interpreted programs return plain String diagnostics instead of
;; aborting the compiled evaluator through `panic`.
(define (as-int-result [v : Value]) : ResultI64
  (match v
    [(VInt n) (OkI64 n)]
    [(VStr _) (ErrI64 "type error: expected int")]
    [(VClosure _ _ _) (ErrI64 "type error: expected int")]
    [(VPair _ _) (ErrI64 "type error: expected int")]))

(define (as-str-result [v : Value]) : ResultString
  (match v
    [(VStr s) (OkString s)]
    [(VInt _) (ErrString "type error: expected string")]
    [(VClosure _ _ _) (ErrString "type error: expected string")]
    [(VPair _ _) (ErrString "type error: expected string")]))

(define (lookup-result [env : Env] [name : String]) : ResultValue
  (match env
    [(ENil) (ErrValue "eval: unbound variable")]
    [(EBind bound val rest)
      (if (string-eq bound name)
        (OkValue val)
        (lookup-result rest name))]))

(define (lookup-fn-result [fenv : FnEnv] [name : String]) : ResultFnDef
  (match fenv
    [(FNil) (ErrFnDef "eval: unknown function")]
    [(FBind fname params body rest)
      (if (string-eq fname name)
        (OkFnDef fname params body)
        (lookup-fn-result rest name))]))

(define (eval-value-as-int [expr : Sexpr] [env : Env] [fenv : FnEnv]) : ResultI64
  (match (eval-sexpr-result expr env fenv)
    [(OkValue v) (as-int-result v)]
    [(ErrValue message) (ErrI64 message)]))

(define (eval-value-as-str [expr : Sexpr] [env : Env] [fenv : FnEnv]) : ResultString
  (match (eval-sexpr-result expr env fenv)
    [(OkValue v) (as-str-result v)]
    [(ErrValue message) (ErrString message)]))

(define (eval-let-bindings-result [bindings : Sexpr] [acc : Env] [fenv : FnEnv]) : ResultEnv
  (match bindings
    [(SNil) (OkEnv acc)]
    [(SCons (SCons (SSym var) (SCons init (SNil))) more)
      (match (eval-sexpr-result init acc fenv)
        [(OkValue v) (eval-let-bindings-result more (EBind var v acc) fenv)]
        [(ErrValue message) (ErrEnv message)])]
    [(SCons (SCons _ _) _) (ErrEnv "eval: malformed let binding name")]
    [(SCons _ _) (ErrEnv "eval: malformed let binding list")]
    [_ (ErrEnv "eval: malformed let binding list")]))

(define (eval-seq-result [forms : Sexpr] [env : Env] [fenv : FnEnv]) : ResultValue
  (match forms
    [(SNil) (OkValue (VInt 0))]
    [(SCons form rest)
      (match (eval-sexpr-result form env fenv)
        [(OkValue v)
          (match rest
            [(SNil) (OkValue v)]
            [(SCons _ _) (eval-seq-result rest env fenv)]
            [_ (ErrValue "eval: malformed begin body")])]
        [(ErrValue message) (ErrValue message)])]
    [_ (ErrValue "eval: malformed begin body")]))

(define (eval-list-result [elems : Sexpr] [env : Env] [fenv : FnEnv]) : ResultValue
  (match elems
    [(SNil) (OkValue (VInt 0))]
    [(SCons head tail)
      (match (eval-sexpr-result head env fenv)
        [(OkValue head-val)
          (match (eval-list-result tail env fenv)
            [(OkValue tail-val) (OkValue (VPair head-val tail-val))]
            [(ErrValue message) (ErrValue message)])]
        [(ErrValue message) (ErrValue message)])]
    [_ (ErrValue "eval: malformed list elements")]))

(define (bind-args-result
  [params : Sexpr]
  [args : Sexpr]
  [caller : Env]
  [fenv : FnEnv]) : ResultEnv
  (bind-args-onto-result params args caller fenv ENil))

(define (bind-args-onto-result
  [params : Sexpr]
  [args : Sexpr]
  [caller : Env]
  [fenv : FnEnv]
  [base : Env]) : ResultEnv
  (match params
    [(SNil)
      (match args
        [(SNil) (OkEnv base)]
        [_ (ErrEnv "eval: too many arguments in call")])]
    [(SCons (SSym pname) ptail)
      (match args
        [(SCons arg atail)
          (match (eval-sexpr-result arg caller fenv)
            [(OkValue arg-val)
              (match (bind-args-onto-result ptail atail caller fenv base)
                [(OkEnv rest-env) (OkEnv (EBind pname arg-val rest-env))]
                [(ErrEnv message) (ErrEnv message)])]
            [(ErrValue message) (ErrEnv message)])]
        [(SNil) (ErrEnv "eval: too few arguments in call")]
        [_ (ErrEnv "eval: malformed argument list")])]
    [_ (ErrEnv "eval: malformed parameter list")]))

(define (apply-value-result
  [f : Value]
  [args : Sexpr]
  [caller : Env]
  [fenv : FnEnv]) : ResultValue
  (match f
    [(VClosure params body captured)
      (match (bind-args-onto-result params args caller fenv captured)
        [(OkEnv call-env) (eval-sexpr-result body call-env fenv)]
        [(ErrEnv message) (ErrValue message)])]
    [(VInt _) (ErrValue "eval: cannot apply a non-function value")]
    [(VStr _) (ErrValue "eval: cannot apply a non-function value")]
    [(VPair _ _) (ErrValue "eval: cannot apply a non-function value")]))

(define (eval-unary-arg [rest : Sexpr] [message : String]) : ResultUnaryArg
  (match rest
    [(SCons arg (SNil)) (OkUnaryArg arg)]
    [_ (ErrUnaryArg message)]))

(define (eval-binary-args [rest : Sexpr] [message : String]) : ResultBinaryArgs
  (match rest
    [(SCons a (SCons b (SNil))) (OkBinaryArgs a b)]
    [_ (ErrBinaryArgs message)]))

(define (eval-ternary-args [rest : Sexpr] [message : String]) : ResultTernaryArgs
  (match rest
    [(SCons a (SCons b (SCons c (SNil)))) (OkTernaryArgs a b c)]
    [_ (ErrTernaryArgs message)]))

(define (eval-symbol-call-result
  [name : String]
  [rest : Sexpr]
  [env : Env]
  [fenv : FnEnv]) : ResultValue
  (if (string-eq name "list")
    (eval-list-result rest env fenv)
    (if (string-eq name "begin")
      (eval-seq-result rest env fenv)
      (if (string-eq name "lambda")
        (match rest
          [(SCons params (SCons body (SNil)))
            (OkValue (VClosure params body env))]
          [_ (ErrValue "eval: malformed lambda")])
        (if (string-eq name "let")
          (match rest
            [(SCons bindings (SCons body (SNil)))
              (match (eval-let-bindings-result bindings env fenv)
                [(OkEnv let-env) (eval-sexpr-result body let-env fenv)]
                [(ErrEnv message) (ErrValue message)])]
            [_ (ErrValue "eval: malformed let")])
          (if (string-eq name "if")
            (match rest
              [(SCons cond-e (SCons then-e (SCons else-e (SNil))))
                (match (eval-value-as-int cond-e env fenv)
                  [(OkI64 c)
                    (if (= c 0)
                      (eval-sexpr-result else-e env fenv)
                      (eval-sexpr-result then-e env fenv))]
                  [(ErrI64 message) (ErrValue message)])]
              [_ (ErrValue "eval: malformed if")])
            (if (string-eq name "print")
              (match (eval-unary-arg rest "eval: malformed print")
                [(OkUnaryArg arg)
                  (match (eval-sexpr-result arg env fenv)
                    [(OkValue v)
                      (begin
                        (match v
                          [(VInt n) (print n)]
                          [(VStr s) (print-string s)]
                          [(VClosure _ _ _) (print-string "#<closure>")]
                          [(VPair _ _) (print-value v)])
                        (OkValue v))]
                    [(ErrValue message) (ErrValue message)])]
                [(ErrUnaryArg message) (ErrValue message)])
              (if (string-eq name "string-length")
                (match (eval-unary-arg rest "eval: malformed string-length")
                  [(OkUnaryArg arg)
                    (match (eval-value-as-str arg env fenv)
                      [(OkString s) (OkValue (VInt (string-length s)))]
                      [(ErrString message) (ErrValue message)])]
                  [(ErrUnaryArg message) (ErrValue message)])
                (if (string-eq name "substring")
                  (match (eval-ternary-args rest "eval: malformed substring")
                    [(OkTernaryArgs se ie ne)
                      (match (eval-value-as-str se env fenv)
                        [(OkString s)
                          (match (eval-value-as-int ie env fenv)
                            [(OkI64 i)
                              (match (eval-value-as-int ne env fenv)
                                [(OkI64 n) (OkValue (VStr (substring s i n)))]
                                [(ErrI64 message) (ErrValue message)])]
                            [(ErrI64 message) (ErrValue message)])]
                        [(ErrString message) (ErrValue message)])]
                    [(ErrTernaryArgs message) (ErrValue message)])
                  (if (string-eq name "string-eq")
                    (match (eval-binary-args rest "eval: malformed string-eq")
                      [(OkBinaryArgs ae be)
                        (match (eval-value-as-str ae env fenv)
                          [(OkString a)
                            (match (eval-value-as-str be env fenv)
                              [(OkString b)
                                (OkValue
                                  (VInt
                                    (if (string-eq a b)
                                      1
                                      0)))]
                              [(ErrString message) (ErrValue message)])]
                          [(ErrString message) (ErrValue message)])]
                      [(ErrBinaryArgs message) (ErrValue message)])
                    (if (string-eq name "int->string")
                      (match (eval-unary-arg rest "eval: malformed int->string")
                        [(OkUnaryArg arg)
                          (match (eval-value-as-int arg env fenv)
                            [(OkI64 n) (OkValue (VStr (int->string n)))]
                            [(ErrI64 message) (ErrValue message)])]
                        [(ErrUnaryArg message) (ErrValue message)])
                      (if (string-eq name "string->int")
                        (match (eval-unary-arg
                          rest
                          "eval: malformed string->int")
                          [(OkUnaryArg arg)
                            (match (eval-value-as-str arg env fenv)
                              [(OkString s) (OkValue (VInt (string->int s)))]
                              [(ErrString message) (ErrValue message)])]
                          [(ErrUnaryArg message) (ErrValue message)])
                        (if (string-eq name "string-append")
                          (match (eval-binary-args
                            rest
                            "eval: malformed string-append")
                            [(OkBinaryArgs ae be)
                              (match (eval-value-as-str ae env fenv)
                                [(OkString a)
                                  (match (eval-value-as-str be env fenv)
                                    [(OkString b)
                                      (OkValue (VStr (string-append a b)))]
                                    [(ErrString message) (ErrValue message)])]
                                [(ErrString message) (ErrValue message)])]
                            [(ErrBinaryArgs message) (ErrValue message)])
                          (if (string-eq name "cons")
                            (match (eval-binary-args
                              rest
                              "eval: malformed cons")
                              [(OkBinaryArgs ae be)
                                (match (eval-sexpr-result ae env fenv)
                                  [(OkValue a)
                                    (match (eval-sexpr-result be env fenv)
                                      [(OkValue b) (OkValue (VPair a b))]
                                      [(ErrValue message) (ErrValue message)])]
                                  [(ErrValue message) (ErrValue message)])]
                              [(ErrBinaryArgs message) (ErrValue message)])
                            (if (string-eq name "car")
                              (match (eval-unary-arg rest "eval: malformed car")
                                [(OkUnaryArg pe)
                                  (match (eval-sexpr-result pe env fenv)
                                    [(OkValue pair-val)
                                      (match pair-val
                                        [(VPair a _) (OkValue a)]
                                        [_ (ErrValue "car: not a pair")])]
                                    [(ErrValue message) (ErrValue message)])]
                                [(ErrUnaryArg message) (ErrValue message)])
                              (if (string-eq name "cdr")
                                (match (eval-unary-arg
                                  rest
                                  "eval: malformed cdr")
                                  [(OkUnaryArg pe)
                                    (match (eval-sexpr-result pe env fenv)
                                      [(OkValue pair-val)
                                        (match pair-val
                                          [(VPair _ d) (OkValue d)]
                                          [_ (ErrValue "cdr: not a pair")])]
                                      [(ErrValue message) (ErrValue message)])]
                                  [(ErrUnaryArg message) (ErrValue message)])
                                (if (string-eq name "pair?")
                                  (match (eval-unary-arg
                                    rest
                                    "eval: malformed pair?")
                                    [(OkUnaryArg pe)
                                      (match (eval-sexpr-result pe env fenv)
                                        [(OkValue pair-val)
                                          (match pair-val
                                            [(VPair _ _) (OkValue (VInt 1))]
                                            [_ (OkValue (VInt 0))])]
                                        [(ErrValue message) (ErrValue message)])]
                                    [(ErrUnaryArg message) (ErrValue message)])
                                  (if (string-eq name "null?")
                                    (match (eval-unary-arg
                                      rest
                                      "eval: malformed null?")
                                      [(OkUnaryArg pe)
                                        (match (eval-sexpr-result pe env fenv)
                                          [(OkValue null-val)
                                            (match null-val
                                              [(VInt n)
                                                (OkValue
                                                  (if (= n 0)
                                                    (VInt 1)
                                                    (VInt 0)))]
                                              [_ (OkValue (VInt 0))])]
                                          [(ErrValue message)
                                            (ErrValue message)])]
                                      [(ErrUnaryArg message) (ErrValue message)])
                                    (if (is-builtin-op name)
                                      (match (eval-binary-args
                                        rest
                                        "eval: malformed binary expression")
                                        [(OkBinaryArgs arg1 arg2)
                                          (match (eval-value-as-int
                                            arg1
                                            env
                                            fenv)
                                            [(OkI64 a)
                                              (match (eval-value-as-int
                                                arg2
                                                env
                                                fenv)
                                                [(OkI64 b)
                                                  (OkValue
                                                    (VInt
                                                      (eval-builtin name a b)))]
                                                [(ErrI64 message)
                                                  (ErrValue message)])]
                                            [(ErrI64 message)
                                              (ErrValue message)])]
                                        [(ErrBinaryArgs message)
                                          (ErrValue message)])
                                      (if (env-has env name)
                                        (match (lookup-result env name)
                                          [(OkValue f)
                                            (apply-value-result f rest env fenv)]
                                          [(ErrValue message)
                                            (ErrValue message)])
                                        (match (lookup-fn-result fenv name)
                                          [(OkFnDef _ params body)
                                            (match (bind-args-result
                                              params
                                              rest
                                              env
                                              fenv)
                                              [(OkEnv call-env)
                                                (eval-sexpr-result
                                                  body
                                                  call-env
                                                  fenv)]
                                              [(ErrEnv message)
                                                (ErrValue message)])]
                                          [(ErrFnDef message)
                                            (ErrValue message)])))))))))))))))))))))

(define (eval-sexpr-result [s : Sexpr] [env : Env] [fenv : FnEnv]) : ResultValue
  (match s
    [(SInt n) (OkValue (VInt n))]
    [(SSym name) (lookup-result env name)]
    [(SStr s) (OkValue (VStr s))]
    [(SFloat _) (ErrValue "eval: float literal not supported yet")]
    [(SChar _) (ErrValue "eval: char literal not supported yet")]
    [(SNil) (ErrValue "eval: cannot evaluate the empty list")]
    [(SCons (SSym name) rest) (eval-symbol-call-result name rest env fenv)]
    [(SCons head rest)
      (match (eval-sexpr-result head env fenv)
        [(OkValue f) (apply-value-result f rest env fenv)]
        [(ErrValue message) (ErrValue message)])]
    [_ (ErrValue "eval: not an evaluable expression")]))

;; Parse a top-level define form into the function environment record that the
;; evaluator needs. This is recoverable because a REPL/tool may want to report a
;; malformed non-final form without terminating the whole evaluator process.
(define (define-result [s : Sexpr]) : ResultFnDef
  (match s
    [(SCons (SSym head) rest)
      (if (string-eq head "define")
        (match rest
          [(SCons (SCons (SSym name) params) (SCons body (SNil)))
            (OkFnDef name params body)]
          [_ (ErrFnDef "eval: malformed define")])
        (ErrFnDef "eval: expected define"))]
    [_ (ErrFnDef "eval: expected define")]))

;; Convert a final expression result to the process-level integer result. A
;; string/pair/closure final value is a recoverable evaluator type error.
(define (value-result-as-int-result [result : ResultValue]) : ResultI64
  (match result
    [(OkValue v) (as-int-result v)]
    [(ErrValue message) (ErrI64 message)]))

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
(define (run-forms-panic
  [toks : (Array Token)]
  [cur : (Array i64)]
  [fenv : FnEnv]) : i64
  (let
    [form : Sexpr (read-form toks cur)]
    (if (= (peek-tag toks cur) (tag-end))
      ;; Last form: the trailing expression to evaluate. Its `Value` result is
      ;; projected to an i64 via `as-int` for the program's integer result (so a
      ;; program whose trailing expression denotes a string is a type error).
      (as-int (eval-sexpr form ENil fenv))
      ;; A leading form must be a definition; fold it into the function env.
      (if (is-define form)
        (run-forms-panic
          toks
          cur
          (FBind
            (define-name form)
            (define-params form)
            (define-body form)
            fenv))
        (begin
          (panic "eval: a non-final top-level form must be a (define ...)")
          0)))))

;; run-program: the public entry. Lex the whole SOURCE into one `(Array Token)`,
;; set a fresh cursor at index 0, then `run-forms` over every top-level form with
;; an initially empty function environment `FNil`. The result is the i64 the
;; trailing expression denotes after all definitions are in scope.
(define (run-program-panic [src : String]) : i64
  (let
    [toks : (Array Token) (lex src)]
    [cur : (Array i64) (make-array i64 1)]
    (begin
      (array-set! cur 0 0)
      (run-forms-panic toks cur FNil))))

(define (run-forms [toks : (Array Token)] [cur : (Array i64)] [fenv : FnEnv]) : ResultI64
  (let
    [form : Sexpr (read-form toks cur)]
    (if (= (peek-tag toks cur) (tag-end))
      (value-result-as-int-result (eval-sexpr-result form ENil fenv))
      (if (is-define form)
        (match (define-result form)
          [(OkFnDef name params body)
            (run-forms toks cur (FBind name params body fenv))]
          [(ErrFnDef message) (ErrI64 message)])
        (ErrI64 "eval: a non-final top-level form must be a (define ...)")))))

(define (run-program-result [src : String]) : ResultI64
  (let
    [toks : (Array Token) (lex src)]
    [cur : (Array i64) (make-array i64 1)]
    (begin
      (array-set! cur 0 0)
      (run-forms toks cur FNil))))

(define (eval-main [src : String]) : i64
  (match (run-program-result src)
    [(OkI64 n) n]
    [(ErrI64 message)
      (begin
        (print-error message)
        1)]))

(define (run-program [src : String]) : i64
  (if (= (arg-count) 2)
    (eval-main (arg 1))
    (eval-main src)))

;; --------------------------------------------------------------------------
;; main: the whole front end composed - lex, read MANY forms, interpret with
;; MULTI-ARGUMENT user functions, recursion, multi-binding `let`, string ops, the
;; `begin` sequencing form, FIRST-CLASS FUNCTIONS (`lambda` + CLOSURES), CONS
;; PAIRS / LINKED LISTS, the `pair?` / `null?` LIST PREDICATES that let an
;; interpreted recursive list algorithm test for the end of a list, and
;; HIGHER-ORDER `map` / `filter` over interpreted lists.
;; --------------------------------------------------------------------------
;; `(run-program "(define (pow b e) (if (< e 1) 1 (* b (pow b (- e 1)))))
;;                (define (second xs) (car (cdr xs)))
;;                (define (sum-list l)
;;                  (if (pair? l) (+ (car l) (sum-list (cdr l))) 0))
;;                (define (list-len l)
;;                  (if (null? l) 0 (+ 1 (list-len (cdr l)))))
;;                (define (map f l)
;;                  (if (pair? l) (cons (f (car l)) (map f (cdr l))) 0))
;;                (define (filter p l)
;;                  (if (pair? l) (if (p (car l)) ... (filter p (cdr l))) 0))
;;                (begin
;;                  (let ((s \"hello world\") ...)
;;                    (begin (print t) (print (+ ...)) (+ ...)))
;;                  (print ((lambda (x) (* x x)) 5))
;;                  (print (let ((n 10)) ((lambda (x) (+ x n)) 5)))
;;                  (let ((lst (list 1 2 3)) (p (cons 10 20)))
;;                    (begin (print (second lst)) (print (car p))
;;                           (print (pair? lst)) (print (null? lst))
;;                           (print (null? 0)) (print (list-len lst))
;;                           (print lst) (print (list 1 (list 2 3) 4))
;;                           (print p) (print (map ...)) (print (filter ...))
;;                           (sum-list (map ...))))))")`:
;;   - the program starts with a recursive TWO-parameter `define` of `pow`, the
;;     ONE-parameter `define` of `second` (just `(car (cdr xs))` - a list accessor
;;     built FROM the pair primitives), and two RECURSIVE LIST functions that the
;;     new predicates make possible: `sum-list` sums a list, recurring on `(cdr l)`
;;     only WHILE `(pair? l)` is true (the pair is the non-empty-list witness; the
;;     `0` NIL terminator is not a pair, so the recursion bottoms out at the base
;;     case `0`), and `list-len` counts the elements, recurring until `(null? l)`
;;     detects the `0` NIL sentinel. Then a trailing `(begin ...)` SPECIAL FORM
;;     with FOUR sub-expressions walked head-first by `eval-seq`.
;;   - FIRST arm (string/recursion witness): a MULTI-BINDING `let` rebuilds
;;     `"hello world"` from `substring` slices via nested `string-append`, appends
;;     `(int->string (pow 2 n))` to produce `"hello world32"`, prints that string,
;;     prints the parsed/string-equality sum `33`, and returns `33` - keeping
;;     runtime coverage for top-level calls, recursion, the string toolkit, and
;;     `begin`. STDOUT so far: `hello world3233\n`.
;;   - SECOND `((lambda (x) (* x x)) 5)`: a COMPUTED OPERATOR. The head is a
;;     `(lambda ...)` form, so it falls through to the `(SCons head rest)` arm;
;;     evaluating it yields a `(VClosure (x) (* x x) <env>)` that `apply-value`
;;     applies to `5` -> `(VInt 25)`. `(print 25)` writes `25\n`.
;;   - THIRD `(let ((n 10)) ((lambda (x) (+ x n)) 5))`: a CLOSURE OVER A FREE
;;     VARIABLE. The lambda CAPTURES `n -> 10`; applying it to `5` binds `x -> 5`
;;     onto the captured env so `(+ x n)` -> `(VInt 15)`. `(print 15)` writes
;;     `15\n` - the load-bearing closure-capture proof.
;;   - FOURTH (the LIST-CONSTRUCTOR / RECURSIVE-LIST witness): `lst` is the
;;     3-element singly-linked list built by the VARIADIC `(list 1 2 3)` SPECIAL
;;     FORM - which denotes exactly the right-nested chain
;;     `(cons 1 (cons 2 (cons 3 0)))` of `(VPair ...)` cells terminated by the `0`
;;     NIL sentinel - and `p` is the heterogeneous pair `(cons 10 20)`. The inner
;;     `begin` prints the list's second element via `(second lst)` =
;;     `(car (cdr lst))` (`2\n`), the pair's car `10\n`, then EXERCISES THE
;;     PREDICATES on the `list`-built chain: `(pair? lst)` is `1\n` (a non-empty
;;     list IS a pair), `(null? lst)` is `0\n` (it is not the NIL terminator),
;;     `(null? 0)` is `1\n` (the `0` sentinel IS nil), and the recursive
;;     `(list-len lst)` walks the chain to `3\n` - so the `(list ...)` constructor
;;     builds a chain indistinguishable from a nested `cons` literal to every list
;;     operation. THEN the new RECURSIVE LIST PRINTER: `(print lst)` renders the
;;     proper 3-element list as `(1 2 3)` (no newline), `(print (list 1 (list 2 3)
;;     4))` renders a NESTED list as `(1 (2 3) 4)` (the inner pair element recurses
;;     parenthesised), and `(print p)` renders the IMPROPER pair `(cons 10 20)` in
;;     DOTTED-PAIR notation as `(10 . 20)`, while `(print (cons 1 (cons 2 3)))`
;;     renders the longer improper list `(1 2 . 3)` - every proper-prefix element
;;     printed normally and only the final non-nil cdr `3` in dotted form.
;;     THEN the HIGHER-ORDER showcase, the payoff of closure-valued PARAMETERS: a
;;     define'd function takes a closure as a parameter and CALLS it (`(f (car l))`
;;     where `f` is bound to a `VClosure`, routed through `apply-value` because the
;;     call head resolves to a value-env binding rather than an `fenv` name).
;;     `(map (lambda (x) (* x x)) (list 1 2 3 4))` builds the squared list, printed
;;     by the recursive list printer as `(1 4 9 16)`, and
;;     `(filter (lambda (x) (< x 3)) (list 1 2 3 4))` keeps the elements below 3,
;;     printed as `(1 2)` - idiomatic functional programs composing closures, lists,
;;     recursion, and list-printing end to end. The arm then denotes the UNPRINTED
;;     `(sum-list (map (lambda (x) (* x x)) (list 1 2 3 4)))` - a NUMERIC witness
;;     that map's result is a real list `sum-list` can walk = `1 + 4 + 9 + 16` =
;;     `(VInt 30)`.
;;   - the outer `begin` returns the LAST arm, `(VInt 30)`, so the whole program
;;     denotes `30`. STDOUT is
;;     `hello world3233\n25\n15\n2\n10\n1\n0\n1\n3\n(1 2 3)(1 (2 3) 4)(10 . 20)(1 2 . 3)(1 4 9 16)(1 2)`;
;;     printing to stdout escapes the mod-256 exit-code ceiling, and the exit code
;;     is `30`.
;; This program proves the evaluator now has FIRST-CLASS FUNCTIONS - a `lambda`
;; special form building a `(VClosure params body captured-env)`, applied as a
;; computed operator or a closure-valued variable, with true CLOSURE capture via
;; `bind-args-onto` - CONS PAIRS / LINKED LISTS - `cons` builds a `(VPair ...)`,
;; `car` / `cdr` project it, and a right-nested chain of pairs terminated by `0`
;; (NIL) is a singly-linked list, now also buildable in one form by the VARIADIC
;; `(list e1 ... en)` SPECIAL FORM and PRINTABLE as a list `(e1 e2 ... en)`
;; via the recursive `print-value` walk (nesting parenthesised; an improper final
;; cdr rendered in dotted-pair form `(a . b)`) - the `pair?` / `null?` LIST
;; PREDICATES that let an interpreted
;; program write RECURSIVE LIST ALGORITHMS: `sum-list` and `list-len` recur on
;; `(cdr l)` and terminate by testing the structure of the value (a pair = more
;; list, the `0` NIL sentinel = done) - AND, the capstone, HIGHER-ORDER FUNCTIONS:
;; `map` and `filter` are define'd functions whose FIRST PARAMETER is a closure they
;; CALL on each element (`(f (car l))` / `(p (car l))`). This works because a
;; symbol-head call probes the value env first (`env-has`) and, finding the
;; parameter bound to a `VClosure`, applies it via `apply-value` rather than
;; treating the head as an `fenv` function name - the dispatch rule that makes
;; closures first-class ARGUMENTS, not just first-class values. So the interpreter
;; runs idiomatic functional programs: `(map (lambda (x) (* x x)) (list 1 2 3 4))`
;; -> `(1 4 9 16)`, composing closures, pairs, the `list` constructor, recursion,
;; and list-printing. `Value` and `Env` are mutually recursive enums (a
;; `VClosure` carries an `Env`, an `EBind` carries a `Value`), each pointer-sized so
;; the layout stays finite. Improper lists now render in DOTTED-PAIR notation
;; `(a . b)` via `print-list-tail` (a non-nil final cdr). (Deferred: variadic
;; user-function arity; string-literal escapes; a dedicated nil variant.)
(define (main) : i64
  (run-program
    "(define (pow b e) (if (< e 1) 1 (* b (pow b (- e 1))))) (define (second xs) (car (cdr xs))) (define (sum-list l) (if (pair? l) (+ (car l) (sum-list (cdr l))) 0)) (define (list-len l) (if (null? l) 0 (+ 1 (list-len (cdr l))))) (define (map f l) (if (pair? l) (cons (f (car l)) (map f (cdr l))) 0)) (define (filter p l) (if (pair? l) (if (p (car l)) (cons (car l) (filter p (cdr l))) (filter p (cdr l))) 0)) (begin (let ((s \"hello world\") (h (substring s 0 5)) (w (substring s 6 5)) (n (string-length h)) (g (string-append h (string-append \" \" w))) (t (string-append g (int->string (pow 2 n))))) (begin (print t) (print (+ (string->int (substring t 11 2)) (string-eq g s))) (+ (string->int (substring t 11 2)) (string-eq g s)))) (print ((lambda (x) (* x x)) 5)) (print (let ((n 10)) ((lambda (x) (+ x n)) 5))) (let ((lst (list 1 2 3)) (p (cons 10 20))) (begin (print (second lst)) (print (car p)) (print (pair? lst)) (print (null? lst)) (print (null? 0)) (print (list-len lst)) (print lst) (print (list 1 (list 2 3) 4)) (print p) (print (cons 1 (cons 2 3))) (print (map (lambda (x) (* x x)) (list 1 2 3 4))) (print (filter (lambda (x) (< x 3)) (list 1 2 3 4))) (sum-list (map (lambda (x) (* x x)) (list 1 2 3 4))))))"))