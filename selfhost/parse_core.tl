;; parse_core.tl - Main-less Sexpr -> Expr parser shared by selfhost drivers.
;;
;; The runnable `parse.tl` demo used to contain these definitions directly.
;; Keeping them here lets other drivers reuse the parser without importing a
;; second `main`.

(import "emit_core.tl")
(import "read.tl")

(define (parse-op [op : String]) : BinOp
  (if (string-eq op "+")
      (OpAdd)
      (if (string-eq op "-")
          (OpSub)
          (if (string-eq op "*")
              (OpMul)
              (if (string-eq op "<")
                  (OpLt)
                  (if (string-eq op "=")
                      (OpEq)
                      (if (string-eq op "<=")
                          (OpLe)
                          (if (string-eq op ">")
                              (OpGt)
                              (if (string-eq op ">=")
                                  (OpGe)
                                  (if (string-eq op "!=")
                                      (OpNe)
                                      (begin
                                        (panic "parse: unknown operator")
                                        (OpAdd))))))))))))

(define (parse-binary [op : BinOp] [rest : Sexpr]) : Expr
  (match rest
    [(SCons a (SCons b (SNil))) (EBin op (parse a) (parse b))]
    [_ (begin
         (panic "parse: malformed binary expression")
         (EInt 0))]))

(define (parse-let [rest : Sexpr]) : Expr
  (match rest
    [(SCons (SCons (SCons (SSym name) (SCons value (SNil))) (SNil))
            (SCons body (SNil)))
     (ELet name (parse value) (parse body))]
    [_ (begin
         (panic "parse: malformed let")
         (EInt 0))]))

(define (parse-if [rest : Sexpr]) : Expr
  (match rest
    [(SCons c (SCons t (SCons e (SNil))))
     (EIf (parse c) (parse t) (parse e))]
    [_ (begin
         (panic "parse: malformed if")
         (EInt 0))]))

(define (parse-print [rest : Sexpr]) : Expr
  (match rest
    [(SCons arg (SNil)) (EPrint (parse arg))]
    [_ (begin
         (panic "parse: malformed print")
         (EInt 0))]))

(define (parse [s : Sexpr]) : Expr
  (match s
    [(SInt n) (EInt n)]
    [(SSym name) (EVar name)]
    [(SStr s) (EStr s)]
    [(SCons (SSym op) rest)
     (if (string-eq op "let")
         (parse-let rest)
         (if (string-eq op "if")
             (parse-if rest)
             (if (string-eq op "print")
                 (parse-print rest)
                 (parse-binary (parse-op op) rest))))]
    [_ (begin
         (panic "parse: malformed expression")
         (EInt 0))]))
