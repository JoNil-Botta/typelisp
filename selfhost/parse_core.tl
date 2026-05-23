;; parse_core.tl - Main-less Sexpr -> Expr parser shared by selfhost drivers.
;;
;; The runnable `parse.tl` demo used to contain these definitions directly.
;; Keeping them here lets other drivers reuse the parser without importing a
;; second `main`.

(import "sym_i64_env.tl")
(import "emit_core.tl")
(import "read.tl")

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

(define (parse-set [rest : Sexpr]) : Expr
  (match rest
    [(SCons (SSym name) (SCons value (SNil))) (ESet name (parse value))]
    [_ (begin
         (panic "parse: malformed set!")
         (EInt 0))]))

(define (parse-if [rest : Sexpr]) : Expr
  (match rest
    [(SCons c (SCons t (SCons e (SNil))))
     (EIf (parse c) (parse t) (parse e))]
    [_ (begin
         (panic "parse: malformed if")
         (EInt 0))]))

(define (parse-while [rest : Sexpr]) : Expr
  (match rest
    [(SCons c (SCons body (SNil)))
     (EWhile (parse c) (parse body))]
    [_ (begin
         (panic "parse: malformed while")
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
                                   (ECall op (parse-args rest))))))))))]
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
