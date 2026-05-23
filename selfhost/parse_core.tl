;; parse_core.tl - Main-less Sexpr -> Expr parser shared by selfhost drivers.
;;
;; The runnable `parse.tl` demo used to contain these definitions directly.
;; Keeping them here lets other drivers reuse the parser without importing a
;; second `main`.

(import "sym_i64_env.tl")
(import "emit_core.tl")
(import "read.tl")

(defenum ResultExprList
  (OkExprList ExprList)
  (ErrExprList String))

(defenum ResultStrList
  (OkStrList StrList)
  (ErrStrList String))

(defenum ResultItem
  (OkItem Item)
  (ErrItem String))

(defenum ResultSexpr
  (OkSexpr Sexpr)
  (ErrSexpr String))

(defenum ResultUnit
  (OkUnit)
  (ErrUnit String))

(define (parse-tag-call) : i64 0)
(define (parse-tag-let) : i64 1)
(define (parse-tag-if) : i64 2)
(define (parse-tag-while) : i64 3)
(define (parse-tag-print) : i64 4)
(define (parse-tag-set) : i64 5)
(define (parse-tag-begin) : i64 6)
(define (parse-tag-add) : i64 10)
(define (parse-tag-sub) : i64 11)
(define (parse-tag-mul) : i64 12)
(define (parse-tag-lt) : i64 13)
(define (parse-tag-eq) : i64 14)
(define (parse-tag-le) : i64 15)
(define (parse-tag-gt) : i64 16)
(define (parse-tag-ge) : i64 17)
(define (parse-tag-ne) : i64 18)

(define (parse-dispatch-env) : SymI64Env
  (let ([e0 : SymI64Env (sym-i64-empty)])
    (let ([e1 : SymI64Env (sym-i64-bind e0 "let" (parse-tag-let))])
      (let ([e2 : SymI64Env (sym-i64-bind e1 "if" (parse-tag-if))])
        (let ([e3 : SymI64Env (sym-i64-bind e2 "while" (parse-tag-while))])
          (let ([e4 : SymI64Env (sym-i64-bind e3 "print" (parse-tag-print))])
            (let ([e5 : SymI64Env (sym-i64-bind e4 "set!" (parse-tag-set))])
              (let ([e6 : SymI64Env (sym-i64-bind e5 "begin" (parse-tag-begin))])
                (let ([e7 : SymI64Env (sym-i64-bind e6 "+" (parse-tag-add))])
                  (let ([e8 : SymI64Env (sym-i64-bind e7 "-" (parse-tag-sub))])
                    (let ([e9 : SymI64Env (sym-i64-bind e8 "*" (parse-tag-mul))])
                      (let ([e10 : SymI64Env (sym-i64-bind e9 "<" (parse-tag-lt))])
                        (let ([e11 : SymI64Env (sym-i64-bind e10 "=" (parse-tag-eq))])
                          (let ([e12 : SymI64Env (sym-i64-bind e11 "<=" (parse-tag-le))])
                            (let ([e13 : SymI64Env (sym-i64-bind e12 ">" (parse-tag-gt))])
                              (let ([e14 : SymI64Env (sym-i64-bind e13 ">=" (parse-tag-ge))])
                                (sym-i64-bind e14 "!=" (parse-tag-ne))))))))))))))))))

(define (parse-dispatch-tag [op : String]) : i64
  (match (sym-i64-lookup (parse-dispatch-env) op)
    [(SomeI64 tag) tag]
    [(NoneI64) (parse-tag-call)]))

(define (parse-op-tag [tag : i64]) : BinOp
  (if (= tag (parse-tag-add))
      (OpAdd)
      (if (= tag (parse-tag-sub))
          (OpSub)
          (if (= tag (parse-tag-mul))
              (OpMul)
              (if (= tag (parse-tag-lt))
                  (OpLt)
                  (if (= tag (parse-tag-eq))
                      (OpEq)
                      (if (= tag (parse-tag-le))
                          (OpLe)
                          (if (= tag (parse-tag-gt))
                              (OpGt)
                              (if (= tag (parse-tag-ge))
                                  (OpGe)
                                  (if (= tag (parse-tag-ne))
                                      (OpNe)
                                      (begin
                                        (panic "parse: unknown operator")
                                        (OpAdd))))))))))))

(define (parse-op [op : String]) : BinOp
  (parse-op-tag (parse-dispatch-tag op)))

(define (is-binary-tag [tag : i64]) : bool
  (if (= tag (parse-tag-add))
      true
      (if (= tag (parse-tag-sub))
          true
          (if (= tag (parse-tag-mul))
              true
              (if (= tag (parse-tag-lt))
                  true
                  (if (= tag (parse-tag-eq))
                      true
                      (if (= tag (parse-tag-le))
                          true
                          (if (= tag (parse-tag-gt))
                              true
                              (if (= tag (parse-tag-ge))
                                  true
                                  (= tag (parse-tag-ne)))))))))))

