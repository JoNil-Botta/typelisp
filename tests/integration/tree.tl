; Recursive enum payloads (refs #13/#27): a tree-shaped expression AST.

; `EAdd` carries two `Expr` children, each represented as an 8-byte heap

; pointer, so the layout is finite. Building the tree heap-allocates every

; node (`mk` returns an `Expr`, so all constructors escape via the return and

; are promoted onto the heap), and a recursive `eval` folds it. This is the

; keystone that lets a TypeLisp compiler build a real Expr tree.

(defenum Expr
  (ENum i64)
  (EAdd Expr Expr))

; Build (1 + 2) as a heap-allocated tree. Returning the `EAdd` node promotes

; all three nodes (EAdd + the two ENum leaves) onto the heap.

(define (mk) : Expr
  (EAdd (ENum 1) (ENum 2)))

; Recursively fold the tree to an integer. A bound recursive payload (`l`/`r`)

; is a pointer to the child enum, passed straight back into `eval`.

(define (eval [e : Expr]) : i64
  (match e
    [(ENum n) n]
    [(EAdd l r) (+ (eval l) (eval r))]))

(define (main) : i64
  (eval (mk)))