;; nested_eval.tl - end-to-end proof of NESTED PATTERN MATCHING (#41).

;;

;; A tiny tree-walking evaluator over the recursive `Sexpr` AST that dispatches

;; a call form on its operator symbol. The point of this example is the SCons

;; arm: it destructures TWO enum layers at once with a single nested pattern

;;

;;     [(SCons (SSym name) rest) ...]

;;

;; binding `name : String` (the operator symbol, projected out of the nested

;; `SSym`) and `rest : Sexpr` (the argument spine) in one `match`. Before

;; nested patterns this required a separate single-level projection helper

;; (`sexpr-sym`, a `match` that pulled the symbol text out of the head and

;; panicked on the wrong shape); the nested pattern folds that projection into

;; the dispatch itself. A non-symbol operator simply does not match the nested

;; `SSym`, so control falls through to the next arm exactly like a flat tag

;; mismatch - the same soundness as before, now without the helper.

;;

;; The tree is built inline (no reader dependency) so this example is

;; self-contained. `main` evaluates `(+ 1 (* 2 3))` and returns 7: the inner

;; `(* 2 3)` is the nested argument, so it is evaluated first (to 6), then the

;; outer `(+ 1 6)` to 7 - the result depends on the whole nested shape.

(defenum Sexpr
  (SInt i64)
  (SSym String)
  (SNil)
  (SCons Sexpr Sexpr))

;; sexpr-head ("car") / sexpr-tail ("cdr"): argument-spine projections. These

;; remain single-level (the spine is a flat cons list); the symbol projection

;; that USED to be a third helper is now the nested pattern in `eval-sexpr`.

(define (sexpr-head [s : Sexpr]) : Sexpr
  (match s
    [(SCons h _) h]
    [_
      (begin
        (panic "eval: car of a non-cons")
        SNil)]))

(define (sexpr-tail [s : Sexpr]) : Sexpr
  (match s
    [(SCons _ t) t]
    [_
      (begin
        (panic "eval: cdr of a non-cons")
        SNil)]))

;; eval-sexpr: the tree-walking interpreter. The SCons arm uses the nested

;; pattern to bind the operator symbol `name` directly from the head's `SSym`.

(define (eval-sexpr [s : Sexpr]) : i64
  (match s
    [(SInt n) n]
    ;; Nested pattern: head must itself be `(SSym name)`. Binds `name : String`
    ;; (one level down) and `rest : Sexpr` together.
    [(SCons (SSym name) rest)
      (let (
        [arg1 : Sexpr (sexpr-head rest)]
        [arg2 : Sexpr (sexpr-head (sexpr-tail rest))])
        (let (
          [a : i64 (eval-sexpr arg1)]
          [b : i64 (eval-sexpr arg2)])
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
                    0)))))))]
    ;; Any other shape (bare symbol, empty list, non-symbol operator head) is
    ;; not an evaluable call: the nested SSym above did not match, so we land
    ;; here.
    [_
      (begin
        (panic "eval: not an evaluable expression")
        0)]))

;; Build `(+ 1 (* 2 3))` as an Sexpr tree:

;;   (SCons (SSym "+")

;;     (SCons (SInt 1)

;;       (SCons (SCons (SSym "*") (SCons (SInt 2) (SCons (SInt 3) SNil)))

;;         SNil)))

(define (main) : i64
  (let ([inner : Sexpr
    (SCons (SSym "*") (SCons (SInt 2) (SCons (SInt 3) SNil)))])
    (let ([prog : Sexpr (SCons (SSym "+") (SCons (SInt 1) (SCons inner SNil)))])
      (eval-sexpr prog))))