(define (is-binary-op [op : String]) : bool
  (is-binary-tag (parse-dispatch-tag op)))

(define (parse-binary [op : BinOp] [rest : Sexpr]) : ResultExpr
  (match rest
    [(SCons a (SCons b (SNil)))
     (match (parse a)
       [(OkExpr lhs)
        (match (parse b)
          [(OkExpr rhs) (OkExpr (EBin op lhs rhs))]
          [(ErrExpr message) (ErrExpr message)])]
       [(ErrExpr message) (ErrExpr message)])]
    [_ (ErrExpr "parse: malformed binary expression")]))

;; parse-let: single- or multi-binding let, desugared into nested ELet nodes
;; so later bindings can see earlier ones (sequential let* semantics).
(define (parse-let-bindings [bindings : Sexpr] [body : Expr]) : ResultExpr
  (match bindings
    [(SNil) (OkExpr body)]
    [(SCons (SCons (SSym name) (SCons value (SNil))) rest)
     (match (parse value)
       [(OkExpr parsed-value)
        (match (parse-let-bindings rest body)
          [(OkExpr parsed-rest) (OkExpr (ELet name parsed-value parsed-rest))]
          [(ErrExpr message) (ErrExpr message)])]
       [(ErrExpr message) (ErrExpr message)])]
    [_ (ErrExpr "parse: malformed let binding")]))

(define (parse-let [rest : Sexpr]) : ResultExpr
  (match rest
    [(SCons bindings (SCons body (SNil)))
     (match (parse body)
       [(OkExpr parsed-body) (parse-let-bindings bindings parsed-body)]
       [(ErrExpr message) (ErrExpr message)])]
    [_ (ErrExpr "parse: malformed let")]))

(define (parse-set [rest : Sexpr]) : ResultExpr
  (match rest
    [(SCons (SSym name) (SCons value (SNil)))
     (match (parse value)
       [(OkExpr parsed-value) (OkExpr (ESet name parsed-value))]
       [(ErrExpr message) (ErrExpr message)])]
    [_ (ErrExpr "parse: malformed set!")]))

(define (parse-if [rest : Sexpr]) : ResultExpr
  (match rest
    [(SCons c (SCons t (SCons e (SNil))))
     (match (parse c)
       [(OkExpr parsed-c)
        (match (parse t)
          [(OkExpr parsed-t)
           (match (parse e)
             [(OkExpr parsed-e) (OkExpr (EIf parsed-c parsed-t parsed-e))]
             [(ErrExpr message) (ErrExpr message)])]
          [(ErrExpr message) (ErrExpr message)])]
       [(ErrExpr message) (ErrExpr message)])]
    [_ (ErrExpr "parse: malformed if")]))

(define (parse-while [rest : Sexpr]) : ResultExpr
  (match rest
    [(SCons c (SCons body (SNil)))
     (match (parse c)
       [(OkExpr parsed-c)
        (match (parse body)
          [(OkExpr parsed-body) (OkExpr (EWhile parsed-c parsed-body))]
          [(ErrExpr message) (ErrExpr message)])]
       [(ErrExpr message) (ErrExpr message)])]
    [_ (ErrExpr "parse: malformed while")]))

(define (parse-print [rest : Sexpr]) : ResultExpr
  (match rest
    [(SCons arg (SNil))
     (match (parse arg)
       [(OkExpr parsed-arg) (OkExpr (EPrint parsed-arg))]
       [(ErrExpr message) (ErrExpr message)])]
    [_ (ErrExpr "parse: malformed print")]))

(define (parse-begin [rest : Sexpr]) : ResultExpr
  (match rest
    [(SNil) (ErrExpr "parse: empty begin")]
    [(SCons _ _)
     (match (parse-args rest)
       [(OkExprList args) (OkExpr (EBegin args))]
       [(ErrExprList message) (ErrExpr message)])]
    [_ (ErrExpr "parse: malformed begin")]))

(define (parse-args [s : Sexpr]) : ResultExprList
  (match s
    [(SNil) (OkExprList ELNil)]
    [(SCons a d)
     (match (parse a)
       [(OkExpr parsed-a)
        (match (parse-args d)
          [(OkExprList parsed-d) (OkExprList (ELCons parsed-a parsed-d))]
          [(ErrExprList message) (ErrExprList message)])]
       [(ErrExpr message) (ErrExprList message)])]
    [_ (ErrExprList "parse: malformed argument list")]))

