; Recursive enum payloads (refs #13/#27): a tree-shaped expression AST.
; `EAdd` carries two explicitly boxed `Expr` children, so the layout is finite.
; Building the tree allocates boxes for both child nodes, and a recursive `eval`
; folds it. This is the keystone that lets a TypeLisp compiler build a real Expr
; tree.
(defenum Expr
  (ENum i64)
  (EAdd (Box Expr) (Box Expr)))

; Build (1 + 2) as a boxed tree.
(define (mk) : Expr
  (EAdd (box (ENum 1)) (box (ENum 2))))

; Recursively fold the tree to an integer.
(define (eval [e : (& e Expr)]) : i64
  (match e
    [(ENum n) (deref n)]
    [(EAdd l r)
      (+ (eval (& (deref (deref l)))) (eval (& (deref (deref r)))))]))

(define (main) : i64
  (let
    [tree : Expr (mk)]
    (eval (& tree))))
