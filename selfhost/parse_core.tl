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

(define (is-binary-op [op : String]) : bool
  (if (string-eq op "+")
      true
      (if (string-eq op "-")
          true
          (if (string-eq op "*")
              true
              (if (string-eq op "<")
                  true
                  (if (string-eq op "=")
                      true
                      (if (string-eq op "<=")
                          true
                          (if (string-eq op ">")
                              true
                              (if (string-eq op ">=")
                                  true
                                  (string-eq op "!="))))))))))

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

(define (parse-begin [rest : Sexpr]) : Expr
  (match rest
    [(SNil) (begin
              (panic "parse: empty begin")
              (EInt 0))]
    [(SCons _ _) (EBegin (parse-args rest))]
    [_ (begin
         (panic "parse: malformed begin")
         (EInt 0))]))

(define (parse-args [s : Sexpr]) : ExprList
  (match s
    [(SNil) ELNil]
    [(SCons a d) (ELCons (parse a) (parse-args d))]
    [_ (begin
         (panic "parse: malformed argument list")
         ELNil)]))

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
                 (if (string-eq op "begin")
                     (parse-begin rest)
                     (if (is-binary-op op)
                         (parse-binary (parse-op op) rest)
                         (ECall op (parse-args rest)))))))]
    [_ (begin
         (panic "parse: malformed expression")
         (EInt 0))]))

(define (sexpr-head [s : Sexpr]) : Sexpr
  (match s
    [(SCons a _) a]
    [_ (begin
         (panic "parse: expected non-empty list")
         SNil)]))

(define (sexpr-tail [s : Sexpr]) : Sexpr
  (match s
    [(SCons _ d) d]
    [_ (begin
         (panic "parse: expected list tail")
         SNil)]))

(define (sexpr-expect-nil [s : Sexpr]) : unit
  (match s
    [(SNil) (print-string "")]
    [_ (panic "parse: expected end of list")]))

(define (parse-params [s : Sexpr]) : StrList
  (match s
    [(SNil) SLNil]
    [(SCons (SSym name) rest) (SLCons name (parse-params rest))]
    [_ (begin
         (panic "parse: malformed parameter list")
         SLNil)]))

(define (is-define-form [s : Sexpr]) : bool
  (match s
    [(SCons (SSym head) _) (string-eq head "define")]
    [_ false]))

(define (parse-item [s : Sexpr]) : Item
  (match s
    [(SCons (SSym head) rest)
     (if (string-eq head "define")
         (let ([header : Sexpr (sexpr-head rest)]
               [after-header : Sexpr (sexpr-tail rest)])
           (let ([body : Sexpr (sexpr-head after-header)]
                 [after-body : Sexpr (sexpr-tail after-header)])
             (begin
               (sexpr-expect-nil after-body)
               (match header
                 [(SCons (SSym name) params)
                  (IDefFn name (parse-params params) (parse body))]
                 [_ (begin
                      (panic "parse: malformed define header")
                      (IDefFn "" SLNil (EInt 0)))]))))
         (begin
           (panic "parse: expected define")
           (IDefFn "" SLNil (EInt 0))))]
    [_ (begin
         (panic "parse: malformed item")
         (IDefFn "" SLNil (EInt 0)))]))

(define (item-list-append-one [items : ItemList] [item : Item]) : ItemList
  (match items
    [(ILNil) (ILCons item ILNil)]
    [(ILCons head rest) (ILCons head (item-list-append-one rest item))]))

(define (parse-program-forms [toks : (Array Token)] [cur : (Array i64)] [defs : ItemList]) : ParsedProgram
  (let ([form : Sexpr (read-form toks cur)])
    (if (= (peek-tag toks cur) (tag-end))
        (if (is-define-form form)
            (begin
              (panic "parse: missing final expression")
              (PProgram defs (EInt 0)))
            (PProgram defs (parse form)))
        (if (is-define-form form)
            (parse-program-forms toks cur (item-list-append-one defs (parse-item form)))
            (begin
              (panic "parse: non-final form must be define")
              (PProgram defs (EInt 0)))))))

(define (parse-program [toks : (Array Token)]) : ParsedProgram
  (let ([cur : (Array i64) (make-array i64 1)])
    (begin
      (array-set! cur 0 0)
      (parse-program-forms toks cur ILNil))))
