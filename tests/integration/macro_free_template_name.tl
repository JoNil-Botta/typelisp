;; A free identifier in a macro template that names nothing at the definition
;; site does not bind a same-name caller local (SPEC section 3.7.2, #9681).
;; Names with a definition-site, builtin or prelude meaning resolve as before,
;; and a template binder handed to a nested binding macro still binds its own
;; references. Every function below has a caller local that shares a template
;; spelling.
(import stdlib.comptime)
(import stdlib.iterator)

;; A definition-site global wins over the caller's local.
(define offset : i64
  20)

(defmacro (plus-offset) : i64
  `(+ offset 1))

(define (definition-global) : i64
  (let
    [offset : i64 5]
    (- (+ offset (plus-offset)) offset)))

;; Builtins and prelude macros keep resolving with unrelated caller locals.
(defmacro (count-true [a : bool] [b : bool]) : i64
  `(let
    [n : i64 0]
    (when (and ,a ,b) (+= n 1))
    (when (or ,a ,b) (+= n 1))
    n))

(define (builtins-and-prelude) : i64
  (let
    [n : i64 100]
    (- (+ n (count-true true false)) n)))

;; Field-name operands read by spelling: a caller local of the same name does
;; not disturb `__tl-project-field`, `offset-of` or a `cond` `else` arm.
(defstruct Pair
  (left i64)
  (right i64))

(defmacro (pair-right [p : Expr]) : i64
  `(__tl-project-field ,p right))

(defmacro (right-offset) : i64
  `(comptime (offset-of (type Pair) right)))

(defmacro (pick [c : bool] [a : i64]) : i64
  `(cond [,c ,a] [else 2]))

(define (spelling-readers) : i64
  (let
    [right : i64 1000]
    [else : bool false]
    [p : Pair (Pair 3 4)]
    ;; 4 + 8 + 9: `else` names the arm, not the caller's local
    (- (+ right (pair-right p) (right-offset) (pick (not else) 9)) right)))

;; A template binder handed to a nested user binding macro through an `Expr`
;; operand binds its own references, even with a same-name caller local; the
;; caller's spliced syntax still names the caller's binding.
(defmacro (let-one [name : Expr] [value : Expr] [body : Expr]) : i64
  (match name
    [(comptime.Expr.Var binder) (comptime.expr-let-scope binder value body)]
    [_ (comptime.comptime-error "let-one expects a binder name")]))

(defmacro (offset-of-ten [p : Expr]) : i64
  `(let-one k (cast 10 : i64) (+ k ,p)))

(define (nested-binder) : i64
  (let
    [k : i64 1]
    ;; 10 + 1; a captured binder would give 10 + 10
    (offset-of-ten k)))

;; The same through an intermediate macro whose `Expr` parameter becomes a
;; `for` clause binder (signature-deferred body).
(defmacro (each [name : Expr] [limit : Expr] [body : Expr]) : unit
  `(for [,name (iterator.range 0 ,limit)]
    ,body))

(defmacro (sum-to [limit : Expr] [p : Expr]) : i64
  `(let
    [total : i64 0]
    (each i ,limit (+= total (+ i ,p)))
    total))

(define (each-for) : i64
  (let
    [i : i64 10]
    ;; (0+10) + (1+10) + (2+10); a captured binder would give 0 + 2 + 4
    (sum-to 3 i)))

;; A user binding-prefix macro (not `for`): its signature defers the body under
;; the clause binder. The template-written binder binds the template's `j`;
;; the caller's spliced `j` still names the caller's local.
(defmacro (bind-first [bindings : ExprBindingClause ...] [body : Expr ...]) : i64
  (let
    [clause : comptime.ExprBindingClause
      (comptime.expr-binding-clause-list-nth bindings 0)]
    (comptime.expr-let-scope
      (comptime.expr-binding-clause-name clause)
      (comptime.expr-binding-clause-init clause)
      (comptime.expr-list-nth body 0))))

(defmacro (plus-ten [p : Expr]) : i64
  `(bind-first [j (cast 10 : i64)] (+ j ,p)))

(define (binding-prefix) : i64
  (let
    [j : i64 3]
    ;; 10 + 3
    (plus-ten j)))

;; Without a same-name caller local, a free template name is unchanged.
(defmacro (plus-global-limit) : i64
  `(+ limit 1))

(define limit : i64
  6)

(define (no-caller-local) : i64
  (plus-global-limit))

(define (main) : i64
  (let
    [total
      : i64
      ;; 21 + 1 + 21 + 11 + 33 + 13 + 7
      (+
        (definition-global)
        (builtins-and-prelude)
        (spelling-readers)
        (nested-binder)
        (each-for)
        (binding-prefix)
        (no-caller-local))]
    (if (= total 107)
      42
      total)))