(define (parse [s : Sexpr]) : ResultExpr
  (match s
    [(SInt n) (OkExpr (EInt n))]
    [(SSym name) (OkExpr (EVar name))]
    [(SStr s) (OkExpr (EStr s))]
    [(SCons (SSym op) rest)
     (let ([tag : i64 (parse-dispatch-tag op)])
       (if (= tag (parse-tag-let))
           (parse-let rest)
           (if (= tag (parse-tag-if))
               (parse-if rest)
               (if (= tag (parse-tag-while))
                   (parse-while rest)
                   (if (= tag (parse-tag-print))
                       (parse-print rest)
                       (if (= tag (parse-tag-set))
                           (parse-set rest)
                           (if (= tag (parse-tag-begin))
                               (parse-begin rest)
                               (if (is-binary-tag tag)
                                    (parse-binary (parse-op-tag tag) rest)
                                    (match (parse-args rest)
                                      [(OkExprList args) (OkExpr (ECall op args))]
                                      [(ErrExprList message) (ErrExpr message)])))))))))]
    [_ (ErrExpr "parse: malformed expression")]))

(define (sexpr-head [s : Sexpr]) : ResultSexpr
  (match s
    [(SCons a _) (OkSexpr a)]
    [_ (ErrSexpr "parse: expected non-empty list")]))

(define (sexpr-tail [s : Sexpr]) : ResultSexpr
  (match s
    [(SCons _ d) (OkSexpr d)]
    [_ (ErrSexpr "parse: expected list tail")]))

(define (sexpr-expect-nil [s : Sexpr]) : ResultUnit
  (match s
    [(SNil) OkUnit]
    [_ (ErrUnit "parse: expected end of list")]))

(define (parse-params [s : Sexpr]) : ResultStrList
  (match s
    [(SNil) (OkStrList SLNil)]
    [(SCons (SSym name) rest)
     (match (parse-params rest)
       [(OkStrList parsed-rest) (OkStrList (SLCons name parsed-rest))]
       [(ErrStrList message) (ErrStrList message)])]
    [_ (ErrStrList "parse: malformed parameter list")]))

(define (is-define-form [s : Sexpr]) : bool
  (match s
    [(SCons (SSym head) _) (string-eq head "define")]
    [_ false]))

(define (parse-item [s : Sexpr]) : ResultItem
  (match s
    [(SCons (SSym head) rest)
     (if (string-eq head "define")
         (match (sexpr-head rest)
           [(OkSexpr header)
            (match (sexpr-tail rest)
              [(OkSexpr after-header)
               (match (sexpr-head after-header)
                 [(OkSexpr body)
                  (match (sexpr-tail after-header)
                    [(OkSexpr after-body)
                     (match (sexpr-expect-nil after-body)
                       [OkUnit
                        (match header
                          [(SCons (SSym name) params)
                           (match (parse-params params)
                             [(OkStrList parsed-params)
                              (match (parse body)
                                [(OkExpr parsed-body)
                                 (OkItem (IDefFn name parsed-params parsed-body))]
                                [(ErrExpr message) (ErrItem message)])]
                             [(ErrStrList message) (ErrItem message)])]
                          [_ (ErrItem "parse: malformed define header")])]
                       [(ErrUnit message) (ErrItem message)])]
                    [(ErrSexpr message) (ErrItem message)])]
                 [(ErrSexpr message) (ErrItem message)])]
              [(ErrSexpr message) (ErrItem message)])]
           [(ErrSexpr message) (ErrItem message)])
         (ErrItem "parse: expected define"))]
    [_ (ErrItem "parse: malformed item")]))

(define (item-list-append-one [items : ItemList] [item : Item]) : ItemList
  (match items
    [(ILNil) (ILCons item ILNil)]
    [(ILCons head rest) (ILCons head (item-list-append-one rest item))]))

(define (parse-program-forms [toks : (Array Token)] [cur : (Array i64)] [defs : ItemList]) : ResultParsedProgram
  (let ([form : Sexpr (read-form toks cur)])
    (if (= (peek-tag toks cur) (tag-end))
        (if (is-define-form form)
            (ErrParsedProgram "parse: missing final expression")
            (match (parse form)
              [(OkExpr expr) (OkParsedProgram (PProgram defs expr))]
              [(ErrExpr message) (ErrParsedProgram message)]))
        (if (is-define-form form)
            (match (parse-item form)
              [(OkItem item) (parse-program-forms toks cur (item-list-append-one defs item))]
              [(ErrItem message) (ErrParsedProgram message)])
            (ErrParsedProgram "parse: non-final form must be define")))))

(define (parse-program [toks : (Array Token)]) : ResultParsedProgram
  (let ([cur : (Array i64) (make-array i64 1)])
    (begin
      (array-set! cur 0 0)
      (parse-program-forms toks cur ILNil))))
