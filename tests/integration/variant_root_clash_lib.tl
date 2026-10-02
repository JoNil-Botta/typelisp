;; Builds its own `Cast` bare in an argument position whose expected type is
;; `Expr`; the entry module of variant_root_clash.tl declares another `Cast`.
;; `Mode` also declares `Other`, so typecheck qualifies the bare `Other` that
;; ends `settle`'s `in-arena` body, and lowering types that `Expr.Other`
;; identity.
(import stdlib.arena)

(defenum Expr
  (Lit i64)
  (Other)
  (Cast i64 i64))

(defenum Mode
  (Other)
  (Plain))

(define (eval [expr : Expr]) : i64
  (match expr
    [(Cast a b) (+ a b)]
    [(Lit n) n]
    [Other 7]))

(define (make [a : i64] [b : i64]) : i64
  (eval (Cast a b)))

(define (settle [owner : arena.Arena] [n : i64]) : Expr
  (in-arena
    owner
    (let
      [doubled : i64 (* n 2)]
      (begin
        (eval (Lit doubled))
        Other))))

(define (mode-score [mode : Mode]) : i64
  (match mode
    [Other 0]
    [Plain 0]))