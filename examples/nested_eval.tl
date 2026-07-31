;; nested_eval.tl - end-to-end proof of NESTED PATTERN MATCHING (#41).
;;
;; A tiny tree-walking evaluator over the recursive `Sexpr` AST that dispatches
;; a call form on its operator symbol. Calls have exactly two arguments, stored
;; in a fixed array. The
;; `Call` arm destructures TWO enum layers at once with a single nested pattern
;;
;;     [(Sexpr.Call (SexprAtom.Sym name) args) ...]
;;
;; binding `name : String` (the operator symbol, projected out of the nested
;; `SexprAtom.Sym`) and `args : (Array SexprAtom 2)` in one `match`. Before
;; nested patterns this required a separate single-level projection helper
;; (`sexpr-sym`, a `match` that pulled the symbol text out of the head and
;; panicked on the wrong shape); the nested pattern folds that projection into
;; the dispatch itself. A non-symbol operator simply does not match the nested
;; `SexprAtom.Sym`, so control falls through to the next arm exactly like a flat tag
;; mismatch - the same soundness as before, now without the helper.
;;
;; The tree is built inline (no reader dependency) so this example is
;; self-contained. `main` evaluates `(+ 1 (* 2 3))`, prints, and returns 7: the inner
;; `(* 2 3)` is the nested argument, so it is evaluated first (to 6), then the
;; outer `(+ 1 6)` to 7 - the result depends on the whole nested shape.
(import stdlib.io)
(import stdlib.string)

(defenum SexprAtom
  (Int i64)
  (Sym String)
  (List (Box Sexpr)))

(defenum Sexpr
  (Call SexprAtom (Array SexprAtom 2)))

(define (eval-atom [a : SexprAtom]) : i64
  (match a
    [(SexprAtom.Int n) n]
    [(SexprAtom.List nested) (eval-sexpr (box-get nested))]
    [_ (io.panic "eval: not an evaluable atom")]))

;; eval-sexpr: the tree-walking interpreter. The `Call` arm uses the nested
;; pattern to bind the operator symbol `name` directly from the head's `Sym`.
(define (eval-sexpr [s : Sexpr]) : i64
  (match s
    ;; Nested pattern: the operator must itself be `(SexprAtom.Sym name)`.
    ;; Binds `name : String` and the dense argument sequence together.
    [(Sexpr.Call (SexprAtom.Sym name) args)
      (let
        [arg1 : SexprAtom (array-ref args 0)]
        [arg2 : SexprAtom (array-ref args 1)]
        [a : i64 (eval-atom arg1)]
        [b : i64 (eval-atom arg2)]
        (cond
          [(string.eq name "+") (+ a b)]
          [(string.eq name "-") (- a b)]
          [(string.eq name "*") (* a b)]
          [(string.eq name "/") (/ a b)]
          [else (io.panic "eval: unknown operator")]))]
    ;; Any other shape (bare symbol, empty list, non-symbol operator head) is
    ;; not an evaluable call: the nested `SexprAtom.Sym` above did not match, so we land
    ;; here.
    [_ (io.panic "eval: not an evaluable expression")]))

;; Build `(+ 1 (* 2 3))` as a recursive expression tree whose call arguments
;; are fixed two-element arrays.
(define (main) : i64
  (let
    [inner : Sexpr
      (Sexpr.Call
        (SexprAtom.Sym "*")
        (array (SexprAtom.Int 2) (SexprAtom.Int 3)))]
    [prog : Sexpr
      (Sexpr.Call
        (SexprAtom.Sym "+")
        (array (SexprAtom.Int 1) (SexprAtom.List (box inner))))]
    [result : i64 (eval-sexpr prog)]
    (begin
      (io.print-string "nested evaluator result: ")
      (io.print result)
      result)))