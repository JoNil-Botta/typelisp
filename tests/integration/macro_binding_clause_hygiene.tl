;; A binder written in a macro template as a nested binding macro's clause is
;; hygienic (SPEC section 3.7.2): caller syntax spliced under it keeps its own
;; binding. A binder name the caller supplies still binds as written.
(import stdlib.comptime)
(import stdlib.iterator)

;; The #9671 reproducer: the caller's `i` names the outer `let`, not the loop.
(defmacro (any-step [p : Expr]) : bool
  `(let
    [found false]
    (for [i (iterator.range 0 4)]
      (if ,p
        (set! found true)
        unit))
    found))

;; Template references to the template binder still see the loop binder.
(defmacro (sum-below [limit : Expr]) : i64
  `(let
    [total : i64 0]
    (for [i (iterator.range 0 ,limit)]
      (+= total i))
    total))

;; A template `let` and a nested template `for` reuse one name; the inner one
;; shadows the outer, and neither captures the caller's `i`.
(defmacro (shadowed-step [p : Expr]) : i64
  `(let
    [i : i64 100]
    [hits : i64 0]
    (for [i (iterator.range 0 3)]
      (if ,p
        (+= hits (+ i 1))
        unit))
    (+ hits i)))

;; Zipped clauses: each template binder is hygienic.
(defmacro (zip-count [p : Expr]) : i64
  `(let
    [n : i64 0]
    (for [i (iterator.range 0 4)]
      [j (iterator.range 10 14)]
      (if ,p
        (+= n (- j i))
        unit))
    n))

;; A user binding macro other than `for`: its clause binder is the same kind.
(defmacro (bind-one [binding : ExprBindingClause] [body : Expr]) : i64
  (comptime.expr-let-scope
    (comptime.expr-binding-clause-name binding)
    (comptime.expr-binding-clause-init binding)
    body))

(defmacro (bind-plus [p : Expr]) : i64
  `(bind-one [x (cast 40 : i64)] (+ x ,p)))

;; Nested expansion: a template-written clause of a macro that itself expands
;; to `for`.
(defmacro (count-if [p : Expr]) : i64
  `(let
    [n : i64 0]
    (for [k (iterator.range 0 5)]
      (if ,p
        (+= n 1)
        unit))
    n))

(defmacro (outer-count [p : Expr]) : i64
  `(let
    [k : i64 7]
    (+ (count-if ,p) k)))

;; Intentional capture: the caller names the binder, so its body sees it.
(defmacro (each [name : Expr] [source : Expr] [body : Expr]) : unit
  `(for [,name ,source]
    ,body))

;; The stdlib clause macros keep the caller's binder.
(defmacro (has-big [p : Expr]) : bool
  `(any? [i (iterator.range 0 4)]
    ,p))

;; A user binding-prefix macro, signature `[ExprBindingClause ...] [Expr ...]`
;; like `for`, whose bodies expansion defers under its binders: the template's
;; clause binder is hygienic here as well.
(defmacro (each-clause [bindings : ExprBindingClause ...] [body : Expr ...]) : unit
  (let
    [binding : comptime.ExprBindingClause
      (comptime.expr-binding-clause-list-nth bindings 0)]
    [name : comptime.Expr
      (comptime.expr-var (comptime.expr-binding-clause-name binding))]
    [source : comptime.Expr (comptime.expr-binding-clause-init binding)]
    `(for [,name ,source]
      ,@body)))

(defmacro (prefix-step [p : Expr]) : bool
  `(let
    [found false]
    (each-clause
      [i (iterator.range 0 4)]
      (if ,p
        (set! found true)
        unit))
    found))

;; `cond` arms keep their tests and `else` heads.
(defmacro (classify [v : Expr]) : i64
  `(let
    [x : i64 ,v]
    (cond [(< x 0) 1] [(= x 0) 2] [else 3])))

(define (main) : i64
  (let
    [i : i64 0]
    [k : i64 1]
    [x : i64 2]
    [seen : i64 0]
    [_ : unit (each item (iterator.range 0 4) (+= seen item))]
    (if (and
      (not (any-step (> i 2)))
      (= (sum-below 4) 6)
      ;; The caller's `i` is 0, so every step adds its loop index plus one,
      ;; then the template's outer `i` (100) is added.
      (= (shadowed-step (= i 0)) 106)
      (= (zip-count (= i 0)) 40)
      (= (bind-plus x) 42)
      ;; The caller's `k` is 1, so all five steps count; the template's
      ;; outer `k` adds 7.
      (= (outer-count (= k 1)) 12)
      (= seen 6)
      (not (prefix-step (> i 2)))
      (not (has-big (> i 2)))
      (has-big (> k 0))
      (= (classify -5) 1)
      (= (classify 0) 2)
      (= (classify 9) 3))
      42
      1)))