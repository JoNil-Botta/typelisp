;; nested_eval.tl - end-to-end proof of NESTED PATTERN MATCHING (#41).
;;
;; A tiny tree-walking evaluator over a boxed recursive `Sexpr` list spine that
;; dispatches a call form on its operator symbol. The point of this example is
;; the SCons arm: it destructures TWO enum layers at once with a single nested
;; pattern
;;
;;     [(SCons (ASym name) rest) ...]
;;
;; binding `name : String` (the operator symbol, projected out of the nested
;; `ASym`) and `rest : (Box Sexpr)` (the argument spine) in one `match`. Before
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
(import "stdlib/io.tl")

(defenum SexprAtom
  (AInt i64)
  (ASym String)
  (AList (Box Sexpr)))

(defenum Sexpr
  (SNil)
  (SCons SexprAtom (Box Sexpr)))

;; sexpr-head ("car") / sexpr-tail ("cdr"): argument-spine projections. These
;; remain single-level (the spine is a flat cons list); the symbol projection
;; that USED to be a third helper is now the nested pattern in `eval-sexpr`.
(define (sexpr-head [s : Sexpr]) : SexprAtom
  (match s
    [(SCons h _) h]
    [_
      (begin
        (panic "eval: car of a non-cons")
        (AInt 0))]))

(define (sexpr-tail [s : Sexpr]) : Sexpr
  (match s
    [(SCons _ t) (box-get t)]
    [_
      (begin
        (panic "eval: cdr of a non-cons")
        SNil)]))

(define (eval-atom [a : SexprAtom]) : i64
  (match a
    [(AInt n) n]
    [(AList nested) (eval-sexpr (box-get nested))]
    [_
      (begin
        (panic "eval: not an evaluable atom")
        0)]))

;; eval-sexpr: the tree-walking interpreter. The SCons arm uses the nested
;; pattern to bind the operator symbol `name` directly from the head's `ASym`.
(define (eval-sexpr [s : Sexpr]) : i64
  (match s
    ;; Nested pattern: head must itself be `(ASym name)`. Binds `name : String`
    ;; (one level down) and `rest : (Box Sexpr)` together.
    [(SCons (ASym name) rest)
      (let
        [args : Sexpr (box-get rest)]
        [arg1 : SexprAtom (sexpr-head args)]
        [arg2 : SexprAtom (sexpr-head (sexpr-tail args))]
        [a : i64 (eval-atom arg1)]
        [b : i64 (eval-atom arg2)]
        (cond
          [(string-eq name "+") (+ a b)]
          [(string-eq name "-") (- a b)]
          [(string-eq name "*") (* a b)]
          [(string-eq name "/") (/ a b)]
          [else
            (begin
              (panic "eval: unknown operator")
              0)]))]
    ;; Any other shape (bare symbol, empty list, non-symbol operator head) is
    ;; not an evaluable call: the nested SSym above did not match, so we land
    ;; here.
    [_
      (begin
        (panic "eval: not an evaluable expression")
        0)]))

;; Build `(+ 1 (* 2 3))` as an Sexpr tree.
(define (main) : i64
  (let
    [inner : Sexpr
      (SCons
        (ASym "*")
        (box (SCons (AInt 2) (box (SCons (AInt 3) (box SNil))))))]
    [prog : Sexpr
      (SCons
        (ASym "+")
        (box (SCons (AInt 1) (box (SCons (AList (box inner)) (box SNil))))))]
    (eval-sexpr prog)))